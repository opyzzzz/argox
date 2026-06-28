#!/bin/sh
#==================================================
# SmartDNS / 系统 DNS 可用性检测脚本 v3.1
# 审计修复版 - 2026-06-28
#==================================================

set +e

# 颜色支持检测
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; NC=''
fi

PASS=0; FAIL=0; WARN=0; TOTAL=0

ICON_OK="${GREEN}✓${NC}"
ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"
ICON_INFO="${CYAN}ℹ${NC}"

CHECK_MODE=""
DNS_TARGET=""
QUIET=0

# 命令行参数处理
while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1 ;;
        -h|--help) 
            echo "用法: $0 [-q|--quiet] [-h|--help]"
            echo "  -q, --quiet  减少输出"
            echo "  -h, --help   显示帮助"
            exit 0 
            ;;
    esac
    shift
done

print_header() {
    [ "$QUIET" -eq 1 ] && return
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║  DNS 可用性检测脚本 v3.1 (审计修复版)                   ║${NC}"
    echo -e "${BOLD}${MAGENTA}║  检测时间: $(date '+%Y-%m-%d %H:%M:%S')                        ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    [ "$QUIET" -eq 1 ] && return
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_sub() {
    [ "$QUIET" -eq 1 ] && return
    echo ""
    echo -e "${BOLD}${CYAN}  ▸ $1${NC}"
}

check_pass() {
    echo -e "  ${ICON_OK} $1"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
}

check_fail() {
    echo -e "  ${ICON_FAIL} $1"
    [ -n "$2" ] && echo -e "    ${ICON_INFO} 解决: $2"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
}

check_warn() {
    echo -e "  ${ICON_WARN} $1"
    [ -n "$2" ] && echo -e "    ${ICON_INFO} 建议: $2"
    WARN=$((WARN + 1))
    TOTAL=$((TOTAL + 1))
}

check_info() {
    echo -e "  ${ICON_INFO} $1: ${CYAN}$2${NC}"
}

# 安全整数转换（增强版）
safe_int() {
    case "$1" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$1" ;;
    esac
}

# 统一的 DNS 解析函数（修复版）
resolve_a() {
    domain="$1"
    type="${2:-A}"
    dns="${3:-}"

    if command -v nslookup >/dev/null 2>&1; then
        if [ -n "$dns" ]; then
            nslookup -timeout=3 -type="$type" "$domain" "$dns" 2>/dev/null || true
        else
            nslookup -timeout=3 -type="$type" "$domain" 2>/dev/null || true
        fi
    elif command -v dig >/dev/null 2>&1; then
        if [ -n "$dns" ]; then
            dig +time=3 +short -t "$type" "$domain" @"$dns" 2>/dev/null || true
        else
            dig +time=3 +short -t "$type" "$domain" 2>/dev/null || true
        fi
    elif command -v getent >/dev/null 2>&1; then
        getent hosts "$domain" 2>/dev/null || true
    else
        # 最后的回退：直接读取 /etc/hosts
        grep -E "^[0-9].*[[:space:]]${domain}(\$|[[:space:]])" /etc/hosts 2>/dev/null || true
    fi
}

# 提取 IPv4 地址
extract_ipv4() {
    echo "$1" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1
}

# 提取 IPv6 地址（改进正则）
extract_ipv6() {
    echo "$1" | grep -Eo '(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|::1)' | head -1
}

# 检测运行模式
detect_mode() {
    SMARTDNS_BIN=""
    for path in /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns; do
        if [ -x "$path" ]; then
            SMARTDNS_BIN="$path"
            break
        fi
    done

    if [ -n "$SMARTDNS_BIN" ] && pgrep smartdns >/dev/null 2>&1; then
        CHECK_MODE="smartdns"
        DNS_TARGET="127.0.0.1"
        return 0
    else
        CHECK_MODE="system"
        DNS_TARGET=""
        return 1
    fi
}

# 安全的 grep 计数（修复 grep -c 返回值问题）
grep_count() {
    pattern="$1"
    file="$2"
    if [ -f "$file" ]; then
        count=$(grep -c "$pattern" "$file" 2>/dev/null) || count=0
        echo "${count:-0}"
    else
        echo "0"
    fi
}

# 安全的 while 循环读取文件
read_config_lines() {
    pattern="$1"
    file="$2"
    if [ -f "$file" ]; then
        grep "$pattern" "$file" 2>/dev/null | head -6
    fi
}

#==================================================
# 第1部分：系统环境
#==================================================
print_header
print_section "第1部分: 系统环境"

print_sub "操作系统"
if [ -f /etc/alpine-release ]; then
    OS="Alpine $(cat /etc/alpine-release)"
elif [ -f /etc/os-release ]; then
    OS=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'"' -f2)
else
    OS="Unknown"
fi
check_info "发行版" "$OS"
check_info "内核" "$(uname -r)"
check_info "架构" "$(uname -m)"

print_sub "虚拟化环境"
if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    check_warn "LXC 容器环境"
elif grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    check_warn "容器环境 (Docker/Podman)"
else
    check_pass "物理机/KVM 环境"
fi

print_sub "Init 系统"
if [ -f /run/systemd/system ]; then
    INIT="systemd"
    check_pass "Init: systemd"
elif [ -f /sbin/openrc ]; then
    INIT="openrc"
    check_pass "Init: OpenRC"
else
    INIT="unknown"
    check_warn "未知 Init 系统"
fi

#==================================================
# 第2部分：检测模式与 DNS 配置
#==================================================
detect_mode

print_section "第2部分: DNS 服务状态"

if [ "$CHECK_MODE" = "smartdns" ]; then
    check_pass "检测到 SmartDNS 运行中"
    print_sub "SmartDNS 版本"
    VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
    check_info "版本" "$VER"

    print_sub "配置文件"
    CONFIG_FILE="/etc/smartdns/smartdns.conf"
    if [ -f "$CONFIG_FILE" ]; then
        check_pass "配置文件存在"
        
        # 修复：正确的 grep 计数方式
        UDP_COUNT=$(safe_int "$(grep_count "^server " "$CONFIG_FILE")")
        DOH_COUNT=$(safe_int "$(grep_count "^server-https" "$CONFIG_FILE")")
        DOT_COUNT=$(safe_int "$(grep_count "^server-tls" "$CONFIG_FILE")")
        TOTAL_UPSTREAM=$((UDP_COUNT + DOH_COUNT + DOT_COUNT))
        
        if [ "$TOTAL_UPSTREAM" -gt 0 ] 2>/dev/null; then
            check_pass "上游 DNS: $TOTAL_UPSTREAM 个"
            check_info "上游统计" "UDP:$UDP_COUNT DoH:$DOH_COUNT DoT:$DOT_COUNT"
        else
            check_fail "缺少上游 DNS 配置"
        fi
        
        if [ "$QUIET" -eq 0 ]; then
            echo ""
            echo -e "  ${BOLD}配置摘要:${NC}"
            while IFS= read -r line; do
                echo -e "    ${CYAN}$line${NC}"
            done <<EOF
$(grep -E "^bind|^server |^server-https|^server-tls" "$CONFIG_FILE" 2>/dev/null)
EOF
        fi
    else
        check_fail "配置文件不存在"
    fi

    print_sub "服务状态"
    case "$INIT" in
        systemd)
            if systemctl is-active smartdns >/dev/null 2>&1; then
                check_pass "systemd 服务: active"
            else
                check_fail "systemd 服务: inactive"
            fi
            if systemctl is-enabled smartdns >/dev/null 2>&1; then
                check_pass "开机自启: 已启用"
            else
                check_warn "开机自启: 未启用"
            fi
            ;;
        openrc)
            if rc-service smartdns status 2>&1 | grep -q "started"; then
                check_pass "OpenRC 服务: started"
            else
                check_warn "OpenRC 服务: 未启动"
            fi
            ;;
    esac
else
    check_warn "未检测到 SmartDNS，切换到系统 DNS 检测"
    
    print_sub "系统 DNS 配置"
    if [ -f /etc/resolv.conf ]; then
        check_pass "/etc/resolv.conf 存在"
        if [ -L /etc/resolv.conf ]; then
            check_warn "resolv.conf 是符号链接"
        fi
        
        if [ "$QUIET" -eq 0 ]; then
            echo ""
            echo -e "  ${BOLD}当前 DNS 服务器:${NC}"
            while IFS= read -r line; do
                echo -e "    ${CYAN}$line${NC}"
            done < <(grep '^nameserver' /etc/resolv.conf 2>/dev/null)
        fi
        
        NS_COUNT=$(grep_count '^nameserver' /etc/resolv.conf)
        if [ "$(safe_int "$NS_COUNT")" -eq 0 ]; then
            check_fail "未配置任何 nameserver"
        fi
    else
        check_fail "/etc/resolv.conf 不存在"
    fi
fi

#==================================================
# 第3部分: DNS 解析测试
#==================================================
print_section "第3部分: DNS 解析测试"

print_sub "IPv4 解析"
IPV4_DOMAINS="google.com github.com cloudflare.com baidu.com"
for domain in $IPV4_DOMAINS; do
    RESULT=$(resolve_a "$domain" "A" "$DNS_TARGET")
    IP=$(extract_ipv4 "$RESULT")
    if [ -n "$IP" ]; then
        check_pass "$domain → $IP"
    else
        if [ "$CHECK_MODE" = "smartdns" ]; then
            check_fail "$domain 解析失败" "检查 SmartDNS 上游配置"
        else
            check_fail "$domain 解析失败" "检查 /etc/resolv.conf 及网络连通性"
        fi
    fi
done

print_sub "IPv6 解析"
IPV6_DOMAINS="ipv6.google.com cloudflare.com"
for domain in $IPV6_DOMAINS; do
    RESULT=$(resolve_a "$domain" "AAAA" "$DNS_TARGET")
    IP=$(extract_ipv6 "$RESULT")
    if [ -n "$IP" ]; then
        check_pass "$domain → $IP"
    else
        check_warn "$domain AAAA 解析失败" "可能无 IPv6 网络或上游不支持"
    fi
done

#==================================================
# 第4部分: 上游连通性（仅 SmartDNS）
#==================================================
if [ "$CHECK_MODE" = "smartdns" ]; then
    print_section "第4部分: 上游 DNS 连通性"

    print_sub "UDP 上游"
    # 修复：避免管道到 while 的变量问题
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IP=$(echo "$line" | awk '{print $2}' | cut -d: -f1)
        if resolve_a google.com A "$IP" >/dev/null 2>&1; then
            echo -e "  ${ICON_OK} $IP"
        else
            echo -e "  ${ICON_FAIL} $IP 不可达"
        fi
    done <<EOF
$(grep "^server " "$CONFIG_FILE" 2>/dev/null | head -6)
EOF

    print_sub "DoH 上游"
    if grep -q "^server-https" "$CONFIG_FILE" 2>/dev/null; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            URL=$(echo "$line" | awk '{print $2}')
            NAME=$(echo "$URL" | sed 's|https://||;s|/dns-query||;s|/resolve||;s|\[||;s|\]||')
            # 修复：使用扩展正则避免 \s 兼容问题
            if curl -s --max-time 5 "${URL}?name=google.com&type=A" \
                -H "accept: application/dns-json" 2>/dev/null | grep -qE '"Status":[[:space:]]*0'; then
                echo -e "  ${ICON_OK} $NAME"
            else
                echo -e "  ${ICON_FAIL} $NAME 不可达"
            fi
        done <<EOF
$(grep "^server-https" "$CONFIG_FILE" 2>/dev/null | head -6)
EOF
    else
        check_info "DoH 上游" "未配置"
    fi
fi

#==================================================
# 第5部分: 公共 DNS 连通性
#==================================================
print_section "第5部分: 公共 DNS 连通性"

print_sub "IPv4 DNS 服务器"
for ip in 8.8.8.8 1.1.1.1 223.5.5.5 119.29.29.29; do
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        check_pass "$ip 可达"
    else
        check_fail "$ip 不可达" "检查网络连通性"
    fi
done

print_sub "IPv6 DNS 服务器"
# 修复：使用 ping -6 替代已废弃的 ping6
for ip6 in 2001:4860:4860::8888 2606:4700:4700::1111; do
    if ping -6 -c 1 -W 2 "$ip6" >/dev/null 2>&1; then
        check_pass "$ip6 可达"
    else
        check_warn "$ip6 不可达" "可能无 IPv6 路由"
    fi
done

print_sub "DoH 公共服务器"
if command -v curl >/dev/null 2>&1; then
    for doh_url in \
        "https://cloudflare-dns.com/dns-query" \
        "https://dns.google/resolve"; do
        # 修复：使用扩展正则
        if curl -s --max-time 5 "${doh_url}?name=google.com&type=A" \
            -H "accept: application/dns-json" 2>/dev/null | grep -qE '"Status":[[:space:]]*0'; then
            check_pass "$(echo "$doh_url" | awk -F/ '{print $3}') DoH 正常"
        else
            check_warn "$(echo "$doh_url" | awk -F/ '{print $3}') DoH 异常"
        fi
    done
else
    check_warn "curl 未安装，跳过 DoH 检测"
fi

print_sub "DoT 公共服务器"
if command -v nc >/dev/null 2>&1; then
    for dot_item in "Cloudflare|1.1.1.1" "Google|8.8.8.8" "Quad9|9.9.9.9"; do
        NAME="${dot_item%%|*}"
        IP="${dot_item##*|}"
        if nc -z -w 3 "$IP" 853 2>/dev/null; then
            check_pass "$NAME DoT 可达"
        else
            check_fail "$NAME DoT 不可达"
        fi
    done
else
    check_info "DoT" "未安装 nc，跳过检测"
fi

#==================================================
# 最终报告
#==================================================
print_section "检测报告"

echo ""
echo -e "  检测模式: ${BOLD}$([ "$CHECK_MODE" = "smartdns" ] && echo "SmartDNS" || echo "系统DNS")${NC}"
echo -e "  ${GREEN}通过: $PASS${NC}"
echo -e "  ${YELLOW}警告: $WARN${NC}"
echo -e "  ${RED}失败: $FAIL${NC}"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}★★★★★ 完美！DNS 服务完全正常${NC}"
elif [ "$FAIL" -eq 0 ] && [ "$WARN" -le 3 ]; then
    echo -e "  ${GREEN}${BOLD}★★★★☆ 良好！基本可用${NC}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}★★★☆☆ 一般，存在较多警告${NC}"
elif [ "$FAIL" -le 2 ]; then
    echo -e "  ${RED}${BOLD}★★☆☆☆ 较差，部分功能不可用${NC}"
else
    echo -e "  ${RED}${BOLD}★☆☆☆☆ 严重，DNS 服务存在问题${NC}"
fi

echo ""
echo -e "检测完成: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 返回合适的退出码
[ "$FAIL" -gt 0 ] && exit 1
exit 0
