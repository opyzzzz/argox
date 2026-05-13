#!/usr/bin/env bash
#===============================================================================
# UUFW 防火墙加固脚本 v3.1.0
# 自动适配 Alpine (nftables/iptables) 与 Debian/Ubuntu (iptables/ufw)
#
# v3.1.0 更新日志:
#   - [修复] 修复 download_cf_ips 在 set -e 下因网络波动导致脚本退出的 bug
#   - [修复] 增加 add_port 端口去重检查，防止重复添加
#   - [新增] SSH 安全检查 (ensure_ssh_safe)，防止误封 SSH 端口
#   - [新增] Cloudflare Only 模式：支持仅允许 CF IP 访问指定端口 (80/443等)
#   - [新增] nftables 语法预检 (nft -c) 与应用失败自动回滚机制
#   - [新增] nftables include 持久化：自动注入 /etc/nftables.conf
#   - [新增] 互斥锁机制：支持 flock 或 mkdir 目录锁回退
#   - [新增] 增强型日志：支持日志速率校验 (LOG_RATE)
#   - [新增] 状态增强：show_status 现在显示持久化状态和布尔配置
#   - [优化] install_deps 分层依赖安装，补齐 curl/flock 等工具
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# 常量与默认值
#===============================================================================
readonly VERSION="3.1.0"
readonly SCRIPT_NAME="uufw"
readonly SSH_PORT_DEFAULT="22"
readonly CF_IPV4_URL="https://www.cloudflare.com/ips-v4/"
readonly CF_IPV6_URL="https://www.cloudflare.com/ips-v6/"
readonly CF_IPS_DIR="/opt/uufw"
readonly BACKUP_DIR="/opt/uufw/backups"
readonly CONFIG_FILE="$CF_IPS_DIR/firewall.conf"
readonly LOCK_DIR="/tmp/uufw.lock"

# 默认配置变量
SSH_PORT="$SSH_PORT_DEFAULT"
EXTRA_PORTS=""
CF_ONLY="false"
CF_PROTECTED_PORTS="80,443"
LOG_ENABLED="true"
LOG_RATE_LIMIT="5/minute"

#===============================================================================
# 颜色与日志
#===============================================================================
if [[ -t 1 ]]; then
    RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
    CYAN='\033[36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

ok()   { printf "%b\n" "${GREEN}[✓]${NC} $*"; }
warn() { printf "%b\n" "${YELLOW}[!]${NC} $*" >&2; }
err()  { printf "%b\n" "${RED}[✗]${NC} $*" >&2; }
step() { printf "%b\n" "${CYAN}[▶]${NC} ${BOLD}$*${NC}"; }
info() { printf '%s\n' "[$(date +%H:%M:%S)] INFO: $*"; }

#===============================================================================
# 工具函数
#===============================================================================
detect_os() {
    [[ -f /etc/alpine-release ]] && { echo alpine; return; }
    [[ -f /etc/debian_version ]] && { echo debian; return; }
    echo unknown
}

detect_firewall_type() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qv "^$" 2>/dev/null; then
        echo "nftables"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

detect_ip() {
    # 优先检测 IPv6 (针对用户纯 IPv6 环境)
    local ip6; ip6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -1)
    if [[ -n "$ip6" ]]; then echo "$ip6"; return; fi
    ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || echo "未知"
}

normalize_bool() {
    case "${1,,}" in
        true|yes|1|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

is_true() {
    [[ "$(normalize_bool "$1")" == "true" ]]
}

# 互斥锁处理 (Bug 9: 增加 mkdir 回退)
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$CF_IPS_DIR/uufw.lock"
        flock -n 8 || { err "另一个 UUFW 实例正在运行"; exit 1; }
    else
        mkdir "$LOCK_DIR" 2>/dev/null || { err "检测到目录锁，请检查是否已有脚本运行"; exit 1; }
        trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
    fi
}

#===============================================================================
# 配置管理
#===============================================================================
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        [[ "$k" =~ ^#.* ]] && continue
        case "$k" in
            SSH_PORT)    SSH_PORT="$v" ;;
            EXTRA_PORTS) EXTRA_PORTS="$v" ;;
            CF_ONLY)     CF_ONLY=$(normalize_bool "$v") ;;
            CF_PROTECTED_PORTS) CF_PROTECTED_PORTS="$v" ;;
            LOG_ENABLED) LOG_ENABLED=$(normalize_bool "$v") ;;
            LOG_RATE_LIMIT) LOG_RATE_LIMIT="$v" ;;
        esac
    done < "$CONFIG_FILE"
}

save_config() {
    mkdir -p "$CF_IPS_DIR"
    cat > "$CONFIG_FILE" <<EOF
SSH_PORT=${SSH_PORT:-$SSH_PORT_DEFAULT}
EXTRA_PORTS=${EXTRA_PORTS:-}
CF_ONLY=${CF_ONLY:-false}
CF_PROTECTED_PORTS=${CF_PROTECTED_PORTS:-80,443}
LOG_ENABLED=${LOG_ENABLED:-true}
LOG_RATE_LIMIT=${LOG_RATE_LIMIT:-5/minute}
EOF
}

#===============================================================================
# CF IP 列表下载 (Bug 1: 增加 || true 和下载失败容错)
#===============================================================================
download_cf_ips() {
    mkdir -p "$CF_IPS_DIR"
    local v4="$CF_IPS_DIR/cf-ipv4.txt"
    local v6="$CF_IPS_DIR/cf-ipv6.txt"
    local updated=0

    step "更新 Cloudflare IP 列表..."
    
    # 下载 IPv4 (IPv6-only 环境下会超时，通过 || true 保护)
    if curl -fsSL --connect-timeout 5 --max-time 10 -o "${v4}.new" "$CF_IPV4_URL" 2>/dev/null; then
        mv "${v4}.new" "$v4"; updated=1
    elif [[ ! -f "$v4" ]]; then
        # 内置回退
        printf "173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n190.93.240.0/20\n188.114.96.0/20\n197.234.240.0/22\n198.41.128.0/17\n162.158.0.0/15\n104.16.0.0/13\n104.24.0.0/14\n172.64.0.0/13\n131.0.72.0/22" > "$v4"
    fi

    # 下载 IPv6
    if curl -fsSL --connect-timeout 5 --max-time 10 -o "${v6}.new" "$CF_IPV6_URL" 2>/dev/null; then
        mv "${v6}.new" "$v6"; updated=1
    elif [[ ! -f "$v6" ]]; then
        printf "2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n2405:b500::/32\n2405:8100::/32\n2a06:98c0::/29\n2c0f:f248::/32" > "$v6"
    fi

    # 修复 Bug 1: 确保即便 updated 为 0 也不退出
    [[ $updated -eq 1 ]] && info "CF IP 列表已更新" || info "使用现有 CF IP 缓存"
}

#===============================================================================
# 核心检查逻辑
#===============================================================================
ensure_ssh_safe() {
    local sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"
    # 检测 SSH 端口是否实际在监听 (Bug 3)
    if command -v ss >/dev/null 2>&1; then
        if ! ss -tln | grep -q ":${sp} "; then
            warn "警告: 检测到 SSH 端口 ${sp} 当前并未处于监听状态！"
            read -rp "强制应用规则可能会导致您失去对服务器的控制，是否继续? [y/N]: " choice
            [[ "$choice" =~ ^[Yy]$ ]] || return 1
        fi
    fi
    return 0
}

#===============================================================================
# 解析辅助函数
#===============================================================================
parse_extra_ports() {
    local ports="${EXTRA_PORTS:-}"
    [[ -z "$ports" ]] && return 0
    printf '%s\n' "$ports" | tr ',' '\n' | while IFS= read -r item; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
}

parse_cf_protected_ports() {
    local p="${CF_PROTECTED_PORTS:-}"
    [[ -z "$p" ]] && return 0
    printf '%s\n' "$p" | tr ',' '\n' | while IFS= read -r item; do
        item=$(echo "$item" | tr -d '[:space:]')
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
}

#===============================================================================
# nftables 规则应用
#===============================================================================
apply_nftables() {
    step "正在构建 nftables 规则..."
    ensure_ssh_safe || return 1

    local sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"
    local nft_conf="$CF_IPS_DIR/uufw.nft"
    local extra_rules=""
    local cf_v4_set="" cf_v6_set=""
    
    # 处理普通额外端口
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local proto="${item%%:*}" port="${item##*:}"
        extra_rules="${extra_rules}        ${proto} dport ${port} accept"$'\n'
    done < <(parse_extra_ports)

    # 处理 Cloudflare 保护端口
    local cf_rules=""
    if is_true "$CF_ONLY"; then
        # 提取 CF IP 列表 (优化: 逗号分隔拼接用于 set)
        local v4_list=""; v4_list=$(tr '\n' ',' < "$CF_IPS_DIR/cf-ipv4.txt" | sed 's/,$//')
        local v6_list=""; v6_list=$(tr '\n' ',' < "$CF_IPS_DIR/cf-ipv6.txt" | sed 's/,$//')
        # Bug 13: 占位符防止空集合语法错误
        [[ -z "$v4_list" ]] && v4_list="1.1.1.1" 
        [[ -z "$v6_list" ]] && v6_list="2606:4700:4700::1111"

        cf_v4_set="set cf_v4 { type ipv4_addr; flags interval; elements = { ${v4_list} } }"
        cf_v6_set="set cf_v6 { type ipv6_addr; flags interval; elements = { ${v6_list} } }"
        
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            cf_rules="${cf_rules}        ip saddr @cf_v4 tcp dport ${port} accept"$'\n'
            cf_rules="${cf_rules}        ip6 saddr @cf_v6 tcp dport ${port} accept"$'\n'
        done < <(parse_cf_protected_ports)
    fi

    # 日志速率限制 (Bug 8)
    local log_limit="${LOG_RATE_LIMIT:-5/minute}"
    local log_stmt=""
    is_true "$LOG_ENABLED" && log_stmt="log prefix \"uufw-blocked: \" flags all limit rate ${log_limit} "

    cat > "$nft_conf" << NFTEOF
#!/usr/sbin/nft -f
flush ruleset

table inet UUFW {
    ${cf_v4_set}
    ${cf_v6_set}

    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept
        tcp dport ${sp} accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
${extra_rules}
${cf_rules}
        ${log_stmt}drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output { type filter hook output priority 0; policy accept; }
}
NFTEOF

    # Bug 5: 语法预检
    if ! nft -c -f "$nft_conf"; then
        err "nftables 语法预检失败，规则未应用！"
        return 1
    fi

    # Bug 6: 备份与回滚
    local bak="$BACKUP_DIR/uufw.nft.bak"
    nft list ruleset > "$bak" 2>/dev/null || true

    if nft -f "$nft_conf"; then
        ok "nftables 规则应用成功"
    else
        err "应用失败，正在回滚..."
        nft -f "$bak" 2>/dev/null || true
        return 1
    fi

    # 持久化 (Bug 7: include 持久化)
    if [[ -d /etc/nftables.d ]]; then
        cp "$nft_conf" /etc/nftables.d/uufw.nft
    elif [[ -f /etc/nftables.conf ]]; then
        if ! grep -q "uufw.nft" /etc/nftables.conf; then
            echo 'include "/opt/uufw/uufw.nft"' >> /etc/nftables.conf
        fi
    fi
    
    if [[ "$(detect_os)" == "alpine" ]]; then
        rc-update add nftables 2>/dev/null || true
        rc-service nftables save 2>/dev/null || true
    fi
}

#===============================================================================
# iptables 规则应用
#===============================================================================
apply_iptables() {
    step "正在应用 iptables 规则..."
    ensure_ssh_safe || return 1

    local sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"
    iptables -F; iptables -X; ip6tables -F 2>/dev/null || true
    
    iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
    ip6tables -P INPUT DROP 2>/dev/null; ip6tables -P FORWARD DROP 2>/dev/null; ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -p tcp --dport "$sp" -j ACCEPT
    iptables -A INPUT -p icmp -j ACCEPT

    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    ip6tables -A INPUT -p icmpv6 -j ACCEPT 2>/dev/null || true

    # 普通额外端口
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local proto="${item%%:*}" port="${item##*:}"
        iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
        ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
    done < <(parse_extra_ports)

    # Cloudflare Only 模式
    if is_true "$CF_ONLY"; then
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            while read -r ip; do
                [[ -n "$ip" ]] && iptables -A INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT
            done < "$CF_IPS_DIR/cf-ipv4.txt"
            while read -r ip; do
                [[ -n "$ip" ]] && ip6tables -A INPUT -s "$ip" -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            done < "$CF_IPS_DIR/cf-ipv6.txt"
        done < <(parse_cf_protected_ports)
    fi

    # 持久化
    if command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
    ok "iptables 规则应用成功"
}

#===============================================================================
# 系统维护
#===============================================================================
install_deps() {
    local os; os=$(detect_os)
    step "检查系统依赖..."
    # Bug 11: 补装基础工具
    case "$os" in
        alpine) apk add --no-cache curl ca-certificates util-linux nftables iptables ip6tables ;;
        debian) 
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates util-linux nftables iptables 
            ;;
    esac
    ok "依赖补齐完成"
}

show_status() {
    local fw; fw=$(detect_firewall_type)
    printf '%b\n' "${BOLD}=== UUFW v${VERSION} 状态报告 ===${NC}"
    printf '  运行系统: %-10s | 防火墙: %s\n' "$(detect_os)" "$fw"
    printf '  本机 IP: %s\n' "$(detect_ip)"
    
    # Bug 10: 持久化状态
    local persisted="未知"
    [[ "$fw" == "nftables" ]] && { [[ -f /etc/nftables.d/uufw.nft || grep -q "uufw.nft" /etc/nftables.conf ]] && persisted="已持久化" || persisted="内存运行"; }
    printf '  持久化: %s\n' "$persisted"
    
    echo ""
    printf '  SSH 端口: %-5s | CF_ONLY: %s\n' "$SSH_PORT" "$(is_true "$CF_ONLY" && echo "开启" || echo "关闭")"
    is_true "$CF_ONLY" && printf '  CF 保护端口: %s\n' "$CF_PROTECTED_PORTS"
    printf '  日志状态: %-5s | 日志限速: %s\n' "$(is_true "$LOG_ENABLED" && echo "开启" || echo "关闭")" "$LOG_RATE_LIMIT"

    echo ""
    printf '%b\n' "${BOLD}=== 开放端口明细 ===${NC}"
    printf '  %-8s %-8s %s\n' "协议" "端口" "类型/说明"
    printf '  %-8s %-8s %s\n' "TCP" "$SSH_PORT" "SSH 管理"
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local proto="${item%%:*}" port="${item##*:}"
        printf '  %-8s %-8s %s\n' "${proto^^}" "$port" "自定义"
    done < <(parse_extra_ports)
}

#===============================================================================
# 端口管理 (Bug 2: 去重逻辑)
#===============================================================================
add_port() {
    local proto port
    read -rp "协议 [tcp/udp]: " proto; proto="${proto:-tcp}"
    read -rp "端口号: " port
    [[ "$port" =~ ^[0-9]+$ ]] || { err "端口无效"; return 1; }

    # Bug 2: 端口去重检查
    if [[ ",${EXTRA_PORTS:-}," == *",${proto}:${port},"* ]]; then
        warn "端口 ${proto}:${port} 已经存在，无需重复添加"
        return 0
    fi

    if [[ -n "${EXTRA_PORTS:-}" ]]; then
        EXTRA_PORTS="${EXTRA_PORTS},${proto}:${port}"
    else
        EXTRA_PORTS="${proto}:${port}"
    fi
    save_config
    apply_current
    ok "已开放 ${proto^^} ${port}"
}

remove_port() {
    [[ -z "${EXTRA_PORTS:-}" ]] && { warn "没有自定义端口"; return 0; }
    local i=1
    while IFS= read -r item; do
        [[ -n "$item" ]] && printf "  %d) %s\n" "$i" "$item" && i=$((i+1))
    done < <(parse_extra_ports)
    read -rp "删除编号 [0取消]: " n
    [[ "$n" == "0" || -z "$n" ]] && return 0
    
    local new_p="" idx=1
    while IFS= read -r item; do
        if [[ $idx -ne $n ]]; then
            [[ -n "$new_p" ]] && new_p="${new_p},${item}" || new_p="$item"
        fi
        idx=$((idx+1))
    done < <(parse_extra_ports)
    
    EXTRA_PORTS="$new_p"
    save_config; apply_current; ok "已移除"
}

#===============================================================================
# 交互菜单 (Bug 14: 新增切换功能)
#===============================================================================
apply_current() {
    local fw; fw=$(detect_firewall_type)
    [[ "$fw" == "nftables" ]] && apply_nftables || apply_iptables
}

menu() {
    while true; do
        clear
        printf '%b\n' "${CYAN}╔════════════════════════════════════════════╗${NC}"
        printf '%b\n' "${CYAN}║      UUFW 防火墙加固管理器 v${VERSION}        ║${NC}"
        printf '%b\n' "${CYAN}╚════════════════════════════════════════════╝${NC}"
        
        local fw; fw=$(detect_firewall_type)
        printf '状态: %s | SSH: %s | CF_ONLY: %s\n\n' "$fw" "$SSH_PORT" "$(is_true "$CF_ONLY" && echo -e "${GREEN}ON${NC}" || echo "OFF")"
        
        printf " 1) 安装/应用最新规则\n"
        printf " 2) 添加自定义开放端口\n"
        printf " 3) 移除自定义开放端口\n"
        printf " 4) 切换 CF_ONLY 模式 (当前: %s)\n" "$(is_true "$CF_ONLY" && echo "开启" || echo "关闭")"
        printf " 5) 切换 日志记录 (当前: %s)\n" "$(is_true "$LOG_ENABLED" && echo "开启" || echo "关闭")"
        printf " 6) 修改 SSH 管理端口\n"
        printf " 7) 查看当前防火墙状态\n"
        printf " 8) 卸载/清除所有规则\n"
        printf " 9) 更新 CF IP 列表\n"
        printf " 0) 退出\n"
        
        read -rp "> " ch
        case "${ch:-0}" in
            1) install_deps; download_cf_ips; apply_current; save_config ;;
            2) add_port ;;
            3) remove_port ;;
            4) 
                is_true "$CF_ONLY" && CF_ONLY="false" || CF_ONLY="true"
                [[ "$CF_ONLY" == "true" ]] && read -rp "请输入要保护的端口 (默认 80,443): " p && CF_PROTECTED_PORTS="${p:-80,443}"
                save_config; apply_current 
                ;;
            5) is_true "$LOG_ENABLED" && LOG_ENABLED="false" || LOG_ENABLED="true"; save_config; apply_current ;;
            6) read -rp "新 SSH 端口: " p; [[ -n "$p" ]] && SSH_PORT="$p" && save_config && apply_current ;;
            7) show_status ;;
            8) uninstall_fw ;;
            9) download_cf_ips; apply_current ;;
            0) exit 0 ;;
        esac
        read -rp "按回车继续..."
    done
}

#===============================================================================
# 卸载逻辑
#===============================================================================
uninstall_fw() {
    warn "这将清除所有 UUFW 生成的规则并放行所有流量！"
    read -rp "确认卸载? [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return 0
    
    local fw; fw=$(detect_firewall_type)
    if [[ "$fw" == "nftables" ]]; then
        nft flush ruleset
        rm -f /etc/nftables.d/uufw.nft
        sed -i '/uufw.nft/d' /etc/nftables.conf 2>/dev/null || true
    else
        iptables -P INPUT ACCEPT; iptables -F; iptables -X
        ip6tables -P INPUT ACCEPT; ip6tables -F; ip6tables -X 2>/dev/null || true
        rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6
    fi
    ok "卸载完成，系统已进入开放模式"
}

#===============================================================================
# 主程序
#===============================================================================
install_shortcut() {
    local dst="/usr/local/bin/${SCRIPT_NAME}"
    if [[ ! -f "$dst" ]]; then
        printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$(readlink -f "$0")" > "$dst"
        chmod +x "$dst"
        ok "快捷命令已安装: uufw"
    fi
}

main() {
    [[ "$(id -u)" -eq 0 ]] || { err "需要 root 权限"; exit 1; }
    load_config
    acquire_lock
    install_shortcut
    
    case "${1:-menu}" in
        install)   install_deps; download_cf_ips; apply_current; save_config ;;
        status)    show_status ;;
        uninstall) uninstall_fw ;;
        menu)      menu ;;
        *)         menu ;;
    esac
}

main "$@"
