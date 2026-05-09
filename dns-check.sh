#!/bin/bash

# =================================================================
# DNS 一键检测脚本 v3.0 (修复版)
# 修复: local 变量作用域问题、空值判断、兼容性
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 符号
PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"

# 配置路径
RESOLV_CONF="/etc/resolv.conf"
STUBBY_CONF="/etc/stubby/stubby.yml"
LOG_DIR="/var/log/secure-dns"
DAEMON_LOG="${LOG_DIR}/daemon.log"
SHA_FILE="/etc/stubby/stubby.yml.sha256"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"

# 统计变量（全局）
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
IS_CONTAINER=false

print_separator() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

print_section() {
    echo -e "\n${PURPLE}▧${NC} ${WHITE}${1}${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
}

check_result() {
    local status=$1
    local message=$2
    
    if [ $status -eq 0 ]; then
        echo -e "  ${PASS} ${message}"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        echo -e "  ${FAIL} ${message}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

warn_result() {
    local message=$1
    echo -e "  ${WARN} ${message}"
    WARN_COUNT=$((WARN_COUNT + 1))
}

# 安全获取文件权限
get_file_perms() {
    local file="$1"
    if [ -f "$file" ]; then
        if stat -c "%a %U:%G" "$file" 2>/dev/null; then
            :
        elif stat -f "%p %u:%g" "$file" 2>/dev/null; then
            :
        else
            echo "unknown"
        fi
    fi
}

# 主标题
clear
echo -e "${BLUE}"
cat << "BANNER"
╔══════════════════════════════════════════════════════════════╗
║     DNS 加密解析系统 (Secure-DNS) 健康检查工具 v3.0        ║
║     Secure DNS Health Check Tool (Bug Fixed)                ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
echo -e "检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "主机名: $(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)"
echo -e "系统版本: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Unknown')"
echo -e "内核版本: $(uname -r)"

# =================================================================
# 1. 环境检测
# =================================================================
print_section "1. 系统环境检测"

# 检测容器环境
echo -e "  → 运行环境检查:"
if [ -f /.dockerenv ]; then
    echo -e "    ${WARN} Docker 容器环境"
    IS_CONTAINER=true
elif grep -qE 'docker|lxc|kubepods' /proc/1/cgroup 2>/dev/null; then
    echo -e "    ${WARN} 容器环境 (LXC/Docker/K8s)"
    IS_CONTAINER=true
else
    echo -e "    ${PASS} 物理机/虚拟机环境"
    IS_CONTAINER=false
fi

# 检查网络连通性
echo -e "  → 网络连通性:"
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    check_result 0 "外网连通性正常 (1.1.1.1)"
else
    check_result 1 "外网连通性异常 - 可能无法连接上游 DNS"
fi

# 检查 853 端口
echo -e "  → DoT 端口连通性:"
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
    REAL_RESOLV=$(readlink -f "$RESOLV_CONF")
    warn_result "resolv.conf 是符号链接 → ${REAL_RESOLV}"
    echo -e "    ${INFO} 实际文件路径: ${REAL_RESOLV}"
else
    echo -e "    ${PASS} resolv.conf 是普通文件"
    REAL_RESOLV="$RESOLV_CONF"
fi

# 检查文件权限
echo -e "  → 文件权限:"
if [ -f "$REAL_RESOLV" ]; then
    perms=$(get_file_perms "$REAL_RESOLV")
    echo -e "    ${INFO} 权限: ${perms}"
    
    # 检查不可变属性
    if lsattr "$REAL_RESOLV" 2>/dev/null | grep -q 'i'; then
        echo -e "    ${PASS} 文件已设置不可变属性 (chattr +i)"
    else
        if [ "$IS_CONTAINER" = true ]; then
            warn_result "文件未设置不可变属性 (容器中属于正常)"
        else
            warn_result "文件未设置不可变属性 - 可能被 DHCP 覆盖"
        fi
    fi
fi

# 检查 DNS 配置内容
echo -e "  → DNS 配置内容:"
if [ -f "$REAL_RESOLV" ] && [ -r "$REAL_RESOLV" ]; then
    first_line=$(head -n 1 "$REAL_RESOLV" 2>/dev/null)
    echo -e "    ${INFO} 首行: ${first_line}"
    
    if echo "$first_line" | grep -q "127.0.0.1"; then
        check_result 0 "DNS 已正确配置为 127.0.0.1"
    else
        check_result 1 "DNS 未指向 127.0.0.1 - 可能未被接管"
    fi
    
    # 显示完整配置
    echo -e "    → 完整配置:"
    cat "$REAL_RESOLV" | while IFS= read -r line; do
        if [ -n "$line" ]; then
            echo -e "      ${CYAN}|${NC} ${line}"
        fi
    done
elif [ -f "$REAL_RESOLV" ]; then
    check_result 1 "resolv.conf 不可读"
fi

# =================================================================
# 3. Stubby 配置检查
# =================================================================
print_section "3. Stubby DoT 服务检查"

# 检查配置文件
if [ -f "$STUBBY_CONF" ]; then
    check_result 0 "Stubby 配置文件存在"
    
    # 配置文件大小
    conf_size=$(wc -c < "$STUBBY_CONF" 2>/dev/null)
    if [ -n "$conf_size" ]; then
        echo -e "    ${INFO} 配置文件大小: ${conf_size} 字节"
    else
        echo -e "    ${WARN} 配置文件为空"
    fi
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
if [ -f "$SHA_FILE" ] && [ -f "$STUBBY_CONF" ]; then
    echo -e "  → 配置完整性校验:"
    if sha256sum -c "$SHA_FILE" >/dev/null 2>&1; then
        check_result 0 "配置文件校验和一致 (未篡改)"
        echo -e "    $(cat $SHA_FILE 2>/dev/null)"
    else
        check_result 1 "配置文件校验和不一致 (可能被篡改)"
        current_hash=$(sha256sum "$STUBBY_CONF" 2>/dev/null | cut -d' ' -f1)
        backup_hash=$(cut -d' ' -f1 "$SHA_FILE" 2>/dev/null)
        echo -e "    ${INFO} 当前哈希: ${current_hash}"
        echo -e "    ${INFO} 备份哈希: ${backup_hash}"
    fi
fi

# 检查配置内容
if [ -f "$STUBBY_CONF" ] && [ -r "$STUBBY_CONF" ]; then
    echo -e "  → 关键配置检查:"
    
    if grep -q "GETDNS_TRANSPORT_TLS" "$STUBBY_CONF"; then
        check_result 0 "加密传输已启用 (TLS)"
    else
        check_result 1 "加密传输未配置"
    fi
    
    if grep -q "127.0.0.1@53" "$STUBBY_CONF"; then
        check_result 0 "监听地址正确 (127.0.0.1:53)"
    else
        check_result 1 "监听地址配置错误"
    fi
    
    if grep -qE "cloudflare-dns\.com|dns\.quad9\.net|dns\.google" "$STUBBY_CONF"; then
        check_result 0 "上游 DNS 配置正常"
    else
        warn_result "未检测到常见的上游 DNS"
    fi
fi

# =================================================================
# 4. Stubby 进程检查
# =================================================================
print_section "4. Stubby 进程状态检查"

# 检查进程
echo -e "  → Stubby 进程:"
stubby_pid=$(pgrep -x stubby 2>/dev/null | head -1)
if [ -n "$stubby_pid" ]; then
    check_result 0 "stubby 进程运行中 (PID: ${stubby_pid})"
    
    # 显示进程详情
    echo -e "    → 进程详情:"
    ps aux 2>/dev/null | grep "[s]tubby" | while IFS= read -r line; do
        echo -e "      ${CYAN}|${NC} ${line}"
    done
    
    # 检查 CPU/内存
    cpu_mem=$(ps -p "$stubby_pid" -o %cpu,%mem --no-headers 2>/dev/null | tr -s ' ')
    if [ -n "$cpu_mem" ]; then
        echo -e "    ${INFO} CPU/MEM: ${cpu_mem}"
    fi
else
    check_result 1 "stubby 进程未运行"
fi

# 检查端口监听
echo -e "  → 端口监听状态:"
port_listening=false
port_detail=""

# 尝试多种方式检查端口
if command -v netstat >/dev/null 2>&1; then
    port_detail=$(netstat -tunlp 2>/dev/null | grep ":53 ")
elif command -v ss >/dev/null 2>&1; then
    port_detail=$(ss -tunlp 2>/dev/null | grep ":53 ")
fi

if [ -n "$port_detail" ]; then
    check_result 0 "53 端口已监听"
    
    # 显示端口详情
    echo -e "    → 端口详情:"
    echo "$port_detail" | while IFS= read -r line; do
        echo -e "      ${CYAN}|${NC} ${line}"
    done
    
    # 检查端口归属
    if echo "$port_detail" | grep -q "stubby"; then
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

# 检查守护脚本
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
echo -e "  → 守护进程运行状态:"
daemon_pid=$(pgrep -f "dns_daemon.sh" 2>/dev/null | head -1)
if [ -n "$daemon_pid" ]; then
    check_result 0 "守护进程运行中 (PID: ${daemon_pid})"
    
    # 显示进程信息
    ps aux 2>/dev/null | grep "[d]ns_daemon" | while IFS= read -r line; do
        echo -e "      ${CYAN}|${NC} ${line}"
    done
else
    check_result 1 "守护进程未运行"
fi

# 检查服务管理器
echo -e "  → 服务管理状态:"
service_managed=false

# Systemd
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active dns-daemon >/dev/null 2>&1; then
        check_result 0 "dns-daemon 服务 active (systemd)"
        service_status=$(systemctl status dns-daemon --no-pager -l 2>&1 | head -3 | tail -1)
        echo -e "    ${INFO} ${service_status}"
        service_managed=true
    elif systemctl is-enabled dns-daemon >/dev/null 2>&1; then
        warn_result "dns-daemon 服务已启用但未运行 (systemd)"
        service_managed=true
    fi
fi

# OpenRC
if command -v rc-service >/dev/null 2>&1; then
    if rc-service dns-daemon status 2>/dev/null | grep -q "started"; then
        if [ "$service_managed" = false ]; then
            check_result 0 "dns-daemon (OpenRC) 已启动"
        fi
        service_managed=true
    fi
fi

if [ "$service_managed" = false ]; then
    warn_result "dns-daemon 未通过任何服务管理器管理"
fi

# 检查守护进程日志
echo -e "  → 守护进程日志:"
if [ -f "$DAEMON_LOG" ]; then
    check_result 0 "日志文件存在"
    
    log_size=$(wc -c < "$DAEMON_LOG" 2>/dev/null)
    if [ -n "$log_size" ] && [ "$log_size" -gt 0 ]; then
        echo -e "    ${INFO} 日志大小: ${log_size} 字节"
        
        echo -e "    → 最近 5 条日志:"
        tail -5 "$DAEMON_LOG" 2>/dev/null | while IFS= read -r line; do
            echo -e "      ${CYAN}|${NC} ${line}"
        done
        
        # 检查错误（大小写不敏感）
        error_count=$(grep -ciE "失败|error|fail" "$DAEMON_LOG" 2>/dev/null)
        if [ -n "$error_count" ] && [ "$error_count" -gt 0 ]; then
            warn_result "日志中发现 ${error_count} 条错误/失败记录"
        else
            check_result 0 "日志中未见错误"
        fi
    else
        echo -e "    ${WARN} 日志文件为空 (0 字节)"
    fi
else
    warn_result "日志文件不存在 - 守护进程可能从未运行"
fi

# =================================================================
# 6. DNS 解析测试
# =================================================================
print_section "6. DNS 解析功能测试"

echo -e "  → 本地 DNS 解析测试:"

# 测试 1: 127.0.0.1
echo -e "    ${INFO} 测试 1: 使用 127.0.0.1"
if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
    check_result 0 "google.com 解析成功 (127.0.0.1)"
    result1=$(nslookup google.com 127.0.0.1 2>&1 | grep "Address:" | tail -1 | sed 's/Address:\s*//')
    if [ -n "$result1" ]; then
        echo -e "      ${CYAN}|${NC} ${result1}"
    fi
else
    check_result 1 "google.com 解析失败 (127.0.0.1)"
fi

# 测试 2: localhost
if nslookup cloudflare.com localhost >/dev/null 2>&1; then
    check_result 0 "cloudflare.com 解析成功 (localhost)"
else
    check_result 1 "cloudflare.com 解析失败 (localhost)"
fi

# 测试 3: 默认 DNS
echo -e "    ${INFO} 测试 3: 使用默认 DNS"
if nslookup github.com >/dev/null 2>&1; then
    check_result 0 "github.com 解析成功 (默认 DNS)"
else
    check_result 1 "github.com 解析失败 (默认 DNS)"
fi

# DoT 加密验证
echo -e "  → DoT 加密验证:"
if command -v dig >/dev/null 2>&1; then
    dot_result=$(dig +tls google.com @1.1.1.1 2>&1)
    if echo "$dot_result" | grep -q "NOERROR"; then
        check_result 0 "DoT 加密查询成功 (1.1.1.1:853)"
    else
        warn_result "DoT 加密查询失败 - 可能 853 端口被拦截"
    fi
else
    warn_result "缺少 dig 工具 - 跳过 DoT 验证"
fi

# DNS 响应时间测试
echo -e "  → DNS 响应时间:"
if command -v dig >/dev/null 2>&1; then
    dns_time=$(dig google.com @127.0.0.1 2>/dev/null | grep "Query time:" | awk '{print $4}')
    if [ -n "$dns_time" ]; then
        if [ "$dns_time" -lt 100 ]; then
            check_result 0 "响应时间: ${dns_time} ms (优秀)"
        elif [ "$dns_time" -lt 500 ]; then
            check_result 0 "响应时间: ${dns_time} ms (正常)"
        else
            warn_result "响应时间: ${dns_time} ms (较慢)"
        fi
    else
        warn_result "无法测量 DNS 响应时间"
    fi
else
    warn_result "缺少 dig 工具 - 跳过性能测试"
fi

# =================================================================
# 7. 安全性检查
# =================================================================
print_section "7. DNS 安全性检查"

# DNS 泄露测试
echo -e "  → DNS 泄露快速检测:"
echo -e "    ${INFO} 查询 whoami.akamai.net 检查出口 IP"
leak_result=$(nslookup whoami.akamai.net 127.0.0.1 2>&1 | grep "Address:" | tail -1)
if [ -n "$leak_result" ]; then
    echo -e "    ${INFO} ${leak_result}"
else
    warn_result "泄露检测查询失败"
fi

# 检查其他 DNS 服务
echo -e "  → 其他 DNS 服务检查:"

# systemd-resolved
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        warn_result "systemd-resolved 仍在运行 - 可能导致冲突"
    else
        check_result 0 "systemd-resolved 已禁用"
    fi
fi

# dnsmasq
if pgrep dnsmasq >/dev/null 2>&1; then
    warn_result "dnsmasq 进程运行中 - 可能导致冲突"
else
    check_result 0 "未检测到 dnsmasq 运行"
fi

# 检查 53 端口是否有多个监听
echo -e "  → 53 端口独占检查:"
port_count=$(ss -tunlp 2>/dev/null | grep -c ":53 ")
if [ "$port_count" -gt 0 ]; then
    if [ "$port_count" -eq 1 ]; then
        check_result 0 "53 端口由单一服务独占"
    else
        warn_result "53 端口有 ${port_count} 个监听 - 可能存在冲突"
    fi
else
    check_result 1 "53 端口无监听"
fi

# =================================================================
# 8. 代理集成检查
# =================================================================
print_section "8. 代理集成检查"

proxy_found=false
proxy_configs=(
    "/etc/xray/config.json"
    "/etc/sing-box/config.json"
    "/usr/local/etc/xray/config.json"
)

for config in "${proxy_configs[@]}"; do
    if [ -f "$config" ]; then
        proxy_found=true
        echo -e "  → 检查: ${config}"
        if grep -q '"address":\s*"127.0.0.1"' "$config" 2>/dev/null; then
            check_result 0 "DNS 已指向本地 Stubby (127.0.0.1)"
        else
            warn_result "DNS 可能未指向本地代理"
        fi
    fi
done

if [ "$proxy_found" = false ]; then
    echo -e "  ${INFO} 未检测到代理配置 - 跳过"
fi

# =================================================================
# 9. 问题诊断与修复建议
# =================================================================
print_section "9. 问题诊断与修复建议"

issues_found=0

# 诊断 1: Stubby 未运行但配置存在
if [ -z "$stubby_pid" ] && [ -f "$STUBBY_CONF" ]; then
    issues_found=$((issues_found + 1))
    echo -e "  ${FAIL} 问题 ${issues_found}: Stubby 服务未运行"
    echo -e "    → 修复:"
    echo -e "      systemctl restart stubby"
    echo -e "      rc-service stubby restart"
    echo -e "      stubby -C /etc/stubby/stubby.yml &"
fi

# 诊断 2: DNS 未指向 127.0.0.1
if [ -f "$REAL_RESOLV" ]; then
    if ! grep -q "127.0.0.1" "$REAL_RESOLV" 2>/dev/null; then
        issues_found=$((issues_found + 1))
        echo -e "  ${FAIL} 问题 ${issues_found}: resolv.conf 未指向 127.0.0.1"
        echo -e "    → 修复: echo -e 'nameserver 127.0.0.1\nnameserver ::1' > /etc/resolv.conf"
    fi
fi

# 诊断 3: 守护进程未运行
if [ -z "$daemon_pid" ]; then
    issues_found=$((issues_found + 1))
    echo -e "  ${FAIL} 问题 ${issues_found}: DNS 守护进程未运行"
    echo -e "    → 修复:"
    echo -e "      systemctl restart dns-daemon"
    echo -e "      nohup /usr/local/bin/dns_daemon.sh &"
fi

# 诊断 4: Stubby 运行但 DNS 解析失败
if [ -n "$stubby_pid" ]; then
    if ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        issues_found=$((issues_found + 1))
        echo -e "  ${FAIL} 问题 ${issues_found}: Stubby 运行但解析失败"
        echo -e "    → 检查: 防火墙是否放行 853 端口"
        echo -e "    → 测试: openssl s_client -connect 1.1.1.1:853"
        echo -e "    → 日志: journalctl -u stubby -f"
    fi
fi

# 诊断 5: 数据库空间
daemon_log_size=$(wc -c < "$DAEMON_LOG" 2>/dev/null || echo 0)
if [ "$daemon_log_size" -gt 10485760 ]; then  # 10MB
    issues_found=$((issues_found + 1))
    echo -e "  ${WARN} 问题 ${issues_found}: 守护进程日志过大 (${daemon_log_size} 字节)"
    echo -e "    → 清理: > ${DAEMON_LOG}"
fi

if [ $issues_found -eq 0 ]; then
    echo -e "  ${PASS} ${GREEN}未发现明显问题！系统运行正常。${NC}"
else
    echo -e "  ${INFO} 共发现 ${issues_found} 个问题需要处理"
fi

# =================================================================
# 总结
# =================================================================
print_separator
echo -e "\n${WHITE}检查总结:${NC}"
echo -e "  ${GREEN}通过: ${PASS_COUNT}${NC}"
echo -e "  ${RED}失败: ${FAIL_COUNT}${NC}"
echo -e "  ${YELLOW}警告: ${WARN_COUNT}${NC}"

# 健康评级
total_checks=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
if [ $total_checks -gt 0 ]; then
    pass_rate=$((PASS_COUNT * 100 / total_checks))
else
    pass_rate=0
fi

echo -e "\n${WHITE}健康评级:${NC}"
if [ $FAIL_COUNT -eq 0 ] && [ $WARN_COUNT -eq 0 ]; then
    echo -e "  ${GREEN}★★★★★ 完美 - 所有检查通过${NC}"
elif [ $FAIL_COUNT -eq 0 ]; then
    echo -e "  ${YELLOW}★★★★☆ 良好 - ${WARN_COUNT} 个警告${NC}"
elif [ $FAIL_COUNT -le 2 ]; then
    echo -e "  ${RED}★★★☆☆ 需要注意 - ${FAIL_COUNT} 项失败${NC}"
else
    echo -e "  ${RED}★★☆☆☆ 异常 - ${FAIL_COUNT} 项失败，需要修复${NC}"
fi

echo -e "\n${WHITE}快速修复命令:${NC}"
echo -e "  重启 Stubby:    ${CYAN}systemctl restart stubby${NC}"
echo -e "  重启守护进程:   ${CYAN}systemctl restart dns-daemon${NC}"
echo -e "  查看实时日志:   ${CYAN}tail -f ${DAEMON_LOG}${NC}"
echo -e "  手动测试 DNS:  ${CYAN}nslookup google.com 127.0.0.1${NC}"
echo -e "  Stubby 日志:    ${CYAN}journalctl -u stubby -f${NC}"

print_separator
echo -e "\n${BLUE}检查完成！${NC}\n"

# 返回状态码
[ $FAIL_COUNT -eq 0 ] && exit 0 || exit 1
