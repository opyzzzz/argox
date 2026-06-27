#!/bin/sh
#==========================================================================
# SmartDNS 智能部署脚本 v6.4.10
# 优化: inotify 安装提前到 ensure_tools，与其他工具同批安装
#==========================================================================
set +e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { printf "%b[INFO]%b %s\n" "$CYAN" "$NC" "$1"; }
log_ok()    { printf "%b[OK]%b %s\n" "$GREEN" "$NC" "$1"; }
log_err()   { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1"; }
log_warn()  { printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1"; }
log_step()  { printf "\n%b>>> %s%b\n" "$BOLD$BLUE" "$1" "$NC"; }

[ "$(id -u)" -ne 0 ] && { log_err "需要 root 权限"; exit 1; }

SMARTDNS_BIN=""; SMARTDNS_VER=""; SMARTDNS_VER_NUM=0; SMARTDNS_SOURCE=""
IS_VER_NEW=false; PORT=53
OS_TYPE=""; OS_VER=""; INIT_TYPE=""; VIRT_TYPE=""; VIRT_IS_CONTAINER=false
NET_STACK=""; HAS_IPV4=true; HAS_IPV6=false
TAKEOVER_STRATEGY="standard"
RESOLV_IS_SYMLINK=false; RESOLV_IS_TMPFS=false; RESOLV_FS_TYPE=""
SYSTEMD_RESOLVED_RUNNING=false; CLOUD_INIT_EXISTS=false; CLOUD_INIT_MANAGES_DNS=false
TMPFILES_HAS_RESOLV=false
DEPLOY_LOG="/var/log/smartdns-deploy.log"
ARCH=""; PKG_MGR=""
INOTIFY_CMD=""; INOTIFY_ARGS=""
PID_FILE="/var/run/smartdns-dns-guard.pid"
GUARD_SCRIPT="/usr/local/bin/smartdns-dns-guard.sh"

RESOLV_TEMPLATE="/etc/smartdns/resolv.smartdns"
RESOLV_BACKUP="/etc/resolv.conf.smartdns.bak"
RESOLV_FALLBACK="/etc/smartdns/resolv.fallback"

APT_UPDATED=false

pkg_install() {
    local pkgs="$1" max_retry="${2:-3}" attempt=1
    
    while [ "$attempt" -le "$max_retry" ]; do
        case "$PKG_MGR" in
            apk)
                apk add --no-cache $pkgs 2>/dev/null && return 0
                ;;
            apt)
                for i in $(seq 1 30); do
                    fuser /var/lib/dpkg/lock-frontend 2>/dev/null && sleep 1 || break
                done
                if ! $APT_UPDATED; then
                    apt-get update -qq 2>/dev/null && APT_UPDATED=true
                fi
                apt-get install -y -qq $pkgs 2>/dev/null && return 0
                ;;
        esac
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_retry" ] && sleep 2
    done
    return 1
}

github_download() {
    local url="$1" output="$2" attempt=1
    
    while [ "$attempt" -le 3 ]; do
        wget -q --timeout=30 --tries=1 -O "$output" "$url" 2>/dev/null && [ -s "$output" ] && return 0
        curl -sL --max-time 30 -o "$output" "$url" 2>/dev/null && [ -s "$output" ] && return 0
        attempt=$((attempt + 1))
        [ "$attempt" -le 3 ] && sleep 3
    done
    return 1
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7)  echo "arm" ;;
        i386|i686)     echo "x86" ;;
        *)             echo "x86_64" ;;
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
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then tools_missing="$tools_missing wget"; fi
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then tools_missing="$tools_missing iproute2"; fi
    if ! command -v nslookup >/dev/null 2>&1; then
        case "$PKG_MGR" in apk) tools_missing="$tools_missing bind-tools" ;; apt) tools_missing="$tools_missing dnsutils" ;; esac
    fi
    if ! command -v nc >/dev/null 2>&1; then
        case "$PKG_MGR" in apk) tools_missing="$tools_missing netcat-openbsd" ;; apt) tools_missing="$tools_missing netcat-openbsd" ;; esac
    fi
    # inotify 提前到此处安装，与其他工具同批，共享 apt 缓存
    if ! command -v inotifywait >/dev/null 2>&1 && ! command -v inotifyd >/dev/null 2>&1; then
        case "$PKG_MGR" in apk) tools_missing="$tools_missing inotify-tools" ;; apt) tools_missing="$tools_missing inotify-tools" ;; esac
    fi
    if [ -n "$tools_missing" ]; then
        log_info "安装缺失工具: $tools_missing"
        pkg_install "$tools_missing" || log_warn "部分工具安装失败"
    fi
}

dns_query() {
    local domain="$1" server="$2"
    if [ "$PORT" = "53" ]; then
        safe_nslookup "$domain" "$server"
    else
        nslookup -timeout=5 -port="$PORT" "$domain" "$server" 2>&1 || \
        nslookup -port="$PORT" "$domain" "$server" 2>&1
    fi
}

safe_nslookup() {
    local domain="$1" server="$2" output
    if output=$(nslookup -timeout=5 "$domain" "$server" 2>&1); then
        if echo "$output" | grep -q "Address"; then
            echo "$output"; return 0
        fi
    fi
    nslookup "$domain" "$server" 2>&1
}

detect_inotify() {
    if command -v inotifywait >/dev/null 2>&1; then
        INOTIFY_CMD="inotifywait"
        INOTIFY_ARGS="-m -e modify,close_write"
        return 0
    fi
    if command -v inotifyd >/dev/null 2>&1; then
        INOTIFY_CMD="inotifyd"
        INOTIFY_ARGS="-"
        return 0
    fi
    log_warn "inotify 工具不可用，将使用轻量级轮询 (5秒间隔)"
    return 1
}

safe_rc_add() {
    local service="$1" runlevel="${2:-default}"
    if ! rc-update show 2>/dev/null | grep -q "$service.*$runlevel"; then
        rc-update add "$service" "$runlevel" 2>/dev/null
    fi
}

write_resolv() {
    cat "$RESOLV_TEMPLATE" > /etc/resolv.conf
}

#==================================================
# 模块0: 环境检测
#==================================================
module_detect() {
    log_step "模块0: 环境检测"
    
    if [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"; OS_VER=$(cat /etc/alpine-release); PKG_MGR="apk"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release 2>/dev/null
        OS_TYPE="debian"; OS_VER="${VERSION_ID:-unknown}"; PKG_MGR="apt"
    else
        log_err "无法识别的系统"; exit 1
    fi
    log_info "系统: $OS_TYPE $OS_VER"
    
    PID1=$(cat /proc/1/comm 2>/dev/null)
    if [ -d /run/systemd/system ]; then
        INIT_TYPE="systemd"
    elif [ "$PID1" = "openrc-init" ] || [ -f /sbin/openrc ]; then
        INIT_TYPE="openrc"
    else
        INIT_TYPE="none"
    fi
    log_info "Init: $INIT_TYPE (PID1: $PID1)"
    
    VIRT_TYPE="kvm"
    if grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null; then VIRT_TYPE="podman"; fi
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then VIRT_TYPE="lxc"; fi
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then VIRT_TYPE="podman"; fi
    case "$VIRT_TYPE" in
        podman|docker|lxc) VIRT_IS_CONTAINER=true ;;
        *) VIRT_IS_CONTAINER=false ;;
    esac
    log_info "虚拟化: $VIRT_TYPE (容器: $VIRT_IS_CONTAINER)"
    
    HAS_IPV4=true; HAS_IPV6=false
    ip route get 1.1.1.1 >/dev/null 2>&1 || HAS_IPV4=false
    ip route get 2606:4700:4700::1111 >/dev/null 2>&1 && HAS_IPV6=true
    if [ "$HAS_IPV4" = true ] && [ "$HAS_IPV6" = true ]; then NET_STACK="双栈"
    elif [ "$HAS_IPV4" = true ]; then NET_STACK="纯IPv4"
    else NET_STACK="纯IPv6"; fi
    log_info "网络栈: $NET_STACK (IPv4: $HAS_IPV4, IPv6: $HAS_IPV6)"
    
    RESOLV_IS_SYMLINK=false; RESOLV_IS_TMPFS=false
    SYSTEMD_RESOLVED_RUNNING=false; CLOUD_INIT_EXISTS=false
    CLOUD_INIT_MANAGES_DNS=false; TMPFILES_HAS_RESOLV=false
    
    if [ -L /etc/resolv.conf ]; then RESOLV_IS_SYMLINK=true; fi
    if [ -f /etc/resolv.conf ]; then
        RESOLV_FS_TYPE=$(df -T /etc/resolv.conf 2>/dev/null | tail -1 | awk '{print $2}')
        [ "$RESOLV_FS_TYPE" = "tmpfs" ] && RESOLV_IS_TMPFS=true
    fi
    log_info "resolv.conf: 软链接=$RESOLV_IS_SYMLINK, tmpfs=$RESOLV_IS_TMPFS"
    
    if command -v resolvectl >/dev/null 2>&1 && resolvectl status >/dev/null 2>&1; then
        SYSTEMD_RESOLVED_RUNNING=true
        log_warn "systemd-resolved 运行中"
    fi
    
    if command -v cloud-init >/dev/null 2>&1; then
        CLOUD_INIT_EXISTS=true
        if [ -f /etc/cloud/cloud.cfg ] && grep -q "resolv_conf\|manage-resolv-conf" /etc/cloud/cloud.cfg 2>/dev/null; then
            CLOUD_INIT_MANAGES_DNS=true
        fi
        for cfg in /etc/cloud/cloud.cfg.d/*; do
            [ -f "$cfg" ] || continue
            grep -q "resolv_conf\|manage-resolv-conf" "$cfg" 2>/dev/null && CLOUD_INIT_MANAGES_DNS=true
        done
        [ "$CLOUD_INIT_MANAGES_DNS" = true ] && log_warn "cloud-init 管理 DNS"
    fi
    
    if find /usr/lib/tmpfiles.d/ /etc/tmpfiles.d/ -maxdepth 1 -type f -exec grep -l "/etc/resolv.conf" {} \; 2>/dev/null | grep -q .; then
        TMPFILES_HAS_RESOLV=true
        log_warn "tmpfiles.d 管理 resolv.conf"
    fi
    
    if $SYSTEMD_RESOLVED_RUNNING; then
        TAKEOVER_STRATEGY="resolved"
    elif $VIRT_IS_CONTAINER && $RESOLV_IS_TMPFS; then
        TAKEOVER_STRATEGY="podman"
    elif $CLOUD_INIT_EXISTS && $CLOUD_INIT_MANAGES_DNS; then
        TAKEOVER_STRATEGY="cloudinit"
    else
        TAKEOVER_STRATEGY="standard"
    fi
    log_ok "接管策略: $TAKEOVER_STRATEGY"
    
    ARCH=$(get_arch)
    ensure_tools
}

#==================================================
# 模块1: 安装 SmartDNS
#==================================================
module_install() {
    log_step "模块1: 安装 SmartDNS"
    
    GITHUB_URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
    TEMP_BIN="/tmp/smartdns-$$"
    
    log_info "尝试 GitHub 最新版..."
    if github_download "$GITHUB_URL" "$TEMP_BIN"; then
        chmod +x "$TEMP_BIN"
        mv "$TEMP_BIN" /usr/bin/smartdns
        SMARTDNS_BIN="/usr/bin/smartdns"
        SMARTDNS_SOURCE="GitHub"
        log_ok "GitHub 最新版安装成功"
    fi
    rm -f "$TEMP_BIN"
    
    if [ -z "$SMARTDNS_BIN" ]; then
        log_warn "GitHub 下载失败，尝试包管理器..."
        if pkg_install smartdns 3; then
            SMARTDNS_BIN="/usr/sbin/smartdns"
            [ -x "$SMARTDNS_BIN" ] || SMARTDNS_BIN="/usr/bin/smartdns"
            [ -x "$SMARTDNS_BIN" ] || SMARTDNS_BIN=$(which smartdns 2>/dev/null)
            [ -n "$SMARTDNS_BIN" ] && SMARTDNS_SOURCE="$PKG_MGR" && log_ok "包管理器安装成功"
        fi
    fi
    
    if [ -z "$SMARTDNS_BIN" ] || [ ! -x "$SMARTDNS_BIN" ]; then
        log_err "所有安装方式均失败"
        echo "手动安装: wget $GITHUB_URL -O /usr/bin/smartdns && chmod +x /usr/bin/smartdns"
        exit 1
    fi
    
    SMARTDNS_VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
    SMARTDNS_VER_NUM=$(get_version_number "$SMARTDNS_BIN")
    [ "$SMARTDNS_VER_NUM" -ge 42 ] 2>/dev/null && IS_VER_NEW=true || IS_VER_NEW=false
    log_info "版本: $SMARTDNS_VER (来源: $SMARTDNS_SOURCE)"
    [ "$IS_VER_NEW" = true ] && log_ok "支持 upstream-group 自动降级"
}

#==================================================
# 模块2: 生成配置与 DNS 模板
#==================================================
module_config() {
    log_step "模块2: 生成配置与 DNS 模板"
    
    mkdir -p /etc/smartdns
    [ -f /etc/smartdns/smartdns.conf ] && \
        cp /etc/smartdns/smartdns.conf "/etc/smartdns/smartdns.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    
    if [ "$HAS_IPV6" = true ] && [ "$HAS_IPV4" = true ]; then
        cat > "$RESOLV_TEMPLATE" << EOF
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
        cat > "$RESOLV_FALLBACK" << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    elif [ "$HAS_IPV6" = true ]; then
        cat > "$RESOLV_TEMPLATE" << EOF
nameserver ::1
options edns0 trust-ad
EOF
        cat > "$RESOLV_FALLBACK" << EOF
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    else
        cat > "$RESOLV_TEMPLATE" << EOF
nameserver 127.0.0.1
options edns0 trust-ad
EOF
        cat > "$RESOLV_FALLBACK" << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
    log_ok "DNS 模板已生成: $RESOLV_TEMPLATE"
    
    [ "$TAKEOVER_STRATEGY" = "resolved" ] && systemctl stop systemd-resolved 2>/dev/null
    
    PORT=53
    if port_in_use 53; then
        log_warn "端口 53 被占用"
        for p in 5353 5354; do
            if ! port_in_use "$p"; then PORT="$p"; log_warn "使用备用端口: $PORT"; break; fi
        done
    else
        log_ok "端口 53 可用"
    fi
    
    cat > /etc/smartdns/smartdns.conf << EOF
# SmartDNS 配置 v6.4.10
# 环境: $OS_TYPE $OS_VER | $VIRT_TYPE | $NET_STACK
# 版本: $SMARTDNS_VER | 来源: $SMARTDNS_SOURCE
# 策略: $TAKEOVER_STRATEGY | 时间: $(date '+%Y-%m-%d %H:%M:%S')
server-name smartdns
EOF
    
    if [ "$HAS_IPV6" = true ] && [ "$HAS_IPV4" = true ]; then
        echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
    elif [ "$HAS_IPV4" = true ]; then
        echo "bind 0.0.0.0:${PORT}" >> /etc/smartdns/smartdns.conf
    else
        echo "bind [::]:${PORT}" >> /etc/smartdns/smartdns.conf
    fi
    
    cat >> /etc/smartdns/smartdns.conf << EOF
cache-size 4096
prefetch-domain yes
serve-expired no
response-mode fastest-ip
rr-ttl 300
rr-ttl-min 0
log-level info
log-file /var/log/smartdns.log
log-size 1m
log-num 3
speed-check-mode tcp:443,tcp:853
alive-check-interval 300
alive-check-mode tcp:80
EOF
    
    [ "$HAS_IPV6" = false ] && echo "force-AAAA-SOA yes" >> /etc/smartdns/smartdns.conf
    [ "$IS_VER_NEW" = true ] && [ "$NET_STACK" = "双栈" ] && \
        echo "dualstack-ip-selection yes" >> /etc/smartdns/smartdns.conf
    
    if [ "$IS_VER_NEW" = true ]; then
        log_info "配置 upstream-group (加密组 + UDP兜底组)"
        cat >> /etc/smartdns/smartdns.conf << 'EOF'

upstream-group secure
server-https https://dns.google/dns-query -group secure
server-https https://cloudflare-dns.com/dns-query -group secure
server-tls 8.8.8.8:853 -host-name dns.google -no-check-certificate -group secure
server-tls 1.1.1.1:853 -host-name cloudflare-dns.com -no-check-certificate -group secure
EOF
        [ "$HAS_IPV6" = true ] && cat >> /etc/smartdns/smartdns.conf << 'EOF'
server-https https://[2001:4860:4860::8888]/dns-query -group secure
server-https https://[2606:4700:4700::1111]/dns-query -group secure
server-tls 2001:4860:4860::8844:853 -host-name dns.google -no-check-certificate -group secure
server-tls 2606:4700:4700::1001:853 -host-name cloudflare-dns.com -no-check-certificate -group secure
EOF
        cat >> /etc/smartdns/smartdns.conf << 'EOF'

upstream-group fallback
server 8.8.8.8 -group fallback
server 1.1.1.1 -group fallback
EOF
        [ "$HAS_IPV6" = true ] && cat >> /etc/smartdns/smartdns.conf << 'EOF'
server 2001:4860:4860::8888 -group fallback
server 2606:4700:4700::1111 -group fallback
EOF
        cat >> /etc/smartdns/smartdns.conf << 'EOF'

fail-count 3
keepalive-fail-count 5
check-interval 600
EOF
    else
        log_warn "旧版降级: 仅 UDP 上游"
        [ "$HAS_IPV4" = true ] && cat >> /etc/smartdns/smartdns.conf << EOF
server 8.8.8.8
server 1.1.1.1
EOF
        [ "$HAS_IPV6" = true ] && cat >> /etc/smartdns/smartdns.conf << EOF
server 2001:4860:4860::8888
server 2606:4700:4700::1111
EOF
    fi
    
    log_ok "配置已生成: /etc/smartdns/smartdns.conf"
}

#==================================================
# 模块3: 接管系统 DNS
#==================================================
module_dns_takeover() {
    log_step "模块3: 接管系统 DNS (策略: $TAKEOVER_STRATEGY)"
    
    detect_inotify
    [ -z "$INOTIFY_CMD" ] && log_warn "inotify 工具不可用，将使用轻量级轮询 (5秒间隔)" || log_info "inotify 工具: $INOTIFY_CMD"
    
    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    fi
    
    if [ "$TAKEOVER_STRATEGY" = "resolved" ]; then
        log_info "执行策略: 停用 systemd-resolved"
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        systemctl mask systemd-resolved 2>/dev/null
        rm -f /etc/resolv.conf
        write_resolv
        if [ "$TMPFILES_HAS_RESOLV" = true ]; then
            mkdir -p /etc/tmpfiles.d
            printf "# SmartDNS 已接管\n" > /etc/tmpfiles.d/systemd-resolved.conf
            log_ok "tmpfiles.d 规则已覆盖"
        fi
        if $CLOUD_INIT_EXISTS; then
            mkdir -p /etc/cloud/cloud.cfg.d
            printf "manage-resolv-conf: false\n" > /etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg
            log_ok "cloud-init DNS 管理已禁用"
        fi
    fi
    
    if [ "$TAKEOVER_STRATEGY" = "cloudinit" ]; then
        log_info "执行策略: 禁用 cloud-init DNS 管理"
        mkdir -p /etc/cloud/cloud.cfg.d
        printf "manage-resolv-conf: false\n" > /etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg
        log_ok "cloud-init DNS 管理已禁用"
    fi
    
    if [ "$TAKEOVER_STRATEGY" != "resolved" ]; then
        write_resolv
    fi
    
    cat "$RESOLV_TEMPLATE" > "$RESOLV_BACKUP"
    chmod 644 "$RESOLV_BACKUP" 2>/dev/null
    
    if [ "$INIT_TYPE" = "openrc" ]; then
        log_info "创建 Alpine 启动覆盖脚本"
        mkdir -p /etc/local.d
        cat > /etc/local.d/smartdns-dns.start << LSTART
#!/bin/sh
sleep 5
for i in 1 2 3 4 5; do
    if cmp -s ${RESOLV_TEMPLATE} /etc/resolv.conf 2>/dev/null; then
        exit 0
    fi
    sleep 1
done
cat ${RESOLV_TEMPLATE} > /etc/resolv.conf
LSTART
        chmod +x /etc/local.d/smartdns-dns.start
        safe_rc_add local default
        log_ok "local.d 启动脚本已创建"
        
    elif [ "$INIT_TYPE" = "systemd" ]; then
        log_info "创建 systemd oneshot 启动覆盖"
        cat > /etc/systemd/system/smartdns-dns-fix.service << SSTART
[Unit]
Description=SmartDNS DNS Fix
After=network-online.target cloud-init.service systemd-resolved.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 5; for i in 1 2 3 4 5; do cmp -s ${RESOLV_TEMPLATE} /etc/resolv.conf 2>/dev/null && exit 0; sleep 1; done; cat ${RESOLV_TEMPLATE} > /etc/resolv.conf'

[Install]
WantedBy=multi-user.target
SSTART
        systemctl daemon-reload 2>/dev/null
        systemctl enable smartdns-dns-fix.service 2>/dev/null
        log_ok "systemd oneshot 服务已创建"
    fi
    
    log_info "部署 DNS 文件守护"
    cat > "$GUARD_SCRIPT" << GUARD
#!/bin/sh
# SmartDNS DNS 文件守护 v6.4.10
TARGET="/etc/resolv.conf"
TEMPLATE="${RESOLV_TEMPLATE}"
PID_FILE="${PID_FILE}"

(
    echo \$\$ > "\$PID_FILE"
    
    cleanup() {
        rm -f "\$PID_FILE"
        pkill -P \$\$ 2>/dev/null
        exit 0
    }
    trap cleanup INT TERM
    
    restore_dns() {
        if [ -f "\$TEMPLATE" ] && ! cmp -s "\$TEMPLATE" "\$TARGET" 2>/dev/null; then
            cat "\$TEMPLATE" > "\$TARGET" 2>/dev/null
        fi
    }
    
    if command -v inotifywait >/dev/null 2>&1; then
        while true; do
            inotifywait -m -e modify,close_write "\$TARGET" 2>/dev/null | while read -r path event file; do
                sleep 0.5
                restore_dns
            done
            sleep 1
        done
    elif command -v inotifyd >/dev/null 2>&1; then
        while true; do
            inotifyd - "\$TARGET" 2>/dev/null | while read -r event file; do
                case "\$event" in w|m|c) sleep 0.5; restore_dns ;; esac
            done
            sleep 1
        done
    else
        while true; do
            sleep 5
            restore_dns
        done
    fi
) &

exit 0
GUARD
    chmod 700 "$GUARD_SCRIPT"
    
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    pkill -f "^/usr/local/bin/smartdns-dns-guard\.sh" 2>/dev/null
    sleep 0.5
    
    if [ "$INIT_TYPE" = "systemd" ]; then
        cat > /etc/systemd/system/smartdns-dns-guard.service << 'GSTART'
[Unit]
Description=SmartDNS DNS Guard
After=smartdns.service smartdns-dns-fix.service
Requires=smartdns.service

[Service]
Type=forking
ExecStart=/usr/local/bin/smartdns-dns-guard.sh
PIDFile=/var/run/smartdns-dns-guard.pid
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
GSTART
        systemctl daemon-reload 2>/dev/null
        systemctl enable smartdns-dns-guard.service 2>/dev/null
        systemctl start smartdns-dns-guard.service 2>/dev/null
    elif [ "$INIT_TYPE" = "openrc" ]; then
        mkdir -p /etc/local.d
        cat > /etc/local.d/smartdns-guard.start << 'OGSTART'
#!/bin/sh
/usr/local/bin/smartdns-dns-guard.sh
OGSTART
        chmod +x /etc/local.d/smartdns-guard.start
        "$GUARD_SCRIPT"
        safe_rc_add local default
    else
        "$GUARD_SCRIPT"
    fi
    
    log_ok "DNS 守护已部署 (工具: ${INOTIFY_CMD:-轮询})"
    log_ok "系统 DNS → $(head -1 "$RESOLV_TEMPLATE")"
}

#==================================================
# 模块4: 服务与守护
#==================================================
module_service() {
    log_step "模块4: 部署 SmartDNS 服务"
    
    pkill smartdns 2>/dev/null
    sleep 1
    echo "" > /var/log/smartdns.log 2>/dev/null
    
    case "$INIT_TYPE" in
        systemd)
            cat > /etc/systemd/system/smartdns.service << 'SVC'
[Unit]
Description=SmartDNS (DoH+DoT+UDP)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/smartdns -c /etc/smartdns/smartdns.conf
PIDFile=/run/smartdns.pid
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=3
WatchdogSec=30

[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload
            systemctl enable smartdns.service 2>/dev/null
            systemctl restart smartdns.service
            sleep 2
            ;;
        openrc)
            if [ ! -f /etc/init.d/smartdns ]; then
                cat > /etc/init.d/smartdns << OSVC
#!/sbin/openrc-run
name="SmartDNS"
command="/usr/bin/smartdns"
command_args="-c /etc/smartdns/smartdns.conf"
command_background=true
pidfile="/run/smartdns.pid"
depend() { need net; after firewall; }
OSVC
                chmod +x /etc/init.d/smartdns
            fi
            safe_rc_add smartdns default
            rc-service smartdns start 2>/dev/null
            sleep 2
            ;;
        *)
            /usr/bin/smartdns -c /etc/smartdns/smartdns.conf &
            sleep 2
            ;;
    esac
    
    if pgrep smartdns >/dev/null 2>&1; then
        log_ok "SmartDNS 已启动"
    else
        log_err "启动失败，日志:"
        tail -20 /var/log/smartdns.log 2>/dev/null
        exit 1
    fi
}

#==================================================
# 模块5: 验证与日志
#==================================================
module_verify() {
    log_step "模块5: 验证与日志"
    
    sleep 2
    ALL_OK=true
    
    if [ "$HAS_IPV4" = true ]; then
        log_info "DNS 解析测试 (IPv4)..."
        for domain in google.com cloudflare.com; do
            RESULT=$(dns_query "$domain" 127.0.0.1)
            if echo "$RESULT" | grep -q "Address"; then
                IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
                log_ok "$domain → $IP"
            else
                log_err "$domain 解析失败"
                ALL_OK=false
            fi
        done
    else
        log_info "跳过 IPv4 解析测试（纯 IPv6 环境）"
    fi
    
    if [ "$HAS_IPV6" = true ]; then
        log_info "DNS 解析测试 (IPv6)..."
        RESULT=$(dns_query "ipv6.google.com" "::1")
        if echo "$RESULT" | grep -q "Address"; then
            IP=$(echo "$RESULT" | grep "Address" | tail -1 | awk '{print $NF}')
            log_ok "ipv6.google.com → $IP"
        else
            log_warn "ipv6.google.com 解析失败"
        fi
    fi
    
    if [ "$IS_VER_NEW" = true ]; then
        echo ""
        log_info "DoH 连通性测试..."
        if [ "$HAS_IPV4" = true ]; then
            for item in "Google|https://dns.google/dns-query" "Cloudflare|https://cloudflare-dns.com/dns-query"; do
                NAME="${item%%|*}"; URL="${item##*|}"
                RESULT=$(curl -s --max-time 5 -H "accept: application/dns-json" "${URL}?name=google.com&type=A" 2>&1)
                if echo "$RESULT" | grep -q '"Status":\s*0'; then
                    log_ok "$NAME DoH (IPv4) 正常"
                else
                    log_warn "$NAME DoH (IPv4) 可能受限"
                fi
            done
        fi
        if [ "$HAS_IPV6" = true ]; then
            for item in "Google|https://[2001:4860:4860::8888]/dns-query" "Cloudflare|https://[2606:4700:4700::1111]/dns-query"; do
                NAME="${item%%|*}"; URL="${item##*|}"
                RESULT=$(curl -s --max-time 5 -H "accept: application/dns-json" "${URL}?name=google.com&type=AAAA" 2>&1)
                if echo "$RESULT" | grep -q '"Status":\s*0'; then
                    log_ok "$NAME DoH (IPv6) 正常"
                else
                    log_warn "$NAME DoH (IPv6) 可能受限"
                fi
            done
        fi
        
        echo ""
        log_info "DoT 端口测试..."
        if [ "$HAS_IPV4" = true ]; then
            for item in "Google|8.8.8.8|853" "Cloudflare|1.1.1.1|853"; do
                NAME="${item%%|*}"; REST="${item#*|}"; IP="${REST%%|*}"; DPORT="${REST##*|}"
                if command -v nc >/dev/null 2>&1 && nc -z -w 3 "$IP" "$DPORT" 2>/dev/null; then
                    log_ok "$NAME DoT (IPv4) 端口可达"
                else
                    log_warn "$NAME DoT (IPv4) 端口不可达"
                fi
            done
        fi
        if [ "$HAS_IPV6" = true ]; then
            for item in "Google|2001:4860:4860::8844|853" "Cloudflare|2606:4700:4700::1001|853"; do
                NAME="${item%%|*}"; REST="${item#*|}"; IP="${REST%%|*}"; DPORT="${REST##*|}"
                if command -v nc >/dev/null 2>&1 && nc -z -w 3 "$IP" "$DPORT" 2>/dev/null; then
                    log_ok "$NAME DoT (IPv6) 端口可达"
                else
                    log_warn "$NAME DoT (IPv6) 端口不可达"
                fi
            done
        fi
    fi
    
    {
        echo ""
        echo "===== SmartDNS 部署日志 ====="
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "系统: $OS_TYPE $OS_VER | Init: $INIT_TYPE | 虚拟化: $VIRT_TYPE"
        echo "网络栈: $NET_STACK | 接管策略: $TAKEOVER_STRATEGY"
        echo "版本: $SMARTDNS_VER ($SMARTDNS_SOURCE) | 端口: $PORT"
        echo "模板: $RESOLV_TEMPLATE"
        echo "守护: inotify=${INOTIFY_CMD:-轮询}"
        echo "=============================="
    } >> "$DEPLOY_LOG"
    
    echo ""
    printf "%b\n" "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
    if [ "$ALL_OK" = true ]; then
        printf "%b\n" "${GREEN}${BOLD}║ ✓ SmartDNS 部署成功                ║${NC}"
    else
        printf "%b\n" "${YELLOW}${BOLD}║ ⚠ 部分域名解析异常                 ║${NC}"
    fi
    printf "%b\n" "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}部署摘要:${NC}"
    echo -e "  系统: ${CYAN}$OS_TYPE $OS_VER ($VIRT_TYPE)${NC}"
    echo -e "  策略: ${CYAN}$TAKEOVER_STRATEGY${NC}"
    echo -e "  版本: ${CYAN}$SMARTDNS_VER${NC}"
    echo -e "  端口: ${CYAN}127.0.0.1:${PORT}${NC}"
    echo -e "  上游: ${GREEN}Google + Cloudflare (DoH/DoT + UDP自动降级)${NC}"
    echo -e "  守护: ${GREEN}${INOTIFY_CMD:-轮询} + 启动覆盖${NC}"
    echo -e "  模板: ${CYAN}$RESOLV_TEMPLATE${NC}"
    echo ""
    if [ "$HAS_IPV4" = true ]; then echo -e "  nslookup google.com 127.0.0.1"; fi
    if [ "$HAS_IPV6" = true ]; then echo -e "  nslookup google.com ::1"; fi
    echo -e "  tail -f /var/log/smartdns.log"
}

#==================================================
# 模块6: 卸载
#==================================================
module_uninstall() {
    echo ""; echo -e "${YELLOW}卸载 SmartDNS...${NC}"
    
    if [ -z "$INIT_TYPE" ]; then
        if [ -d /run/systemd/system ]; then INIT_TYPE="systemd"
        elif [ -f /sbin/openrc ]; then INIT_TYPE="openrc"
        else INIT_TYPE="none"; fi
    fi
    
    if [ -f "$PID_FILE" ]; then
        GUARD_PID=$(cat "$PID_FILE" 2>/dev/null)
        [ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    pkill -f "^/usr/local/bin/smartdns-dns-guard\.sh" 2>/dev/null
    
    case "$INIT_TYPE" in
        systemd)
            systemctl stop smartdns.service smartdns-dns-guard.service smartdns-dns-fix.service 2>/dev/null
            systemctl disable smartdns.service smartdns-dns-guard.service smartdns-dns-fix.service 2>/dev/null
            rm -f /etc/systemd/system/smartdns.service /etc/systemd/system/smartdns-dns-guard.service /etc/systemd/system/smartdns-dns-fix.service
            systemctl daemon-reload 2>/dev/null
            if systemctl is-enabled systemd-resolved 2>/dev/null | grep -q "masked"; then
                systemctl unmask systemd-resolved 2>/dev/null
            fi
            if ! systemctl is-active systemd-resolved >/dev/null 2>&1; then
                systemctl enable systemd-resolved 2>/dev/null
                systemctl start systemd-resolved 2>/dev/null
            fi
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null
            rc-update del smartdns 2>/dev/null
            rm -f /etc/init.d/smartdns
            rm -f /etc/local.d/smartdns-dns.start /etc/local.d/smartdns-guard.start
            ;;
    esac
    
    pkill smartdns 2>/dev/null
    sleep 1
    
    rm -f "$GUARD_SCRIPT" "$RESOLV_BACKUP"
    rm -f /etc/cloud/cloud.cfg.d/99-smartdns-dns.cfg
    
    if [ -f /etc/tmpfiles.d/systemd-resolved.conf ] && grep -q "SmartDNS" /etc/tmpfiles.d/systemd-resolved.conf 2>/dev/null; then
        rm -f /etc/tmpfiles.d/systemd-resolved.conf
    fi
    
    if crontab -l 2>/dev/null | grep -q "resolv-check\|smartdns"; then
        crontab -l 2>/dev/null | grep -v "resolv-check\|smartdns" | crontab - 2>/dev/null
    fi
    
    BAK=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
    if [ -n "$BAK" ]; then
        cp "$BAK" /etc/resolv.conf
    elif [ -f "$RESOLV_FALLBACK" ]; then
        cat "$RESOLV_FALLBACK" > /etc/resolv.conf
    else
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    fi
    log_ok "DNS 已恢复"
    
    rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log* "$DEPLOY_LOG"
    apt-get remove -y smartdns 2>/dev/null
    apk del smartdns 2>/dev/null
    
    log_ok "卸载完成"
}

main() {
    for arg in "$@"; do
        case "$arg" in
            --uninstall|-u)
                module_uninstall
                exit 0
                ;;
        esac
    done
    
    echo ""
    echo -e "${BOLD}SmartDNS 智能部署 v6.4.10${NC}"
    echo -e "上游: Google + Cloudflare (DoH/DoT/UDP)"
    echo -e "环境: Alpine/Debian (LXC/KVM/Podman)"
    echo ""
    
    module_detect
    module_install
    module_config
    module_dns_takeover
    module_service
    module_verify
    
    echo ""
    echo -e "卸载命令: ${GREEN}wget -qO- URL | bash -s -- --uninstall${NC}"
}

main "$@"
