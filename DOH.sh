#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 v4.1
# 策略: GitHub最新版优先 -> 包管理器备用
# 修复: 特性检测bug、兼容旧版配置生成
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
    
    [ -f /run/systemd/system ] && INIT="systemd" || INIT="openrc"
    
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

port_available() {
    ss -tuln 2>/dev/null | grep -q ":${1} " && return 1
    netstat -tuln 2>/dev/null | grep -q ":${1} " && return 1
    return 0
}

# 检测 SmartDNS 版本号
get_version_number() {
    local bin="$1"
    local ver_output
    local major_ver=0
    
    # 尝试多种版本格式
    # Release47.1 -> 47
    # 1.2025.11.09-1443 -> 提取主版本
    # 40+dfsg-1 -> 40
    ver_output=$("$bin" -v 2>&1)
    
    # 先尝试提取 ReleaseXX
    if echo "$ver_output" | grep -qi "Release\([0-9]\+\)"; then
        major_ver=$(echo "$ver_output" | grep -oi "Release\([0-9]\+\)" | grep -o '[0-9]*' | head -1)
    # 再尝试提取 smartdns X.X.X 格式
    elif echo "$ver_output" | grep -q "smartdns [0-9]"; then
        major_ver=$(echo "$ver_output" | grep -oP 'smartdns \K[0-9]+' | head -1)
    fi
    
    [ -z "$major_ver" ] && major_ver=0
    echo "$major_ver"
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
log_info "bindv6only: ${BINDV6ONLY:-未知}"

#==================================================
# 第2步: 安装 SmartDNS (GitHub 优先)
#==================================================
log_step "安装 SmartDNS"

SMARTDNS_BIN=""
SMARTDNS_SOURCE=""
SMARTDNS_VER_NUM=0

# 策略1: GitHub 最新版
ARCH=$(get_arch)
GITHUB_URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"

log_info "尝试 GitHub 最新版..."
if download_file "$GITHUB_URL" "/tmp/smartdns" 2>/dev/null; then
    if [ -s /tmp/smartdns ]; then
        chmod +x /tmp/smartdns
        mv /tmp/smartdns /usr/bin/smartdns
        SMARTDNS_BIN="/usr/bin/smartdns"
        SMARTDNS_SOURCE="GitHub"
        log_ok "GitHub 最新版安装成功"
    fi
fi

# 策略2: 包管理器
if [ -z "$SMARTDNS_BIN" ]; then
    log_warn "GitHub 下载失败，尝试包管理器..."
    
    case "$PKG_MGR" in
        apk)
            apk update --quiet 2>/dev/null
            if apk search smartdns 2>/dev/null | grep -q "^smartdns"; then
                apk add --no-cache smartdns 2>/dev/null && {
                    SMARTDNS_BIN=$(which smartdns 2>/dev/null)
                    SMARTDNS_SOURCE="apk"
                }
            fi
            ;;
        apt)
            apt-get update -qq 2>/dev/null
            if apt-cache show smartdns >/dev/null 2>&1; then
                apt-get install -y -qq smartdns 2>/dev/null && {
                    SMARTDNS_BIN=$(which smartdns 2>/dev/null)
                    SMARTDNS_SOURCE="apt"
                }
            fi
            ;;
    esac
    
    if [ -n "$SMARTDNS_BIN" ]; then
        log_ok "包管理器安装成功"
    else
        log_err "所有安装方式均失败"
        log_err "请手动下载: $GITHUB_URL"
        exit 1
    fi
fi

# 获取版本信息
SMARTDNS_VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
log_info "版本: $SMARTDNS_VER"
log_info "来源: $SMARTDNS_SOURCE"
log_info "主版本号: $SMARTDNS_VER_NUM"

# 版本 >= 42 支持所有新特性
if [ "$SMARTDNS_VER_NUM" -ge 42 ] 2>/dev/null; then
    IS_NEW_VERSION=true
    log_ok "检测到新版本 (>=42)，启用完整功能"
else
    IS_NEW_VERSION=false
    log_warn "检测到旧版本 (<42)，将裁剪配置"
fi

#==================================================
# 第3步: 动态生成兼容配置
#==================================================
log_step "生成兼容配置"

mkdir -p /etc/smartdns
[ -f /etc/smartdns/smartdns.conf ] && \
    cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null

# 端口选择
PORT=53
if ! port_available 53; then
    for p in 5353 5354 5355 8053; do
        if port_available $p; then PORT=$p; break; fi
    done
    log_warn "端口53被占用，使用: $PORT"
else
    log_info "端口53可用"
fi

# 生成基础配置
cat > /etc/smartdns/smartdns.conf << EOF
# SmartDNS 配置 (v4.1 自动生成)
# 版本: $SMARTDNS_VER
# 来源: $SMARTDNS_SOURCE
# 时间: $(date '+%Y-%m-%d %H:%M:%S')

server-name smartdns
EOF

# 绑定地址
if [ "$HAS_IPV6" = true ] && [ "$BINDV6ONLY" = "1" ]; then
    echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
    echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
elif [ "$HAS_IPV6" = true ]; then
    echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
else
    echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
fi

# 基础配置（所有版本通用）
cat >> /etc/smartdns/smartdns.conf << EOF
cache-size 4096
prefetch-domain yes
log-level info
log-file /var/log/smartdns.log
response-mode fastest-ip
rr-ttl 300
rr-ttl-min 60
EOF

# 新版本独有配置
if [ "$IS_NEW_VERSION" = true ]; then
    cat >> /etc/smartdns/smartdns.conf << EOF
serve-expired yes
log-size 2m
log-num 2
speed-check-mode ping,tcp:443
force-AAAA-SOA yes
edns-client-subnet
EOF
fi

# 上游 DNS（所有版本）
cat >> /etc/smartdns/smartdns.conf << EOF

# 上游 DNS 服务器
server 1.1.1.1
server 8.8.8.8
server 9.9.9.9
EOF

# DoH（仅新版本）
if [ "$IS_NEW_VERSION" = true ]; then
    cat >> /etc/smartdns/smartdns.conf << EOF
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
EOF
fi

log_ok "配置已生成"
echo ""
echo -e "${BOLD}配置摘要:${NC}"
grep -E "^bind|^server|^server-https|^force-AAAA|^edns|^speed-check|^serve-expired" /etc/smartdns/smartdns.conf 2>/dev/null || echo "  (基础配置)"

#==================================================
# 第4步: 配置系统 DNS
#==================================================
log_step "配置系统 DNS"

[ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && \
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null

if [ "$INIT" = "systemd" ]; then
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    rm -f /etc/resolv.conf
fi

chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
chattr +i /etc/resolv.conf 2>/dev/null || log_warn "无法锁定 resolv.conf (容器环境正常)"

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

#==================================================
# 第5步: 开机自启 (Alpine)
#==================================================
if [ "$INIT" = "openrc" ]; then
    log_step "创建开机自启"
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
    log_ok "开机自启已创建"
fi

#==================================================
# 第6步: 启动服务
#==================================================
log_step "启动 SmartDNS"

pkill smartdns 2>/dev/null
sleep 1
echo "" > /var/log/smartdns.log 2>/dev/null

STARTED=false

case "$INIT" in
    openrc)
        if [ ! -f /etc/init.d/smartdns ]; then
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
        else
            sed -i "s|command=.*|command=\"${SMARTDNS_BIN}\"|" /etc/init.d/smartdns 2>/dev/null
        fi
        rc-update add smartdns default 2>/dev/null
        rc-service smartdns start 2>/dev/null
        sleep 2
        pgrep smartdns >/dev/null 2>&1 && STARTED=true && log_ok "已启动 (OpenRC)"
        ;;
    systemd)
        if [ -f /lib/systemd/system/smartdns.service ]; then
            SYSTEMD_FILE="/lib/systemd/system/smartdns.service"
        else
            SYSTEMD_FILE="/etc/systemd/system/smartdns.service"
        fi
        
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

# 直接启动
if [ "$STARTED" = false ]; then
    log_warn "服务启动失败，直接启动..."
    "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf &
    sleep 3
    if pgrep smartdns >/dev/null 2>&1; then
        log_ok "已启动 (直接模式)"
        STARTED=true
    else
        log_err "启动失败！"
        echo ""
        echo "=== 错误日志 ==="
        tail -20 /var/log/smartdns.log 2>/dev/null
        echo ""
        echo "=== 手动诊断 ==="
        echo "  $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf -f"
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
    RESULT=$(nslookup -timeout=5 $domain 127.0.0.1 2>&1)
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
    echo -e "${YELLOW}${BOLD}⚠ 部分域名解析异常，请检查网络${NC}"
    echo ""
    echo "可能原因:"
    echo "  1. SmartDNS 监听端口 $PORT，但 resolv.conf 指向默认53"
    echo "     → 测试: nslookup -port=$PORT google.com 127.0.0.1"
    echo "  2. 上游 DNS 不可达"
    echo "     → 检查: cat /var/log/smartdns.log"
fi

echo ""
echo -e "${BOLD}服务信息:${NC}"
echo -e "  版本: ${CYAN}$SMARTDNS_VER${NC}"
echo -e "  来源: ${CYAN}$SMARTDNS_SOURCE${NC}"
echo -e "  程序: ${CYAN}$SMARTDNS_BIN${NC}"
echo -e "  配置: ${CYAN}/etc/smartdns/smartdns.conf${NC}"
echo -e "  日志: ${CYAN}/var/log/smartdns.log${NC}"
echo -e "  端口: ${CYAN}127.0.0.1:${PORT}${NC}"
echo ""
echo -e "${BOLD}常用命令:${NC}"
echo -e "  测试: ${GREEN}nslookup google.com 127.0.0.1${NC}"
echo -e "  日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
echo -e "  重载: ${GREEN}systemctl restart smartdns${NC}"
echo -e "  卸载: ${GREEN}$0 --uninstall${NC}"
echo ""
