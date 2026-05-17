#!/bin/bash
#
# Debian UFW 防火墙 + SSH 密钥登录一键配置脚本 (最终修正版 v3.6)
# 
# 版本历史：
#   v3.1 - 修复 sshd_config 文件不存在的问题
#   v3.2 - 统一变量命名规范和函数封装
#   v3.3 - 修正防火墙启用顺序防止断连，动态获取用户，IPv6安全处理
#   v3.4 - 进一步优化错误处理，添加断连保护机制，完善日志输出
#   v3.5 - 修复 SSH_SERVICE 变量为空导致 systemctl 命令失败
#   v3.6 - 完善函数调用顺序，优化错误恢复，增强边界条件检查
#

set -e

# ========== 全局常量定义 ==========
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
readonly UFW_DEFAULT="/etc/default/ufw"
readonly MIN_PORT=1024
readonly MAX_PORT=65535
readonly DEFAULT_PORT=2222
readonly DEFAULT_SSH_PORT=22
readonly SCRIPT_VERSION="v3.6"

# ========== 全局变量声明（按使用顺序） ==========
SSH_USER="root"                    # 操作目标用户
SSH_SERVICE=""                     # SSH服务名称（ssh或sshd）
CURRENT_SSH_PORT="$DEFAULT_SSH_PORT"  # 当前SSH端口
NEW_SSH_PORT=""                    # 新SSH端口
STACK_TYPE=""                      # 网络栈类型
STACK_DESC=""                      # 网络栈描述
IPV4_ADDR=""                       # IPv4地址
IPV6_ADDR=""                       # IPv6地址
BACKUP_FILE=""                     # SSH配置备份文件路径
AUTH_KEYS_FILE=""                  # 授权密钥文件路径

# ========== 工具函数 ==========
print_banner() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Debian UFW + SSH 安全配置脚本 ${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

print_error() { 
    echo -e "${RED}错误：$1${NC}" >&2
    logger -t "ssh-setup" "ERROR: $1" 2>/dev/null || true
}

print_warning() { 
    echo -e "${YELLOW}警告：$1${NC}"
    logger -t "ssh-setup" "WARNING: $1" 2>/dev/null || true
}

print_success() { 
    echo -e "${GREEN}$1${NC}"
    logger -t "ssh-setup" "SUCCESS: $1" 2>/dev/null || true
}

print_info() { 
    echo -e "${BLUE}$1${NC}"
    logger -t "ssh-setup" "INFO: $1" 2>/dev/null || true
}

# ========== SSH 服务管理函数 ==========
detect_ssh_service() {
    # 如果已经检测到，直接返回
    [[ -n "$SSH_SERVICE" ]] && return 0
    
    print_info "检测 SSH 服务名称..."
    local detected_service=""
    
    # 方法1: 通过 systemctl list-unit-files 查找
    if systemctl list-unit-files 2>/dev/null | grep -qE "^(sshd|ssh)\.service"; then
        detected_service=$(systemctl list-unit-files 2>/dev/null | grep -oE "^(sshd|ssh)\.service" | head -1 | sed 's/\.service//')
    fi
    
    # 方法2: 通过服务状态检查
    if [[ -z "$detected_service" ]]; then
        for svc in sshd ssh; do
            if systemctl status "$svc" >/dev/null 2>&1; then
                detected_service="$svc"
                break
            fi
        done
    fi
    
    # 方法3: 通过进程名检查
    if [[ -z "$detected_service" ]]; then
        if pgrep -x "sshd" >/dev/null 2>&1; then
            detected_service="sshd"
        elif pgrep -x "ssh" >/dev/null 2>&1; then
            detected_service="ssh"
        fi
    fi
    
    # 方法4: 使用发行版默认值
    if [[ -z "$detected_service" ]]; then
        if [[ -f /etc/debian_version ]]; then
            detected_service="ssh"  # Debian/Ubuntu 默认
        else
            detected_service="sshd" # RHEL/CentOS 默认
        fi
        print_warning "使用默认服务名: $detected_service"
    fi
    
    SSH_SERVICE="$detected_service"
    print_success "SSH 服务名称: $SSH_SERVICE"
    return 0
}

validate_ssh_service() {
    # 验证 SSH_SERVICE 变量和实际服务
    if [[ -z "$SSH_SERVICE" ]]; then
        print_error "SSH_SERVICE 变量为空"
        return 1
    fi
    
    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${SSH_SERVICE}.service"; then
        print_warning "$SSH_SERVICE.service 未注册，尝试备选名称"
        
        # 尝试备选名称
        local alt_service=""
        if [[ "$SSH_SERVICE" == "ssh" ]]; then
            alt_service="sshd"
        else
            alt_service="ssh"
        fi
        
        if systemctl list-unit-files 2>/dev/null | grep -q "^${alt_service}.service"; then
            print_info "切换到备选服务: $alt_service"
            SSH_SERVICE="$alt_service"
        else
            print_error "无法找到有效的 SSH 服务"
            return 1
        fi
    fi
    
    return 0
}

safe_ssh_command() {
    # 统一的 SSH 服务操作函数
    local action="${1:-status}"
    
    # 确保 SSH_SERVICE 已设置
    if [[ -z "$SSH_SERVICE" ]]; then
        detect_ssh_service || return 1
    fi
    
    # 验证服务有效性
    validate_ssh_service || return 1
    
    print_info "执行: systemctl $action $SSH_SERVICE"
    
    case "$action" in
        restart|start|stop|enable|disable)
            if systemctl "$action" "$SSH_SERVICE" 2>/dev/null; then
                print_success "systemctl $action $SSH_SERVICE 成功"
                return 0
            else
                print_error "systemctl $action $SSH_SERVICE 失败"
                return 1
            fi
            ;;
        status|is-active)
            systemctl "$action" "$SSH_SERVICE" 2>/dev/null
            return $?
            ;;
        *)
            print_error "不支持的操作: $action"
            return 1
            ;;
    esac
}

safe_sshd_test() {
    # 安全的 SSH 配置测试
    local error_output
    if error_output=$(sshd -t 2>&1); then
        return 0
    else
        print_error "SSH 配置测试失败: $error_output"
        return 1
    fi
}

# ========== 系统检查函数 ==========
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 用户执行"
        exit 1
    fi
    
    # 动态获取实际操作的用户
    if [[ -n "$SUDO_USER" ]]; then
        SSH_USER="$SUDO_USER"
        print_info "检测到 sudo 用户: $SSH_USER"
    else
        SSH_USER="root"
        print_info "使用 root 用户"
    fi
    
    # 验证用户存在性
    if ! id "$SSH_USER" &>/dev/null; then
        print_warning "用户 $SSH_USER 不存在，回退为 root"
        SSH_USER="root"
    fi
}

check_ssh_service() {
    print_info "[0/10] 检查 SSH 服务..."
    
    # 1. 检测服务名称
    detect_ssh_service || {
        print_error "无法检测 SSH 服务名称"
        exit 1
    }
    
    # 2. 检查并安装 OpenSSH
    if ! dpkg -l 2>/dev/null | grep -qE "^ii\s+openssh-server"; then
        print_warning "未检测到 OpenSSH 服务，正在安装..."
        apt-get update -qq
        apt-get install -y openssh-server || {
            print_error "OpenSSH 安装失败"
            exit 1
        }
        print_success "OpenSSH 服务安装完成"
    else
        print_success "OpenSSH 服务已安装"
    fi
    
    # 3. 确保服务运行
    if ! systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null; then
        print_warning "$SSH_SERVICE 服务未运行，正在启动..."
        safe_ssh_command "start" || {
            print_error "无法启动 SSH 服务"
            exit 1
        }
    fi
    
    # 4. 设置开机自启
    safe_ssh_command "enable" || print_warning "无法设置 $SSH_SERVICE 开机自启"
    
    echo ""
}

check_network() {
    print_info "[1/10] 检查网络环境..."
    
    # 获取 IPv4 地址
    IPV4_ADDR=$(ip -4 addr show scope global 2>/dev/null | \
                grep -w "inet" | \
                grep -v "127.0.0.1" | \
                awk '{print $2}' | \
                cut -d/ -f1 | \
                head -1)
    
    # 获取 IPv6 地址（改进过滤逻辑）
    IPV6_ADDR=$(ip -6 addr show scope global 2>/dev/null | \
                grep -w "inet6" | \
                grep -vE "fe80:|temporary|deprecated" | \
                grep -v "::1" | \
                awk '{print $2}' | \
                cut -d/ -f1 | \
                head -1)
    
    echo "  检测到 IPv4: ${IPV4_ADDR:-无}"
    echo "  检测到 IPv6: ${IPV6_ADDR:-无}"
    
    # 验证网络栈类型与IP可用性
    local can_continue=true
    
    if [[ "$STACK_TYPE" == "ipv6" ]] && [[ -z "$IPV6_ADDR" ]]; then
        print_error "选择仅 IPv6 但未检测到公网 IPv6 地址"
        can_continue=false
    elif [[ "$STACK_TYPE" == "ipv4" ]] && [[ -z "$IPV4_ADDR" ]]; then
        print_error "选择仅 IPv4 但未检测到公网 IPv4 地址"
        can_continue=false
    elif [[ "$STACK_TYPE" == "dual" ]] && [[ -z "$IPV4_ADDR" ]] && [[ -z "$IPV6_ADDR" ]]; then
        print_error "选择双栈但未检测到任何公网 IP 地址"
        can_continue=false
    fi
    
    if ! $can_continue; then
        read -p "是否继续？(y/n): " CONTINUE
        [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]] && exit 1
    fi
    
    print_success "网络环境检查完成"
    echo ""
}

# ========== 用户配置函数 ==========
configure_port() {
    print_info "[配置] SSH 端口设置"
    
    while true; do
        read -p "请输入新的 SSH 端口号 (${MIN_PORT}-${MAX_PORT}，默认 ${DEFAULT_PORT}): " input_port
        NEW_SSH_PORT=${input_port:-$DEFAULT_PORT}
        
        # 验证端口号
        if [[ ! "$NEW_SSH_PORT" =~ ^[0-9]+$ ]]; then
            print_error "端口号必须为数字"
            continue
        fi
        
        if [[ "$NEW_SSH_PORT" -lt "$MIN_PORT" ]] || [[ "$NEW_SSH_PORT" -gt "$MAX_PORT" ]]; then
            print_error "端口号必须在 ${MIN_PORT}-${MAX_PORT} 之间"
            continue
        fi
        
        # 检查端口是否被占用
        if ss -tlnp 2>/dev/null | grep -q ":${NEW_SSH_PORT}\s"; then
            print_warning "端口 $NEW_SSH_PORT 已被占用"
            read -p "是否继续使用此端口？(y/n): " use_occupied
            [[ "$use_occupied" != "y" && "$use_occupied" != "Y" ]] && continue
        fi
        
        break
    done
    
    print_success "新 SSH 端口: $NEW_SSH_PORT"
    echo ""
}

configure_stack() {
    print_info "[配置] SSH 端口网络栈类型"
    echo "1) 双栈 (IPv4 + IPv6) - 推荐"
    echo "2) 仅 IPv4"
    echo "3) 仅 IPv6"
    
    while true; do
        read -p "请选择 (1/2/3，默认 1): " stack_choice
        stack_choice=${stack_choice:-1}
        
        case $stack_choice in
            1) 
                STACK_TYPE="dual"
                STACK_DESC="双栈 (IPv4 + IPv6)"
                break 
                ;;
            2) 
                STACK_TYPE="ipv4"
                STACK_DESC="仅 IPv4"
                break 
                ;;
            3) 
                STACK_TYPE="ipv6"
                STACK_DESC="仅 IPv6"
                break 
                ;;
            *) 
                print_error "无效选择，请输入 1、2 或 3"
                ;;
        esac
    done
    
    print_success "网络栈类型: $STACK_DESC"
    echo ""
}

# ========== UFW 安装与配置函数 ==========
install_ufw() {
    print_info "[2/10] 安装 UFW..."
    
    apt-get update -qq
    apt-get install -y ufw || {
        print_error "UFW 安装失败"
        exit 1
    }
    
    # 确保 UFW 默认配置文件存在
    mkdir -p "$(dirname "$UFW_DEFAULT")"
    
    # 启用 IPv6 支持
    if [[ -f "$UFW_DEFAULT" ]]; then
        if grep -q "^IPV6=" "$UFW_DEFAULT"; then
            sed -i 's/^IPV6=.*/IPV6=yes/' "$UFW_DEFAULT"
        else
            echo "IPV6=yes" >> "$UFW_DEFAULT"
        fi
    else
        echo "IPV6=yes" > "$UFW_DEFAULT"
    fi
    
    print_success "UFW 安装完成，IPv6 已启用"
}

# ========== SSH 配置文件处理函数 ==========
check_sshd_config() {
    print_info "[3/10] 检查 SSH 配置文件..."
    
    # 如果配置文件不存在，尝试恢复或创建
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        print_warning "$SSHD_CONFIG 不存在，尝试恢复..."
        local created=false
        
        # 尝试多个可能的源
        for src in \
            "/etc/ssh/sshd_config.dpkg-dist" \
            "/usr/share/openssh/sshd_config" \
            "/usr/share/doc/openssh-server/examples/sshd_config"; do
            if [[ -f "$src" ]]; then
                cp "$src" "$SSHD_CONFIG"
                created=true
                print_success "从 $src 恢复配置文件"
                break
            fi
        done
        
        if ! $created; then
            # 创建基本配置
            print_warning "创建默认 SSH 配置文件"
            cat > "$SSHD_CONFIG" << 'EOF'
# Default SSH Server Configuration
Include /etc/ssh/sshd_config.d/*.conf
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::
PubkeyAuthentication yes
PasswordAuthentication yes
PermitRootLogin yes
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
        fi
    fi
    
    # 提取当前端口
    CURRENT_SSH_PORT=$(grep -E "^[[:space:]]*Port[[:space:]]" "$SSHD_CONFIG" | \
                       awk '{print $2}' | head -1)
    CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-$DEFAULT_SSH_PORT}
    
    echo "  当前 SSH 端口: $CURRENT_SSH_PORT"
    echo ""
}

set_ssh_option() {
    local key="$1"
    local value="$2"
    local config_file="${3:-$SSHD_CONFIG}"
    
    if [[ ! -f "$config_file" ]]; then
        print_error "配置文件 $config_file 不存在"
        return 1
    fi
    
    if [[ ! -w "$config_file" ]]; then
        print_error "配置文件 $config_file 不可写"
        return 1
    fi
    
    # 设置或更新配置项
    if grep -qE "^[[:space:]]*[#]*${key}[[:space:]]" "$config_file"; then
        sed -i "s|^[[:space:]]*[#]*${key}[[:space:]].*|${key} ${value}|g" "$config_file"
    else
        echo "${key} ${value}" >> "$config_file"
    fi
    
    return 0
}

backup_sshd_config() {
    BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    if cp "$SSHD_CONFIG" "$BACKUP_FILE"; then
        print_info "配置文件已备份至: $BACKUP_FILE"
        return 0
    else
        print_error "配置文件备份失败"
        return 1
    fi
}

# ========== 防火墙规则配置 ==========
configure_ufw_rules_safely() {
    print_info "[4/10] 安全配置 UFW 防火墙规则..."
    print_warning "正在配置防火墙规则，请勿中断..."
    
    # 步骤1: 禁用并重置 UFW
    ufw --force disable > /dev/null 2>&1 || true
    echo "y" | ufw --force reset > /dev/null 2>&1 || true
    
    # 步骤2: 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging low
    
    # 步骤3: 【关键】在启用UFW前添加所有放行规则
    
    # 3.1 放行当前SSH端口（保持现有连接）
    if [[ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]]; then
        ufw allow "$CURRENT_SSH_PORT/tcp" comment "Current SSH port (temporary)"
        print_info "已添加当前端口 $CURRENT_SSH_PORT 的临时放行规则"
    fi
    
    # 3.2 添加新SSH端口的限速规则
    local rules_added=false
    
    # IPv4规则
    if [[ "$STACK_TYPE" == "dual" ]] || [[ "$STACK_TYPE" == "ipv4" ]]; then
        if ufw limit proto tcp from 0.0.0.0/0 to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv4"; then
            print_info "已添加新端口 $NEW_SSH_PORT 的IPv4限速规则"
            rules_added=true
        else
            print_error "IPv4限速规则添加失败"
        fi
    fi
    
    # IPv6规则（仅当系统支持IPv6时添加）
    if [[ "$STACK_TYPE" == "dual" ]] || [[ "$STACK_TYPE" == "ipv6" ]]; then
        if [[ -n "$IPV6_ADDR" ]] || [[ "$STACK_TYPE" == "ipv6" ]]; then
            if ufw limit proto tcp from ::/0 to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv6"; then
                print_info "已添加新端口 $NEW_SSH_PORT 的IPv6限速规则"
                rules_added=true
            else
                print_error "IPv6限速规则添加失败"
            fi
        else
            print_warning "系统无IPv6地址，跳过IPv6规则"
        fi
    fi
    
    if ! $rules_added; then
        print_error "未能添加任何防火墙规则"
        exit 1
    fi
    
    # 步骤4: 启用 UFW
    print_info "正在启用 UFW..."
    if ufw --force enable > /dev/null 2>&1; then
        print_success "防火墙规则已安全配置并启用"
    else
        print_error "UFW 启用失败"
        exit 1
    fi
    
    echo ""
}

# ========== SSH 端口修改 ==========
modify_ssh_port() {
    print_info "[5/10] 修改 SSH 端口配置..."
    
    # 备份配置
    backup_sshd_config || {
        print_error "配置备份失败，中止操作"
        exit 1
    }
    
    # 清理所有旧的 Port 行（避免重复）
    sed -i '/^[[:space:]]*Port[[:space:]]/d' "$SSHD_CONFIG"
    
    # 添加新旧端口
    echo "Port $CURRENT_SSH_PORT" >> "$SSHD_CONFIG"
    echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
    
    # 验证配置语法
    if ! safe_sshd_test; then
        print_error "SSH 配置语法错误，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        exit 1
    fi
    
    # 重启 SSH 服务
    print_info "正在重启 SSH 服务..."
    if safe_ssh_command "restart"; then
        sleep 2
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            print_success "SSH 端口已配置: $CURRENT_SSH_PORT (旧) + $NEW_SSH_PORT (新)"
        else
            print_error "SSH 服务启动异常，恢复备份"
            cp "$BACKUP_FILE" "$SSHD_CONFIG"
            safe_ssh_command "restart" || true
            exit 1
        fi
    else
        print_error "SSH 服务重启失败，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        safe_ssh_command "restart" || {
            print_error "自动恢复失败，请手动执行: systemctl restart $SSH_SERVICE"
        }
        exit 1
    fi
    echo ""
}

# ========== SSH 密钥配置 ==========
configure_ssh_key() {
    print_info "[6/10] 配置 SSH 公钥..."
    echo ""
    print_info "目标用户: $SSH_USER"
    echo -n "请粘贴公钥 (以 ssh-rsa/ssh-ed25519 等开头): "
    
    local public_key=""
    read -r public_key
    
    # 清理输入
    public_key=$(echo "$public_key" | tr -d '\r\n' | xargs)
    
    # 验证公钥
    if [[ -z "$public_key" ]]; then
        print_error "未检测到公钥输入"
        exit 1
    fi
    
    # 验证公钥格式（更严格的正则）
    if ! echo "$public_key" | grep -qE "^[[:space:]]*(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)[[:space:]]"; then
        print_error "公钥格式不正确"
        echo -e "${YELLOW}期望格式: ssh-rsa/ssh-ed25519/ecdsa-sha2-nistp 开头${NC}"
        echo -e "${YELLOW}您输入的内容：${NC}"
        echo "$public_key"
        exit 1
    fi
    
    # 确定 .ssh 目录
    local ssh_dir=""
    if [[ "$SSH_USER" == "root" ]]; then
        ssh_dir="/root/.ssh"
    else
        ssh_dir="/home/${SSH_USER}/.ssh"
    fi
    
    # 创建 .ssh 目录
    if ! mkdir -p "$ssh_dir"; then
        print_error "无法创建 $ssh_dir 目录"
        exit 1
    fi
    
    # 设置目录权限
    chmod 700 "$ssh_dir"
    if [[ "$SSH_USER" != "root" ]]; then
        chown "${SSH_USER}:${SSH_USER}" "$ssh_dir" 2>/dev/null || true
    fi
    
    # 备份旧密钥
    AUTH_KEYS_FILE="${ssh_dir}/authorized_keys"
    if [[ -f "$AUTH_KEYS_FILE" ]]; then
        cp "$AUTH_KEYS_FILE" "${AUTH_KEYS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        print_info "已备份旧密钥文件"
    fi
    
    # 写入新公钥
    if echo "$public_key" > "$AUTH_KEYS_FILE"; then
        chmod 600 "$AUTH_KEYS_FILE"
        if [[ "$SSH_USER" != "root" ]]; then
            chown "${SSH_USER}:${SSH_USER}" "$AUTH_KEYS_FILE" 2>/dev/null || true
        fi
        print_success "公钥写入完成"
    else
        print_error "公钥写入失败"
        exit 1
    fi
}

verify_ssh_key() {
    print_info "[7/10] 验证公钥..."
    
    if [[ ! -f "$AUTH_KEYS_FILE" ]]; then
        print_error "密钥文件不存在: $AUTH_KEYS_FILE"
        exit 1
    fi
    
    if ssh-keygen -l -f "$AUTH_KEYS_FILE" >/dev/null 2>&1; then
        print_success "密钥验证通过："
        ssh-keygen -l -f "$AUTH_KEYS_FILE"
    else
        print_error "密钥验证失败"
        echo "密钥文件内容："
        cat "$AUTH_KEYS_FILE"
        exit 1
    fi
    echo ""
}

# ========== SSH 安全优化 ==========
optimize_ssh_security() {
    print_info "[8/10] 优化 SSH 安全配置..."
    
    # 设置安全选项（明确每个配置项的作用）
    set_ssh_option "PubkeyAuthentication" "yes"          # 启用密钥认证
    set_ssh_option "PasswordAuthentication" "yes"         # 暂时保留密码登录
    set_ssh_option "PermitRootLogin" "prohibit-password"  # 禁止root密码登录
    set_ssh_option "MaxAuthTries" "5"                     # 限制认证尝试次数
    set_ssh_option "X11Forwarding" "no"                   # 关闭X11转发
    set_ssh_option "PermitEmptyPasswords" "no"            # 禁止空密码
    
    # 可选：禁用不安全的认证方式
    set_ssh_option "ChallengeResponseAuthentication" "no"
    set_ssh_option "KerberosAuthentication" "no"
    set_ssh_option "GSSAPIAuthentication" "no"
    
    # 验证配置
    if ! safe_sshd_test; then
        print_error "SSH 配置语法错误，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        exit 1
    fi
    
    # 重启服务应用配置
    print_info "正在重启 SSH 服务应用新配置..."
    if safe_ssh_command "restart"; then
        sleep 2
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            print_success "SSH 安全策略应用成功"
        else
            print_error "SSH 服务异常，恢复备份"
            cp "$BACKUP_FILE" "$SSHD_CONFIG"
            safe_ssh_command "restart" || true
            exit 1
        fi
    else
        print_error "SSH 服务重启失败，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        safe_ssh_command "restart" || true
        exit 1
    fi
    echo ""
}

# ========== 输出函数 ==========
print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  配置完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    echo -e "${YELLOW}配置摘要：${NC}"
    echo -e "  脚本版本:       ${SCRIPT_VERSION}"
    echo -e "  SSH 服务:       $SSH_SERVICE"
    echo -e "  旧 SSH 端口:    $CURRENT_SSH_PORT"
    echo -e "  新 SSH 端口:    ${GREEN}$NEW_SSH_PORT${NC}"
    echo -e "  网络栈类型:     $STACK_DESC"
    echo -e "  目标用户:       $SSH_USER"
    echo -e "  公钥文件:       $AUTH_KEYS_FILE"
    echo -e "  配置备份:       $BACKUP_FILE"
    echo ""
    
    print_info "当前防火墙规则："
    ufw status numbered 2>/dev/null || ufw status 2>/dev/null || print_warning "无法获取防火墙状态"
    echo ""
}

print_test_instructions() {
    print_info "[9/10] 下一步：测试密钥登录"
    echo ""
    
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠  重要提示：请保持当前终端窗口不要关闭！           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${GREEN}请在新的终端窗口中测试以下命令：${NC}"
    echo ""
    
    # 根据网络栈类型显示对应的连接命令
    if [[ -n "$IPV4_ADDR" ]] && [[ "$STACK_TYPE" != "ipv6" ]]; then
        echo -e "  ${BLUE}[IPv4 连接]${NC}"
        echo "  ssh -p $NEW_SSH_PORT $SSH_USER@$IPV4_ADDR"
    fi
    
    if [[ -n "$IPV6_ADDR" ]] && [[ "$STACK_TYPE" != "ipv4" ]]; then
        echo -e "  ${BLUE}[IPv6 连接]${NC}"
        echo "  ssh -p $NEW_SSH_PORT $SSH_USER@[$IPV6_ADDR]"
    fi
    
    echo ""
    echo -e "${YELLOW}后续优化建议：${NC}"
    echo ""
    echo -e "${YELLOW}1. 确认密钥登录成功后，关闭密码登录：${NC}"
    echo "   sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG"
    echo "   sudo systemctl restart $SSH_SERVICE"
    echo ""
    
    echo -e "${YELLOW}2. 确认新端口正常后，移除旧端口（可选）：${NC}"
    echo "   sudo sed -i '/^Port $CURRENT_SSH_PORT/d' $SSHD_CONFIG"
    echo "   sudo ufw delete allow $CURRENT_SSH_PORT/tcp"
    echo "   sudo systemctl restart $SSH_SERVICE"
    echo ""
    
    echo -e "${YELLOW}3. 云服务器用户必须操作：${NC}"
    echo -e "   ${RED}在云平台安全组/防火墙规则中放行端口: $NEW_SSH_PORT${NC}"
    echo ""
    
    echo -e "${GREEN}UFW 常用管理命令：${NC}"
    echo "  ufw status numbered              # 查看防火墙规则（带编号）"
    echo "  ufw delete <编号>                # 删除指定编号的规则"
    echo "  ufw enable                       # 启用防火墙"
    echo "  ufw disable                      # 禁用防火墙"
    echo "  ufw reload                       # 重新加载规则"
    echo ""
    
    echo -e "${GREEN}SSH 服务管理命令：${NC}"
    echo "  systemctl status $SSH_SERVICE    # 查看服务状态"
    echo "  systemctl restart $SSH_SERVICE   # 重启服务"
    echo "  journalctl -u $SSH_SERVICE -f    # 查看实时日志"
    echo ""
}

# ========== 错误恢复函数 ==========
cleanup_on_error() {
    local exit_code=$?
    
    echo ""
    print_error "脚本执行出错 (退出码: $exit_code)"
    print_warning "正在尝试安全恢复..."
    
    # 恢复 SSH 配置（如果有备份）
    if [[ -f "$BACKUP_FILE" ]] && [[ -f "$SSHD_CONFIG" ]]; then
        print_info "恢复 SSH 配置备份..."
        if cp "$BACKUP_FILE" "$SSHD_CONFIG"; then
            print_success "SSH 配置已恢复"
        else
            print_error "SSH 配置恢复失败"
        fi
    fi
    
    # 尝试重启 SSH 服务
    print_info "尝试重启 SSH 服务..."
    if [[ -n "$SSH_SERVICE" ]]; then
        if systemctl restart "$SSH_SERVICE" 2>/dev/null; then
            print_success "$SSH_SERVICE 服务已重启"
        else
            print_warning "使用 $SSH_SERVICE 重启失败，尝试备选方案..."
            # 尝试所有可能的SSH服务名
            for svc in ssh sshd; do
                if systemctl restart "$svc" 2>/dev/null; then
                    print_success "使用 $svc 重启成功"
                    break
                fi
            done
        fi
    else
        # SSH_SERVICE 为空，尝试所有可能
        for svc in ssh sshd; do
            if systemctl restart "$svc" 2>/dev/null; then
                print_success "使用 $svc 重启成功"
                break
            fi
        done
    fi
    
    # 确保 SSH 服务运行
    if ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null; then
        print_error "所有 SSH 服务均未运行！请手动检查系统状态"
    fi
    
    print_warning "备份文件位置: ${BACKUP_FILE:-未创建}"
    print_warning "请检查系统状态，必要时手动恢复"
    
    exit $exit_code
}

# ========== 主函数 ==========
main() {
    # 设置错误陷阱
    trap cleanup_on_error ERR
    
    print_banner
    
    # 系统检查
    check_root
    check_ssh_service
    
    # 用户配置
    configure_port
    configure_stack
    
    # 环境检查
    check_network
    
    # 安装和配置组件
    install_ufw
    check_sshd_config
    
    # 核心配置（顺序不能改变！）
    # 1. 先配置防火墙规则（在UFW启用前添加所有必要规则）
    configure_ufw_rules_safely
    # 2. 再修改SSH端口（此时防火墙已配置好，不会断连）
    modify_ssh_port
    
    # 安全配置
    configure_ssh_key
    verify_ssh_key
    optimize_ssh_security
    
    # 输出信息
    print_summary
    print_test_instructions
    
    print_success "所有配置已完成！请按照上述指引测试新连接。"
}

# ========== 脚本入口 ==========
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
