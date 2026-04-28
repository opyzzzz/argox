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
# 系统环境修复 (DNS / 时间 / 网络)
# ==========================
fix_network_env() {
    echo "[+] 正在优化网络环境..."
    
    # 1. 修复 DNS 配置 (防止 [::1]:53 拒绝连接)
    cat > /etc/resolv.conf << EN_DNS
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
EN_DNS

    # 2. 等待网络完全就绪 (最长等待 30 秒)
    local retry=0
    while ! ping -c 1 -W 2 google.com >/dev/null 2>&1; do
        retry=$((retry + 1))
        [ $retry -gt 15 ] && { echo "[-] 网络连接超时"; break; }
        echo "[...] 等待网络连接 ($retry/15)"
        sleep 2
    done

    # 3. 时间校准 (TLS 握手必须)
    sync_time
}

sync_time() {
    echo "[+] 正在同步系统时间..."
    # 确保安装了 chrony
    if ! command -v chronyd >/dev/null 2>&1; then
        apk add --no-cache chrony >/dev/null 2>&1
    fi
    
    # 停止服务模式，强制执行单次同步
    # 使用多个 NTP 服务器以提高成功率
    chronyd -q 'server pool.ntp.org iburst' 'server time.apple.com iburst' 'server ntp.aliyun.com iburst' >/dev/null 2>&1
    
    echo "[!] 当前系统时间: $(date)"
}

# ==========================
# 基础安装
# ==========================
install_base(){
    echo "[+] 安装必要依赖..."
    apk add --no-cache curl wget unzip bash procps chrony >/dev/null 2>&1
}

gen_uuid(){ [ ! -f $UUIDF ] && cat /proc/sys/kernel/random/uuid > $UUIDF; }

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

download_bin(){
    echo "[+] 检查并下载组件..."
    [ ! -f "$CF" ] && wget -O $CF https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x $CF
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
# 进程管理
# ==========================
run_xray(){
    if ! pgrep -x "xray" > /dev/null; then
        nohup $XRAY -config $CONF >/dev/null 2>&1 &
        echo "[!] Xray 进程已启动"
    fi
}

run_argo(){
    if ! pgrep -x "cloudflared" > /dev/null; then
        token=$(cat $TOKENF)
        nohup $CF tunnel --no-autoupdate \
            --edge-ip-version auto \
            --protocol http2 \
            --heartbeat-interval 10s \
            --heartbeat-count 2 \
            run --token $token > $WORKDIR/argo.log 2>&1 &
        echo "[!] Cloudflared 进程已启动"
    fi
}

stop_all(){
    pkill -9 xray 2>/dev/null
    pkill -9 cloudflared 2>/dev/null
    echo "[!] 所有进程已停止"
}

# ==========================
# 保活 & 开机自启
# ==========================
keep_alive(){
    fix_network_env
    pgrep -x "xray" > /dev/null || run_xray
    pgrep -x "cloudflared" > /dev/null || run_argo
}

create_service(){
    cat > /etc/init.d/argo <<EOS
#!/sbin/openrc-run
description="Argo with Xray Service"

depend() {
    after net dns
}

start() {
    ebegin "Starting Argo"
    /root/argo.sh start
    eend \$?
}

stop() {
    ebegin "Stopping Argo"
    /root/argo.sh stop
    eend \$?
}
EOS
    chmod +x /etc/init.d/argo
    rc-update add argo default >/dev/null 2>&1

    if ! crontab -l 2>/dev/null | grep -q "argo.sh cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /root/argo.sh cron") | crontab -
    fi
}

# ==========================
# 菜单界面
# ==========================
show_info(){
    [ ! -f $UUIDF ] && return
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
    echo "======================"
    echo "节点链接："
    echo "vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=%2F#$domain"
}

menu(){
    clear
    echo "===== Argo 管理菜单 ====="
    echo "状态: $(pgrep -x "xray" >/dev/null && echo -n "Xray运行中 " || echo -n "Xray停止 ") | $(pgrep -x "cloudflared" >/dev/null && echo "Argo运行中" || echo "Argo停止")"
    echo "------------------------"
    echo "1. 查看节点信息"
    echo "2. 修改配置并重启"
    echo "3. 启动服务"
    echo "4. 停止服务"
    echo "5. 查看日志"
    echo "6. 强制同步时间"
    echo "7. 卸载"
    echo "0. 退出"
    read -p "选择: " n
    case "$n" in
        1) show_info ;;
        2) set_port; set_domain; set_token; write_conf; stop_all; fix_network_env; run_xray; run_argo ;;
        3) fix_network_env; run_xray; run_argo ;;
        4) stop_all ;;
        5) tail -f $WORKDIR/argo.log ;;
        6) sync_time ;;
        7) stop_all; rc-update del argo; crontab -l | grep -v "argo.sh cron" | crontab -; rm -rf $WORKDIR; rm -f /etc/init.d/argo; echo "已卸载" ;;
        0) exit ;;
    esac
}

# ==========================
# 命令入口
# ==========================
case "$1" in
    install)
        install_base
        gen_uuid
        set_port
        set_domain
        set_token
        download_bin
        write_conf
        create_service
        fix_network_env
        run_xray
        run_argo
        show_info
        echo "alias argo='bash /root/argo.sh menu'" >> /etc/profile
        ;;
    start)
        fix_network_env
        run_xray
        run_argo
        ;;
    stop)
        stop_all
        ;;
    cron)
        keep_alive
        ;;
    menu)
        menu
        ;;
    *)
        echo "用法: $0 {install|menu|start|stop|cron}"
        ;;
esac
EOF

chmod +x /root/argo.sh
/root/argo.sh install
