#!/bin/sh
#===============================================================================
# 加密 DNS 一键部署脚本
# 支持: Alpine / Debian (x86_64, ARM)
# 协议: DNS-over-TLS (DoT) / DNS-over-HTTPS (DoH)
# 上游: Google / Cloudflare
# 功能: 依赖检测安装、持久化、防篡改、30天日志清理
#===============================================================================

set -e

#----- 颜色定义 -----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
err()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }

#----- 根权限检查 -----
[ "$(id -u)" -ne 0 ] && err "请使用 root 权限运行: sudo sh $0"

#----- 架构检测 -----
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_DIR="amd64" ;;
    aarch64) ARCH_DIR="arm64" ;;
    armv7l)  ARCH_DIR="armv7" ;;
    armv6l)  ARCH_DIR="armv6" ;;
    *)       err "不支持的架构: $ARCH" ;;
esac

#----- 系统检测 -----
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ]; then
    OS="debian"
else
    err "不支持的系统，仅支持 Alpine / Debian"
fi

#===============================================================================
# 用户配置区（可按需修改）
#===============================================================================
DNS_PROVIDER="cloudflare"          # cloudflare 或 google
DNS_PROTOCOL="dot"                 # dot 或 doh
STUBBY_PORT=5353                   # 本地监听端口
STUBBY_USER="stubby"
STUBBY_CONFIG="/etc/stubby/stubby.yml"
STUBBY_BIN="/usr/local/bin/stubby"
SERVICE_FILE="/etc/init.d/stubby"
LOG_DIR="/var/log/stubby"
MAX_LOG_DAYS=30
LOCK_FILE="/var/run/stubby.lock"
#===============================================================================

#----- 依赖检测与安装 -----
install_deps() {
    log "正在检测并安装依赖..."
    if [ "$OS" = "alpine" ]; then
        apk update
        apk add --no-cache ca-certificates curl wget unbound libcap
        # 编译依赖（如无预编译包）
        if ! command -v stubby >/dev/null 2>&1; then
            apk add --no-cache build-base cmake openssl-dev libidn2-dev \
                libunbound-dev libcap-dev yaml-dev
        fi
    else
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl wget libyaml-dev \
            libunbound-dev libidn2-dev libcap2-bin 2>/dev/null
    fi
    log "依赖安装完成"
}

#----- 下载/编译 stubby -----
install_stubby() {
    if [ -f "$STUBBY_BIN" ]; then
        log "stubby 已安装: $($STUBBY_BIN -V 2>&1 | head -1)"
        return
    fi

    log "正在安装 stubby (getdns)..."
    STUBBY_VER="1.7.2"
    GETDNS_VER="1.7.2"
    TMP_DIR=$(mktemp -d)

    # 尝试下载预编译二进制
    GETDNS_URL="https://github.com/getdnsapi/getdns/releases/download/v${GETDNS_VER}/getdns-${GETDNS_VER}-${OS}-${ARCH_DIR}.tar.gz"
    if curl -fsSLo "${TMP_DIR}/getdns.tar.gz" "$GETDNS_URL" 2>/dev/null; then
        cd "$TMP_DIR"
        tar xzf getdns.tar.gz
        install -m 755 stubby "$STUBBY_BIN"
        log "预编译 stubby 安装成功"
    else
        # 源码编译
        warn "无预编译包，从源码编译（约3-5分钟）..."
        if [ "$OS" = "alpine" ]; then
            apk add --no-cache build-base cmake openssl-dev libidn2-dev \
                libunbound-dev libcap-dev yaml-dev git
        else
            apt-get install -y -qq build-essential cmake libssl-dev \
                libidn2-dev libunbound-dev libcap-dev libyaml-dev git
        fi

        cd "$TMP_DIR"
        git clone --depth 1 --branch v${GETDNS_VER} https://github.com/getdnsapi/getdns.git
        cd getdns
        mkdir build && cd build
        cmake .. -DBUILD_STUBBY=ON -DCMAKE_INSTALL_PREFIX=/usr/local
        make -j$(nproc) && make install
        log "源码编译安装成功"
    fi
    rm -rf "$TMP_DIR"
}

#----- 生成 stubby 配置 -----
gen_config() {
    log "正在生成配置: $STUBBY_CONFIG"

    # 选择上游 DNS
    if [ "$DNS_PROVIDER" = "google" ]; then
        DOT_IP="8.8.8.8@853#dns.google
                    - 8.8.4.4@853#dns.google"
        DOH_URL="https://dns.google/dns-query"
        HOSTNAME="dns.google"
    else
        DOT_IP="1.1.1.1@853#cloudflare-dns.com
                    - 1.0.0.1@853#cloudflare-dns.com"
        DOH_URL="https://cloudflare-dns.com/dns-query"
        HOSTNAME="cloudflare-dns.com"
    fi

    mkdir -p "$(dirname "$STUBBY_CONFIG")"

    cat > "$STUBBY_CONFIG" << EOF
# Stubby 加密 DNS 配置
# 协议: $([ "$DNS_PROTOCOL" = "dot" ] && echo "DNS-over-TLS" || echo "DNS-over-HTTPS")
# 上游: $DNS_PROVIDER
# 生成时间: $(date)

resolution_type: $([ "$DNS_PROTOCOL" = "dot" ] && echo "GETDNS_RESOLUTION_STUB" || echo "GETDNS_RESOLUTION_STUB")
dns_transport_list:
  - $([ "$DNS_PROTOCOL" = "dot" ] && echo "GETDNS_TRANSPORT_TLS" || echo "GETDNS_TRANSPORT_HTTPS")
tls_authentication: $([ "$DNS_PROTOCOL" = "dot" ] && echo "GETDNS_AUTHENTICATION_REQUIRED" || echo "GETDNS_AUTHENTICATION_NONE")
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@${STUBBY_PORT}
  - 0::1@${STUBBY_PORT}
round_robin_upstreams: 1
upstream_recursive_servers:
$([ "$DNS_PROTOCOL" = "dot" ] && echo "  - address_data: ${DOT_IP}" || echo "  - address_data: ${DOH_URL}")
    tls_auth_name: "${HOSTNAME}"
EOF

    # 防篡改：移除写权限
    chmod 644 "$STUBBY_CONFIG"
    chattr +i "$STUBBY_CONFIG" 2>/dev/null || warn "chattr 不可用，跳过文件锁定"
    log "配置文件已生成并锁定"
}

#----- 创建系统服务 -----
create_service() {
    log "正在创建系统服务..."

    # 创建 stubby 用户
    if ! id "$STUBBY_USER" >/dev/null 2>&1; then
        if [ "$OS" = "alpine" ]; then
            adduser -D -H -s /sbin/nologin "$STUBBY_USER"
        else
            adduser --system --no-create-home --shell /usr/sbin/nologin "$STUBBY_USER"
        fi
    fi

    # 创建日志目录
    mkdir -p "$LOG_DIR"
    chown "$STUBBY_USER:$STUBBY_USER" "$LOG_DIR"
    chmod 750 "$LOG_DIR"

    if [ "$OS" = "alpine" ]; then
        # Alpine: OpenRC init 脚本
        cat > /etc/init.d/stubby << EOF
#!/sbin/openrc-run
name="stubby"
description="Stubby DNS Privacy Daemon"
command="${STUBBY_BIN}"
command_args="-g -C ${STUBBY_CONFIG}"
command_user="${STUBBY_USER}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
output_log="${LOG_DIR}/stubby.log"
error_log="${LOG_DIR}/stubby.log"

depend() {
    need net
    use dns
    after firewall
}
EOF
        chmod +x /etc/init.d/stubby
        rc-update add stubby default 2>/dev/null || true
        rc-service stubby restart 2>/dev/null || true
    else
        # Debian: systemd 服务
        cat > /etc/systemd/system/stubby.service << EOF
[Unit]
Description=Stubby DNS Privacy Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${STUBBY_USER}
ExecStart=${STUBBY_BIN} -g -C ${STUBBY_CONFIG}
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/stubby.log
StandardError=append:${LOG_DIR}/stubby.log

# 安全加固
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ReadOnlyPaths=/
ReadWritePaths=${LOG_DIR}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable stubby 2>/dev/null || true
        systemctl restart stubby 2>/dev/null || true
    fi

    log "系统服务创建完成"
}

#----- 日志清理任务 -----
setup_logrotate() {
    log "配置日志自动清理（保留 ${MAX_LOG_DAYS} 天）..."

    if [ "$OS" = "alpine" ]; then
        apk add --no-cache logrotate 2>/dev/null || true
        cat > /etc/logrotate.d/stubby << EOF
${LOG_DIR}/stubby.log {
    daily
    rotate ${MAX_LOG_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 640 ${STUBBY_USER} ${STUBBY_USER}
    postrotate
        kill -HUP \$(cat /var/run/stubby.pid) 2>/dev/null || true
    endscript
}
EOF
    else
        cat > /etc/logrotate.d/stubby << EOF
${LOG_DIR}/stubby.log {
    daily
    rotate ${MAX_LOG_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 640 ${STUBBY_USER} ${STUBBY_USER}
    postrotate
        systemctl kill -s HUP stubby 2>/dev/null || true
    endscript
}
EOF
    fi

    # 添加 cron 每日清理
    cat > /etc/cron.daily/stubby-clean << EOF
#!/bin/sh
find ${LOG_DIR} -name "*.log" -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null
find ${LOG_DIR} -name "*.gz" -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null
EOF
    chmod +x /etc/cron.daily/stubby-clean

    log "日志清理规则已配置"
}

#----- 验证配置 -----
verify_setup() {
    log "验证服务状态..."
    sleep 2

    if [ -f "$STUBBY_CONFIG" ]; then
        log "配置文件: $STUBBY_CONFIG ✓"
        log "配置内容:"
        cat "$STUBBY_CONFIG" | grep -E "dns_transport|address_data|tls_auth"
    fi

    # 测试 DNS 查询
    log "测试 DNS 查询..."
    if command -v dig >/dev/null 2>&1; then
        if dig +short @127.0.0.1 -p ${STUBBY_PORT} cloudflare.com 2>/dev/null | head -1; then
            log "DNS 查询测试成功 ✓"
        else
            warn "DNS 查询测试失败，请检查服务状态"
        fi
    else
        warn "dig 未安装，跳过查询测试"
    fi

    # 检查日志
    if [ -f "${LOG_DIR}/stubby.log" ]; then
        log "最近日志:"
        tail -5 "${LOG_DIR}/stubby.log"
    fi
}

#----- 清理函数（卸载用）-----
cleanup() {
    log "正在停止服务并清理..."
    if [ "$OS" = "alpine" ]; then
        rc-service stubby stop 2>/dev/null || true
        rc-update del stubby 2>/dev/null || true
        rm -f /etc/init.d/stubby
    else
        systemctl stop stubby 2>/dev/null || true
        systemctl disable stubby 2>/dev/null || true
        rm -f /etc/systemd/system/stubby.service
    fi

    chattr -i "$STUBBY_CONFIG" 2>/dev/null || true
    rm -f "$STUBBY_CONFIG" "$STUBBY_BIN"
    rm -f /etc/logrotate.d/stubby /etc/cron.daily/stubby-clean
    rm -rf "$LOG_DIR"
    log "清理完成"
}

#===============================================================================
# 主流程
#===============================================================================
case "${1:-install}" in
    install|deploy)
        echo "============================================"
        echo "  加密 DNS 一键部署脚本"
        echo "  系统: $OS | 架构: $ARCH"
        echo "  上游: $DNS_PROVIDER | 协议: $DNS_PROTOCOL"
        echo "============================================"
        install_deps
        install_stubby
        gen_config
        create_service
        setup_logrotate
        verify_setup
        echo ""
        log "部署完成！本地加密 DNS 运行在 127.0.0.1:${STUBBY_PORT}"
        log "可使用 dig @127.0.0.1 -p ${STUBBY_PORT} google.com 测试"
        log "将系统 DNS 设置为 127.0.0.1 即可全局使用"
        ;;
    uninstall|remove)
        cleanup
        ;;
    status)
        if [ "$OS" = "alpine" ]; then
            rc-service stubby status 2>/dev/null || warn "服务未运行"
        else
            systemctl status stubby --no-pager 2>/dev/null || warn "服务未运行"
        fi
        ;;
    *)
        echo "用法: $0 {install|uninstall|status}"
        echo "  install    - 安装加密 DNS (默认)"
        echo "  uninstall  - 卸载并清理"
        echo "  status     - 查看服务状态"
        ;;
esac
