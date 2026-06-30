#!/bin/sh
#==========================================================================
# DNS 源头指向有效性检测脚本 v1.1
#==========================================================================
set +e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass=0; fail=0; warn=0

check() {
    local desc="$1"; local cond="$2"
    if eval "$cond"; then
        printf "  %b✓%b %s\n" "$GREEN" "$NC" "$desc"; pass=$((pass+1))
    else
        printf "  %b✗%b %s\n" "$RED" "$NC" "$desc"; fail=$((fail+1))
    fi
}

check_warn() {
    local desc="$1"; local cond="$2"
    if eval "$cond"; then
        printf "  %b✓%b %s\n" "$GREEN" "$NC" "$desc"; pass=$((pass+1))
    else
        printf "  %b⚠%b %s (可能未安装)\n" "$YELLOW" "$NC" "$desc"; warn=$((warn+1))
    fi
}

echo ""
printf "%b========================================%b\n" "$BOLD" "$NC"
printf "%b  DNS 源头指向检测 v1.1%b\n" "$BOLD" "$NC"
printf "  时间: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "%b========================================%b\n" "$BOLD" "$NC"
echo ""

# 系统信息
if [ -f /etc/alpine-release ]; then OS="alpine"; else OS="debian"; fi
printf "系统: %b%s%b\n" "$CYAN" "$OS" "$NC"
echo ""

# ═══════════════════════════════════════
# 1. 模板文件检查
# ═══════════════════════════════════════
printf "%b1. DNS 模板文件%b\n" "$BOLD" "$NC"
TEMPLATE="/etc/smartdns/resolv.smartdns"
check "模板文件存在" "[ -f '$TEMPLATE' ]"
if [ -f "$TEMPLATE" ]; then
    DNS_LIST=$(grep "^nameserver" "$TEMPLATE" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    echo "    DNS 值: ${DNS_LIST}"
fi
echo ""

# ═══════════════════════════════════════
# 2. resolv.conf 检查
# ═══════════════════════════════════════
printf "%b2. /etc/resolv.conf%b\n" "$BOLD" "$NC"
check "resolv.conf 是普通文件" "[ ! -L /etc/resolv.conf ]"
check "指向 127.0.0.1 或 ::1" "grep -qE 'nameserver (127.0.0.1|::1)' /etc/resolv.conf 2>/dev/null"
echo ""

# ═══════════════════════════════════════
# 3. cloud-init 检查
# ═══════════════════════════════════════
printf "%b3. cloud-init%b\n" "$BOLD" "$NC"
if command -v cloud-init >/dev/null 2>&1; then
    CFG="/etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg"
    check "配置文件存在" "[ -f '$CFG' ]"
    check "manage-resolv-conf: true" "grep -q 'manage-resolv-conf: true' '$CFG' 2>/dev/null"
    check "nameservers 包含正确值" "grep -q 'nameservers:' '$CFG' 2>/dev/null"
else
    printf "  %b○%b cloud-init 未安装\n" "$YELLOW" "$NC"; warn=$((warn+1))
fi
echo ""

# ═══════════════════════════════════════
# 4. systemd-resolved 检查
# ═══════════════════════════════════════
printf "%b4. systemd-resolved%b\n" "$BOLD" "$NC"
if command -v resolvectl >/dev/null 2>&1; then
    CFG="/etc/systemd/resolved.conf.d/smartdns.conf"
    check "配置文件存在" "[ -f '$CFG' ]"
    check "DNS= 已设置" "grep -q 'DNS=' '$CFG' 2>/dev/null"
    check "DNSStubListener=no" "grep -q 'DNSStubListener=no' '$CFG' 2>/dev/null"
else
    printf "  %b○%b systemd-resolved 未安装\n" "$YELLOW" "$NC"; warn=$((warn+1))
fi
echo ""

# ═══════════════════════════════════════
# 5. dhclient 检查
# ═══════════════════════════════════════
printf "%b5. dhclient%b\n" "$BOLD" "$NC"
if [ -f /etc/dhcp/dhclient.conf ]; then
    check "supersede domain-name-servers 127.0.0.1" "grep -q 'supersede domain-name-servers 127.0.0.1' /etc/dhcp/dhclient.conf 2>/dev/null"
else
    printf "  %b○%b dhclient 未安装\n" "$YELLOW" "$NC"; warn=$((warn+1))
fi
echo ""

# ═══════════════════════════════════════
# 6. udhcpc 检查
# ═══════════════════════════════════════
printf "%b6. udhcpc%b\n" "$BOLD" "$NC"
if [ -f /etc/udhcpc/udhcpc.conf ]; then
    check "RESOLV_CONF=no" "grep -q 'RESOLV_CONF=\"no\"' /etc/udhcpc/udhcpc.conf 2>/dev/null"
else
    printf "  %b○%b udhcpc 未安装\n" "$YELLOW" "$NC"; warn=$((warn+1))
fi
echo ""

# ═══════════════════════════════════════
# 7. systemd-networkd 检查（修复 ls 通配符）
# ═══════════════════════════════════════
printf "%b7. systemd-networkd%b\n" "$BOLD" "$NC"
HAS_NETWORK_FILES=0
if [ -d /etc/systemd/network ]; then
    for f in /etc/systemd/network/*.network; do
        [ -f "$f" ] && HAS_NETWORK_FILES=1 && break
    done
fi
if [ $HAS_NETWORK_FILES -eq 1 ]; then
    FOUND=0
    for f in /etc/systemd/network/*.network; do
        [ -f "$f" ] || continue
        if grep -q "DNS=" "$f" 2>/dev/null; then FOUND=1; break; fi
    done
    if [ $FOUND -eq 1 ]; then
        check "至少一个 .network 含 DNS=" "true"
    else
        check "至少一个 .network 含 DNS=" "false"
    fi
else
    printf "  %b○%b systemd-networkd 未配置\n" "$YELLOW" "$NC"; warn=$((warn+1))
fi
echo ""

# ═══════════════════════════════════════
# 8. NetworkManager 检查（修复属性名）
# ═══════════════════════════════════════
printf "%b8. NetworkManager%b\n" "$BOLD" "$NC"
if command -v nmcli >/dev/null 2>&1; then
    CONN=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
    if [ -n "$CONN" ]; then
        # 兼容新旧版 nmcli
        DNS=$(nmcli con show "$CONN" 2>/dev/null | grep "ipv4.dns:" | awk '{print $2}')
        [ -z "$DNS" ] && DNS=$(nmcli -t -f IP4.DNS con show "$CONN" 2>/dev/null | head -1)
        if echo "$DNS" | grep -q "127.0.0.1\|::1" 2>/dev/null; then
            check "连接 '$CONN' DNS 指向 SmartDNS" "true"
        else
            check "连接 '$CONN' DNS 指向 SmartDNS" "false"
        fi
    else
        printf "  %b○%b 无活跃连接\n" "$YELLOW" "$NC"; warn=$((warn+1))
    fi
else
    printf "  %b○%b NetworkManager 未安装\n" "$YELLOW" "$NC"; warn=$((warn+1))
fi
echo ""

# ═══════════════════════════════════════
# 9. Alpine ifupdown 检查
# ═══════════════════════════════════════
printf "%b9. Alpine ifupdown%b\n" "$BOLD" "$NC"
if [ -f /etc/network/interfaces ] && grep -q "dns-nameservers" /etc/network/interfaces 2>/dev/null; then
    check "interfaces 含 dns-nameservers" "true"
else
    printf "  %b○%b ifupdown 无需修改或未配置\n" "$YELLOW" "$NC"; warn=$((warn+1))
fi
echo ""

# ═══════════════════════════════════════
# 10. 备份文件检查
# ═══════════════════════════════════════
printf "%b10. 卸载恢复备份%b\n" "$BOLD" "$NC"
check "原始 DNS 备份" "[ -f /etc/resolv.conf.smartdns.orig ]"
check "备份记录文件" "[ -f /etc/smartdns/dns-config-backup.txt ]"
echo ""

# ═══════════════════════════════════════
# 11. 启动覆盖检查
# ═══════════════════════════════════════
printf "%b11. 启动覆盖%b\n" "$BOLD" "$NC"
if [ -f /etc/local.d/resolv-fix.start ]; then
    check "Alpine local.d 脚本" "[ -x /etc/local.d/resolv-fix.start ]"
elif [ -f /etc/systemd/system/resolv-fix.service ]; then
    if systemctl is-enabled resolv-fix.service >/dev/null 2>&1; then
        check "systemd oneshot 服务" "true"
    else
        check "systemd oneshot 服务" "false"
    fi
else
    check "启动覆盖脚本存在" "false"
fi
echo ""

# ═══════════════════════════════════════
# 12. 守护检查
# ═══════════════════════════════════════
printf "%b12. DNS 守护%b\n" "$BOLD" "$NC"
check "守护脚本存在" "[ -f /usr/local/bin/resolv-guard.sh ]"
if pgrep -f resolv-guard >/dev/null 2>&1; then
    check "守护进程运行中" "true"
else
    check "守护进程运行中" "false"
fi
echo ""

# ═══════════════════════════════════════
# 13. SmartDNS 运行状态
# ═══════════════════════════════════════
printf "%b13. SmartDNS 运行状态%b\n" "$BOLD" "$NC"
check "SmartDNS 进程运行中" "pgrep smartdns >/dev/null 2>&1"
echo ""

# ═══════════════════════════════════════
# 14. DNS 解析实际测试
# ═══════════════════════════════════════
printf "%b14. DNS 解析测试%b\n" "$BOLD" "$NC"
for domain in google.com cloudflare.com; do
    RESULT=$(nslookup "$domain" 127.0.0.1 2>&1)
    if echo "$RESULT" | grep -q "Address"; then
        IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
        printf "  %b✓%b %s → %s\n" "$GREEN" "$NC" "$domain" "$IP"; pass=$((pass+1))
    else
        printf "  %b✗%b %s 解析失败\n" "$RED" "$NC" "$domain"; fail=$((fail+1))
    fi
done
echo ""

# ═══════════════════════════════════════
# 汇总
# ═══════════════════════════════════════
total=$((pass + fail + warn))
printf "%b========================================%b\n" "$BOLD" "$NC"
printf "%b  检测完成%b\n" "$BOLD" "$NC"
printf "%b========================================%b\n" "$BOLD" "$NC"
printf "  通过: %b%s%b\n" "$GREEN" "$pass" "$NC"
printf "  失败: %b%s%b\n" "$RED" "$fail" "$NC"
printf "  跳过: %b%s%b\n" "$YELLOW" "$warn" "$NC"
printf "  总计: %s\n" "$total"
echo ""

if [ $fail -eq 0 ]; then
    printf "  %b✓ 所有配置正确，DNS 源头指向生效%b\n" "$GREEN" "$NC"
else
    printf "  %b✗ 发现 %s 处问题，请检查%b\n" "$RED" "$fail" "$NC"
fi
echo ""
