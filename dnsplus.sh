#!/bin/bash

# =================================================================
# Secure-DNS 终极部署脚本 v3.1
# 加密 DNS (DoT) 自动部署 + 自检
# 支持: Debian/Ubuntu/Alpine | 使用 Cloudflare & Google DNS
# =================================================================

set -euo pipefail

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# 路径
STUBBY_CONF="/etc/stubby/stubby.yml"
SHA_FILE="/etc/stubby/stubby.yml.sha256"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
DAEMON_SCRIPT="/usr/local/bin/dns-daemon.sh"
LOG_DIR="/var/log/secure-dns"
RESOLV_CONF="/etc/resolv.conf"

# 统计
OK_COUNT=0
FAIL_COUNT=0

# 日志函数
log_info()  { echo -e "${GREEN}[✓]${NC} $1"; ((OK_COUNT++)); }
log_warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; ((FAIL_COUNT++)); }
log_step()  { echo -e "\n${CYAN}▶${NC} ${BLUE}$1${NC}"; }

# 检测环境
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    else
        OS="debian"
    fi
    
    if [ -f /.dockerenv ] || grep -qE 'docker|lxc|kubepods' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
    else
        IS_CONTAINER=false
    fi
}

# 安装依赖
install_deps() {
    log_step "安装依赖包"
    
    case $OS in
        alpine)
            apk add --no-cache stubby ca-certificates openssl coreutils bind-tools 2>&1 | tail -1
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq 2>/dev/null
            apt-get install -y -qq stubby ca-certificates openssl coreutils dnsutils 2>&1 | tail -1
            
            # 禁用 systemd-resolved
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop systemd-resolved 2>/dev/null || true
                systemctl disable systemd-resolved 2>/dev/null || true
                systemctl mask systemd-resolved 2>/dev/null || true
            fi
            
            # 移除软链接
            if [ -L "$RESOLV_CONF" ]; then
                rm -f "$RESOLV_CONF"
                touch "$RESOLV_CONF"
            fi
            ;;
    esac
    log_info "依赖安装完成"
}

# 配置 Stubby (仅 Cloudflare + Google)
config_stubby() {
    log_step "配置 Stubby 加密 DNS"
    
    mkdir -p /etc/stubby "$LOG_DIR"
    chmod 750 "$LOG_DIR"
    
    cat > "$STUBBY_CONF" << 'EOF'
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 10000
timeout: 5000
round_robin_upstreams: 1
listen_addresses:
  - 127.0.0.1@53
  - 0::1@53
upstream_recursive_servers:
  # Cloudflare
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 1.0.0.1
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 2606:4700:4700::1001
    tls_auth_name: "cloudflare-dns.com"
  # Google
  - address_data: 8.8.8.8
    tls_auth_name: "dns.google"
  - address_data: 8.8.4.4
    tls_auth_name: "dns.google"
  - address_data: 2001:4860:4860::8888
    tls_auth_name: "dns.google"
  - address_data: 2001:4860:4860::8844
    tls_auth_name: "dns.google"
EOF
    
    sha256sum "$STUBBY_CONF" > "$SHA_FILE"
    cp "$STUBBY_CONF" "$BACKUP_CONF"
    log_info "Stubby 配置完成 (Cloudflare + Google)"
}

# 部署守护进程
deploy_daemon() {
    log_step "部署 DNS 守护进程"
    
    cat > "$DAEMON_SCRIPT" << 'INNER_SCRIPT'
#!/bin/bash
RESOLV_CONF="/etc/resolv.conf"
STUBBY_CONF="/etc/stubby/stubby.yml"
SHA_FILE="/etc/stubby/stubby.yml.sha256"
BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
LOG_DIR="/var/log/secure-dns"

mkdir -p "$LOG_DIR"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_DIR}/daemon.log"
}

check_stubby() {
    # 端口检查 (最可靠)
    if ss -tunlp 2>/dev/null | grep -q ":53 .*stubby"; then
        return 0
    fi
    if netstat -tunlp 2>/dev/null | grep -q ":53 .*stubby"; then
        return 0
    fi
    
    # 进程检查
    if pgrep -f stubby >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

restart_stubby() {
    log_msg "Stubby 未运行，尝试重启..."
    
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled stubby >/dev/null 2>&1; then
        systemctl restart stubby 2>/dev/null && return 0
    fi
    
    if command -v rc-service >/dev/null 2>&1; then
        rc-service stubby restart 2>/dev/null && return 0
    fi
    
    killall stubby 2>/dev/null || true
    sleep 1
    stubby -C "$STUBBY_CONF" >/dev/null 2>&1 &
    return 0
}

fix_resolv() {
    local target="$RESOLV_CONF"
    
    if [ -L "$RESOLV_CONF" ]; then
        target=$(readlink -f "$RESOLV_CONF")
    fi
    
    if [ -f "$target" ]; then
        if grep -q "^nameserver 127.0.0.1" "$target" 2>/dev/null; then
            return 0
        fi
    fi
    
    log_msg "已修正 resolv.conf"
    
    # 尝试解锁
    if command -v chattr >/dev/null 2>&1; then
        chattr -i "$target" 2>/dev/null || true
    fi
    
    cat > "$target" <<EOF
nameserver 127.0.0.1
nameserver ::1
options timeout:2
options attempts:3
options edns0
EOF
}

check_config_integrity() {
    if ! sha256sum -c "$SHA_FILE" >/dev/null 2>&1; then
        log_msg "配置文件被篡改，从备份恢复"
        cp "$BACKUP_CONF" "$STUBBY_CONF"
        sha256sum "$STUBBY_CONF" > "$SHA_FILE"
        restart_stubby
    fi
}

# 主循环
last_config=$(date +%s)
last_test=$(date +%s)

while true; do
    now=$(date +%s)
    
    fix_resolv
    
    if ! check_stubby; then
        restart_stubby
    fi
    
    if [ $((now - last_config)) -gt 60 ]; then
        check_config_integrity
        last_config=$now
    fi
    
    if [ $((now - last_test)) -gt 30 ]; then
        if ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
            log_msg "DNS 解析测试失败"
        fi
        last_test=$now
    fi
    
    sleep 2
done
INNER_SCRIPT

    chmod +x "$DAEMON_SCRIPT"
    
    # 创建服务
    case $OS in
        debian)
            cat > /etc/systemd/system/dns-daemon.service << EOF
[Unit]
Description=DNS Security Daemon
After=network-online.target
Wants=network-online.target
Requires=stubby.service
After=stubby.service

[Service]
Type=simple
ExecStart=$DAEMON_SCRIPT
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable dns-daemon 2>/dev/null
            systemctl restart dns-daemon 2>/dev/null
            ;;
        alpine)
            cat > /etc/init.d/dns-daemon << EOF
#!/sbin/openrc-run
name="DNS Security Daemon"
description="Force 127.0.0.1 to resolv.conf"
command="$DAEMON_SCRIPT"
command_background=true
pidfile="/run/dns-daemon.pid"
EOF
            chmod +x /etc/init.d/dns-daemon
            rc-update add dns-daemon default 2>/dev/null
            rc-service dns-daemon restart 2>/dev/null
            ;;
    esac
    
    log_info "守护进程部署完成 (2秒检查间隔)"
}

# 锁定系统 DNS
lock_dns() {
    log_step "接管系统 DNS"
    
    # 方法1: dhcpcd
    if [ -f /etc/dhcpcd.conf ]; then
        grep -q "^nohook resolv.conf" /etc/dhcpcd.conf 2>/dev/null || \
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf
        log_info "dhcpcd hooks 已禁用"
    fi
    
    # 方法2: resolvconf
    if [ -d /etc/resolvconf/resolv.conf.d ]; then
        cat > /etc/resolvconf/resolv.conf.d/head << EOF
nameserver 127.0.0.1
nameserver ::1
EOF
        log_info "resolvconf head 已配置"
    fi
    
    # 方法3: 直接写入
    if [ ! -L "$RESOLV_CONF" ]; then
        cat > "$RESOLV_CONF" << EOF
nameserver 127.0.0.1
nameserver ::1
options timeout:2
options attempts:3
options edns0
EOF
        
        if ! $IS_CONTAINER && command -v chattr >/dev/null 2>&1; then
            chattr +i "$RESOLV_CONF" 2>/dev/null && \
                log_info "文件已锁定 (chattr +i)" || \
                log_warn "无法锁定文件 (文件系统不支持)"
        fi
    fi
    
    log_info "系统 DNS 已接管至 127.0.0.1"
}

# 启动 Stubby
start_stubby() {
    log_step "启动 Stubby 服务"
    
    case $OS in
        debian)
            systemctl enable stubby 2>/dev/null
            systemctl restart stubby 2>/dev/null || stubby -C "$STUBBY_CONF" &
            ;;
        alpine)
            rc-update add stubby default 2>/dev/null
            rc-service stubby restart 2>/dev/null || stubby -C "$STUBBY_CONF" &
            ;;
    esac
    
    sleep 2
    
    if pgrep -f stubby >/dev/null 2>&1; then
        log_info "Stubby 服务已启动"
    else
        log_error "Stubby 启动失败"
        return 1
    fi
}

# 自检
self_check() {
    log_step "执行自检"
    
    echo ""
    echo -e "  ${CYAN}═══════════════════════════════════${NC}"
    echo -e "  ${CYAN}  Secure-DNS 自检报告${NC}"
    echo -e "  ${CYAN}═══════════════════════════════════${NC}"
    echo ""
    
    # 1. 进程检查
    if ss -tunlp 2>/dev/null | grep -q ":53 .*stubby" || \
       netstat -tunlp 2>/dev/null | grep -q ":53 .*stubby"; then
        echo -e "  ${GREEN}[✓]${NC} Stubby 监听 :53"
    else
        echo -e "  ${RED}[✗]${NC} Stubby 未监听 :53"
    fi
    
    # 2. 配置文件
    if grep -q "^nameserver 127.0.0.1" "$RESOLV_CONF" 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} DNS 指向 127.0.0.1"
    else
        echo -e "  ${RED}[✗]${NC} DNS 未指向 127.0.0.1"
    fi
    
    # 3. 加密验证
    if grep -q "GETDNS_TRANSPORT_TLS" "$STUBBY_CONF" 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} DoT 加密已启用"
    else
        echo -e "  ${RED}[✗]${NC} DoT 加密未启用"
    fi
    
    # 4. 上游 DNS
    if grep -qE "cloudflare-dns\.com|dns\.google" "$STUBBY_CONF" 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} 上游: Cloudflare + Google"
    else
        echo -e "  ${RED}[✗]${NC} 上游配置异常"
    fi
    
    # 5. DNS 解析测试
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        local time_ms=$(dig google.com @127.0.0.1 2>/dev/null | grep "Query time:" | awk '{print $4}')
        echo -e "  ${GREEN}[✓]${NC} DNS 解析正常 (${time_ms:-N/A} ms)"
    else
        echo -e "  ${RED}[✗]${NC} DNS 解析失败"
    fi
    
    # 6. DoT 连通性
    if timeout 3 bash -c "echo >/dev/tcp/1.1.1.1/853" 2>/dev/null; then
        echo -e "  ${GREEN}[✓]${NC} DoT 端口 853 可达"
    else
        echo -e "  ${YELLOW}[!]${NC} DoT 端口 853 不可达"
    fi
    
    # 7. 守护进程
    if pgrep -f "dns-daemon.sh" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[✓]${NC} 守护进程运行中"
    else
        echo -e "  ${YELLOW}[!]${NC} 守护进程未运行"
    fi
    
    # 8. 配置备份
    if [ -f "$BACKUP_CONF" ]; then
        echo -e "  ${GREEN}[✓]${NC} 配置备份存在"
    else
        echo -e "  ${YELLOW}[!]${NC} 缺少配置备份"
    fi
    
    echo ""
    echo -e "  ${CYAN}═══════════════════════════════════${NC}"
    
    local total=$((OK_COUNT))
    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "\n  ${GREEN}自检通过 ✓${NC}\n"
    else
        echo -e "\n  ${RED}自检发现 ${FAIL_COUNT} 个问题${NC}\n"
    fi
}

# 显示使用信息
show_info() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  部署完成！${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  DNS:     127.0.0.1 (DoT 加密)"
    echo -e "  上游:    Cloudflare + Google"
    echo -e "  日志:    ${LOG_DIR}/daemon.log"
    echo -e "  守护:    2 秒间隔自动修正"
    echo ""
    echo -e "  测试:    nslookup google.com 127.0.0.1"
    echo -e "  验证:    dig +tls google.com @1.1.1.1"
    echo -e "  日志:    tail -f ${LOG_DIR}/daemon.log"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
}

# =================================================================
# 主流程
# =================================================================
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Secure-DNS 加密部署 v3.1              ║${NC}"
    echo -e "${BLUE}║   Cloudflare + Google DNS over TLS       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""
    
    detect_os
    echo -e "  系统: ${OS}  |  容器: ${IS_CONTAINER}"
    
    install_deps
    config_stubby
    lock_dns
    deploy_daemon
    start_stubby
    self_check
    show_info
}

main "$@"
