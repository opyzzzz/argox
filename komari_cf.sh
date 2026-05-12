#!/usr/bin/env bash
#===============================================================================
# Komari + Cloudflare Tunnel Manager v4.5.2
# 生产级稳定版 | Alpine/Debian/OpenRC/systemd/BusyBox 兼容
#
# v4.5.2 修复:
#   - cloudflared wrapper 使用环境变量传递 Token（不再暴露在 ps 中）
#   - 安装完成后交互界面显示初始账号密码
#   - 交互菜单新增"查看密码"选项
# shellcheck disable=SC1090,SC2034,SC2155
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# 常量
#===============================================================================
readonly VERSION="4.5.2"
readonly APP_NAME="komari"
readonly CF_NAME="cloudflared"

readonly INSTALL_DIR="/opt/komari"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly LOG_DIR="${INSTALL_DIR}/logs"
readonly CONFIG_DIR="${INSTALL_DIR}/config"
readonly BACKUP_DIR="${INSTALL_DIR}/backups"
readonly CF_DIR="${INSTALL_DIR}/cloudflared"

readonly BIN="${INSTALL_DIR}/komari"
readonly CF_BIN="/usr/local/bin/cloudflared"
readonly CF_ENV="${CF_DIR}/.env"
readonly CF_WRAPPER="${CF_DIR}/run-cloudflared.sh"

readonly LOG_SIZE_MAX="$((10*1024*1024))"
readonly LOCK_DIR="/tmp/komari-mgr.lock"
readonly PORT_DEFAULT="25774"
readonly ADDR_DEFAULT="127.0.0.1"

#===============================================================================
# 颜色
#===============================================================================
if [[ -t 1 ]]; then
    RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
    CYAN='\033[36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

#===============================================================================
# 日志函数
#===============================================================================
_log()  { printf '%s\n' "[$(date +%H:%M:%S)] $1: ${*:2}"; }
info()  { _log 'INFO' "$@"; }
ok()    { printf "%b\n" "${GREEN}[✓]${NC} $*"; }
warn()  { printf "%b\n" "${YELLOW}[!]${NC} $*" >&2; }
err()   { printf "%b\n" "${RED}[✗]${NC} $*" >&2; }
step()  { printf "%b\n" "${CYAN}[▶]${NC} ${BOLD}$*${NC}"; }
die()   { err "$@"; exit 1; }

#===============================================================================
# 并发锁
#===============================================================================
cleanup_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    fi
    if [[ -n "${LOCK_MODE:-}" && "$LOCK_MODE" == "mkdir" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    else
        rm -f "${LOCK_DIR}.flock" 2>/dev/null || true
    fi
}

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${LOCK_DIR}.flock"
        flock -n 9 || die "脚本已在运行"
        LOCK_FD=9
        LOCK_MODE="flock"
        trap cleanup_lock EXIT
    else
        mkdir "$LOCK_DIR" 2>/dev/null || die "脚本已在运行"
        LOCK_MODE="mkdir"
        trap cleanup_lock EXIT
    fi
}

#===============================================================================
# 系统检测
#===============================================================================
detect_os() {
    [[ -f /etc/alpine-release ]] && { echo alpine; return; }
    [[ -f /etc/debian_version ]] && { echo debian; return; }
    echo unknown
}

detect_init() {
    [[ -d /run/systemd/system ]] && { echo systemd; return; }
    command -v rc-service >/dev/null 2>&1 && { echo openrc; return; }
    echo unknown
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo amd64 ;;
        aarch64|arm64)  echo arm64 ;;
        armv7*)         echo armv7 ;;
        riscv64)        echo riscv64 ;;
        *)              echo "$(uname -m)" ;;
    esac
}

detect_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
    fi
}

#===============================================================================
# 依赖安装
#===============================================================================
_cmd_ok() {
    command -v "$1" >/dev/null 2>&1
}

ensure_deps() {
    local miss=""
    for d in curl grep sed awk tar gzip sha256sum; do
        _cmd_ok "$d" || miss="$miss $d"
    done

    [[ -z "$miss" ]] && return 0

    info "安装依赖:$miss"
    case "$(detect_os)" in
        alpine)
            apk update -q
            # shellcheck disable=SC2086
            apk add --no-cache $miss
            ;;
        debian)
            apt-get update -qq
            # shellcheck disable=SC2086
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $miss
            ;;
        *)
            die "未知系统，无法自动安装依赖"
            ;;
    esac
}

#===============================================================================
# 端口检查
#===============================================================================
port_free() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [[ $p -ge 1 ]] && [[ $p -le 65535 ]] || return 1

    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":${p} " && return 1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -q ":${p} " && return 1
    fi
    return 0
}

#===============================================================================
# 文件工具
#===============================================================================
_file_size() { wc -c < "$1" 2>/dev/null || echo 0; }
_truncate()  { : > "$1" 2>/dev/null || true; }

_is_junk() {
    local f="$1"
    [[ ! -f "$f" ]] && return 0
    local sz; sz=$(_file_size "$f")
    [[ $sz -lt 200 ]] && return 0
    head -c 256 "$f" | grep -Eqi '<html|doctype html|not found|rate limit|"message".*"error"|access denied' && return 0
    return 1
}

safe_rm_rf() {
    local p="$1"
    [[ -z "$p" || "$p" == "/" || "$p" == "$HOME" ]] && { err "拒绝删除: $p"; return 1; }
    [[ "$p" == "$INSTALL_DIR" || "$p" == "$INSTALL_DIR"/* || "$p" == /tmp/komari* ]] || {
        err "非白名单路径: $p"; return 1
    }
    rm -rf "$p"
}

#===============================================================================
# 版本与指纹工具
#===============================================================================
normalize_version() {
    printf '%s\n' "$1" | tr -d '\r' | head -1 | sed 's/^[Vv]//; s/[[:space:]]*$//'
}

bin_version() {
    local bin="$1" out=""
    [[ -x "$bin" ]] || { echo ""; return 0; }
    out="$("$bin" version 2>/dev/null | head -5 || true)"
    normalize_version "$out"
}

sha256_of() {
    sha256sum "$1" 2>/dev/null | awk '{print tolower($1)}'
}

short_fingerprint() {
    sha256_of "$1" | cut -c1-12
}

#===============================================================================
# SHA256 校验文件解析
#===============================================================================
_checksum_candidates() {
    local url="$1"
    printf '%s\n' \
        "${url}.sha256" \
        "$(dirname "$url")/SHA256SUMS" \
        "$(dirname "$url")/checksums.txt"
}

_download_text() {
    local url="$1" out="$2"
    curl -fsSL --connect-timeout 10 --max-time 30 -o "$out" "$url" 2>/dev/null
}

_extract_expected_sha256() {
    local checksum_file="$1" target_name="$2" target_base
    target_base="$(basename "$target_name")"

    awk -v target="$target_base" '
        BEGIN { IGNORECASE=1 }
        function ishash(s) { return s ~ /^[0-9a-fA-F]{64}$/ }
        $0 ~ target {
            for (i = 1; i <= NF; i++) {
                if (ishash($i)) { print tolower($i); exit }
            }
        }
        {
            for (i = 1; i <= NF; i++) {
                if (ishash($i)) { print tolower($i); exit }
            }
        }
    ' "$checksum_file" 2>/dev/null || true
}

_verify_checksum_if_possible() {
    local file="$1" asset_url="$2" checksum_file expected actual checksum_url
    local base
    base="$(basename "$asset_url")"
    checksum_file="${file}.checksum.$$"

    expected=""
    while IFS= read -r checksum_url; do
        [[ -n "$checksum_url" ]] || continue
        if _download_text "$checksum_url" "$checksum_file"; then
            expected="$(_extract_expected_sha256 "$checksum_file" "$base" | tr '[:upper:]' '[:lower:]')"
            [[ -n "$expected" ]] && break
        fi
    done < <(_checksum_candidates "$asset_url")

    rm -f "$checksum_file" 2>/dev/null || true

    if [[ -z "$expected" ]]; then
        info "未找到可用 checksum 文件，跳过校验: $base"
        return 0
    fi

    actual="$(sha256_of "$file")"
    [[ -n "$actual" ]] || die "无法计算 SHA256: $file"

    if [[ "$actual" != "$expected" ]]; then
        err "SHA256 校验失败: $(basename "$file")"
        err "  期望: $expected"
        err "  实际: $actual"
        return 1
    fi
    ok "SHA256 校验通过: $base"
}

#===============================================================================
# 下载引擎
#===============================================================================
download() {
    local url="$1" out="$2"
    local tmp="${out}.tmp.$$"
    local success=0
    local mirrors=("$url")

    mkdir -p "$(dirname "$out")"

    if [[ "$url" == *github.com/*/releases/download/* ]]; then
        mirrors+=("https://ghproxy.net/$url")
    fi

    for m in "${mirrors[@]}"; do
        local retry=0
        while [[ $retry -lt 3 ]]; do
            info "下载: $m"
            if curl -fSL --connect-timeout 15 --max-time 300 -o "$tmp" "$m" 2>/dev/null; then
                if _is_junk "$tmp"; then
                    warn "下载到错误页面: $(basename "$out")"
                    rm -f "$tmp"
                    break
                fi

                if [[ "$out" == "$BIN" || "$out" == "$CF_BIN" ]]; then
                    local magic
                    magic="$(head -c4 "$tmp" | od -An -tx1 | tr -d '[:space:]')"
                    if [[ "$magic" != "7f454c46" ]]; then
                        warn "非 ELF 文件: $(basename "$out")"
                        rm -f "$tmp"
                        retry=$((retry+1))
                        sleep $((2**retry))
                        continue
                    fi
                fi

                if ! _verify_checksum_if_possible "$tmp" "$url"; then
                    warn "SHA256 校验失败，尝试下一个源"
                    rm -f "$tmp"
                    break
                fi

                mv -f "$tmp" "$out" 2>/dev/null
                chmod +x "$out" 2>/dev/null || true
                success=1
                break 2
            fi
            retry=$((retry+1))
            sleep $((2**retry))
        done
    done

    rm -f "$tmp" 2>/dev/null || true
    [[ $success -eq 1 ]] || die "下载失败: $url"
    ok "下载完成: $(basename "$out") ($(du -h "$out" 2>/dev/null | cut -f1))"
}

#===============================================================================
# 服务管理统一接口
#===============================================================================
svc() {
    local s="$1" a="$2"
    case "$(detect_init)" in
        systemd) systemctl "$a" "$s" 2>/dev/null || true ;;
        openrc)  rc-service "$s" "$a" 2>/dev/null || true ;;
    esac
}

svc_ok() {
    case "$(detect_init)" in
        systemd) systemctl is-active --quiet "$1" 2>/dev/null ;;
        openrc)  rc-service "$1" status 2>/dev/null | grep -qE 'started|running' ;;
        *) return 1 ;;
    esac
}

#===============================================================================
# Cloudflare Tunnel Token 管理（v4.5.2：wrapper 使用环境变量，不在 ps 暴露）
#===============================================================================
install_cf_wrapper() {
    mkdir -p "$CF_DIR"
    cat > "$CF_WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

CF_ENV="/opt/komari/cloudflared/.env"
CF_BIN="/usr/local/bin/cloudflared"

# 从 env 文件加载 Token 到环境变量（不暴露在 ps 命令行中）
if [[ -f "$CF_ENV" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$CF_ENV"
    set +a
fi

if [[ -z "${TUNNEL_TOKEN:-}" ]]; then
    echo "TUNNEL_TOKEN not set" >&2
    exit 1
fi

# cloudflared 会自动读取 TUNNEL_TOKEN 环境变量
exec "$CF_BIN" tunnel --no-autoupdate run
WRAPPER_EOF
    chmod 700 "$CF_WRAPPER"
}

save_tunnel_token() {
    local token="$1"
    mkdir -p "$CF_DIR"
    install_cf_wrapper

    (
        umask 077
        printf 'TUNNEL_TOKEN=%s\n' "$token" > "$CF_ENV"
    )
    chmod 600 "$CF_ENV"
    ok "Token 已安全保存（不暴露在进程列表中）"
}

load_tunnel_token() {
    [[ -f "$CF_ENV" ]] || return 1
    # shellcheck disable=SC1090
    . "$CF_ENV"
    [[ -n "${TUNNEL_TOKEN:-}" ]]
}

#===============================================================================
# 获取初始账号密码
#===============================================================================
get_credentials() {
    local log_file="$LOG_DIR/komari.log"
    if [[ -f "$log_file" ]]; then
        grep "admin account created" "$log_file" 2>/dev/null | tail -1 | \
            sed -n 's/.*Username:\s*\([^,]*\).*Password:\s*\([^ ]*\).*/\1 \2/p' || true
    fi
}

show_credentials() {
    local creds
    creds=$(get_credentials)
    if [[ -n "$creds" ]]; then
        local user pass
        user=$(echo "$creds" | awk '{print $1}')
        pass=$(echo "$creds" | awk '{print $2}')
        echo ""
        printf '%b\n' "${YELLOW}${BOLD}╔══════════════════════════════════════════╗${NC}"
        printf '%b\n' "${YELLOW}${BOLD}║        初始账号信息（仅显示一次）        ║${NC}"
        printf '%b\n' "${YELLOW}${BOLD}╠══════════════════════════════════════════╣${NC}"
        printf '%b\n' "${YELLOW}${BOLD}║  用户名: ${GREEN}${user}${YELLOW}                          ║${NC}"
        printf '%b\n' "${YELLOW}${BOLD}║  密  码: ${GREEN}${pass}${YELLOW}                    ║${NC}"
        printf '%b\n' "${YELLOW}${BOLD}║                                          ║${NC}"
        printf '%b\n' "${YELLOW}${BOLD}║  ${RED}请立即登录修改密码！${YELLOW}                  ║${NC}"
        printf '%b\n' "${YELLOW}${BOLD}╚══════════════════════════════════════════╝${NC}"
        echo ""
    else
        warn "未找到初始账号信息（可能已被轮转或日志已清理）"
    fi
}

#===============================================================================
# 服务文件生成
#===============================================================================
create_komari_svc() {
    local addr="$1" port="$2" init
    init=$(detect_init)

    case "$init" in
        systemd)
            cat > "/etc/systemd/system/${APP_NAME}.service" <<SYSTEMD_EOF
[Unit]
Description=Komari Monitor
After=network-online.target

[Service]
Type=simple
ExecStart=${BIN} server -l ${addr}:${port}
Restart=on-failure
RestartSec=5
ProtectSystem=full
NoNewPrivileges=true
StandardOutput=file:${LOG_DIR}/komari.log
StandardError=file:${LOG_DIR}/komari-error.log

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
            if command -v systemd-analyze >/dev/null 2>&1; then
                if ! systemd-analyze verify "/etc/systemd/system/${APP_NAME}.service" >/dev/null 2>&1; then
                    sed -i 's|StandardOutput=file:.*|StandardOutput=journal|' "/etc/systemd/system/${APP_NAME}.service"
                    sed -i 's|StandardError=file:.*|StandardError=journal|' "/etc/systemd/system/${APP_NAME}.service"
                fi
            fi
            systemctl daemon-reload
            systemctl enable "$APP_NAME" 2>/dev/null || true
            ;;
        openrc)
            cat > "/etc/init.d/${APP_NAME}" <<OPENRC_EOF
#!/sbin/openrc-run
name="${APP_NAME}"
description="Komari Monitor"
supervisor="supervise-daemon"
command="${BIN}"
command_args="server -l ${addr}:${port}"
command_background=true
pidfile="/var/run/\${name}.pid"
output_log="${LOG_DIR}/komari.log"
error_log="${LOG_DIR}/komari-error.log"
respawn_delay=5
respawn_max=10

depend() {
    need net
}

start_pre() {
    checkpath -d -m 0755 -o root:root "${LOG_DIR}" "${DATA_DIR}"
}
OPENRC_EOF
            chmod +x "/etc/init.d/${APP_NAME}"
            rc-update add "$APP_NAME" default 2>/dev/null || true
            ;;
        *)
            warn "未知 init 系统，已跳过 Komari 服务创建"
            return 0
            ;;
    esac
    ok "Komari 服务已创建 ($init)"
}

create_cf_svc() {
    local init
    init=$(detect_init)

    case "$init" in
        systemd)
            cat > "/etc/systemd/system/${CF_NAME}.service" <<SYSTEMD_EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target ${APP_NAME}.service

[Service]
Type=simple
EnvironmentFile=${CF_ENV}
ExecStart=${CF_WRAPPER}
Restart=on-failure
RestartSec=5
ProtectSystem=full
NoNewPrivileges=true
StandardOutput=file:${LOG_DIR}/cloudflared.log
StandardError=file:${LOG_DIR}/cloudflared-error.log

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
            systemctl daemon-reload
            systemctl enable "$CF_NAME" 2>/dev/null || true
            ;;
        openrc)
            cat > "/etc/init.d/${CF_NAME}" <<OPENRC_EOF
#!/sbin/openrc-run
name="${CF_NAME}"
description="Cloudflare Tunnel"
supervisor="supervise-daemon"
command="${CF_WRAPPER}"
command_args=""
command_background=true
pidfile="/var/run/\${name}.pid"
output_log="${LOG_DIR}/cloudflared.log"
error_log="${LOG_DIR}/cloudflared-error.log"
respawn_delay=5
respawn_max=10

depend() {
    need net
    after ${APP_NAME}
}

start_pre() {
    checkpath -d -m 0755 -o root:root "${LOG_DIR}" "${CF_DIR}"
}
OPENRC_EOF
            chmod +x "/etc/init.d/${CF_NAME}"
            rc-update add "$CF_NAME" default 2>/dev/null || true
            ;;
        *)
            warn "未知 init 系统，已跳过 Cloudflared 服务创建"
            return 0
            ;;
    esac
    ok "Cloudflared 服务已创建 ($init)"
}

#===============================================================================
# 健康检查
#===============================================================================
health_tcp() {
    local host="${1:-127.0.0.1}" port="$2" to="${3:-3}"

    if command -v bash >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        timeout "$to" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && return 0
    fi
    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$to" "$host" "$port" 2>/dev/null && return 0
    fi
    curl -sf --connect-timeout "$to" "http://${host}:${port}" >/dev/null 2>&1 && return 0
    return 1
}

#===============================================================================
# 日志轮转
#===============================================================================
rotate_logs() {
    mkdir -p "$LOG_DIR"
    for f in "$LOG_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        local sz ts
        sz=$(_file_size "$f")
        [[ $sz -le $LOG_SIZE_MAX ]] && continue

        ts=$(date +%Y%m%d_%H%M%S)
        cp "$f" "${f}.${ts}"
        _truncate "$f"
        (gzip "${f}.${ts}" 2>/dev/null || mv "${f}.${ts}" "${f}.${ts}.gz" 2>/dev/null) &

        find "$LOG_DIR" -name "$(basename "$f").*.gz" -type f 2>/dev/null | sort -r | awk 'NR > 5' | xargs rm -f 2>/dev/null || true
    done
}

#===============================================================================
# 配置持久化
#===============================================================================
load_config() {
    local f="$CONFIG_DIR/komari.conf"
    [[ -f "$f" ]] || return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            LISTEN_PORT=*)     LISTEN_PORT="${line#LISTEN_PORT=}" ;;
            LISTEN_ADDR=*)     LISTEN_ADDR="${line#LISTEN_ADDR=}" ;;
            DOMAIN=*)          DOMAIN="${line#DOMAIN=}" ;;
            CF_TUNNEL_NAME=*)  CF_TUNNEL_NAME="${line#CF_TUNNEL_NAME=}" ;;
        esac
    done < "$f"

    LISTEN_PORT="${LISTEN_PORT:-$PORT_DEFAULT}"
    LISTEN_ADDR="${LISTEN_ADDR:-$ADDR_DEFAULT}"
    DOMAIN="${DOMAIN:-}"
    CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-komari-tunnel}"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/komari.conf" <<EOF
# Komari Manager Config
LISTEN_PORT=${LISTEN_PORT:-$PORT_DEFAULT}
LISTEN_ADDR=${LISTEN_ADDR:-$ADDR_DEFAULT}
DOMAIN=${DOMAIN:-}
CF_TUNNEL_NAME=${CF_TUNNEL_NAME:-komari-tunnel}
EOF
    chmod 600 "$CONFIG_DIR/komari.conf"
}

#===============================================================================
# 备份与恢复
#===============================================================================
backup() {
    step "创建备份..."
    mkdir -p "$BACKUP_DIR" "$CONFIG_DIR" "$CF_DIR" "$DATA_DIR" "$LOG_DIR"
    local ts out tmp
    ts=$(date +%Y%m%d_%H%M%S)
    out="$BACKUP_DIR/backup-${ts}.tar.gz"
    tmp="/tmp/komari_bak_$$"

    mkdir -p "$tmp"/{config,init,systemd,cf,data,wrapper}

    [[ -f "$CONFIG_DIR/komari.conf" ]] && cp "$CONFIG_DIR/komari.conf" "$tmp/config/"
    [[ -f "$CF_ENV" ]] && cp "$CF_ENV" "$tmp/cf/"
    [[ -f "$CF_WRAPPER" ]] && cp "$CF_WRAPPER" "$tmp/wrapper/"
    [[ -f "/etc/init.d/$APP_NAME" ]] && cp "/etc/init.d/$APP_NAME" "$tmp/init/"
    [[ -f "/etc/init.d/$CF_NAME" ]] && cp "/etc/init.d/$CF_NAME" "$tmp/init/"
    [[ -f "/etc/systemd/system/${APP_NAME}.service" ]] && cp "/etc/systemd/system/${APP_NAME}.service" "$tmp/systemd/"
    [[ -f "/etc/systemd/system/${CF_NAME}.service" ]] && cp "/etc/systemd/system/${CF_NAME}.service" "$tmp/systemd/"
    [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR"/* "$tmp/data/" 2>/dev/null || true

    tar -czf "$out" -C "$tmp" . 2>/dev/null
    rm -rf "$tmp"

    find "$BACKUP_DIR" -name 'backup-*.tar.gz' 2>/dev/null | sort -r | awk 'NR > 7' | xargs rm -f 2>/dev/null || true
    ok "备份: $out ($(du -h "$out" 2>/dev/null | cut -f1))"
}

restore() {
    local f="$1"
    [[ -f "$f" ]] || { err "备份文件不存在"; return 1; }
    step "恢复: $f"

    backup

    svc "$CF_NAME" stop 2>/dev/null || true
    svc "$APP_NAME" stop 2>/dev/null || true

    local tmp
    tmp="/tmp/komari_rst_$$"
    mkdir -p "$tmp"

    if tar -tzf "$f" 2>/dev/null | grep -qE '^/|\.\./'; then
        err "备份包含危险路径，拒绝恢复"
        rm -rf "$tmp"
        return 1
    fi

    tar -xzf "$f" -C "$tmp" 2>/dev/null || { err "解压失败"; rm -rf "$tmp"; return 1; }

    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$CF_DIR" /etc/systemd/system /etc/init.d

    [[ -f "$tmp/config/komari.conf" ]] && cp "$tmp/config/komari.conf" "$CONFIG_DIR/"
    [[ -f "$tmp/cf/.env" ]] && { cp "$tmp/cf/.env" "$CF_ENV"; chmod 600 "$CF_ENV"; }
    [[ -f "$tmp/wrapper/run-cloudflared.sh" ]] && { cp "$tmp/wrapper/run-cloudflared.sh" "$CF_WRAPPER"; chmod 700 "$CF_WRAPPER"; }
    [[ -f "$tmp/init/komari" ]] && { cp "$tmp/init/komari" /etc/init.d/; chmod +x /etc/init.d/komari; }
    [[ -f "$tmp/init/cloudflared" ]] && { cp "$tmp/init/cloudflared" /etc/init.d/; chmod +x /etc/init.d/cloudflared; }
    [[ -f "$tmp/systemd/${APP_NAME}.service" ]] && cp "$tmp/systemd/${APP_NAME}.service" /etc/systemd/system/
    [[ -f "$tmp/systemd/${CF_NAME}.service" ]] && cp "$tmp/systemd/${CF_NAME}.service" /etc/systemd/system/
    [[ -d "$tmp/data" ]] && cp -a "$tmp/data"/* "$DATA_DIR/" 2>/dev/null || true

    rm -rf "$tmp"

    [[ "$(detect_init)" == systemd ]] && systemctl daemon-reload
    load_config

    svc "$APP_NAME" start 2>/dev/null || true
    svc "$CF_NAME" start 2>/dev/null || true
    ok "恢复完成"
}

restore_menu() {
    local list=() line
    [[ -d "$BACKUP_DIR" ]] || { err "无可用备份"; return 1; }

    while IFS= read -r line; do
        [[ -n "$line" ]] && list+=("$line")
    done < <(find "$BACKUP_DIR" -name 'backup-*.tar.gz' 2>/dev/null | sort -r)

    [[ ${#list[@]} -eq 0 ]] && { err "无可用备份"; return 1; }

    local i
    for i in "${!list[@]}"; do
        printf "  %d) %s (%s)\n" "$((i+1))" "$(basename "${list[$i]}")" "$(du -h "${list[$i]}" 2>/dev/null | cut -f1)"
    done
    printf "  0) 取消\n"
    read -rp "选择: " c
    [[ "$c" == "0" ]] && return 0
    [[ -n "${list[$((c-1))]:-}" ]] && restore "${list[$((c-1))]}"
}

#===============================================================================
# 快捷命令
#===============================================================================
install_shortcut() {
    local me="$0" dst="/usr/local/bin/komari" real
    real="$(readlink -f "$me" 2>/dev/null || realpath "$me" 2>/dev/null || echo "$me")"
    [[ -f "$dst" ]] && [[ "$(readlink -f "$dst" 2>/dev/null)" == "$real" ]] && return 0

    printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$real" > "$dst"
    chmod +x "$dst"
}

#===============================================================================
# 系统自检
#===============================================================================
doctor() {
    printf '%b\n' "${BOLD}=== Komari 系统自检 ===${NC}"
    printf '版本: %s | OS: %s | Init: %s | Arch: %s\n' "$VERSION" "$(detect_os)" "$(detect_init)" "$(detect_arch)"
    printf 'IP: %s | 端口: %s | 域名: %s\n\n' "$(detect_ip)" "${LISTEN_PORT:-$PORT_DEFAULT}" "${DOMAIN:-未配置}"

    local issues=0

    if [[ -x "$BIN" ]]; then
        printf '  %b komari\n' "${GREEN}✓${NC}"
    else
        printf '  %b komari: 未安装\n' "${RED}✗${NC}"
        issues=$((issues + 1))
    fi

    if [[ -x "$CF_BIN" ]]; then
        printf '  %b cloudflared\n' "${GREEN}✓${NC}"
    else
        printf '  %b cloudflared: 未安装\n' "${YELLOW}-${NC}"
    fi

    if svc_ok "$APP_NAME"; then
        printf '  %b %s: 运行中\n' "${GREEN}✓${NC}" "$APP_NAME"
    else
        printf '  %b %s: 未运行\n' "${RED}✗${NC}" "$APP_NAME"
        issues=$((issues + 1))
    fi

    if svc_ok "$CF_NAME"; then
        printf '  %b %s: 运行中\n' "${GREEN}✓${NC}" "$CF_NAME"
    else
        printf '  %b %s: 未运行\n' "${YELLOW}-${NC}" "$CF_NAME"
    fi

    if health_tcp 127.0.0.1 "${LISTEN_PORT:-$PORT_DEFAULT}" 3; then
        printf '  %b TCP 端口可达\n' "${GREEN}✓${NC}"
    else
        printf '  %b TCP 端口不可达\n' "${RED}✗${NC}"
        issues=$((issues + 1))
    fi

    if curl -s --connect-timeout 5 https://github.com >/dev/null 2>&1; then
        printf '  %b 外网连通\n' "${GREEN}✓${NC}"
    else
        printf '  %b 外网可能受限\n' "${YELLOW}!${NC}"
    fi

    printf '\n磁盘: %s\n' "$(du -sh "$INSTALL_DIR" 2>/dev/null | cut -f1 || echo 'N/A')"
    [[ $issues -eq 0 ]] && ok "系统健康" || warn "发现 ${issues} 个问题"
}

#===============================================================================
# 安装
#===============================================================================
install() {
    acquire_lock
    [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限"

    step "Komari v${VERSION} 安装向导"
    ensure_deps
    mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "$CF_DIR"

    local arch port addr
    arch=$(detect_arch)
    info "系统: $(detect_os)/$(detect_init)/$arch"

    while true; do
        read -rp "监听端口 [$PORT_DEFAULT]: " port
        port="${port:-$PORT_DEFAULT}"
        port_free "$port" && break
        warn "端口 $port 被占用"
    done
    LISTEN_PORT="$port"

    read -rp "监听地址 [$ADDR_DEFAULT]: " addr
    addr="${addr:-$ADDR_DEFAULT}"
    LISTEN_ADDR="$addr"

    step "下载组件..."
    local k_url cf_arch cf_url
    k_url="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${arch}"
    cf_arch="$arch"
    [[ "$cf_arch" == "riscv64" ]] && cf_arch="amd64"
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"

    download "$k_url" "$BIN"
    download "$cf_url" "$CF_BIN"

    local token
    read -rsp "Cloudflare Tunnel Token (不可见): " token; echo
    [[ -n "$token" ]] || die "Token 不能为空"
    save_tunnel_token "$token"

    step "创建服务..."
    create_komari_svc "$LISTEN_ADDR" "$LISTEN_PORT"
    create_cf_svc

    step "启动服务..."
    svc "$APP_NAME" start
    sleep 3
    svc "$CF_NAME" start
    sleep 2

    if health_tcp "$LISTEN_ADDR" "$LISTEN_PORT" 5; then
        ok "Komari 启动成功"
    else
        warn "Komari 可能未完全启动"
    fi

    svc_ok "$CF_NAME" && ok "Tunnel 启动成功" || warn "Tunnel 可能未完全启动"

    save_config
    install_shortcut

    echo ""
    ok "安装完成！本地: http://${LISTEN_ADDR}:${LISTEN_PORT}"
    [[ -n "${DOMAIN:-}" ]] && info "公网: https://${DOMAIN}"

    # 显示初始账号密码
    show_credentials

    info "管理: komari [status|backup|restore|logs|doctor|update|uninstall|password]"
}

#===============================================================================
# 更新
#===============================================================================
_replace_binary_safe() {
    local target="$1" newfile="$2" bak="$3"
    [[ -f "$target" ]] && cp -f "$target" "$bak" 2>/dev/null || true
    mv -f "$newfile" "$target"
    chmod +x "$target" 2>/dev/null || true
}

update() {
    [[ -x "$BIN" ]] || { err "未安装"; return 1; }
    step "更新..."

    local arch cf_arch
    arch=$(detect_arch)
    cf_arch="$arch"
    [[ "$cf_arch" == "riscv64" ]] && cf_arch="amd64"

    local old_komari old_cf old_komari_sum old_cf_sum
    old_komari="$(bin_version "$BIN")"
    old_cf="$(bin_version "$CF_BIN")"
    old_komari_sum="$(short_fingerprint "$BIN")"
    old_cf_sum="$(short_fingerprint "$CF_BIN")"

    backup

    svc "$CF_NAME" stop 2>/dev/null || true
    svc "$APP_NAME" stop 2>/dev/null || true

    local new_bin new_cf_bin bak_bin bak_cf k_url cf_url rollback
    new_bin="${INSTALL_DIR}/.komari.new.$$"
    new_cf_bin="/usr/local/bin/.cloudflared.new.$$"
    bak_bin="${BIN}.bak.$$"
    bak_cf="${CF_BIN}.bak.$$"
    k_url="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${arch}"
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    rollback=0

    if ! download "$k_url" "$new_bin"; then rollback=1; fi
    if ! download "$cf_url" "$new_cf_bin"; then rollback=1; fi

    if [[ $rollback -eq 0 ]]; then
        local new_komari new_cf new_komari_sum new_cf_sum
        new_komari="$(bin_version "$new_bin")"
        new_cf="$(bin_version "$new_cf_bin")"
        new_komari_sum="$(short_fingerprint "$new_bin")"
        new_cf_sum="$(short_fingerprint "$new_cf_bin")"

        info "Komari 版本: ${old_komari:-unknown} -> ${new_komari:-unknown}"
        info "cloudflared 版本: ${old_cf:-unknown} -> ${new_cf:-unknown}"

        if [[ "${old_komari:-}" == "${new_komari:-}" && "${old_komari_sum:-}" == "${new_komari_sum:-}" ]]; then
            info "Komari 未发生变化，跳过替换"
            rm -f "$new_bin" 2>/dev/null || true
        else
            _replace_binary_safe "$BIN" "$new_bin" "$bak_bin"
        fi

        if [[ "${old_cf:-}" == "${new_cf:-}" && "${old_cf_sum:-}" == "${new_cf_sum:-}" ]]; then
            info "cloudflared 未发生变化，跳过替换"
            rm -f "$new_cf_bin" 2>/dev/null || true
        else
            _replace_binary_safe "$CF_BIN" "$new_cf_bin" "$bak_cf"
        fi
    else
        err "下载或校验失败，准备回滚"
    fi

    if [[ ! -x "$BIN" || ! -x "$CF_BIN" ]]; then
        rollback=1
        err "新二进制不可执行，准备回滚"
    fi

    if [[ $rollback -eq 1 ]]; then
        [[ -f "$bak_bin" ]] && mv -f "$bak_bin" "$BIN" || true
        [[ -f "$bak_cf" ]] && mv -f "$bak_cf" "$CF_BIN" || true
    fi

    svc "$APP_NAME" start 2>/dev/null || true
    svc "$CF_NAME" start 2>/dev/null || true

    sleep 2
    if [[ $rollback -eq 0 ]] && health_tcp "${LISTEN_ADDR:-$ADDR_DEFAULT}" "${LISTEN_PORT:-$PORT_DEFAULT}" 5; then
        ok "更新完成"
        rm -f "$bak_bin" "$bak_cf" 2>/dev/null || true
    else
        warn "更新后健康检查未通过，尝试回滚"
        svc "$CF_NAME" stop 2>/dev/null || true
        svc "$APP_NAME" stop 2>/dev/null || true
        [[ -f "$bak_bin" ]] && mv -f "$bak_bin" "$BIN" || true
        [[ -f "$bak_cf" ]] && mv -f "$bak_cf" "$CF_BIN" || true
        svc "$APP_NAME" start 2>/dev/null || true
        svc "$CF_NAME" start 2>/dev/null || true
        err "已回滚"
    fi

    rm -f "$new_bin" "$new_cf_bin" 2>/dev/null || true
}

#===============================================================================
# 卸载
#===============================================================================
uninstall() {
    printf '%b\n' "${RED}${BOLD}=== 卸载 Komari ===${NC}"
    read -rp "输入 DELETE 确认: " c
    [[ "$c" != "DELETE" ]] && { info "已取消"; return 0; }

    for s in "$CF_NAME" "$APP_NAME"; do
        svc "$s" stop 2>/dev/null || true
    done

    case "$(detect_init)" in
        systemd)
            systemctl disable "$APP_NAME" "$CF_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/${APP_NAME}.service" "/etc/systemd/system/${CF_NAME}.service"
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del "$APP_NAME" 2>/dev/null || true
            rc-update del "$CF_NAME" 2>/dev/null || true
            rm -f "/etc/init.d/${APP_NAME}" "/etc/init.d/${CF_NAME}"
            ;;
    esac

    rm -f "$BIN" "$CF_BIN" /usr/local/bin/komari "$CF_WRAPPER" 2>/dev/null || true
    crontab -l 2>/dev/null | grep -v log-rotate | crontab - 2>/dev/null || true

    read -rp "删除数据目录? [y/N]: " d
    [[ "$d" =~ ^[Yy]$ ]] && safe_rm_rf "$INSTALL_DIR" || info "保留 $INSTALL_DIR"
    ok "卸载完成"
}

#===============================================================================
# 交互菜单
#===============================================================================
menu() {
    while true; do
        clear 2>/dev/null || true
        printf '%b\n' "${CYAN}╔══════════════════════════════════════╗${NC}"
        printf '%b\n' "${CYAN}║   Komari + CF Tunnel Manager v${VERSION}  ║${NC}"
        printf '%b\n' "${CYAN}╚══════════════════════════════════════╝${NC}"

        local ks='✗' cs='✗'
        svc_ok "$APP_NAME" && ks="${GREEN}✓${NC}"
        svc_ok "$CF_NAME" && cs="${GREEN}✓${NC}"

        printf '\n状态: Komari[%b] CF[%b] | 端口:%s | %s\n\n' \
            "$ks" "$cs" "${LISTEN_PORT:-$PORT_DEFAULT}" "${DOMAIN:-未配置域名}"

        printf " 1) 安装      5) 停止     9) 备份\n"
        printf " 2) 更新      6) 重启    10) 恢复\n"
        printf " 3) 卸载      7) 日志    11) 自检\n"
        printf " 4) 启动      8) 状态    12) 配置\n"
        printf "                             13) 查看密码\n"
        printf " 0) 退出\n"

        read -rp "> " ch
        case "${ch:-0}" in
            1) install ;;
            2) update ;;
            3) uninstall ;;
            4) svc "$APP_NAME" start; svc "$CF_NAME" start 2>/dev/null || true ;;
            5) svc "$CF_NAME" stop 2>/dev/null; svc "$APP_NAME" stop ;;
            6) svc "$APP_NAME" restart; svc "$CF_NAME" restart 2>/dev/null || true ;;
            7) (trap '' INT; tail -f "$LOG_DIR/komari.log" 2>/dev/null) || err "日志不可用" ;;
            8) doctor ;;
            9) backup ;;
            10) restore_menu ;;
            11) doctor ;;
            12)
                local p d
                read -rp "新端口 [$PORT_DEFAULT]: " p
                p="${p:-$PORT_DEFAULT}"
                if port_free "$p"; then
                    LISTEN_PORT="$p"
                    save_config
                    svc "$APP_NAME" restart
                else
                    warn "端口被占用"
                fi
                read -rp "域名: " d
                [[ -n "$d" ]] && { DOMAIN="$d"; save_config; }
                ;;
            13) show_credentials ;;
            0) exit 0 ;;
        esac
        read -rp "回车继续..."
    done
}

#===============================================================================
# 帮助
#===============================================================================
show_help() {
    cat <<EOF
Komari Manager v${VERSION}
用法: komari <命令>

命令:
  install      安装 Komari + Cloudflare Tunnel
  uninstall    完全卸载
  update       更新所有组件
  restart      重启所有服务
  start/stop   启动/停止所有服务
  status       显示运行状态 (自检)
  backup       创建配置备份
  restore      从备份恢复
  logs         查看实时日志
  doctor       系统自检
  password     查看初始账号密码
  menu         交互菜单 (默认)

示例:
  komari install
  komari update
  komari status
  komari password
EOF
}

#===============================================================================
# 主入口
#===============================================================================
main() {
    install_shortcut
    load_config
    rotate_logs

    case "${1:-menu}" in
        install)    install ;;
        uninstall)  uninstall ;;
        update)     update ;;
        restart)    svc "$APP_NAME" restart; svc "$CF_NAME" restart 2>/dev/null || true ;;
        start)      svc "$APP_NAME" start; svc "$CF_NAME" start 2>/dev/null || true ;;
        stop)       svc "$CF_NAME" stop 2>/dev/null; svc "$APP_NAME" stop ;;
        status|doctor) doctor ;;
        backup)     backup ;;
        restore)    restore_menu ;;
        logs)       tail -f "$LOG_DIR/komari.log" 2>/dev/null || err "日志不可用" ;;
        password)   show_credentials ;;
        menu)       menu ;;
        help|--help|-h) show_help ;;
        version|--version|-v) echo "v$VERSION" ;;
        *)          show_help ;;
    esac
}

main "$@"
