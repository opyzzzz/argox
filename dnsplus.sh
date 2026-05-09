#!/bin/sh
#===============================================================================
# 加密 DNS 一键部署脚本 v2.0
# 支持: Alpine / Debian (x86_64, ARM)
# 协议: DNS-over-TLS (DoT) / DNS-over-HTTPS (DoH)
# 上游: Google / Cloudflare
# 功能: 依赖检测安装、持久化、防篡改、30天日志清理
#===============================================================================

set -e

#----- 颜色定义 -----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
err()  { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }
info() { printf "${BLUE}[*]${NC} %s\n" "$1"; }

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
    ALPINE_VER=$(cat /etc/alpine-release | cut -d. -f1,2)
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
LOG_DIR="/var/log/stubby"
MAX_LOG_DAYS=30
#===============================================================================

#----- 依赖检测与安装 -----
install_deps_alpine() {
    log "Alpine 系统：检测并安装依赖..."

    # 基础依赖
    apk update
    apk add --no-cache \
        ca-certificates \
        curl \
        wget \
        libcap \
        openssl \
        yaml \
        yaml-dev \
        openssl-dev \
        openssl-libs-static \
        libidn2 \
        libidn2-dev \
        libunbound \
        unbound-dev \
        build-base \
        cmake \
        git \
        pkgconfig

    # 检查是否已有 stubby
    if command -v stubby >/dev/null 2>&1; then
        log "stubby 已通过包管理器安装"
        STUBBY_BIN=$(command -v stubby)
        return
    fi

    # 尝试从社区仓库安装
    if apk search stubby 2>/dev/null | grep -q stubby; then
        log "从 Alpine 仓库安装 stubby..."
        apk add --no-cache stubby
        STUBBY_BIN=$(command -v stubby)
        return
    fi

    log "Alpine 依赖安装完成（将编译安装 stubby）"
}

install_deps_debian() {
    log "Debian 系统：检测并安装依赖..."
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    # 尝试直接安装 stubby
    if apt-cache show stubby >/dev/null 2>&1; then
        log "从 Debian 仓库安装 stubby..."
        apt-get install -y -qq stubby
        STUBBY_BIN=$(command -v stubby)
        return
    fi

    # 安装编译依赖
    apt-get install -y -qq \
        ca-certificates \
        curl \
        wget \
        libyaml-dev \
        libunbound-dev \
        libidn2-dev \
        libssl-dev \
        libcap2-bin \
        build-essential \
        cmake \
        git \
        pkg-config

    log "Debian 依赖安装完成（将编译安装 stubby）"
}

install_deps() {
    if [ "$OS" = "alpine" ]; then
        install_deps_alpine
    else
        install_deps_debian
    fi
}

#----- 编译安装 stubby -----
compile_stubby() {
    if [ -f "$STUBBY_BIN" ] && [ -x "$STUBBY_BIN" ]; then
        log "stubby 已安装: $STUBBY_BIN"
        return
    fi

    # 如果已经通过包管理器安装
    if command -v stubby >/dev/null 2>&1; then
        STUBBY_BIN=$(command -v stubby)
        log "使用系统 stubby: $STUBBY_BIN"
        return
    fi

    log "编译安装 stubby (getdns)..."

    GETDNS_VER="1.7.3"
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"

    # 克隆 getdns 源码
    git clone --depth 1 --branch v${GETDNS_VER} \
        https://github.com/getdnsapi/getdns.git 2>/dev/null || \
        git clone --depth 1 \
        https://github.com/getdnsapi/getdns.git

    cd getdns
    git submodule update --init --depth 1 2>/dev/null || true

    # 编译配置
    mkdir -p build && cd build
    cmake .. \
        -DBUILD_STUBBY=ON \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DENABLE_STATIC=ON \
        -DCMAKE_BUILD_TYPE=Release

    make -j$(nproc)
    make install

    # 验证
    if [ -f /usr/local/bin/stubby ]; then
        STUBBY_BIN="/usr/local/bin/stubby"
        log "stubby 编译安装成功"
    else
        err "stubby 编译失败"
    fi

    rm -rf "$TMP_DIR"
}

#----- 生成 stubby 配置 -----
gen_config() {
    log "生成配置文件: $STUBBY_CONFIG"

    mkdir -p "$(dirname "$STUBBY_CONFIG")"

    # DNS 提供商配置
    if [ "$DNS_PROVIDER" = "google" ]; then
        if [ "$DNS_PROTOCOL" = "dot" ]; then
            UPSTREAM_CONFIG="  - address_data: 8.8.8.8@853#dns.google
  - address_data: 8.8.4.4@853#dns.google"
        else
            UPSTREAM_CONFIG="  - address_data: https://dns.google/dns-query"
        fi
        AUTH_NAME="dns.google"
    else
        if [ "$DNS_PROTOCOL" = "dot" ]; then
            UPSTREAM_CONFIG="  - address_data: 1.1.1.1@853#cloudflare-dns.com
  - address_data: 1.0.0.1@853#cloudflare-dns.com"
        else
            UPSTREAM_CONFIG="  - address_data: https://cloudflare-dns.com/dns-query"
        fi
        AUTH_NAME="cloudflare-dns.com"
    fi

    # 传输协议
    if [ "$DNS_PROTOCOL" = "dot" ]; then
        TRANSPORT="GETDNS_TRANSPORT_TLS"
        AUTH_MODE="GETDNS_AUTHENTICATION_REQUIRED"
    else
        TRANSPORT="GETDNS_TRANSPORT_HTTPS"
        AUTH_MODE="GETDNS_AUTHENTICATION_NONE"
    fi

    cat > "$STUBBY_CONFIG" << EOF
#===============================================================================
# Stubby 加密 DNS 配置
# 协议: $([ "$DNS_PROTOCOL" = "dot" ] && echo "DNS-over-TLS (DoT)" || echo "DNS-over-HTTPS (DoH)")
# 上游: $DNS_PROVIDER
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
#===============================================================================

resolution_type: GETDNS_RESOLUTION_STUB

dns_transport_list:
  - ${TRANSPORT}

tls_authentication: ${AUTH_MODE}

tls_query_padding_blocksize: 128

edns_client_subnet_private: 1

idle_timeout: 10000

listen_addresses:
  - 127.0.0.1@${STUBBY_PORT}
  - 0::1@${STUBBY_PORT}

round_robin_upstreams: 1

appdata_dir: "/var/cache/stubby"

upstream_recursive_servers:
${UPSTREAM_CONFIG}
    tls_auth_name: "${AUTH_NAME}"
EOF

    # 创建缓存目录
    mkdir -p /var/cache/stubby
    
    # 防篡改设置
    chmod 644 "$STUBBY_CONFIG"
    if command -v chattr >/dev/null 2>&1; then
        chattr +i "$STUBBY_CONFIG" 2>/dev/null || warn "chattr 不可用，跳过文件锁定"
    fi

    log "配置文件已生成并锁定"
}

#----- 创建系统服务 -----
create_service() {
    log "创建系统服务..."

    # 创建 stubby 用户
    if ! id "$STUBBY_USER" >/dev/null 2>&1; then
        if [ "$OS" = "alpine" ]; then
            adduser -D -H -s /sbin/nologin -g "Stubby DNS" "$STUBBY_USER"
        else
            adduser --system --no-create-home --group --shell /usr/sbin/nologin \
                --gecos "Stubby DNS" "$STUBBY_USER"
        fi
    fi

    # 创建日志目录
    mkdir -p "$LOG_DIR"
    chown "$STUBBY_USER:$STUBBY_USER" "$LOG_DIR"
    chmod 750 "$LOG_DIR"

    if [ "$OS" = "alpine" ]; then
        # Alpine OpenRC 服务
        cat > /etc/init.d/stubby << 'INITEOF'
#!/sbin/openrc-run
name="stubby"
description="Stubby DNS Privacy Daemon"

command="/usr/local/bin/stubby"
command_args="-g -C /etc/stubby/stubby.yml"
command_user="stubby"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true

output_log="/var/log/stubby/stubby.log"
error_log="/var/log/stubby/stubby.log"

depend() {
    need net
    use dns
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o stubby:stubby /var/cache/stubby
}
INITEOF

        chmod +x /etc/init.d/stubby
        rc-update add stubby default 2>/dev/null || true
        
        # 停止旧服务（如果存在）
        rc-service stubby stop 2>/dev/null || true
        sleep 1
        rc-service stubby start 2>/dev/null || true

    else
        # Debian systemd 服务
        cat > /etc/systemd/system/stubby.service << EOF
[Unit]
Description=Stubby DNS Privacy Daemon
Documentation=https://dnsprivacy.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${STUBBY_USER}
Group=${STUBBY_USER}
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
ReadWritePaths=${LOG_DIR} /var/cache/stubby
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable stubby 2>/dev/null || true
        systemctl restart stubby 2>/dev/null || true
    fi

    log "系统服务创建完成"
}

#----- 日志清理配置 -----
setup_logrotate() {
    log "配置日志自动清理（保留 ${MAX_LOG_DAYS} 天）..."

    # Logrotate 配置
    mkdir -p /etc/logrotate.d
    cat > /etc/logrotate.d/stubby << EOF
${LOG_DIR}/*.log {
    daily
    rotate ${MAX_LOG_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 640 ${STUBBY_USER} ${STUBBY_USER}
}
EOF

    # Cron 定时清理
    if [ -d /etc/cron.daily ]; then
        cat > /etc/cron.daily/stubby-clean << EOF
#!/bin/sh
# 清理 ${MAX_LOG_DAYS} 天前的日志
find ${LOG_DIR} -type f \( -name "*.log.*" -o -name "*.gz" \) -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null
EOF
        chmod +x /etc/cron.daily/stubby-clean
    elif [ -d /etc/periodic/daily ]; then
        # Alpine 使用 periodic
        cat > /etc/periodic/daily/stubby-clean << EOF
#!/bin/sh
find ${LOG_DIR} -type f \( -name "*.log.*" -o -name "*.gz" \) -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null
EOF
        chmod +x /etc/periodic/daily/stubby-clean
    fi

    log "日志清理规则已配置"
}

#----- DNS 测试工具安装 -----
install_dnsutils() {
    if [ "$OS" = "alpine" ]; then
        apk add --no-cache bind-tools 2>/dev/null || true
    else
        apt-get install -y -qq dnsutils 2>/dev/null || true
    fi
}

#----- 验证部署 -----
verify_setup() {
    log "验证部署..."

    # 等待服务启动
    sleep 2

    # 检查进程
    if pidof stubby >/dev/null 2>&1; then
        log "✓ stubby 进程运行中 (PID: $(pidof stubby))"
    else
        warn "✗ stubby 进程未运行"
        log "查看日志: tail -f ${LOG_DIR}/stubby.log"
        return
    fi

    # 检查端口
    if netstat -tlnp 2>/dev/null | grep -q ":${STUBBY_PORT}" || \
       ss -tlnp 2>/dev/null | grep -q ":${STUBBY_PORT}"; then
        log "✓ 监听端口 ${STUBBY_PORT}"
    fi

    # DNS 查询测试
    log "测试 DNS 查询..."
    install_dnsutils
    
    TEST_RESULT=$(dig +short @127.0.0.1 -p ${STUBBY_PORT} cloudflare.com 2>/dev/null)
    if [ -n "$TEST_RESULT" ]; then
        info "✓ DNS 查询成功: $TEST_RESULT"
        
        # DNS 泄露测试
        log "进行 DNS 泄露测试..."
        WHOAMI=$(dig +short @127.0.0.1 -p ${STUBBY_PORT} whoami.akamai.net 2>/dev/null)
        if [ -n "$WHOAMI" ]; then
            info "查询来源 IP: $WHOAMI"
        fi
    else
        warn "✗ DNS 查询失败，检查日志"
        tail -10 "${LOG_DIR}/stubby.log" 2>/dev/null
    fi
}

#----- 显示使用说明 -----
show_usage() {
    echo ""
    echo "============================================"
    printf "${GREEN}  加密 DNS 部署完成！${NC}\n"
    echo "============================================"
    printf "本地地址: ${YELLOW}127.0.0.1:${STUBBY_PORT}${NC}\n"
    echo ""
    echo "测试命令:"
    printf "  dig @127.0.0.1 -p ${STUBBY_PORT} google.com\n"
    echo ""
    echo "系统 DNS 设置:"
    echo "  # 临时测试"
    printf "  echo 'nameserver 127.0.0.1' > /etc/resolv.conf\n"
    echo ""
    echo "  # Alpine 永久设置"
    echo "  echo 'nameserver 127.0.0.1' > /etc/resolv.conf.head"
    echo ""
    echo "服务管理:"
    if [ "$OS" = "alpine" ]; then
        echo "  rc-service stubby {start|stop|restart|status}"
        echo "  rc-update add stubby default  # 开机自启"
    else
        echo "  systemctl {start|stop|restart|status} stubby"
        echo "  systemctl enable stubby       # 开机自启"
    fi
    echo ""
    echo "配置文件: ${STUBBY_CONFIG}"
    echo "日志文件: ${LOG_DIR}/stubby.log"
    echo "============================================"
}

#----- 卸载清理 -----
cleanup() {
    log "停止服务并清理..."

    # 停止服务
    if [ "$OS" = "alpine" ]; then
        rc-service stubby stop 2>/dev/null || true
        rc-update del stubby 2>/dev/null || true
        rm -f /etc/init.d/stubby
    else
        systemctl stop stubby 2>/dev/null || true
        systemctl disable stubby 2>/dev/null || true
        rm -f /etc/systemd/system/stubby.service
        systemctl daemon-reload
    fi

    # 移除文件锁定
    if [ -f "$STUBBY_CONFIG" ]; then
        chattr -i "$STUBBY_CONFIG" 2>/dev/null || true
    fi

    # 清理文件
    rm -f "$STUBBY_CONFIG"
    rm -f /etc/logrotate.d/stubby
    rm -f /etc/cron.daily/stubby-clean
    rm -f /etc/periodic/daily/stubby-clean
    rm -rf "$LOG_DIR"
    rm -rf /var/cache/stubby

    # 删除用户
    if id "$STUBBY_USER" >/dev/null 2>&1; then
        if [ "$OS" = "alpine" ]; then
            deluser "$STUBBY_USER" 2>/dev/null || true
        else
            deluser "$STUBBY_USER" 2>/dev/null || true
        fi
    fi

    log "清理完成"
}

#===============================================================================
# 主流程
#===============================================================================
main() {
    case "${1:-install}" in
        install|deploy)
            echo "============================================"
            printf "${GREEN}  加密 DNS 一键部署脚本${NC}\n"
            echo "============================================"
            printf "系统: ${YELLOW}$OS${NC} | 架构: ${YELLOW}$ARCH${NC}\n"
            printf "上游: ${YELLOW}$DNS_PROVIDER${NC} | 协议: ${YELLOW}$DNS_PROTOCOL${NC}\n"
            echo "============================================"
            echo ""
            
            install_deps
            compile_stubby
            gen_config
            create_service
            setup_logrotate
            verify_setup
            show_usage
            ;;
            
        uninstall|remove|clean)
            cleanup
            ;;
            
        status|check)
            echo "=== Stubby 加密 DNS 状态 ==="
            if [ "$OS" = "alpine" ]; then
                rc-service stubby status 2>/dev/null || warn "服务未运行"
            else
                systemctl status stubby --no-pager 2>/dev/null || warn "服务未运行"
            fi
            
            if [ -f "${LOG_DIR}/stubby.log" ]; then
                echo ""
                echo "最近日志:"
                tail -5 "${LOG_DIR}/stubby.log"
            fi
            ;;
            
        restart)
            log "重启服务..."
            if [ "$OS" = "alpine" ]; then
                rc-service stubby restart
            else
                systemctl restart stubby
            fi
            ;;
            
        logs)
            if [ -f "${LOG_DIR}/stubby.log" ]; then
                tail -f "${LOG_DIR}/stubby.log"
            else
                warn "日志文件不存在"
            fi
            ;;
            
        test)
            log "测试 DNS 查询..."
            install_dnsutils
            echo "查询 google.com:"
            dig +short @127.0.0.1 -p ${STUBBY_PORT} google.com
            echo ""
            echo "查询 cloudflare.com:"
            dig +short @127.0.0.1 -p ${STUBBY_PORT} cloudflare.com
            ;;
            
        *)
            echo "用法: $0 {install|uninstall|status|restart|logs|test}"
            echo ""
            echo "  install    - 安装部署加密 DNS (默认)"
            echo "  uninstall  - 完全卸载清理"
            echo "  status     - 查看服务状态和日志"
            echo "  restart    - 重启服务"
            echo "  logs       - 实时查看日志"
            echo "  test       - 测试 DNS 查询"
            echo ""
            echo "配置说明:"
            echo "  编辑脚本修改 DNS_PROVIDER (cloudflare/google)"
            echo "  编辑脚本修改 DNS_PROTOCOL (dot/doh)"
            echo "  编辑脚本修改 STUBBY_PORT (默认 5353)"
            ;;
    esac
}

# 执行主函数
main "$@"
