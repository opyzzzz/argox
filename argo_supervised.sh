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

# 创建目录
mkdir -p $WORKDIR

# ==========================
# 基础工具安装
# ==========================
install_base(){
    echo "[+] 安装基础依赖..."
    apk add --no-cache curl wget unzip bash procps >/dev/null 2>&1
}

# ==========================
# 配置逻辑
# ==========================
gen_uuid(){
    [ ! -f $UUIDF ] && cat /proc/sys/kernel/random/uuid > $UUIDF
}

set_port(){
    read -p "请输入本地端口 (默认8080): " p
    [ -z "$p" ] && p=8080
    echo $p > $PORTF
}

set_domain(){
    read -p "请输入域名 (必须已接入CF): " d
    [ -z "$d" ] && echo "域名不能为空" && exit 1
    echo $d > $DOMAINF
}

set_token(){
    echo "粘贴 Tunnel Token (支持整段复制):"
    read input
    token=$(echo "$input" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
    if [ -z "$token" ]; then
        echo "[-] Token 识别失败"
        set_token
    else
        echo $token > $TOKENF
    fi
}

# ==========================
# 下载逻辑 (带校验)
# ==========================
download_bin(){
    echo "[+] 正在下载组件..."
    # 下载 Cloudflared
    if [ ! -f "$CF" ]; then
        wget -O $CF https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x $CF
    fi
    # 下载 Xray
    if [ ! -f "$XRAY" ]; then
        wget -O $WORKDIR/x.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
        unzip -o $WORKDIR/x.zip -d $WORKDIR >/dev/null 2>&1
        chmod +x $XRAY
        rm -f $WORKDIR/x.zip
    fi
}

write_conf(){
    port=$(cat $PORTF)
    uuid=$(cat $UUIDF)
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
}

# ==========================
# 进程管理 (关键改进)
# ==========================
run_xray(){
    if ! pgrep -x "xray" > /dev/null; then
        nohup $XRAY -config $CONF >/dev/null 2>&1 &
        sleep 1
        echo "[!] Xray 已启动"
    fi
}

run_argo(){
    if ! pgrep -x "cloudflared" > /dev/null; then
        token=$(cat $TOKENF)
        nohup $CF tunnel --no-autoupdate --edge-ip-version 6 --protocol http2 run --token $token > $WORKDIR/argo.log 2>&1 &
        sleep 1
        echo "[!] Cloudflared 已启动"
    fi
}

stop_all(){
    pkill -9 xray 2>/dev/null
    pkill -9 cloudflared 2>/dev/null
    echo "[!] 服务已停止"
}

# ==========================
# 保活逻辑 (类似 singbox-lite)
# ==========================
keep_alive(){
    # 检查 Xray
    pgrep -x "xray" > /dev/null || run_xray
    # 检查 Cloudflared
    pgrep -x "cloudflared" > /dev/null || run_argo
}

# ==========================
# 开机自启 (OpenRC)
# ==========================
create_service(){
    cat > /etc/init.d/argo <<EOS
#!/sbin/openrc-run
description="Argo with Xray Service"

depend() {
    need net
    after firewall
}

start() {
    ebegin "Starting Argo Service"
    /root/argo.sh start
    eend \$?
}

stop() {
    ebegin "Stopping Argo Service"
    /root/argo.sh stop
    eend \$?
}
EOS
    chmod +x /etc/init.d/argo
    rc-update add argo default >/dev/null 2>&1
    
    # 添加 Crontab 保活 (每分钟检查一次)
    if ! crontab -l 2>/dev/null | grep -q "argo.sh cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /root/argo.sh cron") | crontab -
    fi
}

# ==========================
# 信息展示
# ==========================
show_status(){
    echo "--- 进程状态 ---"
    pgrep -x "xray" >/dev/null && echo "Xray: 运行中" || echo "Xray: 已停止"
    pgrep -x "cloudflared" >/dev/null && echo "Argo: 运行中" || echo "Argo: 已停止"
}

show_info(){
    uuid=$(cat $UUIDF)
    domain=$(cat $DOMAINF)
    port=$(cat $PORTF)
    echo -e "\n======================"
    echo "VLESS 节点信息"
    echo "地址: $domain"
    echo "端口: 443"
    echo "UUID: $uuid"
    echo "路径: /"
    echo "TLS: 开启"
    echo "本地端口: $port"
    echo "======================"
    echo "节点链接："
    echo "vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=%2F#$domain"
}

# ==========================
# 安装 & 菜单
# ==========================
install_all(){
    install_base
    gen_uuid
    set_port
    set_domain
    set_token
    download_bin
    write_conf
    create_service
    run_xray
    run_argo
    show_info
    echo "alias argo='bash /root/argo.sh menu'" >> /etc/profile
    echo -e "\n[+] 安装完成，输入 'argo' 呼出菜单"
}

menu(){
    clear
    echo "===== Argo 管理菜单 ====="
    show_status
    echo "------------------------"
    echo "1. 查看节点信息"
    echo "2. 修改配置 (端口/域名/Token)"
    echo "3. 重启服务"
    echo "4. 停止服务"
    echo "5. 查看 Argo 日志"
    echo "6. 卸载"
    echo "0. 退出"
    read -p "选择: " n
    case "$n" in
        1) show_info ;;
        2) set_port; set_domain; set_token; write_conf; stop_all; run_xray; run_argo ;;
        3) stop_all; run_xray; run_argo ;;
        4) stop_all ;;
        5) tail -f $WORKDIR/argo.log ;;
        6) stop_all; rc-update del argo; crontab -l | grep -v "argo.sh cron" | crontab -; rm -rf $WORKDIR; rm -f /etc/init.d/argo; echo "已卸载" ;;
        0) exit ;;
    esac
}

# 命令分发
case "$1" in
    install) install_all ;;
    menu)    menu ;;
    start)   run_xray; run_argo ;;
    stop)    stop_all ;;
    cron)    keep_alive ;;
    *)       echo "用法: $0 {install|menu|start|stop|cron}" ;;
esac
EOF

chmod +x /root/argo.sh
/root/argo.sh install
