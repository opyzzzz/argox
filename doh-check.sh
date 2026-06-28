#!/bin/sh
#==================================================
# DNS 全面检测脚本 v4.5 - 运行时修复版
# 支持: SmartDNS / 系统DNS / 手动指定DNS
# 修复: nslookup输出解析、IPv6提取、CDN误报
# 新增: 自动安装缺失依赖
# 国际版 - 不含国内检测地址
# 兼容: Alpine/Debian/Ubuntu (bash/dash/ash)
# 更新: 2026-06-28
#==================================================

set +e

#==================================================
# 环境变量配置（可外部覆盖）
#==================================================
export DNS_CHECK_DOMAINS="${DNS_CHECK_DOMAINS:-google.com cloudflare.com github.com}"
export DNS_CHECK_SERVERS="${DNS_CHECK_SERVERS:-8.8.8.8 1.1.1.1 9.9.9.9}"
export DNS_CHECK_IPV6="${DNS_CHECK_IPV6:-2001:4860:4860::8888 2606:4700:4700::1111}"
export DNS_CHECK_DOH_SERVERS="${DNS_CHECK_DOH_SERVERS:-Cloudflare|https://cloudflare-dns.com/dns-query Google|https://dns.google/resolve Quad9|https://dns.quad9.net/dns-query}"
export DNS_CHECK_DOT_SERVERS="${DNS_CHECK_DOT_SERVERS:-Cloudflare|1.1.1.1 Google|8.8.8.8 Quad9|9.9.9.9}"

#==================================================
# 颜色支持检测
#==================================================
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
fi

#==================================================
# 变量初始化
#==================================================
PASS=0; FAIL=0; WARN=0; SKIP=0; TOTAL=0
CHECK_MODE=""; DNS_TARGET=""
QUIET="${QUIET:-0}"; VERBOSE="${VERBOSE:-0}"
AUTO_INSTALL="${AUTO_INSTALL:-0}"

#==================================================
# 随机数生成（跨平台兼容）
#==================================================
random_hex() {
    if [ -n "${RANDOM:-}" ] 2>/dev/null; then
        printf '%04x' "$RANDOM"
    elif [ -c /dev/urandom ]; then
        od -A n -t x2 -N 2 /dev/urandom 2>/dev/null | tr -d ' \n'
    else
        printf '%04x' "$(( ($$ + $(date +%s 2>/dev/null || echo 0)) % 65536 ))"
    fi
}

#==================================================
# 临时文件管理
#==================================================
TMPFILE=$(mktemp 2>/dev/null)
if [ -z "$TMPFILE" ]; then
    TMPFILE="/tmp/dns_check_$$_$(date +%s 2>/dev/null || echo 0)_$(random_hex).tmp"
    touch "$TMPFILE" 2>/dev/null || {
        echo "无法创建临时文件: $TMPFILE"
        exit 1
    }
fi
export TMPFILE

#==================================================
# 进程清理陷阱
#==================================================
cleanup() {
    job_pids=$(jobs -p 2>/dev/null)
    if [ -n "$job_pids" ]; then
        for pid in $job_pids; do
            [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
        done
    fi
    wait 2>/dev/null
    
    if [ -n "$TMPFILE" ]; then
        rm -f "${TMPFILE}"* 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM HUP

#==================================================
# 工具函数
#==================================================
ICON_OK="${GREEN}✓${NC}"; ICON_FAIL="${RED}✗${NC}"
ICON_WARN="${YELLOW}⚠${NC}"; ICON_INFO="${CYAN}ℹ${NC}"; ICON_SKIP="${DIM}⊘${NC}"

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_sub() {
    echo ""
    echo -e "${BOLD}${CYAN}  ▸ $1${NC}"
}

print_detail() {
    echo -e "    ${DIM}$1${NC}"
}

check_pass() {
    echo -e "  ${ICON_OK} $1"
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
}

check_fail() {
    echo -e "  ${ICON_FAIL} $1"
    [ -n "$2" ] && echo -e "    ${ICON_INFO} 修复: $2"
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
}

check_warn() {
    echo -e "  ${ICON_WARN} $1"
    [ -n "$2" ] && echo -e "    ${ICON_INFO} 建议: $2"
    WARN=$((WARN + 1))
    TOTAL=$((TOTAL + 1))
}

check_info() {
    echo -e "  ${ICON_INFO} $1: ${CYAN}$2${NC}"
}

check_skip() {
    echo -e "  ${ICON_SKIP} $1"
    SKIP=$((SKIP + 1))
    TOTAL=$((TOTAL + 1))
}

# 安全整数转换
safe_int() {
    case "$1" in
        ''|*[!0-9]*) echo "0" ;;
        *)
            val=$(printf '%s' "$1" | sed 's/^0*//')
            [ -z "$val" ] && val=0
            echo "$val"
            ;;
    esac
}

#==================================================
# 计时函数
#==================================================
timer_start() {
    timer_id="$(date +%s 2>/dev/null || echo 0)_$(random_hex)"
    timer_file="${TMPFILE}.timer.${timer_id}"
    
    if date +%s%3N >/dev/null 2>&1; then
        date +%s%3N > "$timer_file" 2>/dev/null
    else
        date +%s | awk '{printf "%d", $1 * 1000}' > "$timer_file" 2>/dev/null
    fi
    
    printf '%s' "$timer_file"
}

timer_end() {
    timer_file="$1"
    start=0
    
    if [ -n "$timer_file" ] && [ -f "$timer_file" ]; then
        start=$(cat "$timer_file" 2>/dev/null || echo 0)
        rm -f "$timer_file" 2>/dev/null
    fi
    
    case "$start" in
        ''|*[!0-9]*) start=0 ;;
    esac
    
    if date +%s%3N >/dev/null 2>&1; then
        end=$(date +%s%3N)
    else
        end=$(date +%s | awk '{printf "%d", $1 * 1000}')
    fi
    
    diff=$((end - start))
    [ "$diff" -lt 0 ] && diff=0
    echo "$diff"
}

#==================================================
# 安全的超时执行
#==================================================
run_with_timeout() {
    seconds="$1"; shift
    
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@" 2>/dev/null
        return $?
    fi
    
    "$@" 2>/dev/null &
    cmd_pid=$!
    
    (
        sleep "$seconds"
        kill -9 "$cmd_pid" 2>/dev/null
    ) &
    watchdog_pid=$!
    
    wait "$cmd_pid" 2>/dev/null
    exit_code=$?
    
    kill -9 "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
    
    return $exit_code
}

#==================================================
# grep计数（跨平台兼容）
#==================================================
grep_count() {
    pattern="$1"; file="$2"
    if [ -f "$file" ]; then
        grep "$pattern" "$file" 2>/dev/null | wc -l | awk '{print $1}'
    else
        echo "0"
    fi
}

count_unique_lines() {
    printf '%s' "$1" | awk '{for(i=1;i<=NF;i++) print $i}' | sort -u | wc -l | awk '{print $1}'
}

#==================================================
# 安全的文件读取
#==================================================
safe_read_file() {
    file="$1"; pattern="${2:-.*}"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null | grep "$pattern" 2>/dev/null > "${TMPFILE}.read.$$"
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            printf '%s\n' "$line"
        done < "${TMPFILE}.read.$$"
        rm -f "${TMPFILE}.read.$$" 2>/dev/null
    fi
}

#==================================================
# 服务器列表安全解析
#==================================================
parse_server_list() {
    list="$1"
    [ -z "$list" ] && return
    
    saved_ifs="$IFS"
    IFS=' '
    for item in $list; do
        [ -z "$item" ] && continue
        printf '%s\n' "$item"
    done
    IFS="$saved_ifs"
}

#==================================================
# SmartDNS进程检测
#==================================================
smartdns_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep smartdns >/dev/null 2>&1
    elif command -v pidof >/dev/null 2>&1; then
        pidof smartdns >/dev/null 2>&1
    else
        ps 2>/dev/null | grep -v grep | grep -q smartdns
    fi
}

#==================================================
# resolv.conf符号链接目标获取
#==================================================
get_resolv_target() {
    if command -v realpath >/dev/null 2>&1; then
        realpath /etc/resolv.conf 2>/dev/null
    elif readlink -f /etc/resolv.conf >/dev/null 2>&1; then
        readlink -f /etc/resolv.conf 2>/dev/null
    elif readlink /etc/resolv.conf >/dev/null 2>&1; then
        readlink /etc/resolv.conf 2>/dev/null
    fi
}

#==================================================
# 获取所有nameserver（用于IP过滤）
#==================================================
get_all_nameserver_ips() {
    if [ -f /etc/resolv.conf ]; then
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}'
    fi
}

#==================================================
# DNS 解析核心函数
#==================================================

# 方法1: dig
dns_dig() {
    domain="$1"; type="${2:-A}"; dns="${3:-}"
    cmd="dig +time=3 +tries=1 +short"
    [ -n "$dns" ] && cmd="$cmd @$dns"
    run_with_timeout 5 $cmd -t "$type" "$domain" 2>/dev/null || echo ""
}

# 方法2: host（兼容Alpine busybox）
dns_host() {
    domain="$1"; type="${2:-A}"; dns="${3:-}"
    
    if [ -n "$dns" ]; then
        raw_output=$(run_with_timeout 5 host -t "$type" "$domain" "$dns" 2>/dev/null)
    else
        raw_output=$(run_with_timeout 5 host -t "$type" "$domain" 2>/dev/null)
    fi
    
    # 兼容多种输出格式
    echo "$raw_output" | grep -E "has address|has IPv6 address|address" | awk '{print $NF}' | head -1
}

# 方法3: nslookup（修复：正确解析Address行，跳过DNS服务器行）
dns_nslookup() {
    domain="$1"; type="${2:-A}"; dns="${3:-}"
    
    if [ -n "$dns" ]; then
        raw_output=$(run_with_timeout 5 nslookup -timeout=3 -type="$type" "$domain" "$dns" 2>/dev/null)
    else
        raw_output=$(run_with_timeout 5 nslookup -timeout=3 -type="$type" "$domain" 2>/dev/null)
    fi
    
    # 使用awk状态机：Name: 之后才提取 Address:
    echo "$raw_output" | awk -v dns="$dns" '
        /^Name:/ { in_section=1; next }
        in_section && /^Address:/ {
            ip = $NF
            # 排除包含 # 的行（DNS服务器标记如 10.91.0.1#53）
            if (ip !~ /#/) {
                print ip
                exit
            }
        }
    '
}

# 方法4: getent
dns_getent() {
    domain="$1"
    getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1 || echo ""
}

# 方法5: curl DoH
dns_doh() {
    domain="$1"; type="${2:-A}"; resolver="${3:-https://cloudflare-dns.com/dns-query}"
    type_num=1
    [ "$type" = "AAAA" ] && type_num=28
    
    response=$(run_with_timeout 5 curl -s -H "accept: application/dns-json" \
        "${resolver}?name=${domain}&type=${type_num}" 2>/dev/null)
    
    if [ -n "$response" ] && printf '%s' "$response" | grep -qE '"Status":[[:space:]]*0'; then
        flat_response=$(printf '%s' "$response" | tr -d '\n')
        
        # 方法1: 从Answer数组提取
        ip=$(printf '%s' "$flat_response" | sed -n 's/.*"Answer":\[[^]]*"data":"\([^"]*\)".*/\1/p' | head -1)
        # 方法2: 提取所有data字段的第一个
        [ -z "$ip" ] && ip=$(printf '%s' "$flat_response" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"$//')
        
        echo "$ip"
    fi
}

# 智能解析
smart_resolve() {
    domain="$1"; type="${2:-A}"; dns="${3:-}"; method="${4:-auto}"
    
    case "$method" in
        dig)    dns_dig "$domain" "$type" "$dns" ;;
        host)   dns_host "$domain" "$type" "$dns" ;;
        nslookup) dns_nslookup "$domain" "$type" "$dns" ;;
        getent) dns_getent "$domain" ;;
        doh)    dns_doh "$domain" "$type" "$dns" ;;
        *)
            if command -v dig >/dev/null 2>&1; then
                dns_dig "$domain" "$type" "$dns"
            elif command -v host >/dev/null 2>&1; then
                dns_host "$domain" "$type" "$dns"
            elif command -v nslookup >/dev/null 2>&1; then
                dns_nslookup "$domain" "$type" "$dns"
            elif command -v getent >/dev/null 2>&1; then
                dns_getent "$domain"
            else
                echo ""
            fi
            ;;
    esac
}

# 提取IPv4地址（修复：过滤所有nameserver地址）
extract_ipv4() {
    result="$1"; dns_server="${2:-}"
    
    all_ips=$(printf '%s' "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
    
    # 构建过滤列表
    filter_list="^127\.0\.0\.1$|^0\.0\.0\.0$|^255\.255\.255\.255$"
    [ -n "$dns_server" ] && filter_list="${filter_list}|^${dns_server}$"
    
    # 从resolv.conf获取所有nameserver IPv4并加入过滤
    get_all_nameserver_ips | while IFS= read -r ns; do
        [ -z "$ns" ] && continue
        case "$ns" in
            *:*) continue ;;   # 跳过IPv6
            127.*) continue ;;
            *)
                escaped_ns=$(echo "$ns" | sed 's/\./\\./g')
                filter_list="${filter_list}|^${escaped_ns}$"
                ;;
        esac
    done
    
    # 实际的过滤需要在主进程中完成
    # 使用临时文件传递过滤列表
    printf '%s' "$filter_list" > "${TMPFILE}.filter.$$"
    
    echo "$all_ips" | grep -vE -f "${TMPFILE}.filter.$$" 2>/dev/null | head -1
    
    rm -f "${TMPFILE}.filter.$$" 2>/dev/null
}

# 修复后的 extract_ipv4（不使用子shell）
extract_ipv4_fixed() {
    result="$1"; dns_server="${2:-}"
    
    all_ips=$(printf '%s' "$result" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
    
    # 构建过滤表达式
    filter="127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255"
    [ -n "$dns_server" ] && filter="${filter}|$(echo "$dns_server" | sed 's/\./\\./g')"
    
    # 添加所有resolv.conf中的nameserver
    for ns in $(get_all_nameserver_ips); do
        case "$ns" in
            *:*|127.*) continue ;;
            *) filter="${filter}|$(echo "$ns" | sed 's/\./\\./g')" ;;
        esac
    done
    
    echo "$all_ips" | grep -vE "^(${filter})$" | head -1
}

# 提取IPv6地址（修复：过滤端口号和短字符串）
extract_ipv6() {
    result="$1"
    
    # 第一步：提取可能的IPv6候选
    candidates=$(printf '%s' "$result" | grep -Eo '([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}' 2>/dev/null)
    
    # 第二步：也匹配简写格式
    [ -z "$candidates" ] && candidates=$(printf '%s' "$result" | grep -Eo '([0-9a-fA-F:]+:+[0-9a-fA-F:]+)' 2>/dev/null)
    
    printf '%s' "$candidates" | while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        
        # 过滤长度过短的（可能是端口号如 1:53）
        [ "${#candidate}" -lt 4 ] && continue
        
        case "$candidate" in
            ::1|::)        continue ;;
            fe80:*)        continue ;;
            fc00:*|fd00:*) continue ;;
            ff00:*)        continue ;;
            2001:db8:*)    continue ;;
            *)
                printf '%s' "$candidate"
                return
                ;;
        esac
    done | head -1
}

# 统一提取IP
extract_ip() {
    result="$1"; type="${2:-A}"; dns_server="${3:-}"
    
    if [ "$type" = "AAAA" ]; then
        extract_ipv6 "$result"
    else
        extract_ipv4_fixed "$result" "$dns_server"
    fi
}

#==================================================
# 自动安装依赖函数
#==================================================
auto_install_dependencies() {
    MISSING=""
    
    # 检查缺失的工具
    for tool in dig host nslookup getent curl nc ping awk sed; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            MISSING="$MISSING $tool"
        fi
    done
    
    [ -z "$MISSING" ] && return 0
    
    echo ""
    echo -e "  ${ICON_WARN} 缺少工具:${MISSING}"
    
    # 如果没有自动安装权限，仅提示
    if [ "$AUTO_INSTALL" != "1" ]; then
        echo ""
        echo -e "  ${BOLD}自动安装缺失依赖:${NC}"
        echo ""
        
        if [ -f /etc/alpine-release ]; then
            echo -e "  ${CYAN}Alpine Linux 安装命令:${NC}"
            echo -e "    ${BOLD}apk add bind-tools curl netcat-openbsd iputils${NC}"
            echo ""
            echo -e "  ${DIM}bind-tools 提供: dig, host, nslookup${NC}"
            echo -e "  ${DIM}curl        提供: curl (用于DoH检测)${NC}"
            echo -e "  ${DIM}netcat      提供: nc (用于端口检测)${NC}"
            echo -e "  ${DIM}iputils     提供: ping (用于连通性检测)${NC}"
        elif [ -f /etc/debian_version ]; then
            echo -e "  ${CYAN}Debian/Ubuntu 安装命令:${NC}"
            echo -e "    ${BOLD}apt-get update && apt-get install -y dnsutils curl netcat-openbsd iputils-ping${NC}"
            echo ""
            echo -e "  ${DIM}dnsutils    提供: dig, host, nslookup${NC}"
            echo -e "  ${DIM}curl        提供: curl (用于DoH检测)${NC}"
            echo -e "  ${DIM}netcat      提供: nc (用于端口检测)${NC}"
            echo -e "  ${DIM}iputils-ping提供: ping (用于连通性检测)${NC}"
        elif [ -f /etc/redhat-release ]; then
            echo -e "  ${CYAN}RHEL/CentOS/Fedora 安装命令:${NC}"
            echo -e "    ${BOLD}yum install -y bind-utils curl nmap-ncat iputils${NC}"
            echo ""
            echo -e "  ${DIM}bind-utils  提供: dig, host, nslookup${NC}"
            echo -e "  ${DIM}curl        提供: curl${NC}"
            echo -e "  ${DIM}nmap-ncat   提供: nc${NC}"
            echo -e "  ${DIM}iputils     提供: ping${NC}"
        elif command -v brew >/dev/null 2>&1; then
            echo -e "  ${CYAN}macOS Homebrew 安装命令:${NC}"
            echo -e "    ${BOLD}brew install bind curl netcat${NC}"
        else
            echo -e "  ${YELLOW}未识别的系统，请手动安装以下工具:${NC}"
            echo -e "  ${DIM}dig, host, nslookup - DNS查询工具${NC}"
            echo -e "  ${DIM}curl - HTTP客户端${NC}"
            echo -e "  ${DIM}nc - 网络连接工具${NC}"
            echo -e "  ${DIM}ping - 网络连通性工具${NC}"
        fi
        
        echo ""
        echo -e "  ${ICON_INFO} 提示: 设置环境变量 ${CYAN}AUTO_INSTALL=1${NC} 可自动安装"
        echo -e "  ${ICON_INFO} 示例: ${CYAN}AUTO_INSTALL=1 $0${NC}"
        echo ""
        return 1
    fi
    
    # 自动安装模式
    echo ""
    echo -e "  ${BOLD}正在自动安装缺失依赖...${NC}"
    echo ""
    
    if [ -f /etc/alpine-release ]; then
        echo -e "  ${DIM}检测到 Alpine Linux${NC}"
        
        # 检查是否有root权限
        if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
            echo -e "  ${ICON_FAIL} 需要 root 权限安装依赖"
            echo -e "  ${ICON_INFO} 请使用: ${CYAN}sudo $0${NC}"
            return 1
        fi
        
        echo -e "  ${DIM}运行: apk add bind-tools curl netcat-openbsd iputils${NC}"
        if apk add bind-tools curl netcat-openbsd iputils 2>/dev/null; then
            echo -e "  ${ICON_OK} 依赖安装成功"
        else
            echo -e "  ${ICON_FAIL} 安装失败，请手动安装"
            return 1
        fi
        
    elif [ -f /etc/debian_version ]; then
        echo -e "  ${DIM}检测到 Debian/Ubuntu${NC}"
        
        if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
            echo -e "  ${ICON_FAIL} 需要 root 权限安装依赖"
            echo -e "  ${ICON_INFO} 请使用: ${CYAN}sudo $0${NC}"
            return 1
        fi
        
        echo -e "  ${DIM}运行: apt-get update${NC}"
        apt-get update -qq 2>/dev/null
        
        echo -e "  ${DIM}运行: apt-get install -y dnsutils curl netcat-openbsd iputils-ping${NC}"
        if apt-get install -y dnsutils curl netcat-openbsd iputils-ping 2>/dev/null; then
            echo -e "  ${ICON_OK} 依赖安装成功"
        else
            echo -e "  ${ICON_FAIL} 安装失败，请手动安装"
            return 1
        fi
        
    elif [ -f /etc/redhat-release ]; then
        echo -e "  ${DIM}检测到 RHEL/CentOS/Fedora${NC}"
        
        if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
            echo -e "  ${ICON_FAIL} 需要 root 权限安装依赖"
            echo -e "  ${ICON_INFO} 请使用: ${CYAN}sudo $0${NC}"
            return 1
        fi
        
        echo -e "  ${DIM}运行: yum install -y bind-utils curl nmap-ncat iputils${NC}"
        if yum install -y bind-utils curl nmap-ncat iputils 2>/dev/null; then
            echo -e "  ${ICON_OK} 依赖安装成功"
        else
            echo -e "  ${ICON_FAIL} 安装失败，请手动安装"
            return 1
        fi
        
    elif command -v brew >/dev/null 2>&1; then
        echo -e "  ${DIM}检测到 macOS + Homebrew${NC}"
        echo -e "  ${DIM}运行: brew install bind curl netcat${NC}"
        if brew install bind curl netcat 2>/dev/null; then
            echo -e "  ${ICON_OK} 依赖安装成功"
        else
            echo -e "  ${ICON_FAIL} 安装失败，请手动安装"
            return 1
        fi
        
    else
        echo -e "  ${ICON_FAIL} 未识别的系统，无法自动安装"
        return 1
    fi
    
    echo ""
    return 0
}

#==================================================
# 环境依赖检查
#==================================================
check_dependencies() {
    MISSING_TOOLS=""
    
    for tool in dig host nslookup getent curl nc ping awk sed; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            MISSING_TOOLS="$MISSING_TOOLS $tool"
        fi
    done
    
    if [ -n "$MISSING_TOOLS" ]; then
        echo ""
        echo -e "  ${ICON_WARN} 缺少工具:${MISSING_TOOLS}"
        
        # 核心工具缺失提示
        if ! command -v dig >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
            echo -e "  ${ICON_FAIL} 无DNS查询工具可用！"
            echo -e "  ${ICON_INFO} 安装后可使用完整检测功能"
        elif ! command -v dig >/dev/null 2>&1; then
            echo -e "  ${ICON_WARN} 缺少 dig，部分高级功能不可用"
        fi
        echo ""
    fi
}

#==================================================
# 检测模式判断
#==================================================
detect_mode() {
    SMARTDNS_BIN=""
    for path in /usr/bin/smartdns /usr/sbin/smartdns /usr/local/bin/smartdns; do
        if [ -x "$path" ]; then
            SMARTDNS_BIN="$path"
            break
        fi
    done

    if [ -n "$SMARTDNS_BIN" ] && smartdns_running; then
        CHECK_MODE="smartdns"
        DNS_TARGET="127.0.0.1"
        return 0
    else
        CHECK_MODE="system"
        DNS_TARGET=""
        return 1
    fi
}

#==================================================
# 第1部分: 系统环境
#==================================================
check_system_environment() {
    print_section "第1部分: 系统环境"

    print_sub "操作系统"
    if [ -f /etc/alpine-release ]; then
        OS="Alpine $(cat /etc/alpine-release)"
    elif [ -f /etc/os-release ]; then
        OS=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d'"' -f2)
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release 2>/dev/null)
    elif command -v sw_vers >/dev/null 2>&1; then
        OS="macOS $(sw_vers -productVersion 2>/dev/null)"
    else
        OS="Unknown"
    fi
    check_info "发行版" "$OS"
    check_info "内核" "$(uname -r)"
    check_info "架构" "$(uname -m)"

    print_sub "虚拟化环境"
    if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
        check_warn "LXC 容器环境"
    elif grep -qE "docker|podman" /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        check_warn "容器环境 (Docker/Podman)"
    else
        check_pass "物理机/KVM 环境"
    fi

    print_sub "Init 系统"
    if [ -f /run/systemd/system ]; then
        INIT="systemd"
        check_pass "Init: systemd"
    elif [ -f /sbin/openrc ]; then
        INIT="openrc"
        check_pass "Init: OpenRC"
    else
        INIT="unknown"
        check_warn "未知 Init 系统"
    fi
    
    check_dependencies
}

#==================================================
# 第2部分: DNS 服务状态
#==================================================
check_dns_service() {
    print_section "第2部分: DNS 服务状态"

    if [ "$CHECK_MODE" = "smartdns" ]; then
        check_pass "检测到 SmartDNS 运行中"
        
        print_sub "SmartDNS 版本"
        VER=$("$SMARTDNS_BIN" -v 2>&1 | head -1)
        check_info "版本" "$VER"

        print_sub "配置文件"
        CONFIG_FILE="/etc/smartdns/smartdns.conf"
        if [ -f "$CONFIG_FILE" ]; then
            check_pass "配置文件存在"
            
            UDP_COUNT=$(safe_int "$(grep_count "^server " "$CONFIG_FILE")")
            DOH_COUNT=$(safe_int "$(grep_count "^server-https" "$CONFIG_FILE")")
            DOT_COUNT=$(safe_int "$(grep_count "^server-tls" "$CONFIG_FILE")")
            TOTAL_UPSTREAM=$((UDP_COUNT + DOH_COUNT + DOT_COUNT))
            
            if [ "$TOTAL_UPSTREAM" -gt 0 ] 2>/dev/null; then
                check_pass "上游 DNS: $TOTAL_UPSTREAM 个"
                check_info "上游统计" "UDP:$UDP_COUNT DoH:$DOH_COUNT DoT:$DOT_COUNT"
            else
                check_fail "缺少上游 DNS 配置"
            fi
            
            if [ "${QUIET:-0}" -eq 0 ]; then
                echo ""
                echo -e "  ${BOLD}配置摘要:${NC}"
                safe_read_file "$CONFIG_FILE" "^bind|^server |^server-https|^server-tls"
            fi
        else
            check_fail "配置文件不存在"
        fi

        print_sub "服务状态"
        case "$INIT" in
            systemd)
                systemctl is-active smartdns >/dev/null 2>&1 && \
                    check_pass "systemd 服务: active" || \
                    check_fail "systemd 服务: inactive"
                systemctl is-enabled smartdns >/dev/null 2>&1 && \
                    check_pass "开机自启: 已启用" || \
                    check_warn "开机自启: 未启用"
                ;;
            openrc)
                rc-service smartdns status 2>&1 | grep -q "started" && \
                    check_pass "OpenRC 服务: started" || \
                    check_warn "OpenRC 服务: 未启动"
                ;;
        esac
    else
        check_warn "未检测到 SmartDNS，切换到系统 DNS 检测"
        
        print_sub "系统 DNS 配置"
        if [ -f /etc/resolv.conf ]; then
            check_pass "/etc/resolv.conf 存在"
            if [ -L /etc/resolv.conf ]; then
                target=$(get_resolv_target)
                check_info "符号链接" "→ ${target:-未知}"
            fi
            
            if [ "${QUIET:-0}" -eq 0 ]; then
                echo ""
                echo -e "  ${BOLD}当前 DNS 服务器:${NC}"
                safe_read_file /etc/resolv.conf "^nameserver"
            fi
            
            NS_COUNT=$(grep_count '^nameserver' /etc/resolv.conf)
            if [ "$(safe_int "$NS_COUNT")" -eq 0 ]; then
                check_fail "未配置任何 nameserver"
            else
                check_info "DNS服务器数量" "$NS_COUNT 个"
            fi
            
            if [ "${QUIET:-0}" -eq 0 ]; then
                safe_read_file /etc/resolv.conf "^search|^options" | while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    print_detail "$line"
                done
            fi
        else
            check_fail "/etc/resolv.conf 不存在"
        fi
        
        if [ -f /etc/nsswitch.conf ]; then
            hosts_line=$(grep "^hosts:" /etc/nsswitch.conf 2>/dev/null)
            if printf '%s' "$hosts_line" | grep -q "dns"; then
                check_pass "nsswitch.conf: DNS 已启用"
            fi
        fi
    fi
}

#==================================================
# 第3部分: 多方法解析对比
#==================================================
check_resolution_methods() {
    print_section "第3部分: 多方法解析对比"
    
    test_domains="google.com cloudflare.com github.com"
    
    for domain in $test_domains; do
        print_sub "域名: $domain"
        
        for method in dig host nslookup; do
            if command -v "$method" >/dev/null 2>&1; then
                timer_id=$(timer_start)
                result=$(smart_resolve "$domain" "A" "$DNS_TARGET" "$method")
                elapsed=$(timer_end "$timer_id")
                
                ip=$(extract_ipv4_fixed "$result" "$DNS_TARGET")
                if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
                    check_pass "$method (${elapsed}ms) → $ip"
                else
                    check_fail "$method (${elapsed}ms) → 解析失败"
                fi
            else
                check_skip "$method (未安装)"
            fi
        done
        
        if command -v curl >/dev/null 2>&1; then
            timer_id=$(timer_start)
            result=$(smart_resolve "$domain" "A" "" "doh")
            elapsed=$(timer_end "$timer_id")
            ip=$(extract_ipv4_fixed "$result")
            if [ -n "$ip" ]; then
                check_pass "doh (${elapsed}ms) → $ip"
            else
                check_fail "doh (${elapsed}ms) → 解析失败"
            fi
        fi
    done
}

#==================================================
# 第4部分: 地理分布式解析检测
#==================================================
check_geo_resolution() {
    print_section "第4部分: 地理分布式解析检测"
    
    print_sub "北美区域"
    for domain in google.com cloudflare.com github.com microsoft.com amazon.com; do
        result=$(smart_resolve "$domain" "A" "$DNS_TARGET")
        ip=$(extract_ipv4_fixed "$result" "$DNS_TARGET")
        [ -n "$ip" ] && check_pass "$domain → $ip" || check_fail "$domain 解析失败"
    done
    
    print_sub "欧洲区域"
    for domain in bbc.co.uk deutsche-bahn.com ovh.com; do
        result=$(smart_resolve "$domain" "A" "$DNS_TARGET")
        ip=$(extract_ipv4_fixed "$result" "$DNS_TARGET")
        [ -n "$ip" ] && check_pass "$domain → $ip" || check_fail "$domain 解析失败"
    done
    
    print_sub "亚太区域"
    for domain in japan-post.jp niconico.jp rakuten.co.jp; do
        result=$(smart_resolve "$domain" "A" "$DNS_TARGET")
        ip=$(extract_ipv4_fixed "$result" "$DNS_TARGET")
        [ -n "$ip" ] && check_pass "$domain → $ip" || check_warn "$domain 解析失败"
    done
    
    print_sub "CDN 加速服务"
    for domain in cdn.jsdelivr.net unpkg.com fonts.googleapis.com; do
        result=$(smart_resolve "$domain" "A" "$DNS_TARGET")
        ip=$(extract_ipv4_fixed "$result" "$DNS_TARGET")
        [ -n "$ip" ] && check_pass "$domain → $ip" || check_warn "$domain CDN 解析失败"
    done
}

#==================================================
# 第5部分: DNS记录类型检测
#==================================================
check_record_types() {
    print_section "第5部分: DNS 记录类型检测"
    
    print_sub "A 记录 (IPv4)"
    for domain in google.com cloudflare.com github.com; do
        result=$(smart_resolve "$domain" "A" "$DNS_TARGET")
        ip=$(extract_ipv4_fixed "$result" "$DNS_TARGET")
        [ -n "$ip" ] && check_pass "$domain → $ip" || check_fail "$domain A记录失败"
    done
    
    print_sub "AAAA 记录 (IPv6)"
    for domain in google.com cloudflare.com ipv6.google.com; do
        result=$(smart_resolve "$domain" "AAAA" "$DNS_TARGET")
        ip=$(extract_ipv6 "$result")
        [ -n "$ip" ] && check_pass "$domain → $ip" || check_warn "$domain 无AAAA记录"
    done
    
    print_sub "CNAME 记录 (别名)"
    if command -v dig >/dev/null 2>&1; then
        for domain in www.github.com cdn.jsdelivr.net; do
            cname=$(dig +time=3 +tries=1 +short CNAME "$domain" @${DNS_TARGET:-8.8.8.8} 2>/dev/null | head -1 | sed 's/\.$//')
            [ -n "$cname" ] && check_pass "$domain → $cname" || check_info "$domain" "无 CNAME"
        done
    else
        check_skip "CNAME检测需要 dig 工具"
    fi
    
    print_sub "MX 记录 (邮件交换)"
    if command -v dig >/dev/null 2>&1; then
        for domain in gmail.com protonmail.com; do
            mx=$(dig +time=3 +tries=1 +short MX "$domain" @${DNS_TARGET:-8.8.8.8} 2>/dev/null | head -1)
            [ -n "$mx" ] && check_pass "$domain → $mx" || check_info "$domain" "无 MX 记录"
        done
    else
        check_skip "MX检测需要 dig 工具"
    fi
    
    print_sub "TXT 记录"
    if command -v dig >/dev/null 2>&1; then
        txt=$(dig +time=3 +tries=1 +short TXT cloudflare.com @${DNS_TARGET:-8.8.8.8} 2>/dev/null | head -1 | cut -c1-60)
        [ -n "$txt" ] && check_pass "cloudflare.com TXT: ${txt}..." || check_info "cloudflare.com" "无 TXT 记录"
    else
        check_skip "TXT检测需要 dig 工具"
    fi
}

#==================================================
# 第6部分: 协议和端口检测
#==================================================
check_protocols() {
    print_section "第6部分: 协议和端口检测"
    
    print_sub "UDP:53 (标准DNS)"
    for dns in ${DNS_TARGET:-$DNS_CHECK_SERVERS}; do
        [ -z "$dns" ] && continue
        if command -v dig >/dev/null 2>&1; then
            if dig +time=2 +tries=1 @$dns google.com A +short >/dev/null 2>&1; then
                check_pass "UDP $dns:53 正常"
            else
                check_fail "UDP $dns:53 异常"
            fi
        elif command -v nslookup >/dev/null 2>&1; then
            if nslookup -timeout=2 google.com $dns >/dev/null 2>&1; then
                check_pass "UDP $dns:53 正常"
            else
                check_fail "UDP $dns:53 异常"
            fi
        else
            check_skip "需要 dig 或 nslookup"
            break
        fi
    done
    
    print_sub "TCP:53 (大包/区域传输)"
    for dns in ${DNS_TARGET:-$DNS_CHECK_SERVERS}; do
        [ -z "$dns" ] && continue
        if command -v nc >/dev/null 2>&1; then
            if run_with_timeout 3 nc -z -w 1 "$dns" 53 2>/dev/null; then
                check_pass "TCP $dns:53 可达"
            else
                check_warn "TCP $dns:53 不可达"
            fi
        else
            check_skip "需要 nc 工具"
            break
        fi
    done
    
    print_sub "DoH:443 (DNS over HTTPS)"
    if command -v curl >/dev/null 2>&1; then
        parse_server_list "$DNS_CHECK_DOH_SERVERS" | while IFS='|' read -r name url; do
            [ -z "$name" ] && continue
            if run_with_timeout 5 curl -s -H "accept: application/dns-json" \
                "${url}?name=google.com&type=A" 2>/dev/null | grep -qE '"Status":[[:space:]]*0'; then
                check_pass "$name DoH 可用"
            else
                check_warn "$name DoH 不可用"
            fi
        done
    else
        check_skip "curl 未安装"
    fi
    
    print_sub "DoT:853 (DNS over TLS)"
    if command -v nc >/dev/null 2>&1; then
        parse_server_list "$DNS_CHECK_DOT_SERVERS" | while IFS='|' read -r name ip; do
            [ -z "$name" ] && continue
            if run_with_timeout 3 nc -z -w 1 "$ip" 853 2>/dev/null; then
                check_pass "$name DoT 可达"
            else
                check_fail "$name DoT 不可达"
            fi
        done
    else
        check_skip "nc 未安装"
    fi
}

#==================================================
# 第7部分: 性能基准测试
#==================================================
check_performance() {
    print_section "第7部分: 性能基准测试"
    
    test_domain="cloudflare.com"
    iterations=5
    
    print_sub "响应时间 (连续${iterations}次查询)"
    total_time=0
    success_count=0
    
    for i in $(seq 1 $iterations); do
        timer_id=$(timer_start)
        result=$(smart_resolve "$test_domain" "A" "$DNS_TARGET")
        elapsed=$(timer_end "$timer_id")
        
        ip=$(extract_ipv4_fixed "$result" "$DNS_TARGET")
        if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then
            success_count=$((success_count + 1))
            total_time=$((total_time + elapsed))
            echo -e "    第${i}次: ${elapsed}ms ${DIM}($ip)${NC}"
        else
            echo -e "    第${i}次: ${elapsed}ms ${RED}(失败)${NC}"
        fi
    done
    
    if [ "$success_count" -gt 0 ]; then
        avg_time=$((total_time / success_count))
        if [ "$avg_time" -lt 10 ]; then
            check_pass "平均响应: ${avg_time}ms ${GREEN}(优秀)${NC}"
        elif [ "$avg_time" -lt 50 ]; then
            check_pass "平均响应: ${avg_time}ms ${CYAN}(良好)${NC}"
        elif [ "$avg_time" -lt 100 ]; then
            check_warn "平均响应: ${avg_time}ms ${YELLOW}(一般)${NC}"
        else
            check_fail "平均响应: ${avg_time}ms ${RED}(较慢)${NC}" "检查网络延迟"
        fi
    else
        check_fail "所有查询均失败" "检查DNS配置"
    fi
    
    print_sub "缓存效果"
    cache_domain="github.com"
    
    smart_resolve "$(date +%s)-nonexist.invalid" "A" "$DNS_TARGET" >/dev/null 2>&1
    
    timer_id=$(timer_start)
    smart_resolve "$cache_domain" "A" "$DNS_TARGET" >/dev/null 2>&1
    first_query=$(timer_end "$timer_id")
    
    timer_id=$(timer_start)
    smart_resolve "$cache_domain" "A" "$DNS_TARGET" >/dev/null 2>&1
    second_query=$(timer_end "$timer_id")
    
    if [ "$second_query" -lt "$first_query" ] 2>/dev/null && [ "$first_query" -gt 0 ]; then
        improvement=$(( (first_query - second_query) * 100 / first_query ))
        if [ "$improvement" -gt 10 ]; then
            check_pass "缓存生效 (提升 ${improvement}%, ${first_query}ms→${second_query}ms)"
        else
            check_info "缓存效果微弱" "${first_query}ms→${second_query}ms (${improvement}%)"
        fi
    else
        check_info "未见缓存加速" "首次:${first_query}ms, 二次:${second_query}ms"
    fi
    
    print_sub "并发解析能力"
    if command -v dig >/dev/null 2>&1; then
        domains="google.com cloudflare.com github.com wikipedia.org redhat.com"
        pids=""
        pid_count=0
        
        timer_id=$(timer_start)
        for domain in $domains; do
            smart_resolve "$domain" "A" "$DNS_TARGET" >/dev/null 2>&1 &
            new_pid=$!
            if [ -n "$new_pid" ] && kill -0 "$new_pid" 2>/dev/null; then
                pids="$pids $new_pid"
                pid_count=$((pid_count + 1))
            fi
        done
        
        failed_pids=0
        for pid in $pids; do
            wait "$pid" 2>/dev/null
            wait_exit=$?
            if [ "$wait_exit" -ne 0 ]; then
                failed_pids=$((failed_pids + 1))
            fi
        done
        
        concurrent_time=$(timer_end "$timer_id")
        [ "$pid_count" -gt 0 ] && per_domain=$((concurrent_time / pid_count)) || per_domain=0
        check_info "并发解析" "${pid_count}个域名, 总计${concurrent_time}ms, 平均${per_domain}ms/个"
        [ "$failed_pids" -gt 0 ] && check_warn "$failed_pids 个查询失败"
    else
        check_skip "并发测试需要 dig 工具"
    fi
}

#==================================================
# 第8部分: 安全检测（修复CDN误报）
#==================================================
check_security() {
    print_section "第8部分: 安全检测"
    
    print_sub "DNSSEC 支持"
    if command -v dig >/dev/null 2>&1; then
        dnssec_result=$(dig +time=3 +tries=1 +dnssec cloudflare.com A @${DNS_TARGET:-8.8.8.8} 2>/dev/null)
        
        if printf '%s' "$dnssec_result" | grep -qE "(flags:.*ad|Authentic Data|RRSIG)"; then
            check_pass "DNSSEC 验证通过"
        elif printf '%s' "$dnssec_result" | grep -q "ANSWER SECTION"; then
            check_warn "DNSSEC 未验证或不被支持"
        else
            check_warn "DNSSEC 检测失败"
        fi
    else
        check_skip "需要 dig 工具"
    fi
    
    print_sub "解析一致性"
    test_domain="google.com"
    consistency_file="${TMPFILE}.consistency.$$"
    : > "$consistency_file"
    sources=0
    
    for resolver in ${DNS_TARGET:-""} $DNS_CHECK_SERVERS; do
        [ -z "$resolver" ] && continue
        result=$(smart_resolve "$test_domain" "A" "$resolver" 2>/dev/null)
        ip=$(extract_ipv4_fixed "$result" "$resolver")
        
        if [ -n "$ip" ]; then
            sources=$((sources + 1))
            printf '%s: %s\n' "$resolver" "$ip" >> "$consistency_file"
        fi
    done
    
    if [ "$sources" -ge 2 ]; then
        unique_ips=$(awk -F': ' '{print $2}' "$consistency_file" | sort -u | wc -l | awk '{print $1}')
        
        if [ "$unique_ips" -eq 1 ]; then
            check_pass "多源解析一致 ($sources个源)"
        elif [ "$unique_ips" -eq 2 ]; then
            # 检查是否同一/24子网（CDN正常行为）
            ip1=$(awk -F': ' 'NR==1{print $2}' "$consistency_file")
            ip2=$(awk -F': ' 'NR==2{print $2}' "$consistency_file")
            subnet1=$(echo "$ip1" | cut -d. -f1-3)
            subnet2=$(echo "$ip2" | cut -d. -f1-3)
            
            if [ "$subnet1" = "$subnet2" ]; then
                check_pass "解析一致 (CDN同网段: ${subnet1}.x)"
            else
                check_warn "多源结果不同 (不同网段)" "CDN调度或DNS差异"
            fi
        else
            check_warn "多源结果分散 (${unique_ips}个不同IP)" "CDN多节点或DNS异常"
        fi
        
        if [ "${QUIET:-0}" -eq 0 ] && [ "$unique_ips" -gt 1 ]; then
            cat "$consistency_file" 2>/dev/null | while IFS= read -r line; do
                [ -n "$line" ] && print_detail "$line"
            done
        fi
    elif [ "$sources" -eq 1 ]; then
        check_warn "仅一个源可用，无法对比"
    else
        check_fail "所有源均无法解析"
    fi
    
    rm -f "$consistency_file" 2>/dev/null
    
    print_sub "DNS污染检测"
    test_domain="www.youtube.com"
    pollute_sources=0
    pollute_ips=""
    
    for resolver in ${DNS_TARGET:-""} $DNS_CHECK_SERVERS; do
        [ -z "$resolver" ] && continue
        result=$(smart_resolve "$test_domain" "A" "$resolver" 2>/dev/null)
        ip=$(extract_ipv4_fixed "$result" "$resolver")
        
        if [ -n "$ip" ]; then
            pollute_sources=$((pollute_sources + 1))
            pollute_ips="$pollute_ips $ip"
        fi
    done
    
    if [ "$pollute_sources" -ge 2 ]; then
        unique_pollute=$(count_unique_lines "$pollute_ips")
        if [ "$unique_pollute" -eq 1 ]; then
            check_pass "解析一致，未检测到污染"
        elif [ "$unique_pollute" -ge 3 ]; then
            check_warn "解析高度不一致" "可能存在DNS污染"
        else
            check_warn "解析部分不一致" "CDN调度或轻微污染"
        fi
    else
        check_warn "无法进行污染检测" "解析源不足"
    fi
}

#==================================================
# 最终报告
#==================================================
print_final_report() {
    print_section "检测报告"
    
    echo ""
    echo -e "  检测模式: ${BOLD}$([ "$CHECK_MODE" = "smartdns" ] && echo "SmartDNS" || echo "系统DNS")${NC}"
    [ -n "$DNS_TARGET" ] && echo -e "  目标DNS: ${CYAN}$DNS_TARGET${NC}"
    echo -e "  ${GREEN}通过: $PASS${NC}"
    echo -e "  ${YELLOW}警告: $WARN${NC}"
    echo -e "  ${RED}失败: $FAIL${NC}"
    echo -e "  ${DIM}跳过: $SKIP${NC}"
    echo -e "  ${BOLD}总计: $TOTAL${NC}"
    echo ""
    
    if [ "$TOTAL" -gt 0 ]; then
        score=$(( (PASS * 100) / TOTAL ))
    else
        score=0
    fi
    
    if [ "$FAIL" -eq 0 ] && [ "$score" -ge 90 ]; then
        echo -e "  ${GREEN}${BOLD}★★★★★ 完美 (${score}分)${NC} - DNS服务完全正常"
    elif [ "$FAIL" -eq 0 ] && [ "$score" -ge 70 ]; then
        echo -e "  ${GREEN}${BOLD}★★★★☆ 良好 (${score}分)${NC} - 基本可用，少量警告"
    elif [ "$FAIL" -le 2 ]; then
        echo -e "  ${YELLOW}${BOLD}★★★☆☆ 一般 (${score}分)${NC} - 存在部分问题"
    elif [ "$FAIL" -le 5 ]; then
        echo -e "  ${RED}${BOLD}★★☆☆☆ 较差 (${score}分)${NC} - 需要修复"
    else
        echo -e "  ${RED}${BOLD}★☆☆☆☆ 严重 (${score}分)${NC} - DNS服务存在严重问题"
    fi
    
    echo ""
    echo -e "检测完成: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # 如果跳过多且有自动安装提示
    if [ "$SKIP" -gt 5 ] && [ "$AUTO_INSTALL" != "1" ]; then
        echo -e "  ${ICON_INFO} 提示: ${BOLD}$SKIP 项检测因缺少工具被跳过${NC}"
        echo -e "  ${ICON_INFO} 使用 ${CYAN}AUTO_INSTALL=1 $0${NC} 可自动安装依赖"
        echo ""
    fi
}

#==================================================
# 主函数
#==================================================
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -q|--quiet) QUIET=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -d|--dns) DNS_TARGET="$2"; CHECK_MODE="manual"; shift ;;
            --install) AUTO_INSTALL=1 ;;
            -h|--help)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  -q, --quiet     安静模式"
                echo "  -v, --verbose   详细输出"
                echo "  -d, --dns IP    手动指定DNS服务器"
                echo "  --install       自动安装缺失依赖"
                echo "  -h, --help      显示帮助"
                echo ""
                echo "环境变量:"
                echo "  AUTO_INSTALL=1           自动安装缺失依赖"
                echo "  DNS_CHECK_DOMAINS        测试域名列表"
                echo "  DNS_CHECK_SERVERS        IPv4 DNS服务器列表"
                echo "  DNS_CHECK_IPV6           IPv6 DNS服务器列表"
                echo "  DNS_CHECK_DOH_SERVERS    DoH服务器 (名称|URL)"
                echo "  DNS_CHECK_DOT_SERVERS    DoT服务器 (名称|IP)"
                echo ""
                echo "兼容: Alpine/Debian/Ubuntu/RHEL/macOS"
                exit 0
                ;;
            *) 
                echo "未知参数: $1 (使用 -h 查看帮助)"
                exit 1
                ;;
        esac
        shift
    done
    
    # 自动安装依赖
    if [ "$AUTO_INSTALL" = "1" ]; then
        auto_install_dependencies || {
            echo -e "  ${ICON_FAIL} 依赖安装失败，使用现有工具继续检测..."
            echo ""
        }
    fi
    
    if [ "$CHECK_MODE" != "manual" ]; then
        detect_mode
    fi
    
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║  DNS 全面检测脚本 v4.5 (运行时修复·自动安装)            ║${NC}"
    echo -e "${BOLD}${MAGENTA}║  检测时间: $(date '+%Y-%m-%d %H:%M:%S')                        ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_system_environment
    check_dns_service
    check_resolution_methods
    check_geo_resolution
    check_record_types
    check_protocols
    check_performance
    check_security
    print_final_report
    
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

main "$@"
