#!/bin/sh
set -e

INSTALL_DIR="/opt/mosdns"
BIN_PATH="$INSTALL_DIR/mosdns"
CONFIG_PATH="$INSTALL_DIR/config.yaml"
LOG_DIR="/var/log/mosdns"
LOG_FILE="$LOG_DIR/mosdns.log"
SERVICE_NAME="mosdns"
VERSION="v5.3.1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

detect_os() {
    if [ -f /etc/os-release ]; then
        OS=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        VER=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"; VER=$(cat /etc/alpine-release)
    else
        log_error "不支持的操作系统"; exit 1
    fi
    case "$OS" in
        debian|ubuntu|raspbian) OS="debian" ;;
        alpine) OS="alpine" ;;
        *) log_error "不支持的操作系统: $OS"; exit 1 ;;
    esac
    [ -z "$VER" ] && VER="unknown"
    log_info "检测到系统: $OS $VER"
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  MOSDNS_ARCH="amd64" ;;
        aarch64|arm64) MOSDNS_ARCH="arm64" ;;
        armv7l|armv7)  MOSDNS_ARCH="armv7" ;;
        i386|i686)     MOSDNS_ARCH="386" ;;
        mips64el)      MOSDNS_ARCH="mips64le" ;;
        mips64)
            [ "$(printf '\0\1' | od -A n -t d2 | awk '{print $1}')" = "256" ] && MOSDNS_ARCH="mips64le" || MOSDNS_ARCH="mips64" ;;
        riscv64)       MOSDNS_ARCH="riscv64" ;;
        *) log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    log_info "检测到架构: $ARCH -> $MOSDNS_ARCH"
}

detect_network_stack() {
    IPV4_OK=false; IPV6_OK=false
    curl -4 -s --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" https://1.1.1.1 2>/dev/null | grep -q '^[23]' && IPV4_OK=true
    curl -6 -s --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" https://cloudflare.com 2>/dev/null | grep -q '^[23]' && IPV6_OK=true
    if $IPV4_OK && $IPV6_OK; then NETWORK_STACK="dual"; log_info "检测到双栈网络环境"
    elif $IPV4_OK; then NETWORK_STACK="ipv4"; log_info "检测到纯IPv4网络环境"
    elif $IPV6_OK; then NETWORK_STACK="ipv6"; log_info "检测到纯IPv6网络环境"
    else log_error "无可用网络连接"; exit 1; fi
}

install_dependencies() {
    log_info "检测并安装依赖..."
    MISSING_DEPS=""
    for dep in curl unzip; do command -v $dep >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS $dep"; done
    (command -v ip >/dev/null 2>&1 || command -v ifconfig >/dev/null 2>&1) || MISSING_DEPS="$MISSING_DEPS iproute2"
    MISSING_DEPS=$(echo "$MISSING_DEPS" | sed 's/^ *//')
    [ -z "$MISSING_DEPS" ] && { log_info "所有依赖已安装"; return 0; }
    log_warn "缺少依赖: $MISSING_DEPS"
    set +e
    case "$OS" in
        debian)
            apt-get update -qq 2>/dev/null
            for dep in $MISSING_DEPS; do
                case "$dep" in curl) apt-get install -y -qq curl 2>/dev/null ;; unzip) apt-get install -y -qq unzip 2>/dev/null ;; iproute2) apt-get install -y -qq iproute2 2>/dev/null ;; esac
            done ;;
        alpine)
            apk update >/dev/null 2>&1
            for dep in $MISSING_DEPS; do
                case "$dep" in curl) apk add curl 2>/dev/null ;; unzip) apk add unzip 2>/dev/null ;; iproute2) apk add iproute2 2>/dev/null ;; esac
            done ;;
    esac
    set -e
    for dep in $MISSING_DEPS; do
        case "$dep" in
            curl|unzip) command -v $dep >/dev/null 2>&1 || { log_error "依赖 $dep 安装失败"; exit 1; } ;;
            iproute2) command -v ip >/dev/null 2>&1 || { log_error "依赖 iproute2 安装失败"; exit 1; } ;;
        esac
    done
    log_info "依赖安装完成"
}

install_mosdns() {
    log_info "开始安装 mosdns $VERSION..."
    DOWNLOAD_URL="https://github.com/IrineSistiana/mosdns/releases/download/${VERSION}/mosdns-linux-${MOSDNS_ARCH}.zip"
    WORK_DIR="/tmp/mosdns_install_$$"
    rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR" "$INSTALL_DIR"
    log_info "下载 mosdns..."
    curl -L --connect-timeout 10 --retry 3 --max-time 60 -o "$WORK_DIR/mosdns.zip" "$DOWNLOAD_URL" || { log_error "下载失败"; rm -rf "$WORK_DIR"; exit 1; }
    FILE_SIZE=$(stat -c%s "$WORK_DIR/mosdns.zip" 2>/dev/null || echo 0)
    [ "$FILE_SIZE" -lt 1024 ] && { log_error "下载的文件太小"; rm -rf "$WORK_DIR"; exit 1; }
    unzip -t -q "$WORK_DIR/mosdns.zip" >/dev/null 2>&1 || { log_error "无效zip包"; rm -rf "$WORK_DIR"; exit 1; }
    log_info "解压文件..."
    mkdir -p "$WORK_DIR/extracted"
    unzip -o -q "$WORK_DIR/mosdns.zip" -d "$WORK_DIR/extracted" || { log_error "解压失败"; rm -rf "$WORK_DIR"; exit 1; }
    BINARY=$(find "$WORK_DIR/extracted" -type f -executable ! -name "*.zip" ! -name "*.md" ! -name "*.txt" ! -name "*.yaml" ! -name "*.yml" ! -name "*.json" ! -name "*.toml" ! -name "LICENSE" ! -name "README*" -name "mosdns*" 2>/dev/null | head -1)
    [ -z "$BINARY" ] && { log_error "未找到二进制文件"; rm -rf "$WORK_DIR"; exit 1; }
    cp "$BINARY" "$BIN_PATH"; chmod +x "$BIN_PATH"
    rm -rf "$WORK_DIR"
    "$BIN_PATH" version >/dev/null 2>&1 || { log_error "二进制验证失败"; exit 1; }
    log_info "mosdns 安装完成"
}

generate_config() {
    log_info "生成配置文件..."
    case "$NETWORK_STACK" in
        ipv4)
            CF_IPS="1.1.1.1 1.0.0.1"; GOOGLE_IPS="8.8.8.8 8.8.4.4"
            CF_DOH="https://1.1.1.1/dns-query"; CF_TLS="tls://1.1.1.1"
            GOOGLE_DOH="https://8.8.8.8/dns-query"; GOOGLE_TLS="tls://8.8.8.8"
            LISTEN_ADDR="127.0.0.1:53"; LISTEN_ADDR_V6=""
            ;;
        ipv6)
            CF_IPS="2606:4700:4700::1111 2606:4700:4700::1001"; GOOGLE_IPS="2001:4860:4860::8888 2001:4860:4860::8844"
            CF_DOH="https://[2606:4700:4700::1111]/dns-query"; CF_TLS="tls://[2606:4700:4700::1111]"
            GOOGLE_DOH="https://[2001:4860:4860::8888]/dns-query"; GOOGLE_TLS="tls://[2001:4860:4860::8888]"
            LISTEN_ADDR="[::1]:53"; LISTEN_ADDR_V6=""
            ;;
        dual)
            CF_IPS="1.1.1.1 2606:4700:4700::1111"; GOOGLE_IPS="8.8.8.8 2001:4860:4860::8888"
            CF_DOH="https://cloudflare-dns.com/dns-query"; CF_TLS="tls://cloudflare-dns.com"
            GOOGLE_DOH="https://dns.google/dns-query"; GOOGLE_TLS="tls://dns.google"
            LISTEN_ADDR="127.0.0.1:53"; LISTEN_ADDR_V6="[::1]:53"
            ;;
    esac

    # 预生成 IP 列表
    CF_IP_LINES=""; for ip in $CF_IPS; do CF_IP_LINES="${CF_IP_LINES}        - addr: \"$ip\"\n"; done
    GOOGLE_IP_LINES=""; for ip in $GOOGLE_IPS; do GOOGLE_IP_LINES="${GOOGLE_IP_LINES}        - addr: \"$ip\"\n"; done

    [ -f "$CONFIG_PATH" ] && cp "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"

    # 直接生成完整配置（无 server/servers 顶层键）
    cat > "$CONFIG_PATH" << EOF
log:
  level: info
  file: "$LOG_FILE"

plugins:
  - tag: cache
    type: cache
    args:
      size: 4096
      lazy_cache_ttl: 86400

  - tag: forward_cf
    type: forward
    args:
      upstream:
        - addr: "${CF_DOH}"
          enable_http3: false
        - addr: "${CF_TLS}"
          enable_http3: false
$(printf "$CF_IP_LINES")
  - tag: forward_google
    type: forward
    args:
      upstream:
        - addr: "${GOOGLE_DOH}"
          enable_http3: false
        - addr: "${GOOGLE_TLS}"
          enable_http3: false
$(printf "$GOOGLE_IP_LINES")
  - tag: concurrent_query
    type: concurrent
    args:
      exec:
        - forward_cf
        - forward_google

  - tag: main_sequence
    type: sequence
    args:
      - exec: cache
      - exec: \$concurrent_query

  # 使用 server 插件监听
  - tag: udp_server
    type: server
    args:
      entry: main_sequence
      server:
        addr: "${LISTEN_ADDR}"
        protocol: udp

  - tag: tcp_server
    type: server
    args:
      entry: main_sequence
      server:
        addr: "${LISTEN_ADDR}"
        protocol: tcp
EOF

    if [ -n "${LISTEN_ADDR_V6:-}" ]; then
        cat >> "$CONFIG_PATH" << EOF

  - tag: udp6_server
    type: server
    args:
      entry: main_sequence
      server:
        addr: "${LISTEN_ADDR_V6}"
        protocol: udp

  - tag: tcp6_server
    type: server
    args:
      entry: main_sequence
      server:
        addr: "${LISTEN_ADDR_V6}"
        protocol: tcp
EOF
    fi

    chmod 644 "$CONFIG_PATH"
    log_info "配置文件生成完成"
}

setup_logrotate() {
    log_info "配置日志轮转..."
    mkdir -p "$LOG_DIR"; touch "$LOG_FILE"; chmod 644 "$LOG_FILE"
    if id nobody >/dev/null 2>&1; then
        if getent group nogroup >/dev/null 2>&1; then
            chown nobody:nogroup "$LOG_DIR" "$LOG_FILE" 2>/dev/null || true
        elif getent group nobody >/dev/null 2>&1; then
            chown nobody:nobody "$LOG_DIR" "$LOG_FILE" 2>/dev/null || true
        fi
    fi
    case "$OS" in
        debian)
            if command -v logrotate >/dev/null 2>&1; then
                cat > /etc/logrotate.d/mosdns << 'EOF'
/var/log/mosdns/mosdns.log {
    daily
    rotate 7
    maxsize 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 644 nobody nogroup
}
EOF
                log_info "logrotate 配置完成"
            else
                setup_fallback_logrotate
            fi ;;
        alpine) setup_fallback_logrotate ;;
    esac
}

setup_fallback_logrotate() {
    if [ -d /etc/periodic/daily ]; then ROTATE_SCRIPT="/etc/periodic/daily/mosdns-logrotate"
    elif [ -d /etc/cron.daily ]; then ROTATE_SCRIPT="/etc/cron.daily/mosdns-logrotate"
    else mkdir -p /etc/cron.daily; ROTATE_SCRIPT="/etc/cron.daily/mosdns-logrotate"; fi
    cat > "$ROTATE_SCRIPT" << 'ALPINE'
#!/bin/sh
LOG_FILE="/var/log/mosdns/mosdns.log"; MAX_SIZE=10485760; MAX_FILES=7
[ -f "$LOG_FILE" ] || exit 0
SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
[ "$SIZE" -gt "$MAX_SIZE" ] || exit 0
LOCK_FILE="${LOG_FILE}.lock"
( flock -x 9 || exit 0
  i=$((MAX_FILES - 1))
  while [ $i -ge 0 ]; do
    [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    i=$((i - 1))
  done
  cp "$LOG_FILE" "${LOG_FILE}.0"
  truncate -s 0 "$LOG_FILE"
) 9>"$LOCK_FILE"
ALPINE
    chmod +x "$ROTATE_SCRIPT"
    log_info "备用日志轮转配置完成 ($ROTATE_SCRIPT)"
}

setup_service() {
    log_info "配置系统服务..."
    set +e
    case "$OS" in
        debian) systemctl stop "$SERVICE_NAME" 2>/dev/null; rm -f /etc/systemd/system/${SERVICE_NAME}.service; systemctl daemon-reload 2>/dev/null ;;
        alpine) rc-service "$SERVICE_NAME" stop 2>/dev/null ;;
    esac
    set -e

    case "$OS" in
        debian)
            cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=MosDNS DNS Server
After=network.target network-online.target
Wants=network.target network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH start -c $CONFIG_PATH
Restart=always
RestartSec=5
User=nobody
Group=nogroup
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$LOG_DIR $INSTALL_DIR
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload; systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
            systemctl start "$SERVICE_NAME" || { log_error "systemd 启动失败"; journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null; exit 1; }
            sleep 2
            systemctl is-active --quiet "$SERVICE_NAME" || { log_error "服务未保持运行"; exit 1; }
            log_info "systemd 服务配置完成" ;;
        alpine)
            cat > /etc/init.d/${SERVICE_NAME} << EOF
#!/sbin/openrc-run
name="mosdns"
description="MosDNS DNS Server"
command="$BIN_PATH"
command_args="start -c $CONFIG_PATH"
command_background=true
pidfile="/var/run/\${RC_SVCNAME}.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /var/log/mosdns; checkpath --file --mode 0644 /var/log/mosdns/mosdns.log; }
EOF
            chmod +x /etc/init.d/${SERVICE_NAME}
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
            rc-service "$SERVICE_NAME" start || { log_error "OpenRC 启动失败"; tail -n 20 "$LOG_FILE"; exit 1; }
            sleep 2
            rc-service "$SERVICE_NAME" status >/dev/null 2>&1 || { log_error "服务未保持运行"; tail -n 20 "$LOG_FILE"; exit 1; }
            log_info "OpenRC 服务配置完成" ;;
    esac
}

setup_dns() {
    log_info "配置系统DNS保护..."
    if command -v cloud-init >/dev/null 2>&1 && cloud-init status 2>/dev/null | grep -q "running\|done"; then
        mkdir -p /etc/cloud/cloud.cfg.d
        echo "manage_resolv_conf: false" > /etc/cloud/cloud.cfg.d/99-mosdns-dns.cfg
    fi
    case "$OS" in
        debian)
            systemctl is-active --quiet systemd-resolved 2>/dev/null && { systemctl stop systemd-resolved; systemctl disable systemd-resolved; log_info "已停用 systemd-resolved"; }
            [ -L /etc/resolv.conf ] && { REAL_RESOLV=$(readlink -f /etc/resolv.conf); rm -f /etc/resolv.conf; [ -n "$REAL_RESOLV" ] && [ -f "$REAL_RESOLV" ] && cp "$REAL_RESOLV" /etc/resolv.conf.original; }
            [ ! -f /etc/resolv.conf.original ] && [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && { cp /etc/resolv.conf /etc/resolv.conf.original; log_info "已备份原始 resolv.conf"; }
            if [ "$NETWORK_STACK" = "ipv6" ]; then printf "nameserver ::1\noptions timeout:2\noptions attempts:3\n" > /etc/resolv.conf
            elif [ "$NETWORK_STACK" = "dual" ]; then printf "nameserver 127.0.0.1\nnameserver ::1\noptions timeout:2\noptions attempts:3\n" > /etc/resolv.conf
            else printf "nameserver 127.0.0.1\noptions timeout:2\noptions attempts:3\n" > /etc/resolv.conf; fi
            command -v resolvconf >/dev/null 2>&1 && { printf "nameserver 127.0.0.1\n" | resolvconf -a lo.mosdns 2>/dev/null; [ "$NETWORK_STACK" != "ipv4" ] && printf "nameserver ::1\n" | resolvconf -a lo.mosdns; }
            [ -d /etc/NetworkManager/conf.d ] && { printf "[main]\ndns=none\nsystemd-resolved=false\n" > /etc/NetworkManager/conf.d/90-mosdns-dns.conf; systemctl reload NetworkManager 2>/dev/null; }
            [ -f /etc/dhcp/dhclient.conf ] && ! grep -q "^supersede domain-name-servers 127.0.0.1;" /etc/dhcp/dhclient.conf 2>/dev/null && { echo "supersede domain-name-servers 127.0.0.1;" >> /etc/dhcp/dhclient.conf; [ "$NETWORK_STACK" != "ipv4" ] && echo "prepend domain-name-servers ::1;" >> /etc/dhcp/dhclient.conf; }
            [ -d /etc/netplan ] && command -v netplan >/dev/null 2>&1 && {
                if [ "$NETWORK_STACK" != "ipv4" ]; then printf "network:\n  version: 2\n  ethernets:\n    all:\n      nameservers:\n        addresses: [127.0.0.1, \"::1\"]\n" > /etc/netplan/90-mosdns-dns.yaml
                else printf "network:\n  version: 2\n  ethernets:\n    all:\n      nameservers:\n        addresses: [127.0.0.1]\n" > /etc/netplan/90-mosdns-dns.yaml; fi
                netplan apply 2>/dev/null; } ;;
        alpine)
            [ ! -f /etc/resolv.conf.original ] && [ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.original
            if [ "$NETWORK_STACK" = "ipv6" ]; then echo "nameserver ::1" > /etc/resolv.conf
            elif [ "$NETWORK_STACK" = "dual" ]; then printf "nameserver 127.0.0.1\nnameserver ::1\n" > /etc/resolv.conf
            else echo "nameserver 127.0.0.1" > /etc/resolv.conf; fi
            [ -f /etc/udhcpc/udhcpc.conf ] && { grep -q "^RESOLV_CONF=" /etc/udhcpc/udhcpc.conf 2>/dev/null && sed -i 's/^RESOLV_CONF=.*/RESOLV_CONF="NO"/' /etc/udhcpc/udhcpc.conf || echo 'RESOLV_CONF="NO"' >> /etc/udhcpc/udhcpc.conf; }
            mkdir -p /etc/network/if-up.d
            cat > /etc/network/if-up.d/mosdns-dns << 'ALPINEDNS'
#!/bin/sh
if [ "$IFACE" != "lo" ] && [ -f /etc/resolv.conf.original ]; then
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    ip -6 addr show scope global 2>/dev/null | grep -q inet6 && echo "nameserver ::1" >> /etc/resolv.conf
fi
ALPINEDNS
            chmod +x /etc/network/if-up.d/mosdns-dns ;;
    esac
    log_info "DNS保护配置完成"
}

verify_installation() {
    log_info "验证安装..."
    sleep 2
    PID=$(pgrep -x mosdns 2>/dev/null | head -1)
    [ -z "$PID" ] && { log_error "mosdns 未运行"; return 1; }
    log_info "mosdns 运行正常 (PID: $PID)"
    if command -v nslookup >/dev/null 2>&1 && timeout 5 nslookup cloudflare.com 127.0.0.1 >/dev/null 2>&1; then log_info "DNS测试成功"; return 0; fi
    if command -v host >/dev/null 2>&1 && timeout 5 host cloudflare.com 127.0.0.1 >/dev/null 2>&1; then log_info "DNS测试成功"; return 0; fi
    if command -v dig >/dev/null 2>&1 && timeout 5 dig @127.0.0.1 +short cloudflare.com >/dev/null 2>&1; then log_info "DNS测试成功"; return 0; fi
    log_warn "自动DNS验证未通过，请手动测试"
    return 0
}

main() {
    echo "========================================"
    echo "   MosDNS 一键部署脚本"
    echo "   Version: $VERSION"
    echo "========================================"
    [ "$(id -u)" -ne 0 ] && { log_error "请使用root权限运行"; exit 1; }
    detect_os || exit 1
    detect_arch || exit 1
    detect_network_stack || exit 1
    install_dependencies || exit 1
    install_mosdns || exit 1
    generate_config || exit 1
    setup_logrotate || exit 1
    setup_service || exit 1
    setup_dns || exit 1
    verify_installation || exit 1
    echo ""
    echo "========================================"
    log_info "MosDNS 部署完成！"
    echo "========================================"
}

main "$@"
