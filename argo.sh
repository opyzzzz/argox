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
# 环境检查与安装工具
# ===============================================================
fix_env() {
    echo "[+] 正在检查并优化系统环境..."
    
    # 针对 Alpine 系统安装必要依赖
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache curl wget unzip bash procps chrony ca-certificates openssl >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
        rc-update add chronyd default >/dev/null 2>&1
        service chronyd start >/dev/null 2>&1
    fi

    # 同步时间 (Reality 对时间偏差非常敏感)
    chronyd -q 'server pool.ntp.org iburst' >/dev/null 2>&1

    # IP 优先级检测
    local v4=$(curl -s4m 5 https://api.ipify.org || echo "")
    local v6=$(curl -s6m 5 https://api64.ipify.org || echo "")
    
    if [ ! -f "$IP_PREFF" ]; then
        [ -n "$v4" ] && echo "4" > "$IP_PREFF" || echo "6" > "$IP_PREFF"
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)       ARCH="amd64" ;;
    esac
}

download_bin(){
    get_arch
    local node_type=$(cat "$TYPEF" 2>/dev/null)
    
    # 下载 Cloudflared (仅在 Argo 模式需要)
    if [[ "$node_type" == "argo" && ! -f "$CF" ]]; then
        echo "[+] 下载 Cloudflared ($ARCH)..."
        wget -O "$CF" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
        chmod +x "$CF"
    fi

    # 下载 Xray
    if [ ! -f "$XRAY" ]; then
        echo "[+] 下载 Xray-core ($ARCH)..."
        local x_arch="64"
        [[ "$ARCH" == "arm64" ]] && x_arch="arm64-v8a"
        wget -O "$WORKDIR/x.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$x_arch.zip"
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
        "port": $port, "listen": "127.0.0.1", "protocol": "vless",
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
        "port": $port, "protocol": "vless",
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
    echo "[!] Xray 进程已启动 ($type)"
}

run_argo(){
    [[ "$(cat "$TYPEF" 2>/dev/null)" != "argo" ]] && return
    
    local token=$(cat "$TOKENF")
    local ip_pref=$(cat "$IP_PREFF")
    local edge_arg=""
    [[ "$ip_pref" == "6" ]] && edge_arg="--edge-ip-version 6" || edge_arg="--edge-ip-version 4"

    pkill -9 cloudflared >/dev/null 2>&1
    nohup "$CF" tunnel --no-autoupdate $edge_arg --protocol http2 --heartbeat-interval 10s run --token "$token" > "$WORKDIR/argo.log" 2>&1 &
    
    sleep 3
    pgrep -x "cloudflared" > /dev/null && echo "[!] Argo 隧道已连接 (IPv$ip_pref)" || echo "[-] Argo 启动失败，请检查日志: $WORKDIR/argo.log"
}

# ===============================================================
# 系统集成 (快捷命令与服务)
# ===============================================================
install_to_system() {
    # 将脚本自身移动到系统路径
    if [ "$0" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi

    # 创建 OpenRC 服务 (针对 Alpine)
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

    # 计划任务保活 (纠正了路径)
    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH cron"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * $SCRIPT_PATH cron") | crontab -
    fi
}

# ===============================================================
# 交互菜单功能
# ===============================================================
show_config() {
    local type=$(cat "$TYPEF" 2>/dev/null)
    [ -z "$type" ] && echo "未发现已安装的配置" && return
    
    echo -e "\n--- 当前配置信息 ---"
    if [[ "$type" == "argo" ]]; then
        local uuid=$(cat "$UUIDF")
        local domain=$(cat "$DOMAINF")
        local path=$(cat "$PATHF")
        echo "模式: Cloudflare Argo"
        echo "链接: vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=$(echo $path | sed 's/\//%2F/g')#Argo-VLESS"
    else
        local uuid=$(cat "$UUIDF")
        local port=$(cat "$PORTF")
        local pub=$(cat "$PUBF")
        local sid=$(cat "$SIDF")
        local myip=$(curl -s4m 5 https://api.ipify.org || curl -s6m 5 https://api64.ipify.org)
        echo "模式: VLESS-REALITY"
        echo "链接: vless://$uuid@$myip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$pub&sid=$sid#Reality-VLESS"
    fi
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
            read -p "本地监听端口 (默认8080): " p; echo "${p:-8080}" > "$PORTF"
            read -p "解析域名: " d; echo "$d" > "$DOMAINF"
            read -p "Tunnel Token: " t
            token=$(echo "$t" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
            [ -z "$token" ] && { echo "Token错误"; exit 1; }
            echo "$token" > "$TOKENF"
            echo "/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)" > "$PATHF"
            read -p "优先IP版本 (4/6, 默认4): " ip_v; echo "${ip_v:-4}" > "$IP_PREFF"
        else
            echo "reality" > "$TYPEF"
            read -p "Reality 端口 (默认443): " p; echo "${p:-443}" > "$PORTF"
            download_bin
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
        if [ "$1" != "menu" ] && [ "$1" != "" ]; then 
            # 允许直接执行 argo start 等
            shift; "$0" "$@"; exit
        fi
        echo "========== Argo/Reality 管理工具 =========="
        echo "1. 重启服务"
        echo "2. 查看当前节点链接"
        echo "3. 查看 Argo 日志"
        echo "4. 重新安装/切换模式"
        echo "5. 彻底卸载"
        echo "0. 退出"
        read -p "请选择: " opt
        case "$opt" in
            1) "$SCRIPT_PATH" start ;;
            2) show_config ;;
            3) [ -f "$WORKDIR/argo.log" ] && tail -n 50 "$WORKDIR/argo.log" || echo "无日志" ;;
            4) "$SCRIPT_PATH" install ;;
            5)
                rc-update del argo >/dev/null 2>&1
                pkill -9 xray; pkill -9 cloudflared
                rm -rf "$WORKDIR" "$SCRIPT_PATH" /etc/init.d/argo
                sed -i "/argo cron/d" /var/spool/cron/crontabs/root 2>/dev/null
                echo "卸载完成。"
                ;;
            *) exit ;;
        esac
        ;;
esac
