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

mkdir -p $WORKDIR

# ==========================
# 纯 IPv6 环境修复
# ==========================
fix_env() {
    echo "[+] 正在配置纯 IPv6 网络环境..."
    
    # 1. 补全必要依赖 (ca-certificates 对 TLS 至关重要)
    apk add --no-cache curl wget unzip bash procps chrony ca-certificates >/dev/null 2>&1
    
    # 2. 强制设置 IPv6 DNS (解决 lookup 失败问题)
    cat > /etc/resolv.conf << EN_DNS
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8844
EN_DNS

    # 3. 网络就绪检测 (使用 IPv6 地址)
    local retry=0
    echo "[+] 正在检测 IPv6 连通性..."
    while ! ping -6 -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; do
        retry=$((retry + 1))
        [ $retry -gt 10 ] && { echo "[-] IPv6 网络不可用，请检查网络设置"; break; }
        sleep 3
    done

    # 4. 同步系统时间 (IPv6 模式)
    echo "[+] 同步系统时间..."
    chronyd -q 'server 2.alpine.pool.ntp.org iburst' >/dev/null 2>&1
}

get_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)       ARCH="amd64" ;;
    esac
}

# ==========================
# 组件下载与安装
# ==========================
download_bin(){
    get_arch
    echo "[+] 正在下载组件 (架构: $ARCH)..."
    
    # 下载 Cloudflared
    [ -f "$CF" ] && rm -f "$CF"
    wget -O $CF "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
    chmod +x $CF

    # 下载 Xray
    if [ ! -f "$XRAY" ]; then
        local XRAY_ARCH="64"
        [ "$ARCH" == "arm64" ] && XRAY_ARCH="arm64-v8a"
        wget -O $WORKDIR/x.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$XRAY_ARCH.zip"
        unzip -o $WORKDIR/x.zip -d $WORKDIR >/dev/null 2>&1
        chmod +x $XRAY
        rm -f $WORKDIR/x.zip
    fi
}

set_token(){
    echo "--- Cloudflare Tunnel Token ---"
    echo "请粘贴你的 Token (支持整段粘贴):"
    read -r input
    token=$(echo "$input" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
    if [ -z "$token" ]; then
        echo "[-] 未检测到有效 Token"
        set_token
    else
        echo "$token" > "$TOKENF"
    fi
}

# ==========================
# 进程管理逻辑
# ==========================
run_xray(){
    if ! pgrep -x "xray" > /dev/null; then
        nohup $XRAY -config $CONF >/dev/null 2>&1 &
        sleep 1
        echo "[!] Xray 进程已启动"
    fi
}

run_argo(){
    if ! pgrep -x "cloudflared" > /dev/null; then
        [ ! -f "$TOKENF" ] && return
        local token=$(cat "$TOKENF")
        # 针对纯 IPv6 强制参数: --edge-ip-version 6 和 --protocol http2
        nohup $CF tunnel --no-autoupdate \
            --edge-ip-version 6 \
            --protocol http2 \
            --heartbeat-interval 10s \
            run --token "$token" > "$WORKDIR/argo.log" 2>&1 &
        sleep 3
        pgrep -x "cloudflared" > /dev/null && echo "[!] Argo 隧道连接成功" || echo "[-] Argo 启动失败，请检查日志"
    fi
}

# ==========================
# 开机自启与保活 (参考 singbox-lite)
# ==========================
create_service(){
    cat > /etc/init.d/argo <<EOS
#!/sbin/openrc-run
description="Argo IPv6 Service"
depend() {
    after net dns
}
start() {
    /root/argo.sh start
}
stop() {
    pkill -9 xray
    pkill -9 cloudflared
}
EOS
    chmod +x /etc/init.d/argo
    rc-update add argo default >/dev/null 2>&1

    # 添加 crontab 每分钟保活
    if ! crontab -l 2>/dev/null | grep -q "argo.sh cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /root/argo.sh cron") | crontab -
    fi
}

# ==========================
# 命令入口
# ==========================
case "$1" in
    install)
        fix_env
        [ ! -f $UUIDF ] && cat /proc/sys/kernel/random/uuid > $UUIDF
        [ ! -f $PORTF ] && echo "8080" > $PORTF
        
        echo "--- 节点配置 ---"
        read -p "请输入你的解析域名: " d
        echo "$d" > $DOMAINF
        set_token
        
        download_bin
        
        # 写入配置
        port=$(cat $PORTF); uuid=$(cat $UUIDF)
        cat > $CONF <<EOC
{
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
        "streamSettings": {"network": "ws", "wsSettings": {"path": "/"}}
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOC
        create_service
        run_xray
        run_argo
        
        echo -e "\n======================"
        echo "部署完成 (IPv6 优化版)"
        echo "域名: $d"
        echo "UUID: $uuid"
        echo "链接: vless://$uuid@$d:443?encryption=none&security=tls&type=ws&host=$d&path=%2F#$d"
        echo "======================"
        ;;
    start)
        fix_env
        run_xray
        run_argo
        ;;
    cron)
        # 保活逻辑：如果进程没了就拉起来
        pgrep -x "xray" > /dev/null || run_xray
        pgrep -x "cloudflared" > /dev/null || { fix_env; run_argo; }
        ;;
    menu)
        echo "1. 重启服务"
        echo "2. 查看日志"
        echo "3. 卸载"
        read -p "请选择: " n
        case "$n" in
            1) pkill -9 xray; pkill -9 cloudflared; /root/argo.sh start ;;
            2) tail -f "$WORKDIR/argo.log" ;;
            3) rc-update del argo; pkill -9 xray; pkill -9 cloudflared; rm -rf $WORKDIR /etc/init.d/argo; echo "已彻底卸载" ;;
        esac
        ;;
esac
EOF

chmod +x /root/argo.sh
/root/argo.sh install
