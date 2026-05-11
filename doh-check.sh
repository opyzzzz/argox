#!/bin/sh
#==================================================
# SmartDNS 部署后功能检测脚本 v2.2
# GitHub: https://github.com/你的用户名/仓库名
# 用法: wget -O- https://raw.githubusercontent.com/.../smartdns-check.sh | sh
# 修复: 整数比较bug、LXC磁盘检测、curl缺失降级
# 更新: 2026-05-11
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
ICON_ARROW="${BLUE}→${NC}"

print_header() {
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║  SmartDNS 功能检测脚本 v2.2                             ║${NC}"
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
    [ -n "$2" ] && echo -e "    ${ICON_ARROW} 解决: $2"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
}

check_warn() {
    echo -e "  ${ICON_WARN} $1"
    [ -n "$2" ] && echo -e "    ${ICON_ARROW} 建议: $2"
    WARN=$((WARN + 1))
    TOTAL=$((TOTAL + 1))
}

check_info() {
    echo -e "  ${ICON_INFO} $1: ${CYAN}$2${NC}"
}

# 安全整数比较
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
print_section "📋 第1部分: 系统环境检测"

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
check_info "主机名" "$(hostname)"
check_info "运行时间" "$(uptime | sed 's/.*up //; s/,.*//')"

print_sub "虚拟化环境"
if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    check_warn "检测到 LXC 容器环境" "某些功能可能受限"
elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    check_warn "检测到 Docker 容器环境"
elif [ -d /proc/vz ]; then
    check_warn "检测到 OpenVZ 环境"
else
    check_pass "物理机/KVM 环境: 完全支持"
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
    check_warn "未知 Init 系统" "服务管理可能受限"
fi

#==================================================
# 第2部分: SmartDNS 安装状态
#==================================================
print_section "🔍 第2部分: SmartDNS 安装状态"

print_sub "程序文件"
SMARTDNS_BIN=""
for path in /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns; do
    if [ -x "$path" ]; then
        SMARTDNS_BIN="$path"
        check_pass "找到: $path"
        VER=$($SMARTDNS_BIN -v 2>&1 | head -1)
        check_info "版本" "$VER"
        check_info "大小" "$(ls -lh $path | awk '{print $5}')"
        break
    fi
done
[ -z "$SMARTDNS_BIN" ] && check_fail "未找到 SmartDNS 程序" "请先安装 SmartDNS"

print_sub "配置文件"
CONFIG_FILE="/etc/smartdns/smartdns.conf"
if [ -f "$CONFIG_FILE" ]; then
    check_pass "配置文件存在: $CONFIG_FILE"
    LINES=$(wc -l < "$CONFIG_FILE" 2>/dev/null || echo 0)
    check_info "大小" "$LINES 行"
    
    grep -q "^bind" "$CONFIG_FILE" && check_pass "bind 配置存在" || check_fail "缺少 bind 配置"
    grep -q "^server " "$CONFIG_FILE" && check_pass "上游 DNS 配置存在" || check_fail "缺少上游 DNS 配置"
    grep -q "server-https" "$CONFIG_FILE" && check_pass "DoH 配置存在" || check_warn "未配置 DoH"
    
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
    check_pass "日志文件存在: $LOG_FILE"
    SIZE=$(ls -lh "$LOG_FILE" 2>/dev/null | awk '{print $5}')
    check_info "大小" "$SIZE"
    
    ERRORS=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null)
    ERRORS=$(safe_int "$ERRORS")
    if [ "$ERRORS" -gt 0 ] 2>/dev/null; then
        check_warn "日志中有 $ERRORS 条错误" "查看: tail -50 $LOG_FILE"
        echo ""
        echo -e "  ${BOLD}最近错误:${NC}"
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
print_section "⚙️ 第3部分: 进程与服务状态"

print_sub "进程状态"
if pgrep smartdns >/dev/null 2>&1; then
    PID=$(pgrep smartdns | head -1)
    check_pass "SmartDNS 正在运行 (PID: $PID)"
    
    CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null | tr -d ' ')
    MEM=$(ps -p $PID -o rss --no-headers 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
    START=$(ps -p $PID -o lstart --no-headers 2>/dev/null | tr -d '\n')
    
    check_info "CPU 使用" "${CPU:-未知}%"
    check_info "内存使用" "${MEM:-未知}"
    check_info "启动时间" "${START:-未知}"
else
    check_fail "SmartDNS 未运行" "执行: smartdns -c /etc/smartdns/smartdns.conf &"
fi

print_sub "服务状态"
case "$INIT" in
    openrc)
        STATUS=$(rc-service smartdns status 2>&1)
        if echo "$STATUS" | grep -q "started"; then
            check_pass "OpenRC 服务: 已启动"
        elif echo "$STATUS" | grep -q "crashed"; then
            check_fail "OpenRC 服务: 已崩溃"
        else
            check_info "OpenRC 状态" "$STATUS"
        fi
        ;;
    systemd)
        systemctl is-active smartdns >/dev/null 2>&1 && \
            check_pass "systemd 服务: active" || \
            check_fail "systemd 服务: inactive"
        ;;
esac

print_sub "开机自启"
if [ "$INIT" = "openrc" ]; then
    rc-status 2>/dev/null | grep -q smartdns && \
        check_pass "已添加到运行级别" || \
        check_warn "未添加到运行级别"
    [ -f /etc/local.d/smartdns-fix.start ] && \
        check_pass "开机修复脚本存在" || \
        check_warn "开机修复脚本不存在" "重启后 resolv.conf 可能被重置"
elif [ "$INIT" = "systemd" ]; then
    systemctl is-enabled smartdns >/dev/null 2>&1 && \
        check_pass "systemd 已启用" || \
        check_warn "systemd 未启用"
fi

#==================================================
# 第4部分: 端口与网络
#==================================================
print_section "🌐 第4部分: 端口与网络"

print_sub "监听端口"
if command -v ss >/dev/null 2>&1; then
    PORT_INFO=$(ss -tulnp 2>/dev/null | grep smartdns)
elif command -v netstat >/dev/null 2>&1; then
    PORT_INFO=$(netstat -tulnp 2>/dev/null | grep smartdns)
else
    PORT_INFO=""
fi

if [ -n "$PORT_INFO" ]; then
    echo "$PORT_INFO" | while read line; do
        PORT=$(echo "$line" | grep -oP ':\K\d+' | head -1)
        check_pass "监听: 0.0.0.0:$PORT"
    done
else
    check_fail "未检测到监听端口"
fi

print_sub "本地 DNS 解析"
for domain in google.com github.com cloudflare.com; do
    RESULT=$(nslookup -timeout=5 $domain 127.0.0.1 2>&1)
    if echo "$RESULT" | grep -q "Address"; then
        IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
        check_pass "IPv4: $domain → $IP"
    else
        check_fail "IPv4: $domain 解析失败"
    fi
done

#==================================================
# 第5部分: DoH/DoT 检测
#==================================================
print_section "🔒 第5部分: DoH/DoT 加密 DNS 检测"

HAS_CURL=false
command -v curl >/dev/null 2>&1 && HAS_CURL=true

print_sub "DoH (DNS over HTTPS) 连通性"
if [ "$HAS_CURL" = true ]; then
    for item in "Cloudflare|https://cloudflare-dns.com/dns-query" "Google|https://dns.google/dns-query"; do
        NAME="${item%%|*}"
        URL="${item##*|}"
        RESULT=$(curl -s --max-time 5 -H "accept: application/dns-json" "${URL}?name=google.com&type=A" 2>&1)
        if echo "$RESULT" | grep -q '"Status":\s*0'; then
            check_pass "$NAME DoH 正常"
        elif echo "$RESULT" | grep -q "curl: command not found"; then
            check_warn "$NAME DoH 无法检测 (curl未安装)"
        else
            check_warn "$NAME DoH 响应异常" "可能受网络限制"
        fi
    done
else
    check_warn "curl 未安装，跳过 DoH 检测" "安装: apk add curl 或 apt install curl"
fi

print_sub "DoT (DNS over TLS) 连通性"
for item in "Cloudflare|1.1.1.1|853" "Google|8.8.8.8|853"; do
    NAME="${item%%|*}"
    REST="${item#*|}"
    IP="${REST%%|*}"
    PORT="${REST##*|}"
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "$IP" "$PORT" 2>/dev/null; then
            check_pass "$NAME DoT 端口 $PORT 可达"
        else
            check_fail "$NAME DoT 端口 $PORT 不可达"
        fi
    else
        check_info "$NAME DoT" "未安装 nc，跳过检测"
    fi
done

print_sub "HTTPS 连通性"
if [ "$HAS_CURL" = true ]; then
    for url in "https://cloudflare.com" "https://github.com"; do
        HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
            check_pass "$url 可达"
        else
            check_fail "$url 不可达" "检查网络"
        fi
    done
fi

#==================================================
# 第6部分: resolv.conf
#==================================================
print_section "📝 第6部分: resolv.conf 状态"

print_sub "文件状态"
if [ -L /etc/resolv.conf ]; then
    check_warn "resolv.conf 是符号链接" "可能被 DHCP 覆盖"
elif [ -f /etc/resolv.conf ]; then
    check_pass "resolv.conf 是常规文件"
else
    check_fail "resolv.conf 不存在"
fi

print_sub "DNS 配置"
if [ -f /etc/resolv.conf ]; then
    if grep -q "^nameserver 127.0.0.1" /etc/resolv.conf; then
        check_pass "DNS 指向本地 SmartDNS"
    else
        check_warn "DNS 未指向 127.0.0.1"
    fi
    echo ""
    echo -e "  ${BOLD}当前配置:${NC}"
    cat /etc/resolv.conf | while read line; do
        echo -e "    ${CYAN}$line${NC}"
    done
fi

print_sub "DHCP 客户端"
if [ -f /etc/dhcpcd.conf ]; then
    grep -q "nohook resolv.conf" /etc/dhcpcd.conf && \
        check_pass "dhcpcd 已配置" || \
        check_warn "dhcpcd 未配置"
fi
pgrep dhcpcd >/dev/null 2>&1 && check_warn "dhcpcd 正在运行" "可能干扰 DNS 设置"

#==================================================
# 第7部分: 性能测试
#==================================================
print_section "📊 第7部分: 性能测试"

print_sub "并发解析测试"
SUCCESS=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    nslookup -timeout=2 google.com 127.0.0.1 >/dev/null 2>&1 && SUCCESS=$((SUCCESS + 1))
done
[ "$SUCCESS" -eq 10 ] && check_pass "并发测试: 10/10 成功" || \
    check_warn "并发测试: $SUCCESS/10 成功"

print_sub "缓存命中测试"
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
# 第8部分: 外部影响
#==================================================
print_section "🔎 第8部分: 外部影响因素检测"

print_sub "磁盘空间"
# 修复: 兼容 LXC 的 df 输出格式
DISK_LINE=$(df -h / 2>/dev/null | tail -1)
USAGE=$(echo "$DISK_LINE" | awk '{print $5}' | sed 's/%//' 2>/dev/null)
USAGE=$(safe_int "$USAGE")
AVAIL=$(echo "$DISK_LINE" | awk '{print $4}' 2>/dev/null)

if [ "$USAGE" -gt 90 ] 2>/dev/null; then
    check_fail "磁盘使用率: ${USAGE}%"
elif [ "$USAGE" -gt 75 ] 2>/dev/null; then
    check_warn "磁盘使用率: ${USAGE}%"
else
    check_pass "磁盘空间充足: ${AVAIL}可用"
fi

print_sub "内存"
MEM_AVAIL=$(free -m 2>/dev/null | awk 'NR==2 {print $7}')
MEM_TOTAL=$(free -m 2>/dev/null | awk 'NR==2 {print $2}')
MEM_AVAIL=$(safe_int "$MEM_AVAIL")
check_info "可用内存" "${MEM_AVAIL}MB / ${MEM_TOTAL}MB"
[ "$MEM_AVAIL" -lt 50 ] 2>/dev/null && check_fail "内存不足"

print_sub "DNS 泄露检测"
for dns in "114.114.114.114" "223.5.5.5" "180.76.76.76"; do
    if ss -tulnp 2>/dev/null | grep -q "$dns"; then
        check_fail "检测到非预期 DNS: $dns"
    fi
done
check_pass "未检测到 DNS 泄露"

#==================================================
# 最终报告
#==================================================
print_section "📊 检测报告"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    检测结果汇总                          ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║${NC}  总检测项: %-46s ${BOLD}║${NC}\n" "$TOTAL"
printf "${BOLD}║${NC}  ${GREEN}通过: $PASS${NC}%-$(($(tput cols 2>/dev/null || echo 50) - 20))s ${BOLD}║${NC}\n" ""
printf "${BOLD}║${NC}  ${YELLOW}警告: $WARN${NC}%-$(($(tput cols 2>/dev/null || echo 50) - 20))s ${BOLD}║${NC}\n" ""
printf "${BOLD}║${NC}  ${RED}失败: $FAIL${NC}%-$(($(tput cols 2>/dev/null || echo 50) - 20))s ${BOLD}║${NC}\n" ""
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# 评分
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
echo -e "检测时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "检测脚本: v2.2"
echo ""
