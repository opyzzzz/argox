#!/bin/bash

# =================================================================
# 脚本名称: Secure-DNS 终极部署脚本 (Stubby)
# 适用系统: Debian / Ubuntu / Alpine
# 特色: 解决容器环境 resolv.conf 锁定失败、DHCP 覆盖、IPv6 优先
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

# 1. 环境检测与依赖安装
setup_deps() {
    echo -e "${INFO} 检测系统环境并安装依赖..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
        # 安装 cronie 以获得稳定的 crontab，e2fsprogs-extra 尝试获取 chattr
        apk add stubby ca-certificates openssl coreutils e2fsprogs-extra cronie bind-tools net-tools sed
        rc-update add crond default && rc-service crond start
    else
        OS="Debian"
        apt-get update
        apt-get install -y stubby ca-certificates openssl coreutils e2fsprogs cron dnsutils net-tools sed
        systemctl stop systemd-resolved 2>/dev/null && systemctl disable systemd-resolved 2>/dev/null
    fi
}

# 2. 配置 Stubby (支持 DoT 与双栈轮询)
config_stubby() {
    echo -e "${INFO} 正在配置加密解析器 (Stubby)..."
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
EOF
    # 生成防篡改指纹
    sha256sum $STUBBY_CONF > $SHA_FILE
    cp $STUBBY_CONF $BACKUP_CONF
}

# 3. 解决持久化问题：反制 DHCP 与锁定
persist_dns() {
    echo -e "${INFO} 正在执行 DNS 持久化策略..."
    
    # A. 针对 dhcpcd 的反制 (常见于 Alpine)
    if [ -f /etc/dhcpcd.conf ]; then
        if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf
            echo -e "${OK} 已禁用 dhcpcd 对 resolv.conf 的修改。"
        fi
    fi

    # B. 写入 resolv.conf.head (Alpine 标准持久化方案)
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > /etc/resolv.conf.head 2>/dev/null

    # C. 强制修改当前 resolv.conf
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    
    # D. 尝试物理锁定 (如果失败则忽略，交由卫士脚本)
    if chattr +i $RESOLV_CONF 2>/dev/null; then
        echo -e "${OK} 成功执行物理锁定。"
    else
        echo -e "${WARN} 物理锁定受限 (容器环境)，将依赖安全卫士每分钟强制修正。"
    fi
}

# 4. 代理集成 (Xray/Sing-box Live Reload)
integrate_proxy() {
    echo -e "${INFO} 正在集成代理软件..."
    local paths=("/etc/xray/config.json" "/etc/sing-box/config.json" "/root/sing-box/config.json")
    for p in "${paths[@]}"; do
        if [ -f "$p" ]; then
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$p"
            pkill -HUP xray 2>/dev/null || pkill -HUP sing-box 2>/dev/null
            echo -e "${OK} 已重定向 $p 的 DNS 指向。"
        fi
    done
}

# 5. 部署安全卫士脚本
deploy_guard() {
    echo -e "${INFO} 部署安全卫士..."
    cat > $GUARD_SCRIPT <<EOF
#!/bin/sh
# 1. 端口存活检测
if ! netstat -tunlp | grep -q ":53 "; then
    command -v rc-service >/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 2. 配置防篡改
sha256sum -c $SHA_FILE > /dev/null 2>&1
if [ \$? -ne 0 ]; then
    chattr -i $STUBBY_CONF 2>/dev/null
    cp $BACKUP_CONF $STUBBY_CONF
    command -v rc-service >/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 3. 强力修正 resolv.conf (解决 DHCP 覆盖)
if ! grep -q "127.0.0.1" "$RESOLV_CONF"; then
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    chattr +i $RESOLV_CONF 2>/dev/null
fi

# 4. 清理 30 天日志
find $LOG_DIR -type f -mtime +30 -delete
EOF
    chmod +x $GUARD_SCRIPT

    # 写入 Crontab
    (crontab -l 2>/dev/null | grep -v "$GUARD_SCRIPT"; echo "* * * * * $GUARD_SCRIPT") | crontab -
}

# 6. 启动服务与最终检测
finalize() {
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default
        rc-service stubby restart
    else
        systemctl enable stubby && systemctl restart stubby
    fi

    echo -e "\n${INFO} === 最终部署效果校验 ==="
    sleep 2
    
    # 53 端口检测
    if netstat -tunlp | grep -q ":53 "; then
        echo -e "${OK} 服务监听 (53端口): 正常"
    else
        echo -e "${ERROR} 服务监听: 异常"
    fi

    # 解析检测
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "${OK} 加密 DoT 解析: 正常"
    else
        echo -e "${ERROR} 加密 DoT 解析: 失败"
    fi
}

# --- 执行流程 ---
setup_deps
config_stubby
persist_dns
integrate_proxy
deploy_guard
finalize

echo -e "\n${OK} 部署完成。即使重启后，卫士脚本也会在 1 分钟内夺回 DNS 控制权。"
