#!/bin/bash

# ===============================================================
# 1. 定义变量与路径 (统一管理)
# ===============================================================
SCRIPT_PATH="/usr/local/bin/argo"
WORKDIR="/var/lib/argo"
XRAY="$WORKDIR/xray"
CF="$WORKDIR/cloudflared"
CONF="$WORKDIR/config.json"
LOG_ARGO="$WORKDIR/argo.log"

# 配置持久化文件
UUIDF="$WORKDIR/uuid"
IP_PREFF="$WORKDIR/ip_pref"      # 4 或 6
# Argo 模块
ARGO_EN="$WORKDIR/argo.enabled"   # 标记是否开启
ARGO_PORT="$WORKDIR/argo.port"
ARGO_TOKEN="$WORKDIR/argo.token"
ARGO_DOMAIN="$WORKDIR/argo.domain"
ARGO_PATH="$WORKDIR/argo.path"
# Reality 模块
REAL_EN="$WORKDIR/reality.enabled" # 标记是否开启
REAL_PORT="$WORKDIR/reality.port"
REAL_PRIV="$WORKDIR/reality.priv"
REAL_PUB="$WORKDIR/reality.pub"
REAL_SID="$WORKDIR/reality.sid"

mkdir -p $WORKDIR

# ===============================================================
# 2. 系统环境与依赖 (Alpine 深度优化)
# ===============================================================
fix_env() {
    echo -e "\033[32m[+] 正在检查系统环境...\033[0m"
    if [ -f /etc/alpine-release ]; then
        # 安装 Alpine 运行 Xray 必须的兼容库
        apk add --no-cache curl wget unzip bash procps chrony ca-certificates openssl gcompat libc6-compat >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
        service chronyd start >/dev/null 2>&1
    fi
    # 生成全局 UUID (仅第一次)
    [ ! -f "$UUIDF" ] && cat /proc/sys/kernel/random/uuid > "$UUIDF"
    # 初始化 IP 优先级
    if [ ! -f "$IP_PREFF" ]; then
        local v6=$(curl -s6m 5 https://api64.ipify.org || echo "")
        [ -n "$v6" ] && echo "6" > "$IP_PREFF" || echo "4" > "$IP_PREFF"
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH_CF="amd64"; ARCH_XRAY="64" ;;
        aarch64) ARCH_CF="arm64"; ARCH_XRAY="arm64-v8a" ;;
        *)       ARCH_CF="amd64"; ARCH_XRAY="64" ;;
    esac
}

download_bins() {
    get_arch
    # 下载 Xray
    if [ ! -f "$XRAY" ]; then
        echo -e "\033[32m[+] 下载 Xray-core ($ARCH_XRAY)...\033[0m"
        wget -O "$WORKDIR/x.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH_XRAY.zip"
        unzip -o "$WORKDIR/x.zip" -d "$WORKDIR" >/dev/null 2>&1
        chmod +x "$XRAY" && rm -f "$WORKDIR/x.zip"
    fi
    # 只有开启 Argo 时才下载 Cloudflared
    if [ -f "$ARGO_EN" ] && [ ! -f "$CF" ]; then
        echo -e "\033[32m[+] 下载 Cloudflared ($ARCH_CF)...\033[0m"
        wget -O "$CF" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH_CF"
        chmod +x "$CF"
    fi
}

# ===============================================================
# 3. 核心配置生成 (支持多入站并行)
# ===============================================================
generate_xray_config() {
    local uuid=$(cat "$UUIDF")
    local inbounds=""

    # 构造 Argo Inbound
    if [ -f "$ARGO_EN" ]; then
        local a_port=$(cat "$ARGO_PORT")
        local a_path=$(cat "$ARGO_PATH")
        inbounds+='{
            "port": '$a_port', "listen": "::", "protocol": "vless",
            "settings": {"clients": [{"id": "'$uuid'"}], "decryption": "none"},
            "streamSettings": {"network": "ws", "wsSettings": {"path": "'$a_path'"}}
        }'
    fi

    # 构造 Reality Inbound
    if [ -f "$REAL_EN" ]; then
        [ -n "$inbounds" ] && inbounds+=","
        local r_port=$(cat "$REAL_PORT")
        local r_priv=$(cat "$REAL_PRIV")
        local r_sid=$(cat "$REAL_SID")
        inbounds+='{
            "port": '$r_port', "listen": "::", "protocol": "vless",
            "settings": {"clients": [{"id": "'$uuid'", "flow": "xtls-rprx-vision"}], "decryption": "none"},
            "streamSettings": {
                "network": "tcp", "security": "reality",
                "realitySettings": {
                    "show": false, "dest": "www.microsoft.com:443", "xver": 0,
                    "serverNames": ["www.microsoft.com"], "privateKey": "'$r_priv'", "shortIds": ["'$r_sid'"]
                }
            }
        }'
    fi

    if [ -z "$inbounds" ]; then
        echo "[-] 错误：没有启用的服务模式"
        return 1
    fi

    cat > "$CONF" <<EOF
{
    "inbounds": [$inbounds],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
}

# ===============================================================
# 4. 服务控制管理
# ===============================================================
start_services() {
    echo -e "\033[32m[+] 启动服务中...\033[0m"
    pkill -9 xray
    pkill -9 cloudflared
    
    # 启动 Xray
    if [ -f "$ARGO_EN" ] || [ -f "$REAL_EN" ]; then
        generate_xray_config && nohup "$XRAY" -config "$CONF" >/dev/null 2>&1 &
        sleep 2
        pgrep -x "xray" >/dev/null && echo "[!] Xray 运行正常" || echo "[-] Xray 启动失败"
    fi

    # 启动 Argo 隧道
    if [ -f "$ARGO_EN" ]; then
        local token=$(cat "$TOKENF")
        local pref=$(cat "$IP_PREFF")
        # 纯 IPv6 机器强制指定 edge-ip-version
        nohup "$CF" tunnel --no-autoupdate --edge-ip-version "$pref" --protocol auto run --token "$token" > "$LOG_ARGO" 2>&1 &
        sleep 3
        pgrep -x "cloudflared" >/dev/null && echo "[!] Argo 隧道已连接" || echo "[-] Argo 启动失败，请检查日志"
    fi
}

stop_all() {
    pkill -9 xray
    pkill -9 cloudflared
    echo "[+] 所有服务已停止"
}

# ===============================================================
# 5. 交互菜单功能模块
# ===============================================================

config_argo() {
    echo -e "\n--- 配置 Argo Tunnel (VLESS+WS) ---"
    read -p "请输入 Cloudflare Tunnel Token: " token
    token=$(echo "$token" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
    [ -z "$token" ] && { echo "Token 无效"; return; }
    
    read -p "请输入你在 CF 配置的完整域名: " domain
    read -p "本地监听端口 (默认 25600): " port
    echo "${port:-25600}" > "$ARGO_PORT"
    echo "$token" > "$TOKENF"
    echo "$domain" > "$ARGO_DOMAIN"
    echo "/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)" > "$ARGO_PATH"
    touch "$ARGO_EN"
    download_bins
    start_services
    echo "[+] Argo 配置完成！"
}

config_reality() {
    echo -e "\n--- 配置 VLESS-REALITY (Vision) ---"
    read -p "请输入 Reality 端口 (默认 443): " port
    echo "${port:-443}" > "$REAL_PORT"
    
    # 生成密钥
    download_bins
    local keys=$($XRAY x25519)
    echo "$keys" | grep "Private key:" | awk '{print $3}' > "$REAL_PRIV"
    echo "$keys" | grep "Public key:" | awk '{print $3}' > "$REAL_PUB"
    openssl rand -hex 8 > "$REAL_SID"
    
    touch "$REAL_EN"
    start_services
    echo "[+] Reality 配置完成！"
}

modify_ports() {
    echo -e "\n--- 修改服务端口 ---"
    [ -f "$ARGO_EN" ] && {
        read -p "当前 Argo 端口 [$(cat $ARGO_PORT)], 修改为: " np
        [ -n "$np" ] && echo "$np" > "$ARGO_PORT"
    }
    [ -f "$REAL_EN" ] && {
        read -p "当前 Reality 端口 [$(cat $REAL_PORT)], 修改为: " np
        [ -n "$np" ] && echo "$np" > "$REAL_PORT"
    }
    start_services
}

show_nodes() {
    local uuid=$(cat "$UUIDF")
    echo -e "\n\033[33m========== 节点输出 (已启用模式) ==========\033[0m"
    
    if [ -f "$ARGO_EN" ]; then
        local domain=$(cat "$ARGO_DOMAIN")
        local path=$(cat "$ARGO_PATH")
        echo -e "\n[ Argo Tunnel (VLESS+WS+TLS) ]"
        echo -e "域名: $domain | 端口: 443"
        echo -e "链接: \033[36mvless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=$(echo $path | sed 's/\//%2F/g')#Argo-VLESS\033[0m"
    fi

    if [ -f "$REAL_EN" ]; then
        local port=$(cat "$REAL_PORT")
        local pub=$(cat "$REAL_PUB")
        local sid=$(cat "$REAL_SID")
        local myip=$(curl -s4m 5 https://api.ipify.org || curl -s6m 5 https://api64.ipify.org)
        echo -e "\n[ VLESS-REALITY (TCP+Vision) ]"
        echo -e "地址: $myip | 端口: $port"
        echo -e "链接: \033[36mvless://$uuid@$myip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$pub&sid=$sid#Reality-VLESS\033[0m"
    fi
    echo -e "\033[33m===========================================\033[0m"
}

# ===============================================================
# 6. 系统集成与卸载
# ===============================================================
install_to_system() {
    if [ ! -f "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    fi
    # Alpine OpenRC
    if [ -d /etc/init.d ]; then
        cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
depend() { after net dns; }
start() { $SCRIPT_PATH start; }
stop() { $SCRIPT_PATH stop; }
EOF
        chmod +x /etc/init.d/argo
        rc-update add argo default >/dev/null 2>&1
    fi
    # Cron
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH cron"; echo "*/5 * * * * $SCRIPT_PATH cron") | crontab -
}

uninstall() {
    stop_all
    rc-update del argo >/dev/null 2>&1
    rm -rf "$WORKDIR" "$SCRIPT_PATH" /etc/init.d/argo
    crontab -l | grep -v "$SCRIPT_PATH" | crontab -
    echo "[!] 卸载完成。"
}

# ===============================================================
# 7. 主入口与菜单逻辑
# ===============================================================
main_menu() {
    clear
    echo -e "\033[35m      Argo & Reality 并行部署工具 (Alpine 优化版)\033[0m"
    echo "-------------------------------------------------------"
    # 状态检查
    local status_argo="\033[31m未安装\033[0m"
    [ -f "$ARGO_EN" ] && status_argo="\033[32m已启用\033[0m"
    local status_real="\033[31m未安装\033[0m"
    [ -f "$REAL_EN" ] && status_real="\033[32m已启用\033[0m"

    echo -e "1. [配置/更新] Argo Tunnel (VLESS+WS)    状态: $status_argo"
    echo -e "2. [配置/更新] VLESS-REALITY (Vision)     状态: $status_real"
    echo -e "3. [节点输出] 查看当前所有运行节点"
    echo -e "4. [端口管理] 修改本地监听端口"
    echo -e "5. [服务管理] 重启所有服务"
    echo -e "6. [开关模块] 停用特定模式 (不卸载)"
    echo -e "7. [彻底卸载] 移除所有程序及配置"
    echo -e "0. 退出"
    echo "-------------------------------------------------------"
    read -p "选择操作 [0-7]: " opt

    case "$opt" in
        1) config_argo; install_to_system; main_menu ;;
        2) config_reality; install_to_system; main_menu ;;
        3) show_nodes ;;
        4) modify_ports; main_menu ;;
        5) start_services; main_menu ;;
        6)
            echo "1. 停用 Argo | 2. 停用 Reality"
            read -p "选择: " sopt
            [ "$sopt" == "1" ] && rm -f "$ARGO_EN"
            [ "$sopt" == "2" ] && rm -f "$REAL_EN"
            start_services; main_menu ;;
        7) uninstall ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

# 处理后台指令
case "$1" in
    install) fix_env; main_menu ;;
    start) start_services ;;
    stop) stop_all ;;
    cron) 
        pgrep -x "xray" >/dev/null || start_services
        if [ -f "$ARGO_EN" ]; then
            pgrep -x "cloudflared" >/dev/null || start_services
        fi
        ;;
    menu|*) main_menu ;;
esac
