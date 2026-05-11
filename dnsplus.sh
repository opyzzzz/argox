```bash id="n7h4pw"
#!/usr/bin/env bash

# =========================================================
# Secure-DNS Resolver Takeover
# Unbound + resolv.conf takeover
# Debian / Ubuntu / Alpine
# =========================================================

set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

OS=""
HAS_IPV6=0

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
    [ "$(id -u)" = 0 ] || {
        err "请使用 root 运行"
        exit 1
    }
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
                curl \
                ca-certificates
            ;;

        debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -qq

            apt-get install -y \
                unbound \
                dnsutils \
                curl \
                ca-certificates
            ;;
    esac

    log "依赖安装完成"
}

detect_ipv6() {

    step "检测 IPv6"

    if ping -6 -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1; then
        HAS_IPV6=1
        log "IPv6 可用"
    else
        warn "IPv6 不可用"
    fi
}

disable_system_dns() {

    step "接管系统 DNS"

    case "$OS" in

        debian)

            if systemctl list-unit-files | grep -q systemd-resolved; then

                systemctl disable systemd-resolved >/dev/null 2>&1 || true
                systemctl stop systemd-resolved >/dev/null 2>&1 || true

                log "已关闭 systemd-resolved"
            fi

            rm -f /etc/resolv.conf || true
            ;;

        alpine)

            if [ -f /etc/dhcpcd.conf ]; then

                grep -q '^nohook resolv.conf' /etc/dhcpcd.conf || \
                    echo 'nohook resolv.conf' >> /etc/dhcpcd.conf

                log "已禁止 dhcpcd 覆盖 resolv.conf"
            fi
            ;;
    esac
}

configure_resolv_head() {

    step "配置 resolv.conf.head"

    cat >/etc/resolv.conf.head <<EOF
nameserver 127.0.0.1
EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/resolv.conf.head <<EOF
nameserver ::1
EOF
    fi

    log "resolv.conf.head 已配置"
}

write_resolv_conf() {

    step "写入 resolv.conf"

    cat >/etc/resolv.conf <<EOF
nameserver 127.0.0.1
EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/resolv.conf <<EOF
nameserver ::1
EOF
    fi

    cat >>/etc/resolv.conf <<EOF

options timeout:2
options attempts:2
options edns0
EOF

    log "resolv.conf 已写入"
}

configure_unbound() {

    step "配置 Unbound"

    cat >/etc/unbound/unbound.conf <<EOF
server:
    interface: 127.0.0.1
    port: 53

EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/unbound/unbound.conf <<EOF
    interface: ::1
EOF
    fi

cat >>/etc/unbound/unbound.conf <<EOF

    do-ip4: yes
    do-udp: yes
    do-tcp: yes
EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/unbound/unbound.conf <<EOF
    do-ip6: yes
EOF
    else
cat >>/etc/unbound/unbound.conf <<EOF
    do-ip6: no
EOF
    fi

cat >>/etc/unbound/unbound.conf <<EOF

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
cat >>/etc/unbound/unbound.conf <<EOF
    access-control: ::1 allow
EOF
    fi

cat >>/etc/unbound/unbound.conf <<EOF

forward-zone:
    name: "."

    forward-tls-upstream: yes

    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    forward-addr: 8.8.8.8@853#dns.google
    forward-addr: 8.8.4.4@853#dns.google
EOF

    if [ "$HAS_IPV6" -eq 1 ]; then
cat >>/etc/unbound/unbound.conf <<EOF
    forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
    forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com
EOF
    fi

    log "Unbound 配置完成"
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

    if ss -lnup | grep -q ':53'; then
        log "Unbound 已启动"
    else
        err "Unbound 启动失败"
        exit 1
    fi
}

restart_network_manager() {

    step "刷新 DHCP"

    case "$OS" in

        alpine)

            rc-service dhcpcd restart || true
            ;;

        debian)

            systemctl restart networking 2>/dev/null || true
            ;;
    esac

    sleep 2
}

test_dns() {

    step "测试 DNS"

    if dig cloudflare.com @127.0.0.1 +short >/dev/null 2>&1; then

        RESULT=$(dig cloudflare.com @127.0.0.1 +short | head -n1)

        log "DNS 正常: $RESULT"

    else

        err "DNS 测试失败"
        exit 1
    fi
}

show_result() {

echo
echo "═══════════════════════════════════════"
echo "      Secure-DNS 接管完成"
echo "═══════════════════════════════════════"
echo

echo "当前 resolv.conf:"
cat /etc/resolv.conf

echo
echo "测试命令:"
echo "dig cloudflare.com @127.0.0.1"
echo
}

main() {

    require_root

    echo
    echo "═══════════════════════════════════════"
    echo "      Secure-DNS Resolver Takeover"
    echo "═══════════════════════════════════════"

    detect_os

    install_deps

    detect_ipv6

    disable_system_dns

    configure_resolv_head

    write_resolv_conf

    configure_unbound

    unbound-checkconf

    start_unbound

    restart_network_manager

    test_dns

    show_result
}

main "$@"
```
