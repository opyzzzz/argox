#!/usr/bin/env bash
# =========================================================
# Secure-DNS SmartDNS + DoH Installer
# 适配:
#   - Debian / Ubuntu
#   - Alpine
#   - KVM / LXC / OpenVZ / NAT VPS
#
# 功能:
#   - 自动安装 SmartDNS
#   - 自动检测 IPv4/IPv6
#   - 使用 DoH (443)
#   - 接管 resolv.conf
#   - 接管 dhcpcd DNS
#   - 自动兼容 systemd / OpenRC
#
# DoH:
#   - Cloudflare
#   - Google
#
# Author: ChatGPT
# =========================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SMARTDNS_CONF="/etc/smartdns/smartdns.conf"
RESOLV="/etc/resolv.conf"

HAS_IPV4=0
HAS_IPV6=0
OS="unknown"

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
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 运行"
        exit 1
    fi
}

detect_os() {
    step "检测系统"

    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    else
        err "不支持的系统"
        exit 1
    fi

    log "系统: $OS"

    if grep -qaE 'lxc|docker|kubepods|container' /proc/1/cgroup 2>/dev/null; then
        warn "检测到容器环境"
    fi
}

install_deps() {
    step "安装依赖"

    case "$OS" in
        alpine)
            apk update
            apk add --no-cache \
                smartdns \
                curl \
                bind-tools \
                iproute2 \
                ca-certificates
            ;;

        debian)
            apt-get update -y

            apt-get install -y \
                smartdns \
                curl \
                dnsutils \
                iproute2 \
                ca-certificates
            ;;
    esac

    log "依赖安装完成"
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
    step "处理系统 DNS 服务"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true

        log "已关闭 systemd-resolved"
    fi
}

configure_smartdns() {
    step "配置 SmartDNS"

    mkdir -p /etc/smartdns

    cat > "$SMARTDNS_CONF" <<EOF
# =====================================================
# SmartDNS Secure Config
# =====================================================

bind 127.0.0.1:53

cache-size 4096
prefetch-domain yes
serve-expired yes

speed-check-mode ping,tcp:80,tcp:443
response-mode fastest-ip

dualstack-ip-selection yes

log-level error

EOF

    if [ "$HAS_IPV6" = "1" ]; then
        cat >> "$SMARTDNS_CONF" <<EOF
bind [::1]:53
force-AAAA-SOA no
EOF
    fi

    cat >> "$SMARTDNS_CONF" <<EOF

# =====================================================
# DNS over HTTPS
# =====================================================

server-https https://1.1.1.1/dns-query
server-https https://1.0.0.1/dns-query
server-https https://dns.google/dns-query
server-https https://8.8.8.8/dns-query

EOF

    log "SmartDNS 配置完成"
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
    step "接管 dhcpcd DNS"

    if [ -f /etc/dhcpcd.conf ]; then

        grep -q "nohook resolv.conf" /etc/dhcpcd.conf || \
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf

        mkdir -p /etc

        cat > /etc/resolv.conf.head <<EOF
nameserver 127.0.0.1
EOF

        if [ "$HAS_IPV6" = "1" ]; then
            echo "nameserver ::1" >> /etc/resolv.conf.head
        fi

        log "dhcpcd DNS 已接管"
    else
        warn "未发现 dhcpcd"
    fi
}

start_service() {
    step "启动 SmartDNS"

    case "$OS" in
        alpine)
            rc-update add smartdns default >/dev/null 2>&1 || true
            rc-service smartdns restart
            ;;

        debian)
            systemctl enable smartdns >/dev/null 2>&1 || true
            systemctl restart smartdns
            ;;
    esac

    sleep 2

    if ss -lnup | grep -q ":53"; then
        log "SmartDNS 已监听 53"
    else
        err "SmartDNS 启动失败"
        exit 1
    fi
}

test_dns() {
    step "测试 DNS"

    if dig cloudflare.com @127.0.0.1 +short >/dev/null 2>&1; then
        log "DNS 解析成功"
    else
        err "DNS 解析失败"
    fi
}

show_result() {
    echo
    echo "═══════════════════════════════════════"
    echo "      SmartDNS + DoH 部署完成"
    echo "═══════════════════════════════════════"
    echo

    echo "监听地址:"
    echo "  127.0.0.1:53"

    if [ "$HAS_IPV6" = "1" ]; then
        echo "  [::1]:53"
    fi

    echo
    echo "DoH 上游:"
    echo "  Cloudflare"
    echo "  Google"

    echo
    echo "当前 resolv.conf:"
    echo

    cat /etc/resolv.conf

    echo
    echo "测试命令:"
    echo "  dig cloudflare.com @127.0.0.1"
    echo
}

main() {
    clear

    echo "╔══════════════════════════════════════╗"
    echo "║       SmartDNS + DoH Installer      ║"
    echo "║         Stable DNS Solution         ║"
    echo "╚══════════════════════════════════════╝"

    require_root
    detect_os
    install_deps
    detect_network
    stop_conflict_dns
    configure_smartdns
    take_over_resolv
    take_over_dhcpcd
    start_service
    test_dns
    show_result
}

main "$@"
