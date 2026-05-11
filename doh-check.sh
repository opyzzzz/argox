#!/bin/sh
#==================================================
# SmartDNS 部署后功能检测脚本 v2.0
# GitHub: https://github.com/你的用户名/仓库名
# 用法: wget -O- https://raw.githubusercontent.com/.../smartdns-check.sh | sh
# 功能: 全面检测SmartDNS运行状态、DNS解析、DoH、安全性
# 更新: 2026-05-11
#==================================================

set +e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# 评分
PASS=0
FAIL=0
WARN=0
TOTAL=0

# 图标
ICON_OK="${GREEN}✓${NC}"
ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"
ICON_INFO="${CYAN}ℹ${NC}"
ICON_ARROW="${BLUE}→${NC}"

# 打印函数
print_header() {
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║  SmartDNS 功能检测脚本 v2.0                             ║${NC}"
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
    if [ -n "$2" ]; then
        echo -e "    ${ICON_ARROW} 解决: $2"
    fi
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
}

check_warn() {
    echo -e "  ${ICON_WARN} $1"
    if [ -n "$2" ]; then
        echo -e "    ${ICON_ARROW} 建议: $2"
    fi
    WARN=$((WARN + 1))
    TOTAL=$((TOTAL + 1))
}

check_info() {
    echo -e "  ${ICON_INFO} $1: ${CYAN}$2${NC}"
}

#==================================================
# 第1部分: 系统环境
#==================================================
print_header
print_section "📋 第1部分: 系统环境检测"

print_sub "操作系统"
if [ -f /etc/alpine-release ]; then
    OS="Alpine $(cat /etc/alpine-release)"
    check_info "发行版" "$OS"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$PRETTY_NAME"
    check_info "发行版" "$OS"
else
    OS="Unknown"
    check_warn "无法识别操作系统"
fi

check_info "内核" "$(uname -r)"
check_info "架构" "$(uname -m)"
check_info "主机名" "$(hostname)"
check_info "运行时间" "$(uptime | sed 's/.*up //' | sed 's/,.*//')"

# 虚拟化检测
print_sub "虚拟化环境"
if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    VIRT="LXC"
    check_warn "检测到 LXC 容器环境" "某些功能可能受限"
elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    VIRT="Docker"
    check_warn "检测到 Docker 容器环境" "某些功能可能受限"
elif [ -d /proc/vz ]; then
    VIRT="OpenVZ"
    check_warn "检测到 OpenVZ 环境"
else
    VIRT="KVM/物理机"
    check_pass "物理机/KVM 环境: 完全支持"
fi

# Init 系统
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
        check_info "版本" "$($SMARTDNS_BIN -v 2>&1 | head -1)"
        check_info "大小" "$(ls -lh $path | awk '{print $5}')"
        break
    fi
done

if [ -z "$SMARTDNS_BIN" ]; then
    check_fail "未找到 SmartDNS 程序" "请先安装 SmartDNS"
fi

print_sub "配置文件"
CONFIG_FILE="/etc/smartdns/smartdns.conf"
if [ -f "$CONFIG_FILE" ]; then
    check_pass "配置文件存在: $CONFIG_FILE"
    check_info "大小" "$(wc -l < $CONFIG_FILE) 行"
    
    # 检查关键配置
    grep -q "^bind" "$CONFIG_FILE" && \
        check_pass "bind 配置存在" || \
        check_fail "缺少 bind 配置"
    
    grep -q "^server " "$CONFIG_FILE" && \
        check_pass "上游 DNS 配置存在" || \
        check_fail "缺少上游 DNS 配置"
    
    grep -q "server-https" "$CONFIG_FILE" && \
        check_pass "DoH 配置存在" || \
        check_warn "未配置 DoH" "建议添加 server-https 提升安全性"
    
    # 显示配置
    echo ""
    echo -e "  ${BOLD}配置摘要:${NC}"
    grep -E "^bind|^server |^server-https|^server-tls" "$CONFIG_FILE" | while read line; do
        echo -e "    ${CYAN}$line${NC}"
    done
else
    check_fail "配置文件不存在" "请检查 /etc/smartdns/smartdns.conf"
fi

print_sub "日志文件"
LOG_FILE="/var/log/smartdns.log"
if [ -f "$LOG_FILE" ]; then
    check_pass "日志文件存在: $LOG_FILE"
    check_info "大小" "$(ls -lh $LOG_FILE | awk '{print $5}')"
    
    # 检查日志中的错误
    ERROR_COUNT=$(grep -c "ERROR" "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$ERROR_COUNT" -gt 0 ]; then
        check_warn "日志中有 $ERROR_COUNT 条错误" "查看: tail -50 $LOG_FILE"
        echo ""
        echo -e "  ${BOLD}最近错误:${NC}"
        grep "ERROR" "$LOG_FILE" | tail -3 | while read line; do
            echo -e "    ${RED}$line${NC}"
        done
    else
        check_pass "日志无错误"
    fi
else
    check_warn "日志文件不存在" "首次运行可能尚未生成"
fi

#==================================================
# 第3部分: 进程与服务
#==================================================
print_section "⚙️ 第3部分: 进程与服务状态"

print_sub "进程状态"
if pgrep smartdns >/dev/null 2>&1; then
    PID=$(pgrep smartdns | head -1)
    check_pass "SmartDNS 正在运行 (PID: $PID)"
    
    # 进程详情
    CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null | xargs)
    MEM=$(ps -p $PID -o rss --no-headers 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
    START=$(ps -p $PID -o lstart --no-headers 2>/dev/null | xargs)
    
    check_info "CPU 使用" "${CPU}%"
    check_info "内存使用" "$MEM"
    check_info "启动时间" "$START"
    
    # 检查僵尸进程
    ZOMBIE=$(ps -p $PID -o stat --no-headers 2>/dev/null | grep -c "Z")
    if [ "$ZOMBIE" -gt 0 ]; then
        check_fail "进程状态异常 (僵尸进程)"
    fi
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
            check_fail "OpenRC 服务: 已崩溃" "查看日志: tail -50 /var/log/smartdns.log"
        elif echo "$STATUS" | grep -q "stopped"; then
            check_warn "OpenRC 服务: 已停止 (但进程可能在运行)"
        else
            check_info "OpenRC 状态" "$STATUS"
        fi
        ;;
    systemd)
        if systemctl is-active smartdns >/dev/null 2>&1; then
            check_pass "systemd 服务: active"
        else
            check_fail "systemd 服务: inactive"
        fi
        ;;
esac

print_sub "开机自启"
if [ "$INIT" = "openrc" ]; then
    if rc-status 2>/dev/null | grep -q smartdns; then
        check_pass "已添加到运行级别"
    else
        check_warn "未添加到运行级别" "执行: rc-update add smartdns default"
    fi
    
    # 检查 local.d 修复脚本
    if [ -f /etc/local.d/smartdns-fix.start ]; then
        check_pass "开机修复脚本存在"
    else
        check_warn "开机修复脚本不存在" "重启后 resolv.conf 可能被重置"
    fi
elif [ "$INIT" = "systemd" ]; then
    if systemctl is-enabled smartdns >/dev/null 2>&1; then
        check_pass "systemd 已启用"
    else
        check_warn "systemd 未启用" "执行: systemctl enable smartdns"
    fi
fi

#==================================================
# 第4部分: 端口与网络
#==================================================
print_section "🌐 第4部分: 端口与网络"

print_sub "监听端口"
SMARTDNS_PORT=""
if command -v ss >/dev/null 2>&1; then
    PORT_INFO=$(ss -tulnp 2>/dev/null | grep smartdns)
elif command -v netstat >/dev/null 2>&1; then
    PORT_INFO=$(netstat -tulnp 2>/dev/null | grep smartdns)
else
    PORT_INFO=""
fi

if [ -n "$PORT_INFO" ]; then
    echo "$PORT_INFO" | while read line; do
        PORT=$(echo "$line" | grep -oP ':\K\d+')
        PROTO=$(echo "$line" | awk '{print $1}')
        check_pass "监听: 0.0.0.0:$PORT ($PROTO)"
        SMARTDNS_PORT="$PORT"
    done
    SMARTDNS_PORT=$(echo "$PORT_INFO" | grep -oP ':\K\d+' | head -1)
else
    check_fail "未检测到监听端口"
fi

print_sub "端口冲突检测"
for port in 53 5353 5354 5355 8053; do
    LISTENERS=$(ss -tulnp 2>/dev/null | grep ":${port} " | grep -v smartdns)
    if [ -n "$LISTENERS" ]; then
        check_warn "端口 $port 有其他进程" "$(echo $LISTENERS | head -1)"
    fi
done

print_sub "本地 DNS 解析"
if [ -n "$SMARTDNS_PORT" ]; then
    # IPv4 解析
    for domain in google.com github.com cloudflare.com; do
        RESULT=$(nslookup -timeout=5 $domain 127.0.0.1 2>&1)
        if echo "$RESULT" | grep -q "Address"; then
            IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
            check_pass "IPv4: $domain → $IP"
        else
            check_fail "IPv4: $domain 解析失败" "检查上游DNS和网络"
        fi
    done
    
    # IPv6 解析（如果有）
    if ip route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        for domain in google.com cloudflare.com; do
            RESULT=$(nslookup -timeout=5 -type=AAAA $domain ::1 2>&1)
            if echo "$RESULT" | grep -q "AAAA"; then
                check_pass "IPv6: $domain 解析成功"
            else
                check_warn "IPv6: $domain 解析失败" "纯IPv4环境属正常"
            fi
        done
    fi
else
    check_fail "无法确定 SmartDNS 端口" "检查进程是否正常运行"
fi

#==================================================
# 第5部分: DoH/DoT 功能检测
#==================================================
print_section "🔒 第5部分: DoH/DoT 加密 DNS 检测"

print_sub "DoH (DNS over HTTPS) 连通性"
DOH_SERVERS="
Cloudflare|https://cloudflare-dns.com/dns-query
Google|https://dns.google/dns-query
Quad9|https://dns.quad9.net/dns-query
"

echo "$DOH_SERVERS" | while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    
    # 使用 curl 测试 DoH
    RESULT=$(curl -s --max-time 5 -H "accept: application/dns-json" "${url}?name=google.com&type=A" 2>&1)
    
    if echo "$RESULT" | grep -q '"Status":0'; then
        check_pass "$name DoH 正常"
        IP=$(echo "$RESULT" | grep -oP '"data":"[^"]+"' | head -1 | cut -d'"' -f4)
        [ -n "$IP" ] && check_info "  解析结果" "$IP"
    elif echo "$RESULT" | grep -q '"Status":2'; then
        check_fail "$name DoH 返回 SERVFAIL" "DNS 服务器内部错误"
    elif echo "$RESULT" | grep -q "Could not resolve host"; then
        check_fail "$name DoH DNS解析失败" "检查 resolv.conf 和网络"
    elif [ -z "$RESULT" ]; then
        check_fail "$name DoH 无响应" "网络不通或被防火墙阻止"
    else
        check_warn "$name DoH 响应异常" "$(echo $RESULT | head -c 100)"
    fi
done

print_sub "DoT (DNS over TLS) 连通性"
DOT_SERVERS="
Cloudflare|1.1.1.1|853|cloudflare-dns.com
Google|8.8.8.8|853|dns.google
Quad9|9.9.9.9|853|dns.quad9.net
"

echo "$DOT_SERVERS" | while IFS='|' read -r name ip port hostname; do
    [ -z "$name" ] && continue
    
    # 使用 openssl 测试 TLS 连接
    if command -v openssl >/dev/null 2>&1; then
        RESULT=$(echo | openssl s_client -connect ${ip}:${port} -servername ${hostname} -timeout 3 2>&1)
        if echo "$RESULT" | grep -q "Verify return code: 0"; then
            check_pass "$name DoT TLS 握手成功"
        elif echo "$RESULT" | grep -q "Connection timed out"; then
            check_fail "$name DoT 连接超时" "端口 853 可能被防火墙阻止"
        else
            check_warn "$name DoT 连接异常" "检查防火墙规则"
        fi
    else
        # 备选: 用 nc 测试端口
        if command -v nc >/dev/null 2>&1; then
            if nc -z -w 3 $ip $port 2>/dev/null; then
                check_pass "$name DoT 端口 $port 可达"
            else
                check_fail "$name DoT 端口 $port 不可达"
            fi
        else
            check_warn "$name DoT 无法检测 (缺少 openssl/nc)"
        fi
    fi
done

print_sub "HTTPS 连通性（基础）"
for url in "https://cloudflare.com" "https://google.com" "https://github.com"; do
    if curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "200\|301\|302"; then
        check_pass "$url 可达"
    else
        check_fail "$url 不可达" "检查网络和代理设置"
    fi
done

#==================================================
# 第6部分: resolv.conf 状态
#==================================================
print_section "📝 第6部分: resolv.conf 状态"

print_sub "文件状态"
if [ -L /etc/resolv.conf ]; then
    TARGET=$(readlink -f /etc/resolv.conf 2>/dev/null)
    check_warn "resolv.conf 是符号链接 → $TARGET" "可能被 DHCP 覆盖"
elif [ -f /etc/resolv.conf ]; then
    check_pass "resolv.conf 是常规文件"
else
    check_fail "resolv.conf 不存在"
fi

# 检查不可变属性
if lsattr /etc/resolv.conf 2>/dev/null | grep -q "\-i-"; then
    check_warn "resolv.conf 有不可变属性 (i)" "这可能阻止正常更新"
elif lsattr /etc/resolv.conf 2>/dev/null | grep -q "\-i"; then
    check_pass "resolv.conf 已锁定 (不可变)"
fi

print_sub "DNS 配置"
if [ -f /etc/resolv.conf ]; then
    echo ""
    echo -e "  ${BOLD}当前配置:${NC}"
    cat /etc/resolv.conf | while read line; do
        if echo "$line" | grep -q "^nameserver 127.0.0.1"; then
            echo -e "    ${GREEN}$line${NC}"
        elif echo "$line" | grep -q "^nameserver"; then
            echo -e "    ${YELLOW}$line${NC}"
        else
            echo -e "    ${CYAN}$line${NC}"
        fi
    done
    
    # 检查是否指向本地
    if grep -q "^nameserver 127.0.0.1" /etc/resolv.conf; then
        check_pass "DNS 指向本地 SmartDNS"
    else
        check_warn "DNS 未指向 127.0.0.1" "SmartDNS 可能未被使用"
        grep "^nameserver" /etc/resolv.conf | while read line; do
            check_info "当前 DNS" "$line"
        done
    fi
fi

print_sub "DHCP 客户端配置"
if [ -f /etc/dhcpcd.conf ]; then
    if grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
        check_pass "dhcpcd 已配置为不修改 DNS"
    else
        check_warn "dhcpcd 未配置" "重启后可能覆盖 resolv.conf"
    fi
fi

if pgrep dhcpcd >/dev/null 2>&1; then
    check_warn "dhcpcd 正在运行" "可能干扰 DNS 设置"
fi

# NetworkManager
if [ -f /etc/NetworkManager/conf.d/99-smartdns.conf ]; then
    check_pass "NetworkManager 已配置"
elif pgrep NetworkManager >/dev/null 2>&1; then
    check_warn "NetworkManager 运行中但未配置"
fi

# systemd-resolved
if pgrep systemd-resolved >/dev/null 2>&1; then
    check_warn "systemd-resolved 正在运行" "可能与 SmartDNS 冲突"
fi

#==================================================
# 第7部分: 上游 DNS 延迟测试
#==================================================
print_section "⏱️ 第7部分: 上游 DNS 延迟测试"

print_sub "UDP DNS 延迟"
for dns in "1.1.1.1" "8.8.8.8" "9.9.9.9"; do
    if command -v drill >/dev/null 2>&1; then
        TIME=$(drill google.com @$dns 2>&1 | grep "Query time" | awk '{print $4}')
    elif command -v dig >/dev/null 2>&1; then
        TIME=$(dig +time=3 google.com @$dns 2>&1 | grep "Query time" | awk '{print $4}')
    else
        # 用 nslookup 粗略估算
        START=$(date +%s%N)
        nslookup -timeout=3 google.com $dns >/dev/null 2>&1
        END=$(date +%s%N)
        TIME=$(( (END - START) / 1000000 ))
        TIME="${TIME}ms (估算)"
    fi
    
    if [ -n "$TIME" ]; then
        if echo "$TIME" | grep -q "^[0-9]" && [ "$(echo $TIME | grep -o '^[0-9]*')" -lt 100 ]; then
            check_pass "$dns 延迟: ${TIME}ms"
        else
            check_warn "$dns 延迟: ${TIME}ms (偏高)"
        fi
    else
        check_fail "$dns 无响应"
    fi
done

#==================================================
# 第8部分: 安全性检测
#==================================================
print_section "🛡️ 第8部分: 安全性检测"

print_sub "DNS 劫持检测"
# 使用多个 DNS 服务器解析同一域名，对比结果
DOMAIN="google.com"
RESULTS=""
for dns in "1.1.1.1" "8.8.8.8" "9.9.9.9"; do
    IP=$(nslookup -timeout=3 $DOMAIN $dns 2>/dev/null | grep "Address" | tail -1 | awk '{print $NF}')
    [ -n "$IP" ] && RESULTS="$RESULTS $IP"
done

UNIQUE=$(echo "$RESULTS" | tr ' ' '\n' | sort -u | wc -l)
if [ "$UNIQUE" -le 2 ]; then
    check_pass "多个 DNS 服务器结果一致 (未检测到劫持)"
else
    check_warn "不同 DNS 服务器返回不同 IP" "可能存在 DNS 劫持或 CDN 调度"
fi

print_sub "DNSSEC 支持检测"
if command -v dig >/dev/null 2>&1; then
    if dig +dnssec cloudflare.com @127.0.0.1 2>&1 | grep -q "ad;"; then
        check_pass "DNSSEC 验证通过"
    else
        check_warn "DNSSEC 未验证" "需要上游 DNS 支持"
    fi
else
    check_info "DNSSEC" "未安装 dig，跳过检测"
fi

print_sub "DNS 泄露检测"
# 检测是否会泄露查询到非预期 DNS
LEAK_DNS="114.114.114.114 223.5.5.5"
for dns in $LEAK_DNS; do
    if ss -tulnp 2>/dev/null | grep -q "$dns"; then
        check_fail "检测到可能的 DNS 泄露: $dns"
    fi
done
check_pass "未检测到 DNS 泄露"

#==================================================
# 第9部分: 性能压力测试
#==================================================
print_section "📊 第9部分: 性能测试"

print_sub "并发解析测试"
TEST_COUNT=10
SUCCESS=0
echo -e "  ${ICON_INFO} 测试 $TEST_COUNT 次并发解析..."

for i in $(seq 1 $TEST_COUNT); do
    nslookup -timeout=2 google.com 127.0.0.1 >/dev/null 2>&1 && SUCCESS=$((SUCCESS + 1))
done

if [ "$SUCCESS" -eq "$TEST_COUNT" ]; then
    check_pass "并发测试: $SUCCESS/$TEST_COUNT 成功"
elif [ "$SUCCESS" -ge $((TEST_COUNT * 80 / 100)) ]; then
    check_warn "并发测试: $SUCCESS/$TEST_COUNT 成功 (少量失败)"
else
    check_fail "并发测试: $SUCCESS/$TEST_COUNT 成功" "可能存在性能问题"
fi

print_sub "缓存命中测试"
# 连续查询同一域名，检测响应时间变化
FIRST_TIME=0
SECOND_TIME=0

START=$(date +%s%N)
nslookup -timeout=3 cloudflare.com 127.0.0.1 >/dev/null 2>&1
END=$(date +%s%N)
FIRST_TIME=$(( (END - START) / 1000000 ))

START=$(date +%s%N)
nslookup -timeout=3 cloudflare.com 127.0.0.1 >/dev/null 2>&1
END=$(date +%s%N)
SECOND_TIME=$(( (END - START) / 1000000 ))

check_info "首次查询" "${FIRST_TIME}ms"
check_info "缓存查询" "${SECOND_TIME}ms"

if [ "$SECOND_TIME" -le "$FIRST_TIME" ]; then
    check_pass "缓存生效 (${SECOND_TIME}ms <= ${FIRST_TIME}ms)"
else
    check_warn "缓存可能未生效"
fi

#==================================================
# 第10部分: 外部影响因素检测
#==================================================
print_section "🔎 第10部分: 外部影响因素检测"

print_sub "防火墙规则"
if command -v iptables >/dev/null 2>&1; then
    DNS_RULES=$(iptables -L -n 2>/dev/null | grep -c "dpt:53\|dpt:853\|dpt:5353")
    if [ "$DNS_RULES" -gt 0 ]; then
        check_warn "防火墙有 $DNS_RULES 条 DNS 相关规则" "可能影响 DNS 查询"
        iptables -L -n 2>/dev/null | grep "dpt:53\|dpt:853\|dpt:5353" | head -3 | while read line; do
            echo -e "    ${CYAN}$line${NC}"
        done
    else
        check_pass "防火墙未限制 DNS"
    fi
fi

if command -v nft >/dev/null 2>&1; then
    DNS_RULES=$(nft list ruleset 2>/dev/null | grep -c "dport 53\|dport 853\|dport 5353")
    if [ "$DNS_RULES" -gt 0 ]; then
        check_warn "nftables 有 DNS 相关规则"
    fi
fi

print_sub "SELinux/AppArmor"
if command -v getenforce >/dev/null 2>&1; then
    SE_STATUS=$(getenforce 2>/dev/null)
    if [ "$SE_STATUS" = "Enforcing" ]; then
        check_warn "SELinux 处于强制模式" "可能限制 SmartDNS"
    else
        check_pass "SELinux: $SE_STATUS"
    fi
fi

if command -v aa-status >/dev/null 2>&1; then
    if aa-status 2>/dev/null | grep -q "smartdns"; then
        check_warn "AppArmor 可能限制 smartdns"
    fi
fi

print_sub "资源限制"
if [ -f /proc/sys/fs/file-max ]; then
    FILE_MAX=$(cat /proc/sys/fs/file-max)
    check_info "系统最大文件句柄" "$FILE_MAX"
fi

ULIMIT=$(ulimit -n 2>/dev/null)
check_info "当前限制" "$ULIMIT"
[ "$ULIMIT" -lt 1024 ] && check_warn "文件句柄限制较低" "建议: ulimit -n 65536"

print_sub "磁盘空间"
USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
AVAIL=$(df -h / | awk 'NR==2 {print $4}')
if [ "$USAGE" -gt 90 ]; then
    check_fail "磁盘使用率: ${USAGE}% (可用: $AVAIL)"
elif [ "$USAGE" -gt 75 ]; then
    check_warn "磁盘使用率: ${USAGE}% (可用: $AVAIL)"
else
    check_pass "磁盘空间充足: ${AVAIL}可用"
fi

print_sub "内存"
MEM_AVAIL=$(free -m | awk 'NR==2 {print $7}')
MEM_TOTAL=$(free -m | awk 'NR==2 {print $2}')
check_info "可用内存" "${MEM_AVAIL}MB / ${MEM_TOTAL}MB"
[ "$MEM_AVAIL" -lt 50 ] && check_fail "内存不足" "SmartDNS 至少需要 20MB"

#==================================================
# 最终报告
#==================================================
print_section "📊 检测报告"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    检测结果汇总                          ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
printf "${BOLD}║${NC}  %-52s ${BOLD}║${NC}\n" "  总检测项: $TOTAL"
printf "${BOLD}║${NC}  %-52s ${BOLD}║${NC}\n" "  ${GREEN}通过: $PASS${NC}"
printf "${BOLD}║${NC}  %-52s ${BOLD}║${NC}\n" "  ${YELLOW}警告: $WARN${NC}"
printf "${BOLD}║${NC}  %-52s ${BOLD}║${NC}\n" "  ${RED}失败: $FAIL${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# 综合评分
SCORE=$(( PASS * 100 / TOTAL ))
echo -e "${BOLD}综合评分:${NC}"

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
echo -e "${BOLD}建议操作:${NC}"
if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}1. 优先解决上方标记为 ✗ 的失败项${NC}"
fi
if [ "$WARN" -gt 0 ]; then
    echo -e "  ${YELLOW}2. 关注标记为 ⚠ 的警告项${NC}"
fi
if pgrep smartdns >/dev/null 2>&1; then
    echo -e "  ${GREEN}3. SmartDNS 运行正常，可以继续使用${NC}"
else
    echo -e "  ${RED}3. SmartDNS 未运行，请先启动服务${NC}"
fi

echo ""
echo -e "检测时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "检测脚本版本: v2.0"
echo ""
