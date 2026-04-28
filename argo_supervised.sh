#!/bin/sh

WORKDIR="/root/argo"
CF="$WORKDIR/cloudflared"
XRAY="$WORKDIR/xray"
CONF="$WORKDIR/config.json"

UUIDF="$WORKDIR/uuid"
PORTF="$WORKDIR/port"
DOMAINF="$WORKDIR/domain"
TOKENF="$WORKDIR/token"

CF_WRAP="$WORKDIR/cf.sh"

mkdir -p "$WORKDIR"

install_base(){
  apk add --no-cache curl wget unzip >/dev/null 2>&1
}

gen_uuid(){
  [ ! -f "$UUIDF" ] && cat /proc/sys/kernel/random/uuid > "$UUIDF"
}

set_port(){
  read -p "端口(默认8080): " p
  [ -z "$p" ] && p=8080
  echo "$p" > "$PORTF"
}

set_domain(){
  read -p "域名(必须已接入CF): " d
  echo "$d" > "$DOMAINF"
}

set_token(){
  echo "粘贴Tunnel Token:"
  read input
  token=$(echo "$input" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)

  [ -z "$token" ] && echo "Token错误" && exit 1
  echo "$token" > "$TOKENF"
}

download_cf(){
  wget -O "$CF" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$CF"
}

download_xray(){
  wget -O "$WORKDIR/x.zip" https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o "$WORKDIR/x.zip" -d "$WORKDIR" >/dev/null 2>&1
  chmod +x "$XRAY"
}

write_conf(){
  port=$(cat "$PORTF")
  uuid=$(cat "$UUIDF")

  cat > "$CONF" <<EOF
{
"inbounds":[
{"port":$port,"protocol":"vless",
"settings":{"clients":[{"id":"$uuid"}],"decryption":"none"},
"streamSettings":{"network":"ws","wsSettings":{"path":"/"}}}
],
"outbounds":[{"protocol":"freedom"}]
}
EOF
}

write_wrapper(){
cat > "$CF_WRAP" <<EOF
#!/bin/sh
exec $CF tunnel --no-autoupdate --edge-ip-version 6 --protocol http2 run --token \$(cat $TOKENF)
EOF
chmod +x "$CF_WRAP"
}

create_services(){

# xray
cat > /etc/init.d/argo-xray <<EOF
#!/sbin/openrc-run
name="argo-xray"
command="$XRAY"
command_args="-config $CONF"
command_background=true
pidfile="/run/argo-xray.pid"

supervisor=supervise-daemon
respawn_delay=3
respawn_max=0

depend() {
  need net
}
EOF

# cloudflared
cat > /etc/init.d/argo-cf <<EOF
#!/sbin/openrc-run
name="argo-cf"
command="$CF_WRAP"
command_background=true
pidfile="/run/argo-cf.pid"

supervisor=supervise-daemon
respawn_delay=5
respawn_max=0

depend() {
  need net
  after argo-xray
}
EOF

chmod +x /etc/init.d/argo-*

rc-update add argo-xray default >/dev/null 2>&1
rc-update add argo-cf default >/dev/null 2>&1
}

start_all(){
  rc-service argo-xray restart
  rc-service argo-cf restart
}

show_info(){
  uuid=$(cat "$UUIDF")
  domain=$(cat "$DOMAINF")
  port=$(cat "$PORTF")

  echo "======================"
  echo "地址: $domain"
  echo "端口: 443"
  echo "UUID: $uuid"
  echo "路径: /"
  echo "本地端口: $port"
  echo "======================"

  echo "CF填写: http://localhost:$port"
  echo ""
  echo "vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=%2F#$domain"
}

install_all(){
  install_base
  gen_uuid
  set_port
  set_domain
  set_token

  download_cf
  download_xray

  write_conf
  write_wrapper
  create_services
  start_all

  show_info

  echo "alias argo='sh /root/argo.sh menu'" >> /etc/profile
  echo "[+] 安装完成"
}

menu(){
echo "1. 查看节点"
echo "2. 重启服务"
echo "3. 查看日志"
read -p "选择: " n

case "$n" in
1) show_info ;;
2) start_all ;;
3) tail -f $WORKDIR/argo.log ;;
esac
}

case "$1" in
install) install_all ;;
menu) menu ;;
*) echo "用法: sh argo.sh install" ;;
esac
