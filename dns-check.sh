#!/bin/bash

# =================================================================
# DNS 一键检测脚本 v2.0
# 功能: 全面检测 DNS 加密解析系统健康状况
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 符号定义
PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"
ARROW="${CYAN}→${NC}"

# 配置
RESOLV_CONF="/etc/resolv.conf"
STUBBY_CONF="/etc/stubby/stubby.yml"
LOG_DIR="/var/log/secure-dns"
DAEMON_LOG="${LOG_DIR}/daemon.log"
SHA_FILE="/etc/stubby/stubby.yml.sha256"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"

# 统计变量
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# 分隔线
print_separator() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

# 打印标题
print_section() {
    echo -e "\n${PURPLE}▧${NC} ${WHITE}${1}${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
}

# 检查结果
check_result() {
    local status=$1
    local message=$2
    
    if [ $status -eq 0 ]; then
        echo -e "  ${PASS} ${message}"
        ((PASS_COUNT++))
        return 0
    else
        echo -e "  ${FAIL} ${message}"
        ((FAIL_COUNT++))
        return 1
    fi
}

# 警告结果
warn_result() {
    local message=$1
    echo -e "  ${WARN} ${message}"
    ((WARN_COUNT++))
}

# 主标题
clear
echo -e "${BLUE}"
cat << "BANNER"
╔══════════════════════════════════════════════════════════════╗
║     DNS 加密解析系统 (Secure-DNS) 健康检查工具 v2.0        ║
║     Secure DNS Health Check Tool                            ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
echo -e "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "主机名: $(hostname)"
echo -e "系统版本: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2 2>/dev/null || echo 'Unknown')"

# =================================================================
# 1. 环境检测
# =================================================================
print_section "1. 系统环境检测"

# 检测容器环境
echo -e "  ${ARROW} 运行环境检查:"
if [ -f /.dockerenv ]; then
    echo -e "    ${WARN} Docker 容器环境"
    IS_CONTAINER=true
elif grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
    echo -e "    ${WARN} 容器环境 (LXC/Docker)"
    IS_CONTAINER=true
else
    echo -e "    ${PASS} 物理机/虚拟机环境"
    IS_CONTAINER=false
fi

# 检查网络连通性
echo -e "  ${ARROW} 网络连通性:"
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    check_result 0 "外网连通性正常 (1.1.1.1)"
else
    check_result 1 "外网连通性异常 - 可能无法连接上游 DNS"
fi

# 检查 853 端口 (DoT)
echo -e "  ${ARROW} DoT 端口连通性:"
if timeout 3 bash -c "echo >/dev/tcp/1.1.1.1/853" 2>/dev/null; then
    check_result 0 "DoT 端口 853 可达 (1.1.1.1)"
else
    warn_result "DoT 端口 853 不可达 - 可能被防火墙拦截"
fi

# =================================================================
# 2. resolv.conf 检查
# =================================================================
print_section "2. DNS 配置文件检查 (/etc/resolv.conf)"

# 检查文件存在
if [ -f "$RESOLV_CONF" ]; then
    check_result 0 "resolv.conf 文件存在"
else
    check_result 1 "resolv.conf 文件不存在"
fi

# 检查是否为符号链接
if [ -L "$RESOLV_CONF" ]; then
    local target=$(readlink -f "$RESOLV_CONF")
    warn_result "resolv.conf 是符号链接 → ${target}"
    echo -e "    ${INFO} 实际文件路径: ${target}"
    REAL_RESOLV="$target"
else
    echo -e "    ${PASS} resolv.conf 是普通文件"
    REAL_RESOLV="$RESOLV_CONF"
fi

# 检查文件权限
echo -e "  ${ARROW} 文件权限:"
if [ -f "$RESOLV_CONF" ]; then
    local perms=$(stat -c "%a %U:%G" "$RESOLV_CONF" 2>/dev/null || stat -f "%p %u:%g" "$RESOLV_CONF" 2>/dev/null)
    echo -e "    ${INFO} 权限: ${perms}"
    
    # 检查不可变属性
    if lsattr "$RESOLV_CONF" 2>/dev/null | grep -q 'i'; then
        echo -e "    ${PASS} 文件已设置不可变属性 (chattr +i)"
    else
        warn_result "文件未设置不可变属性 (容器中属于正常)"
    fi
fi

# 检查 DNS 配置内容
echo -e "  ${ARROW} DNS 配置内容:"
if [ -f "$RESOLV_CONF" ]; then
    local first_line=$(head -n 1 "$RESOLV_CONF" 2>/dev/null)
    echo -e "    ${INFO} 首行: ${first_line}"
    
    if echo "$first_line" | grep -q "127.0.0.1"; then
        check_result 0 "DNS 已正确配置为 127.0.0.1"
    else
        check_result 1 "DNS 未指向 127.0.0.1 - 可能未被接管"
    fi
    
    # 显示完整配置
    echo -e "    ${ARROW} 完整配置:"
    cat "$RESOLV_CONF" | while IFS= read -r line; do
        if [ -n "$line" ]; then
            echo -e "      ${CYAN}|${NC} ${line}"
        fi
    done
fi

# =================================================================
# 3. Stubby 配置与服务检查
# =================================================================
print_section "3. Stubby DoT 服务检查"

# 检查配置文件
if [ -f "$STUBBY_CONF" ]; then
    check_result 0 "Stubby 配置文件存在"
    
    # 配置文件大小
    local conf_size=$(wc -c < "$STUBBY_CONF")
    echo -e "    ${INFO} 配置文件大小: ${conf_size} 字节"
else
    check_result 1 "Stubby 配置文件不存在"
fi

# 检查备份配置
if [ -f "$BACKUP_CONF" ]; then
    check_result 0 "存在配置备份 (.stubby.yml.bak)"
else
    warn_result "缺少配置备份文件"
fi

# 配置文件校验
if [ -f "$SHA_FILE" ]; then
    echo -e "  ${ARROW} 配置完整性校验:"
    if sha256sum -c "$SHA_FILE" >/dev/null 2>&1; then
        check_result 0 "配置文件校验和一致 (未篡改)"
        echo -e "    $(cat $SHA_FILE)"
    else
        check_result 1 "配置文件校验和不一致 (可能被篡改)"
        fail_detail "当前哈希: $(sha256sum $STUBBY_CONF | cut -d' ' -f1)"
        fail_detail "备份哈希: $(cat $SHA_FILE | cut -d' ' -f1)"
    fi
fi

# 检查配置文件内容
echo -e "  ${ARROW} 关键配置检查:"
if [ -f "$STUBBY_CONF" ]; then
    grep -q "GETDNS_TRANSPORT_TLS" "$STUBBY_CONF" && \
        check_result 0 "加密传输已启用 (TLS)" || \
        check_result 1 "加密传输未配置"
    
    grep -q "127.0.0.1@53" "$STUBBY_CONF" && \
        check_result 0 "监听地址正确 (127.0.0.1:53)" || \
        check_result 1 "监听地址配置错误"
    
    grep -q "cloudflare-dns.com\|dns.quad9.net" "$STUBBY_CONF" && \
        check_result 0 "上游 DNS 配置正常" || \
        warn_result "未检测到常见的上游 DNS"
fi

# =================================================================
# 4. Stubby 进程检查
# =================================================================
print_section "4. Stubby 进程状态检查"

# 检查进程
echo -e "  ${ARROW} Stubby 进程:"
if pgrep -x stubby >/dev/null; then
    local stubby_pid=$(pgrep -x stubby | head -1)
    check_result 0 "stubby 进程运行中 (PID: ${stubby_pid})"
    
    # 显示进程详情
    echo -e "    ${ARROW} 进程详情:"
    ps aux | grep "[s]tubby" | while IFS= read -r line; do
        echo -e "      ${CYAN}|${NC} ${line}"
    done
    
    # 检查 CPU/内存
    local cpu_mem=$(ps -p $stubby_pid -o %cpu,%mem --no-headers 2>/dev/null || echo "N/A")
    echo -e "    ${INFO} CPU/MEM: ${cpu_mem}"
else
    check_result 1 "stubby 进程未运行"
fi

# 检查端口监听
echo -e "  ${ARROW} 端口监听状态:"
if netstat -tunlp 2>/dev/null | grep -q ":53 " || ss -tunlp 2>/dev/null | grep -q ":53 "; then
    check_result 0 "53 端口已监听"
    
    # 显示端口详情
    echo -e "    ${ARROW} 端口详情:"
    if command -v netstat >/dev/null; then
        netstat -tunlp 2>/dev/null | grep ":53 " | while IFS= read -r line; do
            echo -e "      ${CYAN}|${NC} ${line}"
        done
    elif command -v ss >/dev/null; then
        ss -tunlp 2>/dev/null | grep ":53 " | while IFS= read -r line; do
            echo -e "      ${CYAN}|${NC} ${line}"
        done
    fi
    
    # 检查端口归属
    if ss -tunlp 2>/dev/null | grep ":53 " | grep -q "stubby"; then
        check_result 0 "53 端口由 stubby 监听"
    elif netstat -tunlp 2>/dev/null | grep ":53 " | grep -q "stubby"; then
        check_result 0 "53 端口由 stubby 监听"
    else
        warn_result "53 端口被其他进程占用"
    fi
else
    check_result 1 "53 端口未监听"
fi

# =================================================================
# 5. 守护进程检查
# =================================================================
print_section "5. DNS 守护进程检查 (dns-daemon)"

# 检查守护进程脚本
if [ -f "/usr/local/bin/dns_daemon.sh" ]; then
    check_result 0 "守护脚本存在"
    
    if [ -x "/usr/local/bin/dns_daemon.sh" ]; then
        check_result 0 "守护脚本有执行权限"
    else
        check_result 1 "守护脚本缺少执行权限"
    fi
else
    check_result 1 "守护脚本不存在"
fi

# 检查守护进程运行状态
echo -e "  ${ARROW} 守护进程运行状态:"
if pgrep -f "dns_daemon.sh" >/dev/null; then
    local daemon_pid=$(pgrep -f "dns_daemon.sh" | head -1)
    check_result 0 "守护进程运行中 (PID: ${daemon_pid})"
    
    # 显示进程信息
    ps aux | grep "[d]ns_daemon" | while IFS= read -r line; do
        echo -e "      ${CYAN}|${NC} ${line}"
    done
else
    check_result 1 "守护进程未运行"
fi

# 检查 systemd 服务
echo -e "  ${ARROW} Systemd 服务状态:"
if systemctl is-active dns-daemon >/dev/null 2>&1; then
    check_result 0 "dns-daemon 服务 active"
    echo -e "    ${INFO} $(systemctl status dns-daemon --no-pager -l | head -3 | tail -1)"
else
    warn_result "dns-daemon 服务未通过 systemd 管理"
    
    # 检查 OpenRC
    if rc-service dns-daemon status 2>/dev/null | grep -q "started"; then
        check_result 0 "dns-daemon (OpenRC) 已启动"
    fi
fi

# 检查守护进程日志
echo -e "  ${ARROW} 守护进程日志:"
if [ -f "$DAEMON_LOG" ]; then
    check_result 0 "日志文件存在"
    
    local log_size=$(wc -c < "$DAEMON_LOG" 2>/dev/null || echo 0)
    echo -e "    ${INFO} 日志大小: ${log_size} 字节"
    
    if [ $log_size -gt 0 ]; then
        echo -e "    ${ARROW} 最近 5 条日志:"
        tail -5 "$DAEMON_LOG" | while IFS= read -r line; do
            echo -e "      ${CYAN}|${NC} ${line}"
        done
        
        # 检查是否有错误
        local error_count=$(grep -c "失败\|error\|fail" "$DAEMON_LOG" 2>/dev/null || echo 0)
        if [ $error_count -gt 0 ]; then
            warn_result "日志中发现 ${error_count} 条错误/失败记录"
        fi
    fi
else
    warn_result "日志文件不存在 - 守护进程可能从未运行"
fi

# =================================================================
# 6. DNS 解析测试
# =================================================================
print_section "6. DNS 解析功能测试"

# 测试本地 DNS 解析
echo -e "  ${ARROW} 本地 DNS 解析测试:"

# 测试 1: 使用 127.0.0.1
echo -e "    ${INFO} 测试 1: 使用 127.0.0.1"
if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
    check_result 0 "google.com 解析成功 (127.0.0.1)"
    local result1=$(nslookup google.com 127.0.0.1 2>&1 | grep "Address:" | tail -1)
    echo -e "      ${CYAN}|${NC} ${result1}"
else
    check_result 1 "google.com 解析失败 (127.0.0.1)"
fi

# 测试 2: 使用 localhost
if nslookup cloudflare.com localhost >/dev/null 2>&1; then
    check_result 0 "cloudflare.com 解析成功 (localhost)"
else
    check_result 1 "cloudflare.com 解析失败 (localhost)"
fi

# 测试 3: 使用默认 DNS
echo -e "    ${INFO} 测试 3: 使用默认 DNS"
if nslookup github.com >/dev/null 2>&1; then
    check_result 0 "github.com 解析成功 (默认 DNS)"
else
    check_result 1 "github.com 解析失败 (默认 DNS)"
fi

# 测试 DoT 加密 (检查 853 端口是否真正工作)
echo -e "  ${ARROW} DoT 加密验证:"
if dig +tls google.com @1.1.1.1 2>/dev/null | grep -q "NOERROR"; then
    check_result 0 "DoT 加密查询成功 (直接到 1.1.1.1:853)"
else
    warn_result "DoT 加密查询未能验证 - 但不影响本地代理"
fi

# 解析速度测试
echo -e "  ${ARROW} DNS 响应时间测试:"
if command -v dig >/dev/null; then
    local dns_time=$(dig google.com @127.0.0.1 2>/dev/null | grep "Query time:" | awk '{print $4}')
    if [ -n "$dns_time" ]; then
        if [ $dns_time -lt 100 ]; then
            check_result 0 "响应时间: ${dns_time} ms (优秀)"
        elif [ $dns_time -lt 500 ]; then
            check_result 0 "响应时间: ${dns_time} ms (正常)"
        else
            warn_result "响应时间: ${dns_time} ms (较慢)"
        fi
    else
        warn_result "无法测量 DNS 响应时间"
    fi
fi

# =================================================================
# 7. 安全性检查
# =================================================================
print_section "7. DNS 安全性检查"

# DNS 泄露测试
echo -e "  ${ARROW} DNS 泄露快速检测:"
echo -e "    ${INFO} 测试源 IP 是否通过 Cloudflare/Google 解析"
local leak_test=$(nslookup whoami.akamai.net 127.0.0.1 2>&1 | grep "Address:" | tail -1 | awk '{print $2}')
if [ -n "$leak_test" ]; then
    echo -e "    ${INFO} EDNS 返回 IP: ${leak_test}"
    # 这里只是返回了 Akamai 看到的 IP，不是真正的泄露测试
    # 真正的泄露测试需要检查使用哪个 DNS 服务器
fi

# 检查是否还有其他 DNS 服务器
echo -e "  ${ARROW} 其他 DNS 服务检查:"
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    warn_result "systemd-resolved 仍在运行 - 可能导致冲突"
else
    check_result 0 "systemd-resolved 已禁用"
fi

# 检查 dnsmasq
if pgrep dnsmasq >/dev/null 2>&1; then
    warn_result "dnsmasq 进程运行中 - 可能导致冲突"
else
    check_result 0 "未检测到 dnsmasq 运行"
fi

# =================================================================
# 8. 代理集成检查
# =================================================================
print_section "8. 代理集成检查"

local proxy_found=false
for config in "/etc/xray/config.json" "/etc/sing-box/config.json" "/usr/local/etc/xray/config.json"; do
    if [ -f "$config" ]; then
        proxy_found=true
        echo -e "  ${ARROW} 检查: ${config}"
        if grep -q '"address":\s*"127.0.0.1"' "$config"; then
            check_result 0 "DNS 已指向 127.0.0.1"
        else
            warn_result "DNS 可能未指向本地"
        fi
    fi
done

if ! $proxy_found; then
    echo -e "  ${INFO} 未检测到代理配置 - 跳过"
fi

# =================================================================
# 9. 建议与修复
# =================================================================
print_section "9. 问题诊断与建议"

local issues=0

# 诊断 1: 53 端口未监听且 stubby 未运行
if ! pgrep -x stubby >/dev/null && ! netstat -tunlp 2>/dev/null | grep -q ":53 "; then
    ((issues++))
    echo -e "  ${FAIL} 问题 ${issues}: Stubby 未运行"
    echo -e "    ${ARROW} 修复: systemctl restart stubby 或 rc-service stubby restart"
    echo -e "    ${ARROW} 手动: stubby -C /etc/stubby/stubby.yml"
fi

# 诊断 2: resolv.conf 未指向 127.0.0.1
if ! grep -q "127.0.0.1" "$RESOLV_CONF" 2>/dev/null; then
    ((issues++))
    echo -e "  ${FAIL} 问题 ${issues}: resolv.conf 未配置 127.0.0.1"
    echo -e "    ${ARROW} 修复: echo -e 'nameserver 127.0.0.1\nnameserver ::1' > /etc/resolv.conf"
fi

# 诊断 3: 守护进程未运行
if ! pgrep -f "dns_daemon.sh" >/dev/null; then
    ((issues++))
    echo -e "  ${FAIL} 问题 ${issues}: 守护进程未运行"
    echo -e "    ${ARROW} 修复: systemctl restart dns-daemon"
    echo -e "    ${ARROW} 手动: nohup /usr/local/bin/dns_daemon.sh &"
fi

# 诊断 4: DNS 解析失败但服务正常
if pgrep -x stubby >/dev/null && ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
    ((issues++))
    echo -e "  ${FAIL} 问题 ${issues}: Stubby 运行但解析失败"
    echo -e "    ${ARROW} 检查: 防火墙是否放行 853 端口"
    echo -e "    ${ARROW} 测试: openssl s_client -connect 1.1.1.1:853"
fi

if [ $issues -eq 0 ]; then
    echo -e "  ${PASS} ${GREEN}未发现明显问题！系统运行正常。${NC}"
fi

# =================================================================
# 总结
# =================================================================
print_separator
echo -e "\n${WHITE}检查总结:${NC}"
echo -e "  ${GREEN}通过: ${PASS_COUNT}${NC}"
echo -e "  ${RED}失败: ${FAIL_COUNT}${NC}"
echo -e "  ${YELLOW}警告: ${WARN_COUNT}${NC}"

# 评级
local total=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
local pass_rate=0
if [ $total -gt 0 ]; then
    pass_rate=$((PASS_COUNT * 100 / total))
fi

echo -e "\n${WHITE}健康评级:${NC}"
if [ $FAIL_COUNT -eq 0 ] && [ $WARN_COUNT -eq 0 ]; then
    echo -e "  ${GREEN}★★★★★ 完美 - 所有检查通过${NC}"
elif [ $FAIL_COUNT -eq 0 ]; then
    echo -e "  ${YELLOW}★★★★☆ 良好 - 存在 ${WARN_COUNT} 个警告${NC}"
elif [ $FAIL_COUNT -le 2 ]; then
    echo -e "  ${RED}★★★☆☆ 需要注意 - ${FAIL_COUNT} 项失败${NC}"
else
    echo -e "  ${RED}★★☆☆☆ 异常 - ${FAIL_COUNT} 项失败，需要修复${NC}"
fi

# 快速修复命令
echo -e "\n${WHITE}快速修复:${NC}"
echo -e "  重启 Stubby:    ${CYAN}systemctl restart stubby${NC}"
echo -e "  重启守护进程:   ${CYAN}systemctl restart dns-daemon${NC}"
echo -e "  查看实时日志:   ${CYAN}tail -f ${DAEMON_LOG}${NC}"
echo -e "  手动测试 DNS:  ${CYAN}nslookup google.com 127.0.0.1${NC}"
echo -e "  完整重新部署:  ${CYAN}bash /path/to/secure-dns.sh${NC}"

print_separator
echo -e "\n${BLUE}检查完成！${NC}\n"

# 返回状态码
[ $FAIL_COUNT -eq 0 ] && exit 0 || exit 1
