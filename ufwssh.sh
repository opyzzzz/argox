#!/bin/bash
#
# Debian UFW 防火墙 + SSH 密钥登录一键配置脚本 (修正版 v3.0)
# 修正：
#   1. 移除 allow 规则，直接使用 limit（避免顺序问题）
#   2. 强制启用 IPv6 支持
#   3. 修复多行 Port 提取问题
#   4. SSH 配置统一处理避免重复追加
#   5. 添加云平台安全组提醒
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置变量
SSH_USER="root"
SSHD_CONFIG="/etc/ssh/sshd_config"
UFW_DEFAULT="/etc/default/ufw"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Debian UFW + SSH 安全配置脚本 v3.0${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ========== 检查是否为 root ==========
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：此脚本必须以 root 用户执行${NC}"
    exit 1
fi

# ========== 安装必备依赖 ==========
echo -e "${YELLOW}[0/10] 安装必备依赖...${NC}"

# 更新软件包列表
apt update

# 安装必备工具
apt install -y ufw wget curl

# 如果 ufw 未安装则单独安装（兼容性保障）
if ! command -v ufw &> /dev/null; then
    apt install -y ufw
fi

echo -e "${GREEN}依赖安装完成 (ufw, wget, curl)${NC}"

# ========== 交互式配置端口 ==========
echo -e "${YELLOW}[配置] SSH 端口设置${NC}"
read -p "请输入新的 SSH 端口号 (1024-65535，默认 2222): " NEW_SSH_PORT
NEW_SSH_PORT=${NEW_SSH_PORT:-2222}

if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 1024 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
    echo -e "${RED}错误：端口号必须在 1024-65535 之间${NC}"
    exit 1
fi
echo -e "${GREEN}新 SSH 端口: $NEW_SSH_PORT${NC}"
echo ""

# ========== 选择网络栈类型 ==========
echo -e "${YELLOW}[配置] SSH 端口网络栈类型${NC}"
echo "1) 双栈 (IPv4 + IPv6) - 推荐"
echo "2) 仅 IPv4"
echo "3) 仅 IPv6"
read -p "请选择 (1/2/3，默认 1): " STACK_CHOICE
STACK_CHOICE=${STACK_CHOICE:-1}

case $STACK_CHOICE in
    1) STACK_TYPE="dual";  STACK_DESC="双栈 (IPv4 + IPv6)" ;;
    2) STACK_TYPE="ipv4";  STACK_DESC="仅 IPv4" ;;
    3) STACK_TYPE="ipv6";  STACK_DESC="仅 IPv6" ;;
    *) echo -e "${RED}错误：无效选择${NC}"; exit 1 ;;
esac
echo -e "${GREEN}网络栈类型: $STACK_DESC${NC}"
echo ""

# ========== 检查网络环境 ==========
echo -e "${YELLOW}[1/10] 检查网络环境...${NC}"

IPV4_ADDR=$(ip -4 addr show scope global | grep -w "inet" | awk '{print $2}' | cut -d/ -f1 | head -1)
IPV6_ADDR=$(ip -6 addr show scope global | grep -v "fe80" | grep -v temporary | grep -w "inet6" | awk '{print $2}' | cut -d/ -f1 | head -1)

echo "  检测到 IPv4: ${IPV4_ADDR:-无}"
echo "  检测到 IPv6: ${IPV6_ADDR:-无}"

# 栈类型与IP可用性检查
if [[ "$STACK_TYPE" == "ipv6" ]] && [[ -z "$IPV6_ADDR" ]]; then
    echo -e "${RED}错误：选择仅IPv6但未检测到公网IPv6地址${NC}"
    read -p "是否继续？(y/n): " CONTINUE
    [[ "$CONTINUE" != "y" ]] && exit 1
fi
echo -e "${GREEN}网络环境检查完成${NC}"

# ========== 安装 UFW ==========
echo -e "${YELLOW}[2/10] 安装 UFW...${NC}"
apt update
apt install ufw -y

# 强制开启 IPv6 支持
sed -i 's/IPV6=no/IPV6=yes/' "$UFW_DEFAULT"
echo -e "${GREEN}UFW 安装完成，IPv6 已启用${NC}"

# ========== 获取当前 SSH 端口 ==========
CURRENT_SSH_PORT=$(grep -E "^Port" "$SSHD_CONFIG" | awk '{print $2}' | head -n1)
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
echo -e "${YELLOW}[3/10] 当前 SSH 端口: $CURRENT_SSH_PORT${NC}"

# ========== 重置 UFW 并设置基础规则 ==========
echo -e "${YELLOW}[4/10] 初始化 UFW 规则...${NC}"

# 清空所有旧规则
echo "y" | ufw --force reset > /dev/null 2>&1 || true

# 设置默认策略
ufw default deny incoming
ufw default allow outgoing

# 放行当前端口（双栈，临时保护）
ufw allow "$CURRENT_SSH_PORT/tcp" comment "Current SSH port (temporary)"

# 启用 UFW
echo "y" | ufw enable
echo -e "${GREEN}UFW 基础规则已设置${NC}"

# ========== 修改 SSH 端口 ==========
echo -e "${YELLOW}[5/10] 修改 SSH 配置文件...${NC}"

# 备份原配置
BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SSHD_CONFIG" "$BACKUP_FILE"
echo "  配置文件已备份至: $BACKUP_FILE"

# 使用函数统一设置 SSH 配置项（避免重复追加）
set_ssh_option() {
    local key=$1
    local value=$2
    if grep -qE "^[#]*${key}[[:space:]]" "$SSHD_CONFIG"; then
        sed -i "s/^[#]*${key}[[:space:]].*/${key} ${value}/" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

# 确保旧端口存在
if ! grep -qE "^Port $CURRENT_SSH_PORT" "$SSHD_CONFIG"; then
    echo "Port $CURRENT_SSH_PORT" >> "$SSHD_CONFIG"
fi

# 确保新端口存在
if ! grep -qE "^Port $NEW_SSH_PORT" "$SSHD_CONFIG"; then
    echo "Port $NEW_SSH_PORT" >> "$SSHD_CONFIG"
fi

# 验证配置语法
if ! sshd -t; then
    echo -e "${RED}错误：SSH 配置语法错误，恢复备份${NC}"
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    systemctl restart ssh
    exit 1
fi

systemctl restart ssh
echo -e "${GREEN}SSH 端口已配置: $CURRENT_SSH_PORT (旧) + $NEW_SSH_PORT (新)${NC}"

# ========== 配置新端口防火墙规则（仅用 limit） ==========
echo -e "${YELLOW}[6/10] 配置新 SSH 端口防火墙规则 ($STACK_DESC)...${NC}"

case $STACK_TYPE in
    dual)
        # 双栈：两条 limit 规则
        ufw limit proto tcp from 0.0.0.0/0 to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv4"
        ufw limit proto tcp from ::/0     to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv6"
        ;;
    ipv4)
        ufw limit proto tcp from 0.0.0.0/0 to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv4"
        ;;
    ipv6)
        ufw limit proto tcp from ::/0     to any port "$NEW_SSH_PORT" comment "SSH rate limit IPv6"
        ;;
esac

echo -e "${GREEN}防火墙规则已应用（直接使用 limit，无需 allow）${NC}"

# ========== 配置公钥 ==========
echo -e "${YELLOW}[7/10] 配置 SSH 公钥${NC}"
echo ""
echo -e "${BLUE}请粘贴公钥（单行，以 ssh-rsa/ssh-ed25519 开头）：${NC}"

read -r PUBLIC_KEY
PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '\r' | xargs)

# 验证公钥
if [[ -z "$PUBLIC_KEY" ]]; then
    echo -e "${RED}错误：未检测到公钥输入${NC}"
    exit 1
fi

if ! echo "$PUBLIC_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)"; then
    echo -e "${RED}错误：公钥格式无效${NC}"
    echo -e "${YELLOW}您输入的内容：${NC}"
    echo "$PUBLIC_KEY"
    exit 1
fi

# 检查长度
KEY_LENGTH=$(echo "$PUBLIC_KEY" | wc -c)
if [[ $KEY_LENGTH -lt 200 ]]; then
    echo -e "${RED}错误：公钥长度不足 (${KEY_LENGTH}字符)，可能不完整${NC}"
    exit 1
fi

# 写入公钥
SSH_DIR="/root/.ssh"
if [[ "$SSH_USER" != "root" ]]; then
    SSH_DIR="/home/$SSH_USER/.ssh"
fi
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# 备份旧密钥（若存在）
[[ -f "$AUTH_KEYS" ]] && cp "$AUTH_KEYS" "${AUTH_KEYS}.bak.$(date +%Y%m%d%H%M%S)"

echo "$PUBLIC_KEY" > "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# 验证密钥文件
echo -e "${YELLOW}[8/10] 验证公钥...${NC}"
if ssh-keygen -l -f "$AUTH_KEYS" >/dev/null 2>&1; then
    echo -e "${GREEN}密钥验证通过：${NC}"
    ssh-keygen -l -f "$AUTH_KEYS"
else
    echo -e "${RED}错误：密钥验证失败${NC}"
    cat "$AUTH_KEYS"
    exit 1
fi

# ========== 优化 SSH 安全配置 ==========
echo -e "${YELLOW}[9/10] 优化 SSH 安全配置...${NC}"

set_ssh_option "PubkeyAuthentication" "yes"
set_ssh_option "PasswordAuthentication" "yes"      # 保留密码，稍后手动关闭
set_ssh_option "PermitRootLogin" "prohibit-password"
set_ssh_option "PermitEmptyPasswords" "no"
set_ssh_option "MaxAuthTries" "5"
set_ssh_option "AuthorizedKeysFile" ".ssh/authorized_keys"

# 验证并重启
if sshd -t; then
    systemctl restart ssh
else
    echo -e "${RED}SSH 配置语法错误，恢复备份${NC}"
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    systemctl restart ssh
    exit 1
fi

# 验证 SSH 服务运行状态
if ! systemctl is-active --quiet ssh; then
    echo -e "${RED}错误：SSH 服务未运行${NC}"
    systemctl status ssh --no-pager
    exit 1
fi
echo -e "${GREEN}SSH 安全配置完成，服务运行正常${NC}"

# ========== 最终输出 ==========
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  配置完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}配置摘要：${NC}"
echo -e "  旧 SSH 端口:    $CURRENT_SSH_PORT"
echo -e "  新 SSH 端口:    ${GREEN}$NEW_SSH_PORT${NC}"
echo -e "  网络栈类型:     $STACK_DESC"
echo -e "  SSH 用户:       $SSH_USER"
echo -e "  公钥文件:       $AUTH_KEYS"
echo -e "  配置备份:       $BACKUP_FILE"
echo ""
echo -e "${YELLOW}当前防火墙规则：${NC}"
ufw status numbered
echo ""

# ========== 连接测试指引 ==========
echo -e "${YELLOW}[10/10] 下一步：测试密钥登录${NC}"
echo ""
echo -e "${GREEN}请在新的终端窗口测试：${NC}"

[[ -n "$IPV4_ADDR" && "$STACK_TYPE" != "ipv6" ]] && \
    echo -e "  ${BLUE}[IPv4]${NC} ssh -i ~/.ssh/id_rsa -p $NEW_SSH_PORT $SSH_USER@$IPV4_ADDR"

[[ -n "$IPV6_ADDR" && "$STACK_TYPE" != "ipv4" ]] && \
    echo -e "  ${BLUE}[IPv6]${NC} ssh -i ~/.ssh/id_rsa -p $NEW_SSH_PORT $SSH_USER@$IPV6_ADDR"

echo ""
echo -e "${YELLOW}确认密钥登录成功后，禁用密码登录：${NC}"
echo "  sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' $SSHD_CONFIG"
echo "  sudo systemctl restart ssh"
echo ""
echo -e "${YELLOW}可选：移除旧端口（确认新端口正常后）：${NC}"
echo "  sudo sed -i '/^Port $CURRENT_SSH_PORT/d' $SSHD_CONFIG"
echo "  sudo ufw delete allow $CURRENT_SSH_PORT/tcp"
echo "  sudo systemctl restart ssh"
echo ""

# ========== 云平台安全组提醒 ==========
echo -e "${RED}⚠  云服务器用户重要提醒：${NC}"
echo -e "  如果使用 AWS / 阿里云 / 腾讯云 / 谷歌云 / Vultr 等平台"
echo -e "  请在控制台「安全组/防火墙」中放行端口：${YELLOW}$NEW_SSH_PORT${NC}"
echo -e "  否则即使 UFW 配置正确，外部连接仍会被云防火墙阻挡"
echo ""

echo -e "${RED}⚠  务必保留当前终端，直到确认新终端可正常登录！${NC}"
echo ""
echo -e "${GREEN}UFW 常用命令：${NC}"
echo "  ufw status numbered    # 查看规则"
echo "  ufw delete <编号>      # 删除规则"
echo "  ufw disable            # 临时禁用防火墙"
echo "  tail -f /var/log/syslog | grep UFW    # 查看防火墙日志"
