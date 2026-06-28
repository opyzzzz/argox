#!/bin/sh
#==================================================
# DNS 检测脚本 v5.1 - Alpine/Debian 精简版
# 功能: 检测当前系统DNS的IPv4/IPv6/DoH/DoT可用性
# 兼容: Alpine 3.x / Debian 10+
# 用法: wget -qO- https://.../dns-check.sh | sh
#==================================================

set +e

#==================================================
# 颜色 (Alpine/Debian兼容)
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

# 图标
ICON_OK="${GREEN}✓${NC}"; ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"; ICON_INFO="${CYAN}ℹ${NC}"; ICON_SKIP="${DIM}⊘${NC}"

# DoH/DoT 服务器列表
DOH_SERVERS="
    Cloudflare|https://cloudflare-dns.com/dns-query
    Google|https://dns.google/resolve
"

DOT_SERVERS="
    Cloudflare|1.1.1.1
    Google|8.8.8.8
"

#==================================================
# 工具函数
#==================================================
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  DNS 可用性检测 v5.1 (Alpine/Debian)${NC}"
    echo -e "${BOLD}${BLUE}  时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}── $1 ──${NC}"
}

print_sub() {
    echo -e "  ${CYAN}▸${NC} ${BOLD}$1${NC}"
}

check_pass() { echo -e "    ${ICON_OK} $1"; PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); }
check_fail() { echo -e "    ${ICON_FAIL} $1"; [ -n "$2" ] && echo -e "      ${DIM}修复: $2${NC}"; FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); }
check_warn() { echo -e "    ${ICON_WARN} $1"; [ -n "$2" ] && echo -e "      ${DIM}建议: $2${NC}"; WARN=$((WARN + 1)); TOTAL=$((TOTAL + 1)); }
check_info() { echo -e "    ${ICON_INFO} $1: ${CYAN}$2${NC}"; }
check_skip() { echo -e "    ${ICON_SKIP} $1"; SKIP=$((SKIP + 1)); TOTAL=$((TOTAL + 1)); }

#==================================================
# 依赖检测和安装
#==================================================
check_deps() {
    MISSING=""
    for tool in nslookup curl ping; do
        command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
    done
    
    # nc 是可选的 (用于DoT)
    if ! command -v nc >/dev/null 2>&1; then
        MISSING="$MISSING nc(可选)"
    fi
    
    [ -z "$MISSING" ] && return 0
    
    echo ""
    echo -e "  ${ICON_WARN} 缺少工具:${MISSING}"
    
    if [ -f /etc/alpine-release ]; then
        echo -e "  ${ICON_INFO} 安装: ${CYAN}apk add bind-tools curl iputils netcat-openbsd${NC}"
    elif [ -f /etc/debian_version ]; then
        echo -e "  ${ICON_INFO} 安装: ${CYAN}apt-get install -y dnsutils curl iputils-ping netcat-openbsd${NC}"
    fi
    
    # 自动安装 (如有root权限)
    if [ "$(id -u 2>/dev/null)" = "0" ]; then
        echo -e "  ${ICON_INFO} 正在自动安装..."
        if [ -f /etc/alpine-release ]; then
            apk add bind-tools curl iputils netcat-openbsd 2>/dev/null && echo -e "  ${ICON_OK} 安装完成" || echo -e "  ${ICON_FAIL} 安装失败"
        elif [ -f /etc/debian_version ]; then
            apt-get update -qq 2>/dev/null
            apt-get install -y dnsutils curl iputils-ping netcat-openbsd 2>/dev/null && echo -e "  ${ICON_OK} 安装完成" || echo -e "  ${ICON_FAIL} 安装失败"
        fi
    fi
    echo ""
}

#==================================================
# DNS解析 (兼容nslookup/getent)
#==================================================
dns_resolve() {
    domain="$1"; type="${2:-A}"
    
    # 方法1: nslookup
    if command -v nslookup >/dev/null 2>&1; then
        result=$(nslookup -timeout=3 -type="$type" "$domain" 2>/dev/null)
        echo "$result" | awk '
            /^Name:/ { in_section=1; next }
            in_section && /^Address:/ {
                ip = $NF
                if (ip !~ /#/) { print ip; exit }
            }
        '
        return
    fi
    
    # 方法2: getent (仅A记录)
    if [ "$type" = "A" ] && command -v getent >/dev/null 2>&1; then
        getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1
        return
    fi
    
    echo ""
}

#==================================================
# IPv4提取 (过滤DNS服务器IP)
#==================================================
extract_ipv4() {
    result="$1"
    # 获取所有nameserver用于过滤
    ns_filter="127\.0\.0\.1"
    for ns in $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}'); do
        case "$ns" in
            *:*) continue ;;
            *) ns_filter="${ns_filter}|$(echo "$ns" | sed 's/\./\\./g')" ;;
        esac
    done
    echo "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE "^(${ns_filter})$" | head -1
}

#==================================================
# IPv6提取 (过滤特殊地址和短字符串)
#==================================================
extract_ipv6() {
    result="$1"
    echo "$result" | grep -Eo '([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}' | while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        [ ${#ip} -lt 7 ] && continue
        case "$ip" in
            ::1|::|fe80:*|fc00:*|fd00:*|ff00:*) continue ;;
            *) echo "$ip"; return ;;
        esac
    done | head -1
}

#==================================================
# IPv6可用性检测
#==================================================
has_ipv6() {
    # 检查接口
    ip -6 addr show 2>/dev/null | grep -v '::1' | grep -q 'inet6' && return 0
    # 检查/proc
    [ -f /proc/net/if_inet6 ] && grep -v '^00000000000000000000000000000001' /proc/net/if_inet6 2>/dev/null | head -1 | grep -q . && return 0
    # 检查路由
    ip -6 route show 2>/dev/null | grep -q 'default' && return 0
    # 检查resolv.conf
    grep -q '^nameserver.*:' /etc/resolv.conf 2>/dev/null && return 0
    return 1
}

#==================================================
# DoH 检测函数
#==================================================
check_doh() {
    domain="$1"
    url="$2"
    type_num=1
    
    response=$(curl -s --max-time 5 -H "accept: application/dns-json" \
        "${url}?name=${domain}&type=${type_num}" 2>/dev/null)
    
    if [ -n "$response" ] && echo "$response" | grep -qE '"Status":[[:space:]]*0'; then
        # 提取IP
        flat=$(echo "$response" | tr -d '\n')
        ip=$(echo "$flat" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"$//')
        [ -n "$ip" ] && echo "$ip" || echo "ok"
        return 0
    fi
    return 1
}

#==================================================
# DoT 检测函数
#==================================================
check_dot() {
    ip="$1"
    port="${2:-853}"
    
    if command -v nc >/dev/null 2>&1; then
        # 使用 nc 检测 TCP 853 端口
        if timeout 3 nc -z -w 2 "$ip" "$port" 2>/dev/null; then
            return 0
        fi
        # Alpine busybox nc 可能语法不同
        if timeout 3 sh -c "echo | nc -w 2 $ip $port >/dev/null 2>&1"; then
            return 0
        fi
    fi
    return 1
}

#==================================================
# 检测区域
#==================================================

# ── 第1部分: 系统环境 ──
check_system() {
    print_section "系统环境"
    
    # OS
    if [ -f /etc/alpine-release ]; then
        check_info "系统" "Alpine $(cat /etc/alpine-release)"
    elif [ -f /etc/debian_version ]; then
        check_info "系统" "Debian $(cat /etc/debian_version) ($(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2))"
    fi
    check_info "内核" "$(uname -r)"
    check_info "架构" "$(uname -m)"
    
    # 虚拟化
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        check_info "环境" "LXC 容器"
    elif grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        check_info "环境" "容器"
    else
        check_info "环境" "物理机/KVM"
    fi
    
    # 依赖
    check_deps
}

# ── 第2部分: DNS配置 ──
check_dns_config() {
    print_section "DNS 配置"
    
    print_sub "resolv.conf"
    if [ -f /etc/resolv.conf ]; then
        check_pass "配置文件存在"
        
        # 显示nameserver
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | while IFS= read -r line; do
            echo -e "      ${DIM}$line${NC}"
        done
        
        # 统计
        ns_count=$(grep -c '^nameserver' /etc/resolv.conf 2>/dev/null || echo 0)
        ipv4_ns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep -v ':' | wc -l)
        ipv6_ns=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep ':' | wc -l)
        check_info "统计" "总计${ns_count}个 (IPv4:${ipv4_ns} IPv6:${ipv6_ns})"
        
        [ "$ns_count" -eq 0 ] && check_fail "未配置nameserver" "编辑 /etc/resolv.conf"
    else
        check_fail "resolv.conf 不存在"
    fi
    
    # nsswitch
    if [ -f /etc/nsswitch.conf ]; then
        if grep '^hosts:' /etc/nsswitch.conf 2>/dev/null | grep -q 'dns'; then
            check_pass "nsswitch.conf: DNS已启用"
        else
            check_warn "nsswitch.conf: DNS未在hosts行"
        fi
    fi
}

# ── 第3部分: IPv4 DNS检测 ──
check_ipv4_dns() {
    print_section "IPv4 DNS 检测"
    
    # 测试域名 (覆盖不同区域和类型)
    IPV4_DOMAINS="
        google.com
        cloudflare.com
        github.com
        microsoft.com
        amazon.com
        bbc.co.uk
        ovh.com
        cdn.jsdelivr.net
    "
    
    print_sub "A记录解析"
    ipv4_ok=0; ipv4_total=0
    
    for domain in $IPV4_DOMAINS; do
        [ -z "$domain" ] && continue
        ipv4_total=$((ipv4_total + 1))
        
        result=$(dns_resolve "$domain" "A")
        ip=$(extract_ipv4 "$result")
        
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            ipv4_ok=$((ipv4_ok + 1))
            check_pass "$domain → $ip"
        else
            check_fail "$domain 解析失败"
        fi
    done
    
    # 总结
    echo ""
    if [ "$ipv4_ok" -eq "$ipv4_total" ]; then
        check_pass "IPv4 DNS: ${ipv4_ok}/${ipv4_total} 全部成功"
    elif [ "$ipv4_ok" -ge $((ipv4_total / 2)) ]; then
        check_warn "IPv4 DNS: ${ipv4_ok}/${ipv4_total} 部分成功"
    else
        check_fail "IPv4 DNS: ${ipv4_ok}/${ipv4_total} 大部分失败" "检查网络和DNS配置"
    fi
    
    # 连通性: ping DNS服务器
    print_sub "DNS服务器连通性"
    for ns in $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v ':'); do
        if ping -c 1 -W 2 "$ns" >/dev/null 2>&1; then
            check_pass "DNS $ns 可达"
        else
            check_fail "DNS $ns 不可达"
        fi
    done
    
    # 连通性: ping 公共DNS
    for public_dns in 8.8.8.8 1.1.1.1; do
        if ping -c 1 -W 2 "$public_dns" >/dev/null 2>&1; then
            check_pass "公网DNS $public_dns 可达"
        else
            check_warn "公网DNS $public_dns 不可达"
        fi
    done
}

# ── 第4部分: DoH/DoT 检测 (新增) ──
check_encrypted_dns() {
    print_section "加密DNS检测 (DoH/DoT)"
    
    # ── DoH 检测 ──
    print_sub "DoH (DNS over HTTPS)"
    
    if ! command -v curl >/dev/null 2>&1; then
        check_skip "curl未安装，跳过DoH检测"
    else
        doh_ok=0; doh_total=0
        
        echo "$DOH_SERVERS" | while IFS='|' read -r name url; do
            [ -z "$name" ] && continue
            doh_total=$((doh_total + 1))
            
            result=$(check_doh "google.com" "$url" 2>/dev/null)
            if [ "$result" = "ok" ] || [ -n "$result" ]; then
                doh_ok=$((doh_ok + 1))
                if [ "$result" != "ok" ]; then
                    check_pass "$name DoH → $result"
                else
                    check_pass "$name DoH 可用"
                fi
            else
                check_fail "$name DoH 不可用" "检查网络或防火墙规则"
            fi
        done
        
        # 注意: while在子shell中，计数不会传回。改用for
        # 重新实现DoH检测（避免子shell问题）
        doh_ok=0; doh_total=0
        saved_ifs="$IFS"; IFS='
'
        for entry in $DOH_SERVERS; do
            [ -z "$entry" ] && continue
            name="${entry%%|*}"; url="${entry#*|}"
            doh_total=$((doh_total + 1))
            
            result=$(check_doh "google.com" "$url" 2>/dev/null)
            if [ "$result" = "ok" ] || [ -n "$result" ]; then
                doh_ok=$((doh_ok + 1))
                if [ "$result" != "ok" ]; then
                    check_pass "$name DoH → $result"
                else
                    check_pass "$name DoH 可用"
                fi
            else
                check_fail "$name DoH 不可用" "检查网络或防火墙规则"
            fi
        done
        IFS="$saved_ifs"
        
        echo ""
        if [ "$doh_total" -gt 0 ]; then
            if [ "$doh_ok" -eq "$doh_total" ]; then
                check_pass "DoH: 全部可用"
            elif [ "$doh_ok" -gt 0 ]; then
                check_warn "DoH: 部分可用 (${doh_ok}/${doh_total})"
            else
                check_fail "DoH: 全部不可用" "检查443端口和TLS"
            fi
        fi
    fi
    
    # ── DoT 检测 ──
    echo ""
    print_sub "DoT (DNS over TLS)"
    
    if ! command -v nc >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        check_skip "nc/timeout未安装，跳过DoT检测"
    else
        dot_ok=0; dot_total=0
        saved_ifs="$IFS"; IFS='
'
        for entry in $DOT_SERVERS; do
            [ -z "$entry" ] && continue
            name="${entry%%|*}"; ip="${entry#*|}"
            dot_total=$((dot_total + 1))
            
            if check_dot "$ip" 853; then
                dot_ok=$((dot_ok + 1))
                check_pass "$name DoT ($ip:853) 可达"
            else
                check_fail "$name DoT ($ip:853) 不可达" "检查853端口和防火墙"
            fi
        done
        IFS="$saved_ifs"
        
        echo ""
        if [ "$dot_total" -gt 0 ]; then
            if [ "$dot_ok" -eq "$dot_total" ]; then
                check_pass "DoT: 全部可达"
            elif [ "$dot_ok" -gt 0 ]; then
                check_warn "DoT: 部分可达 (${dot_ok}/${dot_total})"
            else
                check_fail "DoT: 全部不可达" "检查853端口和TLS"
            fi
        fi
    fi
}

# ── 第5部分: IPv6 DNS检测 ──
check_ipv6_dns() {
    print_section "IPv6 DNS 检测"
    
    if ! has_ipv6; then
        check_skip "IPv6未启用，跳过检测"
        return
    fi
    
    # 接口状态
    print_sub "IPv6 接口"
    check_pass "IPv6 已启用"
    
    ipv6_addr=$(ip -6 addr show 2>/dev/null | grep 'inet6' | grep -v '::1' | awk '{print $2}' | head -1)
    [ -n "$ipv6_addr" ] && check_info "地址" "$ipv6_addr"
    
    # 网关
    ipv6_gw=$(ip -6 route show default 2>/dev/null | awk '{print $3}' | head -1)
    if [ -n "$ipv6_gw" ]; then
        check_info "网关" "$ipv6_gw"
        if ping -6 -c 1 -W 2 "$ipv6_gw" >/dev/null 2>&1; then
            check_pass "网关可达"
        else
            check_fail "网关不可达"
        fi
    fi
    
    # AAAA记录解析 (多地址)
    IPV6_DOMAINS="
        google.com
        cloudflare.com
        he.net
        ipv6.google.com
        facebook.com
        ip6only.me
    "
    
    print_sub "AAAA记录解析"
    ipv6_ok=0; ipv6_total=0
    
    for domain in $IPV6_DOMAINS; do
        [ -z "$domain" ] && continue
        ipv6_total=$((ipv6_total + 1))
        
        result=$(dns_resolve "$domain" "AAAA")
        ip=$(extract_ipv6 "$result")
        
        if [ -n "$ip" ] && [ ${#ip} -gt 6 ]; then
            ipv6_ok=$((ipv6_ok + 1))
            check_pass "$domain → $ip"
        else
            check_warn "$domain 无AAAA记录"
        fi
    done
    
    # 总结
    echo ""
    if [ "$ipv6_ok" -ge $((ipv6_total * 2 / 3)) ]; then
        check_pass "IPv6 DNS: ${ipv6_ok}/${ipv6_total} 成功"
    elif [ "$ipv6_ok" -gt 0 ]; then
        check_warn "IPv6 DNS: ${ipv6_ok}/${ipv6_total} 部分成功" "可能IPv6路由不完整"
    else
        check_warn "IPv6 DNS: 全部失败" "IPv6 DNS解析不可用，检查IPv6网络"
    fi
    
    # IPv6 DNS服务器连通性
    print_sub "IPv6 DNS服务器连通性"
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
    
    # 公网IPv6 DNS
    for public_dns6 in 2001:4860:4860::8888 2606:4700:4700::1111; do
        if ping -6 -c 1 -W 2 "$public_dns6" >/dev/null 2>&1; then
            check_pass "公网DNS $public_dns6 可达"
        else
            check_warn "公网DNS $public_dns6 不可达"
        fi
    done
    
    # IPv6 HTTP测试
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
}

# ── 第6部分: 最终报告 ──
print_report() {
    print_section "检测报告"
    
    echo ""
    echo -e "  ${GREEN}通过: $PASS${NC}"
    echo -e "  ${YELLOW}警告: $WARN${NC}"
    echo -e "  ${RED}失败: $FAIL${NC}"
    echo -e "  ${DIM}跳过: $SKIP${NC}"
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
