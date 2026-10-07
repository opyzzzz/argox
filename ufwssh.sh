#!/bin/bash
#
# UFW + SSH 交互式管理工具 v4.3
# Debian/Ubuntu: apt + systemd
# Alpine Linux:  apk + OpenRC
#
# v4.3 变更：
#   - SSH 规则由 allow 改为 limit（缓解暴力破解）
#   - 已存在 allow 规则时先删除再 limit，避免叠加
#   - 旧端口清理同时尝试 delete limit / delete allow
#   - ufw_show_rules 只显示 verbose，去除重复
#
# v4.2 修复清单：
#   - 消除 alpine_packages_available 嵌套定义
#   - delete_ufw_rule 不再把 "12" 拆成 "#1 #2"
#   - enable_ufw_safely 放行全部监听端口
#   - Alpine 确保 sshd_config 含 Include sshd_config.d/*.conf
#   - detect_ssh_service Alpine grep -qx -> grep -qw
#   - configure_ssh_key chown 仅改属主
#   - 补 KbdInteractiveAuthentication no
#   - remove_ssh_port 清理历史注释
#   - get_ssh_port 返回主端口，新增 get_all_ssh_ports
#   - debian_disable_existing_sources 打印被禁用文件
#   - SSH_USER 拆为 DEFAULT_SSH_USER + 局部 target_user
#   - 菜单 choice 全部 local
#   - 函数按域统一前缀重命名
#

set -uo pipefail

# ============================================================
# 0. 常量
# ============================================================

SCRIPT_VERSION="v4.3"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
UFW_DEFAULT="/etc/default/ufw"
DEFAULT_SSH_PORT=22

SOURCE_BACKUP_ROOT="/etc/ufwssh/source-backups"
SSH_BACKUP_ROOT="/etc/ufwssh/ssh-backups"
DEBIAN_MANAGED_SOURCE="/etc/apt/sources.list.d/ufwssh-official.sources"
DEBIAN_MANAGED_LEGACY_SOURCE="/etc/apt/sources.list.d/ufwssh-official.list"
ALPINE_MANAGED_SOURCE="/etc/apk/repositories"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局状态
OS_TYPE=""
OS_NAME=""
OS_VERSION=""
SSH_SERVICE=""
DEFAULT_SSH_USER="root"
CURRENT_SSH_PORT="$DEFAULT_SSH_PORT"

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

# ---- Debian/Ubuntu 软件源 ----

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

# ---- Alpine 软件源 ----

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
    if [[ "$package" == "ufw" ]] && src_alpine_edge_package_available "$package" "edge-community"; then
        ui_info "从 Alpine edge/community 安装 $package..."
        apk add --no-cache "$package@edge-community"
    elif [[ "$package" == "openssl" ]] && src_alpine_edge_package_available "$package" "edge"; then
        ui_info "从 Alpine edge/main 安装 $package..."
        apk add --no-cache "$package@edge"
    elif src_alpine_package_available "$package"; then
        ui_info "从 Alpine stable main/community 安装 $package..."
        apk add --no-cache "$package"
    else
        return 1
    fi
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
# 6. SSH 配置业务层
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

ssh_config_get_port() {
    CURRENT_SSH_PORT="$DEFAULT_SSH_PORT"
    if ! ssh_is_installed; then
        echo "$CURRENT_SSH_PORT"
        return 0
    fi
    ssh_config_ensure
    if sys_command_exists sshd; then
        local port
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            CURRENT_SSH_PORT="$port"
            echo "$CURRENT_SSH_PORT"
            return 0
        fi
    fi
    local config_port
    config_port="$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1)"
    [[ "$config_port" =~ ^[0-9]+$ ]] && CURRENT_SSH_PORT="$config_port"
    echo "$CURRENT_SSH_PORT"
}

ssh_config_get_all_ports() {
    if ssh_is_installed && sys_command_exists sshd; then
        sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
        return 0
    fi
    echo "$DEFAULT_SSH_PORT"
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

ssh_config_port_files() {
    printf '%s\n' "$SSHD_CONFIG"
    [[ -d "$SSHD_CONFIG_DIR" ]] || return 0
    local file
    for file in "$SSHD_CONFIG_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        printf '%s\n' "$file"
    done
}

ssh_port_is_listening() {
    local port="$1"
    if sys_command_exists ss; then
        ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$|\]:$port$" && return 0
    fi
    if sys_command_exists netstat; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$|\]:$port$" && return 0
    fi
    return 1
}

ssh_verify_port() {
    local port="$1"
    if ! ssh_config_get_all_ports | grep -Fxq "$port"; then
        ui_error "sshd 当前生效配置没有端口 $port。"
        ui_info "当前生效端口：$(ssh_config_get_all_ports | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
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

# SSH 规则：优先使用 limit，已存在 allow 时先删除再 limit
ssh_ufw_ensure_rule() {
    local port="$1"
    ufw_is_installed || return 1

    if ufw status 2>/dev/null | grep -Eq "[[:space:]]$port/tcp[[:space:]]+LIMIT"; then
        return 0
    fi

    if ufw status 2>/dev/null | grep -Eq "[[:space:]]$port/tcp[[:space:]]+ALLOW"; then
        ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
    fi

    ufw limit "$port/tcp" comment "SSH"
}

ssh_ufw_remove_rule() {
    local port="$1"
    ufw_is_installed || return 0
    ufw --force delete limit "$port/tcp" >/dev/null 2>&1 || true
    ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
}

ssh_config_set_ports() {
    local old_port="$1" new_port="$2"
    ssh_config_ensure || return 1
    local file
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        sed -i -E 's/^([[:space:]]*)Port[[:space:]]+[0-9]+([[:space:]]*)$/\1# Managed by ufwssh: previous Port\2/' "$file" || return 1
    done < <(ssh_config_port_files)
    printf '\n# Managed by ufwssh\nPort %s\nPort %s\n' "$old_port" "$new_port" >> "$SSHD_CONFIG"
    ssh_config_test
}

ssh_config_remove_port() {
    local port="$1"
    ssh_config_ensure || return 1
    local file
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        sed -i -E "/^[[:space:]]*Port[[:space:]]+$port[[:space:]]*$/d" "$file" || return 1
        sed -i -E "/^[[:space:]]*# Managed by ufwssh: previous Port[[:space:]]+$port[[:space:]]*$/d" "$file" || return 1
    done < <(ssh_config_port_files)
}

# ============================================================
# 7. UFW 业务层
# ============================================================

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
    local port
    while IFS= read -r port; do
        [[ -n "$port" ]] || continue
        if ! ssh_ufw_ensure_rule "$port"; then
            ui_error "无法确保 SSH $port/tcp 已放行，拒绝启用 UFW。"
            return 1
        fi
    done < <(ssh_config_get_all_ports)
    ufw --force enable
}

ufw_reset() {
    ufw_is_installed || { ui_error "UFW 尚未安装。"; return 1; }
    ui_warning "这会删除所有 UFW 规则并关闭 UFW。"
    ui_confirm "确定重置 UFW？" || return 0
    ufw --force reset
}

# ============================================================
# 8. SSH 密钥/安全业务层
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
    read -r -p "请粘贴 SSH 公钥: " public_key
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

    local backup security_conf
    backup="$(ssh_config_backup)" || return 1
    security_conf="$SSHD_CONFIG_DIR/99-ufwssh-security.conf"
    mkdir -p "$SSHD_CONFIG_DIR"

    cat > "$security_conf" <<'EOF'
# Managed by ufwssh
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 5
X11Forwarding no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
EOF

    if ! ssh_config_test || ! ssh_restart; then
        rm -f "$security_conf"
        ssh_config_restore_backup "$backup" || true
        ssh_restart >/dev/null 2>&1 || true
        ui_error "SSH 安全配置失败，已回滚。"
        return 1
    fi
    ui_success "SSH 基础安全配置已应用。"
}

# ============================================================
# 9. 安装业务层
# ============================================================

pkg_debian_install() {
    local package="${1:-}" backup profile
    [[ -n "$package" ]] || { ui_error "未指定 Debian/Ubuntu 软件包。"; return 1; }
    sys_command_exists apt-get || { ui_error "未找到 apt-get。"; return 1; }
    ui_info "刷新 Debian/Ubuntu 软件源..."
    apt-get update
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

# ============================================================
# 10. 软件源业务层
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
# 11. 状态展示层
# ============================================================

ui_show_component_status() {
    ssh_detect_service
    local port
    port="$(ssh_config_get_port)"

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
        echo "  SSH 端口   : $port"
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
# 12. SSH 端口变更业务
# ============================================================

ssh_change_port() {
    ssh_is_installed || { ui_error "SSH 尚未安装。"; return 1; }
    local old_port new_port backup
    old_port="$(ssh_config_get_port)"
    echo "当前 SSH 有效端口：$old_port"
    read -r -p "新的 SSH 端口（1-65535）: " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        ui_error "端口号无效。"
        return 1
    fi
    [[ "$new_port" == "$old_port" ]] && { ui_warning "端口没有变化。"; return 0; }
    if ssh_port_is_listening "$new_port"; then
        ui_error "端口 $new_port 已被占用。"
        return 1
    fi

    backup="$(ssh_config_backup)" || { ui_error "无法备份 SSH 配置。"; return 1; }
    if ufw_is_installed && ! ssh_ufw_ensure_rule "$new_port"; then
        ui_error "UFW 无法放行新端口，停止操作。"
        return 1
    fi

    if ! ssh_config_set_ports "$old_port" "$new_port"; then
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

    ui_success "SSH 已实际监听 $old_port 和 $new_port。"
    ui_warning "请先在另一个终端测试：ssh -p $new_port <用户>@<服务器IP>"
    if ui_confirm "确认新端口可登录后，是否移除旧端口 $old_port？"; then
        backup="$(ssh_config_backup)" || return 1
        if ! ssh_config_remove_port "$old_port"; then
            ssh_config_restore_backup "$backup" || true
            ssh_restart >/dev/null 2>&1 || true
            ui_error "移除旧端口配置失败，已恢复。"
            return 1
        fi
        if ssh_config_test && ssh_restart; then
            ssh_ufw_remove_rule "$old_port"
            ui_success "旧 SSH 端口 $old_port 已移除。"
        else
            ssh_config_restore_backup "$backup" || true
            ssh_restart >/dev/null 2>&1 || true
            ui_error "移除旧端口失败，已恢复。"
            return 1
        fi
    else
        ui_info "保留旧端口 $old_port。"
    fi
}

ssh_restore_default_port() {
    local current backup
    current="$(ssh_config_get_port)"
    [[ "$current" == "$DEFAULT_SSH_PORT" ]] && { ui_info "当前已经是 22 端口。"; return 0; }

    backup="$(ssh_config_backup)" || return 1
    if ufw_is_installed && ! ssh_ufw_ensure_rule "$DEFAULT_SSH_PORT"; then
        ui_error "无法放行 22/tcp。"
        return 1
    fi
    if ! ssh_config_set_ports "$current" "$DEFAULT_SSH_PORT" || ! ssh_restart; then
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

    ui_success "SSH 已切换到 22，原端口 $current 暂时保留。"
    if ui_confirm "确认 22 登录正常后，是否移除旧端口 $current？"; then
        backup="$(ssh_config_backup)" || return 1
        if ! ssh_config_remove_port "$current"; then
            ssh_config_restore_backup "$backup" || true
            ssh_restart >/dev/null 2>&1 || true
            ui_error "移除旧端口失败，已恢复。"
            return 1
        fi
        if ssh_config_test && ssh_restart; then
            ssh_ufw_remove_rule "$current"
            ui_success "旧端口已移除。"
        else
            ssh_config_restore_backup "$backup" || true
            ssh_restart >/dev/null 2>&1 || true
            ui_error "移除旧端口失败，已恢复。"
            return 1
        fi
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
        echo "  0) 返回"
        echo "------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_ssh; ui_pause ;;
            2) install_ufw; ui_pause ;;
            3) install_all; ui_pause ;;
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
    local choice
    while true; do
        ui_print_banner
        echo "========== SSH 端口管理 =========="
        echo "服务：$SSH_SERVICE"
        echo "当前端口：$(ssh_config_get_port)"
        echo ""
        echo "  1) 修改 SSH 端口"
        echo "  2) 查看当前端口"
        echo "  3) 恢复默认端口 22"
        echo "  4) 测试 SSH 配置"
        echo "  5) 重启 SSH"
        echo "  0) 返回"
        echo "----------------------------------"
        read -r -p "请选择: " choice
        case "$choice" in
            1) ssh_change_port; ui_pause ;;
            2)
                echo "当前端口：$(ssh_config_get_port)"
                if sys_command_exists ss; then
                    ss -lntp 2>/dev/null | grep -E ":$(ssh_config_get_port)([[:space:]]|$)" || true
                fi
                ui_pause
                ;;
            3) ssh_restore_default_port; ui_pause ;;
            4) ssh_config_test; ui_pause ;;
            5) ssh_restart && ui_success "SSH 已重启。" || ui_error "SSH 重启失败。"; ui_pause ;;
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
        echo ""
        echo "  1) 启动 SSH"
        echo "  2) 停止 SSH"
        echo "  3) 重启 SSH"
        echo "  4) 设置开机自启"
        echo "  5) 取消开机自启"
        echo "  6) 配置 SSH 公钥"
        echo "  7) 应用 SSH 基础安全配置"
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
