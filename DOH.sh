#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 (最终稳定版 v3.0)
# 功能: 自动检测 -> 安装 -> 配置 -> 启动
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
# 修复: IPv6/IPv4双栈冲突、端口占用、OpenRC服务
# 更新: 2026-05-11
#==================================================

set +e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_step()  { echo -e "\n${BOLD}${BLUE}>>> $1${NC}"; }

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
    log_err "请使用 root 权限运行此脚本"
    exit 1
fi

#==================================================
# 工具函数
#==================================================

# 下载函数
download_file() {
    local url="$1"
    local output="$2"
    
    if wget -q --timeout=30 --tries=1 -O "$output" "$url" 2>/dev/null; then
        return 0
    fi
    
    if curl -sL --max-time 30 -o "$output" "$url" 2>/dev/null; then
        return 0
    fi
    
    return 1
}

# 架构检测
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l|armv7)   echo "arm" ;;
        i386|i686)      echo "x86" ;;
        *)              echo "x86_64" ;;  # 默认
    esac
}

# 端口检测
port_available() {
    local port="$1"
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then
        return 1
    elif netstat -tuln 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

#==================================================
# 第1步: 系统检测
#==================================================
log_step "系统环境检测"

# 发行版
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    VER=$(cat /etc/alpine-release)
    PKG_MGR="apk"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    PKG_MGR="apt"
else
    log_err "无法识别的系统"
    exit 1
fi
log_info "系统: $OS $VER"

# Init系统
if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
    INIT="systemd"
elif [ -f /sbin/openrc ] || [ -f /usr/sbin/openrc ]; then
    INIT="openrc"
else
    INIT="none"
fi
log_info "Init: $INIT"

# 虚拟化
if grep -q "container=lxc" /proc/1/environ 2>/dev/null || grep -q "lxchost" /proc/1/cgroup 2>/dev/null; then
    VIRT="lxc"
elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    VIRT="docker"
else
    VIRT="kvm"
fi
log_info "虚拟化: $VIRT"

# IPv6支持检测
HAS_IPV6=false
if ip route get 2606:4700:4700::1111 >/dev/null 2>&1; then
    HAS_IPV6=true
    log_info "IPv6: 支持"
else
    log_info "IPv6: 不支持 (纯IPv4环境)"
fi

# IPv6双栈绑定模式检测
BINDV6ONLY=$(sysctl net.ipv6.bindv6only 2>/dev/null | awk '{print $3}')
log_info "net.ipv6.bindv6only = ${BINDV6ONLY:-未知}"

#==================================================
# 第2步: 安装 SmartDNS
#==================================================
log_step "安装 SmartDNS"

SMARTDNS_BIN=""

# 方法1: 包管理器
case "$PKG_MGR" in
    apk)
        apk update --quiet 2>/dev/null
        if apk search smartdns 2>/dev/null | grep -q "^smartdns"; then
            log_info "从 apk 安装..."
            apk add --no-cache smartdns && SMARTDNS_BIN=$(which smartdns 2>/dev/null)
        fi
        ;;
    apt)
        apt-get update -qq 2>/dev/null
        if apt-cache show smartdns >/dev/null 2>&1; then
            log_info "从 apt 安装..."
            apt-get install -y -qq smartdns && SMARTDNS_BIN=$(which smartdns 2>/dev/null)
        fi
        ;;
esac

# 方法2: GitHub下载
if [ -z "$SMARTDNS_BIN" ] || [ ! -f "$SMARTDNS_BIN" ]; then
    log_info "从 GitHub 下载..."
    ARCH=$(get_arch)
    URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
    
    if download_file "$URL" "/tmp/smartdns"; then
        if [ -s /tmp/smartdns ]; then
            chmod +x /tmp/smartdns
            mv /tmp/smartdns /usr/bin/smartdns
            SMARTDNS_BIN="/usr/bin/smartdns"
            log_ok "下载成功"
        fi
    else
        log_err "下载失败，请手动访问: https://github.com/pymumu/smartdns/releases/latest"
        log_err "下载 smartdns-${ARCH} 并上传到 /usr/bin/smartdns"
        exit 1
    fi
fi

log_ok "SmartDNS: $SMARTDNS_BIN"
$SMARTDNS_BIN -v 2>&1 | head -1

#==================================================
# 第3步: 生成配置（修复IPv6/IPv4冲突）
#==================================================
log_step "生成配置文件"

mkdir -p /etc/smartdns

# 选择端口（检测可用性）
PORT=53
if ! port_available 53; then
    for p in 5353 5354 5355 8053; do
        if port_available $p; then
            PORT=$p
            break
        fi
    done
    log_warn "端口53被占用，使用端口: $PORT"
else
    log_info "端口53可用"
fi

# 备份旧配置
if [ -f /etc/smartdns/smartdns.conf ]; then
    cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null
fi

# 生成配置（关键修复：根据IPv6支持和bindv6only决定绑定方式）
cat > /etc/smartdns/smartdns.conf << EOF
# SmartDNS 配置 (自动生成)
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
# 环境: $OS $VER | $INIT | $VIRT

server-name smartdns
EOF

# 智能绑定配置 - 解决IPv6/IPv4双栈冲突
if [ "$HAS_IPV6" = true ] && [ "$BINDV6ONLY" = "0" ]; then
    # 有IPv6但bindv6only=0，只用IPv6绑定（同时覆盖IPv4）
    log_info "双栈模式: 仅绑定IPv6（覆盖IPv4）"
    cat >> /etc/smartdns/smartdns.conf << EOF
bind [::]:${PORT}
EOF
elif [ "$HAS_IPV6" = true ] && [ "$BINDV6ONLY" = "1" ]; then
    # 有IPv6且bindv6only=1，需要分别绑定
    log_info "双栈模式: 分别绑定IPv4和IPv6"
    cat >> /etc/smartdns/smartdns.conf << EOF
bind [::]:${PORT}
bind 0.0.0.0:${PORT}
EOF
else
    # 纯IPv4环境，只绑定IPv4（避免冲突）
    log_info "纯IPv4模式: 仅绑定IPv4"
    cat >> /etc/smartdns/smartdns.conf << EOF
bind 0.0.0.0:${PORT}
EOF
fi

# 其余配置
cat >> /etc/smartdns/smartdns.conf << 'EOF'

cache-size 4096
prefetch-domain yes
serve-expired yes

log-level info
log-file /var/log/smartdns.log
log-size 2m
log-num 2

speed-check-mode ping,tcp:443
response-mode fastest-ip

rr-ttl 300
rr-ttl-min 60

EOF

# IPv6相关配置
if [ "$HAS_IPV6" = false ]; then
    echo "force-AAAA-SOA yes" >> /etc/smartdns/smartdns.conf
fi

cat >> /etc/smartdns/smartdns.conf << 'EOF'
edns-client-subnet

# 上游 DNS 服务器
server 1.1.1.1
server 8.8.8.8
server 9.9.9.9
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
EOF

log_ok "配置已生成: /etc/smartdns/smartdns.conf"
log_info "监听端口: $PORT"

# 显示配置
echo ""
echo -e "${BOLD}配置摘要:${NC}"
grep -E "^bind|^server |^server-https" /etc/smartdns/smartdns.conf

#==================================================
# 第4步: 配置系统 DNS
#==================================================
log_step "配置系统 DNS"

# 备份
if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null
fi

# 处理 systemd-resolved
if [ "$INIT" = "systemd" ]; then
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    rm -f /etc/resolv.conf
fi

# 解锁并写入
chattr -i /etc/resolv.conf 2>/dev/null

cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

chattr +i /etc/resolv.conf 2>/dev/null || log_warn "无法锁定 resolv.conf (容器环境正常)"

# dhcpcd 配置
if [ -f /etc/dhcpcd.conf ]; then
    if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
        echo "" >> /etc/dhcpcd.conf
        echo "# SmartDNS: 禁止修改 DNS" >> /etc/dhcpcd.conf
        echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    fi
    # 重启 dhcpcd 确保生效
    rc-service dhcpcd restart 2>/dev/null
fi

log_ok "系统 DNS -> 127.0.0.1"

#==================================================
# 第5步: 启动服务
#==================================================
log_step "启动 SmartDNS"

# 停止旧进程
rc-service smartdns stop 2>/dev/null
pkill smartdns 2>/dev/null
sleep 1

# 清空旧日志
echo "" > /var/log/smartdns.log 2>/dev/null

STARTED=false

# OpenRC 启动
if [ "$INIT" = "openrc" ]; then
    # 确保 OpenRC 服务脚本存在
    if [ ! -f /etc/init.d/smartdns ]; then
        cat > /etc/init.d/smartdns << EOF
#!/sbin/openrc-run
name="SmartDNS"
description="SmartDNS Server"
command="${SMARTDNS_BIN}"
command_args="-c /etc/smartdns/smartdns.conf"
command_background=true
pidfile="/run/smartdns.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/smartdns
    fi
    
    rc-update add smartdns default 2>/dev/null
    rc-service smartdns start 2>/dev/null
    sleep 2
    
    if pgrep smartdns >/dev/null 2>&1; then
        log_ok "SmartDNS 已启动 (OpenRC)"
        STARTED=true
    fi
fi

# systemd 启动
if [ "$INIT" = "systemd" ]; then
    cat > /etc/systemd/system/smartdns.service << EOF
[Unit]
Description=SmartDNS Server
After=network.target

[Service]
Type=forking
ExecStart=${SMARTDNS_BIN} -c /etc/smartdns/smartdns.conf
PIDFile=/run/smartdns.pid
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable smartdns 2>/dev/null
    systemctl restart smartdns
    sleep 2
    
    if pgrep smartdns >/dev/null 2>&1; then
        log_ok "SmartDNS 已启动 (systemd)"
        STARTED=true
    fi
fi

# 直接启动（备用）
if [ "$STARTED" = false ]; then
    log_warn "服务管理启动失败，尝试直接启动..."
    $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf &
    sleep 3
    
    if pgrep smartdns >/dev/null 2>&1; then
        log_ok "SmartDNS 已启动 (直接模式)"
        STARTED=true
    else
        log_err "SmartDNS 启动失败！"
        echo ""
        echo "=== 错误日志 ==="
        tail -20 /var/log/smartdns.log 2>/dev/null
        exit 1
    fi
fi

#==================================================
# 第6步: 验证
#==================================================
log_step "验证 DNS 解析"

sleep 2
ALL_OK=true

for domain in google.com github.com cloudflare.com; do
    RESULT=$(nslookup $domain 127.0.0.1 2>&1)
    if echo "$RESULT" | grep -q "Address"; then
        IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $2}')
        log_ok "$domain -> $IP"
    else
        log_err "$domain 解析失败"
        ALL_OK=false
    fi
done

echo ""

if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║     ✓ SmartDNS 部署成功！             ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
else
    echo -e "${YELLOW}${BOLD}⚠ SmartDNS 运行中但部分解析异常${NC}"
fi

echo ""
echo -e "${BOLD}服务信息:${NC}"
echo -e "  程序: ${CYAN}$SMARTDNS_BIN${NC}"
echo -e "  配置: ${CYAN}/etc/smartdns/smartdns.conf${NC}"
echo -e "  日志: ${CYAN}/var/log/smartdns.log${NC}"
echo -e "  端口: ${CYAN}127.0.0.1:${PORT}${NC}"
echo ""
echo -e "${BOLD}常用命令:${NC}"
echo -e "  测试: ${GREEN}nslookup google.com 127.0.0.1${NC}"
echo -e "  日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
echo -e "  状态: ${GREEN}rc-service smartdns status${NC}"
echo -e "  重启: ${GREEN}rc-service smartdns restart${NC}"
echo -e "  卸载: ${GREEN}$0 --uninstall${NC}"
echo ""

# 卸载功能
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    echo -e "${YELLOW}卸载 SmartDNS...${NC}"
    rc-service smartdns stop 2>/dev/null
    systemctl stop smartdns 2>/dev/null
    pkill smartdns 2>/dev/null
    
    chattr -i /etc/resolv.conf 2>/dev/null
    [ -f /etc/resolv.conf.bak.* ] && cp $(ls -t /etc/resolv.conf.bak.* | head -1) /etc/resolv.conf 2>/dev/null
    
    rm -f /usr/bin/smartdns /etc/init.d/smartdns /etc/systemd/system/smartdns.service
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log*
    
    echo -e "${GREEN}卸载完成${NC}"
    exit 0
fi
