#!/bin/bash

# =================================================================
# 脚本功能：Stubby 加密 DNS (DoT) 一键部署及全接管
# 支持系统：Debian / Ubuntu / Alpine (x86_64, ARM)
# =================================================================

# --- 颜色定义 ---
INFO='\033[0;32m[INFO]\033[0m'
OK='\033[0;34m[OK]\033[0m'
WARN='\033[0;33m[WARN]\033[0m'
ERROR='\033[0;31m[ERROR]\033[0m'

# --- 路径与变量 ---
STUBBY_CONF="/etc/stubby/stubby.yml"
RESOLV_CONF="/etc/resolv.conf"
LOG_DIR="/var/log/secure-dns"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
GUARD_SCRIPT="/usr/local/bin/dns_secure_guard.sh"

# 1. 权限与架构检测
if [[ $EUID -ne 0 ]]; then
   echo -e "${ERROR} 必须以 root 权限运行此脚本。"
   exit 1
fi

# 2. 系统环境检测与依赖安装
install_deps() {
    echo -e "${INFO} 正在安装系统依赖..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
        apk add stubby ca-certificates openssl coreutils e2fsprogs-extra cronie bind-tools
        rc-update add crond default && rc-service crond start
    elif [ -f /etc/debian_version ]; then
        OS="Debian"
        apt-get update
        # Debian 下 chattr 属于 e2fsprogs, nslookup 属于 dnsutils
        apt-get install -y stubby ca-certificates openssl coreutils e2fsprogs cron dnsutils sed
        # 停用干扰服务
        systemctl stop systemd-resolved 2>/dev/null && systemctl disable systemd-resolved 2>/dev/null
    else
        echo -e "${ERROR} 暂不支持的操作系统。" && exit 1
    fi
    echo -e "${OK} 依赖安装完成。"
}

# 3. 初始化目录
init_dirs() {
    mkdir -p /etc/stubby
    mkdir -p $LOG_DIR
    chmod 750 $LOG_DIR
}

# 4. 生成 Stubby 配置 (DoT + 多上游轮询)
gen_config() {
    echo -e "${INFO} 正在配置 Stubby (监听 53 端口)..."
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
    # 生成防篡改备份
    sha256sum $STUBBY_CONF > "${STUBBY_CONF}.sha256"
    cp $STUBBY_CONF $BACKUP_CONF
    echo -e "${OK} Stubby 配置已生成。"
}

# 5. 接管代理软件 (Xray / Sing-box)
integrate_proxy() {
    echo -e "${INFO} 正在检查代理软件集成..."
    # 定义常见路径
    local paths=("/etc/xray/config.json" "/etc/sing-box/config.json" "/usr/local/etc/xray/config.json" "/root/sing-box/config.json")
    
    for p in "${paths[@]}"; do
        if [ -f "$p" ]; then
            echo -e "${OK} 发现配置: $p，正在接管 DNS..."
            # 备份并修改配置，将 DNS 地址指向 127.0.0.1
            cp "$p" "$p.bak"
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$p"
            # 发送重载信号
            pkill -HUP xray 2>/dev/null || pkill -HUP sing-box 2>/dev/null
        fi
    done
}

# 6. 系统服务启动与 DNS 强力锁定
start_and_lock() {
    echo -e "${INFO} 启动服务并锁定系统解析..."
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default && rc-service stubby restart
    else
        systemctl daemon-reload && systemctl enable stubby && systemctl restart stubby
    fi

    # 等待建立 TLS 连接
    sleep 3

    # 处理 resolv.conf (解决重启消失问题)
    chattr -i $RESOLV_CONF 2>/dev/null
    rm -f $RESOLV_CONF # 强制删除可能存在的软链接
    echo -e "nameserver 127.0.0.1\nnameserver ::1\noptions timeout:2 attempts:1" > $RESOLV_CONF
    
    # 尝试锁定，若不支持则降级
    if ! chattr +i $RESOLV_CONF 2>/dev/null; then
        echo -e "${WARN} 文件系统不支持 chattr，已设为只读。"
        chmod 444 $RESOLV_CONF
    else
        echo -e "${OK} 系统 DNS 已通过 chattr +i 强力锁定。"
    fi
}

# 7. 部署安全卫士 (防篡改 + 自动恢复)
deploy_guard() {
    echo -e "${INFO} 部署安全卫士脚本..."
    cat > $GUARD_SCRIPT <<EOF
#!/bin/bash
# 1. 校验 Stubby 配置
cd /etc/stubby
sha256sum -c stubby.yml.sha256 > /dev/null 2>&1
if [ \$? -ne 0 ]; then
    chattr -i $STUBBY_CONF 2>/dev/null
    cp $BACKUP_CONF $STUBBY_CONF
    command -v rc-service &>/dev/null && rc-service stubby restart || systemctl restart stubby
    echo "\$(date) - 配置已篡改并还原" >> $LOG_DIR/guard.log
fi

# 2. 检查 resolv.conf 是否消失或被改
if [ ! -f "$RESOLV_CONF" ] || ! grep -q "127.0.0.1" "$RESOLV_CONF"; then
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    chattr +i $RESOLV_CONF 2>/dev/null
    echo "\$(date) - resolv.conf 已修复" >> $LOG_DIR/guard.log
fi

# 3. 清理 30 天前日志
find $LOG_DIR -type f -mtime +30 -delete
EOF
    chmod +x $GUARD_SCRIPT
    # 加入定时任务 (每分钟运行一次)
    (crontab -l 2>/dev/null | grep -v "$GUARD_SCRIPT"; echo "* * * * * $GUARD_SCRIPT") | crontab -
}

# 8. 效果验证
verify() {
    echo -e "\n${INFO} --- 自动化校验 ---"
    # 进程检查
    pgrep -x stubby > /dev/null && echo -e "${OK} Stubby 运行中" || echo -e "${ERROR} Stubby 未启动"
    
    # 解析测试
    echo -ne "${INFO} Google 解析测试: "
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "${OK}成功"
    else
        echo -e "${ERROR}失败 (请检查 853 端口出站连通性)"
    fi
}

# --- 执行流 ---
install_deps
init_dirs
gen_config
integrate_proxy
start_and_lock
deploy_guard
verify

echo -e "\n${OK} 加密 DNS 部署任务全部完成！"
echo -e "${INFO} 所有 DNS 流量现已通过 Stubby (DoT) 加密。"
