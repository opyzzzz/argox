#!/bin/ash

# ============================================================
# Alpine Linux /bin/ash
# sing-box VLESS + REALITY installer/updater
#
# Architecture:
#
#   GitHub
#      |
#      v
# /usr/local/tmp/sing-box-download.$$
#      |
#      | version / sha256 / binary validation
#      v
# /usr/local/bin/sing-box
#
# Binary update:
#
#   old /usr/local/bin/sing-box
#              |
#              +---- hard link ----> /usr/local/tmp/sing-box-backup.$$
#
#   new /usr/local/tmp/sing-box-download.$$
#              |
#              +-------------------> mv
#                                      |
#                                      v
#                              /usr/local/bin/sing-box
#
#   restart success:
#       rm backup
#
#   restart failure:
#       remove new binary
#       mv backup -> /usr/local/bin/sing-box
#       restart old binary
#
# No /tmp -> /usr/local/bin cross-filesystem operation.
# No cp is used for binary installation or binary rollback.
# ============================================================

set -eu

# ============================================================
# Basic configuration
# ============================================================

BIN_BASE_URL="${BIN_BASE_URL:-https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi}"

BIN_DST="/usr/local/bin/sing-box"

TMP_DIR="/usr/local/tmp"
BIN_TMP="${TMP_DIR}/sing-box-download.$$"
BIN_BACKUP="${TMP_DIR}/sing-box-backup.$$"

CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
CONF_TMP="${CONF_DIR}/.config.json.new.$$"
CONF_BACKUP="${CONF_DIR}/.config.json.backup.$$"

SERVICE_FILE="/etc/init.d/sing-box"
SERVICE_TMP="/etc/init.d/.sing-box.new.$$"
SERVICE_BACKUP="/etc/init.d/.sing-box.backup.$$"

LOG_DIR="/var/log/sing-box"

INFO_FILE="/root/singbox-vless-reality-info.txt"

DEFAULT_PORT="443"
DEFAULT_DOMAIN="www.cloudflare.com"

PORT="${PORT:-$DEFAULT_PORT}"
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"

# Optional SHA256 verification.
#
# Example:
#
# EXPECTED_SHA256="xxxxxxxx..." ./setup-singbox-reality.sh
#
# Empty = skip checksum verification.
EXPECTED_SHA256="${EXPECTED_SHA256:-}"

# ============================================================
# Runtime variables
# ============================================================

MODE=""
ARCH=""
BIN_NAME=""
BIN_URL=""

NEW_BINARY_INSTALLED="0"
OLD_BINARY_BACKED_UP="0"

NEW_CONFIG_INSTALLED="0"
OLD_CONFIG_BACKED_UP="0"

NEW_SERVICE_INSTALLED="0"
OLD_SERVICE_BACKED_UP="0"

SERVICE_WAS_RUNNING="0"

UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

SERVER_ADDR=""
CLIENT_VLESS=""

# ============================================================
# Output helpers
# ============================================================

log() {
    printf '%s\n' "[+] $*"
}

warn() {
    printf '%s\n' "[!] $*" >&2
}

die() {
    printf '%s\n' "[x] $*" >&2
    exit 1
}

# ============================================================
# Cleanup
# ============================================================

cleanup() {
    rm -f \
        "$BIN_TMP" \
        "$CONF_TMP" \
        "$SERVICE_TMP" \
        2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ============================================================
# Root check
# ============================================================

[ "$(id -u)" = "0" ] || die "请使用 root 运行此脚本"

# ============================================================
# Detect architecture
# ============================================================

detect_arch() {
    MACHINE="$(uname -m 2>/dev/null || true)"

    case "$MACHINE" in
        x86_64|amd64)
            ARCH="amd64"
            ;;

        aarch64|arm64)
            ARCH="arm64"
            ;;

        *)
            die "不支持的 CPU 架构: $MACHINE"
            ;;
    esac

    log "检测到 CPU 架构: $MACHINE -> $ARCH"
}

# ============================================================
# Prepare directories
# ============================================================

prepare_dirs() {
    log "准备目录..."

    mkdir -p "$TMP_DIR"
    mkdir -p "$CONF_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$(dirname "$BIN_DST")"

    chmod 700 "$TMP_DIR" 2>/dev/null || true
    chmod 755 "$CONF_DIR" 2>/dev/null || true
    chmod 755 "$LOG_DIR" 2>/dev/null || true

    # Make sure these directories are writable.
    TEST_TMP="${TMP_DIR}/.write-test.$$"
    if ! : > "$TEST_TMP"; then
        die "无法写入 $TMP_DIR"
    fi
    rm -f "$TEST_TMP"

    TEST_CONF="${CONF_DIR}/.write-test.$$"
    if ! : > "$TEST_CONF"; then
        die "无法写入 $CONF_DIR"
    fi
    rm -f "$TEST_CONF"

    TEST_BIN_DIR="/usr/local/bin/.write-test.$$"
    if ! : > "$TEST_BIN_DIR"; then
        die "无法写入 /usr/local/bin"
    fi
    rm -f "$TEST_BIN_DIR"
}

# ============================================================
# Verify /usr/local/tmp and /usr/local/bin support rename
#
# This is more reliable than depending on BusyBox stat syntax.
#
# If mv fails here, the final binary mv would fail as well.
# ============================================================

verify_binary_rename_path() {
    TEST_SRC="${TMP_DIR}/.rename-test.$$"
    TEST_DST="/usr/local/bin/.rename-test.$$"

    log "检查 /usr/local/tmp -> /usr/local/bin 是否支持同文件系统 mv..."

    if ! : > "$TEST_SRC"; then
        die "无法创建 rename 测试文件"
    fi

    if ! mv "$TEST_SRC" "$TEST_DST" 2>/dev/null; then
        rm -f "$TEST_SRC" "$TEST_DST" 2>/dev/null || true

        die "/usr/local/tmp -> /usr/local/bin 的 mv 失败。

这通常意味着：
1. 两个目录位于不同文件系统；
2. /usr/local/bin 所在文件系统只读；
3. 当前目录权限不足；
4. 文件系统存在特殊限制。

本脚本要求二进制最终使用同文件系统 mv 原子替换。
请检查：
    mount
    df -h
    df -T
    ls -ld /usr/local /usr/local/tmp /usr/local/bin"
    fi

    rm -f "$TEST_DST"

    log "rename 路径检查通过"
}

# ============================================================
# Determine binary filename
# ============================================================

detect_binary_name() {
    case "$ARCH" in
        amd64)
            BIN_NAME="sing-box-linux-amd64-musl"
            ;;

        arm64)
            BIN_NAME="sing-box-linux-arm64-musl"
            ;;

        *)
            die "内部错误：未知架构 $ARCH"
            ;;
    esac

    BIN_URL="${BIN_BASE_URL}/${BIN_NAME}"

    log "下载地址:"
    printf '    %s\n' "$BIN_URL"
}

# ============================================================
# Download helper
# ============================================================

download_file() {
    URL="$1"
    DEST="$2"

    if command -v wget >/dev/null 2>&1; then
        log "使用 wget 下载..."
        wget \
            -q \
            --show-progress \
            -O "$DEST" \
            "$URL"
        return $?
    fi

    if command -v curl >/dev/null 2>&1; then
        log "使用 curl 下载..."
        curl \
            -fL \
            --retry 3 \
            --connect-timeout 15 \
            --output "$DEST" \
            "$URL"
        return $?
    fi

    die "系统中没有 wget 或 curl"
}

# ============================================================
# SHA256
# ============================================================

get_sha256() {
    FILE="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$FILE" | awk '{print $1}'
        return 0
    fi

    if command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$FILE"
        return 0
    fi

    die "系统中没有 sha256sum 或 sha256，无法进行 SHA256 校验"
}

verify_sha256() {
    FILE="$1"

    [ -n "$EXPECTED_SHA256" ] || return 0

    log "执行 SHA256 校验..."

    ACTUAL_SHA256="$(get_sha256 "$FILE")"

    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        die "SHA256 校验失败。

Expected:
$EXPECTED_SHA256

Actual:
$ACTUAL_SHA256"
    fi

    log "SHA256 校验通过"
}

# ============================================================
# Download and validate new binary
#
# IMPORTANT:
# This happens BEFORE stopping sing-box.
# ============================================================

download_and_validate_binary() {
    rm -f "$BIN_TMP"

    log "开始下载 sing-box 到:"
    printf '    %s\n' "$BIN_TMP"

    if ! download_file "$BIN_URL" "$BIN_TMP"; then
        rm -f "$BIN_TMP"
        die "sing-box 下载失败"
    fi

    [ -s "$BIN_TMP" ] || die "下载文件为空"

    chmod 755 "$BIN_TMP"

    verify_sha256 "$BIN_TMP"

    log "验证临时核心版本..."

    VERSION_OUTPUT=""

    if ! VERSION_OUTPUT="$("$BIN_TMP" version 2>&1)"; then
        warn "临时核心执行失败:"
        printf '%s\n' "$VERSION_OUTPUT" >&2

        rm -f "$BIN_TMP"

        die "下载的 sing-box 无法执行，拒绝安装"
    fi

    printf '%s\n' "$VERSION_OUTPUT"

    log "临时核心验证通过"

    # A second lightweight executable check.
    if ! "$BIN_TMP" version >/dev/null 2>&1; then
        die "临时核心二次执行验证失败"
    fi
}

# ============================================================
# Stop service
# ============================================================

service_is_running() {
    if rc-service sing-box status >/dev/null 2>&1; then
        return 0
    fi

    if pgrep -x sing-box >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

stop_old_xray() {
    if [ -x /etc/init.d/xray ]; then
        log "检测到旧 xray OpenRC 服务，尝试停止..."

        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
    fi

    if pgrep -x xray >/dev/null 2>&1; then
        log "清理旧 xray 进程..."
        pkill -x xray >/dev/null 2>&1 || true
    fi
}

stop_singbox() {
    SERVICE_WAS_RUNNING="0"

    if service_is_running; then
        SERVICE_WAS_RUNNING="1"

        log "停止现有 sing-box..."

        rc-service sing-box stop >/dev/null 2>&1 || true
    fi

    # Exact process-name fallback only.
    if pgrep -x sing-box >/dev/null 2>&1; then
        log "等待 sing-box 退出..."

        i=0
        while pgrep -x sing-box >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
            sleep 1
            i=$((i + 1))
        done
    fi

    # Last resort.
    if pgrep -x sing-box >/dev/null 2>&1; then
        warn "sing-box 未正常退出，执行精确 pkill..."

        pkill -x sing-box >/dev/null 2>&1 || true

        sleep 1
    fi

    if pgrep -x sing-box >/dev/null 2>&1; then
        die "无法停止现有 sing-box 进程"
    fi
}

# ============================================================
# Binary transaction
#
# No cp.
#
# Existing binary:
#
#   old -> hardlink backup
#   new -> atomic mv
#
# Hardlink is used because:
# - no data copy
# - no cross-filesystem copy
# - backup remains old inode
# - rollback is another rename
# ============================================================

backup_old_binary() {
    OLD_BINARY_BACKUP="$BIN_BACKUP"

    rm -f "$OLD_BINARY_BACKUP"

    if [ ! -f "$BIN_DST" ]; then
        OLD_BINARY_BACKED_UP="0"
        return 0
    fi

    log "创建旧核心硬链接备份..."

    if ! ln "$BIN_DST" "$OLD_BINARY_BACKUP" 2>/dev/null; then
        die "无法创建旧 sing-box 硬链接备份。

请检查：
    ls -l $BIN_DST
    ls -ld $TMP_DIR
    df -h
    df -T

注意：本脚本不会使用 cp 绕过此问题。"
    fi

    OLD_BINARY_BACKED_UP="1"
}

install_new_binary() {
    log "使用 mv 原子替换正式核心..."

    if ! mv "$BIN_TMP" "$BIN_DST"; then
        die "正式核心 mv 失败。

由于新核心已经位于 $TMP_DIR，
这里理论上只应该发生同文件系统 rename。

请检查：
    mount
    df -h
    df -T
    ls -ld $TMP_DIR /usr/local/bin"
    fi

    chmod 755 "$BIN_DST"

    NEW_BINARY_INSTALLED="1"

    log "正式核心替换完成"
}

remove_binary_backup() {
    if [ "$OLD_BINARY_BACKED_UP" = "1" ]; then
        rm -f "$BIN_BACKUP"
        OLD_BINARY_BACKED_UP="0"
    fi
}

rollback_binary() {
    warn "开始回滚 sing-box 核心..."

    if [ "$NEW_BINARY_INSTALLED" = "1" ]; then
        rm -f "$BIN_DST"
        NEW_BINARY_INSTALLED="0"
    fi

    if [ "$OLD_BINARY_BACKED_UP" = "1" ] && [ -f "$BIN_BACKUP" ]; then
        if mv "$BIN_BACKUP" "$BIN_DST"; then
            OLD_BINARY_BACKED_UP="0"
            chmod 755 "$BIN_DST" 2>/dev/null || true
            log "旧核心已经恢复"
        else
            warn "旧核心恢复失败，请手动检查："
            warn "    $BIN_BACKUP"
            warn "    $BIN_DST"
        fi
    fi
}

# ============================================================
# UUID
# ============================================================

generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
        return 0
    fi

    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi

    die "系统没有 uuidgen，且 /proc/sys/kernel/random/uuid 不可用"
}

# ============================================================
# REALITY keypair
# ============================================================

generate_reality_keypair() {
    log "生成 REALITY keypair..."

    KEYPAIR=""

    if ! KEYPAIR="$("$BIN_DST" generate reality-keypair 2>&1)"; then
        printf '%s\n' "$KEYPAIR" >&2
        die "REALITY keypair 生成失败"
    fi

    PRIVATE_KEY="$(printf '%s\n' "$KEYPAIR" | awk -F': ' '
        /PrivateKey/ {
            print $2
            exit
        }
    ')"

    PUBLIC_KEY="$(printf '%s\n' "$KEYPAIR" | awk -F': ' '
        /PublicKey/ {
            print $2
            exit
        }
    ')"

    [ -n "$PRIVATE_KEY" ] || die "无法解析 REALITY PrivateKey"
    [ -n "$PUBLIC_KEY" ] || die "无法解析 REALITY PublicKey"

    log "REALITY keypair 生成成功"
}

# ============================================================
# Short ID
# ============================================================

generate_short_id() {
    log "生成 REALITY short ID..."

    if command -v od >/dev/null 2>&1; then
        SHORT_ID="$(
            od -An -N8 -tx1 /dev/urandom |
            tr -d ' \n'
        )"
    else
        SHORT_ID=""
    fi

    case "$SHORT_ID" in
        ????????????????)
            ;;
        *)
            # Fallback using current time and random data.
            SHORT_ID="$(
                printf '%s%s' \
                    "$(date +%s)" \
                    "$$" |
                md5sum 2>/dev/null |
                awk '{print substr($1,1,16)}'
            )"
            ;;
    esac

    [ -n "$SHORT_ID" ] || die "无法生成 short ID"

    log "short ID: $SHORT_ID"
}

# ============================================================
# JSON escaping
# ============================================================

json_escape() {
    printf '%s' "$1" |
        sed \
            's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

# ============================================================
# Domain validation
# ============================================================

validate_domain() {
    case "$DOMAIN" in
        "")
            die "DOMAIN 不能为空"
            ;;

        *[!A-Za-z0-9.-]*)
            die "DOMAIN 包含非法字符: $DOMAIN"
            ;;

        .*|*.)
            die "DOMAIN 不能以 . 开头或结尾: $DOMAIN"
            ;;

        -*|*-)
            die "DOMAIN 不能以 - 开头或结尾: $DOMAIN"
            ;;
    esac

    # Avoid accidental spaces / excessively long value.
    DOMAIN_LENGTH="$(printf '%s' "$DOMAIN" | wc -c | tr -d ' ')"

    if [ "$DOMAIN_LENGTH" -gt 253 ]; then
        die "DOMAIN 长度超过 253 字符"
    fi
}

# ============================================================
# Port validation
# ============================================================

validate_port() {
    case "$PORT" in
        ''|*[!0-9]*)
            die "PORT 必须是数字: $PORT"
            ;;
    esac

    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        die "PORT 超出范围: $PORT"
    fi
}

# ============================================================
# Generate config
# ============================================================

write_config_temp() {
    validate_domain
    validate_port

    UUID="$(generate_uuid)"

    generate_reality_keypair
    generate_short_id

    DOMAIN_JSON="$(json_escape "$DOMAIN")"
    UUID_JSON="$(json_escape "$UUID")"
    PRIVATE_KEY_JSON="$(json_escape "$PRIVATE_KEY")"
    SHORT_ID_JSON="$(json_escape "$SHORT_ID")"

    log "生成 sing-box 配置临时文件..."

    rm -f "$CONF_TMP"

    cat > "$CONF_TMP" <<EOF
{
  "log": {
    "level": "warn",
    "output": "${LOG_DIR}/sing-box.log",
    "timestamp": true
  },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID_JSON}",
          "flow": ""
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN_JSON}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${DOMAIN_JSON}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY_JSON}",
          "short_id": [
            "${SHORT_ID_JSON}"
          ]
        }
      }
    }
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],

  "route": {
    "final": "direct"
  }
}
EOF

    chmod 600 "$CONF_TMP"

    log "验证临时 sing-box 配置..."

    if ! "$BIN_DST" check -c "$CONF_TMP"; then
        rm -f "$CONF_TMP"
        die "sing-box 配置检查失败，拒绝替换正式配置"
    fi

    log "配置检查通过"
}

# ============================================================
# Config transaction
# ============================================================

backup_old_config() {
    rm -f "$CONF_BACKUP"

    if [ ! -f "$CONF_FILE" ]; then
        OLD_CONFIG_BACKED_UP="0"
        return 0
    fi

    log "创建旧配置硬链接备份..."

    if ! ln "$CONF_FILE" "$CONF_BACKUP" 2>/dev/null; then
        die "无法创建配置备份"
    fi

    OLD_CONFIG_BACKED_UP="1"
}

install_new_config() {
    log "使用 mv 原子替换 config.json..."

    if ! mv "$CONF_TMP" "$CONF_FILE"; then
        die "config.json 原子替换失败"
    fi

    chmod 600 "$CONF_FILE"

    NEW_CONFIG_INSTALLED="1"
}

remove_config_backup() {
    if [ "$OLD_CONFIG_BACKED_UP" = "1" ]; then
        rm -f "$CONF_BACKUP"
        OLD_CONFIG_BACKED_UP="0"
    fi
}

rollback_config() {
    warn "开始回滚配置..."

    if [ "$NEW_CONFIG_INSTALLED" = "1" ]; then
        rm -f "$CONF_FILE"
        NEW_CONFIG_INSTALLED="0"
    fi

    if [ "$OLD_CONFIG_BACKED_UP" = "1" ] && [ -f "$CONF_BACKUP" ]; then
        if mv "$CONF_BACKUP" "$CONF_FILE"; then
            OLD_CONFIG_BACKED_UP="0"
            chmod 600 "$CONF_FILE" 2>/dev/null || true
            log "旧配置已经恢复"
        else
            warn "旧配置恢复失败"
        fi
    fi
}

# ============================================================
# OpenRC service
# ============================================================

write_service_temp() {
    log "生成 OpenRC service..."

    rm -f "$SERVICE_TMP"

    cat > "$SERVICE_TMP" <<'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box VLESS REALITY service"

command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"

command_user="root:root"

pidfile="/run/${RC_SVCNAME}.pid"

output_log="/var/log/sing-box/openrc.log"
error_log="/var/log/sing-box/openrc-error.log"

command_background="yes"

# Low-memory tuning.
export GOMEMLIMIT="32MiB"
export GOGC="25"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath \
        --directory \
        --mode 0755 \
        /var/log/sing-box

    checkpath \
        --file \
        --mode 0600 \
        "$output_log"

    checkpath \
        --file \
        --mode 0600 \
        "$error_log"

    if [ ! -x "$command" ]; then
        eerror "sing-box binary not found: $command"
        return 1
    fi

    if [ ! -f /usr/local/etc/sing-box/config.json ]; then
        eerror "sing-box config not found"
        return 1
    fi

    "$command" check \
        -c /usr/local/etc/sing-box/config.json
}
EOF

    chmod 755 "$SERVICE_TMP"

    log "检查 OpenRC service shell 语法..."

    if ! /bin/ash -n "$SERVICE_TMP"; then
        rm -f "$SERVICE_TMP"
        die "OpenRC service 语法检查失败"
    fi
}

backup_old_service() {
    rm -f "$SERVICE_BACKUP"

    if [ ! -f "$SERVICE_FILE" ]; then
        OLD_SERVICE_BACKED_UP="0"
        return 0
    fi

    if ! ln "$SERVICE_FILE" "$SERVICE_BACKUP" 2>/dev/null; then
        die "无法创建旧 OpenRC service 硬链接备份"
    fi

    OLD_SERVICE_BACKED_UP="1"
}

install_new_service() {
    if [ -f "$SERVICE_FILE" ]; then
        return 0
    fi

    log "安装 OpenRC service..."

    if ! mv "$SERVICE_TMP" "$SERVICE_FILE"; then
        die "OpenRC service 安装失败"
    fi

    chmod 755 "$SERVICE_FILE"

    NEW_SERVICE_INSTALLED="1"
}

remove_service_backup() {
    if [ "$OLD_SERVICE_BACKED_UP" = "1" ]; then
        rm -f "$SERVICE_BACKUP"
        OLD_SERVICE_BACKED_UP="0"
    fi
}

rollback_service() {
    if [ "$NEW_SERVICE_INSTALLED" = "1" ]; then
        rm -f "$SERVICE_FILE"
        NEW_SERVICE_INSTALLED="0"
    fi

    if [ "$OLD_SERVICE_BACKED_UP" = "1" ] &&
       [ -f "$SERVICE_BACKUP" ]; then

        if mv "$SERVICE_BACKUP" "$SERVICE_FILE"; then
            OLD_SERVICE_BACKED_UP="0"
            chmod 755 "$SERVICE_FILE" 2>/dev/null || true
        fi
    fi
}

enable_service() {
    log "启用 OpenRC service..."

    if ! rc-update add sing-box default >/dev/null 2>&1; then
        warn "rc-update add sing-box default 失败"
    fi
}

# ============================================================
# Start / restart service
# ============================================================

start_service() {
    log "启动 sing-box..."

    if ! rc-service sing-box start; then
        return 1
    fi

    sleep 2

    if ! pgrep -x sing-box >/dev/null 2>&1; then
        warn "OpenRC start 返回成功，但没有检测到 sing-box 进程"
        return 1
    fi

    if ! rc-service sing-box status >/dev/null 2>&1; then
        warn "OpenRC 状态检查失败"
        return 1
    fi

    return 0
}

restart_service() {
    log "重新启动 sing-box..."

    if rc-service sing-box restart >/dev/null 2>&1; then
        sleep 2

        if pgrep -x sing-box >/dev/null 2>&1; then
            return 0
        fi
    fi

    warn "OpenRC restart 失败"

    # Try clean stop + start once.
    rc-service sing-box stop >/dev/null 2>&1 || true

    sleep 1

    if pgrep -x sing-box >/dev/null 2>&1; then
        pkill -x sing-box >/dev/null 2>&1 || true
        sleep 1
    fi

    if start_service; then
        return 0
    fi

    return 1
}

# ============================================================
# Get server address
# ============================================================

detect_server_address() {
    SERVER_ADDR=""

    # Prefer IPv4.
    if command -v curl >/dev/null 2>&1; then
        SERVER_ADDR="$(
            curl \
                -4 \
                -fsS \
                --connect-timeout 5 \
                --max-time 10 \
                https://api.ipify.org \
                2>/dev/null || true
        )"
    elif command -v wget >/dev/null 2>&1; then
        SERVER_ADDR="$(
            wget \
                -qO- \
                -T 10 \
                https://api.ipify.org \
                2>/dev/null || true
        )"
    fi

    if [ -z "$SERVER_ADDR" ]; then
        SERVER_ADDR="YOUR_SERVER_IP"
    fi
}

# ============================================================
# Build VLESS URL
# ============================================================

build_client_link() {
    detect_server_address

    CLIENT_VLESS="vless://${UUID}@${SERVER_ADDR}:${PORT}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#sing-box-REALITY"
}

# ============================================================
# Write client info
# ============================================================

write_info() {
    build_client_link

    log "写入客户端连接信息..."

    umask 077

    cat > "$INFO_FILE" <<EOF
============================================================
sing-box VLESS + REALITY
============================================================

Server Address:
${SERVER_ADDR}

Port:
${PORT}

UUID:
${UUID}

REALITY Server Name / SNI:
${DOMAIN}

REALITY Public Key:
${PUBLIC_KEY}

REALITY Short ID:
${SHORT_ID}

VLESS URL:
${CLIENT_VLESS}

------------------------------------------------------------
Server private key:
${PRIVATE_KEY}

Config:
${CONF_FILE}

Binary:
${BIN_DST}

Service:
${SERVICE_FILE}

Log:
${LOG_DIR}

============================================================
EOF

    chmod 600 "$INFO_FILE"

    log "客户端信息:"
    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "$CLIENT_VLESS"
    printf '%s\n' "------------------------------------------------------------"
    log "完整信息已保存到:"
    printf '    %s\n' "$INFO_FILE"
}

# ============================================================
# Show current installation
# ============================================================

show_status() {
    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "sing-box status"
    printf '%s\n' "============================================================"

    if [ -x "$BIN_DST" ]; then
        "$BIN_DST" version 2>/dev/null || true
    else
        printf '%s\n' "binary: not installed"
    fi

    if [ -f "$CONF_FILE" ]; then
        printf '%s\n' "config: $CONF_FILE"
    else
        printf '%s\n' "config: not installed"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        printf '%s\n' "service: $SERVICE_FILE"
    else
        printf '%s\n' "service: not installed"
    fi

    if pgrep -x sing-box >/dev/null 2>&1; then
        printf '%s\n' "process: running"
    else
        printf '%s\n' "process: stopped"
    fi

    printf '%s\n' "============================================================"
}

# ============================================================
# Full installation / update transaction
# ============================================================

install_or_update() {
    detect_arch
    detect_binary_name

    prepare_dirs
    verify_binary_rename_path

    # --------------------------------------------------------
    # 1. Download + validate NEW binary
    # --------------------------------------------------------
    #
    # Do this while old sing-box is still running.
    #
    download_and_validate_binary

    # --------------------------------------------------------
    # 2. Stop old service
    # --------------------------------------------------------

    stop_old_xray
    stop_singbox

    # --------------------------------------------------------
    # 3. Backup old binary without cp
    # --------------------------------------------------------

    backup_old_binary

    # --------------------------------------------------------
    # 4. Install new binary using same-filesystem mv
    # --------------------------------------------------------

    install_new_binary

    # --------------------------------------------------------
    # 5. Generate and validate new config
    # --------------------------------------------------------

    write_config_temp

    # --------------------------------------------------------
    # 6. Backup old config
    # --------------------------------------------------------

    backup_old_config

    # --------------------------------------------------------
    # 7. Atomically replace config
    # --------------------------------------------------------

    install_new_config

    # --------------------------------------------------------
    # 8. Ensure OpenRC service
    # --------------------------------------------------------

    write_service_temp
    backup_old_service
    install_new_service

    # If service already existed, temp is no longer needed.
    rm -f "$SERVICE_TMP"

    enable_service

    # --------------------------------------------------------
    # 9. Start new version
    # --------------------------------------------------------

    if ! start_service; then
        warn "新 sing-box 启动失败，开始事务回滚..."

        # Stop failed new instance.
        rc-service sing-box stop >/dev/null 2>&1 || true

        if pgrep -x sing-box >/dev/null 2>&1; then
            pkill -x sing-box >/dev/null 2>&1 || true
        fi

        # Restore config first.
        rollback_config

        # Restore service if we installed a new one.
        rollback_service

        # Restore binary.
        rollback_binary

        # Try old version.
        if [ -x "$BIN_DST" ] && [ -f "$CONF_FILE" ]; then
            log "尝试重新启动旧版本..."

            if start_service; then
                warn "旧版本 sing-box 已恢复运行"
            else
                warn "旧版本也无法启动，请检查："
                warn "    rc-service sing-box status"
                warn "    $LOG_DIR"
                warn "    $CONF_FILE"
            fi
        fi

        die "更新失败，已经执行回滚"
    fi

    # --------------------------------------------------------
    # 10. Everything successful
    # --------------------------------------------------------

    remove_binary_backup
    remove_config_backup
    remove_service_backup

    rm -f "$BIN_TMP" "$CONF_TMP" "$SERVICE_TMP"

    write_info

    show_status

    printf '\n'
    log "sing-box VLESS + REALITY 安装/更新成功"
}

# ============================================================
# Main
# ============================================================

main() {
    log "开始执行 sing-box VLESS + REALITY 安装/更新"
    log "临时目录: $TMP_DIR"
    log "正式核心: $BIN_DST"
    log "配置文件: $CONF_FILE"
    log "OpenRC:   $SERVICE_FILE"

    install_or_update
}

main "$@"
