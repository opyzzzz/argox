#!/bin/bash

# =================================================================
# 脚本名称: Secure-DNS 一键部署 (Stubby 方案)
# 适用系统: Debian / Ubuntu / Alpine (x86_64 / ARM)
# 功能描述: 实现系统级加密 DNS 接管，支持代理集成、防篡改与自动恢复
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
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
SHA_FILE="/etc/stubby/stubby.yml.sha256"

# 1. 环境检测
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${ERROR} 必须以 root 运行" && exit 1
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
    elif [ -f /etc/debian_version ]; then
        OS="Debian"
    else
        echo -e "${ERROR} 不支持的系统" && exit 1
    fi
}

# 2. 依赖安装
install_deps() {
    echo -e "${INFO} 正在安装官方依赖..."
    if [ "$OS" == "Alpine" ]; then
        # 安装 e2fsprogs-extra 以获得 chattr，安装 cronie 解决 BusyBox cron 兼容性
        apk add stubby ca-certificates openssl coreutils e2fsprogs-extra cronie bind-tools sed net-tools
        rc-update add crond default && rc-service crond start
    else
        apt-get update
        apt-get install -y stubby ca-certificates openssl coreutils e2fsprogs cron dnsutils sed net-tools
        # 禁用干扰服务
        systemctl stop systemd-resolved 2>/dev/null && systemctl disable systemd-resolved 2>/dev/null
    fi
    echo -e "${OK} 依赖安装完成。"
}

# 3. 配置 Stubby (DoT + 多上游)
config_stubby() {
    echo -e "${INFO} 正在配置 Stubby 加密解析器..."
    mkdir -p /etc/stubby $LOG_DIR
    
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
    # 记录指纹用于防篡改
    sha256sum $STUBBY_CONF > $SHA_FILE
    cp $STUBBY_CONF $BACKUP_CONF
    echo -e "${OK} 配置文件生成。"
}

# 4. 接管 Xray / Sing-box
integrate_proxy() {
    echo -e "${INFO} 正在扫描代理软件配置..."
    local cfgs=("/etc/xray/config.json" "/etc/sing-box/config.json" "/usr/local/etc/xray/config.json" "/root/sing-box/config.json")
    for f in "${cfgs[@]}"; do
        if [ -f "$f" ]; then
            echo -e "${OK} 发现配置 $f，正在重定向 DNS..."
            cp "$f" "$f.bak"
            # 将 DNS address 指向本地，同时匹配 IPv4 和 IPv6 格式
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$f"
            # 发送 HUP 信号触发 live reload
            pkill -HUP xray 2>/dev/null || pkill -HUP sing-box 2>/dev/null
        fi
    done
}

# 5. 启动服务与 DNS 锁定
start_and_lock() {
    echo -e "${INFO} 启动 Stubby 并执行全接管..."
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default
        rc-service stubby restart
    else
        systemctl daemon-reload && systemctl enable stubby && systemctl restart stubby
    fi

    # 等待 TLS 握手
    sleep 3

    # 接管 resolv.conf (强制覆盖并锁定)
    chattr -i $RESOLV_CONF 2>/dev/null || chmod 644 $RESOLV_CONF
    echo -e "nameserver 127.0.0.1\nnameserver ::1\noptions timeout:2 attempts:1" > $RESOLV_CONF
    
    if ! chattr +i $RESOLV_CONF 2>/dev/null; then
        echo -e "${WARN} 当前环境不支持 chattr 锁定，采用权限只读模式。"
        chmod 444 $RESOLV_CONF
    else
        echo -e "${OK} 系统 DNS 已锁定至 127.0.0.1。"
    fi
}

# 6. 部署安全卫士 (支持日志自动清理)
deploy_guard() {
    echo -e "${INFO} 正在部署自动恢复卫士..."
    cat > $GUARD_SCRIPT <<EOF
#!/bin/sh
# 1. 基于端口监听检测 Stubby (比进程名检测更准确)
if ! netstat -tunlp | grep -q ":53 "; then
    command -v rc-service >/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 2. 配置防篡改检测
cd /etc/stubby
sha256sum -c stubby.yml.sha256 > /dev/null 2>&1
if [ \$? -ne 0 ]; then
    chattr -i $STUBBY_CONF 2>/dev/null
    cp $BACKUP_CONF $STUBBY_CONF
    command -v rc-service >/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 3. 检查 resolv.conf 完整性
if ! grep -q "127.0.0.1" "$RESOLV_CONF" 2>/dev/null; then
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    chattr +i $RESOLV_CONF 2>/dev/null
fi

# 4. 清理旧日志
find $LOG_DIR -type f -mtime +30 -delete
EOF
    chmod +x $GUARD_SCRIPT

    # 针对 Alpine 的 Crontab 写入优化，避免缓存目录报错
    TMP_CRON="/tmp/cron_dns"
    crontab -l > $TMP_CRON 2>/dev/null || true
    if ! grep -q "$GUARD_SCRIPT" $TMP_CRON; then
        echo "* * * * * $GUARD_SCRIPT" >> $TMP_CRON
        crontab $TMP_CRON
    fi
    rm -f $TMP_CRON
}

# 7. 最终校验
verify() {
    echo -e "\n${INFO} --- 自动化部署校验 ---"
    # 端口校验
    if netstat -tunlp | grep -q ":53 "; then
        echo -e "${OK} 服务监听: 正常"
    else
        echo -e "${ERROR} 服务监听: 失败"
    fi

    # 解析校验
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "${OK} DNS 解析: 正常 (DoT 链路已畅通)"
    else
        echo -e "${ERROR} DNS 解析: 失败"
    fi
}

# --- 执行主流程 ---
check_env
install_deps
config_stubby
integrate_proxy
start_and_lock
deploy_guard
verify

echo -e "\n${OK} 部署完成！Stubby 已全面接管系统 DNS 流量。"
