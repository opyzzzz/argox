#!/bin/bash

# =================================================================
# 脚本名称: Secure DNS 一键部署守护脚本
# 支持系统: Debian / Ubuntu / Alpine
# 核心方案: Stubby (DoT) + 系统 DNS 全接管 + 代理集成
# =================================================================

# --- 颜色定义 ---
INFO='\033[0;32m[INFO]\033[0m'
OK='\033[0;34m[OK]\033[0m'
WARN='\033[0;33m[WARN]\033[0m'
ERROR='\033[0;31m[ERROR]\033[0m'

# --- 全局变量 ---
STUBBY_CONF="/etc/stubby/stubby.yml"
LOG_DIR="/var/log/secure-dns"
GUARD_SCRIPT="/usr/local/bin/dns_secure_guard.sh"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
RESOLV_CONF="/etc/resolv.conf"

# 1. 系统检测与依赖安装
install_dependencies() {
    echo -e "${INFO} 正在检测系统环境与依赖..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
        PM="apk add"
        # 安装 stubby, openssl, e2fsprogs-extra(含chattr), cronie(定时任务)
        $PM stubby ca-certificates openssl coreutils e2fsprogs-extra cronie bind-tools
        rc-update add crond default && rc-service crond start
    elif [ -f /etc/debian_version ]; then
        OS="Debian"
        PM="apt-get install -y"
        apt-get update
        # 安装 stubby, e2fsprogs(含chattr), cron, dnsutils(含nslookup)
        $PM stubby ca-certificates openssl coreutils e2fsprogs cron dnsutils sed
    else
        echo -e "${ERROR} 暂不支持当前操作系统。" && exit 1
    fi
    echo -e "${OK} 依赖安装完成。"
}

# 2. 目录创建与权限初始化
init_env() {
    echo -e "${INFO} 初始化目录权限..."
    mkdir -p /etc/stubby
    mkdir -p $LOG_DIR
    chmod 750 $LOG_DIR
}

# 3. 生成 Stubby 配置文件 (DoT + 多上游轮询)
generate_stubby_config() {
    echo -e "${INFO} 生成 Stubby 配置文件..."
    # 停止可能冲突的系统 DNS 服务 (Debian 特有)
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
  # Cloudflare IPv6 & IPv4
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
  # Google IPv6 & IPv4
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
EOF
    # 生成防篡改备份
    cp $STUBBY_CONF $BACKUP_CONF
    echo -e "${OK} 配置文件已生成。"
}

# 4. 接管 Xray / Sing-box 配置
integrate_proxy() {
    echo -e "${INFO} 扫描并集成 Xray / Sing-box..."
    local proxy_configs=(
        "/etc/xray/config.json"
        "/etc/sing-box/config.json"
        "/usr/local/etc/xray/config.json"
        "/root/sing-box/config.json"
    )

    for config in "${proxy_configs[@]}"; do
        if [ -f "$config" ]; then
            echo -e "${OK} 发现代理配置: $config"
            # 备份原始配置
            cp "$config" "$config.bak"
            # 使用 sed 尝试将 DNS 节点指向本地 53 端口
            # 兼容简单的 address: "1.1.1.1" 替换为 "127.0.0.1"
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$config"
            
            # 发送 HUP 信号尝试 live reload
            pkill -HUP xray 2>/dev/null || pkill -HUP sing-box 2>/dev/null
            echo -e "${OK} 已尝试重载代理服务信号。"
        fi
    done
}

# 5. 启动服务与系统 DNS 锁定
start_and_lock() {
    echo -e "${INFO} 启动 Stubby 并执行系统 DNS 接管..."
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default
        rc-service stubby restart
    else
        systemctl daemon-reload
        systemctl enable stubby
        systemctl restart stubby
    fi

    # 稍等片刻确保服务就绪
    sleep 2

    # 接管 resolv.conf 并尝试使用 chattr 锁定
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1\noptions timeout:2 attempts:1" > $RESOLV_CONF
    
    if ! chattr +i $RESOLV_CONF 2>/dev/null; then
        echo -e "${WARN} 当前文件系统不支持 chattr，使用只读权限模式。"
        chmod 444 $RESOLV_CONF
    else
        echo -e "${OK} 系统 DNS 已通过 chattr 强力锁定。"
    fi
}

# 6. 配置防篡改守卫与日志清理
deploy_guard() {
    echo -e "${INFO} 部署防篡改与日志管理守护脚本..."
    cat > $GUARD_SCRIPT <<EOF
#!/bin/bash
# 1. 配置防篡改校验
ORIGIN="\$(sha256sum $BACKUP_CONF | awk '{print \$1}')"
CURRENT="\$(sha256sum $STUBBY_CONF | awk '{print \$1}')"

if [ "\$ORIGIN" != "\$CURRENT" ]; then
    chattr -i $STUBBY_CONF 2>/dev/null
    cp $BACKUP_CONF $STUBBY_CONF
    command -v rc-service &>/dev/null && rc-service stubby restart || systemctl restart stubby
    echo "\$(date) - 配置被篡改，已自动恢复" >> $LOG_DIR/guard.log
fi

# 2. 检查 Stubby 进程状态
if ! pgrep -x stubby > /dev/null; then
    command -v rc-service &>/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 3. 清理 30 天前的旧日志
find $LOG_DIR -type f -mtime +30 -delete
EOF
    chmod +x $GUARD_SCRIPT

    # 写入定时任务 (每分钟检查一次，确保高可用)
    (crontab -l 2>/dev/null | grep -v "$GUARD_SCRIPT"; echo "* * * * * $GUARD_SCRIPT") | crontab -
}

# 7. 部署效果校验
verify_installation() {
    echo -e "\n${INFO} --- 自动化校验开始 ---"
    
    # 检查进程
    if pgrep -x stubby > /dev/null; then
        echo -e "${OK} Stubby 服务状态: 运行中"
    else
        echo -e "${ERROR} Stubby 服务状态: 未运行"
    fi

    # 检查域名解析
    echo -e "${INFO} 测试域名解析 (Google)..."
    # 使用本地环回地址强制测试
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "${OK} 加密 DNS 解析验证: 成功"
    else
        echo -e "${WARN} 解析验证失败或存在延迟，请稍后手动执行: nslookup google.com"
    fi

    # 检查 resolv.conf 锁定状态
    if lsattr $RESOLV_CONF 2>/dev/null | grep -q "\-i\-"; then
        echo -e "${OK} 防篡改锁定: 已生效"
    else
        echo -e "${WARN} 防篡改锁定: 未生效 (仅只读)"
    fi
}

# --- 执行主流程 ---
install_dependencies
init_env
generate_stubby_config
integrate_proxy
start_and_lock
deploy_guard
verify_installation

echo -e "\n${OK} 加密 DNS 部署任务全部完成！"
echo -e "${INFO} 系统已全面接管至 127.0.0.1:53"
