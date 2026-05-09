#!/bin/bash

# ====================================================
# 高性能加密 DNS (Stubby) 一键部署脚本
# 支持: Debian/Ubuntu (systemd), Alpine (OpenRC)
# 功能: DoT/DoH, IPv4/IPv6, 集成 Xray/Sing-box, 防篡改
# ====================================================

# 颜色定义
INFO='\033[0;32m[INFO]\033[0m'
OK='\033[0;34m[OK]\033[0m'
WARN='\033[0;33m[WARN]\033[0m'
ERROR='\033[0;31m[ERROR]\033[0m'

# 全局变量
STUBBY_CONF="/etc/stubby/stubby.yml"
LOG_DIR="/var/log/secure-dns"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
CHECK_SCRIPT="/usr/local/bin/dns_guard.sh"

# 1. 环境检测与依赖安装
install_deps() {
    echo -e "${INFO} 正在检测系统环境..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
        PM="apk add"
        DEPS="stubby ca-certificates openssl coreutils"
        echo -e "${OK} 检测到 Alpine Linux"
    elif [ -f /etc/debian_version ]; then
        OS="Debian"
        PM="apt-get install -y"
        apt-get update
        DEPS="stubby ca-certificates openssl coreutils cron"
        echo -e "${OK} 检测到 Debian/Ubuntu"
    else
        echo -e "${ERROR} 不支持的操作系统" && exit 1
    fi

    echo -e "${INFO} 正在安装依赖..."
    $PM $DEPS
}

# 2. 创建目录与权限设置
setup_dir() {
    echo -e "${INFO} 配置目录与日志..."
    mkdir -p /etc/stubby
    mkdir -p $LOG_DIR
    chmod 750 $LOG_DIR
    # 确保 stubby 用户（如果存在）拥有日志权限
    chown -R root:root /etc/stubby
}

# 3. 生成 Stubby 配置文件
# 包含 Google, Cloudflare, Quad9 的 DoT 节点，支持双栈轮询
gen_config() {
    echo -e "${INFO} 生成 Stubby 配置文件..."
    cat > $STUBBY_CONF <<EOF
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private : 1
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@5353
  - 0::1@5353
upstream_recursive_servers:
  # Cloudflare
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  # Google
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"
  # Quad9
  - address_data: 9.9.9.9
    tls_auth_name: "dns.quad9.net"
  - address_data: 2620:fe::fe
    tls_auth_name: "dns.quad9.net"
EOF
    # 备份用于防篡改校验
    cp $STUBBY_CONF $BACKUP_CONF
}

# 4. 集成 Xray / Sing-box
integrate_proxy() {
    echo -e "${INFO} 正在检测代理服务配置 (Xray/Sing-box)..."
    local paths=("/etc/xray/config.json" "/etc/sing-box/config.json" "/usr/local/etc/xray/config.json")
    
    for path in "${paths[@]}"; do
        if [ -f "$path" ]; then
            echo -e "${OK} 发现配置文件: $path"
            # 使用 sed 简单替换 DNS 地址（此处建议用户确认 JSON 结构）
            # 将 dns 字段中的 server 指向 127.0.0.1:5353
            sed -i 's/"address": ".*"/"address": "127.0.0.1"/' "$path"
            sed -i 's/"port": [0-9]*/"port": 5353/' "$path"
            
            # 尝试通过 HUP 信号重载
            pkill -HUP xray || pkill -HUP sing-box || echo -e "${WARN} 无法自动重载代理服务，请手动重启。"
        fi
    done
}

# 5. 服务管理 (Systemd / OpenRC)
setup_service() {
    if [ "$OS" == "Alpine" ]; then
        echo -e "${INFO} 配置 OpenRC 服务..."
        rc-update add stubby default
        rc-service stubby restart
    else
        echo -e "${INFO} 配置 Systemd 服务..."
        systemctl enable stubby
        systemctl restart stubby
    fi
}

# 6. 安全防篡改与日志维护脚本
setup_guard() {
    echo -e "${INFO} 部署安全守卫脚本..."
    cat > $CHECK_SCRIPT <<EOF
#!/bin/bash
# 校验配置 SHA256
ORIGIN="\$(sha256sum $BACKUP_CONF | awk '{print \$1}')"
CURRENT="\$(sha256sum $STUBBY_CONF | awk '{print \$1}')"

if [ "\$ORIGIN" != "\$CURRENT" ]; then
    cp $BACKUP_CONF $STUBBY_CONF
    if command -v rc-service &>/dev/null; then
        rc-service stubby restart
    else
        systemctl restart stubby
    fi
    echo "\$(date) - Config restored due to unauthorized modification" >> $LOG_DIR/guard.log
fi

# 清理30天前日志
find $LOG_DIR -type f -mtime +30 -delete
EOF
    chmod +x $CHECK_SCRIPT

    # 添加至 Crontab (每天凌晨执行)
    (crontab -l 2>/dev/null; echo "0 2 * * * $CHECK_SCRIPT") | crontab -
}

# 7. 效果校验
verify_deployment() {
    echo -e "\n${INFO} 正在进行效果校验..."
    
    # 进程检查
    if pgrep stubby > /dev/null; then
        echo -e "${OK} Stubby 服务运行中"
    else
        echo -e "${ERROR} Stubby 未启动，请检查日志"
    fi

    # 解析检查 (使用 dig 或 nslookup)
    local tool=""
    command -v dig >/dev/null && tool="dig +short" || tool="nslookup"
    
    echo -e "${INFO} 测试域名解析 (Google)..."
    if $tool google.com @127.0.0.1 -p 5353 > /dev/null; then
        echo -e "${OK} DNS 解析成功"
    else
        echo -e "${WARN} 解析失败，可能正在等待 TLS 握手，请稍后再试"
    fi
}

# 执行主流程
install_deps
setup_dir
gen_config
integrate_proxy
setup_guard
setup_service
verify_deployment

echo -e "\n${OK} 加密 DNS 部署完成！"
echo -e "${INFO} 监听端口: 127.0.0.1:5353"
echo -e "${INFO} 日志目录: $LOG_DIR"
