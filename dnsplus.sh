#!/bin/bash

# ====================================================
# 加密 DNS 全接管脚本 (Stubby + 53端口接管)
# 特性: DoT加密, 系统全局接管, 强力防篡改, Alpine/Debian双支持
# ====================================================

INFO='\033[0;32m[INFO]\033[0m'
OK='\033[0;34m[OK]\033[0m'
WARN='\033[0;33m[WARN]\033[0m'
ERROR='\033[0;31m[ERROR]\033[0m'

STUBBY_CONF="/etc/stubby/stubby.yml"
RESOLV_CONF="/etc/resolv.conf"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
GUARD_LOG="/var/log/secure-dns/guard.log"

# 1. 环境准备
prepare_env() {
    echo -e "${INFO} 检测系统并安装依赖..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"; PM="apk add"; DEPS="stubby ca-certificates openssl coreutils e2fsprogs-extra cronie"
    else
        OS="Debian"; PM="apt-get install -y"; apt-get update; DEPS="stubby ca-certificates openssl coreutils chattr cron"
    fi
    $PM $DEPS
    mkdir -p /var/log/secure-dns && chmod 750 /var/log/secure-dns
}

# 2. 写入配置 (强制监听 53 端口)
write_config() {
    echo -e "${INFO} 生成 Stubby 配置 (接管 53 端口)..."
    # 如果有其他服务占用53，先尝试关闭 (如 Alpine 的 dnsmasq 或 Debian 的 systemd-resolved)
    [ "$OS" == "Debian" ] && systemctl stop systemd-resolved 2>/dev/null && systemctl disable systemd-resolved 2>/dev/null
    
    cat > $STUBBY_CONF <<EOF
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private : 1
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@53
  - 0::1@53
upstream_recursive_servers:
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
EOF
    cp $STUBBY_CONF $BACKUP_CONF
}

# 3. 启动并接管系统 DNS
takeover_dns() {
    echo -e "${INFO} 启动服务并锁定系统 DNS..."
    
    # 启动 Stubby
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default && rc-service stubby restart
    else
        systemctl enable stubby && systemctl restart stubby
    fi

    # 等待 TLS 握手 (防止断网)
    sleep 3

    # 修改 resolv.conf
    # 先解除锁定（防止脚本重复运行报错）
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1\noptions timeout:2 attempts:1" > $RESOLV_CONF
    
    # 强力锁定：禁止任何进程（包括系统重启脚本）修改此文件
    chattr +i $RESOLV_CONF
    echo -e "${OK} 系统 DNS 已锁定为 127.0.0.1"
}

# 4. 防篡改守卫脚本
setup_guard() {
    local guard_path="/usr/local/bin/dns_secure_guard.sh"
    echo -e "${INFO} 部署防篡改监控..."
    
    cat > $guard_path <<EOF
#!/bin/bash
# 1. 检查 Stubby 配置
ORIGIN="\$(sha256sum $BACKUP_CONF | awk '{print \$1}')"
CURRENT="\$(sha256sum $STUBBY_CONF | awk '{print \$1}')"

if [ "\$ORIGIN" != "\$CURRENT" ]; then
    chattr -i $STUBBY_CONF
    cp $BACKUP_CONF $STUBBY_CONF
    command -v rc-service &>/dev/null && rc-service stubby restart || systemctl restart stubby
    echo "\$(date) - Stubby config restored" >> $GUARD_LOG
fi

# 2. 检查 resolv.conf 是否被强行篡改 (如果 chattr 被绕过)
if ! grep -q "127.0.0.1" "$RESOLV_CONF"; then
    chattr -i $RESOLV_CONF
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    chattr +i $RESOLV_CONF
    echo "\$(date) - resolv.conf restored" >> $GUARD_LOG
fi
EOF
    chmod +x $guard_path
    
    # 写入 Cron 每天凌晨检查
    (crontab -l 2>/dev/null | grep -v "$guard_path"; echo "0 3 * * * $guard_path") | crontab -
}

# 5. 校验
verify() {
    echo -e "${INFO} 执行最终校验..."
    # 针对 Alpine 的 nslookup 语法
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "${OK} 加密 DNS 工作正常，系统已全面接管。"
    else
        echo -e "${WARN} 解析延迟，请稍后使用 'nslookup google.com' 手动测试。"
    fi
}

# 流程控制
prepare_env
write_config
takeover_dns
setup_guard
verify

echo -e "\n${OK} 所有操作已完成！"
echo -e "${INFO} 配置文件: $STUBBY_CONF (已锁定备份)"
echo -e "${INFO} 系统 DNS: $RESOLV_CONF (已通过 chattr +i 强力锁定)"
