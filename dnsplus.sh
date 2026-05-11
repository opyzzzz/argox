```bash
#!/usr/bin/env bash

# =========================================================
# Secure-DNS Stable Edition
# Unbound DNS Cache + Secure Resolver
# Debian / Ubuntu / Alpine
# =========================================================

set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

UNBOUND_CONF="/etc/unbound/unbound.conf"

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
                bind-tools \
                ca-certificates \
                curl
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y \
                unbound \
                dnsutils \
                ca-certificates \
                curl
            ;;
    esac

    log "依赖安装完成"
}

detect_network() {
    step "检测 IPv4"

    if ping -4 -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
        HAS_IPV4=1
        log "IPv4 可用"
    else
        warn "IPv4 不可用"
    fi

    step "检测 IPv6"

    if ping -6 -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1; then
        HAS_IPV6=1
        log "IPv6 可用"
    else
        warn "IPv6 不可用"
    fi
}

disable_systemd_resolved() {
    if [ "$OS" = "debian" ]; then

        if systemctl list-unit-files | grep -q systemd-resolved; then

            step "关闭 systemd-resolved"

            systemctl disable systemd-resolved >/dev/null 2>&1 || true
            systemctl stop systemd-resolved >/dev/null 2>&1 || true

            rm -f /etc/resolv.conf

            log "systemd-resolved 已关闭"
        fi
    fi
}

configure_resolv() {

    step "配置 resolv.conf"

    case "$OS" in

        alpine)

            mkdir -p /etc

            cat >/etc/resolv.conf.head <<EOF
nameserver 127.0.0.1
EOF

            if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/resolv.conf.head <<EOF
nameserver ::1
EOF
            fi

            if [ -f /etc/dhcpcd.conf ]; then

                grep -q "nohook resolv.conf" /etc/dhcpcd.conf || \
                    echo "nohook resolv.conf" >> /etc/dhcpcd.conf

                log "已禁止 dhcpcd 覆盖 resolv.conf"
            fi

            cat >/etc/resolv.conf <<EOF
nameserver 127.0.0.1
EOF

            if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/resolv.conf <<EOF
nameserver ::1
EOF
            fi
            ;;

        debian)

            cat >/etc/resolv.conf <<EOF
nameserver 127.0.0.1
EOF

            if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/resolv.conf <<EOF
nameserver ::1
EOF
            fi
            ;;
    esac

    log "系统 DNS 已配置"
}

configure_unbound() {

    step "配置 Unbound"

    mkdir -p /etc/unbound

    cat >"$UNBOUND_CONF" <<EOF
server:
    interface: 127.0.0.1
    port: 53

EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>"$UNBOUND_CONF" <<EOF
    interface: ::1
EOF
    fi

cat >>"$UNBOUND_CONF" <<EOF

    do-ip4: yes
    do-udp: yes
    do-tcp: yes

EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>"$UNBOUND_CONF" <<EOF
    do-ip6: yes
EOF
    else
cat >>"$UNBOUND_CONF" <<EOF
    do-ip6: no
EOF
    fi

cat >>"$UNBOUND_CONF" <<EOF

    prefer-ip6: no

    verbosity: 0

    hide-identity: yes
    hide-version: yes

    prefetch: yes
    qname-minimisation: yes

    rrset-roundrobin: yes

    cache-min-ttl: 300
    cache-max-ttl: 14400

    edns-buffer-size: 1232

    access-control: 127.0.0.0/8 allow
EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>"$UNBOUND_CONF" <<EOF
    access-control: ::1 allow
EOF
    fi

    log "Unbound 配置完成"
}

validate_config() {

    step "检查配置"

    if unbound-checkconf >/dev/null 2>&1; then
        log "配置检查通过"
    else
        err "配置错误"
        unbound-checkconf
        exit 1
    fi
}

start_unbound() {

    step "启动 Unbound"

    case "$OS" in

        alpine)

            rc-update add unbound default >/dev/null 2>&1 || true
            rc-service unbound restart
            ;;

        debian)

            systemctl enable unbound >/dev/null 2>&1
            systemctl restart unbound
            ;;
    esac

    sleep 2

    if ss -lnup | grep -q ":53"; then
        log "Unbound 已启动"
    else
        err "Unbound 启动失败"
        exit 1
    fi
}

test_dns() {

    step "测试 DNS"

    if dig cloudflare.com @127.0.0.1 +short >/dev/null 2>&1; then

        local result
        result=$(dig cloudflare.com @127.0.0.1 +short | head -n1)

        log "DNS 解析正常: $result"

    else

        err "DNS 测试失败"
        exit 1
    fi
}

show_info() {

cat <<EOF

═══════════════════════════════════════
        Secure-DNS 部署完成
═══════════════════════════════════════

监听地址:
  127.0.0.1:53
EOF

if [ "$HAS_IPV6" -eq 1 ]; then
cat <<EOF
  ::1:53
EOF
fi

cat <<EOF

配置文件:
  $UNBOUND_CONF

测试命令:
  dig cloudflare.com @127.0.0.1

当前 resolv.conf:
EOF

cat /etc/resolv.conf

echo
}

main() {

    require_root

    echo
    echo "═══════════════════════════════════════"
    echo "        Secure-DNS Stable Edition"
    echo "═══════════════════════════════════════"

    detect_os

    install_deps

    detect_network

    disable_systemd_resolved

    configure_resolv

    configure_unbound

    validate_config

    start_unbound

    test_dns

    show_info
}

main "$@"
```
