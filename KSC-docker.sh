#!/bin/bash
#===========================================
# Docker 服务集群管理面板
# 版本: 3.3 (完全采纳审查建议的闭环版)
# 功能：安装Docker、部署Komari/SublinkPro/CF隧道
#===========================================

set -e

#=========== 全局变量 ===========
SCRIPT_NAME="ksc"
INSTALL_PATH="/usr/local/bin/ksc"
BASE_DIR="/opt"
KOMARI_DIR="${BASE_DIR}/komari"
SUBLINK_DIR="${BASE_DIR}/sublinkpro"
TUNNEL_DIR="${BASE_DIR}/cloudflared"
BACKUP_DIR="${BASE_DIR}/docker-backups"
NETWORK_NAME="cf-tunnel-net"
ENV_FILE="${TUNNEL_DIR}/.env"
CRED_FILE="${TUNNEL_DIR}/credentials.json"
COMPOSE_KOMARI="${KOMARI_DIR}/docker-compose.yml"
COMPOSE_SUBLINK="${SUBLINK_DIR}/docker-compose.yml"
COMPOSE_TUNNEL="${TUNNEL_DIR}/docker-compose.yml"
SCRIPT_VERSION="3.3"

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

check_environment() {
    local issues=0
    print_info "检测系统环境..."
    
    if ! check_docker_installed; then print_warning "Docker 未安装"; ((issues++)); fi
    if ! check_docker_running; then print_warning "Docker 服务未运行"; ((issues++)); fi
    if ! check_compose_available; then print_warning "Docker Compose 不可用"; ((issues++)); fi
    if ! check_network_exists; then print_warning "共享网络 ${NETWORK_NAME} 不存在"; ((issues++)); fi
    
    if [[ $issues -gt 0 ]]; then
        print_warning "发现 ${issues} 个环境缺陷，建议先执行初始化部署"
        return 1
    fi
    print_success "环境检测通过"
    return 0
}

read_token() {
    if [[ -f "$ENV_FILE" ]]; then
        TUNNEL_TOKEN=$(sed -n 's/^TUNNEL_TOKEN=//p' "$ENV_FILE" 2>/dev/null || echo "")
    else
        TUNNEL_TOKEN=""
    fi
}

verify_container() {
    local container=$1
    print_info "等待服务状态就绪..."
    sleep 3
    if check_container_running "$container"; then
        print_success "🎉 容器 ${container} 已成功拉起并处于活跃运行状态！"
        return 0
    else
        # ✅ 采纳建议：改回 ksc logs 提示，维持快捷方式生态的闭环
        print_error "❌ 容器 ${container} 启动后异常退出。请稍后执行: ${SCRIPT_NAME} logs ${container} 排查原因"
        return 1
    fi
}

backup_data() {
    print_title "数据备份程序"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${BACKUP_DIR}/backup_${timestamp}"
    
    if [[ ! -d "$KOMARI_DIR" && ! -d "$SUBLINK_DIR" && ! -d "$TUNNEL_DIR" ]]; then
        print_warning "未检测到任何已部署的服务数据，取消备份"
        return 1
    fi
    
    print_info "正在为运行实例建立物理快照..."
    mkdir -p "$backup_path"
    
    for dir in "$KOMARI_DIR" "$SUBLINK_DIR" "$TUNNEL_DIR"; do
        if [[ -d "$dir" ]]; then
            cp -r "$dir" "${backup_path}/$(basename "$dir")" 2>/dev/null || true
        fi
    done
    
    chmod -R 600 "$backup_path" 2>/dev/null || true
    print_success "备份存档成功创建并加锁保护！存放路径: $backup_path"
}

install_docker() {
    print_title "核心运行时环境检查"
    if check_docker_installed; then
        print_info "系统已存在 Docker 主程序，跳过安装阶段"
        return 0
    fi
    
    print_info "正在调取 Docker 引擎安装流水线..."
    if confirm "是否使用国内阿里云镜像源加速拉取基础依赖组件?"; then
        export DOWNLOAD_URL="https://mirrors.aliyun.com/docker-ce"
    fi
    
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
    
    if confirm "是否配置公共 Docker 镜像加速镜像站?"; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<'DAEMONEOF'
{
    "registry-mirrors": [
        "https://docker.1ms.run",
        "https://docker.xuanyuan.me"
    ]
}
DAEMONEOF
        systemctl restart docker
        print_success "镜像站参数载入成功"
    fi
}

create_network() {
    if check_network_exists; then return 0; fi
    print_info "创建集群共享通信专用容器网络: ${NETWORK_NAME}"
    docker network create "$NETWORK_NAME"
}

deploy_komari() {
    print_title "建立 Komari 监控节点"
    if check_container_exists "komari"; then
        print_warning "检测到本地已存在旧的 Komari 容器"
        if confirm "是否销毁该老容器并以最新镜像重构?"; then
            docker rm -f komari 2>/dev/null || true
        else
            print_info "跳过 Komari 模块构建"
            return 0
        fi
    fi
    
    mkdir -p "${KOMARI_DIR}/data"
    
    cat > "$COMPOSE_KOMARI" <<'EOF'
services:
  komari:
    image: ghcr.io/komari-monitor/komari:latest
    container_name: komari
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ./data:/app/data
    networks:
      - cf-tunnel-net
networks:
  cf-tunnel-net:
    external: true
EOF

    cd "$KOMARI_DIR"
    docker compose up -d
    verify_container "komari"
}

deploy_sublink() {
    print_title "建立 Sublink Pro 订阅转换控制台"
    if check_container_exists "sublinkpro"; then
        print_warning "检测到本地已存在旧的 Sublink Pro 容器"
        if confirm "是否销毁该老容器并以最新镜像重构?"; then
            docker rm -f sublinkpro 2>/dev/null || true
        else
            print_info "跳过 Sublink Pro 模块构建"
            return 0
        fi
    fi
    
    mkdir -p "${SUBLINK_DIR}"/{db,template,logs}
    
    cat > "$COMPOSE_SUBLINK" <<'EOF'
services:
  sublinkpro:
    image: zerodeng/sublink-pro
    container_name: sublinkpro
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ./db:/app/db
      - ./template:/app/template
      - ./logs:/app/logs
    networks:
      - cf-tunnel-net
networks:
  cf-tunnel-net:
    external: true
EOF

    cd "$SUBLINK_DIR"
    docker compose up -d
    verify_container "sublinkpro"
}

get_cf_token() {
    local token=""
    print_info "更新 Cloudflare Edge 隧道密钥凭证"
    while true; do
        read -rsp "请输入从 Cloudflare 导出的 Tunnel Token: " token
        echo ""
        if [[ -z "$token" ]]; then continue; fi
        break
    done
    
    mkdir -p "$TUNNEL_DIR"
    echo "TUNNEL_TOKEN=${token}" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    print_success "凭证文件已安全存入本地敏感配置库"
}

deploy_tunnel() {
    print_title "构建 Cloudflare 内网穿透网关"
    
    if [[ -f "$CRED_FILE" ]]; then
        print_info "检测到官方专属认证凭证文件存在，将自动切入文件挂载模式启动..."
        cat > "$COMPOSE_TUNNEL" <<'EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    volumes:
      - ./credentials.json:/etc/cloudflared/credentials.json:ro
    command: tunnel --no-autoupdate --credentials-file /etc/cloudflared/credentials.json run
    networks:
      - cf-tunnel-net
networks:
  cf-tunnel-net:
    external: true
EOF
    else
        read_token
        if [[ -z "$TUNNEL_TOKEN" ]]; then
            get_cf_token
        fi
        
        cat > "$COMPOSE_TUNNEL" <<'EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    command: tunnel --no-autoupdate run
    env_file:
      - .env
    networks:
      - cf-tunnel-net
networks:
  cf-tunnel-net:
    external: true
EOF
    fi

    if check_container_exists "cloudflared"; then
        docker rm -f cloudflared 2>/dev/null || true
    fi

    cd "$TUNNEL_DIR"
    docker compose up -d
    
    if verify_container "cloudflared"; then
        print_success "Cloudflare Tunnel 网关集群部署就绪！"
        print_info "请确保您已前往 Zero Trust 绑定过 Hostname 回源："
        print_info "  -> 📊 监控看板请指向: http://komari:25774"
        print_info "  -> 🔗 订阅控制台请指向: http://sublinkpro:8000"
    fi
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
        print_error "操作受阻：服务 [${service}] 还未生成过配置，请先运行初始化部署。"
        return 1
    fi
    
    cd "$dir"
    
    if [[ "$action" == "start" || "$action" == "update" || "$action" == "rebuild" ]]; then
        create_network
    fi
    
    case $action in
        start) 
            print_info "正在尝试拉起容器 [${service}]..."
            docker compose up -d 
            ;;
        stop) 
            print_info "正在向容器发送平滑停止指令 [${service}]..."
            docker compose stop 
            ;;
        rebuild)
            print_warning "正在一键物理重建容器 [${service}]..."
            if [[ "$service" == "cloudflared" ]]; then
                cd "$BASE_DIR" && deploy_tunnel
            else
                docker compose down && docker compose up -d
                verify_container "$service"
            fi
            ;;
        restart) 
            print_info "正在重载容器任务 [${service}]..."
            docker compose restart 
            ;;
        update) 
            print_info "正在检索服务 [${service}] 的最新镜像标签..."
            docker compose pull && docker compose up -d 
            ;;
        logs) 
            if ! check_container_exists "$service"; then
                print_error "该容器服务尚未实例化，无日志可循"
                return 1
            fi
            print_info "正在查看 [${service}] 实时日志（退出请按 Ctrl+C）..."
            set +e
            docker compose logs --tail 100 -f
            set -e
            ;;
    esac
}

show_status() {
    print_title "服务集群当前拓扑快照"
    printf "  %-20s %-20s %-20s\n" "应用逻辑层" "系统级容器名" "当前健康度"
    printf "  %-20s %-20s %-20s\n" "--------" "--------" "--------"
    printf "  %-20s %-20s %-42b\n" "Komari 监控" "komari" "$(get_container_status komari)"
    printf "  %-20s %-20s %-42b\n" "Sublink Pro 控制台" "sublinkpro" "$(get_container_status sublinkpro)"
    printf "  %-20s %-20s %-42b\n" "CF Tunnel 隧道" "cloudflared" "$(get_container_status cloudflared)"
    echo ""
}

init_deploy() {
    if [[ -d "$KOMARI_DIR" || -d "$SUBLINK_DIR" || -d "$TUNNEL_DIR" ]]; then
        print_warning "注意：检测到您的服务器此前可能部署过本脚本的相关业务组件。"
        if ! confirm "执行初始化会尝试覆写并完全重建这些容器，是否同意继续?"; then
            print_info "已被用户取消，终止部署进程。"
            return 0
        fi
    fi

    install_docker
    create_network
    
    if [[ ! -f "$CRED_FILE" ]]; then
        get_cf_token
    else
        print_success "检测到本地已存在官方专用凭证 credentials.json，初始化自动适配，免去 Token 交互"
    fi
    
    deploy_komari
    deploy_sublink
    deploy_tunnel
    show_status
}

full_uninstall() {
    print_title "危险：集群全面清洗与卸载向导"
    if ! confirm "确定要物理剔除所有的业务容器、网络路由以及您保存的全部配置文件吗?"; then 
        return 0
    fi
    
    print_warning "正在强制停止并清理集群进程生命周期..."
    cd "$TUNNEL_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    cd "$SUBLINK_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    cd "$KOMARI_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
    
    print_info "注销跨域共享网卡桥接..."
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
    
    print_info "擦除磁盘物理遗存配置目录..."
    rm -rf "$KOMARI_DIR" "$SUBLINK_DIR" "$TUNNEL_DIR" "$INSTALL_PATH"
    print_success "环境已全部回归至纯净初始状态。"
    
    # ✅ 采纳建议：回归原汁原味的 return 0。维持函数式管道的连续性，确保用户能确认卸载结果，杜绝突兀中断。
    return 0
}

show_menu() {
    clear
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN}       Docker 服务集群统一管理面板 v${SCRIPT_VERSION}         ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "  1) 查看集群拓扑状态       2) 🚀 初始化全套集群部署"
    echo -e " -----------------------------------------------------"
    echo -e "  3) 🚀 启动 Komari监控     4) ⏸️ 停止 Komari监控     5) 🔄 一键重建 Komari"
    echo -e "  6) 🚀 启动 Sublink转换    7) ⏸️ 停止 Sublink转换    8) 🔄 一键重建 Sublink"
    echo -e "  9) 🚀 启动 CF Tunnel      10) ⏸️ 停止 CF Tunnel     11) 🔄 一键重建 Tunnel"
    echo -e " -----------------------------------------------------"
    echo -e "  12) 📋 审查 Komari 日志    13) 📋 审查 Sublink 日志  14) 📋 审查 Tunnel 日志"
    echo -e " -----------------------------------------------------"
    echo -e " 15) 💾 物理快照数据备份    16) 🔑 修改 CF Tunnel 密钥"
    echo -e " 17) 🗑️ 完全卸载整个集群    0) 退出控制台"
    echo -e "${CYAN}=====================================================${NC}"
}

handle_menu() {
    while true; do
        show_menu
        read -rp "请下达数字操作指令: " choice
        case $choice in
            0) exit 0 ;;
            1) show_status ;;
            2) init_deploy ;;
            3) service_control komari start ;;
            4) service_control komari stop ;;
            5) service_control komari rebuild ;;
            6) service_control sublinkpro start ;;
            7) service_control sublinkpro stop ;;
            8) service_control sublinkpro rebuild ;;
            9) service_control cloudflared start ;;
            10) service_control cloudflared stop ;;
            11) service_control cloudflared rebuild ;;
            12) service_control komari logs ;;
            13) service_control sublinkpro logs ;;
            14) service_control cloudflared logs ;;
            15) backup_data ;;
            16) get_cf_token ;;
            17) full_uninstall ;;
            *) print_error "未知指令" ;;
        esac
        if [[ ! "$choice" =~ ^(12|13|14)$ ]]; then
            echo ""
            read -rp "回车(Enter)返回主菜单面板..."
        fi
    done
}

main() {
    check_root
    
    if [[ "$(readlink -f "$0")" != "$INSTALL_PATH" ]]; then
        if [[ ! -f "$INSTALL_PATH" ]]; then
            print_info "首次运行，正在为您在当前环境中建立全局快捷指令: ${SCRIPT_NAME}..."
            
            if [[ "$0" == "bash" || ! -f "$0" ]]; then
                rm -f "$INSTALL_PATH" 2>/dev/null || true
                if ! curl -fsSL https://raw.githubusercontent.com/opyzzzz/argox/refs/heads/main/KSC-docker.sh -o "$INSTALL_PATH" 2>/dev/null; then
                    print_warning "由于直连 GitHub 失败，快捷命令文件可能写入不完整，系统已自动转入运行态自克隆方案..."
                    cp "$(readlink -f "$0")" "$INSTALL_PATH" 2>/dev/null || true
                fi
            else
                rm -f "$INSTALL_PATH" 2>/dev/null || true
                cp "$(readlink -f "$0")" "$INSTALL_PATH" 2>/dev/null || true
            fi
            
            if [[ -f "$INSTALL_PATH" ]]; then
                chmod +x "$INSTALL_PATH"
                print_success "快捷命令写入成功！后续只需在任何路径输入 [ ${SCRIPT_NAME} ] 即可随时管理服务。"
            fi
        fi
    fi
    
    check_environment || true
    handle_menu
}

main "$@"
