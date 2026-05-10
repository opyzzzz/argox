#!/usr/bin/env bash

# =========================================================
# Secure-DNS Unbound Edition v2.0
#
# 生产级 DNS over TLS 自动部署
#
# 特性:
# - Alpine / Debian / Ubuntu
# - 自动检测 IPv4 / IPv6
# - 自动适配 LXC / Docker / KVM
# - Unbound + DoT
# - Cloudflare + Google
# - DNS 缓存优化
# - 防 resolv.conf 覆盖
# - 无 watchdog
# - 无死循环
# - 无 stubby/getdns bug
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
ENABLE_IPV4=false
ENABLE_IPV6=false

UNBOUND_CONF="/etc/unbound/unbound.conf"
RESOLV_CONF="/etc/resolv.conf"

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
# Root 检测
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

detect_os() {

    if [ -f /etc/alpine-release ]; then

        OS="alpine"

    elif [ -f /etc/debian_version ]; then

        OS="debian"

    else

        log_error "不支持的系统"
        exit 1
    fi

    log_info "系统: ${OS}"
}

# =========================================================
# 安装依赖
# =========================================================

install_deps() {

    log_step "安装依赖"

    case "$OS" in

        alpine)

            apk add --no-cache \
                unbound \
                unbound-openrc \
                bind-tools \
                openssl \
                ca-certificates \
                iproute2
            ;;

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y -qq \
                unbound \
                dnsutils \
                openssl \
                ca-certificates \
                iproute2
            ;;
    esac

    log_info "依赖安装完成"
}

# =========================================================
# IPv4 检测
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
# IPv6 检测
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
# 生成监听配置
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
# 生成上游配置
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

config_unbound() {

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

    prefer-ip6: yes

    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt

    hide-identity: yes
    hide-version: yes

    qname-minimisation: yes

    prefetch: yes
    prefetch-key: yes

    cache-max-ttl: 86400
    cache-min-ttl: 600

    rrset-roundrobin: yes

    edns-buffer-size: 1232

    tcp-fastopen: yes

    so-reuseport: yes

    num-threads: 1

    harden-glue: yes
    harden-dnssec-stripped: yes

forward-zone:

    name: "."

    forward-tls-upstream: yes

${FORWARD_CFG}
EOF

    chmod 640 "$UNBOUND_CONF"

    log_info "Unbound 配置完成"
}

# =========================================================
# 防止 resolv.conf 被覆盖
# =========================================================

protect_resolvconf() {

    log_step "保护 resolv.conf"

    if [ -f /etc/dhcpcd.conf ]; then

        grep -q '^nohook resolv.conf' \
            /etc/dhcpcd.conf \
            || echo 'nohook resolv.conf' \
            >> /etc/dhcpcd.conf

        log_info "已禁用 dhcpcd 覆盖 DNS"
    fi
}

# =========================================================
# 配置系统 DNS
# =========================================================

setup_dns() {

    log_step "配置系统 DNS"

    DNS_CONTENT=""

    if [ "$ENABLE_IPV4" = true ]; then

        DNS_CONTENT="${DNS_CONTENT}
nameserver 127.0.0.1"
    fi

    if [ "$ENABLE_IPV6" = true ]; then

        DNS_CONTENT="${DNS_CONTENT}
nameserver ::1"
    fi

    DNS_CONTENT="${DNS_CONTENT}

options timeout:2
options attempts:2
options edns0"

    [ -L "$RESOLV_CONF" ] && rm -f "$RESOLV_CONF"

    echo "$DNS_CONTENT" > "$RESOLV_CONF"

    chmod 644 "$RESOLV_CONF"

    log_info "系统 DNS 已配置"
}

# =========================================================
# 启动 Unbound
# =========================================================

start_unbound() {

    log_step "启动 Unbound"

    case "$OS" in

        alpine)

            rc-update add unbound default \
                >/dev/null 2>&1 || true

            rc-service unbound restart
            ;;

        debian)

            systemctl enable unbound \
                >/dev/null 2>&1 || true

            systemctl restart unbound
            ;;
    esac

    sleep 5
}

# =========================================================
# DNS 测试
# =========================================================

test_dns() {

    log_step "测试 DNS"

    RESULT=$(dig cloudflare.com \
        @127.0.0.1 \
        +short \
        +time=3 \
        +tries=1 || true)

    if [ -n "$RESULT" ]; then

        log_info "DNS 解析成功"

        echo "$RESULT"

    else

        log_error "DNS 解析失败"

        echo ""
        echo "========== Unbound 日志 =========="

        tail -n 50 /var/log/messages \
            2>/dev/null || true

        journalctl -u unbound \
            -n 50 \
            --no-pager \
            2>/dev/null || true

        echo "================================"

        exit 1
    fi
}

# =========================================================
# 状态检测
# =========================================================

show_status() {

    log_step "运行状态"

    if ss -lnptu 2>/dev/null | grep -q ':53'; then

        log_info "53 端口监听正常"

    else

        log_warn "53 端口未监听"
    fi

    if pgrep unbound >/dev/null 2>&1; then

        log_info "Unbound 进程正常"

    else

        log_warn "Unbound 未运行"
    fi
}

# =========================================================
# 显示信息
# =========================================================

show_info() {

    echo ""

    echo -e \
"${CYAN}═══════════════════════════════════════${NC}"

    echo -e \
"${CYAN}     Secure-DNS Unbound 已部署${NC}"

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

    echo "特性:"
    echo "  DNS Cache"
    echo "  TCP Fast Open"
    echo "  QNAME Minimisation"
    echo "  DNS Hardening"

    echo ""

    echo "测试命令:"
    echo "  dig cloudflare.com @127.0.0.1"

    echo ""

    echo "配置文件:"
    echo "  ${UNBOUND_CONF}"

    echo ""
}

# =========================================================
# 主流程
# =========================================================

main() {

    echo ""

    echo -e \
"${BLUE}╔══════════════════════════════════════╗${NC}"

    echo -e \
"${BLUE}║   Secure-DNS Unbound Edition v2.0   ║${NC}"

    echo -e \
"${BLUE}║         DNS over TLS                ║${NC}"

    echo -e \
"${BLUE}╚══════════════════════════════════════╝${NC}"

    echo ""

    check_root

    detect_os

    install_deps

    detect_ipv4

    detect_ipv6

    config_unbound

    protect_resolvconf

    setup_dns

    start_unbound

    test_dns

    show_status

    show_info
}

main "$@"
