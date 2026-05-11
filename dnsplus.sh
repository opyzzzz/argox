#!/usr/bin/env bash

# =========================================================
# Secure-DNS Unbound Lite Stable
#
# 功能:
# - 系统检测
# - 自动安装依赖
# - 自动检测 IPv4 / IPv6
# - 配置 Unbound + DoT
# - 禁止 DHCP 注入 resolv.conf
# - 配置 resolv.conf.head
# - 启动服务
# - DNS 自检
#
# 支持:
# - Debian / Ubuntu
# - Alpine
# - systemd / OpenRC
# - IPv4-only / IPv6-only / DualStack
#
# =========================================================

set -Eeuo pipefail

# =========================================================
# 颜色
# =========================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =========================================================
# 全局变量
# =========================================================

OS=""
INIT_SYSTEM=""

ENABLE_IPV4=false
ENABLE_IPV6=false

UNBOUND_CONF="/etc/unbound/unbound.conf"

# =========================================================
# 日志
# =========================================================

log_info() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_step() {
    echo ""
    echo -e "${CYAN}▶${NC} ${BLUE}$1${NC}"
}

# =========================================================
# Root
# =========================================================

check_root() {

    if [ "$(id -u)" != "0" ]; then
        log_error "请使用 root 运行"
        exit 1
    fi
}

# =========================================================
# 系统检测
# =========================================================

detect_system() {

    log_step "检测系统"

    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    else
        log_error "不支持当前系统"
        exit 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        log_error "无法识别 init 系统"
        exit 1
    fi

    log_info "系统: ${OS}"
    log_info "Init: ${INIT_SYSTEM}"
}

# =========================================================
# 安装依赖
# =========================================================

install_deps() {

    log_step "安装依赖"

    case "$OS" in

        alpine)

            apk update

            apk add --no-cache \
                unbound \
                unbound-openrc \
                bind-tools \
                ca-certificates \
                curl \
                openssl \
                iproute2
            ;;

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y -qq \
                unbound \
                dnsutils \
                ca-certificates \
                curl \
                openssl \
                iproute2
            ;;
    esac

    update-ca-certificates >/dev/null 2>&1 || true

    log_info "依赖安装完成"
}

# =========================================================
# IPv4
# =========================================================

detect_ipv4() {

    log_step "检测 IPv4"

    if timeout 5 ping -4 -c1 1.1.1.1 \
        >/dev/null 2>&1; then

        ENABLE_IPV4=true
        log_info "IPv4 可用"

    else

        log_warn "IPv4 不可用"
    fi
}

# =========================================================
# IPv6
# =========================================================

detect_ipv6() {

    log_step "检测 IPv6"

    if timeout 5 ping6 -c1 \
        2606:4700:4700::1111 \
        >/dev/null 2>&1; then

        ENABLE_IPV6=true
        log_info "IPv6 可用"

    else

        log_warn "IPv6 不可用"
    fi
}

# =========================================================
# 禁止 DHCP 注入 resolv.conf
# =========================================================

disable_dhcp_dns_override() {

    log_step "禁止 DHCP 注入 resolv.conf"

    # dhcpcd
    if [ -f /etc/dhcpcd.conf ]; then

        grep -q '^nohook resolv.conf' \
            /etc/dhcpcd.conf \
            || echo 'nohook resolv.conf' \
            >> /etc/dhcpcd.conf

        log_info "dhcpcd 已禁止覆盖 resolv.conf"
    fi

    # systemd-resolved
    if command -v systemctl >/dev/null 2>&1; then

        if systemctl is-enabled systemd-resolved \
            >/dev/null 2>&1; then

            systemctl disable \
                --now \
                systemd-resolved \
                >/dev/null 2>&1 || true

            log_info "systemd-resolved 已关闭"
        fi
    fi
}

# =========================================================
# 生成 interface
# =========================================================

generate_interfaces() {

    INTERFACE_CFG=""

    if [ "$ENABLE_IPV4" = true ]; then
        INTERFACE_CFG="${INTERFACE_CFG}
    interface: 127.0.0.1"
    fi

    if [ "$ENABLE_IPV6" = true ]; then
        INTERFACE_CFG="${INTERFACE_CFG}
    interface: ::1"
    fi
}

# =========================================================
# 生成 forward
# =========================================================

generate_forwarders() {

    FORWARD_CFG=""

    if [ "$ENABLE_IPV4" = true ]; then

FORWARD_CFG="${FORWARD_CFG}
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 8.8.4.4@853#dns.google"
    fi

    if [ "$ENABLE_IPV6" = true ]; then

FORWARD_CFG="${FORWARD_CFG}
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com
    forward-addr: 2001:4860:4860::8888@853#dns.google
    forward-addr: 2001:4860:4860::8844@853#dns.google"
    fi
}

# =========================================================
# 配置 Unbound
# =========================================================

configure_unbound() {

    log_step "配置 Unbound"

    mkdir -p /etc/unbound

    generate_interfaces
    generate_forwarders

    cat > "$UNBOUND_CONF" << EOF
server:

    verbosity: 0

${INTERFACE_CFG}

    port: 53

    do-ip4: yes
    do-ip6: yes

    do-udp: yes
    do-tcp: yes

    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt

    hide-identity: yes
    hide-version: yes

    qname-minimisation: yes

    prefetch: yes

    rrset-roundrobin: yes

    cache-max-ttl: 86400
    cache-min-ttl: 300

    edns-buffer-size: 1232

    so-reuseport: yes

    num-threads: 1

    harden-glue: yes
    harden-dnssec-stripped: yes

    unwanted-reply-threshold: 10000

    interface-automatic: no

forward-zone:

    name: "."

    forward-tls-upstream: yes

${FORWARD_CFG}
EOF

    chmod 640 "$UNBOUND_CONF"

    log_info "Unbound 配置完成"
}

# =========================================================
# 检查配置
# =========================================================

check_config() {

    log_step "检查配置"

    if unbound-checkconf "$UNBOUND_CONF"; then
        log_info "配置正常"
    else
        log_error "配置错误"
        exit 1
    fi
}

# =========================================================
# 配置 resolv.conf.head
# =========================================================

configure_resolv_head() {

    log_step "配置 resolv.conf.head"

    cat > /etc/resolv.conf.head << EOF
nameserver 127.0.0.1
EOF

    if [ "$ENABLE_IPV6" = true ]; then
        echo "nameserver ::1" >> /etc/resolv.conf.head
    fi

    # resolvconf
    if [ -d /etc/resolvconf/resolv.conf.d ]; then

        cp /etc/resolv.conf.head \
           /etc/resolvconf/resolv.conf.d/head

        if command -v resolvconf >/dev/null 2>&1; then
            resolvconf -u || true
        fi
    fi

    # dhcpcd
    if command -v rc-service >/dev/null 2>&1; then
        rc-service dhcpcd restart \
            >/dev/null 2>&1 || true
    fi

    # fallback
    if [ ! -f /etc/resolv.conf ]; then

        cp /etc/resolv.conf.head \
           /etc/resolv.conf
    fi

    log_info "resolv.conf.head 已配置"
}

# =========================================================
# 启动 Unbound
# =========================================================

start_unbound() {

    log_step "启动 Unbound"

    case "$INIT_SYSTEM" in

        systemd)

            systemctl enable unbound \
                >/dev/null 2>&1 || true

            systemctl restart unbound
            ;;

        openrc)

            rc-update add unbound default \
                >/dev/null 2>&1 || true

            rc-service unbound restart
            ;;
    esac

    sleep 5

    if pgrep unbound >/dev/null 2>&1; then
        log_info "Unbound 已启动"
    else
        log_error "Unbound 启动失败"
        exit 1
    fi
}

# =========================================================
# 测试 DNS
# =========================================================

test_dns() {

    log_step "测试 DNS"

    RESULT=$(dig cloudflare.com \
        @127.0.0.1 \
        +short \
        +time=3 \
        +tries=1 || true)

    if [ -n "$RESULT" ]; then

        log_info "DNS 工作正常"

        echo "$RESULT"

    else

        log_error "DNS 测试失败"

        if command -v journalctl >/dev/null 2>&1; then

            journalctl -u unbound \
                -n 30 \
                --no-pager || true
        fi

        exit 1
    fi
}

# =========================================================
# 信息
# =========================================================

show_info() {

    echo ""

    echo -e \
"${CYAN}═══════════════════════════════════════${NC}"

    echo -e \
"${CYAN}      Secure-DNS 部署完成${NC}"

    echo -e \
"${CYAN}═══════════════════════════════════════${NC}"

    echo ""

    echo "监听地址:"

    [ "$ENABLE_IPV4" = true ] && \
        echo "  127.0.0.1:53"

    [ "$ENABLE_IPV6" = true ] && \
        echo "  [::1]:53"

    echo ""

    echo "上游 DNS:"
    echo "  Cloudflare DoT"
    echo "  Google DoT"

    echo ""

    echo "当前 resolv.conf:"
    cat /etc/resolv.conf || true

    echo ""

    echo "测试命令:"
    echo "  dig cloudflare.com @127.0.0.1"

    echo ""
}

# =========================================================
# MAIN
# =========================================================

main() {

    echo ""

    echo -e \
"${BLUE}╔══════════════════════════════════════╗${NC}"

    echo -e \
"${BLUE}║      Secure-DNS Unbound Lite        ║${NC}"

    echo -e \
"${BLUE}╚══════════════════════════════════════╝${NC}"

    echo ""

    check_root

    detect_system

    install_deps

    detect_ipv4

    detect_ipv6

    disable_dhcp_dns_override

    configure_unbound

    check_config

    configure_resolv_head

    start_unbound

    test_dns

    show_info
}

main "$@"
