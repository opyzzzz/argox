#!/usr/bin/env bash
#===============================================================================
# Komari + Cloudflare Tunnel Manager v4.5.3
# 生产级稳定版 | Alpine/Debian/OpenRC/systemd/BusyBox 兼容
#
# v4.5.3 更新:
#   - 性能优化：hash 缓存命令路径 / SHA256 本地缓存 / 按需清理日志
#   - 智能卸载：检测其他 CF Tunnel，避免误删共享的 cloudflared 二进制
#   - 交互菜单精简：合并"状态/自检"，新增 quick_status 函数
#   - 响应式布局：自动适配手机小屏和 PC 大屏
# shellcheck disable=SC1090,SC2034,SC2155
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# 常量
#===============================================================================
readonly VERSION="4.5.3"
readonly APP_NAME="komari"
readonly CF_NAME="cloudflared"

readonly INSTALL_DIR="/opt/komari"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly LOG_DIR="${INSTALL_DIR}/logs"
readonly CONFIG_DIR="${INSTALL_DIR}/config"
readonly BACKUP_DIR="${INSTALL_DIR}/backups"
readonly CF_DIR="${INSTALL_DIR}/cloudflared"
readonly CACHE_DIR="${INSTALL_DIR}/cache"

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
# 响应式检测
#===============================================================================
is_wide_screen() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    [[ $cols -ge 60 ]]
}

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
# 依赖安装（优化：hash 缓存命令路径）
#===============================================================================
# 一次性缓存所有关键命令路径，后续检测 O(1)
_cache_commands() {
    local cmd
    for cmd in curl grep sed awk tar gzip sha256sum flock tput od head wc du df stat; do
        hash "$cmd" 2>/dev/null || true
    done
}

_cmd_ok() {
    hash "$1" 2>/dev/null
}

ensure_deps() {
    _cache_commands
    local miss=""
    for d in curl grep sed awk tar gzip sha256sum; do
        _cmd_ok "$d" || miss="$miss $d"
    done
    [[ -z "$miss" ]] && return 0
    info "安装依赖:$miss"
    case "$(detect_os)" in
        alpine) apk update -q; apk add --no-cache $miss ;;
        debian) apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $miss ;;
        *) die "未知系统" ;;
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

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print tolower($1)}'; }
short_fingerprint() { sha256_of "$1" | cut -c1-12; }

#===============================================================================
# SHA256 校验（优化：本地缓存校验结果）
#===============================================================================
_checksum_cache_key() {
    local url="$1"
    printf '%s' "$url" | sha256sum 2>/dev/null | awk '{print $1}' || echo "${url##*/}"
}

_cached_checksum() {
    local key="$1" cache_file="${CACHE_DIR}/checksum-${key}"
    [[ -f "$cache_file" ]] && [[ $(find "$cache_file" -mmin -1440 2>/dev/null) ]] || return 1
    cat "$cache_file"
}

_save_checksum_cache() {
    local key="$1" value="$2"
    mkdir -p "$CACHE_DIR"
    printf '%s\n' "$value" > "${CACHE_DIR}/checksum-${key}"
}

_verify_checksum_if_possible() {
    local file="$1" asset_url="$2" cache_key expected actual checksum_url
    cache_key=$(_checksum_cache_key "$asset_url")

    # 优先使用本地缓存
    expected=$(_cached_checksum "$cache_key" 2>/dev/null || true)
    if [[ -n "$expected" ]]; then
        actual="$(sha256_of "$file")"
        [[ "$actual" == "$expected" ]] && { info "校验通过(缓存): $(basename "$file")"; return 0; }
    fi

    # 缓存未命中，远程获取
    local checksum_file="${file}.checksum.$$" base
    base="$(basename "$asset_url")"
    expected=""
    while IFS= read -r checksum_url; do
        [[ -n "$checksum_url" ]] || continue
        if curl -fsSL --connect-timeout 10 --max-time 30 -o "$checksum_file" "$checksum_url" 2>/dev/null; then
            expected=$(awk -v target="$base" '
                BEGIN { IGNORECASE=1 }
                function ishash(s) { return s ~ /^[0-9a-fA-F]{64}$/ }
                $0 ~ target { for(i=1;i<=NF;i++) if(ishash($i)) { print tolower($i); exit } }
                { for(i=1;i<=NF;i++) if(ishash($i)) { print tolower($i); exit } }
            ' "$checksum_file" 2>/dev/null || true)
            [[ -n "$expected" ]] && break
        fi
    done < <(printf '%s\n' "${asset_url}.sha256" "$(dirname "$asset_url")/SHA256SUMS" "$(dirname "$asset_url")/checksums.txt")
    rm -f "$checksum_file" 2>/dev/null || true

    if [[ -z "$expected" ]]; then
        info "跳过校验: $base"
        return 0
    fi

    actual="$(sha256_of "$file")"
    [[ -n "$actual" ]] || die "无法计算 SHA256: $file"

    if [[ "$actual" != "$expected" ]]; then
        err "SHA256 校验失败: $base"; return 1
    fi

    # 缓存结果
    _save_checksum_cache "$cache_key" "$expected"
    ok "SHA256 校验通过: $base"
}

#===============================================================================
# 下载引擎
#===============================================================================
download() {
    local url out tmp success mirrors
    url="$1"
    out="$2"
    tmp="${out}.tmp.$$"
    success=0
    mirrors=("$url")
    mkdir -p "$(dirname "$out")"
    [[ "$url" == *github.com/*/releases/download/* ]] && mirrors+=("https://ghproxy.net/$url")
    for m in "${mirrors[@]}"; do
        local retry=0
        while [[ $retry -lt 3 ]]; do
            info "下载: $m"
            if curl -fSL --connect-timeout 15 --max-time 300 -o "$tmp" "$m" 2>/dev/null; then
                _is_junk "$tmp" && { warn "错误页面: $(basename "$out")"; rm -f "$tmp"; break; }
                if [[ "$out" == "$BIN" || "$out" == "$CF_BIN" ]]; then
                    local magic; magic="$(head -c4 "$tmp" | od -An -tx1 | tr -d '[:space:]')"
                    [[ "$magic" != "7f454c46" ]] && { warn "非 ELF: $(basename "$out")"; rm -f "$tmp"; retry=$((retry+1)); sleep $((2**retry)); continue; }
                fi
                _verify_checksum_if_possible "$tmp" "$url" || { warn "校验失败"; rm -f "$tmp"; break; }
                mv -f "$tmp" "$out" 2>/dev/null; chmod +x "$out" 2>/dev/null || true
                success=1; break 2
            fi
            retry=$((retry+1)); sleep $((2**retry))
        done
    done
    rm -f "$tmp" 2>/dev/null || true
    [[ $success -eq 1 ]] || die "下载失败: $url"
    ok "下载完成: $(basename "$out") ($(du -h "$out" 2>/dev/null | cut -f1))"
}

#===============================================================================
# 服务管理
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
# 检测是否有其他 CF Tunnel
#===============================================================================
has_other_cf_tunnel() {
    local other=0
    if [[ "$(detect_init)" == "systemd" ]]; then
        for s in /etc/systemd/system/cloudflared*.service /lib/systemd/system/cloudflared*.service; do
            [[ -f "$s" ]] || continue
            grep -q "komari" "$s" 2>/dev/null && continue
            other=1; break
        done
    fi
    if [[ "$(detect_init)" == "openrc" ]]; then
        for s in /etc/init.d/cloudflared*; do
            [[ -f "$s" ]] || continue
            grep -q "komari" "$s" 2>/dev/null && continue
            other=1; break
        done
    fi
    if pgrep -f "cloudflared tunnel" | grep -qv -f <(pgrep -f "komari" 2>/dev/null || true) 2>/dev/null; then
        other=1
    fi
    return $other
}

#===============================================================================
# Token 管理
#===============================================================================
install_cf_wrapper() {
    mkdir -p "$CF_DIR"
    cat > "$CF_WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
CF_ENV="/opt/komari/cloudflared/.env"
CF_BIN="/usr/local/bin/cloudflared"
if [[ -f "$CF_ENV" ]]; then set -a; . "$CF_ENV"; set +a; fi
if [[ -z "${TUNNEL_TOKEN:-}" ]]; then echo "TUNNEL_TOKEN not set" >&2; exit 1; fi
exec "$CF_BIN" tunnel --no-autoupdate run
WRAPPER_EOF
    chmod 700 "$CF_WRAPPER"
}

save_tunnel_token() {
    local token="$1"
    mkdir -p "$CF_DIR"
    install_cf_wrapper
    (umask 077; printf 'TUNNEL_TOKEN=%s\n' "$token" > "$CF_ENV")
    chmod 600 "$CF_ENV"
    ok "Token 已安全保存"
}

#===============================================================================
# 凭证
#===============================================================================
get_credentials() {
    local log_file="$LOG_DIR/komari.log"
    [[ -f "$log_file" ]] || return 0
    grep "admin account created" "$log_file" 2>/dev/null | tail -1 | \
        sed -n 's/.*Username:\s*\([^,]*\).*Password:\s*\([^ ]*\).*/\1 \2/p' || true
}

show_credentials() {
    local creds user pass
    creds=$(get_credentials)
    [[ -z "$creds" ]] && { warn "未找到账号信息"; return; }
    user=$(echo "$creds" | awk '{print $1}')
    pass=$(echo "$creds" | awk '{print $2}')
    echo ""
    printf '%b\n' "${YELLOW}${BOLD}┌──────────────────────────────────────┐${NC}"
    printf '%b\n' "${YELLOW}${BOLD}│      初始账号信息（仅显示一次）      │${NC}"
    printf '%b\n' "${YELLOW}${BOLD}├──────────────────────────────────────┤${NC}"
    printf '%b\n' "${YELLOW}${BOLD}│  用户名: ${GREEN}${user}${YELLOW}                         │${NC}"
    printf '%b\n' "${YELLOW}${BOLD}│  密  码: ${GREEN}${pass}${YELLOW}                   │${NC}"
    printf '%b\n' "${YELLOW}${BOLD}│                                      │${NC}"
    printf '%b\n' "${YELLOW}${BOLD}│  ${RED}请立即登录修改密码！${YELLOW}                │${NC}"
    printf '%b\n' "${YELLOW}${BOLD}└──────────────────────────────────────┘${NC}"
    echo ""
}

#===============================================================================
# 服务文件生成
#===============================================================================
create_komari_svc() {
    local addr="$1" port="$2" init; init=$(detect_init)
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
                systemd-analyze verify "/etc/systemd/system/${APP_NAME}.service" >/dev/null 2>&1 || {
                    sed -i 's|StandardOutput=file:.*|StandardOutput=journal|' "/etc/systemd/system/${APP_NAME}.service"
                    sed -i 's|StandardError=file:.*|StandardError=journal|' "/etc/systemd/system/${APP_NAME}.service"
                }
            fi
            systemctl daemon-reload; systemctl enable "$APP_NAME" 2>/dev/null || true
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
depend() { need net; }
start_pre() { checkpath -d -m 0755 -o root:root "${LOG_DIR}" "${DATA_DIR}"; }
OPENRC_EOF
            chmod +x "/etc/init.d/${APP_NAME}"; rc-update add "$APP_NAME" default 2>/dev/null || true
            ;;
    esac
    ok "Komari 服务已创建 ($init)"
}

create_cf_svc() {
    local init; init=$(detect_init)
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
            systemctl daemon-reload; systemctl enable "$CF_NAME" 2>/dev/null || true
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
depend() { need net; after ${APP_NAME}; }
start_pre() { checkpath -d -m 0755 -o root:root "${LOG_DIR}" "${CF_DIR}"; }
OPENRC_EOF
            chmod +x "/etc/init.d/${CF_NAME}"; rc-update add "$CF_NAME" default 2>/dev/null || true
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
    command -v nc >/dev/null 2>&1 && nc -z -w "$to" "$host" "$port" 2>/dev/null && return 0
    curl -sf --connect-timeout "$to" "http://${host}:${port}" >/dev/null 2>&1 && return 0
    return 1
}

#===============================================================================
# 日志轮转（优化：按需清理）
#===============================================================================
rotate_logs() {
    mkdir -p "$LOG_DIR"
    for f in "$LOG_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        local sz ts; sz=$(_file_size "$f")
        [[ $sz -le $LOG_SIZE_MAX ]] && continue
        ts=$(date +%Y%m%d_%H%M%S); cp "$f" "${f}.${ts}"; _truncate "$f"
        (gzip "${f}.${ts}" 2>/dev/null || mv "${f}.${ts}" "${f}.${ts}.gz" 2>/dev/null) &

        # 按需清理：先统计文件数，超过阈值才执行清理
        local count; count=$(find "$LOG_DIR" -name "$(basename "$f").*.gz" -type f 2>/dev/null | wc -l)
        [[ $count -gt 5 ]] && find "$LOG_DIR" -name "$(basename "$f").*.gz" -type f 2>/dev/null | sort -r | awk 'NR>5' | xargs rm -f 2>/dev/null || true
    done
}

#===============================================================================
# 配置
#===============================================================================
load_config() {
    local f="$CONFIG_DIR/komari.conf"
    [[ -f "$f" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
            LISTEN_PORT=*)    LISTEN_PORT="${line#LISTEN_PORT=}" ;;
            LISTEN_ADDR=*)    LISTEN_ADDR="${line#LISTEN_ADDR=}" ;;
            DOMAIN=*)         DOMAIN="${line#DOMAIN=}" ;;
            CF_TUNNEL_NAME=*) CF_TUNNEL_NAME="${line#CF_TUNNEL_NAME=}" ;;
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
# 备份恢复
#===============================================================================
backup() {
    step "创建备份..."
    mkdir -p "$BACKUP_DIR"
    local ts out tmp; ts=$(date +%Y%m%d_%H%M%S)
    out="$BACKUP_DIR/backup-${ts}.tar.gz"; tmp="/tmp/komari_bak_$$"
    mkdir -p "$tmp"/{config,init,cf,data,wrapper}
    [[ -f "$CONFIG_DIR/komari.conf" ]] && cp "$CONFIG_DIR/komari.conf" "$tmp/config/"
    [[ -f "$CF_ENV" ]] && cp "$CF_ENV" "$tmp/cf/"
    [[ -f "$CF_WRAPPER" ]] && cp "$CF_WRAPPER" "$tmp/wrapper/"
    [[ -f "/etc/init.d/$APP_NAME" ]] && cp "/etc/init.d/$APP_NAME" "$tmp/init/"
    [[ -f "/etc/init.d/$CF_NAME" ]] && cp "/etc/init.d/$CF_NAME" "$tmp/init/"
    [[ -f "/etc/systemd/system/${APP_NAME}.service" ]] && cp "/etc/systemd/system/${APP_NAME}.service" "$tmp/init/"
    [[ -f "/etc/systemd/system/${CF_NAME}.service" ]] && cp "/etc/systemd/system/${CF_NAME}.service" "$tmp/init/"
    [[ -d "$DATA_DIR" ]] && cp -a "$DATA_DIR"/* "$tmp/data/" 2>/dev/null || true
    tar -czf "$out" -C "$tmp" . 2>/dev/null; rm -rf "$tmp"
    find "$BACKUP_DIR" -name 'backup-*.tar.gz' 2>/dev/null | sort -r | awk 'NR>7' | xargs rm -f 2>/dev/null || true
    ok "备份: $out ($(du -h "$out" 2>/dev/null | cut -f1))"
}

restore() {
    local f="$1"
    [[ -f "$f" ]] || { err "备份不存在"; return 1; }
    step "恢复: $f"
    backup; svc "$CF_NAME" stop 2>/dev/null || true; svc "$APP_NAME" stop 2>/dev/null || true
    local tmp="/tmp/komari_rst_$$"; mkdir -p "$tmp"
    tar -tzf "$f" 2>/dev/null | grep -qE '^/|\.\./' && { err "危险路径"; rm -rf "$tmp"; return 1; }
    tar -xzf "$f" -C "$tmp" 2>/dev/null || { err "解压失败"; rm -rf "$tmp"; return 1; }
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$CF_DIR"
    [[ "$(detect_init)" == systemd ]] && mkdir -p /etc/systemd/system
    [[ "$(detect_init)" == openrc ]] && mkdir -p /etc/init.d
    [[ -f "$tmp/config/komari.conf" ]] && cp "$tmp/config/komari.conf" "$CONFIG_DIR/"
    [[ -f "$tmp/cf/.env" ]] && { cp "$tmp/cf/.env" "$CF_ENV"; chmod 600 "$CF_ENV"; }
    [[ -f "$tmp/wrapper/run-cloudflared.sh" ]] && { cp "$tmp/wrapper/run-cloudflared.sh" "$CF_WRAPPER"; chmod 700 "$CF_WRAPPER"; }
    [[ -f "$tmp/init/komari" ]] && { cp "$tmp/init/komari" /etc/init.d/; chmod +x /etc/init.d/komari; }
    [[ -f "$tmp/init/cloudflared" ]] && { cp "$tmp/init/cloudflared" /etc/init.d/; chmod +x /etc/init.d/cloudflared; }
    [[ -f "$tmp/init/${APP_NAME}.service" ]] && cp "$tmp/init/${APP_NAME}.service" /etc/systemd/system/
    [[ -f "$tmp/init/${CF_NAME}.service" ]] && cp "$tmp/init/${CF_NAME}.service" /etc/systemd/system/
    [[ -d "$tmp/data" ]] && cp -a "$tmp/data"/* "$DATA_DIR/" 2>/dev/null || true
    rm -rf "$tmp"
    [[ "$(detect_init)" == systemd ]] && systemctl daemon-reload
    load_config; svc "$APP_NAME" start 2>/dev/null || true; svc "$CF_NAME" start 2>/dev/null || true
    ok "恢复完成"
}

restore_menu() {
    local list=() line
    [[ -d "$BACKUP_DIR" ]] || { err "无备份"; return 1; }
    while IFS= read -r line; do [[ -n "$line" ]] && list+=("$line"); done < <(find "$BACKUP_DIR" -name 'backup-*.tar.gz' 2>/dev/null | sort -r)
    [[ ${#list[@]} -eq 0 ]] && { err "无备份"; return 1; }
    for i in "${!list[@]}"; do printf " %d) %s (%s)\n" "$((i+1))" "$(basename "${list[$i]}")" "$(du -h "${list[$i]}" 2>/dev/null | cut -f1)"; done
    printf " 0) 取消\n"; read -rp "选择: " c
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
# 快速状态
#===============================================================================
quick_status() {
    local ks='✗' cs='✗'
    svc_ok "$APP_NAME" && ks="${GREEN}✓${NC}"
    svc_ok "$CF_NAME" && cs="${GREEN}✓${NC}"
    echo ""
    printf '  Komari: %b  Cloudflared: %b\n' "$ks" "$cs"
    printf '  端口: %s  域名: %s\n' "${LISTEN_PORT:-$PORT_DEFAULT}" "${DOMAIN:-未配置}"
    printf '  磁盘: %s\n' "$(du -sh "$INSTALL_DIR" 2>/dev/null | cut -f1 || echo 'N/A')"
    echo ""
}

#===============================================================================
# 系统自检
#===============================================================================
doctor() {
    printf '%b\n' "${BOLD}=== Komari 系统自检 ===${NC}"
    printf '版本: %s | OS: %s | Init: %s | Arch: %s\n' "$VERSION" "$(detect_os)" "$(detect_init)" "$(detect_arch)"
    printf 'IP: %s | 端口: %s\n\n' "$(detect_ip)" "${LISTEN_PORT:-$PORT_DEFAULT}"
    local issues=0
    [[ -x "$BIN" ]] && printf '  %b komari\n' "${GREEN}✓${NC}" || { printf '  %b komari: 未安装\n' "${RED}✗${NC}"; issues=$((issues+1)); }
    [[ -x "$CF_BIN" ]] && printf '  %b cloudflared\n' "${GREEN}✓${NC}" || printf '  %b cloudflared: 未安装\n' "${YELLOW}-${NC}"
    svc_ok "$APP_NAME" && printf '  %b komari: 运行中\n' "${GREEN}✓${NC}" || { printf '  %b komari: 未运行\n' "${RED}✗${NC}"; issues=$((issues+1)); }
    svc_ok "$CF_NAME" && printf '  %b cloudflared: 运行中\n' "${GREEN}✓${NC}" || printf '  %b cloudflared: 未运行\n' "${YELLOW}-${NC}"
    health_tcp 127.0.0.1 "${LISTEN_PORT:-$PORT_DEFAULT}" 3 && printf '  %b TCP 端口可达\n' "${GREEN}✓${NC}" || { printf '  %b TCP 不可达\n' "${RED}✗${NC}"; issues=$((issues+1)); }
    curl -s --connect-timeout 5 https://github.com >/dev/null 2>&1 && printf '  %b 外网连通\n' "${GREEN}✓${NC}" || printf '  %b 外网受限\n' "${YELLOW}!${NC}"
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
    mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$LOG_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "$CF_DIR" "$CACHE_DIR"
    local arch port addr; arch=$(detect_arch)
    info "系统: $(detect_os)/$(detect_init)/$arch"
    while true; do read -rp "端口 [$PORT_DEFAULT]: " port; port="${port:-$PORT_DEFAULT}"; port_free "$port" && break; warn "端口占用"; done
    LISTEN_PORT="$port"
    read -rp "监听地址 [$ADDR_DEFAULT]: " addr; addr="${addr:-$ADDR_DEFAULT}"; LISTEN_ADDR="$addr"
    step "下载组件..."
    local k_url="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${arch}"
    local cf_arch="$arch"; [[ "$cf_arch" == "riscv64" ]] && cf_arch="amd64"
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    download "$k_url" "$BIN"; download "$cf_url" "$CF_BIN"
    local token; read -rsp "CF Token (不可见): " token; echo
    [[ -n "$token" ]] || die "Token 不能为空"
    save_tunnel_token "$token"
    step "创建服务..."; create_komari_svc "$LISTEN_ADDR" "$LISTEN_PORT"; create_cf_svc
    step "启动..."; svc "$APP_NAME" start; sleep 3; svc "$CF_NAME" start; sleep 2
    health_tcp "$LISTEN_ADDR" "$LISTEN_PORT" 5 && ok "Komari 启动成功" || warn "Komari 可能未完全启动"
    svc_ok "$CF_NAME" && ok "Tunnel 启动成功" || warn "Tunnel 可能未完全启动"
    save_config; install_shortcut
    echo ""; ok "安装完成！http://${LISTEN_ADDR}:${LISTEN_PORT}"
    [[ -n "${DOMAIN:-}" ]] && info "公网: https://${DOMAIN}"
    show_credentials
    info "管理: komari [status|doctor|backup|restore|logs|update|password]"
}

#===============================================================================
# 更新
#===============================================================================
_replace_binary_safe() { local t="$1" n="$2" b="$3"; [[ -f "$t" ]] && cp -f "$t" "$b" 2>/dev/null || true; mv -f "$n" "$t"; chmod +x "$t" 2>/dev/null || true; }

update() {
    [[ -x "$BIN" ]] || { err "未安装"; return 1; }
    step "更新..."
    local arch cf_arch; arch=$(detect_arch); cf_arch="$arch"; [[ "$cf_arch" == "riscv64" ]] && cf_arch="amd64"
    local old_k old_c old_ks old_cs
    old_k="$(bin_version "$BIN")"; old_c="$(bin_version "$CF_BIN")"
    old_ks="$(short_fingerprint "$BIN")"; old_cs="$(short_fingerprint "$CF_BIN")"
    backup; svc "$CF_NAME" stop 2>/dev/null || true; svc "$APP_NAME" stop 2>/dev/null || true
    local nb="${INSTALL_DIR}/.komari.new.$$" ncb="/usr/local/bin/.cloudflared.new.$$"
    local bakb="${BIN}.bak.$$" bakc="${CF_BIN}.bak.$$" rollback=0
    local ku="https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${arch}"
    local cu="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
    download "$ku" "$nb" || rollback=1; download "$cu" "$ncb" || rollback=1
    if [[ $rollback -eq 0 ]]; then
        local nk nc nks ncs; nk="$(bin_version "$nb")"; nc="$(bin_version "$ncb")"
        nks="$(short_fingerprint "$nb")"; ncs="$(short_fingerprint "$ncb")"
        info "Komari: ${old_k:-?} -> ${nk:-?}"; info "CF: ${old_c:-?} -> ${nc:-?}"
        [[ "${old_k:-}" == "${nk:-}" && "${old_ks:-}" == "${nks:-}" ]] && { info "Komari 无变化"; rm -f "$nb"; } || _replace_binary_safe "$BIN" "$nb" "$bakb"
        [[ "${old_c:-}" == "${nc:-}" && "${old_cs:-}" == "${ncs:-}" ]] && { info "CF 无变化"; rm -f "$ncb"; } || _replace_binary_safe "$CF_BIN" "$ncb" "$bakc"
    fi
    [[ ! -x "$BIN" || ! -x "$CF_BIN" ]] && { rollback=1; err "二进制不可执行"; }
    [[ $rollback -eq 1 ]] && { [[ -f "$bakb" ]] && mv -f "$bakb" "$BIN"; [[ -f "$bakc" ]] && mv -f "$bakc" "$CF_BIN"; }
    svc "$APP_NAME" start 2>/dev/null || true; svc "$CF_NAME" start 2>/dev/null || true; sleep 2
    if [[ $rollback -eq 0 ]] && health_tcp "${LISTEN_ADDR:-$ADDR_DEFAULT}" "${LISTEN_PORT:-$PORT_DEFAULT}" 5; then
        ok "更新完成"; rm -f "$bakb" "$bakc" 2>/dev/null || true
    else
        warn "回滚..."; svc "$CF_NAME" stop 2>/dev/null; svc "$APP_NAME" stop 2>/dev/null
        [[ -f "$bakb" ]] && mv -f "$bakb" "$BIN"; [[ -f "$bakc" ]] && mv -f "$bakc" "$CF_BIN"
        svc "$APP_NAME" start; svc "$CF_NAME" start; err "已回滚"
    fi
    rm -f "$nb" "$ncb" 2>/dev/null || true
}

#===============================================================================
# 智能卸载
#===============================================================================
uninstall() {
    printf '%b\n' "${RED}${BOLD}=== 卸载 Komari ===${NC}"
    read -rp "输入 DELETE 确认: " c
    [[ "$c" != "DELETE" ]] && { info "已取消"; return 0; }

    local other_cf=0
    if has_other_cf_tunnel; then
        other_cf=1
        warn "检测到其他 Cloudflare Tunnel 在使用"
        info "将保留 /usr/local/bin/cloudflared 和服务文件"
    fi

    for s in "$CF_NAME" "$APP_NAME"; do svc "$s" stop 2>/dev/null || true; done

    case "$(detect_init)" in
        systemd)
            systemctl disable "$APP_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/${APP_NAME}.service"
            [[ $other_cf -eq 0 ]] && { systemctl disable "$CF_NAME" 2>/dev/null || true; rm -f "/etc/systemd/system/${CF_NAME}.service"; }
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del "$APP_NAME" 2>/dev/null || true
            rm -f "/etc/init.d/${APP_NAME}"
            [[ $other_cf -eq 0 ]] && { rc-update del "$CF_NAME" 2>/dev/null || true; rm -f "/etc/init.d/${CF_NAME}"; }
            ;;
    esac

    rm -f "$BIN"
    if [[ $other_cf -eq 0 ]]; then
        rm -f "$CF_BIN" "$CF_WRAPPER"
    else
        info "保留 cloudflared 二进制（被其他服务使用）"
    fi
    rm -f /usr/local/bin/komari

    read -rp "删除数据目录? [y/N]: " d
    if [[ "$d" =~ ^[Yy]$ ]]; then
        [[ $other_cf -eq 1 ]] && warn "将保留 cloudflared 相关配置"
        safe_rm_rf "$INSTALL_DIR"
    else
        info "保留 $INSTALL_DIR"
    fi
    ok "卸载完成"
}

#===============================================================================
# 交互菜单（响应式）
#===============================================================================
menu() {
    while true; do
        clear 2>/dev/null || true
        local wide; wide=$(is_wide_screen && echo 1 || echo 0)

        if [[ $wide -eq 1 ]]; then
            printf '%b\n' "${CYAN}╔══════════════════════════════════════════════╗${NC}"
            printf '%b\n' "${CYAN}║     Komari + CF Tunnel Manager v${VERSION}        ║${NC}"
            printf '%b\n' "${CYAN}╚══════════════════════════════════════════════╝${NC}"
            local ks='✗' cs='✗'
            svc_ok "$APP_NAME" && ks="${GREEN}✓${NC}"
            svc_ok "$CF_NAME" && cs="${GREEN}✓${NC}"
            printf '\n  Komari[%b]  CF[%b]  |  端口: %s  |  %s\n\n' \
                "$ks" "$cs" "${LISTEN_PORT:-$PORT_DEFAULT}" "${DOMAIN:-未配置域名}"
            printf '  %-20s %-20s %-20s\n' '1) 安装' '5) 停止' '9) 备份'
            printf '  %-20s %-20s %-20s\n' '2) 更新' '6) 重启' '10) 恢复'
            printf '  %-20s %-20s %-20s\n' '3) 卸载' '7) 日志' '11) 自检'
            printf '  %-20s %-20s %-20s\n' '4) 启动' '8) 状态' '12) 配置'
            printf '  %-20s %-20s\n' '13) 密码' '0) 退出'
        else
            printf '%b\n' "${CYAN}╔══════════════════╗${NC}"
            printf '%b\n' "${CYAN}║ Komari Mgr v${VERSION} ║${NC}"
            printf '%b\n' "${CYAN}╚══════════════════╝${NC}"
            local ks='✗' cs='✗'
            svc_ok "$APP_NAME" && ks="${GREEN}✓${NC}"
            svc_ok "$CF_NAME" && cs="${GREEN}✓${NC}"
            printf '\nKomari[%b] CF[%b]\n' "$ks" "$cs"
            printf '端口:%s\n\n' "${LISTEN_PORT:-$PORT_DEFAULT}"
            printf '1)安装  2)更新  3)卸载\n'
            printf '4)启动  5)停止  6)重启\n'
            printf '7)日志  8)状态  9)备份\n'
            printf '10)恢复 11)自检 12)配置\n'
            printf '13)密码 0)退出\n'
        fi

        printf '\n'
        read -rp "> " ch
        case "${ch:-0}" in
            1) install ;;    2) update ;;    3) uninstall ;;
            4) svc "$APP_NAME" start; svc "$CF_NAME" start 2>/dev/null || true ;;
            5) svc "$CF_NAME" stop 2>/dev/null; svc "$APP_NAME" stop ;;
            6) svc "$APP_NAME" restart; svc "$CF_NAME" restart 2>/dev/null || true ;;
            7) (trap '' INT; tail -f "$LOG_DIR/komari.log" 2>/dev/null) || err "日志不可用" ;;
            8) quick_status ;;
            9) backup ;;
            10) restore_menu ;;
            11) doctor ;;
            12)
                local p d
                read -rp "新端口 [$PORT_DEFAULT]: " p; p="${p:-$PORT_DEFAULT}"
                port_free "$p" && { LISTEN_PORT="$p"; save_config; svc "$APP_NAME" restart; } || warn "端口占用"
                read -rp "域名: " d; [[ -n "$d" ]] && { DOMAIN="$d"; save_config; }
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
  install    安装    uninstall  卸载    update    更新
  start      启动    stop       停止    restart   重启
  status     状态    doctor     自检    logs      日志
  backup     备份    restore    恢复    password  密码
  menu       菜单

示例: komari install | komari status | komari password
EOF
}

#===============================================================================
# 入口
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
        status)     quick_status ;;
        doctor)     doctor ;;
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
