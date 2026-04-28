#!/bin/sh
set -eu

WORKDIR="/root/argo"
CF="$WORKDIR/cloudflared"
XRAY="$WORKDIR/xray"
CONF="$WORKDIR/config.json"
LOGDIR="$WORKDIR/logs"

UUIDF="$WORKDIR/uuid"
PORTF="$WORKDIR/port"
DOMAINF="$WORKDIR/domain"
TOKENF="$WORKDIR/token"

XROUT="$LOGDIR/xray.log"
CFOUT="$LOGDIR/cloudflared.log"

XRAY_SVC="/etc/init.d/argo-xray"
CF_SVC="/etc/init.d/argo-cf"

need_root() {
  [ "$(id -u)" = "0" ] || {
    echo "请使用 root 运行"
    exit 1
  }
}

ensure_dirs() {
  mkdir -p "$WORKDIR" "$LOGDIR"
  touch "$XROUT" "$CFOUT"
}

install_base() {
  apk add --no-cache curl wget unzip ca-certificates >/dev/null 2>&1 || true
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    i386|i686) echo "386" ;;
    armv7l|armv7) echo "armv7" ;;
    *)
      echo "unsupported"
      ;;
  esac
}

download_file() {
  url="$1"
  dest="$2"

  rm -f "$dest"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url" && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 "$url" -o "$dest" && return 0
  fi
  return 1
}

gen_uuid() {
  [ -f "$UUIDF" ] || cat /proc/sys/kernel/random/uuid > "$UUIDF"
}

set_port() {
  printf "端口(默认8080): "
  read -r p || true
  [ -n "${p:-}" ] || p=8080
  printf '%s\n' "$p" > "$PORTF"
}

set_domain() {
  printf "域名(必须已接入CF): "
  read -r d || true
  [ -n "${d:-}" ] || {
    echo "域名不能为空"
    return 1
  }
  printf '%s\n' "$d" > "$DOMAINF"
}

set_token() {
  echo "粘贴 Tunnel Token（整段也可）:"
  read -r input || true
  token="$(printf '%s' "${input:-}" | grep -oE '[A-Za-z0-9_-]{120,}' | head -n1 || true)"

  if [ -z "${token:-}" ]; then
    echo "Token 识别失败，请重试"
    return 1
  fi

  printf '%s\n' "$token" > "$TOKENF"
}

download_cf() {
  arch="$(detect_arch)"
  case "$arch" in
    amd64) file="cloudflared-linux-amd64" ;;
    arm64) file="cloudflared-linux-arm64" ;;
    386) file="cloudflared-linux-386" ;;
    *)
      echo "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac

  urls="
https://github.com/cloudflare/cloudflared/releases/latest/download/$file
https://cdn.jsdelivr.net/gh/cloudflare/cloudflared@latest/$file
https://raw.githubusercontent.com/cloudflare/cloudflared/master/$file
"
  for u in $urls; do
    if download_file "$u" "$CF"; then
      chmod +x "$CF"
      return 0
    fi
  done

  echo "cloudflared 下载失败"
  exit 1
}

download_xray() {
  arch="$(detect_arch)"
  case "$arch" in
    amd64) file="Xray-linux-64.zip" ;;
    arm64) file="Xray-linux-arm64-v8a.zip" ;;
    386) file="Xray-linux-32.zip" ;;
    *)
      echo "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac

  zipf="$WORKDIR/xray.zip"
  urls="
https://github.com/XTLS/Xray-core/releases/latest/download/$file
https://cdn.jsdelivr.net/gh/XTLS/Xray-core@release/$file
"
  for u in $urls; do
    if download_file "$u" "$zipf"; then
      unzip -o "$zipf" -d "$WORKDIR" >/dev/null 2>&1 || true
      [ -x "$XRAY" ] || chmod +x "$XRAY"
      rm -f "$zipf"
      return 0
    fi
  done

  echo "xray 下载失败"
  exit 1
}

write_conf() {
  port="$(cat "$PORTF")"
  uuid="$(cat "$UUIDF")"

  cat > "$CONF" <<EOF
{
  "inbounds": [
    {
      "port": $port,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "email": "vless@local"
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
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
}

stop_child() {
  if [ -n "${child:-}" ] && kill -0 "$child" 2>/dev/null; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  exit 0
}

service_loop() {
  kind="${1:-}"
  trap 'stop_child' INT TERM QUIT

  while :; do
    child=""
    case "$kind" in
      xray)
        "$XRAY" -config "$CONF" >> "$XROUT" 2>&1 &
        ;;
      cf|cloudflared)
        token="$(cat "$TOKENF" 2>/dev/null || true)"
        if [ -z "${token:-}" ]; then
          echo "$(date '+%F %T') token missing" >> "$CFOUT"
          sleep 5
          continue
        fi
        "$CF" tunnel \
          --no-autoupdate \
          --edge-ip-version 6 \
          --protocol http2 \
          run --token "$token" >> "$CFOUT" 2>&1 &
        ;;
      *)
        echo "unknown service kind: $kind"
        exit 1
        ;;
    esac

    child=$!
    set +e
    wait "$child"
    code=$?
    set -e
    child=""

    [ "$code" -eq 0 ] && sleep 1 || sleep 3
  done
}

write_service_files() {
  cat > "$XRAY_SVC" <<EOF
#!/sbin/openrc-run
name="argo-xray"
description="Argo Xray service"
command="/bin/sh"
command_args="$WORKDIR/argo.sh service xray"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; }
start() {
  ebegin "Starting \${RC_SVCNAME}"
  start-stop-daemon --start --background --make-pidfile --pidfile "\$pidfile" --exec "\$command" -- \$command_args
  eend \$?
}
stop() {
  ebegin "Stopping \${RC_SVCNAME}"
  start-stop-daemon --stop --pidfile "\$pidfile" --retry TERM/5/KILL/5
  eend \$?
}
EOF

  cat > "$CF_SVC" <<EOF
#!/sbin/openrc-run
name="argo-cf"
description="Argo Cloudflared service"
command="/bin/sh"
command_args="$WORKDIR/argo.sh service cf"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; }
start() {
  ebegin "Starting \${RC_SVCNAME}"
  start-stop-daemon --start --background --make-pidfile --pidfile "\$pidfile" --exec "\$command" -- \$command_args
  eend \$?
}
stop() {
  ebegin "Stopping \${RC_SVCNAME}"
  start-stop-daemon --stop --pidfile "\$pidfile" --retry TERM/5/KILL/5
  eend \$?
}
EOF

  chmod +x "$XRAY_SVC" "$CF_SVC"
  rc-update add argo-xray default >/dev/null 2>&1 || true
  rc-update add argo-cf default >/dev/null 2>&1 || true
}

start_services() {
  rc-service argo-xray restart >/dev/null 2>&1 || rc-service argo-xray start >/dev/null 2>&1 || true
  rc-service argo-cf restart >/dev/null 2>&1 || rc-service argo-cf start >/dev/null 2>&1 || true
}

stop_services() {
  rc-service argo-cf stop >/dev/null 2>&1 || true
  rc-service argo-xray stop >/dev/null 2>&1 || true
}

show_info() {
  uuid="$(cat "$UUIDF")"
  domain="$(cat "$DOMAINF")"
  port="$(cat "$PORTF")"

  echo "======================"
  echo "VLESS 节点信息"
  echo "地址: $domain"
  echo "端口: 443"
  echo "UUID: $uuid"
  echo "路径: /"
  echo "TLS: 开启"
  echo "本地端口: $port"
  echo "======================"
  echo "CF 后台填写："
  echo "http://localhost:$port"
  echo
  echo "节点链接："
  echo "vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=%2F#$domain"
}

append_alias() {
  if ! grep -q "alias argo='sh /root/argo.sh menu'" /etc/profile 2>/dev/null; then
    echo "alias argo='sh /root/argo.sh menu'" >> /etc/profile
  fi
}

install_all() {
  need_root
  ensure_dirs
  install_base
  gen_uuid
  set_port
  set_domain
  set_token

  download_cf
  download_xray
  write_conf
  write_service_files
  start_services
  append_alias

  show_info
  echo
  echo "[+] 安装完成"
  echo "服务已加入开机启动：argo-xray / argo-cf"
  echo "执行: source /etc/profile"
  echo "输入: argo 管理"
}

restart_all() {
  write_conf
  start_services
}

menu() {
  while :; do
    clear 2>/dev/null || true
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

    case "${n:-}" in
      1)
        show_info
        printf "回车返回..."
        read -r _ || true
        ;;
      2)
        set_port
        write_conf
        restart_all
        ;;
      3)
        rm -f "$UUIDF"
        gen_uuid
        write_conf
        restart_all
        ;;
      4)
        set_domain
        ;;
      5)
        set_token
        rc-service argo-cf restart >/dev/null 2>&1 || true
        ;;
      6)
        restart_all
        ;;
      7)
        echo "Ctrl+C 退出日志查看"
        tail -f "$CFOUT" "$XROUT"
        ;;
      8)
        install_all
        ;;
      9)
        uninstall
        ;;
      0)
        exit 0
        ;;
      *)
        echo "无效选择"
        sleep 1
        ;;
    esac
  done
}

uninstall() {
  need_root
  stop_services
  rc-update del argo-xray default >/dev/null 2>&1 || true
  rc-update del argo-cf default >/dev/null 2>&1 || true
  rm -f "$XRAY_SVC" "$CF_SVC"
  rm -rf "$WORKDIR"
  sed -i "/alias argo='sh \\/root\\/argo.sh menu'/d" /etc/profile 2>/dev/null || true
  echo "已卸载"
}

main() {
  need_root
  ensure_dirs

  case "${1:-}" in
    install)
      install_all
      ;;
    menu)
      menu
      ;;
    service)
      service_loop "${2:-}"
      ;;
    start)
      write_conf
      start_services
      ;;
    restart)
      write_conf
      restart_all
      ;;
    stop)
      stop_services
      ;;
    status)
      rc-service argo-xray status || true
      rc-service argo-cf status || true
      ;;
    *)
      echo "用法: sh /root/argo.sh install"
      echo "      sh /root/argo.sh menu"
      echo "      sh /root/argo.sh start|stop|restart|status"
      ;;
  esac
}

main "$@"
