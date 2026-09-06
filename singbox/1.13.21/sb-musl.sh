```sh
#!/bin/ash
# setup-singbox-reality.sh
#
# Alpine Linux low-memory sing-box VLESS + REALITY installer/config updater.
#
# Supported architectures:
#   x86_64 / amd64
#   aarch64 / arm64
#
# Binary files:
#   amd64:
#   https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-amd64
#
#   arm64:
#   https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-arm64
#
# Binary files are already unpacked musl executables.
#
# Main design:
#
#   INSTALL:
#       detect arch
#           ↓
#       download to /tmp
#           ↓
#       validate temporary binary
#           ↓
#       copy to /usr/local/bin/.sing-box.new
#           ↓
#       validate destination binary
#           ↓
#       atomic mv inside SAME filesystem
#           ↓
#       generate configuration
#           ↓
#       validate configuration
#           ↓
#       start service
#
#   BINARY UPDATE:
#       download
#           ↓
#       validate
#           ↓
#       install new binary
#           ↓
#       validate existing configuration
#           ↓
#       restart service
#           ↓
#       if restart fails:
#           restore previous binary
#           ↓
#           restart old service
#
#   CONFIG UPDATE:
#       generate new configuration
#           ↓
#       validate temporary configuration
#           ↓
#       atomic replace config
#           ↓
#       restart service
#           ↓
#       if restart fails:
#           restore previous config
#           ↓
#           restart old service
#
# Important:
#
#   /tmp may be tmpfs while /usr/local is on another filesystem.
#   Therefore the final mv MUST happen inside /usr/local/bin.
#
#   The final operation:
#
#       /usr/local/bin/.sing-box.new.$$
#                    ↓
#                  mv
#                    ↓
#       /usr/local/bin/sing-box
#
#   is an atomic rename on the same filesystem.
#
# Designed for small Alpine VPS / containers.
#
# NOTE:
#   This script does NOT download archives.
#   GitHub Release files are already unpacked executables.

set -eu


###############################################################################
# Configuration
###############################################################################

BIN_BASE_URL="${BIN_BASE_URL:-https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi}"

BIN_DST="/usr/local/bin/sing-box"

# Downloaded file lives in /tmp.
BIN_DOWNLOAD_TMP="/tmp/sing-box-download.$$"

# IMPORTANT:
# This file is created in the same filesystem as BIN_DST.
BIN_INSTALL_TMP="/usr/local/bin/.sing-box.new.$$"

# Backup binary is also created in the same filesystem.
BIN_BACKUP="/usr/local/bin/.sing-box.backup.$$"

CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
CONF_TMP="${CONF_DIR}/.config.json.new.$$"
CONF_BACKUP="${CONF_DIR}/.config.json.backup.$$"

SERVICE_FILE="/etc/init.d/sing-box"
SERVICE_TMP="/etc/init.d/.sing-box.new.$$"
SERVICE_BACKUP="/etc/init.d/.sing-box.backup.$$"

LOG_DIR="/var/log/sing-box"
INFO_FILE="/root/singbox-vless-reality-info.txt"

DEFAULT_PORT="${DEFAULT_PORT:-443}"
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-www.cloudflare.com}"

# Low-memory Go runtime.
# Can be overridden:
#
#   GOMEMLIMIT=64MiB GOGC=25 ./setup-singbox-reality.sh
#
GOMEMLIMIT="${GOMEMLIMIT:-64MiB}"
GOGC="${GOGC:-25}"


###############################################################################
# Runtime variables
###############################################################################

ARCH=""
SING_BOX_ARCH=""
SING_BOX_FILE=""
BIN_URL=""
DOWNLOAD_TOOL=""

PORT=""
PORT_INPUT=""

REALITY_DOMAIN=""
DOMAIN_INPUT=""

HANDSHAKE_SERVER=""
HANDSHAKE_PORT="443"

UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

KEYPAIR=""

SERVER_ADDR=""
LINK=""

OLD_BINARY_EXISTS="no"
OLD_CONFIG_EXISTS="no"
OLD_SERVICE_EXISTS="no"


###############################################################################
# Cleanup
###############################################################################

cleanup() {
    rm -f "$BIN_DOWNLOAD_TMP" 2>/dev/null || true
    rm -f "$BIN_INSTALL_TMP" 2>/dev/null || true

    # Do not automatically remove backups here.
    #
    # Backups may be needed by rollback logic.
    #
    # Successful operations explicitly remove them.

    rm -f "$CONF_TMP" 2>/dev/null || true
    rm -f "$SERVICE_TMP" 2>/dev/null || true
}

trap cleanup EXIT INT TERM


###############################################################################
# Basic functions
###############################################################################

log() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

die() {
    echo "[x] $*" >&2
    exit 1
}

pause() {
    echo
    printf "按回车键继续..."
    read -r _ || true
}


###############################################################################
# Root
###############################################################################

require_root() {
    [ "$(id -u)" = "0" ] || die "请使用 root 用户运行。"
}


###############################################################################
# Low-memory protection
###############################################################################

protect_ssh() {
    # Lower OOM score for current shell where possible.
    echo -1000 > /proc/$$/oom_score_adj 2>/dev/null || true

    # Lower OOM score for sshd processes where possible.
    if command -v pgrep >/dev/null 2>&1; then
        for p in $(pgrep -x sshd 2>/dev/null || true); do
            echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null || true
        done
    fi
}


###############################################################################
# OpenRC runtime
###############################################################################

ensure_openrc_runtime() {
    mkdir -p /run/openrc
    touch /run/openrc/softlevel 2>/dev/null || true
}


###############################################################################
# Directory preparation
###############################################################################

prepare_directories() {
    mkdir -p \
        /usr/local/bin \
        "$CONF_DIR" \
        "$LOG_DIR" \
        /etc/init.d

    # Check that target directories are writable.
    test_write_file="/usr/local/bin/.write-test.$$"

    if ! touch "$test_write_file" 2>/dev/null; then
        die "/usr/local/bin 不可写。

请检查：
  - 文件系统是否只读
  - 权限
  - 磁盘空间
  - 容器挂载状态"
    fi

    rm -f "$test_write_file"

    test_write_file="${CONF_DIR}/.write-test.$$"

    if ! touch "$test_write_file" 2>/dev/null; then
        die "${CONF_DIR} 不可写。"
    fi

    rm -f "$test_write_file"

    test_write_file="${LOG_DIR}/.write-test.$$"

    if ! touch "$test_write_file" 2>/dev/null; then
        die "${LOG_DIR} 不可写。"
    fi

    rm -f "$test_write_file"
}


###############################################################################
# Detect CPU architecture
###############################################################################

detect_arch() {
    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64)
            SING_BOX_ARCH="amd64"
            SING_BOX_FILE="sing-box-amd64"
            ;;

        aarch64|arm64)
            SING_BOX_ARCH="arm64"
            SING_BOX_FILE="sing-box-arm64"
            ;;

        *)
            die "不支持的 CPU 架构：${ARCH}

当前脚本支持：
  x86_64 / amd64
  aarch64 / arm64"
            ;;
    esac

    BIN_URL="${BIN_BASE_URL}/${SING_BOX_FILE}"

    log "CPU 架构：${ARCH}"
    log "目标架构：${SING_BOX_ARCH}"
    log "核心文件：${SING_BOX_FILE}"
}


###############################################################################
# Detect wget / curl
###############################################################################

detect_download_tool() {
    if command -v wget >/dev/null 2>&1; then
        DOWNLOAD_TOOL="wget"
        return
    fi

    if command -v curl >/dev/null 2>&1; then
        DOWNLOAD_TOOL="curl"
        return
    fi

    die "系统没有 wget 或 curl，无法下载 sing-box。"
}


###############################################################################
# Validate port
###############################################################################

validate_port() {
    port="$1"

    case "$port" in
        "")
            die "端口不能为空。"
            ;;
        *[!0-9]*)
            die "端口必须是数字。"
            ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        die "端口范围必须是 1-65535。"
    fi
}


###############################################################################
# Validate domain
#
# This intentionally uses a conservative hostname validation.
#
# Accepted examples:
#   www.cloudflare.com
#   www.example.com
#   example.com
#
# Rejected:
#   http://example.com
#   https://example.com
#   example.com:443
#   /example.com
#   example.com/path
#   spaces
###############################################################################

validate_domain() {
    domain="$1"

    case "$domain" in
        "")
            die "域名不能为空。"
            ;;
        http://*)
            die "请输入纯域名，不要带 http://。"
            ;;
        https://*)
            die "请输入纯域名，不要带 https://。"
            ;;
        */*)
            die "域名格式不正确，请不要包含 /。"
            ;;
        *:*)
            die "域名格式不正确，请不要带端口。"
            ;;
        *" "*)
            die "域名格式不正确，请不要包含空格。"
            ;;
        *[!A-Za-z0-9.-]*)
            die "域名只能包含字母、数字、点和连字符。"
            ;;
        .*|*.)
            die "域名不能以 . 开头或结尾。"
            ;;
        -*|*-)
            die "域名不能以 - 开头或结尾。"
            ;;
        *..*)
            die "域名不能包含连续的 ..。"
            ;;
    esac

    # Require at least one alphabetic/dns-like character.
    case "$domain" in
        *[A-Za-z]*)
            ;;
        *)
            die "请输入有效的域名。"
            ;;
    esac
}


###############################################################################
# Ask port / REALITY domain
###############################################################################

ask_port_domain() {
    echo

    printf "请输入监听端口 [%s]: " "$DEFAULT_PORT"
    read -r PORT_INPUT || true

    PORT="${PORT_INPUT:-$DEFAULT_PORT}"

    validate_port "$PORT"

    printf "请输入 REALITY 域名 / SNI [%s]: " "$DEFAULT_DOMAIN"
    read -r DOMAIN_INPUT || true

    REALITY_DOMAIN="${DOMAIN_INPUT:-$DEFAULT_DOMAIN}"

    validate_domain "$REALITY_DOMAIN"

    HANDSHAKE_SERVER="$REALITY_DOMAIN"
    HANDSHAKE_PORT="443"

    echo
    log "监听端口：${PORT}"
    log "REALITY SNI：${REALITY_DOMAIN}"
    log "REALITY handshake：${HANDSHAKE_SERVER}:${HANDSHAKE_PORT}"
}


###############################################################################
# Check whether service exists
###############################################################################

service_exists() {
    [ -x "$SERVICE_FILE" ]
}


###############################################################################
# Check whether sing-box process is still running
###############################################################################

singbox_process_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x sing-box >/dev/null 2>&1
        return $?
    fi

    # Fallback for minimal Alpine installations.
    ps 2>/dev/null |
        grep '[s]ing-box' >/dev/null 2>&1
}


###############################################################################
# Stop sing-box safely
###############################################################################

stop_singbox() {
    if service_exists; then
        rc-service sing-box stop 2>/dev/null || true
    fi

    # Give OpenRC a chance to stop the process.
    i=0

    while singbox_process_running; do
        i=$((i + 1))

        if [ "$i" -ge 10 ]; then
            break
        fi

        sleep 1
    done

    # Fallback: terminate only exact sing-box process names.
    if singbox_process_running; then
        warn "OpenRC 未能及时停止 sing-box，发送 TERM..."

        if command -v pkill >/dev/null 2>&1; then
            pkill -TERM -x sing-box 2>/dev/null || true
        fi
    fi

    i=0

    while singbox_process_running; do
        i=$((i + 1))

        if [ "$i" -ge 10 ]; then
            break
        fi

        sleep 1
    done

    if singbox_process_running; then
        warn "sing-box 仍在运行，发送 KILL..."

        if command -v pkill >/dev/null 2>&1; then
            pkill -KILL -x sing-box 2>/dev/null || true
        fi
    fi

    if singbox_process_running; then
        die "无法停止正在运行的 sing-box。"
    fi
}


###############################################################################
# Stop old conflicting xray service
#
# This keeps compatibility with the original script.
###############################################################################

stop_conflicting_xray() {
    if [ -x /etc/init.d/xray ]; then
        log "停止可能冲突的 xray 服务..."

        rc-service xray stop 2>/dev/null || true
        rc-update del xray default 2>/dev/null || true
    fi

    if command -v pgrep >/dev/null 2>&1 &&
       command -v pkill >/dev/null 2>&1; then

        if pgrep -x xray >/dev/null 2>&1; then
            warn "检测到独立 xray 进程，发送 TERM..."

            pkill -TERM -x xray 2>/dev/null || true

            i=0

            while pgrep -x xray >/dev/null 2>&1; do
                i=$((i + 1))

                if [ "$i" -ge 10 ]; then
                    break
                fi

                sleep 1
            done

            if pgrep -x xray >/dev/null 2>&1; then
                warn "xray 仍在运行，发送 KILL..."
                pkill -KILL -x xray 2>/dev/null || true
            fi
        fi
    fi
}


###############################################################################
# Stop conflicting services
###############################################################################

stop_conflicting_services() {
    stop_conflicting_xray
    stop_singbox
}


###############################################################################
# Generate UUID
###############################################################################

generate_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        UUID="$(cat /proc/sys/kernel/random/uuid)"
    else
        UUID=""
    fi

    case "$UUID" in
        ????????-????-????-????-????????????)
            ;;
        *)
            die "UUID 生成失败。"
            ;;
    esac
}


###############################################################################
# Parse REALITY keypair output
#
# Supports common formats such as:
#
#   PrivateKey: xxxxx
#   PublicKey:  xxxxx
#
# and:
#
#   Private key: xxxxx
#   Public key:  xxxxx
###############################################################################

parse_reality_keypair() {
    KEYPAIR="$1"

    PRIVATE_KEY="$(
        printf '%s\n' "$KEYPAIR" |
        awk '
            BEGIN { IGNORECASE=1 }
            /^[[:space:]]*private([[:space:]]+key)?[[:space:]]*:/ {
                sub(/^[^:]*:[[:space:]]*/, "")
                print
                exit
            }
        '
    )"

    PUBLIC_KEY="$(
        printf '%s\n' "$KEYPAIR" |
        awk '
            BEGIN { IGNORECASE=1 }
            /^[[:space:]]*public([[:space:]]+key)?[[:space:]]*:/ {
                sub(/^[^:]*:[[:space:]]*/, "")
                print
                exit
            }
        '
    )"

    # Fallback parser.
    #
    # Some builds may use:
    #
    #   PrivateKey = ...
    #   PublicKey = ...
    #
    if [ -z "$PRIVATE_KEY" ]; then
        PRIVATE_KEY="$(
            printf '%s\n' "$KEYPAIR" |
            awk '
                BEGIN { IGNORECASE=1 }
                /private/ {
                    if (index($0, ":")) {
                        sub(/^[^:]*:[[:space:]]*/, "")
                        print
                        exit
                    }
                    if (index($0, "=")) {
                        sub(/^[^=]*=[[:space:]]*/, "")
                        print
                        exit
                    }
                }
            '
        )"
    fi

    if [ -z "$PUBLIC_KEY" ]; then
        PUBLIC_KEY="$(
            printf '%s\n' "$KEYPAIR" |
            awk '
                BEGIN { IGNORECASE=1 }
                /public/ {
                    if (index($0, ":")) {
                        sub(/^[^:]*:[[:space:]]*/, "")
                        print
                        exit
                    }
                    if (index($0, "=")) {
                        sub(/^[^=]*=[[:space:]]*/, "")
                        print
                        exit
                    }
                }
            '
        )"
    fi

    # Remove CR characters in case command output contains CRLF.
    PRIVATE_KEY="$(printf '%s' "$PRIVATE_KEY" | tr -d '\r')"
    PUBLIC_KEY="$(printf '%s' "$PUBLIC_KEY" | tr -d '\r')"

    [ -n "$PRIVATE_KEY" ] \
        || die "REALITY private_key 解析失败。

sing-box 输出：
${KEYPAIR}"

    [ -n "$PUBLIC_KEY" ] \
        || die "REALITY public_key 解析失败。

sing-box 输出：
${KEYPAIR}"
}


###############################################################################
# Generate REALITY values
###############################################################################

generate_reality_values() {
    log "生成 VLESS UUID..."

    generate_uuid

    log "生成 REALITY keypair..."

    KEYPAIR="$(
        "$BIN_DST" generate reality-keypair
    )" || die "REALITY keypair 生成失败。"

    [ -n "$KEYPAIR" ] \
        || die "REALITY keypair 输出为空。"

    parse_reality_keypair "$KEYPAIR"

    log "生成 REALITY short_id..."

    if command -v od >/dev/null 2>&1; then
        SHORT_ID="$(
            od -An -N8 -tx1 /dev/urandom |
            tr -d ' \n'
        )"
    else
        die "系统没有 od，无法生成 REALITY short_id。"
    fi

    case "$SHORT_ID" in
        ""|*[!0-9a-fA-F]*)
            die "REALITY short_id 生成失败。"
            ;;
    esac

    [ "${#SHORT_ID}" -eq 16 ] \
        || die "REALITY short_id 长度异常：${SHORT_ID}"

    log "VLESS / REALITY 参数生成完成。"
}


###############################################################################
# Escape JSON string
#
# Values generated by this script are normally safe, but explicit JSON
# escaping makes config generation more robust.
###############################################################################

json_escape() {
    printf '%s' "$1" |
        sed \
            -e 's/\\/\\\\/g' \
            -e 's/"/\\"/g'
}


###############################################################################
# Write configuration atomically
###############################################################################

write_config() {
    mkdir -p "$CONF_DIR" "$LOG_DIR"

    uuid_json="$(json_escape "$UUID")"
    domain_json="$(json_escape "$REALITY_DOMAIN")"
    handshake_json="$(json_escape "$HANDSHAKE_SERVER")"
    private_json="$(json_escape "$PRIVATE_KEY")"
    short_json="$(json_escape "$SHORT_ID")"

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
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${uuid_json}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${domain_json}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${handshake_json}",
            "server_port": ${HANDSHAKE_PORT}
          },
          "private_key": "${private_json}",
          "short_id": [
            "${short_json}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    chmod 600 "$CONF_TMP"

    log "检查新配置..."

    "$BIN_DST" check -c "$CONF_TMP" \
        || {
            rm -f "$CONF_TMP"
            die "新配置检查失败，旧配置保持不变。

临时配置：
${CONF_TMP}"
        }

    log "新配置检查通过。"

    # Backup current configuration if it exists.
    if [ -f "$CONF_FILE" ]; then
        OLD_CONFIG_EXISTS="yes"

        cp -f "$CONF_FILE" "$CONF_BACKUP" \
            || {
                rm -f "$CONF_TMP"
                die "无法备份当前配置：

${CONF_FILE}

更新已中止，旧配置未修改。"
            }

        chmod 600 "$CONF_BACKUP"
    else
        OLD_CONFIG_EXISTS="no"
    fi

    # Atomic replace on the same filesystem.
    mv -f "$CONF_TMP" "$CONF_FILE" \
        || {
            rm -f "$CONF_TMP"
            die "配置文件原子替换失败。

目标：
${CONF_FILE}"
        }

    chmod 600 "$CONF_FILE"

    log "配置文件已更新：${CONF_FILE}"
}


###############################################################################
# Rollback configuration
###############################################################################

rollback_config() {
    if [ "$OLD_CONFIG_EXISTS" = "yes" ] &&
       [ -f "$CONF_BACKUP" ]; then

        warn "正在恢复旧配置..."

        mv -f "$CONF_BACKUP" "$CONF_FILE" \
            || {
                warn "旧配置恢复失败！"
                return 1
            }

        chmod 600 "$CONF_FILE"

        log "旧配置已恢复。"
        return 0
    fi

    # There was no old configuration.
    rm -f "$CONF_FILE" 2>/dev/null || true

    return 0
}


###############################################################################
# Remove configuration backup after successful update
###############################################################################

commit_config() {
    rm -f "$CONF_BACKUP" 2>/dev/null || true
}


###############################################################################
# Write OpenRC service atomically
###############################################################################

write_openrc_service() {
    cat > "$SERVICE_TMP" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box VLESS REALITY"

command="${BIN_DST}"
command_args="run -c ${CONF_FILE}"

command_background="yes"
pidfile="/run/sing-box.pid"

output_log="/dev/null"
error_log="${LOG_DIR}/error.log"

# Low-memory Go runtime hints.
export GOMEMLIMIT="${GOMEMLIMIT}"
export GOGC="${GOGC}"

depend() {
    need net
}

start_pre() {
    mkdir -p "${LOG_DIR}"

    touch "${LOG_DIR}/sing-box.log"
    touch "${LOG_DIR}/error.log"

    chmod 600 "${LOG_DIR}/sing-box.log"
    chmod 600 "${LOG_DIR}/error.log"
}
EOF

    chmod 755 "$SERVICE_TMP"

    # Basic shell syntax validation if ash is available.
    if ! /bin/ash -n "$SERVICE_TMP"; then
        rm -f "$SERVICE_TMP"
        die "生成的 OpenRC service 文件语法错误。"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        OLD_SERVICE_EXISTS="yes"

        cp -f "$SERVICE_FILE" "$SERVICE_BACKUP" \
            || {
                rm -f "$SERVICE_TMP"
                die "无法备份旧 OpenRC service。"
            }

        chmod 755 "$SERVICE_BACKUP"
    else
        OLD_SERVICE_EXISTS="no"
    fi

    mv -f "$SERVICE_TMP" "$SERVICE_FILE" \
        || {
            rm -f "$SERVICE_TMP"
            die "OpenRC service 原子替换失败。"
        }

    chmod 755 "$SERVICE_FILE"

    ensure_openrc_runtime

    rc-update add sing-box default >/dev/null 2>&1 || true

    log "OpenRC 服务已配置。"
}


###############################################################################
# Commit OpenRC service
###############################################################################

commit_openrc_service() {
    rm -f "$SERVICE_BACKUP" 2>/dev/null || true
}


###############################################################################
# Rollback OpenRC service
###############################################################################

rollback_openrc_service() {
    if [ "$OLD_SERVICE_EXISTS" = "yes" ] &&
       [ -f "$SERVICE_BACKUP" ]; then

        warn "正在恢复旧 OpenRC service..."

        mv -f "$SERVICE_BACKUP" "$SERVICE_FILE" \
            || {
                warn "旧 OpenRC service 恢复失败！"
                return 1
            }

        chmod 755 "$SERVICE_FILE"

        log "旧 OpenRC service 已恢复。"
    else
        rm -f "$SERVICE_FILE" 2>/dev/null || true
        rc-update del sing-box default >/dev/null 2>&1 || true
    fi

    return 0
}


###############################################################################
# Validate configuration
###############################################################################

check_config() {
    [ -f "$CONF_FILE" ] \
        || die "配置文件不存在：${CONF_FILE}"

    log "检查 sing-box 配置..."

    "$BIN_DST" check -c "$CONF_FILE" \
        || die "sing-box 配置检查失败。

配置文件：
${CONF_FILE}"

    log "配置检查通过。"
}


###############################################################################
# Check installed binary
###############################################################################

check_binary_exists() {
    [ -x "$BIN_DST" ] || {
        die "没有找到 ${BIN_DST}。"
    }

    "$BIN_DST" version >/dev/null 2>&1 || {
        die "${BIN_DST} 存在，但无法正常执行。"
    }
}


check_binary() {
    check_binary_exists

    log "当前 sing-box："
    "$BIN_DST" version
}


###############################################################################
# Download binary to /tmp
#
# This function DOES NOT touch the currently installed binary.
###############################################################################

download_binary_to_tmp() {
    detect_arch
    detect_download_tool

    rm -f "$BIN_DOWNLOAD_TMP"

    echo
    log "开始下载 sing-box..."
    log "下载地址：${BIN_URL}"
    log "下载临时文件：${BIN_DOWNLOAD_TMP}"

    case "$DOWNLOAD_TOOL" in
        wget)
            wget \
                -q \
                --show-progress \
                --tries=3 \
                --timeout=20 \
                -O "$BIN_DOWNLOAD_TMP" \
                "$BIN_URL" \
                || die "sing-box 下载失败。"
            ;;

        curl)
            curl \
                -fL \
                --retry 3 \
                --connect-timeout 20 \
                --max-time 300 \
                -o "$BIN_DOWNLOAD_TMP" \
                "$BIN_URL" \
                || die "sing-box 下载失败。"
            ;;
    esac

    [ -s "$BIN_DOWNLOAD_TMP" ] \
        || die "下载失败：临时文件为空。"

    chmod 755 "$BIN_DOWNLOAD_TMP"

    echo
    log "正在验证下载的 sing-box..."

    "$BIN_DOWNLOAD_TMP" version \
        || die "下载的 sing-box 无法执行。

请检查：
  - CPU 架构
  - musl / glibc
  - GitHub Release 文件
  - 下载内容是否完整"

    echo
    log "临时核心验证成功。"

    "$BIN_DOWNLOAD_TMP" version
}


###############################################################################
# Install downloaded binary
#
# IMPORTANT:
#
#   /tmp -> /usr/local/bin
#
# is NOT used for the final mv.
#
# Instead:
#
#   /tmp/download
#        ↓ cp
#   /usr/local/bin/.sing-box.new
#        ↓ validate
#   /usr/local/bin/sing-box
#
# The final mv therefore happens on the same filesystem.
###############################################################################

install_downloaded_binary() {
    [ -s "$BIN_DOWNLOAD_TMP" ] \
        || die "下载的 sing-box 临时文件不存在。"

    mkdir -p "$(dirname "$BIN_DST")"

    rm -f "$BIN_INSTALL_TMP"

    OLD_BINARY_EXISTS="no"

    if [ -x "$BIN_DST" ]; then
        OLD_BINARY_EXISTS="yes"

        log "检测到现有 sing-box，创建回滚备份..."

        rm -f "$BIN_BACKUP"

        cp -f "$BIN_DST" "$BIN_BACKUP" \
            || die "无法备份现有 sing-box。

更新已中止，旧核心保持不变。"

        chmod 755 "$BIN_BACKUP"
    fi

    echo
    log "正在复制核心到目标文件系统..."

    cp -f "$BIN_DOWNLOAD_TMP" "$BIN_INSTALL_TMP" \
        || {
            rm -f "$BIN_INSTALL_TMP"
            die "无法复制 sing-box 到：

${BIN_INSTALL_TMP}

请检查：
  - 磁盘空间
  - 文件系统是否只读
  - /usr/local/bin 是否可写"
        }

    chmod 755 "$BIN_INSTALL_TMP"

    echo
    log "正在验证目标文件系统中的 sing-box..."

    "$BIN_INSTALL_TMP" version \
        || {
            rm -f "$BIN_INSTALL_TMP"
            die "目标文件系统中的 sing-box 无法执行。

旧核心没有被替换。"
        }

    echo
    log "目标临时核心验证成功。"

    echo
    log "使用 mv 原子替换正式核心..."

    if ! mv -f "$BIN_INSTALL_TMP" "$BIN_DST"; then
        rm -f "$BIN_INSTALL_TMP" 2>/dev/null || true

        die "sing-box 原子替换失败。

源文件：
${BIN_INSTALL_TMP}

目标文件：
${BIN_DST}

旧核心没有被主动删除。"
    fi

    chmod 755 "$BIN_DST"

    echo
    log "sing-box 已安装到：${BIN_DST}"

    echo
    log "当前版本："
    "$BIN_DST" version
}


###############################################################################
# Commit binary update
###############################################################################

commit_binary() {
    rm -f "$BIN_BACKUP" 2>/dev/null || true
}


###############################################################################
# Rollback binary
###############################################################################

rollback_binary() {
    if [ "$OLD_BINARY_EXISTS" = "yes" ] &&
       [ -x "$BIN_BACKUP" ]; then

        warn "正在恢复旧 sing-box 核心..."

        if mv -f "$BIN_BACKUP" "$BIN_DST"; then
            chmod 755 "$BIN_DST"

            log "旧 sing-box 核心已恢复。"

            "$BIN_DST" version || true

            return 0
        fi

        warn "旧 sing-box 核心恢复失败！"
        return 1
    fi

    warn "没有可用的旧 sing-box 核心用于回滚。"

    return 1
}


###############################################################################
# Start / restart service
###############################################################################

restart_service() {
    ensure_openrc_runtime

    log "启动 / 重启 sing-box..."

    if ! rc-service sing-box restart; then
        warn "sing-box 重启失败。"

        echo
        warn "最后错误日志："

        if [ -f "${LOG_DIR}/error.log" ]; then
            tail -n 50 "${LOG_DIR}/error.log" 2>/dev/null || true
        fi

        return 1
    fi

    sleep 1

    if ! singbox_process_running; then
        warn "OpenRC 返回成功，但没有检测到 sing-box 进程。"

        if [ -f "${LOG_DIR}/error.log" ]; then
            echo
            warn "最后错误日志："
            tail -n 50 "${LOG_DIR}/error.log" 2>/dev/null || true
        fi

        return 1
    fi

    echo
    log "服务状态："

    rc-service sing-box status || true

    return 0
}


###############################################################################
# Start service with rollback
###############################################################################

restart_with_binary_rollback() {
    if restart_service; then
        return 0
    fi

    warn "新核心启动失败。"

    if [ "$OLD_BINARY_EXISTS" = "yes" ]; then
        warn "开始自动回滚旧核心..."

        stop_singbox

        if rollback_binary; then
            warn "正在使用旧核心重新启动..."

            if restart_service; then
                warn "旧核心恢复并重新启动成功。"
                return 1
            fi

            warn "旧核心恢复后仍无法启动。"
            return 1
        fi
    fi

    return 1
}


###############################################################################
# Configuration update with rollback
###############################################################################

update_configuration_transaction() {
    # Existing service keeps running while new config is prepared.
    #
    # New config:
    #   write temp
    #   check temp
    #   backup old
    #   atomic mv
    #
    # Only AFTER all validation succeeds do we restart the service.

    write_config

    write_openrc_service

    check_config

    echo
    log "新配置和 OpenRC service 均已验证。"

    # At this point old service is still running.
    #
    # Now restart using new configuration.
    if restart_service; then
        commit_config
        commit_openrc_service

        log "配置更新成功。"
        return 0
    fi

    warn "新配置启动失败，开始自动回滚..."

    stop_singbox

    rollback_config
    rollback_openrc_service

    if [ "$OLD_BINARY_EXISTS" = "yes" ]; then
        :
    fi

    if service_exists && [ -f "$CONF_FILE" ]; then
        if rc-service sing-box restart; then
            warn "旧配置已恢复，旧服务重新启动成功。"
        else
            warn "旧配置已恢复，但旧服务启动失败。"
        fi
    fi

    return 1
}


###############################################################################
# Detect public IP
###############################################################################

detect_server_ip() {
    SERVER_ADDR="${SERVER_ADDR:-}"

    if [ -n "$SERVER_ADDR" ]; then
        return
    fi

    if command -v wget >/dev/null 2>&1; then
        SERVER_ADDR="$(
            wget \
                -qO- \
                --timeout=10 \
                https://api.ipify.org \
                2>/dev/null || true
        )
    elif command -v curl >/dev/null 2>&1; then
        SERVER_ADDR="$(
            curl \
                -fsSL \
                --max-time 10 \
                https://api.ipify.org \
                2>/dev/null || true
        )
    fi

    if [ -z "$SERVER_ADDR" ]; then
        SERVER_ADDR="你的服务器IP"

        warn "无法自动获取公网 IP。"
        warn "请在客户端链接中手动替换服务器地址。"
    fi
}


###############################################################################
# Write node information
###############################################################################

write_info() {
    detect_server_ip

    LINK="vless://${UUID}@${SERVER_ADDR}:${PORT}?encryption=none&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#singbox-reality"

    cat > "$INFO_FILE" <<EOF
sing-box VLESS + REALITY

Architecture:
${SING_BOX_ARCH}

Binary:
${BIN_DST}

Address:
${SERVER_ADDR}

Port:
${PORT}

UUID:
${UUID}

Flow:
xtls-rprx-vision

Network:
tcp

Security:
reality

SNI / serverName:
${REALITY_DOMAIN}

Handshake:
${HANDSHAKE_SERVER}:${HANDSHAKE_PORT}

PublicKey / pbk:
${PUBLIC_KEY}

ShortId / sid:
${SHORT_ID}

Fingerprint:
chrome

Client link:
${LINK}

Config:
${CONF_FILE}

Service:
rc-service sing-box status
rc-service sing-box restart
rc-service sing-box stop

Logs:
${LOG_DIR}/sing-box.log
${LOG_DIR}/error.log
EOF

    chmod 600 "$INFO_FILE"

    echo
    echo "==================== 完成 ===================="
    cat "$INFO_FILE"
    echo "=============================================="
    echo

    echo "提示："
    echo "1. 请确认云服务器安全组 / 防火墙已放行 TCP ${PORT}。"
    echo "2. 请确认 REALITY handshake 目标 ${REALITY_DOMAIN}:443 可访问。"
    echo "3. 节点信息已保存到：${INFO_FILE}"
}


###############################################################################
# Full install
###############################################################################

install_mode() {
    echo
    echo "=============================================="
    echo " 安装 sing-box + VLESS REALITY"
    echo "=============================================="

    protect_ssh

    prepare_directories

    ###########################################################################
    # 1. Detect architecture
    ###########################################################################

    detect_arch

    ###########################################################################
    # 2. Download and validate binary.
    #
    # Existing service is NOT stopped here.
    ###########################################################################

    download_binary_to_tmp

    ###########################################################################
    # 3. Install binary atomically.
    ###########################################################################

    install_downloaded_binary

    check_binary

    ###########################################################################
    # 4. Ask configuration parameters.
    ###########################################################################

    ask_port_domain

    ###########################################################################
    # 5. Stop conflicting services only after new binary is ready.
    ###########################################################################

    stop_conflicting_services

    ###########################################################################
    # 6. Generate credentials.
    ###########################################################################

    generate_reality_values

    ###########################################################################
    # 7. Write and validate configuration.
    ###########################################################################

    write_config

    ###########################################################################
    # 8. Write OpenRC service.
    ###########################################################################

    write_openrc_service

    ###########################################################################
    # 9. Validate final configuration.
    ###########################################################################

    check_config

    ###########################################################################
    # 10. Start service.
    #
    # There is no old binary on a fresh install, so rollback is not possible
    # unless an old installation existed.
    ###########################################################################

    if ! restart_service; then
        warn "首次启动失败。"

        if [ "$OLD_BINARY_EXISTS" = "yes" ]; then
            warn "检测到旧核心，尝试恢复..."

            stop_singbox
            rollback_binary

            if service_exists && [ -f "$CONF_FILE" ]; then
                rc-service sing-box restart 2>/dev/null || true
            fi
        fi

        die "sing-box 安装完成，但服务启动失败。

请检查：
${LOG_DIR}/error.log"
    fi

    commit_binary
    commit_config
    commit_openrc_service

    ###########################################################################
    # 11. Save node information.
    ###########################################################################

    write_info
}


###############################################################################
# Update configuration
#
# Does NOT download binary.
###############################################################################

update_config_mode() {
    echo
    echo "=============================================="
    echo " 更新 VLESS REALITY 配置"
    echo "=============================================="

    protect_ssh

    prepare_directories

    check_binary

    if [ ! -f "$CONF_FILE" ]; then
        warn "当前没有配置文件，将创建新的配置。"
    fi

    ask_port_domain

    ###########################################################################
    # Generate new credentials before touching the running service.
    ###########################################################################

    generate_reality_values

    ###########################################################################
    # Configuration transaction:
    #
    #   generate
    #      ↓
    #   validate
    #      ↓
    #   atomic replace
    #      ↓
    #   restart
    #      ↓
    #   failure -> rollback
    ###########################################################################

    if ! update_configuration_transaction; then
        die "配置更新失败。

如果自动回滚成功，旧配置应该已经恢复。

日志：
${LOG_DIR}/error.log"
    fi

    write_info

    echo
    log "VLESS REALITY 配置更新完成。"
}


###############################################################################
# Update binary
#
# Important:
#
#   The old running service is NOT stopped until:
#
#       new binary downloaded
#       ↓
#       new binary validated
#       ↓
#       new binary installed
#       ↓
#       existing config validated
#
# Only then restart.
###############################################################################

update_binary_mode() {
    echo
    echo "=============================================="
    echo " 更新 sing-box 二进制"
    echo "=============================================="

    protect_ssh

    prepare_directories

    detect_arch

    echo
    echo "当前系统架构：${ARCH}"
    echo "目标 sing-box：${SING_BOX_FILE}"
    echo "下载地址：${BIN_URL}"
    echo

    ###########################################################################
    # IMPORTANT:
    # Do NOT stop sing-box here.
    ###########################################################################

    download_binary_to_tmp

    ###########################################################################
    # Install new binary and create rollback backup.
    ###########################################################################

    install_downloaded_binary

    check_binary

    ###########################################################################
    # If an existing config exists, validate it BEFORE restart.
    ###########################################################################

    if [ -f "$CONF_FILE" ]; then
        echo
        log "检测到现有配置。"

        check_config
    else
        warn "没有找到现有配置：${CONF_FILE}"
        warn "二进制已更新，但不会启动节点。"

        commit_binary

        echo
        log "sing-box 二进制更新完成。"

        "$BIN_DST" version

        return 0
    fi

    ###########################################################################
    # New binary + existing configuration are both valid.
    #
    # Now and ONLY now restart the service.
    ###########################################################################

    if restart_service; then
        commit_binary

        echo
        log "sing-box 二进制更新成功。"

        "$BIN_DST" version

        return 0
    fi

    ###########################################################################
    # New binary cannot start.
    #
    # Stop failed process and restore old binary.
    ###########################################################################

    warn "新核心启动失败，开始自动回滚旧核心..."

    stop_singbox

    if ! rollback_binary; then
        die "严重错误：

新核心启动失败，并且旧核心恢复失败。

请检查：
  ${BIN_DST}
  ${BIN_BACKUP}
  ${LOG_DIR}/error.log"
    fi

    if restart_service; then
        warn "旧核心恢复并重新启动成功。"
    else
        die "旧核心已经恢复，但服务仍然无法启动。

请检查：
${LOG_DIR}/error.log"
    fi

    die "二进制更新失败，已自动恢复旧版本。"
}


###############################################################################
# Show status
###############################################################################

show_status() {
    echo
    echo "=============================================="
    echo " 当前状态"
    echo "=============================================="

    echo
    echo "--- CPU architecture ---"

    uname -m 2>/dev/null || true

    echo
    echo "--- sing-box ---"

    if [ -x "$BIN_DST" ]; then
        "$BIN_DST" version || true
    else
        warn "未安装 sing-box：${BIN_DST}"
    fi

    echo
    echo "--- OpenRC ---"

    if [ -x "$SERVICE_FILE" ]; then
        rc-service sing-box status 2>/dev/null || true
    else
        warn "OpenRC service 不存在：${SERVICE_FILE}"
    fi

    echo
    echo "--- Listening ports ---"

    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null |
            grep sing-box ||
            true
    else
        warn "系统没有 ss，无法显示监听端口。"
    fi

    echo
    echo "--- Configuration ---"

    if [ -f "$CONF_FILE" ]; then
        echo "$CONF_FILE"

        if [ -x "$BIN_DST" ]; then
            "$BIN_DST" check -c "$CONF_FILE" 2>/dev/null || true
        fi
    else
        warn "配置文件不存在：${CONF_FILE}"
    fi

    echo
    echo "--- Node information ---"

    if [ -f "$INFO_FILE" ]; then
        cat "$INFO_FILE"
    else
        warn "未找到节点信息文件：${INFO_FILE}"
    fi

    echo
    echo "--- Logs ---"

    if [ -f "${LOG_DIR}/error.log" ]; then
        echo
        echo "[error.log - last 30 lines]"
        tail -n 30 "${LOG_DIR}/error.log" 2>/dev/null || true
    fi

    pause
}


###############################################################################
# Main menu
###############################################################################

main_menu() {
    while true; do
        clear 2>/dev/null || true

        echo "=============================================="
        echo " sing-box VLESS + REALITY for Alpine"
        echo "=============================================="
        echo " Version: 1.13.21"
        echo " Binary: musl"
        echo " Architecture: amd64 / arm64"
        echo " GOMEMLIMIT: ${GOMEMLIMIT}"
        echo " GOGC: ${GOGC}"
        echo "=============================================="
        echo " 1) 安装"
        echo " 2) 更新配置"
        echo " 3) 更新 sing-box 二进制"
        echo " 4) 查看状态"
        echo " 0) 退出"
        echo "=============================================="

        printf "请选择: "

        read -r choice || true

        case "$choice" in
            1)
                install_mode
                break
                ;;

            2)
                update_config_mode
                break
                ;;

            3)
                update_binary_mode
                break
                ;;

            4)
                show_status
                ;;

            0)
                exit 0
                ;;

            *)
                echo "无效选择。"
                pause
                ;;
        esac
    done
}


###############################################################################
# Main
###############################################################################

main() {
    require_root
    main_menu
}


main "$@"
```
