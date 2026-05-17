#!/bin/bash
#===========================================
# Docker 服务部署管理脚本
# 版本: 2.2 (完美修正版)
# 功能：安装Docker、部署Komari/SublinkPro/CF隧道
#===========================================

set -e

#=========== 全局变量 ===========
SCRIPT_NAME="docker-manager"
INSTALL_PATH="/usr/local/bin/docker-manager"
BASE_DIR="/opt"
KOMARI_DIR="${BASE_DIR}/komari"
SUBLINK_DIR="${BASE_DIR}/sublinkpro"
TUNNEL_DIR="${BASE_DIR}/cloudflared"
BACKUP_DIR="${BASE_DIR}/docker-backups"
NETWORK_NAME="cf-tunnel-net"
ENV_FILE="${TUNNEL_DIR}/.env"
COMPOSE_KOMARI="${KOMARI_DIR}/docker-compose.yml"
COMPOSE_SUBLINK="${SUBLINK_DIR}/docker-compose.yml"
COMPOSE_TUNNEL="${TUNNEL_DIR}/docker-compose.yml"
SCRIPT_VERSION="2.2"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#=========== 工具函数 ===========
print_color() { echo -e "${2}${1}${NC}"; }
print_info() { print_color "[信息] $1" "$BLUE"; }
print_success() { print_color "[成功] $1" "$GREEN"; }
print_warning() { print_color "[警告] $1" "$YELLOW"; }
print_error() { print_color "[错误] $1" "$RED"; }
print_title() { echo -e "\n${CYAN}========== $1 ==========${NC}\n"; }

check_cmd() { command -v "$1" &>/dev/null; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

confirm() {
    local prompt="${1:-确认执行此操作?}"
    local response
    read -rp "$prompt [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

get_os_type() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

#=========== 状态检查函数 ===========
check_docker_installed() { check_cmd docker; }
check_docker_running() { systemctl is-active --quiet docker 2>/dev/null; }
check_compose_available() { docker compose version &>/dev/null; }
check_container_exists() { docker ps -a --format '{{.Names}}' | grep -qw "$1"; }
check_container_running() { docker ps --format '{{.Names}}' | grep -qw "$1"; }
check_network_exists() { docker network inspect "$NETWORK_NAME" &>/dev/null; }

get_container_status() {
    local container=$1
    if check_container_running "$container"; then
        echo -e "${GREEN}运行中${NC}"
    elif check_container_exists "$container"; then
        echo -e "${YELLOW}已停止${NC}"
    else
        echo -e "${RED}未安装${NC}"
    fi
}

get_status_icon() {
    local container=$1
    if check_container_running "$container"; then
        echo "✅"
    elif check_container_exists "$container"; then
        echo "⏸️"
    else
        echo "❌"
    fi
}

check_environment() {
    local issues=0
    print_info "检测系统环境..."
    
    if ! check_docker_installed; then print_warning "Docker 未安装"; ((issues++)); fi
    if ! check_docker_running; then print_warning "Docker 服务未运行"; ((issues++)); fi
    if ! check_compose_available; then print_warning "Docker Compose 不可用"; ((issues++)); fi
    if ! check_network_exists; then print_warning "共享网络 ${NETWORK_NAME} 不存在"; ((issues++)); fi
    
    if [[ $issues -gt 0 ]]; then
        print_warning "发现 ${issues} 个问题，部分功能可能不可用"
        return 1
    fi
    print_success "环境检测通过"
    return 0
}

backup_data() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/backup_${timestamp}"
    
    print_info "创建备份..."
    mkdir -p "$backup_path"
    
    for dir in "$KOMARI_DIR" "$SUBLINK_DIR" "$TUNNEL_DIR"; do
        if [[ -d "$dir" ]]; then
            cp -r "$dir" "${backup_path}/$(basename "$dir")" 2>/dev/null || true
        fi
    done
    print_success "备份已保存到: $backup_path"
    echo "$backup_path"
}

install_docker() {
    print_title "安装 Docker 环境"
    if check_docker_installed; then
        print_info "Docker 已安装"
        return 0
    fi
    
    print_info "开始安装 Docker..."
    
    # 采用官方内置环境变量方式配置国内源，完美避开改系统 sources.list 的各种发行版兼容巨坑
    if confirm "是否使用国内镜像源加速安装? (推荐中国大陆服务器)"; then
        export DOWNLOAD_URL="https://mirrors.aliyun.com/docker-ce"
    fi
    
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
    
    if confirm "是否配置 Docker 镜像加速? (随时可能失效，仅供参考)"; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<'DAEMONEOF'
{
    "registry-mirrors": [
        "https://docker.1ms.run",
        "https://docker.xuanyuan.me"
    ],
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3" }
}
DAEMONEOF
        systemctl restart docker
        print_success "镜像加速已配置"
    fi
}

create_network() {
    if check_network_exists; then return 0; fi
    print_info "创建 Docker 共享网络: ${NETWORK_NAME}"
    docker network create "$NETWORK_NAME"
}

deploy_komari() {
    print_title "部署 Komari"
    if check_container_exists "komari"; then
        docker rm -f komari 2>/dev/null || true
    fi
    
    mkdir -p "${KOMARI_DIR}/data"
    cat > "$COMPOSE_KOMARI" <<'KOMARIEOF'
services:
  komari:
    image: ghcr.io/komari-monitor/komari:latest
    container_name: komari
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    networks:
      - cf-tunnel-net
networks:
  cf-tunnel-net:
    external: true
KOMARIEOF

    cd "$KOMARI_DIR"
    docker compose up -d
    print_success "Komari 部署完成"
}

deploy_sublink() {
    print_title "部署 Sublink Pro"
    if check_container_exists "sublinkpro"; then
        docker rm -f sublinkpro 2>/dev/null || true
    fi
    
    mkdir -p "${SUBLINK_DIR}"/{db,template,logs}
    cat > "$COMPOSE_SUBLINK" <<'SUBLINKEOF'
services:
  sublinkpro:
    image: zerodeng/sublink-pro
    container_name: sublinkpro
    restart: unless-stopped
    volumes:
      - ./db:/app/db
      - ./template:/app/template
      - ./logs:/app/logs
    networks:
      - cf-tunnel-net
networks:
  cf-tunnel-net:
    external: true
KOMARIEOF

    cd "$SUBLINK_DIR"
    docker compose up -d
    print_success "Sublink Pro 部署完成"
}

get_cf_token() {
    local token=""
    print_info "获取 Cloudflare Tunnel Token"
    while true; do
        read -rsp "请输入 CF Tunnel Token: " token
        echo ""
        if [[ -z "$token" ]]; then continue; fi
        break
    done
    
    mkdir -p "$TUNNEL_DIR"
    # 直接写入 TUNNEL_TOKEN，对齐 Cloudflare 官方容器的标准变量名
    echo "TUNNEL_TOKEN=${token}" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

deploy_tunnel() {
    print_title "部署 Cloudflare Tunnel"
    if [ -f "$ENV_FILE" ]; then source "$ENV_FILE"; fi
    
    if [[ -z "$TUNNEL_TOKEN" ]]; then
        get_cf_token
        source "$ENV_FILE"
    fi
    
    if check_container_exists "cloudflared"; then
        docker rm -f cloudflared 2>/dev/null || true
    fi
    
    cat > "$COMPOSE_TUNNEL" <<'TUNNELEOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    env_file:
      - .env
    environment:
      - TUNNEL_TOKEN
    networks:
      - cf-tunnel-net
networks:
  cf-tunnel-net:
    external: true
TUNNELEOF

    cd "$TUNNEL_DIR"
    docker compose up -d
    print_success "Cloudflare Tunnel 部署完成！请前往 CF 后台配置 Hostname 绑定本地容器服务："
    print_info "  -> Komari 请绑定到: http://komari:25774"
    print_info "  -> Sublink Pro 请绑定到: http://sublinkpro:8000"
}

service_control() {
    local service=$1
    local action=$2
    local dir=""
    
    case $service in
        komari) dir="$KOMARI_DIR" ;;
        sublinkpro) dir="$SUBLINK_DIR" ;;
        cloudflared) dir="$TUNNEL_DIR" ;;
    esac
    
    if [[ ! -f "${dir}/docker-compose.yml" ]]; then
        print_error "该服务未部署"
        return 1
    fi
    
    cd "$dir"
    create_network
    
    case $action in
        start) docker compose up -d ;;
        stop) docker compose stop ;;
        restart) docker compose restart ;;
        update) docker compose pull && docker compose up -d ;;
        logs) 
            # 优雅捕获 Ctrl+C，避免看日志按退出时把整个脚本连带干掉
            print_info "正在查看日志，退出请按 Ctrl+C..."
            set +e
            docker compose logs --tail 100 -f
            set -e
            ;;
    esac
}

show_status() {
    print_title "服务运行状态"
    printf "  %-20s %-20s %-20s\n" "服务名称" "容器名称" "运行状态"
    printf "  %-20s %-20s %-20s\n" "--------" "--------" "--------"
    printf "  %-20s %-20s %-42b\n" "Komari" "komari" "$(get_container_status komari)"
    printf "  %-20s %-20s %-42b\n" "Sublink Pro" "sublinkpro" "$(get_container_status sublinkpro)"
    printf "  %-20s %-20s %-42b\n" "CF Tunnel" "cloudflared" "$(get_container_status cloudflared)"
    echo ""
}

init_deploy() {
    install_docker
    create_network
    get_cf_token
    deploy_komari
    deploy_sublink
    deploy_tunnel
    show_status
}

full_uninstall() {
    print_title "完全卸载"
    if ! confirm "确定要完全卸载所有服务和数据吗?"; then return; fi
    
    cd "$TUNNEL_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    cd "$SUBLINK_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    cd "$KOMARI_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
    rm -rf "$KOMARI_DIR" "$SUBLINK_DIR" "$TUNNEL_DIR" "$INSTALL_PATH"
    print_success "卸载完成。"
    exit 0
}

show_menu() {
    clear
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}    Docker 服务集群管理面板 v${SCRIPT_VERSION}     ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo "  1) 查看服务状态       2) 初始化全套部署"
    echo "  3) 启动 Komari        4) 停止 Komari        5) 重启 Komari"
    echo "  6) 启动 Sublink Pro   7) 停止 Sublink Pro   8) 重启 Sublink Pro"
    echo "  9) 启动 CF Tunnel     10) 停止 CF Tunnel    11) 重启 CF Tunnel"
    echo " 12) 查看 Komari 日志   13) 查看 Sublink 日志 14) 查看 Tunnel 日志"
    echo " 15) 🔑 修改 CF Token   16) 🗑️ 完全卸载        0) 退出"
    echo -e "${CYAN}=========================================${NC}"
}

handle_menu() {
    while true; do
        show_menu
        read -rp "请输入选项: " choice
        case $choice in
            0) exit 0 ;;
            1) show_status ;;
            2) init_deploy ;;
            3) service_control komari start ;;
            4) service_control komari stop ;;
            5) service_control komari restart ;;
            6) service_control sublinkpro start ;;
            7) service_control sublinkpro stop ;;
            8) service_control sublinkpro restart ;;
            9) service_control cloudflared start ;;
            10) service_control cloudflared stop ;;
            11) service_control cloudflared restart ;;
            12) service_control komari logs ;;
            13) service_control sublinkpro logs ;;
            14) service_control cloudflared logs ;;
            15) get_cf_token ;;
            16) full_uninstall ;;
            *) print_error "无效选项" ;;
        esac
        if [[ ! "$choice" =~ ^(12|13|14)$ ]]; then
            read -rp "按 Enter 继续..."
        fi
    done
}

main() {
    check_root
    
    # 安全的快捷命令安装逻辑：防止 Text file busy 覆盖报错
    if [[ "$(readlink -f "$0")" != "$INSTALL_PATH" ]]; then
        if [[ ! -f "$INSTALL_PATH" ]]; then
            print_info "正在为您安装快捷全局命令: docker-manager..."
            cp "$(readlink -f "$0")" "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
            print_success "安装成功！后续可在系统任意位置输入 docker-manager 直接管理。"
        else
            print_info "检测到系统已有快捷命令，本次跳过安装动作。"
        fi
    fi
    
    check_environment || true
    handle_menu
}

main "$@"