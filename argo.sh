#!/bin/bash

# ===============================================================
# 变量与路径统一定义
# ===============================================================
SCRIPT_PATH="/usr/local/bin/argo"
WORKDIR="/var/lib/argo"
CF="$WORKDIR/cloudflared"
XRAY="$WORKDIR/xray"
CONF="$WORKDIR/config.json"

# 数据持久化文件
UUIDF="$WORKDIR/uuid"
PORTF="$WORKDIR/port"
DOMAINF="$WORKDIR/domain"
TOKENF="$WORKDIR/token"
PATHF="$WORKDIR/path"
IP_PREFF="$WORKDIR/ip_pref"
TYPEF="$WORKDIR/type"
PRIVF="$WORKDIR/priv"
PUBF="$WORKDIR/pub"
SIDF="$WORKDIR/sid"

mkdir -p $WORKDIR

# ===============================================================
# 环境检查与修复 (包含 Alpine 运行库修复)
# ===============================================================
fix_env() {
    echo "[+] 正在配置系统环境 (Alpine 加固)..."
    
    if [ -f /etc/alpine-release ]; then
        # 安装 gcompat 和 libc6-compat 是在 Alpine 运行 Xray 的关键
        apk add --no-cache curl wget unzip bash procps chrony ca-certificates openssl gcompat libc6-compat >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
        rc-update add chronyd default >/dev/null 2>&1
        service chronyd start >/dev/null 2>&1
    fi

    # 强制同步时间
    chronyd -q 'server pool.ntp.org iburst' >/dev/null 2>&1

    # IP 优先级检测
    local v4=$(curl -s4m 5 https://api.ipify.org || echo "")
    local v6=$(curl -s6m 5 https://api64.ipify.org || echo "")
    
    if [ ! -f "$IP_PREFF" ]; then
        # 优先使用 IPv4，若无则使用 IPv6
        [ -n "$v4" ] && echo "4" > "$IP_PREFF" || echo "6" > "$IP_PREFF"
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH_CF="amd64"; ARCH_XRAY="64" ;;
        aarch64) ARCH_CF="arm64"; ARCH_XRAY="arm64-v8a" ;;
        *)       ARCH_CF="amd64"; ARCH_XRAY="64" ;;
    esac
}

download_bin(){
    get_arch
    local node_type=$(cat "$TYPEF" 2>/dev/null)
    
    # 下载 Cloudflared
    if [[ "$node_type" == "argo" && ! -f "$CF" ]]; then
        echo "[+] 下载 Cloudflared ($ARCH_CF)..."
        wget -O "$CF" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH_CF"
        chmod +x "$CF"
    fi

    # 下载 Xray (精准匹配 Alpine)
    if [ ! -f "$XRAY" ]; then
        echo "[+] 下载 Xray-core ($ARCH_XRAY)..."
        wget -O "$WORKDIR/x.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH_XRAY.zip"
        unzip -o "$WORKDIR/x.zip" -d "$WORKDIR" >/dev/null 2>&1
        chmod +x "$XRAY"
        rm -f "$WORKDIR/x.zip"
    fi
}

# ===============================================================
# 核心启动逻辑
# ===============================================================
run_xray(){
    [ ! -f "$TYPEF" ] && return
    local type=$(cat "$TYPEF")
    local port=$(cat "$PORTF")
    local uuid=$(cat "$UUIDF")

    if [[ "$type" == "argo" ]]; then
        local path=$(cat "$PATHF")
        cat > "$CONF" <<EOC
{
    "inbounds": [{
        "port": $port, "listen": "::", "protocol": "vless",
        "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
        "streamSettings": {"network": "ws", "wsSettings": {"path": "$path"}}
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOC
    else
        # Reality 配置
        local priv=$(cat "$PRIVF")
        local sid=$(cat "$SIDF")
        cat > "$CONF" <<EOC
{
    "inbounds": [{
        "port": $port, "listen": "::", "protocol": "vless",
        "settings": {"clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}], "decryption": "none"},
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": false, "dest": "www.microsoft.com:443", "xver": 0,
                "serverNames": ["www.microsoft.com"], "privateKey": "$priv", "shortIds": ["$sid"]
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOC
    fi

    pkill -9 xray >/dev/null 2>&1
    nohup "$XRAY" -config "$CONF" >/dev/null 2>&1 &
    
    sleep 2
    if pgrep -x "xray" > /dev/null; then
        echo "[!] Xray 进程启动成功 ($type)"
    else
        echo "[-] Xray 启动失败，请尝试手动运行查看错误: $XRAY -config $CONF"
    fi
}

run_argo(){
    [[ "$(cat "$TYPEF" 2>/dev/null)" != "argo" ]] && return
    
    local token=$(cat "$TOKENF")
    local ip_pref=$(cat "$IP_PREFF")
    local edge_arg=""
    [[ "$ip_pref" == "6" ]] && edge_arg="--edge-ip-version 6" || edge_arg="--edge-ip-version 4"

    pkill -9 cloudflared >/dev/null 2>&1
    # 强制协议设为 auto 以获得最佳兼容性
    nohup "$CF" tunnel --no-autoupdate $edge_arg --protocol auto --heartbeat-interval 10s run --token "$token" > "$WORKDIR/argo.log" 2>&1 &
    
    sleep 3
    if pgrep -x "cloudflared" > /dev/null; then
        echo "[!] Argo 隧道连接成功 (IPv$ip_pref 优先级)"
    else
        echo "[-] Argo 隧道启动失败，请检查日志: $WORKDIR/argo.log"
    fi
}

# ===============================================================
# 系统集成与管理
# ===============================================================
install_to_system() {
    # 复制自身到 /usr/local/bin
    if [ ! -f "$SCRIPT_PATH" ] || [ "$0" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi

    # Alpine OpenRC 服务支持
    if [ -d /etc/init.d ]; then
        cat > /etc/init.d/argo <<EOS
#!/sbin/openrc-run
depend() { after net dns; }
start() { $SCRIPT_PATH start; }
stop() { pkill -9 xray; pkill -9 cloudflared; }
EOS
        chmod +x /etc/init.d/argo
        rc-update add argo default >/dev/null 2>&1
    fi

    # 计划任务 (每5分钟保活)
    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH cron"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * $SCRIPT_PATH cron") | crontab -
    fi
}

show_config() {
    local type=$(cat "$TYPEF" 2>/dev/null)
    [ -z "$type" ] && echo "未检测到配置" && return
    
    echo -e "\n========== 当前节点信息 =========="
    local uuid=$(cat "$UUIDF")
    if [[ "$type" == "argo" ]]; then
        local domain=$(cat "$DOMAINF")
        local path=$(cat "$PATHF")
        echo "模式: Argo Tunnel (VLESS+WS)"
        echo "域名: $domain | 端口: 443"
        echo "链接: vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=$(echo $path | sed 's/\//%2F/g')#Argo-VLESS"
    else
        local port=$(cat "$PORTF")
        local pub=$(cat "$PUBF")
        local sid=$(cat "$SIDF")
        local myip=$(curl -s4m 5 https://api.ipify.org || curl -s6m 5 https://api64.ipify.org)
        echo "模式: VLESS-REALITY (Vision)"
        echo "地址: $myip | 端口: $port"
        echo "链接: vless://$uuid@$myip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$pub&sid=$sid#Reality-VLESS"
    fi
    echo "=================================="
}

# ===============================================================
# 主程序入口
# ===============================================================
case "$1" in
    install)
        fix_env
        echo "请选择部署类型:"
        echo "1. Cloudflare Argo Tunnel (VLESS+WS)"
        echo "2. VLESS-REALITY (直连+Vision)"
        read -p "选择 [1/2]: " m
        
        if [[ "$m" == "1" ]]; then
            echo "argo" > "$TYPEF"
            read -p "本地监听端口 (默认25600): " p; echo "${p:-25600}" > "$PORTF"
            read -p "解析域名 (与CF后台一致): " d; echo "$d" > "$DOMAINF"
            read -p "Tunnel Token: " t
            token=$(echo "$t" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
            [ -z "$token" ] && { echo "Token 识别错误"; exit 1; }
            echo "$token" > "$TOKENF"
            echo "/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)" > "$PATHF"
            read -p "优先 IP 版本 (4/6, 默认 4): " ip_v; echo "${ip_v:-4}" > "$IP_PREFF"
        else
            echo "reality" > "$TYPEF"
            read -p "Reality 端口 (默认 443): " p; echo "${p:-443}" > "$PORTF"
            download_bin # 为了生成密钥
            keys=$($XRAY x25519)
            echo "$keys" | grep "Private key:" | awk '{print $3}' > "$PRIVF"
            echo "$keys" | grep "Public key:" | awk '{print $3}' > "$PUBF"
            openssl rand -hex 8 > "$SIDF"
        fi
        
        cat /proc/sys/kernel/random/uuid > "$UUIDF"
        download_bin
        install_to_system
        run_xray
        [[ "$(cat "$TYPEF")" == "argo" ]] && run_argo
        show_config
        ;;
    start)
        run_xray
        run_argo
        ;;
    cron)
        pgrep -x "xray" > /dev/null || run_xray
        if [[ "$(cat "$TYPEF" 2>/dev/null)" == "argo" ]]; then
            pgrep -x "cloudflared" > /dev/null || run_argo
        fi
        ;;
    menu|*)
        if [ "$1" != "menu" ] && [ "$1" != "" ]; then shift; "$0" "$@"; exit; fi
        echo "--- Argo/Reality 管理工具 ---"
        echo "1. 重启服务"
        echo "2. 查看链接"
        echo "3. 查看日志"
        echo "4. 卸载"
        read -p "选择: " opt
        case "$opt" in
            1) "$SCRIPT_PATH" start ;;
            2) show_config ;;
            3) [ -f "$WORKDIR/argo.log" ] && tail -n 30 "$WORKDIR/argo.log" || echo "无日志" ;;
            4) 
                rc-update del argo >/dev/null 2>&1
                pkill -9 xray; pkill -9 cloudflared
                rm -rf "$WORKDIR" "$SCRIPT_PATH" /etc/init.d/argo
                sed -i "/argo cron/d" /var/spool/cron/crontabs/root 2>/dev/null
                echo "已卸载" ;;
            *) exit ;;
        esac
        ;;
esac
