#!/usr/bin/env bash

# =========================================================
# Secure-DNS Lite v1.5
# 自适应 DNS over TLS 自动部署脚本
#
# 特性:
#   - 自动检测 IPv4 / IPv6 可用性
#   - 自动检测 IPv6 外网可达性
#   - 自动适配容器 / VPS / NAT 环境
#   - 自动 fallback root compatibility mode
#   - Alpine / Debian 双兼容
#   - Cloudflare + Google DoT
#   - 无 watchdog
#   - 无无限循环
#   - 无 chattr
#
# Version: 1.5
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
VIRT_TYPE="none"

IPV4_AVAILABLE=false
IPV6_AVAILABLE=false

IPV4_UPSTREAM=false
IPV6_UPSTREAM=false

USE_ROOT_STUBBY=false

STUBBY_CONF="/etc/stubby/stubby.yml"
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
# root 检查
# =========================================================

check_root() {

    if [ "$(id -u)" != "0" ]; then
        log_error "请使用 root 运行"
        exit 1
    fi
}

# =========================================================
# 检测系统
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
# 检测虚拟化
# =========================================================

detect_virtualization() {

    log_step "检测运行环境"

    if command -v systemd-detect-virt >/dev/null 2>&1; then

        DETECTED=$(systemd-detect-virt 2>/dev/null || true)

        case "$DETECTED" in
            lxc|docker|podman|openvz)
                VIRT_TYPE="$DETECTED"
                ;;
        esac
    fi

    grep -qaE 'lxc|incus' /proc/1/cgroup \
        2>/dev/null && VIRT_TYPE="lxc"

    [ -f /.dockerenv ] && VIRT_TYPE="docker"

    [ -d /proc/vz ] && \
    [ ! -d /proc/bc ] && \
        VIRT_TYPE="openvz"

    log_info "环境: ${VIRT_TYPE}"
}

# =========================================================
# 安装依赖
# =========================================================

install_deps() {

    log_step "安装依赖"

    case "$OS" in

        alpine)

            apk add --no-cache \
                stubby \
                stubby-openrc \
                bind-tools \
                openssl \
                iproute2 \
                ca-certificates \
                python3
            ;;

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y -qq \
                stubby \
                dnsutils \
                openssl \
                iproute2 \
                ca-certificates \
                python3
            ;;
    esac

    log_info "依赖安装完成"
}

# =========================================================
# 检测 IPv4
# =========================================================

detect_ipv4() {

    log_step "检测 IPv4 环境"

    if ip -4 addr show lo | grep -q "127.0.0.1"; then

        IPV4_AVAILABLE=true

        log_info "IPv4 loopback 可用"
    fi

    if timeout 5 ping -4 -c1 1.1.1.1 \
        >/dev/null 2>&1; then

        IPV4_UPSTREAM=true

        log_info "IPv4 外网可达"

    else

        log_warn "IPv4 外网不可达"
    fi
}

# =========================================================
# 检测 IPv6
# =========================================================

detect_ipv6() {

    log_step "检测 IPv6 环境"

    if ip -6 addr show lo 2>/dev/null | \
        grep -q "::1"; then

        if python3 - << 'EOF' >/dev/null 2>&1
import socket
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
try:
    s.bind(("::1", 53535))
    s.close()
    exit(0)
except:
    exit(1)
EOF
        then
            IPV6_AVAILABLE=true
        fi
    fi

    if [ "$IPV6_AVAILABLE" = true ]; then

        log_info "IPv6 loopback 可用"

    else

        log_warn "IPv6 loopback 不可用"
    fi

    if timeout 5 ping6 -c1 \
        2606:4700:4700::1111 \
        >/dev/null 2>&1; then

        IPV6_UPSTREAM=true

        log_info "IPv6 外网可达"

    else

        log_warn "IPv6 外网不可达"
    fi
}

# =========================================================
# 检测 capability
# =========================================================

detect_capability() {

    if [ "$OS" != "alpine" ]; then
        return
    fi

    log_step "检测 capability 兼容性"

    SCORE=0

    case "$VIRT_TYPE" in
        lxc|docker|openvz|podman)

            SCORE=$((SCORE + 2))
            ;;
    esac

    dmesg 2>/dev/null | \
        grep -qi "permission denied" && \
        SCORE=$((SCORE + 1))

    if [ "$SCORE" -ge 2 ]; then

        USE_ROOT_STUBBY=true

        log_warn "检测到受限环境"
        log_warn "将启用 Root Compatibility Mode"

    else

        log_info "capability 正常"
    fi
}

# =========================================================
# 生成监听地址
# =========================================================

generate_listen() {

    LISTEN_CONFIG="listen_addresses:"

    if [ "$IPV4_AVAILABLE" = true ]; then

        LISTEN_CONFIG="${LISTEN_CONFIG}
  - 127.0.0.1@53"
    fi

    if [ "$IPV6_AVAILABLE" = true ]; then

        LISTEN_CONFIG="${LISTEN_CONFIG}
  - 0::1@53"
    fi
}

# =========================================================
# 生成 upstream
# =========================================================

generate_upstreams() {

    UPSTREAMS=""

    # IPv4 upstream
    if [ "$IPV4_UPSTREAM" = true ]; then

        UPSTREAMS="${UPSTREAMS}

  # Cloudflare IPv4
  - address_data: 1.1.1.1
    tls_auth_name: \"cloudflare-dns.com\"

  - address_data: 1.0.0.1
    tls_auth_name: \"cloudflare-dns.com\"

  # Google IPv4
  - address_data: 8.8.8.8
    tls_auth_name: \"dns.google\"

  - address_data: 8.8.4.4
    tls_auth_name: \"dns.google\""
    fi

    # IPv6 upstream
    if [ "$IPV6_UPSTREAM" = true ]; then

        UPSTREAMS="${UPSTREAMS}

  # Cloudflare IPv6
  - address_data: 2606:4700:4700::1111
    tls_auth_name: \"cloudflare-dns.com\"

  - address_data: 2606:4700:4700::1001
    tls_auth_name: \"cloudflare-dns.com\"

  # Google IPv6
  - address_data: 2001:4860:4860::8888
    tls_auth_name: \"dns.google\"

  - address_data: 2001:4860:4860::8844
    tls_auth_name: \"dns.google\""
    fi
}

# =========================================================
# 配置 Stubby
# =========================================================

config_stubby() {

    log_step "配置 Stubby"

    mkdir -p /etc/stubby

    generate_listen
    generate_upstreams

    cat > "$STUBBY_CONF" << EOF
resolution_type: GETDNS_RESOLUTION_STUB

dns_transport_list:
  - GETDNS_TRANSPORT_TLS

tls_authentication: GETDNS_AUTHENTICATION_REQUIRED

tls_query_padding_blocksize: 128

edns_client_subnet_private: 1

round_robin_upstreams: 1

idle_timeout: 10000

timeout: 5000

tls_connection_retries: 2

tls_backoff_time: 900

dnssec: GETDNS_EXTENSION_TRUE

${LISTEN_CONFIG}

upstream_recursive_servers:
${UPSTREAMS}
EOF

    chmod 640 "$STUBBY_CONF"

    log_info "Stubby 配置完成"
}

# =========================================================
# 修复 Alpine Stubby
# =========================================================

fix_alpine_stubby() {

    if [ "$OS" != "alpine" ]; then
        return
    fi

    if [ "$USE_ROOT_STUBBY" != true ]; then
        return
    fi

    log_step "修复 Alpine Stubby"

    if [ -f /etc/init.d/stubby ]; then

        cp /etc/init.d/stubby \
           /etc/init.d/stubby.bak \
           2>/dev/null || true

        sed -i '/command_user=/d' \
            /etc/init.d/stubby

        sed -i '/capabilities=/d' \
            /etc/init.d/stubby

        log_info "Root Compatibility Mode 已启用"
    fi
}

# =========================================================
# 配置 DNS
# =========================================================

setup_dns() {

    log_step "配置系统 DNS"

    DNS_CONTENT=""

    if [ "$IPV4_AVAILABLE" = true ]; then

        DNS_CONTENT="${DNS_CONTENT}
nameserver 127.0.0.1"
    fi

    if [ "$IPV6_AVAILABLE" = true ]; then

        DNS_CONTENT="${DNS_CONTENT}
nameserver ::1"
    fi

    DNS_CONTENT="${DNS_CONTENT}

options edns0
options timeout:2
options attempts:2"

    if [ -f /etc/dhcpcd.conf ]; then

        sed -i \
            '/^static domain_name_servers=/d' \
            /etc/dhcpcd.conf

        cat >> /etc/dhcpcd.conf << EOF

# Secure-DNS Lite
static domain_name_servers=127.0.0.1
EOF
    fi

    [ -L "$RESOLV_CONF" ] && rm -f "$RESOLV_CONF"

    echo "$DNS_CONTENT" > "$RESOLV_CONF"

    chmod 644 "$RESOLV_CONF"

    log_info "系统 DNS 已配置"
}

# =========================================================
# 启动 Stubby
# =========================================================

start_stubby() {

    log_step "启动 Stubby"

    case "$OS" in

        alpine)

            rc-update add stubby default \
                >/dev/null 2>&1 || true

            rc-service stubby restart
            ;;

        debian)

            systemctl enable stubby \
                >/dev/null 2>&1 || true

            systemctl restart stubby
            ;;
    esac

    sleep 3

    if dig cloudflare.com @127.0.0.1 +short \
        >/dev/null 2>&1; then

        log_info "Stubby 已正常工作"
        return
    fi

    # fallback
    if [ "$OS" = "alpine" ] && \
       [ "$USE_ROOT_STUBBY" != true ]; then

        log_warn "尝试 fallback Root Mode"

        USE_ROOT_STUBBY=true

        fix_alpine_stubby

        rc-service stubby restart

        sleep 3

        if dig cloudflare.com @127.0.0.1 +short \
            >/dev/null 2>&1; then

            log_info "Fallback Root Mode 成功"
            return
        fi
    fi

    log_error "Stubby 启动失败"

    echo ""
    echo "========== stubby 日志 =========="

    tail -n 50 /var/log/messages \
        2>/dev/null || true

    echo "================================"

    exit 1
}

# =========================================================
# DNS 测试
# =========================================================

test_dns() {

    log_step "测试 DNS"

    RESULT=$(dig cloudflare.com @127.0.0.1 +short)

    if [ -n "$RESULT" ]; then

        log_info "DNS 解析成功"

        echo "$RESULT"

    else

        log_error "DNS 解析失败"
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
"${CYAN}      Secure-DNS Lite 部署完成${NC}"

    echo -e \
"${CYAN}═══════════════════════════════════════${NC}"

    echo ""

    echo "监听地址:"

    [ "$IPV4_AVAILABLE" = true ] && \
        echo "  127.0.0.1:53"

    [ "$IPV6_AVAILABLE" = true ] && \
        echo "  [::1]:53"

    echo ""
    echo "Upstream:"

    [ "$IPV4_UPSTREAM" = true ] && \
        echo "  IPv4 DoT"

    [ "$IPV6_UPSTREAM" = true ] && \
        echo "  IPv6 DoT"

    echo ""
    echo "模式:"

    if [ "$USE_ROOT_STUBBY" = true ]; then
        echo "  Root Compatibility Mode"
    else
        echo "  Capability Mode"
    fi

    echo ""
    echo "测试命令:"
    echo "  dig cloudflare.com @127.0.0.1"

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
"${BLUE}║        Secure-DNS Lite v1.5         ║${NC}"

    echo -e \
"${BLUE}║   Adaptive IPv4/IPv6 DoT Resolver   ║${NC}"

    echo -e \
"${BLUE}╚══════════════════════════════════════╝${NC}"

    check_root

    detect_os

    detect_virtualization

    install_deps

    detect_ipv4

    detect_ipv6

    detect_capability

    config_stubby

    fix_alpine_stubby

    setup_dns

    start_stubby

    test_dns

    show_info
}

main "$@"
