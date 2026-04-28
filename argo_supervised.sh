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
CHECK_SCRIPT="$WORKDIR/check.sh"

mkdir -p "$WORKDIR"

install_base(){
  apk add --no-cache curl wget unzip iputils busybox-suid >/dev/null 2>&1
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
  read -p "域名: " d
  echo "$d" > "$DOMAINF"
}

set_token(){
  read -p "Token: " input
  token=$(echo "$input" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)
  [ -z "$token" ] && echo "Token错误" && exit 1
  echo "$token" > "$TOKENF"
}

download_cf(){
  wget -q -O "$CF" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$CF"
}

download_xray(){
  wget -q -O "$WORKDIR/x.zip" https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o "$WORKDIR/x.zip" -d "$WORKDIR" >/dev/null
  chmod +x "$XRAY"
}

write_conf(){
  port=$(cat "$PORTF")
  uuid=$(cat "$UUIDF")

  cat > "$CONF" <<EOF
{
"inbounds":[{"port":$port,"protocol":"vless",
"settings":{"clients":[{"id":"$uuid"}],"decryption":"none"},
"streamSettings":{"network":"ws","wsSettings":{"path":"/"}}}],
"outbounds":[{"protocol":"freedom"}]
}
EOF
}

# ===== 核心1：严格网络检测 =====
wait_ipv6(){
  for i in $(seq 1 60); do
    ping6 -c1 2606:4700:4700::1111 >/dev/null 2>&1 && return
    sleep 2
  done
  return 1
}

# ===== 核心2：wrapper =====
write_wrapper(){
cat > "$CF_WRAP" <<EOF
#!/bin/sh

# 等IPv6真正可用
for i in \$(seq 1 60); do
  ping6 -c1 2606:4700:4700::1111 >/dev/null 2>&1 && break
  sleep 2
done

exec $CF tunnel --no-autoupdate --edge-ip-version 6 --protocol http2 run --token \$(cat $TOKENF)
EOF
chmod +x "$CF_WRAP"
}

# ===== 核心3：主动探活脚本 =====
write_check(){
cat > "$CHECK_SCRIPT" <<'EOF'
#!/bin/sh

# CF进程不存在 → 重启
pgrep cloudflared >/dev/null || rc-service argo-cf restart

# IPv6挂了 → 重启
ping6 -c1 2606:4700:4700::1111 >/dev/null || rc-service argo-cf restart

# CF连接检测（关键）
curl -6 --max-time 5 https://www.cloudflare.com >/dev/null 2>&1 || rc-service argo-cf restart
EOF
chmod +x "$CHECK_SCRIPT"
}

create_services(){

cat > /etc/init.d/argo-xray <<EOF
#!/sbin/openrc-run
command="$XRAY"
command_args="-config $CONF"
command_background=true

supervisor=supervise-daemon
respawn_delay=3
respawn_max=0
EOF

cat > /etc/init.d/argo-cf <<EOF
#!/sbin/openrc-run
command="$CF_WRAP"
command_background=true

supervisor=supervise-daemon
respawn_delay=5
respawn_max=0

depend() {
  need net
  after argo-xray
}
EOF

chmod +x /etc/init.d/argo-*

rc-update add argo-xray default
rc-update add argo-cf default
}

# ===== 核心4：crontab 保活 =====
setup_cron(){

crontab -l 2>/dev/null | grep -q check.sh && return

(
crontab -l 2>/dev/null
echo "* * * * * /root/argo/check.sh"
) | crontab -
}

start_all(){
  rc-service argo-xray restart
  rc-service argo-cf restart
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
  write_check
  create_services
  setup_cron

  start_all

  echo "[OK] 完成"
}

case "$1" in
install) install_all ;;
*) echo "用法: sh argo.sh install" ;;
esac
