#!/bin/sh
#==================================================
# SmartDNS 智能部署脚本 (修复版 v2.6)
# 功能: 自动检测环境 -> 安装稳定版 -> 动态配置
# 兼容: Alpine/Debian/Ubuntu (LXC/KVM/NAT/Docker)
# 修复: 端口冲突检测、进程启动验证
# 更新: 2026-05-11
#==================================================

set +e

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

# 下载函数
download_file() {
    local url="$1"
    local output="$2"
    
    log_info "下载: $url"
    
    if wget -q --timeout=30 --tries=1 -O "$output" "$url" 2>/dev/null; then
        return 0
    fi
    
    log_warn "wget 失败，尝试 curl..."
    if curl -sL --max-time 30 -o "$output" "$url" 2>/dev/null; then
        return 0
    fi
    
    return 1
}

# 检测端口是否被占用
check_port_available() {
    local port="$1"
    
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln 2>/dev/null | grep -q ":${port} "; then
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
            return 1
        fi
    else
        # 尝试直接绑定测试
        (echo >/dev/tcp/127.0.0.1/${port}) 2>/dev/null && return 1
    fi
    
    return 0
}

# 显示端口占用信息
show_port_usage() {
    local port="$1"
    log_warn "端口 ${port} 已被占用:"
    
    if command -v ss >/dev/null 2>&1; then
        ss -tulnp 2>/dev/null | grep ":${port} " || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulnp 2>/dev/null | grep ":${port} " || true
    fi
}

# 等待进程启动
wait_for_process() {
    local max_wait=10
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if pgrep smartdns >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    return 1
}

# 架构映射
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l|armv7)   echo "arm" ;;
        i386|i686)      echo "x86" ;;
        mips)           echo "mips" ;;
        mipsel)         echo "mipsel" ;;
        *)
            log_error "不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
}

#==================================================
# 环境检测
#==================================================
detect_environment() {
    log_step "环境检测..."

    # 系统
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        VER=$(cat /etc/alpine-release)
        PKG_MGR="apk"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        PKG_MGR="apt"
    else
        log_error "无法识别的系统"
        exit 1
    fi
    log_info "系统: $OS $VER"

    # Init
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
    else
        VIRT="kvm"
    fi
    log_info "虚拟化: $VIRT"

    # IPv4
    DEFAULT_IPV4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    [ -n "$DEFAULT_IPV4" ] && log_info "IPv4: $DEFAULT_IPV4" || log_warn "无 IPv4"
}

#==================================================
# 安装 SmartDNS
#==================================================
install_smartdns() {
    log_step "安装 SmartDNS..."

    # 方法1: 包管理器
    case "$PKG_MGR" in
        apk)
            log_info "尝试 apk..."
            apk update --quiet 2>/dev/null
            if apk search smartdns 2>/dev/null | grep -q "^smartdns"; then
                apk add --no-cache smartdns && {
                    SMARTDNS_BIN=$(which smartdns 2>/dev/null || echo "/usr/sbin/smartdns")
                    log_info "✓ apk 安装成功"
                    mkdir -p /etc/smartdns
                    return 0
                }
            fi
            ;;
        apt)
            log_info "尝试 apt..."
            apt-get update -qq 2>/dev/null
            if apt-cache show smartdns >/dev/null 2>&1; then
                apt-get install -y -qq smartdns && {
                    SMARTDNS_BIN=$(which smartdns 2>/dev/null || echo "/usr/sbin/smartdns")
                    log_info "✓ apt 安装成功"
                    mkdir -p /etc/smartdns
                    return 0
                }
            fi
            ;;
    esac

    # 方法2: GitHub Releases
    log_info "从 GitHub 下载..."
    local ARCH=$(get_arch)
    local URL="https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
    
    if download_file "$URL" "/tmp/smartdns"; then
        if [ -s /tmp/smartdns ]; then
            chmod +x /tmp/smartdns
            mv /tmp/smartdns /usr/bin/smartdns
            SMARTDNS_BIN="/usr/bin/smartdns"
            mkdir -p /etc/smartdns
            log_info "✓ 下载成功"
        else
            log_error "下载的文件为空"
            exit 1
        fi
    else
        echo ""
        log_error "下载失败，可能原因："
        log_error "  - GitHub 不可达（LXC/NAT 环境常见）"
        log_error "  - DNS 解析问题"
        echo ""
        log_info "手动安装步骤:"
        log_info "  1. 浏览器访问: https://github.com/pymumu/smartdns/releases/latest"
        log_info "  2. 下载文件: smartdns-${ARCH}"
        log_info "  3. 上传到: /usr/bin/smartdns && chmod +x /usr/bin/smartdns"
        log_info "  4. 重新运行本脚本"
        exit 1
    fi

    # 容器权限
    if [ "$VIRT" = "lxc" ] || [ "$VIRT" = "docker" ]; then
        if command -v setcap >/dev/null 2>&1; then
            setcap cap_net_bind_service=+ep "$SMARTDNS_BIN" 2>/dev/null
        fi
    fi
}

#==================================================
# 生成配置
#==================================================
generate_config() {
    log_step "生成配置..."
    local CONF="/etc/smartdns/smartdns.conf"
    
    # 智能选择端口
    local PRIMARY_PORT="53"
    local FALLBACK_PORT="5353"
    local SELECTED_PORT=""
    
    # 检测端口可用性
    if check_port_available "$PRIMARY_PORT"; then
        SELECTED_PORT="$PRIMARY_PORT"
        log_info "✓ 端口 ${PRIMARY_PORT} 可用"
    elif check_port_available "$FALLBACK_PORT"; then
        SELECTED_PORT="$FALLBACK_PORT"
        show_port_usage "$PRIMARY_PORT"
        log_warn "端口 ${PRIMARY_PORT} 被占用，使用备用端口: ${FALLBACK_PORT}"
    else
        # 两个端口都被占用，尝试其他端口
        for port in 5354 5355 8053 9053; do
            if check_port_available "$port"; then
                SELECTED_PORT="$port"
                log_warn "使用端口: ${port}"
                break
            fi
        done
        if [ -z "$SELECTED_PORT" ]; then
            log_error "所有备用端口都被占用"
            exit 1
        fi
    fi
    
    log_info "监听端口: ${SELECTED_PORT}"

    cat > "$CONF" << EOF
# SmartDNS 配置 (自动生成)
server-name smartdns
bind [::]:${SELECTED_PORT}
bind 0.0.0.0:${SELECTED_PORT}

cache-size 4096
prefetch-domain yes
serve-expired yes

log-level info
log-file /var/log/smartdns.log
log-size 2m
log-num 2

speed-check-mode ping,tcp:443
response-mode fastest-ip

rr-ttl 300
rr-ttl-min 60

force-AAAA-SOA yes
edns-client-subnet

# 上游 DNS
server 1.1.1.1
server 8.8.8.8
server-https https://cloudflare-dns.com/dns-query
server-https https://dns.google/dns-query
server-https https://dns.quad9.net/dns-query
EOF

    log_info "✓ 配置: $CONF"
    
    # 保存端口号供后续使用
    echo "$SELECTED_PORT" > /tmp/smartdns_port
}

#==================================================
# 接管系统 DNS
#==================================================
configure_system_dns() {
    log_step "接管 DNS..."
    
    # 获取实际监听端口
    local DNS_PORT=$(cat /tmp/smartdns_port 2>/dev/null || echo "53")

    # 备份
    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null
    fi

    chattr -i /etc/resolv.conf 2>/dev/null

    # systemd-resolved
    if [ "$INIT" = "systemd" ]; then
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        rm -f /etc/resolv.conf
    fi

    # 写入配置（始终使用 127.0.0.1:53，因为本地通信不受端口限制）
    cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF

    # 如果使用了非53端口，添加配置说明
    if [ "$DNS_PORT" != "53" ]; then
        log_info "SmartDNS 监听端口: ${DNS_PORT}"
        log_info "resolv.conf 使用默认 127.0.0.1:53，请确保配置正确"
    fi

    chattr +i /etc/resolv.conf 2>/dev/null
    log_info "✓ DNS -> 127.0.0.1"
}

#==================================================
# 启动服务
#==================================================
start_service() {
    log_step "启动服务..."

    case "$INIT" in
        openrc)
            log_info "配置 OpenRC 服务..."
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
            
            log_info "启动 SmartDNS..."
            rc-update add smartdns default 2>/dev/null
            
            # 先停止可能存在的旧进程
            rc-service smartdns stop 2>/dev/null
            pkill smartdns 2>/dev/null
            sleep 1
            
            # 启动服务
            rc-service smartdns start 2>/dev/null
            
            # 等待并验证
            log_info "等待进程启动..."
            if wait_for_process; then
                local PID=$(pgrep smartdns | head -1)
                log_info "✓ SmartDNS 运行中 (PID: ${PID})"
                
                # 验证 DNS 响应
                sleep 1
                local PORT=$(cat /tmp/smartdns_port 2>/dev/null || echo "53")
                if nslookup google.com 127.0.0.1 2>/dev/null | grep -q "Address"; then
                    log_info "✓ DNS 服务验证成功"
                else
                    log_warn "⚠ DNS 服务进程运行但解析测试失败"
                    log_info "查看配置: cat /etc/smartdns/smartdns.conf"
                    log_info "查看日志: tail /var/log/smartdns.log"
                fi
            else
                log_error "SmartDNS 启动失败"
                log_error "查看日志:"
                echo ""
                tail -20 /var/log/smartdns.log 2>/dev/null || echo "无法读取日志文件"
                echo ""
                
                # 尝试直接启动并查看错误
                log_info "尝试直接启动以查看错误..."
                $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf &
                sleep 2
                
                if pgrep smartdns >/dev/null 2>&1; then
                    log_info "✓ 直接启动成功"
                else
                    log_error "直接启动也失败，请检查配置"
                    exit 1
                fi
            fi
            ;;
            
        systemd)
            cat > /etc/systemd/system/smartdns.service << EOF
[Unit]
Description=SmartDNS
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
            systemctl stop smartdns 2>/dev/null
            systemctl enable smartdns 2>/dev/null
            systemctl restart smartdns
            
            if wait_for_process; then
                log_info "✓ SmartDNS 运行中"
            else
                log_error "systemd 启动失败"
                journalctl -u smartdns --no-pager -n 10
                exit 1
            fi
            ;;
            
        *)
            log_info "直接启动 SmartDNS..."
            pkill smartdns 2>/dev/null
            $SMARTDNS_BIN -c /etc/smartdns/smartdns.conf &
            
            if wait_for_process; then
                log_info "✓ SmartDNS 后台运行"
            else
                log_error "启动失败"
                tail -20 /var/log/smartdns.log 2>/dev/null
                exit 1
            fi
            ;;
    esac
    
    # 清理临时文件
    rm -f /tmp/smartdns_port
}

#==================================================
# 卸载
#==================================================
uninstall_smartdns() {
    log_step "卸载 SmartDNS..."

    case "$INIT" in
        systemd)
            systemctl stop smartdns 2>/dev/null
            systemctl disable smartdns 2>/dev/null
            rm -f /etc/systemd/system/smartdns.service
            ;;
        openrc)
            rc-service smartdns stop 2>/dev/null
            rc-update del smartdns 2>/dev/null
            rm -f /etc/init.d/smartdns
            ;;
    esac

    pkill smartdns 2>/dev/null

    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
        local bak=$(ls -t /etc/resolv.conf.bak.* 2>/dev/null | head -1)
        if [ -n "$bak" ]; then
            cp "$bak" /etc/resolv.conf
        else
            echo "nameserver 1.1.1.1" > /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        fi
    fi

    [ -f /etc/dhcpcd.conf ] && sed -i '/nohook resolv.conf/d' /etc/dhcpcd.conf
    rm -f /etc/NetworkManager/conf.d/99-smartdns.conf
    rm -f /usr/bin/smartdns /usr/sbin/smartdns
    rm -rf /etc/smartdns
    rm -f /var/log/smartdns.log*

    log_info "卸载完成"
    exit 0
}

#==================================================
# 验证
#==================================================
verify_dns() {
    log_step "验证 DNS..."
    
    local PORT=$(grep "^bind" /etc/smartdns/smartdns.conf | grep -oP ':\K\d+' | head -1)
    
    echo ""
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${GREEN}  ✓ SmartDNS 部署完成${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "系统: ${BLUE}$OS${NC}"
    echo -e "配置: ${BLUE}/etc/smartdns/smartdns.conf${NC}"
    echo -e "日志: ${BLUE}/var/log/smartdns.log${NC}"
    echo -e "端口: ${BLUE}127.0.0.1:${PORT:-53}${NC}"
    echo ""
    echo -e "${YELLOW}测试命令:${NC}"
    echo -e "  本地: ${GREEN}nslookup google.com 127.0.0.1${NC}"
    echo -e "  指定端口: ${GREEN}nslookup google.com 127.0.0.1 -port=${PORT:-53}${NC}"
    echo -e "  查看日志: ${GREEN}tail -f /var/log/smartdns.log${NC}"
    echo -e "  重启服务: ${GREEN}rc-service smartdns restart${NC}"
    echo -e "  卸载: ${GREEN}$0 --uninstall${NC}"
    echo ""
}

#==================================================
# 主函数
#==================================================
main() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}   SmartDNS 智能部署 v2.6${NC}"
    echo -e "${BLUE}   端口冲突检测 | 进程验证${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""

    case "${1:-}" in
        --uninstall|-u)
            [ -f /etc/alpine-release ] && INIT="openrc" || INIT="none"
            uninstall_smartdns
            ;;
        --help|-h)
            echo "用法: $0 [--uninstall|--help]"
            exit 0
            ;;
    esac

    trap 'echo ""; log_error "中断"; rm -f /tmp/smartdns_port; exit 1' INT TERM

    detect_environment
    install_smartdns
    generate_config
    configure_system_dns
    start_service
    verify_dns
}

main "$@"
