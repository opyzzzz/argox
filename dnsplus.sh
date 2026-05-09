#!/bin/bash

# =================================================================
# 脚本名称: Secure-DNS 一键全能部署脚本
# 功能: 部署 Stubby (DoT), 锁定系统 DNS, 自动接管代理软件, 防篡改卫士
# 支持: Debian / Ubuntu / Alpine (x86_64 / ARM)
# =================================================================

# --- 样式定义 ---
INFO='\033[0;32m[INFO]\033[0m'
OK='\033[0;34m[OK]\033[0m'
WARN='\033[0;33m[WARN]\033[0m'
ERROR='\033[0;31m[ERROR]\033[0m'

# --- 路径与全局变量 ---
STUBBY_CONF="/etc/stubby/stubby.yml"
RESOLV_CONF="/etc/resolv.conf"
LOG_DIR="/var/log/secure-dns"
GUARD_SCRIPT="/usr/local/bin/dns_secure_guard.sh"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
SHA_FILE="/etc/stubby/stubby.yml.sha256"

# 1. 环境自检
check_privilege() {
    [[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 root 权限运行此脚本。" && exit 1
}

# 2. 依赖管理
install_deps() {
    echo -e "${INFO} 正在安装系统依赖..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
        # 安装 e2fsprogs-extra 尝试获取 chattr, cronie 解决定时任务兼容性
        apk add stubby ca-certificates openssl coreutils e2fsprogs-extra cronie bind-tools net-tools sed
        rc-update add crond default && rc-service crond start
    elif [ -f /etc/debian_version ]; then
        OS="Debian"
        apt-get update
        apt-get install -y stubby ca-certificates openssl coreutils e2fsprogs cron dnsutils net-tools sed
        # 彻底禁用可能冲突的本地解析器
        systemctl stop systemd-resolved 2>/dev/null && systemctl disable systemd-resolved 2>/dev/null
    else
        echo -e "${ERROR} 暂不支持的操作系统。" && exit 1
    fi
    echo -e "${OK} 依赖安装完成。"
}

# 3. 核心配置生成 (DoT + 多上游轮询)
generate_config() {
    echo -e "${INFO} 正在生成 Stubby 加密配置..."
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
  # Cloudflare (DoT)
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
  # Google (DoT)
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
  # Quad9 (DoT)
  - address_data: 2620:fe::fe
    tls_auth_name: "dns.quad9.net"
  - address_data: 9.9.9.9
    tls_auth_name: "dns.quad9.net"
EOF
    # 生成防篡改基准
    sha256sum $STUBBY_CONF > $SHA_FILE
    cp $STUBBY_CONF $BACKUP_CONF
    echo -e "${OK} 配置文件已生成。"
}

# 4. 接管 Xray / Sing-box 配置
integrate_proxy() {
    echo -e "${INFO} 正在检测并接管代理软件 DNS..."
    # 扫描常见配置文件路径
    local configs=(
        "/etc/xray/config.json" 
        "/etc/sing-box/config.json" 
        "/usr/local/etc/xray/config.json" 
        "/root/sing-box/config.json"
    )

    for cfg in "${configs[@]}"; do
        if [ -f "$cfg" ]; then
            echo -e "${OK} 发现配置: $cfg"
            cp "$cfg" "$cfg.bak"
            # 将所有 DNS 节点的地址指向本地
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$cfg"
            # 尝试发送 HUP 信号 (Live Reload)
            pkill -HUP xray 2>/dev/null || pkill -HUP sing-box 2>/dev/null
        fi
    done
}

# 5. 服务管理与 DNS 接管
start_and_lock() {
    echo -e "${INFO} 启动服务并锁定系统 DNS..."
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default
        rc-service stubby restart
    else
        systemctl daemon-reload && systemctl enable stubby && systemctl restart stubby
    fi

    # 等待 TLS 建立
    sleep 3

    # 处理 resolv.conf
    chattr -i $RESOLV_CONF 2>/dev/null || chmod 644 $RESOLV_CONF
    echo -e "nameserver 127.0.0.1\nnameserver ::1\noptions timeout:2 attempts:1" > $RESOLV_CONF
    
    # 尝试锁定，如果失败则输出警告并由卫士脚本接手
    if ! chattr +i $RESOLV_CONF 2>/dev/null; then
        echo -e "${WARN} 文件系统不支持 chattr 锁定。安全卫士将每分钟监测并自动恢复。"
        chmod 444 $RESOLV_CONF
    else
        echo -e "${OK} 系统 DNS 已物理锁定。"
    fi
}

# 6. 安全卫士脚本部署 (防篡改 + 自动恢复)
deploy_guard() {
    echo -e "${INFO} 正在部署 DNS 安全卫士..."
    cat > $GUARD_SCRIPT <<EOF
#!/bin/sh
# 1. 通过端口存活检查服务状态
if ! netstat -tunlp | grep -q ":53 "; then
    command -v rc-service >/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 2. 配置防篡改校验
cd /etc/stubby
sha256sum -c stubby.yml.sha256 > /dev/null 2>&1
if [ \$? -ne 0 ]; then
    chattr -i $STUBBY_CONF 2>/dev/null
    cp $BACKUP_CONF $STUBBY_CONF
    command -v rc-service >/dev/null && rc-service stubby restart || systemctl restart stubby
fi

# 3. 强制修正 resolv.conf (即便无法锁定也会修正)
if ! grep -q "127.0.0.1" "$RESOLV_CONF" 2>/dev/null; then
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    chattr +i $RESOLV_CONF 2>/dev/null
fi

# 4. 日志自动清理 (30天)
find $LOG_DIR -type f -mtime +30 -delete
EOF
    chmod +x $GUARD_SCRIPT

    # 针对 Alpine 优化 Crontab 写入，避开 /root/.cache 权限问题
    TMP_CRON="/tmp/dns_cron_tmp"
    crontab -l > \$TMP_CRON 2>/dev/null || true
    if ! grep -q "$GUARD_SCRIPT" \$TMP_CRON; then
        echo "* * * * * $GUARD_SCRIPT" >> \$TMP_CRON
        crontab \$TMP_CRON
    fi
    rm -f \$TMP_CRON
}

# 7. 效果最终校验
final_verify() {
    echo -e "\n${INFO} === 部署效果最终校验 ==="
    
    # 校验监听 (核心)
    if netstat -tunlp | grep -q ":53 "; then
        echo -e "${OK} Stubby 监听状态: 正常 (53端口)"
    else
        echo -e "${ERROR} Stubby 未能监听 53 端口，请检查日志"
    fi

    # 校验系统接管
    if grep -q "127.0.0.1" "$RESOLV_CONF"; then
        echo -e "${OK} 系统解析接管: 正常"
    else
        echo -e "${ERROR} 系统解析未指向 127.0.0.1"
    fi

    # 模拟 DoT 解析测试
    echo -ne "${INFO} 加密链路测试 (google.com): "
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "${OK}成功"
    else
        echo -e "${ERROR}失败 (请检查 853 端口是否被防火墙拦截)"
    fi
}

# --- 执行主流程 ---
check_privilege
install_deps
generate_config
integrate_proxy
start_and_lock
deploy_guard
final_verify

echo -e "\n${OK} 加密 DNS 部署任务全部完成！"
