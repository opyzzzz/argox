#!/usr/bin/env bash

# =========================================================
# Secure-DNS Lite v1.6
# 自适应 IPv4/IPv6 DNS over TLS 部署脚本
#
# 特性:
# - Alpine / Debian 自动适配
# - 自动检测 IPv4/IPv6 可用性
# - 自动检测 IPv6 实际外网连通性
# - 自动检测容器限制
# - 自动 fallback Root 模式
# - 避免 Alpine/getdns DNSSEC BUG
# - 仅在 IPv6 真可用时启用 IPv6 upstream
# - 无 watchdog / 无死循环
#
# 兼容:
# - KVM
# - LXC
# - Incus
# - OpenVZ
# - Docker
#
# Version: v1.6
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
VIRT="none"

ENABLE_IPV4=false
ENABLE_IPV6=false

USE_ROOT_MODE=false

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
# Root 检查
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
# 虚拟化检测
# =========================================================

detect_virtualization() {

    log_step "检测运行环境"

    if grep -qaE 'docker|lxc|incus' \
        /proc/1/cgroup 2>/dev/null; then

        VIRT="container"
    fi

    [ -f /.dockerenv ] && VIRT="docker"

    if [ -d /proc/vz ] && \
       [ ! -d /proc/bc ]; then

        VIRT="openvz"
    fi

    log_info "环境: ${VIRT}"
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
                iproute2 \
                ca-certificates \
                python3 \
                openssl
            ;;

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y -qq \
                stubby \
                dnsutils \
                iproute2 \
                ca-certificates \
                python3 \
                openssl
            ;;
    esac

    log_info "依赖安装完成"
}

# =========================================================
# IPv4 检测
# =========================================================

detect_ipv4() {

    log_step "检测 IPv4"

    if ip -4 addr show lo | \
        grep -q "127.0.0.1"; then

        if timeout 5 ping -4 -c1 1.1.1.1 \
            >/dev/null 2>&1; then

            ENABLE_IPV4=true

            log_info "IPv4 可用"

        else
            log_warn "IPv4 外网不可达"
        fi
    else
        log_warn "IPv4 loopback 不可用"
    fi
}

# =========================================================
# IPv6 检测
# =========================================================

detect_ipv6() {

    log_step "检测 IPv6"

    if ! ip -6 addr show lo \
        >/dev/null 2>&1; then

        log_warn "系统未启用 IPv6"
        return
    fi

    if ! ip -6 addr show lo | \
        grep -q "::1"; then

        log_warn "IPv6 loopback 不存在"
        return
    fi

    # bind 检测
    if ! python3 - << 'EOF'
import socket
try:
    s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM)
    s.bind(("::1",53535))
    s.close()
    exit(0)
except:
    exit(1)
EOF
    then
        log_warn "IPv6 bind 不可用"
        return
    fi

    # 外网检测
    if timeout 5 ping6 -c1 \
        2606:4700:4700::1111 \
        >/dev/null 2>&1; then

        ENABLE_IPV6=true

        log_info "IPv6 可用"

    else

        log_warn "IPv6 外网不可达"
    fi
}

# =========================================================
# capability 检测
# =========================================================

detect_capability() {

    log_step "检测 capability"

    SCORE=0

    case "$VIRT" in
        container|docker|openvz)
            SCORE=$((SCORE + 2))
            ;;
    esac

    dmesg 2>/dev/null | \
        grep -qi "permission denied" && \
        SCORE=$((SCORE + 1))

    if [ "$SCORE" -ge 2 ]; then

        USE_ROOT_MODE=true

        log_warn "检测到受限环境"
        log_warn "启用 Root Compatibility Mode"

    else

        log_info "Capability 正常"
    fi
}

# =========================================================
# 生成监听地址
# =========================================================

generate_listen() {

    LISTEN="listen_addresses:"

    if [ "$ENABLE_IPV4" = true ]; then

        LISTEN="${LISTEN}
  - 127.0.0.1@53"
    fi

    if [ "$ENABLE_IPV6" = true ]; then

        LISTEN="${LISTEN}
  - 0::1@53"
    fi
}

# =========================================================
# 生成 upstream
# =========================================================

generate_upstreams() {

    UPSTREAMS=""

    # IPv4
    if [ "$ENABLE_IPV4" = true ]; then

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

    # IPv6
    if [ "$ENABLE_IPV6" = true ]; then

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

round_robin_upstreams: 1

idle_timeout: 10000

timeout: 5000

tls_connection_retries: 2

tls_backoff_time: 900

tls_ca_path: "/etc/ssl/certs"

${LISTEN}

upstream_recursive_servers:
${UPSTREAMS}
EOF

    chmod 640 "$STUBBY_CONF"

    log_info "Stubby 配置完成"
}

# =========================================================
# 修复 Alpine capability
# =========================================================

fix_alpine_root_mode() {

    if [ "$OS" != "alpine" ]; then
        return
    fi

    if [ "$USE_ROOT_MODE" != true ]; then
        return
    fi

    log_step "启用 Root Compatibility Mode"

    if [ -f /etc/init.d/stubby ]; then

        cp /etc/init.d/stubby \
           /etc/init.d/stubby.bak \
           2>/dev/null || true

        sed -i '/command_user=/d' \
            /etc/init.d/stubby

        sed -i '/capabilities=/d' \
            /etc/init.d/stubby

        log_info "Root Mode 已启用"
    fi
}

# =========================================================
# 配置系统 DNS
# =========================================================

setup_dns() {

    log_step "配置系统 DNS"

    DNS=""

    if [ "$ENABLE_IPV4" = true ]; then
        DNS="${DNS}
nameserver 127.0.0.1"
    fi

    if [ "$ENABLE_IPV6" = true ]; then
        DNS="${DNS}
nameserver ::1"
    fi

    DNS="${DNS}

options timeout:2
options attempts:2
options edns0"

    # dhcpcd
    if [ -f /etc/dhcpcd.conf ]; then

        sed -i \
            '/^static domain_name_servers=/d' \
            /etc/dhcpcd.conf

        echo \
"static domain_name_servers=127.0.0.1" \
            >> /etc/dhcpcd.conf
    fi

    [ -L "$RESOLV_CONF" ] && rm -f "$RESOLV_CONF"

    echo "$DNS" > "$RESOLV_CONF"

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

    sleep 5

    if dig cloudflare.com @127.0.0.1 +short \
        +time=3 +tries=1 \
        >/dev/null 2>&1; then

        log_info "Stubby 工作正常"
        return
    fi

    # fallback root mode
    if [ "$OS" = "alpine" ] && \
       [ "$USE_ROOT_MODE" != true ]; then

        log_warn "尝试 fallback Root Mode"

        USE_ROOT_MODE=true

        fix_alpine_root_mode

        rc-service stubby restart

        sleep 5

        if dig cloudflare.com \
            @127.0.0.1 +short \
            +time=3 +tries=1 \
            >/dev/null 2>&1; then

            log_info "Fallback Root Mode 成功"
            return
        fi
    fi

    log_error "Stubby 启动失败"

    echo ""
    echo "========== Stubby 日志 =========="

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
"${CYAN}      Secure-DNS Lite 部署完成${NC}"

    echo -e \
"${CYAN}═══════════════════════════════════════${NC}"

    echo ""

    echo "监听地址:"

    [ "$ENABLE_IPV4" = true ] && \
        echo "  127.0.0.1:53"

    [ "$ENABLE_IPV6" = true ] && \
        echo "  [::1]:53"

    echo ""
    echo "Upstream:"

    [ "$ENABLE_IPV4" = true ] && \
        echo "  IPv4 DoT"

    [ "$ENABLE_IPV6" = true ] && \
        echo "  IPv6 DoT"

    echo ""
    echo "模式:"

    if [ "$USE_ROOT_MODE" = true ]; then
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
"${BLUE}║        Secure-DNS Lite v1.6         ║${NC}"

    echo -e \
"${BLUE}║     Adaptive IPv4/IPv6 DoT DNS      ║${NC}"

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

    fix_alpine_root_mode

    setup_dns

    start_stubby

    test_dns

    show_info
}

main "$@"
