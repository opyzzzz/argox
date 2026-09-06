#!/bin/ash
# setup-singbox-reality.sh
# Alpine low-memory sing-box VLESS + REALITY installer/config updater.
# Designed for tiny Alpine VPS/container.
#
# sing-box musl binaries:
#   amd64:
#   https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-amd64
#
#   arm64:
#   https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi/sing-box-arm64
#
# Binary files are already unpacked musl executables.

set -eu

BIN_BASE_URL="${BIN_BASE_URL:-https://github.com/opyzzzz/argox/releases/download/v1.13.21-multi}"

BIN_DST="/usr/local/bin/sing-box"
BIN_TMP="/usr/local/tmp/sing-box-download.$$"

CONF_DIR="/usr/local/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
LOG_DIR="/var/log/sing-box"
INFO_FILE="/root/singbox-vless-reality-info.txt"
DEFAULT_PORT="${DEFAULT_PORT:-443}"
DEFAULT_DOMAIN="${DEFAULT_DOMAIN:-www.cloudflare.com}"

ARCH=""
SING_BOX_ARCH=""
SING_BOX_FILE=""
BIN_URL=""
DOWNLOAD_TOOL=""

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

cleanup() {
  rm -f "$BIN_TMP" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

require_root() {
  [ "$(id -u)" = "0" ] || die "请使用 root 用户运行。"
}

protect_ssh() {
  # In very low-memory environments, reduce the chance that sshd or this shell
  # gets killed first by the OOM killer.
  echo -1000 > /proc/$$/oom_score_adj 2>/dev/null || true
  for p in $(pgrep -x sshd 2>/dev/null || true); do
    echo -1000 > /proc/$p/oom_score_adj 2>/dev/null || true
  done
}

ensure_openrc_runtime() {
  mkdir -p /run/openrc
  touch /run/openrc/softlevel 2>/dev/null || true
}

validate_port() {
  port="$1"
  case "$port" in
    *[!0-9]*|"")
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
    ""|*"/"*|*":"*|*" "*)
      die "域名格式不正确，请输入类似 www.cloudflare.com 的域名，不要带 https:// 或端口。"
      ;;
  esac
}

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
  log "目标 sing-box 架构：${SING_BOX_ARCH}"
  log "核心文件：${SING_BOX_FILE}"
}


###############################################################################
# Detect download tool
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
# Download and verify sing-box binary
#
# The existing binary is not touched until the downloaded binary:
#   1. exists
#   2. is non-empty
#   3. is executable
#   4. can successfully execute "version"
#
# Only after all checks pass is it moved to BIN_DST.
###############################################################################

install_binary() {
  detect_arch
  detect_download_tool

  mkdir -p \
    /usr/local/bin \
    /usr/local/tmp \
    "$CONF_DIR" \
    "$LOG_DIR"

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

  echo

  # Basic completeness check.
  [ -s "$BIN_TMP" ] \
    || die "下载失败：临时核心文件为空。"

  chmod 755 "$BIN_TMP"

  log "临时核心文件下载完成。"
  log "开始验证 sing-box 核心..."

  # Executing "version" verifies that the downloaded file is a usable
  # executable for the current CPU / Alpine musl environment.
  "$BIN_TMP" version \
    || die "下载的 sing-box 核心无法正常执行。

请检查：
  - CPU 架构
  - Alpine / musl 环境
  - GitHub Release 文件
  - 下载内容是否完整"

  echo
  log "sing-box 核心验证成功。"

  echo
  log "验证版本信息："
  "$BIN_TMP" version

  echo
  log "移动核心："
  log "${BIN_TMP} -> ${BIN_DST}"

  # Only replace the existing binary after the new binary has passed
  # all download and execution checks.
  mv -f "$BIN_TMP" "$BIN_DST"

  chmod 755 "$BIN_DST"

  echo
  log "sing-box 核心安装完成：${BIN_DST}"

  echo
  log "当前 sing-box 版本："
  "$BIN_DST" version
}

check_binary_exists() {
  [ -x "$BIN_DST" ] || die "没有找到 ${BIN_DST}。请先选择安装，或手动安装 sing-box 二进制。"
}

stop_conflicting_services() {
  log "停止可能占用端口的旧服务..."

  rc-service xray stop 2>/dev/null || true
  rc-update del xray default 2>/dev/null || true
  pkill -f 'xray run' 2>/dev/null || true

  rc-service sing-box stop 2>/dev/null || true
  pkill -f 'sing-box run' 2>/dev/null || true
}

generate_reality_values() {
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  KEYPAIR="$("$BIN_DST" generate reality-keypair)"

  PRIVATE_KEY="$(echo "$KEYPAIR" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  PUBLIC_KEY="$(echo "$KEYPAIR" | awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}')"
  SHORT_ID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

  [ -n "$UUID" ] || die "UUID 生成失败。"
  [ -n "$PRIVATE_KEY" ] || die "REALITY private_key 生成失败。"
  [ -n "$PUBLIC_KEY" ] || die "REALITY public_key 生成失败。"
  [ -n "$SHORT_ID" ] || die "REALITY short_id 生成失败。"
}

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
}

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
# Low-memory Go runtime hints. These are helpful on tiny machines,
# but cannot guarantee stability if RAM is extremely limited.
export GOMEMLIMIT="32MiB"
export GOGC="25"

depend() {
  need net
}

start_pre() {
  mkdir -p "${LOG_DIR}"
  touch "${LOG_DIR}/sing-box.log"
  touch "${LOG_DIR}/error.log"
}
EOF

  chmod +x /etc/init.d/sing-box
  ensure_openrc_runtime
  rc-update add sing-box default >/dev/null 2>&1 || true
}

test_and_restart() {
  log "检查 sing-box 配置..."
  "$BIN_DST" check -c "$CONF_FILE"

  log "启动 / 重启 sing-box..."
  rc-service sing-box restart

  log "服务状态："
  rc-service sing-box status || true
}

detect_server_ip() {
  SERVER_ADDR="${SERVER_ADDR:-}"

  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR="$(wget -qO- https://api.ipify.org 2>/dev/null || true)"
  fi

  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR="你的服务器IP"
    warn "未能自动获取公网 IP，请在客户端链接中手动替换服务器地址。"
  fi
}

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
Handshake: ${HANDSHAKE_SERVER}:${HANDSHAKE_PORT}
PublicKey / pbk: ${PUBLIC_KEY}
ShortId / sid: ${SHORT_ID}
Fingerprint: chrome

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
  echo "提示：请确认云服务器安全组 / 防火墙已放行 TCP ${PORT}。"
}

install_mode() {
  echo
  echo "=== 安装 sing-box + 生成配置 ==="

  ask_port_domain

  protect_ssh

  # Detect architecture, download the matching musl binary,
  # verify it, and only then move it into /usr/local/bin.
  install_binary

  stop_conflicting_services
  generate_reality_values
  write_config
  write_openrc_service
  test_and_restart
  write_info
}

update_config_mode() {
  echo
  echo "=== 更新配置 ==="

  ask_port_domain
  protect_ssh
  check_binary_exists
  generate_reality_values
  write_config
  write_openrc_service
  test_and_restart
  write_info
}

show_status() {
  echo
  echo "=== 当前状态 ==="

  if [ -x "$BIN_DST" ]; then
    "$BIN_DST" version || true
  else
    warn "未安装 sing-box：${BIN_DST} 不存在。"
  fi

  echo
  rc-service sing-box status 2>/dev/null || true

  echo
  ss -lntp 2>/dev/null | grep sing-box || true

  echo
  if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
  else
    warn "未找到节点信息文件：${INFO_FILE}"
  fi

  pause
}

main_menu() {
  while true; do
    clear 2>/dev/null || true

    echo "=============================================="
    echo " sing-box VLESS + REALITY for Alpine"
    echo "=============================================="
    echo " 1) 安装"
    echo " 2) 更新配置"
    echo " 3) 查看状态"
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

main() {
  require_root
  main_menu
}

main "$@"
