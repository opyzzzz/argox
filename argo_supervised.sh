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
# 纯 IPv6 环境深度修复
# ==========================
fix_env() {
    echo "[+] 正在进行纯 IPv6 环境加固..."
    
    # 1. 强制安装根证书和必要工具 (没有证书 CF 必离线)
    apk add --no-cache curl wget unzip bash procps chrony ca-certificates >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1

    # 2. 注入 NAT64 + IPv6 DNS (解决纯v6访问v4资源失败)
    cat > /etc/resolv.conf << EN_DNS
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
nameserver 2a00:1098:2c::1
nameserver 2a01:4f8:c2c:123f::1
EN_DNS

    # 3. 连通性检测
    local retry=0
    while ! ping -6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; do
        retry=$((retry + 1))
        [ $retry -gt 5 ] && break
        sleep 2
    done

    # 4. 强制同步时间 (TLS 握手核心)
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
# 下载与配置
# ==========================
download_bin(){
    get_arch
    echo "[+] 检测到架构: $ARCH，正在下载组件..."
    
    # 下载 Cloudflared
    [ -f "$CF" ] && rm -f "$CF"
    wget -O $CF "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
    chmod +x $CF

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
        echo "[!] Xray 进程启动成功"
    fi
}

run_argo(){
    if ! pgrep -x "cloudflared" > /dev/null; then
        local token=$(cat $TOKENF)
        # 强制 IPv6 和 http2 协议，增加稳定心跳
        nohup $CF tunnel --no-autoupdate \
            --edge-ip-version 6 \
            --protocol http2 \
            --heartbeat-interval 10s \
            run --token "$token" > "$WORKDIR/argo.log" 2>&1 &
        
        sleep 5
        if pgrep -x "cloudflared" > /dev/null; then
            echo "[!] Argo 隧道连接成功 (IPv6)"
        else
            echo "[-] Argo 启动失败，请检查日志: cat $WORKDIR/argo.log"
        fi
    fi
}

# ==========================
# 启动与保活
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
        (crontab -l 2>/dev/null; echo "* * * * * /root/argo.sh cron") | crontab -
    fi
}

# ==========================
# 主指令执行
# ==========================
case "$1" in
    install)
        fix_env
        read -p "请输入本地监听端口 (默认8080): " p
        echo "${p:-8080}" > $PORTF
        read -p "请输入解析域名: " d
        echo "$d" > $DOMAINF
        echo "请输入 Tunnel Token:"
        read -r t
        token=$(echo "$t" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
        [ -z "$token" ] && { echo "Token识别错误"; exit 1; }
        echo "$token" > $TOKENF
        
        # 随机参数只生成一次并保存
        cat /proc/sys/kernel/random/uuid > $UUIDF
        echo "/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)" > $PATHF
        
        download_bin
        create_service
        run_xray
        run_argo
        
        uuid=$(cat $UUIDF); path=$(cat $PATHF); domain=$(cat $DOMAINF)
        echo -e "\n========== 节点部署成功 =========="
        echo "架构: $ARCH | 环境: IPv6-Only"
        echo "域名: $domain"
        echo "UUID: $uuid"
        echo "路径: $path"
        echo "----------------------------------"
        echo "链接: vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=$(echo $path | sed 's/\//%2F/g')#$domain"
        echo "=================================="
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
            3) rc-update del argo; pkill -9 xray; pkill -9 cloudflared; rm -rf $WORKDIR; echo "卸载完成" ;;
        esac
        ;;
esac
EOF

chmod +x /root/argo.sh
/root/argo.sh install
