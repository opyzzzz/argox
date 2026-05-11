#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 (最终稳定版 v3.1)
# GitHub: https://github.com/你的用户名/仓库名
# 用法: wget -O- https://raw.githubusercontent.com/.../smartdns-install.sh | sh
# 功能: 自动检测 -> 安装 -> 配置 -> 启动 -> 开机自启
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
# 修复: IPv6/IPv4双栈冲突、端口占用、重启后resolv.conf恢复
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
# 卸载功能
#==================================================
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    echo ""
    echo -e "${YELLOW}============================================${NC}"
    echo -e "${YELLOW}  卸载 SmartDNS${NC}"
    echo -e "${YELLOW}============================================${NC}"
    echo ""
    
    # 检测 Init 系统
    if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
        INIT="systemd"
    elif [ -f /sbin/openrc ] || [ -f /usr/sbin/openrc ]; then
        INIT="openrc"
    else
        INIT="none"
    fi
    
    # 停止服务
    case "$INIT" in
        systemd)
            systemctl stop smartdns 2>/dev/null
            systemctl disable smartdns 2>/dev/null
            rm -f /etc/systemd/system/smartdns.service
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null
            rc-update del smartdns 2>/dev/null
            rm -f /etc/init.d/smartdns
            ;;
    esac
    
    pkill smartdns 2>/dev/null
    sleep 1
    
    # 恢复 resolv.conf
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
        BAK=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
        if [ -n "$BAK" ]; then
            cp "$BAK" /etc/resolv.conf
            log_info "已恢复 resolv.conf"
        else
            cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
            log_warn "未找到备份，已写入默认 DNS"
        fi
    fi
    
    # 清理文件
    [ -f /etc/dhcpcd.conf ] && sed -i '/nohook resolv.conf/d; /SmartDNS/d' /etc/dhcpcd.conf
    rm -f /etc/local.d/smartdns-fix.start
    rm -f /usr/bin/smartdns /usr/sbin/smartdns
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log*
    
    log_ok "SmartDNS 卸载完成"
    exit 0
fi

#==================================================
# 工具函数
#==================================================

download_file() {
    local url="$1"
    local output="$2"
    wget -q --timeout=30 --tries=1 -O "$output" "$url" 2>/dev/null && return 0
    curl -sL --max-time 30 -o "$output" "$url" 2>/dev/null && return 0
    return 1
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l|armv7)   echo "arm" ;;
        i386|i686)      echo "x86" ;;
        *)              echo "x86_64" ;;
    esac
}

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
    log_err "无法识别的系统，仅支持 Alpine/Debian/Ubuntu"
    exit 1
fi
log_info "系统: $OS $VER"

if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
    INIT="systemd"
elif [ -f /sbin/openrc ] || [ -f /usr/sbin/openrc ]; then
    INIT="openrc"
else
    INIT="none"
fi
log_info "Init: $INIT"

if grep -q "container=lxc" /proc/1/environ 2>/dev/null || grep -q "lxchost" /proc/1/cgroup 2>/dev/null; then
    VIRT="lxc"
elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    VIRT="docker"
else
    VIRT="kvm"
fi
log_info "虚拟化: $VIRT"

HAS_IPV6=false
ip route get 2606:4700:4700::1111 >/dev/null 2>&1 && HAS_IPV6=true
log_info "IPv6: $( $HAS_IPV6 && echo '支持' || echo '不支持(纯IPv4)' )"

BINDV6ONLY=$(sysctl net.ipv6.bindv6only 2>/dev/null | awk '{print $3}')
log_info "net.ipv6.bindv6only = ${BINDV6ONLY:-未知}"

#==================================================
# 第2步: 安装 SmartDNS
#==================================================
log_step "安装 SmartDNS"

SMARTDNS_BIN=""

case "$PKG_MGR" in
    apk)
        apk update --quiet 2>/dev/null
        if apk search smartdns 2>/dev/null | grep -q "^smartdns"; then
            log_info "从 apk 安装..."
            apk add --no-cache smartdns 2>/dev/null && SMARTDNS_BIN=$(which smartdns 2>/dev/null)
        fi
        ;;
    apt)
        apt-get update -qq 2>/dev/null
        if apt-cache show smartdns >/dev/null 2>&1; then
            log_info "从 apt 安装..."
            apt-get install -y -qq smartdns 2>/dev/null && SMARTDNS_BIN=$(which smartdns 2>/dev/null)
        fi
        ;;
esac

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
        log_err "下载失败: $URL"
        log_err "请手动下载并上传到 /usr/bin/smartdns"
        exit 1
    fi
fi

log_ok "SmartDNS: $SMARTDNS_BIN"
$SMARTDNS_BIN -v 2>&1 | head -1

#==================================================
# 第3步: 生成配置
#==================================================
log_step "生成配置文件"

mkdir -p /etc/smartdns

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

[ -f /etc/smartdns/smartdns.conf ] && \
    cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null

# 生成配置头
cat > /etc/smartdns/smartdns.conf << EOF
# SmartDNS 配置 (自动生成)
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
# 环境: $OS $VER | $INIT | $VIRT

server-name smartdns
EOF

# 智能绑定: 解决IPv6/IPv4双栈冲突
if [ "$HAS_IPV6" = true ] && [ "$BINDV6ONLY" = "0" ]; then
    log_info "双栈模式: 仅绑定IPv6(覆盖IPv4)"
    echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
elif [ "$HAS_IPV6" = true ] && [ "$BINDV6ONLY" = "1" ]; then
    log_info "双栈模式: 分别绑定IPv4和IPv6"
    cat >> /etc/smartdns/smartdns.conf << EOF
bind [::]:${PORT}
bind 0.0.0.0:${PORT}
EOF
else
    log_info "纯IPv4模式: 仅绑定IPv4"
    echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
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

$HAS_IPV6 || echo "force-AAAA-SOA yes" >> /etc/smartdns/smartdns.conf

cat >> /etc/smartdns/smartdns.conf << 'EOF'
edns-client-subnet

# 上游 DNS
server 1.1.1.1
server 8.8.8.8
server 9.9.9.9
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
EOF

log_ok "配置已生成: /etc/smartdns/smartdns.conf"
log_info "监听端口: $PORT"

#==================================================
# 第4步: 配置系统 DNS 和 dhcpcd
#==================================================
log_step "配置系统 DNS"

# 备份原文件
if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null
fi

# 处理 systemd-resolved
if [ "$INIT" = "systemd" ]; then
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    rm -f /etc/resolv.conf
fi

# 写入并锁定 resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
chattr +i /etc/resolv.conf 2>/dev/null || log_warn "无法锁定 resolv.conf (容器环境正常)"

# 配置 dhcpcd
if [ -f /etc/dhcpcd.conf ]; then
    if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
        echo "" >> /etc/dhcpcd.conf
        echo "# SmartDNS: 禁止修改 DNS" >> /etc/dhcpcd.conf
        echo "nohook resolv.conf" >> /etc/dhcpcd.conf
        log_info "dhcpcd 已配置"
    else
        log_info "dhcpcd 已正确配置"
    fi
    rc-service dhcpcd restart 2>/dev/null
fi

#==================================================
# 第5步: 创建开机自启脚本 (防止重启后 resolv.conf 被重置)
#==================================================
log_step "创建开机自启脚本"

mkdir -p /etc/local.d

cat > /etc/local.d/smartdns-fix.start << 'EOF'
#!/bin/sh
# SmartDNS 开机修复

sleep 3

# 修复 resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf << 'INNEREOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
INNEREOF
chattr +i /etc/resolv.conf 2>/dev/null

# 确保 SmartDNS 运行
if ! pgrep smartdns >/dev/null 2>&1; then
    smartdns -c /etc/smartdns/smartdns.conf &
fi
EOF

chmod +x /etc/local.d/smartdns-fix.start

if [ "$INIT" = "openrc" ]; then
    rc-update add local default 2>/dev/null
    log_ok "开机自启脚本已创建"
else
    log_info "开机自启脚本已创建: /etc/local.d/smartdns-fix.start"
fi

#==================================================
# 第6步: 启动服务
#==================================================
log_step "启动 SmartDNS"

# 停止旧进程
rc-service smartdns stop 2>/dev/null
pkill smartdns 2>/dev/null
sleep 1

echo "" > /var/log/smartdns.log 2>/dev/null

STARTED=false

if [ "$INIT" = "openrc" ]; then
    # 创建 OpenRC 服务脚本
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
    
    pgrep smartdns >/dev/null 2>&1 && STARTED=true && log_ok "SmartDNS 已启动 (OpenRC)"
fi

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
    
    pgrep smartdns >/dev/null 2>&1 && STARTED=true && log_ok "SmartDNS 已启动 (systemd)"
fi

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
# 第7步: 验证
#==================================================
log_step "验证 DNS 解析"

sleep 2
ALL_OK=true

for domain in google.com github.com cloudflare.com; do
    RESULT=$(nslookup $domain 127.0.0.1 2>&1)
    if echo "$RESULT" | grep -q "Address"; then
        IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
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
    echo -e "${YELLOW}${BOLD}⚠ 部分域名解析异常，请检查上游DNS连通性${NC}"
fi

echo ""
echo -e "${BOLD}服务信息:${NC}"
echo -e "  程序: ${CYAN}$SMARTDNS_BIN${NC}"
echo -e "  配置: ${CYAN}/etc/smartdns/smartdns.conf${NC}"
echo -e "  日志: ${CYAN}/var/log/smartdns.log${NC}"
echo -e "  端口: ${CYAN}127.0.0.1:${PORT}${NC}"
echo -e "  开机自启: ${CYAN}/etc/local.d/smartdns-fix.start${NC}"
echo ""
echo -e "${BOLD}常用命令:${NC}"
echo -e "  测试: ${GREEN}nslookup google.com 127.0.0.1${NC}"
echo -e "  日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
echo -e "  状态: ${GREEN}rc-service smartdns status${NC}"
echo -e "  重启: ${GREEN}rc-service smartdns restart${NC}"
echo -e "  卸载: ${GREEN}wget -O- ... | sh -s -- --uninstall${NC}"
echo ""
