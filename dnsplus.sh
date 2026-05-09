#!/usr/bin/env bash
#===============================================================================
# 一键部署加密 DNS (Stubby) 脚本
# 支持 Debian/Ubuntu (systemd) 和 Alpine (OpenRC)，x86_64/ARM
# 功能：DoT/DoH，多上游轮询，xray/sing-box 集成，防篡改，日志自动清理
#===============================================================================

set -o pipefail

#-------------------- 颜色与日志函数 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

#-------------------- 权限检查 --------------------
[ "$(id -u)" -ne 0 ] && err "请使用 root 权限运行本脚本"

#-------------------- 系统与架构检测 --------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
else
    err "无法检测系统类型，缺少 /etc/os-release"
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH_TYPE="x86_64" ;;
    aarch64|arm64) ARCH_TYPE="arm64" ;;
    armv7l|armv6l) ARCH_TYPE="arm" ;;
    *) err "不支持的架构: $ARCH" ;;
esac

info "检测到系统: $OS_ID, 架构: $ARCH_TYPE"

#-------------------- 服务管理系统判断 --------------------
if [ "$OS_ID" = "alpine" ]; then
    USE_OPENRC=1
    USE_SYSTEMD=0
    info "将使用 OpenRC 服务管理"
else
    USE_OPENRC=0
    USE_SYSTEMD=1
    info "将使用 systemd 服务管理"
fi

#-------------------- 安装依赖 --------------------
install_deps() {
    info "开始安装依赖（仅使用官方仓库）..."
    if [ "$OS_ID" = "alpine" ]; then
        apk update || err "apk update 失败"
        apk add stubby bind-tools jq busybox-openrc busybox-crond || err "Alpine 依赖安装失败"
        # 确保 crond 在后台运行
        if ! pgrep crond >/dev/null 2>&1; then
            rc-service crond start || warn "crond 启动失败"
        fi
        rc-update add crond default || warn "无法添加 crond 到自启"
    else
        apt update -qq || err "apt update 失败"
        DEBIAN_FRONTEND=noninteractive apt install -y -qq stubby dnsutils jq cron || err "Debian/Ubuntu 依赖安装失败"
        systemctl enable cron --now 2>/dev/null || systemctl enable cron 2>/dev/null || warn "cron 服务配置有误"
    fi
    ok "依赖安装完成"
}

#-------------------- 配置 Stubby --------------------
configure_stubby() {
    info "配置 Stubby (DoT / DoH 多上游轮询)..."
    STUBBY_CONF="/etc/stubby/stubby.yml"
    # 备份原配置（如果存在）
    if [ -f "$STUBBY_CONF" ]; then
        cp -f "$STUBBY_CONF" "${STUBBY_CONF}.bak.$(date +%s)" || warn "备份原配置失败"
    fi

    # 上游服务器：Google, Cloudflare, Quad9，同时包含 IPv4 和 IPv6，以及 DoT 和 DoH
    cat > "$STUBBY_CONF" <<'EOF'
# Stubby configuration for encrypted DNS (auto-generated)
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
  - GETDNS_TRANSPORT_HTTPS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_query_padding_blocksize: 128
edns_client_subnet_private: 1
idle_timeout: 10000
round_robin_upstreams: 1
listen_addresses:
  - 127.0.0.1@53
  - ::1@53
app_log_file: "/var/log/secure-dns/stubby.log"
app_log_level: 2
upstream_recursive_servers:
  # Google (IPv4 & IPv6 DoT)
  - address: 8.8.8.8@853
    tls_auth_name: "dns.google"
  - address: 2001:4860:4860::8888@853
    tls_auth_name: "dns.google"
  # Cloudflare (IPv4 & IPv6 DoT)
  - address: 1.1.1.1@853
    tls_auth_name: "cloudflare-dns.com"
  - address: 2606:4700:4700::1111@853
    tls_auth_name: "cloudflare-dns.com"
  # Quad9 (IPv4 & IPv6 DoT)
  - address: 9.9.9.9@853
    tls_auth_name: "dns.quad9.net"
  - address: 2620:fe::fe@853
    tls_auth_name: "dns.quad9.net"
  # Google DoH
  - address: https://dns.google/dns-query
    tls_auth_name: "dns.google"
  # Cloudflare DoH
  - address: https://cloudflare-dns.com/dns-query
    tls_auth_name: "cloudflare-dns.com"
  # Quad9 DoH
  - address: https://dns.quad9.net/dns-query
    tls_auth_name: "dns.quad9.net"
EOF

    # 设置安全权限
    chmod 640 "$STUBBY_CONF"
    # 确保 stubby 用户存在（Debian/Ubuntu 包会创建，Alpine 可能需手动）
    if id stubby >/dev/null 2>&1; then
        chown root:stubby "$STUBBY_CONF"
    else
        warn "stubby 用户不存在，跳过 chown。Stubby 可能以 root 运行？"
    fi
    ok "Stubby 配置已写入 $STUBBY_CONF"
}

#-------------------- 创建日志目录 & 权限 --------------------
setup_log_dir() {
    LOG_DIR="/var/log/secure-dns"
    mkdir -p "$LOG_DIR"
    chmod 750 "$LOG_DIR"
    if id stubby >/dev/null 2>&1; then
        chown root:stubby "$LOG_DIR"
    else
        chown root:root "$LOG_DIR"
    fi
    ok "日志目录已创建: $LOG_DIR"
}

#-------------------- 启动 Stubby 服务 --------------------
start_stubby_service() {
    info "启动 Stubby 服务..."
    if [ "$USE_OPENRC" -eq 1 ]; then
        # Alpine OpenRC
        if ! rc-status default 2>/dev/null | grep -q stubby; then
            rc-update add stubby default || err "无法添加 Stubby 到 OpenRC 自启"
        fi
        rc-service stubby stop 2>/dev/null || true
        rc-service stubby start || err "Stubby 启动失败"
    else
        systemctl daemon-reload
        systemctl enable stubby --now || err "Stubby 启用/启动失败"
        # 若因 stubby 用户权限问题导致日志文件无法写入，可重启
        if ! systemctl is-active --quiet stubby; then
            warn "Stubby 首次启动失败，尝试修复权限并重启"
            touch "$LOG_DIR/stubby.log"
            chown stubby:stubby "$LOG_DIR/stubby.log" 2>/dev/null || true
            systemctl restart stubby || err "Stubby 重启失败"
        fi
    fi
    # 等待一秒确认
    sleep 1
    if ! stubby_running; then
        err "Stubby 未能成功运行，请检查日志: $LOG_DIR/stubby.log"
    fi
    ok "Stubby 服务已启动"
}

# 检查 Stubby 是否运行
stubby_running() {
    if [ "$USE_OPENRC" -eq 1 ]; then
        rc-service stubby status 2>/dev/null | grep -q "started" || pgrep -x stubby >/dev/null 2>&1
    else
        systemctl is-active --quiet stubby
    fi
}

#-------------------- 防篡改 & 日志清理定时任务 --------------------
setup_guard() {
    info "配置配置防篡改（每日 SHA256 检测）及日志自动清理（30天）"
    GUARD_SCRIPT="/usr/local/bin/secure-dns-guard.sh"
    STUBBY_CONF="/etc/stubby/stubby.yml"
    CONF_HASH_FILE="/var/lib/secure-dns/stubby.yml.sha256"
    CONF_BACKUP="/var/lib/secure-dns/stubby.yml.valid"
    LOG_DIR="/var/log/secure-dns"

    mkdir -p /var/lib/secure-dns
    chmod 700 /var/lib/secure-dns

    # 保存当前正确配置的哈希和备份
    cp -f "$STUBBY_CONF" "$CONF_BACKUP"
    sha256sum "$STUBBY_CONF" | awk '{print $1}' > "$CONF_HASH_FILE"
    chmod 600 "$CONF_HASH_FILE" "$CONF_BACKUP"

    # 生成守护脚本
    cat > "$GUARD_SCRIPT" <<'GUARDEOF'
#!/bin/sh
CONF="/etc/stubby/stubby.yml"
BACKUP="/var/lib/secure-dns/stubby.yml.valid"
HASH_FILE="/var/lib/secure-dns/stubby.yml.sha256"
LOG_DIR="/var/log/secure-dns"
LOG_TAG="secure-dns-guard"

# 清理 30 天前日志
find "$LOG_DIR" -type f -mtime +30 -delete 2>/dev/null

# 检查配置文件哈希
if [ -f "$HASH_FILE" ] && [ -f "$CONF" ]; then
    current_hash=$(sha256sum "$CONF" | awk '{print $1}')
    saved_hash=$(cat "$HASH_FILE")
    if [ "$current_hash" != "$saved_hash" ]; then
        echo "[$(date)] 检测到 stubby 配置被篡改，自动恢复并重启" | tee -a "$LOG_DIR/guard.log"
        cp -f "$BACKUP" "$CONF"
        # 重启 Stubby
        if [ -f /etc/init.d/stubby ] && command -v rc-service >/dev/null; then
            rc-service stubby restart >/dev/null 2>&1
        elif command -v systemctl >/dev/null; then
            systemctl restart stubby >/dev/null 2>&1
        fi
    fi
fi
GUARDEOF

    chmod 700 "$GUARD_SCRIPT"

    # 添加 cron 定时任务（每天 00:00）
    if [ "$USE_OPENRC" -eq 1 ]; then
        # Alpine 使用 /etc/crontabs/root
        CRONTAB="/etc/crontabs/root"
        mkdir -p /etc/crontabs
        if [ -f "$CRONTAB" ]; then
            grep -q "$GUARD_SCRIPT" "$CRONTAB" || echo "0 0 * * * $GUARD_SCRIPT" >> "$CRONTAB"
        else
            echo "0 0 * * * $GUARD_SCRIPT" > "$CRONTAB"
        fi
        # 重启 crond 以生效
        rc-service crond restart 2>/dev/null || true
    else
        # Debian/Ubuntu 使用 /etc/cron.d/
        cat > /etc/cron.d/secure-dns-guard <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 0 * * * root $GUARD_SCRIPT
EOF
        chmod 644 /etc/cron.d/secure-dns-guard
        # 确保 cron 运行
        systemctl restart cron 2>/dev/null || true
    fi
    ok "防篡改及日志清理任务已配置"
}

#-------------------- 集成 Xray / Sing-Box --------------------
integrate_proxy_dns() {
    info "检查 Xray / Sing-box 并尝试接管 DNS 配置..."
    PROXY_CONF=""
    PROXY_TYPE=""
    PROXY_PID=""

    # 查找 Xray
    if command -v xray >/dev/null 2>&1; then
        PROXY_TYPE="xray"
    elif command -v sing-box >/dev/null 2>&1; then
        PROXY_TYPE="sing-box"
    fi

    [ -z "$PROXY_TYPE" ] && {
        warn "未检测到 xray 或 sing-box 二进制文件，跳过集成"
        return 0
    }

    # 获取 PID 和配置路径
    PROXY_PID=$(pgrep -x "$PROXY_TYPE" | head -1)
    if [ -n "$PROXY_PID" ]; then
        # 尝试从 proc 命令行提取 -config 参数
        CONFIG_PATH=$(tr '\0' ' ' < "/proc/$PROXY_PID/cmdline" | grep -oP '(?<=-config=)[^[:space:]]+' | head -1)
        if [ -z "$CONFIG_PATH" ]; then
            # 另一种模式
            CONFIG_PATH=$(tr '\0' ' ' < "/proc/$PROXY_PID/cmdline" | grep -oP '(?<=-c )[^[:space:]]+' | head -1)
        fi
    fi

    # 若无运行进程，猜测默认路径
    [ -z "$CONFIG_PATH" ] && {
        for guess in "/etc/$PROXY_TYPE/config.json" "/usr/local/etc/$PROXY_TYPE/config.json"; do
            [ -f "$guess" ] && { CONFIG_PATH="$guess"; break; }
        done
    }

    [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ] && {
        warn "找不到 $PROXY_TYPE 的配置文件，跳过 DNS 接管"
        return 0
    }

    info "找到 $PROXY_TYPE 配置: $CONFIG_PATH"
    BACKUP="${CONFIG_PATH}.bak.$(date +%s)"
    cp -f "$CONFIG_PATH" "$BACKUP"
    ok "已备份原配置到 $BACKUP"

    # 使用 jq 修改 DNS 配置，设置 server 为 127.0.0.1
    MODIFIED=$(jq '
      .dns |= (
        if . == null then {}
        else .
        end
        | .servers = [{"address": "127.0.0.1"}]
      )
    ' "$CONFIG_PATH") || err "jq 处理 JSON 失败，请检查 $CONFIG_PATH 格式"

    echo "$MODIFIED" > "$CONFIG_PATH"
    ok "已将 $PROXY_TYPE DNS 指向 127.0.0.1"

    # 发送 SIGHUP 热重载
    if [ -n "$PROXY_PID" ]; then
        kill -HUP "$PROXY_PID" 2>/dev/null && ok "已向 $PROXY_TYPE (PID $PROXY_PID) 发送 SIGHUP 重载配置" || warn "发送 SIGHUP 失败，可能需要手动重启"
    else
        warn "$PROXY_TYPE 未运行，配置已保存，启动后生效"
    fi
}

#-------------------- 效果校验 --------------------
verify_deployment() {
    info "开始部署效果校验..."
    FAIL=0

    # 1. Stubby 运行状态
    if stubby_running; then
        ok "Stubby 进程运行正常"
    else
        warn "Stubby 未运行"
        FAIL=1
    fi

    # 2. IPv4 解析测试
    echo -n "    IPv4 解析 test (google.com) ... "
    IPV4_RESULT=$(dig @127.0.0.1 google.com +short +timeout=3 2>/dev/null | head -1)
    if [ -n "$IPV4_RESULT" ]; then
        echo -e "${GREEN}成功${NC} ($IPV4_RESULT)"
        ok "IPv4 解析正常"
    else
        echo -e "${RED}失败${NC}"
        warn "IPv4 解析失败，请检查网络或上游连通性"
        FAIL=1
    fi

    echo -n "    IPv4 解析 test (cloudflare.com) ... "
    CF4_RESULT=$(dig @127.0.0.1 cloudflare.com +short +timeout=3 2>/dev/null | head -1)
    if [ -n "$CF4_RESULT" ]; then
        echo -e "${GREEN}成功${NC} ($CF4_RESULT)"
    else
        echo -e "${RED}失败${NC}"
        FAIL=1
    fi

    # 3. IPv6 解析测试（如果系统有 IPv6 连通性）
    IPV6_TEST=$(dig @::1 google.com +short +timeout=3 2>/dev/null | head -1)
    if [ -n "$IPV6_TEST" ]; then
        ok "IPv6 解析正常"
    else
        warn "IPv6 解析未成功（可能本机无 IPv6 连接，可忽略）"
    fi

    # 4. Xray/Sing-box 配置校验
    for bin in xray sing-box; do
        if command -v "$bin" >/dev/null 2>&1; then
            PROXY_CONF=""
            PROXY_PID=$(pgrep -x "$bin" | head -1)
            if [ -n "$PROXY_PID" ]; then
                PROXY_CONF=$(tr '\0' ' ' < "/proc/$PROXY_PID/cmdline" | grep -oP '(?<=-config=)[^[:space:]]+' | head -1)
            fi
            [ -z "$PROXY_CONF" ] && [ -f "/etc/$bin/config.json" ] && PROXY_CONF="/etc/$bin/config.json"
            [ -z "$PROXY_CONF" ] && [ -f "/usr/local/etc/$bin/config.json" ] && PROXY_CONF="/usr/local/etc/$bin/config.json"
            if [ -n "$PROXY_CONF" ] && [ -f "$PROXY_CONF" ]; then
                DNS_ADDR=$(jq -r '.dns.servers[0].address // empty' "$PROXY_CONF" 2>/dev/null)
                if [ "$DNS_ADDR" = "127.0.0.1" ] || [ "$DNS_ADDR" = "localhost" ]; then
                    ok "$bin 配置已接管: DNS 指向 127.0.0.1"
                else
                    warn "$bin 配置文件可能未正确设置 DNS 地址"
                fi
            else
                warn "无法找到 $bin 的配置文件进行验证"
            fi
        fi
    done

    if [ $FAIL -eq 1 ]; then
        warn "部分校验未通过，请根据上述信息排查"
    else
        ok "所有校验通过，加密 DNS 部署成功！"
    fi
}

#-------------------- 主流程 --------------------
main() {
    info "===== 开始一键部署加密 DNS (Stubby) ====="
    install_deps
    configure_stubby
    setup_log_dir
    start_stubby_service
    setup_guard
    integrate_proxy_dns
    verify_deployment
    ok "部署完成！"
}

main "$@"
