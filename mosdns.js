#!/bin/sh
set -e

# ============================================
# 模块1: 变量和颜色定义
# ============================================
INSTALL_DIR="/opt/mosdns"
BIN_PATH="$INSTALL_DIR/mosdns"
CONFIG_PATH="$INSTALL_DIR/config.yaml"
LOG_DIR="/var/log/mosdns"
LOG_FILE="$LOG_DIR/mosdns.log"
SERVICE_NAME="mosdns"
VERSION="v5.3.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# ============================================
# 模块2: 环境检测
# ============================================
detect_os() {
    if [ -f /etc/os-release ]; then
        OS=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        VER=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        VER=$(cat /etc/alpine-release)
    else
        log_error "不支持的操作系统"
        exit 1
    fi
    
    case "$OS" in
        debian|ubuntu|raspbian)
            OS="debian"
            ;;
        alpine)
            OS="alpine"
            ;;
        *)
            log_error "不支持的操作系统: $OS"
            exit 1
            ;;
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
        mips64)        MOSDNS_ARCH="mips64" ;;
        riscv64)       MOSDNS_ARCH="riscv64" ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    log_info "检测到架构: $ARCH -> $MOSDNS_ARCH"
}

detect_network_stack() {
    IPV4_OK=false
    IPV6_OK=false
    
    # 检测IPv4连接
    HTTP_CODE=$(curl -4 -s --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" https://1.1.1.1 2>/dev/null || echo "000")
    case "$HTTP_CODE" in
        2*|3*) IPV4_OK=true ;;
    esac
    
    # 检测IPv6连接
    HTTP_CODE=$(curl -6 -s --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" https://[2606:4700:4700::1111] 2>/dev/null || echo "000")
    case "$HTTP_CODE" in
        2*|3*) IPV6_OK=true ;;
    esac
    
    if $IPV4_OK && $IPV6_OK; then
        NETWORK_STACK="dual"
        log_info "检测到双栈网络环境"
    elif $IPV4_OK; then
        NETWORK_STACK="ipv4"
        log_info "检测到纯IPv4网络环境"
    elif $IPV6_OK; then
        NETWORK_STACK="ipv6"
        log_info "检测到纯IPv6网络环境"
    else
        log_error "无可用网络连接"
        exit 1
    fi
}

# ============================================
# 模块3: 依赖检测和安装
# ============================================
install_dependencies() {
    log_info "检测并安装依赖..."
    
    MISSING_DEPS=""
    
    for dep in curl unzip; do
        if ! command -v $dep >/dev/null 2>&1; then
            MISSING_DEPS="$MISSING_DEPS $dep"
        fi
    done
    
    if ! command -v ip >/dev/null 2>&1 && ! command -v ifconfig >/dev/null 2>&1; then
        MISSING_DEPS="$MISSING_DEPS iproute2"
    fi
    
    # 去除前导空格
    MISSING_DEPS=$(echo "$MISSING_DEPS" | sed 's/^ *//')
    
    if [ -z "$MISSING_DEPS" ]; then
        log_info "所有依赖已安装"
        return 0
    fi
    
    log_warn "缺少依赖: $MISSING_DEPS"
    
    case "$OS" in
        debian)
            apt-get update -qq
            for dep in $MISSING_DEPS; do
                case "$dep" in
                    curl) apt-get install -y -qq curl ;;
                    unzip) apt-get install -y -qq unzip ;;
                    iproute2) apt-get install -y -qq iproute2 ;;
                esac
            done
            ;;
        alpine)
            apk update >/dev/null 2>&1
            for dep in $MISSING_DEPS; do
                case "$dep" in
                    curl) apk add curl ;;
                    unzip) apk add unzip ;;
                    iproute2) apk add iproute2 ;;
                esac
            done
            ;;
    esac
    
    log_info "依赖安装完成"
}

# ============================================
# 模块4: 下载和安装mosdns
# ============================================
install_mosdns() {
    log_info "开始安装 mosdns $VERSION..."
    
    DOWNLOAD_URL="https://github.com/IrineSistiana/mosdns/releases/download/${VERSION}/mosdns-linux-${MOSDNS_ARCH}.zip"
    WORK_DIR="/tmp/mosdns_install_$$"
    
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR" "$INSTALL_DIR"
    
    log_info "下载 mosdns..."
    if ! curl -L --connect-timeout 10 --retry 3 --max-time 60 -o "$WORK_DIR/mosdns.zip" "$DOWNLOAD_URL"; then
        log_error "下载失败: $DOWNLOAD_URL"
        rm -rf "$WORK_DIR"
        exit 1
    fi
    
    # 检查文件大小，避免下载到空文件或HTML错误页
    FILE_SIZE=$(stat -c%s "$WORK_DIR/mosdns.zip" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -lt 1024 ]; then
        log_error "下载的文件太小(${FILE_SIZE}字节)，可能下载失败"
        rm -rf "$WORK_DIR"
        exit 1
    fi
    
    # 验证zip文件
    if ! unzip -t -q "$WORK_DIR/mosdns.zip" >/dev/null 2>&1; then
        log_error "下载的文件不是有效的zip包"
        rm -rf "$WORK_DIR"
        exit 1
    fi
    
    log_info "解压文件..."
    mkdir -p "$WORK_DIR/extracted"
    if ! unzip -o -q "$WORK_DIR/mosdns.zip" -d "$WORK_DIR/extracted"; then
        log_error "解压失败"
        rm -rf "$WORK_DIR"
        exit 1
    fi
    
    # 查找二进制文件，排除常见非二进制文件
    BINARY=$(find "$WORK_DIR/extracted" -type f \( -name "mosdns" -o -name "mosdns-*" \) ! -name "*.zip" ! -name "*.md" ! -name "*.txt" ! -name "*.yaml" ! -name "*.yml" ! -name "*.json" ! -name "*.toml" ! -name "LICENSE" ! -name "README*" 2>/dev/null | head -1)
    
    if [ -z "$BINARY" ]; then
        log_error "未找到 mosdns 二进制文件"
        log_error "解压内容:"
        find "$WORK_DIR/extracted" -type f 2>/dev/null | while read -r f; do
            printf "  %s (%s bytes)\n" "$f" "$(stat -c%s "$f" 2>/dev/null || echo 0)"
        done
        rm -rf "$WORK_DIR"
        exit 1
    fi
    
    cp "$BINARY" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    rm -rf "$WORK_DIR"
    
    if ! "$BIN_PATH" version >/dev/null 2>&1; then
        log_error "mosdns 二进制文件验证失败"
        exit 1
    fi
    
    log_info "mosdns 安装完成"
}

# ============================================
# 模块5: 生成配置文件
# ============================================
generate_config() {
    log_info "生成配置文件..."
    
    case "$NETWORK_STACK" in
        ipv4)
            CF_IPS="1.1.1.1 1.0.0.1"
            GOOGLE_IPS="8.8.8.8 8.8.4.4"
            CF_DOH="https://1.1.1.1/dns-query"
            CF_TLS="tls://1.1.1.1"
            GOOGLE_DOH="https://8.8.8.8/dns-query"
            GOOGLE_TLS="tls://8.8.8.8"
            LISTEN_ADDR="127.0.0.1:53"
            LISTEN_ADDR_V6=""
            ;;
        ipv6)
            CF_IPS="2606:4700:4700::1111 2606:4700:4700::1001"
            GOOGLE_IPS="2001:4860:4860::8888 2001:4860:4860::8844"
            CF_DOH="https://[2606:4700:4700::1111]/dns-query"
            CF_TLS="tls://[2606:4700:4700::1111]"
            GOOGLE_DOH="https://[2001:4860:4860::8888]/dns-query"
            GOOGLE_TLS="tls://[2001:4860:4860::8888]"
            LISTEN_ADDR="[::1]:53"
            LISTEN_ADDR_V6=""
            ;;
        dual)
            CF_IPS="1.1.1.1 2606:4700:4700::1111"
            GOOGLE_IPS="8.8.8.8 2001:4860:4860::8888"
            CF_DOH="https://cloudflare-dns.com/dns-query"
            CF_TLS="tls://cloudflare-dns.com"
            GOOGLE_DOH="https://dns.google/dns-query"
            GOOGLE_TLS="tls://dns.google"
            LISTEN_ADDR="127.0.0.1:53"
            LISTEN_ADDR_V6="[::1]:53"
            ;;
    esac
    
    # 备份旧配置
    if [ -f "$CONFIG_PATH" ]; then
        BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_PATH" "$BACKUP"
        log_info "已备份旧配置文件到 $BACKUP"
    fi
    
    # 生成配置文件头部（需要变量展开的部分）
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
EOF

    # Cloudflare普通DNS IP
    for ip in $CF_IPS; do
        echo "        - addr: \"$ip\"" >> "$CONFIG_PATH"
    done

    cat >> "$CONFIG_PATH" << EOF

  - tag: forward_google
    type: forward
    args:
      upstream:
        - addr: "${GOOGLE_DOH}"
          enable_http3: false
        - addr: "${GOOGLE_TLS}"
          enable_http3: false
EOF

    # Google普通DNS IP
    for ip in $GOOGLE_IPS; do
        echo "        - addr: \"$ip\"" >> "$CONFIG_PATH"
    done

    # 序列定义（使用单引号防止变量展开）
    cat >> "$CONFIG_PATH" << 'EOF'

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
      - exec: $concurrent_query

server:
EOF

    # 主监听地址
    cat >> "$CONFIG_PATH" << EOF
  - exec: main_sequence
    listener:
      addr: "${LISTEN_ADDR}"
      protocol: udp
    timeout: 5s

  - exec: main_sequence
    listener:
      addr: "${LISTEN_ADDR}"
      protocol: tcp
    timeout: 5s
EOF

    # 双栈IPv6监听
    if [ -n "${LISTEN_ADDR_V6:-}" ]; then
        cat >> "$CONFIG_PATH" << EOF

  - exec: main_sequence
    listener:
      addr: "${LISTEN_ADDR_V6}"
      protocol: udp
    timeout: 5s

  - exec: main_sequence
    listener:
      addr: "${LISTEN_ADDR_V6}"
      protocol: tcp
    timeout: 5s
EOF
    fi

    # 验证配置文件语法（如果test子命令不存在则跳过）
    if "$BIN_PATH" test -c "$CONFIG_PATH" >/dev/null 2>&1; then
        log_info "配置文件语法验证通过"
    else
        log_warn "无法验证配置文件语法（mosdns可能不支持test子命令）"
    fi
    
    chmod 644 "$CONFIG_PATH"
    log_info "配置文件生成完成"
}

# ============================================
# 模块6: 日志轮转配置
# ============================================
setup_logrotate() {
    log_info "配置日志轮转..."
    
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
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
    create 644 root root
}
EOF
                log_info "logrotate 配置完成"
            else
                log_warn "logrotate 未安装，使用备用方案"
                setup_fallback_logrotate
            fi
            ;;
        alpine)
            setup_fallback_logrotate
            ;;
    esac
}

setup_fallback_logrotate() {
    # Alpine使用/etc/periodic，Debian使用cron.daily
    if [ -d /etc/periodic/daily ]; then
        ROTATE_SCRIPT="/etc/periodic/daily/mosdns-logrotate"
    elif [ -d /etc/cron.daily ]; then
        ROTATE_SCRIPT="/etc/cron.daily/mosdns-logrotate"
    else
        mkdir -p /etc/cron.daily
        ROTATE_SCRIPT="/etc/cron.daily/mosdns-logrotate"
    fi
    
    cat > "$ROTATE_SCRIPT" << 'ALPINE'
#!/bin/sh
LOG_FILE="/var/log/mosdns/mosdns.log"
MAX_SIZE=10485760
MAX_FILES=7

if [ -f "$LOG_FILE" ]; then
    SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt "$MAX_SIZE" ]; then
        i=$((MAX_FILES - 1))
        while [ $i -ge 0 ]; do
            if [ -f "${LOG_FILE}.${i}" ]; then
                mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
            fi
            i=$((i - 1))
        done
        cp "$LOG_FILE" "${LOG_FILE}.0"
        truncate -s 0 "$LOG_FILE"
    fi
fi
ALPINE
    chmod +x "$ROTATE_SCRIPT"
    log_info "备用日志轮转方案配置完成 ($ROTATE_SCRIPT)"
}

# ============================================
# 模块7: 系统服务配置
# ============================================
setup_service() {
    log_info "配置系统服务..."
    
    # 先停止已有服务
    case "$OS" in
        debian)
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            # 删除旧的服务文件（如果存在）
            if [ -f /etc/systemd/system/${SERVICE_NAME}.service ]; then
                rm -f /etc/systemd/system/${SERVICE_NAME}.service
                systemctl daemon-reload
            fi
            ;;
        alpine)
            rc-service "$SERVICE_NAME" stop 2>/dev/null || true
            ;;
    esac
    
    case "$OS" in
        debian)
            cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=MosDNS DNS Server
Documentation=https://github.com/IrineSistiana/mosdns
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
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$LOG_DIR
ReadOnlyPaths=$INSTALL_DIR
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
            
            # 启动服务并检查
            if ! systemctl start "$SERVICE_NAME"; then
                log_error "systemd 服务启动失败"
                journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
                exit 1
            fi
            
            sleep 2
            if ! systemctl is-active --quiet "$SERVICE_NAME"; then
                log_error "systemd 服务未能保持运行"
                journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
                exit 1
            fi
            log_info "systemd 服务配置完成"
            ;;
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

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log/mosdns
    checkpath --file --mode 0644 /var/log/mosdns/mosdns.log
}
EOF
            chmod +x /etc/init.d/${SERVICE_NAME}
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
            
            # 启动服务并检查
            if ! rc-service "$SERVICE_NAME" start; then
                log_error "OpenRC 服务启动失败"
                tail -n 20 "$LOG_FILE" 2>/dev/null || true
                exit 1
            fi
            
            sleep 2
            if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
                log_error "OpenRC 服务未能保持运行"
                tail -n 20 "$LOG_FILE" 2>/dev/null || true
                exit 1
            fi
            log_info "OpenRC 服务配置完成"
            ;;
    esac
}

# ============================================
# 模块8: DNS接管和保护
# ============================================
setup_dns() {
    log_info "配置系统DNS保护..."
    
    case "$OS" in
        debian)
            # 处理systemd-resolved
            if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
                systemctl stop systemd-resolved
                systemctl disable systemd-resolved
                log_info "已停用 systemd-resolved"
            fi
            
            # 处理符号链接（systemd-resolved会将resolv.conf设为符号链接）
            if [ -L /etc/resolv.conf ]; then
                # 保存符号链接目标的真实路径
                REAL_RESOLV=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
                rm -f /etc/resolv.conf
                if [ -n "$REAL_RESOLV" ] && [ -f "$REAL_RESOLV" ]; then
                    cp "$REAL_RESOLV" /etc/resolv.conf.original 2>/dev/null || true
                fi
            fi
            
            # 备份原始配置（如果尚未备份且resolv.conf是普通文件）
            if [ ! -f /etc/resolv.conf.original ] && [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
                cp /etc/resolv.conf /etc/resolv.conf.original 2>/dev/null || true
                log_info "已备份原始 resolv.conf"
            fi
            
            # 配置resolv.conf
            if [ "$NETWORK_STACK" = "ipv6" ]; then
                cat > /etc/resolv.conf << 'EOF'
nameserver ::1
options timeout:2
options attempts:3
EOF
            elif [ "$NETWORK_STACK" = "dual" ]; then
                cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
options timeout:2
options attempts:3
EOF
            else
                cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
options timeout:2
options attempts:3
EOF
            fi
            
            # resolvconf
            if command -v resolvconf >/dev/null 2>&1; then
                printf "nameserver 127.0.0.1\n" | resolvconf -a lo.mosdns 2>/dev/null || true
                if [ "$NETWORK_STACK" != "ipv4" ]; then
                    printf "nameserver ::1\n" | resolvconf -a lo.mosdns 2>/dev/null || true
                fi
            fi
            
            # NetworkManager
            if [ -d /etc/NetworkManager/conf.d ]; then
                cat > /etc/NetworkManager/conf.d/90-mosdns-dns.conf << 'EOF'
[main]
dns=none
systemd-resolved=false
EOF
                if systemctl is-active --quiet NetworkManager 2>/dev/null; then
                    systemctl reload NetworkManager 2>/dev/null || true
                fi
                log_info "NetworkManager DNS配置已更新"
            fi
            
            # dhclient
            if [ -f /etc/dhcp/dhclient.conf ]; then
                if ! grep -q "^supersede domain-name-servers 127.0.0.1;" /etc/dhcp/dhclient.conf 2>/dev/null; then
                    echo "supersede domain-name-servers 127.0.0.1;" >> /etc/dhcp/dhclient.conf
                    if [ "$NETWORK_STACK" != "ipv4" ]; then
                        echo "prepend domain-name-servers ::1;" >> /etc/dhcp/dhclient.conf
                    fi
                    log_info "dhclient DNS配置已更新"
                fi
            fi
            
            # netplan
            if [ -d /etc/netplan ] && command -v netplan >/dev/null 2>&1; then
                if [ "$NETWORK_STACK" != "ipv4" ]; then
                    cat > /etc/netplan/90-mosdns-dns.yaml << 'EOF'
network:
  version: 2
  ethernets:
    all:
      nameservers:
        addresses: [127.0.0.1, "::1"]
EOF
                else
                    cat > /etc/netplan/90-mosdns-dns.yaml << 'EOF'
network:
  version: 2
  ethernets:
    all:
      nameservers:
        addresses: [127.0.0.1]
EOF
                fi
                netplan apply 2>/dev/null || true
                log_info "netplan DNS配置已更新"
            fi
            ;;
            
        alpine)
            # 备份原始配置
            if [ ! -f /etc/resolv.conf.original ] && [ -f /etc/resolv.conf ]; then
                cp /etc/resolv.conf /etc/resolv.conf.original 2>/dev/null || true
            fi
            
            # 配置resolv.conf
            if [ "$NETWORK_STACK" = "ipv6" ]; then
                cat > /etc/resolv.conf << 'EOF'
nameserver ::1
EOF
            elif [ "$NETWORK_STACK" = "dual" ]; then
                cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
EOF
            else
                cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
EOF
            fi
            
            # udhcpc
            if [ -f /etc/udhcpc/udhcpc.conf ]; then
                if grep -q "^RESOLV_CONF=" /etc/udhcpc/udhcpc.conf 2>/dev/null; then
                    sed -i 's/^RESOLV_CONF=.*/RESOLV_CONF="NO"/' /etc/udhcpc/udhcpc.conf
                else
                    echo 'RESOLV_CONF="NO"' >> /etc/udhcpc/udhcpc.conf
                fi
                log_info "udhcpc DNS配置已更新"
            fi
            
            # 接口脚本（防止DHCP客户端覆盖DNS）
            mkdir -p /etc/network/if-up.d
            cat > /etc/network/if-up.d/mosdns-dns << 'ALPINEDNS'
#!/bin/sh
# 仅在非回环接口且原始配置存在时执行
if [ "$IFACE" != "lo" ] && [ -f /etc/resolv.conf.original ]; then
    cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
EOF
    if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
        echo "nameserver ::1" >> /etc/resolv.conf
    fi
fi
ALPINEDNS
            chmod +x /etc/network/if-up.d/mosdns-dns
            ;;
    esac
    
    log_info "DNS保护配置完成"
}

# ============================================
# 模块9: 验证安装
# ============================================
verify_installation() {
    log_info "验证安装..."
    
    sleep 2
    
    PID=$(pgrep -x mosdns 2>/dev/null || true)
    if [ -z "$PID" ]; then
        log_error "mosdns 进程未运行"
        log_error "请查看日志: $LOG_FILE"
        return 1
    fi
    log_info "mosdns 进程运行正常 (PID: $PID)"
    
    # 测试DNS查询，按优先级尝试不同工具
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup cloudflare.com 127.0.0.1 >/dev/null 2>&1; then
            log_info "DNS查询测试成功 (nslookup)"
            return 0
        fi
    fi
    
    if command -v host >/dev/null 2>&1; then
        if host cloudflare.com 127.0.0.1 >/dev/null 2>&1; then
            log_info "DNS查询测试成功 (host)"
            return 0
        fi
    fi
    
    if command -v dig >/dev/null 2>&1; then
        if dig @127.0.0.1 +short cloudflare.com >/dev/null 2>&1; then
            log_info "DNS查询测试成功 (dig)"
            return 0
        fi
    fi
    
    # 所有工具都不可用，提示手动测试
    if ! command -v nslookup >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1 && ! command -v dig >/dev/null 2>&1; then
        log_warn "未找到DNS测试工具，跳过验证"
        log_warn "建议安装: bind9-host 或 dnsutils"
    else
        log_warn "DNS查询测试失败，请检查"
        log_warn "手动测试: nslookup cloudflare.com 127.0.0.1"
    fi
    return 0
}

# ============================================
# 模块10: 主函数
# ============================================
main() {
    echo "========================================"
    echo "   MosDNS 一键部署脚本"
    echo "   Version: $VERSION"
    echo "========================================"
    echo ""
    
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用root权限运行此脚本"
        exit 1
    fi
    
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
    echo ""
    log_info "配置文件: $CONFIG_PATH"
    log_info "日志文件: $LOG_FILE"
    echo ""
    log_info "管理命令:"
    case "$OS" in
        debian)
            echo "  systemctl status $SERVICE_NAME   # 查看状态"
            echo "  systemctl restart $SERVICE_NAME  # 重启服务"
            echo "  journalctl -u $SERVICE_NAME -f   # 查看日志"
            ;;
        alpine)
            echo "  rc-service $SERVICE_NAME status  # 查看状态"
            echo "  rc-service $SERVICE_NAME restart # 重启服务"
            echo "  tail -f $LOG_FILE                # 查看日志"
            ;;
    esac
    echo ""
    log_info "如需恢复原始DNS配置:"
    if [ -f /etc/resolv.conf.original ]; then
        echo "  cp /etc/resolv.conf.original /etc/resolv.conf"
    else
        echo "  原始配置未备份，请手动恢复"
    fi
    echo "========================================"
}

main "$@"
