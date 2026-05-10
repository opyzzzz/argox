#!/usr/bin/env bash

# =========================================================
# Secure-DNS Lite
# 自适应 DNS over TLS 自动部署脚本
#
# 支持:
#   - Debian / Ubuntu
#   - Alpine Linux
#
# 特点:
#   - 自动检测 IPv4 / IPv6 本地监听能力
#   - 自动适配 LXC / Incus / Docker / NAT VPS
#   - 自动检测 Alpine OpenRC capability 兼容性
#   - 必要时自动切换 root 运行 stubby
#   - 保留 IPv6 上游 DNS
#   - 无 watchdog
#   - 无无限循环
#   - 无 chattr
#   - 无 systemd-resolved mask
#   - 兼容 sing-box / xray
#
# 上游:
#   - Cloudflare
#   - Google
#
# Version: v1.3
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
# 路径
# =========================================================

STUBBY_CONF="/etc/stubby/stubby.yml"
RESOLV_CONF="/etc/resolv.conf"

# =========================================================
# 默认能力
# =========================================================

IPV6_AVAILABLE=false
USE_ROOT_STUBBY=false

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

    CONTAINER="no"

    if [ -f /.dockerenv ]; then
        CONTAINER="docker"
    fi

    if grep -qaE 'docker' /proc/1/cgroup 2>/dev/null; then
        CONTAINER="docker"
    fi

    if grep -qaE 'lxc|incus' /proc/1/cgroup 2>/dev/null; then
        CONTAINER="lxc"
    fi

    if systemd-detect-virt >/dev/null 2>&1; then

        VIRT=$(systemd-detect-virt 2>/dev/null || true)

        case "$VIRT" in
            lxc|openvz)
                CONTAINER="lxc"
                ;;
            docker)
                CONTAINER="docker"
                ;;
        esac
    fi

    log_info "系统: ${OS}"
    log_info "环境: ${CONTAINER}"
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
                ca-certificates \
                openssl \
                iproute2 \
                python3
            ;;

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y -qq \
                stubby \
                dnsutils \
                ca-certificates \
                openssl \
                iproute2 \
                python3
            ;;
    esac

    log_info "依赖安装完成"
}

# =========================================================
# 检测 IP 环境
# =========================================================

detect_ip_capability() {

    log_step "检测 IP 环境"

    if ip -6 addr show lo 2>/dev/null | grep -q "::1"; then

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
        log_info "本地 IPv6 bind 可用"
    else
        log_warn "本地 IPv6 bind 不可用"
    fi
}

# =========================================================
# 检测 Alpine 容器兼容性
# =========================================================

detect_stubby_compatibility() {

    if [ "$OS" != "alpine" ]; then
        return
    fi

    log_step "检测 Stubby 容器兼容性"

    case "$CONTAINER" in

        lxc|docker)

            USE_ROOT_STUBBY=true

            log_warn "检测到受限容器环境"
            log_warn "将使用 root 模式运行 Stubby"
            ;;
    esac
}

# =========================================================
# 修复 Alpine OpenRC capability
# =========================================================

fix_alpine_stubby_service() {

    if [ "$OS" != "alpine" ]; then
        return
    fi

    if [ "$USE_ROOT_STUBBY" != true ]; then
        return
    fi

    log_step "修复 Alpine Stubby 服务"

    if [ -f /etc/init.d/stubby ]; then

        cp /etc/init.d/stubby \
           /etc/init.d/stubby.bak 2>/dev/null || true

        sed -i '/command_user=/d' /etc/init.d/stubby

        sed -i '/capabilities=/d' /etc/init.d/stubby

        log_info "已启用 root 模式 Stubby"
    fi
}

# =========================================================
# 配置 Stubby
# =========================================================

config_stubby() {

    log_step "配置 Stubby"

    mkdir -p /etc/stubby

    if [ "$IPV6_AVAILABLE" = true ]; then

        LISTEN_BLOCK=$(cat << EOF
listen_addresses:
  - 127.0.0.1@53
  - 0::1@53
EOF
)

    else

        LISTEN_BLOCK=$(cat << EOF
listen_addresses:
  - 127.0.0.1@53
EOF
)

    fi

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

${LISTEN_BLOCK}

upstream_recursive_servers:

  # Cloudflare IPv4
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"

  - address_data: 1.0.0.1
    tls_auth_name: "cloudflare-dns.com"

  # Cloudflare IPv6
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"

  - address_data: 2606:4700:4700::1001
    tls_auth_name: "cloudflare-dns.com"

  # Google IPv4
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"

  - address_data: 8.8.4.4
    tls_auth_name: "dns.google"

  # Google IPv6
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"

  - address_data: 2001:4860:4860::8844
    tls_auth_name: "dns.google"
EOF

    chmod 640 "$STUBBY_CONF"

    log_info "Stubby 配置完成"
}

# =========================================================
# 配置系统 DNS
# =========================================================

setup_resolv() {

    log_step "配置系统 DNS"

    if [ "$IPV6_AVAILABLE" = true ]; then

        DNS_SERVERS=$(cat << EOF
nameserver 127.0.0.1
nameserver ::1
EOF
)

    else

        DNS_SERVERS=$(cat << EOF
nameserver 127.0.0.1
EOF
)

    fi

    # Alpine dhcpcd
    if [ -f /etc/dhcpcd.conf ]; then

        sed -i '/^static domain_name_servers=/d' \
            /etc/dhcpcd.conf

        cat >> /etc/dhcpcd.conf << EOF

# Secure-DNS Lite
static domain_name_servers=127.0.0.1

EOF

        log_info "已配置 dhcpcd"
    fi

    # resolvconf
    if [ -d /etc/resolvconf/resolv.conf.d ]; then

        cat > /etc/resolvconf/resolv.conf.d/head << EOF
${DNS_SERVERS}
options edns0
options timeout:2
options attempts:2
EOF

        if command -v resolvconf >/dev/null 2>&1; then
            resolvconf -u || true
        fi
    fi

    # systemd-resolved
    if command -v systemctl >/dev/null 2>&1; then

        if systemctl is-active systemd-resolved \
            >/dev/null 2>&1; then

            systemctl disable --now systemd-resolved \
                >/dev/null 2>&1 || true
        fi
    fi

    if [ -L "$RESOLV_CONF" ]; then
        rm -f "$RESOLV_CONF"
    fi

    cat > "$RESOLV_CONF" << EOF
${DNS_SERVERS}
options edns0
options timeout:2
options attempts:2
EOF

    chmod 644 "$RESOLV_CONF"

    if [ "$OS" = "alpine" ]; then

        if command -v rc-service >/dev/null 2>&1; then
            rc-service dhcpcd restart >/dev/null 2>&1 || true
        fi
    fi

    log_info "系统 DNS 已配置"
}

# =========================================================
# 启动 Stubby
# =========================================================

start_stubby() {

    log_step "启动 Stubby"

    case "$OS" in

        debian)

            systemctl enable stubby >/dev/null 2>&1 || true
            systemctl restart stubby
            ;;

        alpine)

            rc-update add stubby default >/dev/null 2>&1 || true
            rc-service stubby restart
            ;;
    esac

    sleep 3

    if dig cloudflare.com @127.0.0.1 +short \
        >/dev/null 2>&1; then

        log_info "Stubby 已正常工作"

    else

        log_error "Stubby 未正常响应 DNS 查询"

        echo ""
        echo "========== stubby 日志 =========="

        tail -n 30 /var/log/messages 2>/dev/null || true

        echo "================================"
        echo ""

        exit 1
    fi
}

# =========================================================
# DNS 测试
# =========================================================

test_dns() {

    log_step "执行 DNS 测试"

    TIME_MS=$(
        dig cloudflare.com @127.0.0.1 2>/dev/null \
        | awk '/Query time:/ {print $4}'
    )

    log_info "DNS 解析正常 (${TIME_MS:-N/A} ms)"
}

# =========================================================
# DoT 测试
# =========================================================

test_dot() {

    log_step "测试 DoT 连通性"

    if timeout 5 openssl s_client \
        -connect 1.1.1.1:853 \
        -servername cloudflare-dns.com \
        </dev/null >/dev/null 2>&1; then

        log_info "DoT 853 连接正常"

    else

        log_warn "DoT 853 连接失败"
    fi
}

# =========================================================
# 信息显示
# =========================================================

show_info() {

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      Secure-DNS Lite 部署完成${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    echo -e "  本地监听:"

    if [ "$IPV6_AVAILABLE" = true ]; then
        echo -e "    127.0.0.1:53"
        echo -e "    [::1]:53"
    else
        echo -e "    127.0.0.1:53"
    fi

    echo ""

    echo -e "  上游 DNS:"
    echo -e "    Cloudflare DoT"
    echo -e "    Google DoT"
    echo ""

    if [ "$USE_ROOT_STUBBY" = true ]; then
        echo -e "  Stubby 模式:"
        echo -e "    Root Compatibility Mode"
        echo ""
    fi

    echo -e "  配置文件:"
    echo -e "    ${STUBBY_CONF}"
    echo ""

    echo -e "  测试命令:"
    echo -e "    dig cloudflare.com @127.0.0.1"
    echo ""

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
}

# =========================================================
# 主流程
# =========================================================

main() {

    echo ""

    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        Secure-DNS Lite v1.3         ║${NC}"
    echo -e "${BLUE}║       Adaptive DoT Deployment       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"

    check_root

    detect_os

    install_deps

    detect_ip_capability

    detect_stubby_compatibility

    fix_alpine_stubby_service

    config_stubby

    setup_resolv

    start_stubby

    test_dns

    test_dot

    show_info
}

main "$@"
