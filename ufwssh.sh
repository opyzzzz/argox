#!/bin/bash
#
# UFW + SSH 交互式管理工具 v4.0
# Debian/Ubuntu: apt + systemd
# Alpine Linux:  apk + OpenRC
#

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_VERSION="v4.1"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
UFW_DEFAULT="/etc/default/ufw"
DEFAULT_SSH_PORT=22

OS_TYPE=""
OS_NAME=""
OS_VERSION=""
SSH_SERVICE=""
SSH_USER="root"
CURRENT_SSH_PORT="$DEFAULT_SSH_PORT"

print_banner() {
    clear 2>/dev/null || true
    echo -e "$GREEN============================================================$NC"
    echo -e "$GREEN             UFW + SSH 管理工具 $SCRIPT_VERSION$NC"
    echo -e "$GREEN============================================================$NC"
    echo ""
}
print_error() { echo -e "$RED错误：$1$NC" >&2; }
print_warning() { echo -e "$YELLOW警告：$1$NC"; }
print_success() { echo -e "$GREEN$1$NC"; }
print_info() { echo -e "$BLUE$1$NC"; }
pause_menu() { echo ""; read -r -p "按 Enter 返回..." _; }
confirm_action() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ==================== 基础系统层 ====================

check_root() {
    [[ "$EUID" -eq 0 ]] || { print_error "此脚本必须以 root 用户执行。"; return 1; }
}

detect_os() {
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

    print_error "不支持的操作系统，仅支持 Debian/Ubuntu 和 Alpine Linux。"
    return 1
}

service_manager() {
    case "$OS_TYPE" in
        debian) echo "systemd" ;;
        alpine) echo "OpenRC" ;;
        *) echo "unknown" ;;
    esac
}

# ==================== SSH 服务抽象层 ====================

detect_ssh_service() {
    SSH_SERVICE=""
    case "$OS_TYPE" in
        debian)
            if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
                SSH_SERVICE="ssh"
            elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
                SSH_SERVICE="sshd"
            elif command_exists sshd; then
                SSH_SERVICE="ssh"
            fi
            ;;
        alpine)
            if rc-status --servicelist 2>/dev/null | grep -qx 'sshd'; then
                SSH_SERVICE="sshd"
            elif command_exists sshd; then
                SSH_SERVICE="sshd"
            fi
            ;;
    esac
}

is_ssh_installed() {
    case "$OS_TYPE" in
        debian) dpkg-query -W -f='$''{Status}' openssh-server 2>/dev/null | grep -q 'install ok installed' ;;
        alpine) apk info -e openssh >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

is_ssh_running() {
    [[ -n "$SSH_SERVICE" ]] || detect_ssh_service
    case "$OS_TYPE" in
        debian) [[ -n "$SSH_SERVICE" ]] && systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null ;;
        alpine) [[ -n "$SSH_SERVICE" ]] && rc-service "$SSH_SERVICE" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

is_ssh_enabled() {
    [[ -n "$SSH_SERVICE" ]] || detect_ssh_service
    case "$OS_TYPE" in
        debian) [[ -n "$SSH_SERVICE" ]] && systemctl is-enabled --quiet "$SSH_SERVICE" 2>/dev/null ;;
        alpine) rc-update show default 2>/dev/null | grep -Eq '^[[:space:]]*sshd[[:space:]]' ;;
        *) return 1 ;;
    esac
}

start_ssh() {
    [[ -n "$SSH_SERVICE" ]] || detect_ssh_service
    case "$OS_TYPE" in
        debian) systemctl start "$SSH_SERVICE" ;;
        alpine) rc-service "$SSH_SERVICE" start ;;
        *) return 1 ;;
    esac
}
stop_ssh() {
    [[ -n "$SSH_SERVICE" ]] || detect_ssh_service
    case "$OS_TYPE" in
        debian) systemctl stop "$SSH_SERVICE" ;;
        alpine) rc-service "$SSH_SERVICE" stop ;;
        *) return 1 ;;
    esac
}
restart_ssh() {
    [[ -n "$SSH_SERVICE" ]] || detect_ssh_service
    case "$OS_TYPE" in
        debian) systemctl restart "$SSH_SERVICE" ;;
        alpine) rc-service "$SSH_SERVICE" restart ;;
        *) return 1 ;;
    esac
}
enable_ssh() {
    [[ -n "$SSH_SERVICE" ]] || detect_ssh_service
    case "$OS_TYPE" in
        debian) systemctl enable "$SSH_SERVICE" ;;
        alpine) rc-update add "$SSH_SERVICE" default ;;
        *) return 1 ;;
    esac
}
disable_ssh() {
    [[ -n "$SSH_SERVICE" ]] || detect_ssh_service
    case "$OS_TYPE" in
        debian) systemctl disable "$SSH_SERVICE" ;;
        alpine) rc-update del "$SSH_SERVICE" default ;;
        *) return 1 ;;
    esac
}
ssh_status_text() {
    if ! is_ssh_installed; then
        echo "未安装"
    elif is_ssh_running; then
        echo "已安装 / 运行中"
    else
        echo "已安装 / 未运行"
    fi
}

# ==================== UFW 抽象层 ====================

is_ufw_installed() { command_exists ufw; }
is_ufw_active() {
    is_ufw_installed || return 1
    ufw status 2>/dev/null | head -1 | grep -q '^Status: active'
}
ufw_status_text() {
    if ! is_ufw_installed; then
        echo "未安装"
    elif is_ufw_active; then
        echo "已安装 / 已启用"
    else
        echo "已安装 / 未启用"
    fi}
configure_ufw_ipv6() {
    is_ufw_installed || return 0
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

# ==================== Debian 安装模块 ====================

debian_prepare_apt() {
    command_exists apt-get || { print_error "未找到 apt-get。"; return 1; }
    print_info "刷新 Debian/Ubuntu 软件源..."
    apt-get update
}

debian_install_package() {
    local package="$1" backup profile
    if debian_prepare_apt && debian_package_available "$package"; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
        return $?
    fi
    print_warning "当前 APT 源无法提供 $package，开始尝试官方源和备用镜像。"
    backup="$(source_backup)" || { print_error "无法创建 APT 软件源备份，停止自动换源。"; return 1; }
    for profile in official tuna; do
        if debian_try_source_profile "$profile" "$package"; then
            print_success "已找到 $package：$profile"
            if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then return 0; fi
            print_warning "$profile 已找到 $package，但安装失败，继续尝试其他源。"
        fi
    done
    print_error "无法从当前源、官方源或备用镜像安装 $package。"
    restore_source_backup "$backup"
    return 1
}

install_debian_ssh() {
    print_info "Debian/Ubuntu：安装 OpenSSH Server..."
    if ! is_ssh_installed; then
        debian_install_package openssh-server || return 1
    fi
    detect_ssh_service
    [[ -n "$SSH_SERVICE" ]] || { print_error "无法检测 SSH 服务。"; return 1; }
    mkdir -p "$SSHD_CONFIG_DIR"
    ssh-keygen -A >/dev/null 2>&1 || true
    is_ssh_running || start_ssh || return 1
    enable_ssh >/dev/null 2>&1 || print_warning "无法设置 SSH 开机自启。"
    print_success "Debian/Ubuntu SSH 安装/修复完成。"
}

install_debian_ufw() {
    print_info "Debian/Ubuntu：安装 UFW..."
    if ! is_ufw_installed; then
        debian_install_package ufw || return 1
    fi
    configure_ufw_ipv6
    print_success "Debian/Ubuntu UFW 安装/修复完成。"
}

# ==================== Alpine 安装模块 ====================

alpine_enable_community() {
    command_exists apk || {
        print_error "未找到 apk。"
        return 1
    }

    [[ -f /etc/apk/repositories ]] || {
        print_error "未找到 /etc/apk/repositories。"
        return 1
    }

    if grep -Eq '^[[:space:]]*[^#[:space:]].*/community([[:space:]]*)$' /etc/apk/repositories; then
        return 0
    fi

    local community_repo=""
    community_repo="$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*[^[:space:]]/ {
            url=$0
            sub(/[[:space:]]+$/, "", url)
            if (url ~ /\/main$/) {
                sub(/\/main$/, "/community", url)
                print url
                exit
            }
        }
    ' /etc/apk/repositories)"

    if [[ -n "$community_repo" ]]; then
        cp -a /etc/apk/repositories "/etc/apk/repositories.bak.$(date +%Y%m%d%H%M%S)"
        printf '%s\n' "$community_repo" >> /etc/apk/repositories
        print_success "已自动启用 Alpine community 仓库：$community_repo"
        return 0
    fi

    print_warning "无法从现有仓库自动推导 community 地址。"
    return 1
}

alpine_refresh_repositories() {
    print_info "刷新 Alpine 软件源..."
    apk update
}

alpine_enable_community() {
    command_exists apk || { print_error "未找到 apk。"; return 1; }
    [[ -f /etc/apk/repositories ]] || { print_error "未找到 /etc/apk/repositories。"; return 1; }
    if grep -Eq '^[[:space:]]*[^#[:space:]].*/community([[:space:]]*)$' /etc/apk/repositories; then return 0; fi
    local community_repo=""
    community_repo="$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*[^[:space:]]/ {
            url=$0
            sub(/[[:space:]]+$/, "", url)
            if (url ~ /\/main$/) { sub(/\/main$/, "/community", url); print url; exit }
        }
    ' /etc/apk/repositories)"
    if [[ -n "$community_repo" ]]; then
        printf '%s\n' "$community_repo" >> /etc/apk/repositories
        print_success "已启用 Alpine community 仓库：$community_repo"
        return 0
    fi
    print_warning "无法从现有仓库自动推导 community 地址。"
    return 1
}

alpine_package_available() {
    local package="$1"
    apk policy "$package" 2>/dev/null | grep -Eq '^[^[:space:]].*-[0-9][^:]*:'
}

alpine_install_package() {
    local package="$1" branch backup profile
    if alpine_refresh_repositories && alpine_package_available "$package"; then
        apk add --no-cache "$package"
        return $?
    fi
    if ! alpine_package_available "$package"; then
        print_warning "当前 Alpine 源无法提供 $package，尝试启用 community..."
        alpine_enable_community >/dev/null 2>&1 || true
        alpine_refresh_repositories >/dev/null 2>&1 || true
    fi
    if alpine_package_available "$package"; then
        apk add --no-cache "$package"
        return $?
    fi
    branch="$(alpine_version_branch)"
    [[ -n "$branch" ]] || { print_error "无法确定 Alpine 稳定仓库分支。"; return 1; }
    print_warning "当前 Alpine 源无法提供 $package，开始尝试官方源和备用镜像。"
    backup="$(source_backup)" || { print_error "无法创建 APK 软件源备份，停止自动换源。"; return 1; }
    for profile in official tuna; do
        if alpine_try_source_profile "$profile" "$branch" "$package"; then
            print_success "已找到 $package：$profile / $branch"
            if apk add --no-cache "$package"; then return 0; fi
            print_warning "$profile 已找到 $package，但安装失败，继续尝试其他源。"
        fi
    done
    print_error "无法从当前源、官方源或备用镜像安装 $package。"
    restore_source_backup "$backup"
    return 1
}

install_alpine_ssh() {
    print_info "Alpine Linux：安装 OpenSSH..."
    if ! is_ssh_installed; then
        alpine_install_package openssh || return 1
    fi
    SSH_SERVICE="sshd"
    mkdir -p "$SSHD_CONFIG_DIR"
    ssh-keygen -A >/dev/null 2>&1 || true
    is_ssh_running || start_ssh || return 1
    enable_ssh >/dev/null 2>&1 || print_warning "无法设置 sshd 开机自启。"
    print_success "Alpine SSH 安装/修复完成（OpenRC）。"
}

install_alpine_ufw() {
    print_info "Alpine Linux：安装 UFW..."
    if is_ufw_installed; then
        configure_ufw_ipv6
        print_success "Alpine UFW 已安装。"
        return 0
    fi

    alpine_install_package ufw || return 1
    configure_ufw_ipv6
    print_success "Alpine UFW 安装完成。"
}


# ==================== 软件源管理层 ====================

SOURCE_BACKUP_ROOT="/etc/ufwssh/source-backups"
DEBIAN_MANAGED_SOURCE="/etc/apt/sources.list.d/ufwssh-official.sources"
DEBIAN_MANAGED_LEGACY_SOURCE="/etc/apt/sources.list.d/ufwssh-official.list"
ALPINE_MANAGED_SOURCE="/etc/apk/repositories"

get_distro_id() {
    [[ -r /etc/os-release ]] || return 1
    . /etc/os-release
    printf '%s\n' "$ID"
}

get_distro_codename() {
    local codename=""
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        codename="$VERSION_CODENAME"
        [[ -z "$codename" ]] && codename="$UBUNTU_CODENAME"
    fi
    if [[ -z "$codename" ]] && command_exists lsb_release; then
        codename="$(lsb_release -cs 2>/dev/null || true)"
    fi
    printf '%s\n' "$codename"
}

source_backup() {
    local backup_dir
    mkdir -p "$SOURCE_BACKUP_ROOT" || return 1
    backup_dir="$(mktemp -d "$SOURCE_BACKUP_ROOT/backup.XXXXXX")" || return 1
    case "$OS_TYPE" in
        debian)
            if [[ -e /etc/apt/sources.list ]]; then cp -a /etc/apt/sources.list "$backup_dir/sources.list"; else : > "$backup_dir/sources.list.missing"; fi
            if [[ -d /etc/apt/sources.list.d ]]; then cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d"; else : > "$backup_dir/sources.list.d.missing"; fi
            ;;
        alpine)
            if [[ -e /etc/apk/repositories ]]; then cp -a /etc/apk/repositories "$backup_dir/repositories"; else : > "$backup_dir/repositories.missing"; fi
            ;;
        *) rm -rf "$backup_dir"; return 1 ;;
    esac
    echo "$backup_dir"
}

source_backup_latest() {
    [[ -d "$SOURCE_BACKUP_ROOT" ]] || return 1
    ls -dt "$SOURCE_BACKUP_ROOT"/backup.* 2>/dev/null | head -1
}

debian_source_files() {
    [[ -d /etc/apt/sources.list.d ]] || return 0
    find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print 2>/dev/null
}

debian_apt_supports_deb822() {
    local major="" minor=""
    read -r major minor _ < <(apt-get --version 2>/dev/null | awk 'NR==1 {split($2,v,"."); print v[1],v[2]}')
    [[ -n "$major" && "$major" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$minor" && "$minor" =~ ^[0-9]+$ ]] || minor=0
    (( major > 1 || (major == 1 && minor >= 1) ))
}

debian_disable_existing_sources() {
    local file
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        case "$file" in
            "$DEBIAN_MANAGED_SOURCE"|"$DEBIAN_MANAGED_LEGACY_SOURCE") continue ;;
        esac
        mv "$file" "$file.ufwssh-disabled"
    done < <(debian_source_files)
}

debian_write_sources() {
    local profile="official"
    [[ $# -gt 0 ]] && profile="$1"
    local distro codename base_uri security_uri components
    distro="$(get_distro_id)"
    codename="$(get_distro_codename)"
    [[ -n "$codename" ]] || { print_error "无法检测 Debian/Ubuntu 发行版代号。"; return 1; }

    case "$distro:$profile" in
        debian:official) base_uri="https://deb.debian.org/debian"; security_uri="https://security.debian.org/debian-security"; components="main contrib non-free non-free-firmware" ;;
        debian:tuna) base_uri="https://mirrors.tuna.tsinghua.edu.cn/debian"; security_uri="https://mirrors.tuna.tsinghua.edu.cn/debian-security"; components="main contrib non-free non-free-firmware" ;;
        ubuntu:official) base_uri="https://archive.ubuntu.com/ubuntu"; security_uri="https://security.ubuntu.com/ubuntu"; components="main restricted universe multiverse" ;;
        ubuntu:tuna) base_uri="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"; security_uri="https://mirrors.tuna.tsinghua.edu.cn/ubuntu"; components="main restricted universe multiverse" ;;
        *) print_error "不支持的 APT 软件源配置：$distro / $profile"; return 1 ;;
    esac

    mkdir -p /etc/apt/sources.list.d
    debian_disable_existing_sources
    rm -f "$DEBIAN_MANAGED_SOURCE" "$DEBIAN_MANAGED_LEGACY_SOURCE"
    if debian_apt_supports_deb822; then
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

debian_package_available() {
    local package="$1" policy candidate
    command_exists apt-cache || return 1
    policy="$(apt-cache policy "$package" 2>/dev/null || true)"
    candidate="$(printf '%s\n' "$policy" | awk -F': ' '/^[[:space:]]*Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

debian_packages_available() {
    local package
    for package in "$@"; do debian_package_available "$package" || return 1; done
    return 0
}

debian_refresh_and_check() {
    print_info "刷新 APT 软件包索引..."
    apt-get update || { print_warning "APT update 失败。"; return 1; }
    debian_packages_available "$@" || { print_warning "当前 APT 源刷新成功，但目标软件包没有可用候选版本。"; return 1; }
}

debian_try_source_profile() {
    local profile="$1"; shift
    print_info "尝试 Debian/Ubuntu $profile 软件源..."
    debian_write_sources "$profile" || return 1
    debian_refresh_and_check "$@"
}

alpine_version_branch() {
    local version
    version="$(printf '%s' "$OS_VERSION" | cut -d- -f1)"
    printf '%s\n' "$version" | sed -n 's/^\([0-9]\+\.[0-9]\+\).*/v\1/p'
}

alpine_write_repositories() {
    local branch="$1"
    cat > "$ALPINE_MANAGED_SOURCE" <<EOF
https://dl-cdn.alpinelinux.org/alpine/$branch/main
https://dl-cdn.alpinelinux.org/alpine/$branch/community
EOF
}

alpine_write_tuna_repositories() {
    local branch="$1"
    cat > "$ALPINE_MANAGED_SOURCE" <<EOF
https://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/community
EOF
}

alpine_package_available() {
    local package="$1"
    apk policy "$package" 2>/dev/null | grep -Eq '^[^[:space:]].*-[0-9][^:]*:'
}

alpine_packages_available() {
    local package
    for package in "$@"; do alpine_package_available "$package" || return 1; done
    return 0
}

alpine_refresh_and_check() {
    print_info "刷新 APK 软件包索引..."
    apk update || { print_warning "APK update 失败。"; return 1; }
    alpine_packages_available "$@" || { print_warning "当前 APK 源刷新成功，但目标软件包没有可用版本。"; return 1; }
}

alpine_try_source_profile() {
    local profile="$1" branch="$2"; shift 2
    case "$profile" in official) alpine_write_repositories "$branch" ;; tuna) alpine_write_tuna_repositories "$branch" ;; *) return 1 ;; esac
    print_info "尝试 Alpine $profile 软件源：$branch"
    alpine_refresh_and_check "$@"
}

restore_source_backup() {
    local backup_dir=""
    [[ $# -gt 0 ]] && backup_dir="$1"
    [[ -n "$backup_dir" && -d "$backup_dir" ]] || backup_dir="$(source_backup_latest 2>/dev/null || true)"
    [[ -n "$backup_dir" && -d "$backup_dir" ]] || { print_error "没有可恢复的软件源备份。"; return 1; }
    case "$OS_TYPE" in
        debian)
            if [[ -f "$backup_dir/sources.list" ]]; then rm -f /etc/apt/sources.list; cp -a "$backup_dir/sources.list" /etc/apt/sources.list; elif [[ -f "$backup_dir/sources.list.missing" ]]; then rm -f /etc/apt/sources.list; fi
            if [[ -d "$backup_dir/sources.list.d" ]]; then rm -rf /etc/apt/sources.list.d; cp -a "$backup_dir/sources.list.d" /etc/apt/sources.list.d; elif [[ -f "$backup_dir/sources.list.d.missing" ]]; then rm -rf /etc/apt/sources.list.d; mkdir -p /etc/apt/sources.list.d; fi
            ;;
        alpine)
            if [[ -f "$backup_dir/repositories" ]]; then cp -a "$backup_dir/repositories" /etc/apk/repositories; elif [[ -f "$backup_dir/repositories.missing" ]]; then rm -f /etc/apk/repositories; fi
            ;;
        *) return 1 ;;
    esac
    print_success "已恢复软件源备份：$backup_dir"
}

repair_debian_sources() {
    local backup profile
    backup="$(source_backup)" || { print_error "无法创建 APT 软件源备份。"; return 1; }
    for profile in official tuna; do
        if debian_try_source_profile "$profile" openssh-server ufw; then print_success "APT 软件源已切换并验证成功：$profile"; echo "备份：$backup"; return 0; fi
    done
    print_error "官方源与备用镜像均无法提供所需软件包，恢复原 APT 配置。"
    restore_source_backup "$backup"
    return 1
}

repair_alpine_sources() {
    local branch backup profile
    branch="$(alpine_version_branch)"
    [[ -n "$branch" ]] || { print_error "无法从 Alpine 版本 $OS_VERSION 推导稳定仓库分支。"; return 1; }
    backup="$(source_backup)" || { print_error "无法创建 APK 软件源备份。"; return 1; }
    for profile in official tuna; do
        if alpine_try_source_profile "$profile" "$branch" openssh ufw; then print_success "APK 软件源已切换并验证成功：$profile / $branch"; echo "备份：$backup"; return 0; fi
    done
    print_error "官方源与备用镜像均无法提供所需软件包，恢复原 APK 配置。"
    restore_source_backup "$backup"
    return 1
}

switch_alpine_tuna_sources() {
    local branch backup
    branch="$(alpine_version_branch)"
    [[ -n "$branch" ]] || { print_error "无法从 Alpine 版本 $OS_VERSION 推导稳定仓库分支。"; return 1; }
    backup="$(source_backup)" || { print_error "无法创建 APK 软件源备份。"; return 1; }
    if alpine_try_source_profile tuna "$branch" openssh ufw; then print_success "APK 已切换到清华 TUNA 镜像：$branch"; echo "备份：$backup"; return 0; fi
    print_error "TUNA 镜像无法提供所需软件包，恢复原 APK 配置。"
    restore_source_backup "$backup"
    return 1
}

switch_debian_tuna_sources() {
    local backup
    backup="$(source_backup)" || { print_error "无法创建 APT 软件源备份。"; return 1; }
    if debian_try_source_profile tuna openssh-server ufw; then print_success "APT 已切换到清华 TUNA 镜像。"; echo "备份：$backup"; return 0; fi
    print_error "TUNA 镜像无法提供所需软件包，恢复原 APT 配置."
    restore_source_backup "$backup"
    return 1
}

repair_sources() {
    case "$OS_TYPE" in
        debian) repair_debian_sources ;;
        alpine) repair_alpine_sources ;;
        *) print_error "当前系统不支持软件源自动修复。"; return 1 ;;
    esac
}

show_source_status() {
    print_banner
    echo "========== 软件源状态 =========="
    case "$OS_TYPE" in
        debian)
            echo "APT 软件源文件："
            [[ -f /etc/apt/sources.list ]] && { echo "  /etc/apt/sources.list"; sed 's/^/    /' /etc/apt/sources.list; }
            local file
            while IFS= read -r file; do [[ -n "$file" ]] || continue; echo "  $file"; sed 's/^/    /' "$file"; done < <(debian_source_files)
            echo ""
            debian_package_available openssh-server && print_success "APT：openssh-server 可用。" || print_warning "APT：openssh-server 当前不可用。"
            debian_package_available ufw && print_success "APT：ufw 可用。" || print_warning "APT：ufw 当前不可用。"
            ;;
        alpine)
            echo "APK 软件源："
            [[ -f /etc/apk/repositories ]] && sed 's/^/  /' /etc/apk/repositories || echo "  /etc/apk/repositories（不存在）"
            echo ""
            alpine_package_available openssh && print_success "APK：openssh 可用。" || print_warning "APK：openssh 当前不可用."
            alpine_package_available ufw && print_success "APK：ufw 可用。" || print_warning "APK：ufw 当前不可用."
            ;;
        *) print_error "未知系统。" ;;
    esac
    echo ""
    echo "最近备份：$(source_backup_latest 2>/dev/null || echo '无')"
}

source_menu() {
    while true; do
        print_banner
        echo "========== 软件源管理 =========="
        echo "系统：$OS_NAME $OS_VERSION"
        echo ""
        echo "  1) 检测当前软件源"
        echo "  2) 自动修复（官方源 → 备用镜像）"
        if [[ "$OS_TYPE" == "alpine" ]]; then echo "  3) 切换 Alpine 清华 TUNA 镜像"; else echo "  3) 切换 Debian/Ubuntu 清华 TUNA 镜像"; fi
        echo "  4) 恢复最近一次备份"
        echo "  0) 返回"
        echo "--------------------------------"
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1) show_source_status; pause_menu ;;
            2) repair_sources; pause_menu ;;
            3) if [[ "$OS_TYPE" == "alpine" ]]; then switch_alpine_tuna_sources; else switch_debian_tuna_sources; fi; pause_menu ;;
            4) restore_source_backup; pause_menu ;;
            0) return 0 ;;
            *) print_error "无效选择。" ;;
        esac
    done
}

# ==================== SSH 配置层 ====================

ensure_sshd_config() {
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

get_ssh_port() {
    CURRENT_SSH_PORT="$DEFAULT_SSH_PORT"
    if ! is_ssh_installed; then
        echo "$CURRENT_SSH_PORT"
        return 0
    fi
    ensure_sshd_config
    if command_exists sshd; then
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

test_sshd_config() {
    command_exists sshd || { print_error "未找到 sshd。"; return 1; }
    local output
    if output="$(sshd -t 2>&1)"; then
        print_success "SSH 配置语法检查通过。"
        return 0
    fi
    print_error "SSH 配置检查失败：$output"
    return 1
}

backup_sshd_config() {
    ensure_sshd_config || return 1
    local backup="$SSHD_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$SSHD_CONFIG" "$backup" || return 1
    echo "$backup"
}

port_is_listening() {
    local port="$1"
    command_exists ss || return 1
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])$port$"
}

ensure_ufw_ssh_rule() {
    local port="$1"
    is_ufw_installed || return 1
    if ufw status 2>/dev/null | grep -Eq "[[:space:]]$port/tcp[[:space:]]+(ALLOW|LIMIT)"; then
        return 0
    fi
    ufw allow "$port/tcp" comment "SSH"
}

set_ssh_ports() {
    local old_port="$1"
    local new_port="$2"
    ensure_sshd_config || return 1
    sed -i -E '/^[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$/d' "$SSHD_CONFIG"
    printf '\n# Managed by ufwssh\nPort %s\nPort %s\n' "$old_port" "$new_port" >> "$SSHD_CONFIG"
    test_sshd_config
}
remove_ssh_port() {
    local port="$1"
    ensure_sshd_config || return 1
    sed -i -E "/^[[:space:]]*Port[[:space:]]+$port[[:space:]]*$/d" "$SSHD_CONFIG"
}

change_ssh_port() {
    is_ssh_installed || { print_error "SSH 尚未安装。"; return 1; }
    local old_port new_port backup
    old_port="$(get_ssh_port)"
    echo "当前 SSH 端口：$old_port"
    read -r -p "新的 SSH 端口（1-65535）: " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        print_error "端口号无效。"
        return 1
    fi
    [[ "$new_port" == "$old_port" ]] && { print_warning "端口没有变化。"; return 0; }
    if port_is_listening "$new_port"; then
        print_error "端口 $new_port 已被占用。"
        return 1
    fi

    backup="$(backup_sshd_config)" || { print_error "无法备份 SSH 配置。"; return 1; }

    if is_ufw_installed && ! ensure_ufw_ssh_rule "$new_port"; then
        print_error "UFW 无法放行新端口，停止操作。"
        return 1
    fi

    if ! set_ssh_ports "$old_port" "$new_port"; then
        cp -a "$backup" "$SSHD_CONFIG"
        return 1
    fi
    if ! restart_ssh; then
        print_error "SSH 重启失败，恢复配置。"
        cp -a "$backup" "$SSHD_CONFIG"
        restart_ssh >/dev/null 2>&1 || true
        return 1
    fi

    sleep 1
    if ! port_is_listening "$new_port"; then
        print_error "新端口未监听，恢复配置。"
        cp -a "$backup" "$SSHD_CONFIG"
        restart_ssh >/dev/null 2>&1 || true
        return 1
    fi

    print_success "SSH 已同时监听 $old_port 和 $new_port。"
    print_warning "请在另一个终端测试：ssh -p $new_port <用户>@<服务器IP>"

    if confirm_action "确认新端口可登录后，是否移除旧端口 $old_port？"; then
        backup="$(backup_sshd_config)" || return 1
        remove_ssh_port "$old_port" || return 1
        if test_sshd_config && restart_ssh; then
            if is_ufw_installed; then
                ufw delete allow "$old_port/tcp" >/dev/null 2>&1 || true
            fi
            print_success "旧端口 $old_port 已移除。"
        else
            cp -a "$backup" "$SSHD_CONFIG"
            restart_ssh >/dev/null 2>&1 || true
            print_error "移除旧端口失败，已恢复。"
            return 1
        fi
    else
        print_info "保留旧端口 $old_port。"
    fi
}

restore_default_ssh_port() {
    local current backup
    current="$(get_ssh_port)"
    [[ "$current" == "$DEFAULT_SSH_PORT" ]] && { print_info "当前已经是 22 端口。"; return 0; }
    backup="$(backup_sshd_config)" || return 1
    if is_ufw_installed && ! ensure_ufw_ssh_rule "$DEFAULT_SSH_PORT"; then
        print_error "无法放行 22/tcp。"
        return 1
    fi

    if ! set_ssh_ports "$current" "$DEFAULT_SSH_PORT" || ! restart_ssh; then
        cp -a "$backup" "$SSHD_CONFIG"
        restart_ssh >/dev/null 2>&1 || true
        return 1
    fi

    sleep 1
    if ! port_is_listening "$DEFAULT_SSH_PORT"; then
        print_error "22 端口未监听，恢复配置。"
        cp -a "$backup" "$SSHD_CONFIG"
        restart_ssh >/dev/null 2>&1 || true
        return 1
    fi

    print_success "SSH 已切换到 22，原端口 $current 暂时保留。"
    if confirm_action "确认 22 登录正常后，是否移除旧端口 $current？"; then
        backup="$(backup_sshd_config)" || return 1
        remove_ssh_port "$current"
        if test_sshd_config && restart_ssh; then
            is_ufw_installed && ufw delete allow "$current/tcp" >/dev/null 2>&1 || true
            print_success "旧端口已移除。"
        else
            cp -a "$backup" "$SSHD_CONFIG"
            restart_ssh >/dev/null 2>&1 || true
            print_error "移除旧端口失败，已恢复。"
        fi
    fi
}

# ==================== UFW 规则管理 ====================

show_ufw_rules() {
    is_ufw_installed || { print_error "UFW 尚未安装。"; return 1; }
    echo ""
    ufw status verbose
    echo ""
    ufw status numbered
}

add_ufw_rule() {
    is_ufw_installed || { print_error "UFW 尚未安装。"; return 1; }
    echo "1) allow  2) limit  3) deny  4) reject  0) 返回"

    local type port protocol
    read -r -p "规则类型: " type
    case "$type" in
        1) type="allow" ;;
        2) type="limit" ;;
        3) type="deny" ;;
        4) type="reject" ;;
        0) return 0 ;;
        *) print_error "无效选择。"; return 1 ;;
    esac

    read -r -p "端口（例如 80、443、8000:8010）: " port
    [[ -n "$port" ]] || { print_error "端口不能为空。"; return 1; }

    echo "1) tcp  2) udp  3) tcp+udp  4) all"
    read -r -p "协议 [默认 1]: " protocol
    [[ -n "$protocol" ]] || protocol=1

    case "$protocol" in
        1) ufw "$type" "$port/tcp" ;;
        2) ufw "$type" "$port/udp" ;;
        3) ufw "$type" "$port/tcp" && ufw "$type" "$port/udp" ;;
        4) ufw "$type" "$port" ;;
        *) print_error "无效协议。"; return 1 ;;
    esac
}

delete_ufw_rule() {
    is_ufw_installed || { print_error "UFW 尚未安装。"; return 1; }
    ufw status numbered
    echo ""
    local number
    read -r -p "要删除的规则编号: " number
    [[ "$number" =~ ^[0-9]+$ ]] || { print_error "编号必须是数字。"; return 1; }
    confirm_action "确定删除规则 #$number？" || return 0
    ufw --force delete "$number"
}

change_ufw_defaults() {
    is_ufw_installed || { print_error "UFW 尚未安装。"; return 1; }
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
        *) print_error "入站策略无效。"; return 1 ;;
    esac
    case "$outgoing" in
        1) ufw default allow outgoing ;;
        2) ufw default deny outgoing ;;
        *) print_error "出站策略无效。"; return 1 ;;
    esac
}

enable_ufw_safely() {
    is_ufw_installed || { print_error "UFW 尚未安装。"; return 1; }
    local ssh_port
    ssh_port="$(get_ssh_port)"
    if ! ensure_ufw_ssh_rule "$ssh_port"; then
        print_error "无法确保 SSH $ssh_port/tcp 已放行，拒绝启用 UFW。"
        return 1
    fi
    ufw --force enable
}
reset_ufw() {
    is_ufw_installed || { print_error "UFW 尚未安装。"; return 1; }
    print_warning "这会删除所有 UFW 规则并关闭 UFW。"
    confirm_action "确定重置 UFW？" || return 0
    ufw --force reset
}

# ==================== SSH 公钥/安全 ====================

get_target_ssh_user() {
    local sudo_user
    sudo_user="$(printenv SUDO_USER 2>/dev/null || true)"
    if [[ -n "$sudo_user" ]] && id "$sudo_user" >/dev/null 2>&1; then
        SSH_USER="$sudo_user"
    else
        SSH_USER="root"
    fi
}

configure_ssh_key() {
    is_ssh_installed || { print_error "SSH 尚未安装。"; return 1; }
    get_target_ssh_user

    echo "当前目标用户：$SSH_USER"
    local selected
    read -r -p "输入其他本地用户名（直接 Enter 保持）: " selected
    if [[ -n "$selected" ]]; then
        id "$selected" >/dev/null 2>&1 || { print_error "用户不存在。"; return 1; }
        SSH_USER="$selected"
    fi

    local home_dir ssh_dir auth_keys public_key
    home_dir="$(getent passwd "$SSH_USER" | cut -d: -f6)"
    [[ -n "$home_dir" ]] || home_dir="/root"
    ssh_dir="$home_dir/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    read -r -p "请粘贴 SSH 公钥: " public_key
    public_key="$(printf '%s' "$public_key" | tr -d '\r\n' | xargs)"

    [[ -n "$public_key" ]] || { print_error "公钥不能为空。"; return 1; }
    printf '%s\n' "$public_key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)-' || {
        print_error "公钥格式无法识别。"
        return 1
    }

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    [[ -f "$auth_keys" ]] && cp -a "$auth_keys" "$auth_keys.bak.$(date +%Y%m%d%H%M%S)"
    printf '%s\n' "$public_key" >> "$auth_keys"
    chmod 600 "$auth_keys"
    [[ "$SSH_USER" == "root" ]] || chown -R "$SSH_USER:$SSH_USER" "$ssh_dir"
    print_success "公钥已写入 $auth_keys"
}

optimize_ssh_security() {
    is_ssh_installed || { print_error "SSH 尚未安装。"; return 1; }
    ensure_sshd_config || return 1

    local backup security_conf
    backup="$(backup_sshd_config)" || return 1
    security_conf="$SSHD_CONFIG_DIR/99-ufwssh-security.conf"
    mkdir -p "$SSHD_CONFIG_DIR"

    cat > "$security_conf" <<'EOF'
# Managed by ufwssh
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 5
X11Forwarding no
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
EOF

    if ! test_sshd_config || ! restart_ssh; then
        rm -f "$security_conf"
        cp -a "$backup" "$SSHD_CONFIG"
        restart_ssh >/dev/null 2>&1 || true
        print_error "SSH 安全配置失败，已回滚。"
        return 1
    fi
    print_success "SSH 基础安全配置已应用。"
}

# ==================== 状态层 ====================

show_component_status() {
    detect_ssh_service
    local port
    port="$(get_ssh_port)"

    echo -e "$CYAN系统信息$NC"
    echo "  系统       : $OS_NAME $OS_VERSION"
    echo "  架构       : $(uname -m)"
    echo "  服务管理器 : $(service_manager)"
    echo ""
    echo -e "$CYAN组件状态$NC"

    if is_ssh_installed; then
        if is_ssh_running; then
            echo -e "  SSH        : $GREEN● 已安装 / 运行中$NC"
        else
            echo -e "  SSH        : $YELLOW● 已安装 / 未运行$NC"
        fi
        echo "  SSH 服务   : $SSH_SERVICE"
        echo "  开机自启   : $(is_ssh_enabled && echo '是' || echo '否')"
        echo "  SSH 端口   : $port"
    else
        echo -e "  SSH        : $YELLOW○ 未安装$NC"
    fi

    echo "  UFW        : $(ufw_status_text)"
    echo ""
}

show_detailed_status() {
    print_banner
    show_component_status
    echo -e "$CYANSSH 监听$NC"
    if command_exists ss; then
        ss -lntp 2>/dev/null || true
    else
        echo "  未安装 ss。"
    fi
    echo ""
    echo -e "$CYANUFW 规则$NC"
    if is_ufw_installed; then
        ufw status verbose
        echo ""
        ufw status numbered
    else
        echo "  UFW 未安装。"
    fi
}

# ==================== 菜单层 ====================

install_menu() {
    while true; do
        print_banner
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
            1) install_ssh; pause_menu ;;
            2) install_ufw; pause_menu ;;
            3) install_all; pause_menu ;;
            0) return 0 ;;
            *) print_error "无效选择。" ;;
        esac
    done
}

ssh_port_menu() {
    while true; do
        print_banner
        echo "========== SSH 端口管理 =========="
        echo "服务：$SSH_SERVICE"
        echo "当前端口：$(get_ssh_port)"
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
            1) change_ssh_port; pause_menu ;;
            2)
                echo "当前端口：$(get_ssh_port)"
                command_exists ss && ss -lntp 2>/dev/null | grep -E ":$(get_ssh_port)([[:space:]]|$)" || true
                pause_menu
                ;;
            3) restore_default_ssh_port; pause_menu ;;
            4) test_sshd_config; pause_menu ;;
            5) restart_ssh && print_success "SSH 已重启。" || print_error "SSH 重启失败。"; pause_menu ;;
            0) return 0 ;;
            *) print_error "无效选择。" ;;
        esac
    done
}

ufw_menu() {
    while true; do
        print_banner
        echo "========== UFW 防火墙管理 =========="
        echo "状态：$(ufw_status_text)"
        echo ""
        is_ufw_installed && ufw status | head -5 || true
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
            1) show_ufw_rules; pause_menu ;;
            2) add_ufw_rule; pause_menu ;;
            3) delete_ufw_rule; pause_menu ;;
            4) change_ufw_defaults; pause_menu ;;
            5) enable_ufw_safely; pause_menu ;;
            6) confirm_action "确定禁用 UFW？" && ufw disable; pause_menu ;;
            7) ufw reload; pause_menu ;;
            8) reset_ufw; pause_menu ;;
            0) return 0 ;;
            *) print_error "无效选择。" ;;
        esac
    done
}

ssh_service_menu() {
    while true; do
        print_banner
        detect_ssh_service
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
            1) start_ssh && print_success "SSH 已启动。" || print_error "SSH 启动失败。"; pause_menu ;;
            2) stop_ssh && print_success "SSH 已停止。" || print_error "SSH 停止失败。"; pause_menu ;;
            3) restart_ssh && print_success "SSH 已重启。" || print_error "SSH 重启失败。"; pause_menu ;;
            4) enable_ssh && print_success "SSH 已设置开机自启。" || print_error "设置失败。"; pause_menu ;;
            5) disable_ssh && print_success "SSH 已取消开机自启。" || print_error "取消失败。"; pause_menu ;;
            6) configure_ssh_key; pause_menu ;;
            7) optimize_ssh_security; pause_menu ;;
            0) return 0 ;;
            *) print_error "无效选择。" ;;
        esac
    done
}

main_menu() {
    while true; do
        print_banner
        show_component_status
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
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_menu ;;
            2) source_menu ;;
            3) ssh_port_menu ;;
            4) ufw_menu ;;
            5) ssh_service_menu ;;