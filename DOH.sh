#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 v5.5 (LTS生产版)
# 上游: 纯 DoH + DoT (无传统UDP)
# 策略: GitHub最新版优先 -> 包管理器备用
# 守护: inotify实时保护 resolv.conf (fallback cron)
# 修复: 下载前自动覆写公网DNS、BusyBox深度兼容
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
# 更新: 2026-06-05
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
# 并发锁（带过期清理 + date fallback）
#==================================================
LOCK_FILE="/tmp/smartdns-deploy.lock"

cleanup_stale_lock() {
    if [ -d "$LOCK_FILE.dir" ]; then
        local lock_mtime now age
        lock_mtime=$(stat -c%Y "$LOCK_FILE.dir" 2>/dev/null || stat -f%m "$LOCK_FILE.dir" 2>/dev/null || echo 0)
        now=$(date +%s 2>/dev/null || awk 'BEGIN{srand(); print srand()}' 2>/dev/null || echo 0)
        age=$((now - lock_mtime))
        if [ "$age" -gt 1800 ] || [ "$age" -lt 0 ]; then
            rmdir "$LOCK_FILE.dir" 2>/dev/null && log_info "清理过期锁文件（${age}秒前）"
        else
            log_err "脚本已在运行或上次异常退出（锁存在 $((age / 60)) 分钟）"
            log_info "如需强制解锁: rmdir $LOCK_FILE.dir"
            exit 1
        fi
    fi
}

if command -v flock >/dev/null 2>&1; then
    exec 200>"$LOCK_FILE"
    if ! flock -n 200 2>/dev/null; then
        log_err "脚本已在运行，请稍后再试"
        exit 1
    fi
    trap 'flock -u 200 2>/dev/null; rm -f "$LOCK_FILE"' EXIT
else
    cleanup_stale_lock
    if ! mkdir "$LOCK_FILE.dir" 2>/dev/null; then
        cleanup_stale_lock
        if ! mkdir "$LOCK_FILE.dir" 2>/dev/null; then
            log_err "无法获取锁，脚本可能已在运行"
            exit 1
        fi
    fi
    trap 'rmdir "$LOCK_FILE.dir" 2>/dev/null' EXIT
fi

#==================================================
# BusyBox 兼容层
#==================================================
BUSYBOX=false
if command -v busybox >/dev/null 2>&1 && [ "$(readlink /bin/sh 2>/dev/null)" = "busybox" ]; then
    BUSYBOX=true
fi

get_filesize() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0
}

kill_process() {
    local proc="$1"
    if command -v pidof >/dev/null 2>&1; then
        pidof "$proc" | xargs kill 2>/dev/null || true
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep "$proc" | xargs kill 2>/dev/null || true
    elif command -v killall >/dev/null 2>&1; then
        killall "$proc" 2>/dev/null || true
    else
        ps -o pid,comm 2>/dev/null | awk -v p="$proc" '$2 ~ p {print $1}' | xargs kill 2>/dev/null || true
    fi
}

process_running() {
    local proc="$1"
    if command -v pidof >/dev/null 2>&1; then
        pidof "$proc" >/dev/null 2>&1 && return 0
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep "$proc" >/dev/null 2>&1 && return 0
    else
        ps -o comm 2>/dev/null | grep -q "$proc" && return 0
    fi
    return 1
}

nslookup_with_timeout() {
    local timeout_sec="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_sec" nslookup "$@" 2>/dev/null
    else
        nslookup "$@" 2>/dev/null &
        local pid=$!
        ( sleep "$timeout_sec" && kill $pid 2>/dev/null ) &
        local killer=$!
        wait $pid 2>/dev/null
        kill $killer 2>/dev/null
        wait $killer 2>/dev/null
    fi
}

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
    
    # 读取端口信息
    PORT=53
    if [ -f /etc/smartdns/smartdns.conf ]; then
        PORT=$(awk '/^bind/{for(i=1;i<=NF;i++) if($i~/:([[:digit:]]+)/){split($i,a,":"); print a[length(a)]; exit}}' /etc/smartdns/smartdns.conf 2>/dev/null)
        [ -z "$PORT" ] && PORT=53
    fi
    
    # 停止守护进程
    kill_process "resolv-guard.sh"
    sleep 0.5
    
    case "$INIT" in
        systemd)
            systemctl stop smartdns 2>/dev/null
            systemctl disable smartdns 2>/dev/null
            systemctl stop resolv-guard 2>/dev/null
            systemctl disable resolv-guard 2>/dev/null
            rm -f /etc/systemd/system/smartdns.service /lib/systemd/system/smartdns.service
            rm -f /etc/systemd/system/resolv-guard.service
            rm -rf /etc/systemd/system/resolv-guard.service.d
            rm -rf /etc/systemd/system/smartdns.service.d
            systemctl daemon-reload 2>/dev/null
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null
            rc-update del smartdns 2>/dev/null
            rc-service resolv-guard stop 2>/dev/null
            rc-update del resolv-guard 2>/dev/null
            rm -f /etc/init.d/smartdns /etc/init.d/resolv-guard
            ;;
    esac
    
    # 清理 cron
    if crontab -l 2>/dev/null | grep -q "resolv-check.sh"; then
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null | grep -v "resolv-check.sh" > "$TMP_CRON"
        if [ -s "$TMP_CRON" ]; then
            crontab "$TMP_CRON" 2>/dev/null
        else
            crontab -r 2>/dev/null
        fi
        rm -f "$TMP_CRON"
    fi
    
    kill_process "smartdns"
    sleep 1
    
    # 清理 iptables
    for proto in udp tcp; do
        iptables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" -m comment --comment "SmartDNS-redirect" 2>/dev/null
        iptables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" -m comment --comment "SmartDNS-redirect" 2>/dev/null 2>&1
            ip6tables -t nat -D OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null 2>&1
        fi
    done
    
    # 持久化
    if [ -f /etc/alpine-release ]; then
        iptables-save > /etc/iptables/rules-save 2>/dev/null
        ip6tables-save > /etc/iptables/rules6-save 2>/dev/null 2>&1
    else
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null 2>&1
    fi
    
    # 恢复 resolv.conf
    BAK=""
    for f in $(ls -t /etc/resolv.conf.bak.* 2>/dev/null); do
        [ -f "$f" ] && { BAK="$f"; break; }
    done
    if [ -n "$BAK" ]; then
        cp "$BAK" /etc/resolv.conf
        log_info "已恢复原始 DNS 配置"
    else
        cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
        log_info "已设置默认公网 DNS"
    fi
    
    # 清理配置
    sed -i '/nohook resolv.conf/d; /SmartDNS/d' /etc/dhcpcd.conf 2>/dev/null
    rm -f /etc/local.d/smartdns-fix.start
    
    # 精确清理日志
    rm -f /var/log/smartdns.log /var/log/smartdns.log.1 /var/log/smartdns.log.2
    rm -f /var/log/resolv-guard.log /var/log/resolv-guard.log.old
    rm -f /var/log/resolv-check.log
    rm -f /var/log/smartdns-install.log
    
    # 清理文件
    rm -f /usr/local/bin/resolv-guard.sh
    rm -f /usr/local/bin/resolv-check.sh
    rm -f /etc/resolv.conf.smartdns.bak
    rm -f /etc/resolv.conf.link.bak
    rm -f /etc/resolv.conf.bak.pre-install
    
    rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
    rm -rf /etc/smartdns
    
    apt-get remove -y smartdns 2>/dev/null
    apk del smartdns 2>/dev/null
    
    echo ""
    echo -e "${YELLOW}如需恢复 systemd-resolved，请手动执行:${NC}"
    echo -e "  systemctl unmask systemd-resolved"
    echo -e "  systemctl enable systemd-resolved"
    echo -e "  systemctl start systemd-resolved"
    
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

ensure_tools() {
    local tools_missing=""
    
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        tools_missing="$tools_missing wget"
    fi
    
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        tools_missing="$tools_missing iproute2"
    fi
    
    if ! command -v nslookup >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apk) tools_missing="$tools_missing bind-tools" ;;
            apt) tools_missing="$tools_missing dnsutils" ;;
        esac
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        tools_missing="$tools_missing curl"
    fi
    if ! command -v nc >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apk) tools_missing="$tools_missing netcat-openbsd" ;;
            apt) tools_missing="$tools_missing netcat-openbsd" ;;
        esac
    fi
    
    if ! command -v timeout >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apk) tools_missing="$tools_missing coreutils" ;;
            apt) tools_missing="$tools_missing coreutils" ;;
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

ensure_inotify() {
    if ! command -v inotifywait >/dev/null 2>&1; then
        log_info "安装 inotify-tools..."
        case "$PKG_MGR" in
            apk) apk add --no-cache inotify-tools 2>/dev/null ;;
            apt) apt-get install -y -qq inotify-tools 2>/dev/null ;;
        esac
    fi
    
    if command -v inotifywait >/dev/null 2>&1; then
        echo "inotify"
    else
        echo "cron"
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
HAS_IPV4=true
ip route get 2606:4700:4700::1111 >/dev/null 2>&1 && HAS_IPV6=true
if [ "$HAS_IPV6" = false ] && [ -f /proc/net/if_inet6 ] && [ -s /proc/net/if_inet6 ]; then
    HAS_IPV6=true
    log_info "通过 /proc/net/if_inet6 检测到 IPv6 支持（容器环境）"
fi
ip route get 1.1.1.1 >/dev/null 2>&1 || HAS_IPV4=false
BINDV6ONLY=$(sysctl net.ipv6.bindv6only 2>/dev/null | awk '{print $3}')
log_info "IPv6: $( $HAS_IPV6 && echo '支持' || echo '不支持' )"
log_info "IPv4: $( $HAS_IPV4 && echo '支持' || echo '不支持' )"

if [ "$HAS_IPV4" = false ] && [ "$HAS_IPV6" = true ]; then
    log_warn "检测到纯 IPv6 环境，GitHub 下载可能需要 NAT64/DNS64"
fi

# 磁盘空间检查
ETC_SPACE=$(df -k /etc 2>/dev/null | awk 'NR==2 {print $4}')
LOG_SPACE=$(df -k /var/log 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$ETC_SPACE" ] && [ "$ETC_SPACE" -lt 5120 ]; then
    log_err "/etc 分区空间不足（<5MB）"; exit 1
fi
if [ -n "$LOG_SPACE" ] && [ "$LOG_SPACE" -lt 5120 ]; then
    log_warn "/var/log 分区空间不足（<5MB），日志可能无法写入"
fi

#==================================================
# 第2步: 确保下载前 DNS 可用
#==================================================
log_step "确保 DNS 可用"

if [ -f /etc/resolv.conf ] && ! grep -q "127.0.0.1" /etc/resolv.conf 2>/dev/null; then
    log_ok "DNS 已是公网配置"
else
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak.pre-install 2>/dev/null
    cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    log_info "已临时设置公网 DNS 用于下载"
fi

#==================================================
# 第3步: 安装 SmartDNS
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
    if [ "$HAS_IPV4" = false ]; then
        log_warn "纯 IPv6 环境下载失败，尝试包管理器..."
        log_warn "如需手动安装: 在有 IPv4 的机器下载后传输"
    fi
    log_warn "GitHub 下载失败，尝试包管理器..."
    case "$PKG_MGR" in
        apk)
            apk update --quiet 2>/dev/null
            apk search smartdns 2>/dev/null | grep -q "^smartdns" && {
                apk add --no-cache smartdns 2>/dev/null
                SMARTDNS_BIN=$(command -v smartdns 2>/dev/null)
                SMARTDNS_SOURCE="apk"
            }
            ;;
        apt)
            apt-get update -qq 2>/dev/null
            apt-cache show smartdns >/dev/null 2>&1 && {
                apt-get install -y -qq smartdns 2>/dev/null
                SMARTDNS_BIN=$(command -v smartdns 2>/dev/null)
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
# 第4步: 准备环境和工具
#==================================================
log_step "准备环境"

ensure_tools

# 处理 systemd-resolved
if [ "$INIT" = "systemd" ]; then
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        log_info "停用 systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        systemctl mask systemd-resolved 2>/dev/null
        if [ -L /etc/resolv.conf ]; then
            cp /etc/resolv.conf /etc/resolv.conf.link.bak 2>/dev/null
        fi
        rm -f /etc/resolv.conf
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        sleep 1
    fi
fi

# 选择端口
PORT=53
USE_IPTABLES=false
is_smartdns_port() {
    if ss -tulnp 2>/dev/null | grep ":53 " | grep -q smartdns 2>/dev/null; then
        return 0
    fi
    if command -v lsof >/dev/null 2>&1; then
        if lsof -i :53 2>/dev/null | grep -q smartdns; then
            return 0
        fi
    fi
    if [ -f /run/smartdns.pid ]; then
        local pid
        pid=$(cat /run/smartdns.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

if port_in_use 53; then
    if is_smartdns_port; then
        log_info "检测到已有 SmartDNS 运行在端口 53，将重新配置"
        PORT=53
    else
        log_warn "端口 53 被占用:"
        ss -tulnp 2>/dev/null | grep ":53 " | head -2
        for p in 5353 5354 5355; do
            if ! port_in_use $p; then
                PORT=$p
                USE_IPTABLES=true
                log_warn "使用备用端口: $PORT (将配置 iptables redirect)"
                break
            fi
        done
        if [ "$PORT" = "53" ]; then
            log_warn "所有端口被占用，强制使用 53"
        fi
    fi
else
    log_ok "端口 53 可用"
fi

#==================================================
# 第5步: 生成配置
#==================================================
log_step "生成配置 (纯 DoH + DoT)"

mkdir -p /etc/smartdns
[ -f /etc/smartdns/smartdns.conf ] && \
    cp /etc/smartdns/smartdns.conf /etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null

cat > /etc/smartdns/smartdns.conf << EOF
#==========================================
# SmartDNS 配置 v5.5 (LTS生产版)
# 上游: DoH + DoT (无传统 UDP)
# 版本: $SMARTDNS_VER | 来源: $SMARTDNS_SOURCE
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
#==========================================

server-name smartdns
EOF

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

# 日志（自动轮转）
log-level info
log-file /var/log/smartdns.log
log-size 2m
log-num 2

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

# 速度检测
speed-check-mode tcp:443,tcp:853

# IPv4 环境
force-AAAA-SOA yes

# EDNS
edns-client-subnet
EOF
fi

if [ "$IS_NEW" = true ]; then
    cat >> /etc/smartdns/smartdns.conf << 'EOF'

#==========================================
# 上游 DNS - 纯加密 (DoH + DoT)
#==========================================

# === DoH ===
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
server-https https://dns.quad9.net/dns-query

# === DoT ===
server-tls 1.1.1.1:853 -host-name cloudflare-dns.com
server-tls 1.0.0.1:853 -host-name cloudflare-dns.com
server-tls 8.8.8.8:853 -host-name dns.google
server-tls 8.8.4.4:853 -host-name dns.google
server-tls 9.9.9.9:853 -host-name dns.quad9.net
server-tls 149.112.112.112:853 -host-name dns.quad9.net
EOF
else
    cat >> /etc/smartdns/smartdns.conf << 'EOF'

#==========================================
# 上游 DNS - UDP 降级模式
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
# 第6步: 配置系统 DNS
#==================================================
log_step "配置系统 DNS"

# 6.1 清理预安装备份
if [ -f /etc/resolv.conf.bak.pre-install ]; then
    log_info "清理下载前 DNS 备份"
    rm -f /etc/resolv.conf.bak.pre-install
fi

# 6.2 备份当前 resolv.conf
if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null
fi

# 6.3 处理符号链接
if [ -L /etc/resolv.conf ]; then
    log_info "检测到 /etc/resolv.conf 为符号链接"
    cp /etc/resolv.conf /etc/resolv.conf.link.bak 2>/dev/null
    
    retry=0
    while [ -L /etc/resolv.conf ] && [ $retry -lt 3 ]; do
        rm -f /etc/resolv.conf
        if [ -L /etc/resolv.conf ]; then
            systemctl stop systemd-resolved 2>/dev/null
            systemctl disable systemd-resolved 2>/dev/null
            systemctl mask systemd-resolved 2>/dev/null
            systemctl daemon-reload 2>/dev/null
            retry=$((retry + 1))
            sleep 2
        fi
    done
    
    if [ -L /etc/resolv.conf ]; then
        log_warn "无法删除符号链接，将使用 iptables redirect 方案"
        USE_IPTABLES=true
    fi
fi

# 6.4 检测容器挂载点
if [ "$USE_IPTABLES" = false ] && mount 2>/dev/null | grep -q "on /etc/resolv.conf "; then
    log_warn "检测到 /etc/resolv.conf 为挂载点（容器环境）"
    log_info "将使用 iptables redirect 方案"
    USE_IPTABLES=true
fi

# 6.5 测试 ::1 连通性
IPV6_LOOPBACK_OK=false
if [ "$HAS_IPV6" = true ]; then
    log_info "测试 ::1 连通性..."
    if nslookup_with_timeout 2 -type=A google.com ::1 >/dev/null 2>&1; then
        IPV6_LOOPBACK_OK=true
        log_ok "::1 可达，将添加到 resolv.conf"
    else
        log_warn "::1 不可达，resolv.conf 将仅使用 127.0.0.1"
    fi
fi

# 6.6 写入 resolv.conf
if [ "$USE_IPTABLES" = false ]; then
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
EOF
    if [ "$IPV6_LOOPBACK_OK" = true ]; then
        echo "nameserver ::1" >> /etc/resolv.conf
    fi
    echo "options edns0 trust-ad" >> /etc/resolv.conf
    
    cp /etc/resolv.conf /etc/resolv.conf.smartdns.bak
    chmod 600 /etc/resolv.conf.smartdns.bak
    log_ok "系统 DNS -> 127.0.0.1$( $IPV6_LOOPBACK_OK && echo ' + ::1' )"
else    log_info "跳过直接写入 resolv.conf，依赖 iptables redirect"
fi

# 6.7 DHCP 客户端
if [ -f /etc/dhcpcd.conf ] && ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
    echo "" >> /etc/dhcpcd.conf
    echo "# SmartDNS - 禁止 DHCP 修改 DNS" >> /etc/dhcpcd.conf
    echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    log_info "已配置 dhcpcd 不覆盖 DNS"
fi

# 6.8 Alpine udhcpc
if [ -d /etc/udhcpc ] || [ -f /etc/alpine-release ]; then
    mkdir -p /etc/udhcpc
    echo 'RESOLV_CONF="NO"' > /etc/udhcpc/udhcpc.conf
    log_info "已配置 udhcpc 不覆盖 DNS"
fi

# 6.9 NetworkManager
if command -v NetworkManager >/dev/null 2>&1; then
    log_info "检测到 NetworkManager"
    if command -v nmcli >/dev/null 2>&1; then
        CON_NAME=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
        if [ -n "$CON_NAME" ]; then
            nmcli con mod "$CON_NAME" ipv4.ignore-auto-dns yes 2>/dev/null
            nmcli con mod "$CON_NAME" ipv6.ignore-auto-dns yes 2>/dev/null
            log_ok "通过 nmcli 配置 NetworkManager"
        fi
    else
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/99-smartdns.conf << 'EOF'
[main]
dns=none
EOF
        log_warn "已配置 NetworkManager，可能需要手动重连网络"
    fi
fi

# 6.10 iptables redirect
if [ "$USE_IPTABLES" = true ] || [ "$PORT" != "53" ]; then
    log_step "配置 iptables redirect"
    
    case "$PKG_MGR" in
        apk) apk add --no-cache iptables 2>/dev/null ;;
        apt) apt-get install -y -qq iptables 2>/dev/null ;;
    esac
    
    for proto in udp tcp; do
        if ! iptables -t nat -C OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null; then
            iptables -t nat -A OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" -m comment --comment "SmartDNS-redirect" 2>/dev/null || \
            iptables -t nat -A OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null
            log_ok "IPv4 $proto 53 -> $PORT"
        fi
    done
    
    if [ "$IPV6_LOOPBACK_OK" = true ] || [ "$HAS_IPV6" = true ]; then
        if command -v ip6tables >/dev/null 2>&1; then
            for proto in udp tcp; do
                if ! ip6tables -t nat -C OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null; then
                    ip6tables -t nat -A OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" -m comment --comment "SmartDNS-redirect" 2>/dev/null || \
                    ip6tables -t nat -A OUTPUT -p $proto --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null
                    log_ok "IPv6 $proto 53 -> $PORT"
                fi
            done
        fi
    fi
    
    mkdir -p /etc/iptables
    case "$PKG_MGR" in
        apk)
            iptables-save > /etc/iptables/rules-save
            ip6tables-save > /etc/iptables/rules6-save 2>/dev/null
            rc-update add iptables 2>/dev/null
            /etc/init.d/iptables save 2>/dev/null
            ;;
        apt)
            iptables-save > /etc/iptables/rules.v4
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
            if ! command -v netfilter-persistent >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>/dev/null
            fi
            netfilter-persistent save 2>/dev/null
            ;;
    esac
    
    IPTABLES_SETUP=true
fi

#==================================================
# 第7步: 部署 resolv.conf 守护
#==================================================
log_step "部署 resolv.conf 守护"

GUARD_MODE=$(ensure_inotify)
mkdir -p /usr/local/bin

# 7.1 创建守护脚本
cat > /usr/local/bin/resolv-guard.sh << 'GUARDEOF'
#!/bin/sh
# SmartDNS resolv.conf 实时守护 v5.5

BAK="/etc/resolv.conf.smartdns.bak"
CONF="/etc/resolv.conf"
LOG="/var/log/resolv-guard.log"
MAX_LOG_SIZE=1048576

get_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0
}

files_differ() {
    [ "$(get_size "$1")" != "$(get_size "$2")" ] && return 0
    
    if command -v cmp >/dev/null 2>&1; then
        if cmp -s "$1" "$2" 2>/dev/null; then
            return 1
        else
            return 0
        fi
    elif command -v diff >/dev/null 2>&1; then
        if diff -q "$1" "$2" >/dev/null 2>&1; then
            return 1
        else
            return 0
        fi
    else
        if [ "$(md5sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$(md5sum "$2" 2>/dev/null | cut -d' ' -f1)" ]; then
            return 1
        else
            return 0
        fi
    fi
}

log_rotate() {
    if [ -f "$LOG" ] && [ "$(get_size "$LOG")" -ge "$MAX_LOG_SIZE" ]; then
        mv "$LOG" "${LOG}.old"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志轮转" > "$LOG"
        chmod 600 "$LOG"
        chmod 600 "${LOG}.old" 2>/dev/null
    fi
}

# 避免重复运行
if command -v pidof >/dev/null 2>&1; then
    pidof -o $$ "resolv-guard.sh" >/dev/null 2>&1 && exit 0
elif command -v pgrep >/dev/null 2>&1; then
    pgrep -f "resolv-guard\.sh" | grep -v $$ | grep -q . 2>/dev/null && exit 0
else
    ps | grep "resolv-guard\.sh" | grep -v grep | grep -v $$ | grep -q . && exit 0
fi

# 检查备份文件
if [ ! -f "$BAK" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误: 备份文件缺失，守护进程退出" >> "$LOG"
    exit 1
fi

last_hour=""
recovery_count=0
error_count=0

while [ ! -d "$(dirname "$CONF")" ]; do
    sleep 2
    error_count=$((error_count + 1))
    [ $error_count -gt 30 ] && exit 1
done

while true; do
    inotifywait -q -e modify,move,delete,create --include "resolv.conf" "$(dirname "$CONF")" 2>/dev/null
    ret=$?
    
    if [ $ret -ne 0 ]; then
        error_count=$((error_count + 1))
        [ $error_count -gt 10 ] && {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误: 连续失败${error_count}次，守护进程退出" >> "$LOG"
            exit 1
        }
        sleep 5
        continue
    fi
    error_count=0
    
    sleep 0.5
    log_rotate
    
    if [ -f "$CONF" ] && [ -f "$BAK" ]; then
        if files_differ "$BAK" "$CONF"; then
            current_hour=$(date '+%Y-%m-%d %H')
            
            if [ "$current_hour" != "$last_hour" ]; then
                cp "$BAK" "$CONF"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] resolv.conf 被修改，已恢复" >> "$LOG"
                last_hour="$current_hour"
                recovery_count=1
            elif [ $recovery_count -ge 5 ]; then
                cp "$BAK" "$CONF"
                recovery_count=$((recovery_count + 1))
            else
                cp "$BAK" "$CONF"
                recovery_count=$((recovery_count + 1))
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] resolv.conf 被修改，已恢复（本小时第${recovery_count}次）" >> "$LOG"
            fi
        fi
    fi
    
    sleep 1
done
GUARDEOF

chmod 700 /usr/local/bin/resolv-guard.sh

# 7.2 注册服务
case "$INIT" in
    systemd)
        cat > /etc/systemd/system/resolv-guard.service << EOF
[Unit]
Description=SmartDNS resolv.conf Guard
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/resolv-guard.sh
Restart=always
RestartSec=3
StandardOutput=null

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable resolv-guard.service 2>/dev/null
        systemctl start resolv-guard.service 2>/dev/null
        log_ok "守护服务已注册 (systemd)"
        ;;
    openrc)
        cat > /etc/init.d/resolv-guard << 'EOF'
#!/sbin/openrc-run
name="resolv-guard"
description="SmartDNS resolv.conf guard daemon"
command="/usr/local/bin/resolv-guard.sh"
command_background=true
pidfile="/run/resolv-guard.pid"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/resolv-guard
        rc-update add resolv-guard default 2>/dev/null
        rc-service resolv-guard start 2>/dev/null
        log_ok "守护服务已注册 (OpenRC)"
        ;;
    *)
        nohup /usr/local/bin/resolv-guard.sh >/dev/null 2>&1 &
        echo $! > /run/resolv-guard.pid
        log_ok "守护进程已启动 (nohup)"
        ;;
esac

# 7.3 fallback cron
if [ "$GUARD_MODE" = "cron" ]; then
    log_warn "inotify 不可用，启用 cron fallback（每分钟检查）"
    
    cat > /usr/local/bin/resolv-check.sh << 'CHECKEOF'
#!/bin/sh
BAK="/etc/resolv.conf.smartdns.bak"
CONF="/etc/resolv.conf"
LOG="/var/log/resolv-check.log"

get_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0
}

files_differ() {
    [ "$(get_size "$1")" != "$(get_size "$2")" ] && return 0
    if command -v cmp >/dev/null 2>&1; then
        if cmp -s "$1" "$2" 2>/dev/null; then
            return 1
        else
            return 0
        fi
    elif command -v diff >/dev/null 2>&1; then
        if diff -q "$1" "$2" >/dev/null 2>&1; then
            return 1
        else
            return 0
        fi
    else
        if [ "$(md5sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$(md5sum "$2" 2>/dev/null | cut -d' ' -f1)" ]; then
            return 1
        else
            return 0
        fi
    fi
}

if [ -f "$LOG" ] && [ "$(get_size "$LOG")" -ge 524288 ]; then
    > "$LOG"
    chmod 600 "$LOG" 2>/dev/null
fi

if [ -f "$BAK" ] && [ -f "$CONF" ] && files_differ "$BAK" "$CONF"; then
    cp "$BAK" "$CONF"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] resolv.conf 修复" >> "$LOG"
fi
CHECKEOF
    chmod 700 /usr/local/bin/resolv-check.sh
    touch /var/log/resolv-check.log 2>/dev/null && chmod 600 /var/log/resolv-check.log 2>/dev/null
    
    if crontab -l >/dev/null 2>&1; then
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null | grep -v "resolv-check.sh" > "$TMP_CRON"
        echo "* * * * * /usr/local/bin/resolv-check.sh" >> "$TMP_CRON"
        crontab "$TMP_CRON" 2>/dev/null
        rm -f "$TMP_CRON"
    else
        echo "* * * * * /usr/local/bin/resolv-check.sh" | crontab - 2>/dev/null
    fi
    log_ok "cron 检查任务已添加"
fi

# 7.4 验证守护
sleep 2
if process_running "resolv-guard.sh"; then
    log_ok "resolv.conf 实时守护已启动"
else
    if [ "$GUARD_MODE" = "cron" ]; then
        log_info "使用 cron 模式保护 resolv.conf"
    else
        log_warn "守护进程启动可能失败，请手动检查"
    fi
fi

# 7.5 Alpine local.d
if [ "$INIT" = "openrc" ]; then
    mkdir -p /etc/local.d
    cat > /etc/local.d/smartdns-fix.start << 'EOF'
#!/bin/sh
sleep 3
if command -v pidof >/dev/null 2>&1; then
    pidof resolv-guard.sh >/dev/null 2>&1 || /usr/local/bin/resolv-guard.sh &
else
    pgrep -f resolv-guard.sh >/dev/null 2>&1 || /usr/local/bin/resolv-guard.sh &
fi
pgrep smartdns >/dev/null 2>&1 || smartdns -c /etc/smartdns/smartdns.conf &
EOF
    chmod +x /etc/local.d/smartdns-fix.start
    rc-update add local default 2>/dev/null
fi

touch /var/log/resolv-guard.log 2>/dev/null && chmod 600 /var/log/resolv-guard.log 2>/dev/null
[ -f /var/log/resolv-guard.log.old ] && chmod 600 /var/log/resolv-guard.log.old 2>/dev/null

#==================================================
# 第8步: 启动服务
#==================================================
log_step "启动 SmartDNS"

kill_process "smartdns"
sleep 1
> /var/log/smartdns.log 2>/dev/null
chmod 644 /var/log/smartdns.log 2>/dev/null

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
        process_running "smartdns" && log_ok "已启动 (OpenRC)" || log_err "启动失败"
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
        process_running "smartdns" && log_ok "已启动 (systemd)" || log_err "启动失败"
        ;;
    *)
        "$SMARTDNS_BIN" -c /etc/smartdns/smartdns.conf &
        sleep 2
        process_running "smartdns" && log_ok "已启动" || log_err "启动失败"
        ;;
esac

if ! process_running "smartdns"; then
    log_err "启动失败，日志:"
    tail -20 /var/log/smartdns.log 2>/dev/null
    exit 1
fi

#==================================================
# 第9步: 验证
#==================================================
log_step "验证 DNS 解析"

sleep 2
ALL_OK=true

echo ""
for domain in google.com ipv6.google.com cloudflare.com; do
    if [ "$domain" = "ipv6.google.com" ] && [ "$HAS_IPV6" = false ]; then
        log_info "ipv6.google.com 跳过（无 IPv6）"
        continue
    fi
    
    if [ "$USE_IPTABLES" = true ] || [ "$PORT" = "53" ]; then
        RESULT=$(nslookup_with_timeout 3 $domain 127.0.0.1 2>&1)
    else
        RESULT=$(nslookup_with_timeout 3 -port=$PORT $domain 127.0.0.1 2>&1)
    fi
    
    if echo "$RESULT" | grep -q "Address"; then
        IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
        log_ok "$domain → $IP"
    else
        log_err "$domain 解析失败"
        ALL_OK=false
    fi
done

# IPv6 localhost 测试
if [ "$IPV6_LOOPBACK_OK" = true ]; then
    echo ""
    log_info "测试 ::1 解析..."
    if nslookup_with_timeout 3 google.com ::1 >/dev/null 2>&1; then
        log_ok "::1 解析正常"
    else
        log_warn "::1 解析失败"
    fi
fi

# 加密 DNS 检测
if [ "$IS_NEW" = true ]; then
    echo ""
    log_step "加密 DNS 连通性检测"
    
    DOH_OK=false
    DOT_OK=false
    
    echo -e "${BOLD}DoH (DNS over HTTPS):${NC}"
    for item in "Cloudflare|https://cloudflare-dns.com/dns-query" "Google|https://dns.google/dns-query" "Quad9|https://dns.quad9.net/dns-query"; do
        NAME="${item%%|*}"
        URL="${item##*|}"
        
        RESULT=$(curl -s --max-time 5 -H "accept: application/dns-json" "${URL}?name=google.com&type=A" 2>&1)
        if echo "$RESULT" | grep -q '"Status":[[:space:]]*0'; then
            log_ok "$NAME 正常"
            DOH_OK=true
        elif echo "$RESULT" | grep -q "curl"; then
            log_warn "$NAME 无法检测 (curl 异常)"
        else
            log_warn "$NAME 可能受限 (NAT/防火墙)"
        fi
    done
    
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
                DOT_OK=true
            else
                log_warn "$NAME 端口 $DPORT 不可达 (防火墙?)"
            fi
        else
            log_warn "$NAME 无法检测 (nc 未安装)"
        fi
    done
    
    if [ "$DOH_OK" = false ] && [ "$DOT_OK" = false ]; then
        echo ""
        echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}${BOLD}║  ⚠ 所有加密 DNS 均不可达                   ║${NC}"
        echo -e "${YELLOW}${BOLD}║  可能原因: 防火墙阻断 443/853 端口         ║${NC}"
        echo -e "${YELLOW}${BOLD}║  建议: 编辑配置添加 UDP fallback           ║${NC}"
        echo -e "${YELLOW}${BOLD}║  echo 'server 1.1.1.1' >> /etc/smartdns/smartdns.conf ║${NC}"
        echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════╝${NC}"
        echo ""
    fi
fi

# 守护进程验证
if [ "$GUARD_MODE" = "inotify" ] && [ "$USE_IPTABLES" = false ]; then
    echo ""
    log_step "守护进程验证"
    
    cp /etc/resolv.conf /tmp/resolv.conf.test.bak 2>/dev/null
    echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null
    
    sleep 2
    
    if grep -q "127.0.0.1" /etc/resolv.conf 2>/dev/null; then
        log_ok "守护进程验证通过（≤2秒自动恢复）"
    else
        log_warn "守护进程未自动恢复，恢复测试配置"
        cp /tmp/resolv.conf.test.bak /etc/resolv.conf 2>/dev/null
    fi
    rm -f /tmp/resolv.conf.test.bak
elif [ "$USE_IPTABLES" = true ]; then
    echo ""
    log_step "iptables 规则验证"
    if iptables -t nat -C OUTPUT -p udp --dport 53 -j REDIRECT --to-port "$PORT" 2>/dev/null; then
        log_ok "iptables redirect 规则正常"
    else
        log_warn "iptables 规则可能未生效"
    fi
fi

#==================================================
# 完成
#==================================================
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
if [ "$ALL_OK" = true ]; then
    echo -e "${GREEN}${BOLD}║   ✓ SmartDNS 部署成功 (纯加密DNS)        ║${NC}"
else
    echo -e "${YELLOW}${BOLD}║   ⚠ 部分域名解析异常                     ║${NC}"
fi
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  DNS 保护状态${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  保护方式: $( [ "$GUARD_MODE" = "inotify" ] && echo "实时守护(inotify)" || echo "定时检查(cron)" )"
echo -e "  恢复速度: $( [ "$GUARD_MODE" = "inotify" ] && echo "≤2秒" || echo "≤60秒" )"
echo -e "  iptables:  $( [ "$USE_IPTABLES" = true ] && echo "已配置 redirect" || echo "未使用" )"
echo -e "  IPv6:      $( [ "$IPV6_LOOPBACK_OK" = true ] && echo "已启用 (::1)" || echo "未启用" )"
echo -e "  日志上限:  ≤8MB (自动轮转)"
echo -e "  日志权限:  守护日志 600 (仅root可读)"
echo -e "  备份权限:  /etc/resolv.conf.smartdns.bak 600"
echo -e "  BusyBox:   $( $BUSYBOX && echo '是 (兼容模式)' || echo '否' )"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  服务信息${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
echo -e "  守护: ${CYAN}/usr/local/bin/resolv-guard.sh${NC}"
echo -e "  备份: ${CYAN}/etc/resolv.conf.smartdns.bak${NC}"
echo ""
echo -e "${BOLD}命令:${NC}"
echo -e "  测试: ${GREEN}nslookup google.com 127.0.0.1${NC}"
echo -e "  日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
echo -e "  守护: ${GREEN}tail -f /var/log/resolv-guard.log${NC}"
echo -e "  卸载: ${GREEN}$0 --uninstall${NC}"
echo ""
