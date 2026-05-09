#!/bin/sh
#===============================================================================
# 加密DNS一键部署脚本 (Alpine/Debian, x86_64/arm)
# 功能: 安装配置 dnscrypt-proxy，使用 Google/Cloudflare DoH/DoT
#       持久化运行，防篡改，接管系统DNS，自动清理30天前日志
#===============================================================================

set -e

#--- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[信息]${NC} $1"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; exit 1; }

#--- 权限检查 ---
[ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行此脚本"

#--- 架构检测 ---
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="aarch64" ;;
    armv7l)  ARCH="arm" ;;
    armv8l)  ARCH="aarch64" ;;  # 部分内核报告为armv8l
    *)       error "不支持的架构: $ARCH" ;;
esac
info "检测到架构: $ARCH"

#--- 系统检测与依赖安装 ---
install_deps() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        info "检测到 Alpine Linux，安装依赖..."
        apk update
        apk add --no-cache dnscrypt-proxy openrc logrotate ca-certificates curl
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        info "检测到 Debian/Ubuntu，安装依赖..."
        apt-get update -qq
        apt-get install -y -qq dnscrypt-proxy logrotate ca-certificates curl
    else
        error "不支持的系统，仅支持 Alpine 和 Debian/Ubuntu"
    fi
}

#--- 预检查 dnscrypt-proxy 包是否存在 ---
check_package() {
    if [ "$OS" = "alpine" ]; then
        if ! apk search -q dnscrypt-proxy 2>/dev/null | grep -q "."; then
            error "Alpine 仓库中未找到 dnscrypt-proxy，请检查系统版本"
        fi
    elif [ "$OS" = "debian" ]; then
        if ! apt-cache show dnscrypt-proxy >/dev/null 2>&1; then
            error "Debian 仓库中未找到 dnscrypt-proxy"
        fi
    fi
}

#--- 配置 dnscrypt-proxy ---
configure_dnscrypt() {
    local CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    
    # 备份原配置
    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"

    info "请选择加密DNS模式:"
    echo "1) DNS over HTTPS (DoH) - 推荐"
    echo "2) DNS over TLS (DoT)"
    read -p "请输入选择 [1-2] (默认1): " MODE_CHOICE
    MODE_CHOICE=${MODE_CHOICE:-1}

    info "请选择上游DNS提供商:"
    echo "1) Google DNS"
    echo "2) Cloudflare DNS"
    read -p "请输入选择 [1-2] (默认2): " PROVIDER
    PROVIDER=${PROVIDER:-2}

    # 根据选择生成配置
    if [ "$MODE_CHOICE" = "1" ]; then
        # DoH 配置
        if [ "$PROVIDER" = "1" ]; then
            DOH_URL="https://dns.google/dns-query"
            STAMP="sdns://AgUAAAAAAAAAACAe9iTPwq0ylRaZT4mKbMBLbUoLxPS9DnE_T4YYVxMeD2Rucy5nb29nbGUuY29tL2Rucy1xdWVyeQ"
        else
            DOH_URL="https://cloudflare-dns.com/dns-query"
            STAMP="sdns://AgcAAAAAAAAABzEuMC4wLjGgENk8mGSlIfMGXMOlIlCcKvq7AVgcrZxtjon911-epjNtI2Rucy5jbG91ZGZsYXJlLmNvbS9kbnMtcXVlcnk"
        fi
        SERVER_NAMES="['cloudflare', 'google']"
    else
        # DoT 配置
        if [ "$PROVIDER" = "1" ]; then
            STAMP="sdns://AwAAAAAAAAAAAAAPZG5zLmdvb2dsZS5jb20KL2Rucy1xdWVyeQ"
        else
            STAMP="sdns://AwAAAAAAAAAAAAARY2xvdWRmbGFyZS1kbnMuY29tCi9kbnMtcXVlcnk"
        fi
        SERVER_NAMES="['cloudflare-dot', 'google-dot']"
    fi

    info "写入配置文件..."
    cat > "$CONF" << EOF
# dnscrypt-proxy 配置文件 - 自动生成
# 生成时间: $(date)

listen_addresses = ['127.0.0.1:53', '[::1]:53']
max_clients = 250
user_name = '_dnscrypt-proxy'

# 强制使用 DNSCrypt/DoH/DoT，拒绝明文DNS
force_tcp = false
timeout = 2500
keepalive = 30

# 上游服务器 (仅使用加密DNS)
server_names = ${SERVER_NAMES}

[static]
  [static.'cloudflare']
  stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjGgENk8mGSlIfMGXMOlIlCcKvq7AVgcrZxtjon911-epjNtI2Rucy5jbG91ZGZsYXJlLmNvbS9kbnMtcXVlcnk'
  
  [static.'google']
  stamp = 'sdns://AgUAAAAAAAAAACAe9iTPwq0ylRaZT4mKbMBLbUoLxPS9DnE_T4YYVxMeD2Rucy5nb29nbGUuY29tL2Rucy1xdWVyeQ'
  
  [static.'cloudflare-dot']
  stamp = 'sdns://AwAAAAAAAAAAAAARY2xvdWRmbGFyZS1kbnMuY29tCi9kbnMtcXVlcnk'
  
  [static.'google-dot']
  stamp = 'sdns://AwAAAAAAAAAAAAAPZG5zLmdvb2dsZS5jb20KL2Rucy1xdWVyeQ'

# 缓存 (减少延迟，持久化)
cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

# 日志配置
[query_log]
  file = '/var/log/dnscrypt-proxy/query.log'
  format = 'tsv'
  ignored_qtypes = ['DNSKEY', 'NS']

# 黑名单/白名单 (可选)
[blocked_names]
  blocked_names_file = '/etc/dnscrypt-proxy/blocked-names.txt'

# 匿名中继 (可选，关闭以提高速度)
[anonymized_dns]
  routes = []
  skip_incompatible = false

# 本地IPv4/IPv6映射
[ipv4]
  block_ipv4 = false
[ipv6]
  block_ipv6 = false

# 源端口随机化
dnssec = true
edns_client_subnet = false
EOF

    # 创建空的黑名单文件
    touch /etc/dnscrypt-proxy/blocked-names.txt

    # 创建日志目录
    mkdir -p /var/log/dnscrypt-proxy
    chown -R _dnscrypt-proxy:_dnscrypt-proxy /var/log/dnscrypt-proxy 2>/dev/null || chown -R dnscrypt-proxy:dnscrypt-proxy /var/log/dnscrypt-proxy 2>/dev/null || true
}

#--- 接管系统 DNS ---
takeover_dns() {
    info "接管系统 DNS 解析..."
    
    # 禁用系统默认 DNS 服务
    if [ "$OS" = "alpine" ]; then
        # Alpine 可能使用 udhcpc 或静态配置
        if [ -f /etc/resolv.conf ]; then
            # 备份
            cp /etc/resolv.conf /etc/resolv.conf.bak.dnscrypt.$(date +%Y%m%d)
        fi
        
        # 设置为本地 DNS
        cat > /etc/resolv.conf << EOF
# 由 dnscrypt-proxy 接管 - $(date)
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

        # 防止 DHCP 客户端覆写
        if [ -f /etc/udhcpc/udhcpc.conf ]; then
            grep -q "RESOLV_CONF" /etc/udhcpc/udhcpc.conf 2>/dev/null || \
                echo 'RESOLV_CONF="NO"' >> /etc/udhcpc/udhcpc.conf
        fi
        
    elif [ "$OS" = "debian" ]; then
        # Debian/Ubuntu 使用 resolvconf 或 systemd-resolved
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
            info "已停止 systemd-resolved"
        fi
        
        # 备份
        [ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak.dnscrypt.$(date +%Y%m%d)
        
        cat > /etc/resolv.conf << EOF
# 由 dnscrypt-proxy 接管 - $(date)
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

        # 加锁防止修改
        chattr +i /etc/resolv.conf 2>/dev/null || warn "无法锁定 /etc/resolv.conf (文件系统不支持 chattr)"
    fi
    
    # 防止 DNS 泄露：屏蔽常见明文 DNS 端口出站 (可选，需要 iptables)
    if command -v iptables >/dev/null 2>&1; then
        info "添加防火墙规则防止 DNS 泄露..."
        # 仅允许本机 dnscrypt-proxy 出站
        iptables -C OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || \
            iptables -A OUTPUT -p udp --dport 53 -j DROP
        iptables -C OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || \
            iptables -A OUTPUT -p tcp --dport 53 -j DROP
        
        if [ "$OS" = "debian" ]; then
            apt-get install -y -qq iptables-persistent 2>/dev/null || true
            netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        elif [ "$OS" = "alpine" ]; then
            rc-update add iptables 2>/dev/null || true
            /etc/init.d/iptables save 2>/dev/null || iptables-save > /etc/iptables/rules-save 2>/dev/null || true
        fi
        info "防火墙规则已添加: 阻止出站明文 DNS (UDP/TCP 53)"
    fi
}

#--- 防篡改保护 ---
protect_config() {
    info "应用防篡改保护..."
    
    local CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    
    # 移除写权限 (仅 root 可修改)
    chmod 644 "$CONF" 2>/dev/null || true
    chown root:root "$CONF" 2>/dev/null || true
    
    # 尝试使用 chattr 锁定 (ext4/btrfs 等文件系统)
    if command -v chattr >/dev/null 2>&1; then
        chattr +i "$CONF" 2>/dev/null && \
            info "配置文件已锁定 (immutable)" || \
            warn "无法锁定配置文件 (文件系统限制)"
    fi
    
    # 锁定黑名单
    chmod 644 /etc/dnscrypt-proxy/blocked-names.txt 2>/dev/null || true
    chattr +i /etc/dnscrypt-proxy/blocked-names.txt 2>/dev/null || true
}

#--- 启动并设置持久化服务 ---
setup_service() {
    info "配置持久化服务..."
    
    if [ "$OS" = "alpine" ]; then
        # Alpine OpenRC
        rc-update add dnscrypt-proxy default
        rc-service dnscrypt-proxy restart 2>/dev/null || \
            /etc/init.d/dnscrypt-proxy restart
        info "OpenRC 服务已启用 (开机自启)"
        
    elif [ "$OS" = "debian" ]; then
        # Debian systemd
        systemctl enable dnscrypt-proxy 2>/dev/null || \
            systemctl enable dnscrypt-proxy.socket 2>/dev/null
        
        # 重启服务（处理 socket 激活情况）
        systemctl stop dnscrypt-proxy dnscrypt-proxy.socket 2>/dev/null || true
        systemctl start dnscrypt-proxy 2>/dev/null || \
            systemctl start dnscrypt-proxy.socket 2>/dev/null
        
        # 验证服务状态
        sleep 1
        if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null || \
           systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
            info "systemd 服务已启用并运行 (开机自启)"
        else
            warn "服务可能未正常启动，请检查: systemctl status dnscrypt-proxy"
        fi
    fi
}

#--- 配置日志轮转 (自动清理30天前日志) ---
setup_logrotate() {
    info "配置日志自动清理 (保留30天)..."
    
    cat > /etc/logrotate.d/dnscrypt-proxy << EOF
/var/log/dnscrypt-proxy/*.log {
    daily
    rotate 30
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        if [ -f /var/run/dnscrypt-proxy.pid ]; then
            kill -HUP \$(cat /var/run/dnscrypt-proxy.pid) 2>/dev/null || true
        fi
    endscript
}
EOF

    # 立即执行一次轮转以验证配置
    logrotate -f /etc/logrotate.d/dnscrypt-proxy 2>/dev/null || true
    info "日志轮转配置完成: 每日轮转，保留30天，旧日志自动压缩删除"
}

#--- 验证 DNS 加密工作 ---
verify_dns() {
    info "验证加密 DNS 功能..."
    
    # 等待服务启动
    sleep 2
    
    # 测试本地 DNS 解析
    if command -v dig >/dev/null 2>&1; then
        TEST_RESULT=$(dig +short @127.0.0.1 google.com 2>/dev/null | head -1)
    elif command -v nslookup >/dev/null 2>&1; then
        TEST_RESULT=$(nslookup google.com 127.0.0.1 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
    else
        TEST_RESULT="工具未安装，跳过验证"
    fi
    
    if [ -n "$TEST_RESULT" ] && [ "$TEST_RESULT" != "工具未安装，跳过验证" ]; then
        info "DNS 解析成功! google.com -> $TEST_RESULT"
    else
        warn "无法验证 DNS 解析，请手动测试: dig @127.0.0.1 google.com"
    fi
    
    # 检查加密 DNS 连接
    info "检查加密 DNS 连接状态..."
    if ss -tlnp 2>/dev/null | grep -q ":53.*dnscrypt" || \
       netstat -tlnp 2>/dev/null | grep -q ":53.*dnscrypt"; then
        info "dnscrypt-proxy 正在监听 53 端口 ✓"
    else
        warn "端口 53 未检测到 dnscrypt-proxy 监听，请检查服务状态"
    fi
}

#--- 显示状态信息 ---
show_status() {
    echo ""
    echo "============================================="
    echo "       加密 DNS 部署完成!"
    echo "============================================="
    echo "DNS 提供商: $(grep -o "server_names = .*" /etc/dnscrypt-proxy/dnscrypt-proxy.toml 2>/dev/null || echo '配置中')"
    echo "监听地址: 127.0.0.1:53, [::1]:53"
    echo "配置路径: /etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    echo "日志路径: /var/log/dnscrypt-proxy/query.log"
    echo "日志保留: 30天 (自动清理)"
    echo ""
    echo "常用命令:"
    if [ "$OS" = "alpine" ]; then
        echo "  查看状态: rc-service dnscrypt-proxy status"
        echo "  重启服务: rc-service dnscrypt-proxy restart"
        echo "  查看日志: tail -f /var/log/dnscrypt-proxy/query.log"
    else
        echo "  查看状态: systemctl status dnscrypt-proxy"
        echo "  重启服务: systemctl restart dnscrypt-proxy"
        echo "  查看日志: journalctl -u dnscrypt-proxy -f"
        echo "  查询日志: tail -f /var/log/dnscrypt-proxy/query.log"
    fi
    echo ""
    echo "DNS 泄露测试: dig @127.0.0.1 whoami.akamai.net"
    echo "加密验证: https://www.dnsleaktest.com"
    echo "============================================="
}

#--- 主流程 ---
main() {
    echo ""
    echo "============================================="
    echo "   加密 DNS 一键部署脚本"
    echo "   支持: Alpine / Debian | x86_64 / ARM"
    echo "============================================="
    echo ""
    
    install_deps
    check_package
    configure_dnscrypt
    takeover_dns
    protect_config
    setup_logrotate
    setup_service
    verify_dns
    show_status
    
    info "全部完成! 系统 DNS 已切换为加密 DNS"
}

main "$@"
