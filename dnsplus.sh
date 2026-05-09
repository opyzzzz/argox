#!/bin/bash

# =================================================================
# 脚本名称: Secure-DNS 终极暴力部署脚本 v2.0
# 适用系统: Debian / Ubuntu / Alpine (x86_64 / ARM)
# 核心优化: 容器环境适配、多重防护、优雅降级
# =================================================================

set -euo pipefail

# 颜色输出
readonly INFO='\033[0;32m[INFO]\033[0m'
readonly OK='\033[0;34m[OK]\033[0m'
readonly WARN='\033[0;33m[WARN]\033[0m'
readonly ERROR='\033[0;31m[ERROR]\033[0m'

# 常量定义
readonly STUBBY_CONF="/etc/stubby/stubby.yml"
readonly RESOLV_CONF="/etc/resolv.conf"
readonly LOG_DIR="/var/log/secure-dns"
readonly DAEMON_SCRIPT="/usr/local/bin/dns_daemon.sh"
readonly SHA_FILE="/etc/stubby/stubby.yml.sha256"
readonly BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
readonly HEAD_CONF="/etc/resolvconf/resolv.conf.d/head"
readonly TAIL_CONF="/etc/resolvconf/resolv.conf.d/tail"  # 修正：原脚本缺少这个

# 检测运行环境
detect_environment() {
    # 检测容器环境
    if [ -f /.dockerenv ] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER=true
        echo -e "${WARN} 检测到容器环境，将启用特殊处理逻辑"
    else
        IS_CONTAINER=false
    fi
    
    # 检测系统类型
    if [ -f /etc/alpine-release ]; then
        OS="Alpine"
    else
        OS="Debian"
    fi
}

# 1. 系统依赖安装
install_deps() {
    echo -e "${INFO} 正在安装系统核心组件..."
    case $OS in
        "Alpine")
            apk add --no-cache stubby ca-certificates openssl coreutils \
                bind-tools net-tools sed bash
            ;;
        "Debian")
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq stubby ca-certificates openssl coreutils \
                dnsutils net-tools sed bash
            # 彻底禁用 systemd-resolved
            systemctl stop systemd-resolved 2>/dev/null || true
            systemctl disable systemd-resolved 2>/dev/null || true
            systemctl mask systemd-resolved 2>/dev/null || true
            
            # 移除 resolved 的 stub listener
            if [ -L /etc/resolv.conf ]; then
                rm -f /etc/resolv.conf
                touch /etc/resolv.conf
            fi
            ;;
    esac
}

# 2. Stubby DoT 高性能配置
config_stubby() {
    echo -e "${INFO} 正在配置 Stubby 加密链路 (DoT)..."
    mkdir -p /etc/stubby "$LOG_DIR"
    chmod 750 "$LOG_DIR"

    # 增强配置：添加更多上游、故障转移、超时优化
    cat > "$STUBBY_CONF" <<'EOF'
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
  - address_data: 2606:4700:4700::1111
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 1.0.0.1
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 2606:4700:4700::1001
    tls_auth_name: "cloudflare-dns.com"
  # Quad9 (备用)
  - address_data: 9.9.9.9
    tls_auth_name: "dns.quad9.net"
  - address_data: 149.112.112.112
    tls_auth_name: "dns.quad9.net"
EOF

    # 创建校验和
    sha256sum "$STUBBY_CONF" > "$SHA_FILE"
    cp "$STUBBY_CONF" "$BACKUP_CONF"
    echo -e "${OK} Stubby 配置已优化并备份。"
}

# 3. 改进的守护进程脚本
deploy_daemon() {
    echo -e "${INFO} 正在部署智能守护进程..."
    
    cat > "$DAEMON_SCRIPT" <<'INNER_EOF'
#!/bin/bash

readonly RESOLV_CONF="/etc/resolv.conf"
readonly STUBBY_CONF="/etc/stubby/stubby.yml"
readonly SHA_FILE="/etc/stubby/stubby.yml.sha256"
readonly BACKUP_CONF="/etc/stubby/.stubby.yml.bak"
readonly LOG_DIR="/var/log/secure-dns"

# 日志函数
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_DIR}/daemon.log"
}

# 修复 resolv.conf
fix_resolv() {
    # 检查文件是否存在
    if [ ! -f "$RESOLV_CONF" ]; then
        touch "$RESOLV_CONF"
        log_msg "resolv.conf 不存在，已创建"
    fi
    
    # 检查是否为符号链接（Docker环境中常见）
    if [ -L "$RESOLV_CONF" ]; then
        # 获取链接目标
        local target=$(readlink -f "$RESOLV_CONF")
        log_msg "检测到符号链接: $target"
        # 如果是链接，需要修改实际文件
        RESOLV_CONF="$target"
    fi
    
    # 检查第一行是否包含 127.0.0.1
    local first_line=$(head -n 1 "$RESOLV_CONF" 2>/dev/null)
    if [[ ! "$first_line" =~ 127\.0\.0\.1 ]]; then
        # 尝试解锁并写入
        chattr -i "$RESOLV_CONF" 2>/dev/null || true
        
        cat > "$RESOLV_CONF" <<EOF
nameserver 127.0.0.1
nameserver ::1
options timeout:2
options attempts:3
options edns0
EOF
        log_msg "已修正 resolv.conf"
        
        # 容器环境不强制锁定（通常无效）
        if [ ! -f /.dockerenv ]; then
            chattr +i "$RESOLV_CONF" 2>/dev/null || log_msg "无法锁定文件（可能不支持chattr）"
        fi
    fi
}

# 检查 Stubby 服务状态
check_stubby() {
    # 使用多种方法检查服务状态
    local stubby_running=false
    
    # 方法1：端口检查
    if netstat -tunlp 2>/dev/null | grep -q ":53 " || \
       ss -tunlp 2>/dev/null | grep -q ":53 "; then
        stubby_running=true
    fi
    
    # 方法2：进程检查
    if pgrep -x stubby >/dev/null; then
        stubby_running=true
    fi
    
    if ! $stubby_running; then
        log_msg "Stubby 未运行，尝试重启..."
        if command -v systemctl >/dev/null && systemctl is-active stubby >/dev/null 2>&1; then
            systemctl restart stubby
        elif command -v rc-service >/dev/null; then
            rc-service stubby restart
        else
            stubby -C "$STUBBY_CONF" &
        fi
    fi
}

# 检查配置文件完整性
check_config_integrity() {
    if ! sha256sum -c "$SHA_FILE" >/dev/null 2>&1; then
        log_msg "配置文件校验失败，从备份恢复"
        cp "$BACKUP_CONF" "$STUBBY_CONF"
        sha256sum "$STUBBY_CONF" > "$SHA_FILE"
        
        # 重启服务
        if command -v systemctl >/dev/null; then
            systemctl restart stubby
        elif command -v rc-service >/dev/null; then
            rc-service stubby restart
        fi
    fi
}

# DNS解析测试
test_resolution() {
    if nslookup -timeout=2 google.com 127.0.0.1 >/dev/null 2>&1; then
        return 0
    else
        log_msg "DNS解析测试失败"
        return 1
    fi
}

# 主循环
main_loop() {
    local fix_count=0
    local last_test_time=0
    
    while true; do
        # 修复 resolv.conf
        fix_resolv
        
        # 检查 Stubby 服务
        check_stubby
        
        # 每分钟检查一次配置完整性
        if [ $(( $(date +%s) - 60 )) -ge $last_test_time ]; then
            check_config_integrity
        fi
        
        # 每30秒测试一次DNS解析
        local current_time=$(date +%s)
        if [ $(( current_time - 30 )) -ge $last_test_time ]; then
            if ! test_resolution; then
                ((fix_count++))
                if [ $fix_count -ge 3 ]; then
                    log_msg "连续解析失败 $fix_count 次，可能需要人工干预"
                    fix_count=0
                fi
            else
                fix_count=0
            fi
            last_test_time=$current_time
        fi
        
        # 容器环境使用更短的检查间隔
        if [ -f /.dockerenv ]; then
            sleep 2
        else
            sleep 5
        fi
    done
}

# 启动主循环
mkdir -p "$LOG_DIR"
main_loop
INNER_EOF

    chmod +x "$DAEMON_SCRIPT"

    # 创建服务
    case $OS in
        "Alpine")
            cat > /etc/init.d/dns-daemon <<EOF
#!/sbin/openrc-run
name="DNS Security Daemon"
description="Force 127.0.0.1 to resolv.conf"
command="$DAEMON_SCRIPT"
command_background=true
pidfile="/run/dns-daemon.pid"
EOF
            chmod +x /etc/init.d/dns-daemon
            rc-update add dns-daemon default
            rc-service dns-daemon restart
            ;;
        "Debian")
            # 改进的 systemd 服务文件
            cat > /etc/systemd/system/dns-daemon.service <<EOF
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
# 环境变量
Environment=HOME=/root
# 安全设置
NoNewPrivileges=no
# 日志
StandardOutput=append:$LOG_DIR/daemon.log
StandardError=append:$LOG_DIR/daemon.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable dns-daemon
            systemctl restart dns-daemon
            ;;
    esac
}

# 4. 改进的 DHCP 防护
disable_dhcp_overwrites() {
    echo -e "${INFO} 正在配置多层DNS防护..."
    
    # 方法1: dhcpcd 配置
    if [ -f /etc/dhcpcd.conf ]; then
        if ! grep -q "^nohook resolv.conf" /etc/dhcpcd.conf; then
            echo "nohook resolv.conf" >> /etc/dhcpcd.conf
        fi
        echo -e "${OK} dhcpcd hook 已禁用"
    fi
    
    # 方法2: resolvconf head 文件
    if [ -d /etc/resolvconf/resolv.conf.d ]; then
        cat > "$HEAD_CONF" <<EOF
# Dynamic resolv.conf(5) file for glibc resolver(3) generated by resolvconf(8)
#     DO NOT EDIT THIS FILE BY HAND -- YOUR CHANGES WILL BE OVERWRITTEN
nameserver 127.0.0.1
nameserver ::1
EOF
        echo -e "${OK} resolvconf head 已配置"
    fi
    
    # 方法3: NetworkManager 配置（如果存在）
    if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
        # 创建 DNS 配置
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/90-dns.conf <<EOF
[main]
dns=none
rc-manager=file
EOF
        echo -e "${OK} NetworkManager DNS 已配置"
    fi
    
    # 方法4: 设置不可变属性（非容器环境）
    if ! $IS_CONTAINER; then
        chattr -i "$RESOLV_CONF" 2>/dev/null || true
        chattr +i "$RESOLV_CONF" 2>/dev/null && echo -e "${OK} 文件锁定已启用" || echo -e "${WARN} chattr 不可用（某些文件系统不支持）"
    fi
}

# 5. 配置 stubby 启动选项
configure_stubby_service() {
    echo -e "${INFO} 正在优化 Stubby 服务配置..."
    
    case $OS in
        "Debian")
            # 修改 Stubby 启动参数
            if [ -f /etc/default/stubby ]; then
                sed -i 's/^DAEMON_ARGS=.*/DAEMON_ARGS="-g -C \/etc\/stubby\/stubby.yml"/' /etc/default/stubby
            fi
            
            # 确保 stubby 启用
            systemctl enable stubby
            ;;
        "Alpine")
            rc-update add stubby default
            ;;
    esac
}

# 6. 代理集成
integrate_proxy() {
    echo -e "${INFO} 正在扫描并集成代理软件..."
    local cfgs=(
        "/etc/xray/config.json"
        "/etc/sing-box/config.json"
        "/usr/local/etc/xray/config.json"
        "/root/sing-box/config.json"
    )
    
    local found=false
    for c in "${cfgs[@]}"; do
        if [ -f "$c" ]; then
            # 备份原文件
            cp "$c" "${c}.bak"
            sed -i 's/"address":\s*"[^"]*"/"address": "127.0.0.1"/g' "$c"
            found=true
            echo -e "${OK} 已集成: $c"
        fi
    done
    
    if $found; then
        # 优雅重启代理
        pkill -HUP xray 2>/dev/null || true
        pkill -HUP sing-box 2>/dev/null || true
    else
        echo -e "${WARN} 未发现代理配置"
    fi
}

# 7. 改进的清理与校验
finalize() {
    echo -e "${INFO} 正在启动服务并校验解析状态..."
    
    # 重启 Stubby
    case $OS in
        "Alpine")
            rc-service stubby restart 2>/dev/null || stubby -C "$STUBBY_CONF" &
            ;;
        "Debian")
            systemctl restart stubby || stubby -C "$STUBBY_CONF" &
            ;;
    esac
    
    # 等待服务启动
    sleep 3
    
    # 多次测试DNS解析
    local success=false
    for i in {1..3}; do
        if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
            success=true
            break
        fi
        sleep 2
    done
    
    if $success; then
        echo -e "${OK} DoT 链路解析正常"
    else
        echo -e "${ERROR} DoT 链路解析失败"
        echo -e "${WARN} 可能原因：853端口被防火墙拦截；上游DNS不可达；容器网络限制"
        echo -e "${INFO} 查看日志: journalctl -u stubby 或 $LOG_DIR/daemon.log"
    fi

    # 验证文件接管
    if grep -q "127.0.0.1" "$RESOLV_CONF"; then
        echo -e "${OK} 全局解析已锁定至本地Stubby"
    else
        echo -e "${ERROR} resolv.conf 配置异常"
    fi
}

# 主流程
main() {
    echo -e "${INFO} Secure-DNS v2.0 开始部署..."
    
    detect_environment
    install_deps
    config_stubby
    disable_dhcp_overwrites
    configure_stubby_service
    integrate_proxy
    deploy_daemon
    finalize
    
    echo -e "\n${OK} 部署完成！"
    echo -e "${INFO} 特性: 容器感知 | 多层防护 | 智能守护 | 详细日志"
    echo -e "${INFO} 守护进程日志: $LOG_DIR/daemon.log"
    echo -e "${INFO} 测试: nslookup google.com 127.0.0.1"
}

# 执行
main "$@"
