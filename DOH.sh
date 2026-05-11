#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 v4.5 (纯加密DNS优化版)
# 上游: 纯 DoH + DoT (无传统UDP)
# 策略: GitHub最新版优先 -> 包管理器备用
# 优化: speed-check适配、工具检测、旧版警告
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
    wget -q --timeout=30 --tries=2 -O "$output" "$url" 2>/dev/null && return 0
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

get_version_number() {
    local ver_output
    ver_output=$("$1" -v 2>&1)
    if echo "$ver_output" | grep -qi "Release\([0-9]\+\)"; then
        echo "$ver_output" | grep -oi "Release\([0-9]\+\)" | grep -o '[0-9]*' | head -1
    else
        echo "0"
    fi
}

port_in_use() {
    ss -tuln 2>/dev/null | grep -q ":${1} " && return 0
    netstat -tuln 2>/dev/null | grep -q ":${1} " && return 0
    return 1
}

# 确保检测工具可用
ensure_tools() {
    local tools_missing=""
    
    # 下载工具
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        tools_missing="$tools_missing wget"
    fi
    
    # 端口检测工具
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        tools_missing="$tools_missing iproute2"
    fi
    
    # DNS 测试工具
    if ! command -v nslookup >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apk) tools_missing="$tools_missing bind-tools" ;;
            apt) tools_missing="$tools_missing dnsutils" ;;
        esac
    fi
    
    # DoH/DoT 检测工具
    if ! command -v curl >/dev/null 2>&1; then
        tools_missing="$tools_missing curl"
    fi
    if ! command -v nc >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apk) tools_missing="$tools_missing netcat-openbsd" ;;
            apt) tools_missing="$tools_missing netcat-openbsd" ;;
        esac
    fi
    
    if [ -n "$tools_missing" ]; then
        log_info "安装缺失工具:${tools_missing}"
        case "$PKG_MGR" in
            apk) apk add --no-cache $tools_missing 2>/dev/null ;;
            apt) apt-get update -qq && apt-get install -y -qq $tools_missing 2>/dev/null ;;
        esac
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

#==================================================
# 第2步: 安装 SmartDNS（需要网络）
#==================================================
log_step "安装 SmartDNS"

SMARTDNS_BIN=""
SMARTDNS_SOURCE=""
SMARTDNS_VER_NUM=0

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

if [ -z "$SMARTDNS_BIN" ]; then
    log_warn "GitHub 下载失败，尝试包管理器..."
    case "$PKG_MGR" in
        apk)
            apk update --quiet 2>/dev/null
            apk search smartdns 2>/dev/null | grep -q "^smartdns" && {
                apk add --no-cache smartdns 2>/dev/null
                SMARTDNS_BIN=$(which smartdns 2>/dev/null)
                SMARTDNS_SOURCE="apk"
            }
            ;;
        apt)
            apt-get update -qq 2>/dev/null
            apt-cache show smartdns >/dev/null 2>&1 && {
                apt-get install -y -qq smartdns 2>/dev/null
                SMARTDNS_BIN=$(which smartdns 2>/dev/null)
                SMARTDNS_SOURCE="apt"
            }
            ;;
    esac
    [ -n "$SMARTDNS_BIN" ] && log_ok "包管理器安装成功"
fi

if [ -z "$SMARTDNS_BIN" ]; then
    log_err "所有安装方式均失败"
    echo ""
    echo "手动安装:"
    echo "  1. wget $GITHUB_URL -O /usr/bin/smartdns"
    echo "  2. chmod +x /usr/bin/smartdns"
    echo "  3. 重新运行: $0"
    exit 1
fi

SMARTDNS_VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
log_info "版本: $SMARTDNS_VER"
log_info "来源: $SMARTDNS_SOURCE"

[ "$SMARTDNS_VER_NUM" -ge 42 ] 2>/dev/null && IS_NEW=true || IS_NEW=false

if [ "$IS_NEW" = false ]; then
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║  ⚠ 警告: 检测到旧版 SmartDNS (<42)        ║${NC}"
    echo -e "${RED}${BOLD}║  旧版不支持 DoH/DoT，将降级为 UDP 模式     ║${NC}"
    echo -e "${RED}${BOLD}║  强烈建议升级: 重新运行脚本使用 GitHub 版  ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "降级为 UDP 上游 DNS"
else
    log_ok "版本支持完整加密功能 (DoH + DoT)"
fi

#==================================================
# 第3步: 准备环境和工具
#==================================================
log_step "准备环境"

# 确保工具
ensure_tools

# 处理 systemd-resolved
if [ "$INIT" = "systemd" ]; then
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        log_info "停用 systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        rm -f /etc/resolv.conf
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        sleep 1
    fi
fi

# 选择端口
PORT=53
if port_in_use 53; then
    log_warn "端口 53 被占用:"
    ss -tulnp 2>/dev/null | grep ":53 " | head -2
    
    for p in 5353 5354; do
        if ! port_in_use $p; then
            PORT=$p
            log_warn "使用备用端口: $PORT"
            break
        fi
    done
    
    if [ "$PORT" = "53" ]; then
        log_warn "所有端口被占用，强制使用 53"
        PORT=53
    fi
else
    log_ok "端口 53 可用"
fi

#==================================================
# 第4步: 生成配置
#==================================================
log_step "生成配置 (纯 DoH + DoT)"

mkdir -p /etc/smartdns
[ -f /etc/smartdns/smartdns.conf ] && \
    cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null

cat > /etc/smartdns/smartdns.conf << EOF
#==========================================
# SmartDNS 配置 v4.5 (纯加密DNS)
# 上游: DoH + DoT (无传统 UDP)
# 版本: $SMARTDNS_VER | 来源: $SMARTDNS_SOURCE
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
#==========================================

server-name smartdns
EOF

# 绑定地址
if [ "$HAS_IPV6" = true ] && [ "$BINDV6ONLY" = "1" ]; then
    cat >> /etc/smartdns/smartdns.conf << EOF
bind [::]:${PORT}
bind 0.0.0.0:${PORT}
EOF
elif [ "$HAS_IPV6" = true ]; then
    echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
else
    echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
fi

cat >> /etc/smartdns/smartdns.conf << EOF

# 缓存
cache-size 4096
prefetch-domain yes

# 日志
log-level info
log-file /var/log/smartdns.log

# 响应模式
response-mode fastest-ip

# TTL
rr-ttl 300
rr-ttl-min 60
EOF

if [ "$IS_NEW" = true ]; then
    cat >> /etc/smartdns/smartdns.conf << 'EOF'

# 过期缓存
serve-expired yes

# 日志轮转
log-size 2m
log-num 2

# 速度检测（优化: 仅检测加密端口）
speed-check-mode tcp:443,tcp:853

# IPv4 环境
force-AAAA-SOA yes

# EDNS
edns-client-subnet
EOF
fi

# 上游 DNS
if [ "$IS_NEW" = true ]; then
    cat >> /etc/smartdns/smartdns.conf << 'EOF'

#==========================================
# 上游 DNS - 纯加密 (DoH + DoT)
# 无传统 UDP, 防止 ISP 劫持/监控
#==========================================

# === DoH (DNS over HTTPS) ===
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
server-https https://dns.quad9.net/dns-query

# === DoT (DNS over TLS) ===
server-tls 1.1.1.1:853 -host-name cloudflare-dns.com
server-tls 1.0.0.1:853 -host-name cloudflare-dns.com
server-tls 8.8.8.8:853 -host-name dns.google
server-tls 8.8.4.4:853 -host-name dns.google
server-tls 9.9.9.9:853 -host-name dns.quad9.net
server-tls 149.112.112.112:853 -host-name dns.quad9.net
EOF
else
    # 旧版降级
    cat >> /etc/smartdns/smartdns.conf << 'EOF'

#==========================================
# 上游 DNS - UDP 降级模式
# ⚠ 此版本不支持 DoH/DoT
# 请升级到 GitHub 最新版获得加密支持
#==========================================

server 1.1.1.1
server 8.8.8.8
server 9.9.9.9
server 2606:4700:4700::1111
server 2001:4860:4860::8888
server 2620:fe::9
EOF
fi

log_ok "配置已生成"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  上游 DNS 配置${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$IS_NEW" = true ]; then
    echo -e "  ${GREEN}DoH (3):${NC} Cloudflare, Google, Quad9"
    echo -e "  ${GREEN}DoT (6):${NC} Cloudflare×2, Google×2, Quad9×2"
    echo -e "  ${RED}UDP:${NC}  无 (纯加密)"
else
    echo -e "  ${YELLOW}UDP (6):${NC} Cloudflare, Google, Quad9 (+IPv6)"
    echo -e "  ${RED}DoH/DoT:${NC} 不支持 (旧版)"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

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
chattr +i /etc/resolv.conf 2>/dev/null || log_warn "无法锁定 (容器环境正常)"

[ -f /etc/dhcpcd.conf ] && ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf && {
    echo "" >> /etc/dhcpcd.conf
    echo "# SmartDNS - 禁止 DHCP 修改 DNS" >> /etc/dhcpcd.conf
    echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    rc-service dhcpcd restart 2>/dev/null
}

log_ok "系统 DNS -> 127.0.0.1"

#==================================================
# 第6步: Alpine 开机自启
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
        pgrep smartdns >/dev/null 2>&1 && log_ok "已启动 (OpenRC)" || log_err "启动失败"
        ;;
    systemd)
        SYSTEMD_FILE="/etc/systemd/system/smartdns.service"
        [ -f /lib/systemd/system/smartdns.service ] && SYSTEMD_FILE="/lib/systemd/system/smartdns.service"
        
        cat > "$SYSTEMD_FILE" << EOF
[Unit]
Description=SmartDNS (纯加密DNS)
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
        pgrep smartdns >/dev/null 2>&1 && log_ok "已启动 (systemd)" || log_err "启动失败"
        ;;
    *)
        "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf &
        sleep 2
        pgrep smartdns >/dev/null 2>&1 && log_ok "已启动" || log_err "启动失败"
        ;;
esac

if ! pgrep smartdns >/dev/null 2>&1; then
    log_err "启动失败，日志:"
    tail -20 /var/log/smartdns.log 2>/dev/null
    exit 1
fi

#==================================================
# 第8步: 验证
#==================================================
log_step "验证 DNS 解析"

sleep 2
ALL_OK=true

echo ""
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

# 加密 DNS 检测
if [ "$IS_NEW" = true ]; then
    echo ""
    log_step "加密 DNS 连通性检测"
    
    # DoH
    echo -e "${BOLD}DoH (DNS over HTTPS):${NC}"
    for item in "Cloudflare|https://cloudflare-dns.com/dns-query" "Google|https://dns.google/dns-query" "Quad9|https://dns.quad9.net/dns-query"; do
        NAME="${item%%|*}"
        URL="${item##*|}"
        
        RESULT=$(curl -s --max-time 5 -H "accept: application/dns-json" "${URL}?name=google.com&type=A" 2>&1)
        if echo "$RESULT" | grep -q '"Status":\s*0'; then
            log_ok "$NAME 正常"
        elif echo "$RESULT" | grep -q "curl"; then
            log_warn "$NAME 无法检测 (curl 异常)"
        else
            log_warn "$NAME 可能受限 (NAT/防火墙)"
        fi
    done
    
    # DoT
    echo ""
    echo -e "${BOLD}DoT (DNS over TLS):${NC}"
    for item in "Cloudflare|1.1.1.1|853" "Google|8.8.8.8|853" "Quad9|9.9.9.9|853"; do
        NAME="${item%%|*}"
        REST="${item#*|}"
        IP="${REST%%|*}"
        DPORT="${REST##*|}"
        
        if command -v nc >/dev/null 2>&1; then
            if nc -z -w 3 "$IP" "$DPORT" 2>/dev/null; then
                log_ok "$NAME 端口 $DPORT 可达"
            else
                log_warn "$NAME 端口 $DPORT 不可达 (防火墙?)"
            fi
        else
            log_warn "$NAME 无法检测 (nc 未安装)"
        fi
    done
fi

# 完成
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}${BOLD}║   ✓ SmartDNS 部署成功 (纯加密DNS)        ║${NC}"
else
    echo -e "${YELLOW}${BOLD}║   ⚠ 部分域名解析异常                     ║${NC}"
fi
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"

echo ""
echo -e "${BOLD}服务信息:${NC}"
echo -e "  版本: ${CYAN}$SMARTDNS_VER${NC}"
echo -e "  来源: ${CYAN}$SMARTDNS_SOURCE${NC}"
echo -e "  端口: ${CYAN}127.0.0.1:${PORT}${NC}"
if [ "$IS_NEW" = true ]; then
    echo -e "  模式: ${GREEN}纯 DoH + DoT (无 UDP)${NC}"
    echo -e "  隐私: ${GREEN}DNS 查询完全加密${NC}"
else
    echo -e "  模式: ${YELLOW}UDP 降级 (旧版)${NC}"
    echo -e "  隐私: ${RED}未加密${NC}"
fi
echo -e "  配置: ${CYAN}/etc/smartdns/smartdns.conf${NC}"
echo -e "  日志: ${CYAN}/var/log/smartdns.log${NC}"
echo ""
echo -e "${BOLD}命令:${NC}"
echo -e "  测试: ${GREEN}nslookup google.com 127.0.0.1${NC}"
echo -e "  日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
echo -e "  卸载: ${GREEN}$0 --uninstall${NC}"
echo ""
