#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 (改善版 v2.0)
# 功能: 自动检测环境 -> 安装稳定版 -> 动态配置
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
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

# 架构检测
get_arch_name() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l|armv7)   echo "armv7l" ;;
        armv6l)         echo "armv6l" ;;
        i386|i686)      echo "i386" ;;
        mips64*)        echo "mips64" ;;
        riscv64)        echo "riscv64" ;;
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
    case "$INIT" in
        systemd)
            systemctl stop smartdns 2>/dev/null
            systemctl disable smartdns 2>/dev/null
            rm -f /etc/systemd/system/smartdns.service
            systemctl daemon-reload
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null
            rc-update del smartdns 2>/dev/null
            rm -f /etc/init.d/smartdns
            ;;
    esac

    # 恢复 resolv.conf
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
    fi
    
    # 查找并恢复备份
    local latest_backup=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        cp "$latest_backup" /etc/resolv.conf
        log_info "已恢复 resolv.conf 从备份: $latest_backup"
    else
        # 写入通用 DNS
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

    # 删除文件
    rm -f /usr/bin/smartdns
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log*

    # 卸载包
    case "$PKG_MANAGER" in
        apk) apk del smartdns 2>/dev/null ;;
        apt) apt-get remove -y smartdns 2>/dev/null ;;
    esac

    log_info "SmartDNS 卸载完成"
    exit 0
}

#==================================================
# 依赖检查
#==================================================
check_dependencies() {
    log_step "检查基础依赖..."
    local missing_pkgs=""
    local required_cmds="wget curl ip nslookup grep awk sed"

    for cmd in $required_cmds; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                nslookup) 
                    # nslookup 可能作为 busybox 的一部分
                    if ! busybox nslookup 2>/dev/null | grep -q "usage"; then
                        missing_pkgs="$missing_pkgs $cmd"
                    fi
                    ;;
                *)
                    missing_pkgs="$missing_pkgs $cmd"
                    ;;
            esac
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        log_warn "缺少基础依赖：$missing_pkgs"
        log_info "正在尝试安装..."

        case "$PKG_MANAGER" in
            apk) 
                # 映射包名
                for pkg in $missing_pkgs; do
                    case "$pkg" in
                        nslookup) apk add --no-cache bind-tools ;;
                        wget)     apk add --no-cache wget ;;
                        curl)     apk add --no-cache curl ;;
                        ip)       apk add --no-cache iproute2 ;;
                        *)        apk add --no-cache "$pkg" ;;
                    esac
                done
                ;;
            apt) 
                for pkg in $missing_pkgs; do
                    case "$pkg" in
                        nslookup) apt-get install -y -qq dnsutils ;;
                        ip)       apt-get install -y -qq iproute2 ;;
                        *)        apt-get install -y -qq "$pkg" ;;
                    esac
                done
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
        alpine) PKG_MANAGER="apk" ;;
        debian|ubuntu) PKG_MANAGER="apt" ;;
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
    DEFAULT_IPV4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    DEFAULT_IPV6=$(ip route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+' || echo "")

    # 获取公网IP (带超时保护)
    PUBLIC_IPV4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
    PUBLIC_IPV6=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null || echo "")

    # IPv4 判断
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

    # IPv6 判断
    if [ -n "$DEFAULT_IPV6" ]; then
        if [ "$DEFAULT_IPV6" != "$PUBLIC_IPV6" ] && [ -n "$PUBLIC_IPV6" ]; then
            NAT_TYPE="${NAT_TYPE}+NAT6"
            log_info "检测到 IPv6 NAT: 内网 $DEFAULT_IPV6 -> 公网 $PUBLIC_IPV6"
        else
            NAT_TYPE="${NAT_TYPE}+Public6"
            log_info "公网 IPv6: $DEFAULT_IPV6"
        fi
    else
        log_warn "未检测到 IPv6 连接"
    fi

    # 5. 检测 resolv.conf 状态
    RESOLV_FILE="/etc/resolv.conf"
    if [ -L "$RESOLV_FILE" ]; then
        log_warn "$RESOLV_FILE 是符号链接，将尝试处理"
        # 记录原链接目标
        RESOLV_LINK_TARGET=$(readlink -f "$RESOLV_FILE" 2>/dev/null || echo "")
    fi
}

#==================================================
# 第二步: 安装 SmartDNS 稳定版
#==================================================
install_smartdns() {
    log_step "开始安装 SmartDNS 稳定版..."

    case "$PKG_MANAGER" in
        apk)
            log_info "使用 apk 安装 SmartDNS"
            apk update --quiet
            
            # 尝试社区仓库
            if ! apk add --no-cache smartdns 2>/dev/null; then
                log_warn "稳定仓库未找到 smartdns，尝试从 Edge 社区安装"
                # 临时添加 edge 社区仓库
                if ! grep -q "edge/community" /etc/apk/repositories; then
                    echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
                fi
                apk update --quiet
                apk add --no-cache smartdns || {
                    log_error "SmartDNS 安装失败"
                    exit 1
                }
                # 移除临时仓库
                sed -i '/edge\/community/d' /etc/apk/repositories
            fi
            
            # Alpine包安装的smartdns可能在 /usr/sbin
            SMARTDNS_BIN=$(which smartdns 2>/dev/null || echo "/usr/sbin/smartdns")
            ;;
            
        apt)
            log_info "使用官方二进制安装 SmartDNS"
            apt-get update -qq
            
            # 获取最新稳定版
            SMARTDNS_VER=$(curl -sL --max-time 10 https://api.github.com/repos/pymumu/smartdns/releases/latest | \
                grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [ -z "$SMARTDNS_VER" ]; then
                SMARTDNS_VER="Release42"
                log_warn "无法获取最新版本，使用回退版本 $SMARTDNS_VER"
            fi
            log_info "SmartDNS 版本: $SMARTDNS_VER"
            
            ARCH=$(get_arch_name)
            PKG_NAME="smartdns.${ARCH}"
            DOWNLOAD_URL="https://github.com/pymumu/smartdns/releases/download/${SMARTDNS_VER}/${PKG_NAME}"

            log_info "下载 SmartDNS 二进制: $PKG_NAME"
            if ! download_with_retry "$DOWNLOAD_URL" "/tmp/smartdns"; then
                log_error "SmartDNS 下载失败，请检查网络连接或架构匹配"
                log_error "URL: $DOWNLOAD_URL"
                log_error "您可以手动下载并放置到 /usr/bin/smartdns 后重新运行"
                exit 1
            fi
            
            mv /tmp/smartdns /usr/bin/smartdns
            chmod +x /usr/bin/smartdns
            SMARTDNS_BIN="/usr/bin/smartdns"
            ;;
    esac

    # 创建配置目录
    mkdir -p /etc/smartdns
    
    # 容器特权处理
    if [ "$VIRT" = "docker" ] || [ "$VIRT" = "lxc" ]; then
        log_info "检测到容器环境，配置 cap_net_bind_service 能力"
        setcap cap_net_bind_service=+ep "$SMARTDNS_BIN" 2>/dev/null || \
            log_warn "setcap 失败 (可能无特权)，SmartDNS 可能需要监听高端口"
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
        # 检查是否可以使用特权端口
        if ! getcap "$SMARTDNS_BIN" 2>/dev/null | grep -q "cap_net_bind_service"; then
            if ! ss -tuln | grep -q ":53 "; then
                log_warn "容器无特权，尝试监听端口 53..."
            else
                BIND_PORT="5853"
                log_warn "使用备用端口: $BIND_PORT"
            fi
        fi
    fi

    # 基础配置头
    cat > "$CONFIG_FILE" << EOF
#==========================================
# SmartDNS 自动生成配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 系统环境: $OS $VER | $INIT | $VIRT | $NAT_TYPE
#==========================================

# 基础设置
server-name smartdns
bind [::]:${BIND_PORT}
bind :${BIND_PORT}

# 缓存设置
cache-size 4096
prefetch-domain yes
serve-expired yes
serve-expired-ttl 86400
serve-expired-reply-ttl 5

# 审计与日志
audit-enable yes
log-level info
log-file /var/log/smartdns.log
log-size 2m
log-num 2

# DNS 速度优化
speed-check-mode ping,tcp:443
response-mode fastest-ip

# TTL 设置
rr-ttl 300
rr-ttl-min 60
rr-ttl-max 86400
EOF

    # IPv6 相关配置
    if [ -n "$DEFAULT_IPV6" ]; then
        cat >> "$CONFIG_FILE" << 'EOF'

# IPv6 DNS64 转换 (NAT64环境)
dns64 64:ff9b::/96
EOF
    else
        cat >> "$CONFIG_FILE" << 'EOF'

# 纯IPv4环境: 强制AAAA SOA
force-AAAA-SOA yes
EOF
    fi

    # EDNS 和双栈优化
    cat >> "$CONFIG_FILE" << 'EOF'

# EDNS 客户端子网
edns-client-subnet

# === 上游 DNS 服务器 ===
# Cloudflare DNS (优先级最高)
server 1.1.1.1 -blacklist-ip -check-edns
server 2606:4700:4700::1111
server-https https://cloudflare-dns.com/dns-query
server-tls 1.1.1.1:853 -host-name cloudflare-dns.com

# Google DNS
server 8.8.8.8 -blacklist-ip -check-edns
server 2001:4860:4860::8888
server-https https://dns.google/dns-query
server-tls 8.8.8.8:853 -host-name dns.google

# Quad9 DNS (安全过滤)
server 9.9.9.9 -blacklist-ip -check-edns
server 2620:fe::9
server-https https://dns.quad9.net/dns-query
server-tls 9.9.9.9:853 -host-name dns.quad9.net

# === 域名分组规则 (可选) ===
# 如需国内外分流，请取消注释以下行
# server 223.5.5.5 -group cn -exclude-default-group
# domain-rules /\.cn$/ -server cn
# domain-rules /\.taobao\.com$/ -server cn
# domain-rules /\.aliyun\.com$/ -server cn
EOF

    log_info "配置文件已生成: $CONFIG_FILE"
    log_info "监听端口: $BIND_PORT"
}

#==================================================
# 第四步: 接管系统 DNS
#==================================================
configure_system_dns() {
    log_step "配置系统 DNS 接管..."

    # 备份原文件
    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)
        log_info "已备份原 resolv.conf"
    elif [ -L /etc/resolv.conf ]; then
        # 符号链接，备份目标文件
        local target=$(readlink -f /etc/resolv.conf 2>/dev/null)
        if [ -f "$target" ]; then
            cp "$target" /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S)
            log_info "已备份符号链接目标: $target"
        fi
    fi

    # 移除不可变属性
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # 处理 systemd-resolved
    if [ "$INIT" = "systemd" ] && systemctl is-active systemd-resolved >/dev/null 2>&1; then
        log_warn "检测到 systemd-resolved，将停用并禁用"
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved 2>/dev/null
        # 删除符号链接
        rm -f /etc/resolv.conf
    fi

    # 写入新配置
    cat > /etc/resolv.conf << EOF
# SmartDNS 接管 (由 smartdns-install.sh 生成)
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

    # 锁定文件 (容器内可能失败)
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        log_info "已锁定 /etc/resolv.conf (防止被覆盖)"
    else
        log_warn "无法锁定 resolv.conf (可能在容器或无特权环境)"
    fi

    # 接管 dhcpcd
    if command -v dhcpcd >/dev/null 2>&1 && [ -f /etc/dhcpcd.conf ]; then
        if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
            echo "# SmartDNS: 禁止 dhcpcd 修改 resolv.conf" >> /etc/dhcpcd.conf
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf
            log_info "dhcpcd 已配置"
        fi
    fi

    # 接管 NetworkManager
    if [ -d /etc/NetworkManager/conf.d ]; then
        cat > /etc/NetworkManager/conf.d/99-smartdns.conf << 'EOF'
[main]
dns=none
EOF
        log_info "NetworkManager DNS 已禁用"
        if [ "$INIT" = "systemd" ]; then
            systemctl restart NetworkManager 2>/dev/null || true
        fi
    fi

    log_info "系统 DNS 已设置为本地 SmartDNS (127.0.0.1)"
}

#==================================================
# 第五步: 启动服务
#==================================================
start_service() {
    log_step "启动 SmartDNS 服务..."

    case "$INIT" in
        systemd)
            # 生成 systemd 服务文件
            cat > /etc/systemd/system/smartdns.service << EOF
[Unit]
Description=SmartDNS Server
Documentation=https://github.com/pymumu/smartdns
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
            systemctl enable smartdns >/dev/null 2>&1
            systemctl restart smartdns
            
            # 检查状态
            sleep 1
            if systemctl is-active smartdns >/dev/null 2>&1; then
                log_info "SmartDNS 服务已启动 (systemd)"
            else
                log_error "SmartDNS 服务启动失败"
                systemctl status smartdns --no-pager -l
                exit 1
            fi
            ;;

        openrc)
            # 确保有 OpenRC 脚本
            if [ ! -f /etc/init.d/smartdns ]; then
                cat > /etc/init.d/smartdns << EOF
#!/sbin/openrc-run
name="SmartDNS"
description="SmartDNS Server"

command="${SMARTDNS_BIN}"
command_args="-c /etc/smartdns/smartdns.conf"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
                chmod +x /etc/init.d/smartdns
            else
                # 确保使用正确配置文件
                sed -i 's|command_args=.*|command_args="-c /etc/smartdns/smartdns.conf"|' /etc/init.d/smartdns
            fi
            
            rc-update add smartdns default 2>/dev/null
            rc-service smartdns restart 2>/dev/null
            
            sleep 1
            if rc-service smartdns status 2>/dev/null | grep -q "started"; then
                log_info "SmartDNS 服务已启动 (OpenRC)"
            else
                log_warn "SmartDNS 状态检查失败，请手动检查"
            fi
            ;;

        *)
            log_warn "无法自动管理服务，请手动启动:"
            echo "  ${SMARTDNS_BIN} -c /etc/smartdns/smartdns.conf &"
            
            # 尝试直接启动
            $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf &
            sleep 1
            if pgrep smartdns >/dev/null 2>&1; then
                log_info "SmartDNS 已后台运行 (PID: $(pgrep smartdns))"
            fi
            ;;
    esac
}

#==================================================
# 第六步: 验证与完成
#==================================================
verify_installation() {
    log_step "验证 DNS 解析..."
    sleep 2

    # 获取监听端口
    local test_port=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -oP ':\K\d+' | head -1)
    test_port=${test_port:-53}

    echo ""
    log_info "测试 IPv4 解析 (端口 $test_port):"
    
    # 兼容不同 nslookup 实现
    if nslookup google.com 127.0.0.1 2>/dev/null | grep -qE "Address|地址"; then
        log_info "✓ IPv4 解析正常"
    elif nslookup -type=a google.com 127.0.0.1 2>/dev/null | grep -qE "Address|地址"; then
        log_info "✓ IPv4 解析正常"
    else
        log_warn "✗ IPv4 解析测试失败 - 请检查防火墙/端口占用"
        log_warn "  诊断命令: ss -tuln | grep $test_port"
    fi

    echo ""
    if [ -n "$DEFAULT_IPV6" ]; then
        log_info "测试 IPv6 解析:"
        if nslookup google.com ::1 2>/dev/null | grep -qE "Address|地址"; then
            log_info "✓ IPv6 解析正常"
        else
            log_warn "✗ IPv6 解析测试失败或未完全支持"
        fi
    fi

    echo ""
    log_info "测试 DoH 上游连通性:"
    if curl -s --max-time 5 https://cloudflare-dns.com/dns-query?name=google.com >/dev/null 2>&1; then
        log_info "✓ Cloudflare DoH 可达"
    else
        log_warn "✗ Cloudflare DoH 不可达 (可能被防火墙阻止)"
    fi

    # 完成信息
    echo ""
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}  ✓ SmartDNS 部署完成!${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "系统环境: ${BLUE}$OS $VER | $INIT | $VIRT${NC}"
    echo -e "监听地址: ${BLUE}127.0.0.1:$test_port, [::1]:$test_port${NC}"
    echo -e "配置文件: ${BLUE}/etc/smartdns/smartdns.conf${NC}"
    echo -e "日志文件: ${BLUE}/var/log/smartdns.log${NC}"
    echo -e "上游 DNS: ${BLUE}Cloudflare / Google / Quad9 (DoH/DoT/UDP)${NC}"
    echo ""
    echo -e "${YELLOW}常用命令:${NC}"
    echo -e "  测试解析: ${GREEN}nslookup youtube.com 127.0.0.1${NC}"
    echo -e "  查看日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
    echo -e "  修改配置: ${GREEN}nano /etc/smartdns/smartdns.conf${NC}"
    echo -e "  重启服务: ${GREEN}systemctl restart smartdns${NC} (或 rc-service smartdns restart)"
    echo -e "  卸载脚本: ${GREEN}$0 --uninstall${NC}"
    echo ""
}

#==================================================
# 主执行流程
#==================================================
main() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   SmartDNS 智能部署脚本 v2.0${NC}"
    echo -e "${BLUE}   自动检测 | 稳定版 | DoH支持 | 容器兼容${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""

    # 参数处理
    case "${1:-}" in
        --uninstall|-u)
            # 先检测环境再卸载
            detect_environment 2>/dev/null || {
                OS="unknown"
                INIT="none"
                PKG_MANAGER="apt"
            }
            uninstall_smartdns
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  无参数      正常安装 SmartDNS"
            echo "  --uninstall 卸载 SmartDNS 并恢复系统 DNS"
            echo "  --help      显示此帮助信息"
            exit 0
            ;;
    esac

    # 捕获中断信号
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
