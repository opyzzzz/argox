#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 (修正版 v2.3)
# 功能: 自动检测环境 -> 安装稳定版 -> 动态配置
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
# 修复: GitHub Release 文件名格式 smartdns-{架构}
# 更新: 2026-05-11
#==================================================

set -e

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

#==================================================
# 工具函数
#==================================================

# 带重试的下载函数
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=3

    for i in $(seq 1 $max_retries); do
        if wget -q --timeout=30 --tries=3 -O "$output" "$url"; then
            return 0
        fi
        log_warn "下载失败，重试 $i/$max_retries ..."
        sleep 2
    done
    return 1
}

# 获取最新版本号（从 GitHub API）
get_latest_release_tag() {
    local api_url="https://api.github.com/repos/pymumu/smartdns/releases/latest"
    local tag

    if command -v curl >/dev/null 2>&1; then
        tag=$(curl -sL --max-time 10 "$api_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    else
        tag=$(wget -qO- --timeout=10 "$api_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi

    if [ -z "$tag" ]; then
        log_warn "无法获取最新版本号，尝试 Release47.1"
        echo "Release47.1"
    else
        echo "$tag"
    fi
}

# 架构映射 (GitHub Release 文件名格式: smartdns-{架构})
get_release_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l|armv7)   echo "arm" ;;
        armv6l)         echo "arm" ;;
        i386|i686)      echo "x86" ;;
        mips)           echo "mips" ;;
        mipsel)         echo "mipsel" ;;
        *)
            log_error "不支持的CPU架构: $(uname -m)"
            exit 1
            ;;
    esac
}

# 卸载函数
uninstall_smartdns() {
    log_step "开始卸载 SmartDNS..."

    # 停止服务
    if [ -n "$INIT" ]; then
        case "$INIT" in
            systemd)
                systemctl stop smartdns 2>/dev/null || true
                systemctl disable smartdns 2>/dev/null || true
                rm -f /etc/systemd/system/smartdns.service
                systemctl daemon-reload 2>/dev/null || true
                ;;
            openrc)
                rc-service smartdns stop 2>/dev/null || true
                rc-update del smartdns 2>/dev/null || true
                rm -f /etc/init.d/smartdns
                ;;
        esac
    fi

    pkill smartdns 2>/dev/null || true
    sleep 1

    # 恢复 resolv.conf
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi

    local latest_backup=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        cp "$latest_backup" /etc/resolv.conf
        log_info "已恢复 resolv.conf: $latest_backup"
    else
        cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
        log_warn "未找到备份，已写入默认 DNS"
    fi

    [ -f /etc/dhcpcd.conf ] && sed -i '/nohook resolv.conf/d' /etc/dhcpcd.conf
    rm -f /etc/NetworkManager/conf.d/99-smartdns.conf
    rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log*

    apk del smartdns 2>/dev/null || true
    apt-get remove -y smartdns 2>/dev/null || true

    log_info "SmartDNS 卸载完成"
    exit 0
}

#==================================================
# 依赖检查
#==================================================
check_dependencies() {
    log_step "检查基础依赖..."
    local missing=""

    for cmd in wget grep sed awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        log_warn "缺少依赖：$missing"
        case "$PKG_MANAGER" in
            apk) apk add --no-cache $missing ;;
            apt) apt-get update -qq && apt-get install -y -qq $missing ;;
        esac
    fi

    log_info "依赖检查完成"
}

#==================================================
# 第一步: 系统环境检测
#==================================================
detect_environment() {
    log_step "正在进行环境检测..."

    # 发行版
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
        VER=$(cat /etc/alpine-release)
    else
        log_error "无法识别的系统"
        exit 1
    fi

    case "$OS" in
        alpine)          PKG_MANAGER="apk" ;;
        debian|ubuntu)   PKG_MANAGER="apt" ;;
        *)
            log_error "不支持的发行版: $OS"
            exit 1
            ;;
    esac
    log_info "系统: $OS $VER ($PKG_MANAGER)"

    # Init 系统
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
    elif [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
        VIRT="openvz"
    else
        VIRT="kvm"
    fi
    log_info "虚拟化: $VIRT"

    # 网络
    if command -v ip >/dev/null 2>&1; then
        DEFAULT_IPV4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
        DEFAULT_IPV6=$(ip route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    else
        DEFAULT_IPV4=""; DEFAULT_IPV6=""
    fi

    if [ -n "$DEFAULT_IPV4" ]; then
        log_info "IPv4: $DEFAULT_IPV4"
    else
        log_warn "未检测到 IPv4"
    fi
    [ -n "$DEFAULT_IPV6" ] && log_info "IPv6: $DEFAULT_IPV6"
}

#==================================================
# 第二步: 安装 SmartDNS
#==================================================
install_smartdns() {
    log_step "安装 SmartDNS..."

    # --- 方法1: 包管理器 ---
    case "$PKG_MANAGER" in
        apt)
            log_info "尝试 apt 安装..."
            apt-get update -qq
            if apt-cache show smartdns >/dev/null 2>&1; then
                apt-get install -y -qq smartdns
                SMARTDNS_BIN=$(which smartdns 2>/dev/null || echo "/usr/sbin/smartdns")
                mkdir -p /etc/smartdns
                log_info "SmartDNS 安装完成 (apt): $SMARTDNS_BIN"
                return 0
            fi
            log_warn "apt 仓库中无 smartdns，使用 GitHub 下载"
            ;;
        apk)
            log_info "尝试 apk 安装..."
            apk update --quiet 2>/dev/null || true
            if apk search smartdns 2>/dev/null | grep -q "^smartdns"; then
                apk add --no-cache smartdns
                SMARTDNS_BIN=$(which smartdns 2>/dev/null || echo "/usr/sbin/smartdns")
                mkdir -p /etc/smartdns
                log_info "SmartDNS 安装完成 (apk): $SMARTDNS_BIN"
                return 0
            fi
            log_warn "apk 仓库中无 smartdns，使用 GitHub 下载"
            ;;
    esac

    # --- 方法2: GitHub Releases 下载 ---
    log_info "从 GitHub Releases 下载..."

    local RELEASE_TAG=$(get_latest_release_tag)
    local ARCH_NAME=$(get_release_arch)
    local FILE_NAME="smartdns-${ARCH_NAME}"
    local DOWNLOAD_URL="https://github.com/pymumu/smartdns/releases/download/${RELEASE_TAG}/${FILE_NAME}"

    log_info "版本: $RELEASE_TAG"
    log_info "架构: $ARCH_NAME"
    log_info "文件: $FILE_NAME"
    log_info "URL: $DOWNLOAD_URL"

    if ! download_with_retry "$DOWNLOAD_URL" "/tmp/smartdns"; then
        log_error "下载失败: $DOWNLOAD_URL"
        log_error "请访问 https://github.com/pymumu/smartdns/releases/latest 手动下载"
        exit 1
    fi

    # 验证文件
    if [ ! -s /tmp/smartdns ]; then
        log_error "下载的文件为空"
        exit 1
    fi

    # 安装
    chmod +x /tmp/smartdns
    mv /tmp/smartdns /usr/bin/smartdns
    SMARTDNS_BIN="/usr/bin/smartdns"

    # 容器权限
    if [ "$VIRT" = "docker" ] || [ "$VIRT" = "lxc" ]; then
        if command -v setcap >/dev/null 2>&1; then
            setcap cap_net_bind_service=+ep "$SMARTDNS_BIN" 2>/dev/null || \
                log_warn "setcap 失败（可能在无特权容器中）"
        fi
    fi

    mkdir -p /etc/smartdns
    log_info "SmartDNS 安装完成: $SMARTDNS_BIN"
}

#==================================================
# 第三步: 生成配置
#==================================================
generate_config() {
    log_step "生成配置..."
    CONFIG_FILE="/etc/smartdns/smartdns.conf"

    BIND_PORT="53"
    if [ "$VIRT" = "docker" ] || [ "$VIRT" = "lxc" ]; then
        if command -v getcap >/dev/null 2>&1; then
            if ! getcap "$SMARTDNS_BIN" 2>/dev/null | grep -q "cap_net_bind_service"; then
                BIND_PORT="5853"
                log_warn "无特权绑定53端口，使用端口: $BIND_PORT"
            fi
        fi
    fi

    cat > "$CONFIG_FILE" << EOF
# SmartDNS 配置 (自动生成)
# 时间: $(date '+%Y-%m-%d %H:%M:%S')

server-name smartdns
bind [::]:${BIND_PORT}
bind 0.0.0.0:${BIND_PORT}

cache-size 4096
prefetch-domain yes
serve-expired yes
serve-expired-ttl 86400

audit-enable yes
log-level info
log-file /var/log/smartdns.log
log-size 2m
log-num 2

speed-check-mode ping,tcp:443
response-mode fastest-ip

rr-ttl 300
rr-ttl-min 60
rr-ttl-max 86400
EOF

    if [ -n "$DEFAULT_IPV6" ]; then
        echo "dns64 64:ff9b::/96" >> "$CONFIG_FILE"
    else
        echo "force-AAAA-SOA yes" >> "$CONFIG_FILE"
    fi

    cat >> "$CONFIG_FILE" << 'EOF'

edns-client-subnet

# Cloudflare
server 1.1.1.1
server 2606:4700:4700::1111
server-https https://cloudflare-dns.com/dns-query

# Google
server 8.8.8.8
server 2001:4860:4860::8888
server-https https://dns.google/dns-query

# Quad9
server 9.9.9.9
server 2620:fe::9
server-https https://dns.quad9.net/dns-query
EOF

    log_info "配置文件: $CONFIG_FILE"
}

#==================================================
# 第四步: 接管系统 DNS
#==================================================
configure_system_dns() {
    log_step "接管系统 DNS..."

    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)
    fi

    chattr -i /etc/resolv.conf 2>/dev/null || true

    if [ "$INIT" = "systemd" ] && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        rm -f /etc/resolv.conf
    fi

    cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

    chattr +i /etc/resolv.conf 2>/dev/null || true

    log_info "DNS -> 127.0.0.1"
}

#==================================================
# 第五步: 启动服务
#==================================================
start_service() {
    log_step "启动 SmartDNS..."

    case "$INIT" in
        systemd)
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
            systemctl enable smartdns 2>/dev/null || true
            systemctl restart smartdns
            sleep 1
            systemctl is-active smartdns >/dev/null 2>&1 && \
                log_info "SmartDNS 已启动" || log_warn "请检查: systemctl status smartdns"
            ;;
        openrc)
            cat > /etc/init.d/smartdns << EOF
#!/sbin/openrc-run
name="SmartDNS"
command="${SMARTDNS_BIN}"
command_args="-c /etc/smartdns/smartdns.conf"
command_background=true
pidfile="/run/smartdns.pid"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /run; }
EOF
            chmod +x /etc/init.d/smartdns
            rc-update add smartdns default 2>/dev/null || true
            rc-service smartdns restart 2>/dev/null || true
            sleep 1
            pgrep smartdns >/dev/null 2>&1 && \
                log_info "SmartDNS 已启动" || log_warn "请手动启动"
            ;;
        *)
            $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf &
            sleep 1
            pgrep smartdns >/dev/null 2>&1 && \
                log_info "SmartDNS 已后台运行" || log_error "启动失败"
            ;;
    esac
}

#==================================================
# 第六步: 验证
#==================================================
verify_installation() {
    log_step "验证 DNS..."
    sleep 2

    local port=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -oP ':\K\d+' | head -1)
    port=${port:-53}

    echo ""
    if command -v nslookup >/dev/null 2>&1; then
        nslookup google.com 127.0.0.1 2>/dev/null | grep -qE "Address|地址" && \
            log_info "✓ IPv4 解析正常" || log_warn "✗ 解析测试失败"
    fi

    echo ""
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}  SmartDNS 部署完成${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "配置: ${BLUE}/etc/smartdns/smartdns.conf${NC}"
    echo -e "日志: ${BLUE}/var/log/smartdns.log${NC}"
    echo -e "监听: ${BLUE}127.0.0.1:$port${NC}"
    echo -e "卸载: ${GREEN}$0 --uninstall${NC}"
}

#==================================================
# 主函数
#==================================================
main() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   SmartDNS 智能部署 v2.3${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""

    case "${1:-}" in
        --uninstall|-u)
            detect_environment 2>/dev/null || { OS="unknown"; INIT="none"; PKG_MANAGER="apk"; }
            uninstall_smartdns
            ;;
        --help|-h)
            echo "用法: $0 [--uninstall|--help]"
            exit 0
            ;;
    esac

    trap 'log_error "安装中断"; exit 1' INT TERM

    detect_environment
    check_dependencies
    install_smartdns
    generate_config
    configure_system_dns
    start_service
    verify_installation
}

main "$@"
