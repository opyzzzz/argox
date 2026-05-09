#!/bin/bash

# =================================================================
# 脚本名称: Secure-DNS 终极暴力部署脚本 (Stubby 方案)
# 适用系统: Debian / Ubuntu / Alpine (x86_64 / ARM)
# 针对核心痛点: 解决容器环境重启后 resolv.conf 被强行覆盖的问题
# =================================================================

INFO='\033[0;32m[INFO]\033[0m'
OK='\033[0;34m[OK]\033[0m'
WARN='\033[0;33m[WARN]\033[0m'
ERROR='\033[0;31m[ERROR]\033[0m'

STUBBY_CONF="/etc/stubby/stubby.yml"
RESOLV_CONF="/etc/resolv.conf"
LOG_DIR="/var/log/secure-dns"
DAEMON_SCRIPT="/usr/local/bin/dns_daemon.sh"
SHA_FILE="/etc/stubby/stubby.yml.sha256"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"

# 1. 系统依赖安装
install_deps() {
    echo -e "${INFO} 正在安装系统核心组件..."
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
        # Alpine 必备组件，net-tools 提供 netstat 检查
        apk add stubby ca-certificates openssl coreutils e2fsprogs-extra bind-tools net-tools sed bash
    else
        OS="Debian"
        apt-get update
        apt-get install -y stubby ca-certificates openssl coreutils e2fsprogs dnsutils net-tools sed bash
        systemctl stop systemd-resolved 2>/dev/null && systemctl disable systemd-resolved 2>/dev/null
    fi
}

# 2. Stubby DoT 高性能配置
config_stubby() {
    echo -e "${INFO} 正在配置 Stubby 加密链路 (DoT)..."
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
  # Cloudflare (Dual-Stack)
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
  # Google (Dual-Stack)
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
EOF
    sha256sum $STUBBY_CONF > $SHA_FILE
    cp $STUBBY_CONF $BACKUP_CONF
    echo -e "${OK} Stubby 配置已备份并加固。"
}

# 3. 部署暴力守护进程 (每 5 秒强制修正)
deploy_daemon() {
    echo -e "${INFO} 正在部署暴力守护进程 (秒级同步)..."
    
    cat > $DAEMON_SCRIPT <<EOF
#!/bin/bash
while true; do
    # 1. 检查服务存活 (端口检测比进程检测更准)
    if ! netstat -tunlp | grep -q ":53 "; then
        if [ -x /sbin/rc-service ]; then rc-service stubby restart; else systemctl restart stubby; fi
    fi

    # 2. 暴力修正 resolv.conf
    # 如果第一行不是 127.0.0.1，则强制覆盖
    if [ "\$(head -n 1 $RESOLV_CONF | grep -o '127.0.0.1')" != "127.0.0.1" ]; then
        chattr -i $RESOLV_CONF 2>/dev/null
        echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
        chattr +i $RESOLV_CONF 2>/dev/null
    fi

    # 3. 配置完整性校验
    sha256sum -c $SHA_FILE > /dev/null 2>&1 || (cp $BACKUP_CONF $STUBBY_CONF && (rc-service stubby restart 2>/dev/null || systemctl restart stubby))

    # 4. 这里的 sleep 时间决定了你的被篡改窗口期
    sleep 5
done
EOF
    chmod +x $DAEMON_SCRIPT

    # 创建 OpenRC 或 Systemd 启动服务
    if [ "$OS" == "Alpine" ]; then
        cat > /etc/init.d/dns-daemon <<EOF
#!/sbin/openrc-run
name="DNS Security Daemon"
description="Force 127.0.0.1 to resolv.conf"
command="$DAEMON_SCRIPT"
command_background=true
pidfile="/run/dns-daemon.pid"
EOF
        chmod +x /etc/init.d/dns-daemon
        rc-update add dns-daemon default
        rc-service dns-daemon restart
    else
        cat > /etc/systemd/system/dns-daemon.service <<EOF
[Unit]
Description=DNS Security Daemon
After=network.target

[Service]
ExecStart=$DAEMON_SCRIPT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable dns-daemon
        systemctl restart dns-daemon
    fi
}

# 4. 彻底屏蔽 dhcpcd/resolvconf 修改权限
disable_dhcp_overwrites() {
    echo -e "${INFO} 正在针对容器环境封锁 DHCP 修改入口..."
    
    # 彻底禁用 dhcpcd 钩子
    [ -f /etc/dhcpcd.conf ] && echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    
    # 修改 resolvconf 默认 head (如果存在)
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > /etc/resolv.conf.head 2>/dev/null
    
    # 这种办法通常最有效：将 resolv.conf 的父目录设为只读或直接暴力锁定文件
    chattr -i $RESOLV_CONF 2>/dev/null
    echo -e "nameserver 127.0.0.1\nnameserver ::1" > $RESOLV_CONF
    chattr +i $RESOLV_CONF 2>/dev/null
}

# 5. 代理集成 (HUP 信号刷新)
integrate_proxy() {
    echo -e "${INFO} 正在扫描并集成代理软件..."
    local cfgs=("/etc/xray/config.json" "/etc/sing-box/config.json" "/usr/local/etc/xray/config.json" "/root/sing-box/config.json")
    for c in "${cfgs[@]}"; do
        if [ -f "$c" ]; then
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$c"
            pkill -HUP xray 2>/dev/null || pkill -HUP sing-box 2>/dev/null
            echo -e "${OK} 已集成: $c"
        fi
    done
}

# 6. 清理与校验
finalize() {
    echo -e "${INFO} 正在启动服务并校验解析状态..."
    if [ "$OS" == "Alpine" ]; then
        rc-update add stubby default && rc-service stubby restart
    else
        systemctl enable stubby && systemctl restart stubby
    fi

    sleep 2
    # 模拟外部解析
    if nslookup google.com 127.0.0.1 > /dev/null 2>&1; then
        echo -e "${OK} DoT 链路解析正常。"
    else
        echo -e "${ERROR} DoT 链路解析失败，请检查 853 端口是否被防火墙拦截。"
    fi

    # 验证文件接管
    if grep -q "127.0.0.1" "$RESOLV_CONF"; then
        echo -e "${OK} 全局解析已锁定至 127.0.0.1。"
    fi
}

# --- 运行流程 ---
install_deps
config_stubby
disable_dhcp_overwrites
integrate_proxy
deploy_daemon
finalize

echo -e "\n${OK} 暴力部署完成！"
echo -e "${INFO} 守护进程 [dns-daemon] 已启动。即使系统重置了 resolv.conf，它也会在 5 秒内强制改回。"
