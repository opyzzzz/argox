#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 v4.2 (最终稳定版)
# 策略: GitHub最新版优先 -> 包管理器备用
# 修复: 端口检测误判、缺失依赖、resolv.conf端口
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
# 更新: 2026-05-11
#==================================================

set +e

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

[ "$(id -u)" -ne 0 ] && { log_err "需要 root 权限"; exit 1; }

#==================================================
# 卸载
#==================================================
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    echo ""; echo -e "${YELLOW}卸载 SmartDNS...${NC}"
    
    if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
        INIT="systemd"
    elif [ -f /sbin/openrc ]; then
        INIT="openrc"
    else
        INIT="none"
    fi
    
    case "$INIT" in
        systemd)
            systemctl stop smartdns 2>/dev/null
            systemctl disable smartdns 2>/dev/null
            rm -f /etc/systemd/system/smartdns.service /lib/systemd/system/smartdns.service
            systemctl daemon-reload 2>/dev/null
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null
            rc-update del smartdns 2>/dev/null
            rm -f /etc/init.d/smartdns
            ;;
    esac
    
    pkill smartdns 2>/dev/null
    sleep 1
    
    chattr -i /etc/resolv.conf 2>/dev/null
    BAK=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
    if [ -n "$BAK" ]; then
        cp "$BAK" /etc/resolv.conf
    else
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    fi
    
    sed -i '/nohook resolv.conf/d; /SmartDNS/d' /etc/dhcpcd.conf 2>/dev/null
    rm -f /etc/local.d/smartdns-fix.start
    rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log*
    
    apt-get remove -y smartdns 2>/dev/null
    apk del smartdns 2>/dev/null
    
    log_ok "卸载完成"
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

# 确保端口检测工具可用
ensure_network_tools() {
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        log_info "安装网络检测工具..."
        case "$PKG_MGR" in
            apk) apk add --no-cache iproute2 2>/dev/null ;;
            apt) apt-get install -y -qq iproute2 2>/dev/null ;;
        esac
    fi
}

# 端口检测
port_in_use() {
    ss -tuln 2>/dev/null | grep -q ":${1} " && return 0
    netstat -tuln 2>/dev/null | grep -q ":${1} " && return 0
    return 1
}

# 版本号提取
get_version_number() {
    local ver_output
    ver_output=$("$1" -v 2>&1)
    if echo "$ver_output" | grep -qi "Release\([0-9]\+\)"; then
        echo "$ver_output" | grep -oi "Release\([0-9]\+\)" | grep -o '[0-9]*' | head -1
    else
        echo "0"
    fi
}

#==================================================
# 第1步: 系统检测
#==================================================
log_step "系统环境检测"

if [ -f /etc/alpine-release ]; then
    OS="alpine"; VER=$(cat /etc/alpine-release); PKG_MGR="apk"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID; VER=$VERSION_ID; PKG_MGR="apt"
else
    log_err "无法识别的系统"; exit 1
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

if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    VIRT="lxc"
elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    VIRT="docker"
else
    VIRT="kvm"
fi
log_info "虚拟化: $VIRT"

HAS_IPV6=false
ip route get 2606:4700:4700::1111 >/dev/null 2>&1 && HAS_IPV6=true
BINDV6ONLY=$(sysctl net.ipv6.bindv6only 2>/dev/null | awk '{print $3}')
log_info "IPv6: $( $HAS_IPV6 && echo '支持' || echo '不支持' )"

# 确保检测工具可用
ensure_network_tools

#==================================================
# 第2步: 处理端口冲突 (53端口优先)
#==================================================
log_step "处理 DNS 端口"

# 先尝试停用 systemd-resolved 释放 53 端口
if [ "$INIT" = "systemd" ]; then
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        log_info "停用 systemd-resolved 以释放 53 端口..."
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        rm -f /etc/resolv.conf
        sleep 1
    fi
fi

# 检测端口
PORT=53
if port_in_use 53; then
    log_warn "端口 53 仍被占用，尝试备用端口..."
    
    # 显示谁占用了
    ss -tulnp 2>/dev/null | grep ":53 " || netstat -tulnp 2>/dev/null | grep ":53 "
    
    for p in 5353 5354 5355; do
        if ! port_in_use $p; then
            PORT=$p
            log_warn "使用备用端口: $PORT"
            log_warn "注意: resolv.conf 不支持指定端口，需手动配合 iptables 重定向"
            log_warn "或使用: nslookup -port=$PORT domain 127.0.0.1"
            break
        fi
    done
    
    if [ "$PORT" = "53" ]; then
        log_err "所有备用端口都被占用，强制使用 53"
        PORT=53
    fi
else
    log_ok "端口 53 可用"
fi

#==================================================
# 第3步: 安装 SmartDNS
#==================================================
log_step "安装 SmartDNS"

SMARTDNS_BIN=""
SMARTDNS_SOURCE=""
SMARTDNS_VER_NUM=0

# GitHub 最新版优先
ARCH=$(get_arch)
GITHUB_URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"

log_info "尝试 GitHub 最新版..."
if download_file "$GITHUB_URL" "/tmp/smartdns"; then
    if [ -s /tmp/smartdns ]; then
        chmod +x /tmp/smartdns
        mv /tmp/smartdns /usr/bin/smartdns
        SMARTDNS_BIN="/usr/bin/smartdns"
        SMARTDNS_SOURCE="GitHub"
        log_ok "GitHub 最新版安装成功"
    fi
fi

# 包管理器备用
if [ -z "$SMARTDNS_BIN" ]; then
    log_warn "GitHub 下载失败，尝试包管理器..."
    case "$PKG_MGR" in
        apk)
            apk update --quiet 2>/dev/null
            apk search smartdns 2>/dev/null | grep -q "^smartdns" && \
                apk add --no-cache smartdns 2>/dev/null && \
                SMARTDNS_BIN=$(which smartdns 2>/dev/null) && \
                SMARTDNS_SOURCE="apk"
            ;;
        apt)
            apt-get update -qq 2>/dev/null
            apt-cache show smartdns >/dev/null 2>&1 && \
                apt-get install -y -qq smartdns 2>/dev/null && \
                SMARTDNS_BIN=$(which smartdns 2>/dev/null) && \
                SMARTDNS_SOURCE="apt"
            ;;
    esac
    [ -n "$SMARTDNS_BIN" ] && log_ok "包管理器安装成功" || {
        log_err "所有安装方式均失败"; exit 1
    }
fi

SMARTDNS_VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
log_info "版本: $SMARTDNS_VER"
log_info "来源: $SMARTDNS_SOURCE"
log_info "主版本: $SMARTDNS_VER_NUM"

[ "$SMARTDNS_VER_NUM" -ge 42 ] 2>/dev/null && IS_NEW=true || IS_NEW=false
$IS_NEW && log_ok "新版本 (>=42)，完整功能" || log_warn "旧版本，裁剪配置"

#==================================================
# 第4步: 生成配置
#==================================================
log_step "生成配置文件"

mkdir -p /etc/smartdns
[ -f /etc/smartdns/smartdns.conf ] && \
    cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null

cat > /etc/smartdns/smartdns.conf << EOF
# SmartDNS 配置 (v4.2)
# 版本: $SMARTDNS_VER | 来源: $SMARTDNS_SOURCE
# 时间: $(date '+%Y-%m-%d %H:%M:%S')

server-name smartdns
EOF

# 绑定
if [ "$HAS_IPV6" = true ] && [ "$BINDV6ONLY" = "1" ]; then
    echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
    echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
elif [ "$HAS_IPV6" = true ]; then
    echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
else
    echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
fi

# 基础配置
cat >> /etc/smartdns/smartdns.conf << EOF
cache-size 4096
prefetch-domain yes
log-level info
log-file /var/log/smartdns.log
response-mode fastest-ip
rr-ttl 300
rr-ttl-min 60
EOF

# 新版本扩展配置
if [ "$IS_NEW" = true ]; then
    cat >> /etc/smartdns/smartdns.conf << EOF
serve-expired yes
log-size 2m
log-num 2
speed-check-mode ping,tcp:443
force-AAAA-SOA yes
edns-client-subnet
EOF
fi

# 上游 DNS
cat >> /etc/smartdns/smartdns.conf << EOF

server 1.1.1.1
server 8.8.8.8
server 9.9.9.9
EOF

# DoH (仅新版本)
$IS_NEW && cat >> /etc/smartdns/smartdns.conf << EOF
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
EOF

log_ok "配置已生成 (端口: $PORT)"

#==================================================
# 第5步: 配置系统 DNS
#==================================================
log_step "配置系统 DNS"

[ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && \
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null

chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
chattr +i /etc/resolv.conf 2>/dev/null || log_warn "无法锁定 (容器正常)"

# dhcpcd
if [ -f /etc/dhcpcd.conf ]; then
    grep -q "nohook resolv.conf" /etc/dhcpcd.conf || {
        echo "" >> /etc/dhcpcd.conf
        echo "# SmartDNS" >> /etc/dhcpcd.conf
        echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    }
    rc-service dhcpcd restart 2>/dev/null
fi

log_ok "系统 DNS -> 127.0.0.1"

# 端口非53时提示
if [ "$PORT" != "53" ]; then
    log_warn "SmartDNS 使用非标准端口 $PORT"
    log_warn "nslookup 默认使用 53，需指定: nslookup -port=$PORT domain 127.0.0.1"
    log_warn "建议添加 iptables 规则: iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-port $PORT"
fi

#==================================================
# 第6步: 开机自启 (Alpine)
#==================================================
if [ "$INIT" = "openrc" ]; then
    mkdir -p /etc/local.d
    cat > /etc/local.d/smartdns-fix.start << 'EOF'
#!/bin/sh
sleep 3
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf << 'INNEREOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
INNEREOF
chattr +i /etc/resolv.conf 2>/dev/null
pgrep smartdns >/dev/null 2>&1 || smartdns -c /etc/smartdns/smartdns.conf &
EOF
    chmod +x /etc/local.d/smartdns-fix.start
    rc-update add local default 2>/dev/null
fi

#==================================================
# 第7步: 启动服务
#==================================================
log_step "启动 SmartDNS"

pkill smartdns 2>/dev/null
sleep 1
echo "" > /var/log/smartdns.log 2>/dev/null

STARTED=false

case "$INIT" in
    openrc)
        [ ! -f /etc/init.d/smartdns ] && {
            cat > /etc/init.d/smartdns << EOF
#!/sbin/openrc-run
name="SmartDNS"
command="${SMARTDNS_BIN}"
command_args="-c /etc/smartdns/smartdns.conf"
command_background=true
pidfile="/run/smartdns.pid"
depend() { need net; }
EOF
            chmod +x /etc/init.d/smartdns
        }
        rc-update add smartdns default 2>/dev/null
        rc-service smartdns start 2>/dev/null
        sleep 2
        pgrep smartdns >/dev/null 2>&1 && STARTED=true && log_ok "已启动 (OpenRC)"
        ;;
    systemd)
        [ -f /lib/systemd/system/smartdns.service ] && \
            SYSTEMD_FILE="/lib/systemd/system/smartdns.service" || \
            SYSTEMD_FILE="/etc/systemd/system/smartdns.service"
        
        cat > "$SYSTEMD_FILE" << EOF
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
        pgrep smartdns >/dev/null 2>&1 && STARTED=true && log_ok "已启动 (systemd)"
        ;;
esac

if [ "$STARTED" = false ]; then
    "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf &
    sleep 3
    pgrep smartdns >/dev/null 2>&1 && STARTED=true && log_ok "已启动 (直接模式)" || {
        log_err "启动失败！"
        tail -20 /var/log/smartdns.log 2>/dev/null
        exit 1
    }
fi

#==================================================
# 第8步: 验证
#==================================================
log_step "验证 DNS 解析"

# 确保有测试工具
if ! command -v nslookup >/dev/null 2>&1; then
    log_info "安装 DNS 测试工具..."
    case "$PKG_MGR" in
        apk) apk add --no-cache bind-tools 2>/dev/null ;;
        apt) apt-get install -y -qq dnsutils 2>/dev/null ;;
    esac
fi

sleep 2
ALL_OK=true

for domain in google.com github.com cloudflare.com; do
    if [ "$PORT" = "53" ]; then
        RESULT=$(nslookup -timeout=5 $domain 127.0.0.1 2>&1)
    else
        RESULT=$(nslookup -timeout=5 -port=$PORT $domain 127.0.0.1 2>&1)
    fi
    
    if echo "$RESULT" | grep -q "Address"; then
        IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
        log_ok "$domain → $IP"
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
    echo -e "${YELLOW}${BOLD}⚠ 解析异常，诊断:${NC}"
    echo "  systemctl status smartdns"
    echo "  tail -50 /var/log/smartdns.log"
fi

echo ""
echo -e "${BOLD}服务信息:${NC}"
echo -e "  版本: ${CYAN}$SMARTDNS_VER${NC}"
echo -e "  来源: ${CYAN}$SMARTDNS_SOURCE${NC}"
echo -e "  端口: ${CYAN}127.0.0.1:${PORT}${NC}"
echo -e "  配置: ${CYAN}/etc/smartdns/smartdns.conf${NC}"
echo -e "  日志: ${CYAN}/var/log/smartdns.log${NC}"
echo ""
echo -e "${BOLD}常用命令:${NC}"
if [ "$PORT" = "53" ]; then
    echo -e "  测试: ${GREEN}nslookup google.com 127.0.0.1${NC}"
else
    echo -e "  测试: ${GREEN}nslookup -port=$PORT google.com 127.0.0.1${NC}"
fi
echo -e "  日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
echo -e "  卸载: ${GREEN}$0 --uninstall${NC}"
echo ""
