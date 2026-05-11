#!/usr/bin/env bash
# =========================================================
# SmartDNS Auto Installer + DoH Auto Detect
#
# 自动检测:
#   - Alpine / Debian
#   - systemd / OpenRC
#   - LXC / Docker / NAT
#   - IPv4 / IPv6
#   - SmartDNS version
#   - DoH support
#
# 自动:
#   - 安装 SmartDNS
#   - 动态生成配置
#   - 接管 resolv.conf
#   - 接管 dhcpcd DNS
#
# 兼容:
#   - Alpine
#   - Debian
#   - Ubuntu
#   - LXC
#   - NAT VPS
#
# =========================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

OS=""
INIT_SYSTEM=""
IS_LXC=0
IS_DOCKER=0
IS_NAT=0
HAS_IPV4=0
HAS_IPV6=0
HAS_DOH=0
SMARTDNS_VERSION=""

SMARTDNS_BIN="/usr/sbin/smartdns"
SMARTDNS_CONF="/etc/smartdns/smartdns.conf"

log() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

err() {
    echo -e "${RED}[✗]${NC} $1"
}

step() {
    echo
    echo -e "${CYAN}▶${NC} ${BLUE}$1${NC}"
}

require_root() {
    [ "$(id -u)" = "0" ] || {
        err "请使用 root 运行"
        exit 1
    }
}

detect_system() {
    step "检测系统"

    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    else
        err "不支持系统"
        exit 1
    fi

    log "系统: $OS"

    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="openrc"
    fi

    log "Init: $INIT_SYSTEM"

    if grep -qaE 'lxc|incus' /proc/1/cgroup 2>/dev/null; then
        IS_LXC=1
        warn "LXC/Incus 容器"
    fi

    if grep -qa docker /proc/1/cgroup 2>/dev/null; then
        IS_DOCKER=1
        warn "Docker 容器"
    fi

    GW=$(ip route | awk '/default/ {print $3}' | head -n1)

    if echo "$GW" | grep -Eq '^10\.|^172\.|^192\.168\.'; then
        IS_NAT=1
        warn "NAT 网络"
    fi
}

install_deps() {
    step "安装依赖"

    case "$OS" in

        alpine)
            apk update

            apk add --no-cache \
                curl \
                tar \
                bind-tools \
                iproute2 \
                ca-certificates
            ;;

        debian)
            apt-get update -y

            apt-get install -y \
                curl \
                tar \
                dnsutils \
                iproute2 \
                ca-certificates
            ;;
    esac

    log "依赖安装完成"
}

install_smartdns() {
    step "安装 SmartDNS"

    if command -v smartdns >/dev/null 2>&1; then
        SMARTDNS_VERSION=$(smartdns -v 2>/dev/null | head -n1 || true)

        log "已安装: ${SMARTDNS_VERSION:-unknown}"
        return
    fi

    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64)
            PKG_ARCH="x86_64"
            ;;
        aarch64)
            PKG_ARCH="aarch64"
            ;;
        *)
            err "不支持架构: $ARCH"
            exit 1
            ;;
    esac

    TMP_DIR=$(mktemp -d)

    cd "$TMP_DIR"

    curl -L -o smartdns.tar.gz \
    https://github.com/pymumu/smartdns/releases/latest/download/smartdns.1.2025.1.${PKG_ARCH}-linux-all.tar.gz

    tar -xzf smartdns.tar.gz

    install -m 755 smartdns/usr/sbin/smartdns "$SMARTDNS_BIN"

    mkdir -p /etc/smartdns

    cd /

    rm -rf "$TMP_DIR"

    SMARTDNS_VERSION=$("$SMARTDNS_BIN" -v 2>/dev/null | head -n1 || true)

    log "安装完成: ${SMARTDNS_VERSION:-unknown}"
}

detect_doh_support() {
    step "检测 DoH 支持"

    if "$SMARTDNS_BIN" -h 2>&1 | grep -qi https; then
        HAS_DOH=1
        log "支持 DoH"
    else
        warn "当前版本不支持 DoH"
    fi
}

detect_network() {
    step "检测 IPv4"

    if ping -4 -c1 1.1.1.1 >/dev/null 2>&1; then
        HAS_IPV4=1
        log "IPv4 可用"
    else
        warn "IPv4 不可用"
    fi

    step "检测 IPv6"

    if ping -6 -c1 2606:4700:4700::1111 >/dev/null 2>&1; then
        HAS_IPV6=1
        log "IPv6 可用"
    else
        warn "IPv6 不可用"
    fi
}

stop_conflict_dns() {
    step "关闭冲突 DNS"

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true

        log "systemd-resolved 已关闭"
    fi
}

generate_config() {
    step "生成 SmartDNS 配置"

    mkdir -p /etc/smartdns

    cat > "$SMARTDNS_CONF" <<EOF
bind 127.0.0.1:53

cache-size 4096
prefetch-domain yes
serve-expired yes

log-level error

response-mode fastest-ip
speed-check-mode ping,tcp:80,tcp:443

EOF

    if [ "$HAS_IPV6" = "1" ]; then
        cat >> "$SMARTDNS_CONF" <<EOF
bind [::1]:53
dualstack-ip-selection yes
EOF
    fi

    echo >> "$SMARTDNS_CONF"

    if [ "$HAS_DOH" = "1" ]; then

        cat >> "$SMARTDNS_CONF" <<EOF
server https://1.1.1.1/dns-query
server https://1.0.0.1/dns-query
server https://dns.google/dns-query
server https://8.8.8.8/dns-query
EOF

        if [ "$HAS_IPV6" = "1" ]; then
            cat >> "$SMARTDNS_CONF" <<EOF
server https://[2606:4700:4700::1111]/dns-query
server https://[2001:4860:4860::8888]/dns-query
EOF
        fi

        log "已启用 DoH"

    else

        cat >> "$SMARTDNS_CONF" <<EOF
server 1.1.1.1
server 1.0.0.1
server 8.8.8.8
server 8.8.4.4
EOF

        if [ "$HAS_IPV6" = "1" ]; then
            cat >> "$SMARTDNS_CONF" <<EOF
server 2606:4700:4700::1111
server 2001:4860:4860::8888
EOF
        fi

        warn "已 fallback 普通 DNS"
    fi

    log "配置生成完成"
}

take_over_resolv() {
    step "接管 resolv.conf"

    rm -f /etc/resolv.conf

    cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
options timeout:2
options attempts:2
options edns0
EOF

    if [ "$HAS_IPV6" = "1" ]; then
        echo "nameserver ::1" >> /etc/resolv.conf
    fi

    chmod 644 /etc/resolv.conf

    log "resolv.conf 已接管"
}

take_over_dhcpcd() {
    step "接管 dhcpcd"

    if [ -f /etc/dhcpcd.conf ]; then

        grep -q "nohook resolv.conf" /etc/dhcpcd.conf || \
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf

        cat > /etc/resolv.conf.head <<EOF
nameserver 127.0.0.1
EOF

        if [ "$HAS_IPV6" = "1" ]; then
            echo "nameserver ::1" >> /etc/resolv.conf.head
        fi

        log "dhcpcd 已接管"
    else
        warn "未发现 dhcpcd"
    fi
}

create_service() {
    step "创建服务"

    if [ "$INIT_SYSTEM" = "systemd" ]; then

cat > /etc/systemd/system/smartdns.service <<EOF
[Unit]
Description=SmartDNS
After=network.target

[Service]
ExecStart=${SMARTDNS_BIN} -f -c ${SMARTDNS_CONF}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable smartdns >/dev/null 2>&1

    else

cat > /etc/init.d/smartdns <<EOF
#!/sbin/openrc-run

command="${SMARTDNS_BIN}"
command_args="-f -c ${SMARTDNS_CONF}"
pidfile="/run/smartdns.pid"

depend() {
    need net
}
EOF

        chmod +x /etc/init.d/smartdns

        rc-update add smartdns default >/dev/null 2>&1 || true
    fi

    log "服务创建完成"
}

start_service() {
    step "启动 SmartDNS"

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart smartdns
    else
        rc-service smartdns restart
    fi

    sleep 2

    if ss -lnup | grep -q ":53"; then
        log "53 端口监听正常"
    else
        err "启动失败"
        exit 1
    fi
}

test_dns() {
    step "测试 DNS"

    if dig cloudflare.com @127.0.0.1 +short >/dev/null 2>&1; then
        log "DNS 正常"
    else
        err "DNS 解析失败"
    fi
}

show_result() {
    echo
    echo "═══════════════════════════════════════"
    echo "      SmartDNS 部署完成"
    echo "═══════════════════════════════════════"
    echo

    echo "系统:"
    echo "  $OS"

    echo
    echo "Init:"
    echo "  $INIT_SYSTEM"

    echo
    echo "SmartDNS:"
    echo "  ${SMARTDNS_VERSION:-unknown}"

    echo
    echo "DoH:"
    if [ "$HAS_DOH" = "1" ]; then
        echo "  Enabled"
    else
        echo "  Disabled"
    fi

    echo
    echo "监听:"
    echo "  127.0.0.1:53"

    if [ "$HAS_IPV6" = "1" ]; then
        echo "  [::1]:53"
    fi

    echo
    echo "resolv.conf:"
    cat /etc/resolv.conf

    echo
    echo "测试:"
    echo "  dig cloudflare.com @127.0.0.1"
    echo
}

main() {
    clear

    echo "╔══════════════════════════════════════╗"
    echo "║       SmartDNS Auto Installer       ║"
    echo "║         DoH Auto Detect             ║"
    echo "╚══════════════════════════════════════╝"

    require_root
    detect_system
    install_deps
    install_smartdns
    detect_doh_support
    detect_network
    stop_conflict_dns
    generate_config
    take_over_resolv
    take_over_dhcpcd
    create_service
    start_service
    test_dns
    show_result
}

main "$@"
