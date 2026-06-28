#!/bin/sh
#==================================================
# DNS 检测脚本 v5.8 - 第六轮审计修复版
# 修复: check_doh条件判断、run_with_timeout PID回收
# 优化: 消除count_loop子shell、统一变量命名
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
# 全局变量 (显式初始化)
#==================================================
PASS=0; FAIL=0; WARN=0; SKIP=0; TOTAL=0
RETRY_COUNT=0
IPV6_AAAA_OK=0; IPV6_AAAA_TOTAL=0
IPV6_E2E_AVAILABLE=0

ICON_OK="${GREEN}✓${NC}"; ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"; ICON_INFO="${CYAN}ℹ${NC}"; ICON_SKIP="${DIM}⊘${NC}"

# 配置 (全局常量)
DOH_SERVERS="Cloudflare|https://cloudflare-dns.com/dns-query Google|https://dns.google/resolve"
DOT_SERVERS="Cloudflare|1.1.1.1 Google|8.8.8.8"
IPV6_DNS_SERVERS="2001:4860:4860::8888 2606:4700:4700::1111"
IPV6_CHECK_SERVICES="https://api64.ipify.org https://v6.ident.me"
IPV6_DOMAINS="google.com cloudflare.com he.net ipv6.google.com facebook.com ip6only.me"
IPV4_DOMAINS="google.com cloudflare.com github.com microsoft.com amazon.com bbc.co.uk ovh.com cdn.jsdelivr.net"

#==================================================
# 工具函数
#==================================================
print_header() {
    printf '\n'
    printf '%b\n' "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    printf '%b\n' "${BOLD}${BLUE}  DNS 可用性检测 v5.8 (Alpine/Debian)${NC}"
    printf '%b\n' "${BOLD}${BLUE}  时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    printf '%b\n' "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    printf '\n'
}

print_section() { printf '\n%b\n' "${BOLD}${BLUE}── $1 ──${NC}"; }
print_sub()    { printf '  %b\n' "${CYAN}▸${NC} ${BOLD}$1${NC}"; }

check_pass()   { printf '    %b\n' "${ICON_OK} $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
check_fail()   {
    printf '    %b\n' "${ICON_FAIL} $1"
    [ -n "$2" ] && printf '      %b\n' "${DIM}修复: $2${NC}"
    FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
}
check_warn()   {
    printf '    %b\n' "${ICON_WARN} $1"
    [ -n "$2" ] && printf '      %b\n' "${DIM}建议: $2${NC}"
    WARN=$((WARN + 1)); TOTAL=$((TOTAL + 1))
}
check_info()   { printf '    %b\n' "${ICON_INFO} $1: ${CYAN}$2${NC}"; }
check_skip()   { printf '    %b\n' "${ICON_SKIP} $1"; SKIP=$((SKIP + 1)); TOTAL=$((TOTAL + 1)); }

#==================================================
# 系统检测
#==================================================
detect_os() {
    if [ -f /etc/alpine-release ]; then echo "alpine"
    elif [ -f /etc/debian_version ]; then echo "debian"
    else echo "unknown"; fi
}

is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }

# 修复: PID回收安全检查
run_with_timeout() {
    seconds="$1"; shift
    [ $# -eq 0 ] && return 1
    
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@" 2>/dev/null; return $?
    fi
    
    "$@" 2>/dev/null & cmd_pid=$!
    (
        sleep "$seconds"
        kill -9 "$cmd_pid" 2>/dev/null
    ) &
    watchdog_pid=$!
    
    wait "$cmd_pid" 2>/dev/null; exit_code=$?
    
    # 安全检查: 确认PID仍属于watchdog进程
    if kill -0 "$watchdog_pid" 2>/dev/null; then
        kill -9 "$watchdog_pid" 2>/dev/null
        wait "$watchdog_pid" 2>/dev/null
    fi
    return $exit_code
}

# grep计数 (使用grep -c + 错误处理)
safe_grep_count() {
    pattern="$1"; file="$2"
    if [ -f "$file" ]; then
        count=$(grep -c "$pattern" "$file" 2>/dev/null)
        echo "${count:-0}"
    else
        echo "0"
    fi
}

#==================================================
# 源管理
#==================================================
alpine_get_version() {
    if [ -f /etc/alpine-release ]; then
        cat /etc/alpine-release | cut -d. -f1-2
    else
        echo "latest-stable"
    fi
}

alpine_backup_repos() {
    [ -f /etc/apk/repositories ] && [ ! -f /etc/apk/repositories.bak ] && \
        cp /etc/apk/repositories /etc/apk/repositories.bak 2>/dev/null
}

alpine_restore_repos() {
    [ -f /etc/apk/repositories.bak ] && \
        mv /etc/apk/repositories.bak /etc/apk/repositories 2>/dev/null
}

alpine_set_mirror() {
    mirror="$1"
    ALPINE_VER=$(alpine_get_version)
    alpine_backup_repos
    case "$mirror" in
        default)
            cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community
EOF
            ;;
        ustc)
            cat > /etc/apk/repositories <<EOF
https://mirrors.ustc.edu.cn/alpine/v${ALPINE_VER}/main
https://mirrors.ustc.edu.cn/alpine/v${ALPINE_VER}/community
EOF
            ;;
        *) return 1 ;;
    esac
    return 0
}

alpine_install_tools() {
    printf '    %b\n' "${DIM}Alpine: 更新源并安装工具...${NC}"
    if apk update 2>/dev/null && apk add --no-cache bind-tools curl iputils netcat-openbsd 2>/dev/null; then
        return 0
    fi
    printf '    %b\n' "${ICON_WARN} 默认源失败，尝试切换镜像源..."
    if alpine_set_mirror "ustc" && apk update 2>/dev/null && apk add --no-cache bind-tools curl iputils netcat-openbsd 2>/dev/null; then
        printf '    %b\n' "${ICON_OK} ustc源安装成功"; return 0
    fi
    alpine_restore_repos; return 1
}

debian_get_codename() {
    if [ -f /etc/os-release ]; then
        codename=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2)
        [ -n "$codename" ] && echo "$codename" && return
    fi
    echo "bookworm"
}

debian_get_version_id() {
    if [ -f /etc/os-release ]; then
        vid=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        [ -n "$vid" ] && echo "$vid" && return
    fi
    cat /etc/debian_version 2>/dev/null | cut -d. -f1 || echo "12"
}

debian_backup_sources() {
    [ -d /etc/apt/sources.list.d ] && [ ! -d /etc/apt/sources.list.d.bak ] && \
        cp -r /etc/apt/sources.list.d /etc/apt/sources.list.d.bak 2>/dev/null
    [ -f /etc/apt/sources.list ] && [ ! -f /etc/apt/sources.list.bak ] && \
        cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null
}

debian_restore_sources() {
    [ -d /etc/apt/sources.list.d.bak ] && \
        rm -rf /etc/apt/sources.list.d 2>/dev/null && \
        mv /etc/apt/sources.list.d.bak /etc/apt/sources.list.d 2>/dev/null
    [ -f /etc/apt/sources.list.bak ] && \
        mv /etc/apt/sources.list.bak /etc/apt/sources.list 2>/dev/null
}

debian_set_mirror() {
    mirror="$1"
    CODENAME=$(debian_get_codename)
    VERSION_ID=$(debian_get_version_id)
    [ "$VERSION_ID" -ge 12 ] 2>/dev/null && NONFREE="non-free non-free-firmware" || NONFREE="non-free"
    debian_backup_sources
    # 安全清理: 检查目录和文件存在
    if [ -d /etc/apt/sources.list.d ]; then
        for f in /etc/apt/sources.list.d/*.list; do
            [ -f "$f" ] && rm -f "$f" 2>/dev/null
        done
    fi
    case "$mirror" in
        default)
            cat > /etc/apt/sources.list <<EOF
deb https://deb.debian.org/debian ${CODENAME} main contrib ${NONFREE}
deb https://deb.debian.org/debian ${CODENAME}-updates main contrib ${NONFREE}
deb https://security.debian.org/debian-security ${CODENAME}-security main contrib ${NONFREE}
EOF
            ;;
        ustc)
            cat > /etc/apt/sources.list <<EOF
deb https://mirrors.ustc.edu.cn/debian ${CODENAME} main contrib ${NONFREE}
deb https://mirrors.ustc.edu.cn/debian ${CODENAME}-updates main contrib ${NONFREE}
deb https://mirrors.ustc.edu.cn/debian-security ${CODENAME}-security main contrib ${NONFREE}
EOF
            ;;
        *) return 1 ;;
    esac
    return 0
}

debian_install_tools() {
    printf '    %b\n' "${DIM}Debian: 更新源并安装工具...${NC}"
    mkdir -p /etc/apt/sources.list.d 2>/dev/null
    if apt-get update -qq 2>/dev/null && apt-get install -y dnsutils curl iputils-ping netcat-openbsd 2>/dev/null; then
        return 0
    fi
    printf '    %b\n' "${ICON_WARN} 默认源失败，尝试切换镜像源..."
    if debian_set_mirror "ustc" && apt-get update -qq 2>/dev/null && apt-get install -y dnsutils curl iputils-ping netcat-openbsd 2>/dev/null; then
        printf '    %b\n' "${ICON_OK} ustc源安装成功"; return 0
    fi
    debian_restore_sources; return 1
}

install_dependencies() {
    OS_TYPE=$(detect_os)
    missing_tools=""
    for tool in nslookup curl ping; do
        command -v "$tool" >/dev/null 2>&1 || missing_tools="$missing_tools $tool"
    done
    optional_missing=""
    for tool in nc dig host; do
        command -v "$tool" >/dev/null 2>&1 || optional_missing="$optional_missing $tool"
    done
    
    [ -z "$missing_tools" ] && [ -z "$optional_missing" ] && { check_pass "所有依赖已就绪"; return 0; }
    
    printf '\n'
    printf '  %b\n' "${BOLD}依赖检查和安装${NC}"
    [ -n "$missing_tools" ] && check_warn "缺少必需工具:${missing_tools}"
    [ -n "$optional_missing" ] && check_info "缺少可选工具" "${optional_missing}"
    
    if ! is_root; then
        printf '\n'
        printf '    %b\n' "${ICON_WARN} 非root用户，无法安装依赖"
        case "$OS_TYPE" in
            alpine) printf '    %b\n' "${ICON_INFO} 手动安装: ${CYAN}sudo apk add bind-tools curl iputils netcat-openbsd${NC}" ;;
            debian) printf '    %b\n' "${ICON_INFO} 手动安装: ${CYAN}sudo apt-get install -y dnsutils curl iputils-ping netcat-openbsd${NC}" ;;
        esac
        printf '\n'; return 1
    fi
    
    printf '\n'
    printf '  %b\n' "${BOLD}包管理器安装 (支持自动换源)${NC}"
    case "$OS_TYPE" in
        alpine)
            alpine_install_tools && printf '    %b\n' "${ICON_OK} 依赖安装完成" || { printf '    %b\n' "${ICON_FAIL} 所有源安装失败"; return 1; }
            ;;
        debian)
            debian_install_tools && printf '    %b\n' "${ICON_OK} 依赖安装完成" || { printf '    %b\n' "${ICON_FAIL} 所有源安装失败"; return 1; }
            ;;
        *) printf '    %b\n' "${ICON_FAIL} 未知系统"; return 1 ;;
    esac
    
    still_missing=""
    for tool in nslookup curl ping; do
        command -v "$tool" >/dev/null 2>&1 || still_missing="$still_missing $tool"
    done
    [ -z "$still_missing" ] && check_pass "所有必需依赖已就绪" || check_warn "仍有工具缺失:${still_missing}"
    printf '\n'; return 0
}

#==================================================
# DNS解析
#==================================================
dns_resolve() {
    domain="$1"; type="${2:-A}"
    
    if command -v nslookup >/dev/null 2>&1; then
        result=$(run_with_timeout 5 nslookup -timeout=3 -type="$type" "$domain" 2>/dev/null)
        ip=$(printf '%s' "$result" | awk -v t="$type" '
            /^Name:/ { in_section=1; next }
            in_section && /^Address:/ { ip=$NF; if(ip!~/#/){print ip;exit} }
            in_section && $0~/has .* address/ { print $NF; exit }
        ')
        [ -n "$ip" ] && echo "$ip" && return 0
    fi
    
    if command -v host >/dev/null 2>&1; then
        result=$(run_with_timeout 5 host -t "$type" "$domain" 2>/dev/null)
        ip=$(printf '%s' "$result" | grep -E "has address|has IPv6 address" | awk '{print $NF}' | head -1)
        [ -n "$ip" ] && echo "$ip" && return 0
    fi
    
    if command -v dig >/dev/null 2>&1; then
        result=$(run_with_timeout 5 dig +short +time=3 -t "$type" "$domain" 2>/dev/null | head -1)
        [ -n "$result" ] && echo "$result" && return 0
    fi
    
    if [ "$type" = "A" ] && command -v getent >/dev/null 2>&1; then
        getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1
        return
    fi
    
    echo ""
}

dns_resolve_via() {
    domain="$1"; type="${2:-A}"; dns="$3"
    [ -z "$dns" ] && { echo ""; return 1; }
    
    if command -v nslookup >/dev/null 2>&1; then
        result=$(run_with_timeout 5 nslookup -timeout=3 -type="$type" "$domain" "$dns" 2>/dev/null)
        ip=$(printf '%s' "$result" | awk -v t="$type" '
            /^Name:/ { in_section=1; next }
            in_section && /^Address:/ { ip=$NF; if(ip!~/#/){print ip;exit} }
            in_section && $0~/has .* address/ { print $NF; exit }
        ')
        [ -n "$ip" ] && echo "$ip" && return 0
    fi
    
    if command -v dig >/dev/null 2>&1; then
        result=$(run_with_timeout 5 dig +short +time=3 -t "$type" "$domain" @"$dns" 2>/dev/null | head -1)
        [ -n "$result" ] && echo "$result" && return 0
    fi
    
    echo ""
}

# 修复: 消除count_loop子shell，直接使用while
dns_resolve_with_retry() {
    domain="$1"; type="${2:-A}"; dns="${3:-}"; max_retries=2
    
    i=1
    while [ "$i" -le "$max_retries" ]; do
        if [ -n "$dns" ]; then
            result=$(dns_resolve_via "$domain" "$type" "$dns")
        else
            result=$(dns_resolve "$domain" "$type")
        fi
        if [ -n "$result" ]; then
            [ "$i" -gt 1 ] && RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "$result"; return 0
        fi
        [ "$i" -lt "$max_retries" ] && sleep 1
        i=$((i + 1))
    done
    echo ""
}

#==================================================
# IP提取
#==================================================
extract_ipv4() {
    result="$1"
    ns_filter="127\.0\.0\.1"
    if [ -f /etc/resolv.conf ]; then
        for ns in $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v ':'); do
            ns_filter="${ns_filter}|$(echo "$ns" | sed 's/\./\\./g')"
        done
    fi
    printf '%s' "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE "^(${ns_filter})$" | head -1
}

extract_ipv6() {
    result="$1"
    printf '%s' "$result" | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        [ ${#ip} -lt 7 ] && continue
        case "$ip" in
            ::1|::|fe80:*|fc00:*|fd00:*|ff00:*) continue ;;
            *) echo "$ip"; return ;;
        esac
    done | head -1
}

#==================================================
# IPv6检测函数
#==================================================
has_ipv6_interface() {
    ip -6 addr show 2>/dev/null | grep -v '::1' | grep -q 'inet6' && return 0
    [ -f /proc/net/if_inet6 ] && grep -v '^00000000000000000000000000000001' /proc/net/if_inet6 2>/dev/null | head -1 | grep -q . && return 0
    return 1
}

has_ipv6_gateway() {
    ip -6 route show default 2>/dev/null | grep -q 'default' && return 0
    return 1
}

has_ipv6_internet_icmp() {
    for dns in $IPV6_DNS_SERVERS; do
        run_with_timeout 3 ping -6 -c 1 "$dns" >/dev/null 2>&1 && return 0
    done
    return 1
}

# 修复: curl busybox回退增加IPv6地址验证
has_ipv6_internet_http() {
    if command -v curl >/dev/null 2>&1; then
        for url in $IPV6_CHECK_SERVICES; do
            # 标准curl
            http_code=$(run_with_timeout 5 curl -6 -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
            if [ -n "$http_code" ] && [ "$http_code" = "200" ]; then
                return 0
            fi
            # busybox回退: 检查响应是否包含IPv6地址
            response=$(run_with_timeout 5 curl -6 -s "$url" 2>/dev/null)
            if printf '%s' "$response" | grep -qE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}'; then
                return 0
            fi
        done
    fi
    return 1
}

get_my_ipv6() {
    if command -v curl >/dev/null 2>&1; then
        for url in $IPV6_CHECK_SERVICES; do
            response=$(run_with_timeout 5 curl -6 -s "$url" 2>/dev/null)
            ipv6=$(printf '%s' "$response" | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | grep -v '^::$' | head -1)
            [ -n "$ipv6" ] && echo "$ipv6" && return 0
        done
    fi
    return 1
}

# 统一的AAAA记录检测
check_aaaa_records() {
    dns_server="$1"; label="$2"
    _ok=0; _total=0
    
    for domain in $IPV6_DOMAINS; do
        _total=$((_total + 1))
        result=$(dns_resolve_with_retry "$domain" "AAAA" "$dns_server")
        ip=$(extract_ipv6 "$result")
        
        if [ -n "$ip" ] && [ ${#ip} -gt 6 ]; then
            _ok=$((_ok + 1))
            if [ "$label" = "IPv4回退" ]; then
                check_warn "$domain → $ip (通过IPv4)"
            else
                check_pass "$domain → $ip"
            fi
        else
            check_warn "$domain 无AAAA记录"
        fi
    done
    
    IPV6_AAAA_OK="$_ok"
    IPV6_AAAA_TOTAL="$_total"
    
    printf '\n'
    if [ "$_ok" -eq "$_total" ]; then
        check_pass "IPv6 DNS解析: ${_ok}/${_total} 全部成功"
    elif [ "$_ok" -ge $((_total * 2 / 3)) ]; then
        check_pass "IPv6 DNS解析: ${_ok}/${_total} 基本可用"
    elif [ "$_ok" -gt 0 ]; then
        check_warn "IPv6 DNS解析: ${_ok}/${_total} 部分成功"
    else
        check_warn "IPv6 DNS解析: 全部失败"
    fi
}

#==================================================
# DoH/DoT (修复条件判断)
#==================================================
check_doh() {
    domain="$1"; url="$2"
    response=$(run_with_timeout 5 curl -s -H "accept: application/dns-json" \
        "${url}?name=${domain}&type=1" 2>/dev/null)
    
    # 明确的条件判断
    if [ -z "$response" ]; then
        return 1
    fi
    if ! printf '%s' "$response" | grep -qE '"Status":[[:space:]]*0'; then
        return 1
    fi
    
    flat=$(printf '%s' "$response" | tr -d '\n')
    ip=$(printf '%s' "$flat" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"$//')
    [ -n "$ip" ] && echo "$ip" || echo "ok"
    return 0
}

check_dot() {
    ip="$1"; port="${2:-853}"
    if command -v nc >/dev/null 2>&1; then
        run_with_timeout 3 nc -z -w 2 "$ip" "$port" 2>/dev/null && return 0
        run_with_timeout 3 sh -c "echo '' | nc -w 2 '$ip' '$port' >/dev/null 2>&1" && return 0
        run_with_timeout 3 sh -c "echo '' | nc '$ip' '$port' -w 2 >/dev/null 2>&1" && return 0
    fi
    return 1
}

parse_servers() {
    list="$1"
    saved_ifs="$IFS"; IFS=' '
    for item in $list; do [ -z "$item" ] && continue; echo "$item"; done
    IFS="$saved_ifs"
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
            printf '      %b\n' "${DIM}$line${NC}"
        done
        
        ns_count=$(safe_grep_count '^nameserver' /etc/resolv.conf)
        ipv4_ns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep -v ':' | wc -l | awk '{print $1}')
        ipv6_ns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep ':' | wc -l | awk '{print $1}')
        check_info "统计" "总计${ns_count}个 (IPv4:${ipv4_ns} IPv6:${ipv6_ns})"
        
        [ "$ns_count" -eq 0 ] && check_fail "未配置nameserver" "编辑 /etc/resolv.conf"
        
        if [ "$ipv6_ns" -eq 0 ] && [ "$ns_count" -gt 0 ]; then
            check_info "注意" "无IPv6 DNS服务器，AAAA记录将通过IPv4查询"
        fi
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
    
    printf '\n'
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
    if [ -f /etc/resolv.conf ]; then
        for ns in $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v ':'); do
            if ping -c 1 -W 2 "$ns" >/dev/null 2>&1; then
                check_pass "DNS $ns 可达"
            else
                check_fail "DNS $ns 不可达"
            fi
        done
    fi
    
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
        # 确保末尾换行
        [ -n "$parsed_list" ] && parsed_list="${parsed_list}
"
        while IFS='|' read -r name url; do
            [ -z "$name" ] && continue
            doh_total=$((doh_total + 1))
            result=$(check_doh "google.com" "$url" 2>/dev/null)
            if [ -n "$result" ]; then
                doh_ok=$((doh_ok + 1))
                [ "$result" != "ok" ] && check_pass "$name DoH → $result" || check_pass "$name DoH 可用"
            else
                check_fail "$name DoH 不可用" "检查443端口和TLS"
            fi
        done <<EOF
$parsed_list
EOF
        printf '\n'
        [ "$doh_total" -gt 0 ] && {
            if [ "$doh_ok" -eq "$doh_total" ]; then check_pass "DoH: 全部可用 (${doh_ok}/${doh_total})"
            elif [ "$doh_ok" -gt 0 ]; then check_warn "DoH: 部分可用 (${doh_ok}/${doh_total})"
            else check_fail "DoH: 全部不可用" "检查443端口和TLS"; fi
        }
    fi
    
    printf '\n'
    print_sub "DoT (DNS over TLS)"
    if ! command -v nc >/dev/null 2>&1; then
        check_skip "nc未安装，跳过DoT检测"
    else
        dot_ok=0; dot_total=0
        parsed_list=$(parse_servers "$DOT_SERVERS")
        [ -n "$parsed_list" ] && parsed_list="${parsed_list}
"
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
        printf '\n'
        [ "$dot_total" -gt 0 ] && {
            if [ "$dot_ok" -eq "$dot_total" ]; then check_pass "DoT: 全部可达 (${dot_ok}/${dot_total})"
            elif [ "$dot_ok" -gt 0 ]; then check_warn "DoT: 部分可达 (${dot_ok}/${dot_total})"
            else check_fail "DoT: 全部不可达" "检查853端口和TLS"; fi
        }
    fi
}

# ── IPv6检测 (3个子模块) ──

check_ipv6_interface_status() {
    print_sub "IPv6 接口状态"
    check_pass "IPv6 接口已启用"
    
    ipv6_addr=$(ip -6 addr show 2>/dev/null | grep 'inet6' | grep -v '::1' | awk '{print $2}' | head -1)
    [ -n "$ipv6_addr" ] && check_info "本地地址" "$ipv6_addr"
    
    if has_ipv6_gateway; then
        ipv6_gw=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
        check_info "网关" "$ipv6_gw"
        if run_with_timeout 3 ping -6 -c 1 "$ipv6_gw" >/dev/null 2>&1; then
            check_pass "网关可达"
        else
            check_fail "网关不可达"
        fi
    else
        check_info "网关" "无默认路由"
    fi
}

check_ipv6_aaaa_resolution() {
    print_sub "AAAA记录解析 (通过IPv6 DNS)"
    
    IPV6_NS=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep ':' | head -1)
    
    if [ -n "$IPV6_NS" ]; then
        check_info "使用IPv6 DNS" "$IPV6_NS"
        
        if run_with_timeout 3 ping -6 -c 1 "$IPV6_NS" >/dev/null 2>&1; then
            check_pass "IPv6 DNS可达"
            check_aaaa_records "$IPV6_NS" "IPv6"
        else
            check_fail "IPv6 DNS不可达" "回退到IPv4查询"
            check_aaaa_records "" "IPv4回退"
        fi
    else
        check_info "IPv6 DNS" "未配置，尝试公网IPv6 DNS"
        
        working_dns=""
        for dns in $IPV6_DNS_SERVERS; do
            if run_with_timeout 3 ping -6 -c 1 "$dns" >/dev/null 2>&1; then
                working_dns="$dns"
                check_pass "公网IPv6 DNS $dns 可达"
                break
            fi
        done
        
        if [ -n "$working_dns" ]; then
            check_aaaa_records "$working_dns" "IPv6"
        else
            check_fail "所有IPv6 DNS不可达" "回退到IPv4查询"
            check_aaaa_records "" "IPv4回退"
        fi
    fi
}

check_ipv6_e2e() {
    print_sub "IPv6 端到端可用性"
    
    # ICMP
    if has_ipv6_internet_icmp; then
        check_pass "IPv6公网可达 (ICMP)"
        IPV6_E2E_AVAILABLE=1
    else
        check_warn "IPv6公网ICMP不可达"
    fi
    
    # HTTP + 本机IPv6
    if command -v curl >/dev/null 2>&1; then
        if has_ipv6_internet_http; then
            check_pass "IPv6公网可达 (HTTP)"
            IPV6_E2E_AVAILABLE=1
            
            my_ipv6=$(get_my_ipv6)
            if [ -n "$my_ipv6" ]; then
                check_pass "本机IPv6地址: $my_ipv6"
            fi
        else
            check_fail "IPv6公网HTTP不可达" "VPS无IPv6出站能力"
            
            if has_ipv6_interface && ! has_ipv6_gateway; then
                check_info "原因" "无IPv6默认路由"
            elif has_ipv6_gateway && ! has_ipv6_internet_icmp; then
                check_info "原因" "上游网络无IPv6路由"
            fi
        fi
        
        # IPv6-only网站
        print_sub "IPv6-only 网站访问"
        if run_with_timeout 5 curl -6 -s https://ip6only.me >/dev/null 2>&1; then
            check_pass "ip6only.me 可访问"
            IPV6_E2E_AVAILABLE=1
        else
            check_warn "ip6only.me 不可访问" "VPS无法访问纯IPv6网站"
        fi
    else
        check_skip "curl未安装，跳过IPv6端到端检测"
    fi
    
    # 最终判断
    printf '\n'
    if [ "$IPV6_E2E_AVAILABLE" -eq 1 ]; then
        check_pass "IPv6 完全可用 ✅"
    elif [ "${IPV6_AAAA_OK:-0}" -gt 0 ]; then
        check_info "IPv6 状态" "DNS解析可用，但无出站能力 (仅本地IPv6)"
    else
        check_warn "IPv6 状态" "不可用"
    fi
}

check_ipv6_dns() {
    print_section "IPv6 DNS 检测"
    
    if ! has_ipv6_interface; then
        check_skip "IPv6接口未启用，跳过检测"
        return
    fi
    
    check_ipv6_interface_status
    check_ipv6_aaaa_resolution
    check_ipv6_e2e
}

print_report() {
    print_section "检测报告"
    
    printf '\n'
    printf '  %b\n' "${GREEN}通过: $PASS${NC}"
    printf '  %b\n' "${YELLOW}警告: $WARN${NC}"
    printf '  %b\n' "${RED}失败: $FAIL${NC}"
    printf '  %b\n' "${DIM}跳过: $SKIP${NC}"
    [ "$RETRY_COUNT" -gt 0 ] && printf '  %b\n' "${CYAN}重试成功: $RETRY_COUNT${NC}"
    printf '  %b\n' "${BOLD}总计: $TOTAL${NC}"
    printf '\n'
    
    if [ "$TOTAL" -gt 0 ]; then
        score=$(( (PASS * 100) / TOTAL ))
    else
        score=0
    fi
    
    if [ "$FAIL" -eq 0 ] && [ "$score" -ge 90 ]; then
        printf '  %b\n' "${GREEN}${BOLD}★★★★★ DNS服务正常 (${score}分)${NC}"
    elif [ "$FAIL" -eq 0 ] && [ "$score" -ge 70 ]; then
        printf '  %b\n' "${GREEN}${BOLD}★★★★☆ DNS基本可用 (${score}分)${NC}"
    elif [ "$FAIL" -le 2 ]; then
        printf '  %b\n' "${YELLOW}${BOLD}★★★☆☆ 存在部分问题 (${score}分)${NC}"
    elif [ "$FAIL" -le 5 ]; then
        printf '  %b\n' "${RED}${BOLD}★★☆☆☆ 需要修复 (${score}分)${NC}"
    else
        printf '  %b\n' "${RED}${BOLD}★☆☆☆☆ 服务异常 (${score}分)${NC}"
    fi
    
    printf '\n'
    printf '完成: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '\n'
}

#==================================================
# 主函数
#==================================================
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fix-source) printf 'fix_source 请使用 v5.5\n'; exit 0 ;;
            -h|--help)
                printf '用法: %s\n' "$0"
                printf '\n'
                printf 'v5.8 改进:\n'
                printf '  - 修复 check_doh 条件判断\n'
                printf '  - 修复 run_with_timeout PID回收\n'
                printf '  - 消除 count_loop 子shell\n'
                printf '  - 优化 curl busybox 回退验证\n'
                printf '  - 统一变量命名风格\n'
                printf '  - echo -e 替换为 printf\n'
                exit 0 ;;
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
