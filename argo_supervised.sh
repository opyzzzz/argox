#!/bin/sh
set -eu

WORKDIR="/root/argo"
CF="$WORKDIR/cloudflared"
XRAY="$WORKDIR/xray"
CONF="$WORKDIR/config.json"

UUIDF="$WORKDIR/uuid"
PORTF="$WORKDIR/port"
DOMAINF="$WORKDIR/domain"
TOKENF="$WORKDIR/token"

CF_WRAP="$WORKDIR/cf.sh"
XRAY_WRAP="$WORKDIR/xray.sh"
CF_LOG="$WORKDIR/argo.log"
XRAY_LOG="$WORKDIR/xray.log"

XRAY_SERVICE="/etc/init.d/argo-xray"
CF_SERVICE="/etc/init.d/argo-cf"

mkdir -p "$WORKDIR"
umask 077

need_root() {
  [ "$(id -u)" -eq 0 ] || {
    echo "请用 root 执行"
    exit 1
  }
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      return 0
      ;;
    *)
      echo "此脚本当前按 x86_64/amd64 编写，其他架构请同步调整下载地址。"
      exit 1
      ;;
  esac
}

install_base() {
  apk add --no-cache curl wget unzip iputils busybox-suid ca-certificates >/dev/null 2>&1
}

gen_uuid() {
  [ -s "$UUIDF" ] || cat /proc/sys/kernel/random/uuid > "$UUIDF"
}

set_port() {
  while :; do
    printf "端口(默认8080): "
    read -r p || true
    [ -z "${p:-}" ] && p=8080
    case "$p" in
      ''|*[!0-9]*)
        echo "端口必须是数字"
        ;;
      *)
        echo "$p" > "$PORTF"
        break
        ;;
    esac
  done
}

set_domain() {
  while :; do
    printf "域名(必须已接入CF): "
    read -r d || true
    [ -n "${d:-}" ] && {
      echo "$d" > "$DOMAINF"
      break
    }
    echo "域名不能为空"
  done
}

set_token() {
  while :; do
    echo "粘贴Tunnel Token(整段也行):"
    read -r input || true
    token=$(printf '%s' "${input:-}" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1 || true)
    if [ -n "${token:-}" ]; then
      printf '%s\n' "$token" > "$TOKENF"
      chmod 600 "$TOKENF" || true
      break
    fi
    echo "Token识别失败"
  done
}

download_cf() {
  wget -q -O "$CF" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x "$CF"
}

download_xray() {
  wget -q -O "$WORKDIR/x.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
  unzip -o "$WORKDIR/x.zip" -d "$WORKDIR" >/dev/null 2>&1
  chmod +x "$XRAY"
}

write_conf() {
  port=$(cat "$PORTF")
  uuid=$(cat "$UUIDF")

  cat > "$CONF" <<EOF
{
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}

write_wrappers() {
  cat > "$XRAY_WRAP" <<EOF
#!/bin/sh
exec "$XRAY" -config "$CONF" >> "$XRAY_LOG" 2>&1
EOF
  chmod +x "$XRAY_WRAP"

  cat > "$CF_WRAP" <<EOF
#!/bin/sh
exec "$CF" tunnel --no-autoupdate --edge-ip-version 6 --protocol http2 run --token "\$(cat "$TOKENF")" >> "$CF_LOG" 2>&1
EOF
  chmod +x "$CF_WRAP"
}

write_services() {
  cat > "$XRAY_SERVICE" <<EOF
#!/sbin/openrc-run

description="Argo Xray"
name="argo-xray"
command="$XRAY_WRAP"
supervisor=supervise-daemon
respawn_delay=3
respawn_max=0

depend() {
  need net
}
EOF

  cat > "$CF_SERVICE" <<'EOF'
#!/sbin/openrc-run

description="Argo Cloudflared"
name="argo-cf"
command="/root/argo/cf.sh"
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0
healthcheck_delay=30
healthcheck_timer=60

depend() {
  need net
  after argo-xray
}

start_pre() {
  ebegin "等待 IPv6 网络"
  i=0
  while [ "$i" -lt 30 ]; do
    if ping6 -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1; then
      eend 0
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  ewarn "IPv6 未就绪，将继续尝试启动"
  eend 0
}

healthcheck() {
  ping6 -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1 && pgrep -x cloudflared >/dev/null 2>&1
}
EOF

  chmod +x "$XRAY_SERVICE" "$CF_SERVICE"

  rc-update add argo-xray default >/dev/null 2>&1 || true
  rc-update add argo-cf default >/dev/null 2>&1 || true
}

ensure_crond() {
  rc-service crond start >/dev/null 2>&1 || true
  rc-update add crond default >/dev/null 2>&1 || true
}

setup_cron() {
  marker="argo-cf IPv6 self-heal"
  current="$(crontab -l 2>/dev/null || true)"

  printf '%s\n' "$current" | grep -q "$marker" && return 0

  {
    printf '%s\n' "$current"
    printf '%s\n' "# $marker"
    printf '%s\n' '* * * * * ping6 -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1 || rc-service argo-cf restart >/dev/null 2>&1'
    printf '%s\n' '* * * * * pgrep -x cloudflared >/dev/null 2>&1 || rc-service argo-cf restart >/dev/null 2>&1'
  } | crontab -
}

start_all() {
  rc-service argo-xray restart >/dev/null 2>&1 || rc-service argo-xray start
  rc-service argo-cf restart >/dev/null 2>&1 || rc-service argo-cf start
}

show_info() {
  uuid=$(cat "$UUIDF")
  domain=$(cat "$DOMAINF")
  port=$(cat "$PORTF")

  cat <<EOM

======================
VLESS 节点信息
地址: $domain
端口: 443
UUID: $uuid
路径: /
TLS: 开启
本地端口: $port
======================

CF后台填写：
http://localhost:$port

节点链接：
vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=%2F#$domain

EOM
}

status_all() {
  rc-service argo-xray status || true
  rc-service argo-cf status || true
  rc-service crond status || true
}

show_logs() {
  echo "=== xray.log ==="
  tail -n 50 "$XRAY_LOG" 2>/dev/null || true
  echo
  echo "=== argo.log ==="
  tail -n 80 "$CF_LOG" 2>/dev/null || true
}

remove_cron() {
  crontab -l 2>/dev/null | grep -v 'argo-cf IPv6 self-heal' | grep -v 'ping6 -c1 -W1 2606:4700:4700::1111' | grep -v 'pgrep -x cloudflared' | crontab - 2>/dev/null || true
}

uninstall_all() {
  rc-service argo-cf stop >/dev/null 2>&1 || true
  rc-service argo-xray stop >/dev/null 2>&1 || true
  rc-update del argo-cf default >/dev/null 2>&1 || true
  rc-update del argo-xray default >/dev/null 2>&1 || true
  rc-service crond restart >/dev/null 2>&1 || true
  remove_cron

  rm -f "$CF_SERVICE" "$XRAY_SERVICE"
  rm -f "$CF_WRAP" "$XRAY_WRAP" "$CONF" "$CF_LOG" "$XRAY_LOG" "$UUIDF" "$PORTF" "$DOMAINF" "$TOKENF" "$WORKDIR/x.zip"
  echo "[+] 已卸载"
}

install_all() {
  need_root
  detect_arch
  install_base
  gen_uuid
  set_port
  set_domain
  set_token

  download_cf
  download_xray
  write_conf
  write_wrappers
  write_services
  ensure_crond
  setup_cron
  start_all

  show_info

  if ! grep -q "alias argo='sh /root/argo.sh menu'" /etc/profile 2>/dev/null; then
    echo "alias argo='sh /root/argo.sh menu'" >> /etc/profile
  fi

  echo "[+] 安装完成"
  echo "执行: source /etc/profile"
  echo "输入: argo 管理"
}

menu() {
  while :; do
    clear
    echo "===== Argo 管理 ====="
    echo "1. 查看节点"
    echo "2. 修改端口"
    echo "3. 修改UUID"
    echo "4. 修改域名"
    echo "5. 修改Token"
    echo "6. 重启服务"
    echo "7. 查看日志"
    echo "8. 重装"
    echo "9. 卸载"
    echo "0. 退出"
    printf "选择: "
    read -r n || true

    case "$n" in
      1) show_info; printf "回车继续..."; read -r _ || true ;;
      2) set_port; write_conf; start_all ;;
      3) rm -f "$UUIDF"; gen_uuid; write_conf; start_all ;;
      4) set_domain ;;
      5) set_token; write_wrappers; start_all ;;
      6) start_all ;;
      7) show_logs; printf "回车继续..."; read -r _ || true ;;
      8) install_all ;;
      9) uninstall_all; exit 0 ;;
      0) exit 0 ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  install) install_all ;;
  menu) menu ;;
  start)
    need_root
    start_all
    ;;
  restart)
    need_root
    start_all
    ;;
  status)
    need_root
    status_all
    ;;
  logs)
    need_root
    show_logs
    ;;
  uninstall)
    need_root
    uninstall_all
    ;;
  *)
    echo "用法: sh argo.sh install | menu | start | restart | status | logs | uninstall"
    ;;
esac
