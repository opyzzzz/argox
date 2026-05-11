#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 (修复版 v2.2)
# 功能: 自动检测环境 -> 安装稳定版 -> 动态配置
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
# 修复: 按官方文档规范下载和安装
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
get_latest_version() {
    local api_url="https://api.github.com/repos/pymumu/smartdns/releases/latest"
    local tag
    
    if command -v curl >/dev/null 2>&1; then
        tag=$(curl -sL --max-time 10 "$api_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    else
        tag=$(wget -qO- --timeout=10 "$api_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    # 去除可能的 'Release' 前缀和 'V' 前缀，获取纯版本号
    tag=$(echo "$tag" | sed -E 's/^[Rr]elease//; s/^[Vv]//')
    
    if [ -z "$tag" ]; then
        # 回退版本
        echo "43"
    else
        echo "$tag"
    fi
}

# 获取适合当前系统的下载文件名
get_download_filename() {
    local arch="$1"
    local ver="$2"
    
    case "$arch" in
        x86_64)
            echo "smartdns.${ver}.x86_64-linux-all.tar.gz"
            ;;
        aarch64)
            echo "smartdns.${ver}.aarch64-debian-all.deb"
            ;;
        armv7l|armv7)
            echo "smartdns.${ver}.arm-debian-all.deb"
            ;;
        armv6l)
            echo "smartdns.${ver}.arm-debian-all.deb"
            ;;
        i386|i686)
            echo "smartdns.${ver}.x86-linux-all.tar.gz"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# 架构检测
get_arch_name() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l|armv7)   echo "armv7l" ;;
        armv6l)         echo "armv6l" ;;
        i386|i686)      echo "i386" ;;
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

    # 终止所有 smartdns 进程
    pkill smartdns 2>/dev/null || true
    sleep 1

    # 恢复 resolv.conf
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi

    local latest_backup=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        cp "$latest_backup" /etc/resolv.conf
        log_info "已恢复 resolv.conf 从备份: $latest_backup"
    else
        cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
        log_warn "未找到备份，已写入默认 DNS"
    fi

    # 恢复 dhcpcd
    if [ -f /etc/dhcpcd.conf ]; then
        sed -i '/nohook resolv.conf/d' /etc/dhcpcd.conf
    fi

    # 恢复 NetworkManager
    rm -f /etc/NetworkManager/conf.d/99-smartdns.conf

    # 删除文件
    rm -f /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log*

    # 如果用包管理器安装的也尝试卸载
    if command -v apk >/dev/null 2>&1; then
        apk del smartdns 2>/dev/null || true
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y smartdns 2>/dev/null || true
    fi

    log_info "SmartDNS 卸载完成"
    exit 0
}

#==================================================
# 依赖检查与安装
#==================================================
check_dependencies() {
    log_step "检查基础依赖..."
    local missing=""

    # 必须的命令
    for cmd in wget grep sed awk tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        log_warn "缺少基础依赖：$missing"
        log_info "正在尝试安装..."

        case "$PKG_MANAGER" in
            apk)
                apk add --no-cache $missing
                # tar 在 Alpine 可能需要单独安装
                if ! command -v tar >/dev/null 2>&1; then
                    apk add --no-cache tar
                fi
                ;;
            apt)
                apt-get update -qq
                apt-get install -y -qq $missing
                ;;
        esac
    fi

    log_info "依赖检查完成"
}

#==================================================
# 第一步: 系统环境自动检测
#==================================================
detect_environment() {
    log_step "正在进行环境检测..."

    # 1. 检测发行版
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
    log_info "检测到系统: $OS $VER (包管理器: $PKG_MANAGER)"

    # 2. 检测 init 系统
    if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
        INIT="systemd"
    elif [ -f /sbin/openrc ] || [ -f /usr/sbin/openrc ]; then
        INIT="openrc"
    else
        log_warn "未检测到 systemd/OpenRC，将仅生成配置"
        INIT="none"
    fi
    log_info "Init 系统: $INIT"

    # 3. 检测虚拟化/容器环境
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null || grep -q "lxchost" /proc/1/cgroup 2>/dev/null; then
        VIRT="lxc"
    elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        VIRT="docker"
    elif [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
        VIRT="openvz"
    else
        VIRT="kvm"
    fi
    log_info "虚拟化环境: $VIRT"

    # 4. 检测网络与 NAT
    if command -v ip >/dev/null 2>&1; then
        DEFAULT_IPV4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
        DEFAULT_IPV6=$(ip route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    else
        DEFAULT_IPV4=""
        DEFAULT_IPV6=""
    fi

    if command -v curl >/dev/null 2>&1; then
        PUBLIC_IPV4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
        PUBLIC_IPV6=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    elif command -v wget >/dev/null 2>&1; then
        PUBLIC_IPV4=$(wget -4 -qO- --timeout=5 ifconfig.me 2>/dev/null || echo "")
        PUBLIC_IPV6=$(wget -6 -qO- --timeout=5 ifconfig.me 2>/dev/null || echo "")
    else
        PUBLIC_IPV4=""
        PUBLIC_IPV6=""
    fi

    if [ -n "$DEFAULT_IPV4" ]; then
        if [ "$DEFAULT_IPV4" != "$PUBLIC_IPV4" ] && [ -n "$PUBLIC_IPV4" ]; then
            NAT_TYPE="NAT4"
            log_info "检测到 IPv4 NAT: 内网 $DEFAULT_IPV4 -> 公网 $PUBLIC_IPV4"
        else
            NAT_TYPE="Public4"
            log_info "公网 IPv4: $DEFAULT_IPV4"
        fi
    else
        NAT_TYPE="NoIPv4"
        log_warn "未检测到 IPv4 连接"
    fi

    if [ -n "$DEFAULT_IPV6" ]; then
        NAT_TYPE="${NAT_TYPE}+IPv6"
        log_info "IPv6: $DEFAULT_IPV6"
    else
        log_warn "未检测到 IPv6 连接"
    fi

    # 5. 检测 resolv.conf 状态
    if [ -L /etc/resolv.conf ]; then
        log_warn "/etc/resolv.conf 是符号链接，将尝试处理"
    fi
}

#==================================================
# 第二步: 安装 SmartDNS
#==================================================
install_smartdns() {
    log_step "开始安装 SmartDNS..."

    # === 方法1: Debian/Ubuntu 优先使用 apt ===
    if [ "$PKG_MANAGER" = "apt" ]; then
        log_info "尝试从 apt 仓库安装 SmartDNS..."
        apt-get update -qq
        
        if apt-cache show smartdns >/dev/null 2>&1; then
            log_info "apt 仓库中存在 smartdns，直接安装"
            apt-get install -y -qq smartdns
            
            # 获取安装路径
            SMARTDNS_BIN=$(which smartdns 2>/dev/null || echo "/usr/sbin/smartdns")
            log_info "SmartDNS 安装完成 (apt): $SMARTDNS_BIN"
            mkdir -p /etc/smartdns
            return 0
        else
            log_warn "apt 仓库中未找到 smartdns，改用 GitHub 下载"
        fi
    fi

    # === 方法2: Alpine 优先使用 apk ===
    if [ "$PKG_MANAGER" = "apk" ]; then
        log_info "尝试从 apk 仓库安装 SmartDNS..."
        apk update --quiet 2>/dev/null || true
        
        # 检查包是否存在
        if apk search smartdns 2>/dev/null | grep -q "^smartdns"; then
            log_info "apk 仓库中存在 smartdns，直接安装"
            apk add --no-cache smartdns
            
            SMARTDNS_BIN=$(which smartdns 2>/dev/null || echo "/usr/sbin/smartdns")
            log_info "SmartDNS 安装完成 (apk): $SMARTDNS_BIN"
            mkdir -p /etc/smartdns
            return 0
        else
            log_warn "apk 仓库中未找到 smartdns，改用 GitHub 下载"
        fi
    fi

    # === 方法3: GitHub Releases 下载 ===
    log_info "从 GitHub Releases 下载 SmartDNS..."

    local SMARTDNS_VER=$(get_latest_version)
    ARCH=$(get_arch_name)
    local PKG_NAME=$(get_download_filename "$ARCH" "$SMARTDNS_VER")
    local DOWNLOAD_URL="https://github.com/pymumu/smartdns/releases/download/Release${SMARTDNS_VER}/${PKG_NAME}"

    log_info "版本: $SMARTDNS_VER"
    log_info "架构: $ARCH"
    log_info "包名: $PKG_NAME"
    log_info "URL: $DOWNLOAD_URL"

    # 下载
    if ! download_with_retry "$DOWNLOAD_URL" "/tmp/${PKG_NAME}"; then
        log_error "下载失败: $DOWNLOAD_URL"
        log_error "请手动访问 https://github.com/pymumu/smartdns/releases/latest 下载"
        exit 1
    fi

    # 安装
    cd /tmp

    case "$PKG_NAME" in
        *.tar.gz)
            log_info "解压 tar.gz..."
            tar xzf "$PKG_NAME"
            
            # 查找解压后的 smartdns 二进制
            if [ -f "smartdns" ]; then
                cp smartdns /usr/bin/smartdns
            elif [ -d "smartdns" ]; then
                cp smartdns/smartdns /usr/bin/smartdns 2>/dev/null || \
                find smartdns -name "smartdns" -type f -exec cp {} /usr/bin/smartdns \;
            else
                find . -name "smartdns" -type f -exec cp {} /usr/bin/smartdns \;
            fi
            ;;
        *.deb)
            log_info "安装 deb 包..."
            if command -v dpkg >/dev/null 2>&1; then
                dpkg -i "$PKG_NAME" || apt-get install -f -y
            else
                # 手动提取 deb
                ar x "$PKG_NAME"
                tar xzf data.tar.* -C /
            fi
            ;;
        *)
            log_error "不支持的包格式: $PKG_NAME"
            exit 1
            ;;
    esac

    chmod +x /usr/bin/smartdns 2>/dev/null || true
    SMARTDNS_BIN="/usr/bin/smartdns"
    
    # 如果 /usr/bin/smartdns 不存在，尝试查找
    if [ ! -f "$SMARTDNS_BIN" ]; then
        SMARTDNS_BIN=$(which smartdns 2>/dev/null || find /usr -name "smartdns" -type f 2>/dev/null | head -1)
    fi

    if [ ! -f "$SMARTDNS_BIN" ] || [ ! -x "$SMARTDNS_BIN" ]; then
        log_error "找不到 smartdns 二进制文件"
        exit 1
    fi

    # 清理
    rm -f "/tmp/${PKG_NAME}"
    
    # 创建配置目录
    mkdir -p /etc/smartdns

    # 容器环境设置
    if [ "$VIRT" = "docker" ] || [ "$VIRT" = "lxc" ]; then
        log_info "容器环境，配置端口绑定权限..."
        if command -v setcap >/dev/null 2>&1; then
            setcap cap_net_bind_service=+ep "$SMARTDNS_BIN" 2>/dev/null || \
                log_warn "setcap 失败（可能在无特权容器中）"
        fi
    fi

    log_info "SmartDNS 安装完成: $SMARTDNS_BIN"
}

#==================================================
# 第三步: 动态生成配置文件
#==================================================
generate_config() {
    log_step "动态生成 SmartDNS 配置..."
    CONFIG_FILE="/etc/smartdns/smartdns.conf"

    # 决定监听端口
    BIND_PORT="53"
    if [ "$VIRT" = "docker" ] || [ "$VIRT" = "lxc" ]; then
        if command -v getcap >/dev/null 2>&1; then
            if ! getcap "$SMARTDNS_BIN" 2>/dev/null | grep -q "cap_net_bind_service"; then
                BIND_PORT="5853"
                log_warn "容器无特权，使用备用端口: $BIND_PORT"
            fi
        fi
    fi

    cat > "$CONFIG_FILE" << EOF
#==========================================
# SmartDNS 配置 (自动生成)
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
# 环境: $OS $VER | $INIT | $VIRT
#==========================================

# 基础设置
server-name smartdns
bind [::]:${BIND_PORT}
bind 0.0.0.0:${BIND_PORT}

# 缓存
cache-size 4096
prefetch-domain yes
serve-expired yes
serve-expired-ttl 86400
serve-expired-reply-ttl 5

# 日志
audit-enable yes
log-level info
log-file /var/log/smartdns.log
log-size 2m
log-num 2

# 速度优化
speed-check-mode ping,tcp:443
response-mode fastest-ip

# TTL
rr-ttl 300
rr-ttl-min 60
rr-ttl-max 86400
EOF

    if [ -n "$DEFAULT_IPV6" ]; then
        cat >> "$CONFIG_FILE" << 'EOF'

# IPv6 DNS64
dns64 64:ff9b::/96
EOF
    else
        cat >> "$CONFIG_FILE" << 'EOF'

# 纯IPv4
force-AAAA-SOA yes
EOF
    fi

    cat >> "$CONFIG_FILE" << 'EOF'

# EDNS
edns-client-subnet

# === 上游 DNS ===
# Cloudflare
server 1.1.1.1 -blacklist-ip -check-edns
server 2606:4700:4700::1111
server-https https://cloudflare-dns.com/dns-query
server-tls 1.1.1.1:853 -host-name cloudflare-dns.com

# Google
server 8.8.8.8 -blacklist-ip -check-edns
server 2001:4860:4860::8888
server-https https://dns.google/dns-query
server-tls 8.8.8.8:853 -host-name dns.google

# Quad9
server 9.9.9.9 -blacklist-ip -check-edns
server 2620:fe::9
server-https https://dns.quad9.net/dns-query
server-tls 9.9.9.9:853 -host-name dns.quad9.net
EOF

    log_info "配置已生成: $CONFIG_FILE"
}

#==================================================
# 第四步: 接管系统 DNS
#==================================================
configure_system_dns() {
    log_step "配置系统 DNS..."

    # 备份
    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)
        log_info "已备份 resolv.conf"
    fi

    chattr -i /etc/resolv.conf 2>/dev/null || true

    # 处理 systemd-resolved
    if [ "$INIT" = "systemd" ] && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        log_warn "停用 systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        rm -f /etc/resolv.conf
    fi

    # 写入新配置
    cat > /etc/resolv.conf << EOF
# SmartDNS 接管
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

    chattr +i /etc/resolv.conf 2>/dev/null || log_warn "无法锁定 resolv.conf（容器环境属正常）"

    # dhcpcd
    if command -v dhcpcd >/dev/null 2>&1 && [ -f /etc/dhcpcd.conf ]; then
        if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
            echo "" >> /etc/dhcpcd.conf
            echo "# SmartDNS" >> /etc/dhcpcd.conf
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf
            log_info "dhcpcd 已配置"
        fi
    fi

    # NetworkManager
    if [ -d /etc/NetworkManager/conf.d ]; then
        cat > /etc/NetworkManager/conf.d/99-smartdns.conf << 'EOF'
[main]
dns=none
EOF
        log_info "NetworkManager DNS 已禁用"
    fi

    log_info "系统 DNS -> 127.0.0.1"
}

#==================================================
# 第五步: 启动服务
#==================================================
start_service() {
    log_step "启动 SmartDNS 服务..."

    case "$INIT" in
        systemd)
            cat > /etc/systemd/system/smartdns.service << EOF
[Unit]
Description=SmartDNS Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=${SMARTDNS_BIN} -c /etc/smartdns/smartdns.conf
PIDFile=/run/smartdns.pid
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable smartdns >/dev/null 2>&1 || true
            systemctl restart smartdns
            sleep 1
            if systemctl is-active smartdns >/dev/null 2>&1; then
                log_info "SmartDNS 已启动 (systemd)"
            else
                log_warn "启动检查失败，查看: systemctl status smartdns"
            fi
            ;;

        openrc)
            cat > /etc/init.d/smartdns << EOF
#!/sbin/openrc-run
name="SmartDNS"
description="SmartDNS Server"

command="${SMARTDNS_BIN}"
command_args="-c /etc/smartdns/smartdns.conf"
command_background=true
pidfile="/run/smartdns.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /run
}
EOF
            chmod +x /etc/init.d/smartdns
            rc-update add smartdns default 2>/dev/null || true
            rc-service smartdns restart 2>/dev/null || true
            sleep 1
            if pgrep smartdns >/dev/null 2>&1; then
                log_info "SmartDNS 已启动 (OpenRC)"
            else
                log_warn "OpenRC 启动失败，直接后台运行..."
                $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf &
            fi
            ;;

        *)
            $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf &
            sleep 1
            if pgrep smartdns >/dev/null 2>&1; then
                log_info "SmartDNS 已后台运行"
            else
                log_error "启动失败"
            fi
            ;;
    esac
}

#==================================================
# 第六步: 验证
#==================================================
verify_installation() {
    log_step "验证 DNS 解析..."
    sleep 2

    local test_port=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -oP ':\K\d+' | head -1)
    test_port=${test_port:-53}

    echo ""
    log_info "测试 IPv4 解析:"
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup google.com 127.0.0.1 2>/dev/null | grep -qE "Address|地址"; then
            log_info "✓ 解析正常"
        else
            log_warn "✗ 测试失败"
        fi
    elif command -v drill >/dev/null 2>&1; then
        if drill google.com @127.0.0.1 2>/dev/null | grep -q "rcode: NOERROR"; then
            log_info "✓ 解析正常"
        else
            log_warn "✗ 测试失败"
        fi
    else
        log_info "跳过测试（无测试工具）"
    fi

    echo ""
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}  ✓ SmartDNS 部署完成${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "监听: ${BLUE}127.0.0.1:$test_port${NC}"
    echo -e "配置: ${BLUE}/etc/smartdns/smartdns.conf${NC}"
    echo -e "日志: ${BLUE}/var/log/smartdns.log${NC}"
    echo ""
    echo -e "${YELLOW}命令:${NC}"
    echo -e "  测试: ${GREEN}nslookup google.com 127.0.0.1${NC}"
    echo -e "  日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
    echo -e "  重启: ${GREEN}rc-service smartdns restart${NC}"
    echo -e "  卸载: ${GREEN}$0 --uninstall${NC}"
    echo ""
}

#==================================================
# 主函数
#==================================================
main() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   SmartDNS 智能部署 v2.2${NC}"
    echo -e "${BLUE}   按官方规范安装 | GitHub Releases${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""

    case "${1:-}" in
        --uninstall|-u)
            detect_environment 2>/dev/null || {
                OS="unknown"
                INIT="none"
                PKG_MANAGER="apk"
            }
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
