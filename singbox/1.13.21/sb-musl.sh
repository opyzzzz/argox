#!/bin/ash
# setup-singbox-reality.sh
#
# Alpine Linux low-memory sing-box VLESS + REALITY installer/config updater.
#
# Supported architectures:
#   x86_64 / amd64
#   aarch64 / arm64
#
# sing-box binaries:
#   amd64:
#   https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-amd64
#
#   arm64:
#   https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-arm64
#
# Binary files are already unpacked musl executables.
#
# Installation flow:
#
#   1. Check root
#        ↓
#   2. Detect CPU architecture
#        ↓
#   3. Select amd64 / arm64 binary
#        ↓
#   4. Download to /usr/local/tmp
#        ↓
#   5. Execute temporary binary "version" for validation
#        ↓
#   6. mv to /usr/local/bin/sing-box
#        ↓
#   7. Check configuration
#        ↓
#   8. Start / restart OpenRC service
#
# Designed for small Alpine VPS / containers.
#
# NOTE:
#   This script does NOT download archives.
#   The GitHub Release files are already unpacked executables.

set -eu


###############################################################################
# Configuration
###############################################################################

BIN_BASE_URL="${BIN_BASE_URL:-https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi}"

BIN_DST="/usr/local/bin/sing-box"
BIN_TMP="/usr/local/tmp/sing-box-download.$$"

CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"

LOG_DIR="/var/log/sing-box"
INFO_FILE="/root/singbox-vless-reality-info.txt"

DEFAULT_PORT="${DEFAULT_PORT:-443}"
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-www.cloudflare.com}"


###############################################################################
# Runtime variables
###############################################################################

ARCH=""
SING_BOX_ARCH=""
SING_BOX_FILE=""
BIN_URL=""
DOWNLOAD_TOOL=""

PORT=""
REALITY_DOMAIN=""
HANDSHAKE_SERVER=""
HANDSHAKE_PORT="443"

UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

SERVER_ADDR=""
LINK=""


###############################################################################
# Cleanup
###############################################################################

cleanup() {
    rm -f "$BIN_TMP" 2>/dev/null || true
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
    # Lower OOM score for current shell.
    echo -1000 > /proc/$$/oom_score_adj 2>/dev/null || true

    # Lower OOM score for sshd processes where possible.
    for p in $(pgrep -x sshd 2>/dev/null || true); do
        echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null || true
    done
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
        /usr/local/tmp \
        "$CONF_DIR" \
        "$LOG_DIR"
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
# Download sing-box safely
#
# Important:
#   Existing /usr/local/bin/sing-box is NOT touched until the new binary
#   has successfully downloaded and passed the version test.
###############################################################################

download_binary() {
    detect_arch
    detect_download_tool

    rm -f "$BIN_TMP"

    echo
    log "开始下载 sing-box..."
    log "下载地址：${BIN_URL}"
    log "临时文件：${BIN_TMP}"

    case "$DOWNLOAD_TOOL" in
        wget)
            wget \
                -q \
                --show-progress \
                --tries=3 \
                --timeout=20 \
                -O "$BIN_TMP" \
                "$BIN_URL" \
                || die "sing-box 下载失败。"
            ;;

        curl)
            curl \
                -fL \
                --retry 3 \
                --connect-timeout 20 \
                --max-time 300 \
                -o "$BIN_TMP" \
                "$BIN_URL" \
                || die "sing-box 下载失败。"
            ;;
    esac

    # Basic file check.
    [ -s "$BIN_TMP" ] \
        || die "下载失败：临时文件为空。"

    chmod 755 "$BIN_TMP"

    echo
    log "正在验证下载的 sing-box..."

    # Do NOT replace existing binary before this succeeds.
    "$BIN_TMP" version \
        || die "下载的 sing-box 无法执行。

请检查：
  - CPU 架构
  - musl / glibc
  - GitHub Release 文件
  - 下载内容是否完整"

    echo
    log "临时核心验证成功。"

    echo
    log "安装前版本信息："
    "$BIN_TMP" version

    echo
    log "使用 mv 原子替换正式核心..."

    mv -f "$BIN_TMP" "$BIN_DST"

    chmod 755 "$BIN_DST"

    echo
    log "sing-box 已安装到：${BIN_DST}"

    echo
    log "当前版本："
    "$BIN_DST" version
}


###############################################################################
# Check installed binary
###############################################################################

check_binary_exists() {
    [ -x "$BIN_DST" ] || {
        die "没有找到 ${BIN_DST}。

请先执行：
  1) 安装"
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
###############################################################################

validate_domain() {
    domain="$1"

    case "$domain" in
        "")
            die "域名不能为空。"
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
        http://*)
            die "请输入纯域名，不要带 http://。"
            ;;
        https://*)
            die "请输入纯域名，不要带 https://。"
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
}


###############################################################################
# Stop conflicting services
###############################################################################

stop_conflicting_services() {
    log "停止可能占用端口的旧服务..."

    rc-service xray stop 2>/dev/null || true
    rc-update del xray default 2>/dev/null || true

    pkill -f 'xray run' 2>/dev/null || true

    rc-service sing-box stop 2>/dev/null || true

    pkill -f 'sing-box run' 2>/dev/null || true
}


###############################################################################
# Generate UUID / REALITY keypair / short_id
###############################################################################

generate_reality_values() {
    log "生成 VLESS UUID..."

    UUID="$(cat /proc/sys/kernel/random/uuid)"

    [ -n "$UUID" ] || die "UUID 生成失败。"

    log "生成 REALITY keypair..."

    KEYPAIR="$("$BIN_DST" generate reality-keypair)" \
        || die "REALITY keypair 生成失败。"

    PRIVATE_KEY="$(
        echo "$KEYPAIR" |
        awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}'
    )"

    PUBLIC_KEY="$(
        echo "$KEYPAIR" |
        awk -F': ' 'tolower($1) ~ /public/ {print $2; exit}'
    )"

    [ -n "$PRIVATE_KEY" ] \
        || die "REALITY private_key 生成失败。"

    [ -n "$PUBLIC_KEY" ] \
        || die "REALITY public_key 生成失败。"

    log "生成 REALITY short_id..."

    SHORT_ID="$(
        od -An -N8 -tx1 /dev/urandom |
        tr -d ' \n'
    )"

    [ -n "$SHORT_ID" ] \
        || die "REALITY short_id 生成失败。"

    log "VLESS / REALITY 参数生成完成。"
}


###############################################################################
# Write sing-box config
###############################################################################

write_config() {
    mkdir -p "$CONF_DIR" "$LOG_DIR"

    cat > "$CONF_FILE" <<EOF
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
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${HANDSHAKE_SERVER}",
            "server_port": ${HANDSHAKE_PORT}
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
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

    chmod 600 "$CONF_FILE"

    log "配置文件已写入：${CONF_FILE}"
}


###############################################################################
# Write OpenRC service
###############################################################################

write_openrc_service() {
    cat > /etc/init.d/sing-box <<EOF
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
export GOMEMLIMIT="32MiB"
export GOGC="25"

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

    chmod +x /etc/init.d/sing-box

    ensure_openrc_runtime

    rc-update add sing-box default >/dev/null 2>&1 || true

    log "OpenRC 服务已配置。"
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
# Restart service
###############################################################################

restart_service() {
    log "启动 / 重启 sing-box..."

    rc-service sing-box restart \
        || die "sing-box 启动失败。

请检查：
${LOG_DIR}/error.log"

    echo
    log "服务状态："

    rc-service sing-box status || true
}


###############################################################################
# Test configuration and restart
###############################################################################

test_and_restart() {
    check_config
    restart_service
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
# Install mode
###############################################################################

install_mode() {
    echo
    echo "=============================================="
    echo " 安装 sing-box + VLESS REALITY"
    echo "=============================================="

    protect_ssh

    # 1. Detect architecture
    detect_arch

    # 2. Prepare directories
    prepare_directories

    # 3. Download selected architecture binary
    # 4. Validate temporary binary
    # 5. mv to final location
    download_binary

    # Check final binary after installation.
    check_binary

    # Ask configuration parameters.
    ask_port_domain

    # Stop old services before starting the new one.
    stop_conflicting_services

    # Generate new VLESS / REALITY credentials.
    generate_reality_values

    # Write configuration.
    write_config

    # Write OpenRC service.
    write_openrc_service

    # Check configuration and start service.
    test_and_restart

    # Save client information.
    write_info
}


###############################################################################
# Update configuration mode
#
# Does NOT download the binary.
###############################################################################

update_config_mode() {
    echo
    echo "=============================================="
    echo " 更新 VLESS REALITY 配置"
    echo "=============================================="

    protect_ssh

    check_binary

    ask_port_domain

    stop_conflicting_services

    generate_reality_values

    write_config

    write_openrc_service

    test_and_restart

    write_info
}


###############################################################################
# Update binary mode
#
# Automatically detects CPU architecture again.
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

    stop_conflicting_services

    # Download -> temporary version check -> mv.
    download_binary

    check_binary

    # If configuration exists, validate it before restarting.
    if [ -f "$CONF_FILE" ]; then
        echo
        log "检测到现有配置。"

        check_config

        restart_service
    else
        warn "没有找到现有配置：${CONF_FILE}"
        warn "二进制已更新，但不会自动创建节点配置。"
    fi

    echo
    log "sing-box 二进制更新完成。"

    "$BIN_DST" version
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

    rc-service sing-box status 2>/dev/null || true

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
