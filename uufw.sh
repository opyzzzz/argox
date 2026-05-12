#!/usr/bin/env bash
#===============================================================================
# UUFW 防火墙加固脚本 v2.2.3
# 自动适配 Alpine (nftables/iptables) 与 Debian/Ubuntu (iptables/ufw)
#
# v2.2.3 修复:
#   - parse_extra_ports: read -ra 改为 while read 循环（完整兼容性）
#   - remove_port: 空数组保护
#   - 脚本重命名uufw
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# 常量
#===============================================================================
readonly VERSION="2.2.3"
readonly SCRIPT_NAME="uufw"
readonly SSH_PORT_DEFAULT="22"
readonly CF_IPV4_URL="https://www.cloudflare.com/ips-v4/"
readonly CF_IPV6_URL="https://www.cloudflare.com/ips-v6/"
readonly CF_IPS_DIR="/opt/uufw"
readonly BACKUP_DIR="/opt/uufw/backups"
readonly CONFIG_FILE="$CF_IPS_DIR/firewall.conf"

#===============================================================================
# 颜色
#===============================================================================
if [[ -t 1 ]]; then
    RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
    CYAN='\033[36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

#===============================================================================
# 日志
#===============================================================================
ok()   { printf "%b\n" "${GREEN}[✓]${NC} $*"; }
warn() { printf "%b\n" "${YELLOW}[!]${NC} $*" >&2; }
err()  { printf "%b\n" "${RED}[✗]${NC} $*" >&2; }
step() { printf "%b\n" "${CYAN}[▶]${NC} ${BOLD}$*${NC}"; }
info() { printf '%s\n' "[$(date +%H:%M:%S)] INFO: $*"; }

#===============================================================================
# 系统检测
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
    ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || echo "未知"
}

#===============================================================================
# 配置管理
#===============================================================================
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] || continue
        case "$k" in
            SSH_PORT)    SSH_PORT="$v" ;;
            EXTRA_PORTS) EXTRA_PORTS="$v" ;;
        esac
    done < "$CONFIG_FILE"
    SSH_PORT="${SSH_PORT:-$SSH_PORT_DEFAULT}"
    EXTRA_PORTS="${EXTRA_PORTS:-}"
}

save_config() {
    mkdir -p "$CF_IPS_DIR"
    cat > "$CONFIG_FILE" <<EOF
SSH_PORT=${SSH_PORT:-$SSH_PORT_DEFAULT}
EXTRA_PORTS=${EXTRA_PORTS:-}
EOF
}

#===============================================================================
# CF IP 列表下载
#===============================================================================
download_cf_ips() {
    mkdir -p "$CF_IPS_DIR"
    local v4="$CF_IPS_DIR/cf-ipv4.txt"
    local v6="$CF_IPS_DIR/cf-ipv6.txt"
    local updated=0

    if curl -fsSL --connect-timeout 10 --max-time 30 -o "${v4}.new" "$CF_IPV4_URL" 2>/dev/null; then
        mv "${v4}.new" "$v4"; updated=1
    elif [[ ! -f "$v4" ]]; then
        cat > "$v4" << 'EOF'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
EOF
    fi

    if curl -fsSL --connect-timeout 10 --max-time 30 -o "${v6}.new" "$CF_IPV6_URL" 2>/dev/null; then
        mv "${v6}.new" "$v6"; updated=1
    elif [[ ! -f "$v6" ]]; then
        cat > "$v6" << 'EOF'
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
EOF
    fi

    [[ $updated -eq 1 ]] && info "CF IP 列表已更新"
}

#===============================================================================
# 备份
#===============================================================================
backup_rules() {
    mkdir -p "$BACKUP_DIR"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local fw_type; fw_type=$(detect_firewall_type)

    case "$fw_type" in
        nftables)
            nft list ruleset > "$BACKUP_DIR/nftables-${ts}.txt" 2>/dev/null || true
            ok "备份: nftables-${ts}.txt"
            ;;
        iptables)
            iptables-save > "$BACKUP_DIR/iptables-v4-${ts}.txt" 2>/dev/null || true
            ip6tables-save > "$BACKUP_DIR/iptables-v6-${ts}.txt" 2>/dev/null || true
            ok "备份完成"
            ;;
    esac

    find "$BACKUP_DIR" -type f 2>/dev/null | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
}

#===============================================================================
# 解析额外端口（v2.2.2: while read 循环替代 read -ra 数组）
#===============================================================================
parse_extra_ports() {
    local ports="${EXTRA_PORTS:-}"
    if [[ -z "$ports" ]]; then
        return 0
    fi
    # 将逗号替换为换行，逐行读取（兼容所有 Bash 版本）
    printf '%s\n' "$ports" | tr ',' '\n' | while IFS= read -r item; do
        # Bash 原生 trim
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
}

#===============================================================================
# nftables 规则
#===============================================================================
apply_nftables() {
    step "应用 nftables 规则..."
    backup_rules

    local sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"
    local nft_conf="$CF_IPS_DIR/uufw.nft"
    local extra_rules=""

    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local proto="${item%%:*}" port="${item##*:}"
        extra_rules="${extra_rules}        ${proto} dport ${port} accept"$'\n'
    done < <(parse_extra_ports)

    cat > "$nft_conf" << NFTEOF
#!/usr/sbin/nft -f
# UUFW Firewall Rules v${VERSION}
# Generated: $(date)

flush ruleset

table inet UUFW {

    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept
        tcp dport ${sp} accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
${extra_rules}
        log prefix "uufw-blocked: " drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFTEOF

    if nft -f "$nft_conf" 2>/dev/null; then
        ok "nftables 规则已应用"
    else
        err "nftables 规则应用失败！"
        warn "请检查: nft -f $nft_conf"
        return 1
    fi

    # 持久化
    if [[ -d /etc/nftables ]]; then
        cp "$nft_conf" /etc/nftables/uufw.nft
    elif [[ -d /etc/nftables.d ]]; then
        cp "$nft_conf" /etc/nftables.d/uufw.nft
    fi
    if [[ "$(detect_os)" == "alpine" ]]; then
        rc-update add nftables 2>/dev/null || true
        rc-service nftables save 2>/dev/null || true
    fi

    ok "nftables 规则已持久化"
}

#===============================================================================
# iptables 规则
#===============================================================================
apply_iptables() {
    step "应用 iptables 规则..."
    backup_rules

    local sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"

    # 清空
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t nat -X 2>/dev/null || true
    ip6tables -F 2>/dev/null || true
    ip6tables -X 2>/dev/null || true

    # 默认策略
    iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
    ip6tables -P INPUT DROP 2>/dev/null; ip6tables -P FORWARD DROP 2>/dev/null; ip6tables -P OUTPUT ACCEPT 2>/dev/null || true

    # 回环
    iptables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true

    # 已建立连接
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # SSH
    iptables -A INPUT -p tcp --dport "$sp" -j ACCEPT

    # ICMP
    iptables -A INPUT -p icmp -j ACCEPT
    ip6tables -A INPUT -p icmpv6 -j ACCEPT 2>/dev/null || true

    # 自定义端口
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local proto="${item%%:*}" port="${item##*:}"
        [[ "$proto" == "tcp" ]] && iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
        [[ "$proto" == "udp" ]] && iptables -A INPUT -p udp --dport "$port" -j ACCEPT
        [[ "$proto" == "tcp" ]] && ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        [[ "$proto" == "udp" ]] && ip6tables -A INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    done < <(parse_extra_ports)

    ok "iptables 规则已应用"

    # 持久化
    if command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        ok "iptables 规则已持久化"
    fi
}

#===============================================================================
# 安装依赖
#===============================================================================
install_deps() {
    local fw_type; fw_type=$(detect_firewall_type)

    if [[ "$fw_type" == "ufw" ]]; then
        warn "检测到 ufw 正在运行，可能与 iptables 规则冲突"
        read -rp "禁用 ufw 并安装 iptables? [Y/n]: " c
        if [[ ! "$c" =~ ^[Nn]$ ]]; then
            ufw disable 2>/dev/null || true
            ok "ufw 已禁用"
            case "$(detect_os)" in
                alpine) apk add --no-cache iptables ip6tables ;;
                debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables ;;
            esac
            ok "iptables 已安装"
            return 0
        else
            warn "跳过安装"
            return 1
        fi
    fi

    if [[ "$fw_type" == "none" ]]; then
        step "安装防火墙..."
        case "$(detect_os)" in
            alpine) apk add --no-cache iptables ip6tables nftables ;;
            debian) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables nftables ;;
        esac
        ok "防火墙已安装"
    else
        info "防火墙已就绪: $fw_type"
    fi
}

#===============================================================================
# 状态展示
#===============================================================================
show_status() {
    local fw_type; fw_type=$(detect_firewall_type)
    local sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"

    printf '%b\n' "${BOLD}=== 防火墙状态 ===${NC}"
    printf '  版本: %s\n' "$VERSION"
    printf '  系统: %s | 类型: %s\n' "$(detect_os)" "$fw_type"
    printf '  本机 IP: %s\n' "$(detect_ip)"

    echo ""
    printf '%b\n' "${BOLD}=== 开放端口 (入站) ===${NC}"
    printf '  %-8s %-8s %s\n' "协议" "端口" "说明"
    printf '  %-8s %-8s %s\n' "TCP" "$sp" "SSH"
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local proto="${item%%:*}" port="${item##*:}"
        printf '  %-8s %-8s %s\n' "${proto^^}" "$port" "自定义"
    done < <(parse_extra_ports)
    echo "  ICMP     -       Ping 诊断"

    echo ""
    printf '%b\n' "${BOLD}=== 实际监听端口 ===${NC}"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -v "127.0.0.1\|::1" || echo "  无公网监听端口（安全）"
    fi

    echo ""
    printf '%b\n' "${BOLD}=== 拦截统计 ===${NC}"
    case "$fw_type" in
        nftables)
            local blocked
            blocked=$(dmesg 2>/dev/null | grep -c "uufw-blocked" || echo 0)
            echo "  拦截: ${blocked} 次"
            dmesg 2>/dev/null | grep "uufw-blocked" | tail -3 | sed 's/^/  /'
            ;;
        iptables)
            iptables -L INPUT -v -n 2>/dev/null | head -5 | sed 's/^/  /'
            ;;
        ufw)
            ufw status numbered 2>/dev/null || true
            ;;
    esac
}

#===============================================================================
# 添加端口
#===============================================================================
add_port() {
    local proto port
    read -rp "协议 [tcp]: " proto; proto="${proto:-tcp}"
    [[ "$proto" =~ ^(tcp|udp)$ ]] || { err "无效协议: $proto"; return 1; }
    read -rp "端口号: " port
    [[ "$port" =~ ^[0-9]+$ ]] && [[ $port -ge 1 ]] && [[ $port -le 65535 ]] || { err "无效端口: $port"; return 1; }

    local new_entry="${proto}:${port}"
    if [[ -n "${EXTRA_PORTS:-}" ]]; then
        EXTRA_PORTS="${EXTRA_PORTS},${new_entry}"
    else
        EXTRA_PORTS="$new_entry"
    fi
    save_config
    apply_current
    ok "已开放: ${proto^^} $port"
}

#===============================================================================
# 移除端口（v2.2.2: 空数组保护）
#===============================================================================
remove_port() {
    if [[ -z "${EXTRA_PORTS:-}" ]]; then
        warn "没有自定义端口"
        return 0
    fi

    echo "当前自定义端口:"
    local i=1
    local items_str=""
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        items_str="${items_str}${item}"$'\n'
        printf '  %d) %s\n' "$i" "$item"
        i=$((i+1))
    done < <(parse_extra_ports)
    printf '  0) 取消\n'

    local total=$((i-1))
    [[ $total -eq 0 ]] && { warn "没有自定义端口"; return 0; }

    read -rp "删除编号: " n
    [[ "$n" == "0" ]] && return 0
    [[ "$n" =~ ^[0-9]+$ ]] && [[ $n -ge 1 ]] && [[ $n -le $total ]] || { err "无效编号"; return 1; }

    # 重建 EXTRA_PORTS（v2.2.2: 空数组保护）
    local new_ports="" idx=1 first=1
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        if [[ $idx -ne $n ]]; then
            if [[ $first -eq 1 ]]; then
                new_ports="$item"
                first=0
            else
                new_ports="${new_ports},${item}"
            fi
        fi
        idx=$((idx+1))
    done < <(parse_extra_ports)

    EXTRA_PORTS="$new_ports"
    save_config
    apply_current
    ok "已移除"
}

#===============================================================================
# 临时开放端口
#===============================================================================
temp_open_port() {
    local proto port duration
    read -rp "协议 [tcp]: " proto; proto="${proto:-tcp}"
    read -rp "端口号: " port
    read -rp "持续时间(秒) [300]: " duration; duration="${duration:-300}"

    step "临时开放 ${proto^^} $port (${duration}s 后自动关闭)"

    case "$(detect_firewall_type)" in
        nftables)
            nft add rule inet UUFW input ${proto} dport "$port" accept 2>/dev/null || true
            ok "已开放"
            (sleep "$duration"; apply_nftables) &
            ;;
        iptables)
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
            ok "已开放"
            (sleep "$duration"; iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null) &
            ;;
    esac

    warn "后台任务已启动，关闭终端不会取消"
}

#===============================================================================
# 卸载
#===============================================================================
uninstall_fw() {
    printf '%b\n' "${RED}${BOLD}=== 卸载防火墙规则 ===${NC}"
    read -rp "确认卸载? [y/N]: " c
    if [[ ! "$c" =~ ^[Yy]$ ]]; then
        info "已取消"
        return 0
    fi

    local fw_type; fw_type=$(detect_firewall_type)

    case "$fw_type" in
        nftables)
            nft flush ruleset 2>/dev/null || true
            rm -f /etc/nftables/uufw.nft /etc/nftables.d/uufw.nft "$CF_IPS_DIR/uufw.nft"
            nft add table inet filter 2>/dev/null || true
            nft add chain inet filter input { type filter hook input priority 0\; policy accept\; } 2>/dev/null || true
            ok "nftables 规则已清除"
            ;;
        iptables)
            iptables -F 2>/dev/null; iptables -X 2>/dev/null
            iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
            ip6tables -F 2>/dev/null; ip6tables -X 2>/dev/null || true
            ip6tables -P INPUT ACCEPT 2>/dev/null; ip6tables -P FORWARD ACCEPT 2>/dev/null; ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
            rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6
            ok "iptables 规则已清除"
            ;;
        ufw)
            ufw --force reset >/dev/null 2>&1 || true
            ok "ufw 已重置"
            ;;
    esac

    echo ""
    warn "防火墙已清除，系统处于开放状态！"
    warn "重新安装: uufw install"
}

#===============================================================================
# 应用当前配置
#===============================================================================
apply_current() {
    local fw; fw=$(detect_firewall_type)
    case "$fw" in
        nftables) apply_nftables ;;
        iptables|ufw) apply_iptables ;;
    esac
}

#===============================================================================
# 交互菜单
#===============================================================================
menu() {
    while true; do
        clear 2>/dev/null || true
        printf '%b\n' "${CYAN}╔══════════════════════════════════════╗${NC}"
        printf '%b\n' "${CYAN}║    UUFW 防火墙管理 v${VERSION}        ║${NC}"
        printf '%b\n' "${CYAN}╚══════════════════════════════════════╝${NC}"

        local fw_type; fw_type=$(detect_firewall_type)
        printf '\n防火墙: %s | OS: %s\n' "$fw_type" "$(detect_os)"
        printf 'SSH 端口: %s\n' "${SSH_PORT:-$SSH_PORT_DEFAULT}"

        # 显示自定义端口
        local extra_count=0
        while IFS= read -r item; do
            [[ -z "$item" ]] && continue
            [[ $extra_count -eq 0 ]] && printf '自定义端口: '
            printf '%s ' "$item"
            extra_count=$((extra_count+1))
        done < <(parse_extra_ports)
        [[ $extra_count -gt 0 ]] && echo ""

        if [[ "$fw_type" == "ufw" ]]; then
            printf '%b\n' "${RED}[警告] ufw 可能冲突${NC}"
        fi
        printf '\n'

        printf " 1) 安装/应用规则\n"
        printf " 2) 卸载规则\n"
        printf " 3) 查看状态\n"
        printf " 4) 添加开放端口\n"
        printf " 5) 移除开放端口\n"
        printf " 6) 临时开放端口\n"
        printf " 7) 修改 SSH 端口\n"
        printf " 8) 更新 CF IP 列表\n"
        printf " 9) 备份当前规则\n"
        printf " 0) 退出\n"

        printf '\n'
        read -rp "> " ch
        case "${ch:-0}" in
            1)
                install_deps || { read -rp "回车继续..."; continue; }
                download_cf_ips
                apply_current
                save_config
                ;;
            2) uninstall_fw ;;
            3) show_status ;;
            4) add_port ;;
            5) remove_port ;;
            6) temp_open_port ;;
            7)
                read -rp "新 SSH 端口: " p
                if [[ -n "$p" ]]; then
                    SSH_PORT="$p"
                    save_config
                    apply_current
                    ok "SSH 端口已更新为 $p"
                fi
                ;;
            8)
                download_cf_ips
                apply_current
                ok "CF IP 列表已更新"
                ;;
            9) backup_rules ;;
            0) exit 0 ;;
        esac
        read -rp "回车继续..."
    done
}

#===============================================================================
# 快捷命令
#===============================================================================
install_shortcut() {
    local me="$0" dst="/usr/local/bin/${SCRIPT_NAME}" real
    real="$(readlink -f "$me" 2>/dev/null || realpath "$me" 2>/dev/null || echo "$me")"
    [[ -f "$dst" ]] && [[ "$(readlink -f "$dst" 2>/dev/null)" == "$real" ]] && return 0
    printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$real" > "$dst"
    chmod +x "$dst"
    ok "快捷命令已安装: ${SCRIPT_NAME}"
}

#===============================================================================
# 帮助
#===============================================================================
show_help() {
    cat <<EOF
UUFW 防火墙管理器 v${VERSION}
用法: uufw [命令]

命令:
  install     安装/应用防火墙规则
  uninstall   卸载所有规则
  status      查看状态和开放端口
  backup      备份当前规则
  menu        交互管理面板（默认）

示例:
  uufw install
  uufw status
EOF
}

#===============================================================================
# 主入口
#===============================================================================
main() {
    [[ "$(id -u)" -eq 0 ]] || { err "需要 root 权限"; exit 1; }
    install_shortcut
    load_config
    mkdir -p "$CF_IPS_DIR" "$BACKUP_DIR"

    case "${1:-menu}" in
        install)
            install_deps || exit 0
            download_cf_ips
            apply_current
            save_config
            ;;
        uninstall) uninstall_fw ;;
        status)    show_status ;;
        backup)    backup_rules ;;
        menu)      menu ;;
        help|--help|-h) show_help ;;
        version|--version|-v) echo "v$VERSION" ;;
        *)         show_help ;;
    esac
}

main "$@"
