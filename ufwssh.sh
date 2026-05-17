#!/bin/bash
#
# Debian UFW 防火墙 + SSH 密钥登录一键配置脚本 (最终修正版 v3.4)
# 修复历史：
#   v3.1 - 修复 sshd_config 文件不存在的问题
#   v3.2 - 统一变量命名规范和函数封装
#   v3.3 - 修正防火墙启用顺序防止断连，动态获取用户，IPv6安全处理
#   v3.4 - 进一步优化错误处理，添加断连保护机制，完善日志输出
#

set -e

# ========== 全局常量定义 ==========
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly UFW_DEFAULT="/etc/default/ufw"
readonly MIN_PORT=1024
readonly MAX_PORT=65535
readonly DEFAULT_PORT=2222
readonly DEFAULT_SSH_PORT=22
readonly SCRIPT_VERSION="v3.4"

# ========== 全局变量声明（必须在函数外显式声明） ==========
SSH_USER=""           # 操作目标用户
SSH_SERVICE=""        # SSH服务名称（ssh或sshd）
NEW_SSH_PORT=""       # 新SSH端口
CURRENT_SSH_PORT=""   # 当前SSH端口
STACK_TYPE=""         # 网络栈类型
STACK_DESC=""         # 网络栈描述
IPV4_ADDR=""          # IPv4地址
IPV6_ADDR=""          # IPv6地址
BACKUP_FILE=""        # SSH配置备份文件路径
AUTH_KEYS_FILE=""     # 授权密钥文件路径
CONNECTION_SAFE=false # 连接安全保障标志

# ========== 工具函数 ==========
print_banner() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Debian UFW + SSH 安全配置脚本 ${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

print_error() { 
    echo -e "${RED}错误：$1${NC}" >&2
    logger -t "ssh-setup" "ERROR: $1"
}

print_warning() { 
    echo -e "${YELLOW}警告：$1${NC}"
    logger -t "ssh-setup" "WARNING: $1"
}

print_success() { 
    echo -e "${GREEN}$1${NC}"
    logger -t "ssh-setup" "SUCCESS: $1"
}

print_info() { 
    echo -e "${BLUE}$1${NC}"
    logger -t "ssh-setup" "INFO: $1"
}

# ========== 系统检查函数 ==========
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 用户执行"
        exit 1
    fi
    
    # 动态获取实际操作的用户（修复v3.2硬编码问题）
    SSH_USER="${SUDO_USER:-root}"
    
    # 验证用户存在性
    if ! id "$SSH_USER" &>/dev/null; then
        print_warning "用户 $SSH_USER 不存在，回退为 root"
        SSH_USER="root"
    fi
    
    print_info "操作目标用户: $SSH_USER"
}

check_ssh_service() {
    print_info "[0/10] 检查 SSH 服务..."
    
    # 检测 SSH 服务名称（修复v3.2未声明全局变量问题）
    if systemctl list-unit-files 2>/dev/null | grep -q "^sshd.service"; then
        SSH_SERVICE="sshd"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^ssh.service"; then
        SSH_SERVICE="ssh"
    else
        # 默认使用 ssh（Debian系标准）
        SSH_SERVICE="ssh"
    fi
    
    print_info "检测到 SSH 服务: $SSH_SERVICE"
    
    # 检查并安装 OpenSSH
    if ! dpkg -l 2>/dev/null | grep -qE "^ii.*openssh-server"; then
        print_warning "未检测到 OpenSSH 服务，正在安装..."
        apt-get update -qq
        apt-get install -y openssh-server
        print_success "OpenSSH 服务安装完成"
    else
        print_success "OpenSSH 服务已安装"
    fi
    
    # 确保服务运行
    systemctl start "$SSH_SERVICE" 2>/dev/null || {
        print_warning "无法启动 $SSH_SERVICE，尝试 ssh..."
        SSH_SERVICE="ssh"
        systemctl start "$SSH_SERVICE" 2>/dev/null || {
            print_error "无法启动 SSH 服务"
            exit 1
        }
    }
    
    systemctl enable "$SSH_SERVICE" 2>/dev/null || true
    echo ""
}

check_network() {
    print_info "[1/10] 检查网络环境..."
    
    # 获取 IPv4 地址
    IPV4_ADDR=$(ip -4 addr show scope global 2>/dev/null | grep -w "inet" | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -1)
    
    # 获取 IPv6 地址（过滤链路本地和临时地址）
    IPV6_ADDR=$(ip -6 addr show scope global 2>/dev/null | grep -w "inet6" | grep -vE "(fe80|temporary|deprecated)" | awk '{print $2}' | cut -d/ -f1 | head -1)
    
    echo "  检测到 IPv4: ${IPV4_ADDR:-无}"
    echo "  检测到 IPv6: ${IPV6_ADDR:-无}"
    
    # 验证网络栈类型与IP可用性
    if [[ "$STACK_TYPE" == "ipv6" ]] && [[ -z "$IPV6_ADDR" ]]; then
        print_error "选择仅 IPv6 但未检测到公网 IPv6 地址"
        read -p "是否继续？(y/n): " CONTINUE
        [[ "$CONTINUE" != "y" ]] && exit 1
    elif [[ "$STACK_TYPE" == "ipv4" ]] && [[ -z "$IPV4_ADDR" ]]; then
        print_error "选择仅 IPv4 但未检测到公网 IPv4 地址"
        read -p "是否继续？(y/n): " CONTINUE
        [[ "$CONTINUE" != "y" ]] && exit 1
    fi
    
    print_success "网络环境检查完成"
    echo ""
}

# ========== 用户配置函数 ==========
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

# ========== UFW 安装与配置函数 ==========
install_ufw() {
    print_info "[2/10] 安装 UFW..."
    apt-get update -qq
    apt-get install -y ufw
    
    # 确保 UFW 默认配置文件存在
    mkdir -p "$(dirname "$UFW_DEFAULT")"
    
    # 强制启用 IPv6 支持
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
    
    # 如果配置文件不存在，尝试从备份恢复
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        print_warning "$SSHD_CONFIG 不存在，尝试恢复..."
        local created=false
        
        # 按优先级尝试多个来源
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
            print_error "无法恢复 SSH 配置文件，请手动安装 openssh-server"
            exit 1
        fi
    fi
    
    # 提取当前端口（匹配可能带空格的行）
    CURRENT_SSH_PORT=$(grep -E "^[[:space:]]*Port[[:space:]]" "$SSHD_CONFIG" | awk '{print $2}' | head -n1)
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
    
    # 使用更精确的正则匹配，包括注释和空格
    if grep -qE "^[[:space:]]*[#]*${key}[[:space:]]" "$config_file"; then
        sed -i "s|^[[:space:]]*[#]*${key}[[:space:]].*|${key} ${value}|g" "$config_file"
    else
        echo "${key} ${value}" >> "$config_file"
    fi
}

# ========== 核心改进：安全的防火墙配置顺序 ==========
configure_ufw_rules_safely() {
    print_info "[4/10] 安全配置 UFW 防火墙规则..."
    print_warning "正在配置防火墙规则，请勿中断..."
    
    # 步骤1: 重置并设置默认策略（此时UFW处于禁用状态）
    ufw --force disable > /dev/null 2>&1 || true
    echo "y" | ufw --force reset > /dev/null 2>&1 || true
    
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny routed
    ufw logging low
    
    # 步骤2: 【关键】在启用UFW前，先添加所有必要的放行规则
    # 这样可以确保启用UFW时不会阻断现有连接
    
    # 2.1 放行当前SSH端口（保持现有连接）
    if [[ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]]; then
        ufw allow "$CURRENT_SSH_PORT/tcp" comment "Current SSH port (temporary)"
        print_info "已添加当前端口 $CURRENT_SSH_PORT 的临时放行规则"
    fi
    
    # 2.2 添加新SSH端口的限速规则
    # IPv4规则
    if [[ "$STACK_TYPE" == "dual" ]] || [[ "$STACK_TYPE" == "ipv4" ]]; then
        ufw limit proto tcp from 0.0.0.0/0 to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv4"
        print_info "已添加新端口 $NEW_SSH_PORT 的IPv4限速规则"
    fi
    
    # IPv6规则（仅当系统支持IPv6时添加，修复v3.2的bug）
    if [[ "$STACK_TYPE" == "dual" ]] || [[ "$STACK_TYPE" == "ipv6" ]]; then
        if [[ -n "$IPV6_ADDR" ]]; then
            ufw limit proto tcp from ::/0 to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv6"
            print_info "已添加新端口 $NEW_SSH_PORT 的IPv6限速规则"
        else
            print_warning "系统无IPv6地址，跳过IPv6规则添加"
        fi
    fi
    
    # 步骤3: 安全启用UFW（此时规则已就绪）
    ufw --force enable > /dev/null 2>&1 || {
        print_error "UFW 启用失败"
        exit 1
    }
    
    CONNECTION_SAFE=true
    print_success "防火墙规则已安全配置并启用"
    echo ""
}

# ========== SSH 端口修改函数 ==========
modify_ssh_port() {
    print_info "[5/10] 修改 SSH 端口配置..."
    
    # 创建备份
    BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP_FILE"
    print_info "配置文件已备份至: $BACKUP_FILE"
    
    # 清理所有旧的Port行，避免重复和冲突
    # 同时注释掉 Include 目录中可能的端口设置（通过主配置文件覆盖）
    sed -i '/^[[:space:]]*Port[[:space:]]/d' "$SSHD_CONFIG"
    
    # 添加新旧端口（确保都能访问）
    echo "Port $CURRENT_SSH_PORT" >> "$SSHD_CONFIG"
    echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
    
    # 验证配置语法
    if ! sshd -t; then
        print_error "SSH 配置语法错误，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        exit 1
    fi
    
    # 重启SSH服务（此时防火墙规则已就绪，不会断连）
    if systemctl restart "$SSH_SERVICE"; then
        sleep 2
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            print_success "SSH 端口已配置: $CURRENT_SSH_PORT (旧) + $NEW_SSH_PORT (新)"
        else
            print_error "SSH 服务启动异常，恢复备份"
            cp "$BACKUP_FILE" "$SSHD_CONFIG"
            systemctl restart "$SSH_SERVICE"
            exit 1
        fi
    else
        print_error "SSH 服务重启失败，恢复备份"
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        systemctl restart "$SSH_SERVICE"
        exit 1
    fi
    echo ""
}

# ========== SSH 密钥配置函数 ==========
configure_ssh_key() {
    print_info "[6/10] 配置 SSH 公钥..."
    echo ""
    print_info "目标用户: $SSH_USER"
    print_info "请粘贴公钥（以 ssh-rsa/ssh-ed25519 等开头）："
    
    local public_key=""
    read -r public_key
    
    # 清理输入
    public_key=$(echo "$public_key" | tr -d '\r\n' | xargs)
    
    # 验证公钥格式
    if [[ -z "$public_key" ]]; then
        print_error "未检测到公钥输入"
        exit 1
    fi
    
    if ! echo "$public_key" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)"; then
        print_error "公钥格式不正确"
        echo -e "${YELLOW}您输入的内容：${NC}"
        echo "$public_key"
        exit 1
    fi
    
    # 确定 .ssh 目录路径
    local ssh_dir=""
    if [[ "$SSH_USER" == "root" ]]; then
        ssh_dir="/root/.ssh"
    else
        ssh_dir="/home/${SSH_USER}/.ssh"
    fi
    
    # 创建 .ssh 目录
    mkdir -p "$ssh_dir"
    
    # 备份旧密钥
    AUTH_KEYS_FILE="${ssh_dir}/authorized_keys"
    if [[ -f "$AUTH_KEYS_FILE" ]]; then
        cp "$AUTH_KEYS_FILE" "${AUTH_KEYS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        print_info "已备份旧密钥文件"
    fi
    
    # 写入新公钥
    echo "$public_key" > "$AUTH_KEYS_FILE"
    
    # 设置权限
    chmod 700 "$ssh_dir"
    chmod 600 "$AUTH_KEYS_FILE"
    
    # 设置所有者（修复v3.2可能的所有者问题）
    if [[ "$SSH_USER" != "root" ]]; then
        chown -R "${SSH_USER}:${SSH_USER}" "$ssh_dir" 2>/dev/null || {
            print_warning "无法设置 $ssh_dir 的所有者为 $SSH_USER"
        }
    fi
    
    print_success "公钥写入完成"
}

verify_ssh_key() {
    print_info "[7/10] 验证公钥..."
    
    if ssh-keygen -l -f "$AUTH_KEYS_FILE" >/dev/null 2>&1; then
        print_success "密钥验证通过："
        ssh-keygen -l -f "$AUTH_KEYS_FILE"
    else
        print_error "密钥有效性检查失败"
        echo "密钥文件内容："
        cat "$AUTH_KEYS_FILE"
        exit 1
    fi
    echo ""
}

# ========== SSH 安全优化函数 ==========
optimize_ssh_security() {
    print_info "[8/10] 优化 SSH 安全配置..."
    
    # 设置安全选项
    set_ssh_option "PubkeyAuthentication" "yes"
    set_ssh_option "PasswordAuthentication" "yes"  # 暂时保留密码登录
    set_ssh_option "PermitRootLogin" "prohibit-password"
    set_ssh_option "MaxAuthTries" "5"
    set_ssh_option "X11Forwarding" "no"
    set_ssh_option "PermitEmptyPasswords" "no"
    set_ssh_option "ChallengeResponseAuthentication" "no"
    
    # 验证并应用配置
    if sshd -t; then
        if systemctl restart "$SSH_SERVICE"; then
            sleep 2
            if systemctl is-active --quiet "$SSH_SERVICE"; then
                print_success "SSH 安全策略应用成功"
            else
                print_error "SSH 服务异常，恢复备份"
                cp "$BACKUP_FILE" "$SSHD_CONFIG"
                systemctl restart "$SSH_SERVICE"
                exit 1
            fi
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
    echo ""
}

# ========== 输出汇总函数 ==========
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
    ufw status numbered
    echo ""
}

print_test_instructions() {
    print_info "[9/10] 下一步：测试密钥登录"
    echo ""
    
    echo -e "${RED}⚠  重要提示：请保持当前终端窗口不要关闭！${NC}"
    echo -e "${GREEN}请在新的终端窗口中测试以下命令：${NC}"
    echo ""
    
    # IPv4连接命令
    if [[ -n "$IPV4_ADDR" ]] && [[ "$STACK_TYPE" != "ipv6" ]]; then
        echo -e "  ${BLUE}[IPv4]${NC} ssh -p $NEW_SSH_PORT $SSH_USER@$IPV4_ADDR"
        echo "         或使用密钥: ssh -i ~/.ssh/id_rsa -p $NEW_SSH_PORT $SSH_USER@$IPV4_ADDR"
    fi
    
    # IPv6连接命令
    if [[ -n "$IPV6_ADDR" ]] && [[ "$STACK_TYPE" != "ipv4" ]]; then
        echo -e "  ${BLUE}[IPv6]${NC} ssh -p $NEW_SSH_PORT $SSH_USER@[$IPV6_ADDR]"
        echo "         或使用密钥: ssh -i ~/.ssh/id_rsa -p $NEW_SSH_PORT $SSH_USER@[$IPV6_ADDR]"
    fi
    
    echo ""
    echo -e "${YELLOW}后续优化建议：${NC}"
    echo ""
    echo -e "${YELLOW}1. 确认密钥登录成功后，关闭密码登录：${NC}"
    echo "   sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG"
    echo "   sudo systemctl restart $SSH_SERVICE"
    echo ""
    
    echo -e "${YELLOW}2. 确认新端口正常后，移除旧端口：${NC}"
    echo "   sudo sed -i '/^Port $CURRENT_SSH_PORT/d' $SSHD_CONFIG"
    echo "   sudo ufw delete allow $CURRENT_SSH_PORT/tcp"
    echo "   sudo systemctl restart $SSH_SERVICE"
    echo ""
    
    echo -e "${YELLOW}3. 云服务器用户注意：${NC}"
    echo "   请在云平台安全组中放行新端口: ${RED}$NEW_SSH_PORT${NC}"
    echo ""
    
    echo -e "${RED}⚠  确认新连接可用前，请勿关闭当前终端！${NC}"
    echo ""
    
    echo -e "${GREEN}UFW 常用管理命令：${NC}"
    echo "  ufw status numbered              # 查看规则编号"
    echo "  ufw delete <编号>                # 删除指定规则"
    echo "  ufw disable                      # 临时禁用防火墙"
    echo "  ufw enable                       # 启用防火墙"
    echo "  tail -f /var/log/ufw.log         # 查看防火墙日志"
    echo "  journalctl -u $SSH_SERVICE -f    # 查看SSH服务日志"
}

# ========== 错误恢复函数 ==========
cleanup_on_error() {
    local exit_code=$?
    
    echo ""
    print_error "脚本执行出错 (退出码: $exit_code)"
    print_warning "正在尝试安全恢复..."
    
    # 恢复 SSH 配置
    if [[ -f "$BACKUP_FILE" ]] && [[ -f "$SSHD_CONFIG" ]]; then
        print_info "恢复 SSH 配置文件备份..."
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        
        if systemctl restart "$SSH_SERVICE" 2>/dev/null; then
            print_success "SSH 配置已恢复"
        else
            print_error "SSH 服务恢复失败，请手动检查"
            print_info "尝试启动 SSH 服务..."
            systemctl start "$SSH_SERVICE" 2>/dev/null || true
        fi
    fi
    
    # 确保 SSH 服务运行
    if ! systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null; then
        print_warning "SSH 服务未运行，尝试启动..."
        systemctl start "$SSH_SERVICE" 2>/dev/null || true
    fi
    
    print_warning "请手动检查系统状态，必要时恢复备份文件"
    print_info "备份文件位置: ${BACKUP_FILE:-未创建}"
    
    exit $exit_code
}

# ========== 主函数 ==========
main() {
    # 设置错误陷阱
    trap cleanup_on_error ERR
    
    # 开始日志记录
    logger -t "ssh-setup" "开始执行 SSH 安全配置脚本 ${SCRIPT_VERSION}"
    
    print_banner
    
    # 系统检查
    check_root
    check_ssh_service
    
    # 用户配置
    configure_port
    configure_stack
    
    # 环境检查
    check_network
    
    # 安装组件
    install_ufw
    check_sshd_config
    
    # 核心配置（顺序很重要！）
    configure_ufw_rules_safely  # 先配置防火墙规则
    modify_ssh_port             # 再修改SSH端口
    
    # 安全配置
    configure_ssh_key
    verify_ssh_key
    optimize_ssh_security
    
    # 输出信息
    print_summary
    print_test_instructions
    
    logger -t "ssh-setup" "SSH 安全配置脚本执行完成"
    print_success "所有配置已完成！请按照上述指引测试新连接。"
}

# ========== 脚本入口 ==========
main "$@"
