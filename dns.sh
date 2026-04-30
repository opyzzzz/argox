#!/bin/sh

# 严格模式
set -e

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "错误: 必须使用 root 用户运行此脚本！"
    exit 1
fi

echo "正在增强 DNS 设置并锁定防止 DHCP 修改..."
echo "目标系统: Debian/Alpine 基础系统"
echo ""

# DNS 服务器配置
DNS1_IPV4="8.8.8.8"
DNS2_IPV4="1.1.1.1"
DNS1_IPV6="2001:4860:4860::8888"
DNS2_IPV6="2001:4860:4860::8844"

# 检测系统类型
detect_system() {
    if [ -f /etc/alpine-release ]; then
        SYSTEM="alpine"
    elif [ -f /etc/debian_version ]; then
        SYSTEM="debian"
    else
        SYSTEM="unknown"
    fi
    echo "检测到系统: $SYSTEM"
}

# 创建标准 resolv.conf
create_resolv_conf() {
    cat > /etc/resolv.conf << EOF
# DNS Configuration - Locked
# This file is protected from modification
nameserver $DNS1_IPV4
nameserver $DNS2_IPV4
nameserver $DNS1_IPV6
nameserver $DNS2_IPV6
EOF
    echo "已创建 /etc/resolv.conf"
}

# 1. Debian 系统处理
setup_debian() {
    echo "配置 Debian 系统..."
    
    # 1.1 禁用 resolvconf 服务（如果存在）
    if [ -f /etc/init.d/resolvconf ] || [ -f /lib/systemd/system/resolvconf.service ]; then
        echo "发现 resolvconf 服务，正在禁用..."
        systemctl disable resolvconf 2>/dev/null || update-rc.d resolvconf disable 2>/dev/null || true
        systemctl stop resolvconf 2>/dev/null || service resolvconf stop 2>/dev/null || true
    fi
    
    # 1.2 处理 NetworkManager
    if [ -f /etc/NetworkManager/NetworkManager.conf ] || [ -d /etc/NetworkManager/conf.d ]; then
        echo "配置 NetworkManager..."
        mkdir -p /etc/NetworkManager/conf.d
        
        # 创建 DNS 锁定配置
        cat > /etc/NetworkManager/conf.d/90-dns-none.conf << EOF
[main]
dns=none
EOF
        echo "已设置 NetworkManager dns=none"
        
        # 重启 NetworkManager（如果正在运行）
        if pgrep NetworkManager >/dev/null 2>&1; then
            systemctl restart NetworkManager 2>/dev/null || service network-manager restart 2>/dev/null || true
        fi
    fi
    
    # 1.3 处理 systemd-resolved
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo "处理 systemd-resolved..."
        
        # 禁用 DNS 存根解析器
        if [ -f /etc/systemd/resolved.conf ]; then
            # 备份原配置
            cp -f /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup 2>/dev/null || true
            
            # 配置 resolved
            cat > /etc/systemd/resolved.conf << EOF
[Resolve]
DNS=$DNS1_IPV4 $DNS2_IPV4 $DNS1_IPV6 $DNS2_IPV6
FallbackDNS=8.8.4.4 1.0.0.1
DNSStubListener=no
LLMNR=no
MulticastDNS=no
DNSSEC=no
DNSOverTLS=no
Cache=no
EOF
            
            # 如果 /etc/resolv.conf 是符号链接，改为实际文件
            if [ -L /etc/resolv.conf ]; then
                echo "移除符号链接 /etc/resolv.conf"
                rm -f /etc/resolv.conf
            fi
            
            # 重启 resolved
            systemctl restart systemd-resolved 2>/dev/null || true
        fi
    fi
    
    # 1.4 处理 dhclient (ISC DHCP Client)
    if command -v dhclient >/dev/null 2>&1 || [ -f /etc/dhcp/dhclient.conf ]; then
        echo "配置 dhclient..."
        
        if [ -f /etc/dhcp/dhclient.conf ]; then
            # 备份原配置
            cp -f /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.conf.backup 2>/dev/null || true
            
            # 移除可能导致 DNS 更新的配置
            sed -i '/^supersede domain-name-servers/d' /etc/dhcp/dhclient.conf
            sed -i '/^prepend domain-name-servers/d' /etc/dhcp/dhclient.conf
            
            # 添加静态 DNS
            echo "supersede domain-name-servers $DNS1_IPV4, $DNS2_IPV4, $DNS1_IPV6, $DNS2_IPV6;" >> /etc/dhcp/dhclient.conf
            
            echo "已配置 dhclient DNS 锁定"
        fi
    fi
    
    # 1.5 处理 systemd-networkd
    if systemctl is-active systemd-networkd >/dev/null 2>&1; then
        echo "配置 systemd-networkd..."
        mkdir -p /etc/systemd/network/
        
        cat > /etc/systemd/network/90-dns-lock.network << EOF
[Network]
DNS=$DNS1_IPV4
DNS=$DNS2_IPV4
DNS=$DNS1_IPV6
DNS=$DNS2_IPV6
EOF
        
        systemctl restart systemd-networkd 2>/dev/null || true
    fi
    
    # 1.6 禁用 ifupdown 中的 DNS 配置
    if [ -f /etc/network/interfaces ]; then
        echo "检查 /etc/network/interfaces..."
        # 注释掉 dns-nameservers 行
        sed -i 's/^[^#]*dns-nameservers/#&/' /etc/network/interfaces 2>/dev/null || true
    fi
}

# 2. Alpine 系统处理
setup_alpine() {
    echo "配置 Alpine 系统..."
    
    # 2.1 处理 udhcpc (Alpine 默认 DHCP 客户端)
    if command -v udhcpc >/dev/null 2>&1 || [ -d /etc/udhcpc ]; then
        echo "配置 udhcpc..."
        mkdir -p /etc/udhcpc/
        
        # 创建 udhcpc 配置，禁止修改 resolv.conf
        cat > /etc/udhcpc/udhcpc.conf << EOF
RESOLV_CONF=NO
IF_PEER_DNS=NO
EOF
        
        # 修改 udhcpc 默认脚本
        if [ -f /usr/share/udhcpc/default.script ]; then
            # 备份原脚本
            cp -f /usr/share/udhcpc/default.script /usr/share/udhcpc/default.script.backup 2>/dev/null || true
            
            # 注释掉修改 resolv.conf 的部分
            sed -i 's/^[^#]*\/etc\/resolv\.conf/#&/' /usr/share/udhcpc/default.script 2>/dev/null || true
        fi
        
        echo "已配置 udhcpc 不修改 DNS"
    fi
    
    # 2.2 处理 dhcpcd（如果安装）
    if [ -f /etc/dhcpcd.conf ]; then
        echo "配置 dhcpcd..."
        
        # 备份原配置
        cp -f /etc/dhcpcd.conf /etc/dhcpcd.conf.backup 2>/dev/null || true
        
        # 清理已有配置
        sed -i '/^nohook resolv.conf/d' /etc/dhcpcd.conf
        sed -i '/^static domain_name_servers/d' /etc/dhcpcd.conf
        
        # 添加锁定配置
        cat >> /etc/dhcpcd.conf << EOF

# DNS Lock Configuration
nohook resolv.conf
static domain_name_servers=$DNS1_IPV4 $DNS2_IPV4 $DNS1_IPV6 $DNS2_IPV6
EOF
        
        echo "已配置 dhcpcd DNS 锁定"
    fi
    
    # 2.3 处理 /etc/network/interfaces（Alpine 常用）
    if [ -f /etc/network/interfaces ]; then
        echo "检查 /etc/network/interfaces..."
        # 注释掉 DNS 相关配置行
        sed -i 's/^[^#]*dns-nameservers/#&/' /etc/network/interfaces 2>/dev/null || true
    fi
    
    # 2.4 创建 OpenRC 服务用于启动时恢复 DNS
    echo "创建 OpenRC 启动服务..."
    
    mkdir -p /etc/local.d/
    
    # 创建启动脚本
    cat > /etc/local.d/dns-lock.start << EOF
#!/bin/sh
# DNS Lock - 启动时强制恢复 DNS 配置

# 检查 resolv.conf 是否需要恢复
NEEDS_RESTORE=0

# 检查文件是否存在
if [ ! -f /etc/resolv.conf ]; then
    NEEDS_RESTORE=1
fi

# 检查是否包含我们的 DNS
if ! grep -q "$DNS1_IPV4" /etc/resolv.conf 2>/dev/null; then
    NEEDS_RESTORE=1
fi

# 恢复配置
if [ "\$NEEDS_RESTORE" = "1" ]; then
    echo "Restoring DNS configuration..."
    cat > /etc/resolv.conf << DNSEOF
# DNS Configuration - Locked
# This file is protected from modification
nameserver $DNS1_IPV4
nameserver $DNS2_IPV4
nameserver $DNS1_IPV6
nameserver $DNS2_IPV6
DNSEOF
fi

exit 0
EOF
    
    chmod +x /etc/local.d/dns-lock.start
    
    # 启用 local 服务（Alpine/OpenRC）
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add local default 2>/dev/null || true
        echo "已启用 OpenRC local 服务"
    fi
}

# 3. 通用保护措施
apply_universal_protection() {
    echo "应用通用保护措施..."
    
    # 3.1 移除并创建新的 resolv.conf
    if [ -f /etc/resolv.conf ]; then
        # 尝试移除不可变属性（如果之前设置过）
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    # 3.2 如果 resolv.conf 是符号链接，移除它
    if [ -L /etc/resolv.conf ]; then
        echo "移除符号链接 /etc/resolv.conf"
        rm -f /etc/resolv.conf
    fi
    
    # 3.3 创建我们的 resolv.conf
    create_resolv_conf
    
    # 3.4 设置文件权限为只读
    chmod 444 /etc/resolv.conf
    
    # 3.5 尝试设置不可变属性（需要支持 chattr 的文件系统）
    if command -v chattr >/dev/null 2>&1; then
        chattr +i /etc/resolv.conf 2>/dev/null && echo "已设置文件不可变属性 (chattr +i)" || echo "注意: 当前文件系统不支持 chattr"
    fi
    
    echo "已锁定 /etc/resolv.conf"
}

# 4. 创建监控脚本（使用 cron）
create_cron_monitor() {
    echo "创建 DNS 监控脚本..."
    
    # 创建监控脚本
    cat > /etc/dns-lock-monitor.sh << EOF
#!/bin/sh
# DNS Lock Monitor - 检测并恢复 DNS 配置

EXPECTED_DNS1="$DNS1_IPV4"
EXPECTED_DNS2="$DNS2_IPV4"

# 快速检查
if ! grep -q "\$EXPECTED_DNS1" /etc/resolv.conf 2>/dev/null; then
    logger -t dns-lock "DNS 配置已被修改，正在恢复..."
    
    # 移除不可变属性
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # 恢复配置
    cat > /etc/resolv.conf << DNSEOF
# DNS Configuration - Locked
# This file is protected from modification
nameserver $DNS1_IPV4
nameserver $DNS2_IPV4
nameserver $DNS1_IPV6
nameserver $DNS2_IPV6
DNSEOF
    
    # 重新设置只读
    chmod 444 /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    logger -t dns-lock "DNS 配置已恢复"
fi
EOF
    
    chmod +x /etc/dns-lock-monitor.sh
    
    # 添加到 crontab（如果存在）
    if command -v crontab >/dev/null 2>&1; then
        # 检查是否已存在
        if ! crontab -l 2>/dev/null | grep -q "dns-lock-monitor"; then
            # 添加每5分钟检查一次的任务
            (crontab -l 2>/dev/null; echo "*/5 * * * * /etc/dns-lock-monitor.sh") | crontab -
            echo "已添加 cron 监控任务（每5分钟）"
            
            # 确保 crond 运行
            if [ "$SYSTEM" = "alpine" ]; then
                rc-service crond start 2>/dev/null || true
                rc-update add crond default 2>/dev/null || true
            else
                systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
                systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
            fi
        else
            echo "cron 监控任务已存在"
        fi
    fi
}

# 5. 主执行流程
main() {
    # 检测系统
    detect_system
    
    echo ""
    echo "开始配置 DNS 锁定..."
    echo ""
    
    # 根据系统类型执行相应配置
    case "$SYSTEM" in
        debian)
            setup_debian
            ;;
        alpine)
            setup_alpine
            ;;
        *)
            echo "警告: 未知系统类型，仅应用通用保护"
            ;;
    esac
    
    # 应用通用保护
    apply_universal_protection
    
    # 创建设置监控
    create_cron_monitor
    
    echo ""
    echo "=========================================="
    echo "  DNS 锁定配置完成"
    echo "=========================================="
    echo ""
    echo "当前 DNS 配置:"
    echo "---"
    cat /etc/resolv.conf 2>/dev/null || echo "无法读取配置"
    echo "---"
    echo ""
    echo "已应用的锁定措施:"
    echo "  1. 禁用所有 DHCP 客户端修改 DNS"
    
    if [ "$SYSTEM" = "alpine" ]; then
        echo "  2. 配置 udhcpc 不修改 resolv.conf"
        echo "  3. 创建 OpenRC 启动恢复服务"
    fi
    
    if [ "$SYSTEM" = "debian" ]; then
        echo "  2. 禁用 NetworkManager/systemd-resolved DNS 管理"
        echo "  3. 配置 dhclient 固定 DNS"
    fi
    
    echo "  4. 设置文件系统保护 (chmod 444 + chattr +i)"
    echo "  5. 启用 cron 监控 (每5分钟检查)"
    echo ""
    
    # 测试 DNS
    echo "正在测试 DNS 解析..."
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup google.com >/dev/null 2>&1; then
            echo "✓ DNS 解析正常"
        else
            echo "✗ DNS 解析失败，但配置已锁定"
        fi
    elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
            echo "✓ 网络连通正常"
        else
            echo "✗ 网络测试失败，但配置已锁定"
        fi
    else
        echo "无法测试 DNS（缺少测试工具）"
    fi
    
    echo ""
    echo "提示:"
    echo "  - 配置已锁定，重启后依然有效"
    echo "  - 如需修改 DNS，请执行:"
    echo "    chattr -i /etc/resolv.conf"
    echo "    然后编辑 /etc/resolv.conf"
    echo "    chattr +i /etc/resolv.conf"
    echo "  - 查看监控日志:"
    echo "    grep 'dns-lock' /var/log/messages"
}

# 执行主函数
main

exit 0
