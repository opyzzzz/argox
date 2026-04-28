cat > /root/argo.sh << 'EOF'
#!/bin/bash

# ==========================
# 变量定义
# ==========================
WORKDIR="/root/argo"
CF="$WORKDIR/cloudflared"
XRAY="$WORKDIR/xray"
CONF="$WORKDIR/config.json"

UUIDF="$WORKDIR/uuid"
PORTF="$WORKDIR/port"
DOMAINF="$WORKDIR/domain"
TOKENF="$WORKDIR/token"
PATHF="$WORKDIR/path"

mkdir -p $WORKDIR

# ==========================
# 系统环境修复 (针对纯 IPv6)
# ==========================
fix_env() {
    echo "[+] 正在配置纯 IPv6 网络环境..."
    apk add --no-cache curl wget unzip bash procps chrony ca-certificates >/dev/null 2>&1
    
    # 修复 DNS
    cat > /etc/resolv.conf << EN_DNS
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
EN_DNS

    # 网络连通性检测
    local retry=0
    while ! ping -6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; do
        retry=$((retry + 1))
        [ $retry -gt 10 ] && break
        sleep 3
    done

    # 时间同步
    chronyd -q 'server pool.ntp.org iburst' >/dev/null 2>&1
}

get_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)       ARCH="amd64" ;;
    esac
}

# ==========================
# 下载与安装
# ==========================
download_bin(){
    get_arch
    echo "[+] 下载组件 (架构: $ARCH)..."
    [ -f "$CF" ] && rm -f "$CF"
    wget -O $CF "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
    chmod +x $CF

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
# 随机参数生成
# ==========================
gen_random_params(){
    # 生成随机 UUID
    cat /proc/sys/kernel/random/uuid > $UUIDF
    # 生成随机路径 (8位随机字母数字)
    echo "/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)" > $PATHF
    echo "[+] 已生成随机 UUID 和 WebSocket 路径"
}

# ==========================
# 运行逻辑
# ==========================
run_xray(){
    if ! pgrep -x "xray" > /dev/null; then
        local port=$(cat $PORTF)
        local uuid=$(cat $UUIDF)
        local path=$(cat $PATHF)
        
        cat > $CONF <<EOC
{
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
        "streamSettings": {"network": "ws", "wsSettings": {"path": "$path"}}
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOC
        nohup $XRAY -config $CONF >/dev/null 2>&1 &
        echo "[!] Xray 启动成功"
    fi
}

run_argo(){
    if ! pgrep -x "cloudflared" > /dev/null; then
        local token=$(cat $TOKENF)
        nohup $CF tunnel --no-autoupdate \
            --edge-ip-version 6 \
            --protocol http2 \
            run --token "$token" > "$WORKDIR/argo.log" 2>&1 &
        sleep 3
        pgrep -x "cloudflared" > /dev/null && echo "[!] Argo 隧道已上线"
    fi
}

# ==========================
# 保活与自启
# ==========================
create_service(){
    # OpenRC 服务
    cat > /etc/init.d/argo <<EOS
#!/sbin/openrc-run
depend() { after net dns; }
start() { /root/argo.sh start; }
stop() { pkill -9 xray; pkill -9 cloudflared; }
EOS
    chmod +x /etc/init.d/argo
    rc-update add argo default >/dev/null 2>&1

    # Cron 保活
    if ! crontab -l 2>/dev/null | grep -q "argo.sh cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /root/argo.sh cron") | crontab -
    fi
}

# ==========================
# 主流程
# ==========================
case "$1" in
    install)
        fix_env
        read -p "请输入本地监听端口 (如8080): " p
        echo "${p:-8080}" > $PORTF
        read -p "请输入你的解析域名: " d
        echo "$d" > $DOMAINF
        echo "请输入 Tunnel Token:"
        read -r t
        token=$(echo "$t" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
        [ -z "$token" ] && { echo "Token无效"; exit 1; }
        echo "$token" > $TOKENF
        
        gen_random_params
        download_bin
        create_service
        run_xray
        run_argo
        
        uuid=$(cat $UUIDF); path=$(cat $PATHF); domain=$(cat $DOMAINF)
        echo -e "\n========== 节点信息 =========="
        echo "域名: $domain"
        echo "UUID: $uuid"
        echo "路径: $path"
        echo "端口: 443 (TLS)"
        echo -e "------------------------------"
        echo "链接: vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=$(echo $path | sed 's/\//%2F/g')#$domain"
        echo "=============================="
        ;;
    start)
        fix_env
        run_xray
        run_argo
        ;;
    cron)
        pgrep -x "xray" > /dev/null || run_xray
        pgrep -x "cloudflared" > /dev/null || { fix_env; run_argo; }
        ;;
    menu)
        echo "1. 重启服务  2. 查看日志  3. 卸载"
        read -p "选择: " n
        case "$n" in
            1) pkill -9 xray; pkill -9 cloudflared; /root/argo.sh start ;;
            2) tail -f "$WORKDIR/argo.log" ;;
            3) rc-update del argo; pkill -9 xray; pkill -9 cloudflared; rm -rf $WORKDIR; echo "已卸载" ;;
        esac
        ;;
esac
EOF

chmod +x /root/argo.sh
/root/argo.sh install
