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

SCRIPT_VERSION="v4.0"
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
    fi
}
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
    command_exists apt-get || {
        print_error "未找到 apt-get。"
        return 1
    }

    print_info "刷新 Debian/Ubuntu 软件源..."
    apt-get update
}

debian_package_available() {
    local package="$1"
    command_exists apt-cache || return 1

    local policy
    policy="$(apt-cache policy "$package" 2>/dev/null || true)"
    if printf '%s\n' "$policy" | grep -Eq '^[[:space:]]*Candidate:[[:space:]]+[^ (]'; then
        return 0
    fi

    print_error "Debian/Ubuntu 当前软件源没有可用的 $package 安装候选版本。"
    print_warning "请检查 /etc/apt/sources.list 和 /etc/apt/sources.list.d/ 中的软件源。"
    return 1
}

debian_install_package() {
    local package="$1"

    if ! debian_prepare_apt; then
        print_warning "apt 软件源刷新失败，继续检查现有本地软件包索引..."
    fi

    debian_package_available "$package" || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
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

alpine_package_available() {
    local package="$1"
    apk policy "$package" 2>/dev/null | grep -Eq '^[[:alnum:]_.+~-]+-[0-9]'
}

alpine_install_package() {
    local package="$1"

    if ! alpine_refresh_repositories; then
        print_warning "apk update 失败，继续检查现有软件包索引..."
    fi

    if ! alpine_package_available "$package"; then
        print_warning "当前 Alpine 软件源没有 $package，尝试启用 community..."
        if alpine_enable_community; then
            alpine_refresh_repositories || return 1
        fi
    fi

    if ! alpine_package_available "$package"; then
        print_error "当前 Alpine 软件源仍没有可用的 $package 安装包。"
        print_warning "请检查 /etc/apk/repositories 后重试。"
        return 1
    fi

    apk add --no-cache "$package"
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

# ==================== 统一安装入口 ====================

install_ssh() {
    case "$OS_TYPE" in
        debian) install_debian_ssh ;;
        alpine) install_alpine_ssh ;;
        *) print_error "未知系统。"; return 1 ;;
    esac
}
install_ufw() {
    case "$OS_TYPE" in
        debian) install_debian_ufw ;;
        alpine) install_alpine_ufw ;;
        *) print_error "未知系统。"; return 1 ;;
    esac
}
install_all() {
    local ssh_ok=true
    local ufw_ok=true
    echo ""
    print_info "当前系统：$OS_NAME $OS_VERSION"
    install_ssh || ssh_ok=false
    echo ""
    install_ufw || ufw_ok=false
    echo ""
    if $ssh_ok && $ufw_ok; then
        print_success "SSH + UFW 安装/修复完成。"
        print_warning "UFW 安装后不会自动启用，请先确认规则。"
    else
        print_error "安装流程未全部成功。"
        return 1
    fi
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
        echo "  2) SSH 端口管理"
        echo "  3) UFW 防火墙规则管理"
        echo "  4) SSH 服务管理"
        echo "  5) 查看详细状态"
        echo "  6) 重置 UFW"
        echo "  0) 退出"
        echo "------------------------------------------------------------"
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1) install_menu ;;
            2) ssh_port_menu ;;
            3) ufw_menu ;;
            4) ssh_service_menu ;;
            5) show_detailed_status; pause_menu ;;
            6) reset_ufw; pause_menu ;;
            0) echo "已退出。"; return 0 ;;
            *) print_error "无效选择，请输入 0-6。" ;;
        esac
    done
}

main() {
    check_root || exit 1
    detect_os || exit 1
    get_target_ssh_user
    detect_ssh_service
    # 启动阶段只做只读检测，不自动安装、启用 UFW 或修改 SSH。
    main_menu
}

if [[ "$0" == "$BASH_SOURCE" ]]; then
    main "$@"
fi
