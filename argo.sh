#!/usr/bin/env bash

# =========================================================
# sing-box + Cloudflared(QUIC)
# Alpine / Debian / Podman / Docker / VPS
# 小内存优化版
# 支持:
#   - VLESS-WS-Argo
#   - VLESS-Reality
# =========================================================

set -u

# =========================================================
# 基础变量
# =========================================================

WORKDIR="/root/sbox"

SB="$WORKDIR/sing-box"
CF="$WORKDIR/cloudflared"

SB_CONF="$WORKDIR/config.json"

SB_LOG="$WORKDIR/singbox.log"
ARGO_LOG="$WORKDIR/argo.log"

UUIDF="$WORKDIR/uuid"

WS_PORTF="$WORKDIR/ws_port"
REALITY_PORTF="$WORKDIR/reality_port"

DOMAINF="$WORKDIR/domain"
TOKENF="$WORKDIR/token"

WSPATHF="$WORKDIR/ws_path"

PRIVATEF="$WORKDIR/private.key"
PUBLICF="$WORKDIR/public.key"
SHORTIDF="$WORKDIR/shortid"

IPMODEF="$WORKDIR/ipmode"

mkdir -p "$WORKDIR"

# =========================================================
# 颜色
# =========================================================

red='\033[1;31m'
green='\033[1;32m'
yellow='\033[1;33m'
plain='\033[0m'

# =========================================================
# 输出函数
# =========================================================

info() {
    echo -e "${green}[+] $*${plain}"
}

warn() {
    echo -e "${yellow}[!] $*${plain}"
}

error() {
    echo -e "${red}[-] $*${plain}"
}

# =========================================================
# 系统检测
# =========================================================

detect_pkgmgr() {

    if command -v apk >/dev/null 2>&1; then
        PKG="apk"

    elif command -v apt >/dev/null 2>&1; then
        PKG="apt"

    else
        error "不支持的系统"
        exit 1
    fi
}

# =========================================================
# 安装依赖
# =========================================================

install_deps() {

    detect_pkgmgr

    info "安装依赖..."

    if [ "$PKG" = "apk" ]; then

        apk add --no-cache \
            bash \
            curl \
            wget \
            tar \
            openssl \
            ca-certificates \
            >/dev/null 2>&1

    else

        export DEBIAN_FRONTEND=noninteractive

        apt update -y >/dev/null 2>&1

        apt install -y \
            bash \
            curl \
            wget \
            tar \
            openssl \
            ca-certificates \
            >/dev/null 2>&1
    fi

    update-ca-certificates >/dev/null 2>&1 || true
}

# =========================================================
# 架构检测
# =========================================================

get_arch() {

    case "$(uname -m)" in

        x86_64|amd64)
            ARCH_SB="amd64"
            ARCH_CF="amd64"
            ;;

        aarch64|arm64)
            ARCH_SB="arm64"
            ARCH_CF="arm64"
            ;;

        *)
            error "不支持架构: $(uname -m)"
            exit 1
            ;;
    esac
}

# =========================================================
# 下载 sing-box
# =========================================================

download_singbox() {

    get_arch

    info "下载 sing-box..."

    rm -rf "$WORKDIR"/sing-box*
    rm -f "$WORKDIR/sb.tar.gz"

    local url

    url="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$ARCH_SB.tar.gz"

    wget -q -O "$WORKDIR/sb.tar.gz" "$url"

    if [ ! -s "$WORKDIR/sb.tar.gz" ]; then
        error "sing-box 下载失败"
        exit 1
    fi

    mkdir -p "$WORKDIR/sbtmp"

    tar -xzf "$WORKDIR/sb.tar.gz" \
        -C "$WORKDIR/sbtmp" >/dev/null 2>&1

    local sb_bin

    sb_bin=$(find "$WORKDIR/sbtmp" -type f -name sing-box | head -n1)

    if [ -z "$sb_bin" ]; then
        error "sing-box 解压失败"
        exit 1
    fi

    mv "$sb_bin" "$SB"

    chmod +x "$SB"

    rm -rf "$WORKDIR/sbtmp"
    rm -f "$WORKDIR/sb.tar.gz"
}

# =========================================================
# 下载 cloudflared
# =========================================================

download_cf() {

    get_arch

    info "下载 cloudflared..."

    rm -f "$CF"

    wget -q -O "$CF" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH_CF"

    if [ ! -s "$CF" ]; then
        error "cloudflared 下载失败"
        exit 1
    fi

    chmod +x "$CF"
}

# =========================================================
# 生成 Reality 密钥
# =========================================================

generate_reality_key() {

    info "生成 Reality 密钥..."

    local key_output

    key_output=$("$SB" generate reality-keypair 2>/dev/null)

    if [ -z "$key_output" ]; then
        error "Reality 密钥生成失败"
        exit 1
    fi

    echo "$key_output" | awk '/PrivateKey/ {print $2}' > "$PRIVATEF"
    echo "$key_output" | awk '/PublicKey/ {print $2}' > "$PUBLICF"

    if [ ! -s "$PRIVATEF" ] || [ ! -s "$PUBLICF" ]; then
        error "Reality 密钥解析失败"
        exit 1
    fi

    openssl rand -hex 4 > "$SHORTIDF"
}

# =========================================================
# 获取公网IP
# =========================================================

get_public_ip() {

    local ip

    ip=$(curl -s4 --max-time 10 ip.sb 2>/dev/null)

    if [ -z "$ip" ]; then
        ip=$(curl -s4 --max-time 10 api.ipify.org 2>/dev/null)
    fi

    if [ -z "$ip" ]; then
        ip="YOUR_IP"
    fi

    echo "$ip"
}

# =========================================================
# 生成配置
# =========================================================

generate_config() {

    local uuid
    local ws_port
    local reality_port

    local ws_path

    local private_key
    local shortid

    uuid=$(cat "$UUIDF")

    ws_port=$(cat "$WS_PORTF")
    reality_port=$(cat "$REALITY_PORTF")

    ws_path=$(cat "$WSPATHF")

    private_key=$(cat "$PRIVATEF")
    shortid=$(cat "$SHORTIDF")

    cat > "$SB_CONF" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },

  "inbounds": [

    {
      "type": "vless",
      "tag": "vless-ws",

      "listen": "::",
      "listen_port": $ws_port,

      "users": [
        {
          "uuid": "$uuid"
        }
      ],

      "transport": {
        "type": "ws",
        "path": "$ws_path"
      }
    },

    {
      "type": "vless",
      "tag": "vless-reality",

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

          "private_key": "$private_key",

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
# 配置检测
# =========================================================

check_config() {

    "$SB" check -c "$SB_CONF" >/dev/null 2>&1
}

# =========================================================
# 启动 sing-box
# =========================================================

run_singbox() {

    if pgrep -x sing-box >/dev/null 2>&1; then
        return
    fi

    generate_config

    if ! check_config; then
        error "sing-box 配置错误"
        "$SB" check -c "$SB_CONF"
        exit 1
    fi

    info "启动 sing-box..."

    nohup "$SB" run -c "$SB_CONF" \
        > "$SB_LOG" 2>&1 &

    sleep 3

    if pgrep -x sing-box >/dev/null 2>&1; then
        info "sing-box 启动成功"
    else
        error "sing-box 启动失败"
        tail -20 "$SB_LOG"
        exit 1
    fi
}

# =========================================================
# 启动 cloudflared
# =========================================================

run_argo() {

    if pgrep -x cloudflared >/dev/null 2>&1; then
        return
    fi

    local token
    local ipmode

    token=$(cat "$TOKENF")
    ipmode=$(cat "$IPMODEF")

    info "启动 Argo Tunnel..."

    nohup "$CF" tunnel run \
        --token "$token" \
        --protocol quic \
        --edge-ip-version "$ipmode" \
        --no-autoupdate \
        > "$ARGO_LOG" 2>&1 &

    sleep 8

    if pgrep -x cloudflared >/dev/null 2>&1; then
        info "Argo Tunnel 启动成功"
    else
        error "Argo Tunnel 启动失败"
        tail -20 "$ARGO_LOG"
        exit 1
    fi
}

# =========================================================
# 停止服务
# =========================================================

stop_all() {

    pkill -x sing-box >/dev/null 2>&1 || true
    pkill -x cloudflared >/dev/null 2>&1 || true

    info "服务已停止"
}

# =========================================================
# 输出节点
# =========================================================

show_links() {

    local uuid
    local domain

    local ws_path

    local reality_port

    local public_key
    local shortid

    local server_ip

    uuid=$(cat "$UUIDF")
    domain=$(cat "$DOMAINF")

    ws_path=$(cat "$WSPATHF")

    reality_port=$(cat "$REALITY_PORTF")

    public_key=$(cat "$PUBLICF")
    shortid=$(cat "$SHORTIDF")

    server_ip=$(get_public_ip)

    local enc_path

    enc_path=$(echo "$ws_path" | sed 's/\//%2F/g')

    echo
    echo "================================================"
    echo -e "${green}部署完成${plain}"
    echo "================================================"

    echo
    echo "【VLESS-WS-Argo】"
    echo

    echo "vless://$uuid@$domain:443?encryption=none&security=tls&type=ws&host=$domain&path=$enc_path#$domain-Argo"

    echo
    echo "------------------------------------------------"

    echo
    echo "【VLESS-Reality】"
    echo

    echo "vless://$uuid@$server_ip:$reality_port?security=reality&sni=www.cloudflare.com&fp=chrome&pbk=$public_key&sid=$shortid&type=tcp&flow=xtls-rprx-vision#Reality"

    echo
    echo "================================================"
}

# =========================================================
# 安装
# =========================================================

install_all() {

    install_deps

    echo
    read -rp "请输入 Argo 域名: " domain

    if [ -z "$domain" ]; then
        error "域名不能为空"
        exit 1
    fi

    echo "$domain" > "$DOMAINF"

    echo
    echo "Cloudflare 出口IP模式:"
    echo "1. IPv4 (默认)"
    echo "2. IPv6"
    echo

    read -rp "请选择 [1-2 默认1]: " ipchoose

    case "$ipchoose" in
        2)
            echo "6" > "$IPMODEF"
            ;;
        *)
            echo "4" > "$IPMODEF"
            ;;
    esac

    echo
    read -rp "请输入 Reality 端口 [默认443]: " reality_port

    case "$reality_port" in
        "")
            reality_port="443"
            ;;

        *[!0-9]*)
            error "端口必须是数字"
            exit 1
            ;;
    esac

    echo "$reality_port" > "$REALITY_PORTF"

    echo "10000" > "$WS_PORTF"

    echo
    echo "请输入 Cloudflare Tunnel Token:"
    read -r token

    token=$(echo "$token" | tr -d '\r\n')

    if [ ${#token} -lt 100 ]; then
        error "Token 无效"
        exit 1
    fi

    echo "$token" > "$TOKENF"

    cat /proc/sys/kernel/random/uuid > "$UUIDF"

    echo "/$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)" > "$WSPATHF"

    download_singbox
    download_cf

    generate_reality_key

    run_singbox
    run_argo

    show_links
}

# =========================================================
# 守护模式
# =========================================================

daemon_loop() {

    info "进入守护模式"

    while true; do

        if ! pgrep -x sing-box >/dev/null 2>&1; then
            warn "sing-box 已停止，重新启动"
            run_singbox
        fi

        if ! pgrep -x cloudflared >/dev/null 2>&1; then
            warn "cloudflared 已停止，重新启动"
            run_argo
        fi

        sleep 30
    done
}

# =========================================================
# 菜单
# =========================================================

menu() {

    while true; do

        echo
        echo "=============================="
        echo "1. 安装"
        echo "2. 启动"
        echo "3. 停止"
        echo "4. 重启"
        echo "5. 查看 sing-box 日志"
        echo "6. 查看 Argo 日志"
        echo "7. 查看节点"
        echo "8. 守护模式"
        echo "9. 卸载"
        echo "0. 退出"
        echo "=============================="

        read -rp "请选择: " num

        case "$num" in

            1)
                install_all
                ;;

            2)
                run_singbox
                run_argo
                ;;

            3)
                stop_all
                ;;

            4)
                stop_all
                sleep 2
                run_singbox
                run_argo
                ;;

            5)
                tail -f "$SB_LOG"
                ;;

            6)
                tail -f "$ARGO_LOG"
                ;;

            7)
                show_links
                ;;

            8)
                daemon_loop
                ;;

            9)

                stop_all

                rm -rf "$WORKDIR"

                info "卸载完成"

                exit 0
                ;;

            0)
                exit 0
                ;;

        esac
    done
}

# =========================================================
# 入口
# =========================================================

case "${1:-menu}" in

    install)
        install_all
        ;;

    start)
        run_singbox
        run_argo
        ;;

    stop)
        stop_all
        ;;

    restart)
        stop_all
        sleep 2
        run_singbox
        run_argo
        ;;

    daemon)
        daemon_loop
        ;;

    menu)
        menu
        ;;

    *)
        menu
        ;;
esac
