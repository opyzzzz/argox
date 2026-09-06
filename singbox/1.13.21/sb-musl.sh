#!/bin/ash

# ============================================================
# Alpine Linux /bin/ash
# sing-box VLESS + REALITY installer/updater
#
# Supported:
#   - x86_64 / amd64
#   - aarch64 / arm64
#
# Binary:
#   amd64:
#     https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-amd64
#
#   arm64:
#     https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-arm64
#
# Architecture:
#
#   GitHub Release
#          |
#          v
#   /usr/local/tmp/sing-box-download.$$
#          |
#          +-- chmod 755
#          +-- optional SHA256
#          +-- sing-box version
#          |
#          v
#   validated binary
#          |
#          | hard-link old binary
#          v
#   /usr/local/bin/sing-box
#
# Binary rollback:
#
#   /usr/local/bin/sing-box
#          |
#          +-- hard link -->
#              /usr/local/tmp/sing-box-backup.$$
#
#   new binary
#          |
#          +-- atomic mv -->
#              /usr/local/bin/sing-box
#
#   success:
#       delete backup
#
#   failure:
#       remove new binary
#       mv backup -> sing-box
#       start old binary
#
# IMPORTANT:
#   No cp is used for binary installation or rollback.
#
# ============================================================

set -eu

# ============================================================
# Configuration
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

# ------------------------------------------------------------
# Key regeneration
#
# 0 = update existing installation and preserve:
#     UUID
#     REALITY private key
#     REALITY short ID
#
# 1 = force regenerate all of them.
# ------------------------------------------------------------

REGENERATE_KEYS="${REGENERATE_KEYS:-0}"

# ------------------------------------------------------------
# Optional SHA256 verification.
#
# Example:
#
# EXPECTED_SHA256="xxxxxxxxxxxxxxxx..." ./setup-singbox.sh
#
# Empty = skip checksum verification.
# ------------------------------------------------------------

EXPECTED_SHA256="${EXPECTED_SHA256:-}"

# ------------------------------------------------------------
# Go memory tuning.
#
# 64MiB is deliberately more conservative than the old 32MiB,
# while avoiding an unnecessarily large memory footprint.
# ------------------------------------------------------------

GOMEMLIMIT_VALUE="${GOMEMLIMIT_VALUE:-64MiB}"
GOGC_VALUE="${GOGC_VALUE:-25}"

# ============================================================
# Runtime variables
# ============================================================

ARCH=""
BIN_NAME=""
BIN_URL=""

UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

SERVER_ADDR=""
CLIENT_VLESS=""

OLD_BINARY_BACKED_UP="0"
NEW_BINARY_INSTALLED="0"

OLD_CONFIG_BACKED_UP="0"
NEW_CONFIG_INSTALLED="0"

OLD_SERVICE_BACKED_UP="0"
NEW_SERVICE_INSTALLED="0"

SERVICE_WAS_RUNNING="0"

# ============================================================
# Logging
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
# Root
# ============================================================

check_root() {
    [ "$(id -u)" = "0" ] || die "请使用 root 运行此脚本"
}

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
# Detect correct release asset
# ============================================================

detect_binary_name() {
    case "$ARCH" in
        amd64)
            BIN_NAME="sing-box-amd64"
            ;;

        arm64)
            BIN_NAME="sing-box-arm64"
            ;;

        *)
            die "未知 CPU 架构: $ARCH"
            ;;
    esac

    BIN_URL="${BIN_BASE_URL}/${BIN_NAME}"

    log "下载文件: $BIN_NAME"
    log "下载地址:"
    printf '    %s\n' "$BIN_URL"
}

# ============================================================
# Prepare directories
# ============================================================

prepare_dirs() {
    log "准备目录..."

    mkdir -p "$TMP_DIR"
    mkdir -p "$CONF_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "/usr/local/bin"

    chmod 700 "$TMP_DIR" 2>/dev/null || true
    chmod 755 "$CONF_DIR" 2>/dev/null || true
    chmod 755 "$LOG_DIR" 2>/dev/null || true

    # --------------------------------------------------------
    # Test /usr/local/tmp write
    # --------------------------------------------------------

    TEST_FILE="${TMP_DIR}/.write-test.$$"

    if ! : > "$TEST_FILE"; then
        die "无法写入 $TMP_DIR"
    fi

    rm -f "$TEST_FILE"

    # --------------------------------------------------------
    # Test /usr/local/bin write
    # --------------------------------------------------------

    TEST_FILE="/usr/local/bin/.write-test.$$"

    if ! : > "$TEST_FILE"; then
        die "无法写入 /usr/local/bin"
    fi

    rm -f "$TEST_FILE"

    # --------------------------------------------------------
    # Test config directory write
    # --------------------------------------------------------

    TEST_FILE="${CONF_DIR}/.write-test.$$"

    if ! : > "$TEST_FILE"; then
        die "无法写入 $CONF_DIR"
    fi

    rm -f "$TEST_FILE"

    # --------------------------------------------------------
    # Test OpenRC directory write
    # --------------------------------------------------------

    TEST_FILE="/etc/init.d/.write-test.$$"

    if ! : > "$TEST_FILE"; then
        die "无法写入 /etc/init.d"
    fi

    rm -f "$TEST_FILE"
}

# ============================================================
# Verify same-filesystem rename
#
# This does a REAL mv test instead of relying on stat syntax,
# because Alpine may use different BusyBox stat implementations.
# ============================================================

verify_binary_rename_path() {
    TEST_SRC="${TMP_DIR}/.rename-test.$$"
    TEST_DST="/usr/local/bin/.rename-test.$$"

    log "检查 /usr/local/tmp -> /usr/local/bin 的 mv..."

    rm -f "$TEST_SRC" "$TEST_DST"

    if ! : > "$TEST_SRC"; then
        die "无法创建 rename 测试文件"
    fi

    if ! mv "$TEST_SRC" "$TEST_DST" 2>/dev/null; then
        rm -f "$TEST_SRC" "$TEST_DST" 2>/dev/null || true

        die "无法执行 /usr/local/tmp -> /usr/local/bin 的 mv。

这通常表示：
  - 两个目录位于不同文件系统；
  - /usr/local/bin 所在文件系统只读；
  - 文件权限不足；
  - 文件系统存在特殊限制。

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
# Download
# ============================================================

download_binary() {
    rm -f "$BIN_TMP"

    log "开始下载 sing-box..."
    printf '    URL : %s\n' "$BIN_URL"
    printf '    DST : %s\n' "$BIN_TMP"

    # --------------------------------------------------------
    # wget
    # --------------------------------------------------------

    if command -v wget >/dev/null 2>&1; then
        log "使用 wget..."

        if wget \
            -T 30 \
            -t 3 \
            -O "$BIN_TMP" \
            "$BIN_URL"; then

            :
        else
            warn "wget 下载失败"
            warn "URL: $BIN_URL"

            rm -f "$BIN_TMP"

            # Retry in verbose mode so the actual HTTP/network
            # error is visible.
            warn "重新尝试一次并显示详细错误..."

            if ! wget \
                -T 30 \
                -t 1 \
                -O "$BIN_TMP" \
                "$BIN_URL"; then

                rm -f "$BIN_TMP"

                die "sing-box 下载失败。

请检查：
  1. GitHub 网络连接
  2. DNS
  3. HTTPS
  4. GitHub Release 是否可访问
  5. 当前 URL 是否返回 404/403/429

URL:
$BIN_URL"
            fi
        fi

    # --------------------------------------------------------
    # curl
    # --------------------------------------------------------

    elif command -v curl >/dev/null 2>&1; then
        log "使用 curl..."

        if ! curl \
            -fL \
            --retry 3 \
            --connect-timeout 15 \
            --max-time 300 \
            --output "$BIN_TMP" \
            "$BIN_URL"; then

            rm -f "$BIN_TMP"

            die "sing-box 下载失败。

URL:
$BIN_URL"
        fi

    else
        die "系统没有 wget 或 curl"
    fi

    [ -s "$BIN_TMP" ] || die "下载完成但文件为空"

    FILE_SIZE="$(wc -c < "$BIN_TMP" | tr -d ' ')"

    log "下载完成，文件大小: ${FILE_SIZE} bytes"
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

    die "没有 sha256sum 或 sha256"
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
# Validate downloaded binary
# ============================================================

validate_downloaded_binary() {
    log "设置临时核心执行权限..."

    chmod 755 "$BIN_TMP"

    verify_sha256 "$BIN_TMP"

    log "验证临时核心..."

    VERSION_OUTPUT=""

    if ! VERSION_OUTPUT="$("$BIN_TMP" version 2>&1)"; then
        warn "临时核心无法执行："
        printf '%s\n' "$VERSION_OUTPUT" >&2

        die "下载文件不是可执行的 sing-box 二进制"
    fi

    printf '%s\n' "$VERSION_OUTPUT"

    case "$VERSION_OUTPUT" in
        *sing-box*)
            ;;
        *)
            warn "version 输出没有明显包含 sing-box"
            ;;
    esac

    # --------------------------------------------------------
    # Check architecture when file reports it.
    # --------------------------------------------------------

    log "临时核心执行验证通过"
}

download_and_validate_binary() {
    download_binary
    validate_downloaded_binary
}

# ============================================================
# Existing service status
# ============================================================

service_is_running() {
    if pgrep -x sing-box >/dev/null 2>&1; then
        return 0
    fi

    if rc-service sing-box status >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# ============================================================
# Stop old xray
# ============================================================

stop_old_xray() {
    if [ -x /etc/init.d/xray ]; then
        log "检测到旧 xray OpenRC service..."

        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
    fi

    if pgrep -x xray >/dev/null 2>&1; then
        log "停止旧 xray 进程..."

        pkill -x xray >/dev/null 2>&1 || true

        sleep 1
    fi
}

# ============================================================
# Stop sing-box
# ============================================================

stop_singbox() {
    SERVICE_WAS_RUNNING="0"

    if service_is_running; then
        SERVICE_WAS_RUNNING="1"
    fi

    if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
        log "停止现有 sing-box..."

        rc-service sing-box stop >/dev/null 2>&1 || true
    fi

    # --------------------------------------------------------
    # Wait for process to disappear.
    # --------------------------------------------------------

    i=0

    while pgrep -x sing-box >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done

    # --------------------------------------------------------
    # Exact process fallback.
    # --------------------------------------------------------

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
# Binary backup
#
# hard link instead of cp.
# ============================================================

backup_old_binary() {
    rm -f "$BIN_BACKUP"

    if [ ! -f "$BIN_DST" ]; then
        OLD_BINARY_BACKED_UP="0"
        return 0
    fi

    log "创建旧核心硬链接备份..."

    if ! ln "$BIN_DST" "$BIN_BACKUP" 2>/dev/null; then
        die "无法创建旧 sing-box 硬链接备份。

当前路径：
  old: $BIN_DST
  backup: $BIN_BACKUP

请检查：
  ls -l $BIN_DST
  ls -ld $TMP_DIR /usr/local/bin
  df -h
  df -T"
    fi

    OLD_BINARY_BACKED_UP="1"
}

# ============================================================
# Install binary
# ============================================================

install_new_binary() {
    log "使用 mv 原子替换正式核心..."

    if ! mv "$BIN_TMP" "$BIN_DST"; then
        die "正式核心 mv 失败"
    fi

    chmod 755 "$BIN_DST"

    NEW_BINARY_INSTALLED="1"

    log "正式核心替换完成"
}

# ============================================================
# Remove binary backup
# ============================================================

remove_binary_backup() {
    if [ "$OLD_BINARY_BACKED_UP" = "1" ]; then
        rm -f "$BIN_BACKUP"
        OLD_BINARY_BACKED_UP="0"
    fi
}

# ============================================================
# Rollback binary
# ============================================================

rollback_binary() {
    warn "开始回滚 sing-box 核心..."

    if [ "$NEW_BINARY_INSTALLED" = "1" ]; then
        rm -f "$BIN_DST"
        NEW_BINARY_INSTALLED="0"
    fi

    if [ "$OLD_BINARY_BACKED_UP" = "1" ] &&
       [ -f "$BIN_BACKUP" ]; then

        if mv "$BIN_BACKUP" "$BIN_DST"; then
            chmod 755 "$BIN_DST" 2>/dev/null || true

            OLD_BINARY_BACKED_UP="0"

            log "旧 sing-box 核心已恢复"
        else
            warn "旧核心恢复失败"
            warn "备份仍在：$BIN_BACKUP"
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

    die "无法生成 UUID：缺少 uuidgen 和 /proc/sys/kernel/random/uuid"
}

# ============================================================
# Validate UUID
# ============================================================

validate_uuid() {
    VALUE="$1"

    case "$VALUE" in
        ????????-????-????-????-????????????)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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

    PRIVATE_KEY="$(
        printf '%s\n' "$KEYPAIR" |
        awk -F': ' '
            /PrivateKey/ {
                print $2
                exit
            }
        '
    )"

    PUBLIC_KEY="$(
        printf '%s\n' "$KEYPAIR" |
        awk -F': ' '
            /PublicKey/ {
                print $2
                exit
            }
        '
    )"

    [ -n "$PRIVATE_KEY" ] ||
        die "无法解析 REALITY PrivateKey"

    [ -n "$PUBLIC_KEY" ] ||
        die "无法解析 REALITY PublicKey"

    log "REALITY keypair 生成成功"
}

# ============================================================
# Short ID
# ============================================================

generate_short_id() {
    log "生成 REALITY short ID..."

    SHORT_ID=""

    if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        SHORT_ID="$(
            od -An -N8 -tx1 /dev/urandom |
            tr -d ' \n'
        )"
    fi

    case "$SHORT_ID" in
        ????????????????)
            ;;
        *)
            if command -v md5sum >/dev/null 2>&1; then
                SHORT_ID="$(
                    printf '%s-%s-%s' \
                        "$(date +%s)" \
                        "$$" \
                        "$(cat /proc/uptime 2>/dev/null || true)" |
                    md5sum |
                    awk '{print substr($1,1,16)}'
                )"
            fi
            ;;
    esac

    case "$SHORT_ID" in
        ????????????????)
            ;;
        *)
            die "无法生成有效的 REALITY short ID"
            ;;
    esac

    log "REALITY short ID: $SHORT_ID"
}

# ============================================================
# Extract existing config value
#
# These parsers intentionally target the config generated by
# this script. They are not intended as a general JSON parser.
# ============================================================

extract_json_string() {
    FILE="$1"
    KEY="$2"

    awk -v key="$KEY" '
        index($0, "\"" key "\"") {
            line=$0

            sub("^.*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", line)
            sub("\"[[:space:]]*,?[[:space:]]*$", "", line)

            if (line != $0) {
                print line
                exit
            }
        }
    ' "$FILE"
}

load_existing_identity() {
    [ -f "$CONF_FILE" ] || return 1

    OLD_UUID="$(extract_json_string "$CONF_FILE" "uuid" || true)"
    OLD_PRIVATE_KEY="$(extract_json_string "$CONF_FILE" "private_key" || true)"
    OLD_SHORT_ID="$(extract_json_string "$CONF_FILE" "short_id" || true)"

    if ! validate_uuid "$OLD_UUID"; then
        return 1
    fi

    [ -n "$OLD_PRIVATE_KEY" ] || return 1
    [ -n "$OLD_SHORT_ID" ] || return 1

    UUID="$OLD_UUID"
    PRIVATE_KEY="$OLD_PRIVATE_KEY"
    SHORT_ID="$OLD_SHORT_ID"

    # Public key isn't normally stored in the server config.
    # It will be derived from the private key below.
    return 0
}

# ============================================================
# Derive REALITY public key
#
# sing-box 1.13.x supports:
#   generate reality-keypair
#
# There is no universally reliable "private-key -> public-key"
# command exposed in all versions, therefore the script stores
# the public key in INFO_FILE and prefers it during updates.
# ============================================================

load_existing_public_key() {
    PUBLIC_KEY=""

    if [ -f "$INFO_FILE" ]; then
        PUBLIC_KEY="$(
            awk '
                /^REALITY Public Key:/ {
                    getline
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                    print
                    exit
                }
            ' "$INFO_FILE"
        )"
    fi

    [ -n "$PUBLIC_KEY" ]
}

# ============================================================
# Identity generation / reuse
# ============================================================

prepare_identity() {
    # --------------------------------------------------------
    # Force regeneration.
    # --------------------------------------------------------

    if [ "$REGENERATE_KEYS" = "1" ]; then
        log "REGENERATE_KEYS=1，重新生成 UUID / REALITY keypair / short ID"

        UUID="$(generate_uuid)"
        generate_reality_keypair
        generate_short_id

        return 0
    fi

    # --------------------------------------------------------
    # Try to preserve existing identity.
    # --------------------------------------------------------

    if load_existing_identity; then

        if load_existing_public_key; then
            log "检测到已有 sing-box 身份，保持 UUID / REALITY key / short ID 不变"
            return 0
        fi

        warn "检测到旧配置，但无法从信息文件读取 REALITY Public Key"
        warn "为了避免生成不匹配的客户端 Public Key，本次将重新生成 REALITY keypair"

        UUID="$(generate_uuid)"
        generate_reality_keypair
        generate_short_id

        return 0
    fi

    # --------------------------------------------------------
    # New installation.
    # --------------------------------------------------------

    log "未检测到可复用的旧身份，生成新的 UUID / REALITY keypair / short ID"

    UUID="$(generate_uuid)"

    generate_reality_keypair
    generate_short_id
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
            die "DOMAIN 不能以 . 开头或结尾"
            ;;

        -*|*-)
            die "DOMAIN 不能以 - 开头或结尾"
            ;;
    esac

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
# JSON escape
# ============================================================

json_escape() {
    printf '%s' "$1" |
        sed \
            's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

# ============================================================
# Write config
# ============================================================

write_config_temp() {
    validate_domain
    validate_port

    prepare_identity

    DOMAIN_JSON="$(json_escape "$DOMAIN")"
    UUID_JSON="$(json_escape "$UUID")"
    PRIVATE_KEY_JSON="$(json_escape "$PRIVATE_KEY")"
    SHORT_ID_JSON="$(json_escape "$SHORT_ID")"

    log "生成新的 config.json 临时文件..."

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

    log "验证新配置..."

    if ! "$BIN_DST" check -c "$CONF_TMP"; then
        rm -f "$CONF_TMP"
        die "新配置检查失败，拒绝替换正式配置"
    fi

    log "新配置检查通过"
}

# ============================================================
# Config backup
# ============================================================

backup_old_config() {
    rm -f "$CONF_BACKUP"

    if [ ! -f "$CONF_FILE" ]; then
        OLD_CONFIG_BACKED_UP="0"
        return 0
    fi

    log "创建旧配置硬链接备份..."

    if ! ln "$CONF_FILE" "$CONF_BACKUP" 2>/dev/null; then
        die "无法创建旧配置备份"
    fi

    OLD_CONFIG_BACKED_UP="1"
}

# ============================================================
# Install config
# ============================================================

install_new_config() {
    log "使用 mv 原子替换 config.json..."

    if ! mv "$CONF_TMP" "$CONF_FILE"; then
        die "config.json 原子替换失败"
    fi

    chmod 600 "$CONF_FILE"

    NEW_CONFIG_INSTALLED="1"
}

# ============================================================
# Remove config backup
# ============================================================

remove_config_backup() {
    if [ "$OLD_CONFIG_BACKED_UP" = "1" ]; then
        rm -f "$CONF_BACKUP"
        OLD_CONFIG_BACKED_UP="0"
    fi
}

# ============================================================
# Rollback config
# ============================================================

rollback_config() {
    warn "开始回滚配置..."

    if [ "$NEW_CONFIG_INSTALLED" = "1" ]; then
        rm -f "$CONF_FILE"
        NEW_CONFIG_INSTALLED="0"
    fi

    if [ "$OLD_CONFIG_BACKED_UP" = "1" ] &&
       [ -f "$CONF_BACKUP" ]; then

        if mv "$CONF_BACKUP" "$CONF_FILE"; then
            chmod 600 "$CONF_FILE" 2>/dev/null || true

            OLD_CONFIG_BACKED_UP="0"

            log "旧配置已经恢复"
        else
            warn "旧配置恢复失败"
            warn "备份仍在：$CONF_BACKUP"
        fi
    fi
}

# ============================================================
# OpenRC service
# ============================================================

write_service_temp() {
    log "生成 OpenRC service..."

    rm -f "$SERVICE_TMP"

    cat > "$SERVICE_TMP" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box VLESS REALITY service"

command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"

command_user="root:root"

pidfile="/run/\${RC_SVCNAME}.pid"

output_log="/var/log/sing-box/openrc.log"
error_log="/var/log/sing-box/openrc-error.log"

command_background="yes"

# Low-memory tuning.
export GOMEMLIMIT="${GOMEMLIMIT_VALUE}"
export GOGC="${GOGC_VALUE}"

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
        "\$output_log"

    checkpath \
        --file \
        --mode 0600 \
        "\$error_log"

    if [ ! -x "\$command" ]; then
        eerror "sing-box binary not found: \$command"
        return 1
    fi

    if [ ! -f /usr/local/etc/sing-box/config.json ]; then
        eerror "sing-box config not found"
        return 1
    fi

    "\$command" check \
        -c /usr/local/etc/sing-box/config.json
}
EOF

    chmod 755 "$SERVICE_TMP"

    if ! /bin/ash -n "$SERVICE_TMP"; then
        rm -f "$SERVICE_TMP"
        die "OpenRC service shell 语法检查失败"
    fi

    log "OpenRC service 语法检查通过"
}

# ============================================================
# Service backup
# ============================================================

backup_old_service() {
    rm -f "$SERVICE_BACKUP"

    if [ ! -f "$SERVICE_FILE" ]; then
        OLD_SERVICE_BACKED_UP="0"
        return 0
    fi

    log "创建旧 OpenRC service 硬链接备份..."

    if ! ln "$SERVICE_FILE" "$SERVICE_BACKUP" 2>/dev/null; then
        die "无法创建旧 OpenRC service 备份"
    fi

    OLD_SERVICE_BACKED_UP="1"
}

# ============================================================
# Install service
# ============================================================

install_new_service() {
    log "使用 mv 原子替换 OpenRC service..."

    if ! mv "$SERVICE_TMP" "$SERVICE_FILE"; then
        die "OpenRC service 替换失败"
    fi

    chmod 755 "$SERVICE_FILE"

    NEW_SERVICE_INSTALLED="1"
}

# ============================================================
# Remove service backup
# ============================================================

remove_service_backup() {
    if [ "$OLD_SERVICE_BACKED_UP" = "1" ]; then
        rm -f "$SERVICE_BACKUP"
        OLD_SERVICE_BACKED_UP="0"
    fi
}

# ============================================================
# Rollback service
# ============================================================

rollback_service() {
    if [ "$NEW_SERVICE_INSTALLED" = "1" ]; then
        rm -f "$SERVICE_FILE"
        NEW_SERVICE_INSTALLED="0"
    fi

    if [ "$OLD_SERVICE_BACKED_UP" = "1" ] &&
       [ -f "$SERVICE_BACKUP" ]; then

        if mv "$SERVICE_BACKUP" "$SERVICE_FILE"; then
            chmod 755 "$SERVICE_FILE" 2>/dev/null || true
            OLD_SERVICE_BACKED_UP="0"

            log "旧 OpenRC service 已恢复"
        else
            warn "旧 OpenRC service 恢复失败"
            warn "备份仍在：$SERVICE_BACKUP"
        fi
    fi
}

# ============================================================
# Enable OpenRC service
# ============================================================

enable_service() {
    log "启用 sing-box OpenRC service..."

    if ! rc-update add sing-box default >/dev/null 2>&1; then
        warn "rc-update add sing-box default 失败"
    fi
}

# ============================================================
# Start service
# ============================================================

start_service() {
    log "启动 sing-box..."

    if ! rc-service sing-box start; then
        return 1
    fi

    sleep 2

    if ! pgrep -x sing-box >/dev/null 2>&1; then
        warn "OpenRC start 成功，但没有检测到 sing-box 进程"
        return 1
    fi

    return 0
}

# ============================================================
# Stop + start
# ============================================================

restart_service() {
    log "重新启动 sing-box..."

    rc-service sing-box stop >/dev/null 2>&1 || true

    i=0

    while pgrep -x sing-box >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done

    if pgrep -x sing-box >/dev/null 2>&1; then
        pkill -x sing-box >/dev/null 2>&1 || true
        sleep 1
    fi

    if ! start_service; then
        return 1
    fi

    return 0
}

# ============================================================
# Detect public IPv4
# ============================================================

detect_server_address() {
    SERVER_ADDR=""

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
# Build VLESS client URL
# ============================================================

build_client_link() {
    detect_server_address

    CLIENT_VLESS="vless://${UUID}@${SERVER_ADDR}:${PORT}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#sing-box-REALITY"
}

# ============================================================
# Write client information
# ============================================================

write_info() {
    build_client_link

    log "写入客户端信息..."

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

------------------------------------------------------------
Paths

Binary:
${BIN_DST}

Config:
${CONF_FILE}

OpenRC:
${SERVICE_FILE}

Log:
${LOG_DIR}

============================================================
EOF

    chmod 600 "$INFO_FILE"

    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "VLESS + REALITY"
    printf '%s\n' "============================================================"
    printf '%s\n' "$CLIENT_VLESS"
    printf '%s\n' "============================================================"
    printf '\n'

    log "完整客户端信息已保存到:"
    printf '    %s\n' "$INFO_FILE"
}

# ============================================================
# Verify final installation
# ============================================================

verify_final_installation() {
    log "执行最终检查..."

    if [ ! -x "$BIN_DST" ]; then
        die "正式核心不存在或不可执行: $BIN_DST"
    fi

    if ! "$BIN_DST" version >/dev/null 2>&1; then
        die "正式核心执行失败"
    fi

    if [ ! -f "$CONF_FILE" ]; then
        die "正式配置不存在: $CONF_FILE"
    fi

    if ! "$BIN_DST" check -c "$CONF_FILE"; then
        die "正式配置检查失败"
    fi

    if [ ! -x "$SERVICE_FILE" ]; then
        die "OpenRC service 不存在或不可执行"
    fi

    if ! pgrep -x sing-box >/dev/null 2>&1; then
        die "sing-box 进程未运行"
    fi

    log "最终检查通过"
}

# ============================================================
# Show status
# ============================================================

show_status() {
    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "sing-box status"
    printf '%s\n' "============================================================"

    printf '%s\n' "Architecture:"
    printf '    %s\n' "$ARCH"

    printf '%s\n' "Binary:"
    printf '    %s\n' "$BIN_DST"

    if [ -x "$BIN_DST" ]; then
        "$BIN_DST" version 2>/dev/null || true
    fi

    printf '%s\n' "Config:"
    printf '    %s\n' "$CONF_FILE"

    printf '%s\n' "Service:"
    printf '    %s\n' "$SERVICE_FILE"

    if pgrep -x sing-box >/dev/null 2>&1; then
        printf '%s\n' "Process: running"
    else
        printf '%s\n' "Process: stopped"
    fi

    printf '%s\n' "Temporary directory:"
    printf '    %s\n' "$TMP_DIR"

    printf '%s\n' "Client info:"
    printf '    %s\n' "$INFO_FILE"

    printf '%s\n' "============================================================"
}

# ============================================================
# Full transaction
# ============================================================

install_or_update() {
    detect_arch
    detect_binary_name

    prepare_dirs

    # --------------------------------------------------------
    # Important:
    # Verify final binary rename BEFORE downloading.
    # --------------------------------------------------------

    verify_binary_rename_path

    # --------------------------------------------------------
    # 1. Download and validate new binary.
    #
    # Existing sing-box remains running at this point.
    # --------------------------------------------------------

    download_and_validate_binary

    # --------------------------------------------------------
    # 2. Stop old services only after the new binary has passed
    #    validation.
    # --------------------------------------------------------

    stop_old_xray
    stop_singbox

    # --------------------------------------------------------
    # 3. Backup old binary using hard link.
    # --------------------------------------------------------

    backup_old_binary

    # --------------------------------------------------------
    # 4. Install new binary.
    # --------------------------------------------------------

    install_new_binary

    # --------------------------------------------------------
    # 5. Build and validate new config.
    # --------------------------------------------------------

    write_config_temp

    # --------------------------------------------------------
    # 6. Backup old config.
    # --------------------------------------------------------

    backup_old_config

    # --------------------------------------------------------
    # 7. Replace config atomically.
    # --------------------------------------------------------

    install_new_config

    # --------------------------------------------------------
    # 8. Build and install OpenRC service.
    # --------------------------------------------------------

    write_service_temp
    backup_old_service
    install_new_service

    # --------------------------------------------------------
    # 9. Enable service.
    # --------------------------------------------------------

    enable_service

    # --------------------------------------------------------
    # 10. Start new version.
    # --------------------------------------------------------

    if ! start_service; then
        warn "新版本启动失败，开始事务回滚..."

        # Stop failed new process.
        rc-service sing-box stop >/dev/null 2>&1 || true

        if pgrep -x sing-box >/dev/null 2>&1; then
            pkill -x sing-box >/dev/null 2>&1 || true
            sleep 1
        fi

        # Restore config.
        rollback_config

        # Restore service.
        rollback_service

        # Restore binary.
        rollback_binary

        # Try old installation.
        if [ -x "$BIN_DST" ] && [ -f "$CONF_FILE" ]; then
            log "尝试启动恢复后的旧版本..."

            if start_service; then
                warn "旧版本 sing-box 已恢复运行"
            else
                warn "旧版本也无法启动"
                warn "请检查："
                warn "    rc-service sing-box status"
                warn "    $LOG_DIR"
                warn "    $CONF_FILE"
            fi
        fi

        die "更新失败，事务已经执行回滚"
    fi

    # --------------------------------------------------------
    # 11. Final verification.
    # --------------------------------------------------------

    if ! verify_final_installation; then
        warn "最终检查失败，开始回滚..."

        rc-service sing-box stop >/dev/null 2>&1 || true

        rollback_config
        rollback_service
        rollback_binary

        if [ -x "$BIN_DST" ] && [ -f "$CONF_FILE" ]; then
            start_service >/dev/null 2>&1 || true
        fi

        die "最终检查失败，已执行回滚"
    fi

    # --------------------------------------------------------
    # 12. Commit transaction.
    # --------------------------------------------------------

    remove_binary_backup
    remove_config_backup
    remove_service_backup

    rm -f \
        "$BIN_TMP" \
        "$CONF_TMP" \
        "$SERVICE_TMP"

    write_info

    show_status

    printf '\n'
    log "============================================================"
    log "sing-box VLESS + REALITY 安装/更新成功"
    log "============================================================"
}

# ============================================================
# Main
# ============================================================

main() {
    check_root

    log "开始执行 sing-box VLESS + REALITY 安装/更新"
    log "临时目录: $TMP_DIR"
    log "正式核心: $BIN_DST"
    log "配置文件: $CONF_FILE"
    log "OpenRC:   $SERVICE_FILE"

    install_or_update
}

main "$@"
