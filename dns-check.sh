#!/usr/bin/env bash

# =========================================================
# Secure-DNS Diagnostic Tool
# 检测:
# - 系统环境
# - 网络
# - IPv4 / IPv6
# - resolv.conf
# - dhcpcd
# - systemd-resolved
# - Unbound
# - DoT
# - DNS解析
# =========================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

fail() {
    echo -e "${RED}[✗]${NC} $1"
}

step() {
    echo -e "\n${CYAN}▶${NC} ${BLUE}$1${NC}"
}

echo ""
echo "╔══════════════════════════════════════╗"
echo "║      Secure-DNS Diagnostic          ║"
echo "╚══════════════════════════════════════╝"

# =========================================================
# 系统检测
# =========================================================

step "系统检测"

if [ -f /etc/alpine-release ]; then
    OS="alpine"
    ok "系统: Alpine"
elif [ -f /etc/debian_version ]; then
    OS="debian"
    ok "系统: Debian/Ubuntu"
else
    OS="unknown"
    warn "未知系统"
fi

if [ -f /.dockerenv ]; then
    warn "Docker 容器环境"
fi

if grep -qa container=lxc /proc/1/environ 2>/dev/null; then
    warn "LXC 容器环境"
fi

if systemd-detect-virt >/dev/null 2>&1; then
    VIRT=$(systemd-detect-virt)
    ok "虚拟化: $VIRT"
fi

# =========================================================
# 网络检测
# =========================================================

step "网络检测"

if ping -4 -c1 1.1.1.1 >/dev/null 2>&1; then
    ok "IPv4 网络正常"
else
    fail "IPv4 网络异常"
fi

if ping -6 -c1 2606:4700:4700::1111 >/dev/null 2>&1; then
    ok "IPv6 网络正常"
else
    warn "IPv6 网络不可用"
fi

# =========================================================
# 本地监听检测
# =========================================================

step "Loopback 检测"

if ip addr show lo | grep -q "127.0.0.1"; then
    ok "IPv4 loopback 正常"
else
    fail "IPv4 loopback 异常"
fi

if ip addr show lo | grep -q "::1"; then
    ok "IPv6 loopback 正常"
else
    warn "IPv6 loopback 不可用"
fi

# =========================================================
# resolv.conf 检测
# =========================================================

step "resolv.conf 检测"

if [ -e /etc/resolv.conf ]; then
    ok "/etc/resolv.conf 存在"

    echo ""
    cat /etc/resolv.conf
    echo ""

    if grep -q "127.0.0.1" /etc/resolv.conf; then
        ok "已接管本地 DNS"
    else
        warn "未使用本地 DNS"
    fi
else
    fail "/etc/resolv.conf 不存在"
fi

if [ -f /etc/resolv.conf.head ]; then
    ok "发现 resolv.conf.head"

    echo ""
    cat /etc/resolv.conf.head
    echo ""
else
    warn "未发现 resolv.conf.head"
fi

# =========================================================
# dhcpcd 检测
# =========================================================

step "dhcpcd 检测"

if command -v dhcpcd >/dev/null 2>&1; then
    ok "dhcpcd 已安装"

    if pgrep dhcpcd >/dev/null 2>&1; then
        ok "dhcpcd 正在运行"
    else
        warn "dhcpcd 未运行"
    fi

    if [ -f /etc/dhcpcd.conf ]; then
        ok "dhcpcd.conf 存在"

        if grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
            warn "发现 nohook resolv.conf"
        fi
    fi
else
    warn "未安装 dhcpcd"
fi

# =========================================================
# systemd-resolved 检测
# =========================================================

step "systemd-resolved 检测"

if command -v systemctl >/dev/null 2>&1; then

    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        warn "systemd-resolved 正在运行"
    else
        ok "systemd-resolved 已关闭"
    fi

else
    warn "无 systemd"
fi

# =========================================================
# Unbound 检测
# =========================================================

step "Unbound 检测"

if command -v unbound >/dev/null 2>&1; then
    ok "Unbound 已安装"

    unbound -V | head -1

    if pgrep unbound >/dev/null 2>&1; then
        ok "Unbound 正在运行"
    else
        fail "Unbound 未运行"
    fi

    if [ -f /etc/unbound/unbound.conf ]; then
        ok "配置文件存在"

        if unbound-checkconf >/dev/null 2>&1; then
            ok "配置文件正常"
        else
            fail "配置文件错误"

            echo ""
            unbound-checkconf
            echo ""
        fi
    fi

else
    fail "未安装 Unbound"
fi

# =========================================================
# 53端口检测
# =========================================================

step "53 端口检测"

if ss -lnptu 2>/dev/null | grep -q ":53"; then
    ok "53 端口已监听"

    echo ""
    ss -lnptu | grep ":53"
    echo ""
else
    fail "53 端口未监听"
fi

# =========================================================
# DoT 连通性检测
# =========================================================

step "DoT 连通性检测"

if timeout 3 sh -c 'echo > /dev/tcp/1.1.1.1/853' 2>/dev/null; then
    ok "Cloudflare DoT 可达"
else
    fail "Cloudflare DoT 不可达"
fi

if timeout 3 sh -c 'echo > /dev/tcp/8.8.8.8/853' 2>/dev/null; then
    ok "Google DoT 可达"
else
    fail "Google DoT 不可达"
fi

# =========================================================
# DNS解析测试
# =========================================================

step "DNS 解析测试"

if dig cloudflare.com @127.0.0.1 +short >/dev/null 2>&1; then
    ok "本地 DNS 正常"

    echo ""
    dig cloudflare.com @127.0.0.1 +short
    echo ""
else
    fail "本地 DNS 解析失败"
fi

# =========================================================
# TLS测试
# =========================================================

step "TLS 上游测试"

if openssl s_client \
-connect 1.1.1.1:853 \
-servername cloudflare-dns.com \
brief </dev/null >/dev/null 2>&1; then

    ok "Cloudflare TLS 正常"

else
    fail "Cloudflare TLS 失败"
fi

# =========================================================
# 总结
# =========================================================

echo ""
echo "═══════════════════════════════════════"
echo "           检测完成"
echo "═══════════════════════════════════════"
echo ""
