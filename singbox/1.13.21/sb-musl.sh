#!/bin/ash
# setup-singbox-reality.sh
#
# Alpine low-memory sing-box VLESS + REALITY installer/config updater.
#
# 特点：
#   - 自动从指定 GitHub Release 下载 amd64/musl sing-box 二进制
#   - 不需要服务器预先上传 sing-box
#   - 适合低内存 Alpine VPS / Container
#   - 使用 OpenRC 管理 sing-box
#   - 自动生成 VLESS UUID / REALITY keypair / short_id
#   - 自动生成 VLESS 分享链接
#
# 当前下载版本：
#   sing-box v1.13.21
#
# 下载文件：
#   https://github.com/opyzzzz/argox/releases/download/v1.13.21/sing-box

set -eu

###############################################################################
# 基本路径
###############################################################################

BIN_URL="${BIN_URL:-https://github.com/opyzzzz/argox/releases/download/v1.13.21/sing-box}"
BIN_DST="/usr/local/bin/sing-box"
BIN_TMP="/tmp/sing-box-download"

CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"

LOG_DIR="/var/log/sing-box"
INFO_FILE="/root/singbox-vless-reality-info.txt"

DEFAULT_PORT="${DEFAULT_PORT:-443}"
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-www.cloudflare.com}"


###############################################################################
# 基础函数
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

require_root() {
    [ "$(id -u)" = "0" ] || die "请使用 root 用户运行。"
}


###############################################################################
# 低内存保护
###############################################################################

protect_ssh() {
    # 尽量避免当前 SSH shell / sshd 在低内存情况下优先被 OOM killer 杀掉。

    echo -1000 > /proc/$$/oom_score_adj 2>/dev/null || true

    for p in $(pgrep -x sshd 2>/dev/null || true); do
        echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null || true
    done
}


###############################################################################
# OpenRC
###############################################################################

ensure_openrc_runtime() {
    mkdir -p /run/openrc
    touch /run/openrc/softlevel 2>/dev/null || true
}


###############################################################################
# 输入验证
###############################################################################

validate_port() {
    port="$1"

    case "$port" in
        ""|*[!0-9]*)
            die "端口必须是数字。"
            ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        die "端口范围必须是 1-65535。"
    fi
}

validate_domain() {
    domain="$1"

    case "$domain" in
        "")
            die "域名不能为空。"
            ;;
        */*)
            die "域名格式不正确，请不要带 /。"
            ;;
        *:*)
            die "域名格式不正确，请不要带端口。"
            ;;
        *" "*)
            die "域名格式不正确，请不要包含空格。"
            ;;
        http://*|https://*)
            die "请输入纯域名，例如 www.cloudflare.com，不要带 https://。"
            ;;
    esac
}


###############################################################################
# 询问端口 / REALITY SNI
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
}


###############################################################################
# 下载工具
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

    die "系统中没有 wget 或 curl，无法下载 sing-box。"
}


###############################################################################
# 下载 sing-box
###############################################################################

download_binary() {
    detect_download_tool

    log "准备下载 sing-box..."
    log "URL: ${BIN_URL}"

    rm -f "$BIN_TMP"

    case "$DOWNLOAD_TOOL" in
        wget)
            wget \
                -q \
                --show-progress \
                -O "$BIN_TMP" \
                "$BIN_URL" \
                || die "sing-box 下载失败。"
            ;;
        curl)
            curl \
                -fL \
                --retry 3 \
                --connect-timeout 15 \
                --max-time 300 \
                -o "$BIN_TMP" \
                "$BIN_URL" \
                || die "sing-box 下载失败。"
            ;;
    esac

    [ -s "$BIN_TMP" ] || die "下载完成，但文件为空。"

    chmod 755 "$BIN_TMP"

    log "检查下载的 sing-box..."

    "$BIN_TMP" version >/dev/null 2>&1 \
        || die "下载的文件无法执行，可能不是正确的 Alpine/musl sing-box 二进制。"

    log "下载成功。"

    rm -f "$BIN_DST"

    mv "$BIN_TMP" "$BIN_DST"

    chmod 755 "$BIN_DST"

    log "sing-box 已安装到：${BIN_DST}"

    "$BIN_DST" version
}


###############################################################################
# 检查现有二进制
###############################################################################

check_binary_exists() {
    [ -x "$BIN_DST" ] || {
        die "没有找到 ${BIN_DST}。请先执行安装。"
    }
}

check_binary() {
    check_binary_exists

    "$BIN_DST" version >/dev/null 2>&1 \
        || die "${BIN_DST} 存在，但无法正常执行。"

    log "当前 sing-box："
    "$BIN_DST" version
}


###############################################################################
# 安装目录
###############################################################################

prepare_directories() {
    mkdir -p \
        /usr/local/bin \
        "$CONF_DIR" \
        "$LOG_DIR"
}


###############################################################################
# 停止可能冲突的服务
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
# 生成 UUID / REALITY keypair / short_id
###############################################################################

generate_reality_values() {
    log "生成 VLESS UUID / REALITY 密钥..."

    UUID="$(cat /proc/sys/kernel/random/uuid)"

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

    SHORT_ID="$(
        od -An -N8 -tx1 /dev/urandom |
        tr -d ' \n'
    )"

    [ -n "$UUID" ] \
        || die "UUID 生成失败。"

    [ -n "$PRIVATE_KEY" ] \
        || die "REALITY private_key 生成失败。"

    [ -n "$PUBLIC_KEY" ] \
        || die "REALITY public_key 生成失败。"

    [ -n "$SHORT_ID" ] \
        || die "REALITY short_id 生成失败。"

    log "UUID / REALITY 参数生成完成。"
}


###############################################################################
# 写入 sing-box 配置
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
# OpenRC 服务
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

# 低内存环境的 Go runtime 参数。
# 注意：这不是内存硬限制，只是降低 Go GC / heap 的内存压力。
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
# 检查配置并启动
###############################################################################

test_and_restart() {
    log "检查 sing-box 配置..."

    "$BIN_DST" check -c "$CONF_FILE" \
        || die "sing-box 配置检查失败，服务不会启动。"

    log "配置检查通过。"

    log "启动 / 重启 sing-box..."

    rc-service sing-box restart \
        || die "sing-box 启动失败，请检查日志：${LOG_DIR}/error.log"

    echo
    log "服务状态："

    rc-service sing-box status || true
}


###############################################################################
# 获取服务器公网 IP
###############################################################################

detect_server_ip() {
    SERVER_ADDR="${SERVER_ADDR:-}"

    if [ -n "$SERVER_ADDR" ]; then
        return
    fi

    if command -v wget >/dev/null 2>&1; then
        SERVER_ADDR="$(
            wget -qO- \
            https://api.ipify.org \
            2>/dev/null || true
        )"
    elif command -v curl >/dev/null 2>&1; then
        SERVER_ADDR="$(
            curl -fsSL \
            --max-time 10 \
            https://api.ipify.org \
            2>/dev/null || true
        )"
    fi

    if [ -z "$SERVER_ADDR" ]; then
        SERVER_ADDR="你的服务器IP"

        warn "无法自动获取公网 IP。"
        warn "请在客户端链接中手动替换服务器地址。"
    fi
}


###############################################################################
# 写入节点信息
###############################################################################

write_info() {
    detect_server_ip

    LINK="vless://${UUID}@${SERVER_ADDR}:${PORT}?encryption=none&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&type=tcp&flow=xtls-rprx-vision&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#singbox-reality"

    cat > "$INFO_FILE" <<EOF
sing-box VLESS + REALITY

Address: ${SERVER_ADDR}
Port: ${PORT}

UUID: ${UUID}
Flow: xtls-rprx-vision
Network: tcp
Security: reality

SNI / serverName: ${REALITY_DOMAIN}

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
    echo "2. 请确认 ${REALITY_DOMAIN}:443 可以正常访问。"
    echo "3. 节点信息已保存到：${INFO_FILE}"
}


###############################################################################
# 安装
###############################################################################

install_mode() {
    echo
    echo "=== 安装 sing-box + 生成 REALITY 配置 ==="

    ask_port_domain

    protect_ssh

    prepare_directories

    # 自动下载指定版本
    download_binary

    stop_conflicting_services

    generate_reality_values

    write_config

    write_openrc_service

    test_and_restart

    write_info
}


###############################################################################
# 更新配置
###############################################################################

update_config_mode() {
    echo
    echo "=== 更新 REALITY 配置 ==="

    ask_port_domain

    protect_ssh

    check_binary

    generate_reality_values

    write_config

    write_openrc_service

    test_and_restart

    write_info
}


###############################################################################
# 更新 sing-box 二进制
###############################################################################

update_binary_mode() {
    echo
    echo "=== 更新 sing-box 二进制 ==="

    protect_ssh

    prepare_directories

    stop_conflicting_services

    download_binary

    if [ -f "$CONF_FILE" ]; then
        log "检测到现有配置，重新检查配置..."

        "$BIN_DST" check -c "$CONF_FILE" \
            || die "现有配置与当前 sing-box 不兼容。"

        rc-service sing-box restart \
            || die "sing-box 重启失败。"
    fi

    echo
    log "sing-box 二进制更新完成。"

    "$BIN_DST" version

    rc-service sing-box status || true
}


###############################################################################
# 查看状态
###############################################################################

show_status() {
    echo
    echo "=== 当前状态 ==="

    echo
    if [ -x "$BIN_DST" ]; then
        "$BIN_DST" version || true
    else
        warn "未安装 sing-box：${BIN_DST} 不存在。"
    fi

    echo
    echo "--- OpenRC ---"

    rc-service sing-box status 2>/dev/null || true

    echo
    echo "--- Listening ports ---"

    ss -lntp 2>/dev/null |
        grep sing-box ||
        true

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
# 主菜单
###############################################################################

main_menu() {
    while true; do
        clear 2>/dev/null || true

        echo "=============================================="
        echo " sing-box VLESS + REALITY for Alpine"
        echo "=============================================="
        echo " Version: 1.13.21"
        echo " Arch: amd64 / musl"
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
