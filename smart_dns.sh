#!/bin/sh

# ==============================================================================
# 脚本名称: smart_dns.sh
# 描述: 智能自适应网络接管 DNS 脚本（完美兼容 Debian / Alpine 纯净及容器环境）
# 特点: 多重容错探测，动态按需分配，零阻塞，无 chattr 强锁
# ==============================================================================

set -e

# 1. 检查 root 权限
[ "$(id -u)" != "0" ] && { echo "[错误] 必须使用 root 用户运行此脚本！" >&2; exit 1; }

# 2. 检查必需命令
if ! command -v ping >/dev/null 2>&1; then
    echo "[错误] ping 命令不可用，无法进行网络探测！" >&2
    exit 1
fi

echo "=========================================="
echo "    正在开始智能自适应配置系统网络 DNS"
echo "=========================================="

# 3. 检测系统类型
SYSTEM="unknown"
[ -f /etc/alpine-release ] && SYSTEM="alpine"
[ -f /etc/debian_version ] && SYSTEM="debian"
echo "[信息] 检测到当前操作系统: $SYSTEM"

# 4. 网络环境多重容错探测
HAS_IPV4=0
HAS_IPV6=0
echo "[配置] 正在多重探测网络出站能力..."

# 通用探测函数（含参数验证）
probe() {
    local ver="${1:-4}" target="${2:-}"
    [ -z "$target" ] && return 1
    [ "$ver" = "6" ] && ping -6 -c 1 -w 2 "$target" >/dev/null 2>&1 || \
                       ping -c 1 -w 2 "$target" >/dev/null 2>&1
}

# IPv4 探测（3目标，需2个成功）
set +e
ipv4_ok=0
echo "--- IPv4 探测 ---"
for t in "1.1.1.1" "8.8.8.8" "9.9.9.9"; do
    if probe 4 "$t"; then
        ipv4_ok=$((ipv4_ok + 1))
        echo "  ✓ $t"
    else
        echo "  ✗ $t"
    fi
    [ $ipv4_ok -ge 2 ] && break
done

# IPv6 探测（4目标，需2个成功）
ipv6_ok=0
echo "--- IPv6 探测 ---"
for t in "2606:4700:4700::1111" "2001:4860:4860::8888" "2620:fe::fe" "2620:0:ccc::2"; do
    if probe 6 "$t"; then
        ipv6_ok=$((ipv6_ok + 1))
        echo "  ✓ $t"
    else
        echo "  ✗ $t"
    fi
    [ $ipv6_ok -ge 2 ] && break
done
set -e

# 判定结果
[ $ipv4_ok -ge 2 ] && HAS_IPV4=1
[ $ipv6_ok -ge 2 ] && HAS_IPV6=1

# 最终容错：完全不通时检查本地接口
if [ $HAS_IPV4 -eq 0 ] && [ $HAS_IPV6 -eq 0 ]; then
    echo "[警告] 所有公网探测失败，检查本地网络接口..."
    if command -v ip >/dev/null 2>&1; then
        ip addr show 2>/dev/null | grep -q "inet " && HAS_IPV4=1
        ip addr show 2>/dev/null | grep -q "inet6 " && HAS_IPV6=1
    fi
    [ $HAS_IPV4 -eq 0 ] && [ $HAS_IPV6 -eq 0 ] && { HAS_IPV4=1; HAS_IPV6=1; }
fi

# 打印结果
case "$HAS_IPV4$HAS_IPV6" in
    "11") echo "[网络] 最终判定: 双栈网络 (IPv4 + IPv6)" ;;
    "10") echo "[网络] 最终判定: 纯 IPv4 网络" ;;
    "01") echo "[网络] 最终判定: 纯 IPv6 网络" ;;
     *)  echo "[网络] 最终判定: 强制双栈 (保底配置)" ;;
esac

# 5. 备份并解锁
[ -f /etc/resolv.conf ] && cp -a /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
command -v chattr >/dev/null 2>&1 && chattr -i /etc/resolv.conf 2>/dev/null || true
[ -L /etc/resolv.conf ] && { echo "[信息] 转换软链接为常规文件..."; rm -f /etc/resolv.conf; }

# ==============================================================================
# 分系统配置
# ==============================================================================

if [ "$SYSTEM" = "debian" ]; then
    echo "[配置] 优化 Debian 网络管理..."

    # 禁用 systemd-resolved
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active systemd-resolved >/dev/null 2>&1 && {
            echo " -> 停用 systemd-resolved"
            systemctl disable --now systemd-resolved 2>/dev/null || true
        }
    fi

    # 配置 NetworkManager
    NM_CONF="/etc/NetworkManager/NetworkManager.conf"
    if [ -f "$NM_CONF" ]; then
        echo " -> 配置 NetworkManager dns=none"
        sed -i '/^dns=/d' "$NM_CONF" 2>/dev/null || true
        grep -q "\[main\]" "$NM_CONF" 2>/dev/null && \
            sed -i '/\[main\]/a dns=none' "$NM_CONF" || \
            printf "[main]\ndns=none\n" >> "$NM_CONF"
        command -v systemctl >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1 && \
            pgrep NetworkManager >/dev/null 2>&1 && \
            systemctl restart NetworkManager >/dev/null 2>&1 &
    fi

    # 处理 resolvconf
    command -v resolvconf >/dev/null 2>&1 && {
        echo " -> 配置 resolvconf"
        mkdir -p /etc/resolvconf/resolv.conf.d 2>/dev/null || true
        printf "nameserver 127.0.0.1\n" > /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
    }

    # 配置 dhclient
    for conf in /etc/dhcp/dhclient.conf /etc/dhcp3/dhclient.conf; do
        [ -f "$conf" ] && { DHCLIENT_CONF="$conf"; break; }
    done
    if [ -n "${DHCLIENT_CONF:-}" ]; then
        echo " -> 配置 dhclient 防篡改"
        sed -i '/supersede domain-name-servers/d' "$DHCLIENT_CONF" 2>/dev/null || true
        DNS_LIST=""
        [ $HAS_IPV4 -eq 1 ] && DNS_LIST="8.8.8.8, 1.1.1.1"
        [ $HAS_IPV6 -eq 1 ] && DNS_LIST="${DNS_LIST:+$DNS_LIST, }2001:4860:4860::8888, 2001:4860:4860::8844"
        [ -n "$DNS_LIST" ] && echo "supersede domain-name-servers $DNS_LIST;" >> "$DHCLIENT_CONF"
    fi
    rm -f /etc/dhcp/dhclient-enter-hooks.d/nodnsupdate \
          /etc/dhcp/dhclient-exit-hooks.d/nodnsupdate \
          /etc/dhcp3/dhclient-enter-hooks.d/nodnsupdate 2>/dev/null || true

elif [ "$SYSTEM" = "alpine" ]; then
    echo "[配置] 优化 Alpine 网络管理..."
    mkdir -p /etc/udhcpc 2>/dev/null || true
    printf 'RESOLV_CONF="no"\n' > /etc/udhcpc/udhcpc.conf
    echo " -> 已配置 udhcpc 忽略远程 DNS"
fi

# ==============================================================================
# 写入 /etc/resolv.conf
# ==============================================================================
echo "[配置] 写入系统 DNS..."

{
    echo "# DNS Configuration - Managed by smart_dns.sh"
    if [ $HAS_IPV4 -eq 1 ]; then
        echo "nameserver 8.8.8.8"
        echo "nameserver 1.1.1.1"
    fi
    if [ $HAS_IPV6 -eq 1 ]; then
        echo "nameserver 2001:4860:4860::8888"
        echo "nameserver 2001:4860:4860::8844"
    fi
    echo "options timeout:2 attempts:3 rotate"
} > /etc/resolv.conf || { echo "[错误] 写入 /etc/resolv.conf 失败！" >&2; exit 1; }

chmod 644 /etc/resolv.conf

echo ""
echo "=========================================="
echo "    ✔ DNS 配置完成"
echo "=========================================="
cat /etc/resolv.conf
echo "------------------------------------------"
echo "[信息] 备份: /etc/resolv.conf.bak"
echo "=========================================="
