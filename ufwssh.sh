#!/bin/bash
#
# UFW + SSH 交互式管理工具 v4.8.3
# Debian/Ubuntu: apt + systemd
# Alpine Linux:  apk + OpenRC
#
# v4.8.3 修复：
#   - P0: ssh_password_auth_original_comment 跳过 Match 块
#        只注释第一个 Match 之前的裸 PasswordAuthentication 行
#        避免误注释用户已有 Match 块内的 PasswordAuthentication
#        $line 加 local
#   - P0: ssh_password_auth_has_pubkey 检查 authorized_keys 权限
#        权限非 600/400 时打印警告，视为不可用公钥
#   - P1: ssh_optimize_security 检查 sshd_config.d/ 中字母序在 99 之前的
#        文件是否包含冲突指令，警告用户本脚本配置可能不生效
#   - P2: ssh_config_ports_managed_write 加前导 \n，避免与主文件末尾紧贴
#   - P2: install_quick_init 的 [5/7] 先检查密码登录当前状态
#
# v4.8.2 变更：
#   - 密码登录开关改用 Match All 块覆盖全局
#   - 管理块标记 MANAGED_PW_BEGIN / MANAGED_PW_END
#   - 清理主文件里已有的裸 PasswordAuthentication 行
#
# v4.8.1 变更：
#   - 密码登录开关：改为直接修改 sshd_config 主文件（已废弃，改用 Match All）
#   - ssh_detect_service：Debian 优先 ssh.service
#   - ssh_change_port / ssh_key_configure：支持空输入跳过
#   - install_quick_init：直接调函数，不再二次询问
#
# v4.8 变更：
#   - 新增“快捷安装与配置”（菜单 4）
#
# v4.7 变更：
#   - 新增“密码登录开关”（SSH 服务管理 → 8）
#   - ssh_optimize_security 用 $OS_TYPE 判断 Kerberos/GSSAPI
#
# v4.6.1 修复：
#   - 脚本开头显式设置 PATH
#   - ssh_port_is_listening 改用 /proc/net/tcp
#
# v4.6 变更：
#   - 新增“删除 SSH 端口”（菜单 3 → 4）
#   - 不允许删到 0 个端口
#

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ============================================================
# 0. 常量
# ============================================================

SCRIPT_VERSION="v4.8.3"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
UFW_DEFAULT="/etc/default/ufw"
DEFAULT_SSH_PORT=22

MANAGED_BLOCK_BEGIN="# >>> ufwssh managed ports >>>"
MANAGED_BLOCK_END="# <<< ufwssh managed ports <<<"
MANAGED_PW_BEGIN="# >>> ufwssh managed password auth >>>"
MANAGED_PW_END="# <<< ufwssh managed password auth <<<"
ORIGINAL_PORT_PREFIX="# ufwssh: original Port"
ORIGINAL_PW_PREFIX="# ufwssh: original PasswordAuthentication"

SECURITY_CONF="$SSHD_CONFIG_DIR/99-ufwssh-security.conf"

SOURCE_BACKUP_ROOT="/etc/ufwssh/source-backups"
SSH_BACKUP_ROOT="/etc/ufwssh/ssh-backups"
DEBIAN_MANAGED_SOURCE="/etc/apt/sources.list.d/ufwssh-official.sources"
DEBIAN_MANAGED_LEGACY_SOURCE="/etc/apt/sources.list.d/ufwssh-official.list"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

OS_TYPE=""
OS_NAME=""
OS_VERSION=""
SSH_SERVICE=""
DEFAULT_SSH_USER="root"

# ============================================================
# 1. 基础工具层
# ============================================================

ui_print_banner() {
    clear 2>/dev/null || true
    echo -e "$GREEN============================================================$NC"
    echo -e "$GREEN             UFW + SSH 管理工具 $SCRIPT_VERSION$NC"
    echo -e "$GREEN============================================================$NC"
    echo ""
}

ui_error() { echo -e "$RED错误：$1$NC" >&2; }
ui_warning() { echo -e "$YELLOW警告：$1$NC"; }
ui_success() { echo -e "$GREEN$1$NC"; }
ui_info() { echo -e "$BLUE$1$NC"; }

ui_pause() { echo ""; read -r -p "按 Enter 返回..." _; }

ui_confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

sys_command_exists() { command -v "$1" >/dev/null 2>&1; }

sys_check_root() {
    [[ "$EUID" -eq 0 ]] || { ui_error "此脚本必须以 root 用户执行。"; return 1; }
}

# ============================================================
# 2. 系统探测层
# ============================================================

sys_detect_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"
        OS_NAME="Alpine Linux"
        OS_VERSION="$(cat /etc/alpine-release 2>/dev/null || true)"
        return 0
    fi

    if [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
        OS_NAME="Debian/Ubuntu"
        OS_VERSION="$(cat /etc/debian_version 2>/dev/null || true)"
        if [[ -r /etc/os-release ]]; then
            OS_NAME="$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
            OS_VERSION="$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2- | tr -d '"')"
        fi
        return 0
    fi

    ui_error "不支持的操作系统，仅支持 Debian/Ubuntu 和 Alpine Linux。"
    return 1
}

sys_service_manager() {
    case "$OS_TYPE" in
        debian) echo "systemd" ;;
        alpine) echo "OpenRC" ;;
        *) echo "unknown" ;;
    esac
}

sys_get_distro_id() {
    [[ -r /etc/os-release ]] || return 1
    (
        . /etc/os-release
        printf '%s\n' "$ID"
    )
}

sys_get_distro_codename() {
    local codename=""
    if [[ -r /etc/os-release ]]; then
        codename="$(
            . /etc/os-release
            printf '%s\n' "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
        )"
    fi
    if [[ -z "$codename" ]] && sys_command_exists lsb_release; then
        codename="$(lsb_release -cs 2>/dev/null || true)"
    fi
    printf '%s\n' "$codename"
}

# ============================================================
# 3. SSH 服务抽象层
# ============================================================

ssh_detect_service() {
    SSH_SERVICE=""
    case "$OS_TYPE" in
        debian)
            if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
                SSH_SERVICE="ssh"
            elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
                SSH_SERVICE="sshd"
            elif sys_command_exists sshd; then
                SSH_SERVICE="ssh"
            fi
            ;;
        alpine)
            if rc-status --servicelist 2>/dev/null | grep -qw 'sshd'; then
                SSH_SERVICE="sshd"
            elif sys_command_exists sshd; then
                SSH_SERVICE="sshd"
            fi
            ;;
    esac
}

ssh_is_installed() {
    case "$OS_TYPE" in
        debian) dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed' ;;
        alpine) apk info -e openssh >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ssh_is_running() {
    [[ -n "$SSH_SERVICE" ]] || ssh_detect_service
    case "$OS_TYPE" in
        debian) [[ -n "$SSH_SERVICE" ]] && systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null ;;
        alpine) [[ -n "$SSH_SERVICE" ]] && rc-service "$SSH_SERVICE" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ssh_is_enabled() {
    [[ -n "$SSH_SERVICE" ]] || ssh_detect_service
    case "$OS_TYPE" in
        debian) [[ -n "$SSH_SERVICE" ]] && systemctl is-enabled --quiet "$SSH_SERVICE" 2>/dev/null ;;
        alpine) rc-update show default 2>/dev/null | grep -Eq '^[[:space:]]*sshd[[:space:]]' ;;
        *) return 1 ;;
    esac
}

ssh_start() {
    [[ -n "$SSH_SERVICE" ]] || ssh_detect_service
    case "$OS_TYPE" in
        debian) systemctl start "$SSH_SERVICE" ;;
        alpine) rc-service "$SSH_SERVICE" start ;;
        *) return 1 ;;
    esac
}

ssh_stop() {
    [[ -n "$SSH_SERVICE" ]] || ssh_detect_service
    case "$OS_TYPE" in
        debian) systemctl stop "$SSH_SERVICE" ;;
        alpine) rc-service "$SSH_SERVICE" stop ;;
        *) return 1 ;;
    esac
}

ssh_restart() {
    [[ -n "$SSH_SERVICE" ]] || ssh_detect_service
    case "$OS_TYPE" in
        debian) systemctl restart "$SSH_SERVICE" ;;
        alpine) rc-service "$SSH_SERVICE" restart ;;
        *) return 1 ;;
    esac
}

ssh_enable() {
    [[ -n "$SSH_SERVICE" ]] || ssh_detect_service
    case "$OS_TYPE" in
        debian) systemctl enable "$SSH_SERVICE" ;;
        alpine) rc-update add "$SSH_SERVICE" default ;;
        *) return 1 ;;
    esac
}

ssh_disable() {
    [[ -n "$SSH_SERVICE" ]] || ssh_detect_service
    case "$OS_TYPE" in
        debian) systemctl disable "$SSH_SERVICE" ;;
        alpine) rc-update del "$SSH_SERVICE" default ;;
        *) return 1 ;;
    esac
}

ssh_status_text() {
    if ! ssh_is_installed; then
        echo "未安装"
    elif ssh_is_running; then
        echo "已安装 / 运行中"
    else
        echo "已安装 / 未运行"
    fi
}

# ============================================================
# 4. UFW 抽象层
# ============================================================

ufw_is_installed() { sys_command_exists ufw; }

ufw_is_active() {
    ufw_is_installed || return 1
    ufw status 2>/dev/null | head -1 | grep -q '^Status: active'
}

ufw_status_text() {
    if ! ufw_is_installed; then
        echo "未安装"
    elif ufw_is_active; then
        echo "已安装 / 已启用"
    else
        echo "已安装 / 未启用"
    fi
}

ufw_configure_ipv6() {
    ufw_is_installed || return 0
    mkdir -p "$(dirname "$UFW_DEFAULT")"
    if [[ -f "$UFW_DEFAULT" ]]; then
        if grep -qE '^IPV6=' "$UFW_DEFAULT"; then
            sed -i 's/^IPV6=.*/IPV6=yes/' "$UFW_DEFAULT"
        else
            printf '\nIPV6=yes\n' >> "$UFW_DEFAULT"
        fi
    else
        printf 'IPV6=yes\n' > "$UFW_DEFAULT"
    fi
}

# ============================================================
# 5. 软件源抽象层
# ============================================================

src_backup() {
    local backup_dir
    mkdir -p "$SOURCE_BACKUP_ROOT" || return 1
    backup_dir="$(mktemp -d "$SOURCE_BACKUP_ROOT/backup.XXXXXX")" || return 1
    case "$OS_TYPE" in
        debian)
            if [[ -e /etc/apt/sources.list ]]; then
                cp -a /etc/apt/sources.list "$backup_dir/sources.list"
            else
                : > "$backup_dir/sources.list.missing"
            fi
            if [[ -d /etc/apt/sources.list.d ]]; then
                cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d"
            else
                : > "$backup_dir/sources.list.d.missing"
            fi
            ;;
        alpine)
            if [[ -e /etc/apk/repositories ]]; then
                cp -a /etc/apk/repositories "$backup_dir/repositories"
            else
                : > "$backup_dir/repositories.missing"
            fi
            ;;
        *) rm -rf "$backup_dir"; return 1 ;;
    esac
    echo "$backup_dir"
}

src_backup_latest() {
    [[ -d "$SOURCE_BACKUP_ROOT" ]] || return 1
    ls -dt "$SOURCE_BACKUP_ROOT"/backup.* 2>/dev/null | head -1
}

src_restore_backup() {
    local backup_dir=""
    [[ $# -gt 0 ]] && backup_dir="$1"
    [[ -n "$backup_dir" && -d "$backup_dir" ]] || backup_dir="$(src_backup_latest 2>/dev/null || true)"
    [[ -n "$backup_dir" && -d "$backup_dir" ]] || { ui_error "没有可恢复的软件源备份。"; return 1; }
    case "$OS_TYPE" in
        debian)
            if [[ -f "$backup_dir/sources.list" ]]; then
                rm -f /etc/apt/sources.list
                cp -a "$backup_dir/sources.list" /etc/apt/sources.list
            elif [[ -f "$backup_dir/sources.list.missing" ]]; then
                rm -f /etc/apt/sources.list
            fi
            if [[ -d "$backup_dir/sources.list.d" ]]; then
                rm -rf /etc/apt/sources.list.d
                cp -a "$backup_dir/sources.list.d" /etc/apt/sources.list.d
            elif [[ -f "$backup_dir/sources.list.d.missing" ]]; then
                rm -rf /etc/apt/sources.list.d
                mkdir -p /etc/apt/sources.list.d
            fi
            ;;
        alpine)
            if [[ -f "$backup_dir/repositories" ]]; then
                cp -a "$backup_dir/repositories" /etc/apk/repositories
            elif [[ -f "$backup_dir/repositories.missing" ]]; then
                rm -f /etc/apk/repositories
            fi
            ;;
        *) return 1 ;;
    esac
    ui_success "已恢复软件源备份：$backup_dir"
}

src_debian_files() {
    [[ -d /etc/apt/sources.list.d ]] || return 0
    find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print 2>/dev/null
}

src_debian_apt_supports_deb822() {
    local major="" minor=""
    read -r major minor _ < <(apt-get --version 2>/dev/null | awk 'NR==1 {split($2,v,"."); print v[1],v[2]}')
    [[ -n "$major" && "$major" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$minor" && "$minor" =~ ^[0-9]+$ ]] || minor=0
    (( major > 1 || (major == 1 && minor >= 1) ))
}

src_debian_disable_existing() {
    local file
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        case "$file" in
            "$DEBIAN_MANAGED_SOURCE"|"$DEBIAN_MANAGED_LEGACY_SOURCE") continue ;;
        esac
        ui_warning "禁用现有软件源：$file -> $file.ufwssh-disabled"
        mv "$file" "$file.ufwssh-disabled"
    done < <(src_debian_files)
}

src_debian_write() {
    local profile="official"
    [[ $# -gt 0 ]] && profile="$1"
    local distro codename base_uri security_uri components
    distro="$(sys_get_distro_id)"
    codename="$(sys_get_distro_codename)"
    [[ -n "$codename" ]] || { ui_error "无法检测 Debian/Ubuntu 发行版代号。"; return 1; }

    case "$distro:$profile" in
        debian:official) base_uri="https://deb.debian.org/debian"; security_uri="https://security.debian.org/debian-security"; components="main contrib non-free non-free-firmware" ;;
        debian:tuna) base_uri="https://mirrors.tuna.tsinghua.edu.cn/debian"; security_uri="https://mirrors.tuna.tsinghua.edu.cn/debian-security"; components="main contrib non-free non-free-firmware" ;;
        ubuntu:official) base_uri="https://archive.ubuntu.com/ubuntu"; security_uri="https://security.ubuntu.com/ubuntu"; components="main restricted universe multiverse" ;;
        ubuntu:tuna) base_uri="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"; security_uri="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"; components="main restricted universe multiverse" ;;
        *) ui_error "不支持的 APT 软件源配置：$distro / $profile"; return 1 ;;
    esac

    mkdir -p /etc/apt/sources.list.d || return 1
    src_debian_disable_existing || return 1
    rm -f "$DEBIAN_MANAGED_SOURCE" "$DEBIAN_MANAGED_LEGACY_SOURCE"
    if src_debian_apt_supports_deb822; then
        cat > "$DEBIAN_MANAGED_SOURCE" <<EOF
Types: deb
URIs: $base_uri
Suites: $codename $codename-updates
Components: $components
Signed-By: /usr/share/keyrings/$distro-archive-keyring.gpg

Types: deb
URIs: $security_uri
Suites: $codename-security
Components: $components
Signed-By: /usr/share/keyrings/$distro-archive-keyring.gpg
EOF
    else
        cat > "$DEBIAN_MANAGED_LEGACY_SOURCE" <<EOF
deb $base_uri $codename $components
deb $base_uri $codename-updates $components
deb $security_uri $codename-security $components
EOF
    fi
}

src_debian_package_available() {
    local package="$1" policy candidate
    sys_command_exists apt-cache || return 1
    policy="$(apt-cache policy "$package" 2>/dev/null || true)"
    candidate="$(printf '%s\n' "$policy" | awk -F': ' '/^[[:space:]]*Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

src_debian_packages_available() {
    local package
    for package in "$@"; do src_debian_package_available "$package" || return 1; done
    return 0
}

src_debian_refresh_and_check() {
    ui_info "刷新 APT 软件包索引..."
    apt-get update || { ui_warning "APT update 失败。"; return 1; }
    src_debian_packages_available "$@" || { ui_warning "当前 APT 源刷新成功，但目标软件包没有可用候选版本。"; return 1; }
}

src_debian_try_profile() {
    local profile="$1"; shift
    ui_info "尝试 Debian/Ubuntu $profile 软件源..."
    src_debian_write "$profile" || return 1
    src_debian_refresh_and_check "$@"
}

src_alpine_refresh() {
    sys_command_exists apk || { ui_error "未找到 apk。"; return 1; }
    ui_info "刷新 Alpine 软件源..."
    apk update
}

src_alpine_write_official() {
    local branch="$1"
    cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/$branch/main
https://dl-cdn.alpinelinux.org/alpine/$branch/community
@edge https://dl-cdn.alpinelinux.org/alpine/edge/main
@edge-community https://dl-cdn.alpinelinux.org/alpine/edge/community
EOF
}

src_alpine_write_tuna() {
    local branch="$1"
    cat > /etc/apk/repositories <<EOF
https://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/community
@edge https://mirrors.tuna.tsinghua.edu.cn/alpine/edge/main
@edge-community https://mirrors.tuna.tsinghua.edu.cn/alpine/edge/community
EOF
}

src_alpine_package_available() {
    local package="$1"
    apk policy "$package" 2>/dev/null | grep -Eq '^[[:space:]]*[^[:space:]]+'
}

src_alpine_edge_package_available() {
    local package="$1" repo_tag="$2"
    apk policy "$package@$repo_tag" 2>/dev/null | grep -Eq '^[[:space:]]*[^[:space:]]+'
}

src_alpine_packages_available() {
    local package
    for package in "$@"; do
        src_alpine_package_available "$package" || return 1
    done
    return 0
}

src_alpine_install_from_repos() {
    local package="$1"

    if src_alpine_package_available "$package"; then
        ui_info "从 Alpine stable main/community 安装 $package..."
        apk add --no-cache "$package"
        return 0
    fi

    if [[ "$package" == "ufw" ]] && src_alpine_edge_package_available "$package" "edge-community"; then
        ui_info "从 Alpine edge/community 安装 $package..."
        apk add --no-cache "$package@edge-community"
        return 0
    fi

    if [[ "$package" == "openssl" ]] && src_alpine_edge_package_available "$package" "edge"; then
        ui_info "从 Alpine edge/main 安装 $package..."
        apk add --no-cache "$package@edge"
        return 0
    fi

    return 1
}

src_alpine_version_branch() {
    local version
    version="$(printf '%s' "$OS_VERSION" | cut -d- -f1)"
    printf '%s\n' "$version" | sed -n 's/^\([0-9]\+\.[0-9]\+\).*/v\1/p'
}

src_alpine_try_profile() {
    local profile="$1" branch="$2"
    shift 2
    case "$profile" in
        official) src_alpine_write_official "$branch" ;;
        tuna) src_alpine_write_tuna "$branch" ;;
        *) return 1 ;;
    esac
    ui_info "尝试 Alpine $profile 软件源：$branch"
    src_alpine_refresh || return 1
    src_alpine_packages_available "$@"
}

# ============================================================
# 6. SSH 端口配置读写（管理块）
# ============================================================

ssh_config_ensure() {
    [[ -f "$SSHD_CONFIG" ]] && return 0
    local source
    for source in /etc/ssh/sshd_config.dpkg-dist /usr/share/openssh/sshd_config /usr/share/doc/openssh-server/examples/sshd_config; do
        if [[ -f "$source" ]]; then
            cp "$source" "$SSHD_CONFIG"
            return 0
        fi
    done
    cat > "$SSHD_CONFIG" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
Port 22
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin yes
EOF
}

ssh_config_ensure_include() {
    ssh_config_ensure || return 1
    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)" || return 1
    {
        printf 'Include /etc/ssh/sshd_config.d/*.conf\n'
        cat "$SSHD_CONFIG"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$SSHD_CONFIG"
}

ssh_config_port_files() {
    printf '%s\n' "$SSHD_CONFIG"
    [[ -d "$SSHD_CONFIG_DIR" ]] || return 0
    local file
    for file in "$SSHD_CONFIG_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        printf '%s\n' "$file"
    done
}

ssh_config_ports_effective() {
    if ssh_is_installed && sys_command_exists sshd; then
        local ports
        ports="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | awk '!seen[$0]++')"
        if [[ -n "$ports" ]]; then
            printf '%s\n' "$ports"
            return 0
        fi
    fi
    printf '%s\n' "$DEFAULT_SSH_PORT"
}

ssh_config_ports_in_block() {
    local file in_block=0 line port
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            if [[ "$line" == "$MANAGED_BLOCK_BEGIN" ]]; then
                in_block=1
                continue
            fi
            if [[ "$line" == "$MANAGED_BLOCK_END" ]]; then
                in_block=0
                continue
            fi
            if (( in_block == 1 )) && [[ "$line" =~ ^Port[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then
                port="${BASH_REMATCH[1]}"
                printf '%s\n' "$port"
            fi
        done < "$file"
    done < <(ssh_config_port_files) | awk '!seen[$0]++'
}

ssh_config_ports_text() {
    local text
    text="$(ssh_config_ports_effective | paste -sd, - 2>/dev/null || true)"
    [[ -n "$text" ]] || text="$DEFAULT_SSH_PORT"
    echo "$text"
}

ssh_config_test() {
    sys_command_exists sshd || { ui_error "未找到 sshd。"; return 1; }
    local output
    if output="$(sshd -t 2>&1)"; then
        ui_success "SSH 配置语法检查通过。"
        return 0
    fi
    ui_error "SSH 配置检查失败：$output"
    return 1
}

ssh_config_backup() {
    ssh_config_ensure || return 1
    local backup_dir
    mkdir -p "$SSH_BACKUP_ROOT" || return 1
    backup_dir="$(mktemp -d "$SSH_BACKUP_ROOT/backup.XXXXXX")" || return 1
    cp -a "$SSHD_CONFIG" "$backup_dir/sshd_config" || { rm -rf "$backup_dir"; return 1; }
    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        cp -a "$SSHD_CONFIG_DIR" "$backup_dir/sshd_config.d" || { rm -rf "$backup_dir"; return 1; }
    else
        : > "$backup_dir/sshd_config.d.missing"
    fi
    echo "$backup_dir"
}

ssh_config_restore_backup() {
    local backup="$1"
    [[ -f "$backup/sshd_config" ]] || return 1
    cp -a "$backup/sshd_config" "$SSHD_CONFIG" || return 1
    if [[ -f "$backup/sshd_config.d.missing" ]]; then
        rm -rf "$SSHD_CONFIG_DIR"
    elif [[ -d "$backup/sshd_config.d" ]]; then
        rm -rf "$SSHD_CONFIG_DIR"
        cp -a "$backup/sshd_config.d" "$SSHD_CONFIG_DIR" || return 1
    fi
}

ssh_port_is_listening() {
    local port="$1"
    local hex_port
    hex_port="$(printf '%04X' "$port")"

    if [[ -r /proc/net/tcp || -r /proc/net/tcp6 ]]; then
        if awk -v hex="$hex_port" '
            NR > 1 && $4 == "0A" {
                split($2, a, ":")
                if (toupper(a[2]) == hex) { found=1; exit }
            }
            END { exit(found ? 0 : 1) }
        ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    if sys_command_exists ss; then
        ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|:)$port$|\]:$port$" && return 0
    fi
    if sys_command_exists netstat; then
        netstat -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -Eq "(^|:)$port$|\]:$port$" && return 0
    fi
    return 1
}

ssh_verify_port() {
    local port="$1"
    if ! ssh_config_ports_effective | grep -Fxq "$port"; then
        ui_error "sshd 当前生效配置没有端口 $port。"
        ui_info "当前生效端口：$(ssh_config_ports_text)"
        return 1
    fi
    if ssh_port_is_listening "$port"; then
        return 0
    fi
    ui_error "sshd 配置包含端口 $port，但系统没有检测到该端口监听。"
    if sys_command_exists ss; then
        ss -lntH 2>/dev/null | sed -n '1,20p' || true
    elif sys_command_exists netstat; then
        netstat -lnt 2>/dev/null | sed -n '1,20p' || true
    fi
    return 1
}

ssh_config_ports_original_comment() {
    local file line port changed=0
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            [[ "$line" == "$MANAGED_BLOCK_BEGIN" ]] && continue
            [[ "$line" == "$MANAGED_BLOCK_END" ]] && continue
            [[ "$line" == "$ORIGINAL_PORT_PREFIX"* ]] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^([[:space:]]*)Port[[:space:]]+([0-9]+)([[:space:]]*)$ ]]; then
                port="${BASH_REMATCH[2]}"
                changed=1
            fi
        done < "$file"
    done < <(ssh_config_port_files)
    (( changed == 0 )) && return 0

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        awk -v begin="$MANAGED_BLOCK_BEGIN" -v end="$MANAGED_BLOCK_END" -v prefix="$ORIGINAL_PORT_PREFIX" '
            BEGIN { in_block=0 }
            $0 == begin { in_block=1; print; next }
            $0 == end { in_block=0; print; next }
            in_block == 1 { print; next }
            /^[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$/ {
                line=$0
                match(line, /^[[:space:]]*/); lead=substr(line, 1, RLENGTH)
                match(line, /Port[[:space:]]+[0-9]+/); body=substr(line, RSTART, RLENGTH)
                print lead prefix " " substr(body, 6)
                next
            }
            { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file" || {
            rm -f "$file.tmp"
            return 1
        }
    done < <(ssh_config_port_files)
    return 0
}

ssh_config_ports_managed_remove() {
    local file
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        if grep -qF "$MANAGED_BLOCK_BEGIN" "$file"; then
            awk -v begin="$MANAGED_BLOCK_BEGIN" -v end="$MANAGED_BLOCK_END" '
                BEGIN { in_block=0 }
                $0 == begin { in_block=1; next }
                $0 == end { in_block=0; next }
                in_block == 1 { next }
                { print }
            ' "$file" > "$file.tmp" && mv "$file.tmp" "$file" || {
                rm -f "$file.tmp"
                return 1
            }
        fi
    done < <(ssh_config_port_files)
    return 0
}

ssh_config_ports_managed_write() {
    local port
    [[ $# -gt 0 ]] || { ui_error "管理块写入：未指定端口。"; return 1; }

    ssh_config_ports_managed_remove || return 1

    {
        printf '\n%s\n' "$MANAGED_BLOCK_BEGIN"
        for port in "$@"; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            printf 'Port %s\n' "$port"
        done
        printf '%s\n' "$MANAGED_BLOCK_END"
    } >> "$SSHD_CONFIG" || return 1

    ssh_config_test
}

# ============================================================
# 7. UFW 业务层
# ============================================================

ssh_ufw_detect_limit_ports() {
    ufw_is_installed || return 0
    ufw status 2>/dev/null | awk '
        /# SSH$/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /LIMIT/) {
                    for (j=1; j<=NF; j++) {
                        if ($j ~ /^[0-9]+\/tcp$/) {
                            split($j, a, "/")
                            print a[1]
                            break
                        }
                    }
                    break
                }
            }
        }
    ' | awk '!seen[$0]++'
}

ssh_ufw_detect_allow_ports() {
    ufw_is_installed || return 0
    ufw status 2>/dev/null | awk '
        /# SSH$/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /ALLOW/) {
                    for (j=1; j<=NF; j++) {
                        if ($j ~ /^[0-9]+\/tcp$/) {
                            split($j, a, "/")
                            print a[1]
                            break
                        }
                    }
                    break
                }
            }
        }
    ' | awk '!seen[$0]++'
}

ssh_ufw_ensure_rule_one() {
    local port="$1"
    ufw_is_installed || return 1

    if ufw status 2>/dev/null | grep -Eq "[[:space:]]$port/tcp([[:space:]]+\(v6\))?[[:space:]]+LIMIT"; then
        return 0
    fi

    if ufw status 2>/dev/null | grep -Eq "[[:space:]]$port/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW"; then
        ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
    fi

    ufw limit "$port/tcp" comment "SSH"
}

ssh_ufw_remove_rule_one() {
    local port="$1"
    ufw_is_installed || return 0
    ufw delete limit "$port/tcp" >/dev/null 2>&1 || true
    ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
}

ssh_ufw_sync() {
    ufw_is_installed || return 1

    local target_port current_port
    local -a target=() current=()

    while IFS= read -r target_port; do
        [[ -n "$target_port" ]] || continue
        target+=( "$target_port" )
    done < <(ssh_config_ports_in_block)

    if (( ${#target[@]} == 0 )); then
        while IFS= read -r target_port; do
            [[ -n "$target_port" ]] || continue
            target+=( "$target_port" )
        done < <(ssh_config_ports_effective)
    fi

    if (( ${#target[@]} == 0 )); then
        target=( "$DEFAULT_SSH_PORT" )
    fi

    while IFS= read -r current_port; do
        [[ -n "$current_port" ]] || continue
        current+=( "$current_port" )
    done < <(ssh_ufw_detect_limit_ports)

    local p found
    for p in "${target[@]}"; do
        ssh_ufw_ensure_rule_one "$p" || return 1
    done

    for p in "${current[@]}"; do
        found=0
        local t
        for t in "${target[@]}"; do
            [[ "$p" == "$t" ]] && { found=1; break; }
        done
        (( found == 0 )) && ssh_ufw_remove_rule_one "$p"
    done

    return 0
}

ufw_show_rules() {
    ufw_is_installed || { ui_error "UFW 尚未安装。"; return 1; }
    echo ""
    ufw status verbose
    echo ""
    echo "提示：如需删除规则，请使用「删除规则」菜单，会自动显示编号。"
}

ufw_add_rule() {
    ufw_is_installed || { ui_error "UFW 尚未安装。"; return 1; }
    echo "1) allow  2) limit  3) deny  4) reject  0) 返回"

    local type port protocol
    read -r -p "规则类型: " type
    case "$type" in
        1) type="allow" ;;
        2) type="limit" ;;
        3) type="deny" ;;
        4) type="reject" ;;
        0) return 0 ;;
        *) ui_error "无效选择。"; return 1 ;;
    esac

    read -r -p "端口（例如 80、443、8000:8010）: " port
    [[ -n "$port" ]] || { ui_error "端口不能为空。"; return 1; }

    echo "1) tcp  2) udp  3) tcp+udp  4) all"
    read -r -p "协议 [默认 1]: " protocol
    [[ -n "$protocol" ]] || protocol=1

    case "$protocol" in
        1) ufw "$type" "$port/tcp" ;;
        2) ufw "$type" "$port/udp" ;;
        3) ufw "$type" "$port/tcp" && ufw "$type" "$port/udp" ;;
        4) ufw "$type" "$port" ;;
        *) ui_error "无效协议。"; return 1 ;;
    esac
}

ufw_delete_rule() {
    ufw_is_installed || { ui_error "UFW 尚未安装。"; return 1; }
    ufw status numbered
    echo ""
    local input token numbers=()
    read -r -p "要删除的规则编号（空格或逗号分隔，如 1,3,5）: " input
    [[ -n "$input" ]] || { ui_error "未输入规则编号。"; return 1; }

    input="${input//,/ }"
    if [[ ! "$input" =~ ^[0-9[:space:]]+$ ]]; then
        ui_error "规则编号只能使用数字、空格或逗号。"
        return 1
    fi
    for token in $input; do
        [[ "$token" =~ ^[0-9]+$ ]] || { ui_error "无效规则编号：$token"; return 1; }
        (( token > 0 )) || { ui_error "规则编号必须大于 0。"; return 1; }
        numbers+=( "$token" )
    done

    echo "将删除规则：${numbers[*]}"
    ui_confirm "确定删除以上 UFW 规则？" || return 0

    local i j tmp n
    for ((i=0; i<${#numbers[@]}; i++)); do
        for ((j=i+1; j<${#numbers[@]}; j++)); do
            if (( numbers[i] < numbers[j] )); then
                tmp="${numbers[i]}"
                numbers[i]="${numbers[j]}"
                numbers[j]="$tmp"
            fi
        done
    done

    for n in "${numbers[@]}"; do
        if ! ufw --force delete "$n"; then
            ui_warning "删除规则 #$n 失败，继续处理其余规则。"
        fi
    done
}

ufw_change_defaults() {
    ufw_is_installed || { ui_error "UFW 尚未安装。"; return 1; }
    local incoming outgoing
    echo "默认入站：1) deny  2) allow"
    read -r -p "选择 [默认 1]: " incoming
    [[ -n "$incoming" ]] || incoming=1
    echo "默认出站：1) allow  2) deny"
    read -r -p "选择 [默认 1]: " outgoing
    [[ -n "$outgoing" ]] || outgoing=1

    case "$incoming" in
        1) ufw default deny incoming ;;
        2) ufw default allow incoming ;;
        *) ui_error "入站策略无效。"; return 1 ;;
    esac
    case "$outgoing" in
        1) ufw default allow outgoing ;;
        2) ufw default deny outgoing ;;
        *) ui_error "出站策略无效。"; return 1 ;;
    esac
}

ufw_enable_safely() {
    ufw_is_installed || { ui_error "UFW 尚未安装。"; return 1; }
    ssh_ufw_sync || { ui_error "无法同步 SSH UFW 规则，拒绝启用 UFW。"; return 1; }
    ufw --force enable
}

ufw_reset() {
    ufw_is_installed || { ui_error "UFW 尚未安装。"; return 1; }
    ui_warning "这会删除所有 UFW 规则并关闭 UFW。"
    ui_confirm "确定重置 UFW？" || return 0
    ufw --force reset
}

# ============================================================
# 8. SSH 端口变更业务
# ============================================================

ssh_change_port() {
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }

    local -a before=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        before+=( "$p" )
    done < <(ssh_config_ports_effective)

    echo "当前 SSH 端口：$(ssh_config_ports_text)"

    local new_port
    read -r -p "新的 SSH 端口（1-65535，Enter 跳过）: " new_port
    if [[ -z "$new_port" ]]; then
        ui_info "跳过修改端口。"
        return 0
    fi
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        ui_error "端口号无效。"
        return 1
    fi

    for p in "${before[@]}"; do
        [[ "$p" == "$new_port" ]] && { ui_warning "端口 $new_port 已在监听，无需变更。"; return 0; }
    done

    if ssh_port_is_listening "$new_port"; then
        ui_error "端口 $new_port 已被占用。"
        return 1
    fi

    local backup
    backup="$(ssh_config_backup)" || { ui_error "无法备份 SSH 配置。"; return 1; }

    if ufw_is_installed && ! ssh_ufw_ensure_rule_one "$new_port"; then
        ui_error "UFW 无法放行新端口，停止操作。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_config_ports_original_comment; then
        ui_error "无法注释原有 Port 行，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_config_ports_managed_write "$new_port"; then
        ui_error "写入管理块失败，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_restart; then
        ui_error "SSH 重启失败，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        return 1
    fi

    sleep 1
    if ! ssh_verify_port "$new_port"; then
        ui_error "新端口未监听，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        return 1
    fi

    ui_success "SSH 已实际监听：$(ssh_config_ports_text)"
    ui_warning "请先在另一个终端测试：ssh -p $new_port <用户>@<服务器IP>"

    local -a kept=()
    for p in "${before[@]}"; do
        [[ "$p" == "$new_port" ]] && continue
        kept+=( "$p" )
    done

    if (( ${#kept[@]} > 0 )); then
        if ui_confirm "确认新端口可登录后，是否保留旧端口 ${kept[*]}？"; then
            local -a all=( "$new_port" "${kept[@]}" )
            if ! ssh_config_ports_managed_write "${all[@]}"; then
                ui_error "写入管理块失败，恢复配置。"
                ssh_config_restore_backup "$backup" || true
                ssh_restart >/dev/null 2>&1 || true
                return 1
            fi
            if ! ssh_config_test || ! ssh_restart; then
                ssh_config_restore_backup "$backup" || true
                ssh_restart >/dev/null 2>&1 || true
                ui_error "应用保留端口失败，已恢复。"
                return 1
            fi
            ui_success "已保留旧端口：$(ssh_config_ports_text)"
        else
            for p in "${kept[@]}"; do
                ssh_ufw_remove_rule_one "$p"
            done
            ui_success "旧端口已从 UFW 规则中移除。"
        fi
    fi
}

ssh_restore_default_port() {
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }

    local -a before=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        before+=( "$p" )
    done < <(ssh_config_ports_effective)

    if (( ${#before[@]} == 1 )) && [[ "${before[0]}" == "$DEFAULT_SSH_PORT" ]]; then
        ui_info "当前已经是 22 端口。"
        return 0
    fi

    local backup
    backup="$(ssh_config_backup)" || return 1

    if ufw_is_installed && ! ssh_ufw_ensure_rule_one "$DEFAULT_SSH_PORT"; then
        ui_error "无法放行 22/tcp。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_config_ports_original_comment; then
        ui_error "无法注释原有 Port 行，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_config_ports_managed_write "$DEFAULT_SSH_PORT"; then
        ui_error "写入管理块失败，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_restart; then
        ui_error "SSH 重启失败，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        return 1
    fi

    sleep 1
    if ! ssh_verify_port "$DEFAULT_SSH_PORT"; then
        ui_error "22 端口未监听，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        return 1
    fi

    ui_success "SSH 已切换到 22，当前端口：$(ssh_config_ports_text)"
    ui_warning "请先在另一个终端测试：ssh -p 22 <用户>@<服务器IP>"

    local -a kept=()
    for p in "${before[@]}"; do
        [[ "$p" == "$DEFAULT_SSH_PORT" ]] && continue
        kept+=( "$p" )
    done

    if (( ${#kept[@]} > 0 )); then
        if ui_confirm "确认 22 登录正常后，是否保留旧端口 ${kept[*]}？"; then
            local -a all=( "$DEFAULT_SSH_PORT" "${kept[@]}" )
            if ! ssh_config_ports_managed_write "${all[@]}"; then
                ssh_config_restore_backup "$backup" || true
                ssh_restart >/dev/null 2>&1 || true
                ui_error "写入管理块失败，已恢复。"
                return 1
            fi
            if ! ssh_config_test || ! ssh_restart; then
                ssh_config_restore_backup "$backup" || true
                ssh_restart >/dev/null 2>&1 || true
                ui_error "应用保留端口失败，已恢复。"
                return 1
            fi
            ui_success "已保留旧端口：$(ssh_config_ports_text)"
        else
            for p in "${kept[@]}"; do
                ssh_ufw_remove_rule_one "$p"
            done
            ui_success "旧端口已从 UFW 规则中移除。"
        fi
    fi
}

ssh_remove_port() {
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }

    local -a current=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        current+=( "$p" )
    done < <(ssh_config_ports_effective)

    if (( ${#current[@]} <= 1 )); then
        ui_error "当前只有 1 个端口（${current[*]:-无}），删除会导致 SSH 无法监听。"
        ui_info "如需更换端口，请使用「修改 SSH 端口」。"
        return 1
    fi

    echo "当前 SSH 端口：${current[*]}"
    echo "请输入要删除的端口（空格或逗号分隔，可多选）："
    local input
    read -r -p "> " input
    [[ -n "$input" ]] || { ui_error "未输入端口。"; return 1; }

    input="${input//,/ }"
    if [[ ! "$input" =~ ^[0-9[:space:]]+$ ]]; then
        ui_error "端口只能使用数字、空格或逗号。"
        return 1
    fi

    local -a remove_list=()
    local token found
    for token in $input; do
        [[ "$token" =~ ^[0-9]+$ ]] || { ui_error "无效端口：$token"; return 1; }
        found=0
        for p in "${current[@]}"; do
            if [[ "$p" == "$token" ]]; then
                found=1
                break
            fi
        done
        (( found == 1 )) || { ui_error "端口 $token 不在当前监听列表中。"; return 1; }
        local dup=0
        local r
        for r in "${remove_list[@]}"; do
            [[ "$r" == "$token" ]] && { dup=1; break; }
        done
        (( dup == 0 )) && remove_list+=( "$token" )
    done

    if (( ${#remove_list[@]} == 0 )); then
        ui_error "没有有效的待删除端口。"
        return 1
    fi

    if (( ${#remove_list[@]} >= ${#current[@]} )); then
        ui_error "不能删除全部端口，至少保留 1 个。"
        return 1
    fi

    local -a remaining=()
    for p in "${current[@]}"; do
        local is_remove=0
        local r
        for r in "${remove_list[@]}"; do
            [[ "$p" == "$r" ]] && { is_remove=1; break; }
        done
        (( is_remove == 0 )) && remaining+=( "$p" )
    done

    echo ""
    echo "将删除端口：${remove_list[*]}"
    echo "保留端口：${remaining[*]}"
    ui_warning "如果你当前正通过被删端口连接，操作完成后会断连。"
    ui_confirm "确认删除？" || return 0

    local backup
    backup="$(ssh_config_backup)" || { ui_error "无法备份 SSH 配置。"; return 1; }

    if ! ssh_config_ports_original_comment; then
        ui_error "无法注释原有 Port 行，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_config_ports_managed_write "${remaining[@]}"; then
        ui_error "写入管理块失败，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        return 1
    fi

    if ! ssh_restart; then
        ui_error "SSH 重启失败，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        return 1
    fi

    sleep 1

    local ok=1
    for p in "${remaining[@]}"; do
        if ! ssh_verify_port "$p"; then
            ok=0
            break
        fi
    done

    if (( ok == 0 )); then
        ui_error "剩余端口未全部生效，恢复配置。"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        return 1
    fi

    local r
    for r in "${remove_list[@]}"; do
        ssh_ufw_remove_rule_one "$r"
    done

    ui_success "已删除端口：${remove_list[*]}"
    ui_success "当前 SSH 端口：$(ssh_config_ports_text)"
}

# ============================================================
# 9. SSH 密钥/安全业务层
# ============================================================

ssh_user_default() {
    local sudo_user
    sudo_user="$(printenv SUDO_USER 2>/dev/null || true)"
    if [[ -n "$sudo_user" ]] && id "$sudo_user" >/dev/null 2>&1; then
        DEFAULT_SSH_USER="$sudo_user"
    else
        DEFAULT_SSH_USER="root"
    fi
}

ssh_key_normalize() {
    local key="$1" decoded_type
    key="$(printf '%s' "$key" | tr -d '\r\n')"
    if [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+([^[:space:]]+)([[:space:]].*)?$ ]]; then
        printf '%s\n' "$key"
        return 0
    fi
    if [[ "$key" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
        decoded_type="$(printf '%s' "$key" | base64 -d 2>/dev/null | grep -a -o -m1 -E 'ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com' || true)"
        case "$decoded_type" in
            ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
                printf '%s %s\n' "$decoded_type" "$key"
                return 0 ;;
        esac
    fi
    return 1
}

ssh_key_configure() {
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }
    local target_user="$DEFAULT_SSH_USER"
    echo "当前目标用户：$target_user"
    local selected
    read -r -p "输入其他本地用户名（直接 Enter 保持）: " selected
    if [[ -n "$selected" ]]; then
        id "$selected" >/dev/null 2>&1 || { ui_error "用户不存在。"; return 1; }
        target_user="$selected"
    fi

    local home_dir ssh_dir auth_keys public_key normalized
    home_dir="$(getent passwd "$target_user" | cut -d: -f6 2>/dev/null || true)"
    [[ -n "$home_dir" ]] || home_dir="/root"
    ssh_dir="$home_dir/.ssh"
    auth_keys="$ssh_dir/authorized_keys"
    echo "支持完整 OpenSSH 公钥，例如：ssh-ed25519 AAAA..."
    echo "也支持仅粘贴 base64 密钥主体，例如：AAAA..."
    read -r -p "请粘贴 SSH 公钥（Enter 跳过）: " public_key
    if [[ -z "$public_key" ]]; then
        ui_info "跳过配置公钥。"
        return 0
    fi
    normalized="$(ssh_key_normalize "$public_key")" || {
        ui_error "公钥格式无法识别，请粘贴有效的 OpenSSH 公钥。"
        return 1
    }

    if sys_command_exists ssh-keygen; then
        local tmp_key
        tmp_key="$(mktemp)"
        printf '%s\n' "$normalized" > "$tmp_key"
        if ! ssh-keygen -lf "$tmp_key" >/dev/null 2>&1; then
            rm -f "$tmp_key"
            ui_error "公钥内容校验失败。"
            return 1
        fi
        rm -f "$tmp_key"
    fi

    mkdir -p "$ssh_dir" || return 1
    chmod 700 "$ssh_dir" || return 1
    if [[ -f "$auth_keys" ]]; then
        cp -a "$auth_keys" "$auth_keys.bak.$(date +%Y%m%d%H%M%S)" || return 1
    fi
    printf '%s\n' "$normalized" >> "$auth_keys" || return 1
    chmod 600 "$auth_keys" || return 1
    if [[ "$target_user" != "root" ]]; then
        chown -R "$target_user" "$ssh_dir" || return 1
    fi
    ui_success "公钥已写入 $auth_keys"
    ui_info "识别结果：$(printf '%s' "$normalized" | awk '{print $1}')"
}

ssh_optimize_security() {
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }
    ssh_config_ensure || return 1
    ssh_config_ensure_include || return 1

    # 检查 sshd_config.d/ 中字母序在 99 之前的文件是否包含冲突指令
    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        local conflict_files=()
        local d base
        for d in "$SSHD_CONFIG_DIR"/*.conf; do
            [[ -f "$d" ]] || continue
            [[ "$d" == "$SECURITY_CONF" ]] && continue
            base="$(basename "$d")"
            # 只检查字母序在 "99-" 之前的文件
            [[ "$base" < "99-" ]] || continue
            if grep -qE '^[[:space:]]*(PubkeyAuthentication|PermitEmptyPasswords|MaxAuthTries|X11Forwarding|ChallengeResponseAuthentication|KbdInteractiveAuthentication|KerberosAuthentication|GSSAPIAuthentication)[[:space:]]' "$d"; then
                conflict_files+=( "$d" )
            fi
        done
        if (( ${#conflict_files[@]} > 0 )); then
            ui_warning "以下文件包含与安全配置冲突的指令（字母序在 99 之前，会覆盖本脚本配置）："
            local f
            for f in "${conflict_files[@]}"; do
                ui_warning "  $f"
            done
            ui_info "本脚本写入的 99-ufwssh-security.conf 部分指令可能不生效。"
            ui_info "如需强制生效，可手动检查上述文件。"
        fi
    fi

    local backup
    backup="$(ssh_config_backup)" || return 1
    mkdir -p "$SSHD_CONFIG_DIR"

    cat > "$SECURITY_CONF" <<'EOF'
# Managed by ufwssh
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 5
X11Forwarding no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF

    if [[ "$OS_TYPE" == "debian" ]]; then
        cat >> "$SECURITY_CONF" <<'EOF'
KerberosAuthentication no
GSSAPIAuthentication no
EOF
    fi

    if ! ssh_config_test || ! ssh_restart; then
        rm -f "$SECURITY_CONF"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        ui_error "SSH 安全配置失败，已回滚。"
        return 1
    fi
    ui_success "SSH 基础安全配置已应用。"
}

# ---- 密码登录开关（Match All 块） ----

ssh_password_auth_is_enabled() {
    ssh_is_installed || return 1
    local value
    value="$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2; exit}')"
    [[ "$value" == "yes" ]]
}

ssh_password_auth_has_pubkey() {
    local user home auth_keys perm
    local found_bad_perm=0
    local -a users=()

    users+=( "root" )
    if [[ -n "${DEFAULT_SSH_USER:-}" && "$DEFAULT_SSH_USER" != "root" ]]; then
        users+=( "$DEFAULT_SSH_USER" )
    fi
    if [[ -d /home ]]; then
        local d
        for d in /home/*; do
            [[ -d "$d" ]] || continue
            users+=( "$(basename "$d")" )
        done
    fi

    for user in "${users[@]}"; do
        id "$user" >/dev/null 2>&1 || continue
        home="$(getent passwd "$user" | cut -d: -f6 2>/dev/null || true)"
        [[ -n "$home" ]] || continue
        auth_keys="$home/.ssh/authorized_keys"
        [[ -s "$auth_keys" ]] || continue

        perm="$(stat -c '%a' "$auth_keys" 2>/dev/null || echo "")"
        case "$perm" in
            600|400)
                return 0
                ;;
            *)
                ui_warning "公钥权限不正确（$perm）：$auth_keys（应为 600 或 400）"
                found_bad_perm=1
                ;;
        esac
    done
    (( found_bad_perm == 1 )) && return 1
    return 1
}

ssh_password_auth_block_remove() {
    if grep -qF "$MANAGED_PW_BEGIN" "$SSHD_CONFIG"; then
        awk -v begin="$MANAGED_PW_BEGIN" -v end="$MANAGED_PW_END" '
            BEGIN { in_block=0 }
            $0 == begin { in_block=1; next }
            $0 == end { in_block=0; next }
            in_block == 1 { next }
            { print }
        ' "$SSHD_CONFIG" > "$SSHD_CONFIG.tmp" && mv "$SSHD_CONFIG.tmp" "$SSHD_CONFIG" || {
            rm -f "$SSHD_CONFIG.tmp"
            return 1
        }
    fi
    return 0
}

# 注释主文件里已有的裸 PasswordAuthentication 行
# 只处理第一个 Match 块之前的行，避免误伤 Match 块内配置
ssh_password_auth_original_comment() {
    local line
    local changed=0

    # 第一遍：检查第一个 Match 之前是否有裸 PasswordAuthentication 行
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*Match[[:space:]] ]] && break
        [[ "$line" == "$ORIGINAL_PW_PREFIX"* ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*PasswordAuthentication[[:space:]]+ ]]; then
            changed=1
            break
        fi
    done < "$SSHD_CONFIG"
    (( changed == 0 )) && return 0

    # 第二遍：只注释第一个 Match 之前的裸行
    awk -v prefix="$ORIGINAL_PW_PREFIX" '
        BEGIN { in_match=0 }
        /^[[:space:]]*Match[[:space:]]/ { in_match=1 }
        !in_match && /^[[:space:]]*PasswordAuthentication[[:space:]]+/ {
            line=$0
            match(line, /^[[:space:]]*/); lead=substr(line, 1, RLENGTH)
            print lead prefix " " substr(line, RLENGTH+1)
            next
        }
        { print }
    ' "$SSHD_CONFIG" > "$SSHD_CONFIG.tmp" && mv "$SSHD_CONFIG.tmp" "$SSHD_CONFIG" || {
        rm -f "$SSHD_CONFIG.tmp"
        return 1
    }
    return 0
}

ssh_password_auth_write_block() {
    local enabled="$1"

    {
        printf '\n%s\n' "$MANAGED_PW_BEGIN"
        printf 'Match All\n'
        printf '    PasswordAuthentication %s\n' "$enabled"
        printf '%s\n' "$MANAGED_PW_END"
    } >> "$SSHD_CONFIG" || return 1

    return 0
}

ssh_password_auth_set() {
    local enabled="$1"
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }

    [[ "$enabled" == "yes" || "$enabled" == "no" ]] || {
        ui_error "内部错误：无效参数 $enabled"
        return 1
    }

    ssh_config_ensure || return 1

    local backup
    backup="$(ssh_config_backup)" || { ui_error "无法备份 SSH 配置。"; return 1; }

    if ! ssh_password_auth_block_remove; then
        ssh_config_restore_backup "$backup" || true
        ui_error "删除旧管理块失败，已恢复。"
        return 1
    fi

    if ! ssh_password_auth_original_comment; then
        ssh_config_restore_backup "$backup" || true
        ui_error "注释原有 PasswordAuthentication 行失败，已恢复。"
        return 1
    fi

    if ! ssh_password_auth_write_block "$enabled"; then
        ssh_config_restore_backup "$backup" || true
        ui_error "写入管理块失败，已恢复。"
        return 1
    fi

    if ! ssh_config_test; then
        ssh_config_restore_backup "$backup" || true
        ui_error "SSH 配置语法检查失败，已恢复。"
        return 1
    fi

    if ! ssh_restart; then
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        ui_error "SSH 重启失败，已恢复。"
        return 1
    fi

    sleep 1

    local actual
    actual="$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" {print $2; exit}')"
    if [[ "$actual" != "$enabled" ]]; then
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        ui_error "密码登录设置未生效（当前：$actual），已恢复。"
        return 1
    fi

    return 0
}

ssh_password_auth_menu() {
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }

    while true; do
        local status
        if ssh_password_auth_is_enabled; then
            status="${GREEN}已开启$NC"
        else
            status="${RED}已关闭$NC"
        fi

        ui_print_banner
        echo "========== 密码登录开关 =========="
        echo -e "当前状态：$status"
        echo ""
        echo "  说明："
        echo "    开启：允许用密码登录（PasswordAuthentication yes）"
        echo "    关闭：仅允许公钥登录（PasswordAuthentication no）"
        echo ""
        echo "  1) 开启密码登录"
        echo "  2) 关闭密码登录"
        echo "  0) 返回"
        echo "----------------------------------"
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                if ssh_password_auth_is_enabled; then
                    ui_info "密码登录已经是开启状态。"
                    ui_pause
                    continue
                fi
                if ui_confirm "确定开启密码登录？"; then
                    if ssh_password_auth_set "yes"; then
                        ui_success "密码登录已开启。"
                    fi
                fi
                ui_pause
                ;;
            2)
                if ! ssh_password_auth_is_enabled; then
                    ui_info "密码登录已经是关闭状态。"
                    ui_pause
                    continue
                fi
                if ! ssh_password_auth_has_pubkey; then
                    ui_error "未检测到任何用户配置了有效 SSH 公钥（权限需为 600 或 400）。"
                    ui_info "关闭密码登录后你将无法登录。"
                    ui_info "请先用「配置 SSH 公钥」添加公钥。"
                    ui_pause
                    continue
                fi
                ui_warning "关闭密码登录后，仅允许公钥登录。"
                ui_warning "请确保你已配置公钥并能正常登录。"
                if ui_confirm "确定关闭密码登录？"; then
                    if ssh_password_auth_set "no"; then
                        ui_success "密码登录已关闭，仅允许公钥登录。"
                        ui_info "如断连，请用公钥重新连接。"
                    fi
                fi
                ui_pause
                ;;
            0) return 0 ;;
            *) ui_error "无效选择。" ;;
        esac
    done
}

# ============================================================
# 10. 安装业务层
# ============================================================

pkg_debian_install() {
    local package="${1:-}" backup profile
    [[ -n "$package" ]] || { ui_error "未指定 Debian/Ubuntu 软件包。"; return 1; }
    sys_command_exists apt-get || { ui_error "未找到 apt-get。"; return 1; }
    ui_info "刷新 Debian/Ubuntu 软件源..."
    if ! apt-get update; then
        ui_warning "APT update 失败，继续尝试安装（可能使用旧索引）。"
    fi
    if src_debian_package_available "$package"; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
        return $?
    fi
    ui_warning "当前 APT 源无法提供 $package，开始尝试官方源和备用镜像。"
    backup="$(src_backup)" || { ui_error "无法创建 APT 软件源备份，停止自动换源。"; return 1; }
    for profile in official tuna; do
        if src_debian_try_profile "$profile" "$package"; then
            ui_success "已找到 $package：$profile"
            if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
                return 0
            fi
            ui_warning "$profile 已找到 $package，但安装失败，继续尝试其他源。"
        fi
    done
    ui_error "无法从当前源、官方源或备用镜像安装 $package。"
    src_restore_backup "$backup"
    return 1
}

pkg_alpine_install() {
    local package="${1:-}" branch backup profile
    [[ -n "$package" ]] || { ui_error "未指定 Alpine 软件包。"; return 1; }

    if src_alpine_refresh; then
        if src_alpine_install_from_repos "$package"; then
            return 0
        fi
    fi

    branch="$(src_alpine_version_branch)"
    [[ -n "$branch" ]] || { ui_error "无法确定 Alpine 稳定仓库分支。"; return 1; }

    backup="$(src_backup)" || {
        ui_error "无法创建 APK 软件源备份，停止自动换源。"
        return 1
    }

    ui_warning "当前 Alpine 源无法提供 $package，切换官方源：stable main/community + edge main/community。"
    src_alpine_write_official "$branch"
    if src_alpine_refresh && src_alpine_install_from_repos "$package"; then
        return 0
    fi

    ui_warning "官方源安装失败，切换 TUNA：stable main/community + edge main/community。"
    src_alpine_write_tuna "$branch"
    if src_alpine_refresh && src_alpine_install_from_repos "$package"; then
        return 0
    fi

    ui_error "无法从当前源、官方源或 TUNA 源安装 $package。"
    src_restore_backup "$backup"
    return 1
}

install_ssh() {
    case "$OS_TYPE" in
        debian)
            ui_info "Debian/Ubuntu：安装 OpenSSH Server..."
            if ! ssh_is_installed; then
                pkg_debian_install openssh-server || return 1
            fi
            ssh_detect_service
            [[ -n "$SSH_SERVICE" ]] || { ui_error "无法检测 SSH 服务。"; return 1; }
            mkdir -p "$SSHD_CONFIG_DIR"
            ssh-keygen -A >/dev/null 2>&1 || true
            ssh_is_running || ssh_start || return 1
            ssh_enable >/dev/null 2>&1 || ui_warning "无法设置 SSH 开机自启。"
            ui_success "Debian/Ubuntu SSH 安装/修复完成。"
            ;;
        alpine)
            ui_info "Alpine Linux：安装 OpenSSH..."
            if ! ssh_is_installed; then
                pkg_alpine_install openssh || return 1
            fi
            SSH_SERVICE="sshd"
            mkdir -p "$SSHD_CONFIG_DIR"
            ssh-keygen -A >/dev/null 2>&1 || true
            ssh_is_running || ssh_start || return 1
            ssh_enable >/dev/null 2>&1 || ui_warning "无法设置 sshd 开机自启。"
            ui_success "Alpine SSH 安装/修复完成（OpenRC）。"
            ;;
        *) ui_error "当前系统不支持 SSH 安装。"; return 1 ;;
    esac
}

install_ufw() {
    case "$OS_TYPE" in
        debian)
            ui_info "Debian/Ubuntu：安装 UFW..."
            if ! ufw_is_installed; then
                pkg_debian_install ufw || return 1
            fi
            ufw_configure_ipv6
            ui_success "Debian/Ubuntu UFW 安装/修复完成。"
            ;;
        alpine)
            ui_info "Alpine Linux：安装 UFW..."
            if ufw_is_installed; then
                ufw_configure_ipv6
                ui_success "Alpine UFW 已安装。"
                return 0
            fi
            pkg_alpine_install ufw || return 1
            ufw_configure_ipv6
            ui_success "Alpine UFW 安装完成。"
            ;;
        *) ui_error "当前系统不支持 UFW 安装。"; return 1 ;;
    esac
}

install_all() {
    ui_info "开始安装/修复 SSH + UFW..."
    install_ssh || return 1
    install_ufw || return 1
    ui_success "SSH + UFW 安装/修复完成。"
}

install_quick_summary() {
    echo ""
    ui_success "========== 快捷安装完成 =========="
    echo "  SSH 端口   : $(ssh_config_ports_text)"
    if ssh_password_auth_is_enabled; then
        echo -e "  密码登录   : ${GREEN}已开启$NC"
    else
        echo -e "  密码登录   : ${RED}已关闭$NC"
    fi
    echo "  UFW        : $(ufw_status_text)"
    if ufw_is_installed; then
        echo ""
        echo "  SSH 规则："
        ufw status 2>/dev/null | grep -E '/tcp.*(LIMIT|ALLOW).*# SSH' | sed 's/^/    /' || true
    fi
}

install_quick_init() {
    ui_print_banner
    echo "========== 快捷安装与配置 =========="
    echo ""
    echo "即将执行："
    echo "  1. 安装/修复 SSH"
    echo "  2. 安装/修复 UFW"
    echo "  3. 修改 SSH 端口（Enter 跳过）"
    echo "  4. 配置 SSH 公钥（Enter 跳过）"
    echo "  5. 关闭密码登录（已配公钥则自动关闭，否则跳过）"
    echo "  6. 同步 SSH UFW 规则（limit）"
    echo "  7. 启用 UFW"
    echo ""
    ui_confirm "继续？" || return 0

    echo ""
    echo "[1/7] 安装/修复 SSH..."
    if ! install_ssh; then
        ui_error "SSH 安装失败，中止。"
        return 1
    fi

    echo ""
    echo "[2/7] 安装/修复 UFW..."
    if ! install_ufw; then
        ui_error "UFW 安装失败，中止。"
        return 1
    fi

    echo ""
    echo "[3/7] 修改 SSH 端口..."
    ssh_change_port || ui_warning "端口修改失败，继续后续步骤。"

    echo ""
    echo "[4/7] 配置 SSH 公钥..."
    ssh_key_configure || ui_warning "公钥配置失败，继续后续步骤。"

    echo ""
    echo "[5/7] 关闭密码登录..."
    if ! ssh_password_auth_is_enabled; then
        echo "      密码登录已关闭，跳过。"
    elif ssh_password_auth_has_pubkey; then
        echo "      已检测到公钥，正在关闭..."
        if ssh_password_auth_set "no"; then
            ui_success "      密码登录已关闭。"
        else
            ui_warning "      关闭失败，保持现状。"
        fi
    else
        echo "      未检测到有效公钥，跳过。"
    fi

    echo ""
    echo "[6/7] 同步 SSH UFW 规则..."
    if ! ssh_ufw_sync; then
        ui_error "同步失败，中止。"
        return 1
    fi
    ui_success "      同步完成。"

    echo ""
    echo "[7/7] 启用 UFW..."
    if ! ufw_enable_safely; then
        ui_error "启用 UFW 失败，中止。"
        return 1
    fi
    ui_success "      UFW 已启用。"

    install_quick_summary
}

# ============================================================
# 11. 软件源业务层
# ============================================================

src_repair_debian() {
    local backup profile
    backup="$(src_backup)" || { ui_error "无法创建 APT 软件源备份。"; return 1; }
    for profile in official tuna; do
        if src_debian_try_profile "$profile" openssh-server ufw; then
            ui_success "APT 软件源已切换并验证成功：$profile"
            echo "备份：$backup"
            return 0
        fi
    done
    ui_error "官方源与备用镜像均无法提供所需软件包，恢复原 APT 配置。"
    src_restore_backup "$backup"
    return 1
}

src_repair_alpine() {
    local branch backup profile
    branch="$(src_alpine_version_branch)"
    [[ -n "$branch" ]] || { ui_error "无法从 Alpine 版本 $OS_VERSION 推导稳定仓库分支。"; return 1; }
    backup="$(src_backup)" || { ui_error "无法创建 APK 软件源备份。"; return 1; }
    for profile in official tuna; do
        if src_alpine_try_profile "$profile" "$branch" openssh ufw; then
            ui_success "APK 软件源已切换并验证成功：$profile / $branch"
            echo "备份：$backup"
            return 0
        fi
    done
    ui_error "官方源与备用镜像均无法提供所需软件包，恢复原 APK 配置。"
    src_restore_backup "$backup"
    return 1
}

src_repair() {
    case "$OS_TYPE" in
        debian) src_repair_debian ;;
        alpine) src_repair_alpine ;;
        *) ui_error "当前系统不支持软件源自动修复。"; return 1 ;;
    esac
}

src_switch_alpine_tuna() {
    local branch backup
    branch="$(src_alpine_version_branch)"
    [[ -n "$branch" ]] || { ui_error "无法从 Alpine 版本 $OS_VERSION 推导稳定仓库分支。"; return 1; }
    backup="$(src_backup)" || { ui_error "无法创建 APK 软件源备份。"; return 1; }
    if src_alpine_try_profile tuna "$branch" openssh ufw; then
        ui_success "APK 已切换到清华 TUNA 镜像：$branch"
        echo "备份：$backup"
        return 0
    fi
    ui_error "TUNA 镜像无法提供所需软件包，恢复原 APK 配置。"
    src_restore_backup "$backup"
    return 1
}

src_switch_debian_tuna() {
    local backup
    backup="$(src_backup)" || { ui_error "无法创建 APT 软件源备份。"; return 1; }
    if src_debian_try_profile tuna openssh-server ufw; then
        ui_success "APT 已切换到清华 TUNA 镜像。"
        echo "备份：$backup"
        return 0
    fi
    ui_error "TUNA 镜像无法提供所需软件包，恢复原 APT 配置。"
    src_restore_backup "$backup"
    return 1
}

src_show_status() {
    ui_print_banner
    echo "========== 软件源状态 =========="
    case "$OS_TYPE" in
        debian)
            echo "APT 软件源文件："
            if [[ -f /etc/apt/sources.list ]]; then
                echo "  /etc/apt/sources.list"
                sed 's/^/    /' /etc/apt/sources.list
            fi
            local file
            while IFS= read -r file; do
                [[ -n "$file" ]] || continue
                echo "  $file"
                sed 's/^/    /' "$file"
            done < <(src_debian_files)
            echo ""
            src_debian_package_available openssh-server && ui_success "APT：openssh-server 可用。" || ui_warning "APT：openssh-server 当前不可用。"
            src_debian_package_available ufw && ui_success "APT：ufw 可用。" || ui_warning "APT：ufw 当前不可用。"
            ;;
        alpine)
            echo "APK 软件源："
            if [[ -f /etc/apk/repositories ]]; then
                sed 's/^/  /' /etc/apk/repositories
            else
                echo "  /etc/apk/repositories（不存在）"
            fi
            echo ""
            src_alpine_package_available openssh && ui_success "APK：openssh 可用。" || ui_warning "APK：openssh 当前不可用。"
            src_alpine_package_available ufw && ui_success "APK：ufw 可用。" || ui_warning "APK：ufw 当前不可用。"
            ;;
        *) ui_error "未知系统。" ;;
    esac
    echo ""
    echo "最近备份：$(src_backup_latest 2>/dev/null || echo '无')"
}

# ============================================================
# 12. 状态展示层
# ============================================================

ui_show_component_status() {
    ssh_detect_service
    local ports_text
    ports_text="$(ssh_config_ports_text)"

    echo -e "${CYAN}系统信息${NC}"
    echo "  系统       : $OS_NAME $OS_VERSION"
    echo "  架构       : $(uname -m)"
    echo "  服务管理器 : $(sys_service_manager)"
    echo ""
    echo -e "${CYAN}组件状态${NC}"

    if ssh_is_installed; then
        if ssh_is_running; then
            echo -e "  SSH        : $GREEN● 已安装 / 运行中$NC"
        else
            echo -e "  SSH        : $YELLOW● 已安装 / 未运行$NC"
        fi
        echo "  SSH 服务   : $SSH_SERVICE"
        echo "  开机自启   : $(ssh_is_enabled && echo '是' || echo '否')"
        echo "  SSH 端口   : $ports_text"
        if ssh_password_auth_is_enabled; then
            echo -e "  密码登录   : ${GREEN}已开启$NC"
        else
            echo -e "  密码登录   : ${RED}已关闭$NC"
        fi
    else
        echo -e "  SSH        : $YELLOW○ 未安装$NC"
    fi

    echo "  UFW        : $(ufw_status_text)"
    echo ""
}

ui_show_detailed_status() {
    ui_print_banner
    ui_show_component_status
    echo -e "${CYAN}SSH 监听${NC}"
    if sys_command_exists ss; then
        ss -lntp 2>/dev/null || true
    else
        echo "  未安装 ss。"
    fi
    echo ""
    echo -e "${CYAN}UFW 规则${NC}"
    if ufw_is_installed; then
        ufw status verbose
        echo ""
        ufw status numbered
    else
        echo "  UFW 未安装。"
    fi
}

# ============================================================
# 13. 菜单层
# ============================================================

menu_install() {
    local choice
    while true; do
        ui_print_banner
        echo "========== 组件安装 =========="
        echo "系统：$OS_NAME $OS_VERSION"
        echo "SSH：$(ssh_status_text)"
        echo "UFW：$(ufw_status_text)"
        echo ""
        echo "  1) 安装/修复 SSH"
        echo "  2) 安装/修复 UFW"
        echo "  3) 安装/修复 SSH + UFW"
        echo "  4) 快捷安装与配置"
        echo "  0) 返回"
        echo "------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_ssh; ui_pause ;;
            2) install_ufw; ui_pause ;;
            3) install_all; ui_pause ;;
            4) install_quick_init; ui_pause ;;
            0) return 0 ;;
            *) ui_error "无效选择。" ;;
        esac
    done
}

menu_source() {
    local choice
    while true; do
        ui_print_banner
        echo "========== 软件源管理 =========="
        echo "系统：$OS_NAME $OS_VERSION"
        echo ""
        echo "  1) 检测当前软件源"
        echo "  2) 自动修复（官方源 → 备用镜像）"
        if [[ "$OS_TYPE" == "alpine" ]]; then
            echo "  3) 切换 Alpine 清华 TUNA 镜像"
        else
            echo "  3) 切换 Debian/Ubuntu 清华 TUNA 镜像"
        fi
        echo "  4) 恢复最近一次备份"
        echo "  0) 返回"
        echo "--------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) src_show_status; ui_pause ;;
            2) src_repair; ui_pause ;;
            3) if [[ "$OS_TYPE" == "alpine" ]]; then src_switch_alpine_tuna; else src_switch_debian_tuna; fi; ui_pause ;;
            4) src_restore_backup; ui_pause ;;
            0) return 0 ;;
            *) ui_error "无效选择。" ;;
        esac
    done
}

menu_ssh_port() {
    local choice ports_text
    while true; do
        ports_text="$(ssh_config_ports_text)"
        ui_print_banner
        echo "========== SSH 端口管理 =========="
        echo "服务：$SSH_SERVICE"
        echo "当前端口：$ports_text"
        echo ""
        echo "  1) 修改 SSH 端口"
        echo "  2) 查看当前端口"
        echo "  3) 恢复默认端口 22"
        echo "  4) 删除 SSH 端口"
        echo "  5) 测试 SSH 配置"
        echo "  6) 重启 SSH"
        echo "  0) 返回"
        echo "----------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) ssh_change_port; ui_pause ;;
            2)
                echo "当前端口：$(ssh_config_ports_text)"
                echo ""
                echo "监听情况："
                local port
                while IFS= read -r port; do
                    [[ -n "$port" ]] || continue
                    if ssh_port_is_listening "$port"; then
                        if sys_command_exists ss; then
                            ss -lntp 2>/dev/null | grep -E ":${port}([[:space:]]|$)" || echo "  端口 $port 已监听"
                        else
                            echo "  端口 $port 已监听"
                        fi
                    else
                        echo "  端口 $port 未监听"
                    fi
                done < <(ssh_config_ports_effective)
                ui_pause
                ;;
            3) ssh_restore_default_port; ui_pause ;;
            4) ssh_remove_port; ui_pause ;;
            5) ssh_config_test; ui_pause ;;
            6) ssh_restart && ui_success "SSH 已重启。" || ui_error "SSH 重启失败。"; ui_pause ;;
            0) return 0 ;;
            *) ui_error "无效选择。" ;;
        esac
    done
}

menu_ufw() {
    local choice
    while true; do
        ui_print_banner
        echo "========== UFW 防火墙管理 =========="
        echo "状态：$(ufw_status_text)"
        echo ""
        if ufw_is_installed; then
            ufw status | head -5 || true
        fi
        echo ""
        echo "  1) 查看详细规则"
        echo "  2) 添加规则"
        echo "  3) 删除规则"
        echo "  4) 修改默认策略"
        echo "  5) 启用 UFW（自动保护 SSH）"
        echo "  6) 禁用 UFW"
        echo "  7) 重载 UFW"
        echo "  8) 重置 UFW"
        echo "  0) 返回"
        echo "------------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) ufw_show_rules; ui_pause ;;
            2) ufw_add_rule; ui_pause ;;
            3) ufw_delete_rule; ui_pause ;;
            4) ufw_change_defaults; ui_pause ;;
            5) ufw_enable_safely; ui_pause ;;
            6) ui_confirm "确定禁用 UFW？" && ufw disable; ui_pause ;;
            7) ufw reload; ui_pause ;;
            8) ufw_reset; ui_pause ;;
            0) return 0 ;;
            *) ui_error "无效选择。" ;;
        esac
    done
}

menu_ssh_service() {
    local choice
    while true; do
        ui_print_banner
        ssh_detect_service
        echo "========== SSH 服务管理 =========="
        echo "服务：$SSH_SERVICE"
        echo "状态：$(ssh_status_text)"
        echo "端口：$(ssh_config_ports_text)"
        echo ""
        echo "  1) 启动 SSH"
        echo "  2) 停止 SSH"
        echo "  3) 重启 SSH"
        echo "  4) 设置开机自启"
        echo "  5) 取消开机自启"
        echo "  6) 配置 SSH 公钥"
        echo "  7) 应用 SSH 基础安全配置"
        echo "  8) 密码登录开关"
        echo "  0) 返回"
        echo "----------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) ssh_start && ui_success "SSH 已启动。" || ui_error "SSH 启动失败。"; ui_pause ;;
            2) ssh_stop && ui_success "SSH 已停止。" || ui_error "SSH 停止失败。"; ui_pause ;;
            3) ssh_restart && ui_success "SSH 已重启。" || ui_error "SSH 重启失败。"; ui_pause ;;
            4) ssh_enable && ui_success "SSH 已设置开机自启。" || ui_error "设置失败。"; ui_pause ;;
            5) ssh_disable && ui_success "SSH 已取消开机自启。" || ui_error "取消失败。"; ui_pause ;;
            6) ssh_key_configure; ui_pause ;;
            7) ssh_optimize_security; ui_pause ;;
            8) ssh_password_auth_menu ;;
            0) return 0 ;;
            *) ui_error "无效选择。" ;;
        esac
    done
}

menu_main() {
    local choice
    while true; do
        ui_print_banner
        ui_show_component_status
        echo "------------------------------------------------------------"
        echo "  1) 安装 SSH + UFW"
        echo "  2) 软件源管理"
        echo "  3) SSH 端口管理"
        echo "  4) UFW 防火墙规则管理"
        echo "  5) SSH 服务管理"
        echo "  6) 查看详细状态"
        echo "  7) 重置 UFW"
        echo "  0) 退出"
        echo "------------------------------------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) menu_install ;;
            2) menu_source ;;
            3) menu_ssh_port ;;
            4) menu_ufw ;;
            5) menu_ssh_service ;;
            6) ui_show_detailed_status; ui_pause ;;
            7) ufw_reset; ui_pause ;;
            0) return 0 ;;
            *) ui_error "无效选择。" ;;
        esac
    done
}

# ============================================================
# 14. 入口
# ============================================================

main() {
    sys_check_root || exit 1
    sys_detect_os || exit 1
    ssh_user_default
    ssh_detect_service
    menu_main
}

main "$@"
