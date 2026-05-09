#!/bin/bash

# =================================================================
# 脚本名称: Secure-DNS 终极部署脚本 (Stubby 方案)
# 适用系统: Debian / Ubuntu / Alpine
# 针对痛点: 解决容器环境 resolv.conf 被覆盖及锁定失效问题
# =================================================================

# --- 样式定义 ---
INFO='\033[0;32m[INFO]\033[0m'
OK='\033[0;34m[OK]\033[0m'
WARN='\033[0;33m[WARN]\033[0m'
ERROR='\033[0;31m[ERROR]\033[0m'

# --- 变量定义 ---
STUBBY_CONF="/etc/stubby/stubby.yml"
RESOLV_CONF="/etc/resolv.conf"
LOG_DIR="/var/log/secure-dns"
GUARD_SCRIPT="/usr/local/bin/dns_secure_guard.sh"
SHA_FILE="/etc/stubby/stubby.yml.sha256"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"

# 1. 环境自检与依赖安装
setup_deps() {
    echo -e "${INFO} 正在检测系统并安装必要组件..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
        # 安装 cronie 确保 crontab 稳定，安装 net-tools 用于端口检测
        apk add stubby ca-certificates openssl coreutils e2fsprogs-extra cronie bind-tools net-tools sed
        rc-update add crond default && rc-service crond start
    elif [ -f /etc/debian_version ]; then
        OS="Debian"
        apt-get update
        apt-get install -y stubby ca-certificates openssl coreutils e2fsprogs cron dnsutils net-tools sed
        # 禁用 systemd-resolved 避免 53 端口冲突
        systemctl stop systemd-resolved 2>/dev/null && systemctl disable systemd-resolved 2>/dev/null
    else
        echo -e "${ERROR} 不支持的系统架构。" && exit 1
    fi
    echo -e "${OK} 基础环境准备就绪。"
}

# 2. 配置 Stubby (高性能 DoT 轮询)
config_stubby() {
    echo -e "${INFO} 正在生成 Stubby 加密解析配置..."
    mkdir -p /etc/stubby $LOG_DIR
    chmod 750 $LOG_DIR

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
  # Cloudflare
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
  # Google
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
  # Quad9
  - address_data: 2620:fe::fe
    tls_auth_name: "dns.quad9.net"
  - address_data: 9.9.9.9
    tls_auth_name: "dns.quad9.net"
EOF
    # 计算防篡改 SHA256 并备份
    sha256sum $STUBBY_CONF > $SHA_FILE
    cp $STUBBY_CONF $BACKUP_CONF
    echo -e "${OK} Stubby 配置完成 (DoT 模式)。"
}

# 3. 持久化接管策略 (解决 DHCP 覆盖关键)
persist_dns() {
    echo -e "${INFO} 执行系统 DNS 强力接管策略..."
    
    # [策略 A] 禁用 dhcpcd 修改 DNS
    if [ -f /etc/dhcpcd.conf ]; then
        if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf
        fi
    fi

    # [策略 B] 使用 Alpine/Debian 的 .head 机制占位
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > /etc/resolv.conf.head 2>/dev/null

    # [策略 C] 强制修正当前 resolv.conf
    chattr -i $RESOLV_CONF 2>/dev/null || chmod 644 $RESOLV_CONF
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    
    # 尝试物理锁定 (容器环境下即便失败，后续卫士也会介入)
    chattr +i $RESOLV_CONF 2>/dev/null
    echo -e "${OK} DNS 持久化指令已下达。"
}

# 4. 代理软件自动集成 (Live Reload)
integrate_proxy() {
    echo -e "${INFO} 正在检测并接管代理软件 DNS 配置..."
    # 定义常见配置文件路径
    local configs=("/etc/xray/config.json" "/etc/sing-box/config.json" "/usr/local/etc/xray/config.json" "/root/sing-box/config.json")
    
    for cfg in "${configs[@]}"; do
        if [ -f "$cfg" ]; then
            # 使用 sed 匹配并替换 DNS 地址为 127.0.0.1
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$cfg"
            # 发送 HUP 信号平滑重启 DNS 模块
            pkill -HUP xray 2>/dev/null || pkill -HUP sing-box 2>/dev/null
            echo -e "${OK} 已接管配置: $cfg"
        fi
    done
}

# 5. 部署“安全卫士”守护脚本 (每分钟强制对齐)
deploy_guard() {
    echo -e "${INFO} 部署 DNS 安全卫士 (每分钟强制对齐)..."
    cat > $GUARD_SCRIPT <<EOF
#!/bin/sh
# 1. 服务存活检测 (基于端口判断更准确)
if ! netstat -tunlp | grep -q ":53 "; then
    if [ -x /sbin/rc-service ]; then rc-service stubby restart; else systemctl restart stubby; fi
fi

# 2. 配置防篡改校验
cd /etc/stubby
sha256sum -c $SHA_FILE > /dev/null 2>&1
if [ \$? -ne 0 ]; then
    chattr -i $STUBBY_CONF 2>/dev/null
    cp $BACKUP_CONF $STUBBY_CONF
    if [ -x /sbin/rc-service ]; then rc-service stubby restart; else systemctl restart stubby; fi
fi

# 3. 核心：强制修正 resolv.conf (对抗 DHCP)
if ! grep -q "127.0.0.1" "$RESOLV_CONF"; then
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    chattr +i $RESOLV_CONF 2>/dev/null
fi

# 4. 日志清理
find $LOG_DIR -type f -mtime +30 -delete
EOF
    chmod +x $GUARD_SCRIPT

    # 添加至 crontab，避免 Alpine 下 BusyBox 路径问题
    (crontab -l 2>/dev/null | grep -v "$GUARD_SCRIPT"; echo "* * * * * $GUARD_SCRIPT") | crontab -
}

# 6. 启动服务与最终校验
start_and_verify() {
    echo -e "${INFO} 启动 Stubby 并执行最终校验..."
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default && rc-service stubby restart
    else
        systemctl enable stubby && systemctl restart stubby
    fi

    sleep 3 # 等待 DoT 握手

    echo -e "\n--- 校验结果 ---"
    # 端口校验
    if netstat -tunlp | grep -q ":53 "; then
        echo -e "[服务] Stubby 状态: ${OK}正常"
    else
        echo -e "[服务] Stubby 状态: ${ERROR}异常"
    fi

    # 解析校验
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "[功能] DoT 解析测试: ${OK}通过"
    else
        echo -e "[功能] DoT 解析测试: ${ERROR}失败"
    fi
}

# --- 流程触发 ---
setup_deps
config_stubby
persist_dns
integrate_proxy
deploy_guard
start_and_verify

echo -e "\n${OK} 加密 DNS 部署完成！"
echo -e "${INFO} 注意：即使重启后 resolv.conf 暂时变回 10.10.0.1，卫士脚本也会在 1 分钟内将其强制改回。"
