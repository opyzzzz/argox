```bash
#!/usr/bin/env bash

# =========================================================
# Ultra Lite Argo + sing-box
# For:
#   - 64MB VPS
#   - Alpine
#   - Debian
#   - Podman
#   - Docker
#   - LXC
# =========================================================

set -u

# =========================================================
# 基础变量
# =========================================================

WORKDIR="/root/.argo-lite"

mkdir -p "$WORKDIR"

SB="$WORKDIR/sing-box"
CF="$WORKDIR/cloudflared"

CONFIG="$WORKDIR/config.json"

SB_PID="$WORKDIR/singbox.pid"
CF_PID="$WORKDIR/cloudflared.pid"

UUID_FILE="$WORKDIR/uuid"
TOKEN_FILE="$WORKDIR/token"
DOMAIN_FILE="$WORKDIR/domain"

PRIVATE_FILE="$WORKDIR/private.key"
PUBLIC_FILE="$WORKDIR/public.key"
SHORTID_FILE="$WORKDIR/shortid"

WS_PATH_FILE="$WORKDIR/ws_path"

REALITY_PORT_FILE="$WORKDIR/reality_port"

LOG="$WORKDIR/runtime.log"

# =========================================================
# 输出
# =========================================================

info() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*"
}

error() {
    echo "[-] $*"
}

# =========================================================
# 架构检测
# =========================================================

get_arch() {

    case "$(uname -m)" in

        x86_64|amd64)
            ARCH="amd64"
            ;;

        aarch64|arm64)
            ARCH="arm64"
            ;;

        *)
            error "unsupported arch"
            exit 1
            ;;
    esac
}

# =========================================================
# 下载文件
# =========================================================

download_file() {

    local url="$1"
    local out="$2"

    if command -v wget >/dev/null 2>&1; then

        wget \
            --no-check-certificate \
            -qO "$out" "$url"

    elif command -v curl >/dev/null 2>&1; then

        curl -Lks -o "$out" "$url"

    else

        error "need wget or curl"
        exit 1
    fi
}

# =========================================================
# 下载 sing-box
# =========================================================

download_singbox() {

    if [ -x "$SB" ]; then
        return
    fi

    get_arch

    info "download sing-box"

    local url
    local tmp

    tmp="$WORKDIR/sb.tar.gz"

    url="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$ARCH.tar.gz"

    download_file "$url" "$tmp"

    if [ ! -s "$tmp" ]; then
        error "download sing-box failed"
        exit 1
    fi

    mkdir -p "$WORKDIR/tmp"

    tar -xzf "$tmp" -C "$WORKDIR/tmp" >/dev/null 2>&1

    local bin

    bin=$(find "$WORKDIR/tmp" -type f -name sing-box | head -n1)

    if [ -z "$bin" ]; then
        error "extract sing-box failed"
        exit 1
    fi

    mv "$bin" "$SB"

    chmod +x "$SB"

    rm -rf "$WORKDIR/tmp"
    rm -f "$tmp"
}

# =========================================================
# 下载 cloudflared
# =========================================================

download_cf() {

    if [ -x "$CF" ]; then
        return
    fi

    get_arch

    info "download cloudflared"

    local url

    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"

    download_file "$url" "$CF"

    chmod +x "$CF"
}

# =========================================================
# Reality 密钥
# =========================================================

generate_reality() {

    if [ -f "$PRIVATE_FILE" ]; then
        return
    fi

    info "generate reality key"

    local out

    out=$("$SB" generate reality-keypair)

    echo "$out" | awk '/PrivateKey/ {print $2}' > "$PRIVATE_FILE"
    echo "$out" | awk '/PublicKey/ {print $2}' > "$PUBLIC_FILE"

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 4 > "$SHORTID_FILE"
    else
        date +%s | md5sum | cut -c1-8 > "$SHORTID_FILE"
    fi
}

# =========================================================
# 获取IP
# =========================================================

get_ip() {

    local ip

    ip=$(curl -s6 --max-time 5 ip.sb 2>/dev/null)

    if [ -z "$ip" ]; then
        ip=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
    fi

    if [ -z "$ip" ]; then
        ip="YOUR_IP"
    fi

    echo "$ip"
}

# =========================================================
# 配置
# =========================================================

generate_config() {

    local uuid
    local private
    local shortid
    local path
    local reality_port

    uuid=$(cat "$UUID_FILE")

    private=$(cat "$PRIVATE_FILE")
    shortid=$(cat "$SHORTID_FILE")

    path=$(cat "$WS_PATH_FILE")

    reality_port=$(cat "$REALITY_PORT_FILE")

    cat > "$CONFIG" <<EOF
{
  "log": {
    "disabled": true
  },

  "inbounds": [

    {
      "type": "vless",

      "listen": "::",

      "listen_port": 10000,

      "users": [
        {
          "uuid": "$uuid"
        }
      ],

      "transport": {
        "type": "ws",
        "path": "$path"
      }
    },

    {
      "type": "vless",

      "listen": "::",

      "listen_port": $reality_port,

      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],

      "tls": {
        "enabled": true,

        "server_name": "www.cloudflare.com",

        "reality": {
          "enabled": true,

          "handshake": {
            "server": "www.cloudflare.com",
            "server_port": 443
          },

          "private_key": "$private",

          "short_id": [
            "$shortid"
          ]
        }
      }
    }

  ],

  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF
}

# =========================================================
# 启动 sing-box
# =========================================================

start_sb() {

    if [ -f "$SB_PID" ]; then

        local pid

        pid=$(cat "$SB_PID")

        if kill -0 "$pid" 2>/dev/null; then
            return
        fi
    fi

    info "start sing-box"

    nohup "$SB" run -c "$CONFIG" \
        >/dev/null 2>&1 &

    echo $! > "$SB_PID"

    sleep 2
}

# =========================================================
# 启动 cloudflared
# =========================================================

start_cf() {

    if [ -f "$CF_PID" ]; then

        local pid

        pid=$(cat "$CF_PID")

        if kill -0 "$pid" 2>/dev/null; then
            return
        fi
    fi

    info "start cloudflared"

    local token

    token=$(cat "$TOKEN_FILE")

    nohup "$CF" tunnel run \
        --token "$token" \
        --protocol auto \
        --no-autoupdate \
        >/dev/null 2>&1 &

    echo $! > "$CF_PID"

    sleep 3
}

# =========================================================
# 停止
# =========================================================

stop_all() {

    if [ -f "$SB_PID" ]; then

        kill "$(cat "$SB_PID")" 2>/dev/null || true

        rm -f "$SB_PID"
    fi

    if [ -f "$CF_PID" ]; then

        kill "$(cat "$CF_PID")" 2>/dev/null || true

        rm -f "$CF_PID"
    fi
}

# =========================================================
# 输出节点
# =========================================================

show_links() {

    local uuid
    local domain
    local path

    local pbk
    local sid

    local ip
    local port

    uuid=$(cat "$UUID_FILE")

    domain=$(cat "$DOMAIN_FILE")

    path=$(cat "$WS_PATH_FILE")

    pbk=$(cat "$PUBLIC_FILE")

    sid=$(cat "$SHORTID_FILE")

    port=$(cat "$REALITY_PORT_FILE")

    ip=$(get_ip)

    local enc

    enc=$(echo "$path" | sed 's/\//%2F/g')

    echo
    echo "=================================="
    echo "VLESS WS ARGO"
    echo "=================================="
    echo

    echo "vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=$enc#$domain"

    echo
    echo "=================================="
    echo "VLESS REALITY"
    echo "=================================="
    echo

    echo "vless://$uuid@$ip:$port?security=reality&sni=www.cloudflare.com&fp=chrome&pbk=$pbk&sid=$sid&type=tcp&flow=xtls-rprx-vision#Reality"

    echo
}

# =========================================================
# 初始化
# =========================================================

init_env() {

    if [ ! -f "$UUID_FILE" ]; then
        cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
    fi

    if [ ! -f "$WS_PATH_FILE" ]; then
        echo "/$(date +%s | md5sum | cut -c1-8)" > "$WS_PATH_FILE"
    fi

    if [ ! -f "$REALITY_PORT_FILE" ]; then
        echo "2053" > "$REALITY_PORT_FILE"
    fi
}

# =========================================================
# 安装
# =========================================================

install_all() {

    init_env

    echo
    echo "Input argo domain:"
    read -r domain

    echo "$domain" > "$DOMAIN_FILE"

    echo
    echo "Input cloudflare token:"
    read -r token

    echo "$token" > "$TOKEN_FILE"

    echo
    echo "Reality port (default 2053):"
    read -r rport

    if [ -n "$rport" ]; then
        echo "$rport" > "$REALITY_PORT_FILE"
    fi

    download_singbox

    download_cf

    generate_reality

    generate_config

    start_sb

    start_cf

    show_links
}

# =========================================================
# 守护
# =========================================================

daemon_loop() {

    local fail=0

    while true; do

        if [ -f "$SB_PID" ]; then

            if ! kill -0 "$(cat "$SB_PID")" 2>/dev/null; then

                warn "restart sing-box"

                start_sb

                fail=$((fail + 1))
            fi
        fi

        if [ -f "$CF_PID" ]; then

            if ! kill -0 "$(cat "$CF_PID")" 2>/dev/null; then

                warn "restart cloudflared"

                start_cf

                fail=$((fail + 1))
            fi
        fi

        if [ "$fail" -gt 10 ]; then

            warn "too many crashes"

            sleep 60

            fail=0
        fi

        sleep 15
    done
}

# =========================================================
# 主逻辑
# =========================================================

case "${1:-install}" in

    install)

        install_all

        daemon_loop
        ;;

    stop)

        stop_all
        ;;

    links)

        show_links
        ;;

    daemon)

        daemon_loop
        ;;

esac
```
