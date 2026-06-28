#!/bin/sh
#==================================================
# DNS 检测脚本 v5.4 - Alpine/Debian 源管理增强版
# 修复: 解析重试、IPv6分级评估、包管理换源+安装
# 兼容: Alpine 3.x / Debian 10+
# 用法: wget -qO- https://.../dns-check.sh | sh
#==================================================

set +e

#==================================================
# 颜色
#==================================================
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

#==================================================
# 统计
#==================================================
PASS=0; FAIL=0; WARN=0; SKIP=0; TOTAL=0
RETRY_COUNT=0

ICON_OK="${GREEN}✓${NC}"; ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"; ICON_INFO="${CYAN}ℹ${NC}"; ICON_SKIP="${DIM}⊘${NC}"

# 服务器列表
DOH_SERVERS="Cloudflare|https://cloudflare-dns.com/dns-query Google|https://dns.google/resolve"
DOT_SERVERS="Cloudflare|1.1.1.1 Google|8.8.8.8"

#==================================================
# 工具函数
#==================================================
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  DNS 可用性检测 v5.4 (Alpine/Debian)${NC}"
    echo -e "${BOLD}${BLUE}  时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_section() { echo -e "\n${BOLD}${BLUE}── $1 ──${NC}"; }
print_sub()    { echo -e "  ${CYAN}▸${NC} ${BOLD}$1${NC}"; }

check_pass()   { echo -e "    ${ICON_OK} $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
check_fail()   { echo -e "    ${ICON_FAIL} $1"; [ -n "$2" ] && echo -e "      ${DIM}修复: $2${NC}"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }
check_warn()   { echo -e "    ${ICON_WARN} $1"; [ -n "$2" ] && echo -e "      ${DIM}建议: $2${NC}"; WARN=$((WARN + 1)); TOTAL=$((TOTAL + 1)); }
check_info()   { echo -e "    ${ICON_INFO} $1: ${CYAN}$2${NC}"; }
check_skip()   { echo -e "    ${ICON_SKIP} $1"; SKIP=$((SKIP + 1)); TOTAL=$((TOTAL + 1)); }

#==================================================
# 系统检测
#==================================================
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# 检查root权限
is_root() {
    [ "$(id -u 2>/dev/null)" = "0" ]
}

#==================================================
# Alpine 源管理
#==================================================
alpine_backup_repos() {
    if [ -f /etc/apk/repositories ] && [ ! -f /etc/apk/repositories.bak ]; then
        cp /etc/apk/repositories /etc/apk/repositories.bak 2>/dev/null
    fi
}

alpine_restore_repos() {
    if [ -f /etc/apk/repositories.bak ]; then
        mv /etc/apk/repositories.bak /etc/apk/repositories 2>/dev/null
    fi
}

alpine_set_mirror() {
    mirror="$1"
    case "$mirror" in
        default)
            alpine_backup_repos
            cat > /etc/apk/repositories <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/latest-stable/main
https://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF
            ;;
        edge)
            alpine_backup_repos
            cat > /etc/apk/repositories <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/edge/main
https://dl-cdn.alpinelinux.org/alpine/edge/community
EOF
            ;;
        ustc)
            alpine_backup_repos
            cat > /etc/apk/repositories <<'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
            ;;
        tuna)
            alpine_backup_repos
            cat > /etc/apk/repositories <<'EOF'
https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/community
EOF
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

alpine_install_tools() {
    echo -e "    ${DIM}Alpine: 更新源并安装工具...${NC}"
    
    # 先尝试默认源
    if apk update 2>/dev/null && apk add --no-cache bind-tools curl iputils netcat-openbsd 2>/dev/null; then
        return 0
    fi
    
    echo -e "    ${ICON_WARN} 默认源失败，尝试切换镜像源..."
    
    # 尝试中科大源
    if alpine_set_mirror "ustc" && apk update 2>/dev/null && apk add --no-cache bind-tools curl iputils netcat-openbsd 2>/dev/null; then
        echo -e "    ${ICON_OK} 中科大源安装成功"
        return 0
    fi
    
    # 尝试清华源
    if alpine_set_mirror "tuna" && apk update 2>/dev/null && apk add --no-cache bind-tools curl iputils netcat-openbsd 2>/dev/null; then
        echo -e "    ${ICON_OK} 清华源安装成功"
        return 0
    fi
    
    # 尝试edge源
    if alpine_set_mirror "edge" && apk update 2>/dev/null && apk add --no-cache bind-tools curl iputils netcat-openbsd 2>/dev/null; then
        echo -e "    ${ICON_OK} Edge源安装成功"
        return 0
    fi
    
    # 恢复默认源
    alpine_set_mirror "default"
    return 1
}

#==================================================
# Debian 源管理
#==================================================
debian_backup_sources() {
    if [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.bak ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null
    fi
}

debian_restore_sources() {
    if [ -f /etc/apt/sources.list.bak ]; then
        mv /etc/apt/sources.list.bak /etc/apt/sources.list 2>/dev/null
    fi
}

debian_set_mirror() {
    mirror="$1"
    # 检测Debian版本
    if [ -f /etc/os-release ]; then
        . /etc/os-release 2>/dev/null
        CODENAME="${VERSION_CODENAME:-bookworm}"
    else
        CODENAME="bookworm"
    fi
    
    case "$mirror" in
        default)
            debian_backup_sources
            cat > /etc/apt/sources.list <<EOF
deb https://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware
deb https://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
EOF
            ;;
        ustc)
            debian_backup_sources
            cat > /etc/apt/sources.list <<EOF
deb https://mirrors.ustc.edu.cn/debian ${CODENAME} main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
EOF
            ;;
        tuna)
            debian_backup_sources
            cat > /etc/apt/sources.list <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/debian ${CODENAME} main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
EOF
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

debian_install_tools() {
    echo -e "    ${DIM}Debian: 更新源并安装工具...${NC}"
    
    # 先尝试默认源
    if apt-get update -qq 2>/dev/null && apt-get install -y dnsutils curl iputils-ping netcat-openbsd 2>/dev/null; then
        return 0
    fi
    
    echo -e "    ${ICON_WARN} 默认源失败，尝试切换镜像源..."
    
    # 尝试中科大源
    if debian_set_mirror "ustc" && apt-get update -qq 2>/dev/null && apt-get install -y dnsutils curl iputils-ping netcat-openbsd 2>/dev/null; then
        echo -e "    ${ICON_OK} 中科大源安装成功"
        return 0
    fi
    
    # 尝试清华源
    if debian_set_mirror "tuna" && apt-get update -qq 2>/dev/null && apt-get install -y dnsutils curl iputils-ping netcat-openbsd 2>/dev/null; then
        echo -e "    ${ICON_OK} 清华源安装成功"
        return 0
    fi
    
    # 恢复默认源
    debian_set_mirror "default"
    return 1
}

#==================================================
# 依赖安装主函数
#==================================================
install_dependencies() {
    OS_TYPE=$(detect_os)
    MISSING_TOOLS=""
    
    # 必需工具
    for tool in nslookup curl ping; do
        command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
    done
    
    # 可选工具
    OPTIONAL_MISSING=""
    for tool in nc dig host; do
        command -v "$tool" >/dev/null 2>&1 || OPTIONAL_MISSING="$OPTIONAL_MISSING $tool"
    done
    
    # 没有缺失
    if [ -z "$MISSING_TOOLS" ] && [ -z "$OPTIONAL_MISSING" ]; then
        check_pass "所有依赖已就绪"
        return 0
    fi
    
    echo ""
    echo -e "  ${BOLD}依赖检查和安装${NC}"
    
    # 显示缺失
    [ -n "$MISSING_TOOLS" ] && check_warn "缺少必需工具:${MISSING_TOOLS}"
    [ -n "$OPTIONAL_MISSING" ] && check_info "缺少可选工具" "${OPTIONAL_MISSING}"
    
    # 检查root权限
    if ! is_root; then
        echo ""
        echo -e "    ${ICON_WARN} 非root用户，无法安装依赖"
        case "$OS_TYPE" in
            alpine)
                echo -e "    ${ICON_INFO} 请手动执行: ${CYAN}sudo apk add bind-tools curl iputils netcat-openbsd${NC}"
                ;;
            debian)
                echo -e "    ${ICON_INFO} 请手动执行: ${CYAN}sudo apt-get install -y dnsutils curl iputils-ping netcat-openbsd${NC}"
                ;;
        esac
        echo -e "    ${ICON_INFO} 换源方法: ${CYAN}sudo $0 --fix-source${NC}"
        echo ""
        return 1
    fi
    
    echo ""
    echo -e "  ${BOLD}包管理器安装 (支持自动换源)${NC}"
    
    case "$OS_TYPE" in
        alpine)
            if alpine_install_tools; then
                echo -e "    ${ICON_OK} 依赖安装完成"
            else
                echo -e "    ${ICON_FAIL} 所有源安装失败"
                echo -e "    ${ICON_INFO} 手动安装: ${CYAN}apk add bind-tools curl iputils netcat-openbsd${NC}"
                return 1
            fi
            ;;
        debian)
            if debian_install_tools; then
                echo -e "    ${ICON_OK} 依赖安装完成"
            else
                echo -e "    ${ICON_FAIL} 所有源安装失败"
                echo -e "    ${ICON_INFO} 手动安装: ${CYAN}apt-get install -y dnsutils curl iputils-ping netcat-openbsd${NC}"
                return 1
            fi
            ;;
        *)
            echo -e "    ${ICON_FAIL} 未知系统，无法自动安装"
            return 1
            ;;
    esac
    
    # 验证安装
    STILL_MISSING=""
    for tool in nslookup curl ping; do
        command -v "$tool" >/dev/null 2>&1 || STILL_MISSING="$STILL_MISSING $tool"
    done
    
    if [ -z "$STILL_MISSING" ]; then
        check_pass "所有必需依赖已就绪"
    else
        check_warn "仍有工具缺失:${STILL_MISSING}"
    fi
    
    echo ""
    return 0
}

#==================================================
# 仅修复源 (--fix-source)
#==================================================
fix_source() {
    OS_TYPE=$(detect_os)
    
    echo ""
    echo -e "  ${BOLD}修复软件源${NC}"
    
    if ! is_root; then
        echo -e "    ${ICON_FAIL} 需要root权限"
        echo -e "    ${ICON_INFO} 请使用: ${CYAN}sudo $0 --fix-source${NC}"
        return 1
    fi
    
    case "$OS_TYPE" in
        alpine)
            echo -e "    ${DIM}尝试切换 Alpine 镜像源...${NC}"
            
            # 备份
            alpine_backup_repos
            
            # 测试各镜像源
            for mirror in default ustc tuna edge; do
                alpine_set_mirror "$mirror"
                echo -e "    ${DIM}测试: $mirror 源...${NC}"
                if apk update 2>/dev/null; then
                    echo -e "    ${ICON_OK} $mirror 源可用，已设置"
                    return 0
                fi
            done
            
            # 恢复
            alpine_restore_repos
            echo -e "    ${ICON_FAIL} 所有源均不可用"
            ;;
        debian)
            echo -e "    ${DIM}尝试切换 Debian 镜像源...${NC}"
            
            # 备份
            debian_backup_sources
            
            # 测试各镜像源
            for mirror in default ustc tuna; do
                debian_set_mirror "$mirror"
                echo -e "    ${DIM}测试: $mirror 源...${NC}"
                if apt-get update -qq 2>/dev/null; then
                    echo -e "    ${ICON_OK} $mirror 源可用，已设置"
                    return 0
                fi
            done
            
            # 恢复
            debian_restore_sources
            echo -e "    ${ICON_FAIL} 所有源均不可用"
            ;;
        *)
            echo -e "    ${ICON_FAIL} 未知系统"
            ;;
    esac
    
    return 1
}

#==================================================
# DNS解析 (带重试)
#==================================================
dns_resolve() {
    domain="$1"; type="${2:-A}"
    
    if command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup -timeout=3 -type="$type" "$domain" 2>/dev/null)
        echo "$result" | awk -v t="$type" '
            /^Name:/ { in_section=1; next }
            in_section && /^Address:/ {
                ip = $NF
                if (ip !~ /#/) { print ip; exit }
            }
            in_section && $0 ~ /has .* address/ {
                ip = $NF
                print ip; exit
            }
        '
        return
    fi
    
    if [ "$type" = "A" ] && command -v getent >/dev/null 2>&1; then
        getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1
        return
    fi
    
    echo ""
}

dns_resolve_with_retry() {
    domain="$1"; type="${2:-A}"; max_retries=2
    
    for i in $(seq 1 $max_retries); do
        result=$(dns_resolve "$domain" "$type")
        if [ -n "$result" ]; then
            [ "$i" -gt 1 ] && RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "$result"
            return 0
        fi
        [ "$i" -lt "$max_retries" ] && sleep 1
    done
    echo ""
}

#==================================================
# IP提取
#==================================================
extract_ipv4() {
    result="$1"
    ns_filter="127\.0\.0\.1"
    for ns in $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v ':'); do
        ns_filter="${ns_filter}|$(echo "$ns" | sed 's/\./\\./g')"
    done
    echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE "^(${ns_filter})$" | head -1
}

extract_ipv6() {
    result="$1"
    echo "$result" | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        [ ${#ip} -lt 7 ] && continue
        case "$ip" in
            ::1|::|fe80:*|fc00:*|fd00:*|ff00:*) continue ;;
            *) echo "$ip"; return ;;
        esac
    done | head -1
}

#==================================================
# IPv6可用性
#==================================================
has_ipv6() {
    ip -6 addr show 2>/dev/null | grep -v '::1' | grep -q 'inet6' && return 0
    [ -f /proc/net/if_inet6 ] && grep -v '^00000000000000000000000000000001' /proc/net/if_inet6 2>/dev/null | head -1 | grep -q . && return 0
    ip -6 route show 2>/dev/null | grep -q 'default' && return 0
    grep -q '^nameserver.*:' /etc/resolv.conf 2>/dev/null && return 0
    return 1
}

has_ipv6_internet() {
    for dns in 2001:4860:4860::8888 2606:4700:4700::1111; do
        ping -6 -c 1 -W 2 "$dns" >/dev/null 2>&1 && return 0
    done
    return 1
}

#==================================================
# DoH/DoT
#==================================================
check_doh() {
    domain="$1"; url="$2"
    response=$(curl -s --max-time 5 -H "accept: application/dns-json" \
        "${url}?name=${domain}&type=1" 2>/dev/null)
    
    if [ -n "$response" ] && echo "$response" | grep -qE '"Status":[[:space:]]*0'; then
        flat=$(echo "$response" | tr -d '\n')
        ip=$(echo "$flat" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"$//')
        [ -n "$ip" ] && echo "$ip" || echo "ok"
        return 0
    fi
    return 1
}

check_dot() {
    ip="$1"; port="${2:-853}"
    
    if command -v nc >/dev/null 2>&1; then
        timeout 3 nc -z -w 2 "$ip" "$port" 2>/dev/null && return 0
        timeout 3 sh -c "echo '' | nc -w 2 '$ip' '$port' >/dev/null 2>&1" && return 0
        timeout 3 sh -c "echo '' | nc '$ip' '$port' -w 2 >/dev/null 2>&1" && return 0
    fi
    return 1
}

parse_servers() {
    list="$1"
    for item in $list; do
        [ -z "$item" ] && continue
        echo "$item"
    done
}

#==================================================
# 检测模块
#==================================================

check_system() {
    print_section "系统环境"
    
    OS_TYPE=$(detect_os)
    if [ "$OS_TYPE" = "alpine" ]; then
        check_info "系统" "Alpine $(cat /etc/alpine-release 2>/dev/null)"
    elif [ "$OS_TYPE" = "debian" ]; then
        check_info "系统" "Debian $(cat /etc/debian_version 2>/dev/null) ($(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2))"
    else
        check_info "系统" "$(uname -s) $(uname -r)"
    fi
    check_info "内核" "$(uname -r)"
    check_info "架构" "$(uname -m)"
    
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        check_info "环境" "LXC 容器"
    elif grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        check_info "环境" "容器"
    else
        check_info "环境" "物理机/KVM"
    fi
    
    install_dependencies
}

check_dns_config() {
    print_section "DNS 配置"
    
    print_sub "resolv.conf"
    if [ -f /etc/resolv.conf ]; then
        check_pass "配置文件存在"
        
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | while IFS= read -r line; do
            echo -e "      ${DIM}$line${NC}"
        done
        
        ns_count=$(grep -c '^nameserver' /etc/resolv.conf 2>/dev/null || echo 0)
        ipv4_ns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep -c -v ':' || echo 0)
        ipv6_ns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep -c ':' || echo 0)
        check_info "统计" "总计${ns_count}个 (IPv4:${ipv4_ns} IPv6:${ipv6_ns})"
        
        [ "$ns_count" -eq 0 ] && check_fail "未配置nameserver" "编辑 /etc/resolv.conf"
    else
        check_fail "resolv.conf 不存在"
    fi
    
    if [ -f /etc/nsswitch.conf ]; then
        if grep '^hosts:' /etc/nsswitch.conf 2>/dev/null | grep -q 'dns'; then
            check_pass "nsswitch.conf: DNS已启用"
        else
            check_warn "nsswitch.conf: DNS未在hosts行"
        fi
    fi
}

check_ipv4_dns() {
    print_section "IPv4 DNS 检测"
    
    IPV4_DOMAINS="google.com cloudflare.com github.com microsoft.com amazon.com bbc.co.uk ovh.com cdn.jsdelivr.net"
    
    print_sub "A记录解析"
    ipv4_ok=0; ipv4_total=0
    
    for domain in $IPV4_DOMAINS; do
        ipv4_total=$((ipv4_total + 1))
        result=$(dns_resolve_with_retry "$domain" "A")
        ip=$(extract_ipv4 "$result")
        
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            ipv4_ok=$((ipv4_ok + 1))
            check_pass "$domain → $ip"
        else
            check_fail "$domain 解析失败" "检查DNS配置"
        fi
    done
    
    echo ""
    if [ "$ipv4_ok" -eq "$ipv4_total" ]; then
        check_pass "IPv4 DNS: ${ipv4_ok}/${ipv4_total} 全部成功"
    elif [ "$ipv4_ok" -ge $((ipv4_total * 7 / 8)) ]; then
        check_warn "IPv4 DNS: ${ipv4_ok}/${ipv4_total} (偶发失败)"
    elif [ "$ipv4_ok" -ge $((ipv4_total / 2)) ]; then
        check_warn "IPv4 DNS: ${ipv4_ok}/${ipv4_total} 部分成功"
    else
        check_fail "IPv4 DNS: ${ipv4_ok}/${ipv4_total} 大部分失败" "检查网络和DNS配置"
    fi
    
    print_sub "DNS服务器连通性"
    for ns in $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v ':'); do
        if ping -c 1 -W 2 "$ns" >/dev/null 2>&1; then
            check_pass "DNS $ns 可达"
        else
            check_fail "DNS $ns 不可达"
        fi
    done
    
    for public_dns in 8.8.8.8 1.1.1.1; do
        if ping -c 1 -W 2 "$public_dns" >/dev/null 2>&1; then
            check_pass "公网DNS $public_dns 可达"
        else
            check_warn "公网DNS $public_dns 不可达"
        fi
    done
}

check_encrypted_dns() {
    print_section "加密DNS检测 (DoH/DoT)"
    
    print_sub "DoH (DNS over HTTPS)"
    
    if ! command -v curl >/dev/null 2>&1; then
        check_skip "curl未安装，跳过DoH检测"
    else
        doh_ok=0; doh_total=0
        parsed_list=$(parse_servers "$DOH_SERVERS")
        
        while IFS='|' read -r name url; do
            [ -z "$name" ] && continue
            doh_total=$((doh_total + 1))
            
            result=$(check_doh "google.com" "$url" 2>/dev/null)
            if [ -n "$result" ]; then
                doh_ok=$((doh_ok + 1))
                if [ "$result" != "ok" ]; then
                    check_pass "$name DoH → $result"
                else
                    check_pass "$name DoH 可用"
                fi
            else
                check_fail "$name DoH 不可用" "检查443端口和TLS"
            fi
        done <<EOF
$parsed_list
EOF
        
        echo ""
        if [ "$doh_total" -gt 0 ]; then
            if [ "$doh_ok" -eq "$doh_total" ]; then
                check_pass "DoH: 全部可用 (${doh_ok}/${doh_total})"
            elif [ "$doh_ok" -gt 0 ]; then
                check_warn "DoH: 部分可用 (${doh_ok}/${doh_total})"
            else
                check_fail "DoH: 全部不可用" "检查443端口和TLS"
            fi
        fi
    fi
    
    echo ""
    print_sub "DoT (DNS over TLS)"
    
    if ! command -v nc >/dev/null 2>&1; then
        check_skip "nc未安装，跳过DoT检测"
    else
        dot_ok=0; dot_total=0
        parsed_list=$(parse_servers "$DOT_SERVERS")
        
        while IFS='|' read -r name ip; do
            [ -z "$name" ] && continue
            dot_total=$((dot_total + 1))
            
            if check_dot "$ip" 853; then
                dot_ok=$((dot_ok + 1))
                check_pass "$name DoT ($ip:853) 可达"
            else
                check_fail "$name DoT ($ip:853) 不可达" "检查853端口和防火墙"
            fi
        done <<EOF
$parsed_list
EOF
        
        echo ""
        if [ "$dot_total" -gt 0 ]; then
            if [ "$dot_ok" -eq "$dot_total" ]; then
                check_pass "DoT: 全部可达 (${dot_ok}/${dot_total})"
            elif [ "$dot_ok" -gt 0 ]; then
                check_warn "DoT: 部分可达 (${dot_ok}/${dot_total})"
            else
                check_fail "DoT: 全部不可达" "检查853端口和TLS"
            fi
        fi
    fi
}

check_ipv6_dns() {
    print_section "IPv6 DNS 检测"
    
    if ! has_ipv6; then
        check_skip "IPv6未启用，跳过检测"
        return
    fi
    
    print_sub "IPv6 接口"
    check_pass "IPv6 已启用"
    
    ipv6_addr=$(ip -6 addr show 2>/dev/null | grep 'inet6' | grep -v '::1' | awk '{print $2}' | head -1)
    [ -n "$ipv6_addr" ] && check_info "地址" "$ipv6_addr"
    
    ipv6_gw=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [ -n "$ipv6_gw" ]; then
        check_info "网关" "$ipv6_gw"
        if ping -6 -c 1 -W 2 "$ipv6_gw" >/dev/null 2>&1; then
            check_pass "网关可达"
        else
            check_fail "网关不可达"
        fi
    fi
    
    IPV6_DOMAINS="google.com cloudflare.com he.net ipv6.google.com facebook.com ip6only.me"
    
    print_sub "AAAA记录解析"
    ipv6_ok=0; ipv6_total=0
    
    for domain in $IPV6_DOMAINS; do
        ipv6_total=$((ipv6_total + 1))
        result=$(dns_resolve_with_retry "$domain" "AAAA")
        ip=$(extract_ipv6 "$result")
        
        if [ -n "$ip" ] && [ ${#ip} -gt 6 ]; then
            ipv6_ok=$((ipv6_ok + 1))
            check_pass "$domain → $ip"
        else
            check_warn "$domain 无AAAA记录"
        fi
    done
    
    echo ""
    if [ "$ipv6_ok" -eq "$ipv6_total" ]; then
        check_pass "IPv6 DNS: ${ipv6_ok}/${ipv6_total} 全部成功"
    elif [ "$ipv6_ok" -ge $((ipv6_total * 2 / 3)) ]; then
        check_pass "IPv6 DNS: ${ipv6_ok}/${ipv6_total} 基本可用"
    elif [ "$ipv6_ok" -gt 0 ]; then
        check_warn "IPv6 DNS: ${ipv6_ok}/${ipv6_total} 部分成功" "可能IPv6路由不完整"
    else
        check_warn "IPv6 DNS: 全部失败" "检查IPv6网络配置"
    fi
    
    print_sub "IPv6 连通性"
    
    ipv6_ns_found=0
    for ns in $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep ':'); do
        ipv6_ns_found=1
        if ping -6 -c 1 -W 2 "$ns" >/dev/null 2>&1; then
            check_pass "DNS $ns 可达"
        else
            check_fail "DNS $ns 不可达"
        fi
    done
    [ "$ipv6_ns_found" -eq 0 ] && check_info "IPv6 DNS" "未配置IPv6 nameserver"
    
    if has_ipv6_internet; then
        check_pass "公网IPv6可达"
        
        print_sub "IPv6 HTTP 访问"
        if command -v curl >/dev/null 2>&1; then
            for url in "https://ipv6.google.com" "https://cloudflare.com"; do
                http_code=$(curl -6 -s --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
                [ -z "$http_code" ] && http_code="000"
                if echo "$http_code" | grep -q '^[23]'; then
                    check_pass "$url → HTTP $http_code"
                else
                    check_warn "$url → HTTP $http_code"
                fi
            done
        else
            check_skip "curl未安装"
        fi
    else
        if [ "$ipv6_ok" -gt 0 ]; then
            check_info "公网IPv6" "不可达 (仅本地IPv6可用)"
        else
            check_warn "公网IPv6不可达" "IPv6功能受限"
        fi
    fi
}

print_report() {
    print_section "检测报告"
    
    echo ""
    echo -e "  ${GREEN}通过: $PASS${NC}"
    echo -e "  ${YELLOW}警告: $WARN${NC}"
    echo -e "  ${RED}失败: $FAIL${NC}"
    echo -e "  ${DIM}跳过: $SKIP${NC}"
    [ "$RETRY_COUNT" -gt 0 ] && echo -e "  ${CYAN}重试成功: $RETRY_COUNT${NC}"
    echo -e "  ${BOLD}总计: $TOTAL${NC}"
    echo ""
    
    if [ "$TOTAL" -gt 0 ]; then
        score=$(( (PASS * 100) / TOTAL ))
    else
        score=0
    fi
    
    if [ "$FAIL" -eq 0 ] && [ "$score" -ge 90 ]; then
        echo -e "  ${GREEN}${BOLD}★★★★★ DNS服务正常 (${score}分)${NC}"
    elif [ "$FAIL" -eq 0 ] && [ "$score" -ge 70 ]; then
        echo -e "  ${GREEN}${BOLD}★★★★☆ DNS基本可用 (${score}分)${NC}"
    elif [ "$FAIL" -le 2 ]; then
        echo -e "  ${YELLOW}${BOLD}★★★☆☆ 存在部分问题 (${score}分)${NC}"
    elif [ "$FAIL" -le 5 ]; then
        echo -e "  ${RED}${BOLD}★★☆☆☆ 需要修复 (${score}分)${NC}"
    else
        echo -e "  ${RED}${BOLD}★☆☆☆☆ 服务异常 (${score}分)${NC}"
    fi
    
    echo ""
    echo -e "完成: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

#==================================================
# 主函数
#==================================================
main() {
    # 处理参数
    while [ $# -gt 0 ]; do
        case "$1" in
            --fix-source)
                fix_source
                exit $?
                ;;
            -h|--help)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --fix-source    修复软件源 (自动选择可用镜像)"
                echo "  -h, --help      显示帮助"
                echo ""
                echo "示例:"
                echo "  $0                  # 检测DNS"
                echo "  sudo $0 --fix-source # 修复源"
                echo ""
                exit 0
                ;;
        esac
        shift
    done
    
    print_header
    check_system
    check_dns_config
    check_ipv4_dns
    check_encrypted_dns
    check_ipv6_dns
    print_report
    
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

main "$@"
