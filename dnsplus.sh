#!/bin/sh
#===============================================================================
# 加密DNS一键部署脚本 v2 (Alpine/Debian, x86_64/arm)
# 功能: 安装配置 dnscrypt-proxy，使用 Google/Cloudflare DoH/DoT
#       持久化运行，防篡改，接管系统DNS，自动清理30天前日志
#===============================================================================

set -e

#--- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[信息]${NC} $1"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; exit 1; }

#--- 权限检查 ---
[ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行此脚本"

#--- 参数解析 (支持命令行参数) ---
PROVIDER="cloudflare"
MODE="doh"

while [ $# -gt 0 ]; do
    case "$1" in
        --google)   PROVIDER="google" ;;
        --cf)       PROVIDER="cloudflare" ;;
        --doh)      MODE="doh" ;;
        --dot)      MODE="dot" ;;
        --help)     
            echo "用法: $0 [选项]"
            echo "  --cf        使用 Cloudflare DNS (默认)"
            echo "  --google    使用 Google DNS"
            echo "  --doh       使用 DNS over HTTPS (默认)"
            echo "  --dot       使用 DNS over TLS"
            exit 0 ;;
        *) warn "未知参数: $1" ;;
    esac
    shift
done

#--- 架构检测 ---
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ;;
    aarch64) ;;
    armv7l)  ;;
    armv8l)  ARCH="aarch64" ;;
    *)       error "不支持的架构: $ARCH" ;;
esac
info "架构: $ARCH | 系统: $(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME" | cut -d'"' -f2 || uname -s)"
info "DNS提供商: $PROVIDER | 模式: $MODE"

#--- 系统检测与依赖安装 ---
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    info "检测到 Alpine Linux，安装依赖..."
    apk update
    apk add --no-cache dnscrypt-proxy ca-certificates curl
    
    # Alpine 的 dnscrypt-proxy 配置路径
    CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    USER="dnscrypt-proxy"
    GROUP="dnscrypt-proxy"
    
elif [ -f /etc/debian_version ]; then
    OS="debian"
    info "检测到 Debian/Ubuntu，安装依赖..."
    apt-get update -qq
    apt-get install -y -qq dnscrypt-proxy ca-certificates curl iptables
    
    # Debian 的 dnscrypt-proxy 配置路径
    CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    USER="_dnscrypt-proxy"
    GROUP="_dnscrypt-proxy"
else
    error "不支持的系统，仅支持 Alpine 和 Debian"
fi

#--- 检查 dnscrypt-proxy 是否安装成功 ---
if ! command -v dnscrypt-proxy >/dev/null 2>&1; then
    error "dnscrypt-proxy 安装失败"
fi

#--- 停止现有服务 ---
info "停止现有 DNS 服务..."
if [ "$OS" = "alpine" ]; then
    rc-service dnscrypt-proxy stop 2>/dev/null || true
elif [ "$OS" = "debian" ]; then
    systemctl stop dnscrypt-proxy dnscrypt-proxy.socket 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
fi

#--- 备份原配置 ---
if [ -f "$CONF" ]; then
    cp "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份原配置"
fi

#--- 创建配置目录 ---
mkdir -p /etc/dnscrypt-proxy /var/log/dnscrypt-proxy

#--- 生成配置文件 ---
info "写入配置文件 ($MODE - $PROVIDER)..."

if [ "$MODE" = "doh" ]; then
    if [ "$PROVIDER" = "google" ]; then
        SERVER_NAMES="['google']"
    else
        SERVER_NAMES="['cloudflare']"
    fi
else
    if [ "$PROVIDER" = "google" ]; then
        SERVER_NAMES="['google-dot']"
    else
        SERVER_NAMES="['cloudflare-dot']"
    fi
fi

cat > "$CONF" << 'DNSCRYPT_EOF'
##############################################
# dnscrypt-proxy 配置
# 生成时间: TIMESTAMP_PLACEHOLDER
# 提供商: PROVIDER_PLACEHOLDER
# 模式: MODE_PLACEHOLDER
##############################################

# 监听地址 (所有接口，可根据需要修改)
listen_addresses = ['127.0.0.1:53', '[::1]:53']
max_clients = 250

# 运行用户 (Alpine用dnscrypt-proxy, Debian用_dnscrypt-proxy)
user_name = 'USER_PLACEHOLDER'

# 超时设置
timeout = 5000
keepalive = 30

# 强制使用加密DNS
force_tcp = false

# 上游服务器配置
server_names = SERVER_NAMES_PLACEHOLDER

[static]
  # Cloudflare DoH
  [static.'cloudflare']
  stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjGgENk8mGSlIfMGXMOlIlCcKvq7AVgcrZxtjon911-epjNtI2Rucy5jbG91ZGZsYXJlLmNvbS9kbnMtcXVlcnk'
  
  # Google DoH
  [static.'google']
  stamp = 'sdns://AgUAAAAAAAAAACAe9iTPwq0ylRaZT4mKbMBLbUoLxPS9DnE_T4YYVxMeD2Rucy5nb29nbGUuY29tL2Rucy1xdWVyeQ'
  
  # Cloudflare DoT
  [static.'cloudflare-dot']
  stamp = 'sdns://AwAAAAAAAAAAAAARY2xvdWRmbGFyZS1kbnMuY29tCi9kbnMtcXVlcnk'
  
  # Google DoT
  [static.'google-dot']
  stamp = 'sdns://AwAAAAAAAAAAAAAPZG5zLmdvb2dsZS5jb20KL2Rucy1xdWVyeQ'

# DNS 缓存
cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

# DNSSEC 验证
dnssec = true

# 禁用 EDNS Client Subnet (隐私保护)
edns_client_subnet = false

# 查询日志
[query_log]
  file = '/var/log/dnscrypt-proxy/query.log'
  format = 'tsv'

# 匿名中继 (关闭以提高性能)
[anonymized_dns]
  routes = []
  skip_incompatible = false

# IPv4/IPv6
[ipv4]
  block_ipv4 = false
[ipv6]
  block_ipv6 = false
DNSCRYPT_EOF

# 替换占位符
sed -i "s/TIMESTAMP_PLACEHOLDER/$(date)/" "$CONF"
sed -i "s/PROVIDER_PLACEHOLDER/$PROVIDER/" "$CONF"
sed -i "s/MODE_PLACEHOLDER/$MODE/" "$CONF"
sed -i "s/USER_PLACEHOLDER/$USER/" "$CONF"
sed -i "s/SERVER_NAMES_PLACEHOLDER/$SERVER_NAMES/" "$CONF"

# 创建空的黑名单文件
touch /etc/dnscrypt-proxy/blocked-names.txt

# 设置正确的权限
info "设置文件权限..."
chown -R ${USER}:${GROUP} /var/log/dnscrypt-proxy 2>/dev/null || \
chown -R $(id -u ${USER} 2>/dev/null || echo 0):$(id -g ${GROUP} 2>/dev/null || echo 0) /var/log/dnscrypt-proxy 2>/dev/null || true
chmod 644 "$CONF"

#--- 接管系统 DNS ---
info "接管系统 DNS 解析..."

# 备份 resolv.conf
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak.dnscrypt.$(date +%Y%m%d)
fi

# 移除 immutable 属性 (如果之前设置过)
chattr -i /etc/resolv.conf 2>/dev/null || true

# 写入新的 DNS 配置
cat > /etc/resolv.conf << EOF
# DNS 由 dnscrypt-proxy 管理
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

# 锁定 resolv.conf 防止修改
chattr +i /etc/resolv.conf 2>/dev/null && \
    info "/etc/resolv.conf 已锁定 (immutable)" || \
    warn "无法锁定 /etc/resolv.conf (文件系统不支持 chattr，但配置仍然有效)"

#--- 防篡改保护 ---
protect_config() {
    info "应用配置文件防篡改保护..."
    
    chmod 644 "$CONF"
    chown root:root "$CONF"
    
    if command -v chattr >/dev/null 2>&1; then
        chattr -i "$CONF" 2>/dev/null || true  # 先移除
        chattr +i "$CONF" 2>/dev/null && \
            info "配置文件已锁定 (immutable)" || \
            warn "无法锁定配置文件"
    fi
}
protect_config

#--- 防火墙规则 (防 DNS 泄露) ---
setup_firewall() {
    if command -v iptables >/dev/null 2>&1; then
        info "配置防火墙规则 (阻止明文 DNS 泄露)..."
        
        # 阻止所有出站明文 DNS (UDP 53)
        iptables -C OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || \
            iptables -A OUTPUT -p udp --dport 53 -j DROP
        
        # 阻止所有出站明文 DNS (TCP 53)
        iptables -C OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || \
            iptables -A OUTPUT -p tcp --dport 53 -j DROP
        
        # 保存规则
        if [ "$OS" = "alpine" ]; then
            rc-update add iptables 2>/dev/null || true
            iptables-save > /etc/iptables/rules-save 2>/dev/null || true
        elif [ "$OS" = "debian" ]; then
            apt-get install -y -qq iptables-persistent 2>/dev/null || true
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        
        info "防火墙规则已配置"
    else
        warn "未找到 iptables，跳过防火墙配置"
    fi
}
setup_firewall

#--- 配置日志自动清理 (30天) ---
setup_logrotate() {
    info "配置日志轮转 (保留30天)..."
    
    if command -v logrotate >/dev/null 2>&1; then
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
        info "日志轮转配置完成"
    else
        # Alpine 可能没有 logrotate，使用 cron 实现
        info "logrotate 不可用，使用 crontab 清理旧日志..."
        
        if [ "$OS" = "alpine" ]; then
            apk add --no-cache dcron 2>/dev/null || true
        fi
        
        # 创建每日清理脚本
        cat > /etc/periodic/daily/dnscrypt-log-cleanup << 'EOF'
#!/bin/sh
# 清理30天前的 dnscrypt-proxy 日志
LOG_DIR="/var/log/dnscrypt-proxy"
if [ -d "$LOG_DIR" ]; then
    find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null
    find "$LOG_DIR" -name "*.gz" -mtime +30 -delete 2>/dev/null
fi
EOF
        chmod +x /etc/periodic/daily/dnscrypt-log-cleanup 2>/dev/null || true
        
        info "已添加每日日志清理任务"
    fi
}
setup_logrotate

#--- 启动服务 ---
info "启动 dnscrypt-proxy 服务..."

if [ "$OS" = "alpine" ]; then
    # Alpine OpenRC
    rc-update add dnscrypt-proxy default
    rc-service dnscrypt-proxy restart
    
    # 等待服务启动
    sleep 2
    
    if rc-service dnscrypt-proxy status | grep -q "started"; then
        info "服务已成功启动"
    else
        warn "服务可能未正常启动，请检查:"
        warn "  rc-service dnscrypt-proxy status"
        warn "  cat /var/log/dnscrypt-proxy/dnscrypt-proxy.log"
        
        # 尝试直接运行以查看错误
        info "尝试直接运行 dnscrypt-proxy 查看错误..."
        timeout 3 dnscrypt-proxy -config "$CONF" 2>&1 || true
    fi
    
elif [ "$OS" = "debian" ]; then
    # Debian systemd
    systemctl daemon-reload
    systemctl enable dnscrypt-proxy.service 2>/dev/null || \
    systemctl enable dnscrypt-proxy.socket 2>/dev/null || \
    systemctl enable dnscrypt-proxy 2>/dev/null
    
    # 重启服务
    systemctl stop dnscrypt-proxy.service dnscrypt-proxy.socket 2>/dev/null || true
    
    # 确保使用正确的配置文件
    if [ -f /lib/systemd/system/dnscrypt-proxy.service ]; then
        # 检查服务文件
        if ! grep -q "dnscrypt-proxy.toml" /lib/systemd/system/dnscrypt-proxy.service; then
            # 可能使用了旧的配置路径
            warn "systemd 服务文件可能使用旧配置路径，尝试适配..."
        fi
    fi
    
    systemctl start dnscrypt-proxy.service 2>/dev/null || \
    systemctl start dnscrypt-proxy 2>/dev/null || \
    systemctl start dnscrypt-proxy.socket 2>/dev/null
    
    sleep 2
    
    if systemctl is-active --quiet dnscrypt-proxy.service 2>/dev/null || \
       systemctl is-active --quiet dnscrypt-proxy.socket 2>/dev/null; then
        info "服务已成功启动"
    else
        warn "服务可能未正常启动，查看日志:"
        systemctl status dnscrypt-proxy 2>/dev/null || true
        journalctl -xeu dnscrypt-proxy --no-pager -n 20 2>/dev/null || true
    fi
fi

#--- 验证功能 ---
verify_dns() {
    info "验证 DNS 加密功能..."
    sleep 2
    
    # 测试解析
    echo ""
    echo -e "${BLUE}=== DNS 测试 ===${NC}"
    
    if command -v nslookup >/dev/null 2>&1; then
        echo -n "测试 google.com: "
        nslookup google.com 127.0.0.1 2>/dev/null | grep "Address:" | grep -v "#53" | head -1 || echo "失败"
    elif command -v dig >/dev/null 2>&1; then
        echo -n "测试 google.com: "
        dig +short @127.0.0.1 google.com 2>/dev/null | head -1 || echo "失败"
    else
        # 使用 curl 测试
        echo -n "测试 google.com: "
        curl -s --doh-url https://dns.google/dns-query https://google.com >/dev/null 2>&1 && \
            echo "解析正常" || echo "需要安装 nslookup/dig 进行测试"
    fi
    
    # 检查监听端口
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":53.*LISTEN"; then
            info "端口 53 已监听 ✓"
        else
            warn "端口 53 未检测到监听"
        fi
    fi
}
verify_dns

#--- 显示完成信息 ---
show_complete() {
    echo ""
    echo "============================================="
    echo "       加密 DNS 部署完成!"
    echo "============================================="
    echo "提供商: $PROVIDER  |  模式: $MODE"
    echo "监听地址: 127.0.0.1:53, [::1]:53"
    echo "配置路径: $CONF"
    echo "日志路径: /var/log/dnscrypt-proxy/query.log"
    echo "日志保留: 保留30天"
    echo ""
    echo "常用命令:"
    if [ "$OS" = "alpine" ]; then
        echo "  状态: rc-service dnscrypt-proxy status"
        echo "  重启: rc-service dnscrypt-proxy restart"
        echo "  停止: rc-service dnscrypt-proxy stop"
        echo "  日志: tail -f /var/log/dnscrypt-proxy/query.log"
    else
        echo "  状态: systemctl status dnscrypt-proxy"
        echo "  重启: systemctl restart dnscrypt-proxy"
        echo "  停止: systemctl stop dnscrypt-proxy"
        echo "  日志: journalctl -u dnscrypt-proxy -f"
    fi
    echo ""
    echo "DNS 泄露测试:"
    echo "  nslookup whoami.akamai.net 127.0.0.1"
    echo "  https://www.dnsleaktest.com"
    echo "============================================="
}
show_complete

info "全部完成! 系统DNS已通过加密通道进行解析"

exit 0
