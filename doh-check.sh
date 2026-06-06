#!/bin/sh
#==================================================
# SmartDNS 部署后功能检测脚本 v2.7
# 修复: Quad9 DoH 使用 POST 检测
# 用法: wget -qO- https://.../smartdns-check.sh | sh
# 更新: 2026-06-06
#==================================================

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0; FAIL=0; WARN=0; TOTAL=0

ICON_OK="${GREEN}✓${NC}"
ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"
ICON_INFO="${CYAN}ℹ${NC}"

print_header() {
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║  SmartDNS 功能检测脚本 v2.7                             ║${NC}"
    echo -e "${BOLD}${MAGENTA}║  检测时间: $(date '+%Y-%m-%d %H:%M:%S')                        ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_sub() {
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

safe_int() {
    local val="$1"
    case "$val" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$val" ;;
    esac
}

#==================================================
# 第1部分: 系统环境
#==================================================
print_header
print_section "第1部分: 系统环境"

print_sub "操作系统"
if [ -f /etc/alpine-release ]; then
    OS="Alpine $(cat /etc/alpine-release)"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$PRETTY_NAME"
else
    OS="Unknown"
fi
check_info "发行版" "$OS"
check_info "内核" "$(uname -r)"
check_info "架构" "$(uname -m)"
check_info "运行时间" "$(uptime | sed 's/.*up //; s/,.*//')"

print_sub "虚拟化环境"
if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    check_warn "LXC 容器环境"
elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    check_warn "Docker 容器环境"
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
# 第2部分: SmartDNS 安装状态
#==================================================
print_section "第2部分: SmartDNS 安装状态"

print_sub "程序文件"
SMARTDNS_BIN=""
for path in /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns; do
    if [ -x "$path" ]; then
        SMARTDNS_BIN="$path"
        check_pass "找到: $path"
        VER=$($SMARTDNS_BIN -v 2>&1 | head -1)
        check_info "版本" "$VER"
        break
    fi
done
[ -z "$SMARTDNS_BIN" ] && check_fail "未找到 SmartDNS 程序" "请先安装 SmartDNS"

print_sub "配置文件"
CONFIG_FILE="/etc/smartdns/smartdns.conf"
if [ -f "$CONFIG_FILE" ]; then
    check_pass "配置文件存在"
    
    grep -q "^bind" "$CONFIG_FILE" && check_pass "bind 配置存在" || check_fail "缺少 bind 配置"
    
    UDP_COUNT=$(grep -c "^server " "$CONFIG_FILE" 2>/dev/null || echo 0)
    DOH_COUNT=$(grep -c "^server-https" "$CONFIG_FILE" 2>/dev/null || echo 0)
    DOT_COUNT=$(grep -c "^server-tls" "$CONFIG_FILE" 2>/dev/null || echo 0)
    
    TOTAL_UPSTREAM=$((UDP_COUNT + DOH_COUNT + DOT_COUNT))
    
    if [ "$TOTAL_UPSTREAM" -gt 0 ]; then
        check_pass "上游 DNS: $TOTAL_UPSTREAM 个"
        check_info "上游统计" "UDP:$UDP_COUNT DoH:$DOH_COUNT DoT:$DOT_COUNT"
    else
        check_fail "缺少上游 DNS 配置"
    fi
    
    echo ""
    echo -e "  ${BOLD}配置摘要:${NC}"
    grep -E "^bind|^server |^server-https|^server-tls" "$CONFIG_FILE" 2>/dev/null | while read line; do
        echo -e "    ${CYAN}$line${NC}"
    done
else
    check_fail "配置文件不存在"
fi

print_sub "日志文件"
LOG_FILE="/var/log/smartdns.log"
if [ -f "$LOG_FILE" ]; then
    check_pass "日志文件存在"
    ERRORS=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo 0)
    ERRORS=$(safe_int "$ERRORS")
    if [ "$ERRORS" -gt 0 ]; then
        check_warn "日志中有 $ERRORS 条错误"
        echo ""
        grep "ERROR" "$LOG_FILE" 2>/dev/null | tail -3 | while read line; do
            echo -e "    ${RED}$line${NC}"
        done
    else
        check_pass "日志无错误"
    fi
else
    check_warn "日志文件不存在"
fi

#==================================================
# 第3部分: 进程与服务
#==================================================
print_section "第3部分: 进程与服务"

print_sub "进程状态"
if pgrep smartdns >/dev/null 2>&1; then
    PID=$(pgrep smartdns | head -1)
    check_pass "SmartDNS 运行中 (PID: $PID)"
    MEM=$(ps -p $PID -o rss --no-headers 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
    check_info "内存使用" "${MEM:-未知}"
else
    check_fail "SmartDNS 未运行" "systemctl start smartdns"
fi

print_sub "服务状态"
case "$INIT" in
    systemd)
        systemctl is-active smartdns >/dev/null 2>&1 && \
            check_pass "systemd 服务: active" || \
            check_fail "systemd 服务: inactive"
        systemctl is-enabled smartdns >/dev/null 2>&1 && \
            check_pass "开机自启: 已启用" || \
            check_warn "开机自启: 未启用"
        ;;
    openrc)
        rc-service smartdns status 2>&1 | grep -q "started" && \
            check_pass "OpenRC 服务: started" || \
            check_warn "OpenRC 服务: 未启动"
        [ -f /etc/local.d/smartdns-fix.start ] && \
            check_pass "开机修复脚本存在" || \
            check_warn "开机修复脚本不存在"
        ;;
esac

#==================================================
# 第4部分: DNS 解析测试
#==================================================
print_section "第4部分: DNS 解析测试"

print_sub "IPv4 解析"
for domain in google.com github.com cloudflare.com; do
    if nslookup -timeout=3 $domain 127.0.0.1 >/dev/null 2>&1; then
        IP=$(nslookup -timeout=3 $domain 127.0.0.1 2>/dev/null | grep "Address" | tail -1 | awk '{print $NF}')
        check_pass "$domain → $IP"
    else
        check_fail "$domain 解析失败"
    fi
done

print_sub "IPv6 解析"
for domain in ipv6.google.com cloudflare.com; do
    if nslookup -timeout=3 -type=AAAA $domain 127.0.0.1 >/dev/null 2>&1; then
        IP=$(nslookup -timeout=3 -type=AAAA $domain 127.0.0.1 2>/dev/null | grep "Address" | tail -1 | awk '{print $NF}')
        check_pass "$domain → $IP"
    else
        check_warn "$domain AAAA 解析失败" "可能无 IPv6 上游"
    fi
done

#==================================================
# 第5部分: 上游 DNS 解析测试
#==================================================
print_section "第5部分: 上游 DNS 解析测试"

print_sub "UDP 上游"
if [ -f "$CONFIG_FILE" ] && grep -q "^server " "$CONFIG_FILE" 2>/dev/null; then
    grep "^server " "$CONFIG_FILE" 2>/dev/null | head -6 | while read line; do
        IP=$(echo "$line" | awk '{print $2}' | cut -d: -f1)
        if nslookup -timeout=3 google.com $IP >/dev/null 2>&1; then
            echo -e "  ${ICON_OK} $IP"
        else
            echo -e "  ${ICON_FAIL} $IP 不可达"
        fi
    done
else
    check_info "UDP 上游" "未配置"
fi

print_sub "DoH 上游"
if [ -f "$CONFIG_FILE" ] && grep -q "^server-https" "$CONFIG_FILE" 2>/dev/null; then
    grep "^server-https" "$CONFIG_FILE" 2>/dev/null | head -6 | while read line; do
        URL=$(echo "$line" | awk '{print $2}')
        NAME=$(echo "$URL" | sed 's|https://||;s|/dns-query||;s|/resolve||;s|\[||;s|\]||')
        case "$URL" in
            *dns.google*)
                if curl -s --max-time 5 "https://dns.google/resolve?name=google.com&type=A" \
                    -H "accept: application/dns-json" 2>/dev/null | grep -q '"Status":\s*0'; then
                    echo -e "  ${ICON_OK} $NAME"
                else
                    echo -e "  ${ICON_FAIL} $NAME 不可达"
                fi
                ;;
            *quad9*)
                if curl -s --max-time 5 -X POST "$URL" \
                    -H "Content-Type: application/dns-message" \
                    --data "AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB" 2>/dev/null | grep -q .; then
                    echo -e "  ${ICON_OK} $NAME"
                else
                    echo -e "  ${ICON_FAIL} $NAME 不可达"
                fi
                ;;
            *)
                if curl -s --max-time 5 "${URL}?name=google.com&type=A" \
                    -H "accept: application/dns-json" 2>/dev/null | grep -q '"Status":\s*0'; then
                    echo -e "  ${ICON_OK} $NAME"
                else
                    echo -e "  ${ICON_FAIL} $NAME 不可达"
                fi
                ;;
        esac
    done
else
    check_info "DoH 上游" "未配置"
fi

print_sub "DoT 上游"
if [ -f "$CONFIG_FILE" ] && grep -q "^server-tls" "$CONFIG_FILE" 2>/dev/null; then
    grep "^server-tls" "$CONFIG_FILE" 2>/dev/null | head -6 | while read line; do
        IP=$(echo "$line" | awk '{print $2}' | cut -d: -f1)
        if nc -z -w 3 "$IP" 853 2>/dev/null; then
            echo -e "  ${ICON_OK} $IP"
        else
            echo -e "  ${ICON_FAIL} $IP 不可达"
        fi
    done
else
    check_info "DoT 上游" "未配置"
fi

#==================================================
# 第6部分: DoH/DoT 公网连通性
#==================================================
print_section "第6部分: DoH/DoT 公网连通性"

print_sub "DoH 连通性"
if command -v curl >/dev/null 2>&1; then
    if curl -s --max-time 5 "https://cloudflare-dns.com/dns-query?name=google.com" \
        -H "accept: application/dns-json" 2>/dev/null | grep -q '"Status":\s*0'; then
        check_pass "Cloudflare DoH 正常"
    else
        check_warn "Cloudflare DoH 异常"
    fi
    
    if curl -s --max-time 5 "https://dns.google/resolve?name=google.com&type=A" \
        -H "accept: application/dns-json" 2>/dev/null | grep -q '"Status":\s*0'; then
        check_pass "Google DoH 正常"
    else
        check_warn "Google DoH 异常" "国内可能被阻断"
    fi
    
    if curl -s --max-time 5 -X POST "https://dns.quad9.net/dns-query" \
        -H "Content-Type: application/dns-message" \
        --data "AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB" 2>/dev/null | grep -q .; then
        check_pass "Quad9 DoH 正常"
    else
        check_warn "Quad9 DoH 异常"
    fi
else
    check_warn "curl 未安装，跳过 DoH 检测"
fi

print_sub "DoT 连通性"
for item in "Cloudflare|1.1.1.1|853" "Google|8.8.8.8|853" "Quad9|9.9.9.9|853"; do
    NAME="${item%%|*}"
    IP=$(echo "$item" | awk -F'|' '{print $2}')
    PORT=$(echo "$item" | awk -F'|' '{print $3}')
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "$IP" "$PORT" 2>/dev/null; then
            check_pass "$NAME DoT 可达"
        else
            check_fail "$NAME DoT 不可达" "检查防火墙 853 端口"
        fi
    else
        check_info "$NAME DoT" "未安装 nc，跳过检测"
    fi
done

#==================================================
# 第7部分: resolv.conf
#==================================================
print_section "第7部分: resolv.conf 状态"

if [ -L /etc/resolv.conf ]; then
    check_warn "resolv.conf 是符号链接"
elif [ -f /etc/resolv.conf ]; then
    check_pass "resolv.conf 是常规文件"
else
    check_fail "resolv.conf 不存在"
fi

if [ -f /etc/resolv.conf ]; then
    if grep -q "^nameserver 127.0.0.1" /etc/resolv.conf; then
        check_pass "DNS 指向 127.0.0.1"
    else
        check_warn "DNS 未指向 127.0.0.1"
    fi
    
    echo ""
    echo -e "  ${BOLD}当前配置:${NC}"
    cat /etc/resolv.conf | while read line; do
        echo -e "    ${CYAN}$line${NC}"
    done
fi

#==================================================
# 第8部分: 性能测试
#==================================================
print_section "第8部分: 性能测试"

print_sub "缓存测试"
START=$(date +%s%N 2>/dev/null || echo 0)
nslookup -timeout=3 cloudflare.com 127.0.0.1 >/dev/null 2>&1
END=$(date +%s%N 2>/dev/null || echo 0)
FIRST=$(( (END - START) / 1000000 ))

START=$(date +%s%N 2>/dev/null || echo 0)
nslookup -timeout=3 cloudflare.com 127.0.0.1 >/dev/null 2>&1
END=$(date +%s%N 2>/dev/null || echo 0)
SECOND=$(( (END - START) / 1000000 ))

check_info "首次查询" "${FIRST}ms"
check_info "缓存查询" "${SECOND}ms"
[ "$SECOND" -le "$FIRST" ] 2>/dev/null && check_pass "缓存生效" || check_warn "缓存可能未生效"

#==================================================
# 第9部分: 系统资源
#==================================================
print_section "第9部分: 系统资源"

DISK_AVAIL=$(df -h / 2>/dev/null | tail -1 | awk '{print $4}')
MEM_AVAIL=$(free -m 2>/dev/null | awk 'NR==2 {print $7}')
MEM_AVAIL=$(safe_int "$MEM_AVAIL")

check_info "磁盘可用" "${DISK_AVAIL:-未知}"
check_info "内存可用" "${MEM_AVAIL}MB"

[ "$MEM_AVAIL" -lt 50 ] 2>/dev/null && check_warn "内存不足 50MB"

#==================================================
# 最终报告
#==================================================
print_section "检测报告"

echo ""
echo -e "  ${GREEN}通过: $PASS${NC}"
echo -e "  ${YELLOW}警告: $WARN${NC}"
echo -e "  ${RED}失败: $FAIL${NC}"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}★★★★★ 完美！所有检测通过${NC}"
elif [ "$FAIL" -eq 0 ] && [ "$WARN" -le 3 ]; then
    echo -e "  ${GREEN}${BOLD}★★★★☆ 良好！仅有少量警告${NC}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "  ${YELLOW}${BOLD}★★★☆☆ 一般！需要关注警告项${NC}"
elif [ "$FAIL" -le 2 ]; then
    echo -e "  ${RED}${BOLD}★★☆☆☆ 较差！需要修复失败项${NC}"
else
    echo -e "  ${RED}${BOLD}★☆☆☆☆ 严重！存在多个问题${NC}"
fi

echo ""
echo -e "检测完成: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
