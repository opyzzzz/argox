#!/bin/sh
#==================================================
# SmartDNS 环境检测脚本 v1.0
# 功能: 全面检测系统环境是否支持 SmartDNS 部署
# 使用: chmod +x smartdns-check.sh && ./smartdns-check.sh
# 更新: 2026-05-11
#==================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"
INFO="${CYAN}ℹ${NC}"

# 评分系统
TOTAL_CHECKS=0
PASSED_CHECKS=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
    echo -e "  ${PASS} $1"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
}

fail() {
    echo -e "  ${FAIL} $1"
    echo -e "      解决方案: $2"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "  ${WARN} $1"
    echo -e "      建议: $2"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
    echo -e "  ${INFO} $1: ${CYAN}$2${NC}"
}

section() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━ $1 ━━━${NC}"
}

# --- 权限检查 ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${FAIL} 请使用 root 权限运行: sudo $0"
    exit 1
fi

clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     SmartDNS 环境兼容性检测工具         ║${NC}"
echo -e "${BOLD}${CYAN}║     v1.0 - $(date '+%Y-%m-%d %H:%M:%S')       ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"

#==================================================
# 1. 系统基本信息
#==================================================
section "系统基本信息"

# 发行版检测
if [ -f /etc/alpine-release ]; then
    OS="Alpine Linux"
    VER=$(cat /etc/alpine-release)
    PKG_MGR="apk"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$PRETTY_NAME"
    VER="$VERSION_ID"
    case "$ID" in
        debian|ubuntu) PKG_MGR="apt" ;;
        *) PKG_MGR="unknown" ;;
    esac
else
    OS="Unknown"
    VER="Unknown"
    PKG_MGR="unknown"
fi

info "操作系统" "$OS"
info "版本" "$VER"
info "包管理器" "$PKG_MGR"

# 内核信息
KERNEL=$(uname -r)
info "内核版本" "$KERNEL"

# 架构
ARCH=$(uname -m)
info "CPU架构" "$ARCH"

# 运行时间
UPTIME=$(uptime | sed 's/.*up //' | sed 's/,.*//')
info "运行时间" "$UPTIME"

#==================================================
# 2. 系统兼容性检查
#==================================================
section "系统兼容性检查"

# 发行版兼容性
case "$OS" in
    *Alpine*|*Debian*|*Ubuntu*)
        pass "发行版兼容: $OS"
        ;;
    *)
        fail "不支持的发行版: $OS" \
             "仅支持 Alpine Linux、Debian、Ubuntu"
        ;;
esac

# 架构兼容性
case "$ARCH" in
    x86_64|amd64|aarch64|arm64|armv7l|armv7|i386|i686)
        pass "CPU架构兼容: $ARCH"
        ;;
    *)
        fail "CPU架构可能不兼容: $ARCH" \
             "SmartDNS 需要 x86_64/arm64/arm/i386 架构"
        ;;
esac

# Init 系统检测
if [ -f /run/systemd/system ] || [ -d /run/systemd/system ]; then
    INIT="systemd"
    pass "Init 系统: systemd"
elif [ -f /sbin/openrc ] || [ -f /usr/sbin/openrc ]; then
    INIT="openrc"
    pass "Init 系统: OpenRC"
else
    INIT="unknown"
    warn "未检测到 systemd/OpenRC" \
         "SmartDNS 可以手动启动，但不会自动开机运行"
fi

# 虚拟化环境
if grep -q "container=lxc" /proc/1/environ 2>/dev/null || grep -q "lxchost" /proc/1/cgroup 2>/dev/null; then
    VIRT="LXC"
    info "虚拟化" "LXC 容器"
elif grep -q "docker" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
    VIRT="Docker"
    info "虚拟化" "Docker 容器"
elif [ -d /proc/vz ]; then
    VIRT="OpenVZ"
    info "虚拟化" "OpenVZ 容器"
elif [ -f /sys/class/dmi/id/product_name ]; then
    VIRT=$(cat /sys/class/dmi/id/product_name)
    info "虚拟化" "KVM/物理机: $VIRT"
else
    VIRT="Unknown"
    info "虚拟化" "未知"
fi

if echo "$VIRT" | grep -qiE "lxc|docker|openvz"; then
    warn "容器环境检测到" \
         "可能需要额外配置特权端口或使用高端口"
fi

#==================================================
# 3. 基础依赖检查
#==================================================
section "基础依赖检查"

# 必需工具
REQUIRED_TOOLS="wget grep sed awk"
OPTIONAL_TOOLS="curl netstat ss nslookup drill tar"

for tool in $REQUIRED_TOOLS; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "必需工具 $tool 已安装"
    else
        fail "必需工具 $tool 未安装" \
             "安装: $PKG_MGR add $tool 或 $PKG_MGR install $tool"
    fi
done

for tool in $OPTIONAL_TOOLS; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "可选工具 $tool 已安装"
    else
        warn "可选工具 $tool 未安装" \
             "建议安装以获得更好的诊断能力"
    fi
done

#==================================================
# 4. 网络环境检查
#==================================================
section "网络环境检查"

# 网络接口
INTERFACES=$(ip link show 2>/dev/null | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v "lo")
if [ -n "$INTERFACES" ]; then
    pass "检测到网络接口"
    for iface in $INTERFACES; do
        STATE=$(ip link show "$iface" 2>/dev/null | grep -oP 'state \K\w+')
        IP=$(ip addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+')
        info "  接口 $iface" "状态: $STATE, IP: ${IP:-无}"
    done
else
    fail "未检测到网络接口" \
         "请检查网络配置"
fi

# IPv4 连通性
if ip route get 1.1.1.1 >/dev/null 2>&1; then
    DEFAULT_IPV4=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
    pass "IPv4 路由正常: $DEFAULT_IPV4"
    
    # 测试公网连通性
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        pass "IPv4 公网可达 (1.1.1.1)"
    else
        warn "IPv4 公网可能不通 (ICMP被禁或网络受限)" \
             "如果使用 NAT/防火墙，属正常现象"
    fi
else
    fail "IPv4 路由异常" \
         "请检查网络配置: ip route"
fi

# IPv6 连通性
if ip route get 2606:4700:4700::1111 >/dev/null 2>&1; then
    DEFAULT_IPV6=$(ip route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+')
    pass "IPv6 路由正常: $DEFAULT_IPV6"
else
    warn "未检测到 IPv6 (纯 IPv4 环境)" \
         "SmartDNS 仍可正常工作"
fi

# DNS 解析测试
echo ""
info "DNS 解析测试" ""
for dns in "google.com" "github.com" "cloudflare.com"; do
    if nslookup "$dns" 2>/dev/null | grep -q "Address"; then
        pass "DNS 解析正常: $dns"
    else
        fail "DNS 解析失败: $dns" \
             "检查 /etc/resolv.conf 和上游 DNS 配置"
    fi
done

#==================================================
# 5. 端口可用性检查
#==================================================
section "端口可用性检查"

# 检测端口是否被占用
check_port() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":${port} "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -q ":${port} "
    else
        return 1
    fi
}

# 显示端口占用详情
show_port_detail() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        echo -e "      $(ss -tulnp 2>/dev/null | grep ":${port} ")"
    elif command -v netstat >/dev/null 2>&1; then
        echo -e "      $(netstat -tulnp 2>/dev/null | grep ":${port} ")"
    fi
}

PORTS="53 5353 5354 8053 9053"
PORT_53_AVAILABLE=true

for port in $PORTS; do
    if check_port "$port"; then
        if [ "$port" = "53" ]; then
            PORT_53_AVAILABLE=false
            warn "端口 $port 已被占用" \
                 "将使用备用端口"
            show_port_detail "$port"
        else
            warn "端口 $port 已被占用" \
                 "如需使用此端口，请先释放"
            show_port_detail "$port"
        fi
    else
        pass "端口 $port 可用"
    fi
done

# 检查 dhcpcd 是否占用 53
if pgrep dhcpcd >/dev/null 2>&1; then
    warn "dhcpcd 服务正在运行" \
         "可能占用 DNS 端口，安装脚本会自动配置"
fi

#==================================================
# 6. resolv.conf 状态
#==================================================
section "resolv.conf 状态"

if [ -f /etc/resolv.conf ]; then
    if [ -L /etc/resolv.conf ]; then
        LINK_TARGET=$(readlink -f /etc/resolv.conf 2>/dev/null)
        warn "/etc/resolv.conf 是符号链接" \
             "指向: $LINK_TARGET"
    else
        pass "/etc/resolv.conf 是常规文件"
    fi
    
    # 显示当前 DNS 配置
    info "当前 DNS 配置" ""
    if grep "^nameserver" /etc/resolv.conf 2>/dev/null; then
        :
    else
        warn "未配置 nameserver" \
             "需要配置上游 DNS"
    fi
    
    # 检查是否可写
    if [ -w /etc/resolv.conf ]; then
        pass "/etc/resolv.conf 可写"
    else
        warn "/etc/resolv.conf 不可写" \
             "可能需要 chattr -i 解锁"
    fi
else
    fail "/etc/resolv.conf 不存在" \
         "创建: echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
fi

#==================================================
# 7. 服务状态检查
#==================================================
section "服务状态检查"

# systemd-resolved
if [ "$INIT" = "systemd" ]; then
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        warn "systemd-resolved 正在运行" \
             "SmartDNS 安装时会自动停用"
    else
        pass "systemd-resolved 未运行"
    fi
fi

# 其他 DNS 服务
OTHER_DNS=$(pgrep -x "named|dnsmasq|unbound|pdnsd" 2>/dev/null)
if [ -n "$OTHER_DNS" ]; then
    warn "检测到其他 DNS 服务: $OTHER_DNS" \
         "可能冲突，建议停用后再安装 SmartDNS"
else
    pass "未检测到其他 DNS 服务"
fi

#==================================================
# 8. 网络连通性测试
#==================================================
section "网络连通性测试"

# GitHub 可达性
GITHUB_ACCESSIBLE=false
for url in "https://github.com" "https://api.github.com"; do
    if curl -sL --max-time 5 "$url" >/dev/null 2>&1; then
        pass "GitHub 可达: $url"
        GITHUB_ACCESSIBLE=true
    else
        warn "GitHub 可能不可达: $url" \
             "可能需要代理或手动下载"
    fi
done

# Cloudflare DoH 可达性
if curl -s --max-time 5 "https://cloudflare-dns.com/dns-query?name=google.com" >/dev/null 2>&1; then
    pass "Cloudflare DoH 可达"
else
    warn "Cloudflare DoH 不可达" \
         "传统 DNS (UDP 53) 仍可正常使用"
fi

# Google DoH 可达性
if curl -s --max-time 5 "https://dns.google/dns-query?name=google.com" >/dev/null 2>&1; then
    pass "Google DoH 可达"
else
    warn "Google DoH 不可达" \
         "传统 DNS (UDP 53) 仍可正常使用"
fi

#==================================================
# 9. 存储空间检查
#==================================================
section "存储空间检查"

# 磁盘空间
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
info "根分区使用率" "${DISK_USAGE}%"
info "可用空间" "$DISK_AVAIL"

if [ "$DISK_USAGE" -gt 90 ]; then
    fail "磁盘空间不足 (${DISK_USAGE}%)" \
         "建议清理或扩容，至少保留 50MB"
elif [ "$DISK_USAGE" -gt 70 ]; then
    warn "磁盘空间偏低 (${DISK_USAGE}%)" \
         "建议关注空间使用"
else
    pass "磁盘空间充足"
fi

# 内存
MEM_TOTAL=$(free -m | awk 'NR==2 {print $2}')
MEM_AVAIL=$(free -m | awk 'NR==2 {print $7}')
info "总内存" "${MEM_TOTAL}MB"
info "可用内存" "${MEM_AVAIL}MB"

if [ "$MEM_AVAIL" -lt 50 ]; then
    fail "内存不足 (可用: ${MEM_AVAIL}MB)" \
         "SmartDNS 至少需要 20MB，建议增加内存"
elif [ "$MEM_AVAIL" -lt 100 ]; then
    warn "内存偏低 (可用: ${MEM_AVAIL}MB)" \
         "SmartDNS 最小运行内存约 20MB"
else
    pass "内存充足"
fi

#==================================================
# 10. 权限检查
#==================================================
section "权限检查"

# 文件写入权限
for dir in /usr/bin /usr/sbin /etc /var/log; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then
        pass "目录可写: $dir"
    else
        fail "目录不可写: $dir" \
             "SmartDNS 安装需要写入此目录"
    fi
done

# 服务管理权限
if [ "$INIT" = "systemd" ]; then
    if systemctl >/dev/null 2>&1; then
        pass "systemctl 可用"
    else
        fail "systemctl 不可用" \
             "可能无法自动启动服务"
    fi
elif [ "$INIT" = "openrc" ]; then
    if rc-service >/dev/null 2>&1; then
        pass "rc-service 可用"
    else
        fail "rc-service 不可用" \
             "可能无法自动启动服务"
    fi
fi

#==================================================
# 检测结果汇总
#==================================================
echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  检测结果汇总${NC}"
echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
echo ""
echo -e "  总检测项: ${BOLD}${TOTAL_CHECKS}${NC}"
echo -e "  通过: ${GREEN}${PASSED_CHECKS}${NC}"
echo -e "  警告: ${YELLOW}${WARN_COUNT}${NC}"
echo -e "  失败: ${RED}${FAIL_COUNT}${NC}"
echo ""

# 综合评分
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ 完美！系统完全兼容 SmartDNS 部署${NC}"
    COMPATIBILITY="完美"
elif [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✓ 系统兼容，但存在 ${WARN_COUNT} 个警告${NC}"
    echo -e "  ${GREEN}建议查看上方警告项，但可继续安装${NC}"
    COMPATIBILITY="良好"
elif [ "$FAIL_COUNT" -le 2 ]; then
    echo -e "  ${YELLOW}${BOLD}⚠ 存在 ${FAIL_COUNT} 个严重问题，需解决后再安装${NC}"
    COMPATIBILITY="需要注意"
else
    echo -e "  ${RED}${BOLD}✗ 存在多个严重问题，不建议直接安装${NC}"
    COMPATIBILITY="不兼容"
fi

echo ""
echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  安装建议${NC}"
echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
echo ""

if [ "$GITHUB_ACCESSIBLE" = false ]; then
    echo -e "  ${WARN} GitHub 不可达，建议提前下载:"
    echo -e "      wget https://github.com/pymumu/smartdns/releases/latest/download/smartdns-${ARCH}"
    echo ""
fi

if [ "$PORT_53_AVAILABLE" = false ]; then
    echo -e "  ${WARN} 端口 53 被占用，SmartDNS 将使用备用端口"
    echo -e "      安装脚本会自动选择可用端口"
    echo ""
fi

echo -e "  ${INFO} 安装命令:"
echo -e "      ${GREEN}wget -O smartdns-install.sh https://你的脚本地址${NC}"
echo -e "      ${GREEN}chmod +x smartdns-install.sh${NC}"
echo -e "      ${GREEN}./smartdns-install.sh${NC}"
echo ""

# 导出检测报告
REPORT_FILE="/tmp/smartdns-check-report.txt"
{
    echo "SmartDNS 环境检测报告"
    echo "检测时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "操作系统: $OS $VER"
    echo "内核: $KERNEL"
    echo "架构: $ARCH"
    echo "Init: $INIT"
    echo "虚拟化: $VIRT"
    echo ""
    echo "检测结果: $COMPATIBILITY"
    echo "通过: $PASSED_CHECKS / 警告: $WARN_COUNT / 失败: $FAIL_COUNT"
} > "$REPORT_FILE"

echo -e "  ${INFO} 完整报告已保存: ${CYAN}${REPORT_FILE}${NC}"
echo ""
