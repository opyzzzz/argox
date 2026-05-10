#!/usr/bin/env bash

# =========================================================
# Secure-DNS Lite
# 轻量级 DNS over TLS 自动部署脚本
#
# 支持:
#   - Debian / Ubuntu
#   - Alpine Linux
#
# 特点:
#   - 无 watchdog
#   - 无无限循环
#   - 无 chattr
#   - 无 systemd-resolved mask
#   - VPS / NAT / OpenRC 兼容优化
#   - 保留 IPv6 DNS 支持
#   - 兼容 sing-box / xray
#
# 上游:
#   - Cloudflare
#   - Google
#
# Version: v1.1
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

    if [ -f /.dockerenv ] || \
       grep -qaE 'docker|lxc|kubepods' /proc/1/cgroup 2>/dev/null; then
        CONTAINER="yes"
    else
        CONTAINER="no"
    fi

    log_info "系统: ${OS}"
    log_info "容器: ${CONTAINER}"
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
                ca-certificates \
                bind-tools \
                openssl \
                iproute2
            ;;

        debian)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y -qq \
                stubby \
                dnsutils \
                ca-certificates \
                openssl \
                iproute2
            ;;
    esac

    log_info "依赖安装完成"
}

# =========================================================
# 配置 Stubby
# =========================================================

config_stubby() {

    log_step "配置 Stubby"

    mkdir -p /etc/stubby

    cat > "$STUBBY_CONF" << 'EOF'
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

listen_addresses:
  - 127.0.0.1@53
  - 0::1@53

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

    # -----------------------------------------------------
    # Alpine dhcpcd
    # -----------------------------------------------------

    if [ -f /etc/dhcpcd.conf ]; then

        # 删除旧配置
        sed -i '/^nohook resolv.conf/d' /etc/dhcpcd.conf
        sed -i '/^static domain_name_servers=/d' /etc/dhcpcd.conf

        # 添加静态 DNS
        cat >> /etc/dhcpcd.conf << EOF

# Secure-DNS Lite
static domain_name_servers=127.0.0.1 ::1

EOF

        log_info "已配置 dhcpcd 静态 DNS"
    fi

    # -----------------------------------------------------
    # resolvconf
    # -----------------------------------------------------

    if [ -d /etc/resolvconf/resolv.conf.d ]; then

        cat > /etc/resolvconf/resolv.conf.d/head << EOF
nameserver 127.0.0.1
nameserver ::1
options edns0
options timeout:2
options attempts:2
EOF

        if command -v resolvconf >/dev/null 2>&1; then
            resolvconf -u || true
        fi

        log_info "已配置 resolvconf"
    fi

    # -----------------------------------------------------
    # systemd-resolved
    # -----------------------------------------------------

    if command -v systemctl >/dev/null 2>&1; then

        if systemctl is-active systemd-resolved >/dev/null 2>&1; then

            log_warn "检测到 systemd-resolved"

            systemctl disable --now systemd-resolved \
                >/dev/null 2>&1 || true

            log_info "已停止 systemd-resolved"
        fi
    fi

    # -----------------------------------------------------
    # resolv.conf
    # -----------------------------------------------------

    if [ -L "$RESOLV_CONF" ]; then
        rm -f "$RESOLV_CONF"
    fi

    cat > "$RESOLV_CONF" << EOF
nameserver 127.0.0.1
nameserver ::1
options edns0
options timeout:2
options attempts:2
EOF

    chmod 644 "$RESOLV_CONF"

    # -----------------------------------------------------
    # Alpine 重载 dhcpcd
    # -----------------------------------------------------

    if [ "$OS" = "alpine" ]; then

        if command -v rc-service >/dev/null 2>&1; then
            rc-service dhcpcd restart >/dev/null 2>&1 || true
        fi
    fi

    log_info "系统 DNS 已指向 127.0.0.1"
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

    # -----------------------------------------------------
    # 使用真实 DNS 查询检测
    # 避免 pgrep Alpine 误判
    # -----------------------------------------------------

    if dig google.com @127.0.0.1 +short >/dev/null 2>&1; then

        log_info "Stubby 已正常工作"

    else

        log_error "Stubby 未正常响应 DNS 查询"

        echo ""
        echo "========== stubby 日志 =========="
        tail -n 20 /var/log/messages 2>/dev/null || true
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

    if dig google.com @127.0.0.1 +short >/dev/null 2>&1; then

        TIME_MS=$(
            dig google.com @127.0.0.1 2>/dev/null \
            | awk '/Query time:/ {print $4}'
        )

        log_info "DNS 解析正常 (${TIME_MS:-N/A} ms)"

    else

        log_error "DNS 解析失败"
        exit 1
    fi
}

# =========================================================
# DoT 测试
# =========================================================

test_dot() {

    log_step "测试 DoT 连通性"

    if command -v openssl >/dev/null 2>&1; then

        if timeout 5 openssl s_client \
            -connect 1.1.1.1:853 \
            -servername cloudflare-dns.com \
            </dev/null >/dev/null 2>&1; then

            log_info "DoT 853 连接正常"

        else

            log_warn "DoT 853 连接失败"
        fi
    fi
}

# =========================================================
# 信息
# =========================================================

show_info() {

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      Secure-DNS Lite 部署完成${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    echo -e "  本地 DNS:"
    echo -e "    127.0.0.1"
    echo -e "    ::1"
    echo ""

    echo -e "  上游 DNS:"
    echo -e "    Cloudflare DoT"
    echo -e "    Google DoT"
    echo ""

    echo -e "  配置文件:"
    echo -e "    ${STUBBY_CONF}"
    echo ""

    echo -e "  测试命令:"
    echo -e "    dig google.com @127.0.0.1"
    echo ""

    echo -e "  查看状态:"

    case "$OS" in
        debian)
            echo -e "    systemctl status stubby"
            ;;
        alpine)
            echo -e "    rc-service stubby status"
            ;;
    esac

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
    echo -e "${BLUE}║        Secure-DNS Lite v1.1         ║${NC}"
    echo -e "${BLUE}║         DNS over TLS Setup          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"

    check_root

    detect_os

    install_deps

    config_stubby

    setup_resolv

    start_stubby

    test_dns

    test_dot

    show_info
}

main "$@"
