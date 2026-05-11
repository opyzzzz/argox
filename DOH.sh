#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 (一键版)
# 功能: 自动检测环境 -> 安装稳定版 -> 动态配置
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT)
# 更新: 2025-04-13
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
    log_info "检测到系统: $OS $VER"

    # 2. 检测 init 系统
    if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
        INIT="systemd"
    elif [ -f /sbin/openrc ] || [ -f /usr/sbin/openrc ]; then
        INIT="openrc"
    else
        log_warn "未检测到 systemd/OpenRC，将仅生成文件"
        INIT="none"
    fi
    log_info "Init 系统: $INIT"

    # 3. 检测虚拟化/容器环境
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null || grep -q "lxchost" /proc/1/cgroup 2>/dev/null; then
        VIRT="lxc"
    elif grep -q "docker" /proc/1/cgroup 2>/dev/null; then
        VIRT="docker"
    elif [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
        VIRT="openvz"
    else
        VIRT="kvm" # 默认为KVM/物理机
    fi
    log_info "虚拟化环境: $VIRT"

    # 4. 检测 NAT 与 IPv4/IPv6
    DEFAULT_IPV4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    DEFAULT_IPV6=$(ip route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+')
    PUBLIC_IPV4=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || echo "")
    PUBLIC_IPV6=$(curl -6 -s --max-time 3 ifconfig.me 2>/dev/null || echo "")

    if [ -n "$DEFAULT_IPV4" ]; then
        if [ "$DEFAULT_IPV4" != "$PUBLIC_IPV4" ]; then
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
        if [ "$DEFAULT_IPV6" != "$PUBLIC_IPV6" ]; then
            NAT_TYPE="${NAT_TYPE}+NAT6"
            log_info "检测到 IPv6 NAT: 内网 $DEFAULT_IPV6 -> 公网 $PUBLIC_IPV6"
        else
            NAT_TYPE="${NAT_TYPE}+Public6"
            log_info "公网 IPv6: $DEFAULT_IPV6"
        fi
    else
        log_warn "未检测到 IPv6 连接"
    fi

    # 5. 检测 DNS 解析文件
    RESOLV_FILE="/etc/resolv.conf"
    if [ -L "$RESOLV_FILE" ] || [ ! -f "$RESOLV_FILE" ]; then
        log_warn "$RESOLV_FILE 不是常规文件，将尝试备份并创建新文件"
    fi
}

#==================================================
# 第二步: 安装 SmartDNS 稳定版
#==================================================
install_smartdns() {
    log_step "开始安装 SmartDNS 稳定版..."

    case "$OS" in
        alpine)
            log_info "使用 apk 安装 SmartDNS"
            apk update
            # 使用社区仓库中的 smartdns 包
            if ! apk add smartdns; then
                log_warn "apk 仓库安装失败，尝试从 Edge 社区仓库安装"
                echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
                apk update
                apk add smartdns
            fi
            ;;
        debian|ubuntu)
            log_info "使用官方仓库安装 SmartDNS (Release 稳定版)"
            # 安装依赖
            apt-get update
            apt-get install -y curl wget tar

            # 获取最新稳定版
            SMARTDNS_VER=$(curl -sL https://api.github.com/repos/pymumu/smartdns/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [ -z "$SMARTDNS_VER" ]; then
                SMARTDNS_VER="Release42" # 回退版本
                log_warn "无法获取最新版本，使用回退版本 $SMARTDNS_VER"
            fi
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64)  ARCH="x86_64" ;;
                aarch64) ARCH="aarch64" ;;
                armv7l)  ARCH="armv7l" ;;
                *)       log_error "不支持的架构: $ARCH"; exit 1 ;;
            esac

            PKG_NAME="smartdns.${ARCH}"
            DOWNLOAD_URL="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_VER}/${PKG_NAME}"

            log_info "下载 SmartDNS ${SMARTDNS_VER} for ${ARCH}"
            wget -q --show-progress -O /usr/bin/smartdns "$DOWNLOAD_URL"
            chmod +x /usr/bin/smartdns

            # 创建必要的目录
            mkdir -p /etc/smartdns
            ;;
        *)
            log_error "不支持的发行版: $OS"
            exit 1
            ;;
    esac

    # 通用配置目录
    mkdir -p /etc/smartdns
    log_info "SmartDNS 安装完成"
}

#==================================================
# 第三步: 动态生成配置文件
#==================================================
generate_config() {
    log_step "动态生成 SmartDNS 配置..."
    CONFIG_FILE="/etc/smartdns/smartdns.conf"

    # 基础配置
    cat > "$CONFIG_FILE" << 'EOF'
# SmartDNS 自动生成配置
# 生成时间: $(date)
# 系统环境: $OS $VER | $INIT | $VIRT

# 基础设置
server-name smartdns
bind [::]:53

# 缓存大小与持久化
cache-size 4096
prefetch-domain yes
serve-expired yes
serve-expired-ttl 3600

# 审计与日志
audit-enable yes
log-level info
log-file /var/log/smartdns.log
log-size 2m
log-num 2

# 速度模式: 返回最快IP
speed-check-mode ping,tcp:443
response-mode fastest-ip

# TTL 设置
rr-ttl 300
rr-ttl-min 60
rr-ttl-max 86400

# 安全防护
dns64 64:ff9b::/96
edns-client-subnet
force-AAAA-SOA yes
EOF

    # 动态上游 DNS 配置 (使用 CF 和 Google 的 DoH/DNS)
    cat >> "$CONFIG_FILE" << 'EOF'

# === 上游 DNS 服务器 ===
# 传统 UDP (低延迟)
server 1.1.1.1 -blacklist-ip -check-edns
server 8.8.8.8 -blacklist-ip -check-edns
server 9.9.9.9 -blacklist-ip -check-edns

# IPv6 传统 DNS
server 2606:4700:4700::1111
server 2001:4860:4860::8888
server 2620:fe::9

# DoH (DNS over HTTPS) - 高安全
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
server-https https://dns.quad9.net/dns-query

# DoT (DNS over TLS) - 备用
server-tls 1.1.1.1:853
server-tls 8.8.8.8:853
server-tls 9.9.9.9:853

# 特定域名优化 (使用国内DNS加速)
# 如需国内分流，请取消下方注释并调整上游
# server 223.5.5.5 -group cn
# domain-rules /example.cn/ -server cn
EOF

    echo "配置已生成: $CONFIG_FILE"
}

#==================================================
# 第四步: 接管系统 DNS
#==================================================
configure_system_dns() {
    log_step "配置系统 DNS 接管..."

    # 备份原文件
    cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

    # 方法一: 直接修改 resolv.conf (适用于大多数情况)
    if [ "$VIRT" = "docker" ] || [ "$INIT" = "none" ]; then
        log_warn "Docker/无init环境，直接静态写入 resolv.conf"
        cat > /etc/resolv.conf << EOF
# SmartDNS 接管
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
        chattr +i /etc/resolv.conf 2>/dev/null && log_info "已锁定 resolv.conf" || log_warn "无法锁定 resolv.conf (可能在容器内)"
    else
        # 标准系统环境
        cat > /etc/resolv.conf << EOF
# SmartDNS 接管 (自动生成)
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
        # 防止被网络管理器覆盖
        chattr +i /etc/resolv.conf 2>/dev/null && log_info "已锁定 /etc/resolv.conf" || log_warn "无法锁定 resolv.conf，请手动检查网络管理器"
    fi

    # 方法二: 接管 dhcpcd (如果存在)
    if command -v dhcpcd >/dev/null 2>&1; then
        log_info "检测到 dhcpcd，配置其禁用自动DNS"
        if [ -f /etc/dhcpcd.conf ]; then
            if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
                echo "nohook resolv.conf" >> /etc/dhcpcd.conf
                log_info "dhcpcd 已配置为不修改 resolv.conf"
            fi
        fi
    fi

    # 方法三: 禁用 systemd-resolved (如果存在)
    if [ "$INIT" = "systemd" ] && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        log_warn "检测到 systemd-resolved 正在运行，将停用并禁用"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        rm -f /etc/resolv.conf
        cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ::1
EOF
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi

    log_info "系统 DNS 已设置为本地 SmartDNS"
}

#==================================================
# 第五步: 启动服务
#==================================================
start_service() {
    log_step "启动 SmartDNS 服务..."

    case "$INIT" in
        systemd)
            # 生成 systemd service 文件 (如果不存在)
            if [ ! -f /etc/systemd/system/smartdns.service ]; then
                cat > /etc/systemd/system/smartdns.service << 'EOF'
[Unit]
Description=SmartDNS Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/smartdns -c /etc/smartdns/smartdns.conf
PIDFile=/run/smartdns.pid
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
            fi
            systemctl enable smartdns
            systemctl restart smartdns
            systemctl status smartdns --no-pager
            ;;
        openrc)
            # Alpine OpenRC
            if [ -f /etc/init.d/smartdns ]; then
                rc-update add smartdns default
                rc-service smartdns restart
            else
                log_warn "未找到 OpenRC 脚本，尝试直接启动"
                smartdns -c /etc/smartdns/smartdns.conf &
            fi
            ;;
        *)
            log_warn "无法自动启动服务，请手动运行:"
            echo "  smartdns -c /etc/smartdns/smartdns.conf &"
            ;;
    esac
}

#==================================================
# 第六步: 验证
#==================================================
verify_installation() {
    log_step "验证 DNS 解析..."
    sleep 2

    # 测试解析
    echo ""
    log_info "测试 IPv4 解析:"
    if nslookup -timeout=2 google.com 127.0.0.1; then
        log_info "IPv4 解析正常"
    else
        log_warn "IPv4 解析测试失败，请检查配置"
    fi

    echo ""
    log_info "测试 IPv6 解析:"
    if nslookup -timeout=2 google.com ::1 2>/dev/null; then
        log_info "IPv6 解析正常"
    else
        log_warn "IPv6 解析测试失败或未启用"
    fi

    echo ""
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN} SmartDNS 部署完成!${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "配置文件: ${BLUE}/etc/smartdns/smartdns.conf${NC}"
    echo -e "日志文件: ${BLUE}/var/log/smartdns.log${NC}"
    echo -e "监听地址: ${BLUE}127.0.0.1:53, [::1]:53${NC}"
    echo -e "上游 DNS: ${BLUE}Cloudflare & Google (DoH/DoT/UDP)${NC}"
    echo ""
    echo -e "测试命令: ${YELLOW}nslookup youtube.com 127.0.0.1${NC}"
    echo -e "查看日志: ${YELLOW}tail -f /var/log/smartdns.log${NC}"
    echo -e "如需修改配置: ${YELLOW}nano /etc/smartdns/smartdns.conf && systemctl restart smartdns${NC}"
}

#==================================================
# 主执行流程
#==================================================
main() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   SmartDNS 智能部署脚本 v1.0${NC}"
    echo -e "${BLUE}   自动检测 | 稳定版 | DoH支持${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""

    detect_environment
    install_smartdns
    generate_config
    configure_system_dns
    start_service
    verify_installation
}

main "$@"
