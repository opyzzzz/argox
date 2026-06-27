#!/bin/sh
#==================================================
# DNS 篡改溯源诊断脚本 v2
# 用途: 遍历所有可能修改 DNS 的角色，定位真凶
# 兼容: Alpine / Debian (LXC/KVM/Docker/Podman)
# 用法: sh dns-detective.sh
# 更新: 修复逻辑错误、兼容性、完整性
#==================================================

set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_section() { echo ""; echo -e "${BOLD}${CYAN}========================================${NC}"; echo -e "${BOLD}${CYAN}$1${NC}"; echo -e "${BOLD}${CYAN}========================================${NC}"; }
log_ok()     { echo -e "  ${GREEN}[√]${NC} $1"; }
log_warn()   { echo -e "  ${YELLOW}[!]${NC} $1"; }
log_err()    { echo -e "  ${RED}[×]${NC} $1"; }
log_info()   { echo -e "  ${CYAN}[i]${NC} $1"; }

[ "$(id -u)" -ne 0 ] && { echo "需要 root 权限"; exit 1; }

echo -e "${BOLD}DNS 篡改溯源诊断${NC}"
echo -e "时间: $(date '+%Y-%m-%d %H:%M:%S')\n"

#------------------------------------------------
# 0. 初始化检测
#------------------------------------------------
log_section "0. 系统环境"

if [ -f /etc/alpine-release ]; then
    OS="alpine"
    OS_VER=$(cat /etc/alpine-release)
    log_info "系统: Alpine $OS_VER"
elif [ -f /etc/os-release ]; then
    OS="debian"
    . /etc/os-release 2>/dev/null
    log_info "系统: ${PRETTY_NAME:-Debian/Ubuntu}"
else
    OS="unknown"
    log_warn "无法识别系统"
fi

# 更可靠的 init 检测
INIT="unknown"
PID1=$(cat /proc/1/comm 2>/dev/null)
if [ -d /run/systemd/system ]; then
    INIT="systemd"
elif [ "$PID1" = "openrc-init" ] || [ -f /sbin/openrc ]; then
    INIT="openrc"
elif [ -f /sbin/openrc ]; then
    INIT="openrc"
fi
log_info "Init: $INIT (PID1: $PID1)"

# 更精确的虚拟化检测
VIRT=""
grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null && VIRT="${VIRT}docker "
grep -q "container=lxc" /proc/1/environ 2>/dev/null && VIRT="${VIRT}lxc "
[ -f /.dockerenv ] && VIRT="${VIRT}docker-file "
[ -f /run/.containerenv ] && VIRT="${VIRT}podman "
[ -z "$VIRT" ] && VIRT="kvm/bare"
VIRT=$(echo "$VIRT" | xargs)  # 去除首尾空格
log_info "虚拟化: $VIRT"

IS_CONTAINER=false
echo "$VIRT" | grep -qE "docker|podman|lxc|container" && IS_CONTAINER=true

# 基础工具检查
log_info "已安装工具:"
command -v wget >/dev/null 2>&1  && echo -n " wget"    || echo -n " [无wget]"
command -v curl >/dev/null 2>&1  && echo -n " curl"    || echo -n " [无curl]"
command -v grep >/dev/null 2>&1  && echo -n " grep"    || echo -n " [无grep]"
command -v lsattr >/dev/null 2>&1 && echo -n " lsattr" || echo -n " [无lsattr]"
command -v chattr >/dev/null 2>&1 && echo -n " chattr" || echo -n " [无chattr]"
echo ""

#------------------------------------------------
# 1. 当前 DNS 状态快照
#------------------------------------------------
log_section "1. 当前 DNS 配置"

if [ -f /etc/resolv.conf ]; then
    log_info "/etc/resolv.conf 内容 (前20行):"
    head -n 20 /etc/resolv.conf | while read line; do echo "    $line"; done
else
    log_err "/etc/resolv.conf 不存在"
fi

if [ -L /etc/resolv.conf ]; then
    LINK_TARGET=$(readlink -f /etc/resolv.conf 2>/dev/null)
    log_warn "resolv.conf 是软链接 → ${LINK_TARGET}"
    if [ -f "$LINK_TARGET" ]; then
        log_info "链接目标内容:"
        head -n 20 "$LINK_TARGET" | while read line; do echo "    $line"; done
    fi
fi

if command -v lsattr >/dev/null 2>&1; then
    ATTR=$(lsattr /etc/resolv.conf 2>/dev/null)
    if echo "$ATTR" | grep -q "i"; then
        log_warn "resolv.conf 被 immutable 锁定: $ATTR"
    elif [ -n "$ATTR" ]; then
        log_info "resolv.conf 属性: $ATTR"
    fi
fi

#------------------------------------------------
# 2. /etc/hosts 劫持检查
#------------------------------------------------
log_section "2. /etc/hosts 劫持检查"

if [ -f /etc/hosts ]; then
    HOSTS_DNS=$(grep -iE "dns\.|cloudflare|google.*dns|8\.8\.8\.8|1\.1\.1\.1" /etc/hosts 2>/dev/null)
    if [ -n "$HOSTS_DNS" ]; then
        log_err "/etc/hosts 中发现 DNS 相关劫持条目:"
        echo "$HOSTS_DNS" | while read line; do echo "    $line"; done
    else
        log_ok "/etc/hosts 无 DNS 劫持迹象"
    fi
else
    log_warn "/etc/hosts 不存在"
fi

#------------------------------------------------
# 3. DHCP 客户端检查
#------------------------------------------------
log_section "3. DHCP 客户端"

check_process() {
    if pgrep -x "$1" >/dev/null 2>&1; then
        PIDS=$(pgrep -x "$1" | head -n 3 | tr '\n' ' ')
        log_err "进程中存在: $1 (PID: $PIDS)"
        return 0
    else
        log_ok "未运行: $1"
        return 1
    fi
}

check_dhcp_processes() {
    check_process "dhclient"
    check_process "dhcpcd"
    check_process "udhcpc"
}
check_dhcp_processes

# dhclient 配置
if [ -f /etc/dhcp/dhclient.conf ]; then
    log_info "dhclient.conf 存在"
    if grep -qE "supersede domain-name-servers|prepend domain-name-servers" /etc/dhcp/dhclient.conf 2>/dev/null; then
        log_warn "dhclient.conf 中有 DNS 相关指令:"
        grep -nE "domain-name-servers" /etc/dhcp/dhclient.conf | while read line; do echo "    L$line"; done
    else
        log_ok "dhclient.conf 无 DNS 覆盖指令"
    fi
else
    log_ok "无 /etc/dhcp/dhclient.conf"
fi

# dhclient 钩子目录
for hook_dir in /etc/dhcp/dhclient-exit-hooks.d /etc/dhcp/dhclient-enter-hooks.d; do
    if [ -d "$hook_dir" ]; then
        HOOK_COUNT=$(find "$hook_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
        if [ "$HOOK_COUNT" -gt 0 ]; then
            log_warn "$hook_dir 有 $HOOK_COUNT 个钩子脚本:"
            find "$hook_dir" -maxdepth 1 -type f -exec ls -la {} \; 2>/dev/null | while read line; do echo "    $line"; done
            # 检查钩子是否包含 DNS 操作
            find "$hook_dir" -maxdepth 1 -type f -exec grep -l "resolv.conf\|nameserver" {} \; 2>/dev/null | while read f; do
                log_err "  → $f 包含 DNS 相关操作"
            done
        fi
    fi
done

# udhcpc 脚本
if [ "$OS" = "alpine" ]; then
    log_info "udhcpc 配置:"
    if [ -f /usr/share/udhcpc/default.script ]; then
        log_warn "存在 default.script"
        DNS_LINES=$(grep -n "resolv.conf\|nameserver\|dns" /usr/share/udhcpc/default.script 2>/dev/null | head -n 10)
        if [ -n "$DNS_LINES" ]; then
            echo "$DNS_LINES" | while read line; do echo "    L$line"; done
        else
            log_ok "default.script 无 DNS 操作"
        fi
    else
        log_ok "无 default.script"
    fi
    if [ -f /etc/udhcpc/udhcpc.conf ]; then
        log_warn "存在 udhcpc.conf:"
        cat /etc/udhcpc/udhcpc.conf | while read line; do echo "    $line"; done
    else
        log_ok "无 udhcpc.conf"
    fi
    log_info "提示: udhcpc 可通过 -s 参数指定自定义脚本，请检查进程命令行(见13节)"
fi

#------------------------------------------------
# 4. DNS 管理服务
#------------------------------------------------
log_section "4. DNS 管理服务"

# systemd-resolved
if command -v resolvectl >/dev/null 2>&1; then
    log_err "systemd-resolved 已安装"
    if resolvectl status >/dev/null 2>&1; then
        log_info "运行状态:"
        resolvectl status 2>/dev/null | head -n 20 | while read line; do echo "    $line"; done
    fi
else
    log_ok "未安装 systemd-resolved"
fi

# NetworkManager
if command -v nmcli >/dev/null 2>&1; then
    log_err "NetworkManager 已安装"
    if nmcli device status >/dev/null 2>&1; then
        log_info "设备状态:"
        nmcli device status 2>/dev/null | head -n 10 | while read line; do echo "    $line"; done
    fi
else
    log_ok "未安装 NetworkManager"
fi

# connman
if command -v connmanctl >/dev/null 2>&1 || pgrep -x connmand >/dev/null 2>&1; then
    log_err "connman 存在"
    if command -v connmanctl >/dev/null 2>&1; then
        connmanctl services 2>/dev/null | head -n 10 | while read line; do echo "    $line"; done
    fi
else
    log_ok "未安装 connman"
fi

#------------------------------------------------
# 5. resolvconf / openresolv
#------------------------------------------------
log_section "5. resolvconf 框架"

if command -v resolvconf >/dev/null 2>&1; then
    log_err "resolvconf 命令存在"
    resolvconf --version 2>/dev/null | head -n 3 | while read line; do echo "    $line"; done
    
    # 检查接口目录
    for dir in /run/resolvconf/interface /run/resolvconf/interfaces /var/run/resolvconf /etc/resolvconf; do
        if [ -d "$dir" ]; then
            FILE_COUNT=$(find "$dir" -type f 2>/dev/null | wc -l)
            if [ "$FILE_COUNT" -gt 0 ]; then
                log_warn "resolvconf 数据目录: $dir ($FILE_COUNT 个文件)"
                find "$dir" -type f 2>/dev/null | while read f; do
                    CONTENT=$(head -c 200 "$f" 2>/dev/null | tr '\n' ' ')
                    echo "    $f : $CONTENT"
                done
            fi
        fi
    done
else
    log_ok "未安装 resolvconf"
fi

#------------------------------------------------
# 6. 网络接口配置
#------------------------------------------------
log_section "6. 网络接口配置"

if [ -f /etc/network/interfaces ]; then
    log_warn "/etc/network/interfaces 存在"
    
    # 直接 DNS 配置
    DNS_COUNT=$(grep -c "dns-nameservers" /etc/network/interfaces 2>/dev/null)
    if [ "$DNS_COUNT" -gt 0 ]; then
        log_err "包含 dns-nameservers 指令 ($DNS_COUNT 处):"
        grep -n "dns-nameservers" /etc/network/interfaces | while read line; do echo "    $line"; done
    fi
    
    # 检查 source 引用的文件
    SOURCE_FILES=$(grep "^source" /etc/network/interfaces 2>/dev/null | awk '{for(i=2;i<=NF;i++) print $i}')
    for sf in $SOURCE_FILES; do
        # 展开通配符
        for expanded in $sf; do
            if [ -f "$expanded" ] && grep -q "dns-nameservers" "$expanded" 2>/dev/null; then
                log_err "  source 文件 $expanded 包含 dns-nameservers:"
                grep -n "dns-nameservers" "$expanded" | while read line; do echo "      $line"; done
            fi
        done
    done
    
    # 输出接口配置摘要
    log_info "接口配置摘要 (前30行):"
    grep -v "^#\|^$" /etc/network/interfaces 2>/dev/null | head -n 30 | while read line; do echo "    $line"; done
else
    log_ok "/etc/network/interfaces 不存在"
fi

# if-up.d / if-down.d 钩子
for hook_dir in /etc/network/if-up.d /etc/network/if-down.d /etc/network/if-pre-up.d /etc/network/if-post-down.d; do
    if [ -d "$hook_dir" ]; then
        COUNT=$(find "$hook_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
        if [ "$COUNT" -gt 0 ]; then
            log_warn "$hook_dir 有 $COUNT 个钩子:"
            find "$hook_dir" -maxdepth 1 -type f -exec ls -la {} \; 2>/dev/null | while read line; do echo "    $line"; done
            # 标记 DNS 相关
            find "$hook_dir" -maxdepth 1 -type f -exec grep -l "resolv.conf\|nameserver\|dns" {} \; 2>/dev/null | while read f; do
                log_err "  → $f 包含 DNS 操作"
            done
        fi
    fi
done

#------------------------------------------------
# 7. cloud-init
#------------------------------------------------
log_section "7. cloud-init"

if command -v cloud-init >/dev/null 2>&1; then
    log_err "cloud-init 已安装"
    cloud-init --version 2>/dev/null | head -n 1 | while read line; do echo "    $line"; done
    
    # 主配置文件
    if [ -f /etc/cloud/cloud.cfg ]; then
        log_info "检查 /etc/cloud/cloud.cfg:"
        if grep -q "manage-resolv-conf\|resolv_conf\|nameserver" /etc/cloud/cloud.cfg 2>/dev/null; then
            log_err "cloud.cfg 包含 DNS 相关配置:"
            grep -n "manage-resolv-conf\|resolv_conf\|nameserver" /etc/cloud/cloud.cfg | while read line; do echo "    $line"; done
        else
            log_ok "cloud.cfg 无 DNS 相关配置"
        fi
    fi
    
    # 子配置目录
    if [ -d /etc/cloud/cloud.cfg.d ]; then
        log_warn "cloud-init 配置目录存在"
        for cfg in /etc/cloud/cloud.cfg.d/*; do
            [ ! -f "$cfg" ] && continue
            if grep -qE "manage-resolv-conf|resolv_conf|nameserver|dns" "$cfg" 2>/dev/null; then
                log_err "$cfg 包含 DNS 相关配置:"
                grep -nE "manage-resolv-conf|resolv_conf|nameserver|dns" "$cfg" | while read line; do echo "    $line"; done
            fi
        done
    fi
    
    # 网络配置
    for netcfg in /etc/cloud/cloud.cfg.d/*network* /etc/cloud/cloud.cfg.d/*Network*; do
        if [ -f "$netcfg" ]; then
            log_warn "网络配置文件: $netcfg"
            head -n 30 "$netcfg" | while read line; do echo "    $line"; done
        fi
    done
else
    log_ok "未安装 cloud-init"
fi

#------------------------------------------------
# 8. VPN 客户端
#------------------------------------------------
log_section "8. VPN 客户端"

VPN_FOUND=false
for vpn in openvpn wireguard wg strongswan libreswan ipsec charon; do
    if pgrep -x "$vpn" >/dev/null 2>&1; then
        log_err "VPN 进程运行中: $vpn (PID: $(pgrep -x "$vpn" | head -n 3 | tr '\n' ' '))"
        VPN_FOUND=true
    fi
done
[ "$VPN_FOUND" = false ] && log_ok "未检测到运行中的 VPN 进程"

# OpenVPN
if [ -f /etc/openvpn/update-resolv-conf ] || [ -f /usr/share/openvpn/update-resolv-conf ]; then
    log_warn "存在 OpenVPN DNS 更新脚本"
    for f in /etc/openvpn/update-resolv-conf /usr/share/openvpn/update-resolv-conf; do
        [ -f "$f" ] && log_info "$f:" && head -n 5 "$f" | while read line; do echo "    $line"; done
    done
fi

# WireGuard
if [ -d /etc/wireguard ]; then
    WG_CONFIGS=$(find /etc/wireguard -maxdepth 1 -name "*.conf" 2>/dev/null)
    if [ -n "$WG_CONFIGS" ]; then
        log_warn "WireGuard 配置存在"
        for wgconf in /etc/wireguard/*.conf; do
            [ ! -f "$wgconf" ] && continue
            if grep -qE "DNS|PostUp.*resolv|PreDown.*resolv" "$wgconf" 2>/dev/null; then
                log_err "$wgconf 包含 DNS 相关配置:"
                grep -nE "DNS|PostUp.*resolv|PreDown.*resolv" "$wgconf" | while read line; do echo "    $line"; done
            fi
        done
    fi
fi

# IPsec VPN 的 DNS 推送
if [ -d /etc/ipsec.d ]; then
    for ipsec_conf in /etc/ipsec.conf /etc/ipsec.d/*.conf; do
        [ -f "$ipsec_conf" ] && grep -qi "dns" "$ipsec_conf" 2>/dev/null && \
            log_warn "$ipsec_conf 包含 DNS 相关内容"
    done
fi

#------------------------------------------------
# 9. netplan
#------------------------------------------------
log_section "9. netplan"

if command -v netplan >/dev/null 2>&1; then
    log_err "netplan 已安装"
    netplan get 2>/dev/null | grep -A2 "nameservers\|dns" | while read line; do echo "    $line"; done
else
    log_ok "未安装 netplan"
fi

#------------------------------------------------
# 10. Alpine local.d 启动脚本
#------------------------------------------------
if [ "$OS" = "alpine" ]; then
    log_section "10. Alpine local.d 启动脚本"
    if [ -d /etc/local.d ]; then
        HAS_SCRIPT=false
        for script in /etc/local.d/*.start /etc/local.d/*.stop; do
            [ -f "$script" ] || continue
            HAS_SCRIPT=true
            if grep -q "resolv.conf\|nameserver\|dns" "$script" 2>/dev/null; then
                log_err "$script 包含 DNS 相关操作:"
                grep -n "resolv.conf\|nameserver\|dns" "$script" | while read line; do echo "    $line"; done
            else
                log_warn "$script 存在 (未发现 DNS 操作)"
            fi
        done
        [ "$HAS_SCRIPT" = false ] && log_ok "local.d 目录为空"
    else
        log_ok "无 /etc/local.d 目录"
    fi
    
    if rc-update show 2>/dev/null | grep -q "local"; then
        log_warn "local 服务已加入启动项: $(rc-update show 2>/dev/null | grep local)"
    fi
fi

#------------------------------------------------
# 11. systemd 相关
#------------------------------------------------
if [ "$INIT" = "systemd" ]; then
    log_section "11. systemd DNS 相关单元"
    
    # tmpfiles.d
    TMPFILES_FOUND=false
    for tmpf in /etc/tmpfiles.d/*.conf /usr/lib/tmpfiles.d/*.conf; do
        [ -f "$tmpf" ] || continue
        if grep -q "/etc/resolv.conf" "$tmpf" 2>/dev/null; then
            log_err "$tmpf 包含 resolv.conf 规则:"
            grep "/etc/resolv.conf" "$tmpf" | while read line; do echo "    $line"; done
            TMPFILES_FOUND=true
        fi
    done
    [ "$TMPFILES_FOUND" = false ] && log_ok "tmpfiles.d 无 resolv.conf 规则"
    
    # systemd-networkd
    if [ -d /etc/systemd/network ]; then
        NETWORK_DNS=$(grep -rl "^DNS=" /etc/systemd/network/ 2>/dev/null)
        if [ -n "$NETWORK_DNS" ]; then
            log_err "systemd-networkd 配置文件指定了 DNS:"
            for nf in $NETWORK_DNS; do
                echo "    $nf:"
                grep "^DNS=" "$nf" | while read line; do echo "      $line"; done
            done
        else
            log_ok "systemd-networkd 配置无 DNS 指定"
        fi
    fi
    
    # 运行中的 DNS 相关服务
    log_info "运行中的 DNS/网络相关服务:"
    systemctl list-units --type=service --state=running 2>/dev/null | grep -iE "resolv|dns|network|dhcp|connman" | while read line; do
        log_warn "  $line"
    done
    
    # path unit 监控
    for path_unit in /etc/systemd/system/*resolv*.path /usr/lib/systemd/system/*resolv*.path; do
        [ -f "$path_unit" ] && log_warn "存在 path 单元监控 resolv.conf: $path_unit"
    done
fi

#------------------------------------------------
# 12. 扫描会修改 resolv.conf 的文件
#------------------------------------------------
log_section "12. 扫描引用 resolv.conf 的文件"

log_info "在 /etc 下搜索 (限制深度3, 最多20个结果)..."
grep -rl --max-depth=3 "/etc/resolv.conf" /etc 2>/dev/null \
    | grep -vE "\.bak$|\.backup|~$|\.orig$" \
    | head -n 20 \
    | while read f; do
    log_warn "  $f"
done

#------------------------------------------------
# 13. 进程命令行检查
#------------------------------------------------
log_section "13. DHCP/VPN 进程命令行详情"

for proc in udhcpc dhclient dhcpcd openvpn wg; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        CMDLINES=$(pgrep -x "$proc" -a 2>/dev/null)
        if [ -n "$CMDLINES" ]; then
            log_err "$proc 命令行:"
            echo "$CMDLINES" | while read line; do echo "    $line"; done
            
            # udhcpc 自定义脚本
            if [ "$proc" = "udhcpc" ]; then
                echo "$CMDLINES" | grep -o "\-s [^ ]*" | while read opt script; do
                    [ -n "$script" ] && {
                        log_warn "  使用自定义脚本: $script"
                        [ -f "$script" ] && {
                            log_info "  脚本内容 (DNS 相关行):"
                            grep -n "resolv.conf\|nameserver\|dns" "$script" 2>/dev/null | while read line; do echo "      $line"; done
                        }
                    }
                done
            fi
        fi
    fi
done

#------------------------------------------------
# 14. Alpine lbu 持久化配置
#------------------------------------------------
if [ "$OS" = "alpine" ]; then
    log_section "14. Alpine lbu 持久化配置"
    if command -v lbu >/dev/null 2>&1; then
        LBU_INCLUDE=$(lbu include 2>/dev/null)
        if echo "$LBU_INCLUDE" | grep -q "resolv.conf"; then
            log_err "lbu 会备份 /etc/resolv.conf，重启后恢复"
            log_info "lbu include 列表:"
            echo "$LBU_INCLUDE" | while read line; do echo "    $line"; done
        else
            log_ok "lbu 未包含 resolv.conf"
        fi
        
        # 检查 alpine-conf 的 setup-dns
        if [ -f /etc/conf.d/dns ]; then
            log_warn "存在 /etc/conf.d/dns (alpine-conf DNS 配置):"
            cat /etc/conf.d/dns | while read line; do echo "    $line"; done
        fi
    else
        log_ok "未安装 lbu"
    fi
fi

#------------------------------------------------
# 15. 容器环境分析
#------------------------------------------------
if $IS_CONTAINER; then
    log_section "15. 容器环境分析"
    
    MOUNT_INFO=$(mount 2>/dev/null | grep resolv.conf)
    if [ -n "$MOUNT_INFO" ]; then
        log_warn "/etc/resolv.conf 是挂载点:"
        echo "$MOUNT_INFO" | while read line; do echo "    $line"; done
        log_info "容器引擎管理 DNS，需通过 --dns 参数或 compose 文件控制"
    fi
    
    if [ -n "$DNS" ]; then
        log_warn "环境变量 DNS=$DNS"
    fi
    
    # 检查 Podman/Docker DNS 配置
    if [ -f /run/.containerenv ]; then
        log_info "Podman 容器环境变量:"
        grep -i dns /run/.containerenv 2>/dev/null | while read line; do echo "    $line"; done
    fi
    
    # 容器内的 dhcp 通常无效
    if pgrep -x "dhclient" >/dev/null 2>&1 || pgrep -x "udhcpc" >/dev/null 2>&1; then
        log_warn "容器内运行 DHCP 客户端 (通常无效，DNS 由引擎管理)"
    fi
fi

#------------------------------------------------
# 16. 其他检查
#------------------------------------------------
log_section "16. 其他可能来源"

# crontab
CRON_DNS=$(crontab -l 2>/dev/null | grep -iE "resolv|nameserver|dns")
if [ -n "$CRON_DNS" ]; then
    log_err "用户 crontab 包含 DNS 操作:"
    echo "$CRON_DNS" | while read line; do echo "    $line"; done
else
    log_ok "用户 crontab 无 DNS 操作"
fi

# 系统 crontab
for cronf in /etc/crontab /etc/cron.d/*; do
    [ -f "$cronf" ] && grep -qiE "resolv|nameserver|dns" "$cronf" 2>/dev/null && {
        log_err "系统 crontab $cronf 包含 DNS 操作:"
        grep -inE "resolv|nameserver|dns" "$cronf" | while read line; do echo "    $line"; done
    }
done

# 定时任务
[ -d /etc/periodic ] && {
    PERIODIC_DNS=$(grep -rl "resolv.conf\|nameserver" /etc/periodic/ 2>/dev/null)
    [ -n "$PERIODIC_DNS" ] && {
        log_err "/etc/periodic 中有 DNS 相关脚本:"
        echo "$PERIODIC_DNS" | while read line; do echo "    $line"; done
    }
}

# rc.local / systemd 的一次性启动脚本
[ -f /etc/rc.local ] && grep -qE "resolv.conf|nameserver|dns" /etc/rc.local 2>/dev/null && {
    log_err "/etc/rc.local 包含 DNS 操作"
    grep -nE "resolv.conf|nameserver|dns" /etc/rc.local | while read line; do echo "    $line"; done
}

#------------------------------------------------
# 汇总
#------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}           诊断完成${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo -e "图例:"
echo -e "  ${RED}[×]${NC} = 极可能是 DNS 篡改源"
echo -e "  ${YELLOW}[!]${NC} = 可疑，需结合环境判断"
echo -e "  ${GREEN}[√]${NC} = 已排除 / 无异常"
echo -e "  ${CYAN}[i]${NC} = 纯信息"
echo ""
echo -e "下一步建议:"
echo -e "  1. 重点关注 ${RED}[×]${NC} 标记的项目"
echo -e "  2. 如果是 VPS，优先检查 cloud-init 和 DHCP 客户端"
echo -e "  3. 如果是容器，DNS 由引擎管理，修改启动参数即可"
echo -e "  4. 找到真凶后，针对性地用事件驱动方案防御"
