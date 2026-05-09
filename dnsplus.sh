#!/bin/bash

# ====================================================
# 加密 DNS 全接管脚本 (Stubby + 53端口接管) - 修复版
# 兼容性: Debian (Bookworm/Bullseye), Ubuntu, Alpine
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
        OS="Alpine"
        PM="apk add"
        DEPS="stubby ca-certificates openssl coreutils e2fsprogs-extra cronie"
    elif [ -f /etc/debian_version ]; then
        OS="Debian"
        PM="apt-get install -y"
        # 修复：Debian 中 chattr 属于 e2fsprogs
        apt-get update
        DEPS="stubby ca-certificates openssl coreutils e2fsprogs cron dnsutils"
    else
        echo -e "${ERROR} 暂不支持此操作系统" && exit 1
    fi

    $PM $DEPS
    
    # 确保必要目录存在
    mkdir -p /etc/stubby
    mkdir -p /var/log/secure-dns
    chmod 750 /var/log/secure-dns
}

# 2. 写入配置
write_config() {
    echo -e "${INFO} 生成 Stubby 配置 (监听 53 端口)..."
    
    # 停用 Debian 常见的系统 DNS 服务以释放 53 端口
    if [ "$OS" == "Debian" ]; then
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
    fi
    
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

# 3. 启动与锁定
takeover_dns() {
    echo -e "${INFO} 启动服务并锁定系统 DNS..."
    
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default && rc-service stubby restart
    else
        # 针对部分环境可能未自动生成 service 文件的情况
        systemctl daemon-reload
        systemctl enable stubby
        systemctl restart stubby
    fi

    sleep 2

    # 尝试执行锁定，若文件系统不支持则降级为只读权限
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1\noptions timeout:2 attempts:1" > $RESOLV_CONF
    
    if ! chattr +i $RESOLV_CONF 2>/dev/null; then
        echo -e "${WARN} 文件系统不支持 chattr 锁定，改用只读权限设置"
        chmod 444 $RESOLV_CONF
    else
        echo -e "${OK} 系统 DNS 已锁定 (chattr +i)"
    fi
}

# 4. 防篡改守卫
setup_guard() {
    local guard_path="/usr/local/bin/dns_secure_guard.sh"
    echo -e "${INFO} 部署防篡改监控..."
    
    cat > $guard_path <<EOF
#!/bin/bash
# 检查进程
if ! pgrep -x stubby > /dev/null; then
    command -v rc-service &>/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 检查配置
ORIGIN="\$(sha256sum $BACKUP_CONF | awk '{print \$1}')"
CURRENT="\$(sha256sum $STUBBY_CONF | awk '{print \$1}')"
if [ "\$ORIGIN" != "\$CURRENT" ]; then
    chattr -i $STUBBY_CONF 2>/dev/null
    cp $BACKUP_CONF $STUBBY_CONF
    command -v rc-service &>/dev/null && rc-service stubby restart || systemctl restart stubby
fi
EOF
    chmod +x $guard_path
    
    # 修复：确保 crontab 存在并写入
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null | grep -v "$guard_path"; echo "* * * * * $guard_path") | crontab -
    else
        echo -e "${WARN} 未检测到 crontab，跳过定时任务设置"
    fi
}

# 5. 校验
verify() {
    echo -e "${INFO} 执行最终校验..."
    # 兼容性解析测试
    local TEST_CMD="nslookup google.com 127.0.0.1"
    if $TEST_CMD >/dev/null 2>&1 || dig @127.0.0.1 google.com >/dev/null 2>&1; then
        echo -e "${OK} 加密 DNS 工作正常！"
    else
        echo -e "${ERROR} 解析失败，请检查端口 53 占用情况或 stubby 日志。"
    fi
}

prepare_env
write_config
takeover_dns
setup_guard
verify

echo -e "\n${OK} 部署修复完成！"
