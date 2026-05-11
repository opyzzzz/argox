#!/usr/bin/env bash

# =========================================================
# Secure-DNS Lite Final
# Unbound + DoT
# Alpine / Debian / Ubuntu
# Compatible with:
# - VPS
# - LXC
# - Incus
# - OpenVZ
# - KVM
# =========================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

UNBOUND_CONF="/etc/unbound/unbound.conf"

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
    echo -e "\n${CYAN}▶${NC} ${BLUE}$1${NC}"
}

require_root() {
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 运行"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    else
        err "不支持的系统"
        exit 1
    fi

    log "系统: $OS"
}

install_deps() {
    step "安装依赖"

    case "$OS" in
        alpine)
            apk update
            apk add --no-cache \
                unbound \
                unbound-openrc \
                ca-certificates \
                bind-tools \
                curl
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y \
                unbound \
                unbound-anchor \
                dnsutils \
                ca-certificates \
                curl
            ;;
    esac

    log "依赖安装完成"
}

detect_ip() {
    step "检测 IPv4"

    IPV4_OK=false
    IPV6_OK=false

    if ping -4 -c1 1.1.1.1 >/dev/null 2>&1; then
        IPV4_OK=true
        log "IPv4 可用"
    else
        warn "IPv4 不可用"
    fi

    step "检测 IPv6"

    if ping -6 -c1 2606:4700:4700::1111 >/dev/null 2>&1; then
        IPV6_OK=true
        log "IPv6 可用"
    else
        warn "IPv6 不可用"
    fi
}

disable_system_dns() {
    step "处理系统 DNS"

    case "$OS" in
        debian)
            if systemctl is-active systemd-resolved >/dev/null 2>&1; then
                systemctl disable --now systemd-resolved || true
                log "已关闭 systemd-resolved"
            fi
            ;;
    esac
}

configure_unbound() {
    step "配置 Unbound"

    mkdir -p /etc/unbound

    cat > "$UNBOUND_CONF" <<EOF
server:
    username: ""
    interface: 127.0.0.1
    port: 53

    do-ip4: yes
    do-udp: yes
    do-tcp: yes

    do-ip6: $( $IPV6_OK && echo yes || echo no )

    verbosity: 0

    prefetch: yes
    prefetch-key: yes

    cache-min-ttl: 300
    cache-max-ttl: 14400

    rrset-roundrobin: yes

    edns-buffer-size: 1232

    hide-identity: yes
    hide-version: yes

    qname-minimisation: yes

    harden-glue: yes
    harden-dnssec-stripped: yes

    use-caps-for-id: no

    auto-trust-anchor-file: "/var/lib/unbound/root.key"

forward-zone:
    name: "."

EOF

    if $IPV4_OK; then
        cat >> "$UNBOUND_CONF" <<EOF
    forward-tls-upstream: yes

    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com

    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 8.8.4.4@853#dns.google

EOF
    fi

    if $IPV6_OK; then
        cat >> "$UNBOUND_CONF" <<EOF
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com

    forward-addr: 2001:4860:4860::8888@853#dns.google
    forward-addr: 2001:4860:4860::8844@853#dns.google

EOF
    fi

    log "Unbound 配置完成"
}

setup_resolvconf() {
    step "接管 resolv.conf"

    case "$OS" in

        alpine)
            mkdir -p /etc

            cat > /etc/resolv.conf.head <<EOF
nameserver 127.0.0.1
EOF

            if $IPV6_OK; then
                echo "nameserver ::1" >> /etc/resolv.conf.head
            fi

            if command -v rc-service >/dev/null 2>&1; then
                rc-service dhcpcd restart || true
            fi

            ;;

        debian)

            rm -f /etc/resolv.conf

            cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
options timeout:2
options attempts:2
options edns0
EOF

            if $IPV6_OK; then
                sed -i '2i nameserver ::1' /etc/resolv.conf
            fi

            ;;
    esac

    log "系统 DNS 已配置"
}

start_unbound() {
    step "启动 Unbound"

    unbound-checkconf "$UNBOUND_CONF"

    case "$OS" in
        alpine)

            rc-update add unbound default >/dev/null 2>&1 || true

            rc-service unbound restart

            ;;

        debian)

            systemctl enable unbound >/dev/null 2>&1 || true

            systemctl restart unbound

            ;;
    esac

    sleep 2

    if dig cloudflare.com @127.0.0.1 +short >/dev/null 2>&1; then
        log "Unbound 启动成功"
    else
        err "Unbound 启动失败"

        case "$OS" in
            alpine)
                rc-service unbound status || true
                ;;
            debian)
                systemctl status unbound --no-pager || true
                ;;
        esac

        exit 1
    fi
}

test_dns() {
    step "测试 DNS"

    if dig cloudflare.com @127.0.0.1 +short >/dev/null 2>&1; then
        log "DNS 解析正常"
    else
        err "DNS 解析失败"
        exit 1
    fi
}

show_info() {
    echo ""
    echo "═══════════════════════════════════════"
    echo "      Secure-DNS Lite 部署完成"
    echo "═══════════════════════════════════════"
    echo ""

    echo "监听地址:"
    echo "  127.0.0.1:53"

    if $IPV6_OK; then
        echo "  ::1:53"
    fi

    echo ""

    echo "上游 DNS:"
    echo "  Cloudflare DoT"
    echo "  Google DoT"

    echo ""

    echo "当前 resolv.conf:"
    echo ""

    cat /etc/resolv.conf || true

    echo ""
    echo "测试命令:"
    echo "  dig cloudflare.com @127.0.0.1"
    echo ""
}

main() {
    clear

    echo "╔══════════════════════════════════════╗"
    echo "║      Secure-DNS Lite Final          ║"
    echo "║        Unbound + DoT Setup          ║"
    echo "╚══════════════════════════════════════╝"

    require_root
    detect_os
    install_deps
    detect_ip
    disable_system_dns
    configure_unbound
    setup_resolvconf
    start_unbound
    test_dns
    show_info
}

main "$@"
