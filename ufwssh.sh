#!/bin/bash
#
# Debian UFW 防火墙 + SSH 密钥登录一键配置脚本 (修正版 v3.2)
# 修正：
#   1. 移除 allow 规则，直接使用 limit（避免顺序问题）
#   2. 强制启用 IPv6 支持
#   3. 修复多行 Port 提取问题
#   4. SSH 配置统一处理避免重复追加
#   5. 添加云平台安全组提醒
#   6. 修复 sshd_config 文件不存在的问题
#   7. 添加 SSH 配置文件存在性检查和自动创建
#   8. 统一变量命名规范和函数封装
#   9. 修复防火墙规则添加顺序
#   10. 改进 SSH 服务管理逻辑
#

set -e

# ========== 全局常量定义 ==========
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly SSH_USER="root"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
readonly UFW_DEFAULT="/etc/default/ufw"
readonly MIN_PORT=1024
readonly MAX_PORT=65535
readonly DEFAULT_PORT=2222
readonly DEFAULT_SSH_PORT=22

# ========== 全局变量 ==========
NEW_SSH_PORT=""
CURRENT_SSH_PORT=""
STACK_TYPE=""
STACK_DESC=""
IPV4_ADDR=""
IPV6_ADDR=""
BACKUP_FILE=""
AUTH_KEYS_FILE=""

# ========== 工具函数 ==========
print_banner() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Debian UFW + SSH 安全配置脚本 v3.2${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

print_error() {
    echo -e "${RED}错误：$1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}警告：$1${NC}"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${BLUE}$1${NC}"
}

# ========== 系统检查函数 ==========
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 用户执行"
        exit 1
    fi
}

check_ssh_service() {
    print_info "[0/10] 检查 SSH 服务..."
    
    # 检测 SSH 服务名称
    if systemctl list-unit-files | grep -q "sshd.service"; then
        SSH_SERVICE="sshd"
    elif systemctl list-unit-files | grep -q "ssh.service"; then
        SSH_SERVICE="ssh"
    else
        SSH_SERVICE="ssh"
    fi
    
    # 检查并安装 OpenSSH
    if ! dpkg -l | grep -qE "^ii.*openssh-server"; then
        print_warning "未检测到 OpenSSH 服务，正在安装..."
        apt-get update -qq
        apt-get install -y openssh-server
        print_success "OpenSSH 服务安装完成"
    else
        print_success "OpenSSH 服务已安装"
    fi
    
    # 确保服务运行
    systemctl start "$SSH_SERVICE" 2>/dev/null || true
    systemctl enable "$SSH_SERVICE" 2>/dev/null || true
    
    echo ""
    return 0
}

check_network() {
    print_info "[1/10] 检查网络环境..."
    
    # 获取 IPv4 地址（过滤回环地址）
    IPV4_ADDR=$(ip -4 addr show scope global | grep -w "inet" | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -1)
    
    # 获取 IPv6 地址（过滤链路本地和临时地址）
    IPV6_ADDR=$(ip -6 addr show scope global | grep -w "inet6" | grep -vE "(fe80|temporary|deprecated)" | awk '{print $2}' | cut -d/ -f1 | head -1)
    
    echo "  检测到 IPv4: ${IPV4_ADDR:-无}"
    echo "  检测到 IPv6: ${IPV6_ADDR:-无}"
    
    # 栈类型与 IP 可用性检查
    if [[ "$STACK_TYPE" == "ipv6" ]] && [[ -z "$IPV6_ADDR" ]]; then
        print_error "选择仅 IPv6 但未检测到公网 IPv6 地址"
        read -p "是否继续？(y/n): " CONTINUE
        [[ "$CONTINUE" != "y" ]] && exit 1
    elif [[ "$STACK_TYPE" == "ipv4" ]] && [[ -z "$IPV4_ADDR" ]]; then
        print_error "选择仅 IPv4 但未检测到公网 IPv4 地址"
        read -p "是否继续？(y/n): " CONTINUE
        [[ "$CONTINUE" != "y" ]] && exit 1
    elif [[ "$STACK_TYPE" == "dual" ]] && [[ -z "$IPV4_ADDR" ]] && [[ -z "$IPV6_ADDR" ]]; then
        print_error "未检测到任何公网 IP 地址"
        read -p "是否继续？(y/n): " CONTINUE
        [[ "$CONTINUE" != "y" ]] && exit 1
    fi
    
    print_success "网络环境检查完成"
    return 0
}

# ========== 配置函数 ==========
configure_port() {
    print_info "[配置] SSH 端口设置"
    
    while true; do
        read -p "请输入新的 SSH 端口号 (${MIN_PORT}-${MAX_PORT}，默认 ${DEFAULT_PORT}): " NEW_SSH_PORT
        NEW_SSH_PORT=${NEW_SSH_PORT:-$DEFAULT_PORT}
        
        if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && \
           [ "$NEW_SSH_PORT" -ge "$MIN_PORT" ] && \
           [ "$NEW_SSH_PORT" -le "$MAX_PORT" ]; then
            break
        else
            print_error "端口号必须在 ${MIN_PORT}-${MAX_PORT} 之间"
        fi
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
        read -p "请选择 (1/2/3，默认 1): " STACK_CHOICE
        STACK_CHOICE=${STACK_CHOICE:-1}
        
        case $STACK_CHOICE in
            1) STACK_TYPE="dual";  STACK_DESC="双栈 (IPv4 + IPv6)"; break ;;
            2) STACK_TYPE="ipv4";  STACK_DESC="仅 IPv4"; break ;;
            3) STACK_TYPE="ipv6";  STACK_DESC="仅 IPv6"; break ;;
            *) print_error "无效选择，请输入 1、2 或 3" ;;
        esac
    done
    
    print_success "网络栈类型: $STACK_DESC"
    echo ""
}

# ========== UFW 配置函数 ==========
install_ufw() {
    print_info "[2/10] 安装 UFW..."
    
    apt-get update -qq
    apt-get install -y ufw
    
    # 确保 UFW 默认配置文件存在
    if [[ ! -f "$UFW_DEFAULT" ]]; then
        print_warning "创建 UFW 默认配置文件..."
        mkdir -p "$(dirname "$UFW_DEFAULT")"
        echo 'IPV6=yes' > "$UFW_DEFAULT"
    fi
    
    # 强制开启 IPv6 支持
    if grep -q "^IPV6=" "$UFW_DEFAULT"; then
        sed -i 's/^IPV6=.*/IPV6=yes/' "$UFW_DEFAULT"
    else
        echo "IPV6=yes" >> "$UFW_DEFAULT"
    fi
    
    print_success "UFW 安装完成，IPv6 已启用"
}

configure_ufw_base() {
    print_info "[4/10] 初始化 UFW 基础规则..."
    
    # 禁用 UFW 以清空规则
    ufw --force disable > /dev/null 2>&1 || true
    
    # 重置所有规则
    echo "y" | ufw --force reset > /dev/null 2>&1 || true
    
    # 设置默认策略
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny routed
    
    # 开启日志记录（低级别）
    ufw logging low
    
    print_success "UFW 基础规则已设置"
}

# ========== SSH 配置函数 ==========
check_sshd_config() {
    print_info "[3/10] 检查 SSH 配置文件..."
    
    # 检查主配置文件
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        print_warning "$SSHD_CONFIG 不存在，尝试恢复或创建..."
        
        local created=false
        
        # 尝试从多个位置恢复配置
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
        
        # 如果无法恢复，创建默认配置
        if ! $created; then
            print_warning "创建默认 SSH 配置文件..."
            create_default_sshd_config
            created=true
        fi
        
        if ! $created; then
            print_error "无法创建 SSH 配置文件"
            exit 1
        fi
    else
        print_success "SSH 配置文件已存在"
    fi
    
    # 获取当前 SSH 端口
    CURRENT_SSH_PORT=$(grep -E "^Port[[:space:]]" "$SSHD_CONFIG" | awk '{print $2}' | head -n1)
    CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-$DEFAULT_SSH_PORT}
    
    echo "  当前 SSH 端口: $CURRENT_SSH_PORT"
    echo ""
}

create_default_sshd_config() {
    cat > "$SSHD_CONFIG" << 'EOF'
# OpenSSH Server Configuration (Generated by setup script)
Include /etc/ssh/sshd_config.d/*.conf

Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# HostKeys
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Logging
SyslogFacility AUTH
LogLevel INFO

# Authentication
LoginGraceTime 2m
PermitRootLogin yes
StrictModes yes
MaxAuthTries 6
MaxSessions 10

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

PasswordAuthentication yes
PermitEmptyPasswords no

ChallengeResponseAuthentication no
UsePAM yes

# Forwarding
X11Forwarding yes
PrintMotd no

# Environment
AcceptEnv LANG LC_*

# Subsystem
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
}

set_ssh_option() {
    local key="$1"
    local value="$2"
    local config_file="${3:-$SSHD_CONFIG}"
    
    if [[ ! -w "$config_file" ]]; then
        print_error "配置文件 $config_file 不可写"
        return 1
    fi
    
    if grep -qE "^[#]*${key}[[:space:]]" "$config_file"; then
        sed -i "s|^[#]*${key}[[:space:]].*|${key} ${value}|" "$config_file"
    else
        echo "${key} ${value}" >> "$config_file"
    fi
}

backup_sshd_config() {
    BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP_FILE"
    echo "  配置文件已备份至: $BACKUP_FILE"
}

modify_ssh_port() {
    print_info "[5/10] 修改 SSH 端口配置..."
    
    backup_sshd_config
    
    # 确保旧端口配置存在
    if ! grep -qE "^Port[[:space:]]+${CURRENT_SSH_PORT}" "$SSHD_CONFIG"; then
        echo "Port ${CURRENT_SSH_PORT}" >> "$SSHD_CONFIG"
    fi
    
    # 添加新端口配置
    if ! grep -qE "^Port[[:space:]]+${NEW_SSH_PORT}" "$SSHD_CONFIG"; then
        echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONFIG"
    fi
    
    # 验证 SSH 配置语法
    if ! sshd -t; then
        print_error "SSH 配置语法错误，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        systemctl restart "$SSH_SERVICE"
        exit 1
    fi
    
    # 重启 SSH 服务
    if ! systemctl restart "$SSH_SERVICE"; then
        print_error "SSH 服务重启失败，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        systemctl restart "$SSH_SERVICE"
        exit 1
    fi
    
    # 验证服务运行状态
    sleep 2
    if ! systemctl is-active --quiet "$SSH_SERVICE"; then
        print_error "SSH 服务未运行，检查状态..."
        systemctl status "$SSH_SERVICE" --no-pager
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        systemctl restart "$SSH_SERVICE"
        exit 1
    fi
    
    print_success "SSH 端口已配置: $CURRENT_SSH_PORT (旧) + $NEW_SSH_PORT (新)"
}

# ========== 防火墙规则配置函数 ==========
configure_firewall_rules() {
    print_info "[6/10] 配置新 SSH 端口防火墙规则 ($STACK_DESC)..."
    
    # 先添加新端口的 limit 规则
    add_ssh_firewall_rules "$NEW_SSH_PORT"
    
    # 启用 UFW 并添加临时规则保护当前连接
    ufw --force enable > /dev/null 2>&1 || true
    
    # 临时放行当前 SSH 端口（确保当前连接不中断）
    if [[ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]]; then
        ufw allow "$CURRENT_SSH_PORT/tcp" comment "Current SSH port (temporary)"
        print_warning "已临时放行当前端口 $CURRENT_SSH_PORT，请在新端口可用后删除"
    fi
    
    print_success "防火墙规则已应用"
}

add_ssh_firewall_rules() {
    local port="$1"
    local added_rules=false
    
    case $STACK_TYPE in
        dual)
            # 双栈：先添加 IPv4，再添加 IPv6
            ufw limit proto tcp from 0.0.0.0/0 to any port "$port" comment "SSH rate limit IPv4"
            ufw limit proto tcp from ::/0 to any port "$port" comment "SSH rate limit IPv6"
            added_rules=true
            ;;
        ipv4)
            ufw limit proto tcp from 0.0.0.0/0 to any port "$port" comment "SSH rate limit IPv4"
            added_rules=true
            ;;
        ipv6)
            ufw limit proto tcp from ::/0 to any port "$port" comment "SSH rate limit IPv6"
            added_rules=true
            ;;
        *)
            print_error "未知的网络栈类型: $STACK_TYPE"
            return 1
            ;;
    esac
    
    if $added_rules; then
        print_success "已为端口 $port 添加限速规则"
    else
        print_error "防火墙规则添加失败"
        return 1
    fi
}

# ========== SSH 密钥配置函数 ==========
configure_ssh_key() {
    print_info "[7/10] 配置 SSH 公钥..."
    echo ""
    print_info "请粘贴公钥（单行，以 ssh-rsa/ssh-ed25519 开头）："
    
    local public_key=""
    read -r public_key
    
    # 清理输入
    public_key=$(echo "$public_key" | tr -d '\r\n' | xargs)
    
    # 验证公钥
    if ! validate_public_key "$public_key"; then
        exit 1
    fi
    
    # 设置密钥文件路径
    setup_auth_keys_path
    
    # 写入公钥
    write_public_key "$public_key"
}

validate_public_key() {
    local key="$1"
    
    # 检查是否为空
    if [[ -z "$key" ]]; then
        print_error "未检测到公钥输入"
        return 1
    fi
    
    # 检查格式
    if ! echo "$key" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)"; then
        print_error "公钥格式无效"
        echo -e "${YELLOW}您输入的内容：${NC}"
        echo "$key"
        return 1
    fi
    
    # 检查长度
    local key_length=$(echo "$key" | wc -c)
    if [[ $key_length -lt 70 ]]; then
        print_error "公钥长度不足 (${key_length}字符)，可能不完整"
        return 1
    fi
    
    return 0
}

setup_auth_keys_path() {
    local ssh_dir=""
    
    if [[ "$SSH_USER" == "root" ]]; then
        ssh_dir="/root/.ssh"
    else
        ssh_dir="/home/${SSH_USER}/.ssh"
        
        # 检查用户是否存在
        if ! id "$SSH_USER" &>/dev/null; then
            print_error "用户 $SSH_USER 不存在"
            exit 1
        fi
    fi
    
    AUTH_KEYS_FILE="${ssh_dir}/authorized_keys"
    
    # 创建 .ssh 目录
    if [[ ! -d "$ssh_dir" ]]; then
        mkdir -p "$ssh_dir"
        chown "${SSH_USER}:${SSH_USER}" "$ssh_dir" 2>/dev/null || true
    fi
    
    chmod 700 "$ssh_dir"
}

write_public_key() {
    local key="$1"
    
    # 备份旧密钥
    if [[ -f "$AUTH_KEYS_FILE" ]]; then
        cp "$AUTH_KEYS_FILE" "${AUTH_KEYS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    
    # 写入新密钥
    echo "$key" > "$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"
    
    # 设置所有者
    if [[ "$SSH_USER" != "root" ]]; then
        chown "${SSH_USER}:${SSH_USER}" "$AUTH_KEYS_FILE" 2>/dev/null || true
    fi
}

verify_ssh_key() {
    print_info "[8/10] 验证公钥..."
    
    if ssh-keygen -l -f "$AUTH_KEYS_FILE" >/dev/null 2>&1; then
        print_success "密钥验证通过："
        ssh-keygen -l -f "$AUTH_KEYS_FILE"
    else
        print_error "密钥验证失败"
        echo "密钥文件内容："
        cat "$AUTH_KEYS_FILE"
        return 1
    fi
}

# ========== SSH 安全配置函数 ==========
optimize_ssh_security() {
    print_info "[9/10] 优化 SSH 安全配置..."
    
    # 设置安全选项
    set_ssh_option "PubkeyAuthentication" "yes"
    set_ssh_option "PasswordAuthentication" "yes"  # 保留密码登录，稍后手动关闭
    set_ssh_option "PermitRootLogin" "prohibit-password"
    set_ssh_option "PermitEmptyPasswords" "no"
    set_ssh_option "MaxAuthTries" "5"
    set_ssh_option "AuthorizedKeysFile" ".ssh/authorized_keys"
    
    # 禁用不安全的选项
    set_ssh_option "ChallengeResponseAuthentication" "no"
    set_ssh_option "KerberosAuthentication" "no"
    set_ssh_option "GSSAPIAuthentication" "no"
    set_ssh_option "X11Forwarding" "no"
    
    # 验证配置并重启服务
    if sshd -t; then
        if systemctl restart "$SSH_SERVICE"; then
            print_success "SSH 安全配置完成，服务运行正常"
        else
            print_error "SSH 服务重启失败，恢复备份"
            cp "$BACKUP_FILE" "$SSHD_CONFIG"
            systemctl restart "$SSH_SERVICE"
            exit 1
        fi
    else
        print_error "SSH 配置语法错误，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        systemctl restart "$SSH_SERVICE"
        exit 1
    fi
    
    # 等待服务稳定
    sleep 2
    
    # 最终验证服务状态
    if ! systemctl is-active --quiet "$SSH_SERVICE"; then
        print_error "SSH 服务未运行"
        systemctl status "$SSH_SERVICE" --no-pager
        exit 1
    fi
}

# ========== 输出和提示函数 ==========
print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  配置完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}配置摘要：${NC}"
    echo -e "  SSH 服务:       $SSH_SERVICE"
    echo -e "  旧 SSH 端口:    $CURRENT_SSH_PORT"
    echo -e "  新 SSH 端口:    ${GREEN}$NEW_SSH_PORT${NC}"
    echo -e "  网络栈类型:     $STACK_DESC"
    echo -e "  SSH 用户:       $SSH_USER"
    echo -e "  公钥文件:       $AUTH_KEYS_FILE"
    echo -e "  配置备份:       $BACKUP_FILE"
    echo ""
    echo -e "${YELLOW}当前防火墙规则：${NC}"
    ufw status numbered
    echo ""
}

print_test_instructions() {
    print_info "[10/10] 下一步：测试密钥登录"
    echo ""
    echo -e "${GREEN}请在新的终端窗口测试：${NC}"
    
    if [[ -n "$IPV4_ADDR" ]] && [[ "$STACK_TYPE" != "ipv6" ]]; then
        echo -e "  ${BLUE}[IPv4]${NC} ssh -i ~/.ssh/id_rsa -p $NEW_SSH_PORT $SSH_USER@$IPV4_ADDR"
    fi
    
    if [[ -n "$IPV6_ADDR" ]] && [[ "$STACK_TYPE" != "ipv4" ]]; then
        echo -e "  ${BLUE}[IPv6]${NC} ssh -i ~/.ssh/id_rsa -p $NEW_SSH_PORT $SSH_USER@$IPV6_ADDR"
    fi
    
    echo ""
    echo -e "${YELLOW}确认密钥登录成功后，禁用密码登录：${NC}"
    echo "  sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG"
    echo "  sudo systemctl restart $SSH_SERVICE"
    echo ""
    echo -e "${YELLOW}可选：移除旧端口（确认新端口正常后）：${NC}"
    echo "  sudo sed -i '/^Port $CURRENT_SSH_PORT/d' $SSHD_CONFIG"
    echo "  sudo ufw delete allow $CURRENT_SSH_PORT/tcp"
    echo "  sudo systemctl restart $SSH_SERVICE"
    echo ""
}

print_cloud_reminder() {
    echo -e "${RED}⚠  云服务器用户重要提醒：${NC}"
    echo -e "  如果使用 AWS / 阿里云 / 腾讯云 / 谷歌云 / Vultr 等平台"
    echo -e "  请在控制台「安全组/防火墙」中放行端口：${YELLOW}$NEW_SSH_PORT${NC}"
    echo -e "  否则即使 UFW 配置正确，外部连接仍会被云防火墙阻挡"
    echo ""
    
    echo -e "${RED}⚠  务必保留当前终端，直到确认新终端可正常登录！${NC}"
    echo ""
    
    echo -e "${GREEN}UFW 常用命令：${NC}"
    echo "  ufw status numbered              # 查看规则"
    echo "  ufw delete <编号>                # 删除规则"
    echo "  ufw disable                      # 临时禁用防火墙"
    echo "  tail -f /var/log/syslog | grep UFW  # 查看防火墙日志"
    echo "  journalctl -u $SSH_SERVICE -f     # 查看 SSH 服务日志"
}

# ========== 清理函数 ==========
cleanup_on_error() {
    print_error "脚本执行出错，尝试恢复..."
    
    if [[ -f "$BACKUP_FILE" ]]; then
        print_warning "恢复 SSH 配置备份..."
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        systemctl restart "$SSH_SERVICE" 2>/dev/null || true
    fi
    
    print_info "请检查系统状态并手动修复问题"
}

# ========== 主函数 ==========
main() {
    # 设置错误处理
    trap cleanup_on_error ERR
    
    print_banner
    
    # 前置检查
    check_root
    check_ssh_service
    
    # 用户配置
    configure_port
    configure_stack
    
    # 网络检查
    check_network
    
    # 安装和配置 UFW
    install_ufw
    
    # 检查 SSH 配置
    check_sshd_config
    
    # 初始化 UFW 基础规则
    configure_ufw_base
    
    # 修改 SSH 端口
    modify_ssh_port
    
    # 配置防火墙规则（顺序很重要）
    configure_firewall_rules
    
    # 配置 SSH 密钥
    configure_ssh_key
    
    # 验证密钥
    verify_ssh_key
    
    # 优化 SSH 安全配置
    optimize_ssh_security
    
    # 输出信息
    print_summary
    print_test_instructions
    print_cloud_reminder
}

# ========== 脚本入口 ==========
main "$@"
