#!/bin/sh
# 上方特意使用 /bin/sh 确保 Alpine 与 Debian 极简环境的绝对兼容性

# ==============================================================================
# 脚本名称: smart_dns.sh
# 描述: 智能自适应网络接管 DNS 脚本（支持 Debian / Alpine）
# 特点: 自动探测【纯IPv4 / 纯IPv6 / 双栈】，按需写入，无 chattr 锁，防 DHCP 篡改
# ==============================================================================

# 严格模式：出错即退出
set -e

# 1. 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo "[错误] 必须使用 root 用户运行此脚本！" >&2
    exit 1
fi

echo "=========================================="
echo "    正在开始智能自适应配置系统网络 DNS"
echo "=========================================="

# 2. 检测系统类型
SYSTEM="unknown"
if [ -f /etc/alpine-release ]; then
    SYSTEM="alpine"
elif [ -f /etc/debian_version ]; then
    SYSTEM="debian"
fi
echo "[信息] 检测到当前操作系统: $SYSTEM"

# 3. 网络环境动态探测（核心改进：拒绝盲目写入）
HAS_IPV4=0
# 尝试连接 Cloudflare 的 IPv4 DNS（仅测试底层连接，不依赖域名解析）
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    HAS_IPV4=1
fi

HAS_IPV6=0
# 尝试连接 Cloudflare 的 IPv6 DNS 节点（仅测试底层连接，不依赖域名解析）
# 在某些环境中 ping6 可能不存在，改用 ping -6 命令做兼容性适配
if command -v ping6 >/dev/null 2>&1; then
    if ping6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
        HAS_IPV6=1
    fi
elif ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1; then
    HAS_IPV6=1
fi

# 打印检测到的网络架构
if [ $HAS_IPV4 -eq 1 ] && [ $HAS_IPV6 -eq 1 ]; then
    echo "[网络] 检测结果: 双方双栈网络 (IPv4 + IPv6)"
elif [ $HAS_IPV4 -eq 1 ]; then
    echo "[网络] 检测结果: 纯 IPv4 网络 (不带 IPv6)"
elif [ $HAS_IPV6 -eq 1 ]; then
    echo "[网络] 检测结果: 纯 IPv6 网络 (不带 IPv4)"
else
    echo "[警告] 未检测到有效的公网出站路由，将默认采用双栈 DNS 配置！"
    HAS_IPV4=1
    HAS_IPV6=1
fi

# 4. 彻底解除旧脚本遗留的底层 chattr 文件锁（防止后续流程无法写入）
if command -v chattr >/dev/null 2>&1; then
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
fi

# 5. 修复/重建 resolv.conf 软链接问题
if [ -L /etc/resolv.conf ]; then
    echo "[信息] 检测到 /etc/resolv.conf 为软链接，正在将其转换为常规文件..."
    rm -f /etc/resolv.conf
fi

# ==============================================================================
# 核心逻辑：分系统配置原生网络组件，从根源防止 DHCP / NetworkManager 篡改
# ==============================================================================

if [ "$SYSTEM" = "debian" ]; then
    echo "[配置] 正在优化 Debian 网络管理服务..."

    # 1) 彻底停用并禁用 systemd-resolved 冲突服务
    if systemctl is-enabled systemd-resolved >/dev/null 2>&1 || systemctl is-active systemd-resolved >/dev/null 2>&1; then
        echo " -> 正在关闭并禁用 systemd-resolved 服务..."
        systemctl disable --now systemd-resolved 2>/dev/null || true
    fi

    # 2) 阻止 NetworkManager 篡改 DNS
    if [ -d /etc/NetworkManager ]; then
        NM_CONF="/etc/NetworkManager/NetworkManager.conf"
        if [ -f "$NM_CONF" ]; then
            echo " -> 配置 NetworkManager 忽略 DNS 修改 (dns=none)..."
            if grep -q "\[main\]" "$NM_CONF"; then
                sed -i '/^dns=/d' "$NM_CONF"
                sed -i '/\[main\]/a dns=none' "$NM_CONF"
            else
                echo -e "[main]\ndns=none" >> "$NM_CONF"
            fi
            # 异步重启 NetworkManager 防止当前 SSH 终端瞬间中断卡死
            if pgrep NetworkManager >/dev/null 2>&1; then
                systemctl restart NetworkManager >/dev/null 2>&1 &
            fi
        fi
    fi

    # 3) 使用 dhclient 原生高级属性限制 DHCP 篡改
    if [ -d /etc/dhcp ]; then
        DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
        if [ -f "$DHCLIENT_CONF" ]; then
            echo " -> 配置 dhclient 原生属性限制 DHCP 篡改..."
            sed -i '/supersede domain-name-servers/d' "$DHCLIENT_CONF"
            
            # 根据前述网络探测结果，优雅按需生成限制行
            if [ $HAS_IPV4 -eq 1 ] && [ $HAS_IPV6 -eq 1 ]; then
                echo "supersede domain-name-servers 8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2001:4860:4860::8844;" >> "$DHCLIENT_CONF"
            elif [ $HAS_IPV4 -eq 1 ]; then
                echo "supersede domain-name-servers 8.8.8.8, 1.1.1.1;" >> "$DHCLIENT_CONF"
            elif [ $HAS_IPV6 -eq 1 ]; then
                echo "supersede domain-name-servers 2001:4860:4860::8888, 2001:4860:4860::8844;" >> "$DHCLIENT_CONF"
            fi
        fi
        # 清理可能残留的旧防篡改钩子脚本（防止发生内部死锁）
        rm -f /etc/dhcp/dhclient-enter-hooks.d/nodnsupdate
    fi

elif [ "$SYSTEM" = "alpine" ]; then
    echo "[配置] 正在优化 Alpine 网络管理服务..."

    # 1) 阻止 udhcpc 篡改 DNS (Alpine 默认的 DHCP 客户端)
    if [ -f /etc/udhcpc/udhcpc.conf ]; then
        sed -i '/^RESOLV_CONF=/d' /etc/udhcpc/udhcpc.conf
        echo 'RESOLV_CONF="no"' >> /etc/udhcpc/udhcpc.conf
    else
        mkdir -p /etc/udhcpc
        echo 'RESOLV_CONF="no"' > /etc/udhcpc/udhcpc.conf
    fi
    echo " -> 已配置 udhcpc 忽略远程分配的 DNS"

else
    echo "[警告] 未知系统类型，将跳过网络管理器配置，仅更新 resolv.conf 配置文件。"
fi

# ==============================================================================
# 根据探测结果，动态精确写入 /etc/resolv.conf
# ==============================================================================
echo "[配置] 正在按需写入最精确的系统 DNS..."

# 先生成文件头部说明
cat > /etc/resolv.conf << 'EOF'
# ====================================================================
#  DNS Configuration - Managed Naturally, Dynamically & Safely
# ====================================================================
EOF

# 按需追加 nameserver
if [ $HAS_IPV4 -eq 1 ]; then
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
fi

if [ $HAS_IPV6 -eq 1 ]; then
    echo "nameserver 2001:4860:4860::8888" >> /etc/resolv.conf
    echo "nameserver 2001:4860:4860::8844" >> /etc/resolv.conf
fi

# 追加解析性能优化参数
cat >> /etc/resolv.conf << 'EOF'
options timeout:2 attempts:3 rotate
EOF

# 优雅设置只读权限（普通 444 权限，允许所有核心读取，防外部胡乱覆盖，无需强锁）
chmod 444 /etc/resolv.conf

echo ""
echo "=========================================="
echo "    ✔ 智能 DNS 安全接管配置已全部完成！"
echo "=========================================="
echo "当前 VPS 有效 DNS 状态:"
echo "------------------------------------------"
cat /etc/resolv.conf
echo "------------------------------------------"
echo "[提示] 建议执行重启命令使您的节点无缝同步新网络环境。"
echo "=========================================="
