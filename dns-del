#!/bin/sh
#==================================================
# SmartDNS 综合卸载脚本 v2.1
# 兼容: smart_dns.sh / smartdns.sh v4.5 / v4.6 / v5.x
#==================================================

echo ""
echo "========================================"
echo "  SmartDNS 综合卸载 + 系统还原"
echo "========================================"
echo ""

#==================================================
# 1. 检测系统环境
#==================================================
if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
    INIT="systemd"
elif [ -f /sbin/openrc ]; then
    INIT="openrc"
else
    INIT="none"
fi

if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ]; then
    OS="debian"
else
    OS="unknown"
fi

echo "[INFO] 系统: $OS | Init: $INIT"

#==================================================
# 2. 停止所有相关进程
#==================================================
echo "[INFO] 停止进程..."

# 停止 smartdns（只杀进程名，不用 -f 避免自杀）
pkill smartdns 2>/dev/null
killall smartdns 2>/dev/null
pidof smartdns | xargs kill 2>/dev/null

# 停止 v5.x inotify 守护
pkill -f resolv-guard.sh 2>/dev/null
killall resolv-guard.sh 2>/dev/null

sleep 1
echo "[OK] 进程已停止"

#==================================================
# 3. 清理系统服务
#==================================================
echo "[INFO] 清理服务..."

case "$INIT" in
    systemd)
        systemctl stop smartdns 2>/dev/null
        systemctl disable smartdns 2>/dev/null
        rm -f /etc/systemd/system/smartdns.service /lib/systemd/system/smartdns.service
        
        systemctl stop resolv-guard 2>/dev/null
        systemctl disable resolv-guard 2>/dev/null
        rm -f /etc/systemd/system/resolv-guard.service
        rm -rf /etc/systemd/system/resolv-guard.service.d /etc/systemd/system/smartdns.service.d
        
        systemctl stop smart-dns 2>/dev/null
        systemctl disable smart-dns 2>/dev/null
        rm -f /etc/systemd/system/smart-dns.service
        
        systemctl daemon-reload 2>/dev/null
        echo "[OK] systemd 服务已清理"
        ;;
    openrc)
        rc-service smartdns stop 2>/dev/null
        rc-update del smartdns 2>/dev/null
        rm -f /etc/init.d/smartdns
        
        rc-service resolv-guard stop 2>/dev/null
        rc-update del resolv-guard 2>/dev/null
        rm -f /etc/init.d/resolv-guard
        
        rc-service smart-dns stop 2>/dev/null
        rc-update del smart-dns 2>/dev/null
        rm -f /etc/init.d/smart-dns
        
        rm -f /etc/local.d/smartdns-fix.start /etc/local.d/smart-dns-fix.start
        
        echo "[OK] OpenRC 服务已清理"
        ;;
esac

#==================================================
# 4. 清理 crontab
#==================================================
echo "[INFO] 清理 crontab..."

CLEANED=false
if crontab -l 2>/dev/null | grep -qE "resolv-check|@reboot.*dns"; then
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null | grep -vE "resolv-check|@reboot.*dns" > "$TMP_CRON"
    if [ -s "$TMP_CRON" ]; then
        crontab "$TMP_CRON" 2>/dev/null
    else
        crontab -r 2>/dev/null
    fi
    rm -f "$TMP_CRON"
    CLEANED=true
fi

[ "$CLEANED" = true ] && echo "[OK] crontab 已清理" || echo "[INFO] 无相关 crontab"

#==================================================
# 5. 清理 iptables 规则
#==================================================
echo "[INFO] 清理 iptables..."

PORT=53
if [ -f /etc/smartdns/smartdns.conf ]; then
    PORT=$(awk '/^bind/{for(i=1;i<=NF;i++) if($i~/:([0-9]+)/){split($i,a,":"); print a[length(a)]; exit}}' /etc/smartdns/smartdns.conf 2>/dev/null)
    [ -z "$PORT" ] && PORT=53
fi

for proto in udp tcp; do
    iptables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" -m comment --comment "SmartDNS-redirect" 2>/dev/null
    iptables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null
    iptables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port 5353 2>/dev/null
    iptables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port 5354 2>/dev/null
    iptables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port 5355 2>/dev/null
    
    ip6tables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" -m comment --comment "SmartDNS-redirect" 2>/dev/null 2>&1
    ip6tables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null 2>&1
    ip6tables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port 5353 2>/dev/null 2>&1
done

# 保存（加超时防止卡死）
if [ -f /etc/alpine-release ]; then
    timeout 3 iptables-save > /etc/iptables/rules-save 2>/dev/null || true
else
    timeout 3 iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

echo "[OK] iptables 已清理"

#==================================================
# 6. 恢复 resolv.conf
#==================================================
echo "[INFO] 恢复 DNS..."

chattr -i /etc/resolv.conf 2>/dev/null
RESTORED=false

for f in $(ls -t /etc/resolv.conf.bak.* 2>/dev/null); do
    if [ -f "$f" ] && ! grep -q "127.0.0.1" "$f" 2>/dev/null; then
        cp "$f" /etc/resolv.conf
        echo "[OK] 已恢复原始配置: $f"
        RESTORED=true
        break
    fi
done

if [ "$RESTORED" = false ] && [ "$INIT" = "systemd" ]; then
    if systemctl is-enabled systemd-resolved 2>/dev/null | grep -q "masked"; then
        echo "[INFO] 恢复 systemd-resolved..."
        systemctl unmask systemd-resolved 2>/dev/null
        systemctl enable systemd-resolved 2>/dev/null
        systemctl start systemd-resolved 2>/dev/null
        sleep 1
        [ -L /run/systemd/resolve/stub-resolv.conf ] && ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf && RESTORED=true
        echo "[OK] 已恢复 systemd-resolved"
    fi
fi

if [ "$RESTORED" = false ]; then
    cat > /etc/resolv.conf << 'INNER'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
INNER
    echo "[OK] 已设置公网 DNS"
fi

#==================================================
# 7. 清理 DHCP 配置
#==================================================
echo "[INFO] 清理 DHCP 配置..."

if [ -f /etc/dhcpcd.conf ]; then
    sed -i '/nohook resolv.conf/d; /SmartDNS/d; /smart.dns/d' /etc/dhcpcd.conf 2>/dev/null
fi

rm -f /etc/udhcpc/udhcpc.conf

echo "[OK] DHCP 配置已清理"

#==================================================
# 8. 清理文件
#==================================================
echo "[INFO] 清理文件..."

rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
rm -f /usr/bin/smart-dns /usr/sbin/smart-dns /usr/local/bin/smart-dns
rm -rf /etc/smartdns /etc/smart-dns
rm -f /usr/local/bin/resolv-check.sh /usr/local/bin/resolv-guard.sh
rm -f /etc/resolv.conf.smartdns.bak /etc/resolv.conf.smart-dns.bak
rm -f /etc/resolv.conf.link.bak /etc/resolv.conf.bak.pre-install
rm -f /var/log/smartdns.log* /var/log/smart-dns.log*
rm -f /var/log/resolv-guard.log* /var/log/resolv-check.log*
rm -f /var/log/smartdns-install.log
rm -f /tmp/smartdns-deploy.lock /tmp/smart-dns.lock
rmdir /tmp/smartdns-deploy.lock.dir 2>/dev/null

apt-get remove -y smartdns 2>/dev/null
apt-get remove -y smart-dns 2>/dev/null
apk del smartdns 2>/dev/null
apk del smart-dns 2>/dev/null

echo "[OK] 文件已清理"

#==================================================
# 9. 完成
#==================================================
echo ""
echo "========================================"
echo "  卸载完成！当前 DNS 配置:"
echo "========================================"
cat /etc/resolv.conf 2>/dev/null || echo "(无 /etc/resolv.conf)"
echo ""
echo "如需重启网络:"
[ "$INIT" = "systemd" ] && echo "  systemctl restart networking"
[ "$INIT" = "openrc" ] && echo "  rc-service networking restart"
echo ""
