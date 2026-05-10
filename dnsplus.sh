#!/usr/bin/env bash

# =========================================================
# Secure-DNS Lite v1.4
# 自适应 DNS over TLS 自动部署脚本
#
# 支持:
#   - Alpine
#   - Debian / Ubuntu
#
# 特点:
#   - 自动检测 IPv4 / IPv6 本地监听能力
#   - 多重容器 / capability 检测
#   - 自动 fallback root compatibility mode
#   - 保留 IPv6 upstream
#   - 无 watchdog
#   - 无无限循环
#   - 无 chattr
#   - 无暴力 systemd-resolved mask
#   - 兼容 xray / sing-box
#
# 上游:
#   - Cloudflare
#   - Google
#
# Version: 1.4
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
# 全局状态
# =========================================================

OS=""
VIRT_TYPE="none"

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
# root 检查
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
# 虚拟化 / 容器检测
# =========================================================

detect_virtualization() {

    log_step "检测运行环境"

    # -----------------------------------------------------
    # systemd-detect-virt
    # -----------------------------------------------------

    if command -v systemd-detect-virt >/dev/null 2>&1; then

        DETECTED=$(
            systemd-detect-virt 2>/dev/null || true
        )

        case "$DETECTED" in
            lxc|openvz|docker|podman|container-other)
                VIRT_TYPE="$DETECTED"
                ;;
        esac
    fi

    # -----------------------------------------------------
    # cgroup
    # -----------------------------------------------------

    if [ "$VIRT_TYPE" = "none" ]; then

        if grep -qaE \
            'docker|podman|containerd' \
            /proc/1/cgroup 2>/dev/null; then

            VIRT_TYPE="docker"
        fi

        if grep -qaE \
            'lxc|incus' \
            /proc/1/cgroup 2>/dev/null; then

            VIRT_TYPE="lxc"
        fi
    fi

    # -----------------------------------------------------
    # 环境文件
    # -----------------------------------------------------

    if [ "$VIRT_TYPE" = "none" ]; then

        [ -f /.dockerenv ] && VIRT_TYPE="docker"

        [ -f /run/.containerenv ] && \
            VIRT_TYPE="container"
    fi

    # -----------------------------------------------------
    # OpenVZ
    # -----------------------------------------------------

    if [ "$VIRT_TYPE" = "none" ]; then

        [ -d /proc/vz ] && \
        [ ! -d /proc/bc ] && \
            VIRT_TYPE="openvz"
    fi

    # -----------------------------------------------------
    # DMI
    # -----------------------------------------------------

    if [ "$VIRT_TYPE" = "none" ]; then

        if command -v dmidecode >/dev/null 2>&1; then

            DMI=$(dmidecode -s system-product-name \
                2>/dev/null || true)

            echo "$DMI" | grep -qiE \
                'openvz|lxc|docker|kvm' && \
                VIRT_TYPE="virtualized"
        fi
    fi

    # -----------------------------------------------------
    # 输出
    # -----------------------------------------------------

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
                ca-certificates \
                iproute2 \
                python3
            ;;

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y -qq \
                stubby \
                dnsutils \
                openssl \
                ca-certificates \
                iproute2 \
                python3
            ;;
    esac

    log_info "依赖安装完成"
}

# =========================================================
# IPv6 检测
# =========================================================

detect_ipv6() {

    log_step "检测 IP 环境"

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
        log_info "本地 IPv6 bind 可用"
    else
        log_warn "本地 IPv6 bind 不可用"
    fi
}

# =========================================================
# capability 检测
# =========================================================

detect_capability_issues() {

    if [ "$OS" != "alpine" ]; then
        return
    fi

    log_step "检测 Stubby capability 兼容性"

    SCORE=0

    # -----------------------------------------------------
    # 容器环境
    # -----------------------------------------------------

    case "$VIRT_TYPE" in
        lxc|openvz|docker|podman|container|container-other)

            SCORE=$((SCORE + 2))

            log_warn "检测到受限容器环境"
            ;;
    esac

    # -----------------------------------------------------
    # IPv6 permission denied
    # -----------------------------------------------------

    if dmesg 2>/dev/null | \
        grep -qi 'permission denied'; then

        SCORE=$((SCORE + 1))
    fi

    # -----------------------------------------------------
    # capability 支持
    # -----------------------------------------------------

    if ! command -v getcap >/dev/null 2>&1; then
        SCORE=$((SCORE + 1))
    fi

    # -----------------------------------------------------
    # OpenRC supervise-daemon
    # -----------------------------------------------------

    if command -v supervise-daemon >/dev/null 2>&1; then

        if ! supervise-daemon --help \
            >/dev/null 2>&1; then

            SCORE=$((SCORE + 1))
        fi
    fi

    # -----------------------------------------------------
    # 判定
    # -----------------------------------------------------

    if [ "$SCORE" -ge 2 ]; then

        USE_ROOT_STUBBY=true

        log_warn "检测到 capability 兼容性风险"
        log_warn "将启用 Root Compatibility Mode"

    else

        log_info "capability 兼容性正常"
    fi
}

# =========================================================
# 配置 Stubby
# =========================================================

config_stubby() {

    log_step "配置 Stubby"

    mkdir -p /etc/stubby

    if [ "$IPV6_AVAILABLE" = true ]; then

        LISTEN=$(cat << EOF
listen_addresses:
  - 127.0.0.1@53
  - 0::1@53
EOF
)

    else

        LISTEN=$(cat << EOF
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

${LISTEN}

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
# 修复 Alpine capability
# =========================================================

fix_alpine_service() {

    if [ "$OS" != "alpine" ]; then
        return
    fi

    if [ "$USE_ROOT_STUBBY" != true ]; then
        return
    fi

    log_step "修复 Alpine Stubby 服务"

    if [ -f /etc/init.d/stubby ]; then

        cp /etc/init.d/stubby \
           /etc/init.d/stubby.bak \
           2>/dev/null || true

        sed -i '/command_user=/d' \
            /etc/init.d/stubby

        sed -i '/capabilities=/d' \
            /etc/init.d/stubby

        log_info "已启用 Root Compatibility Mode"
    fi
}

# =========================================================
# 配置 DNS
# =========================================================

setup_dns() {

    log_step "配置系统 DNS"

    if [ "$IPV6_AVAILABLE" = true ]; then

        DNS_BLOCK=$(cat << EOF
nameserver 127.0.0.1
nameserver ::1
EOF
)

    else

        DNS_BLOCK=$(cat << EOF
nameserver 127.0.0.1
EOF
)

    fi

    # dhcpcd
    if [ -f /etc/dhcpcd.conf ]; then

        sed -i \
            '/^static domain_name_servers=/d' \
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
${DNS_BLOCK}
options edns0
options timeout:2
options attempts:2
EOF

        command -v resolvconf >/dev/null 2>&1 && \
            resolvconf -u || true
    fi

    # systemd-resolved
    if command -v systemctl >/dev/null 2>&1; then

        systemctl is-active systemd-resolved \
            >/dev/null 2>&1 && \
            systemctl disable --now \
            systemd-resolved >/dev/null 2>&1 || true
    fi

    [ -L "$RESOLV_CONF" ] && rm -f "$RESOLV_CONF"

    cat > "$RESOLV_CONF" << EOF
${DNS_BLOCK}
options edns0
options timeout:2
options attempts:2
EOF

    chmod 644 "$RESOLV_CONF"

    if [ "$OS" = "alpine" ]; then

        command -v rc-service >/dev/null 2>&1 && \
            rc-service dhcpcd restart \
            >/dev/null 2>&1 || true
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

            systemctl enable stubby \
                >/dev/null 2>&1 || true

            systemctl restart stubby
            ;;

        alpine)

            rc-update add stubby default \
                >/dev/null 2>&1 || true

            rc-service stubby restart
            ;;
    esac

    sleep 3

    # -----------------------------------------------------
    # 首次检测
    # -----------------------------------------------------

    if dig cloudflare.com @127.0.0.1 +short \
        >/dev/null 2>&1; then

        log_info "Stubby 已正常工作"
        return
    fi

    # -----------------------------------------------------
    # Alpine fallback
    # -----------------------------------------------------

    if [ "$OS" = "alpine" ] && \
       [ "$USE_ROOT_STUBBY" != true ]; then

        log_warn "检测到 Stubby 启动异常"
        log_warn "尝试 fallback Root Mode"

        USE_ROOT_STUBBY=true

        fix_alpine_service

        rc-service stubby restart

        sleep 3

        if dig cloudflare.com @127.0.0.1 +short \
            >/dev/null 2>&1; then

            log_info "Fallback Root Mode 启动成功"
            return
        fi
    fi

    # -----------------------------------------------------
    # 失败日志
    # -----------------------------------------------------

    log_error "Stubby 未正常响应 DNS 查询"

    echo ""
    echo "========== stubby 日志 =========="

    tail -n 50 /var/log/messages \
        2>/dev/null || true

    echo "================================"
    echo ""

    exit 1
}

# =========================================================
# DNS 测试
# =========================================================

test_dns() {

    log_step "执行 DNS 测试"

    TIME_MS=$(
        dig cloudflare.com @127.0.0.1 \
        2>/dev/null \
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

    echo "  监听地址:"

    if [ "$IPV6_AVAILABLE" = true ]; then
        echo "    127.0.0.1:53"
        echo "    [::1]:53"
    else
        echo "    127.0.0.1:53"
    fi

    echo ""
    echo "  上游 DNS:"
    echo "    Cloudflare DoT"
    echo "    Google DoT"

    echo ""
    echo "  运行模式:"

    if [ "$USE_ROOT_STUBBY" = true ]; then
        echo "    Root Compatibility Mode"
    else
        echo "    Capability Mode"
    fi

    echo ""
    echo "  配置文件:"
    echo "    ${STUBBY_CONF}"

    echo ""
    echo "  测试命令:"
    echo "    dig cloudflare.com @127.0.0.1"

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
"${BLUE}║        Secure-DNS Lite v1.4         ║${NC}"

    echo -e \
"${BLUE}║    Adaptive DoT Deployment System   ║${NC}"

    echo -e \
"${BLUE}╚══════════════════════════════════════╝${NC}"

    check_root

    detect_os

    detect_virtualization

    install_deps

    detect_ipv6

    detect_capability_issues

    config_stubby

    fix_alpine_service

    setup_dns

    start_stubby

    test_dns

    test_dot

    show_info
}

main "$@"
