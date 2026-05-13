#!/bin/bash

# ==========================
# 变量定义
# ==========================
WORKDIR="/root/argo"
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
TYPEF="$WORKDIR/type" # 记录节点类型: argo 或 reality

mkdir -p $WORKDIR

# ==========================
# 环境检测与修复
# ==========================
fix_env() {
    echo "[+] 检查运行环境..."
    # 基础工具安装
    apk add --no-cache curl wget unzip bash procps chrony ca-certificates openssl >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
    
    # 强制同步时间 (Reality 对时间要求极高)
    chronyd -q 'server pool.ntp.org iburst' >/dev/null 2>&1

    # 检测 IP 优先级
    V4=$(curl -s4m 5 https://api.ipify.org || echo "")
    V6=$(curl -s6m 5 https://api64.ipify.org || echo "")

    echo "[!] 检测到本地 IP: IPv4=[$V4] IPv6=[$V6]"
    
    # 如果没指定过，默认优先 IPv4
    if [ ! -f "$IP_PREFF" ]; then
        if [ -n "$V4" ]; then
            echo "4" > $IP_PREFF
        else
            echo "6" > $IP_PREFF
        fi
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
    echo "[+] 系统架构: $ARCH, 正在下载核心组件..."
    
    # 下载 Cloudflared
    if [[ "$(cat $TYPEF)" == "argo" ]]; then
        [ ! -f "$CF" ] && wget -O $CF "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
        chmod +x $CF
    fi

    # 下载 Xray
    if [ ! -f "$XRAY" ]; then
        local X_ARCH="64"
        [[ "$ARCH" == "arm64" ]] && X_ARCH="arm64-v8a"
        wget -O $WORKDIR/x.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$X_ARCH.zip"
        unzip -o $WORKDIR/x.zip -d $WORKDIR >/dev/null 2>&1
        chmod +x $XRAY
        rm -f $WORKDIR/x.zip
    fi
}

# ==========================
# 核心运行逻辑
# ==========================

run_xray(){
    local type=$(cat $TYPEF)
    local port=$(cat $PORTF)
    local uuid=$(cat $UUIDF)

    if [[ "$type" == "argo" ]]; then
        local path=$(cat $PATHF)
        cat > $CONF <<EOC
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
        local priv_key=$(cat $WORKDIR/priv)
        local pub_key=$(cat $WORKDIR/pub)
        local sid=$(cat $WORKDIR/sid)
        local sni="www.microsoft.com"
        cat > $CONF <<EOC
{
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
                "show": false, "dest": "$sni:443", "xver": 0,
                "serverNames": ["$sni"],
                "privateKey": "$priv_key",
                "shortIds": ["$sid"]
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOC
    fi

    pkill -x xray
    nohup $XRAY -config $CONF >/dev/null 2>&1 &
    echo "[!] Xray ($type) 启动成功"
}

run_argo(){
    [[ "$(cat $TYPEF)" != "argo" ]] && return
    
    local token=$(cat $TOKENF)
    local ip_pref=$(cat $IP_PREFF)
    
    pkill -x cloudflared
    # 移除 --edge-ip-version 强制，改用参数控制
    local edge_arg=""
    [[ "$ip_pref" == "6" ]] && edge_arg="--edge-ip-version 6"
    [[ "$ip_pref" == "4" ]] && edge_arg="--edge-ip-version 4"

    nohup $CF tunnel --no-autoupdate \
        $edge_arg \
        --protocol http2 \
        --heartbeat-interval 10s \
        run --token "$token" > "$WORKDIR/argo.log" 2>&1 &
    
    sleep 5
    if pgrep -x "cloudflared" > /dev/null; then
        echo "[!] Argo 隧道已建立 (IPv$ip_pref 优先)"
    else
        echo "[-] Argo 启动失败，请检查日志。尝试切换 IPv4/IPv6 或检查 Token。"
    fi
}

# ==========================
# 安装函数
# ==========================

install_argo() {
    echo "argo" > $TYPEF
    read -p "请输入本地监听端口 (默认8080): " p
    echo "${p:-8080}" > $PORTF
    read -p "请输入 Cloudflare 解析域名: " d
    echo "$d" > $DOMAINF
    read -p "请输入 Tunnel Token: " t
    token=$(echo "$t" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
    [ -z "$token" ] && { echo "Token识别错误"; exit 1; }
    echo "$token" > $TOKENF
    
    echo "请选择连接 Cloudflare 的优先级:"
    echo "1. 默认 (IPv4)"
    echo "2. 强制 (IPv6)"
    read -p "选择 [1/2]: " ip_choice
    [[ "$ip_choice" == "2" ]] && echo "6" > $IP_PREFF || echo "4" > $IP_PREFF

    cat /proc/sys/kernel/random/uuid > $UUIDF
    echo "/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)" > $PATHF
    
    download_bin
    run_xray
    run_argo
    
    # 打印 Argo 节点信息
    echo -e "\n========== Argo 节点配置 =========="
    echo "域名: $(cat $DOMAINF)"
    echo "UUID: $(cat $UUIDF)"
    echo "路径: $(cat $PATHF)"
    echo "链接: vless://$(cat $UUIDF)@$(cat $DOMAINF):443?encryption=none&security=tls&type=ws&host=$(cat $DOMAINF)&path=$(sed 's/\//%2F/g' $PATHF)#Argo-VLESS"
}

install_reality() {
    echo "reality" > $TYPEF
    read -p "请输入 Reality 监听端口 (默认443): " p
    echo "${p:-443}" > $PORTF
    
    # 生成 Reality 密钥
    download_bin # 需要 xray 来生成密钥
    keys=$($XRAY x25519)
    echo "$keys" | grep "Private key:" | awk '{print $3}' > $WORKDIR/priv
    echo "$keys" | grep "Public key:" | awk '{print $3}' > $WORKDIR/pub
    openssl rand -hex 8 > $WORKDIR/sid
    cat /proc/sys/kernel/random/uuid > $UUIDF
    
    run_xray
    
    # 获取当前公网 IP
    local myip=$(curl -s4m 5 https://api.ipify.org || curl -s6m 5 https://api64.ipify.org)
    
    echo -e "\n========== Reality 节点配置 =========="
    echo "地址: $myip"
    echo "端口: $(cat $PORTF)"
    echo "UUID: $(cat $UUIDF)"
    echo "PublicKey: $(cat $WORKDIR/pub)"
    echo "ShortID: $(cat $WORKDIR/sid)"
    echo "SNI: www.microsoft.com"
    echo "--------------------------------------"
    echo "链接: vless://$(cat $UUIDF)@$myip:$(cat $PORTF)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$(cat $WORKDIR/pub)&sid=$(cat $WORKDIR/sid)#Reality-VLESS"
}

# ==========================
# 菜单与保活
# ==========================

create_service(){
    cat > /etc/init.d/argo <<EOS
#!/sbin/openrc-run
depend() { after net dns; }
start() { /root/argo.sh start; }
stop() { pkill -9 xray; pkill -9 cloudflared; }
EOS
    chmod +x /etc/init.d/argo
    rc-update add argo default >/dev/null 2>&1
    if ! crontab -l 2>/dev/null | grep -q "argo.sh cron"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * /root/argo.sh cron") | crontab -
    fi
}

case "$1" in
    install)
        fix_env
        echo "请选择部署类型:"
        echo "1. Cloudflare Argo Tunnel (VLESS+WS)"
        echo "2. VLESS-REALITY (直连+Vision)"
        read -p "选择: " m
        if [[ "$m" == "1" ]]; then install_argo; else install_reality; fi
        create_service
        ;;
    start)
        fix_env
        run_xray
        [[ "$(cat $TYPEF)" == "argo" ]] && run_argo
        ;;
    cron)
        pgrep -x "xray" > /dev/null || $0 start
        if [[ "$(cat $TYPEF)" == "argo" ]]; then
             pgrep -x "cloudflared" > /dev/null || $0 start
        fi
        ;;
    menu)
        echo "---------- 节点管理菜单 ----------"
        echo "1. 重启服务"
        echo "2. 查看 Argo 日志 (仅限Tunnel模式)"
        echo "3. 查看当前连接链接"
        echo "4. 彻底卸载"
        read -p "请选择 [1-4]: " n
        case "$n" in
            1) $0 start ;;
            2) [ -f "$WORKDIR/argo.log" ] && tail -n 20 "$WORKDIR/argo.log" || echo "无日志文件" ;;
            3)
                type=$(cat $TYPEF)
                if [[ "$type" == "argo" ]]; then
                    echo "vless://$(cat $UUIDF)@$(cat $DOMAINF):443?encryption=none&security=tls&type=ws&host=$(cat $DOMAINF)&path=$(sed 's/\//%2F/g' $PATHF)#Argo-VLESS"
                else
                    myip=$(curl -s4m 5 https://api.ipify.org || curl -s6m 5 https://api64.ipify.org)
                    echo "vless://$(cat $UUIDF)@$myip:$(cat $PORTF)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$(cat $WORKDIR/pub)&sid=$(cat $WORKDIR/sid)#Reality-VLESS"
                fi
                ;;
            4)
                rc-update del argo >/dev/null 2>&1
                pkill -9 xray; pkill -9 cloudflared
                rm -rf $WORKDIR
                sed -i '/argo.sh cron/d' /var/spool/cron/crontabs/root 2>/dev/null
                echo "卸载完成"
                ;;
        esac
        ;;
    *)
        echo "用法: $0 {install|start|menu}"
        ;;
esac
