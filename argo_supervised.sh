#!/usr/bin/env bash
set -e

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

install_base() {
  if command -v apt >/dev/null; then
    apt update -y && apt install -y curl wget unzip
  elif command -v dnf >/dev/null; then
    dnf install -y curl wget unzip
  elif command -v yum >/dev/null; then
    yum install -y curl wget unzip
  else
    echo "不支持的系统（需要 systemd）"
    exit 1
  fi
}

gen_uuid() {
  [ ! -f "$UUIDF" ] && cat /proc/sys/kernel/random/uuid > "$UUIDF"
}

set_port() {
  read -rp "端口(默认8080): " p
  [ -z "$p" ] && p=8080
  echo "$p" > "$PORTF"
}

set_domain() {
  read -rp "域名(必须已接入CF): " d
  echo "$d" > "$DOMAINF"
}

set_token() {
  echo "粘贴Tunnel Token:"
  read -r input
  token=$(echo "$input" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1)

  if [ -z "$token" ]; then
    echo "Token错误"
    exit 1
  fi

  echo "$token" > "$TOKENF"
}

download_cf() {
  wget -q -O "$CF" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x "$CF"
}

download_xray() {
  wget -q -O "$WORKDIR/x.zip" https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o "$WORKDIR/x.zip" -d "$WORKDIR" >/dev/null
  chmod +x "$XRAY"
}

write_conf() {
  port=$(cat "$PORTF")
  uuid=$(cat "$UUIDF")

  cat > "$CONF" <<EOF
{
  "inbounds":[
    {
      "port":$port,
      "protocol":"vless",
      "settings":{"clients":[{"id":"$uuid"}],"decryption":"none"},
      "streamSettings":{"network":"ws","wsSettings":{"path":"/"}}
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
}

write_wrapper() {
  cat > "$CF_WRAP" <<EOF
#!/bin/sh
exec $CF tunnel --no-autoupdate --edge-ip-version 6 --protocol http2 run --token \$(cat $TOKENF)
EOF
  chmod +x "$CF_WRAP"
}

create_services() {

cat > /etc/systemd/system/argo-xray.service <<EOF
[Unit]
Description=Argo Xray
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$XRAY -config $CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/argo-cf.service <<EOF
[Unit]
Description=Argo Cloudflared
After=network-online.target argo-xray.service
Requires=argo-xray.service

[Service]
ExecStart=$CF_WRAP
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable argo-xray argo-cf
}

start_all() {
  systemctl restart argo-xray
  systemctl restart argo-cf
}

show_info() {
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

install_all() {
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

  echo "alias argo='bash /root/argo.sh menu'" >> /etc/profile
  echo "[+] 安装完成"
}

menu() {
  echo "1. 查看节点"
  echo "2. 重启服务"
  echo "3. 查看日志"
  read -rp "选择: " n

  case "$n" in
    1) show_info ;;
    2) start_all ;;
    3) journalctl -u argo-cf -f ;;
  esac
}

case "$1" in
  install) install_all ;;
  menu) menu ;;
  *) echo "用法: bash argo.sh install" ;;
esac
