#!/usr/bin/env bash
#===============================================================================
# UUFW Firewall Manager v3.0.6
# Change log:
#   - [v3.0.6] 修复 sanitize_csv_ports 数组定义和追加语法，防止 set -e 下解析失效
#   - [v3.0.6] add_port 增加重复端口检查，避免配置冗余
#   - [v3.0.6] load_config 修复 read 循环，支持末行无换行符的配置文件读取
#   - [v3.0.6] 增强 download_cf_ips 在 set -e 下对 grep 返回值的容错性
#   - [v3.0.6] 优化 parse_extra_ports 过滤逻辑，确保状态显示和删除列表准确
#   - [v3.0.5] 修复 download_cf_ips 中 set -e 下 CF API 500 导致脚本退出的问题
#   - Alpine / Debian 兼容，支持纯 IPv6 环境
#===============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

#===============================================================================
# Constants
#===============================================================================
readonly VERSION="3.0.6"
readonly SCRIPT_NAME="uufw"
readonly SSH_PORT_DEFAULT="22"
readonly CF_IPV4_URL="https://www.cloudflare.com/ips-v4/"
readonly CF_IPV6_URL="https://www.cloudflare.com/ips-v6/"
readonly DATA_DIR="/opt/uufw"
readonly BACKUP_DIR="/opt/uufw/backups"
readonly CONFIG_FILE="/opt/uufw/firewall.conf"
readonly LOCK_FILE="/run/uufw.lock"
readonly LOCK_DIR="/run/uufw.lock.d"
readonly STATE_DIR="/run/uufw"
readonly LAST_NFT_FILE="/opt/uufw/uufw.nft"
readonly LAST_V4_RULES="/opt/uufw/iptables-v4.rules"
readonly LAST_V6_RULES="/opt/uufw/iptables-v6.rules"
readonly NFT_TABLE_FAMILY="inet"
readonly NFT_TABLE_NAME="UUFW"
readonly NFT_CHAIN_INPUT="input"
readonly NFT_CHAIN_FORWARD="forward"
readonly NFT_CHAIN_OUTPUT="output"

readonly DEFAULT_CF_PROTECTED_PORTS="80,443"
readonly DEFAULT_LOG_RATE="5/second"

#===============================================================================
# Globals
#===============================================================================
SSH_PORT="$SSH_PORT_DEFAULT"
EXTRA_PORTS=""
CF_ONLY="0"
CF_PROTECTED_PORTS="$DEFAULT_CF_PROTECTED_PORTS"
ENABLE_LOGGING="1"
LOG_RATE="$DEFAULT_LOG_RATE"

OS_TYPE="unknown"
FW_TYPE="none"
LOCK_METHOD=""

TMP_FILES=()

#===============================================================================
# Colors / Logging
#===============================================================================
if [[ -t 1 ]]; then
    RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
    CYAN='\033[36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

ok()   { printf '%b\n' "${GREEN}[✓]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[!]${NC} $*" >&2; }
err()  { printf '%b\n' "${RED}[✗]${NC} $*" >&2; }
step() { printf '%b\n' "${CYAN}[▶]${NC} ${BOLD}$*${NC}"; }
info() { printf '%s\n' "[$(date +%H:%M:%S)] INFO: $*"; }

cleanup() {
    local f
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f -- "$f" || true
    done
    if [[ "${LOCK_METHOD:-}" == "mkdir" ]]; then
        rmdir -- "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

on_err() {
    local line=$1 cmd=$2
    err "脚本执行失败: line $line, command: $cmd"
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

#===============================================================================
# Utilities
#===============================================================================
need_root() {
    [[ "$(id -u)" -eq 0 ]] || { err "需要 root 权限"; exit 1; }
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

acquire_lock() {
    mkdir -p /run 2>/dev/null || true
    if has_cmd flock; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            err "检测到另一个 uufw 实例正在运行"
            exit 1
        fi
        LOCK_METHOD="flock"
    else
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            err "检测到另一个 uufw 实例正在运行"
            exit 1
        fi
        LOCK_METHOD="mkdir"
        warn "flock 不可用，已使用目录锁回退"
    fi
}

mktemp_file() {
    local t
    t=$(mktemp 2>/dev/null || mktemp -t uufw)
    TMP_FILES+=("$t")
    printf '%s\n' "$t"
}

trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

normalize_bool() {
    case "$(printf '%s' "${1:-0}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) printf '1' ;;
        *) printf '0' ;;
    esac
}

validate_port_number() {
    local p=$1
    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

validate_proto() {
    [[ "$1" == "tcp" || "$1" == "udp" ]]
}

validate_log_rate() {
    [[ "$1" =~ ^[0-9]+/(second|minute|hour|day)$ ]]
}

sanitize_csv_ports() {
    local input=${1:-}
    local -a out=() # Fix: explicitly declare as array
    local item proto port
    [[ -z "$input" ]] && { printf '%s' ""; return 0; }
    while IFS= read -r item; do
        item=$(trim "$item")
        [[ -z "$item" ]] && continue
        proto=${item%%:*}
        port=${item##*:}
        proto=$(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]')
        validate_proto "$proto" || { err "无效协议: $proto"; return 1; }
        validate_port_number "$port" || { err "无效端口: $port"; return 1; }
        out+=("${proto}:${port}") # Fix: standardized array append
    done < <(printf '%s' "$input" | tr ',' '\n')
    (IFS=,; printf '%s' "${out[*]:-}")
}

sanitize_port_list() {
    local input=${1:-}
    local out=() item
    [[ -z "$input" ]] && { printf '%s' ""; return 0; }
    while IFS= read -r item; do
        item=$(trim "$item")
        [[ -z "$item" ]] && continue
        validate_port_number "$item" || { err "无效端口: $item"; return 1; }
        out+=("$item")
    done < <(printf '%s' "$input" | tr ' ,' '\n')
    (IFS=,; printf '%s' "${out[*]:-}")
}

parse_extra_ports() {
    [[ -z "${EXTRA_PORTS:-}" ]] && return 0
    local item
    while IFS= read -r item; do
        item=$(trim "$item") # Fix: trim whitespace for display
        [[ -n "$item" ]] && printf '%s\n' "$item" # Fix: filter empty lines
    done < <(printf '%s' "${EXTRA_PORTS}" | tr ',' '\n')
}

#===============================================================================
# Detection
#===============================================================================
detect_os() {
    [[ -f /etc/alpine-release ]] && { echo alpine; return; }
    [[ -f /etc/debian_version ]] && { echo debian; return; }
    echo unknown
}

detect_firewall_type() {
    if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        echo ufw
    elif has_cmd nft; then
        echo nftables
    elif has_cmd iptables; then
        echo iptables
    else
        echo none
    fi
}

detect_ip() {
    if has_cmd ip; then
        ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1 || true
    fi
}

ssh_listener_present() {
    local port=${1:-$SSH_PORT_DEFAULT}
    if ! has_cmd ss; then
        return 0
    fi
    ss -tlnH 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
}

ensure_ssh_safe() {
    local port=${SSH_PORT:-$SSH_PORT_DEFAULT}
    if ! validate_port_number "$port"; then
        err "SSH 端口非法: $port"
        return 1
    fi
    if has_cmd ss && ! ssh_listener_present "$port"; then
        warn "未检测到本机正在监听的 SSH 端口 $port"
        read -r -p "仍然继续应用规则? [y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

#===============================================================================
# Config
#===============================================================================
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    # Fix: Ensure last line is read even if no newline
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        k=$(trim "${k:-}")
        v=$(trim "${v:-}")
        [[ -z "$k" || "$k" == \#* ]] && continue
        case "$k" in
            SSH_PORT) SSH_PORT="$v" ;;
            EXTRA_PORTS) EXTRA_PORTS="$v" ;;
            CF_ONLY) CF_ONLY="$v" ;;
            CF_PROTECTED_PORTS) CF_PROTECTED_PORTS="$v" ;;
            ENABLE_LOGGING) ENABLE_LOGGING="$v" ;;
            LOG_RATE) LOG_RATE="$v" ;;
        esac
    done < "$CONFIG_FILE"

    SSH_PORT="$(trim "${SSH_PORT:-$SSH_PORT_DEFAULT}")"
    if ! validate_port_number "$SSH_PORT"; then
        warn "配置中的 SSH_PORT 非法，已回退到默认值"
        SSH_PORT="$SSH_PORT_DEFAULT"
    fi

    if ! EXTRA_PORTS="$(sanitize_csv_ports "${EXTRA_PORTS:-}")"; then
        warn "配置中的 EXTRA_PORTS 非法，已清空"
        EXTRA_PORTS=""
    fi

    CF_ONLY="$(normalize_bool "${CF_ONLY:-0}")"

    if ! CF_PROTECTED_PORTS="$(sanitize_port_list "${CF_PROTECTED_PORTS:-$DEFAULT_CF_PROTECTED_PORTS}")"; then
        warn "配置中的 CF_PROTECTED_PORTS 非法，已回退到默认值"
        CF_PROTECTED_PORTS="$DEFAULT_CF_PROTECTED_PORTS"
    fi
    [[ -n "$CF_PROTECTED_PORTS" ]] || CF_PROTECTED_PORTS="$DEFAULT_CF_PROTECTED_PORTS"

    ENABLE_LOGGING="$(normalize_bool "${ENABLE_LOGGING:-1}")"

    LOG_RATE="$(trim "${LOG_RATE:-$DEFAULT_LOG_RATE}")"
    if ! validate_log_rate "$LOG_RATE"; then
        warn "配置中的 LOG_RATE 非法，已回退到默认值"
        LOG_RATE="$DEFAULT_LOG_RATE"
    fi
}

save_config() {
    mkdir -p "$DATA_DIR"
    cat > "$CONFIG_FILE" <<EOF_CONF
SSH_PORT=${SSH_PORT:-$SSH_PORT_DEFAULT}
EXTRA_PORTS=${EXTRA_PORTS:-}
CF_ONLY=${CF_ONLY:-0}
CF_PROTECTED_PORTS=${CF_PROTECTED_PORTS:-$DEFAULT_CF_PROTECTED_PORTS}
ENABLE_LOGGING=${ENABLE_LOGGING:-1}
LOG_RATE=${LOG_RATE:-$DEFAULT_LOG_RATE}
EOF_CONF
}

#===============================================================================
# Downloads
#===============================================================================
download_url() {
    local url=$1 out=$2
    if has_cmd curl; then
        curl -fsSL --connect-timeout 10 --max-time 30 -o "$out" "$url" 2>/dev/null
    elif has_cmd wget; then
        wget -qO "$out" "$url" 2>/dev/null
    else
        return 127
    fi
}

write_cf_default_v4() {
    cat > "$1" <<'EOF_V4'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
EOF_V4
}

write_cf_default_v6() {
    cat > "$1" <<'EOF_V6'
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
EOF_V6
}

download_cf_ips() {
    mkdir -p "$DATA_DIR"
    local v4="$DATA_DIR/cf-ipv4.txt"
    local v6="$DATA_DIR/cf-ipv6.txt"
    local updated=0 tmp filtered download_ok=0

    tmp="$(mktemp_file)"
    filtered="$(mktemp_file)"
    if download_url "$CF_IPV4_URL" "$tmp" && [[ -s "$tmp" ]]; then
        # Fix: ensure grep doesn't trip set -e if no match
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$tmp" > "$filtered" 2>/dev/null || true
        if [[ -s "$filtered" ]]; then
            mv -f "$filtered" "$v4"
            updated=1
            download_ok=1
        fi
    fi
    if [[ $download_ok -eq 0 ]]; then
        if [[ ! -s "$v4" ]]; then
            write_cf_default_v4 "$v4"
        fi
    fi

    download_ok=0
    tmp="$(mktemp_file)"
    filtered="$(mktemp_file)"
    if download_url "$CF_IPV6_URL" "$tmp" && [[ -s "$tmp" ]]; then
        # Fix: ensure grep doesn't trip set -e if no match
        grep -E '^[0-9A-Fa-f:]+/[0-9]+$' "$tmp" > "$filtered" 2>/dev/null || true
        if [[ -s "$filtered" ]]; then
            mv -f "$filtered" "$v6"
            updated=1
            download_ok=1
        fi
    fi
    if [[ $download_ok -eq 0 ]]; then
        if [[ ! -s "$v6" ]]; then
            write_cf_default_v6 "$v6"
        fi
    fi

    if [[ $updated -eq 1 ]]; then
        info "CF IP 列表已更新"
    else
        info "CF IP 列表使用本地缓存"
    fi
    return 0
}

#===============================================================================
# Backup
#===============================================================================
backup_rules() {
    mkdir -p "$BACKUP_DIR"
    local ts fw_type
    ts=$(date +%Y%m%d_%H%M%S)
    fw_type=$(detect_firewall_type)

    case "$fw_type" in
        nftables)
            if has_cmd nft; then
                nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" > "$BACKUP_DIR/nft-${ts}.txt" 2>/dev/null || true
                ok "备份完成: nft-${ts}.txt"
            fi
            ;;
        iptables)
            has_cmd iptables-save && iptables-save > "$BACKUP_DIR/iptables-v4-${ts}.rules" 2>/dev/null || true
            has_cmd ip6tables-save && ip6tables-save > "$BACKUP_DIR/iptables-v6-${ts}.rules" 2>/dev/null || true
            ok "备份完成"
            ;;
        ufw)
            has_cmd ufw && ufw status verbose > "$BACKUP_DIR/ufw-${ts}.txt" 2>/dev/null || true
            ok "备份完成"
            ;;
        *)
            warn "无法识别防火墙类型，未执行备份"
            ;;
    esac

    find "$BACKUP_DIR" -type f 2>/dev/null | sort -r | tail -n +11 | xargs rm -f 2>/dev/null || true
}

#===============================================================================
# Rule builders
#===============================================================================
read_ip_list_file() {
    local file=$1
    [[ -f "$file" ]] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/[[:space:]]//g'
}

emit_nft_set() {
    local set_name=$1 type_name=$2 file=$3
    local first=1 item
    printf '    set %s {\n' "$set_name"
    printf '        type %s; flags interval;\n' "$type_name"
    printf '        elements = {\n'
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        if [[ $first -eq 0 ]]; then
            printf ',\n'
        fi
        printf '            %s' "$item"
        first=0
    done < <(read_ip_list_file "$file")
    if [[ $first -eq 1 ]]; then
        if [[ "$type_name" == "ipv4_addr" ]]; then
            printf '            0.0.0.0/32\n        }\n'
        else
            printf '            ::1/128\n        }\n'
        fi
    else
        printf '\n        }\n'
    fi
    printf '    }\n\n'
}

emit_iptables_cf_rules() {
    local file=$1 port_list=$2
    local cidr port
    [[ -f "$file" ]] || return 0
    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        while IFS= read -r port; do
            [[ -z "$port" ]] && continue
            printf '-A INPUT -s %s -p tcp --dport %s -j ACCEPT\n' "$cidr" "$port"
        done < <(printf '%s\n' "$port_list" | tr ',' '\n')
    done < <(read_ip_list_file "$file")
}

build_nft_rules() {
    local nft_conf=$1
    local cf4_file="$DATA_DIR/cf-ipv4.txt"
    local cf6_file="$DATA_DIR/cf-ipv6.txt"
    local sp cf_port_list
    sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"
    cf_port_list="$(sanitize_port_list "${CF_PROTECTED_PORTS:-$DEFAULT_CF_PROTECTED_PORTS}")"

    {
        printf '#!/usr/sbin/nft -f\n'
        printf '# Generated by UUFW v%s on %s\n\n' "$VERSION" "$(date)"

        printf 'table %s %s {\n\n' "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME"
        emit_nft_set "cloudflare4" "ipv4_addr" "$cf4_file"
        emit_nft_set "cloudflare6" "ipv6_addr" "$cf6_file"

        printf '    chain %s {\n' "$NFT_CHAIN_INPUT"
        printf '        type filter hook input priority 0; policy drop;\n\n'
        printf '        iif lo accept\n'
        printf '        ct state invalid drop\n'
        printf '        ct state established,related accept\n'
        printf '        tcp dport %s accept\n' "$sp"
        printf '        ip protocol icmp accept\n'
        printf '        icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept\n'
        printf '        udp dport 546 accept\n'

        if [[ "${CF_ONLY:-0}" == "1" ]]; then
            while IFS= read -r port; do
                [[ -z "$port" ]] && continue
                printf '        ip saddr @cloudflare4 tcp dport %s accept\n' "$port"
                printf '        ip6 saddr @cloudflare6 tcp dport %s accept\n' "$port"
            done < <(printf '%s\n' "$cf_port_list" | tr ',' '\n')
        fi

        while IFS= read -r extra; do
            [[ -z "$extra" ]] && continue
            local proto=${extra%%:*} port=${extra##*:}
            if [[ "$proto" == "tcp" ]]; then
                if [[ "${CF_ONLY:-0}" == "1" ]] && [[ ",$cf_port_list," == *",${port},"* ]]; then
                    :
                else
                    printf '        tcp dport %s accept\n' "$port"
                fi
            else
                printf '        udp dport %s accept\n' "$port"
            fi
        done < <(parse_extra_ports)

        if [[ "${ENABLE_LOGGING:-1}" == "1" ]]; then
            printf '        limit rate %s log prefix "uufw-blocked: "\n' "$LOG_RATE"
            printf '        drop\n'
        else
            printf '        drop\n'
        fi

        printf '    }\n\n'
        printf '    chain %s {\n' "$NFT_CHAIN_FORWARD"
        printf '        type filter hook forward priority 0; policy drop;\n'
        printf '    }\n\n'
        printf '    chain %s {\n' "$NFT_CHAIN_OUTPUT"
        printf '        type filter hook output priority 0; policy accept;\n'
        printf '    }\n'
        printf '}\n'
    } > "$nft_conf"
}

build_iptables_restore_files() {
    local v4=$1 v6=$2
    local sp cf_port_list cf4_file cf6_file
    sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"
    cf_port_list="$(sanitize_port_list "${CF_PROTECTED_PORTS:-$DEFAULT_CF_PROTECTED_PORTS}")"
    cf4_file="$DATA_DIR/cf-ipv4.txt"
    cf6_file="$DATA_DIR/cf-ipv6.txt"

    {
        printf '*filter\n'
        printf ':INPUT DROP [0:0]\n'
        printf ':FORWARD DROP [0:0]\n'
        printf ':OUTPUT ACCEPT [0:0]\n'
        printf '-A INPUT -i lo -j ACCEPT\n'
        printf '-A INPUT -m conntrack --ctstate INVALID -j DROP\n'
        printf '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
        printf '-A INPUT -p tcp --dport %s -j ACCEPT\n' "$sp"
        printf '-A INPUT -p icmp -j ACCEPT\n'

        if [[ "${CF_ONLY:-0}" == "1" ]]; then
            emit_iptables_cf_rules "$cf4_file" "$cf_port_list"
        fi

        while IFS= read -r extra; do
            [[ -z "$extra" ]] && continue
            local proto=${extra%%:*} port=${extra##*:}
            if [[ "$proto" == "tcp" ]]; then
                if [[ "${CF_ONLY:-0}" == "1" ]] && [[ ",$cf_port_list," == *",${port},"* ]]; then
                    :
                else
                    printf '-A INPUT -p tcp --dport %s -j ACCEPT\n' "$port"
                fi
            elif [[ "$proto" == "udp" ]]; then
                printf '-A INPUT -p udp --dport %s -j ACCEPT\n' "$port"
            fi
        done < <(parse_extra_ports)
        printf 'COMMIT\n'
    } > "$v4"

    {
        printf '*filter\n'
        printf ':INPUT DROP [0:0]\n'
        printf ':FORWARD DROP [0:0]\n'
        printf ':OUTPUT ACCEPT [0:0]\n'
        printf '-A INPUT -i lo -j ACCEPT\n'
        printf '-A INPUT -m conntrack --ctstate INVALID -j DROP\n'
        printf '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
        printf '-A INPUT -p tcp --dport %s -j ACCEPT\n' "$sp"
        printf '-A INPUT -p icmpv6 -j ACCEPT\n'
        printf '-A INPUT -p udp -m udp --dport 546 -j ACCEPT\n'

        if [[ "${CF_ONLY:-0}" == "1" ]]; then
            emit_iptables_cf_rules "$cf6_file" "$cf_port_list"
        fi

        while IFS= read -r extra; do
            [[ -z "$extra" ]] && continue
            local proto=${extra%%:*} port=${extra##*:}
            if [[ "$proto" == "tcp" ]]; then
                if [[ "${CF_ONLY:-0}" == "1" ]] && [[ ",$cf_port_list," == *",${port},"* ]]; then
                    :
                else
                    printf '-A INPUT -p tcp --dport %s -j ACCEPT\n' "$port"
                fi
            elif [[ "$proto" == "udp" ]]; then
                printf '-A INPUT -p udp --dport %s -j ACCEPT\n' "$port"
            fi
        done < <(parse_extra_ports)
        printf 'COMMIT\n'
    } > "$v6"
}

#===============================================================================
# Apply rules
#===============================================================================
restore_nft_backup() {
    local backup_file=$1
    has_cmd nft || return 0
    [[ -n "$backup_file" && -s "$backup_file" ]] || return 0
    nft -f "$backup_file" >/dev/null 2>&1 || true
}

restore_iptables_backup() {
    local v4_bak=$1 v6_bak=$2
    if has_cmd iptables-restore && [[ -n "$v4_bak" && -s "$v4_bak" ]]; then
        iptables-restore < "$v4_bak" >/dev/null 2>&1 || true
    fi
    if has_cmd ip6tables-restore && [[ -n "$v6_bak" && -s "$v6_bak" ]]; then
        ip6tables-restore < "$v6_bak" >/dev/null 2>&1 || true
    fi
}

apply_nftables() {
    has_cmd nft || { err "未找到 nft"; return 1; }
    step "应用 nftables 规则..."
    backup_rules
    mkdir -p "$DATA_DIR"
    download_cf_ips

    if ! ensure_ssh_safe; then
        return 1
    fi

    local nft_conf current_backup prev_table_exists
    nft_conf="$(mktemp_file)"
    current_backup=""
    prev_table_exists=0

    build_nft_rules "$nft_conf"

    if ! nft -c -f "$nft_conf" >/dev/null 2>&1; then
        err "nftables 语法检查失败"
        warn "请检查生成文件: $nft_conf"
        return 1
    fi

    if nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1; then
        current_backup="$(mktemp_file)"
        nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" > "$current_backup" 2>/dev/null || current_backup=""
        prev_table_exists=1
    fi

    if [[ "$prev_table_exists" -eq 1 ]]; then
        nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
    fi

    if ! nft -f "$nft_conf" >/dev/null 2>&1; then
        err "nftables 应用失败"
        warn "正在尝试恢复旧规则..."
        if [[ "$prev_table_exists" -eq 1 && -n "$current_backup" && -s "$current_backup" ]]; then
            restore_nft_backup "$current_backup"
        fi
        return 1
    fi

    if [[ -f /etc/nftables.conf ]]; then
        mkdir -p /etc/nftables
        cp -f "$nft_conf" /etc/nftables/uufw.nft
        if ! grep -Eq 'include[[:space:]]+["'\'']/etc/nftables/uufw\.nft["'\'']' /etc/nftables.conf; then
            printf '\ninclude "/etc/nftables/uufw.nft"\n' >> /etc/nftables.conf
        fi
    elif [[ -d /etc/nftables.d ]]; then
        cp -f "$nft_conf" /etc/nftables.d/uufw.nft
    else
        mkdir -p /etc/nftables
        cp -f "$nft_conf" /etc/nftables/uufw.nft
    fi

    if [[ "$OS_TYPE" == alpine ]]; then
        if has_cmd rc-update; then rc-update add nftables >/dev/null 2>&1 || true; fi
        if has_cmd rc-service; then rc-service nftables save >/dev/null 2>&1 || true; fi
    fi

    cp -f "$nft_conf" "$LAST_NFT_FILE" 2>/dev/null || true
    ok "nftables 规则已应用并持久化"
}

apply_iptables() {
    has_cmd iptables || { err "未找到 iptables"; return 1; }
    step "应用 iptables 规则..."
    backup_rules
    mkdir -p "$DATA_DIR"
    download_cf_ips

    if ! ensure_ssh_safe; then
        return 1
    fi

    local v4 v6 prev4 prev6 have_prev4=0 have_prev6=0
    v4="$(mktemp_file)"
    v6="$(mktemp_file)"
    prev4=""
    prev6=""

    build_iptables_restore_files "$v4" "$v6"

    if has_cmd iptables-save; then
        prev4="$(mktemp_file)"
        iptables-save > "$prev4" 2>/dev/null || prev4=""
        [[ -n "$prev4" && -s "$prev4" ]] && have_prev4=1
    fi
    if has_cmd ip6tables-save; then
        prev6="$(mktemp_file)"
        ip6tables-save > "$prev6" 2>/dev/null || prev6=""
        [[ -n "$prev6" && -s "$prev6" ]] && have_prev6=1
    fi

    if ! has_cmd iptables-restore; then
        err "缺少 iptables-restore"
        return 1
    fi

    if ! iptables-restore < "$v4" >/dev/null 2>&1; then
        err "iptables v4 应用失败"
        warn "正在尝试恢复旧规则..."
        [[ $have_prev4 -eq 1 ]] && restore_iptables_backup "$prev4" ""
        return 1
    fi

    if has_cmd ip6tables-restore; then
        if ! ip6tables-restore < "$v6" >/dev/null 2>&1; then
            err "ip6tables 应用失败"
            warn "正在尝试恢复旧规则..."
            [[ $have_prev4 -eq 1 ]] && restore_iptables_backup "$prev4" "$prev6"
            return 1
        fi
    fi

    if has_cmd iptables-save; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        has_cmd ip6tables-save && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi

    cp -f "$v4" "$LAST_V4_RULES" 2>/dev/null || true
    cp -f "$v6" "$LAST_V6_RULES" 2>/dev/null || true
    ok "iptables 规则已应用并持久化"
}

apply_current() {
    case "$FW_TYPE" in
        nftables) apply_nftables ;;
        iptables) apply_iptables ;;
        ufw)
            warn "检测到 ufw 正在运行"
            read -r -p "一键禁用 ufw 并继续? [Y/n]: " ans
            ans=${ans:-Y}
            if [[ ! "$ans" =~ ^[Nn]$ ]]; then
                ufw disable >/dev/null 2>&1 || true
                ok "ufw 已禁用，切换至 iptables"
                FW_TYPE="iptables"
                apply_iptables
            else
                warn "请手动处理 ufw 后重试"
                return 1
            fi
            ;;
        *)
            err "未检测到可用防火墙组件"
            return 1
            ;;
    esac
}

#===============================================================================
# Install deps
#===============================================================================
install_deps() {
    if [[ "$FW_TYPE" == "ufw" ]]; then
        warn "检测到 ufw 正在运行"
        read -r -p "禁用 ufw 并继续? [Y/n]: " ans
        ans=${ans:-Y}
        if [[ ! "$ans" =~ ^[Nn]$ ]]; then
            ufw disable >/dev/null 2>&1 || true
            ok "ufw 已禁用"
        else
            warn "已取消"
            return 1
        fi
    fi

    if ! has_cmd nft && ! has_cmd iptables; then
        step "安装防火墙组件..."
        case "$OS_TYPE" in
            alpine)
                apk add --no-cache nftables iptables curl wget ca-certificates util-linux >/dev/null
                ;;
            debian)
                DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables iptables curl wget ca-certificates util-linux >/dev/null
                ;;
            *)
                warn "无法识别系统，跳过自动安装"
                ;;
        esac
    else
        case "$OS_TYPE" in
            alpine)
                has_cmd curl || has_cmd wget || apk add --no-cache curl wget >/dev/null
                has_cmd flock || apk add --no-cache util-linux >/dev/null
                has_cmd ca-certificates || apk add --no-cache ca-certificates >/dev/null
                ;;
            debian)
                has_cmd curl || has_cmd wget || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget >/dev/null
                has_cmd flock || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux >/dev/null
                has_cmd ca-certificates || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates >/dev/null
                ;;
        esac
    fi

    FW_TYPE=$(detect_firewall_type)
    ok "防火墙组件已就绪: ${FW_TYPE}"
}

#===============================================================================
# Status / Help
#===============================================================================
show_status() {
    local sp
    sp="${SSH_PORT:-$SSH_PORT_DEFAULT}"

    printf '%b\n' "${BOLD}=== 防火墙状态 ===${NC}"
    printf '  版本: %s\n' "$VERSION"
    printf '  系统: %s | 类型: %s\n' "$OS_TYPE" "$FW_TYPE"
    printf '  本机 IP: %s\n' "$(detect_ip || true)"
    printf '  SSH 端口: %s\n' "$sp"
    printf '  CF_ONLY: %s\n' "${CF_ONLY:-0}"
    printf '  CF_PROTECTED_PORTS: %s\n' "${CF_PROTECTED_PORTS:-$DEFAULT_CF_PROTECTED_PORTS}"
    printf '  ENABLE_LOGGING: %s\n' "${ENABLE_LOGGING:-1}"
    printf '  持久化:\n'
    case "$FW_TYPE" in
        nftables)
            if [[ -f /etc/nftables/uufw.nft ]] || [[ -f /etc/nftables.d/uufw.nft ]]; then
                echo "    ✓ 已持久化"
            else
                echo "    ✗ 未持久化"
            fi
            ;;
        iptables)
            if [[ -f /etc/iptables/rules.v4 ]]; then
                echo "    ✓ 已持久化"
            else
                echo "    ✗ 未持久化"
            fi
            ;;
    esac

    echo
    printf '%b\n' "${BOLD}=== 开放端口 ===${NC}"
    printf '  %-8s %-8s %s\n' "协议" "端口" "说明"
    printf '  %-8s %-8s %s\n' "TCP" "$sp" "SSH"
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        local proto=${item%%:*} port=${item##*:}
        printf '  %-8s %-8s %s\n' "$(upper "$proto")" "$port" "自定义"
    done < <(parse_extra_ports)
    printf '  %-8s %-8s %s\n' "ICMP" "-" "Ping 诊断"

    echo
    printf '%b\n' "${BOLD}=== 监听端口 ===${NC}"
    if has_cmd ss; then
        ss -tlnp 2>/dev/null | grep -vE '127\.0\.0\.1|::1' || echo "  无公网监听端口（安全）"
    else
        echo "  ss 不可用"
    fi
}

show_help() {
    cat <<EOF_HELP
UUFW 防火墙管理器 v${VERSION}
用法: uufw [命令]

命令:
  install     安装/应用规则
  apply       安装/应用规则
  uninstall   卸载本脚本规则
  status      查看状态
  backup      备份当前规则
  menu        交互管理面板（默认）
  help        帮助
  version     版本

配置文件:
  $CONFIG_FILE

可选配置项:
  CF_ONLY=1
  CF_PROTECTED_PORTS=80,443
  ENABLE_LOGGING=1
  LOG_RATE=5/second
EOF_HELP
}

#===============================================================================
# Port management
#===============================================================================
add_port() {
    local proto port new_entry
    read -r -p "协议 [tcp]: " proto
    proto=${proto:-tcp}
    proto=$(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]')
    validate_proto "$proto" || { err "无效协议: $proto"; return 1; }
    read -r -p "端口号: " port
    validate_port_number "$port" || { err "无效端口: $port"; return 1; }

    new_entry="${proto}:${port}"
    # Fix: deduplication check before adding
    if [[ ",${EXTRA_PORTS:-}," == *",${new_entry},"* ]]; then
        warn "端口 ${new_entry} 已在列表中，无需重复添加"
        return 0
    fi

    if [[ -n "${EXTRA_PORTS:-}" ]]; then
        EXTRA_PORTS="${EXTRA_PORTS},${new_entry}"
    else
        EXTRA_PORTS="$new_entry"
    fi
    EXTRA_PORTS="$(sanitize_csv_ports "$EXTRA_PORTS")"
    save_config
    apply_current
    ok "已开放: ${proto^^} $port"
}

remove_port() {
    [[ -z "${EXTRA_PORTS:-}" ]] && { warn "没有自定义端口"; return 0; }

    echo "当前自定义端口:"
    local i=1 item target total=0 new_ports=()
    while IFS= read -r item; do
        item=$(trim "$item")
        [[ -z "$item" ]] && continue
        printf '  %d) %s\n' "$i" "$item"
        total=$i
        i=$((i+1))
    done < <(parse_extra_ports)
    printf '  0) 取消\n'

    read -r -p "删除编号: " target
    [[ "$target" == "0" ]] && return 0
    [[ "$target" =~ ^[0-9]+$ ]] || { err "无效编号"; return 1; }
    [[ "$target" -ge 1 && "$target" -le "$total" ]] || { err "无效编号"; return 1; }

    i=1
    while IFS= read -r item; do
        item=$(trim "$item")
        [[ -z "$item" ]] && continue
        [[ $i -ne $target ]] && new_ports+=("$item")
        i=$((i+1))
    done < <(parse_extra_ports)

    EXTRA_PORTS="$(IFS=,; printf '%s' "${new_ports[*]:-}")"
    save_config
    apply_current
    ok "已移除"
}

change_ssh_port() {
    local p
    read -r -p "新 SSH 端口: " p
    validate_port_number "$p" || { err "无效端口: $p"; return 1; }
    SSH_PORT="$p"
    save_config
    apply_current
    ok "SSH 端口已更新为 $p"
}

#===============================================================================
# Temporary open port
#===============================================================================
temp_open_port() {
    local proto port duration self
    read -r -p "协议 [tcp]: " proto
    proto=${proto:-tcp}
    proto=$(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]')
    validate_proto "$proto" || { err "无效协议: $proto"; return 1; }
    read -r -p "端口号: " port
    validate_port_number "$port" || { err "无效端口: $port"; return 1; }
    read -r -p "持续时间(秒) [300]: " duration
    duration=${duration:-300}
    [[ "$duration" =~ ^[0-9]+$ ]] || { err "无效持续时间"; return 1; }

    step "临时开放 ${proto^^} $port (${duration}s 后自动关闭)"

    self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")

    case "$FW_TYPE" in
        nftables)
            has_cmd nft || { err "缺少 nft"; return 1; }
            nft add rule "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" "$NFT_CHAIN_INPUT" "$proto" dport "$port" accept >/dev/null 2>&1 || true
            ok "已开放"
            if has_cmd systemd-run; then
                systemd-run --unit="uufw-temp-$port" --on-active="${duration}s" /bin/sh -c 'exec "$1" apply >/dev/null 2>&1' sh "$self" >/dev/null 2>&1 || true
            elif has_cmd at; then
                printf '%s\n' "'$self' apply >/dev/null 2>&1" | at now + "$duration" seconds >/dev/null 2>&1 || true
            else
                ( sleep "$duration"; "$self" apply >/dev/null 2>&1 ) >/dev/null 2>&1 &
            fi
            ;;
        iptables)
            iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT
            ok "已开放"
            if has_cmd systemd-run; then
                systemd-run --unit="uufw-temp-$port" --on-active="${duration}s" /bin/sh -c 'exec "$1" apply >/dev/null 2>&1' sh "$self" >/dev/null 2>&1 || true
            elif has_cmd at; then
                printf '%s\n' "'$self' apply >/dev/null 2>&1" | at now + "$duration" seconds >/dev/null 2>&1 || true
            else
                ( sleep "$duration"; "$self" apply >/dev/null 2>&1 ) >/dev/null 2>&1 &
            fi
            ;;
        *)
            err "当前防火墙类型不支持临时开放"
            return 1
            ;;
    esac

    warn "临时规则已生效；到期后将自动重新应用主规则"
}

#===============================================================================
# Uninstall
#===============================================================================
uninstall_fw() {
    printf '%b\n' "${RED}${BOLD}=== 卸载本脚本规则 ===${NC}"
    read -r -p "确认卸载? [y/N]: " c
    if [[ ! "$c" =~ ^[Yy]$ ]]; then
        info "已取消"
        return 0
    fi

    case "$FW_TYPE" in
        nftables)
            if has_cmd nft && nft list table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1; then
                nft delete table "$NFT_TABLE_FAMILY" "$NFT_TABLE_NAME" >/dev/null 2>&1 || true
            fi
            [[ -f /etc/nftables.conf ]] && sed -i '/include.*uufw\.nft/d' /etc/nftables.conf
            rm -f /etc/nftables/uufw.nft /etc/nftables.d/uufw.nft "$LAST_NFT_FILE"
            ok "nftables 规则已清除"
            ;;
        iptables)
            if has_cmd iptables-restore; then
                local rst
                rst="$(mktemp_file)"
                cat > "$rst" <<'EOF_RST'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF_RST
                iptables-restore < "$rst" >/dev/null 2>&1 || true
            else
                iptables -P INPUT ACCEPT 2>/dev/null || true
                iptables -P FORWARD ACCEPT 2>/dev/null || true
                iptables -P OUTPUT ACCEPT 2>/dev/null || true
                iptables -F 2>/dev/null || true
                iptables -X 2>/dev/null || true
            fi
            if has_cmd ip6tables-restore; then
                local rst6
                rst6="$(mktemp_file)"
                cat > "$rst6" <<'EOF_RST6'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF_RST6
                ip6tables-restore < "$rst6" >/dev/null 2>&1 || true
            fi
            rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 "$LAST_V4_RULES" "$LAST_V6_RULES"
            ok "iptables 规则已清除"
            ;;
        ufw)
            ufw --force reset >/dev/null 2>&1 || true
            ok "ufw 已重置"
            ;;
        *)
            warn "未检测到可卸载的防火墙类型"
            ;;
    esac

    warn "防火墙已清除，系统处于开放状态"
    warn "重新安装: $SCRIPT_NAME install"
}

#===============================================================================
# Menu
#===============================================================================
menu() {
    while true; do
        clear 2>/dev/null || true
        printf '%b\n' "${CYAN}╔══════════════════════════════════════╗${NC}"
        printf '%b\n' "${CYAN}║      UUFW 防火墙管理 v${VERSION}      ║${NC}"
        printf '%b\n' "${CYAN}╚══════════════════════════════════════╝${NC}"

        printf '\n防火墙: %s | OS: %s\n' "$FW_TYPE" "$OS_TYPE"
        printf 'SSH 端口: %s\n' "${SSH_PORT:-$SSH_PORT_DEFAULT}"
        printf 'CF_ONLY: %s\n' "${CF_ONLY:-0}"

        local count=0 item
        while IFS= read -r item; do
            item=$(trim "$item")
            [[ -z "$item" ]] && continue
            [[ $count -eq 0 ]] && printf '自定义端口: '
            printf '%s ' "$item"
            count=$((count+1))
        done < <(parse_extra_ports)
        [[ $count -gt 0 ]] && echo

        if [[ "$FW_TYPE" == ufw ]]; then
            printf '%b\n' "${YELLOW}[警告] 你当前正在使用 ufw，建议先禁用后再由本脚本接管${NC}"
        fi
        printf '\n'

        printf ' 1) 安装/应用规则\n'
        printf ' 2) 卸载规则\n'
        printf ' 3) 查看状态\n'
        printf ' 4) 添加开放端口\n'
        printf ' 5) 移除开放端口\n'
        printf ' 6) 临时开放端口\n'
        printf ' 7) 修改 SSH 端口\n'
        printf ' 8) 更新 CF IP 列表\n'
        printf ' 9) 备份当前规则\n'
        printf '10) 切换 CF_ONLY\n'
        printf '11) 切换日志\n'
        printf ' 0) 退出\n'

        read -r -p '> ' ch
        case "${ch:-0}" in
            1)
                install_deps || { read -r -p '回车继续...'; continue; }
                apply_current && save_config
                ;;
            2) uninstall_fw ;;
            3) show_status ;;
            4) add_port ;;
            5) remove_port ;;
            6) temp_open_port ;;
            7) change_ssh_port ;;
            8)
                download_cf_ips
                apply_current
                ok "CF IP 列表已更新并重新应用"
                ;;
            9) backup_rules ;;
            10)
                if [[ "${CF_ONLY:-0}" == "1" ]]; then CF_ONLY=0; else CF_ONLY=1; fi
                save_config
                apply_current
                ok "CF_ONLY=${CF_ONLY}"
                ;;
            11)
                if [[ "${ENABLE_LOGGING:-1}" == "1" ]]; then ENABLE_LOGGING=0; else ENABLE_LOGGING=1; fi
                save_config
                apply_current
                ok "ENABLE_LOGGING=${ENABLE_LOGGING}"
                ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        read -r -p '回车继续...'
    done
}

#===============================================================================
# Shortcut
#===============================================================================
install_shortcut() {
    local me dst real
    me="$0"
    dst="/usr/local/bin/${SCRIPT_NAME}"
    real="$(readlink -f "$me" 2>/dev/null || realpath "$me" 2>/dev/null || printf '%s' "$me")"

    if [[ -f "$dst" ]] && [[ "$(readlink -f "$dst" 2>/dev/null || true)" == "$real" ]]; then
        return 0
    fi

    cat > "$dst" <<EOF_SC
#!/usr/bin/env bash
exec bash "$real" "\$@"
EOF_SC
    chmod +x "$dst"
    ok "快捷命令已安装: ${SCRIPT_NAME}"
}

#===============================================================================
# Main
#===============================================================================
main() {
    need_root
    acquire_lock
    OS_TYPE="$(detect_os)"
    FW_TYPE="$(detect_firewall_type)"
    mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$STATE_DIR"
    load_config
    install_shortcut

    case "${1:-menu}" in
        install|apply)
            install_deps
            apply_current
            save_config
            ;;
        uninstall)
            uninstall_fw
            ;;
        status)
            show_status
            ;;
        backup)
            backup_rules
            ;;
        menu)
            menu
            ;;
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            echo "v$VERSION"
            ;;
        *)
            show_help
            ;;
    esac
}

main "$@"
