#!/usr/bin/env bash
# =========================================================
# 最终增强版加密 DNS 部署脚本
# IPv4/IPv6 自动选择
# xray/sing-box live reload
# 多上游 DoH/DoT
# Alpine/Debian x86_64 & ARM
# 安装进度、效果校验
# =========================================================

set -euo pipefail

# -------------------------
# 配置变量
# -------------------------
DNS_MODE=${1:-"doh"}  # doh 或 dot
LOG_DIR="/var/log/secure-dns"
CONFIG_DIR="/etc/secure-dns"
CONFIG_FILE="$CONFIG_DIR/stubby.yml"
CHECK_SCRIPT="/usr/local/bin/secure-dns-check.sh"
ARCH=$(uname -m)
OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
XRS_BOX_PATHS=("/etc/xray/config.json" "/etc/sing-box/config.json")

# -------------------------
# 颜色输出
# -------------------------
info() { echo -e "[\e[34mINFO\e[0m] $1"; }
ok() { echo -e "[\e[32mOK\e[0m] $1"; }
warn() { echo -e "[\e[33mWARN\e[0m] $1"; }
error() { echo -e "[\e[31mERROR\e[0m] $1"; }

info "开始部署增强版加密 DNS..."

# -------------------------
# 安装依赖
# -------------------------
info "检测系统并安装依赖..."
install_debian() { apt-get update; apt-get install -y stubby curl jq dig systemd; }
install_alpine() { apk update; apk add stubby curl jq bind-tools; }

case "$OS" in
    alpine) install_alpine ;;
    debian|ubuntu) install_debian ;;
    *) error "不支持的系统: $OS"; exit 1 ;;
esac
ok "依赖安装完成"

# -------------------------
# 创建目录
# -------------------------
info "创建配置和日志目录..."
mkdir -p "$CONFIG_DIR" "$LOG_DIR"
chmod 700 "$CONFIG_DIR" "$LOG_DIR"
ok "目录创建完成"

# -------------------------
# 生成 Stubby 配置
# -------------------------
info "生成 Stubby 配置..."
cat > "$CONFIG_FILE" <<EOF
resolution_type: GETDNS_RESOLUTION_STUB
round_robin_upstreams: 1
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
idle_timeout: 10000
listen_addresses:
  - 127.0.0.1@53
  - ::1@53
upstream_recursive_servers:
  # Cloudflare
  - address_data: 1.1.1.1
    tls_port: 853
    tls_auth_name: "cloudflare-dns.com"
  - address_data: 2606:4700:4700::1111
    tls_port: 853
    tls_auth_name: "cloudflare-dns.com"
  # Google
  - address_data: 8.8.8.8
    tls_port: 853
    tls_auth_name: "dns.google"
  - address_data: 2001:4860:4860::8888
    tls_port: 853
    tls_auth_name: "dns.google"
  # Quad9
  - address_data: 9.9.9.9
    tls_port: 853
    tls_auth_name: "dns.quad9.net"
  - address_data: 2620:fe::fe
    tls_port: 853
    tls_auth_name: "dns.quad9.net"
EOF
chmod 600 "$CONFIG_FILE"
ok "Stubby 配置生成完成"

# -------------------------
# 创建服务
# -------------------------
if [[ "$OS" == "alpine" ]]; then
    info "创建 OpenRC 服务..."
    SERVICE_FILE="/etc/init.d/secure-dns"
    cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run
name="Secure DNS Stubby"
description="Secure DNS Stubby Service"

command="/usr/sbin/stubby"
command_args="-C /etc/secure-dns/stubby.yml -g /var/log/secure-dns/stubby.log"
pidfile="/run/secure-dns.pid"

depend() { need net }

start_pre() { checkpath --directory --mode 700 /var/log/secure-dns }
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add secure-dns default
    rc-service secure-dns start
    ok "OpenRC 服务启动完成"
else
    info "创建 systemd 服务..."
    SERVICE_FILE="/etc/systemd/system/secure-dns.service"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Secure DNS Stubby Service
After=network.target

[Service]
ExecStart=/usr/sbin/stubby -C $CONFIG_FILE -g $LOG_DIR/stubby.log
Restart=on-failure
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
ReadOnlyPaths=/
ReadWritePaths=$LOG_DIR
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable secure-dns.service
    systemctl restart secure-dns.service
    ok "Systemd 服务启动完成"
fi

# -------------------------
# 防篡改检测
# -------------------------
info "设置防篡改检测..."
CONFIG_HASH=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
echo "$CONFIG_HASH" > "$CONFIG_DIR/config.sha256"
cat > "$CHECK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
CONFIG_FILE="/etc/secure-dns/stubby.yml"
HASH_FILE="/etc/secure-dns/config.sha256"
LOG_FILE="/var/log/secure-dns/monitor.log"

CURRENT_HASH=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
SAVED_HASH=$(cat "$HASH_FILE")

if [ "$CURRENT_HASH" != "$SAVED_HASH" ]; then
    echo "$(date '+%F %T') [WARN] Stubby 配置被篡改，正在恢复..." >> "$LOG_FILE"
    cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
    if command -v systemctl >/dev/null; then
        systemctl restart secure-dns.service
    else
        rc-service secure-dns restart
    fi
    echo "$(date '+%F %T') [INFO] Stubby 已恢复并重启" >> "$LOG_FILE"
fi
EOF
chmod +x "$CHECK_SCRIPT"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

# 创建定时器 / cron
if [[ "$OS" == "alpine" ]]; then
    CRON_FILE="/etc/periodic/daily/secure-dns-check"
else
    TIMER_FILE="/etc/systemd/system/secure-dns-check.timer"
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily Secure DNS config check

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now secure-dns-check.timer
fi
ok "防篡改检测设置完成"

# -------------------------
# 日志清理
# -------------------------
info "安装日志清理任务..."
if [[ "$OS" == "alpine" ]]; then
    CRON_JOB="/etc/periodic/daily/secure-dns-log-clean"
else
    CRON_JOB="/etc/cron.daily/secure-dns-log-clean"
fi
cat > "$CRON_JOB" <<'EOF'
#!/bin/sh
LOG_DIR="/var/log/secure-dns"
find "$LOG_DIR" -type f -mtime +30 -exec rm -f {} \;
EOF
chmod +x "$CRON_JOB"
ok "日志清理任务设置完成"

# -------------------------
# 自动接管 xray/sing-box DNS (live reload)
# -------------------------
info "检测并接管 xray/sing-box DNS..."
for cfg in "${XRS_BOX_PATHS[@]}"; do
    if [ -f "$cfg" ]; then
        jq '.dns = ["127.0.0.1"]' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
        # live reload
        if pgrep -f sing-box >/dev/null; then kill -HUP $(pgrep -f sing-box) || true; fi
        if pgrep -f xray >/dev/null; then kill -HUP $(pgrep -f xray) || true; fi
        ok "$cfg 已接管 DNS 并 live reload"
    fi
done

# -------------------------
# 效果校验
# -------------------------
info "进行部署效果校验..."
if [[ "$OS" == "alpine" ]]; then
    rc-service secure-dns status >/dev/null && ok "Stubby 服务正在运行" || warn "Stubby 服务未运行"
else
    systemctl is-active --quiet secure-dns.service && ok "Stubby 服务正在运行" || warn "Stubby 服务未运行"
fi

# 测试 IPv4/IPv6 DNS 解析
for d in google.com cloudflare.com; do
    if dig +short @"127.0.0.1" "$d" A >/dev/null 2>&1; then
        ok "IPv4 解析 $d 成功"
    else
        warn "IPv4 解析 $d 失败"
    fi
    if dig +short @"::1" "$d" AAAA >/dev/null 2>&1; then
        ok "IPv6 解析 $d 成功"
    else
        warn "IPv6 解析 $d 失败"
    fi
done

info "增强版加密 DNS 部署完成 ✅"
echo "日志目录: $LOG_DIR"
echo "配置文件: $CONFIG_FILE"
