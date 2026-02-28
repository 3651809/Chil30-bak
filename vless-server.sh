#!/bin/bash 
#═══════════════════════════════════════════════════════════════════════════════
#  多协议代理一键部署脚本 v3.4.10 [服务端]
#  
#  架构升级:
#    • Xray 核心: 处理 TCP/TLS 协议 (VLESS/VMess/Trojan/SOCKS/SS2022)
#    • Sing-box 核心: 处理 UDP/QUIC 协议 (Hysteria2/TUIC) - 低内存高效率
#  
#  支持协议: VLESS+Reality / VLESS+Reality+XHTTP / VLESS+WS / VMess+WS / 
#           VLESS-XTLS-Vision / SOCKS5 / SS2022 / HY2 / Trojan / 
#           Snell v4 / Snell v5 / AnyTLS / TUIC / NaïveProxy (共14种)
#  插件支持: Snell v4/v5 和 SS2022 可选启用 ShadowTLS
#  适配: Alpine/Debian/Ubuntu/CentOS
#  
#  
#  作者: Chil30
#  项目地址: https://github.com/Chil30/vless-all-in-one
#═══════════════════════════════════════════════════════════════════════════════

readonly VERSION="3.4.10"
readonly AUTHOR="Chil30"
readonly REPO_URL="https://github.com/Chil30/vless-all-in-one"
readonly SCRIPT_REPO="Chil30/vless-all-in-one"
readonly SCRIPT_RAW_URL="https://raw.githubusercontent.com/Chil30/vless-all-in-one/main/vless-server.sh"
readonly CFG="/etc/vless-reality"
readonly ACME_DEFAULT_EMAIL="acme@vaio.com"

# curl 超时常量
readonly CURL_TIMEOUT_FAST=5
readonly CURL_TIMEOUT_NORMAL=10
readonly CURL_TIMEOUT_DOWNLOAD=60
readonly LATENCY_TEST_URL="https://www.gstatic.com/generate_204"
readonly LATENCY_PARALLEL="${LATENCY_PARALLEL:-4}"
readonly LATENCY_PROBES="${LATENCY_PROBES:-3}"
readonly LATENCY_MAX_ATTEMPTS="${LATENCY_MAX_ATTEMPTS:-0}"

# IP 缓存变量
_CACHED_IPV4=""
_CACHED_IPV6=""

# Alpine busybox pgrep 不支持 -x，使用兼容方式检测进程
_pgrep() {
    local proc="$1"
    if [[ "$DISTRO" == "alpine" ]]; then
        # Alpine busybox pgrep: 先尝试精确匹配，再尝试命令行匹配
        pgrep "$proc" >/dev/null 2>&1 || pgrep -f "$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  全局状态数据库 (JSON)
#═══════════════════════════════════════════════════════════════════════════════
readonly DB_FILE="$CFG/db.json"

# 初始化数据库
init_db() {
    mkdir -p "$CFG" || return 1
    [[ -f "$DB_FILE" ]] && return 0
    local now tmp
    # Alpine busybox date 不支持 -Iseconds，使用兼容格式
    now=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    tmp=$(mktemp) || return 1
    if jq -n --arg v "4.0.0" --arg t "$now" \
      '{version:$v,xray:{},singbox:{},meta:{created:$t,updated:$t}}' >"$tmp" 2>/dev/null; then
        mv "$tmp" "$DB_FILE"
        return 0
    fi
    # jq 失败时使用简单方式创建
    echo '{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}' > "$DB_FILE"
    rm -f "$tmp"
    return 0
}

# 更新数据库时间戳
_db_touch() {
    [[ -f "$DB_FILE" ]] || init_db || return 1
    local now tmp
    # Alpine busybox date 不支持 -Iseconds，使用兼容格式
    now=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    tmp=$(mktemp) || return 1
    if jq --arg t "$now" '.meta.updated=$t' "$DB_FILE" >"$tmp"; then
        mv "$tmp" "$DB_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

_db_apply() { # _db_apply [jq args...] 'filter'
    [[ -f "$DB_FILE" ]] || init_db || return 1
    local tmp; tmp=$(mktemp) || return 1
    if jq "$@" "$DB_FILE" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$DB_FILE"
        _db_touch
        return 0
    fi
    rm -f "$tmp"
    return 1
}


# 添加协议到数据库
# 用法: db_add "xray" "vless" '{"uuid":"xxx","port":443,...}'
db_add() { # db_add core proto json
    local core="$1" proto="$2" json="$3"
    
    # 验证 JSON 格式
    if ! echo "$json" | jq empty 2>/dev/null; then
        _err "db_add: 无效的 JSON 格式 - $proto"
        return 1
    fi
    
    _db_apply --arg p "$proto" --argjson c "$json" ".${core}[\$p]=\$c"
    
    # 协议配置更新后，自动同步隧道配置（如果有隧道）
    # 确保隧道配置与新协议兼容
    _sync_tunnel_config 2>/dev/null || true
}


# 获取协议配置（支持多端口实例）
# 参数: $1=core(xray/singbox), $2=protocol
# 返回: JSON配置（数组或单个对象）
db_get() {
    local core="$1" protocol="$2"
    [[ ! -f "$DB_FILE" ]] && return 1

    local config=$(jq --arg c "$core" --arg p "$protocol" \
        '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null)

    [[ -z "$config" || "$config" == "null" ]] && return 1

    # 直接返回配置（保持 JSON 格式）
    echo "$config"
}

# 从数据库获取协议的某个字段
db_get_field() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg p "$2" --arg f "$3" ".${1}[\$p][\$f] // empty" "$DB_FILE" 2>/dev/null
}

# 参数: $1=core(xray/singbox), $2=protocol
# 返回: 端口列表，每行一个端口号
db_list_ports() {
    local core="$1" protocol="$2"
    [[ ! -f "$DB_FILE" ]] && return 1

    local config=$(jq --arg c "$core" --arg p "$protocol" \
        '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null)

    [[ -z "$config" || "$config" == "null" ]] && return 1

    # 检查是否为数组
    if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$config" | jq -r '.[].port'
    else
        # 兼容旧格式（单个对象）
        echo "$config" | jq -r '.port // empty'
    fi
}

# 获取指定端口的配置
# 参数: $1=core, $2=protocol, $3=port
# 返回: JSON配置对象
db_get_port_config() {
    local core="$1" protocol="$2" port="$3"
    [[ ! -f "$DB_FILE" ]] && return 1

    local config=$(jq --arg c "$core" --arg p "$protocol" \
        '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null)

    [[ -z "$config" || "$config" == "null" ]] && return 1

    if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "$config" | jq --arg port "$port" '.[] | select(.port == ($port | tonumber))'
    else
        # 兼容旧格式
        local existing_port=$(echo "$config" | jq -r '.port')
        [[ "$existing_port" == "$port" ]] && echo "$config"
    fi
}

# 添加端口实例到协议
# 参数: $1=core, $2=protocol, $3=port_config_json
db_add_port() {
    local core="$1" protocol="$2" port_config="$3"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    # 提取要添加的端口号
    local new_port=$(echo "$port_config" | jq -r '.port')
    
    # 检查端口是否已存在
    local existing_ports=$(db_list_ports "$core" "$protocol")
    if echo "$existing_ports" | grep -q "^${new_port}$"; then
        echo -e "${YELLOW}警告: 端口 $new_port 已存在于协议 $protocol 中，跳过添加${NC}" >&2
        return 0
    fi
    
    local tmp_file="${DB_FILE}.tmp"
    
    jq --arg c "$core" --arg p "$protocol" --argjson cfg "$port_config" '
        .[$c][$p] = (
            if .[$c][$p] then
                if (.[$c][$p] | type) == "array" then
                    .[$c][$p] + [$cfg]
                else
                    [.[$c][$p], $cfg]
                end
            else
                [$cfg]
            end
        )
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
}

# 删除指定端口实例
# 参数: $1=core, $2=protocol, $3=port
db_remove_port() {
    local core="$1" protocol="$2" port="$3"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    
    jq --arg c "$core" --arg p "$protocol" --arg port "$port" '
        .[$c][$p] = (
            if (.[$c][$p] | type) == "array" then
                .[$c][$p] | map(select(.port != ($port | tonumber)))
            else
                if .[$c][$p].port == ($port | tonumber) then
                    null
                else
                    .[$c][$p]
                end
            end
        ) | if .[$c][$p] == [] or .[$c][$p] == null then
            del(.[$c][$p])
        else
            .
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
}

# 更新指定端口的配置
# 参数: $1=core, $2=protocol, $3=port, $4=new_config_json
db_update_port() {
    local core="$1" protocol="$2" port="$3" new_config="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    
    jq --arg c "$core" --arg p "$protocol" --arg port "$port" --argjson cfg "$new_config" '
        .[$c][$p] = (
            if (.[$c][$p] | type) == "array" then
                .[$c][$p] | map(if .port == ($port | tonumber) then $cfg else . end)
            else
                if .[$c][$p].port == ($port | tonumber) then
                    $cfg
                else
                    .[$c][$p]
                end
            end
        )
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
}

# 删除协议
db_del() { # db_del core proto
    _db_apply --arg p "$2" "del(.${1}[\$p])"
}


# 检查协议是否存在
db_exists() {
    [[ ! -f "$DB_FILE" ]] && return 1
    local val=$(jq -r --arg p "$2" ".${1}[\$p] // empty" "$DB_FILE" 2>/dev/null)
    [[ -n "$val" && "$val" != "null" ]]
}

# 获取某个核心下所有协议名
db_list_protocols() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r ".${1} | keys[]" "$DB_FILE" 2>/dev/null
}

# 获取所有已安装协议
db_get_all_protocols() {
    [[ ! -f "$DB_FILE" ]] && return 1
    { jq -r '.xray | keys[]' "$DB_FILE" 2>/dev/null; jq -r '.singbox | keys[]' "$DB_FILE" 2>/dev/null; } | sort -u
}

#═══════════════════════════════════════════════════════════════════════════════
#  多IP入出站配置 (IP Routing)
#═══════════════════════════════════════════════════════════════════════════════

# 获取系统所有公网IPv4地址
get_all_public_ipv4() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | sort -u
}

# 获取系统所有公网IPv6地址
get_all_public_ipv6() {
    ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d'/' -f1 | grep -v '^fe80' | sort -u
}

# 获取系统所有公网IP (IPv4 + IPv6)
get_all_public_ips() {
    {
        get_all_public_ipv4
        get_all_public_ipv6
    } | sort -u
}

# 获取IP路由配置
db_get_ip_routing() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r '.ip_routing // empty' "$DB_FILE" 2>/dev/null
}

# 获取IP路由规则列表
db_get_ip_routing_rules() {
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r '.ip_routing.rules // []' "$DB_FILE" 2>/dev/null
}

# 检查IP路由是否启用
db_ip_routing_enabled() {
    [[ ! -f "$DB_FILE" ]] && return 1
    local enabled=$(jq -r '.ip_routing.enabled // false' "$DB_FILE" 2>/dev/null)
    [[ "$enabled" == "true" ]]
}

# 添加IP路由规则
# 用法: db_add_ip_routing_rule "入站IP" "出站IP"
db_add_ip_routing_rule() {
    local inbound_ip="$1"
    local outbound_ip="$2"
    [[ -z "$inbound_ip" || -z "$outbound_ip" ]] && return 1
    [[ ! -f "$DB_FILE" ]] && init_db
    
    local tmp=$(mktemp)
    jq --arg in_ip "$inbound_ip" --arg out_ip "$outbound_ip" '
        .ip_routing.enabled = true |
        .ip_routing.rules = ((.ip_routing.rules // []) | 
            [.[] | select(.inbound_ip != $in_ip)] + 
            [{"inbound_ip": $in_ip, "outbound_ip": $out_ip}])
    ' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 删除IP路由规则
# 用法: db_del_ip_routing_rule "入站IP"
db_del_ip_routing_rule() {
    local inbound_ip="$1"
    [[ -z "$inbound_ip" ]] && return 1
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp=$(mktemp)
    jq --arg in_ip "$inbound_ip" '
        .ip_routing.rules = [(.ip_routing.rules // [])[] | select(.inbound_ip != $in_ip)]
    ' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 清空所有IP路由规则
db_clear_ip_routing_rules() {
    [[ ! -f "$DB_FILE" ]] && return 1
    local tmp=$(mktemp)
    jq '.ip_routing.rules = []' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 设置IP路由启用/禁用
db_set_ip_routing_enabled() {
    local enabled="$1"
    [[ ! -f "$DB_FILE" ]] && init_db
    local tmp=$(mktemp)
    jq --argjson e "$enabled" '.ip_routing.enabled = $e' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 获取指定入站IP的出站IP
db_get_ip_routing_outbound() {
    local inbound_ip="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg in_ip "$inbound_ip" '
        (.ip_routing.rules // [])[] | select(.inbound_ip == $in_ip) | .outbound_ip
    ' "$DB_FILE" 2>/dev/null
}

#═══════════════════════════════════════════════════════════════════════════════
#  辅助函数 (用户管理需要)

#═══════════════════════════════════════════════════════════════════════════════

# 生成 UUID
gen_uuid() {
    # 优先使用 xray uuid 命令
    if command -v xray &>/dev/null; then
        xray uuid 2>/dev/null && return
    fi
    # 备用方案: 使用 /proc/sys/kernel/random/uuid
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi
    # 最后方案: 使用 uuidgen
    if command -v uuidgen &>/dev/null; then
        uuidgen
        return
    fi
    # 如果都不可用，生成一个伪 UUID
    printf '%s-%s-%s-%s-%s\n' \
        $(head -c 4 /dev/urandom | xxd -p) \
        $(head -c 2 /dev/urandom | xxd -p) \
        $(head -c 2 /dev/urandom | xxd -p) \
        $(head -c 2 /dev/urandom | xxd -p) \
        $(head -c 6 /dev/urandom | xxd -p)
}

# 生成随机密码
gen_password() {
    local length="${1:-16}"
    head -c 32 /dev/urandom 2>/dev/null | base64 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# 询问密码（支持自定义或自动生成）
# 用法: ask_password [长度] [提示文本]
ask_password() {
    local length="${1:-16}"
    local prompt="${2:-密码}"
    local password=""
    
    read -rp "请输入${prompt} (直接回车自动生成): " password
    
    # 如果直接回车，生成随机密码
    if [[ -z "$password" ]]; then
        password=$(gen_password "$length")
    fi
    
    echo "$password"
}

# 获取协议的中文显示名
get_protocol_name() {
    local proto="$1"
    case "$proto" in
        vless) echo "VLESS-REALITY" ;;
        vless-vision) echo "VLESS-Vision" ;;
        vless-ws) echo "VLESS-WS-TLS" ;;
        vless-ws-notls) echo "VLESS-WS-CF" ;;
        vless-xhttp) echo "VLESS-XHTTP" ;;
        vless-xhttp-cdn) echo "VLESS-XHTTP-CDN" ;;
        vmess) echo "VMess-WS" ;;
        vmess-xhttp) echo "VMess-XHTTP" ;;
        tuic) echo "TUIC" ;;
        hy2) echo "Hysteria2" ;;
        ss2022) echo "SS2022" ;;
        ss2022-shadowtls) echo "SS2022+ShadowTLS" ;;
        snell) echo "Snell" ;;
        snell-v5) echo "Snell v5" ;;
        snell-shadowtls) echo "Snell+ShadowTLS" ;;
        snell-v5-shadowtls) echo "Snell v5+ShadowTLS" ;;
        trojan) echo "Trojan" ;;
        trojan-ws) echo "Trojan-WS" ;;
        anytls) echo "AnyTLS" ;;
        *) echo "$proto" ;;
    esac
}

# 检查是否为独立协议（不支持多用户和流量统计）
# 独立协议由独立二进制运行，使用配置文件中的固定密钥
# 用法: is_standalone_protocol "snell" -> 返回 0 表示是独立协议
is_standalone_protocol() {
    local proto="$1"
    [[ " $STANDALONE_PROTOCOLS " == *" $proto "* ]]
}

#═══════════════════════════════════════════════════════════════════════════════
#  多用户配置生成辅助函数
#═══════════════════════════════════════════════════════════════════════════════

# 生成 Xray VLESS 多用户 clients 数组
# 用法: gen_xray_vless_clients "vless" [flow] [port]
# 输出: JSON 数组 [{id: "uuid1", email: "user@vless", flow: "..."}, ...]
gen_xray_vless_clients() {
    local proto="$1"
    local flow="${2:-}"
    local filter_port="${3:-}"
    
    local users=$(db_get_users_stats "xray" "$proto")
    if [[ -z "$users" ]]; then
        # 尝试从配置中获取默认 UUID（支持多端口数组）
        local config=$(db_get "xray" "$proto")
        if [[ -n "$config" && "$config" != "null" ]]; then
            # 检查是否为数组
            if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
                # 多端口：优先按端口过滤，其次取第一个端口的 uuid
                local uuid=""
                if [[ -n "$filter_port" ]]; then
                    uuid=$(echo "$config" | jq -r --arg port "$filter_port" '.[] | select(.port == ($port | tonumber)) | .uuid // empty' | head -n1)
                else
                    uuid=$(echo "$config" | jq -r '.[0].uuid // empty')
                fi
                if [[ -n "$uuid" ]]; then
                    if [[ -n "$flow" ]]; then
                        echo "[{\"id\":\"$uuid\",\"email\":\"default@${proto}\",\"flow\":\"$flow\"}]"
                    else
                        echo "[{\"id\":\"$uuid\",\"email\":\"default@${proto}\"}]"
                    fi
                    return
                fi
            else
                # 单端口
                local uuid=$(echo "$config" | jq -r '.uuid // empty')
                if [[ -n "$uuid" ]]; then
                    if [[ -n "$flow" ]]; then
                        echo "[{\"id\":\"$uuid\",\"email\":\"default@${proto}\",\"flow\":\"$flow\"}]"
                    else
                        echo "[{\"id\":\"$uuid\",\"email\":\"default@${proto}\"}]"
                    fi
                    return
                fi
            fi
        fi
        echo "[]"
        return
    fi
    
    local clients="[]"
    declare -A seen_emails=()
    while IFS='|' read -r name uuid used quota enabled port routing; do
        [[ -z "$name" || -z "$uuid" || "$enabled" != "true" ]] && continue
        [[ -n "$filter_port" && "$port" != "$filter_port" ]] && continue
        local email="${name}@${proto}"
        [[ -n "${seen_emails[$email]+x}" ]] && continue
        seen_emails["$email"]=1
        
        if [[ -n "$flow" ]]; then
            clients=$(echo "$clients" | jq --arg id "$uuid" --arg e "$email" --arg f "$flow" '. + [{id: $id, email: $e, flow: $f}]')
        else
            clients=$(echo "$clients" | jq --arg id "$uuid" --arg e "$email" '. + [{id: $id, email: $e}]')
        fi
    done <<< "$users"
    
    echo "$clients"
}

# 生成 Xray VMess 多用户 clients 数组
gen_xray_vmess_clients() {
    local proto="$1"
    
    local users=$(db_get_users_stats "xray" "$proto")
    if [[ -z "$users" ]]; then
        # 尝试从配置中获取默认 UUID（支持多端口数组）
        local config=$(db_get "xray" "$proto")
        if [[ -n "$config" && "$config" != "null" ]]; then
            if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
                local uuid=$(echo "$config" | jq -r '.[0].uuid // empty')
            else
                local uuid=$(echo "$config" | jq -r '.uuid // empty')
            fi
            if [[ -n "$uuid" ]]; then
                echo "[{\"id\":\"$uuid\",\"email\":\"default@${proto}\",\"alterId\":0}]"
                return
            fi
        fi
        echo "[]"
        return
    fi
    
    local clients="[]"
    while IFS='|' read -r name uuid used quota enabled port routing; do
        [[ -z "$name" || -z "$uuid" || "$enabled" != "true" ]] && continue
        local email="${name}@${proto}"
        clients=$(echo "$clients" | jq --arg id "$uuid" --arg e "$email" '. + [{id: $id, email: $e, alterId: 0}]')
    done <<< "$users"
    
    echo "$clients"
}

# 生成 Xray Trojan 多用户 clients 数组
gen_xray_trojan_clients() {
    local proto="$1"
    
    local users=$(db_get_users_stats "xray" "$proto")
    if [[ -z "$users" ]]; then
        # 尝试从配置中获取默认 password（支持多端口数组）
        local config=$(db_get "xray" "$proto")
        if [[ -n "$config" && "$config" != "null" ]]; then
            if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
                local password=$(echo "$config" | jq -r '.[0].password // empty')
            else
                local password=$(echo "$config" | jq -r '.password // empty')
            fi
            if [[ -n "$password" ]]; then
                echo "[{\"password\":\"$password\",\"email\":\"default@${proto}\"}]"
                return
            fi
        fi
        echo "[]"
        return
    fi
    
    local clients="[]"
    while IFS='|' read -r name uuid used quota enabled port routing; do
        [[ -z "$name" || -z "$uuid" || "$enabled" != "true" ]] && continue
        local email="${name}@${proto}"
        # Trojan 使用 password 字段，这里 uuid 实际存储的是 password
        clients=$(echo "$clients" | jq --arg pw "$uuid" --arg e "$email" '. + [{password: $pw, email: $e}]')
    done <<< "$users"
    
    echo "$clients"
}

# 生成 Xray SS2022 多用户 clients 数组
gen_xray_ss2022_clients() {
    local proto="$1"
    
    local users=$(db_get_users_stats "xray" "$proto")
    if [[ -z "$users" ]]; then
        # SS2022 多用户模式必须有 users 数组，返回空
        echo "[]"
        return
    fi
    
    local clients="[]"
    while IFS='|' read -r name uuid used quota enabled port routing; do
        [[ -z "$name" || -z "$uuid" || "$enabled" != "true" ]] && continue
        local email="${name}@${proto}"
        # SS2022 使用 password 字段
        clients=$(echo "$clients" | jq --arg pw "$uuid" --arg e "$email" '. + [{password: $pw, email: $e}]')
    done <<< "$users"
    
    echo "$clients"
}

# 生成 Xray SOCKS5 多用户 accounts 数组
gen_xray_socks_accounts() {
    local proto="$1"
    
    local users=$(db_get_users_stats "xray" "$proto")
    if [[ -z "$users" ]]; then
        # 尝试从配置中获取默认账号（支持多端口数组）
        local config=$(db_get "xray" "$proto")
        if [[ -n "$config" && "$config" != "null" ]]; then
            local username password
            if echo "$config" | jq -e 'type == "array"' >/dev/null 2>&1; then
                username=$(echo "$config" | jq -r '.[0].username // empty')
                password=$(echo "$config" | jq -r '.[0].password // empty')
            else
                username=$(echo "$config" | jq -r '.username // empty')
                password=$(echo "$config" | jq -r '.password // empty')
            fi
            if [[ -n "$username" && -n "$password" ]]; then
                echo "[{\"user\":\"$username\",\"pass\":\"$password\"}]"
                return
            fi
        fi
        echo "[]"
        return
    fi
    
    local accounts="[]"
    while IFS='|' read -r name uuid used quota enabled port routing; do
        [[ -z "$name" || -z "$uuid" || "$enabled" != "true" ]] && continue
        # SOCKS5: name 是 username，uuid 是 password
        accounts=$(echo "$accounts" | jq --arg u "$name" --arg p "$uuid" '. + [{user: $u, pass: $p}]')
    done <<< "$users"
    
    echo "$accounts"
}

#═══════════════════════════════════════════════════════════════════════════════
#  用户管理函数
#═══════════════════════════════════════════════════════════════════════════════

# 数据库结构说明:
# {
#   "xray": {
#     "vless": {
#       "port": 443,
#       "sni": "example.com",
#       "users": [
#         {"name": "user1", "uuid": "xxx", "quota": 107374182400, "used": 0, "enabled": true, "created": "2026-01-07"},
#         {"name": "user2", "uuid": "yyy", "quota": 0, "used": 0, "enabled": true, "created": "2026-01-07"}
#       ]
#     }
#   }
# }
# quota: 流量配额(字节)，0 表示无限制
# used: 已用流量(字节)
# enabled: 是否启用

# 添加用户到协议 (支持多端口数组格式)
# 用法: db_add_user "xray" "vless" "用户名" "uuid" [配额GB] [到期日期YYYY-MM-DD]
# 多端口时：用户会添加到第一个端口实例的 users 数组（共享凭证）
db_add_user() {
    local core="$1" proto="$2" name="$3" uuid="$4" quota_gb="${5:-0}" expire_date="${6:-}"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    # 检查协议是否存在
    if ! db_exists "$core" "$proto"; then
        _err "协议 $proto 不存在"
        return 1
    fi
    
    # 检查是否为独立协议（不支持多用户）
    if is_standalone_protocol "$proto"; then
        _err "独立协议 $proto 不支持添加用户"
        return 1
    fi
    

    
    # 检查用户名是否已存在 (支持多端口)
    local exists=$(jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then 0
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | length
        else
            ($cfg.users // [] | map(select(.name == $n))) | length
        end
    ' "$DB_FILE" 2>/dev/null)
    if [[ "$exists" -gt 0 ]]; then
        _err "用户 $name 已存在"
        return 1
    fi
    
    # 计算配额(字节)
    local quota=0
    if [[ "$quota_gb" -gt 0 ]]; then
        quota=$((quota_gb * 1073741824))  # GB to bytes
    fi
    
    local created=$(date '+%Y-%m-%d')
    
    # 添加用户 (支持多端口数组，包含 expire_date)
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" --arg u "$uuid" \
       --argjson q "$quota" --arg cr "$created" --arg exp "$expire_date" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            # 多端口: 添加到第一个端口实例
            .[$c][$p][0].users = ((.[$c][$p][0].users // []) + [{name:$n,uuid:$u,quota:$q,used:0,enabled:true,created:$cr,expire_date:$exp}])
        else
            # 单端口: 正常添加
            .[$c][$p].users = ((.[$c][$p].users // []) + [{name:$n,uuid:$u,quota:$q,used:0,enabled:true,created:$cr,expire_date:$exp}])
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
    
    # 如果设置了到期日期，自动安装过期检查 cron
    [[ -n "$expire_date" ]] && ensure_expire_check_cron 2>/dev/null
    
    # 自动重建配置
    if [[ "$core" == "xray" ]]; then
        rebuild_and_reload_xray "silent"
    elif [[ "$core" == "singbox" ]]; then
        rebuild_and_reload_singbox "silent"
    fi
}


# 删除用户 (支持多端口数组格式)
# 用法: db_del_user "xray" "vless" "用户名"
db_del_user() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            # 多端口: 从所有端口实例中删除该用户
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | select(.name != $n)])]
        else
            # 单端口
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | select(.name != $n)]
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
    
    # 自动重建配置
    if [[ "$core" == "xray" ]]; then
        rebuild_and_reload_xray "silent"
    elif [[ "$core" == "singbox" ]]; then
        rebuild_and_reload_singbox "silent"
    fi
}

# 获取用户信息 (支持多端口数组格式)
# 用法: db_get_user "xray" "vless" "用户名"
db_get_user() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            empty
        elif ($cfg | type) == "array" then
            # 多端口: 合并所有端口的 users 数组查找
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0] // empty
        else
            # 单端口
            ($cfg.users // [] | map(select(.name == $n)) | .[0]) // empty
        end
    ' "$DB_FILE" 2>/dev/null
}

# 获取用户的某个字段 (支持多端口数组格式)
# 用法: db_get_user_field "xray" "vless" "用户名" "uuid"
db_get_user_field() {
    local core="$1" proto="$2" name="$3" field="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            empty
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0][$f] // empty
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0][$f]) // empty
        end
    ' "$DB_FILE" 2>/dev/null
}

# 列出协议的所有用户 (支持多端口数组格式)
# 用法: db_list_users "xray" "vless"
# 多端口时合并所有端口的用户列表，无 users 数组时返回 "default"
db_list_users() {
    local core="$1" proto="$2"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    jq -r --arg c "$core" --arg p "$proto" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            empty
        elif ($cfg | type) == "array" then
            # 多端口: 合并所有端口的 users，无 users 时输出 "default"（与 Xray email 格式一致）
            ($cfg | map(
                if (.users | length) > 0 then
                    .users[].name
                elif (.uuid != null or .password != null) then
                    "default"
                else
                    empty
                end
            ) | unique | .[]) // empty
        else
            # 单端口
            if ($cfg.users | length) > 0 then
                $cfg.users[].name
            elif ($cfg.uuid != null or $cfg.password != null) then
                "default"
            else
                empty
            end
        end
    ' "$DB_FILE" 2>/dev/null
}

# 获取协议的用户数量
# 用法: db_count_users "xray" "vless"
# 支持三种配置格式：
#   1. 有 users 数组: 返回 users 数组长度
#   2. 单端口旧格式 (无 users 但有 uuid/password): 返回 1
#   3. 多端口数组 (无 users 但每个端口有 uuid/password): 返回端口实例数量
db_count_users() {
    local core="$1" proto="$2"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    # 使用 jq 一次性计算，处理所有情况
    local count=$(jq -r --arg c "$core" --arg p "$proto" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            0
        elif ($cfg | type) == "array" then
            # 多端口数组: 统计所有端口的 users，或统计有 uuid/password 的端口数
            ($cfg | map(.users // [] | length) | add) as $users_total |
            if $users_total > 0 then
                $users_total
            else
                # 没有 users 数组，统计有默认凭证的端口数
                [$cfg[] | select(.uuid != null or .password != null)] | length
            end
        else
            # 单端口对象
            ($cfg.users // [] | length) as $users_len |
            if $users_len > 0 then
                $users_len
            elif ($cfg.uuid != null or $cfg.password != null) then
                1
            else
                0
            end
        end
    ' "$DB_FILE" 2>/dev/null)
    
    echo "${count:-0}"
}

# 更新用户流量 (支持多端口数组格式)
# 用法: db_update_user_traffic "xray" "vless" "用户名" 增量字节数
db_update_user_traffic() {
    local core="$1" proto="$2" name="$3" bytes="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" --argjson b "$bytes" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .used += $b else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .used += $b else . end]
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
}

# 设置用户流量(覆盖) (支持多端口数组格式)
# 用法: db_set_user_traffic "xray" "vless" "用户名" 字节数
db_set_user_traffic() {
    local core="$1" proto="$2" name="$3" bytes="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" --argjson b "$bytes" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .used = $b else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .used = $b else . end]
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
}

# 重置用户流量
# 用法: db_reset_user_traffic "xray" "vless" "用户名"
db_reset_user_traffic() {
    db_set_user_traffic "$1" "$2" "$3" 0
}

# 设置用户配额 (支持多端口数组格式)
# 用法: db_set_user_quota "xray" "vless" "用户名" 配额GB (0=无限)
db_set_user_quota() {
    local core="$1" proto="$2" name="$3" quota_gb="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local quota=0
    if [[ "$quota_gb" -gt 0 ]]; then
        quota=$((quota_gb * 1073741824))
    fi
    
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" --argjson q "$quota" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .quota = $q else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .quota = $q else . end]
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
}

# 启用/禁用用户 (支持多端口数组格式)
# 用法: db_set_user_enabled "xray" "vless" "用户名" true/false
db_set_user_enabled() {
    local core="$1" proto="$2" name="$3" enabled="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" --argjson e "$enabled" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .enabled = $e else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .enabled = $e else . end]
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
    
    # 自动重建配置
    [[ "$core" == "xray" ]] && rebuild_and_reload_xray "silent"
}

# 检查用户是否超限 (支持多端口数组格式)
# 用法: db_is_user_over_quota "xray" "vless" "用户名"
# 返回: 0=未超限或无限制, 1=已超限
db_is_user_over_quota() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 0
    
    local result=$(jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then "no"
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0] |
            if . == null then "no" elif .quota == 0 then "no" elif .used >= .quota then "yes" else "no" end
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0]) |
            if . == null then "no" elif .quota == 0 then "no" elif .used >= .quota then "yes" else "no" end
        end
    ' "$DB_FILE" 2>/dev/null)
    
    [[ "$result" == "yes" ]]
}

# 获取用户告警状态 (用于防止重复通知)
# 用法: db_get_user_alert_state "xray" "vless" "用户名" "last_alert_percent|quota_exceeded_notified"
db_get_user_alert_state() {
    local core="$1" proto="$2" name="$3" field="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" '
        .[$c][$p] as $cfg |
        if $cfg == null then ""
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0][$f] // ""
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0][$f]) // ""
        end
    ' "$DB_FILE" 2>/dev/null
}

# 设置用户告警状态 (支持多端口数组格式)
# 用法: db_set_user_alert_state "xray" "vless" "用户名" "last_alert_percent" 80
db_set_user_alert_state() {
    local core="$1" proto="$2" name="$3" field="$4" value="$5"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    
    # 根据值类型选择合适的 jq 参数
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
        jq --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" --argjson v "$value" '
            .[$c][$p] as $cfg |
            if ($cfg | type) == "array" then
                .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .[$f] = $v else . end])]
            else
                .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .[$f] = $v else . end]
            end
        ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
    else
        jq --arg c "$core" --arg p "$proto" --arg n "$name" --arg f "$field" --arg v "$value" '
            .[$c][$p] as $cfg |
            if ($cfg | type) == "array" then
                .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .[$f] = $v else . end])]
            else
                .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .[$f] = $v else . end]
            end
        ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
    fi
}
# 设置用户路由 (支持多端口数组格式)
# 用法: db_set_user_routing "xray" "vless" "用户名" "direct|warp|chain:xxx|balancer:xxx"
# routing 值说明:
#   "" 或 null - 使用全局规则
#   "direct" - 直连出站
#   "warp" - WARP 出站
#   "chain:节点名" - 链式代理指定节点
#   "balancer:组名" - 负载均衡组
db_set_user_routing() {
    local core="$1" proto="$2" name="$3" routing="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" --arg r "$routing" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .routing = $r else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .routing = $r else . end]
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
    
    # 自动重建配置
    if [[ "$core" == "xray" ]]; then
        rebuild_and_reload_xray "silent"
    elif [[ "$core" == "singbox" ]]; then
        rebuild_and_reload_singbox "silent"
    fi
}

# 获取用户路由 (支持多端口数组格式)
# 用法: db_get_user_routing "xray" "vless" "用户名"
# 返回: routing 值，空表示使用全局规则
db_get_user_routing() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then ""
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0].routing // ""
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0].routing) // ""
        end
    ' "$DB_FILE" 2>/dev/null
}

# 格式化显示用户路由
# 用法: _format_user_routing "direct" -> "直连"
_format_user_routing() {
    local routing="$1"
    case "$routing" in
        ""|null) echo "全局规则" ;;
        direct) echo "直连" ;;
        warp) echo "WARP" ;;
        chain:*) echo "链路→${routing#chain:}" ;;
        balancer:*) echo "负载→${routing#balancer:}" ;;
        *) echo "$routing" ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════════════
#  用户到期日期管理函数
#═══════════════════════════════════════════════════════════════════════════════

# 设置用户到期日期 (支持多端口数组格式)
# 用法: db_set_user_expire_date "xray" "vless" "用户名" "2026-02-28"
# 空字符串或 "never" 表示永不过期
db_set_user_expire_date() {
    local core="$1" proto="$2" name="$3" expire_date="$4"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    # 处理特殊值
    [[ "$expire_date" == "never" ]] && expire_date=""
    
    local tmp_file="${DB_FILE}.tmp"
    jq --arg c "$core" --arg p "$proto" --arg n "$name" --arg e "$expire_date" '
        .[$c][$p] as $cfg |
        if ($cfg | type) == "array" then
            .[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | if .name == $n then .expire_date = $e else . end])]
        else
            .[$c][$p].users = [.[$c][$p].users // [] | .[] | if .name == $n then .expire_date = $e else . end]
        end
    ' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
    
    # 如果设置了到期日期，自动安装过期检查 cron
    [[ -n "$expire_date" ]] && ensure_expire_check_cron 2>/dev/null
}

# 获取用户到期日期
# 用法: db_get_user_expire_date "xray" "vless" "用户名"
# 返回: YYYY-MM-DD 格式的日期，空表示永不过期
db_get_user_expire_date() {
    local core="$1" proto="$2" name="$3"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    jq -r --arg c "$core" --arg p "$proto" --arg n "$name" '
        .[$c][$p] as $cfg |
        if $cfg == null then ""
        elif ($cfg | type) == "array" then
            [$cfg[].users // [] | .[] | select(.name == $n)] | .[0].expire_date // ""
        else
            ($cfg.users // [] | map(select(.name == $n)) | .[0].expire_date) // ""
        end
    ' "$DB_FILE" 2>/dev/null
}

# 检查用户是否已过期
# 用法: db_is_user_expired "xray" "vless" "用户名"
# 返回: 0=已过期, 1=未过期或永不过期
db_is_user_expired() {
    local core="$1" proto="$2" name="$3"
    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")
    
    # 空日期表示永不过期
    [[ -z "$expire_date" ]] && return 1
    
    # 比较日期 (YYYY-MM-DD 格式可直接字符串比较)
    local today=$(date '+%Y-%m-%d')
    [[ "$today" > "$expire_date" ]]
}

# 获取用户剩余天数
# 用法: db_get_user_days_left "xray" "vless" "用户名"
# 返回: 剩余天数 (负数表示已过期，空表示永不过期)
db_get_user_days_left() {
    local core="$1" proto="$2" name="$3"
    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")
    
    [[ -z "$expire_date" ]] && echo "" && return
    
    local today_sec=$(date -d "$(date '+%Y-%m-%d')" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$(date '+%Y-%m-%d')" '+%s' 2>/dev/null)
    local expire_sec=$(date -d "$expire_date" '+%s' 2>/dev/null || date -j -f '%Y-%m-%d' "$expire_date" '+%s' 2>/dev/null)
    
    if [[ -n "$today_sec" && -n "$expire_sec" ]]; then
        echo $(( (expire_sec - today_sec) / 86400 ))
    else
        echo ""
    fi
}

# 获取即将过期的用户列表 (用于提醒)
# 用法: db_get_expiring_users [天数阈值，默认3]
# 输出: core|proto|name|expire_date|days_left (每行一个用户)
db_get_expiring_users() {
    local threshold="${1:-3}"
    local today=$(date '+%Y-%m-%d')
    
    [[ ! -f "$DB_FILE" ]] && return 1
    
    # 遍历所有协议的所有用户
    for core in xray singbox; do
        local protocols=$(db_list_protocols "$core" 2>/dev/null)
        [[ -z "$protocols" ]] && continue
        
        while read -r proto; do
            [[ -z "$proto" ]] && continue
            local users=$(db_list_users "$core" "$proto" 2>/dev/null)
            [[ -z "$users" ]] && continue
            
            while read -r name; do
                [[ -z "$name" || "$name" == "default" ]] && continue
                local days_left=$(db_get_user_days_left "$core" "$proto" "$name")
                [[ -z "$days_left" ]] && continue
                
                # 检查是否在阈值范围内 (0 <= days_left <= threshold)
                if [[ "$days_left" -ge 0 && "$days_left" -le "$threshold" ]]; then
                    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")
                    echo "${core}|${proto}|${name}|${expire_date}|${days_left}"
                fi
            done <<< "$users"
        done <<< "$protocols"
    done
}

# 获取所有已过期的用户列表
# 用法: db_get_expired_users
# 输出: core|proto|name|expire_date|days_left (每行一个用户)
db_get_expired_users() {
    local today=$(date '+%Y-%m-%d')
    
    [[ ! -f "$DB_FILE" ]] && return 1
    
    for core in xray singbox; do
        local protocols=$(db_list_protocols "$core" 2>/dev/null)
        [[ -z "$protocols" ]] && continue
        
        while read -r proto; do
            [[ -z "$proto" ]] && continue
            local users=$(db_list_users "$core" "$proto" 2>/dev/null)
            [[ -z "$users" ]] && continue
            
            while read -r name; do
                [[ -z "$name" || "$name" == "default" ]] && continue
                local days_left=$(db_get_user_days_left "$core" "$proto" "$name")
                [[ -z "$days_left" ]] && continue
                
                # 已过期: days_left < 0
                if [[ "$days_left" -lt 0 ]]; then
                    local expire_date=$(db_get_user_expire_date "$core" "$proto" "$name")
                    local enabled=$(db_get_user_field "$core" "$proto" "$name" "enabled")
                    # 只返回仍然启用的过期用户（需要禁用）
                    [[ "$enabled" == "true" ]] && echo "${core}|${proto}|${name}|${expire_date}|${days_left}"
                fi
            done <<< "$users"
        done <<< "$protocols"
    done
}

#═══════════════════════════════════════════════════════════════════════════════
#  Telegram 通知功能
#═══════════════════════════════════════════════════════════════════════════════

# 获取 Telegram 配置
db_get_tg_config() {
    local field="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg f "$field" '.telegram[$f] // ""' "$DB_FILE" 2>/dev/null
}

# 设置 Telegram 配置
db_set_tg_config() {
    local field="$1" value="$2"
    [[ ! -f "$DB_FILE" ]] && init_db
    local tmp_file="${DB_FILE}.tmp"
    jq --arg f "$field" --arg v "$value" '.telegram[$f] = $v' "$DB_FILE" > "$tmp_file" && mv "$tmp_file" "$DB_FILE"
}

# 发送 Telegram 消息
send_tg_message() {
    local message="$1"
    local bot_token=$(db_get_tg_config "bot_token")
    local chat_id=$(db_get_tg_config "chat_id")
    
    [[ -z "$bot_token" || -z "$chat_id" ]] && return 1
    
    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        --connect-timeout 10 >/dev/null 2>&1
}

# 发送用户即将过期提醒
send_tg_expire_warning() {
    local name="$1" proto="$2" expire_date="$3" days_left="$4"
    local proto_name=$(get_protocol_name "$proto")
    local hostname=$(hostname 2>/dev/null || echo "服务器")
    
    local message="⚠️ *用户即将过期*
🖥 服务器: \`$hostname\`
👤 用户: \`$name\`
📋 协议: $proto_name
📅 到期: $expire_date
⏰ 剩余: *${days_left}天*"
    
    send_tg_message "$message"
}

# 发送用户已过期通知
send_tg_expired_notice() {
    local name="$1" proto="$2" expire_date="$3"
    local proto_name=$(get_protocol_name "$proto")
    local hostname=$(hostname 2>/dev/null || echo "服务器")
    
    local message="🚫 *用户已过期禁用*
🖥 服务器: \`$hostname\`
👤 用户: \`$name\`
📋 协议: $proto_name
📅 到期: $expire_date"
    
    send_tg_message "$message"
}

#═══════════════════════════════════════════════════════════════════════════════
#  过期检查和处理
#═══════════════════════════════════════════════════════════════════════════════

# 执行过期用户检查和禁用
check_and_disable_expired_users() {
    local notify="${1:-}"
    local count=0
    
    local expired_users=$(db_get_expired_users)
    [[ -z "$expired_users" ]] && echo "$count" && return 0
    
    while IFS='|' read -r core proto name expire_date days_left; do
        [[ -z "$name" ]] && continue
        db_set_user_enabled "$core" "$proto" "$name" false
        ((count++))
        [[ "$notify" == "--notify" ]] && send_tg_expired_notice "$name" "$proto" "$expire_date"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 禁用: $name ($proto)" >> "$CFG/expire.log"
    done <<< "$expired_users"
    
    [[ $count -gt 0 ]] && rebuild_and_reload_xray "silent" 2>/dev/null
    echo "$count"
}

# 发送即将过期提醒
send_expire_warnings() {
    local threshold="${1:-3}"
    local count=0
    
    local expiring_users=$(db_get_expiring_users "$threshold")
    [[ -z "$expiring_users" ]] && echo "$count" && return 0
    
    while IFS='|' read -r core proto name expire_date days_left; do
        [[ -z "$name" ]] && continue
        local last_warn=$(db_get_user_alert_state "$core" "$proto" "$name" "last_expire_warn_day")
        [[ "$last_warn" == "$days_left" ]] && continue
        send_tg_expire_warning "$name" "$proto" "$expire_date" "$days_left"
        db_set_user_alert_state "$core" "$proto" "$name" "last_expire_warn_day" "$days_left"
        ((count++))
    done <<< "$expiring_users"
    
    echo "$count"
}

# 安装过期检查 cron job (每天 3:00)
install_expire_check_cron() {
    local script_path="$0"
    local cron_cmd="0 3 * * * $script_path --check-expire --notify >/dev/null 2>&1"
    
    if crontab -l 2>/dev/null | grep -q "check-expire"; then
        _info "过期检查 cron 已存在"
        return 0
    fi
    
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    [[ $? -eq 0 ]] && _ok "已安装过期检查 cron (每天 3:00)" || _err "安装失败"
}

# 确保过期检查 cron 已安装（设置到期日期时自动调用）
# 返回: 0=已存在, 1=新安装成功, 2=安装失败
ensure_expire_check_cron() {
    local script_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    local cron_cmd="0 3 * * * $script_path --check-expire --notify >/dev/null 2>&1"
    
    # 如果已存在则跳过
    if crontab -l 2>/dev/null | grep -q "check-expire"; then
        echo -e "  ${D}(过期检查定时任务已启用)${NC}"
        return 0
    fi
    
    # 尝试安装
    if (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab - 2>/dev/null; then
        echo -e "  ${G}✓ 已自动安装过期检查定时任务 (每天 3:00)${NC}"
        return 1
    else
        echo -e "  ${Y}提示: 过期检查定时任务未安装，可运行: ./vless-server.sh --setup-expire-cron${NC}"
        return 2
    fi
}

# 卸载过期检查 cron
uninstall_expire_check_cron() {
    crontab -l 2>/dev/null | grep -v "check-expire" | crontab -
    _ok "已移除过期检查 cron"
}

# 获取所有用户的流量统计 (用于显示，支持多端口数组格式)
# 用法: db_get_users_stats "xray" "vless"
# 输出: name|uuid|used|quota|enabled|port|routing|expire_date (每行一个用户)
# 多端口时合并所有端口的用户，无 users 的端口输出默认用户
db_get_users_stats() {
    local core="$1" proto="$2"
    [[ ! -f "$DB_FILE" ]] && return 1
    
    jq -r --arg c "$core" --arg p "$proto" '
        .[$c][$p] as $cfg |
        if $cfg == null then
            empty
        elif ($cfg | type) == "array" then
            # 多端口数组
            $cfg[] | . as $port_cfg |
            if (.users | length) > 0 then
                .users[] | "\(.name)|\(.uuid)|\(.used // 0)|\(.quota // 0)|\(.enabled // true)|\($port_cfg.port)|\(.routing // "")|\(.expire_date // "")"
            elif (.uuid != null or .password != null or .username != null) then
                # 无 users 数组，生成默认用户（与 Xray email 格式一致使用 "default"）
                "default|\(.uuid // .password // .username)|0|0|true|\(.port)||"
            else
                empty
            end
        else
            # 单端口对象
            if ($cfg.users | length) > 0 then
                $cfg.users[] | "\(.name)|\(.uuid)|\(.used // 0)|\(.quota // 0)|\(.enabled // true)|\($cfg.port)|\(.routing // "")|\(.expire_date // "")"
            elif ($cfg.uuid != null or $cfg.password != null or $cfg.username != null) then
                "default|\($cfg.uuid // $cfg.password // $cfg.username)|0|0|true|\($cfg.port)||"
            else
                empty
            end
        end
    ' "$DB_FILE" 2>/dev/null
}


# 格式化流量显示
# 用法: format_bytes 1073741824  -> "1.00 GB"
format_bytes() {
    local bytes="$1"
    if [[ "$bytes" -ge 1099511627776 ]]; then
        awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"
    elif [[ "$bytes" -ge 1073741824 ]]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [[ "$bytes" -ge 1024 ]]; then
        awk "BEGIN {printf \"%.2f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

# 迁移旧数据库到新格式 (兼容性)
# 将单用户配置迁移为多用户格式
db_migrate_to_multiuser() {
    [[ ! -f "$DB_FILE" ]] && return 0
    
    local migrated=false
    
    # 检查是否需要迁移 (检查 xray.vless 是否有 users 字段)
    for core in xray singbox; do
        local protocols=$(db_list_protocols "$core")
        for proto in $protocols; do
            local has_users=$(jq -r --arg p "$proto" ".${core}[\$p].users // \"none\"" "$DB_FILE" 2>/dev/null)
            if [[ "$has_users" == "none" ]]; then
                # 需要迁移：将现有配置转为默认用户
                local uuid=$(db_get_field "$core" "$proto" "uuid")
                local password=$(db_get_field "$core" "$proto" "password")
                local psk=$(db_get_field "$core" "$proto" "psk")
                
                # 根据协议类型确定用户凭证
                local user_cred=""
                if [[ -n "$uuid" ]]; then
                    user_cred="$uuid"
                elif [[ -n "$password" ]]; then
                    user_cred="$password"
                elif [[ -n "$psk" ]]; then
                    user_cred="$psk"
                fi
                
                if [[ -n "$user_cred" ]]; then
                    local created=$(date '+%Y-%m-%d')
                    _db_apply --arg p "$proto" --arg u "$user_cred" --arg c "$created" \
                        ".${core}[\$p].users = [{name:\"default\",uuid:\$u,quota:0,used:0,enabled:true,created:\$c}]"
                    migrated=true
                fi
            fi
        done
    done
    
    [[ "$migrated" == "true" ]] && _ok "数据库已迁移到多用户格式"
}

# 用户变更后重建配置并重载服务
# 用法: rebuild_and_reload_xray [silent]
# 参数: silent - 如果设置则不输出成功信息
rebuild_and_reload_xray() {
    local silent="${1:-}"
    
    # 重新生成 Xray 配置
    if generate_xray_config 2>/dev/null; then
        # 检查 Xray 服务是否在运行
        if svc status vless-reality 2>/dev/null; then
            # 重启服务确保配置生效 (reload 可能不可靠)
            if svc restart vless-reality 2>/dev/null; then
                [[ -z "$silent" ]] && _ok "配置已更新并重载"
                return 0
            else
                [[ -z "$silent" ]] && _err "配置已更新，但服务重启失败"
                return 1
            fi
        else
            [[ -z "$silent" ]] && _ok "配置已更新"
            return 0
        fi
    else
        [[ -z "$silent" ]] && _err "配置重建失败"
        return 1
    fi
}

# 用户变更后重建 Sing-box 配置并重载服务
# 用法: rebuild_and_reload_singbox [silent]
# 参数: silent - 如果设置则不输出成功信息
rebuild_and_reload_singbox() {
    local silent="${1:-}"
    
    # 重新生成 Sing-box 配置
    if generate_singbox_config; then
        # 检查 Sing-box 服务是否在运行
        if svc status vless-singbox 2>/dev/null; then
            # 重载服务
            if svc restart vless-singbox 2>/dev/null; then
                [[ -z "$silent" ]] && _ok "Sing-box 配置已更新并重载"
                return 0
            else
                [[ -z "$silent" ]] && _warn "配置已更新，服务重载失败"
                return 1
            fi
        else
            [[ -z "$silent" ]] && _ok "Sing-box 配置已更新"
            return 0
        fi
    else
        [[ -z "$silent" ]] && _err "Sing-box 配置重建失败"
        return 1
    fi
}


#═══════════════════════════════════════════════════════════════════════════════
#  TG 通知配置
#═══════════════════════════════════════════════════════════════════════════════

readonly TG_CONFIG_FILE="$CFG/telegram.json"

# 初始化 TG 配置
init_tg_config() {
    [[ -f "$TG_CONFIG_FILE" ]] && return 0
    echo '{"enabled":false,"bot_token":"","chat_id":"","notify_quota_percent":80,"notify_daily":false}' > "$TG_CONFIG_FILE"
}

# 获取 TG 配置
tg_get_config() {
    local field="$1"
    [[ ! -f "$TG_CONFIG_FILE" ]] && init_tg_config
    jq -r ".$field // empty" "$TG_CONFIG_FILE" 2>/dev/null
}

# 设置 TG 配置
tg_set_config() {
    local field="$1" value="$2"
    [[ ! -f "$TG_CONFIG_FILE" ]] && init_tg_config
    
    local tmp=$(mktemp)
    if [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
        jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$TG_CONFIG_FILE" > "$tmp"
    else
        jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$TG_CONFIG_FILE" > "$tmp"
    fi
    mv "$tmp" "$TG_CONFIG_FILE"
}

# 发送 TG 消息
tg_send_message() {
    local message="$1"
    local bot_token=$(tg_get_config "bot_token")
    local chat_id=$(tg_get_config "chat_id")
    local enabled=$(tg_get_config "enabled")
    
    [[ "$enabled" != "true" ]] && return 0
    [[ -z "$bot_token" || -z "$chat_id" ]] && return 1
    
    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        --connect-timeout 10 \
        >/dev/null 2>&1
}

# 发送流量告警
tg_send_quota_alert() {
    local user="$1" proto="$2" used="$3" quota="$4" percent="$5"
    local server_ip=$(get_ipv4)
    
    local message="⚠️ *流量告警*

服务器: \`${server_ip}\`
协议: ${proto}
用户: ${user}
已用: $(format_bytes $used)
配额: $(format_bytes $quota)
使用率: ${percent}%"
    
    tg_send_message "$message"
}

# 发送超限通知
tg_send_over_quota() {
    local user="$1" proto="$2" used="$3" quota="$4"
    local server_ip=$(get_ipv4)
    
    local message="🚫 *流量超限*

服务器: \`${server_ip}\`
协议: ${proto}
用户: ${user}
已用: $(format_bytes $used)
配额: $(format_bytes $quota)

用户已被自动禁用"
    
    tg_send_message "$message"
}

# 发送每日流量报告
# 注意: 此函数由 check_daily_report() 调用，而 check_daily_report() 由 sync_all_user_traffic() 调用
# 因此不能在此函数内再次调用 sync_all_user_traffic()，否则会导致无限递归
tg_send_daily_report() {
    local server_ip=$(get_ipv4)
    [[ -z "$server_ip" ]] && server_ip=$(get_ipv6)
    
    local report="📊 *每日流量报告*
服务器: \`${server_ip}\`
时间: $(date '+%Y-%m-%d %H:%M')
━━━━━━━━━━━━━━━━━━━━"
    
    local total_users=0
    local total_used=0
    local user_details=""
    
    # 遍历所有协议的用户
    for core in xray singbox; do
        local protocols=$(db_list_protocols "$core" 2>/dev/null)
        [[ -z "$protocols" ]] && continue
        
        for proto in $protocols; do
            local stats=$(db_get_users_stats "$core" "$proto" 2>/dev/null)
            [[ -z "$stats" ]] && continue
            
            while IFS='|' read -r name uuid used quota enabled port routing; do
                [[ -z "$name" ]] && continue
                ((total_users++))
                total_used=$((total_used + used))
                
                local status_icon="✅"
                [[ "$enabled" != "true" ]] && status_icon="❌"
                
                local used_fmt=$(format_bytes "$used")
                local quota_fmt="∞"
                local percent_str=""
                
                if [[ "$quota" -gt 0 ]]; then
                    quota_fmt=$(format_bytes "$quota")
                    local percent=$((used * 100 / quota))
                    percent_str=" (${percent}%)"
                fi
                
                user_details+="
${status_icon} *${name}* (${proto})
   ${used_fmt} / ${quota_fmt}${percent_str}"
            done <<< "$stats"
        done
    done
    
    report+="
总用户: ${total_users}
总流量: $(format_bytes $total_used)
━━━━━━━━━━━━━━━━━━━━"
    
    # 如果有用户详情则显示
    if [[ -n "$user_details" ]]; then
        report+="
*用户详情:*${user_details}"
    fi
    
    # 添加已安装协议列表
    local installed_protocols=$(get_installed_protocols 2>/dev/null)
    if [[ -n "$installed_protocols" ]]; then
        report+="
━━━━━━━━━━━━━━━━━━━━
*已安装协议:*"
        for proto in $installed_protocols; do
            local proto_name=$(get_protocol_name "$proto")
            report+="
• ${proto_name}"
        done
    fi
    
    tg_send_message "$report"
}

# 检查是否需要发送每日报告
check_daily_report() {
    local enabled=$(tg_get_config "enabled")
    local daily_enabled=$(tg_get_config "notify_daily")
    
    [[ "$enabled" != "true" || "$daily_enabled" != "true" ]] && return 0
    
    local report_hour=$(tg_get_config "daily_report_hour")
    local report_minute=$(tg_get_config "daily_report_minute")
    report_hour=${report_hour:-9}     # 默认早上9点
    report_minute=${report_minute:-0}  # 默认0分
    
    local current_hour=$(date '+%H' | sed 's/^0//')
    local current_minute=$(date '+%M' | sed 's/^0//')
    local last_report_date=$(tg_get_config "last_report_date")
    local today=$(date '+%Y-%m-%d')
    
    # 获取检测间隔（用于范围匹配）
    local interval=$(get_traffic_interval)
    interval=${interval:-5}
    
    # 范围匹配：当前小时等于报告小时，且当前分钟在 [报告分钟, 报告分钟+间隔) 范围内
    # 这样即使 cron 不是精确在报告分钟运行，也能在下一个间隔内触发
    if [[ "$current_hour" -eq "$report_hour" && 
          "$current_minute" -ge "$report_minute" && 
          "$current_minute" -lt "$((report_minute + interval))" && 
          "$last_report_date" != "$today" ]]; then
        tg_send_daily_report
        tg_set_config "last_report_date" "$today"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  流量统计函数 - 基于 Xray Stats API
#═══════════════════════════════════════════════════════════════════════════════

readonly XRAY_API_PORT=10085
readonly TRAFFIC_INTERVAL_FILE="$CFG/traffic_interval"

# 查询 Xray Stats API
# 用法: xray_api_query "user>>>user1@vless>>>traffic>>>downlink"
xray_api_query() {
    local pattern="$1"
    local reset="${2:-false}"  # 是否重置计数器
    
    if ! command -v xray &>/dev/null; then
        return 1
    fi
    
    local cmd="xray api statsquery --server=127.0.0.1:${XRAY_API_PORT}"
    [[ "$reset" == "true" ]] && cmd+=" -reset"
    [[ -n "$pattern" ]] && cmd+=" -pattern \"$pattern\""
    
    eval "$cmd" 2>/dev/null
}

# 获取用户流量 (上行+下行)
# 用法: get_user_traffic "user1@vless" [reset]
# 返回: 总字节数
get_user_traffic() {
    local email="$1"
    local reset="${2:-false}"
    
    local uplink=0 downlink=0
    
    # 查询上行流量
    local up_result=$(xray_api_query "user>>>$email>>>traffic>>>uplink" "$reset" 2>/dev/null)
    if [[ -n "$up_result" ]]; then
        # 使用 jq 解析，兼容大小写字段名
        uplink=$(echo "$up_result" | jq -r '.stat[]? | select((.name // .Name) | contains("uplink")) | (.value // .Value // 0)' 2>/dev/null | head -1)
        # 如果 jq 失败，尝试 grep（兼容大小写）
        if [[ -z "$uplink" || "$uplink" == "null" ]]; then
            uplink=$(echo "$up_result" | grep -oiE '"value"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -o '[0-9]*')
        fi
        uplink=${uplink:-0}
    fi
    
    # 查询下行流量
    local down_result=$(xray_api_query "user>>>$email>>>traffic>>>downlink" "$reset" 2>/dev/null)
    if [[ -n "$down_result" ]]; then
        downlink=$(echo "$down_result" | jq -r '.stat[]? | select((.name // .Name) | contains("downlink")) | (.value // .Value // 0)' 2>/dev/null | head -1)
        if [[ -z "$downlink" || "$downlink" == "null" ]]; then
            downlink=$(echo "$down_result" | grep -oiE '"value"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -o '[0-9]*')
        fi
        downlink=${downlink:-0}
    fi
    
    echo $((uplink + downlink))
}

# 同步所有用户流量到数据库
# 用法: sync_all_user_traffic [reset]
sync_all_user_traffic() {
    local reset="${1:-true}"  # 默认重置计数器
    
    [[ ! -f "$DB_FILE" ]] && return 1
    
    # 检查是否需要发送每日报告 (在流量统计之前调用，确保不会被 early return 跳过)
    check_daily_report
    
    # 检查 Xray 是否运行 (使用兼容 Alpine 的 _pgrep)
    if ! _pgrep xray; then
        return 0  # 改为 return 0，因为每日报告已处理，不算错误
    fi
    
    # 使用临时文件存储 API 结果，避免内存问题
    local tmp_stats=$(mktemp)
    trap "rm -f '$tmp_stats'" RETURN
    
    # 一次性获取所有流量统计（带重置选项）
    local reset_flag=""
    [[ "$reset" == "true" ]] && reset_flag="-reset"
    
    if ! xray api statsquery --server=127.0.0.1:${XRAY_API_PORT} $reset_flag 2>/dev/null | \
         jq -r '.stat[]? | "\(.name // .Name) \(.value // .Value // 0)"' > "$tmp_stats" 2>/dev/null; then
        rm -f "$tmp_stats"
        return 1
    fi
    
    [[ ! -s "$tmp_stats" ]] && { rm -f "$tmp_stats"; return 0; }
    
    local updated=0
    local need_reload=false  # 标记是否需要重载配置
    local notify_percent=$(tg_get_config "notify_quota_percent")
    notify_percent=${notify_percent:-80}
    
    # 定义告警阈值档位（依次检查，每档只发一次）
    local -a alert_thresholds=(80 90 95)
    
    # 遍历所有 Xray 协议
    for proto in $(db_list_protocols "xray"); do
        local users=$(db_list_users "xray" "$proto")
        [[ -z "$users" ]] && continue
        
        for user in $users; do
            local email="${user}@${proto}"
            
            # 从临时文件中提取流量值
            local uplink=$(grep -F "user>>>${email}>>>traffic>>>uplink " "$tmp_stats" 2>/dev/null | awk '{print $NF}')
            local downlink=$(grep -F "user>>>${email}>>>traffic>>>downlink " "$tmp_stats" 2>/dev/null | awk '{print $NF}')
            
            uplink=${uplink:-0}
            downlink=${downlink:-0}
            local traffic=$((uplink + downlink))
            
            if [[ "$traffic" -gt 0 ]]; then
                # 更新数据库
                db_update_user_traffic "xray" "$proto" "$user" "$traffic"
                ((updated++))
                
                # 检查配额
                local quota=$(db_get_user_field "xray" "$proto" "$user" "quota")
                local used=$(db_get_user_field "xray" "$proto" "$user" "used")
                
                if [[ "$quota" -gt 0 ]]; then
                    local percent=$((used * 100 / quota))
                    
                    # 超限检查 (只处理一次)
                    if [[ "$used" -ge "$quota" ]]; then
                        # 检查是否已发送过超限通知
                        local exceeded_notified=$(db_get_user_alert_state "xray" "$proto" "$user" "quota_exceeded_notified")
                        if [[ "$exceeded_notified" != "true" ]]; then
                            # 禁用用户
                            db_set_user_enabled "xray" "$proto" "$user" "false"
                            # 标记已发送超限通知
                            db_set_user_alert_state "xray" "$proto" "$user" "quota_exceeded_notified" "true"
                            # 发送通知
                            tg_send_over_quota "$user" "$proto" "$used" "$quota"
                            # 标记需要重载配置
                            need_reload=true
                        fi
                    elif [[ "$percent" -ge "$notify_percent" ]]; then
                        # 告警检查：只在跨越新的阈值档位时发送
                        local last_alert=$(db_get_user_alert_state "xray" "$proto" "$user" "last_alert_percent")
                        last_alert=${last_alert:-0}
                        
                        # 找到当前应该告警的最高档位
                        local should_alert=false
                        local current_threshold=0
                        for threshold in "${alert_thresholds[@]}"; do
                            if [[ "$percent" -ge "$threshold" && "$last_alert" -lt "$threshold" ]]; then
                                should_alert=true
                                current_threshold=$threshold
                            fi
                        done
                        
                        if [[ "$should_alert" == "true" ]]; then
                            # 发送告警并更新记录
                            tg_send_quota_alert "$user" "$proto" "$used" "$quota" "$percent"
                            db_set_user_alert_state "xray" "$proto" "$user" "last_alert_percent" "$current_threshold"
                        fi
                    fi
                fi
            fi
        done
    done
    
    rm -f "$tmp_stats"
    
    # 批量处理完成后统一重载配置（避免循环内多次重启）
    if [[ "$need_reload" == "true" ]]; then
        generate_xray_config 2>/dev/null
        svc restart vless-reality 2>/dev/null
    fi
    
    # 注：Sing-box 协议 (hy2/tuic) 暂不支持流量统计（需要完整版编译）
    
    return 0
}

# 获取所有用户流量统计 (用于显示)
# 输出格式: proto|user|uplink|downlink|total
# 注：仅支持 Xray 协议，Sing-box (hy2/tuic) 需要完整版支持
get_all_traffic_stats() {
    [[ ! -f "$DB_FILE" ]] && return 1
    
    # 使用临时文件存储，避免大变量导致内存问题
    local tmp_stats=$(mktemp)
    trap "rm -f '$tmp_stats'" RETURN
    
    local has_data=false
    
    # === Xray 流量统计 ===
    if _pgrep xray &>/dev/null; then
        if xray api statsquery --server=127.0.0.1:${XRAY_API_PORT} 2>/dev/null | \
             jq -r '.stat[]? | "\(.name // .Name) \(.value // .Value // 0)"' > "$tmp_stats" 2>/dev/null; then
            
            if [[ -s "$tmp_stats" ]]; then
                # 遍历 Xray 用户
                for proto in $(db_list_protocols "xray"); do
                    local users=$(db_list_users "xray" "$proto")
                    [[ -z "$users" ]] && continue
                    
                    for user in $users; do
                        local email="${user}@${proto}"
                        
                        local uplink=$(grep -F "user>>>${email}>>>traffic>>>uplink " "$tmp_stats" 2>/dev/null | awk '{print $NF}')
                        local downlink=$(grep -F "user>>>${email}>>>traffic>>>downlink " "$tmp_stats" 2>/dev/null | awk '{print $NF}')
                        
                        uplink=${uplink:-0}
                        downlink=${downlink:-0}
                        
                        local total=$((uplink + downlink))
                        if [[ "$total" -gt 0 ]]; then
                            echo "${proto}|${user}|${uplink}|${downlink}|${total}"
                            has_data=true
                        fi
                    done
                done
            fi
        fi
    fi
    
    # 注：Sing-box 协议 (hy2/tuic) 暂不支持实时流量统计（需要完整版编译）
    
    rm -f "$tmp_stats"
}

# 获取流量检测间隔 (分钟)
get_traffic_interval() {
    if [[ -f "$TRAFFIC_INTERVAL_FILE" ]]; then
        cat "$TRAFFIC_INTERVAL_FILE"
    else
        echo "5"  # 默认5分钟
    fi
}

# 设置流量检测间隔
set_traffic_interval() {
    local interval="$1"
    echo "$interval" > "$TRAFFIC_INTERVAL_FILE"
}

# 创建流量统计定时任务
setup_traffic_cron() {
    local interval="${1:-$(get_traffic_interval)}"
    local script_path=$(readlink -f "$0")
    local cron_cmd="*/$interval * * * * $script_path --sync-traffic >/dev/null 2>&1"
    
    # 先移除旧的定时任务
    crontab -l 2>/dev/null | grep -v "sync-traffic" | crontab - 2>/dev/null
    
    # 添加新的定时任务
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    
    # 保存间隔设置
    set_traffic_interval "$interval"
    
    _ok "已添加流量统计定时任务 (每${interval}分钟)"
}

# 移除流量统计定时任务
remove_traffic_cron() {
    crontab -l 2>/dev/null | grep -v "sync-traffic" | crontab -
    _ok "已移除流量统计定时任务"
}


#═══════════════════════════════════════════════════════════════════════════════
#  通用配置保存函数
#═══════════════════════════════════════════════════════════════════════════════

# 简化版：直接用关联数组构建 JSON
# 用法: build_config "uuid" "$uuid" "port" "$port" "sni" "$sni"
build_config() {
    local args=()
    local keys=()
    
    while [[ $# -ge 2 ]]; do
        local key="$1" val="$2"
        shift 2
        keys+=("$key")
        # 数字检测
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            args+=(--argjson "$key" "$val")
        else
            args+=(--arg "$key" "$val")
        fi
    done
    
    # 自动添加 IP
    local ipv4=$(get_ipv4) ipv6=$(get_ipv6)
    args+=(--arg "ipv4" "$ipv4" --arg "ipv6" "$ipv6")
    keys+=("ipv4" "ipv6")
    
    # 构建 jq 表达式
    local expr="{"
    local first=true
    for k in "${keys[@]}"; do
        [[ "$first" == "true" ]] && first=false || expr+=","
        expr+="\"$k\":\$$k"
    done
    expr+="}"
    
    jq -n "${args[@]}" "$expr"
}

# 保存 JOIN 信息到文件
# 用法: _save_join_info "协议名" "数据格式" "链接生成命令" [额外行...]
# 数据格式中 %s 会被替换为 IP，%b 会被替换为 [IP] (IPv6 带括号)
# 示例: _save_join_info "vless" "REALITY|%s|$port|$uuid" "gen_vless_link %s $port $uuid"
_save_join_info() {
    local protocol="$1" data_fmt="$2" link_cmd="$3"; shift 3
    local join_file="$CFG/${protocol}.join"
    local link_prefix; link_prefix=$(tr '[:lower:]-' '[:upper:]_' <<<"$protocol")
    : >"$join_file"

    local label ip ipfmt data code cmd link
    for label in V4 V6; do
        ip=$([[ "$label" == V4 ]] && get_ipv4 || get_ipv6)
        [[ -z "$ip" ]] && continue
        ipfmt=$ip; [[ "$label" == V6 ]] && ipfmt="[$ip]"

        data=${data_fmt//%s/$ipfmt}; data=${data//%b/$ipfmt}
        code=$(printf '%s' "$data" | base64 -w 0 2>/dev/null || printf '%s' "$data" | base64)
        cmd=${link_cmd//%s/$ipfmt}; cmd=${cmd//%b/$ipfmt}
        link=$(eval "$cmd")

        printf '# IPv%s\nJOIN_%s=%s\n%s_%s=%s\n' "${label#V}" "$label" "$code" "$link_prefix" "$label" "$link" >>"$join_file"
    done

    local line
    for line in "$@"; do
        printf '%s\n' "$line" >>"$join_file"
    done
}


# 检测 TLS 主协议并返回外部端口（用于 WS 类回落协议）
# 注意：Reality (vless) 不支持 WS 回落，只有 vless-vision 和 trojan 可以
# 仅当主协议端口为 8443 时才触发回落
# 用法: outer_port=$(_get_master_port "$default_port")
_get_master_port() {
    local default_port="$1"
    local master_port=""
    
    if db_exists "xray" "vless-vision"; then
        master_port=$(db_get_field "xray" "vless-vision" "port")
    elif db_exists "xray" "trojan"; then
        master_port=$(db_get_field "xray" "trojan" "port")
    fi
    
    # 仅当主协议端口为 8443 时才返回主端口（触发回落）
    if [[ "$master_port" == "8443" ]]; then
        echo "$master_port"
    else
        echo "$default_port"
    fi
}

# 检测是否有 TLS 主协议且端口为 8443 (支持 WS 回落的协议)
# 注意：Reality 使用 uTLS，不支持 WS 类型的回落
_has_master_protocol() {
    local master_port=""
    
    if db_exists "xray" "vless-vision"; then
        master_port=$(db_get_field "xray" "vless-vision" "port")
    elif db_exists "xray" "trojan"; then
        master_port=$(db_get_field "xray" "trojan" "port")
    fi
    
    # 仅当主协议存在且端口为 8443 时返回成功
    [[ "$master_port" == "8443" ]]
}

# 检查证书是否为 CA 签发的真实证书
_is_real_cert() {
    [[ ! -f "$CFG/certs/server.crt" ]] && return 1
    local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
    [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || \
    [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]] || \
    [[ "$issuer" == *"E1"* ]] || [[ "$issuer" == *"ZeroSSL"* ]] || [[ "$issuer" == *"Buypass"* ]]
}

# 确保 Nginx HTTPS 监听存在 (真实域名模式，供 Reality dest 回落)
# 用法: _ensure_nginx_https_for_reality "domain.com"
_ensure_nginx_https_for_reality() {
    local domain="$1"
    local nginx_https_port=8443
    local nginx_conf=""
    
    # 确定 nginx 配置文件路径 (Alpine http.d 优先)
    if [[ -d "/etc/nginx/http.d" ]]; then
        nginx_conf="/etc/nginx/http.d/vless-reality-https.conf"
    elif [[ -d "/etc/nginx/sites-available" ]]; then
        nginx_conf="/etc/nginx/sites-available/vless-reality-https"
    elif [[ -d "/etc/nginx/conf.d" ]]; then
        nginx_conf="/etc/nginx/conf.d/vless-reality-https.conf"
    else
        return 1
    fi
    
    # 检查 8443 端口是否已被 nginx 监听
    if ss -tln 2>/dev/null | grep -q ":${nginx_https_port} "; then
        # 端口已被占用，检查是否是我们的配置
        [[ -f "$nginx_conf" ]] && return 0
    fi
    
    # 确保 nginx 已安装
    if ! command -v nginx &>/dev/null; then
        return 1
    fi
    
    # 生成 HTTPS 配置 (供 Reality dest 回落)
    cat > "$nginx_conf" << EOF
# Reality 回落后端 (真实域名模式) - 供 Reality dest 使用
# 此配置由脚本自动生成，请勿手动修改
server {
    listen 127.0.0.1:${nginx_https_port} ssl http2;
    server_name ${domain};
    
    ssl_certificate $CFG/certs/server.crt;
    ssl_certificate_key $CFG/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    root /var/www/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    server_tokens off;
}
EOF
    
    # 如果是 sites-available 模式，创建软链接
    if [[ "$nginx_conf" == *"sites-available"* ]]; then
        ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/vless-reality-https" 2>/dev/null
    fi
    
    # 重载 nginx
    nginx -t &>/dev/null && nginx -s reload &>/dev/null
    return 0
}

# 配置 Nginx 反代 XHTTP (h2c 模式，用于 TLS+CDN)
# 用法: _setup_nginx_xhttp_proxy "domain.com" "18080" "/xhttp_path"
_setup_nginx_xhttp_proxy() {
    local domain="$1"
    local internal_port="$2"
    local path="$3"
    local nginx_conf=""
    
    # 确定 nginx 配置文件路径
    if [[ -d "/etc/nginx/http.d" ]]; then
        nginx_conf="/etc/nginx/http.d/xhttp-cdn.conf"
    elif [[ -d "/etc/nginx/sites-available" ]]; then
        nginx_conf="/etc/nginx/sites-available/xhttp-cdn"
    elif [[ -d "/etc/nginx/conf.d" ]]; then
        nginx_conf="/etc/nginx/conf.d/xhttp-cdn.conf"
    else
        _err "未找到 Nginx 配置目录"
        return 1
    fi
    
    # 确保 nginx 已安装
    if ! command -v nginx &>/dev/null; then
        _err "Nginx 未安装"
        return 1
    fi
    
    # 生成 XHTTP 反代配置 (h2c 模式)
    # 注意: 使用 listen ... http2 语法兼容所有 Nginx 版本
    cat > "$nginx_conf" << 'NGINX_EOF'
# XHTTP TLS+CDN 反代配置 - 供 Cloudflare CDN 使用
# 此配置由脚本自动生成，请勿手动修改
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    
    server_name DOMAIN_PLACEHOLDER;
    
    ssl_certificate CFG_PLACEHOLDER/certs/server.crt;
    ssl_certificate_key CFG_PLACEHOLDER/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    # XHTTP 路径反代到 Xray (h2c)
    location PATH_PLACEHOLDER {
        grpc_pass grpc://127.0.0.1:PORT_PLACEHOLDER;
        grpc_set_header Host $host;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    
    # 其他路径返回伪装页面
    location / {
        root /var/www/html;
        index index.html;
        try_files $uri $uri/ =404;
    }
    
    server_tokens off;
}
NGINX_EOF
    
    # 替换占位符
    sed -i "s|DOMAIN_PLACEHOLDER|${domain}|g" "$nginx_conf"
    sed -i "s|CFG_PLACEHOLDER|${CFG}|g" "$nginx_conf"
    sed -i "s|PATH_PLACEHOLDER|${path}|g" "$nginx_conf"
    sed -i "s|PORT_PLACEHOLDER|${internal_port}|g" "$nginx_conf"
    
    # 如果是 sites-available 模式，创建软链接
    if [[ "$nginx_conf" == *"sites-available"* ]]; then
        ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/xhttp-cdn" 2>/dev/null
    fi
    
    # 测试并重载 nginx
    if nginx -t &>/dev/null; then
        nginx -s reload &>/dev/null
        _ok "Nginx XHTTP 反代配置成功"
        return 0
    else
        _err "Nginx 配置错误"
        nginx -t
        return 1
    fi
}

# 生成 VLESS+XHTTP+TLS+CDN 配置 (无 Reality，纯 h2c 模式)
# 用法: gen_vless_xhttp_tls_cdn_config "$uuid" "$port" "$path" "$domain"
gen_vless_xhttp_tls_cdn_config() {
    local uuid="$1"
    local port="$2"
    local path="$3"
    local domain="$4"
    local protocol="vless-xhttp-cdn"
    
    # 保存到数据库 (对外端口固定为 443，内部端口为用户指定)
    local config_json=$(build_config \
        "uuid" "$uuid" \
        "port" "$port" \
        "internal_port" "$port" \
        "path" "$path" \
        "domain" "$domain" \
        "sni" "$domain" \
        "mode" "tls-cdn")
    
    # 添加默认用户
    config_json=$(echo "$config_json" | jq --arg name "default" --arg uuid "$uuid" \
        '.users = [{"name": $name, "uuid": $uuid, "quota": 0, "used": 0, "enabled": true, "created": (now | strftime("%Y-%m-%d"))}]')
    
    # 使用 register_protocol 支持多端口和覆盖模式
    register_protocol "$protocol" "$config_json"
    
    # 生成分享链接 (URL 编码 path)
    local encoded_path=$(printf '%s' "$path" | sed 's|/|%2F|g')
    local share_link="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=xhttp&host=${domain}&path=${encoded_path}&mode=auto#XHTTP-CDN"
    
    # 保存 JOIN 信息
    echo "# XHTTP TLS+CDN" > "$CFG/${protocol}.join"
    echo "XHTTP_CDN_LINK=${share_link}" >> "$CFG/${protocol}.join"
    
    _ok "配置生成成功"
    echo ""
    echo -e "  ${C}分享链接:${NC}"
    echo -e "  ${G}${share_link}${NC}"
    echo ""
    echo -e "  ${Y}客户端配置:${NC} 地址=${domain}, 端口=443, TLS=开启"
    
    return 0
}

# 处理独立协议的证书 (WS 类协议独立安装时使用)
# 用法: _handle_standalone_cert "$sni" "$force_new_cert"
_handle_standalone_cert() {
    local sni="$1" force_new="${2:-false}"
    
    if [[ "$force_new" == "true" ]]; then
        if _is_real_cert; then
            _warn "检测到 CA 签发的真实证书，不会覆盖"
            return 1
        fi
        rm -f "$CFG/certs/server.crt" "$CFG/certs/server.key"
        gen_self_cert "$sni"
        # 自签证书使用独立的标记文件，不写入 cert_domain (避免与 ACME 证书混淆)
        echo "$sni" > "$CFG/self_cert_sni"
        rm -f "$CFG/cert_domain"  # 清除可能存在的 ACME 域名记录
    elif [[ ! -f "$CFG/certs/server.crt" ]]; then
        gen_self_cert "$sni"
        echo "$sni" > "$CFG/self_cert_sni"
    fi
    return 0
}

# 检测系统是否支持 IPv6
_has_ipv6() {
    [[ -e /proc/net/if_inet6 ]]
}

# 检测 IPv6 socket 是否允许双栈（IPv4-mapped）
_can_dual_stack_listen() {
    [[ ! -f /proc/sys/net/ipv6/bindv6only ]] && return 0
    local val
    val=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo "1")
    [[ "$val" == "0" ]]
}

# 获取监听地址：有 IPv6 且支持双栈才用 ::，否则用 0.0.0.0
_listen_addr() {
    if _has_ipv6 && _can_dual_stack_listen; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

# 格式化 host:port（IPv6 需要方括号）
_fmt_hostport() {
    local host="$1" port="$2"
    if [[ "$host" == *:* ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
#  用户配置区 - 可根据需要修改以下设置
#═══════════════════════════════════════════════════════════════════════════════
# JOIN 码显示开关 (on=显示, off=隐藏)
SHOW_JOIN_CODE="off"
#═══════════════════════════════════════════════════════════════════════════════

# 颜色
R='\e[31m'; G='\e[32m'; Y='\e[33m'; C='\e[36m'; M='\e[35m'; W='\e[97m'; D='\e[2m'; NC='\e[0m'
set -o pipefail

# 日志文件
LOG_FILE="/var/log/vless-server.log"

# 统一日志函数 - 同时输出到终端和日志文件
_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 写入日志文件（无颜色）
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null
}

# 初始化日志文件
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    # 日志轮转：超过 5MB 时截断保留最后 1000 行
    if [[ -f "$LOG_FILE" ]]; then
        local size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $size -gt 5242880 ]]; then
            tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
    _log "INFO" "========== 脚本启动 v${VERSION} =========="
}

# timeout 兼容函数（某些精简系统可能没有 timeout 命令）
if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"
        shift
        # 使用后台进程实现简单的超时
        "$@" &
        local pid=$!
        ( sleep "$duration" 2>/dev/null; kill -9 $pid 2>/dev/null ) &
        local killer=$!
        wait $pid 2>/dev/null
        local ret=$?
        kill $killer 2>/dev/null
        wait $killer 2>/dev/null
        return $ret
    }
fi

# 系统检测
if [[ -f /etc/alpine-release ]]; then
    DISTRO="alpine"
elif [[ -f /etc/redhat-release ]]; then
    DISTRO="centos"
elif [[ -f /etc/lsb-release ]] && grep -q "Ubuntu" /etc/lsb-release; then
    DISTRO="ubuntu"
elif [[ -f /etc/os-release ]] && grep -q "Ubuntu" /etc/os-release; then
    DISTRO="ubuntu"
else
    DISTRO="debian"
fi

# RHEL 系兼容：无 yum 时使用 dnf
if ! command -v yum &>/dev/null && command -v dnf &>/dev/null; then
    yum() { dnf "$@"; }
fi

#═══════════════════════════════════════════════════════════════════════════════
# 多协议管理系统
#═══════════════════════════════════════════════════════════════════════════════

# 协议分类定义 (重构: Sing-box 接管独立协议)
XRAY_PROTOCOLS="vless vless-xhttp vless-xhttp-cdn vless-ws vless-ws-notls vmess-ws vless-vision trojan trojan-ws socks ss2022 ss-legacy"
# Sing-box 管理的协议 (原独立协议，现统一由 Sing-box 处理)
SINGBOX_PROTOCOLS="hy2 tuic"
# 仍需独立进程的协议 (Snell 等闭源协议)
STANDALONE_PROTOCOLS="snell snell-v5 snell-shadowtls snell-v5-shadowtls ss2022-shadowtls anytls naive"

#═══════════════════════════════════════════════════════════════════════════════
#  表驱动元数据 (协议/服务/进程/启动命令)
#  说明：将 “协议差异” 集中到这里，主体流程尽量通用化
#═══════════════════════════════════════════════════════════════════════════════
declare -A PROTO_SVC PROTO_EXEC PROTO_BIN PROTO_KIND
declare -A BACKEND_NAME BACKEND_DESC BACKEND_EXEC

# Xray 统一服务：所有 XRAY_PROTOCOLS 共用一个主服务 vless-reality
for _p in $XRAY_PROTOCOLS; do
    PROTO_SVC[$_p]="vless-reality"
    PROTO_EXEC[$_p]="/usr/local/bin/xray run -c $CFG/config.json"
    PROTO_BIN[$_p]="xray"
    PROTO_KIND[$_p]="xray"
done

# Sing-box 统一服务：hy2/tuic 由 vless-singbox 统一管理
PROTO_SVC[hy2]="vless-singbox";  PROTO_BIN[hy2]="sing-box"; PROTO_KIND[hy2]="singbox"
PROTO_SVC[tuic]="vless-singbox"; PROTO_BIN[tuic]="sing-box"; PROTO_KIND[tuic]="singbox"

# 独立协议 (Snell 等闭源协议仍需独立进程)
PROTO_SVC[snell]="vless-snell";     PROTO_EXEC[snell]="/usr/local/bin/snell-server -c $CFG/snell.conf";        PROTO_BIN[snell]="snell-server"; PROTO_KIND[snell]="snell"
PROTO_SVC[snell-v5]="vless-snell-v5"; PROTO_EXEC[snell-v5]="/usr/local/bin/snell-server-v5 -c $CFG/snell-v5.conf"; PROTO_BIN[snell-v5]="snell-server-v5"; PROTO_KIND[snell-v5]="snell"

# 动态命令：运行时从数据库取参数
PROTO_SVC[anytls]="vless-anytls"; PROTO_KIND[anytls]="anytls"
PROTO_SVC[naive]="vless-naive"; PROTO_KIND[naive]="naive"

# ShadowTLS：主服务 shadow-tls + 额外 backend 服务
for _p in snell-shadowtls snell-v5-shadowtls ss2022-shadowtls; do
    PROTO_SVC[$_p]="vless-${_p}"
    PROTO_KIND[$_p]="shadowtls"
    PROTO_BIN[$_p]="shadow-tls"
done

BACKEND_NAME[snell-shadowtls]="vless-snell-shadowtls-backend"
BACKEND_DESC[snell-shadowtls]="Snell Backend for ShadowTLS"
BACKEND_EXEC[snell-shadowtls]="/usr/local/bin/snell-server -c $CFG/snell-shadowtls.conf"

BACKEND_NAME[snell-v5-shadowtls]="vless-snell-v5-shadowtls-backend"
BACKEND_DESC[snell-v5-shadowtls]="Snell v5 Backend for ShadowTLS"
BACKEND_EXEC[snell-v5-shadowtls]="/usr/local/bin/snell-server-v5 -c $CFG/snell-v5-shadowtls.conf"

BACKEND_NAME[ss2022-shadowtls]="vless-ss2022-shadowtls-backend"
BACKEND_DESC[ss2022-shadowtls]="SS2022 Backend for ShadowTLS"
BACKEND_EXEC[ss2022-shadowtls]="/usr/local/bin/xray run -c $CFG/ss2022-shadowtls-backend.json"

# OpenRC status 回退：服务名 -> 进程名
declare -A SVC_PROC=(
    [vless-reality]="xray"
    [vless-singbox]="sing-box"
    [vless-snell]="snell-server"
    [vless-snell-v5]="snell-server-v5"
    [vless-anytls]="anytls-server"
    [vless-naive]="caddy"
    [vless-snell-shadowtls]="shadow-tls"
    [vless-snell-v5-shadowtls]="shadow-tls"
    [vless-ss2022-shadowtls]="shadow-tls"
    [nginx]="nginx"
)

# 注册协议配置到数据库
# 参数: $1=protocol, $2=config_json
register_protocol() {
    local protocol="$1"
    local config_json="$2"
    
    # 确定核心类型
    local core="xray"
    if [[ " $SINGBOX_PROTOCOLS " == *" $protocol "* ]]; then
        core="singbox"
    fi
    
    # 获取端口
    local port
    port=$(echo "$config_json" | jq -r '.port')
    
    # 根据安装模式处理
    if [[ "$INSTALL_MODE" == "replace" && -n "$REPLACE_PORT" ]]; then
        # 覆盖模式：更新指定端口的配置
        echo -e "  ${CYAN}覆盖端口 $REPLACE_PORT 的配置...${NC}"
        db_update_port "$core" "$protocol" "$REPLACE_PORT" "$config_json"
    elif [[ "$INSTALL_MODE" == "add" ]]; then
        # 添加模式：添加新端口实例
        echo -e "  ${CYAN}添加新端口 $port 实例...${NC}"
        db_add_port "$core" "$protocol" "$config_json"
    elif is_protocol_installed "$protocol"; then
        # 协议已存在但未指定模式：默认添加新端口
        echo -e "  ${CYAN}添加新端口 $port 实例...${NC}"
        db_add_port "$core" "$protocol" "$config_json"
    else
        # 首次安装：使用单对象格式
        db_add "$core" "$protocol" "$config_json"
    fi
    
    # 重置安装模式变量
    unset INSTALL_MODE REPLACE_PORT
}

unregister_protocol() {
    local protocol=$1
    
    # 从数据库删除
    db_del "xray" "$protocol" 2>/dev/null
    db_del "singbox" "$protocol" 2>/dev/null
}

get_installed_protocols() {
    # 从数据库获取
    if [[ -f "$DB_FILE" ]]; then
        db_get_all_protocols
    fi
}

is_protocol_installed() {
    local protocol=$1
    # 检查数据库
    db_exists "xray" "$protocol" && return 0
    db_exists "singbox" "$protocol" && return 0
    return 1
}

filter_installed() { # filter_installed "proto1 proto2 ..."
    local installed; installed=$(get_installed_protocols) || return 0
    local p
    for p in $1; do
        grep -qx "$p" <<<"$installed" && echo "$p"
    done
}

get_xray_protocols()       { filter_installed "$XRAY_PROTOCOLS"; }
get_singbox_protocols()    { filter_installed "$SINGBOX_PROTOCOLS"; }
get_standalone_protocols() {
    # 独立协议使用 db_exists 逐个检测，避免 grep 匹配问题
    local p
    for p in $STANDALONE_PROTOCOLS; do
        if db_exists "xray" "$p" || db_exists "singbox" "$p"; then
            echo "$p"
        fi
    done
}

# 生成用户级路由规则
# 遍历所有用户，为有自定义routing的用户生成Xray routing rules
# 返回: JSON数组格式的路由规则
gen_xray_user_routing_rules() {
    local rules="[]"
    
    # 遍历所有 Xray 协议
    local xray_protocols=$(get_xray_protocols)
    [[ -z "$xray_protocols" ]] && { echo "[]"; return; }
    
    for proto in $xray_protocols; do
        local stats=$(db_get_users_stats "xray" "$proto")
        [[ -z "$stats" ]] && continue
        
        while IFS='|' read -r name uuid used quota enabled port routing; do
            [[ -z "$name" || -z "$routing" || "$routing" == "null" ]] && continue
            [[ "$enabled" != "true" ]] && continue  # 只为启用的用户生成规则
            
            local email="${name}@${proto}"
            
            case "$routing" in
                direct)
                    local rule=$(jq -n \
                        --arg user "$email" \
                        '{type: "field", user: [$user], outboundTag: "direct"}')
                    rules=$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')
                    ;;
                warp)
                    local rule=$(jq -n \
                        --arg user "$email" \
                        '{type: "field", user: [$user], outboundTag: "warp-prefer-ipv4"}')
                    rules=$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')
                    ;;
                chain:*)
                    local node_name="${routing#chain:}"
                    local outbound_tag="chain-${node_name}-prefer-ipv4"
                    local rule=$(jq -n \
                        --arg user "$email" \
                        --arg tag "$outbound_tag" \
                        '{type: "field", user: [$user], outboundTag: $tag}')
                    rules=$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')
                    ;;
                balancer:*)
                    local group_name="${routing#balancer:}"
                    local balancer_tag="balancer-${group_name}"
                    # 负载均衡使用 balancerTag 而不是 outboundTag
                    local rule=$(jq -n \
                        --arg user "$email" \
                        --arg tag "$balancer_tag" \
                        '{type: "field", user: [$user], balancerTag: $tag}')
                    rules=$(echo "$rules" | jq --argjson r "$rule" '. + [$r]')
                    ;;
            esac
        done <<< "$stats"
    done
    
    echo "$rules"
}

# 获取用户路由需要的额外outbounds (确保WARP/链式代理等出口存在)
# 返回: 需要添加的outbound tags列表
gen_xray_user_routing_outbounds() {
    local outbounds_needed=""
    
    local xray_protocols=$(get_xray_protocols)
    [[ -z "$xray_protocols" ]] && return
    
    for proto in $xray_protocols; do
        local stats=$(db_get_users_stats "xray" "$proto")
        [[ -z "$stats" ]] && continue
        
        while IFS='|' read -r name uuid used quota enabled port routing; do
            [[ -z "$routing" || "$routing" == "null" ]] && continue
            
            case "$routing" in
                warp)
                    echo "warp"
                    ;;
                chain:*)
                    echo "$routing"
                    ;;
                balancer:*)
                    echo "$routing"
                    ;;
            esac
        done <<< "$stats"
    done | sort -u
}

# 生成 Xray 多 inbounds 配置
generate_xray_config() {
    local xray_protocols=$(get_xray_protocols)
    [[ -z "$xray_protocols" ]] && return 1
    
    mkdir -p "$CFG"
    
    # 确保日志目录存在
    mkdir -p /var/log/xray
    
    # 读取直连出口 IP 版本设置（默认 AsIs）
    local direct_ip_version="as_is"
    [[ -f "$CFG/direct_ip_version" ]] && direct_ip_version=$(cat "$CFG/direct_ip_version")

    # 监听地址：IPv6 双栈不可用时退回 IPv4
    local listen_addr=$(_listen_addr)
    
    # 根据设置生成 freedom 出口配置
    local direct_outbound='{"protocol": "freedom", "tag": "direct"}'
    case "$direct_ip_version" in
        ipv4|ipv4_only)
            direct_outbound='{"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}}'
            ;;
        ipv6|ipv6_only)
            direct_outbound='{"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv6"}}'
            ;;
        prefer_ipv4)
            direct_outbound='{"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}}'
            ;;
        prefer_ipv6)
            direct_outbound='{"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv6"}}'
            ;;
        as_is|asis)
            direct_outbound='{"protocol": "freedom", "tag": "direct"}'
            ;;
    esac
    
    # 收集所有需要的出口
    local outbounds="[$direct_outbound, {\"protocol\": \"blackhole\", \"tag\": \"block\"}]"
    local routing_rules=""
    local balancers="[]"
    local has_routing=false
    
    # 获取分流规则
    local rules=$(db_get_routing_rules)
    
    if [[ -n "$rules" && "$rules" != "[]" ]]; then
        # 收集所有用到的出口 (支持多出口)
        
        while IFS= read -r rule_json; do
            [[ -z "$rule_json" ]] && continue
            local outbound=$(echo "$rule_json" | jq -r '.outbound')
            local ip_version=$(echo "$rule_json" | jq -r '.ip_version // "prefer_ipv4"')
            
            if [[ "$outbound" == "direct" ]]; then
                # 直连规则：根据 IP 版本策略添加专用出口
                case "$ip_version" in
                    ipv4_only)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-ipv4" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_ipv4_out='{"protocol": "freedom", "tag": "direct-ipv4", "settings": {"domainStrategy": "UseIPv4"}}'
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_ipv4_out" '. + [$out]')
                        fi
                        ;;
                    ipv6_only)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-ipv6" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_ipv6_out='{"protocol": "freedom", "tag": "direct-ipv6", "settings": {"domainStrategy": "UseIPv6"}}'
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_ipv6_out" '. + [$out]')
                        fi
                        ;;
                    prefer_ipv6)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-prefer-ipv6" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_prefer_ipv6_out='{"protocol": "freedom", "tag": "direct-prefer-ipv6", "settings": {"domainStrategy": "UseIPv6"}}'
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_prefer_ipv6_out" '. + [$out]')
                        fi
                        ;;
                    as_is|asis)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-asis" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_asis_out='{"protocol": "freedom", "tag": "direct-asis"}'
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_asis_out" '. + [$out]')
                        fi
                        ;;
                    prefer_ipv4|*)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-prefer-ipv4" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_prefer_ipv4_out='{"protocol": "freedom", "tag": "direct-prefer-ipv4", "settings": {"domainStrategy": "UseIPv4"}}'
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_prefer_ipv4_out" '. + [$out]')
                        fi
                        ;;
                esac
            elif [[ "$outbound" == "warp" ]]; then
                local warp_tag=""
                local warp_strategy=""
                case "$ip_version" in
                    ipv4_only)
                        warp_tag="warp-ipv4"
                        warp_strategy="ForceIPv4"
                        ;;
                    ipv6_only)
                        warp_tag="warp-ipv6"
                        warp_strategy="ForceIPv6"
                        ;;
                    prefer_ipv6)
                        warp_tag="warp-prefer-ipv6"
                        warp_strategy="ForceIPv6v4"
                        ;;
                    prefer_ipv4|*)
                        warp_tag="warp-prefer-ipv4"
                        warp_strategy="ForceIPv4v6"
                        ;;
                esac
                if ! echo "$outbounds" | jq -e --arg tag "$warp_tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                    local warp_out=$(gen_xray_warp_outbound)
                    if [[ -n "$warp_out" ]]; then
                        # WireGuard 使用 ForceIPv4 等策略（不是 UseIPv4）
                        local warp_out_with_strategy=$(echo "$warp_out" | jq --arg tag "$warp_tag" --arg ds "$warp_strategy" \
                            '.tag = $tag | .domainStrategy = $ds')
                        outbounds=$(echo "$outbounds" | jq --argjson out "$warp_out_with_strategy" '. + [$out]')
                    fi
                fi
            elif [[ "$outbound" == chain:* ]]; then
                local node_name="${outbound#chain:}"
                local tag_suffix=""
                case "$ip_version" in
                    ipv4_only) tag_suffix="-ipv4" ;;
                    ipv6_only) tag_suffix="-ipv6" ;;
                    prefer_ipv6) tag_suffix="-prefer-ipv6" ;;
                    prefer_ipv4|*) tag_suffix="-prefer-ipv4" ;;
                esac
                local tag="chain-${node_name}${tag_suffix}"
                # 链式代理支持每种策略一个独立出口
                if ! echo "$outbounds" | jq -e --arg tag "$tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                    local chain_out=$(gen_xray_chain_outbound "$node_name" "$tag" "$ip_version")
                    [[ -n "$chain_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                fi
            fi
        done < <(echo "$rules" | jq -c '.[]')
        
        # 独立检查 WARP 配置，确保有 WARP 就生成 outbound（不依赖分流规则）
        local warp_mode=$(db_get_warp_mode)
        if [[ -n "$warp_mode" && "$warp_mode" != "disabled" ]]; then
            # 检查是否已经有 warp outbound（可能在遍历规则时已生成）
            if ! echo "$outbounds" | jq -e '.[] | select(.tag == "warp" or .tag | startswith("warp-"))' >/dev/null 2>&1; then
                # 没有 warp outbound，生成一个默认的
                local warp_out=$(gen_xray_warp_outbound)
                if [[ -n "$warp_out" ]]; then
                    # 使用默认 tag "warp"，WireGuard 使用 ForceIPv4 策略
                    local warp_out_default=$(echo "$warp_out" | jq '.tag = "warp"')
                    if echo "$warp_out_default" | jq -e '.protocol == "wireguard"' >/dev/null 2>&1; then
                        warp_out_default=$(echo "$warp_out_default" | jq '.domainStrategy = "ForceIPv4"')
                    fi
                    outbounds=$(echo "$outbounds" | jq --argjson out "$warp_out_default" '. + [$out]')
                fi
            fi
        fi

        # 生成负载均衡器
        local balancers="[]"
        local balancer_groups=$(db_get_balancer_groups)
        if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
            while IFS= read -r group_json; do
                local group_name=$(echo "$group_json" | jq -r '.name')
                local strategy=$(echo "$group_json" | jq -r '.strategy')
                
                # 构建 selector 数组 (节点 tag)
                local selectors="[]"
                local balancer_ip_version="prefer_ipv4"
                local tag_suffix=""
                case "$balancer_ip_version" in
                    ipv4_only) tag_suffix="-ipv4" ;;
                    ipv6_only) tag_suffix="-ipv6" ;;
                    prefer_ipv6) tag_suffix="-prefer-ipv6" ;;
                    prefer_ipv4|*) tag_suffix="-prefer-ipv4" ;;
                esac
                while IFS= read -r node_name; do
                    [[ -z "$node_name" ]] && continue
                    local node_tag="chain-${node_name}${tag_suffix}"
                    selectors=$(echo "$selectors" | jq --arg tag "$node_tag" '. + [$tag]')
                    
                    # 确保节点 outbound 存在
                    if ! echo "$outbounds" | jq -e --arg tag "$node_tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                        local chain_out=$(gen_xray_chain_outbound "$node_name" "$node_tag" "$balancer_ip_version")
                        [[ -n "$chain_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                    fi
                done < <(echo "$group_json" | jq -r '.nodes[]?')
                
                # 生成 balancer 配置
                local balancer=$(jq -n \
                    --arg tag "balancer-${group_name}" \
                    --arg strategy "$strategy" \
                    --argjson selector "$selectors" \
                    '{tag: $tag, selector: $selector, strategy: {type: $strategy}}')

                balancers=$(echo "$balancers" | jq --argjson b "$balancer" '. + [$b]')
            done < <(echo "$balancer_groups" | jq -c '.[]')
        fi

        routing_rules=$(gen_xray_routing_rules)
        [[ -n "$routing_rules" && "$routing_rules" != "[]" ]] && has_routing=true
        
        # 添加用户级路由规则 (优先级高于全局规则)
        local user_routing_rules=$(gen_xray_user_routing_rules)
        if [[ -n "$user_routing_rules" && "$user_routing_rules" != "[]" ]]; then
            # 确保用户路由需要的outbounds存在
            local user_routing_needs=$(gen_xray_user_routing_outbounds)
            for need in $user_routing_needs; do
                case "$need" in
                    warp)
                        if ! echo "$outbounds" | jq -e '.[] | select(.tag == "warp-prefer-ipv4")' >/dev/null 2>&1; then
                            local warp_out=$(gen_xray_warp_outbound)
                            if [[ -n "$warp_out" ]]; then
                                local warp_out_v4=$(echo "$warp_out" | jq '.tag = "warp-prefer-ipv4" | .domainStrategy = "ForceIPv4v6"')
                                outbounds=$(echo "$outbounds" | jq --argjson out "$warp_out_v4" '. + [$out]')
                            fi
                        fi
                        ;;
                    chain:*)
                        local node_name="${need#chain:}"
                        local tag="chain-${node_name}-prefer-ipv4"
                        if ! echo "$outbounds" | jq -e --arg tag "$tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local chain_out=$(gen_xray_chain_outbound "$node_name" "$tag" "prefer_ipv4")
                            [[ -n "$chain_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                        fi
                        ;;
                esac
            done
            
            # 用户级规则放在最前面，优先匹配
            if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                routing_rules=$(echo "$user_routing_rules" | jq --argjson global_rules "$routing_rules" '. + $global_rules')
            else
                routing_rules="$user_routing_rules"
            fi
            has_routing=true
        fi
        
        # 添加多IP路由的outbound和routing规则
        local ip_routing_outbounds=$(gen_xray_ip_routing_outbounds)
        if [[ -n "$ip_routing_outbounds" && "$ip_routing_outbounds" != "[]" ]]; then
            outbounds=$(echo "$outbounds" | jq --argjson ip_outs "$ip_routing_outbounds" '. + $ip_outs')
            
            # 添加多IP路由规则
            local ip_routing_rules=$(gen_xray_ip_routing_rules)
            if [[ -n "$ip_routing_rules" && "$ip_routing_rules" != "[]" ]]; then
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    # 多IP路由规则放在最前面，优先匹配
                    routing_rules=$(echo "$ip_routing_rules" | jq --argjson user_rules "$routing_rules" '. + $user_rules')
                else
                    routing_rules="$ip_routing_rules"
                fi
                has_routing=true
            fi
        fi
        
        # 检测是否使用了 WARP，如果是，添加保护性直连规则
        if echo "$outbounds" | jq -e '.[] | select(.tag | startswith("warp"))' >/dev/null 2>&1; then
            local warp_mode=$(db_get_warp_mode)
            
            # 只有 WireGuard 模式需要保护性规则
            if [[ "$warp_mode" == "wgcf" ]]; then
                # 生成保护性规则：WARP 服务器和私有 IP 必须直连
                local warp_protection_rules='[
                    {
                        "type": "field",
                        "domain": ["engage.cloudflareclient.com"],
                        "outboundTag": "direct"
                    },
                    {
                        "type": "field",
                        "ip": [
                            "10.0.0.0/8",
                            "172.16.0.0/12",
                            "192.168.0.0/16",
                            "127.0.0.0/8",
                            "169.254.0.0/16",
                            "224.0.0.0/4",
                            "240.0.0.0/4",
                            "fc00::/7",
                            "fe80::/10"
                        ],
                        "outboundTag": "direct"
                    }
                ]'
                
                # 将保护性规则放在最前面
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    routing_rules=$(echo "$warp_protection_rules" | jq --argjson user_rules "$routing_rules" '. + $user_rules')
                else
                    routing_rules="$warp_protection_rules"
                fi
                has_routing=true
            elif [[ "$warp_mode" == "official" ]]; then
                # SOCKS5 模式：UDP 必须直连（warp-cli SOCKS5 不支持 UDP），私有 IP 直连
                local warp_protection_rules='[
                    {
                        "type": "field",
                        "network": "udp",
                        "outboundTag": "direct"
                    },
                    {
                        "type": "field",
                        "ip": [
                            "10.0.0.0/8",
                            "172.16.0.0/12",
                            "192.168.0.0/16",
                            "127.0.0.0/8"
                        ],
                        "outboundTag": "direct"
                    }
                ]'
                
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    routing_rules=$(echo "$warp_protection_rules" | jq --argjson user_rules "$routing_rules" '. + $user_rules')
                else
                    routing_rules="$warp_protection_rules"
                fi
                has_routing=true
            fi
        fi
    fi
    
    # 构建基础配置
    if [[ "$has_routing" == "true" ]]; then
        # 添加 api outbound
        outbounds=$(echo "$outbounds" | jq '. + [{protocol: "blackhole", tag: "api"}]')
        
        jq -n --argjson outbounds "$outbounds" --argjson balancers "$balancers" '{
            log: {loglevel: "warning", access: "/var/log/xray/access.log", error: "/var/log/xray/error.log"},
            api: {tag: "api", services: ["StatsService"]},
            stats: {},
            policy: {levels: {"0": {statsUserUplink: true, statsUserDownlink: true}}},
            inbounds: [{listen: "127.0.0.1", port: 10085, protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, tag: "api"}],
            outbounds: $outbounds,
            routing: {domainStrategy: "IPIfNonMatch", rules: [], balancers: $balancers}
        }' > "$CFG/config.json"

        # 添加路由规则（API 规则放最前面）
        if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
            local api_rule='{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}'
            local all_rules=$(echo "$routing_rules" | jq --argjson api "$api_rule" '[$api] + .')
            local tmp=$(mktemp)
            jq --argjson rules "$all_rules" '.routing.rules = $rules' "$CFG/config.json" > "$tmp" && mv "$tmp" "$CFG/config.json"
        else
            # 即使没有其他规则，也要添加 API 规则
            local tmp=$(mktemp)
            jq '.routing.rules = [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]' "$CFG/config.json" > "$tmp" && mv "$tmp" "$CFG/config.json"
        fi

        # 检查是否使用了leastPing或leastLoad策略,添加burstObservatory配置
        local needs_observatory=false
        if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
            while IFS= read -r group_json; do
                local strategy=$(echo "$group_json" | jq -r '.strategy')
                if [[ "$strategy" == "leastPing" || "$strategy" == "leastLoad" ]]; then
                    needs_observatory=true
                    break
                fi
            done < <(echo "$balancer_groups" | jq -c '.[]')
        fi

        if [[ "$needs_observatory" == "true" ]]; then
            # 构建subjectSelector: 使用通配符匹配所有链式代理出站
            # 示例: ["chain-Alice-TW-SOCKS5-"] 将匹配所有Alice节点
            local subject_selectors="[]"
            while IFS= read -r group_json; do
                local strategy=$(echo "$group_json" | jq -r '.strategy')
                if [[ "$strategy" == "leastPing" || "$strategy" == "leastLoad" ]]; then
                    # 提取节点名前缀用于通配
                    local first_node=$(echo "$group_json" | jq -r '.nodes[0] // ""')
                    if [[ -n "$first_node" ]]; then
                        # 提取公共前缀 (例如 Alice-TW-SOCKS5-01 -> Alice-TW-SOCKS5)
                        local prefix=$(echo "$first_node" | sed 's/-[0-9][0-9]*$//')
                        local tag_prefix="chain-${prefix}-"
                        # 避免重复添加相同前缀
                        if ! echo "$subject_selectors" | jq -e --arg p "$tag_prefix" '.[] | select(. == $p)' >/dev/null 2>&1; then
                            subject_selectors=$(echo "$subject_selectors" | jq --arg p "$tag_prefix" '. + [$p]')
                        fi
                    fi
                fi
            done < <(echo "$balancer_groups" | jq -c '.[]')

            # 添加burstObservatory配置
            local tmp=$(mktemp)
            jq --argjson selectors "$subject_selectors" '
                .burstObservatory = {
                    subjectSelector: $selectors,
                    pingConfig: {
                        destination: "https://www.gstatic.com/generate_204",
                        interval: "10s",
                        sampling: 2,
                        timeout: "5s"
                    }
                }
            ' "$CFG/config.json" > "$tmp" && mv "$tmp" "$CFG/config.json"
        fi
    else
        # 无全局分流规则时，仍然需要检查用户级路由规则和负载均衡器
        local user_routing_rules=$(gen_xray_user_routing_rules)
        local user_outbounds="[$direct_outbound]"
        local user_balancers="[]"
        
        if [[ -n "$user_routing_rules" && "$user_routing_rules" != "[]" ]]; then
            # 用户有自定义路由，需要生成对应的 outbounds 和 balancers
            
            # 确保用户路由需要的outbounds存在
            local user_routing_needs=$(gen_xray_user_routing_outbounds)
            for need in $user_routing_needs; do
                case "$need" in
                    warp)
                        local warp_out=$(gen_xray_warp_outbound)
                        if [[ -n "$warp_out" ]]; then
                            local warp_out_v4=$(echo "$warp_out" | jq '.tag = "warp-prefer-ipv4" | .domainStrategy = "ForceIPv4v6"')
                            user_outbounds=$(echo "$user_outbounds" | jq --argjson out "$warp_out_v4" '. + [$out]')
                        fi
                        ;;
                    chain:*)
                        local node_name="${need#chain:}"
                        local tag="chain-${node_name}-prefer-ipv4"
                        local chain_out=$(gen_xray_chain_outbound "$node_name" "$tag" "prefer_ipv4")
                        [[ -n "$chain_out" ]] && user_outbounds=$(echo "$user_outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                        ;;
                    balancer:*)
                        # 需要生成 balancer 和对应的链式代理 outbounds
                        local group_name="${need#balancer:}"
                        local balancer_groups=$(db_get_balancer_groups)
                        if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
                            local group_json=$(echo "$balancer_groups" | jq -c --arg name "$group_name" '.[] | select(.name == $name)')
                            if [[ -n "$group_json" ]]; then
                                local strategy=$(echo "$group_json" | jq -r '.strategy')
                                local selectors="[]"
                                while IFS= read -r node_name; do
                                    [[ -z "$node_name" ]] && continue
                                    local node_tag="chain-${node_name}-prefer-ipv4"
                                    selectors=$(echo "$selectors" | jq --arg tag "$node_tag" '. + [$tag]')
                                    # 确保节点 outbound 存在
                                    if ! echo "$user_outbounds" | jq -e --arg tag "$node_tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                                        local chain_out=$(gen_xray_chain_outbound "$node_name" "$node_tag" "prefer_ipv4")
                                        [[ -n "$chain_out" ]] && user_outbounds=$(echo "$user_outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                                    fi
                                done < <(echo "$group_json" | jq -r '.nodes[]?')
                                
                                local balancer=$(jq -n \
                                    --arg tag "balancer-${group_name}" \
                                    --arg strategy "$strategy" \
                                    --argjson selector "$selectors" \
                                    '{tag: $tag, selector: $selector, strategy: {type: $strategy}}')
                                user_balancers=$(echo "$user_balancers" | jq --argjson b "$balancer" '. + [$b]')
                            fi
                        fi
                        ;;
                esac
            done
            
            # 添加 API 规则到用户路由规则前面
            local api_rule='{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}'
            local all_rules=$(echo "$user_routing_rules" | jq --argjson api "$api_rule" '[$api] + .')
            
            # 添加 api outbound
            user_outbounds=$(echo "$user_outbounds" | jq '. + [{protocol: "blackhole", tag: "api"}]')
            
            # 生成包含用户路由的配置
            jq -n --argjson outbounds "$user_outbounds" --argjson balancers "$user_balancers" --argjson rules "$all_rules" '{
                log: {loglevel: "warning", access: "/var/log/xray/access.log", error: "/var/log/xray/error.log"},
                api: {tag: "api", services: ["StatsService"]},
                stats: {},
                policy: {levels: {"0": {statsUserUplink: true, statsUserDownlink: true}}},
                inbounds: [{listen: "127.0.0.1", port: 10085, protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, tag: "api"}],
                outbounds: $outbounds,
                routing: {domainStrategy: "IPIfNonMatch", rules: $rules, balancers: $balancers}
            }' > "$CFG/config.json"
            
            # 添加多IP路由 outbound 支持（routing 规则将在 inbound 添加完成后统一添加）
            local ip_routing_outbounds=$(gen_xray_ip_routing_outbounds)
            if [[ -n "$ip_routing_outbounds" && "$ip_routing_outbounds" != "[]" ]]; then
                local tmp=$(mktemp)
                jq --argjson ip_outs "$ip_routing_outbounds" '.outbounds += $ip_outs' "$CFG/config.json" > "$tmp" && mv "$tmp" "$CFG/config.json"
            fi
        else
            # 无任何用户路由规则时
            # 先检查是否有多IP路由的 outbound 需要添加
            local ip_routing_outbounds=$(gen_xray_ip_routing_outbounds)
            
            if [[ -n "$ip_routing_outbounds" && "$ip_routing_outbounds" != "[]" ]]; then
                # 有多IP路由，生成包含多IP路由 outbound 的配置
                # routing 规则将在 inbound 添加完成后统一添加
                local all_outbounds=$(echo "[$direct_outbound]" | jq --argjson ip_outs "$ip_routing_outbounds" '. + $ip_outs + [{protocol: "blackhole", tag: "api"}]')
                
                jq -n --argjson outbounds "$all_outbounds" '{
                    log: {loglevel: "warning", access: "/var/log/xray/access.log", error: "/var/log/xray/error.log"},
                    api: {tag: "api", services: ["StatsService"]},
                    stats: {},
                    policy: {levels: {"0": {statsUserUplink: true, statsUserDownlink: true}}},
                    inbounds: [{listen: "127.0.0.1", port: 10085, protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, tag: "api"}],
                    outbounds: $outbounds,
                    routing: {domainStrategy: "IPIfNonMatch", rules: [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]}
                }' > "$CFG/config.json"
            else
                # 无任何路由规则，使用简单直连配置（仍需要 API 规则）
                jq -n --argjson direct "$direct_outbound" '{
                    log: {loglevel: "warning", access: "/var/log/xray/access.log", error: "/var/log/xray/error.log"},
                    api: {tag: "api", services: ["StatsService"]},
                    stats: {},
                    policy: {levels: {"0": {statsUserUplink: true, statsUserDownlink: true}}},
                    inbounds: [{listen: "127.0.0.1", port: 10085, protocol: "dokodemo-door", settings: {address: "127.0.0.1"}, tag: "api"}],
                    outbounds: [$direct, {protocol: "blackhole", tag: "api"}],
                    routing: {domainStrategy: "IPIfNonMatch", rules: [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]}
                }' > "$CFG/config.json"
            fi
        fi
    fi
    
    # 为每个 Xray 协议添加 inbound，并统计成功数量
    local success_count=0
    local failed_protocols=""
    local p
    for p in $xray_protocols; do
        # 获取协议配置
        local cfg=$(db_get "xray" "$p")

        # 检查是否为多端口数组
        if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
            # 多端口模式：为每个端口创建临时单端口配置
            local port_count=$(echo "$cfg" | jq 'length')
            local i=0
            local port_success=0

            while [[ $i -lt $port_count ]]; do
                local single_cfg=$(echo "$cfg" | jq ".[$i]")
                local port=$(echo "$single_cfg" | jq -r '.port')

                # 临时存储单端口配置
                local tmp_protocol="${p}_port_${port}"
                db_add "xray" "$tmp_protocol" "$single_cfg"

                # 调用原有函数处理
                if add_xray_inbound_v2 "$tmp_protocol"; then
                    ((port_success++))
                fi

                # 清理临时配置
                db_del "xray" "$tmp_protocol"

                ((i++))
            done

            if [[ $port_success -gt 0 ]]; then
                ((success_count++))
            else
                _warn "协议 $p 配置生成失败，跳过"
                failed_protocols+="$p "
            fi
        else
            # 单端口模式：使用原有逻辑
            if add_xray_inbound_v2 "$p"; then
                ((success_count++))
            else
                _warn "协议 $p 配置生成失败，跳过"
                failed_protocols+="$p "
            fi
        fi
    done
    
    # 检查是否至少有一个 inbound 成功添加
    if [[ $success_count -eq 0 ]]; then
        _err "没有任何协议配置成功生成"
        return 1
    fi
    
    # 验证最终配置文件的 JSON 格式
    if ! jq empty "$CFG/config.json" 2>/dev/null; then
        _err "生成的 Xray 配置文件 JSON 格式错误"
        return 1
    fi
    
    # 检查 inbounds 数组是否为空
    local inbound_count=$(jq '.inbounds | length' "$CFG/config.json" 2>/dev/null)
    if [[ "$inbound_count" == "0" || -z "$inbound_count" ]]; then
        _err "Xray 配置中没有有效的 inbound"
        return 1
    fi
    
    # 多IP路由：在所有 inbound 添加完成后，更新 routing 规则
    # 因为 routing 规则需要知道实际生成的 inbound tag
    if db_ip_routing_enabled; then
        local inbounds_json=$(jq '.inbounds' "$CFG/config.json" 2>/dev/null || echo "[]")
        local ip_routing_rules=$(gen_xray_ip_routing_rules "$inbounds_json")
        
        if [[ -n "$ip_routing_rules" && "$ip_routing_rules" != "[]" ]]; then
            local tmp=$(mktemp)
            # 将多IP路由规则放在 routing.rules 最前面（在 api 规则之后）
            jq --argjson ip_rules "$ip_routing_rules" '
                .routing.rules = (
                    [.routing.rules[0]] + $ip_rules + .routing.rules[1:]
                )
            ' "$CFG/config.json" > "$tmp" && mv "$tmp" "$CFG/config.json"
        fi
    fi
    
    if [[ -n "$failed_protocols" ]]; then
        _warn "以下协议配置失败: $failed_protocols"
    fi
    
    _ok "Xray 配置生成成功 ($success_count 个协议)"
    return 0
}

# 处理单个端口实例的 inbound 生成
# 参数: $1=protocol, $2=config_json
_add_single_xray_inbound() {
    local protocol="$1"
    local cfg="$2"
    
    # 从配置中提取字段
    local port=$(echo "$cfg" | jq -r '.port // empty')
    [[ -z "$port" ]] && return 1
    
    # 调用原有的 inbound 生成逻辑
    # 这里暂时返回成功，后续会补充完整逻辑
    return 0
}

# 使用 jq 动态构建 inbound (重构版 - 只从数据库读取)
add_xray_inbound_v2() {
    local protocol=$1
    
    # 从数据库读取配置
    local cfg=""
    if db_exists "xray" "$protocol"; then
        cfg=$(db_get "xray" "$protocol")
    else
        _err "协议 $protocol 在数据库中不存在 (xray 分类)"
        return 1
    fi
    
    [[ -z "$cfg" ]] && { _err "协议 $protocol 配置为空"; return 1; }
    
    # 提取基础协议名（去掉 _port_xxx 后缀）
    local base_protocol="$protocol"
    if [[ "$protocol" =~ ^(.+)_port_[0-9]+$ ]]; then
        base_protocol="${BASH_REMATCH[1]}"
    fi
    
    # 从配置中提取字段
    local port=$(echo "$cfg" | jq -r '.port // empty')
    local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
    local sni=$(echo "$cfg" | jq -r '.sni // empty')
    local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
    local private_key=$(echo "$cfg" | jq -r '.private_key // empty')
    local path=$(echo "$cfg" | jq -r '.path // empty')
    local password=$(echo "$cfg" | jq -r '.password // empty')
    local username=$(echo "$cfg" | jq -r '.username // empty')
    local method=$(echo "$cfg" | jq -r '.method // empty')
    
    [[ -z "$port" ]] && return 1

    # 生成唯一的 inbound tag（基础协议名 + 端口）
    local inbound_tag="${base_protocol}-${port}"
    
    # 检测主协议和回落配置（仅当主协议端口为 8443 时才启用回落模式）
    local has_master=false
    local master_port=""
    for proto in vless-vision trojan; do
        if db_exists "xray" "$proto"; then
            master_port=$(db_get_field "xray" "$proto" "port" 2>/dev/null)
            if [[ "$master_port" == "8443" ]]; then
                has_master=true
                break
            fi
        fi
    done
    
    # 构建回落数组
    local fallbacks='[{"dest":"127.0.0.1:80","xver":0}]'
    local ws_port="" ws_path="" vmess_port="" vmess_path="" trojan_ws_port="" trojan_ws_path=""
    
    # 检查 vless-ws 回落
    if db_exists "xray" "vless-ws"; then
        ws_port=$(db_get_field "xray" "vless-ws" "port")
        ws_path=$(db_get_field "xray" "vless-ws" "path")
    fi
    
    # 检查 vmess-ws 回落
    if db_exists "xray" "vmess-ws"; then
        vmess_port=$(db_get_field "xray" "vmess-ws" "port")
        vmess_path=$(db_get_field "xray" "vmess-ws" "path")
    fi
    
    # 检查 trojan-ws 回落
    if db_exists "xray" "trojan-ws"; then
        trojan_ws_port=$(db_get_field "xray" "trojan-ws" "port")
        trojan_ws_path=$(db_get_field "xray" "trojan-ws" "path")
    fi
    
    # 使用 jq 构建回落数组
    if [[ -n "$ws_port" && -n "$ws_path" ]]; then
        fallbacks=$(echo "$fallbacks" | jq --arg p "$ws_path" --argjson d "$ws_port" '. += [{"path":$p,"dest":$d,"xver":0}]')
    fi
    if [[ -n "$vmess_port" && -n "$vmess_path" ]]; then
        fallbacks=$(echo "$fallbacks" | jq --arg p "$vmess_path" --argjson d "$vmess_port" '. += [{"path":$p,"dest":$d,"xver":0}]')
    fi
    if [[ -n "$trojan_ws_port" && -n "$trojan_ws_path" ]]; then
        fallbacks=$(echo "$fallbacks" | jq --arg p "$trojan_ws_path" --argjson d "$trojan_ws_port" '. += [{"path":$p,"dest":$d,"xver":0}]')
    fi
    
    local inbound_json=""
    local tmp_inbound=$(mktemp)
    
    # 检测是否使用真实证书 (Reality 需要特殊处理 dest)
    local reality_dest="${sni}:443"
    local cert_domain=""
    [[ -f "$CFG/cert_domain" ]] && cert_domain=$(cat "$CFG/cert_domain")
    
    # 只有 Reality 协议需要处理 dest 回落，其他协议不需要
    if [[ "$base_protocol" == "vless" && -n "$cert_domain" && "$sni" == "$cert_domain" ]] && _is_real_cert; then
        # 真实证书模式，dest 必须指向本地 Nginx HTTPS (固定 8443)
        reality_dest="127.0.0.1:8443"
        
        # 确保 Nginx HTTPS 监听存在 (真实域名模式)
        _ensure_nginx_https_for_reality "$cert_domain"
    fi
    
    case "$base_protocol" in
        vless)
            # VLESS+Reality - 使用 jq 安全构建 (支持 WS 回落)
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            local clients=$(gen_xray_vless_clients "$base_protocol" "xtls-rprx-vision" "$port")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"id\":\"$uuid\",\"email\":\"default@${base_protocol}\",\"flow\":\"xtls-rprx-vision\"}]"
            
            jq -n \
                --argjson port "$port" \
                --argjson clients "$clients" \
                --arg sni "$sni" \
                --arg private_key "$private_key" \
                --arg short_id "$short_id" \
                --arg dest "$reality_dest" \
                --arg listen_addr "$listen_addr" \
                --arg tag "$inbound_tag" \
                --argjson fallbacks "$fallbacks" \
            '{
                port: $port,
                listen: $listen_addr,
                protocol: "vless",
                settings: {
                    clients: $clients,
                    decryption: "none",
                    fallbacks: $fallbacks
                },
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {
                        show: false,
                        dest: $dest,
                        xver: 0,
                        serverNames: [$sni],
                        privateKey: $private_key,
                        shortIds: [$short_id]
                    }
                },
                sniffing: {enabled: true, destOverride: ["http","tls"]},
                tag: $tag
            }' > "$tmp_inbound"
            ;;
        vless-vision)
            # VLESS-Vision - 使用 jq 安全构建
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            local clients=$(gen_xray_vless_clients "$base_protocol" "xtls-rprx-vision" "$port")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"id\":\"$uuid\",\"email\":\"default@${base_protocol}\",\"flow\":\"xtls-rprx-vision\"}]"
            
            jq -n \
                --argjson port "$port" \
                --argjson clients "$clients" \
                --arg cert "$CFG/certs/server.crt" \
                --arg key "$CFG/certs/server.key" \
                --arg tag "$inbound_tag" \
                --argjson fallbacks "$fallbacks" \
                --arg listen_addr "$listen_addr" \
            '{
                port: $port,
                listen: $listen_addr,
                protocol: "vless",
                settings: {
                    clients: $clients,
                    decryption: "none",
                    fallbacks: $fallbacks
                },
                streamSettings: {
                    network: "tcp",
                    security: "tls",
                    tlsSettings: {
                        rejectUnknownSni: false,
                        minVersion: "1.2",
                        alpn: ["h2","http/1.1"],
                        certificates: [{certificateFile: $cert, keyFile: $key}]
                    }
                },
                tag: $tag
            }' > "$tmp_inbound"
            ;;
        vless-ws)
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            # vless-ws 不需要 flow
            local clients=$(gen_xray_vless_clients "$base_protocol" "" "$port")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"id\":\"$uuid\",\"email\":\"default@${base_protocol}\"}]"
            
            if [[ "$has_master" == "true" ]]; then
                # 回落模式：监听本地
                jq -n \
                    --argjson port "$port" \
                    --argjson clients "$clients" \
                    --arg path "$path" \
                    --arg sni "$sni" \
                    --arg tag "$inbound_tag" \
                '{
                    port: $port,
                    listen: "127.0.0.1",
                    protocol: "vless",
                    settings: {clients: $clients, decryption: "none"},
                    streamSettings: {
                        network: "ws",
                        security: "none",
                        wsSettings: {path: $path, headers: {Host: $sni}}
                    },
                    sniffing: {enabled: true, destOverride: ["http","tls"]},
                    tag: $tag
                }' > "$tmp_inbound"
            else
                # 独立模式：监听公网
                jq -n \
                    --argjson port "$port" \
                    --argjson clients "$clients" \
                    --arg path "$path" \
                    --arg sni "$sni" \
                    --arg cert "$CFG/certs/server.crt" \
                    --arg key "$CFG/certs/server.key" \
                    --arg listen_addr "$listen_addr" \
                    --arg tag "$inbound_tag" \
                '{
                    port: $port,
                    listen: $listen_addr,
                    protocol: "vless",
                    settings: {
                        clients: $clients,
                        decryption: "none",
                        fallbacks: [{"dest":"127.0.0.1:80","xver":0}]
                    },
                    streamSettings: {
                        network: "ws",
                        security: "tls",
                        tlsSettings: {
                            alpn: ["http/1.1"],
                            certificates: [{certificateFile: $cert, keyFile: $key}]
                        },
                        wsSettings: {path: $path}
                    },
                    sniffing: {enabled: true, destOverride: ["http","tls"]},
                    tag: $tag
                }' > "$tmp_inbound"
            fi
            ;;
        vless-ws-notls)
            # VLESS-WS 无 TLS - 专为 CF Tunnel 设计
            local clients=$(gen_xray_vless_clients "$base_protocol" "" "$port")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"id\":\"$uuid\",\"email\":\"default@${base_protocol}\"}]"
            
            # 从数据库获取 host 配置
            local host=$(db_get_field "xray" "$base_protocol" "host")
            [[ -z "$host" ]] && host=""
            
            jq -n \
                --argjson port "$port" \
                --argjson clients "$clients" \
                --arg path "$path" \
                --arg host "$host" \
                --arg listen_addr "$listen_addr" \
                --arg tag "$inbound_tag" \
            '{
                port: $port,
                listen: $listen_addr,
                protocol: "vless",
                settings: {clients: $clients, decryption: "none"},
                streamSettings: {
                    network: "ws",
                    security: "none",
                    wsSettings: {path: $path, headers: (if $host != "" then {Host: $host} else {} end)}
                },
                sniffing: {enabled: true, destOverride: ["http","tls"]},
                tag: $tag
            }' > "$tmp_inbound"
            ;;
        vless-xhttp)
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            local clients=$(gen_xray_vless_clients "$base_protocol" "" "$port")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"id\":\"$uuid\",\"email\":\"default@${base_protocol}\"}]"
            
            jq -n \
                --argjson port "$port" \
                --argjson clients "$clients" \
                --arg path "$path" \
                --arg sni "$sni" \
                --arg private_key "$private_key" \
                --arg short_id "$short_id" \
                --arg dest "$reality_dest" \
                --arg listen_addr "$listen_addr" \
                --arg tag "$inbound_tag" \
            '{
                port: $port,
                listen: $listen_addr,
                protocol: "vless",
                settings: {clients: $clients, decryption: "none"},
                streamSettings: {
                    network: "xhttp",
                    xhttpSettings: {path: $path, mode: "auto", host: $sni},
                    security: "reality",
                    realitySettings: {
                        show: false,
                        dest: $dest,
                        xver: 0,
                        serverNames: [$sni],
                        privateKey: $private_key,
                        shortIds: [$short_id]
                    }
                },
                sniffing: {enabled: true, destOverride: ["http","tls"]},
                tag: $tag
            }' > "$tmp_inbound"
            ;;
        vless-xhttp-cdn)
            # VLESS+XHTTP+TLS+CDN 模式 - Nginx 反代 h2c，无 Reality
            local domain=$(echo "$cfg" | jq -r '.domain // empty')
            local internal_port=$(echo "$cfg" | jq -r '.internal_port // .port')
            
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            local clients=$(gen_xray_vless_clients "$base_protocol" "" "$port")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"id\":\"$uuid\",\"email\":\"default@${base_protocol}\"}]"
            
            jq -n \
                --argjson port "$internal_port" \
                --argjson clients "$clients" \
                --arg path "$path" \
                --arg domain "$domain" \
                --arg tag "$inbound_tag" \
            '{
                port: $port,
                listen: "127.0.0.1",
                protocol: "vless",
                settings: {clients: $clients, decryption: "none"},
                streamSettings: {
                    network: "xhttp",
                    xhttpSettings: {path: $path, mode: "auto", host: $domain}
                },
                sniffing: {enabled: true, destOverride: ["http","tls"]},
                tag: $tag
            }' > "$tmp_inbound"
            ;;
        vmess-ws)
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            local clients=$(gen_xray_vmess_clients "$base_protocol")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"id\":\"$uuid\",\"email\":\"default@${base_protocol}\",\"alterId\":0}]"
            
            if [[ "$has_master" == "true" ]]; then
                jq -n \
                    --argjson port "$port" \
                    --argjson clients "$clients" \
                    --arg path "$path" \
                    --arg sni "$sni" \
                    --arg tag "$inbound_tag" \
                '{
                    port: $port,
                    listen: "127.0.0.1",
                    protocol: "vmess",
                    settings: {clients: $clients},
                    streamSettings: {
                        network: "ws",
                        security: "none",
                        wsSettings: {path: $path, headers: {Host: $sni}}
                    },
                    tag: $tag
                }' > "$tmp_inbound"
            else
                jq -n \
                    --argjson port "$port" \
                    --argjson clients "$clients" \
                    --arg path "$path" \
                    --arg sni "$sni" \
                    --arg cert "$CFG/certs/server.crt" \
                    --arg key "$CFG/certs/server.key" \
                    --arg listen_addr "$listen_addr" \
                    --arg tag "$inbound_tag" \
                '{
                    port: $port,
                    listen: $listen_addr,
                    protocol: "vmess",
                    settings: {clients: $clients},
                    streamSettings: {
                        network: "ws",
                        security: "tls",
                        tlsSettings: {
                            certificates: [{certificateFile: $cert, keyFile: $key}],
                            alpn: ["http/1.1"]
                        },
                        wsSettings: {path: $path, headers: {Host: $sni}}
                    },
                    tag: $tag
                }' > "$tmp_inbound"
            fi
            ;;
        trojan)
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            local clients=$(gen_xray_trojan_clients "$base_protocol")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"password\":\"$password\",\"email\":\"default@${base_protocol}\"}]"
            
            jq -n \
                --argjson port "$port" \
                --argjson clients "$clients" \
                --arg cert "$CFG/certs/server.crt" \
                --arg key "$CFG/certs/server.key" \
                --argjson fallbacks "$fallbacks" \
                --arg tag "$inbound_tag" \
                --arg listen_addr "$listen_addr" \
            '{
                port: $port,
                listen: $listen_addr,
                protocol: "trojan",
                settings: {
                    clients: $clients,
                    fallbacks: $fallbacks
                },
                streamSettings: {
                    network: "tcp",
                    security: "tls",
                    tlsSettings: {certificates: [{certificateFile: $cert, keyFile: $key}]}
                },
                tag: $tag
            }' > "$tmp_inbound"
            ;;
        trojan-ws)
            local path=$(echo "$cfg" | jq -r '.path // "/trojan"')
            local sni=$(echo "$cfg" | jq -r '.sni // "bing.com"')
            
            # 获取完整的用户列表（包含子用户和 email，用于流量统计）
            local clients=$(gen_xray_trojan_clients "$base_protocol")
            [[ -z "$clients" || "$clients" == "[]" ]] && clients="[{\"password\":\"$password\",\"email\":\"default@${base_protocol}\"}]"
            
            # Trojan-WS 作为回落协议或独立运行
            if _has_master_protocol; then
                # 作为主协议的回落，监听本地端口
                jq -n \
                    --argjson port "$port" \
                    --argjson clients "$clients" \
                    --arg path "$path" \
                    --arg sni "$sni" \
                    --arg tag "$inbound_tag" \
                '{
                    port: $port,
                    listen: "127.0.0.1",
                    protocol: "trojan",
                    settings: {clients: $clients},
                    streamSettings: {
                        network: "ws",
                        security: "none",
                        wsSettings: {path: $path, headers: {Host: $sni}}
                    },
                    tag: $tag
                }' > "$tmp_inbound"
            else
                # 独立运行，需要 TLS
                jq -n \
                    --argjson port "$port" \
                    --argjson clients "$clients" \
                    --arg cert "$CFG/certs/server.crt" \
                    --arg key "$CFG/certs/server.key" \
                    --arg path "$path" \
                    --arg sni "$sni" \
                    --arg tag "$inbound_tag" \
                    --arg listen_addr "$listen_addr" \
                '{
                    port: $port,
                    listen: $listen_addr,
                    protocol: "trojan",
                    settings: {clients: $clients},
                    streamSettings: {
                        network: "ws",
                        security: "tls",
                        tlsSettings: {
                            alpn: ["http/1.1"],
                            certificates: [{certificateFile: $cert, keyFile: $key}]
                        },
                        wsSettings: {path: $path, headers: {Host: $sni}}
                    },
                    tag: $tag
                }' > "$tmp_inbound"
            fi
            ;;
        socks)
            local use_tls=$(echo "$cfg" | jq -r '.tls // "false"')
            local sni=$(echo "$cfg" | jq -r '.sni // ""')
            local auth_mode=$(echo "$cfg" | jq -r '.auth_mode // "password"')
            local config_listen_addr=$(echo "$cfg" | jq -r '.listen_addr // empty')
            local socks_listen_addr="${listen_addr:-}"
            [[ -z "$socks_listen_addr" ]] && socks_listen_addr=$(_listen_addr)
            [[ -n "$config_listen_addr" ]] && socks_listen_addr="$config_listen_addr"
            
            if [[ "$use_tls" == "true" ]]; then
                # SOCKS5 + TLS
                jq -n \
                    --argjson port "$port" \
                    --arg username "$username" \
                    --arg password "$password" \
                    --arg cert "$CFG/certs/server.crt" \
                    --arg key "$CFG/certs/server.key" \
                    --arg tag "$inbound_tag" \
                    --arg listen_addr "$socks_listen_addr" \
                    --arg auth_mode "$auth_mode" \
                '{
                    port: $port,
                    listen: $listen_addr,
                    protocol: "socks",
                    settings: ({
                        auth: $auth_mode,
                        udp: true
                    } + (if $auth_mode == "noauth" then {} else {accounts: [{user: $username, pass: $password}]} end)),
                    streamSettings: {
                        network: "tcp",
                        security: "tls",
                        tlsSettings: {
                            certificates: [{certificateFile: $cert, keyFile: $key}]
                        }
                    },
                    tag: $tag
                }' > "$tmp_inbound"
            else
                # SOCKS5 无 TLS
                jq -n \
                    --argjson port "$port" \
                    --arg username "$username" \
                    --arg password "$password" \
                    --arg tag "$inbound_tag" \
                    --arg listen_addr "$socks_listen_addr" \
                    --arg auth_mode "$auth_mode" \
                '{
                    port: $port,
                    listen: $listen_addr,
                    protocol: "socks",
                    settings: ({
                        auth: $auth_mode,
                        udp: true
                    } + (if $auth_mode == "noauth" then {} else {accounts: [{user: $username, pass: $password}]} end)),
                    tag: $tag
                }' > "$tmp_inbound"
            fi
            ;;
        ss2022|ss-legacy)
            jq -n \
                --argjson port "$port" \
                --arg method "$method" \
                --arg password "$password" \
                --arg tag "$inbound_tag" \
                --arg listen_addr "$listen_addr" \
            '{
                port: $port,
                listen: $listen_addr,
                protocol: "shadowsocks",
                settings: {
                    method: $method,
                    password: $password,
                    network: "tcp,udp"
                },
                tag: $tag
            }' > "$tmp_inbound"
            ;;
        *)
            rm -f "$tmp_inbound"
            return 1
            ;;
    esac
    
    # 验证生成的 inbound JSON
    if ! jq empty "$tmp_inbound" 2>/dev/null; then
        _err "生成的 $protocol inbound JSON 格式错误"
        rm -f "$tmp_inbound"
        return 1
    fi
    
    # 合并到主配置
    local tmp_config=$(mktemp)
    if jq '.inbounds += [input]' "$CFG/config.json" "$tmp_inbound" > "$tmp_config" 2>/dev/null; then
        mv "$tmp_config" "$CFG/config.json"
    else
        _err "合并 $protocol 配置失败"
        rm -f "$tmp_inbound" "$tmp_config"
        return 1
    fi
    
    # 多IP路由支持：为每个配置的入站IP创建独立的 inbound 副本
    # 这样 routing 规则可以通过 inboundTag 匹配到正确的出站
    if db_ip_routing_enabled; then
        local ip_rules=$(db_get_ip_routing_rules)
        if [[ -n "$ip_rules" && "$ip_rules" != "[]" ]]; then
            while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                local inbound_ip=$(echo "$rule" | jq -r '.inbound_ip')
                [[ -z "$inbound_ip" ]] && continue
                
                # 为该入站IP创建专用的 inbound 副本
                # tag 需要包含端口号，避免多协议时 tag 冲突
                local ip_tag="ip-in-${inbound_ip//[.:]/-}-${port}"
                local ip_inbound_file=$(mktemp)
                
                # 复制原始 inbound，修改 listen 和 tag
                jq --arg listen "$inbound_ip" --arg tag "$ip_tag" \
                    '.listen = $listen | .tag = $tag' "$tmp_inbound" > "$ip_inbound_file"
                
                if jq empty "$ip_inbound_file" 2>/dev/null; then
                    local tmp2=$(mktemp)
                    if jq '.inbounds += [input]' "$CFG/config.json" "$ip_inbound_file" > "$tmp2" 2>/dev/null; then
                        mv "$tmp2" "$CFG/config.json"
                    fi
                    rm -f "$tmp2"
                fi
                rm -f "$ip_inbound_file"
            done < <(echo "$ip_rules" | jq -c '.[]')
        fi
    fi
    
    rm -f "$tmp_inbound"
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 基础工具函数
#═══════════════════════════════════════════════════════════════════════════════
_line()  { echo -e "${D}─────────────────────────────────────────────${NC}" >&2; }
_dline() { echo -e "${C}═════════════════════════════════════════════${NC}" >&2; }
_info()  { echo -e "  ${C}▸${NC} $1" >&2; }
_ok()    { echo -e "  ${G}✓${NC} $1" >&2; _log "OK" "$1"; }
_err()   { echo -e "  ${R}✗${NC} $1" >&2; _log "ERROR" "$1"; }
_warn()  { echo -e "  ${Y}!${NC} $1" >&2; _log "WARN" "$1"; }
_item()  { echo -e "  ${G}$1${NC}) $2" >&2; }
_pause() { echo "" >&2; read -rp "  按回车继续..."; }

# URL 解码函数 (处理 %XX 编码的中文等字符)
urldecode() {
    local encoded="$1"
    # 使用 printf 解码 %XX 格式
    printf '%b' "${encoded//%/\\x}"
}

# 解析 URL 查询参数 (key=value&...)
_get_query_param() {
    local params="$1"
    local key="$2"
    local value=""
    local IFS='&'
    local pair=""

    for pair in $params; do
        if [[ "$pair" == "$key="* ]]; then
            value="${pair#*=}"
            break
        fi
    done

    echo "$value"
}

_header() {
    clear; echo "" >&2
    _dline
    echo -e "      ${W}多协议代理${NC} ${D}一键部署${NC} ${C}v${VERSION}${NC} ${Y}[服务端]${NC}" >&2
    echo -e "      ${D}作者: ${AUTHOR}  快捷命令: vless${NC}" >&2
    echo -e "      ${D}${REPO_URL}${NC}" >&2
    _dline
}

get_protocol() {
    # 多协议模式下返回主协议或第一个协议
    local installed=$(get_installed_protocols)
    if [[ -n "$installed" ]]; then
        # 优先返回 Xray 主协议
        for proto in vless vless-vision vless-ws vless-xhttp trojan socks ss2022; do
            if echo "$installed" | grep -q "^$proto$"; then
                echo "$proto"
                return
            fi
        done
        # 返回第一个已安装的协议
        echo "$installed" | head -1
    elif [[ -f "$CFG/protocol" ]]; then
        cat "$CFG/protocol"
    else
        echo "vless"
    fi
}



check_root()      { [[ $EUID -ne 0 ]] && { _err "请使用 root 权限运行"; exit 1; }; }
check_cmd()       { command -v "$1" &>/dev/null; }
check_installed() { [[ -d "$CFG" && ( -f "$CFG/config.json" || -f "$CFG/db.json" ) ]]; }
get_role()        { [[ -f "$CFG/role" ]] && cat "$CFG/role" || echo ""; }
is_paused()       { [[ -f "$CFG/paused" ]]; }

# 配置 DNS64 (纯 IPv6 环境)
configure_dns64() {
    # 检测 IPv4 网络是否可用
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        return 0  # IPv4 正常，无需配置
    fi
    
    _warn "检测到纯 IPv6 环境，准备配置 DNS64..."
    
    # 备份原有配置
    if [[ -f /etc/resolv.conf ]] && [[ ! -f /etc/resolv.conf.bak ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak
    fi
    
    # 写入 DNS64 服务器
    cat > /etc/resolv.conf << 'EOF'
nameserver 2a00:1098:2b::1
nameserver 2001:4860:4860::6464
nameserver 2a00:1098:2c::1
EOF
    
    _ok "DNS64 配置完成 (Kasper Sky + Google DNS64 + Trex)"
}

# 检查 CA 证书是否存在
_has_ca_bundle() {
    local ca_file=""
    for ca_file in "/etc/ssl/certs/ca-certificates.crt" "/etc/ssl/cert.pem" "/etc/pki/tls/certs/ca-bundle.crt"; do
        [[ -s "$ca_file" ]] && return 0
    done
    return 1
}

# 检测并安装基础依赖
check_dependencies() {
    # 先配置 DNS64 (如果是纯 IPv6 环境)
    configure_dns64
    
    local missing_deps=()
    local need_install=false
    
    # 必需的基础命令
    local required_cmds="curl jq openssl qrencode"
    
    for cmd in $required_cmds; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
            need_install=true
        fi
    done

    # 检查 crontab (流量统计和过期检查需要)
    if ! command -v crontab &>/dev/null; then
        missing_deps+=("cron")
        need_install=true
    fi

    if ! _has_ca_bundle; then
        missing_deps+=("ca-certificates")
        need_install=true
    fi
    
    if [[ "$need_install" == "true" ]]; then
        _info "安装缺失的依赖: ${missing_deps[*]}..."
        
        case "$DISTRO" in
            alpine)
                apk update >/dev/null 2>&1
                apk add --no-cache curl jq openssl coreutils ca-certificates gawk libqrencode-tools cronie >/dev/null 2>&1
                # 启动 crond 服务
                rc-service crond start >/dev/null 2>&1
                rc-update add crond default >/dev/null 2>&1
                ;;
            centos)
                yum install -y curl jq openssl ca-certificates qrencode cronie >/dev/null 2>&1
                # 启动 crond 服务
                systemctl enable crond >/dev/null 2>&1
                systemctl start crond >/dev/null 2>&1
                ;;
            debian|ubuntu)
                apt-get update >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq openssl ca-certificates qrencode cron >/dev/null 2>&1
                # Debian/Ubuntu 的 cron 通常自动启动,但确保服务运行
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl enable cron >/dev/null 2>&1
                    systemctl start cron >/dev/null 2>&1
                fi
                ;;
        esac
        
        # 再次检查
        for cmd in $required_cmds; do
            if ! command -v "$cmd" &>/dev/null; then
                _err "依赖安装失败: $cmd"
                _warn "请手动安装: $cmd"
                return 1
            fi
        done
        if ! command -v crontab &>/dev/null; then
            _err "依赖安装失败: crontab"
            _warn "请手动安装 cron 服务"
            return 1
        fi
        if ! _has_ca_bundle; then
            _err "依赖安装失败: ca-certificates"
            _warn "请手动安装: ca-certificates"
            return 1
        fi
        _ok "依赖安装完成"
    fi
    return 0
}

# 核心更新依赖检查（避免版本获取失败）
_check_core_update_deps() {
    local missing=()
    local cmd
    for cmd in curl jq; do
        if ! check_cmd "$cmd"; then
            missing+=("$cmd")
        fi
    done
    if ! _has_ca_bundle; then
        missing+=("ca-certificates")
    fi
    if [[ ${#missing[@]} -ne 0 ]]; then
        _err "缺少依赖: ${missing[*]}"
        _warn "请先安装缺失依赖或手动补齐后重试"
        return 1
    fi
    return 0
}

# 确保系统支持双栈监听（IPv4 + IPv6）
ensure_dual_stack_listen() {
    # 仅在 Linux 系统上执行
    [[ ! -f /proc/sys/net/ipv6/bindv6only ]] && return 0

    local current=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo "1")

    # 如果已经是双栈（0），直接返回
    [[ "$current" == "0" ]] && return 0

    # bindv6only=1 表示 IPv6 socket 只监听 IPv6，需要改成 0 才能双栈
    _warn "检测到系统 IPv6 socket 为 v6-only 模式，这会导致 IPv4 客户端无法连接"
    _info "正在配置双栈监听支持..."

    # 临时生效
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1

    # 持久化配置
    local sysctl_conf="/etc/sysctl.d/99-vless-dualstack.conf"
    echo "net.ipv6.bindv6only=0" > "$sysctl_conf"

    # 重新加载
    sysctl -p "$sysctl_conf" >/dev/null 2>&1

    # 验证
    local new_value=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo "1")
    if [[ "$new_value" == "0" ]]; then
        _ok "双栈监听已启用（IPv4 和 IPv6 可同时连接）"
    else
        _warn "双栈配置未生效，将使用 IPv4 监听以保证可用性"
        _warn "如需双栈，请手动执行: sysctl -w net.ipv6.bindv6only=0"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 核心功能：强力清理 & 时间同步
#═══════════════════════════════════════════════════════════════════════════════
force_cleanup() {
    # 停止所有 vless 相关服务
    local services="watchdog reality hy2 tuic snell snell-v5 anytls singbox"
    services+=" snell-shadowtls snell-v5-shadowtls ss2022-shadowtls"
    services+=" snell-shadowtls-backend snell-v5-shadowtls-backend ss2022-shadowtls-backend"
    for s in $services; do svc stop "vless-$s" 2>/dev/null; done
    
    killall xray sing-box snell-server snell-server-v5 anytls-server shadow-tls 2>/dev/null
    
    # 清理 iptables NAT 规则
    cleanup_hy2_nat_rules
}

# 清理 Hysteria2/TUIC 端口跳跃 NAT 规则
cleanup_hy2_nat_rules() {
    # 清理 Hysteria2 端口跳跃规则
    if db_exists "singbox" "hy2"; then
        local port=$(db_get_field "singbox" "hy2" "port")
        local hs=$(db_get_field "singbox" "hy2" "hop_start"); hs="${hs:-20000}"
        local he=$(db_get_field "singbox" "hy2" "hop_end"); he="${he:-50000}"
        [[ -n "$port" ]] && {
            iptables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            iptables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
        }
    fi
    # 清理 TUIC 端口跳跃规则
    if db_exists "singbox" "tuic"; then
        local port=$(db_get_field "singbox" "tuic" "port")
        local hs=$(db_get_field "singbox" "tuic" "hop_start"); hs="${hs:-20000}"
        local he=$(db_get_field "singbox" "tuic" "hop_end"); he="${he:-50000}"
        [[ -n "$port" ]] && {
            iptables -t nat -D PREROUTING -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
            iptables -t nat -D OUTPUT -p udp --dport ${hs}:${he} -j REDIRECT --to-ports ${port} 2>/dev/null
        }
    fi
    # 兜底清理
    for chain in PREROUTING OUTPUT; do
        iptables -t nat -S $chain 2>/dev/null | grep -E "REDIRECT.*--to-ports" | while read -r rule; do
            eval "iptables -t nat $(echo "$rule" | sed 's/^-A/-D/')" 2>/dev/null
        done
    done
}

sync_time() {
    _info "同步系统时间..."
    
    # 方法1: 使用HTTP获取时间 (最快最可靠)
    local http_time=$(timeout 5 curl -sI --connect-timeout 3 --max-time 5 http://www.baidu.com 2>/dev/null | grep -i "^date:" | cut -d' ' -f2-)
    if [[ -n "$http_time" ]]; then
        if date -s "$http_time" &>/dev/null; then
            _ok "时间同步完成 (HTTP)"
            return 0
        fi
    fi
    
    # 方法2: 使用ntpdate (如果可用)
    if command -v ntpdate &>/dev/null; then
        if timeout 5 ntpdate -s pool.ntp.org &>/dev/null; then
            _ok "时间同步完成 (NTP)"
            return 0
        fi
    fi
    
    # 方法3: 使用timedatectl (systemd系统)
    if command -v timedatectl &>/dev/null; then
        if timeout 5 timedatectl set-ntp true &>/dev/null; then
            _ok "时间同步完成 (systemd)"
            return 0
        fi
    fi
    
    # 如果所有方法都失败，跳过时间同步
    _warn "时间同步失败，继续安装..."
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 网络工具
#═══════════════════════════════════════════════════════════════════════════════
get_ipv4() {
    [[ -n "$_CACHED_IPV4" ]] && { echo "$_CACHED_IPV4"; return; }
    local result=$(curl -4 -sf --connect-timeout 5 ip.sb 2>/dev/null || curl -4 -sf --connect-timeout 5 ifconfig.me 2>/dev/null)
    [[ -n "$result" ]] && _CACHED_IPV4="$result"
    echo "$result"
}
get_ipv6() {
    [[ -n "$_CACHED_IPV6" ]] && { echo "$_CACHED_IPV6"; return; }
    local result=$(curl -6 -sf --connect-timeout 5 ip.sb 2>/dev/null || curl -6 -sf --connect-timeout 5 ifconfig.me 2>/dev/null)
    [[ -n "$result" ]] && _CACHED_IPV6="$result"
    echo "$result"
}

# 获取 IP 地理位置代码 (如 HK, JP, US, SG)
get_ip_country() {
    local ip="${1:-}"
    local country=""
    
    # 方法1: ip-api.com (免费，无需 key)
    if [[ -n "$ip" ]]; then
        country=$(curl -sf --connect-timeout 3 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null)
    else
        country=$(curl -sf --connect-timeout 3 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null)
    fi
    
    # 方法2: 回退到 ipinfo.io
    if [[ -z "$country" || "$country" == "fail" ]]; then
        if [[ -n "$ip" ]]; then
            country=$(curl -sf --connect-timeout 3 "https://ipinfo.io/${ip}/country" 2>/dev/null)
        else
            country=$(curl -sf --connect-timeout 3 "https://ipinfo.io/country" 2>/dev/null)
        fi
    fi
    
    # 清理结果（去除空白字符）
    country=$(echo "$country" | tr -d '[:space:]')
    
    # 默认返回 XX
    echo "${country:-XX}"
}

# 通过DNS检查域名的IP解析 (兼容性增强)
check_domain_dns() {
    local domain=$1
    local dns_ip=""
    local ip_type=4
    local public_ip=""
    
    # 优先使用 dig
    if command -v dig &>/dev/null; then
        dns_ip=$(dig @1.1.1.1 +time=2 +short "$domain" 2>/dev/null | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$" | head -1)
        
        # 如果Cloudflare DNS失败，尝试Google DNS
        if [[ -z "$dns_ip" ]]; then
            dns_ip=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$" | head -1)
        fi
    fi
    
    # 回退到 nslookup
    if [[ -z "$dns_ip" ]] && command -v nslookup &>/dev/null; then
        dns_ip=$(nslookup "$domain" 1.1.1.1 2>/dev/null | awk '/^Address: / { print $2 }' | grep -v "1.1.1.1" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" | head -1)
    fi
    
    # 回退到 getent
    if [[ -z "$dns_ip" ]] && command -v getent &>/dev/null; then
        dns_ip=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    fi
    
    # 如果IPv4解析失败，尝试IPv6
    if [[ -z "$dns_ip" ]] || echo "$dns_ip" | grep -q "timed out"; then
        _warn "无法通过DNS获取域名 IPv4 地址"
        _info "尝试检查域名 IPv6 地址..."
        
        if command -v dig &>/dev/null; then
            dns_ip=$(dig @2606:4700:4700::1111 +time=2 aaaa +short "$domain" 2>/dev/null | head -1)
        elif command -v getent &>/dev/null; then
            dns_ip=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | head -1)
        fi
        ip_type=6
        
        if [[ -z "$dns_ip" ]] || echo "$dns_ip" | grep -q "network unreachable"; then
            _err "无法通过DNS获取域名IPv6地址"
            return 1
        fi
    fi
    
    # 获取服务器公网IP
    if [[ $ip_type -eq 4 ]]; then
        public_ip=$(get_ipv4)
    else
        public_ip=$(get_ipv6)
    fi
    
    # 比较DNS解析IP与服务器IP
    if [[ "$public_ip" != "$dns_ip" ]]; then
        _err "域名解析IP与当前服务器IP不一致"
        _warn "请检查域名解析是否生效以及正确"
        echo -e "  ${G}当前VPS IP：${NC}$public_ip"
        echo -e "  ${G}DNS解析 IP：${NC}$dns_ip"
        return 1
    else
        _ok "域名IP校验通过"
        return 0
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 端口管理
#═══════════════════════════════════════════════════════════════════════════════

# 检查脚本内部记录的端口占用 (从数据库读取)
# 返回 0 表示被占用，1 表示未被占用
is_internal_port_occupied() {
    local check_port="$1"
    
    # 遍历 Xray 协议
    local xray_protos=$(db_list_protocols "xray")
    for proto in $xray_protos; do
        local used_port=$(db_get_field "xray" "$proto" "port")
        if [[ "$used_port" == "$check_port" ]]; then
            echo "$proto"
            return 0
        fi
    done
    
    # 遍历 Singbox 协议
    local singbox_protos=$(db_list_protocols "singbox")
    for proto in $singbox_protos; do
        local used_port=$(db_get_field "singbox" "$proto" "port")
        if [[ "$used_port" == "$check_port" ]]; then
            echo "$proto"
            return 0
        fi
    done
    
    return 1
}

# 优化后的端口生成函数 - 增加端口冲突检测和最大尝试次数
gen_port() {
    local port
    local max_attempts=100  # 最大尝试次数，防止无限循环
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        port=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50000 + 10000)))
        # 检查端口是否被占用 (TCP 和 UDP)
        if ! ss -tuln 2>/dev/null | grep -q ":$port " && ! netstat -tuln 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
        ((attempt++))
    done
    
    # 达到最大尝试次数，返回一个随机端口并警告
    _warn "无法找到空闲端口（尝试 $max_attempts 次），使用随机端口" >&2
    echo "$port"
    return 1
}

# 智能端口推荐
# 参数: $1=协议类型
recommend_port() {
    local protocol="$1"
    
    # 覆盖模式：优先推荐被覆盖的端口
    if [[ "$INSTALL_MODE" == "replace" && -n "$REPLACE_PORT" ]]; then
        echo "$REPLACE_PORT"
        return 0
    fi
    
    # 检查是否已安装主协议（Vision/Trojan/Reality），用于判断 WS 协议是否为回落子协议
    local has_master=false
    if db_exists "xray" "vless-vision" || db_exists "xray" "vless" || db_exists "xray" "trojan"; then
        has_master=true
    fi
    
    case "$protocol" in
        vless-ws|vmess-ws)
            # 如果已有主协议，这些是回落子协议，监听本地，随机端口即可
            if [[ "$has_master" == "true" ]]; then
                gen_port
            else
                # 独立运行时才需要 HTTPS 端口
                if ! ss -tuln 2>/dev/null | grep -q ":443 " && ! is_internal_port_occupied "443" >/dev/null; then
                    echo "443"
                elif ! ss -tuln 2>/dev/null | grep -q ":8443 " && ! is_internal_port_occupied "8443" >/dev/null; then
                    echo "8443"
                else
                    gen_port
                fi
            fi
            ;;
        vless|vless-xhttp)
            # Reality 协议：伪装特性使其可使用任意端口，默认随机高位端口
            while true; do
                local p=$(gen_port)
                if ! is_internal_port_occupied "$p" >/dev/null; then
                    echo "$p"
                    break
                fi
            done
            ;;
        vless-vision|trojan|anytls|snell-shadowtls|snell-v5-shadowtls|ss2022-shadowtls)
            # 这些协议需要对外暴露，优先使用 HTTPS 端口
            if ! ss -tuln 2>/dev/null | grep -q ":443 " && ! is_internal_port_occupied "443" >/dev/null; then
                echo "443"
            elif ! ss -tuln 2>/dev/null | grep -q ":8443 " && ! is_internal_port_occupied "8443" >/dev/null; then
                echo "8443"
            elif ! ss -tuln 2>/dev/null | grep -q ":2096 " && ! is_internal_port_occupied "2096" >/dev/null; then
                echo "2096"
            else
                gen_port
            fi
            ;;
        hy2|tuic)
            # UDP 协议直接随机
            while true; do
                local p=$(gen_port)
                if ! is_internal_port_occupied "$p" >/dev/null; then
                    echo "$p"
                    break
                fi
            done
            ;;
        *)
            gen_port
            ;;
    esac
}

# 交互式端口选择
ask_port() {
    local protocol="$1"
    local recommend=$(recommend_port "$protocol")
    
    # 检查是否已安装主协议在 8443 端口（仅 8443 端口才触发回落）
    local has_master=false
    local master_port=""
    for proto in vless-vision vless trojan; do
        master_port=$(db_get_port "xray" "$proto" 2>/dev/null)
        if [[ "$master_port" == "8443" ]]; then
            has_master=true
            break
        fi
    done
    
    echo "" >&2
    _line >&2
    echo -e "  ${W}端口配置${NC}" >&2
    
    # 根据协议类型和是否有主协议显示不同的提示
    case "$protocol" in
        vless-ws|vmess-ws)
            if [[ "$has_master" == "true" ]]; then
                # 回落子协议，自动分配内部端口，不询问用户
                echo -e "  ${D}(作为回落子协议，监听本地，外部通过 8443 访问)${NC}" >&2
                echo -e "  ${C}自动分配内部端口: ${G}$recommend${NC}" >&2
                echo "$recommend"
                return 0
            elif [[ "$recommend" == "443" ]]; then
                echo -e "  ${C}建议: ${G}443${NC} (标准 HTTPS 端口)" >&2
            else
                local owner_443=$(is_internal_port_occupied "443")
                if [[ -n "$owner_443" ]]; then
                    echo -e "  ${Y}注意: 443 端口已被 [$owner_443] 协议占用${NC}" >&2
                fi
                if [[ "$INSTALL_MODE" == "replace" ]]; then
                    echo -e "  ${C}建议: ${G}$recommend${NC}" >&2
                else
                    echo -e "  ${C}建议: ${G}$recommend${NC} (已自动避开冲突)" >&2
                fi
            fi
            ;;
        vless|vless-xhttp)
            # Reality 协议默认随机端口
            echo -e "  ${D}(Reality 协议伪装能力强，可使用任意端口)${NC}" >&2
            echo -e "  ${C}建议: ${G}$recommend${NC} (随机高位端口)" >&2
            ;;
        vless-vision|trojan)
            if [[ "$recommend" == "443" ]]; then
                echo -e "  ${C}建议: ${G}443${NC} (标准 HTTPS 端口)" >&2
            else
                local owner_443=$(is_internal_port_occupied "443")
                if [[ -n "$owner_443" ]]; then
                    echo -e "  ${Y}注意: 443 端口已被 [$owner_443] 协议占用${NC}" >&2
                fi
                if [[ "$INSTALL_MODE" == "replace" ]]; then
                    echo -e "  ${C}建议: ${G}$recommend${NC}" >&2
                else
                    echo -e "  ${C}建议: ${G}$recommend${NC} (已自动避开冲突)" >&2
                fi
            fi
            ;;
        *)
            echo -e "  ${C}建议: ${G}$recommend${NC}" >&2
            ;;
    esac
    
    echo "" >&2
    echo -e "  ${D}(输入 0 或 q 返回上级菜单)${NC}" >&2
    
    while true; do
        read -rp "  请输入端口 [回车使用 $recommend]: " custom_port
        
        # 检查退出命令
        if [[ "$custom_port" == "0" || "$custom_port" == "q" || "$custom_port" == "Q" ]]; then
            echo ""  # 返回空字符串表示取消
            return 1  # 返回非0表示取消
        fi
        
        # 如果用户直接回车，使用推荐端口
        if [[ -z "$custom_port" ]]; then
            custom_port="$recommend"
        fi
        
        # 0. 验证端口格式 (必须是1-65535的数字)
        if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || [[ $custom_port -lt 1 ]] || [[ $custom_port -gt 65535 ]]; then
            _err "无效端口: $custom_port" >&2
            _warn "端口必须是 1-65535 之间的数字" >&2
            continue # 跳过本次循环，让用户重输
        fi
        
        # 0.1 检查是否使用了系统保留端口
        if [[ $custom_port -lt 1024 && $custom_port -ne 80 && $custom_port -ne 443 ]]; then
            _warn "端口 $custom_port 是系统保留端口，可能需要特殊权限" >&2
            read -rp "  是否继续使用? [y/N]: " use_reserved
            if [[ ! "$use_reserved" =~ ^[yY]$ ]]; then
                continue
            fi
        fi
        
        # 确定当前协议的核心类型
        local current_core="xray"
        if [[ " $SINGBOX_PROTOCOLS " == *" $protocol "* ]]; then
            current_core="singbox"
        fi
        
        # 检查端口冲突（跨协议检测）
        if ! check_port_conflict "$custom_port" "$protocol" "$current_core"; then
            continue  # 端口冲突，重新输入
        fi
        
        # 检查同协议端口占用
        if [[ "$INSTALL_MODE" == "replace" ]]; then
            # 覆盖模式：只允许使用被覆盖的端口或未占用的端口
            local existing_ports=$(db_list_ports "$current_core" "$protocol" 2>/dev/null)
            if echo "$existing_ports" | grep -q "^${custom_port}$"; then
                # 端口已被该协议使用
                if [[ "$custom_port" != "$REPLACE_PORT" ]]; then
                    # 不是被覆盖的端口，拒绝
                    echo -e "${RED}错误: 协议 $protocol 已在端口 $custom_port 上运行${NC}"
                    echo -e "${YELLOW}提示: 覆盖模式下只能使用被覆盖的端口 $REPLACE_PORT 或其他未占用端口${NC}"
                    continue
                fi
                # 是被覆盖的端口，允许继续
            fi
        else
            # 添加/首次安装模式：不允许使用任何已占用端口
            local existing_ports=$(db_list_ports "$current_core" "$protocol" 2>/dev/null)
            if echo "$existing_ports" | grep -q "^${custom_port}$"; then
                echo -e "${RED}错误: 协议 $protocol 已在端口 $custom_port 上运行${NC}"
                echo -e "${YELLOW}提示: 请选择其他端口或返回主菜单选择覆盖模式${NC}"
                continue
            fi
        fi
        
        # 2. 检查系统端口占用 (Nginx 等外部程序)
        # 使用正则匹配：端口号后跟非数字字符（空格、tab、冒号等）
        if ss -tuln 2>/dev/null | grep -Eq ":${custom_port}[^0-9]" || netstat -tuln 2>/dev/null | grep -Eq ":${custom_port}[^0-9]"; then
            # 覆盖模式：如果是被覆盖的端口，允许使用（服务正在运行是正常的）
            if [[ "$INSTALL_MODE" == "replace" && "$custom_port" == "$REPLACE_PORT" ]]; then
                echo "$custom_port"
                return
            fi
            
            # 其他情况：提示端口被占用
            _warn "端口 $custom_port 系统占用中" >&2
            read -rp "  是否强制使用? (可能导致启动失败) [y/N]: " force
            if [[ "$force" =~ ^[yY]$ ]]; then
                echo "$custom_port"
                return
            else
                continue
            fi
        else
            # 端口干净，通过
            echo "$custom_port"
            return
        fi
    done
}

# 处理协议已安装时的多端口选择
# 参数: $1=protocol, $2=core(xray/singbox)
# 返回: 0=继续安装, 1=取消
handle_existing_protocol() {
    local protocol="$1" core="$2"
    
    # 获取已有端口列表
    local ports=$(db_list_ports "$core" "$protocol")
    
    if [[ -z "$ports" ]]; then
        return 0  # 没有已安装实例，继续
    fi
    
    echo ""
    echo -e "${CYAN}检测到协议 ${YELLOW}$protocol${CYAN} 已安装以下端口实例：${NC}"
    echo "$ports" | while read -r port; do
        echo -e "    ${G}●${NC} 端口 ${G}$port${NC}"
    done
    echo ""
    
    echo -e "${YELLOW}请选择操作：${NC}"
    echo -e "  ${G}1${NC}) 添加新端口实例"
    echo -e "  ${G}2${NC}) 覆盖现有端口"
    echo "  0) 返回"
    echo ""
    
    local choice
    read -p "$(echo -e "  ${GREEN}请输入选项 [0-2]:${NC} ")" choice
    
    case "$choice" in
        1)
            INSTALL_MODE="add"
            return 0
            ;;
        2)
            INSTALL_MODE="replace"
            # 选择要覆盖的端口
            echo ""
            echo -e "${YELLOW}请选择要覆盖的端口：${NC}"
            local port_array=($ports)
            local i=1
            for port in "${port_array[@]}"; do
                echo -e "  ${G}$i${NC}) 端口 ${G}$port${NC}"
                ((i++))
            done
            echo "  0) 返回"
            echo ""
            
            local port_choice
            read -p "$(echo -e "  ${GREEN}请输入选项 [0-$((i-1))]:${NC} ")" port_choice
            
            if [[ "$port_choice" == "0" ]]; then
                echo -e "${YELLOW}已取消，返回上级菜单${NC}"
                return 1
            elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le "$((i-1))" ]; then
                REPLACE_PORT="${port_array[$((port_choice-1))]}"
                return 0
            else
                echo -e "${RED}无效选项${NC}"
                return 1
            fi
            ;;
        0)
            echo -e "${YELLOW}已取消，返回上级菜单${NC}"
            return 1
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            return 1
            ;;
    esac
}

# 检查端口是否被其他协议占用
# 参数: $1=port, $2=current_protocol, $3=current_core
# 返回: 0=未占用, 1=已占用
check_port_conflict() {
    local check_port="$1" current_protocol="$2" current_core="$3"
    
    # 检查 xray 协议
    for proto in $(db_list_protocols "xray"); do
        [[ "$proto" == "$current_protocol" && "$current_core" == "xray" ]] && continue
        
        local ports=$(db_list_ports "xray" "$proto")
        if echo "$ports" | grep -q "^${check_port}$"; then
            echo -e "${RED}错误: 端口 $check_port 已被协议 $proto 占用${NC}"
            return 1
        fi
    done
    
    # 检查 singbox 协议
    for proto in $(db_list_protocols "singbox"); do
        [[ "$proto" == "$current_protocol" && "$current_core" == "singbox" ]] && continue
        
        local ports=$(db_list_ports "singbox" "$proto")
        if echo "$ports" | grep -q "^${check_port}$"; then
            echo -e "${RED}错误: 端口 $check_port 已被协议 $proto 占用${NC}"
            return 1
        fi
    done
    
    return 0
}

#═══════════════════════════════════════════════════════════════════════════════
# 密钥与凭证生成
#═══════════════════════════════════════════════════════════════════════════════

# 生成 ShortID (兼容无 xxd 的系统)
gen_sid() {
    if command -v xxd &>/dev/null; then
        head -c 4 /dev/urandom 2>/dev/null | xxd -p
    elif command -v od &>/dev/null; then
        head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
    else
        printf '%08x' $RANDOM
    fi
}

# 证书诊断函数
diagnose_certificate() {
    local domain="$1"
    
    echo ""
    _info "证书诊断报告："
    
    # 检查证书文件
    if [[ -f "$CFG/certs/server.crt" && -f "$CFG/certs/server.key" ]]; then
        _ok "证书文件存在"
        
        # 检查证书有效期
        local expiry=$(openssl x509 -in "$CFG/certs/server.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -n "$expiry" ]]; then
            _ok "证书有效期: $expiry"
        fi
    else
        _err "证书文件不存在"
    fi
    
    # 检查端口监听 (从数据库读取)
    local port=$(db_get_field "xray" "vless-ws" "port")
    if [[ -n "$port" ]]; then
        if ss -tlnp | grep -q ":$port "; then
            _ok "端口 $port 正在监听"
        else
            _err "端口 $port 未监听"
        fi
    fi
    
    # DNS解析检查
    local resolved_ip=$(dig +short "$domain" 2>/dev/null | head -1)
    local server_ip=$(get_ipv4)
    if [[ "$resolved_ip" == "$server_ip" ]]; then
        _ok "DNS解析正确: $domain -> $resolved_ip"
    else
        _warn "DNS解析问题: $domain -> $resolved_ip (期望: $server_ip)"
    fi
    
    echo ""
}

# 创建伪装网页
create_fake_website() {
    local domain="$1"
    local protocol="$2"
    local custom_nginx_port="$3"  # 新增：自定义 Nginx 端口
    local web_dir="/var/www/html"
    
    # 根据系统确定 nginx 配置目录
    local nginx_conf_dir=""
    local nginx_conf_file=""
    if [[ -d "/etc/nginx/sites-available" ]]; then
        nginx_conf_dir="/etc/nginx/sites-available"
        nginx_conf_file="$nginx_conf_dir/vless-fake"
    elif [[ -d "/etc/nginx/http.d" ]]; then
        # Alpine: 必须使用 http.d 目录，conf.d 不在 http{} 块内
        nginx_conf_dir="/etc/nginx/http.d"
        nginx_conf_file="$nginx_conf_dir/vless-fake.conf"
    elif [[ -d "/etc/nginx/conf.d" ]]; then
        nginx_conf_dir="/etc/nginx/conf.d"
        nginx_conf_file="$nginx_conf_dir/vless-fake.conf"
    else
        nginx_conf_dir="/etc/nginx/conf.d"
        nginx_conf_file="$nginx_conf_dir/vless-fake.conf"
        mkdir -p "$nginx_conf_dir"
    fi
    
    # 删除旧配置，确保使用最新配置
    rm -f "$nginx_conf_file" /etc/nginx/sites-enabled/vless-fake 2>/dev/null
    # 同时删除可能冲突的 vless-sub.conf (包括 http.d 目录)
    rm -f /etc/nginx/conf.d/vless-sub.conf /etc/nginx/http.d/vless-sub.conf 2>/dev/null
    
    # 创建网页目录
    mkdir -p "$web_dir"
    
    # 创建简单的伪装网页
    cat > "$web_dir/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        p { color: #666; line-height: 1.6; }
        .footer { text-align: center; margin-top: 40px; color: #999; font-size: 14px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to Our Website</h1>
        <p>This is a simple website hosted on our server. We provide various web services and solutions for our clients.</p>
        <p>Our team is dedicated to delivering high-quality web hosting and development services. Feel free to contact us for more information about our services.</p>
        <div class="footer">
            <p>&copy; 2024 Web Services. All rights reserved.</p>
        </div>
    </div>
</body>
</html>
EOF
    
    # 检查是否有SSL证书，决定使用Nginx
    if [[ -n "$domain" ]] && [[ -f "/etc/vless-reality/certs/server.crt" ]]; then
        # 安装Nginx（如果未安装）
        if ! command -v nginx >/dev/null 2>&1; then
            _info "安装Nginx..."
            case "$DISTRO" in
                alpine) apk add --no-cache nginx >/dev/null 2>&1 ;;
                centos) yum install -y nginx >/dev/null 2>&1 ;;
                debian|ubuntu) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1 ;;
            esac
        fi
        
        # 启用Nginx服务
        svc enable nginx 2>/dev/null
        
        # 根据协议选择Nginx监听端口和模式
        local nginx_port="80"
        local nginx_listen="127.0.0.1:$nginx_port"
        local nginx_comment="作为Xray的fallback后端"
        local nginx_ssl=""
        
        if [[ "$protocol" == "vless" || "$protocol" == "vless-xhttp" ]]; then
            # Reality协议：Nginx独立运行，提供HTTP订阅服务
            nginx_port="${custom_nginx_port:-8080}"
            nginx_listen="[::]:$nginx_port"
            nginx_comment="独立提供订阅服务 (HTTP)，不与Reality冲突"
            
            # 检测是否使用真实证书 (真实域名模式)
            local is_real_domain=false
            if [[ "$domain" == "$(cat "$CFG/cert_domain" 2>/dev/null)" ]] && _is_real_cert; then
                is_real_domain=true
                # 真实域名模式：回落和外部访问用同一个 HTTPS 端口
                nginx_port="${custom_nginx_port:-8443}"
                nginx_ssl="ssl"
            fi
        elif [[ "$protocol" == "vless-vision" || "$protocol" == "vless-ws" || "$protocol" == "vmess-ws" || "$protocol" == "trojan" ]]; then
            # 证书协议：Nginx 同时监听 80 (fallback) 和自定义端口 (HTTPS订阅)
            nginx_port="${custom_nginx_port:-8443}"
            nginx_listen="127.0.0.1:80"  # fallback 后端
            nginx_comment="80端口作为fallback，${nginx_port}端口提供HTTPS订阅"
            nginx_ssl="ssl"
        fi
        
        # 配置Nginx
        # TLS协议：双端口配置 (80回落 + 外部HTTPS)
        # Reality真实域名模式：单端口 HTTPS (同时作为回落和外部访问)
        if [[ "$protocol" == "vless-vision" || "$protocol" == "vless-ws" || "$protocol" == "vmess-ws" || "$protocol" == "trojan" ]]; then
            cat > "$nginx_conf_file" << EOF
# Fallback 后端 (供 Xray 回落使用)
server {
    listen 127.0.0.1:80;
    server_name $domain;
    
    root $web_dir;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    server_tokens off;
}

# HTTPS 订阅服务 (独立端口)
server {
    listen $nginx_port ssl http2;
    listen [::]:$nginx_port ssl http2;
    server_name $domain;
    
    ssl_certificate $CFG/certs/server.crt;
    ssl_certificate_key $CFG/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    root $web_dir;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 订阅文件目录 - v2ray 映射到 base64
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }
    
    # 订阅文件目录 - clash
    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }
    
    # 订阅文件目录 - surge
    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }
    
    # 订阅文件目录 - 通用
    location /sub/ {
        alias $CFG/subscription/;
        autoindex off;
        default_type text/plain;
    }
    
    server_tokens off;
}
EOF
        elif [[ "$is_real_domain" == "true" ]]; then
            # Reality真实域名模式：
            # - 127.0.0.1:nginx_port 供 Reality dest 回落（只显示伪装网页，无订阅）
            # - 0.0.0.0:nginx_port 供外部直接访问（伪装网页 + 订阅服务）
            cat > "$nginx_conf_file" << EOF
# Reality 回落后端 (真实域名模式) - 只显示伪装网页
server {
    listen 127.0.0.1:$nginx_port ssl http2;
    server_name $domain;
    
    ssl_certificate $CFG/certs/server.crt;
    ssl_certificate_key $CFG/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    root $web_dir;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 订阅路径返回404，防止通过Reality端口访问订阅
    location /sub/ {
        return 404;
    }
    
    server_tokens off;
}

# 订阅服务 (外部直接访问) - 伪装网页 + 订阅
server {
    listen $nginx_port ssl http2;
    listen [::]:$nginx_port ssl http2;
    server_name $domain;
    
    ssl_certificate $CFG/certs/server.crt;
    ssl_certificate_key $CFG/certs/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    root $web_dir;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 订阅文件目录 - v2ray 映射到 base64
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }
    
    # 订阅文件目录 - clash
    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }
    
    # 订阅文件目录 - surge
    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }
    
    # 订阅文件目录 - 通用
    location /sub/ {
        alias $CFG/subscription/;
        autoindex off;
        default_type text/plain;
    }
    
    server_tokens off;
}
EOF
        else
            # Reality无域名模式：单端口 HTTP 配置
            cat > "$nginx_conf_file" << EOF
server {
    listen $nginx_listen;  # $nginx_comment
    server_name $domain;
    
    root $web_dir;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 订阅文件目录 - v2ray 映射到 base64
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }
    
    # 订阅文件目录 - clash
    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }
    
    # 订阅文件目录 - surge
    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }
    
    # 订阅文件目录 - 通用
    location /sub/ {
        alias $CFG/subscription/;
        autoindex off;
        default_type text/plain;
    }
    
    server_tokens off;
}
EOF
        fi
        
        # 如果使用 sites-available 模式，创建软链接
        if [[ "$nginx_conf_dir" == "/etc/nginx/sites-available" ]]; then
            mkdir -p /etc/nginx/sites-enabled
            rm -f /etc/nginx/sites-enabled/default
            ln -sf "$nginx_conf_file" /etc/nginx/sites-enabled/vless-fake
        fi
        
        # 测试Nginx配置
        _info "配置Nginx并启动Web服务..."
        if nginx -t 2>/dev/null; then
            # 强制重启 Nginx 确保新配置生效（直接用 systemctl，更可靠）
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-service nginx stop 2>/dev/null
                sleep 1
                rc-service nginx start 2>/dev/null
            else
                systemctl stop nginx 2>/dev/null
                sleep 1
                systemctl start nginx 2>/dev/null
            fi
            sleep 1
            
            # 验证端口是否监听（兼容不同系统）
            local port_listening=false
            if ss -tlnp 2>/dev/null | grep -qE ":${nginx_port}\s|:${nginx_port}$"; then
                port_listening=true
            elif netstat -tlnp 2>/dev/null | grep -q ":${nginx_port} "; then
                port_listening=true
            fi
            
            # 检查服务状态
            local nginx_running=false
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-service nginx status &>/dev/null && nginx_running=true
            else
                systemctl is-active nginx &>/dev/null && nginx_running=true
            fi
            
            if [[ "$nginx_running" == "true" && "$port_listening" == "true" ]]; then
                _ok "伪装网页已创建并启动"
                _ok "Web服务器运行正常，订阅链接可用"
                # Reality 真实域名模式时，显示 Reality 端口
                if [[ "$is_real_domain" == "true" ]]; then
                    local reality_port=$(db_get_field "xray" "vless" "port")
                    [[ -z "$reality_port" ]] && reality_port=$(db_get_field "xray" "vless-xhttp" "port")
                    if [[ -n "$reality_port" ]]; then
                        _ok "伪装网页: https://$domain:$reality_port"
                    fi
                elif [[ "$protocol" == "vless-vision" || "$protocol" == "vless-ws" || "$protocol" == "vmess-ws" || "$protocol" == "trojan" ]]; then
                    _ok "伪装网页: https://$domain:$nginx_port"
                else
                    _ok "伪装网页: http://$domain:$nginx_port"
                fi
                echo -e "  ${D}提示: 自定义伪装网页请将 HTML 文件放入 $web_dir${NC}"
            elif [[ "$nginx_running" == "true" ]]; then
                _ok "伪装网页已创建"
                _warn "端口 $nginx_port 未监听，请检查 Nginx 配置"
            else
                _ok "伪装网页已创建"
                _warn "Nginx 服务未运行，请手动启动: systemctl start nginx"
            fi
        else
            _warn "Nginx配置测试失败"
            echo "配置错误详情："
            nginx -t
            rm -f "$nginx_conf_file" /etc/nginx/sites-enabled/vless-fake 2>/dev/null
        fi
        
        # 保存订阅配置信息
        local sub_uuid=$(get_sub_uuid)
        local use_https="false"
        # TLS协议 或 Reality真实域名模式 用 HTTPS
        if [[ "$protocol" == "vless-vision" || "$protocol" == "vless-ws" || "$protocol" == "vmess-ws" || "$protocol" == "trojan" ]] || [[ "$is_real_domain" == "true" ]]; then
            use_https="true"
        fi
        
        cat > "$CFG/sub.info" << EOF
sub_uuid=$sub_uuid
sub_port=$nginx_port
sub_domain=$domain
sub_https=$use_https
EOF
        _log "INFO" "订阅配置已保存: UUID=${sub_uuid:0:8}..., 端口=$nginx_port, 域名=$domain"
    fi
    
}

# 全局 SNI 域名列表（大陆可访问的企业子域名，用于 Reality 伪装）
readonly COMMON_SNI_LIST=(
    "ads.apple.com"
    "advertising.apple.com"
    "apps.apple.com"
    "asia.apple.com"
    "books.apple.com"
    "community.apple.com"
    "crl.apple.com"
    "developer.apple.com"
    "files.apple.com"
    "guide.apple.com"
    "iphone.apple.com"
    "link.apple.com"
    "maps.apple.com"
    "ml.apple.com"
    "music.apple.com"
    "one.apple.com"
    "store.apple.com"
    "support.apple.com"
    "time.apple.com"
    "tv.apple.com"
    "videos.apple.com"
)

gen_sni() { 
    # 从全局列表中随机选择一个 SNI
    local idx=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
    [[ -z "$idx" ]] && idx=$RANDOM
    echo "${COMMON_SNI_LIST[$((idx % ${#COMMON_SNI_LIST[@]}))]}"
}

gen_xhttp_path() {
    # 生成随机XHTTP路径，避免与Web服务器默认路由冲突
    local path="/$(head -c 32 /dev/urandom 2>/dev/null | base64 | tr -d '/+=' | head -c 8)"
    # 确保路径不为空
    if [[ -z "$path" || "$path" == "/" ]]; then
        path="/xhttp$(printf '%04x' $RANDOM)"
    fi
    echo "$path"
}

urlencode() {
    local s="$1" i c o=""
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) o+="$c" ;;
            *) printf -v c '%%%02x' "'$c"; o+="$c" ;;
        esac
    done
    echo "$o"
}

# 提取 IP 地址后缀（IPv4 取最后一段，IPv6 直接返回 "v6"）
get_ip_suffix() {
    local ip="$1"
    # 移除方括号
    ip="${ip#[}"
    ip="${ip%]}"
    
    if [[ "$ip" == *:* ]]; then
        # IPv6: 直接返回 "v6"
        echo "v6"
    else
        # IPv4: 取最后一个点后面的数字
        echo "${ip##*.}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 分享链接生成
#═══════════════════════════════════════════════════════════════════════════════

gen_vless_link() {
    local ip="$1" port="$2" uuid="$3" pbk="$4" sid="$5" sni="$6" country="${7:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}VLESS+Reality${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&type=tcp&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&flow=xtls-rprx-vision#${name}"
}

gen_vless_xhttp_link() {
    local ip="$1" port="$2" uuid="$3" pbk="$4" sid="$5" sni="$6" path="${7:-/}" country="${8:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}VLESS-XHTTP${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&type=xhttp&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&path=$(urlencode "$path")&mode=auto#${name}"
}

gen_vless_xhttp_cdn_link() {
    local domain="$1" port="$2" uuid="$3" path="${4:-/}" country="${5:-}"
    local name="${country:+${country}-}XHTTP-CDN"
    printf '%s\n' "vless://${uuid}@${domain}:${port}?encryption=none&security=tls&type=xhttp&sni=${domain}&host=${domain}&path=$(urlencode "$path")&mode=auto#${name}"
}

gen_vmess_ws_link() {
    local ip="$1" port="$2" uuid="$3" sni="$4" path="$5" country="${6:-}"
    local clean_ip="${ip#[}"
    clean_ip="${clean_ip%]}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}VMess-WS${ip_suffix:+-${ip_suffix}}"

    # VMess ws 链接：vmess://base64(json)
    # 注意：allowInsecure 必须是字符串 "true"，不是布尔值
    local json
    json=$(cat <<EOF
{"v":"2","ps":"${name}","add":"${clean_ip}","port":"${port}","id":"${uuid}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${sni}","path":"${path}","tls":"tls","sni":"${sni}","allowInsecure":"true"}
EOF
)
    printf 'vmess://%s\n' "$(echo -n "$json" | base64 -w 0 2>/dev/null || echo -n "$json" | base64 | tr -d '\n')"
}

# 生成二维码 (使用 qrencode 生成终端二维码)
gen_qr() {
    local text="$1"
    local margin="${2:-2}" 
    
    # 使用 qrencode 生成终端二维码 (标准黑白二维码)
    if command -v qrencode &>/dev/null; then
        echo "$text" | qrencode -t UTF8 -m "$margin" 2>/dev/null && return 0
    fi
    
    # 未安装 qrencode，提示用户安装
    echo "[需安装 qrencode 才能显示二维码]"
    return 1
}

# 检查是否能生成终端二维码
_can_gen_qr() {
    command -v qrencode &>/dev/null
}



# 生成各协议分享链接
gen_hy2_link() {
    local ip="$1" port="$2" password="$3" sni="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}Hysteria2${ip_suffix:+-${ip_suffix}}"
    # 链接始终使用实际端口，端口跳跃需要客户端手动配置
    printf '%s\n' "hysteria2://${password}@${ip}:${port}?sni=${sni}&insecure=1#${name}"
}

gen_trojan_link() {
    local ip="$1" port="$2" password="$3" sni="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}Trojan${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "trojan://${password}@${ip}:${port}?security=tls&sni=${sni}&type=tcp&allowInsecure=1#${name}"
}

gen_trojan_ws_link() {
    local ip="$1" port="$2" password="$3" sni="$4" path="${5:-/trojan}" country="${6:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}Trojan-WS${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "trojan://${password}@${ip}:${port}?security=tls&sni=${sni}&type=ws&host=${sni}&path=$(urlencode "$path")&allowInsecure=1#${name}"
}

gen_vless_ws_link() {
    local ip="$1" port="$2" uuid="$3" sni="$4" path="${5:-/}" country="${6:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}VLESS-WS${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "vless://${uuid}@${ip}:${port}?encryption=none&security=tls&sni=${sni}&type=ws&host=${sni}&path=$(urlencode "$path")&allowInsecure=1#${name}"
}

# VLESS-WS (无TLS) 分享链接 - 用于 CF Tunnel
gen_vless_ws_notls_link() {
    local ip="$1" port="$2" uuid="$3" path="${4:-/}" host="${5:-}" country="${6:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}VLESS-WS-CF${ip_suffix:+-${ip_suffix}}"
    # security=none 表示不使用 TLS
    local link="vless://${uuid}@${ip}:${port}?encryption=none&security=none&type=ws&path=$(urlencode "$path")"
    [[ -n "$host" ]] && link="${link}&host=${host}"
    printf '%s\n' "${link}#${name}"
}

gen_vless_vision_link() {
    local ip="$1" port="$2" uuid="$3" sni="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}VLESS-Vision${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "vless://${uuid}@${ip}:${port}?encryption=none&security=tls&sni=${sni}&type=tcp&flow=xtls-rprx-vision&allowInsecure=1#${name}"
}

gen_ss2022_link() {
    local ip="$1" port="$2" method="$3" password="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}SS2022${ip_suffix:+-${ip_suffix}}"
    local userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w 0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)
    printf '%s\n' "ss://${userinfo}@${ip}:${port}#${name}"
}

gen_ss_legacy_link() {
    local ip="$1" port="$2" method="$3" password="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}SS${ip_suffix:+-${ip_suffix}}"
    local userinfo=$(printf '%s:%s' "$method" "$password" | base64 -w 0 2>/dev/null || printf '%s:%s' "$method" "$password" | base64)
    printf '%s\n' "ss://${userinfo}@${ip}:${port}#${name}"
}

gen_snell_link() {
    local ip="$1" port="$2" psk="$3" version="${4:-4}" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}Snell-v${version}${ip_suffix:+-${ip_suffix}}"
    # Snell 没有标准URI格式，使用自定义格式
    printf '%s\n' "snell://${psk}@${ip}:${port}?version=${version}#${name}"
}

gen_tuic_link() {
    local ip="$1" port="$2" uuid="$3" password="$4" sni="$5" country="${6:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}TUIC${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "tuic://${uuid}:${password}@${ip}:${port}?congestion_control=bbr&alpn=h3&sni=${sni}&udp_relay_mode=native&allow_insecure=1#${name}"
}

gen_anytls_link() {
    local ip="$1" port="$2" password="$3" sni="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}AnyTLS${ip_suffix:+-${ip_suffix}}"
    printf '%s\n' "anytls://${password}@${ip}:${port}?sni=${sni}&allowInsecure=1#${name}"
}

gen_naive_link() {
    local host="$1" port="$2" username="$3" password="$4" country="${5:-}"
    local name="${country:+${country}-}Naive"
    # Shadowrocket HTTP/2 格式，使用域名
    printf '%s\n' "http2://${username}:${password}@${host}:${port}#${name}"
}

gen_shadowtls_link() {
    local ip="$1" port="$2" password="$3" method="$4" sni="$5" stls_password="$6" country="${7:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}ShadowTLS${ip_suffix:+-${ip_suffix}}"
    # ShadowTLS链接格式：ss://method:password@server:port#name + ShadowTLS参数
    local ss_link=$(echo -n "${method}:${password}" | base64 -w 0)
    printf '%s\n' "ss://${ss_link}@${ip}:${port}?plugin=shadow-tls;host=${sni};password=${stls_password}#${name}"
}

# gen_snell_v5_link 已合并到 gen_snell_link，通过 version 参数区分
gen_snell_v5_link() { gen_snell_link "$1" "$2" "$3" "${4:-5}" "$5"; }

gen_socks_link() {
    local ip="$1" port="$2" username="$3" password="$4" country="${5:-}"
    local ip_suffix=$(get_ip_suffix "$ip")
    local name="${country:+${country}-}SOCKS5${ip_suffix:+-${ip_suffix}}"
    if [[ -n "$username" && -n "$password" ]]; then
        printf '%s\n' "https://t.me/socks?server=${ip}&port=${port}&user=${username}&pass=${password}"
    else
        printf '%s\n' "socks5://${ip}:${port}#${name}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 连接测试
#═══════════════════════════════════════════════════════════════════════════════

test_connection() {
    # 服务端：检查所有已安装协议的端口 (从数据库读取)
    local installed=$(get_installed_protocols)
    for proto in $installed; do
        local port=""
        # 尝试从 xray 或 singbox 读取
        if db_exists "xray" "$proto"; then
            port=$(db_get_field "xray" "$proto" "port")
        elif db_exists "singbox" "$proto"; then
            port=$(db_get_field "singbox" "$proto" "port")
        fi
        
        if [[ -n "$port" ]]; then
            if ss -tlnp 2>/dev/null | grep -q ":$port " || ss -ulnp 2>/dev/null | grep -q ":$port "; then
                _ok "$(get_protocol_name $proto) 端口 $port 已监听"
            else
                _err "$(get_protocol_name $proto) 端口 $port 未监听"
            fi
        fi
    done
}

test_latency() {
    local ip="$1" port="$2" proto="${3:-tcp}" start end
    start=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
    
    if [[ "$proto" == "hy2" || "$proto" == "tuic" ]]; then
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            echo "$((end-start))ms"
        else
            echo "UDP"
        fi
    else
        # 优先使用 nc (netcat)，更通用且跨平台兼容性更好
        if command -v nc &>/dev/null; then
            if timeout 3 nc -z -w 2 "$ip" "$port" 2>/dev/null; then
                end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
                echo "$((end-start))ms"
            else
                echo "超时"
            fi
        # 回退到 bash /dev/tcp（某些系统可能不支持）
        elif timeout 3 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
            end=$(date +%s%3N 2>/dev/null || echo $(($(date +%s)*1000)))
            echo "$((end-start))ms"
        else
            echo "超时"
        fi
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 软件安装
#═══════════════════════════════════════════════════════════════════════════════

# 安装系统依赖
install_deps() {
    _info "检查系统依赖..."
    if [[ "$DISTRO" == "alpine" ]]; then
        _info "更新软件包索引..."
        if ! timeout 60 apk update 2>&1 | grep -E '^(fetch|OK)' | sed 's/^/  /'; then
            if ! apk update &>/dev/null; then
                _err "更新软件包索引失败（可能超时）"
                return 1
            fi
        fi
        
        local deps="curl jq unzip iproute2 iptables ip6tables gcompat libc6-compat openssl socat bind-tools xz"
        _info "安装依赖: $deps"
        if ! timeout 180 apk add --no-cache $deps 2>&1 | grep -E '^(\(|OK|Installing|Executing)' | sed 's/^/  /'; then
            # 检查实际安装结果
            local missing=""
            for dep in $deps; do
                apk info -e "$dep" &>/dev/null || missing="$missing $dep"
            done
            if [[ -n "$missing" ]]; then
                _err "依赖安装失败:$missing"
                return 1
            fi
        fi
        _ok "依赖安装完成"
    elif [[ "$DISTRO" == "centos" ]]; then
        _info "安装 EPEL 源..."
        if ! timeout 120 yum install -y epel-release 2>&1 | grep -E '^(Installing|Verifying|Complete)' | sed 's/^/  /'; then
            if ! rpm -q epel-release &>/dev/null; then
                _err "EPEL 源安装失败（可能超时）"
                return 1
            fi
        fi
        
        local deps="curl jq unzip iproute iptables vim-common openssl socat bind-utils xz"
        _info "安装依赖: $deps"
        if ! timeout 300 yum install -y $deps 2>&1 | grep -E '^(Installing|Verifying|Complete|Downloading)' | sed 's/^/  /'; then
            # 检查实际安装结果
            local missing=""
            for dep in $deps; do
                rpm -q "$dep" &>/dev/null || missing="$missing $dep"
            done
            if [[ -n "$missing" ]]; then
                _err "依赖安装失败:$missing"
                return 1
            fi
        fi
        _ok "依赖安装完成"
    elif [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        _info "更新软件包索引..."
        # 移除 -qq 让用户能看到进度，避免交互卡住
        if ! DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | grep -E '^(Hit|Get|Fetched|Reading)' | head -10 | sed 's/^/  /'; then
            # 即使 grep 没匹配到也继续，只要 apt-get 成功即可
            :
        fi
        
        local deps="curl jq unzip iproute2 xxd openssl socat dnsutils xz-utils iptables"
        _info "安装依赖: $deps"
        # 使用 DEBIAN_FRONTEND 避免交互，显示简化进度，移除 timeout 避免死锁
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $deps 2>&1 | grep -E '^(Setting up|Unpacking|Processing|Get:|Fetched)' | sed 's/^/  /'; then
            # 检查实际安装结果
            if ! dpkg -l $deps >/dev/null 2>&1; then
                _err "依赖安装失败"
                return 1
            fi
        fi
        _ok "依赖安装完成"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 证书管理
#═══════════════════════════════════════════════════════════════════════════════

# 安装 acme.sh
install_acme_tool() {
    # 检查多个可能的安装位置
    local acme_paths=(
        "$HOME/.acme.sh/acme.sh"
        "/root/.acme.sh/acme.sh"
        "/usr/local/bin/acme.sh"
    )
    
    for acme_path in "${acme_paths[@]}"; do
        if [[ -f "$acme_path" ]]; then
            _ok "acme.sh 已安装 ($acme_path)"
            return 0
        fi
    done
    
    _info "安装 acme.sh 证书申请工具..."
    
    # 方法1: 官方安装脚本
    if curl -sL https://get.acme.sh | sh -s email="$ACME_DEFAULT_EMAIL" 2>&1 | grep -qE "Install success|already installed"; then
        source "$HOME/.acme.sh/acme.sh.env" 2>/dev/null || true
        if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
            _ok "acme.sh 安装成功"
            return 0
        fi
    fi
    
    # 方法2: 使用 git clone
    if command -v git &>/dev/null; then
        _info "尝试使用 git 安装..."
        if git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /tmp/acme.sh 2>/dev/null; then
            cd /tmp/acme.sh && ./acme.sh --install -m "$ACME_DEFAULT_EMAIL" 2>/dev/null
            cd - >/dev/null
            rm -rf /tmp/acme.sh
            if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
                _ok "acme.sh 安装成功 (git)"
                return 0
            fi
        fi
    fi
    
    # 方法3: 直接下载脚本
    _info "尝试直接下载..."
    mkdir -p "$HOME/.acme.sh"
    if curl -sL -o "$HOME/.acme.sh/acme.sh" "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" 2>/dev/null; then
        chmod +x "$HOME/.acme.sh/acme.sh"
        if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
            _ok "acme.sh 安装成功 (直接下载)"
            return 0
        fi
    fi
    
    _err "acme.sh 安装失败，请检查网络连接"
    _warn "你可以手动安装: curl https://get.acme.sh | sh"
    return 1
}

# 确保 ACME 账户邮箱有效（避免 example.com 被拒）
ensure_acme_account_email() {
    local acme_sh="$1"
    local account_conf="$HOME/.acme.sh/account.conf"
    local current_email=""
    
    if [[ -f "$account_conf" ]]; then
        current_email=$(grep -E "^ACCOUNT_EMAIL=" "$account_conf" | head -1 | sed -E "s/^ACCOUNT_EMAIL=['\"]?([^'\"]*)['\"]?$/\1/")
    fi
    
    if [[ -z "$current_email" || "$current_email" == *"example.com"* ]]; then
        echo ""
        _info "设置 ACME 账户邮箱为默认值: $ACME_DEFAULT_EMAIL"
        if [[ -f "$account_conf" ]]; then
            if grep -q "^ACCOUNT_EMAIL=" "$account_conf"; then
                sed -i "s/^ACCOUNT_EMAIL=.*/ACCOUNT_EMAIL='$ACME_DEFAULT_EMAIL'/" "$account_conf"
            else
                echo "ACCOUNT_EMAIL='$ACME_DEFAULT_EMAIL'" >> "$account_conf"
            fi
        else
            mkdir -p "$HOME/.acme.sh"
            echo "ACCOUNT_EMAIL='$ACME_DEFAULT_EMAIL'" > "$account_conf"
        fi
        
        if ! ACCOUNT_EMAIL="$ACME_DEFAULT_EMAIL" "$acme_sh" --register-account -m "$ACME_DEFAULT_EMAIL" >/dev/null 2>&1; then
            _err "ACME 账户注册失败，请检查网络或稍后重试"
            return 1
        fi
        _ok "ACME 账户邮箱已更新: $ACME_DEFAULT_EMAIL"
    fi
    
    return 0
}

# DNS-01 验证申请证书
# 参数: $1=域名 $2=证书目录 $3=协议
_issue_cert_dns() {
    local domain="$1"
    local cert_dir="$2"
    local protocol="$3"
    
    echo ""
    _line >&2
    echo -e "  ${C}DNS-01 验证模式${NC}"
    _line >&2
    echo ""
    echo -e "  ${Y}支持的 DNS 服务商：${NC}"
    echo -e "  1) Cloudflare"
    echo -e "  2) Aliyun (阿里云)"
    echo -e "  3) DNSPod (腾讯云)"
    echo -e "  4) 手动 DNS 验证"
    echo ""
    read -rp "  请选择 DNS 服务商 [1-4]: " dns_choice
    
    local dns_api=""
    local dns_env=""
    
    case "$dns_choice" in
        1)
            echo ""
            echo -e "  ${D}获取 Cloudflare API Token:${NC}"
            echo -e "  ${D}https://dash.cloudflare.com/profile/api-tokens${NC}"
            echo -e "  ${D}创建 Token 时选择 'Edit zone DNS' 模板${NC}"
            echo ""
            read -rp "  请输入 CF_Token: " cf_token
            [[ -z "$cf_token" ]] && { _err "Token 不能为空"; return 1; }
            dns_api="dns_cf"
            dns_env="CF_Token=$cf_token"
            ;;
        2)
            echo ""
            echo -e "  ${D}获取阿里云 AccessKey:${NC}"
            echo -e "  ${D}https://ram.console.aliyun.com/manage/ak${NC}"
            echo ""
            read -rp "  请输入 Ali_Key: " ali_key
            read -rp "  请输入 Ali_Secret: " ali_secret
            [[ -z "$ali_key" || -z "$ali_secret" ]] && { _err "Key/Secret 不能为空"; return 1; }
            dns_api="dns_ali"
            dns_env="Ali_Key=$ali_key Ali_Secret=$ali_secret"
            ;;
        3)
            echo ""
            echo -e "  ${D}获取 DNSPod Token:${NC}"
            echo -e "  ${D}https://console.dnspod.cn/account/token/token${NC}"
            echo ""
            read -rp "  请输入 DP_Id: " dp_id
            read -rp "  请输入 DP_Key: " dp_key
            [[ -z "$dp_id" || -z "$dp_key" ]] && { _err "ID/Key 不能为空"; return 1; }
            dns_api="dns_dp"
            dns_env="DP_Id=$dp_id DP_Key=$dp_key"
            ;;
        4)
            # 手动 DNS 验证
            _issue_cert_dns_manual "$domain" "$cert_dir" "$protocol"
            return $?
            ;;
        *)
            _err "无效选择"
            return 1
            ;;
    esac
    
    # 安装 acme.sh
    install_acme_tool || return 1
    local acme_sh="$HOME/.acme.sh/acme.sh"
    ensure_acme_account_email "$acme_sh" || return 1
    
    _info "正在通过 DNS 验证申请证书..."
    echo ""
    
    # 设置环境变量并申请证书
    eval "export $dns_env"
    
    local reload_cmd="chmod 600 $cert_dir/server.key; chmod 644 $cert_dir/server.crt"
    
    if "$acme_sh" --issue -d "$domain" --dns "$dns_api" --force 2>&1 | tee /tmp/acme_dns.log | grep -E "^\[|Verify finished|Cert success|error|Error" | sed 's/^/  /'; then
        echo ""
        _ok "证书申请成功，安装证书..."
        
        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "$cert_dir/server.key"  \
            --fullchain-file "$cert_dir/server.crt" \
            --reloadcmd      "$reload_cmd" >/dev/null 2>&1
        
        # 保存域名
        echo "$domain" > "$CFG/cert_domain"
        
        rm -f /tmp/acme_dns.log
        
        # 读取自定义 nginx 端口
        local custom_port=""
        [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")
        create_fake_website "$domain" "$protocol" "$custom_port"
        
        _ok "证书已配置到 $cert_dir"
        diagnose_certificate "$domain"
        return 0
    else
        echo ""
        _err "DNS 验证失败！"
        cat /tmp/acme_dns.log 2>/dev/null | grep -E "(error|Error)" | head -3
        rm -f /tmp/acme_dns.log
        return 1
    fi
}

# 手动 DNS 验证
_issue_cert_dns_manual() {
    local domain="$1"
    local cert_dir="$2"
    local protocol="$3"
    
    install_acme_tool || return 1
    local acme_sh="$HOME/.acme.sh/acme.sh"
    ensure_acme_account_email "$acme_sh" || return 1
    
    echo ""
    _info "开始手动 DNS 验证..."
    echo ""
    
    # 获取 DNS 记录
    local txt_record=$("$acme_sh" --issue -d "$domain" --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1 | sed -n "s/.*TXT value: '\([^']*\)'.*/\1/p")
    
    if [[ -z "$txt_record" ]]; then
        # 尝试另一种方式获取
        "$acme_sh" --issue -d "$domain" --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1 | tee /tmp/acme_manual.log
        txt_record=$(sed -n "s/.*TXT value: '\([^']*\)'.*/\1/p" "/tmp/acme_manual.log" 2>/dev/null)
    fi
    
    if [[ -z "$txt_record" ]]; then
        _err "无法获取 DNS TXT 记录值"
        return 1
    fi
    
    echo ""
    _line
    echo -e "  ${Y}请添加以下 DNS TXT 记录：${NC}"
    _line
    echo ""
    echo -e "  主机记录: ${G}_acme-challenge${NC}"
    echo -e "  记录类型: ${G}TXT${NC}"
    echo -e "  记录值:   ${G}$txt_record${NC}"
    echo ""
    _line
    echo ""
    echo -e "  ${D}添加完成后，等待 DNS 生效（通常 1-5 分钟）${NC}"
    echo ""
    read -rp "  DNS 记录添加完成后按回车继续..." _
    
    _info "验证 DNS 记录..."
    
    # 完成验证
    if "$acme_sh" --renew -d "$domain" --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1 | grep -q "Cert success"; then
        echo ""
        _ok "证书申请成功，安装证书..."
        
        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "$cert_dir/server.key"  \
            --fullchain-file "$cert_dir/server.crt" >/dev/null 2>&1
        
        echo "$domain" > "$CFG/cert_domain"
        
        local custom_port=""
        [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")
        create_fake_website "$domain" "$protocol" "$custom_port"
        
        _ok "证书已配置到 $cert_dir"
        echo ""
        _warn "注意: 手动 DNS 模式无法自动续期，证书到期前需要手动更新"
        return 0
    else
        _err "DNS 验证失败，请检查 TXT 记录是否正确"
        return 1
    fi
}

# 申请 ACME 证书
# 参数: $1=域名
get_acme_cert() {
    local domain=$1
    local protocol="${2:-unknown}"
    local cert_dir="$CFG/certs"
    mkdir -p "$cert_dir"
    
    # 检查是否已有相同域名的证书
    if [[ -f "$CFG/cert_domain" ]]; then
        local existing_domain=$(cat "$CFG/cert_domain")
        if [[ "$existing_domain" == "$domain" && -f "$cert_dir/server.crt" && -f "$cert_dir/server.key" ]]; then
            _ok "检测到相同域名的现有证书，跳过申请"
            # 检查证书是否仍然有效
            if openssl x509 -in "$cert_dir/server.crt" -noout -checkend 2592000 >/dev/null 2>&1; then
                _ok "现有证书仍然有效（30天以上）"
                
                # 读取自定义 nginx 端口（如果有）
                local custom_port=""
                [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")
                
                # 确保Web服务器也启动（复用证书时也需要）
                create_fake_website "$domain" "$protocol" "$custom_port"
                
                diagnose_certificate "$domain"
                return 0
            else
                _warn "现有证书即将过期，重新申请..."
            fi
        fi
    fi
    
    # 先检查域名解析 (快速验证)
    _info "检查域名解析..."
    if ! check_domain_dns "$domain"; then
        _err "域名解析检查失败，无法申请 Let's Encrypt 证书"
        echo ""
        echo -e "  ${Y}选项：${NC}"
        echo -e "  1) 使用自签证书 (安全性较低，易被识别)"
        echo -e "  2) 重新输入域名"
        echo -e "  3) 退出安装"
        echo ""
        read -rp "  请选择 [1-3]: " choice
        
        case "$choice" in
            1)
                _warn "将使用自签证书"
                return 1  # 返回失败，让调用方使用自签证书
                ;;
            2)
                return 2  # 返回特殊值，表示需要重新输入域名
                ;;
            3|"")
                _info "已退出安装"
                exit 0
                ;;
            *)
                _err "无效选择，退出安装"
                exit 0
                ;;
        esac
    fi
    
    # 域名解析通过，询问是否申请证书
    echo ""
    _ok "域名解析验证通过！"
    echo ""
    echo -e "  ${Y}接下来将申请 Let's Encrypt 证书：${NC}"
    echo -e "  • 域名: ${G}$domain${NC}"
    echo -e "  • 证书有效期: 90天 (自动续期)"
    echo ""
    echo -e "  ${Y}请选择验证方式：${NC}"
    echo -e "  1) HTTP 验证 (需要80端口，推荐)"
    echo -e "  2) DNS 验证 (无需80端口，适合NAT/无公网IP)"
    echo -e "  3) 取消"
    echo ""
    read -rp "  请选择 [1-3]: " verify_method
    
    case "$verify_method" in
        2)
            # DNS 验证模式
            _issue_cert_dns "$domain" "$cert_dir" "$protocol"
            return $?
            ;;
        3)
            _info "已取消证书申请"
            return 2
            ;;
        1|"")
            # HTTP 验证模式（默认）
            ;;
        *)
            _err "无效选择"
            return 1
            ;;
    esac
    
    # 用户确认后再安装 acme.sh
    _info "安装证书申请工具..."
    install_acme_tool || return 1
    
    local acme_sh="$HOME/.acme.sh/acme.sh"
    ensure_acme_account_email "$acme_sh" || return 1
    
    # 临时停止可能占用 80 端口的服务（兼容 Alpine/systemd）
    local nginx_was_running=false
    if svc status nginx 2>/dev/null; then
        nginx_was_running=true
        _info "临时停止 Nginx..."
        svc stop nginx
    fi
    
    _info "正在为 $domain 申请证书 (Let's Encrypt)..."
    echo ""
    
    # 获取服务器IP用于错误提示
    local server_ip=$(get_ipv4)
    [[ -z "$server_ip" ]] && server_ip=$(get_ipv6)
    
    # 构建 reloadcmd（兼容 systemd 和 OpenRC）
    local reload_cmd="chmod 600 $cert_dir/server.key; chmod 644 $cert_dir/server.crt; chown root:root $cert_dir/server.key $cert_dir/server.crt; if command -v systemctl >/dev/null 2>&1; then systemctl restart vless-reality vless-singbox 2>/dev/null || true; elif command -v rc-service >/dev/null 2>&1; then rc-service vless-reality restart 2>/dev/null || true; rc-service vless-singbox restart 2>/dev/null || true; fi"
    
    # 使用 standalone 模式申请证书，显示实时进度
    local acme_log="/tmp/acme_output.log"
    
    # 直接执行 acme.sh，不使用 timeout（避免某些系统兼容性问题）
    if "$acme_sh" --issue -d "$domain" --standalone --httpport 80 --force 2>&1 | tee "$acme_log" | grep -E "^\[|Verify finished|Cert success|error|Error" | sed 's/^/  /'; then
        echo ""
        _ok "证书申请成功，安装证书..."
        
        # 安装证书到指定目录，并设置权限和自动重启服务
        "$acme_sh" --install-cert -d "$domain" \
            --key-file       "$cert_dir/server.key"  \
            --fullchain-file "$cert_dir/server.crt" \
            --reloadcmd      "$reload_cmd" >/dev/null 2>&1
        
        rm -f "$acme_log"
        
        # 恢复 Nginx
        if [[ "$nginx_was_running" == "true" ]]; then
            svc start nginx
        fi
        
        _ok "证书已配置到 $cert_dir"
        _ok "证书自动续期已启用 (60天后)"
        
        # 读取自定义 nginx 端口（如果有）
        local custom_port=""
        [[ -f "$CFG/.nginx_port_tmp" ]] && custom_port=$(cat "$CFG/.nginx_port_tmp")
        
        # 创建简单的伪装网页
        create_fake_website "$domain" "$protocol" "$custom_port"
        
        # 验证证书文件
        if [[ -f "$cert_dir/server.crt" && -f "$cert_dir/server.key" ]]; then
            _ok "证书文件验证通过"
            # 运行证书诊断
            diagnose_certificate "$domain"
        else
            _err "证书文件不存在"
            return 1
        fi
        
        return 0
    else
        echo ""
        # 恢复 Nginx
        if [[ "$nginx_was_running" == "true" ]]; then
            svc start nginx
        fi
        
        _err "证书申请失败！"
        echo ""
        _err "详细错误信息："
        cat "$acme_log" 2>/dev/null | grep -E "(error|Error|ERROR|fail|Fail|FAIL)" | head -5 | while read -r line; do
            _err "  $line"
        done
        rm -f "$acme_log"
        echo ""
        _err "常见问题检查："
        _err "  1. 域名是否正确解析到本机 IP: $server_ip"
        _err "  2. 80 端口是否在防火墙中开放"
        _err "  3. 域名是否已被其他证书占用"
        _err "  4. 是否有其他程序占用80端口"
        echo ""
        
        # 给用户选择而不是自动回退
        echo -e "  ${W}请选择操作：${NC}"
        echo -e "  ${G}1${NC}) 重试证书申请"
        echo -e "  ${G}2${NC}) 使用 DNS 验证模式 (需要 DNS API)"
        echo -e "  ${G}3${NC}) 使用自签名证书 (不推荐)"
        echo -e "  ${G}0${NC}) 取消安装"
        echo ""
        read -rp "  请选择 [0]: " cert_choice
        cert_choice="${cert_choice:-0}"
        
        case "$cert_choice" in
            1)
                # 重试
                get_acme_cert "$domain" "$protocol"
                return $?
                ;;
            2)
                # DNS 验证模式
                _info "切换到 DNS 验证模式..."
                get_acme_cert_dns "$domain" "$protocol"
                return $?
                ;;
            3)
                # 自签名证书
                _warn "使用自签名证书模式..."
                return 1
                ;;
            *)
                # 取消
                _warn "已取消安装"
                return 2
                ;;
        esac
    fi
}

# 检测并设置证书和 Nginx 配置（统一入口）
# 返回: 0=成功（有证书和Nginx），1=失败（无证书或用户取消）
# 设置全局变量: CERT_DOMAIN, NGINX_PORT
setup_cert_and_nginx() {
    local protocol="$1"
    local default_nginx_port="18443"
    
    # 全局变量，供调用方使用
    CERT_DOMAIN=""
    NGINX_PORT="$default_nginx_port"
    
    # === 回落子协议检测：如果是 WS 协议且主协议在 8443 端口，跳过 Nginx 配置 ===
    local is_fallback_mode=false
    if [[ "$protocol" == "vless-ws" || "$protocol" == "vmess-ws" || "$protocol" == "trojan-ws" ]]; then
        local master_port=""
        for proto in vless-vision trojan; do
            if db_exists "xray" "$proto"; then
                master_port=$(db_get_field "xray" "$proto" "port" 2>/dev/null)
                if [[ "$master_port" == "8443" ]]; then
                    is_fallback_mode=true
                    break
                fi
            fi
        done
    fi
    
    # 检测是否已有证书
    if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
        # 验证证书是否有效
        if openssl x509 -in "$CFG/certs/server.crt" -noout -checkend 2592000 >/dev/null 2>&1; then
            CERT_DOMAIN=$(cat "$CFG/cert_domain")
            
            # 检查是否是自签名证书
            local is_self_signed=true
            local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
            if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]] || [[ "$issuer" == *"E1"* ]] || [[ "$issuer" == *"ZeroSSL"* ]] || [[ "$issuer" == *"Buypass"* ]]; then
                is_self_signed=false
            fi
            
            # 如果是自签名证书，询问用户是否申请真实证书
            if [[ "$is_self_signed" == "true" && "$is_fallback_mode" == "false" ]]; then
                echo ""
                _warn "检测到自签名证书 (域名: $CERT_DOMAIN)"
                echo -e "  ${G}1)${NC} 申请真实证书 (推荐 - 订阅功能可用)"
                echo -e "  ${G}2)${NC} 继续使用自签名证书 (订阅功能不可用)"
                echo ""
                read -rp "  请选择 [1]: " self_cert_choice
                
                if [[ "$self_cert_choice" != "2" ]]; then
                    # 用户选择申请真实证书，清除旧证书，走正常申请流程
                    rm -f "$CFG/certs/server.crt" "$CFG/certs/server.key" "$CFG/cert_domain"
                    CERT_DOMAIN=""
                    # 继续往下走到证书申请流程
                else
                    # 继续使用自签名证书，跳过 Nginx 配置
                    _ok "继续使用自签名证书: $CERT_DOMAIN"
                    return 0
                fi
            else
                # 真实证书，正常处理
                # 回落模式：只设置证书域名，跳过 Nginx 配置
                if [[ "$is_fallback_mode" == "true" ]]; then
                    _ok "检测到现有证书: $CERT_DOMAIN (回落模式，跳过 Nginx)"
                    return 0
                fi
                
                # Reality 协议：询问用户是否使用现有证书
                if [[ "$protocol" == "vless" || "$protocol" == "vless-xhttp" ]]; then
                    echo ""
                    _ok "检测到现有证书: $CERT_DOMAIN"
                    echo ""
                    echo -e "  ${Y}Reality 协议可选择:${NC}"
                    echo -e "  ${G}1)${NC} 使用真实域名 (使用现有证书，支持订阅服务)"
                    echo -e "  ${G}2)${NC} 无域名模式 (使用随机 SNI，更隐蔽)"
                    echo ""
                    read -rp "  请选择 [1]: " reality_cert_choice
                    
                    if [[ "$reality_cert_choice" == "2" ]]; then
                        # 用户选择无域名模式，清除证书域名变量和旧证书
                        CERT_DOMAIN=""
                        rm -f "$CFG/certs/server.crt" "$CFG/certs/server.key" "$CFG/cert_domain"
                        _info "将使用随机 SNI (无域名模式)"
                        return 0
                    fi
                    # 继续使用真实证书，标记SNI已确定，避免ask_sni_config再次询问
                    REALITY_SNI_CONFIRMED="$CERT_DOMAIN"
                fi
                
                # 读取已有的订阅配置
                if [[ -f "$CFG/sub.info" ]]; then
                    source "$CFG/sub.info" 2>/dev/null
                    NGINX_PORT="${sub_port:-$default_nginx_port}"
                    
                    # Reality 协议使用真实域名时，必须用 HTTPS 端口，不能用 80
                    if [[ "$protocol" == "vless" || "$protocol" == "vless-xhttp" ]]; then
                        if [[ "$NGINX_PORT" == "80" ]]; then
                            NGINX_PORT="$default_nginx_port"
                        fi
                    fi
                fi
                
                _ok "使用证书域名: $CERT_DOMAIN"
                
                # 检查 Nginx 配置文件是否存在 (包括 Alpine http.d)
                local nginx_conf_exists=false
                if [[ -f "/etc/nginx/http.d/vless-fake.conf" ]] || [[ -f "/etc/nginx/conf.d/vless-fake.conf" ]] || [[ -f "/etc/nginx/sites-available/vless-fake" ]]; then
                    nginx_conf_exists=true
                fi
                
                # 检查订阅文件是否存在
                local sub_uuid=$(get_sub_uuid)  # 使用统一的函数获取或生成 UUID
                local sub_files_exist=false
                if [[ -f "$CFG/subscription/$sub_uuid/base64" ]]; then
                    sub_files_exist=true
                fi
                
                # 如果 Nginx 配置或订阅文件不存在，重新配置
                if [[ "$nginx_conf_exists" == "false" ]] || [[ "$sub_files_exist" == "false" ]]; then
                    _info "配置订阅服务 (端口: $NGINX_PORT)..."
                    generate_sub_files
                    create_fake_website "$CERT_DOMAIN" "$protocol" "$NGINX_PORT"
                else
                    # 检查 Nginx 配置是否有正确的订阅路由 (使用 alias 指向 subscription 目录)
                    local nginx_conf_valid=false
                    if grep -q "alias.*subscription" "/etc/nginx/http.d/vless-fake.conf" 2>/dev/null; then
                        nginx_conf_valid=true
                    elif grep -q "alias.*subscription" "/etc/nginx/conf.d/vless-fake.conf" 2>/dev/null; then
                        nginx_conf_valid=true
                    elif grep -q "alias.*subscription" "/etc/nginx/sites-available/vless-fake" 2>/dev/null; then
                        nginx_conf_valid=true
                    fi
                    
                    if [[ "$nginx_conf_valid" == "false" ]]; then
                        _warn "检测到旧版 Nginx 配置，正在更新..."
                        generate_sub_files
                        create_fake_website "$CERT_DOMAIN" "$protocol" "$NGINX_PORT"
                    fi
                    
                    # Reality 协议不显示 Nginx 端口（外部访问走 Reality 端口）
                    if [[ "$protocol" != "vless" && "$protocol" != "vless-xhttp" ]]; then
                        _ok "订阅服务端口: $NGINX_PORT"
                    fi
                    
                    # 确保订阅文件是最新的
                    generate_sub_files
                    
                    # 确保 Nginx 运行
                    if ! ss -tlnp 2>/dev/null | grep -qE ":${NGINX_PORT}\s|:${NGINX_PORT}$"; then
                        _info "启动 Nginx 服务..."
                        systemctl stop nginx 2>/dev/null
                        sleep 1
                        systemctl start nginx 2>/dev/null || rc-service nginx start 2>/dev/null
                        sleep 1
                    fi
                    
                    # 再次检查端口是否监听
                    if ss -tlnp 2>/dev/null | grep -qE ":${NGINX_PORT}\s|:${NGINX_PORT}$"; then
                        _ok "Nginx 服务运行正常"
                        # Reality 协议不显示 Nginx 端口
                        if [[ "$protocol" != "vless" && "$protocol" != "vless-xhttp" ]]; then
                            _ok "伪装网页: https://$CERT_DOMAIN:$NGINX_PORT"
                        fi
                    else
                        _warn "Nginx 端口 $NGINX_PORT 未监听，尝试重新配置..."
                        generate_sub_files
                        create_fake_website "$CERT_DOMAIN" "$protocol" "$NGINX_PORT"
                    fi
                fi
                
                return 0
            fi
        fi
    fi
    
    # 没有证书或用户选择申请新证书，询问用户
    # TLS+CDN 模式必须使用真实证书，不提供自签选项
    local is_cdn_mode=false
    if [[ "$protocol" == "vless-xhttp-cdn" ]]; then
        is_cdn_mode=true
    fi
    
    if [[ "$is_cdn_mode" == "true" ]]; then
        # TLS+CDN 模式：强制使用真实域名
        echo ""
        _line
        echo -e "  ${W}TLS+CDN 模式 - 证书配置${NC}"
        _line
        echo -e "  ${Y}此模式必须使用真实域名和证书${NC}"
        echo -e "  ${D}提示: 域名必须已解析到本机 IP${NC}"
        _line
        echo ""
        read -rp "  请输入你的域名: " input_domain
        
        if [[ -z "$input_domain" ]]; then
            _err "域名不能为空"
            return 1
        fi
        
        CERT_DOMAIN="$input_domain"
        
        # 确保配置目录存在
        mkdir -p "$CFG" 2>/dev/null
        
        # 保存端口到临时文件，供 create_fake_website 使用
        echo "$NGINX_PORT" > "$CFG/.nginx_port_tmp" 2>/dev/null
        
        # 申请证书（内部会调用 create_fake_website，会自动保存 sub.info）
        if get_acme_cert "$CERT_DOMAIN" "$protocol"; then
            echo "$CERT_DOMAIN" > "$CFG/cert_domain"
            # 确保订阅文件存在
            generate_sub_files
            rm -f "$CFG/.nginx_port_tmp"
            return 0
        else
            _err "证书申请失败"
            rm -f "$CFG/.nginx_port_tmp"
            return 1
        fi
    else
        # 其他模式：提供真实证书和自签证书两个选项
        echo ""
        _line
        echo -e "  ${W}证书配置模式${NC}"
        echo -e "  ${G}1)${NC} 使用真实域名 (推荐 - 自动申请 Let's Encrypt 证书)"
        echo -e "  ${G}2)${NC} 无域名 (使用自签证书 - 安全性较低，易被识别)"
        echo ""
        read -rp "  请选择 [1-2，默认 2]: " cert_choice
        
        if [[ "$cert_choice" == "1" ]]; then
            echo -e "  ${Y}提示: 域名必须已解析到本机 IP${NC}"
            read -rp "  请输入你的域名: " input_domain
            
            if [[ -n "$input_domain" ]]; then
                CERT_DOMAIN="$input_domain"
                
                # 确保配置目录存在
                mkdir -p "$CFG" 2>/dev/null
                
                # 保存端口到临时文件，供 create_fake_website 使用
                echo "$NGINX_PORT" > "$CFG/.nginx_port_tmp" 2>/dev/null
                
                # 申请证书（内部会调用 create_fake_website，会自动保存 sub.info）
                if get_acme_cert "$CERT_DOMAIN" "$protocol"; then
                    echo "$CERT_DOMAIN" > "$CFG/cert_domain"
                    # 确保订阅文件存在
                    generate_sub_files
                    rm -f "$CFG/.nginx_port_tmp"
                    return 0
                else
                    _warn "证书申请失败，使用自签证书"
                    gen_self_cert "$CERT_DOMAIN"
                    echo "$CERT_DOMAIN" > "$CFG/cert_domain"
                    rm -f "$CFG/.nginx_port_tmp"
                    return 1
                fi
            fi
        fi
    fi
    
    # 使用自签证书（仅对需要真实 TLS 证书的协议）
    # Reality 协议 (vless、vless-xhttp) 不需要证书，使用 TLS 指纹伪装
    if [[ "$protocol" != "vless" && "$protocol" != "vless-xhttp" ]]; then
        gen_self_cert "localhost"
    fi
    return 1
}

# SNI配置交互式询问
# 参数: $1=默认SNI (可选), $2=已申请的域名 (可选)
ask_sni_config() {
    local default_sni="${1:-$(gen_sni)}"
    local cert_domain="${2:-}"
    
    # 如果 Reality 协议已在 setup_cert_and_nginx 中确定使用真实域名，直接返回
    if [[ -n "$REALITY_SNI_CONFIRMED" ]]; then
        _ok "使用真实域名: $REALITY_SNI_CONFIRMED" >&2
        echo "$REALITY_SNI_CONFIRMED"
        unset REALITY_SNI_CONFIRMED  # 清除标记
        return 0
    fi
    
    # 如果有证书域名，检查是否是真实证书
    if [[ -n "$cert_domain" && -f "$CFG/certs/server.crt" ]]; then
        local is_real_cert=false
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]] || [[ "$issuer" == *"E1"* ]] || [[ "$issuer" == *"ZeroSSL"* ]] || [[ "$issuer" == *"Buypass"* ]]; then
            is_real_cert=true
        fi
        
        # 真实证书：直接使用证书域名，不询问
        if [[ "$is_real_cert" == "true" ]]; then
            _ok "使用证书域名: $cert_domain" >&2
            echo "$cert_domain"
            return 0
        fi
    fi
    
    echo "" >&2
    _line >&2
    echo -e "  ${W}SNI 配置${NC}" >&2
    
    # 生成一个真正的随机 SNI（用于"更隐蔽"选项）
    local random_sni=$(gen_sni)
    
    # 如果有证书域名（自签名证书），询问是否使用
    # 注意：自签名证书的域名没有实际意义，推荐使用随机 SNI
    if [[ -n "$cert_domain" ]]; then
        echo -e "  ${G}1${NC}) 使用随机SNI (${G}$random_sni${NC}) - 推荐" >&2
        echo -e "  ${G}2${NC}) 自定义SNI" >&2
        echo "" >&2
        
        local sni_choice=""
        while true; do
            read -rp "  请选择 [1-2，默认 1]: " sni_choice
            
            if [[ -z "$sni_choice" ]]; then
                sni_choice="1"
            fi
            
            if [[ "$sni_choice" == "1" ]]; then
                echo "$random_sni"
                return 0
            elif [[ "$sni_choice" == "2" ]]; then
                break
            else
                _err "无效选择: $sni_choice" >&2
                _warn "请输入 1 或 2" >&2
            fi
        done
    else
        # 没有证书域名时（如Reality协议），提供随机SNI和自定义选项
        echo -e "  ${G}1${NC}) 使用随机SNI (${G}$default_sni${NC}) - 推荐" >&2
        echo -e "  ${G}2${NC}) 自定义SNI" >&2
        echo "" >&2
        
        local sni_choice=""
        while true; do
            read -rp "  请选择 [1-2，默认 1]: " sni_choice
            
            if [[ -z "$sni_choice" ]]; then
                sni_choice="1"
            fi
            
            if [[ "$sni_choice" == "1" ]]; then
                echo "$default_sni"
                return 0
            elif [[ "$sni_choice" == "2" ]]; then
                break
            else
                _err "无效选择: $sni_choice" >&2
                _warn "请输入 1 或 2" >&2
            fi
        done
    fi
    
    # 自定义SNI输入
    while true; do
        echo "" >&2
        echo -e "  ${C}请输入自定义SNI域名 (回车使用随机SNI):${NC}" >&2
        read -rp "  SNI: " custom_sni
        
        if [[ -z "$custom_sni" ]]; then
            # 重新生成一个随机SNI
            local new_random_sni=$(gen_sni)
            echo -e "  ${G}使用随机SNI: $new_random_sni${NC}" >&2
            echo "$new_random_sni"
            return 0
        else
            # 基本域名格式验证
            if [[ "$custom_sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
                echo "$custom_sni"
                return 0
            else
                _err "无效SNI格式: $custom_sni" >&2
                _warn "SNI格式示例: www.example.com" >&2
            fi
        fi
    done
}

# 证书配置交互式询问
# 参数: $1=默认SNI (可选)
ask_cert_config() {
    local default_sni="${1:-bing.com}"
    local protocol="${2:-unknown}"
    
    # 检查是否已有 ACME 证书，如果有则直接复用
    if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
        local existing_domain=$(cat "$CFG/cert_domain")
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]]; then
            _ok "检测到现有 ACME 证书: $existing_domain，自动复用" >&2
            echo "$existing_domain"
            return 0
        fi
    fi
    
    # 所有提示信息输出到 stderr，避免污染返回值
    echo "" >&2
    _line >&2
    echo -e "  ${W}证书配置模式${NC}" >&2
    echo -e "  ${G}1${NC}) 使用真实域名 (推荐 - 自动申请 Let's Encrypt 证书)" >&2
    echo -e "  ${Y}2${NC}) 无域名 (使用自签证书 - 安全性较低，易被识别)" >&2
    echo "" >&2
    
    local cert_mode=""
    local domain=""
    local use_acme=false
    
    # 验证证书模式选择
    while true; do
        read -rp "  请选择 [1-2，默认 2]: " cert_mode
        
        # 如果用户直接回车，使用默认选项 2
        if [[ -z "$cert_mode" ]]; then
            cert_mode="2"
        fi
        
        # 验证输入是否为有效选项
        if [[ "$cert_mode" == "1" || "$cert_mode" == "2" ]]; then
            break
        else
            _err "无效选择: $cert_mode" >&2
            _warn "请输入 1 或 2" >&2
        fi
    done
    
    if [[ "$cert_mode" == "1" ]]; then
        # 域名输入循环，支持重新输入
        while true; do
            echo "" >&2
            echo -e "  ${C}提示: 域名必须已解析到本机 IP${NC}" >&2
            read -rp "  请输入你的域名: " domain
            
            if [[ -z "$domain" ]]; then
                _warn "域名不能为空，使用自签证书" >&2
                gen_self_cert "$default_sni" >&2
                domain=""
                break
            else
                # 基本域名格式验证
                if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
                    _err "无效域名格式: $domain" >&2
                    _warn "域名格式示例: example.com 或 sub.example.com" >&2
                    continue
                fi
                local cert_result
                get_acme_cert "$domain" "$protocol" >&2
                cert_result=$?
                
                if [[ $cert_result -eq 0 ]]; then
                    # ACME 成功
                    use_acme=true
                    echo "$domain" > "$CFG/cert_domain"
                    break
                elif [[ $cert_result -eq 2 ]]; then
                    # 需要重新输入域名，继续循环
                    continue
                else
                    # ACME 失败，使用自签证书，返回空字符串
                    gen_self_cert "$default_sni" >&2
                    domain=""
                    break
                fi
            fi
        done
    else
        # 无域名模式：使用自签证书，返回空字符串表示没有真实域名
        gen_self_cert "$default_sni" >&2
        domain=""
    fi
    
    # 只返回域名到 stdout（空字符串表示使用了自签证书）
    echo "$domain"
}

fix_selinux_context() {
    # 仅在 CentOS/RHEL 且 SELinux 启用时执行
    if [[ "$DISTRO" != "centos" ]]; then
        return 0
    fi
    
    # 检查 SELinux 是否启用
    if ! command -v getenforce &>/dev/null || [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
        return 0
    fi
    
    _info "配置 SELinux 上下文..."
    
    # 允许自定义端口
    if command -v semanage &>/dev/null; then
        local port="$1"
        if [[ -n "$port" ]]; then
            semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || true
            semanage port -a -t http_port_t -p udp "$port" 2>/dev/null || true
        fi
    fi
    
    # 恢复文件上下文
    if command -v restorecon &>/dev/null; then
        restorecon -Rv /usr/local/bin/xray /usr/local/bin/sing-box /usr/local/bin/snell-server \
            /usr/local/bin/snell-server-v5 /usr/local/bin/anytls-server /usr/local/bin/shadow-tls \
            /etc/vless-reality 2>/dev/null || true
    fi
    
    # 允许网络连接
    if command -v setsebool &>/dev/null; then
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi
}

# GitHub API 请求配置
readonly GITHUB_API_PER_PAGE=10
readonly VERSION_CACHE_DIR="/tmp/vless-version-cache"
readonly VERSION_CACHE_TTL=3600  # 缓存1小时
readonly SCRIPT_VERSION_CACHE_FILE="$VERSION_CACHE_DIR/.script_version"
readonly SNELL_RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md"
readonly SNELL_RELEASE_NOTES_ZH_URL="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell.md"
readonly SNELL_DEFAULT_VERSION="5.0.1"

# 获取文件修改时间戳（跨平台兼容）
_get_file_mtime() {
    local file="$1"
    [[ ! -f "$file" ]] && return 1

    # 尝试 Linux 格式
    if stat -c %Y "$file" 2>/dev/null; then
        return 0
    fi

    # 尝试 macOS/BSD 格式
    if stat -f %m "$file" 2>/dev/null; then
        return 0
    fi

    # 都失败则返回错误
    return 1
}

# 初始化版本缓存目录
_init_version_cache() {
    mkdir -p "$VERSION_CACHE_DIR" 2>/dev/null || true
}

_is_cache_fresh() {
    local cache_file="$1"
    [[ ! -f "$cache_file" ]] && return 1
    local cache_time
    cache_time=$(_get_file_mtime "$cache_file")
    [[ -z "$cache_time" ]] && return 1
    local current_time=$(date +%s)
    local age=$((current_time - cache_time))
    [[ $age -lt $VERSION_CACHE_TTL ]]
}

# 下载脚本到临时文件（回显临时文件路径）
_fetch_script_tmp() {
    local connect_timeout="${1:-10}"
    local max_time="${2:-}"
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null) || return 1
    if [[ -n "$max_time" ]]; then
        if ! curl -sL --connect-timeout "$connect_timeout" --max-time "$max_time" -o "$tmp_file" "$SCRIPT_RAW_URL"; then
            rm -f "$tmp_file"
            return 1
        fi
    else
        if ! curl -sL --connect-timeout "$connect_timeout" -o "$tmp_file" "$SCRIPT_RAW_URL"; then
            rm -f "$tmp_file"
            return 1
        fi
    fi
    echo "$tmp_file"
}

# 提取脚本版本号
_extract_script_version() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    grep -m1 '^readonly VERSION=' "$file" 2>/dev/null | cut -d'"' -f2
}

# 下载脚本到指定路径
_download_script_to() {
    local target="$1"
    local tmp_file
    tmp_file=$(_fetch_script_tmp 10) || return 1
    if mv "$tmp_file" "$target" 2>/dev/null; then
        return 0
    fi
    if cp -f "$tmp_file" "$target" 2>/dev/null; then
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

# 获取最新标签版本号（无缓存）
_get_latest_tag_version() {
    local repo="$1"
    local result version
    result=$(curl -sL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/$repo/tags?per_page=1" 2>/dev/null)
    [[ -z "$result" ]] && return 1
    version=$(echo "$result" | jq -r '.[0].name // empty' 2>/dev/null | sed 's/^v//')
    [[ -z "$version" ]] && return 1
    echo "$version"
}

# 获取脚本最新版本号（优先 release，失败则 tag，带缓存）
_get_latest_script_version() {
    local use_cache="${1:-true}"
    local force="${2:-false}"
    local version=""

    _init_version_cache
    if [[ "$force" != "true" ]] && _is_cache_fresh "$SCRIPT_VERSION_CACHE_FILE"; then
        cat "$SCRIPT_VERSION_CACHE_FILE" 2>/dev/null
        return 0
    fi

    if [[ "$force" != "true" && "$use_cache" == "true" ]]; then
        local cached_version
        cached_version=$(cat "$SCRIPT_VERSION_CACHE_FILE" 2>/dev/null)
        if [[ -n "$cached_version" ]]; then
            echo "$cached_version"
            return 0
        fi
    fi

    version=$(_get_latest_version "$SCRIPT_REPO" "false" "true" 2>/dev/null)
    if [[ -z "$version" ]]; then
        version=$(_get_latest_tag_version "$SCRIPT_REPO")
    fi
    [[ -z "$version" ]] && return 1

    echo "$version" > "$SCRIPT_VERSION_CACHE_FILE" 2>/dev/null || true
    echo "$version"
}

# 语义化版本比较（v1 > v2 返回 0）
_version_gt() {
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && return 1
    local IFS=.
    local i v1_arr=($v1) v2_arr=($v2)
    for ((i=0; i<${#v1_arr[@]} || i<${#v2_arr[@]}; i++)); do
        local n1=${v1_arr[i]:-0} n2=${v2_arr[i]:-0}
        ((n1 > n2)) && return 0
        ((n1 < n2)) && return 1
    done
    return 1
}

# 后台异步检查脚本版本（用于主菜单提示）
_check_script_update_async() {
    _init_version_cache
    if _is_cache_fresh "$SCRIPT_VERSION_CACHE_FILE"; then
        return 0
    fi
    (
        _get_latest_script_version "false" "true" >/dev/null 2>&1 || exit 0
    ) &
}

_has_script_update() {
    [[ -f "$SCRIPT_VERSION_CACHE_FILE" ]] || return 1
    local remote_ver
    remote_ver=$(cat "$SCRIPT_VERSION_CACHE_FILE" 2>/dev/null)
    [[ -z "$remote_ver" ]] && return 1
    _version_gt "$remote_ver" "$VERSION"
}

_get_script_update_info() {
    [[ -f "$SCRIPT_VERSION_CACHE_FILE" ]] || return 1
    local remote_ver
    remote_ver=$(cat "$SCRIPT_VERSION_CACHE_FILE" 2>/dev/null)
    if _version_gt "$remote_ver" "$VERSION"; then
        echo "$remote_ver"
    fi
}

_get_snell_versions_from_kb() {
    local limit="${1:-10}"
    local result versions
    result=$(curl -sL --connect-timeout 5 --max-time 10 "$SNELL_RELEASE_NOTES_URL" 2>/dev/null)
    [[ -z "$result" ]] && return 1
    versions=$(printf '%s\n' "$result" | sed -nE 's/^### v([0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?).*/\1/p' | head -n "$limit")
    [[ -z "$versions" ]] && return 1
    echo "$versions"
}

_get_snell_latest_version() {
    local use_cache="${1:-true}"
    local force="${2:-false}"
    _init_version_cache

    local cache_file="$VERSION_CACHE_DIR/surge-networks_snell"
    if [[ "$force" != "true" ]] && _is_cache_fresh "$cache_file"; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    if [[ "$force" != "true" && "$use_cache" == "true" ]]; then
        local cached_version
        if cached_version=$(_get_cached_version "surge-networks/snell"); then
            if _is_plain_version "$cached_version"; then
                echo "$cached_version"
                return 0
            fi
        fi
    fi

    local version
    version=$(_get_snell_versions_from_kb 1 | head -n 1)
    [[ -z "$version" ]] && version="$SNELL_DEFAULT_VERSION"
    _save_version_cache "surge-networks/snell" "$version"
    echo "$version"
}

_get_snell_changelog_from_kb() {
    local version="$1"
    local result block
    result=$(curl -sL --connect-timeout 5 --max-time 10 "$SNELL_RELEASE_NOTES_ZH_URL" 2>/dev/null)
    [[ -z "$result" ]] && return 1
    
    # BusyBox 兼容写法：使用 sed 替代复杂的 awk 正则
    # 匹配从 "### v版本号" 开始到下一个 "### v" 之间的内容
    block=$(printf '%s\n' "$result" | sed -n "/^### v${version}/,/^### v/p" | sed '1d;$d')
    [[ -z "$block" ]] && return 1
    
    # 过滤掉不需要的行
    block=$(printf '%s\n' "$block" | grep -v '^{%' | grep -v '^[[:space:]]*```' | grep -v '^[[:space:]]*$')
    [[ -z "$block" ]] && return 1
    echo "$block"
}

# 获取缓存的版本号
_get_cached_version() {
    local repo="$1"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')"

    # 检查缓存文件是否存在且未过期
    if [[ -f "$cache_file" ]]; then
        local cache_time
        cache_time=$(_get_file_mtime "$cache_file")
        if [[ -n "$cache_time" ]]; then
            local current_time=$(date +%s)
            local age=$((current_time - cache_time))

            if [[ $age -lt $VERSION_CACHE_TTL ]]; then
                cat "$cache_file"
                return 0
            fi
        fi
    fi
    return 1
}

# 获取缓存的测试版版本号
_get_cached_prerelease_version() {
    local repo="$1"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_prerelease"

    # 检查缓存文件是否存在且未过期
    if [[ -f "$cache_file" ]]; then
        local cache_time
        cache_time=$(_get_file_mtime "$cache_file")
        if [[ -n "$cache_time" ]]; then
            local current_time=$(date +%s)
            local age=$((current_time - cache_time))

            if [[ $age -lt $VERSION_CACHE_TTL ]]; then
                cat "$cache_file"
                return 0
            fi
        fi
    fi
    return 1
}

# 强制获取缓存版本（忽略过期时间，用于网络失败时的降级）
_force_get_cached_version() {
    local repo="$1"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')"
    
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi
    return 1
}

# 强制获取测试版缓存（忽略过期时间，用于网络失败时的降级）
_force_get_cached_prerelease_version() {
    local repo="$1"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_prerelease"
    
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi
    return 1
}

# 获取缓存版本（优先新鲜缓存，无则回退旧缓存）
_get_cached_version_with_fallback() {
    local repo="$1"
    local version=""
    version=$(_get_cached_version "$repo" 2>/dev/null)
    [[ -z "$version" ]] && version=$(_force_get_cached_version "$repo" 2>/dev/null)
    [[ -n "$version" ]] && printf '%s' "$version"
}

# 获取缓存测试版版本（优先新鲜缓存，无则回退旧缓存）
_get_cached_prerelease_with_fallback() {
    local repo="$1"
    local version=""
    version=$(_get_cached_prerelease_version "$repo" 2>/dev/null)
    [[ -z "$version" ]] && version=$(_force_get_cached_prerelease_version "$repo" 2>/dev/null)
    [[ -n "$version" ]] && printf '%s' "$version"
}

# 保存版本号到缓存
_save_version_cache() {
    local repo="$1"
    local version="$2"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')"
    echo "$version" > "$cache_file" 2>/dev/null || true
}

# 后台异步更新版本缓存
_update_version_cache_async() {
    local repo="$1"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')"
    local unavailable_file="${cache_file}_unavailable"
    if _is_cache_fresh "$cache_file"; then
        return 0
    fi
    if [[ "$repo" == "surge-networks/snell" ]]; then
        (
            local version
            version=$(_get_snell_versions_from_kb 1 | head -n 1)
            rm -f "$unavailable_file" 2>/dev/null || true
            [[ -n "$version" ]] && _save_version_cache "$repo" "$version"
        ) &
        return 0
    fi
    (
        local version
        local response http_code body
        response=$(curl -sL --connect-timeout 5 --max-time 10 -w "\n%{http_code}" "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
        http_code=$(printf '%s' "$response" | tail -n 1)
        body=$(printf '%s' "$response" | sed '$d')
        if [[ "$http_code" == "404" ]]; then
            echo "not_found" > "$unavailable_file" 2>/dev/null || true
            return 0
        fi
        version=$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
        if [[ -n "$version" ]]; then
            rm -f "$unavailable_file" 2>/dev/null || true
            _save_version_cache "$repo" "$version"
        fi
    ) &
}

# 后台异步更新测试版版本缓存
_update_prerelease_cache_async() {
    local repo="$1"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_prerelease"
    local unavailable_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_unavailable"
    if _is_cache_fresh "$cache_file"; then
        return 0
    fi
    if [[ "$repo" == "surge-networks/snell" ]]; then
        echo "无" > "$cache_file" 2>/dev/null || true
        rm -f "$unavailable_file" 2>/dev/null || true
        return 0
    fi
    (
        local version
        local response http_code body
        response=$(curl -sL --connect-timeout 5 --max-time 10 -w "\n%{http_code}" "https://api.github.com/repos/$repo/releases?per_page=$GITHUB_API_PER_PAGE" 2>/dev/null)
        http_code=$(printf '%s' "$response" | tail -n 1)
        body=$(printf '%s' "$response" | sed '$d')
        if [[ "$http_code" == "404" ]]; then
            echo "not_found" > "$unavailable_file" 2>/dev/null || true
            return 0
        fi
        version=$(printf '%s' "$body" | jq -r '[.[] | select(.prerelease == true)][0].tag_name // empty' 2>/dev/null | sed 's/^v//')
        if [[ -n "$version" ]]; then
            rm -f "$unavailable_file" 2>/dev/null || true
            echo "$version" > "$cache_file" 2>/dev/null || true
        fi
    ) &
}

# 后台异步更新所有版本缓存（稳定版+测试版，一次请求）
_update_all_versions_async() {
    local repo="$1"
    local stable_cache="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')"
    local prerelease_cache="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_prerelease"
    if _is_cache_fresh "$stable_cache" && _is_cache_fresh "$prerelease_cache"; then
        return 0
    fi
    (
        # 一次请求获取最近10个版本（足够覆盖最新稳定版和测试版）
        local releases
        releases=$(curl -sL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/$repo/releases?per_page=10" 2>/dev/null)
        if [[ -n "$releases" ]]; then
            # 提取稳定版（第一个非prerelease）
            local stable_version
            stable_version=$(echo "$releases" | jq -r '[.[] | select(.prerelease == false)][0].tag_name // empty' 2>/dev/null | sed 's/^v//')
            [[ -n "$stable_version" ]] && echo "$stable_version" > "$stable_cache" 2>/dev/null

            # 提取测试版（第一个prerelease）
            local prerelease_version
            prerelease_version=$(echo "$releases" | jq -r '[.[] | select(.prerelease == true)][0].tag_name // empty' 2>/dev/null | sed 's/^v//')
            [[ -n "$prerelease_version" ]] && echo "$prerelease_version" > "$prerelease_cache" 2>/dev/null
        fi
    ) &
}

# 获取 GitHub 最新版本号 (带缓存)
_get_latest_version() {
    local repo="$1"
    local use_cache="${2:-true}"
    local force="${3:-false}"

    # 初始化缓存目录
    _init_version_cache

    if [[ "$repo" == "surge-networks/snell" ]]; then
        _get_snell_latest_version "$use_cache" "$force"
        return $?
    fi

    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')"
    if [[ "$force" != "true" ]] && _is_cache_fresh "$cache_file"; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    # 如果启用缓存,先尝试从缓存读取
    if [[ "$force" != "true" && "$use_cache" == "true" ]]; then
        local cached_version
        if cached_version=$(_get_cached_version "$repo"); then
            echo "$cached_version"
            return 0
        fi
    fi

    # 缓存未命中或禁用缓存,执行网络请求
    local result curl_exit
    result=$(curl -sL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)
    curl_exit=$?
    if [[ $curl_exit -ne 0 ]]; then
        return 1
    fi
    local version
    version=$(echo "$result" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    local jq_exit=$?
    if [[ -z "$version" ]]; then
        # 调试：输出 jq 解析失败原因
        if [[ $jq_exit -ne 0 ]]; then
            echo "$result" | head -c 200 >&2
            echo "" >&2
        fi
        return 1
    fi

    # 保存到缓存
    _save_version_cache "$repo" "$version"
    echo "$version"
}

# 后台异步检查版本更新（用于菜单刷新）
_check_version_updates_async() {
    local xray_ver="$1"
    local singbox_ver="$2"
    local update_flag_file="$VERSION_CACHE_DIR/.update_available"

    # 清除旧的更新标记
    rm -f "$update_flag_file" "${update_flag_file}.done" 2>/dev/null

    (
        local has_update=false
        local xray_cached="" singbox_cached=""

        # 优先从缓存获取最新版本号（立即可用）
        if [[ "$xray_ver" != "未安装" ]] && [[ "$xray_ver" != "未知" ]]; then
            xray_cached=$(_get_cached_version "XTLS/Xray-core" 2>/dev/null)
            if [[ -n "$xray_cached" ]] && [[ "$xray_ver" != "$xray_cached" ]]; then
                has_update=true
                echo "xray:$xray_cached" >> "$update_flag_file"
            fi
        fi

        if [[ "$singbox_ver" != "未安装" ]] && [[ "$singbox_ver" != "未知" ]]; then
            singbox_cached=$(_get_cached_version "SagerNet/sing-box" 2>/dev/null)
            if [[ -n "$singbox_cached" ]] && [[ "$singbox_ver" != "$singbox_cached" ]]; then
                has_update=true
                echo "singbox:$singbox_cached" >> "$update_flag_file"
            fi
        fi

        # 如果缓存中有更新，立即标记完成（极速显示）
        if [[ "$has_update" == "true" ]]; then
            touch "${update_flag_file}.done"
        fi

        # 然后后台异步更新缓存（为下次访问准备）
        if [[ "$xray_ver" != "未安装" ]] && [[ "$xray_ver" != "未知" ]]; then
            _update_version_cache_async "XTLS/Xray-core"
        fi
        if [[ "$singbox_ver" != "未安装" ]] && [[ "$singbox_ver" != "未知" ]]; then
            _update_version_cache_async "SagerNet/sing-box"
        fi
    ) &
}

# 检查是否有版本更新（非阻塞）
_has_version_updates() {
    local update_flag_file="$VERSION_CACHE_DIR/.update_available"
    [[ -f "${update_flag_file}.done" ]]
}

# 获取版本更新信息
_get_version_update_info() {
    local core="$1"  # xray 或 singbox
    local update_flag_file="$VERSION_CACHE_DIR/.update_available"

    if [[ -f "$update_flag_file" ]]; then
        grep "^${core}:" "$update_flag_file" 2>/dev/null | cut -d':' -f2
    fi
}

# 获取 GitHub 最新测试版版本号 (pre-release，带缓存)
_get_latest_prerelease_version() {
    local repo="$1"
    local use_cache="${2:-true}"
    local cache_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_prerelease"
    local force="${3:-false}"

    # 初始化缓存目录
    _init_version_cache

    if [[ "$repo" == "surge-networks/snell" ]]; then
        echo "无" > "$cache_file" 2>/dev/null || true
        echo "无"
        return 0
    fi

    if [[ "$force" != "true" ]] && _is_cache_fresh "$cache_file"; then
        cat "$cache_file" 2>/dev/null
        return 0
    fi

    # 如果启用缓存,先尝试从缓存读取
    if [[ "$force" != "true" && "$use_cache" == "true" ]]; then
        local cached_version
        if cached_version=$(_get_cached_prerelease_version "$repo"); then
            echo "$cached_version"
            return 0
        fi
    fi

    # 缓存未命中,执行网络请求
    local result
    result=$(curl -sL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/$repo/releases?per_page=$GITHUB_API_PER_PAGE" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        # 网络请求失败时静默返回（不显示错误）
        return 1
    fi
    local version
    version=$(echo "$result" | jq -r '[.[] | select(.prerelease == true)][0].tag_name // empty' 2>/dev/null | sed 's/^v//')
    if [[ -z "$version" ]]; then
        # 未找到测试版时静默返回（可能该项目没有测试版）
        return 1
    fi

    # 保存到缓存
    echo "$version" > "$cache_file" 2>/dev/null || true
    echo "$version"
}

# 获取最近版本列表
_get_release_versions() {
    local repo="$1" limit="${2:-10}" mode="${3:-stable}"
    local filter
    # 统一空 mode 为 "all"
    [[ -z "$mode" || "$mode" == "" ]] && mode="all"
    local repo_safe cache_file
    repo_safe=$(echo "$repo" | tr '/' '_')
    cache_file="$VERSION_CACHE_DIR/${repo_safe}_releases_${mode}"
    if [[ "$repo" == "surge-networks/snell" ]] && _is_cache_fresh "$cache_file"; then
        local cached_versions
        cached_versions=$(cat "$cache_file" 2>/dev/null)
        if [[ -n "$cached_versions" ]]; then
            echo "$cached_versions"
            return 0
        fi
    fi
    if _is_cache_fresh "$cache_file"; then
        local cached_versions cached_count
        cached_versions=$(cat "$cache_file" 2>/dev/null)
        cached_count=$(printf '%s\n' "$cached_versions" | grep -c .)
        if [[ "$cached_count" -ge "$limit" ]]; then
            echo "$cached_versions"
            return 0
        fi
    fi
    if [[ "$repo" == "surge-networks/snell" ]]; then
        local versions
        if [[ "$mode" == "prerelease" || "$mode" == "test" || "$mode" == "beta" ]]; then
            _err "Snell 无预发布版本"
            return 1
        fi
        versions=$(_get_snell_versions_from_kb "$limit")
        [[ -z "$versions" ]] && versions="$SNELL_DEFAULT_VERSION"
        case "$mode" in
            prerelease|test|beta) versions=$(printf '%s\n' "$versions" | grep -E '-' || true) ;;
            stable) versions=$(printf '%s\n' "$versions" | grep -v -E '-' || true) ;;
        esac
        if [[ -z "$versions" ]]; then
            _err "未找到符合条件的版本"
            return 1
        fi
        echo "$versions" > "$cache_file" 2>/dev/null || true
        echo "$versions"
        return 0
    fi
    case "$mode" in
        prerelease|test|beta) filter='[.[] | select(.prerelease == true)]' ;;
        stable) filter='[.[] | select(.prerelease == false)]' ;;
        all|"") filter='[.[]]' ;;
        *) filter='[.[]]' ;;
    esac
    local result
    result=$(curl -sL --max-time 30 --connect-timeout 10 "https://api.github.com/repos/$repo/releases?per_page=$GITHUB_API_PER_PAGE" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        _err "网络连接失败，无法访问 GitHub API"
        return 1
    fi
    if printf '%s' "$result" | grep -qiE 'API rate limit exceeded|rate limit'; then
        _warn "API 限流，尝试从缓存获取版本列表..."
        # 尝试从缓存读取版本列表
        local fallback_files fallback
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return 0
        fi

        # 降级策略：尝试其他缓存文件
        fallback_files=(
            "$VERSION_CACHE_DIR/${repo_safe}_releases_all"
            "$VERSION_CACHE_DIR/${repo_safe}_releases_stable"
            "$VERSION_CACHE_DIR/${repo_safe}_releases_prerelease"
        )
        for fallback in "${fallback_files[@]}"; do
            if [[ -f "$fallback" ]]; then
                _warn "使用降级缓存: $(basename "$fallback")"
                cat "$fallback"
                return 0
            fi
        done

        _err "缓存未找到，无法获取版本列表"
        _warn "建议：等待 API 限流解除后重试，或先执行一次正常更新以创建缓存"
        return 1
    fi
    local jq_output jq_status versions
    jq_output=$(printf '%s' "$result" | jq -r "$filter | .[0:$limit][] | .tag_name // empty" 2>/dev/null)
    jq_status=$?
    if [[ $jq_status -ne 0 ]]; then
        local snippet
        snippet=$(printf '%s' "$result" | head -c 200)
        _err "JSON 解析失败，响应片段: $snippet"
        return 1
    fi
    versions=$(printf '%s\n' "$jq_output" | sed 's/^v//')
    if [[ -z "$versions" ]]; then
        _err "未找到符合条件的版本"
        return 1
    fi
    # 保存到缓存供限流时使用
    echo "$versions" > "$cache_file" 2>/dev/null || true

    echo "$versions"
}

# 获取版本变更日志
_get_release_changelog() {
    local repo="$1" version="$2"
    if [[ "$repo" == "surge-networks/snell" ]]; then
        _get_snell_changelog_from_kb "$version"
        return $?
    fi
    local tag="v$version"
    local result
    result=$(curl -sL "https://api.github.com/repos/$repo/releases/tags/$tag" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    echo "$result" | jq -r '.body // empty' 2>/dev/null
}

# 展示变更日志 (简化版)
_show_changelog_summary() {
    local repo="$1" version="$2" max_lines="${3:-10}"
    local changelog
    changelog=$(_get_release_changelog "$repo" "$version")
    if [[ -z "$changelog" ]]; then
        echo "  (无变更日志)" >&2
        return
    fi

    echo -e "\n  ${C}变更摘要 (v${version})${NC}" >&2
    _line
    echo "$changelog" | head -n "$max_lines" | while IFS= read -r line; do
        # 简化 Markdown 格式
        line=$(echo "$line" | sed 's/^### /  ▸ /; s/^## /▸ /; s/^\* /  • /; s/^- /  • /')
        echo "$line" >&2
    done
    _line
}

# 架构映射 (减少重复代码)
# 用法: local mapped=$(_map_arch "amd64:arm64:armv7")
_map_arch() {
    local mapping="$1" arch=$(uname -m)
    local x86 arm64 arm7
    IFS=':' read -r x86 arm64 arm7 <<< "$mapping"
    case $arch in
        x86_64)  echo "$x86" ;;
        aarch64) echo "$arm64" ;;
        armv7l)  echo "$arm7" ;;
        *) return 1 ;;
    esac
}

# 通用二进制下载安装函数
_install_binary() {
    local name="$1" repo="$2" url_pattern="$3" extract_cmd="$4"
    local channel="${5:-stable}" force="${6:-false}" version_override="${7:-}"
    local exists=false action="安装" channel_label="稳定版"
    
    if check_cmd "$name"; then
        exists=true
        [[ "$force" != "true" ]] && { _ok "$name 已安装"; return 0; }
    fi
    
    [[ "$exists" == "true" ]] && action="更新"
    [[ "$channel" == "prerelease" || "$channel" == "test" || "$channel" == "beta" ]] && channel_label="测试版"
    
    local version=""
    if [[ -n "$version_override" ]]; then
        _info "$action $name (版本 v$version_override)..."
        version="$version_override"
    else
        _info "$action $name (获取最新${channel_label})..."
        # 实际安装/更新时优先使用缓存（1小时内有效），减少 API 请求频率
        if [[ "$channel" == "prerelease" || "$channel" == "test" || "$channel" == "beta" ]]; then
            version=$(_get_latest_prerelease_version "$repo" "true")
        else
            version=$(_get_latest_version "$repo" "true")
        fi

        # 如果获取失败（缓存过期且网络失败），尝试强制使用旧缓存
        if [[ -z "$version" ]]; then
            local cached_version=""
            if [[ "$channel" == "prerelease" || "$channel" == "test" || "$channel" == "beta" ]]; then
                cached_version=$(_force_get_cached_prerelease_version "$repo" 2>/dev/null)
            else
                cached_version=$(_force_get_cached_version "$repo" 2>/dev/null)
            fi
            if [[ -n "$cached_version" ]]; then
                _warn "获取最新${channel_label}失败，使用缓存版本 v$cached_version"
                version="$cached_version"
            fi
        fi
    fi
    if [[ -z "$version" ]]; then
        _err "获取 $name 版本失败"
        _warn "请检查网络/证书/DNS，并确保系统依赖已安装"
        return 1
    fi

    # 验证版本号，防止命令注入
    if [[ ! "$version" =~ ^[0-9A-Za-z._-]+$ ]]; then
        _err "无效的版本号格式: $version"
        return 1
    fi

    local arch=$(uname -m)
    local tmp
    tmp=$(mktemp -d) || { _err "创建临时目录失败"; return 1; }

    # 安全地构建 URL（避免 eval）
    local url="${url_pattern//\$version/$version}"
    url="${url//\$\{version\}/$version}"
    url="${url//\$\{xarch\}/$xarch}"
    url="${url//\$\{sarch\}/$sarch}"
    url="${url//\$\{aarch\}/$aarch}"

    # 下载并验证
    if ! curl -fsSL --connect-timeout 60 --retry 2 -o "$tmp/pkg" "$url"; then
        rm -rf "$tmp"
        _err "下载 $name 失败: $url"
        return 1
    fi

    # 执行解压安装（仍需 eval 但在受控环境）
    if ! eval "$extract_cmd" 2>/dev/null; then
        rm -rf "$tmp"
        _err "安装 $name 失败（解压或文件操作错误）"
        return 1
    fi

    rm -rf "$tmp"
    _ok "$name v$version 已安装"
    return 0
}

install_xray() {
    local channel="${1:-stable}"
    local force="${2:-false}"
    local version_override="${3:-}"
    local xarch=$(_map_arch "64:arm64-v8a:arm32-v7a") || { _err "不支持的架构"; return 1; }
    # Alpine 需要安装 gcompat 兼容层来运行 glibc 编译的二进制
    if [[ "$DISTRO" == "alpine" ]]; then
        apk add --no-cache gcompat libc6-compat &>/dev/null
    fi
    _install_binary "xray" "XTLS/Xray-core" \
        'https://github.com/XTLS/Xray-core/releases/download/v$version/Xray-linux-${xarch}.zip' \
        'unzip -oq "$tmp/pkg" -d "$tmp/" && install -m 755 "$tmp/xray" /usr/local/bin/xray && mkdir -p /usr/local/share/xray && cp "$tmp"/*.dat /usr/local/share/xray/ 2>/dev/null; fix_selinux_context' \
        "$channel" "$force" "$version_override"
}

#═══════════════════════════════════════════════════════════════════════════════
# Sing-box 核心 - 统一管理 UDP/QUIC 协议 (Hy2/TUIC)
#═══════════════════════════════════════════════════════════════════════════════

install_singbox() {
    local channel="${1:-stable}"
    local force="${2:-false}"
    local version_override="${3:-}"
    local sarch=$(_map_arch "amd64:arm64:armv7") || { _err "不支持的架构"; return 1; }
    # Alpine 需要安装 gcompat 兼容层来运行 glibc 编译的二进制
    if [[ "$DISTRO" == "alpine" ]]; then
        apk add --no-cache gcompat libc6-compat &>/dev/null
    fi
    _install_binary "sing-box" "SagerNet/sing-box" \
        'https://github.com/SagerNet/sing-box/releases/download/v$version/sing-box-$version-linux-${sarch}.tar.gz' \
        'tar -xzf "$tmp/pkg" -C "$tmp/" && install -m 755 "$(find "$tmp" -name sing-box -type f | head -1)" /usr/local/bin/sing-box' \
        "$channel" "$force" "$version_override"
}

#═══════════════════════════════════════════════════════════════════════════════
# 核心更新 (Xray/Sing-box)
#═══════════════════════════════════════════════════════════════════════════════

_core_channel_label() {
    local channel="$1"
    case "$channel" in
        prerelease|test|beta) echo "测试版" ;;
        stable) echo "稳定版" ;;
        "") echo "指定版本" ;;
        *) echo "全部版本" ;;
    esac
}

# Snell v5 版本获取
_get_snell_v5_version() {
    local version="未知"

    if check_cmd snell-server-v5; then
        local output status
        output=$(snell-server-v5 --version 2>&1)
        status=$?
        if [[ $status -ne 0 ]]; then
            version="未安装"
        else
            version=$(printf '%s\n' "$output" | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' | head -n 1)
            [[ -z "$version" ]] && version="未知"
        fi
    else
        version="未安装"
    fi

    echo "$version"
}

# 公共方法：核心版本获取与状态判断
_get_core_version() {
    local core="$1"
    local version="未知"

    case "$core" in
        xray)
            if check_cmd xray; then
                version=$(xray version 2>/dev/null | head -n 1 | awk '{print $2}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
                [[ -z "$version" ]] && version="未知"
            else
                version="未安装"
            fi
            ;;
        sing-box)
            if check_cmd sing-box; then
                version=$(sing-box version 2>/dev/null | awk '{print $3}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?')
                [[ -z "$version" ]] && version="未知"
            else
                version="未安装"
            fi
            ;;
        snell-server-v5)
            version=$(_get_snell_v5_version)
            ;;
        snellv5|snell-v5)
            version=$(_get_snell_v5_version)
            ;;
        *)
            version="未知"
            ;;
    esac

    echo "$version"
}

_is_version_unknown() {
    [[ "$1" == "获取中..." || "$1" == "不可获取" || "$1" == "无" ]]
}

_is_plain_version() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)+$ ]]
}

_get_version_status() {
    local current="$1"
    local latest_stable="$2"
    local latest_prerelease="$3"
    local target=""

    if [[ "$current" == *"-"* ]]; then
        target="$latest_prerelease"
    else
        target="$latest_stable"
    fi

    if [[ -z "$target" ]] || _is_version_unknown "$target"; then
        echo ""
        return 0
    fi

    if [[ "$current" == "$target" ]]; then
        # 最新版本不显示标识
        echo ""
    else
        # [可更新] 使用亮橙色，显示后恢复默认样式
        echo " \e[22;93m[可更新]\e[0m\e[2m"
    fi
}

_get_core_version_with_status() {
    local core="$1"
    local repo="$2"
    local current latest_stable latest_prerelease prerelease_cache status

    current=$(_get_core_version "$core")
    if [[ "$current" == "未安装" || "$current" == "未知" ]]; then
        echo "$current"
        return 0
    fi

    latest_stable=$(_get_cached_version "$repo" 2>/dev/null)
    [[ -z "$latest_stable" ]] && latest_stable="获取中..."

    prerelease_cache="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_prerelease"
    if [[ -f "$prerelease_cache" ]]; then
        latest_prerelease=$(cat "$prerelease_cache" 2>/dev/null)
    fi
    [[ -z "$latest_prerelease" ]] && latest_prerelease="获取中..."

    status=$(_get_version_status "$current" "$latest_stable" "$latest_prerelease")
    echo "${current}${status}"
}

_confirm_core_update() {
    local core="$1" channel="$2"
    local channel_label=$(_core_channel_label "$channel")
    local risk_desc=""

    # 根据 channel 生成不同的风险评估
    if [[ "$channel" == "prerelease" || "$channel" == "test" || "$channel" == "beta" ]]; then
        risk_desc="测试版可能不稳定，更新失败可能导致服务不可用"
    else
        risk_desc="更新失败可能导致服务不可用，建议先备份配置"
    fi

    echo "⚠️ 危险操作检测！"
    echo "操作类型：更新 ${core} 内核（${channel_label}）"
    echo "影响范围：${core} 二进制与相关服务，更新后需重启服务"
    echo "风险评估：${risk_desc}"
    echo ""
    read -rp "请确认是否继续？[y/N]: " confirm
    case "${confirm,,}" in
        y|yes) return 0 ;;
        *) _warn "已取消"; return 1 ;;
    esac
}

_confirm_core_update_version() {
    local core="$1" channel="$2" version="$3"
    local channel_label=$(_core_channel_label "$channel")
    local risk_desc=""
    local label=""

    # 根据 channel 生成不同的风险评估
    if [[ "$channel" == "prerelease" || "$channel" == "test" || "$channel" == "beta" ]]; then
        risk_desc="测试版可能不稳定，更新失败可能导致服务不可用"
    else
        risk_desc="更新失败可能导致服务不可用，建议先备份配置"
    fi
    if [[ -n "$channel" && -n "$channel_label" ]]; then
        label="${channel_label} "
    fi

    echo "⚠️ 危险操作检测！"
    echo "操作类型：更新 ${core} 内核（${label}v${version}）"
    echo "影响范围：${core} 二进制与相关服务，更新后需重启服务"
    echo "风险评估：${risk_desc}"
    echo ""
    read -rp "请确认是否继续？[y/N]: " confirm
    case "${confirm,,}" in
        y|yes) return 0 ;;
        *) _warn "已取消"; return 1 ;;
    esac
}

_select_version_from_list() {
    local repo="$1" channel="$2" name="$3" limit="${4:-10}"
    local channel_label=$(_core_channel_label "$channel")

    _check_core_update_deps || return 1

    # 初始化缓存目录
    _init_version_cache

    # 获取当前版本
    local current_ver="未知"
    case "$name" in
        Xray) check_cmd xray && current_ver=$(xray version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) ;;
        Sing-box) check_cmd sing-box && current_ver=$(sing-box version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -n 1) ;;
        "Snell v5") current_ver=$(_get_snell_v5_version) ;;
    esac
    if [[ "$current_ver" != "未知" && "$current_ver" != "未安装" ]]; then
        local ver_only
        ver_only=$(printf '%s' "$current_ver" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -n 1)
        [[ -n "$ver_only" ]] && current_ver="$ver_only"
    fi

    local versions
    versions=$(_get_release_versions "$repo" "$limit" "$channel")
    if [[ $? -ne 0 ]] || [[ -z "$versions" ]]; then
        _err "获取 ${name} 版本列表失败"
        return 1
    fi

    echo -e "  ${C}可选版本 (${channel_label})${NC}" >&2
    echo -e "  ${D}当前版本: ${current_ver}${NC}" >&2
    _line
    local i=1
    local -a list=()
    while read -r v; do
        [[ -z "$v" ]] && continue
        local marker=""
        [[ "$v" == "$current_ver" ]] && marker=" ${Y}[当前]${NC}"
        echo -e "  ${G}$i${NC}) v$v$marker" >&2
        list[$i]="$v"
        ((i++))
    done <<< "$versions"
    _line
    echo -e "  ${D}提示: 输入编号、版本号 (如 1.8.24) 或 0 返回${NC}" >&2
    read -rp "  请选择: " choice
    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        [[ -z "$choice" ]] && _warn "已取消"
        return 2
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local selected="${list[$choice]}"
        if [[ -z "$selected" ]]; then
            _err "无效选择: 编号超出范围 (1-$((i-1)))"
            return 1
        fi
        echo "$selected"
    else
        # 移除可能的 v 前缀
        echo "${choice#v}"
    fi
    return 0
}

# 选择可用的备份目录
_get_core_backup_dir() {
    local -a candidates=(
        "/var/backups/vless-cores"
        "/usr/local/var/backups/vless-cores"
    )
    if [[ -n "$HOME" ]]; then
        candidates+=("$HOME/.vless-backups/vless-cores")
    fi

    local dir
    for dir in "${candidates[@]}"; do
        if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
            echo "$dir"
            return 0
        fi
    done

    return 1
}

# 备份核心二进制文件
_backup_core_binary() {
    local binary_name="$1"
    local binary_path="/usr/local/bin/$binary_name"
    [[ ! -f "$binary_path" ]] && return 0

    local backup_dir
    if ! backup_dir=$(_get_core_backup_dir); then
        _warn "创建备份目录失败"
        return 1
    fi

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local current_ver
    case "$binary_name" in
        xray) current_ver=$(xray version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) ;;
        sing-box) current_ver=$(sing-box version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -n 1) ;;
        snell-server-v5) current_ver=$(_get_snell_v5_version) ;;
    esac
    [[ -z "$current_ver" ]] && current_ver="unknown"

    local backup_name="${binary_name}_${current_ver}_${timestamp}"
    local cp_err
    cp_err=$(cp "$binary_path" "$backup_dir/$backup_name" 2>&1)
    if [[ $? -eq 0 ]]; then
        chmod 755 "$backup_dir/$backup_name"
        _info "已备份: $backup_name"
        echo "$backup_dir/$backup_name"
        return 0
    fi
    cp_err=${cp_err//$'\n'/ }
    _warn "备份失败${cp_err:+: $cp_err}"
    return 1
}

# 回滚核心二进制文件
_rollback_core_binary() {
    local binary_name="$1" backup_file="$2"
    [[ ! -f "$backup_file" ]] && { _err "备份文件不存在: $backup_file"; return 1; }

    local binary_path="/usr/local/bin/$binary_name"
    if cp "$backup_file" "$binary_path" 2>/dev/null; then
        chmod 755 "$binary_path"
        _ok "已回滚至备份版本"
        return 0
    fi
    _err "回滚失败"
    return 1
}

_update_core_to_version() {
    local core="$1" channel="$2" version="$3" service="$4" install_func="$5"
    _check_core_update_deps || return 1
    _confirm_core_update_version "$core" "$channel" "$version" || return 1

    local binary_name
    case "$core" in
        Xray) binary_name="xray" ;;
        Sing-box) binary_name="sing-box" ;;
        "Snell v5") binary_name="snell-server-v5" ;;
        *) _err "未知核心: $core"; return 1 ;;
    esac

    # 备份当前版本
    local backup_file
    if ! backup_file=$(_backup_core_binary "$binary_name"); then
        # 备份失败但继续更新（可能是首次安装）
        _warn "备份失败，继续更新（无法回滚）"
        backup_file=""
    fi

    local need_restart=false
    if svc status "$service" 2>/dev/null; then
        need_restart=true
        if ! svc stop "$service" 2>/dev/null; then
            _err "停止服务失败，为避免风险已终止更新"
            return 1
        fi
        _info "服务已停止"
    fi

    # 执行更新
    if "$install_func" "$channel" "true" "$version"; then
        _ok "${core} 内核已更新 (v${version})"

        # 重启服务
        if [[ "$need_restart" == "true" ]]; then
            _info "重新启动服务..."
            if ! svc start "$service" 2>/dev/null; then
                _err "服务启动失败，请手动检查: svc start $service"
                return 1
            fi
            _ok "服务已启动"
        fi

        # 展示变更日志
        case "$core" in
            Xray) _show_changelog_summary "XTLS/Xray-core" "$version" 8 ;;
            Sing-box) _show_changelog_summary "SagerNet/sing-box" "$version" 8 ;;
            "Snell v5") _show_changelog_summary "surge-networks/snell" "$version" 8 ;;
        esac

        # 清理旧备份 (保留最近 3 个)
        if [[ -n "$backup_file" ]]; then
            local backup_dir=$(dirname "$backup_file")
            ls -t "$backup_dir/${binary_name}_"* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
        fi
        return 0
    fi

    # 更新失败，尝试回滚
    _err "${core} 内核更新失败"
    if [[ -n "$backup_file" ]]; then
        _warn "尝试回滚到之前版本..."
        if ! _rollback_core_binary "$binary_name" "$backup_file"; then
            _err "回滚失败，请手动恢复: cp $backup_file /usr/local/bin/$binary_name"
        fi
    fi

    # 尝试恢复服务
    if [[ "$need_restart" == "true" ]]; then
        _warn "尝试恢复服务..."
        if svc start "$service" 2>/dev/null; then
            _ok "服务已恢复"
        else
            _err "服务恢复失败，请手动启动: svc start $service"
        fi
    fi
    return 1
}

# 后台异步更新核心版本信息（用于版本管理菜单）
_update_core_versions_async() {
    local version_info_file="$VERSION_CACHE_DIR/.core_version_info"

    (
        local xray_latest="" singbox_latest="" snell_latest=""

        # 优先从缓存获取稳定版
        xray_latest=$(_get_cached_version "XTLS/Xray-core" 2>/dev/null)
        singbox_latest=$(_get_cached_version "SagerNet/sing-box" 2>/dev/null)
        snell_latest=$(_get_cached_version "surge-networks/snell" 2>/dev/null)

        # 写入版本信息
        {
            echo "xray_latest=$xray_latest"
            echo "singbox_latest=$singbox_latest"
            echo "snell_latest=$snell_latest"
        } > "$version_info_file" 2>/dev/null

        # 标记完成
        touch "${version_info_file}.done" 2>/dev/null

        # 后台异步更新稳定版缓存
        _update_version_cache_async "XTLS/Xray-core"
        _update_version_cache_async "SagerNet/sing-box"
        _update_version_cache_async "surge-networks/snell"

        # 后台异步更新测试版缓存（使用专用函数）
        # 注意：这些函数内部已经有缓存机制，这里只是触发后台更新
        (
            _get_latest_prerelease_version "XTLS/Xray-core" "false" >/dev/null 2>&1
            _get_latest_prerelease_version "SagerNet/sing-box" "false" >/dev/null 2>&1
            _get_latest_prerelease_version "surge-networks/snell" "false" >/dev/null 2>&1
        ) &
    ) &
}

_refresh_core_versions_now() {
    _info "重新获取版本..."
    _get_latest_version "XTLS/Xray-core" "false" "true" >/dev/null 2>&1
    _get_latest_prerelease_version "XTLS/Xray-core" "false" "true" >/dev/null 2>&1
    _get_latest_version "SagerNet/sing-box" "false" "true" >/dev/null 2>&1
    _get_latest_prerelease_version "SagerNet/sing-box" "false" "true" >/dev/null 2>&1
    _get_latest_version "surge-networks/snell" "false" "true" >/dev/null 2>&1
    _get_latest_prerelease_version "surge-networks/snell" "false" "true" >/dev/null 2>&1
    local xray_current singbox_current
    xray_current=$(_get_core_version "xray")
    singbox_current=$(_get_core_version "sing-box")
    _check_version_updates_async "$xray_current" "$singbox_current"
    _version_check_started=1
    _ok "版本信息已更新"
}

_show_core_versions() {
    local filter="${1:-all}"  # 参数：xray, singbox, snellv5, all(默认)
    
    # 初始化缓存目录
    _init_version_cache

    # 辅助函数定义
    _is_numeric_version() {
        [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
    }

    _version_ge() {
        local v1="$1" v2="$2"
        [[ "$v1" == "$v2" ]] && return 0
        local IFS=.
        local i v1_arr=($v1) v2_arr=($v2)
        for ((i=0; i<${#v1_arr[@]} || i<${#v2_arr[@]}; i++)); do
            local n1=${v1_arr[i]:-0} n2=${v2_arr[i]:-0}
            ((n1 > n2)) && return 0
            ((n1 < n2)) && return 1
        done
        return 0
    }

    _prerelease_hint() {
        local prerelease="$1" stable="$2"
        _is_version_unknown "$prerelease" && return 0
        local hint="（GitHub 预发布）"
        if ! _is_version_unknown "$stable"; then
            local pre_base="${prerelease%%-*}"
            local stable_base="${stable%%-*}"
            if _is_numeric_version "$pre_base" && _is_numeric_version "$stable_base"; then
                if ! _version_ge "$pre_base" "$stable_base"; then
                    hint="（GitHub 预发布，可能低于稳定版）"
                fi
            fi
        fi
        echo "$hint"
    }

    # 显示 Xray 版本信息
    if [[ "$filter" == "all" ]] || [[ "$filter" == "xray" ]]; then
        local xray_current
        xray_current=$(_get_core_version "xray")
        
        local xray_latest xray_prerelease
        xray_latest=$(_get_cached_version_with_fallback "XTLS/Xray-core")
        [[ -z "$xray_latest" ]] && xray_latest="获取中..."
        
        xray_prerelease=$(_get_cached_prerelease_with_fallback "XTLS/Xray-core")
        [[ -z "$xray_prerelease" ]] && xray_prerelease="获取中..."

        local xray_unavailable="$VERSION_CACHE_DIR/XTLS_Xray-core_unavailable"
        if [[ -f "$xray_unavailable" ]]; then
            [[ "$xray_latest" == "获取中..." ]] && xray_latest="不可获取"
            [[ "$xray_prerelease" == "获取中..." ]] && xray_prerelease="不可获取"
        fi
        
        local xray_prerelease_hint
        xray_prerelease_hint=$(_prerelease_hint "$xray_prerelease" "$xray_latest")
        
        echo -e "  ${W}Xray${NC}"
        if [[ "$xray_current" == "未安装" ]]; then
            echo -e "    ${W}当前版本:${NC} ${D}${xray_current}${NC}"
        else
            local xray_status=$(_get_version_status "$xray_current" "$xray_latest" "$xray_prerelease")
            echo -e "    ${W}当前版本:${NC} ${G}v${xray_current}${NC}${xray_status}"
        fi
        
        if ! _is_version_unknown "$xray_latest"; then
            echo -e "    ${NC}${W}稳定版本:${NC} ${C}v${xray_latest}${NC}"
        else
            echo -e "    ${NC}${W}稳定版本:${NC} ${D}${xray_latest}${NC}"
        fi
        
        if ! _is_version_unknown "$xray_prerelease"; then
            echo -e "    ${W}预发布版本:${NC} ${M}v${xray_prerelease}${NC}${D}${xray_prerelease_hint}${NC}"
        else
            echo -e "    ${W}预发布版本:${NC} ${D}${xray_prerelease}${NC}"
        fi
        
        # 如果还要显示 Sing-box，添加空行分隔
        [[ "$filter" == "all" ]] && echo ""
    fi

    # 显示 Sing-box 版本信息
    if [[ "$filter" == "all" ]] || [[ "$filter" == "singbox" ]]; then
        local singbox_current
        singbox_current=$(_get_core_version "sing-box")
        
        local singbox_latest singbox_prerelease
        singbox_latest=$(_get_cached_version_with_fallback "SagerNet/sing-box")
        [[ -z "$singbox_latest" ]] && singbox_latest="获取中..."
        
        singbox_prerelease=$(_get_cached_prerelease_with_fallback "SagerNet/sing-box")
        [[ -z "$singbox_prerelease" ]] && singbox_prerelease="获取中..."

        local singbox_unavailable="$VERSION_CACHE_DIR/SagerNet_sing-box_unavailable"
        if [[ -f "$singbox_unavailable" ]]; then
            [[ "$singbox_latest" == "获取中..." ]] && singbox_latest="不可获取"
            [[ "$singbox_prerelease" == "获取中..." ]] && singbox_prerelease="不可获取"
        fi
        
        local singbox_prerelease_hint
        singbox_prerelease_hint=$(_prerelease_hint "$singbox_prerelease" "$singbox_latest")
        
        echo -e "  ${W}Sing-box${NC}"
        if [[ "$singbox_current" == "未安装" ]]; then
            echo -e "    ${W}当前版本:${NC} ${D}${singbox_current}${NC}"
        else
            local singbox_status=$(_get_version_status "$singbox_current" "$singbox_latest" "$singbox_prerelease")
            echo -e "    ${W}当前版本:${NC} ${G}v${singbox_current}${NC}${singbox_status}"
        fi
        
        if ! _is_version_unknown "$singbox_latest"; then
            echo -e "    ${NC}${W}稳定版本:${NC} ${C}v${singbox_latest}${NC}"
        else
            echo -e "    ${NC}${W}稳定版本:${NC} ${D}${singbox_latest}${NC}"
        fi
        
        if ! _is_version_unknown "$singbox_prerelease"; then
            echo -e "    ${W}预发布版本:${NC} ${M}v${singbox_prerelease}${NC}${D}${singbox_prerelease_hint}${NC}"
        else
            echo -e "    ${W}预发布版本:${NC} ${D}${singbox_prerelease}${NC}"
        fi

        # 如果还要显示 Snell v5，添加空行分隔
        [[ "$filter" == "all" ]] && echo ""
    fi

    # 显示 Snell v5 版本信息
    if [[ "$filter" == "all" ]] || [[ "$filter" == "snellv5" ]]; then
        local snell_current
        snell_current=$(_get_snell_v5_version)
        
        local snell_latest snell_prerelease
        snell_latest=$(_get_cached_version "surge-networks/snell" 2>/dev/null)
        [[ -z "$snell_latest" ]] && snell_latest="$SNELL_DEFAULT_VERSION"
        ! _is_plain_version "$snell_latest" && snell_latest="$SNELL_DEFAULT_VERSION"
        
        local snell_prerelease_cache="$VERSION_CACHE_DIR/surge-networks_snell_prerelease"
        if [[ -f "$snell_prerelease_cache" ]]; then
            local cache_time
            cache_time=$(_get_file_mtime "$snell_prerelease_cache")
            if [[ -n "$cache_time" ]]; then
                local current_time=$(date +%s)
                local age=$((current_time - cache_time))
                if [[ $age -lt $VERSION_CACHE_TTL ]]; then
                    snell_prerelease=$(cat "$snell_prerelease_cache" 2>/dev/null)
                fi
            fi
        fi
        [[ -z "$snell_prerelease" ]] && snell_prerelease="无"
        
        echo -e "  ${W}Snell v5${NC}"
        if [[ "$snell_current" == "未安装" ]]; then
            echo -e "    ${W}当前版本:${NC} ${D}${snell_current}${NC}"
        else
            local snell_status=$(_get_version_status "$snell_current" "$snell_latest" "$snell_prerelease")
            echo -e "    ${W}当前版本:${NC} ${G}v${snell_current}${NC}${snell_status}"
        fi
        
        if ! _is_version_unknown "$snell_latest"; then
            echo -e "    ${NC}${W}稳定版本:${NC} ${C}v${snell_latest}${NC}"
        else
            echo -e "    ${NC}${W}稳定版本:${NC} ${D}${snell_latest}${NC}"
        fi
    fi

    # 启动后台异步更新（为下次访问准备）
    if [[ "$filter" == "all" ]] || [[ "$filter" == "xray" ]]; then
        _update_version_cache_async "XTLS/Xray-core"
        _update_prerelease_cache_async "XTLS/Xray-core"
    fi
    
    if [[ "$filter" == "all" ]] || [[ "$filter" == "singbox" ]]; then
        _update_version_cache_async "SagerNet/sing-box"
        _update_prerelease_cache_async "SagerNet/sing-box"
    fi

    if [[ "$filter" == "all" ]] || [[ "$filter" == "snellv5" ]]; then
        _update_version_cache_async "surge-networks/snell"
        _update_prerelease_cache_async "surge-networks/snell"
    fi
}

update_xray_core() {
    local channel="${1:-stable}"
    _check_core_update_deps || return 1
    _confirm_core_update "Xray" "$channel" || return 1

    local is_new_install=false
    if ! check_cmd xray; then
        _warn "未检测到 Xray，将执行安装"
        is_new_install=true
    fi

    local need_restart=false service_running=false
    if svc status vless-reality 2>/dev/null; then
        service_running=true
        need_restart=true
        _info "停止 vless-reality 服务..."
        if ! svc stop vless-reality 2>/dev/null; then
            _warn "停止服务失败，继续更新"
        fi
    fi

    if install_xray "$channel" "true"; then
        _ok "Xray 内核已更新"
        local new_version
        new_version=$(xray version 2>/dev/null | awk 'NR==1{print $2}' | sed 's/^v//')
        if [[ -n "$new_version" && "$is_new_install" != "true" ]]; then
            _show_changelog_summary "XTLS/Xray-core" "$new_version" 10
        fi
        if [[ "$need_restart" == "true" ]]; then
            _info "重新启动 vless-reality 服务..."
            if svc start vless-reality 2>/dev/null; then
                _ok "服务已启动"
            else
                _err "服务启动失败，请手动检查配置: svc start vless-reality"
                return 1
            fi
        fi
        return 0
    fi

    _err "Xray 内核更新失败"
    if [[ "$service_running" == "true" ]]; then
        _warn "尝试恢复服务..."
        if svc start vless-reality 2>/dev/null; then
            _ok "服务已恢复"
        else
            _err "服务恢复失败，请手动检查: svc start vless-reality"
        fi
    fi
    return 1
}

update_singbox_core() {
    local channel="${1:-stable}"
    _check_core_update_deps || return 1
    _confirm_core_update "Sing-box" "$channel" || return 1

    local is_new_install=false
    if ! check_cmd sing-box; then
        _warn "未检测到 Sing-box，将执行安装"
        is_new_install=true
    fi

    local need_restart=false service_running=false
    if svc status vless-singbox 2>/dev/null; then
        service_running=true
        need_restart=true
        _info "停止 vless-singbox 服务..."
        if ! svc stop vless-singbox 2>/dev/null; then
            _warn "停止服务失败，继续更新"
        fi
    fi

    if install_singbox "$channel" "true"; then
        _ok "Sing-box 内核已更新"
        local new_version
        new_version=$(sing-box version 2>/dev/null | awk '{print $3}')
        if [[ -n "$new_version" && "$is_new_install" != "true" ]]; then
            _show_changelog_summary "SagerNet/sing-box" "$new_version" 10
        fi
        if [[ "$need_restart" == "true" ]]; then
            _info "重新启动 vless-singbox 服务..."
            if svc start vless-singbox 2>/dev/null; then
                _ok "服务已启动"
            else
                _err "服务启动失败，请手动检查配置: svc start vless-singbox"
                return 1
            fi
        fi
        return 0
    fi

    _err "Sing-box 内核更新失败"
    if [[ "$service_running" == "true" ]]; then
        _warn "尝试恢复服务..."
        if svc start vless-singbox 2>/dev/null; then
            _ok "服务已恢复"
        else
            _err "服务恢复失败，请手动检查: svc start vless-singbox"
        fi
    fi
    return 1
}

update_snell_v5_core() {
    local channel="${1:-stable}"
    _check_core_update_deps || return 1
    _confirm_core_update "Snell v5" "$channel" || return 1

    local is_new_install=false
    if ! check_cmd snell-server-v5; then
        _warn "未检测到 Snell v5，将执行安装"
        is_new_install=true
    fi

    local need_restart=false service_running=false
    if svc status vless-snell-v5 2>/dev/null; then
        service_running=true
        need_restart=true
        _info "停止 vless-snell-v5 服务..."
        if ! svc stop vless-snell-v5 2>/dev/null; then
            _warn "停止服务失败，继续更新"
        fi
    fi

    if install_snell_v5 "$channel" "true"; then
        _ok "Snell v5 内核已更新"
        local new_version
        new_version=$(_get_snell_v5_version)
        if [[ -n "$new_version" && "$new_version" != "未安装" && "$new_version" != "未知" && "$is_new_install" != "true" ]]; then
            _show_changelog_summary "surge-networks/snell" "$new_version" 10
        fi
        if [[ "$need_restart" == "true" ]]; then
            _info "重新启动 vless-snell-v5 服务..."
            if svc start vless-snell-v5 2>/dev/null; then
                _ok "服务已启动"
            else
                _err "服务启动失败，请手动检查配置: svc start vless-snell-v5"
                return 1
            fi
        fi
        return 0
    fi

    _err "Snell v5 内核更新失败"
    if [[ "$service_running" == "true" ]]; then
        _warn "尝试恢复服务..."
        if svc start vless-snell-v5 2>/dev/null; then
            _ok "服务已恢复"
        else
            _err "服务恢复失败，请手动检查: svc start vless-snell-v5"
        fi
    fi
    return 1
}

update_xray_core_custom() {
    _header
    echo -e "  ${W}Xray 安装指定版本${NC}"
    _line
    _show_core_versions "xray"
    _line

    if ! check_cmd xray; then
        _warn "未检测到 Xray，将执行安装"
    fi

    local version
    version=$(_select_version_from_list "XTLS/Xray-core" "all" "Xray" 10)
    local select_rc=$?
    if [[ $select_rc -ne 0 ]]; then
        [[ $select_rc -eq 2 ]] && { _SKIP_PAUSE_ONCE=1; return 0; }
        return 1
    fi
    _update_core_to_version "Xray" "" "$version" "vless-reality" "install_xray"
}

update_singbox_core_custom() {
    _header
    echo -e "  ${W}Sing-box 安装指定版本${NC}"
    _line
    _show_core_versions "singbox"
    _line

    if ! check_cmd sing-box; then
        _warn "未检测到 Sing-box，将执行安装"
    fi

    local version
    version=$(_select_version_from_list "SagerNet/sing-box" "all" "Sing-box" 10)
    local select_rc=$?
    if [[ $select_rc -ne 0 ]]; then
        [[ $select_rc -eq 2 ]] && { _SKIP_PAUSE_ONCE=1; return 0; }
        return 1
    fi
    _update_core_to_version "Sing-box" "" "$version" "vless-singbox" "install_singbox"
}

update_snell_v5_core_custom() {
    _header
    echo -e "  ${W}Snell v5 安装指定版本${NC}"
    _line
    _show_core_versions "snellv5"
    _line

    if ! check_cmd snell-server-v5; then
        _warn "未检测到 Snell v5，将执行安装"
    fi

    local version
    version=$(_select_version_from_list "surge-networks/snell" "all" "Snell v5" 10)
    local select_rc=$?
    if [[ $select_rc -ne 0 ]]; then
        [[ $select_rc -eq 2 ]] && { _SKIP_PAUSE_ONCE=1; return 0; }
        return 1
    fi
    _update_core_to_version "Snell v5" "" "$version" "vless-snell-v5" "install_snell_v5"
}

_update_core_with_channel_select() {
    local core_name="$1"
    local repo="$2"
    local binary_name="$3"
    local service_name="$4"
    local install_func="$5"
    
    # 获取版本信息
    local current_ver stable_ver prerelease_ver
    current_ver=$(_get_core_version "$binary_name")
    stable_ver=$(_get_cached_version_with_fallback "$repo")
    [[ -z "$stable_ver" ]] && stable_ver="获取中..."
    
    prerelease_ver=$(_get_cached_prerelease_with_fallback "$repo")
    [[ -z "$prerelease_ver" ]] && prerelease_ver="获取中..."
    
    if [[ "$repo" == "surge-networks/snell" ]]; then
        [[ "$stable_ver" == "获取中..." ]] && stable_ver="$SNELL_DEFAULT_VERSION"
        [[ "$prerelease_ver" == "获取中..." ]] && prerelease_ver="无"
        ! _is_plain_version "$stable_ver" && stable_ver="$SNELL_DEFAULT_VERSION"
    else
        local unavailable_file="$VERSION_CACHE_DIR/$(echo "$repo" | tr '/' '_')_unavailable"
        if [[ -f "$unavailable_file" ]]; then
            [[ "$stable_ver" == "获取中..." ]] && stable_ver="不可获取"
            [[ "$prerelease_ver" == "获取中..." ]] && prerelease_ver="不可获取"
        fi
    fi

    if [[ "$core_name" == "Snell v5" ]]; then
        _header
        echo -e "  ${W}${core_name} 版本选择${NC}"
        _line
        echo -e "  ${W}当前版本:${NC} ${G}${current_ver}${NC}"
        echo ""
        local stable_label="v${stable_ver}"
        _is_version_unknown "$stable_ver" && stable_label="${stable_ver}"
        _item "1" "稳定版 (${stable_label})"
        _item "2" "指定版本"
        _item "0" "返回"
        _line

        read -rp "  请选择: " channel_choice
        case "$channel_choice" in
            1) update_snell_v5_core "stable" ;;
            2) update_snell_v5_core_custom ;;
            0) return 0 ;;
            *) _err "无效选择"; return 1 ;;
        esac
        return 0
    fi
    
    # 显示选择菜单
    _header
    echo -e "  ${W}${core_name} 版本选择${NC}"
    _line
    echo -e "  ${W}当前版本:${NC} ${G}${current_ver}${NC}"
    echo ""
    local stable_label="v${stable_ver}"
    local prerelease_label="v${prerelease_ver}"
    _is_version_unknown "$stable_ver" && stable_label="$stable_ver"
    _is_version_unknown "$prerelease_ver" && prerelease_label="$prerelease_ver"
    _item "1" "稳定版 (${stable_label})"
    _item "2" "预发布版 (${prerelease_label})"
    _item "3" "指定版本"
    _item "0" "返回"
    _line
    
    read -rp "  请选择: " channel_choice
    local channel=""
    case "$channel_choice" in
        1) channel="stable" ;;
        2) channel="prerelease" ;;
        3)
            case "$core_name" in
                Xray) update_xray_core_custom ;;
                Sing-box) update_singbox_core_custom ;;
                *) _err "不支持的核心"; return 1 ;;
            esac
            return 0
            ;;
        0) return 0 ;;
        *) _err "无效选择"; return 1 ;;
    esac
    
    # 执行更新
    case "$core_name" in
        Xray) update_xray_core "$channel" ;;
        Sing-box) update_singbox_core "$channel" ;;
        "Snell v5") update_snell_v5_core "$channel" ;;
    esac
}

update_core_menu() {
    while true; do
        _header
        echo -e "  ${W}核心版本管理 (Xray/Sing-box/Snell v5)${NC}"
        _line
        _show_core_versions
        _line
        
        _item "1" "更新 Xray"
        _item "2" "更新 Sing-box"
        _item "3" "更新 Snell v5"
        _item "4" "重新获取版本"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        case "$choice" in
            1) _update_core_with_channel_select "Xray" "XTLS/Xray-core" "xray" "vless-reality" "install_xray" ;;
            2) _update_core_with_channel_select "Sing-box" "SagerNet/sing-box" "sing-box" "vless-singbox" "install_singbox" ;;
            3) _update_core_with_channel_select "Snell v5" "surge-networks/snell" "snell-server-v5" "vless-snell-v5" "install_snell_v5" ;;
            4) _refresh_core_versions_now ;;
            0) break ;;
            *) _err "无效选择" ;;
        esac
        if [[ "$choice" != "0" ]]; then
            if [[ -n "$_SKIP_PAUSE_ONCE" ]]; then
                _SKIP_PAUSE_ONCE=""
            else
                _pause
            fi
        fi
    done
}

# 生成 Sing-box 统一配置 (Hy2 + TUIC 共用一个进程)
generate_singbox_config() {
    local singbox_protocols=$(db_list_protocols "singbox")
    [[ -z "$singbox_protocols" ]] && return 1
    
    mkdir -p "$CFG"
    
    # 读取直连出口 IP 版本设置（默认 AsIs）
    local direct_ip_version="as_is"
    [[ -f "$CFG/direct_ip_version" ]] && direct_ip_version=$(cat "$CFG/direct_ip_version")

    # 监听地址：IPv6 双栈不可用时退回 IPv4
    local listen_addr=$(_listen_addr)
    
    # 根据设置生成 direct 出口配置
    local direct_outbound=""
    case "$direct_ip_version" in
        ipv4|ipv4_only)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "ipv4_only"
            }')
            ;;
        ipv6|ipv6_only)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "ipv6_only"
            }')
            ;;
        prefer_ipv4)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "prefer_ipv4"
            }')
            ;;
        prefer_ipv6)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct",
                domain_strategy: "prefer_ipv6"
            }')
            ;;
        as_is|asis|*)
            direct_outbound=$(jq -n '{
                type: "direct",
                tag: "direct"
            }')
            ;;
    esac
    
    # 收集所有需要的出口
    local outbounds=$(jq -n --argjson direct "$direct_outbound" '[$direct, {type: "block", tag: "block"}]')
    local routing_rules=""
    local has_routing=false
    local warp_has_endpoint=false
    local warp_endpoint_data=""
    
    # 获取分流规则
    local rules=$(db_get_routing_rules)
    
    if [[ -n "$rules" && "$rules" != "[]" ]]; then
        # 收集所有用到的出口 (支持多出口)
        
        while IFS= read -r rule_json; do
            [[ -z "$rule_json" ]] && continue
            local outbound=$(echo "$rule_json" | jq -r '.outbound')
            local ip_version=$(echo "$rule_json" | jq -r '.ip_version // "prefer_ipv4"')
            
            if [[ "$outbound" == "direct" ]]; then
                case "$ip_version" in
                    ipv4_only)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-ipv4" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_ipv4_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-ipv4",
                                domain_strategy: "ipv4_only"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_ipv4_out" '. + [$out]')
                        fi
                        ;;
                    ipv6_only)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-ipv6" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_ipv6_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-ipv6",
                                domain_strategy: "ipv6_only"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_ipv6_out" '. + [$out]')
                        fi
                        ;;
                    prefer_ipv6)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-prefer-ipv6" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_prefer_ipv6_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-prefer-ipv6",
                                domain_strategy: "prefer_ipv6"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_prefer_ipv6_out" '. + [$out]')
                        fi
                        ;;
                    as_is|asis)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-asis" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_asis_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-asis"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_asis_out" '. + [$out]')
                        fi
                        ;;
                    prefer_ipv4|*)
                        if ! echo "$outbounds" | jq -e --arg tag "direct-prefer-ipv4" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                            local direct_prefer_ipv4_out=$(jq -n '{
                                type: "direct",
                                tag: "direct-prefer-ipv4",
                                domain_strategy: "prefer_ipv4"
                            }')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$direct_prefer_ipv4_out" '. + [$out]')
                        fi
                        ;;
                esac
            elif [[ "$outbound" == "warp" ]]; then
                local warp_tag=""
                case "$ip_version" in
                    ipv4_only)
                        warp_tag="warp-ipv4"
                        ;;
                    ipv6_only)
                        warp_tag="warp-ipv6"
                        ;;
                    prefer_ipv6)
                        warp_tag="warp-prefer-ipv6"
                        ;;
                    prefer_ipv4|*)
                        warp_tag="warp-prefer-ipv4"
                        ;;
                esac
                if [[ "$warp_has_endpoint" == "true" ]]; then
                    continue
                fi
                if ! echo "$outbounds" | jq -e --arg tag "$warp_tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                    local warp_out=$(gen_singbox_warp_outbound)
                    if [[ -n "$warp_out" ]]; then
                        if echo "$warp_out" | jq -e '.endpoint' >/dev/null 2>&1; then
                            local warp_endpoint=$(echo "$warp_out" | jq '.endpoint')
                            if [[ "$warp_has_endpoint" != "true" ]]; then
                                warp_has_endpoint=true
                                warp_endpoint_data="$warp_endpoint"
                            fi
                        else
                            local warp_out_with_tag=$(echo "$warp_out" | jq --arg tag "$warp_tag" '.tag = $tag')
                            outbounds=$(echo "$outbounds" | jq --argjson out "$warp_out_with_tag" '. + [$out]')
                        fi
                    fi
                fi
            elif [[ "$outbound" == chain:* ]]; then
                local node_name="${outbound#chain:}"
                local tag_suffix=""
                case "$ip_version" in
                    ipv4_only) tag_suffix="-ipv4" ;;
                    ipv6_only) tag_suffix="-ipv6" ;;
                    prefer_ipv6) tag_suffix="-prefer-ipv6" ;;
                    prefer_ipv4|*) tag_suffix="-prefer-ipv4" ;;
                esac
                local tag="chain-${node_name}${tag_suffix}"
                # 链式代理支持每种策略一个独立出口
                if ! echo "$outbounds" | jq -e --arg tag "$tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                    local chain_out=$(gen_singbox_chain_outbound "$node_name" "$tag" "$ip_version")
                    [[ -n "$chain_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                fi
            fi
        done < <(echo "$rules" | jq -c '.[]')
        
        # 独立检查 WARP 配置，确保有 WARP 就生成 outbound（不依赖分流规则）
        local warp_mode=$(db_get_warp_mode)
        if [[ -n "$warp_mode" && "$warp_mode" != "disabled" && "$warp_has_endpoint" != "true" ]]; then
            # 检查是否已经有 warp outbound（可能在遍历规则时已生成）
            if ! echo "$outbounds" | jq -e '.[] | select(.tag == "warp" or .tag | startswith("warp-"))' >/dev/null 2>&1; then
                # 没有 warp outbound，生成一个默认的
                local warp_out=$(gen_singbox_warp_outbound)
                if [[ -n "$warp_out" ]]; then
                    if echo "$warp_out" | jq -e '.endpoint' >/dev/null 2>&1; then
                        local warp_endpoint=$(echo "$warp_out" | jq '.endpoint')
                        if [[ "$warp_has_endpoint" != "true" ]]; then
                            warp_has_endpoint=true
                            warp_endpoint_data="$warp_endpoint"
                        fi
                    else
                        # 使用默认 tag "warp"
                        local warp_out_default=$(echo "$warp_out" | jq '.tag = "warp"')
                        outbounds=$(echo "$outbounds" | jq --argjson out "$warp_out_default" '. + [$out]')
                    fi
                fi
            fi
        fi

        # 生成负载均衡器 (sing-box 使用 urltest/selector outbound)
        local balancer_groups=$(db_get_balancer_groups)
        if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
            while IFS= read -r group_json; do
                local group_name=$(echo "$group_json" | jq -r '.name')
                local strategy=$(echo "$group_json" | jq -r '.strategy')

                # 构建节点 outbound 数组
                local node_outbounds="[]"
                local balancer_ip_version="prefer_ipv4"
                local tag_suffix=""
                case "$balancer_ip_version" in
                    ipv4_only) tag_suffix="-ipv4" ;;
                    ipv6_only) tag_suffix="-ipv6" ;;
                    prefer_ipv6) tag_suffix="-prefer-ipv6" ;;
                    prefer_ipv4|*) tag_suffix="-prefer-ipv4" ;;
                esac

                while IFS= read -r node_name; do
                    [[ -z "$node_name" ]] && continue
                    local node_tag="chain-${node_name}${tag_suffix}"
                    node_outbounds=$(echo "$node_outbounds" | jq --arg tag "$node_tag" '. + [$tag]')

                    # 确保节点 outbound 存在
                    if ! echo "$outbounds" | jq -e --arg tag "$node_tag" '.[] | select(.tag == $tag)' >/dev/null 2>&1; then
                        local chain_out=$(gen_singbox_chain_outbound "$node_name" "$node_tag" "$balancer_ip_version")
                        [[ -n "$chain_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                    fi
                done < <(echo "$group_json" | jq -r '.nodes[]?')

                # 根据策略生成不同类型的 sing-box outbound
                local balancer_out=""
                case "$strategy" in
                    leastPing)
                        # sing-box 使用 urltest 实现最低延迟选择
                        balancer_out=$(jq -n \
                            --arg tag "balancer-${group_name}" \
                            --argjson outbounds "$node_outbounds" \
                            '{
                                type: "urltest",
                                tag: $tag,
                                outbounds: $outbounds,
                                url: "https://www.gstatic.com/generate_204",
                                interval: "10s",
                                tolerance: 50,
                                idle_timeout: "30m"
                            }')
                        ;;
                    random|roundRobin|*)
                        # sing-box 使用 selector 实现手动/随机选择
                        balancer_out=$(jq -n \
                            --arg tag "balancer-${group_name}" \
                            --argjson outbounds "$node_outbounds" \
                            '{
                                type: "selector",
                                tag: $tag,
                                outbounds: $outbounds,
                                default: ($outbounds[0] // "direct")
                            }')
                        ;;
                esac

                # 添加负载均衡器 outbound
                [[ -n "$balancer_out" ]] && outbounds=$(echo "$outbounds" | jq --argjson out "$balancer_out" '. + [$out]')
            done < <(echo "$balancer_groups" | jq -c '.[]')
        fi

        routing_rules=$(gen_singbox_routing_rules)
        if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
            if [[ "$warp_has_endpoint" == "true" ]]; then
                routing_rules=$(echo "$routing_rules" | jq 'map(if ((.outbound // "") | startswith("warp")) then .outbound = "warp" else . end)')
            fi
            has_routing=true
        fi
        
        # 检测是否使用了 WARP，如果是，添加保护性直连规则
        if [[ "$warp_has_endpoint" == "true" ]] || echo "$outbounds" | jq -e '.[] | select(.tag | startswith("warp"))' >/dev/null 2>&1; then
            local warp_mode=$(db_get_warp_mode)
            
            # 只有 WireGuard 模式需要保护性规则
            if [[ "$warp_mode" == "wgcf" ]]; then
                # 生成保护性规则：WARP 服务器和私有 IP 必须直连
                local warp_protection_rules='[
                    {
                        "outbound": "direct",
                        "domain": ["engage.cloudflareclient.com"]
                    },
                    {
                        "outbound": "direct",
                        "ip_cidr": [
                            "10.0.0.0/8",
                            "172.16.0.0/12",
                            "192.168.0.0/16",
                            "127.0.0.0/8",
                            "169.254.0.0/16",
                            "224.0.0.0/4",
                            "240.0.0.0/4",
                            "fc00::/7",
                            "fe80::/10"
                        ]
                    }
                ]'
                
                # 将保护性规则放在最前面
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    routing_rules=$(echo "$warp_protection_rules" | jq --argjson user_rules "$routing_rules" '. + $user_rules')
                else
                    routing_rules="$warp_protection_rules"
                fi
                has_routing=true
            elif [[ "$warp_mode" == "official" ]]; then
                # SOCKS5 模式：UDP 必须直连（warp-cli SOCKS5 不支持 UDP），私有 IP 直连
                local warp_protection_rules='[
                    {
                        "network": "udp",
                        "outbound": "direct"
                    },
                    {
                        "outbound": "direct",
                        "ip_cidr": [
                            "10.0.0.0/8",
                            "172.16.0.0/12",
                            "192.168.0.0/16",
                            "127.0.0.0/8"
                        ]
                    }
                ]'
                
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    routing_rules=$(echo "$warp_protection_rules" | jq --argjson user_rules "$routing_rules" '. + $user_rules')
                else
                    routing_rules="$warp_protection_rules"
                fi
                has_routing=true
            fi
        fi
    fi
    
    # 构建基础配置
    local base_config=""
    if [[ "$has_routing" == "true" ]]; then
        base_config=$(jq -n --argjson outbounds "$outbounds" '{
            log: {level: "warn", timestamp: true},
            inbounds: [],
            outbounds: $outbounds,
            route: {rules: [], final: "direct"}
        }')
        
        # 添加 WireGuard endpoint（如果存在）
        if [[ "$warp_has_endpoint" == "true" ]]; then
            base_config=$(echo "$base_config" | jq --argjson ep "$warp_endpoint_data" '.endpoints = [$ep]')
        fi
        
        # 添加路由规则
        if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
            base_config=$(echo "$base_config" | jq --argjson rules "$routing_rules" '.route.rules = $rules')
        fi
    else
        base_config=$(jq -n --argjson direct "$direct_outbound" '{
            log: {level: "warn", timestamp: true},
            inbounds: [],
            outbounds: [$direct]
        }')
        
        # 添加 WireGuard endpoint（如果存在）
        if [[ "$warp_has_endpoint" == "true" ]]; then
            base_config=$(echo "$base_config" | jq --argjson ep "$warp_endpoint_data" '.endpoints = [$ep]')
        fi
    fi
    
    local inbounds="[]"
    local success_count=0
    
    for proto in $singbox_protocols; do
        local cfg=$(db_get "singbox" "$proto")
        [[ -z "$cfg" ]] && continue
        
        local port=$(echo "$cfg" | jq -r '.port // empty')
        [[ -z "$port" ]] && continue
        
        local inbound=""
        
        case "$proto" in
            hy2)
                local password=$(echo "$cfg" | jq -r '.password // empty')
                local sni=$(echo "$cfg" | jq -r '.sni // "www.bing.com"')
                
                # 智能证书选择：优先使用 ACME 证书，否则使用 hy2 独立自签证书
                local cert_path="$CFG/certs/hy2/server.crt"
                local key_path="$CFG/certs/hy2/server.key"
                if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
                    local cert_domain=$(cat "$CFG/cert_domain" 2>/dev/null)
                    if [[ "$sni" == "$cert_domain" ]]; then
                        cert_path="$CFG/certs/server.crt"
                        key_path="$CFG/certs/server.key"
                    fi
                fi
                
                # 构建用户列表：从数据库读取用户，如果没有则使用默认用户
                local users_json="[]"
                local db_users=$(jq -r --arg p "$proto" '
                    .singbox[$p] as $cfg |
                    if $cfg == null then empty
                    elif ($cfg | type) == "array" then
                        [$cfg[].users // [] | .[]] | unique_by(.name)
                    else
                        $cfg.users // []
                    end
                ' "$DB_FILE" 2>/dev/null)
                
                if [[ -n "$db_users" && "$db_users" != "[]" && "$db_users" != "null" ]]; then
                    # 有自定义用户，为每个用户生成 {name, password}
                    # hy2 用户的 uuid 字段存储的是密码
                    local default_user_json=$(jq -n --arg pw "$password" '{name: "default", password: $pw}')
                    users_json=$(jq -n --argjson db_users "$db_users" --argjson chk_def "$default_user_json" '[$chk_def] + ($db_users | map({name: .name, password: .uuid}))')
                else
                    # 没有自定义用户，使用默认密码
                    users_json=$(jq -n --arg pw "$password" '[{name: "default", password: $pw}]')
                fi
                
                inbound=$(jq -n \
                    --argjson port "$port" \
                    --argjson users "$users_json" \
                    --arg cert "$cert_path" \
                    --arg key "$key_path" \
                    --arg listen_addr "$listen_addr" \
                '{
                    type: "hysteria2",
                    tag: "hy2-in",
                    listen: $listen_addr,
                    listen_port: $port,
                    users: $users,
                    ignore_client_bandwidth: true,
                    tls: {
                        enabled: true,
                        certificate_path: $cert,
                        key_path: $key,
                        alpn: ["h3"]
                    },
                    masquerade: "https://www.bing.com"
                }')
                ;;
            tuic)
                local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
                local password=$(echo "$cfg" | jq -r '.password // empty')
                
                # TUIC 使用独立证书目录
                local cert_path="$CFG/certs/tuic/server.crt"
                local key_path="$CFG/certs/tuic/server.key"
                [[ ! -f "$cert_path" ]] && { cert_path="$CFG/certs/server.crt"; key_path="$CFG/certs/server.key"; }
                
                inbound=$(jq -n \
                    --argjson port "$port" \
                    --arg uuid "$uuid" \
                    --arg password "$password" \
                    --arg cert "$cert_path" \
                    --arg key "$key_path" \
                    --arg listen_addr "$listen_addr" \
                '{
                    type: "tuic",
                    tag: "tuic-in",
                    listen: $listen_addr,
                    listen_port: $port,
                    users: [{uuid: $uuid, password: $password}],
                    congestion_control: "bbr",
                    tls: {
                        enabled: true,
                        certificate_path: $cert,
                        key_path: $key,
                        alpn: ["h3"]
                    }
                }')
                ;;
            ss2022|ss-legacy)
                local password=$(echo "$cfg" | jq -r '.password // empty')
                local default_method="2022-blake3-aes-128-gcm"
                [[ "$p" == "ss-legacy" ]] && default_method="aes-256-gcm"
                local method=$(echo "$cfg" | jq -r '.method // empty')
                [[ -z "$method" ]] && method="$default_method"
                
                inbound=$(jq -n \
                    --argjson port "$port" \
                    --arg method "$method" \
                    --arg password "$password" \
                    --arg tag "${p}-in" \
                    --arg listen_addr "$listen_addr" \
                '{
                    type: "shadowsocks",
                    tag: $tag,
                    listen: $listen_addr,
                    listen_port: $port,
                    method: $method,
                    password: $password
                }')
                ;;
        esac
        
        if [[ -n "$inbound" ]]; then
            inbounds=$(echo "$inbounds" | jq --argjson ib "$inbound" '. += [$ib]')
            ((success_count++))
        fi
    done
    
    if [[ $success_count -eq 0 ]]; then
        _err "没有有效的 Sing-box 协议配置"
        return 1
    fi
    
    # 生成用户级路由规则 (auth_user) 和所需的 outbounds
    local user_routing_rules="[]"
    local user_outbounds="[]"
    local chain_outbounds_added=""  # 跟踪已添加的链式代理 outbound
    
    for proto in $singbox_protocols; do
        local db_users=$(jq -r --arg p "$proto" '
            .singbox[$p] as $cfg |
            if $cfg == null then empty
            elif ($cfg | type) == "array" then
                [$cfg[].users // [] | .[]] | unique_by(.name) | .[]
            else
                $cfg.users // [] | .[]
            end | @json
        ' "$DB_FILE" 2>/dev/null)
        
        while IFS= read -r user_json; do
            [[ -z "$user_json" ]] && continue
            local uname=$(echo "$user_json" | jq -r '.name // empty')
            local urouting=$(echo "$user_json" | jq -r '.routing // empty')
            
            [[ -z "$uname" || -z "$urouting" || "$urouting" == "default" ]] && continue
            
            # 根据路由类型生成规则
            local outbound_name=""
            case "$urouting" in
                warp|warp-wireguard|warp-official)
                    outbound_name="warp"
                    ;;
                direct)
                    outbound_name="direct"
                    ;;
                chain:*)
                    # 链式代理支持
                    local node_name="${urouting#chain:}"
                    outbound_name="chain-${node_name}"
                    
                    # 检查该链式代理 outbound 是否已添加
                    if [[ ! " $chain_outbounds_added " =~ " $outbound_name " ]]; then
                        # 生成链式代理 outbound
                        local chain_out=$(gen_singbox_chain_outbound "$node_name" "$outbound_name" "prefer_ipv4")
                        if [[ -n "$chain_out" && "$chain_out" != "null" ]]; then
                            user_outbounds=$(echo "$user_outbounds" | jq --argjson out "$chain_out" '. + [$out]')
                            chain_outbounds_added="$chain_outbounds_added $outbound_name"
                        else
                            # 链式代理节点不存在，跳过
                            continue
                        fi
                    fi
                    ;;
                *)
                    # 其他路由类型暂不支持
                    continue
                    ;;
            esac
            
            # 添加路由规则
            user_routing_rules=$(echo "$user_routing_rules" | jq \
                --arg user "$uname" \
                --arg outbound "$outbound_name" \
                '. + [{auth_user: [$user], outbound: $outbound}]')
        done <<< "$db_users"
    done
    
    # 将用户路由所需的 outbounds 添加到 base_config
    if [[ "$user_outbounds" != "[]" ]]; then
        base_config=$(echo "$base_config" | jq --argjson outs "$user_outbounds" '.outbounds = ($outs + (.outbounds // []))')
    fi
    
    # 将用户路由规则添加到 base_config
    if [[ "$user_routing_rules" != "[]" ]]; then
        if echo "$base_config" | jq -e '.route' >/dev/null 2>&1; then
            base_config=$(echo "$base_config" | jq --argjson ur "$user_routing_rules" '.route.rules = ($ur + .route.rules)')
        else
            base_config=$(echo "$base_config" | jq --argjson ur "$user_routing_rules" '. + {route: {rules: $ur, final: "direct"}}')
        fi
    fi
    
    # 合并配置并写入文件（不生成 v2ray_api，精简版 sing-box 不支持流量统计）
    echo "$base_config" | jq \
        --argjson ibs "$inbounds" \
        '.inbounds = $ibs' > "$CFG/singbox.json"
    
    # 验证配置
    if ! jq empty "$CFG/singbox.json" 2>/dev/null; then
        _err "Sing-box 配置 JSON 格式错误"
        return 1
    fi
    
    _ok "Sing-box 配置生成成功 ($success_count 个协议)"
    return 0
}

# 创建 Sing-box 服务
create_singbox_service() {
    local service_name="vless-singbox"
    local exec_cmd="/usr/local/bin/sing-box run -c $CFG/singbox.json"
    
    # 检查是否有 hy2 协议且启用了端口跳跃
    local has_hy2_hop=false
    if db_exists "singbox" "hy2"; then
        local hop_enable=$(db_get_field "singbox" "hy2" "hop_enable")
        [[ "$hop_enable" == "1" ]] && has_hy2_hop=true
    fi
    
    local has_tuic_hop=false
    if db_exists "singbox" "tuic"; then
        local hop_enable=$(db_get_field "singbox" "tuic" "hop_enable")
        [[ "$hop_enable" == "1" ]] && has_tuic_hop=true
    fi
    
    if [[ "$DISTRO" == "alpine" ]]; then
        # Alpine: 在 start_pre 中执行端口跳跃脚本
        cat > /etc/init.d/$service_name << EOF
#!/sbin/openrc-run
name="Sing-box Proxy Server"
command="/usr/local/bin/sing-box"
command_args="run -c $CFG/singbox.json"
command_background="yes"
pidfile="/run/${service_name}.pid"
depend() { need net; }
start_pre() {
    [[ -x "$CFG/hy2-nat.sh" ]] && "$CFG/hy2-nat.sh" || true
    [[ -x "$CFG/tuic-nat.sh" ]] && "$CFG/tuic-nat.sh" || true
}
EOF
        chmod +x /etc/init.d/$service_name
    else
        # systemd: 添加 ExecStartPre 执行端口跳跃脚本
        local pre_cmd=""
        [[ -f "$CFG/hy2-nat.sh" ]] && pre_cmd="ExecStartPre=-/bin/bash $CFG/hy2-nat.sh"
        [[ -f "$CFG/tuic-nat.sh" ]] && pre_cmd="${pre_cmd}"$'\n'"ExecStartPre=-/bin/bash $CFG/tuic-nat.sh"
        
        cat > /etc/systemd/system/${service_name}.service << EOF
[Unit]
Description=Sing-box Proxy Server (Hy2/TUIC/SS2022)
After=network.target

[Service]
Type=simple
${pre_cmd}
ExecStart=$exec_cmd
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

# 安装 Snell v4
install_snell() {
    check_cmd snell-server && { _ok "Snell 已安装"; return 0; }
    local sarch=$(_map_arch "amd64:aarch64:armv7l") || { _err "不支持的架构"; return 1; }
    # Alpine 需要安装 upx 来解压 UPX 压缩的二进制 (musl 不兼容 UPX stub)
    if [[ "$DISTRO" == "alpine" ]]; then
        apk add --no-cache upx &>/dev/null
    fi
    _info "安装 Snell v4..."
    local tmp=$(mktemp -d)
    if curl -sLo "$tmp/snell.zip" --connect-timeout 60 "https://dl.nssurge.com/snell/snell-server-v4.1.1-linux-${sarch}.zip"; then
        unzip -oq "$tmp/snell.zip" -d "$tmp/" && install -m 755 "$tmp/snell-server" /usr/local/bin/snell-server
        # Alpine: 解压 UPX 压缩 (Snell 官方二进制使用 UPX，musl 不兼容 UPX stub)
        if [[ "$DISTRO" == "alpine" ]] && command -v upx &>/dev/null; then
            upx -d /usr/local/bin/snell-server &>/dev/null || true
        fi
        rm -rf "$tmp"; _ok "Snell v4 已安装"; return 0
    fi
    rm -rf "$tmp"; _err "下载失败"; return 1
}

# 安装 Snell v5
install_snell_v5() {
    local channel="${1:-stable}"
    local force="${2:-false}"
    local version_override="${3:-}"
    local exists=false action="安装" channel_label="稳定版"

    if check_cmd snell-server-v5; then
        exists=true
        [[ "$force" != "true" ]] && { _ok "Snell v5 已安装"; return 0; }
    fi
    [[ "$exists" == "true" ]] && action="更新"
    if [[ "$channel" == "prerelease" || "$channel" == "test" || "$channel" == "beta" ]]; then
        _warn "Snell v5 未提供预发布版本，使用稳定版"
        channel="stable"
    fi

    local sarch=$(_map_arch "amd64:aarch64:armv7l") || { _err "不支持的架构"; return 1; }
    # Alpine 需要安装 upx 来解压 UPX 压缩的二进制 (musl 不兼容 UPX stub)
    if [[ "$DISTRO" == "alpine" ]]; then
        apk add --no-cache upx &>/dev/null
    fi
    local version=""
    if [[ -n "$version_override" ]]; then
        _info "$action Snell v5 (版本 v$version_override)..."
        version="$version_override"
    else
        _info "$action Snell v5 (获取最新${channel_label})..."
        version=$(_get_snell_latest_version "true")
        if [[ -z "$version" ]]; then
            local cached_version=""
            cached_version=$(_force_get_cached_version "surge-networks/snell" 2>/dev/null)
            if [[ -n "$cached_version" ]]; then
                _warn "获取最新${channel_label}失败，使用缓存版本 v$cached_version"
                version="$cached_version"
            fi
        fi
    fi
    [[ -z "$version" ]] && version="$SNELL_DEFAULT_VERSION"
    if [[ ! "$version" =~ ^[0-9A-Za-z._-]+$ ]]; then
        _err "无效的版本号格式: $version"
        return 1
    fi
    local tmp=$(mktemp -d)
    if curl -sLo "$tmp/snell.zip" --connect-timeout 60 "https://dl.nssurge.com/snell/snell-server-v${version}-linux-${sarch}.zip"; then
        unzip -oq "$tmp/snell.zip" -d "$tmp/" && install -m 755 "$tmp/snell-server" /usr/local/bin/snell-server-v5
        # Alpine: 解压 UPX 压缩 (Snell 官方二进制使用 UPX，musl 不兼容 UPX stub)
        if [[ "$DISTRO" == "alpine" ]] && command -v upx &>/dev/null; then
            upx -d /usr/local/bin/snell-server-v5 &>/dev/null || true
        fi
        rm -rf "$tmp"; _ok "Snell v$version 已安装"; return 0
    fi
    rm -rf "$tmp"; _err "下载失败"; return 1
}

# 安装 AnyTLS
install_anytls() {
    local aarch=$(_map_arch "amd64:arm64:armv7") || { _err "不支持的架构"; return 1; }
    # Alpine 需要安装 gcompat 兼容层（以防 Go 二进制使用 CGO）
    if [[ "$DISTRO" == "alpine" ]]; then
        apk add --no-cache gcompat libc6-compat &>/dev/null
    fi
    _install_binary "anytls-server" "anytls/anytls-go" \
        'https://github.com/anytls/anytls-go/releases/download/v$version/anytls_${version}_linux_${aarch}.zip' \
        'unzip -oq "$tmp/pkg" -d "$tmp/" && install -m 755 "$tmp/anytls-server" /usr/local/bin/anytls-server && install -m 755 "$tmp/anytls-client" /usr/local/bin/anytls-client 2>/dev/null'
}

# 安装 ShadowTLS
install_shadowtls() {
    local aarch=$(_map_arch "x86_64-unknown-linux-musl:aarch64-unknown-linux-musl:armv7-unknown-linux-musleabihf") || { _err "不支持的架构"; return 1; }
    _install_binary "shadow-tls" "ihciah/shadow-tls" \
        'https://github.com/ihciah/shadow-tls/releases/download/v$version/shadow-tls-${aarch}' \
        'install -m 755 "$tmp/pkg" /usr/local/bin/shadow-tls'
}

# 安装 NaïveProxy (Caddy with forwardproxy)
install_naive() {
    check_cmd caddy && caddy list-modules 2>/dev/null | grep -q "http.handlers.forward_proxy" && { _ok "NaïveProxy (Caddy) 已安装"; return 0; }
    
    local narch=$(_map_arch "amd64:arm64:armv7") || { _err "不支持的架构"; return 1; }
    
    # 安装依赖
    case "$DISTRO" in
        alpine)
            apk add --no-cache gcompat libc6-compat xz curl jq &>/dev/null
            ;;
        debian|ubuntu)
            apt-get update -qq &>/dev/null
            apt-get install -y -qq xz-utils curl jq &>/dev/null
            ;;
        centos)
            yum install -y -q xz curl jq &>/dev/null
            ;;
    esac
    
    _info "安装 NaïveProxy (Caddy with forwardproxy)..."
    
    local tmp=$(mktemp -d)
    
    # 获取 tar.xz 下载链接 (使用 jq 解析 JSON)
    _info "获取最新版本信息..."
    local api_response=$(curl -sL --connect-timeout "$CURL_TIMEOUT_NORMAL" \
        "https://api.github.com/repos/klzgrad/forwardproxy/releases/latest" 2>&1)
    
    if [[ -z "$api_response" ]]; then
        _err "无法连接 GitHub API"
        rm -rf "$tmp"
        return 1
    fi
    
    # 优先下载对应架构的文件，如果没有则下载通用包
    local download_url=""
    
    # 尝试获取架构特定的文件
    case "$narch" in
        amd64)
            download_url=$(echo "$api_response" | \
                jq -r '.assets[] | select(.name | test("linux.*amd64|linux.*x86_64"; "i")) | .browser_download_url' 2>/dev/null | head -1)
            ;;
        arm64)
            download_url=$(echo "$api_response" | \
                jq -r '.assets[] | select(.name | test("linux.*arm64|linux.*aarch64"; "i")) | .browser_download_url' 2>/dev/null | head -1)
            ;;
    esac
    
    # 如果没有架构特定文件，获取通用 tar.xz
    if [[ -z "$download_url" ]]; then
        download_url=$(echo "$api_response" | \
            jq -r '.assets[] | select(.name | endswith(".tar.xz")) | .browser_download_url' 2>/dev/null | head -1)
    fi
    
    if [[ -z "$download_url" ]]; then
        _err "无法获取下载链接"
        _warn "API 响应: $(echo "$api_response" | head -c 200)"
        rm -rf "$tmp"
        return 1
    fi
    
    _info "下载: $download_url"
    if ! curl -fSLo "$tmp/caddy.tar.xz" --connect-timeout 60 --retry 3 --progress-bar "$download_url"; then
        _err "下载失败"
        rm -rf "$tmp"
        return 1
    fi
    
    # 检查文件是否下载成功
    if [[ ! -f "$tmp/caddy.tar.xz" ]] || [[ ! -s "$tmp/caddy.tar.xz" ]]; then
        _err "下载的文件为空或不存在"
        rm -rf "$tmp"
        return 1
    fi
    
    _info "解压文件..."
    # 解压
    if ! tar -xJf "$tmp/caddy.tar.xz" -C "$tmp/" 2>&1; then
        _err "解压失败，可能是 xz-utils 未安装或文件损坏"
        rm -rf "$tmp"
        return 1
    fi
    
    # 查找 caddy 二进制文件 (forwardproxy 的 release 结构是 caddy-forwardproxy-naive/caddy)
    local caddy_bin=""
    
    # 方法1: 直接查找名为 caddy 的可执行文件
    caddy_bin=$(find "$tmp" -type f -name "caddy" 2>/dev/null | head -1)
    
    # 方法2: 按架构名匹配文件名
    if [[ -z "$caddy_bin" ]]; then
        local arch_patterns=()
        case "$narch" in
            amd64) arch_patterns=("linux-amd64" "linux_amd64" "amd64") ;;
            arm64) arch_patterns=("linux-arm64" "linux_arm64" "arm64") ;;
            armv7) arch_patterns=("linux-arm" "linux_arm" "arm") ;;
        esac
        
        for pattern in "${arch_patterns[@]}"; do
            caddy_bin=$(find "$tmp" -type f -name "*${pattern}*" 2>/dev/null | head -1)
            [[ -n "$caddy_bin" ]] && break
        done
    fi
    
    # 验证并安装
    if [[ -n "$caddy_bin" ]] && [[ -f "$caddy_bin" ]]; then
        # 检查是否为可执行文件 (不依赖 file 命令)
        # 方法1: 检查 ELF magic number
        local magic=$(head -c 4 "$caddy_bin" 2>/dev/null | od -A n -t x1 2>/dev/null | tr -d ' ')
        
        # ELF 文件的 magic number 是 7f454c46
        if [[ "$magic" == "7f454c46" ]]; then
            chmod +x "$caddy_bin"
            install -m 755 "$caddy_bin" /usr/local/bin/caddy
            rm -rf "$tmp"
            _ok "NaïveProxy (Caddy) 已安装"
            return 0
        fi
        
        # 方法2: 尝试使用 file 命令 (如果可用)
        if command -v file &>/dev/null; then
            local file_info=$(file "$caddy_bin" 2>/dev/null)
            if echo "$file_info" | grep -qE "ELF.*(executable|shared object)"; then
                chmod +x "$caddy_bin"
                install -m 755 "$caddy_bin" /usr/local/bin/caddy
                rm -rf "$tmp"
                _ok "NaïveProxy (Caddy) 已安装"
                return 0
            fi
        fi
        
        # 方法3: 直接尝试执行 (最后的手段)
        chmod +x "$caddy_bin"
        if "$caddy_bin" version &>/dev/null || "$caddy_bin" --version &>/dev/null; then
            install -m 755 "$caddy_bin" /usr/local/bin/caddy
            rm -rf "$tmp"
            _ok "NaïveProxy (Caddy) 已安装"
            return 0
        fi
    fi
    
    # 安装失败，显示调试信息
    _err "未找到有效的 Caddy 二进制文件"
    _warn "解压目录内容:"
    ls -laR "$tmp/" 2>/dev/null | head -20
    rm -rf "$tmp"
    return 1
}

# 生成通用自签名证书 (适配 Xray/Sing-box)
gen_self_cert() {
    local domain="${1:-localhost}"
    mkdir -p "$CFG/certs"
    
    # 检查是否应该保护现有证书
    if [[ -f "$CFG/certs/server.crt" ]]; then
        # 检查是否为 CA 签发的证书（真实证书不覆盖）
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" =~ (Let\'s\ Encrypt|R3|R10|R11|E1|E5|ZeroSSL|Buypass|DigiCert|Comodo|GlobalSign) ]]; then
            _ok "检测到 CA 证书，跳过"
            return 0
        fi
        # 检查现有自签证书的 CN 是否匹配
        local current_cn=$(openssl x509 -in "$CFG/certs/server.crt" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
        if [[ "$current_cn" == "$domain" ]]; then
            _ok "自签证书 CN 匹配，跳过"
            return 0
        fi
    fi
    
    rm -f "$CFG/certs/server.crt" "$CFG/certs/server.key"
    _info "生成自签名证书..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" \
        -subj "/CN=$domain" -days 36500 2>/dev/null
    chmod 600 "$CFG/certs/server.key"
}


#═══════════════════════════════════════════════════════════════════════════════
# 配置生成
#═══════════════════════════════════════════════════════════════════════════════

# VLESS+Reality 服务端配置
gen_server_config() {
    local uuid="$1" port="$2" privkey="$3" pubkey="$4" sid="$5" sni="$6"
    mkdir -p "$CFG"
    
    register_protocol "vless" "$(build_config \
        uuid "$uuid" port "$port" private_key "$privkey" \
        public_key "$pubkey" short_id "$sid" sni "$sni")"
    
    _save_join_info "vless" "REALITY|%s|$port|$uuid|$pubkey|$sid|$sni" \
        "gen_vless_link %s $port $uuid $pubkey $sid $sni"
    echo "server" > "$CFG/role"
}

# VLESS+Reality+XHTTP 服务端配置
gen_vless_xhttp_server_config() {
    local uuid="$1" port="$2" privkey="$3" pubkey="$4" sid="$5" sni="$6" path="${7:-/}"
    mkdir -p "$CFG"
    
    register_protocol "vless-xhttp" "$(build_config \
        uuid "$uuid" port "$port" private_key "$privkey" \
        public_key "$pubkey" short_id "$sid" sni "$sni" path "$path")"
    
    _save_join_info "vless-xhttp" "REALITY-XHTTP|%s|$port|$uuid|$pubkey|$sid|$sni|$path" \
        "gen_vless_xhttp_link %s $port $uuid $pubkey $sid $sni $path"
    echo "server" > "$CFG/role"
}

# Hysteria2 服务端配置
gen_hy2_server_config() {
    local password="$1" port="$2" sni="${3:-bing.com}"
    local hop_enable="${4:-0}" hop_start="${5:-20000}" hop_end="${6:-50000}"
    mkdir -p "$CFG"
    
    # 生成自签证书（Sing-box 使用）
    local hy2_cert_dir="$CFG/certs/hy2"
    mkdir -p "$hy2_cert_dir"
    
    local cert_file="$hy2_cert_dir/server.crt"
    local key_file="$hy2_cert_dir/server.key"
    
    # 检查是否有真实域名的 ACME 证书可复用
    if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
        local cert_domain=$(cat "$CFG/cert_domain")
        local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
        if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]]; then
            if [[ "$sni" == "$cert_domain" ]]; then
                _ok "复用现有 ACME 证书 (域名: $sni)"
            fi
        fi
    fi
    
    # 生成独立自签证书（无论是否有 ACME 证书都生成，Sing-box 配置会智能选择）
    local need_regen=false
    [[ ! -f "$cert_file" ]] && need_regen=true
    if [[ "$need_regen" == "false" ]]; then
        local cert_cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
        [[ "$cert_cn" != "$sni" ]] && need_regen=true
    fi
    
    if [[ "$need_regen" == "true" ]]; then
        _info "为 Hysteria2 生成自签证书 (SNI: $sni)..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$key_file" -out "$cert_file" -subj "/CN=$sni" -days 36500 2>/dev/null
        chmod 600 "$key_file"
        _ok "Hysteria2 自签证书生成完成"
    fi

    # 写入数据库（Sing-box 从数据库读取配置生成 singbox.json）
    register_protocol "hy2" "$(build_config \
        password "$password" port "$port" sni "$sni" \
        hop_enable "$hop_enable" hop_start "$hop_start" hop_end "$hop_end")"
    
    # 保存 join 信息
    local extra_lines=()
    [[ "$hop_enable" == "1" ]] && extra_lines=("" "# 端口跳跃已启用" "# 客户端请手动将端口改为: ${hop_start}-${hop_end}")
    
    _save_join_info "hy2" "HY2|%s|$port|$password|$sni" \
        "gen_hy2_link %s $port $password $sni" "${extra_lines[@]}"
    cp "$CFG/hy2.join" "$CFG/join.txt" 2>/dev/null
    echo "server" > "$CFG/role"
}

# Trojan 服务端配置
gen_trojan_server_config() {
    local password="$1" port="$2" sni="${3:-bing.com}"
    mkdir -p "$CFG"
    
    [[ ! -f "$CFG/certs/server.crt" ]] && gen_self_cert "$sni"

    register_protocol "trojan" "$(build_config password "$password" port "$port" sni "$sni")"
    _save_join_info "trojan" "TROJAN|%s|$port|$password|$sni" \
        "gen_trojan_link %s $port $password $sni"
    echo "server" > "$CFG/role"
}

# Trojan+WS+TLS 服务端配置
gen_trojan_ws_server_config() {
    local password="$1" port="$2" sni="${3:-bing.com}" path="${4:-/trojan}" force_new_cert="${5:-false}"
    mkdir -p "$CFG"
    
    local outer_port=$(_get_master_port "$port")
    _has_master_protocol || _handle_standalone_cert "$sni" "$force_new_cert"

    register_protocol "trojan-ws" "$(build_config \
        password "$password" port "$port" outer_port "$outer_port" sni "$sni" path "$path")"
    _save_join_info "trojan-ws" "TROJAN-WS|%s|$outer_port|$password|$sni|$path" \
        "gen_trojan_ws_link %s $outer_port $password $sni $path"
    echo "server" > "$CFG/role"
}

# VLESS+WS+TLS 服务端配置
gen_vless_ws_server_config() {
    local uuid="$1" port="$2" sni="${3:-bing.com}" path="${4:-/vless}" force_new_cert="${5:-false}"
    mkdir -p "$CFG"
    
    local outer_port=$(_get_master_port "$port")
    _has_master_protocol || _handle_standalone_cert "$sni" "$force_new_cert"

    register_protocol "vless-ws" "$(build_config \
        uuid "$uuid" port "$port" outer_port "$outer_port" sni "$sni" path "$path")"
    _save_join_info "vless-ws" "VLESS-WS|%s|$outer_port|$uuid|$sni|$path" \
        "gen_vless_ws_link %s $outer_port $uuid $sni $path"
    echo "server" > "$CFG/role"
}

# VLESS+WS (无TLS) 服务端配置 - 专为 CF Tunnel 设计
gen_vless_ws_notls_server_config() {
    local uuid="$1" port="$2" path="${3:-/vless}" host="${4:-}"
    mkdir -p "$CFG"
    
    # 无需证书，直接使用外部端口
    register_protocol "vless-ws-notls" "$(build_config \
        uuid "$uuid" port "$port" path "$path" host "$host")"
    _save_join_info "vless-ws-notls" "VLESS-WS-CF|%s|$port|$uuid|$path|$host" \
        "gen_vless_ws_notls_link %s $port $uuid $path $host"
    echo "server" > "$CFG/role"
}


# VMess+WS 服务端配置
gen_vmess_ws_server_config() {
    local uuid="$1" port="$2" sni="$3" path="$4" force_new_cert="${5:-false}"
    mkdir -p "$CFG"
    
    local outer_port=$(_get_master_port "$port")
    _has_master_protocol || _handle_standalone_cert "$sni" "$force_new_cert"

    register_protocol "vmess-ws" "$(build_config \
        uuid "$uuid" port "$port" outer_port "$outer_port" sni "$sni" path "$path")"
    _save_join_info "vmess-ws" "VMESSWS|%s|$outer_port|$uuid|$sni|$path" \
        "gen_vmess_ws_link %s $outer_port $uuid $sni $path"
    echo "server" > "$CFG/role"
}

# VLESS-XTLS-Vision 服务端配置
gen_vless_vision_server_config() {
    local uuid="$1" port="$2" sni="${3:-bing.com}"
    mkdir -p "$CFG"
    
    [[ ! -f "$CFG/certs/server.crt" ]] && gen_self_cert "$sni"

    register_protocol "vless-vision" "$(build_config uuid "$uuid" port "$port" sni "$sni")"
    _save_join_info "vless-vision" "VLESS-VISION|%s|$port|$uuid|$sni" \
        "gen_vless_vision_link %s $port $uuid $sni"
    echo "server" > "$CFG/role"
}

# Shadowsocks 2022 服务端配置
gen_ss2022_server_config() {
    local password="$1" port="$2" method="${3:-2022-blake3-aes-128-gcm}"
    mkdir -p "$CFG"

    register_protocol "ss2022" "$(build_config password "$password" port "$port" method "$method")"
    _save_join_info "ss2022" "SS2022|%s|$port|$method|$password" \
        "gen_ss2022_link %s $port $method $password"
    echo "server" > "$CFG/role"
}

# Shadowsocks 传统版服务端配置
gen_ss_legacy_server_config() {
    local password="$1" port="$2" method="${3:-aes-256-gcm}"
    mkdir -p "$CFG"

    register_protocol "ss-legacy" "$(build_config password "$password" port "$port" method "$method")"
    _save_join_info "ss-legacy" "SS|%s|$port|$method|$password" \
        "gen_ss_legacy_link %s $port $method $password"
    echo "server" > "$CFG/role"
}

# Snell v4 服务端配置
gen_snell_server_config() {
    local psk="$1" port="$2" version="${3:-4}"
    mkdir -p "$CFG"

    local listen_addr="0.0.0.0"
    local ipv6_enabled="false"
    if [[ "$version" != "4" ]]; then
        listen_addr=$(_listen_addr)
        [[ "$listen_addr" == "::" ]] && ipv6_enabled="true"
    else
        _has_ipv6 && ipv6_enabled="true"
    fi

    cat > "$CFG/snell.conf" << EOF
[snell-server]
listen = $(_fmt_hostport "$listen_addr" "$port")
psk = $psk
ipv6 = $ipv6_enabled
obfs = off
EOF

    register_protocol "snell" "$(build_config psk "$psk" port "$port" version "$version")"

    _save_join_info "snell" "SNELL|%s|$port|$psk|$version" \
        "gen_snell_link %s $port $psk $version"
    cp "$CFG/snell.join" "$CFG/join.txt" 2>/dev/null
    echo "server" > "$CFG/role"
}

# TUIC v5 服务端配置
gen_tuic_server_config() {
    local uuid="$1" password="$2" port="$3" sni="${4:-bing.com}"
    local hop_enable="${5:-0}" hop_start="${6:-20000}" hop_end="${7:-50000}"
    mkdir -p "$CFG"
    
    # 生成自签证书（Sing-box 使用）
    local tuic_cert_dir="$CFG/certs/tuic"
    mkdir -p "$tuic_cert_dir"
    local cert_file="$tuic_cert_dir/server.crt"
    local key_file="$tuic_cert_dir/server.key"
    
    local server_ip=$(get_ipv4)
    [[ -z "$server_ip" ]] && server_ip=$(get_ipv6)
    [[ -z "$server_ip" ]] && server_ip="$sni"
    
    # TUIC 需要证书：检查 SNI 是否为用户自己的域名
    # - 如果是用户域名（不在常见 SNI 列表）→ 尝试复用已有真实证书
    # - 如果是常见域名（如 microsoft.com）→ 后续生成自签证书
    local is_common_sni=false
    for common_sni in "${COMMON_SNI_LIST[@]}"; do
        if [[ "$sni" == "$common_sni" ]]; then
            is_common_sni=true
            break
        fi
    done
    
    if [[ "$is_common_sni" == "false" ]]; then
        # 用户自己的域名：检查是否有真实证书可复用
        if [[ -f "$CFG/certs/server.crt" && -f "$CFG/certs/server.key" ]]; then
            local cert_cn=$(openssl x509 -in "$CFG/certs/server.crt" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
            if [[ "$cert_cn" == "$sni" ]]; then
                _ok "复用现有真实证书 (域名: $sni)"
            fi
        fi
    fi
    
    # 生成独立自签证书（无论是否有 ACME 证书都生成，Sing-box 配置会智能选择）
    if [[ ! -f "$cert_file" ]]; then
        _info "为 TUIC 生成独立自签证书 (SNI: $sni)..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$key_file" -out "$cert_file" \
            -subj "/CN=$sni" -days 36500 \
            -addext "subjectAltName=DNS:$sni" \
            -addext "basicConstraints=critical,CA:FALSE" \
            -addext "extendedKeyUsage=serverAuth" 2>/dev/null
        chmod 600 "$key_file"
        _ok "TUIC 自签证书生成完成"
    fi

    # 写入数据库（Sing-box 从数据库读取配置生成 singbox.json）
    register_protocol "tuic" "$(build_config \
        uuid "$uuid" password "$password" port "$port" sni "$sni" \
        hop_enable "$hop_enable" hop_start "$hop_start" hop_end "$hop_end")"
    
    # 保存 join 信息
    local extra_lines=()
    [[ "$hop_enable" == "1" ]] && extra_lines=("" "# 端口跳跃已启用" "# 客户端请手动将端口改为: ${hop_start}-${hop_end}")
    
    _save_join_info "tuic" "TUIC|%s|$port|$uuid|$password|$sni" \
        "gen_tuic_link %s $port $uuid $password $sni" "${extra_lines[@]}"
    cp "$CFG/tuic.join" "$CFG/join.txt" 2>/dev/null
    echo "server" > "$CFG/role"
}

# AnyTLS 服务端配置
gen_anytls_server_config() {
    local password="$1" port="$2" sni="${3:-bing.com}"
    mkdir -p "$CFG"

    register_protocol "anytls" "$(build_config password "$password" port "$port" sni "$sni")"
    _save_join_info "anytls" "ANYTLS|%s|$port|$password|$sni" \
        "gen_anytls_link %s $port $password $sni"
    cp "$CFG/anytls.join" "$CFG/join.txt" 2>/dev/null
    echo "server" > "$CFG/role"
}

# NaïveProxy 服务端配置
gen_naive_server_config() {
    local username="$1" password="$2" port="$3" domain="$4"
    mkdir -p "$CFG"
    
    # NaïveProxy 必须使用域名 + Caddy 自动申请证书
    cat > "$CFG/Caddyfile" << EOF
{
    order forward_proxy before file_server
    admin off
    log {
        output file /var/log/caddy/access.log
        level WARN
    }
}

:${port}, ${domain}:${port} {
    tls {
        protocols tls1.2 tls1.3
    }
    forward_proxy {
        basic_auth ${username} ${password}
        hide_ip
        hide_via
        probe_resistance
    }
    file_server {
        root /var/www/html
    }
}
EOF
    
    # 创建日志目录和伪装页面
    mkdir -p /var/log/caddy /var/www/html
    echo "<html><body><h1>Welcome</h1></body></html>" > /var/www/html/index.html
    
    register_protocol "naive" "$(build_config username "$username" password "$password" port "$port" domain "$domain")"
    # 链接使用域名而不是 IP
    _save_join_info "naive" "NAIVE|$domain|$port|$username|$password" \
        "gen_naive_link $domain $port $username $password"
    cp "$CFG/naive.join" "$CFG/join.txt" 2>/dev/null
    echo "server" > "$CFG/role"
}

# Snell + ShadowTLS 服务端配置 (v4/v5)
gen_snell_shadowtls_server_config() {
    local psk="$1" port="$2" sni="${3:-www.microsoft.com}" stls_password="$4" version="${5:-4}" custom_backend_port="${6:-}"
    mkdir -p "$CFG"
    
    local ipv4=$(get_ipv4) ipv6=$(get_ipv6)
    local protocol_name="snell-shadowtls"
    local snell_bin="snell-server"
    local snell_conf="snell-shadowtls.conf"
    
    if [[ "$version" == "5" ]]; then
        protocol_name="snell-v5-shadowtls"
        snell_bin="snell-server-v5"
        snell_conf="snell-v5-shadowtls.conf"
    fi
    
    # Snell 后端端口 (内部监听)
    local snell_backend_port
    if [[ -n "$custom_backend_port" ]]; then
        snell_backend_port="$custom_backend_port"
    else
        snell_backend_port=$((port + 10000))
        [[ $snell_backend_port -gt 65535 ]] && snell_backend_port=$((port - 10000))
    fi
    
    # Snell 监听地址：ShadowTLS 模式下监听本地 127.0.0.1
    # ShadowTLS 会转发到这个地址
    local listen_addr="127.0.0.1"
    
    local ipv6_line=""
    # Snell v4 不支持 ipv6 配置项，v5 支持
    # 如果系统有 IPv6，启用 IPv6 支持；否则禁用
    if [[ "$version" != "4" ]]; then
        if _has_ipv6; then
            ipv6_line="ipv6 = true"
        else
            ipv6_line="ipv6 = false"
        fi
    fi

    cat > "$CFG/$snell_conf" << EOF
[snell-server]
listen = $listen_addr:$snell_backend_port
psk = $psk
$ipv6_line
obfs = off
EOF
    
    register_protocol "$protocol_name" "$(build_config \
        psk "$psk" port "$port" sni "$sni" stls_password "$stls_password" \
        snell_backend_port "$snell_backend_port" version "$version")"
    echo "server" > "$CFG/role"
}

# SS2022 + ShadowTLS 服务端配置
gen_ss2022_shadowtls_server_config() {
    local password="$1" port="$2" method="${3:-2022-blake3-aes-256-gcm}" sni="${4:-www.microsoft.com}" stls_password="$5" custom_backend_port="${6:-}"
    mkdir -p "$CFG"
    
    # SS2022 后端端口
    local ss_backend_port
    if [[ -n "$custom_backend_port" ]]; then
        ss_backend_port="$custom_backend_port"
    else
        ss_backend_port=$((port + 10000))
        [[ $ss_backend_port -gt 65535 ]] && ss_backend_port=$((port - 10000))
    fi
    
    cat > "$CFG/ss2022-shadowtls-backend.json" << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $ss_backend_port,
    "listen": "127.0.0.1",
    "protocol": "shadowsocks",
    "settings": {"method": "$method", "password": "$password", "network": "tcp,udp"}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    
    register_protocol "ss2022-shadowtls" "$(build_config \
        password "$password" port "$port" method "$method" sni "$sni" \
        stls_password "$stls_password" ss_backend_port "$ss_backend_port")"
    echo "server" > "$CFG/role"
}

# SOCKS5 服务端配置
gen_socks_server_config() {
    local username="$1" password="$2" port="$3" use_tls="${4:-false}" sni="${5:-}"
    local auth_mode="${6:-password}" listen_addr="${7:-}"
    mkdir -p "$CFG"

    # 构建配置 JSON
    local config_json=""
    if [[ "$use_tls" == "true" ]]; then
        config_json=$(build_config username "$username" password "$password" port "$port" tls "true" sni "$sni" auth_mode "$auth_mode" listen_addr "$listen_addr")
    else
        config_json=$(build_config username "$username" password "$password" port "$port" auth_mode "$auth_mode" listen_addr "$listen_addr")
    fi
    register_protocol "socks" "$config_json"

    # SOCKS5 的 join 信息
    local ipv4=$(get_ipv4) ipv6=$(get_ipv6)
    local tls_suffix=""
    [[ "$use_tls" == "true" ]] && tls_suffix="-TLS"

    > "$CFG/socks.join"

    # 无认证模式不生成 join 信息（因为没有用户名密码）
    if [[ "$auth_mode" == "noauth" ]]; then
        echo "# SOCKS5 无认证模式" >> "$CFG/socks.join"
        echo "# 监听地址: $listen_addr" >> "$CFG/socks.join"
        echo "# 端口: $port" >> "$CFG/socks.join"
        [[ "$use_tls" == "true" ]] && echo "# TLS SNI: $sni" >> "$CFG/socks.join"
    else
        # 用户名密码模式生成完整的 join 信息
        if [[ -n "$ipv4" ]]; then
            local data="SOCKS${tls_suffix}|$ipv4|$port|$username|$password"
            [[ "$use_tls" == "true" ]] && data="SOCKS${tls_suffix}|$ipv4|$port|$username|$password|$sni"
            local code=$(printf '%s' "$data" | base64 -w 0 2>/dev/null || printf '%s' "$data" | base64)
            local socks_link
            if [[ "$use_tls" == "true" ]]; then
                socks_link="socks5://${username}:${password}@${ipv4}:${port}?tls=true&sni=${sni}#SOCKS5-TLS-${ipv4}"
            else
                socks_link="socks5://${username}:${password}@${ipv4}:${port}#SOCKS5-${ipv4}"
            fi
            printf '%s\n' "# IPv4" >> "$CFG/socks.join"
            printf '%s\n' "JOIN_V4=$code" >> "$CFG/socks.join"
            printf '%s\n' "SOCKS5_V4=$socks_link" >> "$CFG/socks.join"
        fi
        if [[ -n "$ipv6" ]]; then
            local data="SOCKS${tls_suffix}|[$ipv6]|$port|$username|$password"
            [[ "$use_tls" == "true" ]] && data="SOCKS${tls_suffix}|[$ipv6]|$port|$username|$password|$sni"
            local code=$(printf '%s' "$data" | base64 -w 0 2>/dev/null || printf '%s' "$data" | base64)
            local socks_link
            if [[ "$use_tls" == "true" ]]; then
                socks_link="socks5://${username}:${password}@[$ipv6]:${port}?tls=true&sni=${sni}#SOCKS5-TLS-[$ipv6]"
            else
                socks_link="socks5://${username}:${password}@[$ipv6]:${port}#SOCKS5-[$ipv6]"
            fi
            printf '%s\n' "# IPv6" >> "$CFG/socks.join"
            printf '%s\n' "JOIN_V6=$code" >> "$CFG/socks.join"
            printf '%s\n' "SOCKS5_V6=$socks_link" >> "$CFG/socks.join"
        fi
    fi
    echo "server" > "$CFG/role"
}

# Snell v5 服务端配置
gen_snell_v5_server_config() {
    local psk="$1" port="$2" version="${3:-5}"
    mkdir -p "$CFG"

    local listen_addr=$(_listen_addr)
    local ipv6_enabled="false"
    [[ "$listen_addr" == "::" ]] && ipv6_enabled="true"

    cat > "$CFG/snell-v5.conf" << EOF
[snell-server]
listen = $(_fmt_hostport "$listen_addr" "$port")
psk = $psk
version = $version
ipv6 = $ipv6_enabled
obfs = off
EOF

    register_protocol "snell-v5" "$(build_config psk "$psk" port "$port" version "$version")"
    _save_join_info "snell-v5" "SNELL-V5|%s|$port|$psk|$version" \
        "gen_snell_v5_link %s $port $psk $version"
    cp "$CFG/snell-v5.join" "$CFG/join.txt" 2>/dev/null
    echo "server" > "$CFG/role"
}

#═══════════════════════════════════════════════════════════════════════════════
# 服务端辅助脚本生成
#═══════════════════════════════════════════════════════════════════════════════
create_server_scripts() {
    # Watchdog 脚本 - 服务端监控进程（带重启次数限制）
    cat > "$CFG/watchdog.sh" << 'EOFSCRIPT'
#!/bin/bash
CFG="/etc/vless-reality"
LOG_FILE="/var/log/vless-watchdog.log"
MAX_RESTARTS=5           # 冷却期内最大重启次数
COOLDOWN_PERIOD=300      # 冷却期（秒）
declare -A restart_counts
declare -A first_restart_time

log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    # 日志轮转：超过 2MB 时截断
    local size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ $size -gt 2097152 ]]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

restart_service() {
    local svc="$1"
    local now=$(date +%s)
    local first_time=${first_restart_time[$svc]:-0}
    local count=${restart_counts[$svc]:-0}
    
    # 检查是否在冷却期内
    if [[ $((now - first_time)) -gt $COOLDOWN_PERIOD ]]; then
        # 冷却期已过，重置计数
        restart_counts[$svc]=1
        first_restart_time[$svc]=$now
    else
        # 仍在冷却期内
        ((count++))
        restart_counts[$svc]=$count
        
        if [[ $count -gt $MAX_RESTARTS ]]; then
            log "ERROR: $svc 在 ${COOLDOWN_PERIOD}s 内重启次数超过 $MAX_RESTARTS 次，暂停监控该服务"
            return 1
        fi
    fi
    
    log "INFO: 正在重启 $svc (第 ${restart_counts[$svc]} 次)"
    
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl restart "$svc" 2>&1; then
            log "OK: $svc 重启成功"
            return 0
        else
            log "ERROR: $svc 重启失败"
            return 1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service "$svc" restart 2>&1; then
            log "OK: $svc 重启成功"
            return 0
        else
            log "ERROR: $svc 重启失败"
            return 1
        fi
    else
        log "ERROR: 无法找到服务管理命令"
        return 1
    fi
}

# 获取所有需要监控的服务 (支持多协议) - 从数据库读取
get_all_services() {
    local services=""
    local DB_FILE="$CFG/db.json"
    
    [[ ! -f "$DB_FILE" ]] && { echo ""; return; }
    
    # 检查 Xray 协议
    local xray_protos=$(jq -r '.xray | keys[]' "$DB_FILE" 2>/dev/null)
    [[ -n "$xray_protos" ]] && services+="vless-reality:xray "
    
    # 检查 Sing-box 协议 (hy2/tuic 由 vless-singbox 统一管理)
    local singbox_protos=$(jq -r '.singbox | keys[]' "$DB_FILE" 2>/dev/null)
    local has_singbox=false
    for proto in $singbox_protos; do
        case "$proto" in
            hy2|tuic) has_singbox=true ;;
            snell) services+="vless-snell:snell-server " ;;
            snell-v5) services+="vless-snell-v5:snell-server-v5 " ;;
            anytls) services+="vless-anytls:anytls-server " ;;
            snell-shadowtls) services+="vless-snell-shadowtls:shadow-tls " ;;
            snell-v5-shadowtls) services+="vless-snell-v5-shadowtls:shadow-tls " ;;
            ss2022-shadowtls) services+="vless-ss2022-shadowtls:shadow-tls " ;;
        esac
    done
    [[ "$has_singbox" == "true" ]] && services+="vless-singbox:sing-box "
    
    echo "$services"
}

log "INFO: Watchdog 启动"

while true; do
    for svc_info in $(get_all_services); do
        IFS=':' read -r svc_name proc_name <<< "$svc_info"
        # 多种方式检测进程 (使用兼容函数)
        if ! _pgrep "$proc_name" && ! pgrep -f "$proc_name" > /dev/null 2>&1; then
            log "CRITICAL: $proc_name 进程不存在，尝试重启 $svc_name..."
            restart_service "$svc_name"
            sleep 5
        fi
    done
    sleep 60
done
EOFSCRIPT

    # Hysteria2 端口跳跃规则脚本 (服务端) - 从数据库读取
    if is_protocol_installed "hy2"; then
        cat > "$CFG/hy2-nat.sh" << 'EOFSCRIPT'
#!/bin/bash
CFG=/etc/vless-reality
DB_FILE="$CFG/db.json"

[[ ! -f "$DB_FILE" ]] && exit 0

# 检查 iptables 是否存在
if ! command -v iptables &>/dev/null; then
    echo "[hy2-nat] iptables 未安装，端口跳跃不可用" >&2
    exit 1
fi

# 从数据库读取配置
port=$(jq -r '.singbox.hy2.port // empty' "$DB_FILE" 2>/dev/null)
hop_enable=$(jq -r '.singbox.hy2.hop_enable // empty' "$DB_FILE" 2>/dev/null)
hop_start=$(jq -r '.singbox.hy2.hop_start // empty' "$DB_FILE" 2>/dev/null)
hop_end=$(jq -r '.singbox.hy2.hop_end // empty' "$DB_FILE" 2>/dev/null)

[[ -z "$port" ]] && exit 0

hop_start="${hop_start:-20000}"
hop_end="${hop_end:-50000}"

if ! [[ "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]] || [[ "$hop_start" -ge "$hop_end" ]]; then
  exit 0
fi

# 清理旧规则 (IPv4)
iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
# 清理旧规则 (IPv6)
ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null

[[ "${hop_enable:-0}" != "1" ]] && exit 0

# 添加规则 (IPv4)
iptables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port
iptables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port

# 添加规则 (IPv6)
ip6tables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port
ip6tables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port
EOFSCRIPT
    fi

    # TUIC 端口跳跃规则脚本 (服务端) - 从数据库读取
    if is_protocol_installed "tuic"; then
        cat > "$CFG/tuic-nat.sh" << 'EOFSCRIPT'
#!/bin/bash
CFG=/etc/vless-reality
DB_FILE="$CFG/db.json"

[[ ! -f "$DB_FILE" ]] && exit 0

# 检查 iptables 是否存在
if ! command -v iptables &>/dev/null; then
    echo "[tuic-nat] iptables 未安装，端口跳跃不可用" >&2
    exit 1
fi

# 从数据库读取配置
port=$(jq -r '.singbox.tuic.port // empty' "$DB_FILE" 2>/dev/null)
hop_enable=$(jq -r '.singbox.tuic.hop_enable // empty' "$DB_FILE" 2>/dev/null)
hop_start=$(jq -r '.singbox.tuic.hop_start // empty' "$DB_FILE" 2>/dev/null)
hop_end=$(jq -r '.singbox.tuic.hop_end // empty' "$DB_FILE" 2>/dev/null)

[[ -z "$port" ]] && exit 0

hop_start="${hop_start:-20000}"
hop_end="${hop_end:-50000}"

if ! [[ "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]] || [[ "$hop_start" -ge "$hop_end" ]]; then
  exit 0
fi

# 清理旧规则 (IPv4)
iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
iptables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
# 清理旧规则 (IPv6)
ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null
ip6tables -t nat -D OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null

[[ "${hop_enable:-0}" != "1" ]] && exit 0

# 添加规则 (IPv4)
iptables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port
iptables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || iptables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port

# 添加规则 (IPv6)
ip6tables -t nat -C PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port
ip6tables -t nat -C OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port 2>/dev/null \
  || ip6tables -t nat -A OUTPUT -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports $port
EOFSCRIPT
    fi

    chmod +x "$CFG"/*.sh 2>/dev/null
}

#═══════════════════════════════════════════════════════════════════════════════
# 服务管理
#═══════════════════════════════════════════════════════════════════════════════
create_service() {
    local protocol="${1:-$(get_protocol)}"
    local kind="${PROTO_KIND[$protocol]:-}"
    local service_name="${PROTO_SVC[$protocol]:-}"
    local exec_cmd="${PROTO_EXEC[$protocol]:-}"
    local exec_name="${PROTO_BIN[$protocol]:-}"
    local port password sni stls_password ss_backend_port snell_backend_port

    [[ -z "$service_name" ]] && { _err "未知协议: $protocol"; return 1; }

    # 检查配置是否存在（支持 xray 和 singbox 核心）
    _need_cfg() { 
        local proto="$1" name="$2"
        db_exists "xray" "$proto" || db_exists "singbox" "$proto" || { _err "$name 配置不存在"; return 1; }
    }
    
    # 获取协议配置所在的核心
    # 与 register_protocol 保持一致：SINGBOX_PROTOCOLS 以外的协议都保存在 xray 核心
    _get_proto_core() {
        local proto="$1"
        # 只有 hy2/tuic 保存在 singbox 核心，其他协议（包括所有 shadowtls）都在 xray
        if [[ " $SINGBOX_PROTOCOLS " == *" $proto "* ]]; then
            echo "singbox"
        else
            echo "xray"
        fi
    }

    case "$kind" in
        anytls)
            _need_cfg "anytls" "AnyTLS" || return 1
            port=$(db_get_field "xray" "anytls" "port")
            password=$(db_get_field "xray" "anytls" "password")
            local lh=$(_listen_addr)
            exec_cmd="/usr/local/bin/anytls-server -l $(_fmt_hostport "$lh" "$port") -p ${password}"
            exec_name="anytls-server"
            ;;
        naive)
            _need_cfg "naive" "NaïveProxy" || return 1
            exec_cmd="/usr/local/bin/caddy run --config $CFG/Caddyfile"
            exec_name="caddy"
            ;;
        shadowtls)
            _need_cfg "$protocol" "$protocol" || return 1
            local cfg_core=$(_get_proto_core "$protocol")
            port=$(db_get_field "$cfg_core" "$protocol" "port")
            sni=$(db_get_field "$cfg_core" "$protocol" "sni")
            stls_password=$(db_get_field "$cfg_core" "$protocol" "stls_password")
            if [[ "$protocol" == "ss2022-shadowtls" ]]; then
                ss_backend_port=$(db_get_field "$cfg_core" "$protocol" "ss_backend_port")
            else
                snell_backend_port=$(db_get_field "$cfg_core" "$protocol" "snell_backend_port")
            fi
            local lh=$(_listen_addr)
            exec_cmd="/usr/local/bin/shadow-tls --v3 server --listen $(_fmt_hostport "$lh" "$port") --server 127.0.0.1:${ss_backend_port:-$snell_backend_port} --tls ${sni}:443 --password ${stls_password}"
            exec_name="shadow-tls"
            ;;
    esac

    _write_openrc() { # name desc cmd args [env]
        local name="$1" desc="$2" cmd="$3" args="$4" env="$5"
        cat >"/etc/init.d/${name}" <<EOF
#!/sbin/openrc-run
name="${desc}"
command="${cmd}"
command_args="${args}"
command_background="yes"
pidfile="/run/${name}.pid"
${env:+export ${env}}
depend() { need net; }
EOF
        chmod +x "/etc/init.d/${name}"
    }

    _write_systemd() { # name desc exec pre before env [requires] [after]
        local name="$1" desc="$2" exec="$3" pre="$4" before="$5" env="$6" requires="${7:-}" after="${8:-}"
        cat >"/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${desc}
After=network.target${after:+ ${after}}
${before:+Before=${before}}
${requires:+Requires=${requires}}

[Service]
Type=simple
${env:+Environment=${env}}
${pre:+ExecStartPre=${pre}}
ExecStart=${exec}
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
    }

    if [[ "$DISTRO" == "alpine" ]]; then
        local cmd="${exec_cmd%% *}" args=""; [[ "$exec_cmd" == *" "* ]] && args="${exec_cmd#* }"
        local env=""
        # ShadowTLS CPU 100% 修复: 高版本内核 io_uring 问题
        [[ "$kind" == "shadowtls" ]] && env="MONOIO_FORCE_LEGACY_DRIVER=1"
        _write_openrc "$service_name" "Proxy Server ($protocol)" "$cmd" "$args" "$env"

        if [[ "$kind" == "shadowtls" ]]; then
            _write_openrc "${BACKEND_NAME[$protocol]}" "${BACKEND_DESC[$protocol]}" "${BACKEND_EXEC[$protocol]%% *}" "${BACKEND_EXEC[$protocol]#* }" ""
        fi

        _write_openrc "vless-watchdog" "VLESS Watchdog" "/bin/bash" "$CFG/watchdog.sh" ""
    else
        local pre="" env="" requires="" after=""
        [[ "$kind" == "hy2" ]] && pre="-/bin/bash $CFG/hy2-nat.sh"
        [[ "$kind" == "tuic" ]] && pre="-/bin/bash $CFG/tuic-nat.sh"
        # ShadowTLS CPU 100% 修复: 高版本内核 io_uring 问题
        if [[ "$kind" == "shadowtls" ]]; then
            env="MONOIO_FORCE_LEGACY_DRIVER=1"
            # 主服务依赖 backend 服务
            requires="${BACKEND_NAME[$protocol]}.service"
            after="${BACKEND_NAME[$protocol]}.service"
        fi
        _write_systemd "$service_name" "Proxy Server ($protocol)" "$exec_cmd" "$pre" "" "$env" "$requires" "$after"

        if [[ "$kind" == "shadowtls" ]]; then
            # backend 服务在主服务之前启动
            _write_systemd "${BACKEND_NAME[$protocol]}" "${BACKEND_DESC[$protocol]}" "${BACKEND_EXEC[$protocol]}" "" "${service_name}.service" ""
        fi

        cat > /etc/systemd/system/vless-watchdog.service << EOF
[Unit]
Description=VLESS Watchdog
After=${service_name}.service

[Service]
Type=simple
ExecStart=/bin/bash $CFG/watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        # 写入 unit 文件后执行 daemon-reload
        systemctl daemon-reload 2>/dev/null
    fi
}



svc() { # svc action service_name
    local action="$1" name="$2" err=/tmp/svc_error.log
    _svc_try() { : >"$err"; "$@" 2>"$err" || { [[ -s "$err" ]] && { _err "服务${action}失败:"; cat "$err"; }; rm -f "$err"; return 1; }; rm -f "$err"; }

    if [[ "$DISTRO" == "alpine" ]]; then
        case "$action" in
            start|restart) _svc_try rc-service "$name" "$action" ;;
            stop)    rc-service "$name" stop &>/dev/null ;;
            enable)  rc-update add "$name" default &>/dev/null ;;
            disable) rc-update del "$name" default &>/dev/null ;;
            reload)  rc-service "$name" reload &>/dev/null || rc-service "$name" restart &>/dev/null ;;
            status)
                rc-service "$name" status &>/dev/null && return 0
                local pidfile="/run/${name}.pid"
                [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null && return 0
                local p="${SVC_PROC[$name]:-}"
                [[ -n "$p" ]] && _pgrep "$p" && return 0
                return 1
                ;;
        esac
    else
        case "$action" in
            start|restart)
                _svc_try systemctl "$action" "$name" || { _err "详细状态信息:"; systemctl status "$name" --no-pager -l || true; return 1; }
                ;;
            stop|enable|disable) systemctl "$action" "$name" &>/dev/null ;;
            reload) systemctl reload "$name" &>/dev/null || systemctl restart "$name" &>/dev/null ;;
            status)
                local state; state=$(systemctl is-active "$name" 2>/dev/null)
                [[ "$state" == active || "$state" == activating ]]
                ;;
        esac
    fi
}

# 通用服务启动/重启辅助函数
# 用法: _start_core_service "服务名" "进程名" "协议列表" "配置生成函数"
_start_core_service() {
    local service_name="$1"
    local process_name="$2"
    local protocols="$3"
    local gen_config_func="$4"
    local failed_services_ref="$5"
    
    local is_running=false
    svc status "$service_name" >/dev/null 2>&1 && is_running=true
    
    local action_word="启动"
    [[ "$is_running" == "true" ]] && action_word="更新"
    
    _info "${action_word} ${process_name} 配置..."
    
    if ! $gen_config_func; then
        _err "${process_name} 配置生成失败"
        return 1
    fi
    
    svc enable "$service_name" 2>/dev/null
    
    local svc_action="start"
    [[ "$is_running" == "true" ]] && svc_action="restart"
    
    if ! svc $svc_action "$service_name"; then
        _err "${process_name} 服务${action_word}失败"
        return 1
    fi
    
    # 等待进程启动
    local wait_count=0
    local max_wait=$([[ "$is_running" == "true" ]] && echo 5 || echo 10)
    while [[ $wait_count -lt $max_wait ]]; do
        if _pgrep "$process_name"; then
            local proto_list=$(echo $protocols | tr '\n' ' ')
            _ok "${process_name} 服务已${action_word} (协议: $proto_list)"
            return 0
        fi
        sleep 1
        ((wait_count++))
    done
    
    _err "${process_name} 进程未运行"
    return 1
}

start_services() {
    local failed_services=()
    rm -f "$CFG/paused"
    
    # 初始化数据库
    init_db
    
    # 服务端：启动所有已注册的协议服务
    
    # 1. 启动 Xray 服务（TCP 协议）
    local xray_protocols=$(get_xray_protocols)
    if [[ -n "$xray_protocols" ]]; then
        _start_core_service "vless-reality" "xray" "$xray_protocols" "generate_xray_config" || \
            failed_services+=("vless-reality")
    fi
    
    # 2. 启动 Sing-box 服务（UDP/QUIC 协议: Hy2/TUIC）
    local singbox_protocols=$(get_singbox_protocols)
    if [[ -n "$singbox_protocols" ]]; then
        # 确保 Sing-box 已安装
        if ! check_cmd sing-box; then
            _info "安装 Sing-box..."
            install_singbox || { _err "Sing-box 安装失败"; failed_services+=("vless-singbox"); }
        fi
        
        if check_cmd sing-box; then
            create_singbox_service
            _start_core_service "vless-singbox" "sing-box" "$singbox_protocols" "generate_singbox_config" || \
                failed_services+=("vless-singbox")
        fi
    fi
    
    # 3. 启动独立进程协议 (Snell 等闭源协议)
    local standalone_protocols=$(get_standalone_protocols)
    local ind_proto
    for ind_proto in $standalone_protocols; do
        local service_name="vless-${ind_proto}"
        
        # ShadowTLS 组合协议需要先启动/重启后端服务
        case "$ind_proto" in
            snell-shadowtls|snell-v5-shadowtls|ss2022-shadowtls)
                local backend_svc="vless-${ind_proto}-backend"
                svc enable "$backend_svc"
                if svc status "$backend_svc" >/dev/null 2>&1; then
                    svc restart "$backend_svc" || true
                else
                    if ! svc start "$backend_svc"; then
                        _err "${ind_proto} 后端服务启动失败"
                        failed_services+=("$backend_svc")
                        continue
                    fi
                fi
                sleep 1
                ;;
        esac
        
        svc enable "$service_name"
        
        if svc status "$service_name" >/dev/null 2>&1; then
            # 服务已在运行，需要重启以加载新配置
            _info "重启 $ind_proto 服务以加载新配置..."
            if ! svc restart "$service_name"; then
                _err "$ind_proto 服务重启失败"
                failed_services+=("$service_name")
            else
                sleep 1
                _ok "$ind_proto 服务已重启"
            fi
        else
            if ! svc start "$service_name"; then
                _err "$ind_proto 服务启动失败"
                failed_services+=("$service_name")
            else
                sleep 1
                _ok "$ind_proto 服务已启动"
            fi
        fi
    done
    
    # 启动 Watchdog
    svc enable vless-watchdog 2>/dev/null
    svc start vless-watchdog 2>/dev/null
    
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        _warn "以下服务启动失败: ${failed_services[*]}"
        return 1
    fi
    
    return 0
}

stop_services() {
    local stopped_services=()
    
    is_service_active() {
        local svc_name="$1"
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-service "$svc_name" status &>/dev/null
        else
            systemctl is-active --quiet "$svc_name" 2>/dev/null
        fi
    }
    
    # 停止 Watchdog
    if is_service_active vless-watchdog; then
        svc stop vless-watchdog 2>/dev/null && stopped_services+=("vless-watchdog")
    fi
    
    # 停止 Xray 服务
    if is_service_active vless-reality; then
        svc stop vless-reality 2>/dev/null && stopped_services+=("vless-reality")
    fi
    
    # 停止 Sing-box 服务 (Hy2/TUIC)
    if is_service_active vless-singbox; then
        svc stop vless-singbox 2>/dev/null && stopped_services+=("vless-singbox")
    fi
    
    # 停止独立进程协议服务 (Snell 等)
    for proto in $STANDALONE_PROTOCOLS; do
        local service_name="vless-${proto}"
        if is_service_active "$service_name"; then
            svc stop "$service_name" 2>/dev/null && stopped_services+=("$service_name")
        fi
    done
    
    # 停止 ShadowTLS 组合协议的后端服务
    for backend_svc in vless-snell-shadowtls-backend vless-snell-v5-shadowtls-backend vless-ss2022-shadowtls-backend; do
        if is_service_active "$backend_svc"; then
            svc stop "$backend_svc" 2>/dev/null && stopped_services+=("$backend_svc")
        fi
    done
    
    # 清理 Hysteria2 端口跳跃 NAT 规则
    cleanup_hy2_nat_rules
    
    if [[ ${#stopped_services[@]} -gt 0 ]]; then
        echo "  ▸ 已停止服务: ${stopped_services[*]}"
    else
        echo "  ▸ 没有运行中的服务需要停止"
    fi
}

# 自动更新系统脚本 (启动时检测)
_auto_update_system_script() {
    local system_script="/usr/local/bin/vless-server.sh"
    local current_script="$0"
    
    # 获取当前脚本的绝对路径
    local real_path=""
    if [[ "$current_script" == /* ]]; then
        real_path="$current_script"
    elif [[ "$current_script" != "bash" && "$current_script" != "-bash" && -f "$current_script" ]]; then
        real_path="$(cd "$(dirname "$current_script")" 2>/dev/null && pwd)/$(basename "$current_script")"
    fi
    
    # 如果当前脚本不是系统脚本，检查是否需要更新
    if [[ -n "$real_path" && -f "$real_path" && "$real_path" != "$system_script" ]]; then
        local need_update=false
        
        if [[ ! -f "$system_script" ]]; then
            need_update=true
        else
            # 用 md5 校验文件内容是否不同
            local cur_md5 sys_md5
            cur_md5=$(md5sum "$real_path" 2>/dev/null | cut -d' ' -f1)
            sys_md5=$(md5sum "$system_script" 2>/dev/null | cut -d' ' -f1)
            [[ "$cur_md5" != "$sys_md5" ]] && need_update=true
        fi
        
        if [[ "$need_update" == "true" ]]; then
            cp -f "$real_path" "$system_script" 2>/dev/null
            chmod +x "$system_script" 2>/dev/null
            ln -sf "$system_script" /usr/local/bin/vless 2>/dev/null
            ln -sf "$system_script" /usr/bin/vless 2>/dev/null
            hash -r 2>/dev/null
            _ok "系统脚本已同步更新 (v$VERSION)"
        fi
    fi
}

create_shortcut() {
    local system_script="/usr/local/bin/vless-server.sh"
    local current_script="$0"

    # 获取当前脚本的绝对路径（解析软链接）
    local real_path
    if [[ "$current_script" == /* ]]; then
        # 解析软链接获取真实路径
        real_path=$(readlink -f "$current_script" 2>/dev/null || echo "$current_script")
    elif [[ "$current_script" == "bash" || "$current_script" == "-bash" ]]; then
        # 内存运行模式 (curl | bash)，从网络下载
        real_path=""
    else
        real_path="$(cd "$(dirname "$current_script")" 2>/dev/null && pwd)/$(basename "$current_script")"
        # 解析软链接
        real_path=$(readlink -f "$real_path" 2>/dev/null || echo "$real_path")
    fi

    # 如果系统目录没有脚本，需要创建
    if [[ ! -f "$system_script" ]]; then
        if [[ -n "$real_path" && -f "$real_path" ]]; then
            # 从当前脚本复制（不删除原文件）
            cp -f "$real_path" "$system_script"
        else
            # 内存运行模式，从网络下载
            if ! _download_script_to "$system_script"; then
                _warn "无法下载脚本到系统目录"
                return 1
            fi
        fi
    elif [[ -n "$real_path" && -f "$real_path" && "$real_path" != "$system_script" ]]; then
        # 系统目录已有脚本，用当前脚本更新（不删除原文件）
        cp -f "$real_path" "$system_script"
    fi

    chmod +x "$system_script" 2>/dev/null

    # 创建软链接
    ln -sf "$system_script" /usr/local/bin/vless 2>/dev/null
    ln -sf "$system_script" /usr/bin/vless 2>/dev/null
    hash -r 2>/dev/null

    _ok "快捷命令已创建: vless"
}

remove_shortcut() { 
    rm -f /usr/local/bin/vless /usr/local/bin/vless-server.sh /usr/bin/vless 2>/dev/null
    _ok "快捷命令已移除"
}


#═══════════════════════════════════════════════════════════════════════════════
# 分流管理 (WARP + 路由规则) - 双模式支持
# 模式 1: WGCF (Xray 内置 WireGuard) - UDP 协议，性能好但可能被封锁
# 模式 2: 官方客户端 (SOCKS5 代理) - TCP 协议，绕过 UDP 封锁
#═══════════════════════════════════════════════════════════════════════════════

# WARP 配置存储路径
WARP_CONF_FILE="$CFG/warp.json"
WARP_OFFICIAL_PORT=40000  # 官方客户端 SOCKS5 端口

# 保存 WARP 模式到数据库 (wgcf 或 official)
db_set_warp_mode() {
    local mode="$1"
    [[ ! -f "$DB_FILE" ]] && init_db
    local tmp=$(mktemp)
    jq --arg m "$mode" '.routing.warp_mode = $m' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 获取 WARP 模式
db_get_warp_mode() {
    [[ ! -f "$DB_FILE" ]] && echo "wgcf" && return
    local mode=$(jq -r '.routing.warp_mode // "wgcf"' "$DB_FILE" 2>/dev/null)
    echo "$mode"
}

# WARP 状态检测 (支持双模式)
warp_status() {
    local mode=$(db_get_warp_mode)
    
    if [[ "$mode" == "official" ]]; then
        # 检查官方客户端状态
        if check_cmd warp-cli; then
            local status_output=$(warp-cli status 2>/dev/null)
            if echo "$status_output" | grep -qiE "Connected|Status:.*Connected"; then
                echo "connected"
                return
            elif echo "$status_output" | grep -qiE "Registration|Account|Disconnected|Status:"; then
                echo "registered"
                return
            fi
        fi
        echo "not_configured"
    else
        # 检查 WGCF 配置
        if [[ -f "$WARP_CONF_FILE" ]]; then
            local private_key=$(jq -r '.private_key // empty' "$WARP_CONF_FILE" 2>/dev/null)
            if [[ -n "$private_key" ]]; then
                echo "configured"
                return
            fi
        fi
        echo "not_configured"
    fi
}

# 下载 wgcf 工具
download_wgcf() {
    # 检查 file 命令是否存在，不存在则尝试安装
    if ! command -v file &>/dev/null; then
        echo -ne "  ${C}▸${NC} 检测到缺少 file 命令，正在安装..."
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
            apt-get update -qq && apt-get install -y file >/dev/null 2>&1
        elif [[ "$DISTRO" == "centos" ]]; then
            yum install -y file >/dev/null 2>&1
        elif [[ "$DISTRO" == "alpine" ]]; then
            apk add --no-cache file >/dev/null 2>&1
        fi
        
        if command -v file &>/dev/null; then
            echo -e " ${G}✓${NC}"
        else
            echo -e " ${Y}⚠${NC}"
            echo -e "  ${Y}提示${NC}: file 命令安装失败，将使用简化验证（仅检查文件大小）"
        fi
    fi

    # 检查是否已存在有效的 wgcf
    if [[ -x /usr/local/bin/wgcf ]]; then
        if command -v file &>/dev/null && file "/usr/local/bin/wgcf" 2>/dev/null | grep -q "ELF"; then
            return 0
        elif ! command -v file &>/dev/null && [[ -s /usr/local/bin/wgcf ]] && [[ $(stat -f%z /usr/local/bin/wgcf 2>/dev/null || stat -c%s /usr/local/bin/wgcf 2>/dev/null) -gt 100000 ]]; then
            # 降级验证：文件大于 100KB 且可执行
            return 0
        fi
    fi
    
    local arch=$(uname -m)
    local wgcf_arch="amd64"
    [[ "$arch" == "aarch64" ]] && wgcf_arch="arm64"
    [[ "$arch" == "armv7l" ]] && wgcf_arch="armv7"
    
    # 自动获取最新版本
    echo -ne "  ${C}▸${NC} 获取 wgcf 最新版本..."
    local wgcf_ver=$(curl -sL --connect-timeout 10 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | jq -r '.tag_name' 2>/dev/null | tr -d 'v')
    [[ -z "$wgcf_ver" || "$wgcf_ver" == "null" ]] && wgcf_ver="2.2.29"
    echo -e " v${wgcf_ver}"
    
    # 镜像源列表（优先使用支持 IPv6 的镜像，IPv4 直连放后面备选）
    local wgcf_urls=(
        "https://gh-proxy.com/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://ghps.cc/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://gh.ddlc.top/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
        "https://ghproxy.net/https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_${wgcf_arch}"
    )
    
    # 确保目录存在并可写
    if [[ ! -d "/usr/local/bin" ]]; then
        echo -e "  ${Y}提示${NC}: /usr/local/bin 目录不存在，正在创建..."
        mkdir -p "/usr/local/bin" 2>/dev/null || {
            _err "无法创建 /usr/local/bin 目录（权限不足？）"
            return 1
        }
    fi
    
    if [[ ! -w "/usr/local/bin" ]]; then
        _err "/usr/local/bin 目录不可写，请检查权限或使用 sudo"
        return 1
    fi
    
    # 删除旧文件（如果存在）
    if [[ -f "/usr/local/bin/wgcf" ]]; then
        echo -ne "  ${C}▸${NC} 删除旧版本..."
        if rm -f "/usr/local/bin/wgcf" 2>/dev/null; then
            echo -e " ${G}✓${NC}"
        else
            echo -e " ${R}✗${NC}"
            _err "无法删除旧文件（权限不足或文件被锁定）"
            return 1
        fi
    fi
    
    local try_num=1
    local last_error=""
    for url in "${wgcf_urls[@]}"; do
        echo -e "  ${C}▸${NC} 下载 wgcf (尝试 $try_num/${#wgcf_urls[@]})"
        echo -e "    ${D}地址: $url${NC}"
        
        # 捕获详细错误
        last_error=$(curl -fsSL -o "/usr/local/bin/wgcf" -A "Mozilla/5.0" --max-redirs 5 --connect-timeout 15 --max-time 90 "$url" 2>&1)
        local curl_ret=$?
        
        # 详细的验证流程
        if [[ $curl_ret -eq 0 ]]; then
            if [[ ! -f "/usr/local/bin/wgcf" ]]; then
                echo -e "    ${R}✗ 文件未生成${NC}"
            elif [[ ! -s "/usr/local/bin/wgcf" ]]; then
                echo -e "    ${R}✗ 文件为空${NC}"
                rm -f "/usr/local/bin/wgcf"
            elif command -v file &>/dev/null; then
                # 有 file 命令：完整验证
                if ! file "/usr/local/bin/wgcf" 2>/dev/null | grep -q "ELF"; then
                    echo -e "    ${R}✗ 文件格式错误（非 ELF 可执行文件）${NC}"
                    echo -e "    ${D}文件类型: $(file "/usr/local/bin/wgcf" 2>/dev/null)${NC}"
                    rm -f "/usr/local/bin/wgcf"
                else
                    chmod +x "/usr/local/bin/wgcf"
                    echo -e "    ${G}✓ 下载成功${NC}"
                    return 0
                fi
            else
                # 无 file 命令：降级验证（检查文件大小）
                local filesize=$(stat -f%z "/usr/local/bin/wgcf" 2>/dev/null || stat -c%s "/usr/local/bin/wgcf" 2>/dev/null)
                if [[ $filesize -gt 100000 ]]; then
                    chmod +x "/usr/local/bin/wgcf"
                    echo -e "    ${G}✓ 下载成功${NC} ${D}(文件大小: $((filesize/1024))KB)${NC}"
                    return 0
                else
                    echo -e "    ${R}✗ 文件大小异常 (${filesize} 字节)${NC}"
                    rm -f "/usr/local/bin/wgcf"
                fi
            fi
        else
            echo -e "    ${R}✗ 下载失败 (curl 返回码: $curl_ret)${NC}"
        fi
        
        [[ -n "$last_error" ]] && echo -e "    ${D}错误: $last_error${NC}"
        rm -f "/usr/local/bin/wgcf"
        ((try_num++))
        sleep 1
    done
    
    _err "wgcf 下载失败"
    echo -e "  ${Y}提示${NC}: 所有镜像源均不可用，可能是网络问题"
    echo -e "  ${Y}手动下载${NC}: https://github.com/ViRb3/wgcf/releases"
    echo -e "  ${Y}下载后${NC}: 将文件上传到 /usr/local/bin/wgcf 并执行 chmod +x"
    return 1
}

# 注册 WARP 账号并获取 WireGuard 配置
register_warp() {
    _info "注册 Cloudflare WARP 账号..."
    
    if ! download_wgcf; then
        _err "wgcf 下载失败，无法注册 WARP"
        return 1
    fi
    
    cd /tmp
    rm -f /tmp/wgcf-account.toml /tmp/wgcf-profile.conf 2>/dev/null
    
    # 注册 WARP 账户
    echo -ne "  ${C}▸${NC} 注册 WARP 账户..."
    local register_output
    register_output=$(/usr/local/bin/wgcf register --accept-tos 2>&1)
    local register_ret=$?
    
    if [[ $register_ret -ne 0 ]] || [[ ! -f /tmp/wgcf-account.toml ]]; then
        echo -e " ${R}✗${NC}"
        _err "WARP 账户注册失败"
        [[ -n "$register_output" ]] && echo -e "  ${D}$register_output${NC}"
        return 1
    fi
    echo -e " ${G}✓${NC}"
    
    # 生成 WireGuard 配置
    echo -ne "  ${C}▸${NC} 生成 WireGuard 配置..."
    local generate_output
    generate_output=$(/usr/local/bin/wgcf generate 2>&1)
    local generate_ret=$?
    
    if [[ $generate_ret -ne 0 ]] || [[ ! -f /tmp/wgcf-profile.conf ]]; then
        echo -e " ${R}✗${NC}"
        _err "配置生成失败"
        [[ -n "$generate_output" ]] && echo -e "  ${D}$generate_output${NC}"
        return 1
    fi
    echo -e " ${G}✓${NC}"
    
    # 解析配置并保存到 JSON
    echo -ne "  ${C}▸${NC} 保存配置..."
    parse_and_save_warp_config /tmp/wgcf-profile.conf
    rm -f /tmp/wgcf-account.toml /tmp/wgcf-profile.conf
    echo -e " ${G}✓${NC}"
    
    # 显示配置信息
    echo ""
    _line
    echo -e "  ${G}WGCF 配置成功${NC}"
    _line
    local endpoint=$(jq -r '.endpoint' "$WARP_CONF_FILE" 2>/dev/null)
    local address_v4=$(jq -r '.address_v4' "$WARP_CONF_FILE" 2>/dev/null)
    local address_v6=$(jq -r '.address_v6' "$WARP_CONF_FILE" 2>/dev/null)
    echo -e "  WARP 端点: ${C}${endpoint}${NC}"
    echo -e "  内网 IPv4: ${G}${address_v4}${NC}"
    echo -e "  内网 IPv6: ${D}${address_v6}${NC}"
    _line
    
    return 0
}

# WARP IPv6 端点优选
# 测试多个 Cloudflare WARP IPv6 端点，选择延迟最低的
_select_best_warp_ipv6_endpoint() {
    local port="${1:-2408}"
    local endpoints=(
        "2606:4700:d0::a29f:c001"
        "2606:4700:d0::a29f:c002"
        "2606:4700:d1::a29f:c001"
        "2606:4700:d1::a29f:c002"
    )
    
    local best_endpoint="${endpoints[0]}"
    local best_latency=9999
    
    echo -ne "  ${C}▸${NC} 优选 IPv6 端点..." >&2
    
    for ep in "${endpoints[@]}"; do
        # ping6 测试延迟，取平均值
        local latency=$(ping6 -c 2 -W 1 "$ep" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | awk '{sum+=$1} END {if(NR>0) printf "%.0f", sum/NR; else print 9999}')
        [[ -z "$latency" ]] && latency=9999
        
        if [[ "$latency" -lt "$best_latency" ]]; then
            best_latency="$latency"
            best_endpoint="$ep"
        fi
    done
    
    if [[ "$best_latency" -lt 9999 ]]; then
        echo -e " ${G}${best_endpoint}${NC} (${best_latency}ms)" >&2
    else
        echo -e " ${Y}${best_endpoint}${NC} (默认)" >&2
    fi
    
    echo "[${best_endpoint}]:${port}"
}

# 规范化 base64 字符串，自动添加正确的填充符
normalize_base64() {
    local input="$1"
    local len=${#input}
    local mod=$((len % 4))

    # 如果长度不是 4 的倍数，添加 = 填充
    if [[ $mod -eq 2 ]]; then
        echo "${input}=="
    elif [[ $mod -eq 3 ]]; then
        echo "${input}="
    else
        echo "$input"
    fi
}

# 解析 wgcf 生成的配置并保存为 JSON
parse_and_save_warp_config() {
    local conf_file="$1"
    
    local private_key=$(grep "PrivateKey" "$conf_file" | cut -d'=' -f2 | xargs)
    private_key=$(normalize_base64 "$private_key")
    local public_key=$(grep "PublicKey" "$conf_file" | cut -d'=' -f2 | xargs)
    public_key=$(normalize_base64 "$public_key")
    local endpoint=$(grep "Endpoint" "$conf_file" | cut -d'=' -f2 | xargs)
    
    # 自动检测：纯 IPv6 服务器使用优选的 IPv6 端点
    local has_ipv4=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null)
    if [[ -z "$has_ipv4" ]]; then
        # 无 IPv4，自动优选 WARP IPv6 端点
        local ep_port=$(echo "$endpoint" | grep -oE ':[0-9]+$' | tr -d ':')
        [[ -z "$ep_port" ]] && ep_port="2408"
        endpoint=$(_select_best_warp_ipv6_endpoint "$ep_port")
    fi
    
    # 解析 Address 行，可能有多行或逗号分隔
    local addresses=$(grep "Address" "$conf_file" | cut -d'=' -f2 | tr -d ' ' | tr '\n' ',' | sed 's/,$//')
    
    # 分离 IPv4 和 IPv6
    local address_v4=""
    local address_v6=""
    
    IFS=',' read -ra ADDR_ARRAY <<< "$addresses"
    for addr in "${ADDR_ARRAY[@]}"; do
        if [[ "$addr" == *":"* ]]; then
            # IPv6 地址
            address_v6="$addr"
        else
            # IPv4 地址
            address_v4="$addr"
        fi
    done
    
    mkdir -p "$CFG"
    jq -n \
        --arg pk "$private_key" \
        --arg pub "$public_key" \
        --arg v4 "$address_v4" \
        --arg v6 "$address_v6" \
        --arg ep "$endpoint" \
    '{
        private_key: $pk,
        public_key: $pub,
        address_v4: $v4,
        address_v6: $v6,
        endpoint: $ep,
        reserved: [0, 0, 0]
    }' > "$WARP_CONF_FILE"
}

# 生成 Xray WARP outbound 配置 (支持 WireGuard 和 SOCKS5 双模式)
gen_xray_warp_outbound() {
    local warp_mode=$(db_get_warp_mode)
    
    [[ -z "$warp_mode" || "$warp_mode" == "disabled" ]] && return
    
    # === 模式 A: 官方客户端 (SOCKS5) ===
    if [[ "$warp_mode" == "official" ]]; then
        # 检查官方客户端是否运行
        if ! check_cmd warp-cli; then
            return
        fi
        if [[ ! "$WARP_OFFICIAL_PORT" =~ ^[0-9]+$ ]] || [[ "$WARP_OFFICIAL_PORT" -lt 1 || "$WARP_OFFICIAL_PORT" -gt 65535 ]]; then
            return
        fi
        
        # 生成指向本地 SOCKS5 端口的出站
        jq -n --argjson port "$WARP_OFFICIAL_PORT" '{
            tag: "warp",
            protocol: "socks",
            settings: {
                servers: [{
                    address: "127.0.0.1",
                    port: $port
                }]
            }
        }'
        return
    fi
    
    # === 模式 B: WGCF (WireGuard) ===
    [[ "$warp_mode" != "wgcf" ]] && return
    [[ ! -f "$WARP_CONF_FILE" ]] && return
    
    local private_key=$(jq -r '.private_key' "$WARP_CONF_FILE")
    local public_key=$(jq -r '.public_key' "$WARP_CONF_FILE")
    # 必须保留完整 CIDR 掩码，避免下游解析失败
    local address_v4=$(jq -r '.address_v4' "$WARP_CONF_FILE")
    local address_v6=$(jq -r '.address_v6' "$WARP_CONF_FILE")
    local endpoint=$(jq -r '.endpoint' "$WARP_CONF_FILE")
    
    # 正确解析 endpoint（支持 IPv6 格式 [host]:port）
    local ep_host ep_port
    if [[ "$endpoint" == \[*\]:* ]]; then
        # IPv6 格式: [2606:4700:d0::a29f:c001]:2408
        ep_host=$(echo "$endpoint" | sed 's/^\[\(.*\)\]:.*/\1/')
        ep_port=$(echo "$endpoint" | sed 's/.*\]://')
    else
        # IPv4 格式: 162.159.192.1:2408
        ep_host=$(echo "$endpoint" | cut -d':' -f1)
        ep_port=$(echo "$endpoint" | cut -d':' -f2)
    fi
    
    # IPv6 地址需要方括号
    local ep_formatted="$ep_host"
    [[ "$ep_host" == *:* ]] && ep_formatted="[$ep_host]"
    
    jq -n \
        --arg pk "$private_key" \
        --arg pub "$public_key" \
        --arg v4 "$address_v4" \
        --arg v6 "$address_v6" \
        --arg endpoint "${ep_formatted}:${ep_port}" \
    '{
        tag: "warp",
        protocol: "wireguard",
        settings: {
            secretKey: $pk,
            address: [$v4, $v6],
            peers: [{
                publicKey: $pub,
                allowedIPs: ["0.0.0.0/0", "::/0"],
                endpoint: $endpoint
            }],
            mtu: 1280
        }
    }'
}

# 测试 WARP 连接 (支持双模式)
test_warp_connection() {
    local warp_mode=$(db_get_warp_mode)
    _info "测试 WARP 连接..."
    
    if [[ "$warp_mode" == "official" ]]; then
        # 测试官方客户端
        if ! check_cmd warp-cli; then
            _warn "WARP 官方客户端未安装"
            return 1
        fi
        
        local status=$(warp-cli status 2>/dev/null)
        if echo "$status" | grep -qi "Connected"; then
            _ok "WARP 官方客户端已连接"
            echo -e "  模式: ${G}TCP/SOCKS5${NC} (端口 $WARP_OFFICIAL_PORT)"
            
            # 通过 SOCKS5 代理测试出口 IP (多源重试)
            echo -ne "  获取出口 IP..."
            local warp_ip=""
            local ip_apis=("https://api.ipify.org" "https://ifconfig.me" "https://ip.sb")
            for api in "${ip_apis[@]}"; do
                warp_ip=$(curl -s --connect-timeout 8 --max-time 12 --socks5 127.0.0.1:$WARP_OFFICIAL_PORT "$api" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                [[ -n "$warp_ip" ]] && break
            done
            if [[ -n "$warp_ip" ]]; then
                echo -e " ${G}${warp_ip}${NC}"
            else
                echo -e " ${Y}获取超时${NC}"
            fi
        else
            _warn "WARP 官方客户端未连接"
            echo -e "  ${D}状态: ${status}${NC}"
            return 1
        fi
    else
        # 测试 WGCF 配置
        if [[ ! -f "$WARP_CONF_FILE" ]]; then
            _warn "WARP (WGCF) 未配置"
            return 1
        fi
        
        echo -e "  模式: ${C}UDP/WireGuard${NC} (Xray 内置)"
        
        local endpoint=$(jq -r '.endpoint // "N/A"' "$WARP_CONF_FILE" 2>/dev/null)
        local address=$(jq -r '.address_v4 // "N/A"' "$WARP_CONF_FILE" 2>/dev/null)
        echo -e "  WARP 端点: ${G}${endpoint}${NC}"
        echo -e "  WARP 内网: ${D}${address}${NC}"
        
        _ok "WARP (WGCF) 配置已就绪"
    fi
    
    # 检查是否有分流规则
    local rules=$(db_get_routing_rules)
    if [[ -z "$rules" || "$rules" == "[]" ]]; then
        _warn "未配置分流规则，WARP 不会生效"
        echo -e "  ${D}请先配置分流规则${NC}"
        return 1
    fi
    
    # 获取直连 IP
    local direct_ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    echo -e "  直连出口 IP: ${C}${direct_ip:-获取失败}${NC}"
    
    echo ""
    echo -e "  ${Y}验证方法:${NC} 手机连接代理后访问 https://ip.sb"
    echo -e "  ${D}如果显示的 IP 不是 ${direct_ip}，说明 WARP 生效${NC}"
    
    return 0
}

# 重新获取 WARP IP (WGCF 模式)
refresh_warp_wgcf() {
    _info "重新获取 WARP (WGCF) 配置..."
    
    # 删除旧配置
    rm -f "$WARP_CONF_FILE"
    rm -f /usr/local/bin/wgcf
    rm -f ~/.wgcf-account.toml 2>/dev/null
    
    # 重新注册
    if register_warp; then
        db_set_warp_mode "wgcf"
        _regenerate_proxy_configs
        _ok "WARP (WGCF) 配置已更新"
        return 0
    fi
    return 1
}

# ==============================================================================
# WARP 官方客户端支持 (解决 UDP 封锁问题)
# ==============================================================================

# 安装 Cloudflare WARP 官方客户端
install_warp_official() {
    echo ""
    echo -e "  ${C}安装 WARP 官方客户端${NC}"
    _line
    
    # Alpine 不支持官方客户端 (依赖 glibc)
    if [[ "$DISTRO" == "alpine" ]]; then
        _err "Alpine 系统不支持 WARP 官方客户端 (依赖 glibc)"
        _info "请使用 WGCF 模式"
        return 1
    fi
    
    # 检查是否已安装
    if check_cmd warp-cli; then
        echo -e "  ${C}▸${NC} WARP 客户端已安装 ${G}✓${NC}"
        return 0
    fi
    
    # 检查架构
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        _err "WARP 官方客户端仅支持 x86_64 和 arm64 架构"
        return 1
    fi
    
    echo -ne "  ${C}▸${NC} 添加 Cloudflare 软件源..."
    
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        # 安装依赖
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl gnupg lsb-release >/dev/null 2>&1
        
        # 添加 GPG 密钥
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg 2>/dev/null | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
        
        # 获取发行版代号
        local codename=""
        if check_cmd lsb_release; then
            codename=$(lsb_release -cs 2>/dev/null)
        else
            codename=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d'=' -f2)
        fi
        
        # 某些新版本可能没有对应的源，回退到较新的稳定版
        case "$codename" in
            bookworm|trixie|sid) codename="bookworm" ;;
            noble|oracular) codename="jammy" ;;
        esac
        
        [[ -z "$codename" ]] && codename="jammy"
        
        echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
        echo -e " ${G}✓${NC}"
        
        echo -ne "  ${C}▸${NC} 安装 cloudflare-warp..."
        apt-get update -qq >/dev/null 2>&1
        if apt-get install -y cloudflare-warp >/dev/null 2>&1; then
            echo -e " ${G}✓${NC}"
        else
            echo -e " ${R}✗${NC}"
            _warn "尝试使用备用源..."
            echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ focal main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
            apt-get update -qq >/dev/null 2>&1
            if ! apt-get install -y cloudflare-warp >/dev/null 2>&1; then
                _err "安装失败"
                return 1
            fi
        fi
        
    elif [[ "$DISTRO" == "centos" ]]; then
        curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo 2>/dev/null | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
        echo -e " ${G}✓${NC}"
        
        echo -ne "  ${C}▸${NC} 安装 cloudflare-warp..."
        if yum install -y cloudflare-warp >/dev/null 2>&1; then
            echo -e " ${G}✓${NC}"
        else
            echo -e " ${R}✗${NC}"
            _err "安装失败"
            return 1
        fi
    else
        echo -e " ${R}✗${NC}"
        _err "不支持的系统: $DISTRO"
        return 1
    fi
    
    # 验证安装
    if ! check_cmd warp-cli; then
        _err "WARP 官方客户端安装失败"
        return 1
    fi
    
    # 启动 warp-svc 服务
    echo -ne "  ${C}▸${NC} 启动 WARP 服务..."
    systemctl enable warp-svc >/dev/null 2>&1
    systemctl start warp-svc >/dev/null 2>&1
    
    local svc_retry=0
    while [[ $svc_retry -lt 5 ]]; do
        sleep 1
        if systemctl is-active warp-svc &>/dev/null; then
            echo -e " ${G}✓${NC}"
            echo ""
            _ok "WARP 官方客户端安装成功"
            return 0
        fi
        ((svc_retry++))
    done
    
    echo -e " ${Y}!${NC}"
    _warn "WARP 服务启动较慢，继续配置..."
    return 0
}

# 配置 WARP 官方客户端 (SOCKS5 代理模式)
configure_warp_official() {
    _info "配置 WARP 官方客户端..."
    
    # 检查 warp-cli 是否存在
    if ! check_cmd warp-cli; then
        _err "warp-cli 未安装"
        return 1
    fi
    
    # 确保 warp-svc 服务运行
    echo -ne "  ${C}▸${NC} 启动 WARP 服务..."
    if ! systemctl is-active warp-svc &>/dev/null; then
        systemctl start warp-svc 2>/dev/null
        local svc_retry=0
        while [[ $svc_retry -lt 10 ]]; do
            sleep 1
            if systemctl is-active warp-svc &>/dev/null; then
                break
            fi
            ((svc_retry++))
        done
    fi
    if systemctl is-active warp-svc &>/dev/null; then
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${R}✗${NC}"
        _err "WARP 服务启动失败"
        return 1
    fi
    
    # 检查是否已注册 (新版 warp-cli 状态关键词: Status, Connected, Disconnected)
    local status=$(warp-cli status 2>/dev/null)
    local is_registered=false
    
    # 检测多种可能的已注册状态（排除 Registration Missing）
    if echo "$status" | grep -qiE "Registration|Account|Status:|Connected|Disconnected" && \
        ! echo "$status" | grep -qi "Registration Missing"; then
        is_registered=true
    fi
    
    register_warp_account() {
        echo -ne "  ${C}▸${NC} 注册 WARP 账户..."
        local reg_output=""
        local reg_success=false
        
        # 等待服务完全启动
        sleep 2
        
        # 尝试新版命令 (warp-cli 2024+)
        for i in 1 2 3; do
            # 方法1: --accept-tos 放在前面（全局选项）
            reg_output=$(warp-cli --accept-tos registration new 2>&1)
            if [[ $? -eq 0 ]] || echo "$reg_output" | grep -qi "already\|success\|registered"; then
                reg_success=true
                break
            fi
            
            # 方法2: 用 yes 管道模拟输入
            reg_output=$(yes | warp-cli registration new 2>&1)
            if [[ $? -eq 0 ]] || echo "$reg_output" | grep -qi "already\|success\|registered"; then
                reg_success=true
                break
            fi
            
            # 方法3: 使用 script 命令模拟 TTY
            if command -v script &>/dev/null; then
                reg_output=$(script -q -c "warp-cli registration new" /dev/null 2>&1 <<< "y")
                if [[ $? -eq 0 ]] || echo "$reg_output" | grep -qi "already\|success\|registered"; then
                    reg_success=true
                    break
                fi
            fi
            sleep 2
        done
        
        # 如果新版命令失败，检查是否已经注册
        if [[ "$reg_success" != "true" ]]; then
            reg_output=$(warp-cli registration show 2>&1)
            if [[ $? -eq 0 ]] && ! echo "$reg_output" | grep -qi "error\|not found\|missing"; then
                reg_success=true
            fi
        fi
        
        # 再次检查状态确认注册成功
        sleep 1
        status=$(warp-cli status 2>/dev/null)
        if [[ "$reg_success" == "true" ]] || echo "$status" | grep -qiE "Registration|Account|Status:|Connected|Disconnected"; then
            echo -e " ${G}✓${NC}"
            echo -ne "  ${C}▸${NC} 等待配置生效..."
            sleep 5
            echo -e " ${G}✓${NC}"
            return 0
        fi
        
        echo -e " ${R}✗${NC}"
        _err "WARP 账户注册失败"
        [[ -n "$reg_output" ]] && echo -e "  ${D}$reg_output${NC}"
        return 1
    }
    
    if [[ "$is_registered" != "true" ]]; then
        if ! register_warp_account; then
            return 1
        fi
    else
        echo -e "  ${C}▸${NC} WARP 账户已注册 ${G}✓${NC}"
    fi
    
    # 先断开现有连接，释放端口
    # warp-cli disconnect 2>/dev/null
    # sleep 1
    
    # 设置为代理模式
    echo -ne "  ${C}▸${NC} 设置代理模式..."
    warp-cli mode proxy 2>/dev/null || warp-cli set-mode proxy 2>/dev/null
    echo -e " ${G}✓${NC}"
    
    # 重置端口为默认值
    WARP_OFFICIAL_PORT=40000
    
    # 设置代理端口
    echo -ne "  ${C}▸${NC} 设置代理端口 $WARP_OFFICIAL_PORT..."
    warp-cli proxy port "$WARP_OFFICIAL_PORT" 2>/dev/null || warp-cli set-proxy-port "$WARP_OFFICIAL_PORT" 2>/dev/null
    echo -e " ${G}✓${NC}"

    # 【关键】设置完成后验证注册状态（防止设置过程中守护进程重启导致注册丢失）
    echo -ne "  ${C}▸${NC} 验证注册状态..."
    sleep 2
    local verify_status=$(warp-cli status 2>/dev/null)
    
    if echo "$verify_status" | grep -qi "Registration Missing"; then
        echo -e " ${R}✗${NC}"
        _warn "检测到注册信息丢失，正在重新注册..."
        
        # 重启服务并重新注册
        systemctl restart warp-svc 2>/dev/null
        sleep 3
        
        if ! register_warp_account; then
            _err "重新注册失败"
            return 1
        fi
        
        # 重新设置代理模式和端口
        echo -ne "  ${C}▸${NC} 重新设置代理配置..."
        warp-cli mode proxy 2>/dev/null
        warp-cli proxy port "$WARP_OFFICIAL_PORT" 2>/dev/null || warp-cli set-proxy-port "$WARP_OFFICIAL_PORT" 2>/dev/null
        sleep 2
        
        # 最终验证
        verify_status=$(warp-cli status 2>/dev/null)
        if echo "$verify_status" | grep -qi "Registration Missing"; then
            echo -e " ${R}✗${NC}"
            _err "注册失败：守护进程无法保持注册状态"
            echo -e "  ${D}状态输出:${NC}"
            echo "$verify_status" | sed 's/^/    /'
            return 1
        fi
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${G}✓${NC}"
    fi
    
    # 连接 WARP
    echo -ne "  ${C}▸${NC} 连接 WARP..."
    warp-cli connect 2>/dev/null
    
    # 等待连接成功 (带进度显示，增加到 60 秒)
    local retry=0
    local connected=false
    while [[ $retry -lt 30 ]]; do
        sleep 2
        local status_output=$(warp-cli status 2>/dev/null)
        # 改进检测：支持多种状态格式
        if echo "$status_output" | grep -qiE "(Connected|Status.*Connected)"; then
            connected=true
            break
        fi
        echo -n "."
        ((retry++))
    done
    
    if $connected; then
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${R}✗${NC}"
        
        # 超时后二次确认最终状态
        local final_status=$(warp-cli status 2>/dev/null)
        if echo "$final_status" | grep -qiE "(Connected|Status.*Connected)"; then
            echo -e "  ${Y}注意${NC}: 连接过程较慢，但最终已成功连接"
            connected=true
        else
            _err "WARP 连接超时"
            echo -e "  当前状态:"
            echo "$final_status" | sed 's/^/  /'
            return 1
        fi
    fi
    
    # 只有真正连接失败才返回错误
    if ! $connected; then
        return 1
    fi
    
    # 保存模式到数据库
    db_set_warp_mode "official"
    
    # 获取 WARP 出口 IP (带重试和多源)
    _get_warp_official_ip
    return $?
}

# 获取 WARP 官方客户端出口 IP (带重试机制)
# 获取 WARP 官方客户端出口 IP
# 参数: $1 = "interactive" (带用户交互) 或 "simple" (静默模式)
_get_warp_official_ip() {
    local mode="${1:-interactive}"
    local ip_apis=("https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://api.ip.sb/ip")
    
    while true; do
        echo -e "  ${C}▸${NC} 获取 WARP 出口 IP..."
        local warp_ip="" attempt=1
        
        while [[ $attempt -le 3 && -z "$warp_ip" ]]; do
            echo -ne "    尝试 $attempt/3..."
            for api in "${ip_apis[@]}"; do
                warp_ip=$(curl -s --connect-timeout 8 --max-time 12 --socks5 127.0.0.1:$WARP_OFFICIAL_PORT "$api" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                [[ -n "$warp_ip" ]] && break
            done
            [[ -n "$warp_ip" ]] && echo -e " ${G}成功${NC}" && break
            echo -e " ${Y}超时${NC}"
            ((attempt++))
            [[ $attempt -le 3 ]] && sleep 2
        done
        
        if [[ -n "$warp_ip" ]]; then
            if [[ "$mode" == "simple" ]]; then
                _ok "WARP 已重新连接"
                echo -e "  WARP 出口 IP: ${G}${warp_ip}${NC}"
            else
                echo ""
                _line
                echo -e "  ${G}WARP 官方客户端配置成功${NC}"
                _line
                echo -e "  SOCKS5 代理: ${C}127.0.0.1:${WARP_OFFICIAL_PORT}${NC}"
                echo -e "  WARP 出口 IP: ${G}${warp_ip}${NC}"
                _line
            fi
            return 0
        fi
        
        # 获取失败
        if [[ "$mode" == "simple" ]]; then
            _ok "WARP 已重新连接"
            echo -e "  ${D}出口 IP 获取超时，请稍后手动验证${NC}"
            return 0
        fi
        
        # interactive 模式：询问用户
        echo ""
        _warn "无法获取 WARP 出口 IP"
        echo ""
        _item "1" "重试获取"
        _item "2" "跳过 (连接已建立，可能是 API 问题)"
        _item "3" "放弃配置"
        _line
        read -rp "  请选择: " ip_choice
        ip_choice=$(echo "$ip_choice" | tr -d ' \t')
        
        case "$ip_choice" in
            1) continue ;;
            2)
                echo ""
                _line
                echo -e "  ${G}WARP 官方客户端已连接${NC}"
                _line
                echo -e "  SOCKS5 代理: ${C}127.0.0.1:${WARP_OFFICIAL_PORT}${NC}"
                echo -e "  ${D}出口 IP 未获取，请稍后手动验证${NC}"
                _line
                return 0
                ;;
            *)
                _err "配置已取消"
                warp-cli disconnect 2>/dev/null
                db_set_warp_mode "wgcf"
                return 1
                ;;
        esac
    done
}

# 重新连接 WARP 官方客户端
reconnect_warp_official() {
    _info "重新连接 WARP 官方客户端..."
    
    if ! check_cmd warp-cli; then
        _err "warp-cli 未安装"
        return 1
    fi
    
    warp-cli disconnect 2>/dev/null
    sleep 2
    warp-cli connect 2>/dev/null
    
    # 等待连接 (带进度显示，延长到 60 秒)
    echo -ne "  ${C}▸${NC} 等待连接..."
    local retry=0 connected=false
    while [[ $retry -lt 30 ]]; do
        sleep 2
        local status_output=$(warp-cli status 2>/dev/null)
        # 改进检测：支持多种状态格式
        if echo "$status_output" | grep -qiE "(Connected|Status.*Connected)"; then
            connected=true
            break
        fi
        echo -ne "."
        ((retry++))
    done
    
    if $connected; then
        echo -e " ${G}✓${NC}"
    else
        echo -e " ${R}✗${NC}"
        
        # 超时后二次确认最终状态
        local final_status=$(warp-cli status 2>/dev/null)
        if echo "$final_status" | grep -qiE "(Connected|Status.*Connected)"; then
            echo -e "  ${Y}注意${NC}: 连接过程较慢，但最终已成功连接"
            connected=true
        else
            _err "重新连接失败"
            echo "$final_status" | sed 's/^/  /'
            return 1
        fi
    fi
    
    # 只有真正连接成功才继续
    if ! $connected; then
        return 1
    fi
    
    echo -e " ${G}✓${NC}"
    _get_warp_official_ip "simple"
    return 0
}

# 卸载 WARP 官方客户端
uninstall_warp_official() {
    _info "卸载 WARP 官方客户端..."
    
    # 断开连接
    warp-cli disconnect 2>/dev/null
    
    # 停止服务
    systemctl stop warp-svc 2>/dev/null
    systemctl disable warp-svc 2>/dev/null
    
    # 卸载软件包
    if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
        apt-get remove -y cloudflare-warp 2>/dev/null
        apt-get autoremove -y 2>/dev/null
        rm -f /etc/apt/sources.list.d/cloudflare-client.list
        rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    elif [[ "$DISTRO" == "centos" ]]; then
        yum remove -y cloudflare-warp 2>/dev/null
        rm -f /etc/yum.repos.d/cloudflare-warp.repo
    fi
    
    _ok "WARP 官方客户端已卸载"
}

# 卸载 WARP (支持双模式)
uninstall_warp() {
    local warp_mode=$(db_get_warp_mode)
    _info "卸载 WARP..."
    
    if [[ "$warp_mode" == "official" ]]; then
        uninstall_warp_official
    else
        # 卸载 WGCF
        rm -f "$WARP_CONF_FILE"
        rm -f /usr/local/bin/wgcf
        rm -f ~/.wgcf-account.toml 2>/dev/null
        _ok "WARP (WGCF) 已卸载"
    fi
    
    # 清除模式设置和分流配置
    db_set_warp_mode "wgcf"
    db_clear_routing_rules
    
    # 重新生成配置 (移除 WARP outbound)
    _regenerate_proxy_configs
    _ok "WARP 已完全卸载"
}

#═══════════════════════════════════════════════════════════════════════════════
# 多出口分流规则系统
#═══════════════════════════════════════════════════════════════════════════════

# 预设规则类型定义 (使用 geosite 规则库，更全面且自动更新)
declare -A ROUTING_PRESETS=(
    [ai-intl]="geosite:category-ai-!cn"
    [openai]="geosite:openai"
    [netflix]="geosite:netflix"
    [disney]="geosite:disney"
    [mytvsuper]="geosite:mytvsuper"
    [youtube]="geosite:youtube"
    [spotify]="geosite:spotify"
    [tiktok]="geosite:tiktok"
    [telegram]="geosite:telegram"
    [google]="geosite:google"
    [ads]="geosite:category-ads-all"
)

# 需要同时匹配 IP 的预设规则 (这些服务客户端会直连 IP)
declare -A ROUTING_PRESETS_IP=(
    [telegram]="geoip:telegram"
    [netflix]="geoip:netflix"
    [google]="geoip:google"
)

# 预设规则显示名称
declare -A ROUTING_PRESET_NAMES=(
    [ai-intl]="AI服务(国际)"
    [openai]="OpenAI/ChatGPT"
    [netflix]="Netflix"
    [disney]="Disney+"
    [mytvsuper]="MyTVSuper"
    [youtube]="YouTube"
    [spotify]="Spotify"
    [tiktok]="TikTok"
    [telegram]="Telegram"
    [google]="Google"
    [ads]="广告屏蔽"
)

# 数据库：添加分流规则
# 规则优先级：custom > 预设规则 > all（全局）
# custom 规则会插入到数组开头，确保优先匹配
# 规则优先级：直连规则 > custom > 预设规则 > all（全局）
db_add_routing_rule() {
    local rule_type="$1"    # openai, netflix, custom, all
    local outbound="$2"     # 出口标识: direct, warp, chain:节点名
    local domains="$3"      # 自定义域名 (仅 custom 类型)
    
    [[ ! -f "$DB_FILE" ]] && echo '{}' > "$DB_FILE"

    # 获取 IP 版本选项 (第4个参数)
    local ip_version="${4:-prefer_ipv4}"
    
    # 生成规则 ID
    local rule_id="${rule_type}_$(date +%s)"
    if [[ "$rule_type" != "custom" ]]; then
        if [[ "$rule_type" == "all" ]]; then
            rule_id="all_${ip_version}"
        else
            rule_id="$rule_type"
        fi
    fi
    
    # 获取域名
    local rule_domains="$domains"
    [[ "$rule_type" != "custom" && "$rule_type" != "all" ]] && rule_domains="${ROUTING_PRESETS[$rule_type]:-}"
    
    local tmp=$(mktemp)
    
    # 规则优先级排序：
    # 1. 直连规则 (outbound=direct) - 最高优先级
    # 2. custom 规则 - 次高优先级
    # 3. 预设规则 (openai, netflix 等)
    # 4. all 规则 - 最低优先级
    
    if [[ "$rule_type" == "custom" ]]; then
        if [[ "$outbound" == "direct" ]]; then
            # 直连的 custom 规则插入到最开头
            jq --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = ([{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] + (.routing_rules // []))' \
                "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
        else
            # 非直连的 custom 规则插入到直连规则之后
            jq --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = (
                    ((.routing_rules // []) | map(select(.outbound == "direct"))) + 
                    [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] +
                    ((.routing_rules // []) | map(select(.outbound != "direct")))
                )' \
                "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
        fi
    elif [[ "$rule_type" == "all" ]]; then
        # all 规则追加到末尾，优先级最低
        jq --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
            '.routing_rules = (
                ((.routing_rules // []) | map(select(.type != $type or ((.ip_version // "prefer_ipv4") != $ip_ver))))
            ) + [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}]' \
            "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
    else
        # 预设规则：删除同类型旧规则
        if [[ "$outbound" == "direct" ]]; then
            # 直连的预设规则插入到最开头
            jq --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = (
                    [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] +
                    ((.routing_rules // []) | map(select(.type != $type)))
                )' \
                "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
        else
            # 非直连的预设规则：插入到直连和 custom 规则之后
            jq --arg id "$rule_id" --arg type "$rule_type" --arg out "$outbound" --arg domains "$rule_domains" --arg ip_ver "$ip_version" \
                '.routing_rules = (
                    ((.routing_rules // []) | map(select(.outbound == "direct"))) + 
                    ((.routing_rules // []) | map(select(.type == "custom" and .outbound != "direct"))) + 
                    [{id: $id, type: $type, outbound: $out, domains: $domains, ip_version: $ip_ver}] +
                    ((.routing_rules // []) | map(select(.type != "custom" and .type != $type and .outbound != "direct")))
                )' \
                "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
        fi
    fi
}

# 数据库：删除分流规则 (支持按 id 或 type 删除)
# 用法: db_del_routing_rule "rule_id" 或 db_del_routing_rule "type" "by_type"
db_del_routing_rule() {
    local identifier="$1"
    local mode="${2:-by_id}"  # 默认按 id 删除
    [[ ! -f "$DB_FILE" ]] && return
    
    local tmp=$(mktemp)
    if [[ "$mode" == "by_type" ]]; then
        # 按 type 删除 (删除所有同类型规则)
        jq --arg type "$identifier" '.routing_rules = [.routing_rules[]? | select(.type != $type)]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
    else
        # 按 id 删除 (只删除单个规则)
        jq --arg id "$identifier" '.routing_rules = [.routing_rules[]? | select(.id != $id)]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
    fi
}

# 数据库：获取所有分流规则
db_get_routing_rules() {
    [[ ! -f "$DB_FILE" ]] && echo "[]" && return
    jq -r '.routing_rules // []' "$DB_FILE" 2>/dev/null
}

# 数据库：检查规则是否存在
db_has_routing_rule() {
    local rule_type="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    local count=$(jq --arg type "$rule_type" '[.routing_rules[]? | select(.type == $type)] | length' "$DB_FILE" 2>/dev/null)
    [[ "$count" -gt 0 ]]
}

# 数据库：检查规则是否存在（按类型 + IP 版本）
db_has_routing_rule_by_type_and_ip_version() {
    local rule_type="$1"
    local ip_version="$2"
    [[ ! -f "$DB_FILE" ]] && return 1
    local count=$(jq --arg type "$rule_type" --arg ip_ver "$ip_version" \
        '[.routing_rules[]? | select(.type == $type and (.ip_version // "prefer_ipv4") == $ip_ver)] | length' \
        "$DB_FILE" 2>/dev/null)
    [[ "$count" -gt 0 ]]
}
# 数据库：清空所有分流规则
db_clear_routing_rules() {
    [[ ! -f "$DB_FILE" ]] && return
    local tmp=$(mktemp)
    jq '.routing_rules = []' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

#═══════════════════════════════════════════════════════════════════════════════
# 负载均衡组管理
#═══════════════════════════════════════════════════════════════════════════════

# 数据库：添加负载均衡组
# 用法: db_add_balancer_group "组名" "策略" "节点1" "节点2" ...
# 策略: random(随机), roundRobin(轮询), leastPing(最低延迟), leastLoad(最低负载)
# 注意: leastPing/leastLoad需要Observatory配置,配置生成时会自动添加burstObservatory
db_add_balancer_group() {
    local name="$1" strategy="$2"
    shift 2
    local nodes=("$@")

    [[ ! -f "$DB_FILE" ]] && echo '{}' > "$DB_FILE"

    # 构建节点数组
    local nodes_json=$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s .)

    # 构建组对象
    local group_json=$(jq -n \
        --arg name "$name" \
        --arg strategy "$strategy" \
        --argjson nodes "$nodes_json" \
        '{name: $name, strategy: $strategy, nodes: $nodes}')

    # 写入数据库
    local tmp=$(mktemp)
    jq --argjson group "$group_json" \
        '.balancer_groups = (.balancer_groups // []) + [$group]' \
        "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 数据库：获取所有负载均衡组
db_get_balancer_groups() {
    [[ ! -f "$DB_FILE" ]] && echo "[]" && return
    jq -r '.balancer_groups // []' "$DB_FILE" 2>/dev/null
}

# 数据库：获取指定负载均衡组
db_get_balancer_group() {
    local name="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    jq -r --arg name "$name" '.balancer_groups[]? | select(.name == $name)' "$DB_FILE" 2>/dev/null
}

# 数据库：删除负载均衡组
db_delete_balancer_group() {
    local name="$1"
    [[ ! -f "$DB_FILE" ]] && return
    local tmp=$(mktemp)
    jq --arg name "$name" \
        '.balancer_groups = [.balancer_groups[]? | select(.name != $name)]' \
        "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 数据库：检查负载均衡组是否存在
db_balancer_group_exists() {
    local name="$1"
    [[ ! -f "$DB_FILE" ]] && return 1
    local exists=$(jq --arg name "$name" \
        '[.balancer_groups[]? | select(.name == $name)] | length' "$DB_FILE" 2>/dev/null)
    [[ "$exists" -gt 0 ]]
}

# 数据库：更新负载均衡组节点
db_update_balancer_nodes() {
    local name="$1"
    shift
    local nodes=("$@")

    [[ ! -f "$DB_FILE" ]] && return 1

    local nodes_json=$(printf '%s\n' "${nodes[@]}" | jq -R . | jq -s .)
    local tmp=$(mktemp)
    jq --arg name "$name" --argjson nodes "$nodes_json" \
        '.balancer_groups = [.balancer_groups[]? | if .name == $name then .nodes = $nodes else . end]' \
        "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 获取可用的出口列表
_get_available_outbounds() {
    local outbounds=()
    
    # WARP 出口
    local warp_st=$(warp_status 2>/dev/null)
    if [[ "$warp_st" == "configured" || "$warp_st" == "connected" ]]; then
        outbounds+=("warp|WARP")
    fi
    
    # 链式代理节点
    local nodes=$(db_get_chain_nodes 2>/dev/null)
    if [[ -n "$nodes" && "$nodes" != "[]" ]]; then
        while IFS= read -r node_name; do
            [[ -n "$node_name" ]] && outbounds+=("chain:${node_name}|${node_name}")
        done < <(echo "$nodes" | jq -r '.[].name' 2>/dev/null)
    fi

    # 负载均衡组
    local balancer_groups=$(db_get_balancer_groups 2>/dev/null)
    if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
        while IFS= read -r group_name; do
            [[ -n "$group_name" ]] && outbounds+=("balancer:${group_name}|负载均衡:${group_name}")
        done < <(echo "$balancer_groups" | jq -r '.[].name' 2>/dev/null)
    fi

    # 输出格式: "id|显示名" 每行一个
    printf '%s\n' "${outbounds[@]}"
}

# 延迟展示辅助函数
_latency_color() {
    local latency="$1"
    local color="${G}"
    if [[ "$latency" == "超时" ]]; then
        color="${R}"
    elif [[ "$latency" =~ ^[0-9]+$ ]]; then
        if [[ "$latency" -gt 1000 ]]; then
            color="${R}"
        elif [[ "$latency" -gt 300 ]]; then
            color="${Y}"
        fi
    fi
    echo "$color"
}

_format_latency_badge() {
    local latency="$1"
    local color
    color=$(_latency_color "$latency")
    if [[ "$latency" == "超时" ]]; then
        printf "%b\n" "[${color}超时${NC}]"
    elif [[ "$latency" =~ ^[0-9]+$ ]]; then
        printf "%b\n" "[${color}${latency}ms${NC}]"
    else
        echo ""
    fi
}

# 配置地址展示 (支持 IPv6)
_format_server_port() {
    local server="$1"
    local port="$2"
    local display="$server"
    
    if [[ -z "$display" || "$display" == "-" ]]; then
        echo "-"
        return
    fi
    
    display="${display#[}"
    display="${display%]}"
    [[ "$display" =~ : ]] && display="[$display]"
    
    if [[ -z "$port" || "$port" == "-" ]]; then
        echo "${display}"
    else
        echo "${display}:${port}"
    fi
}

# 显示排序后的延迟结果
# 用法: _display_sorted_latencies "结果文件路径" [标记关联数组名]
_display_sorted_latencies() {
    local results="$1"
    local marks_array_name="${2:-}"
    [[ ! -f "$results" ]] && return
    
    sort -t'|' -k1 -n "$results" | while IFS='|' read -r _ latency name type server port; do
        local latency_badge=$(_format_latency_badge "$latency")
        local display_addr=$(_format_server_port "$server" "$port")
        local mark_suffix=""

        # 如果提供了标记数组名，尝试获取对应的标记
        if [[ -n "$marks_array_name" ]]; then
            eval "local mark_value=\"\${${marks_array_name}[${name}]}\""
            [[ -n "$mark_value" ]] && mark_suffix=" ${Y}← ${mark_value}${NC}"
        fi
        
        if [[ -n "$latency_badge" ]]; then
            echo -e "  ${latency_badge} $name ${D}($type)${NC} ${D}${display_addr}${NC}${mark_suffix}"
        fi
    done
}

# 选择出口的交互函数
# 参数: $1=提示文本, $2=是否检测延迟(check_latency/no_check, 默认 check_latency)
_select_outbound() {
    local prompt="${1:-选择出口}"
    local check_mode="${2:-check_latency}"
    local outbounds=()
    local display_names=()
    
    # 直连出口（优先级最高）
    outbounds+=("direct")
    display_names+=("DIRECT")
    
    # 获取节点完整信息
    local nodes=$(db_get_chain_nodes 2>/dev/null)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    
    # WARP 出口
    local warp_st=$(warp_status 2>/dev/null)
    if [[ "$warp_st" == "configured" || "$warp_st" == "connected" ]]; then
        outbounds+=("warp")
        display_names+=("WARP")
    fi
    
    # 链式代理节点 - 获取完整信息(优化:一次 jq 调用提取所有字段)
    if [[ "$node_count" -gt 0 ]]; then
        while IFS=$'\t' read -r name type server port; do
            [[ -z "$name" ]] && continue
            outbounds+=("chain:${name}")
            display_names+=("${name}"$'\t'"${type}"$'\t'"${server}"$'\t'"${port}")
        done < <(echo "$nodes" | jq -r '.[] | [.name // "", .type // "", .server // "", .port // ""] | @tsv')
    fi

    # 负载均衡组(优化:一次 jq 调用提取所有字段)
    local balancer_groups=$(db_get_balancer_groups 2>/dev/null)
    if [[ -n "$balancer_groups" && "$balancer_groups" != "[]" ]]; then
        while IFS=$'\t' read -r group_name strategy node_count; do
            [[ -z "$group_name" ]] && continue
            outbounds+=("balancer:${group_name}")
            display_names+=("${group_name}"$'\t'"balancer"$'\t'"${strategy}"$'\t'"${node_count}节点")
        done < <(echo "$balancer_groups" | jq -r '.[] | [.name // "", .strategy // "", (.nodes | length)] | @tsv')
    fi

    # 检测延迟（跳过直连、WARP 和负载均衡组）
    local need_latency_check=false
    if [[ "$check_mode" == "check_latency" ]]; then
        for info in "${display_names[@]}"; do
            if [[ "$info" != "DIRECT" && "$info" != "WARP" ]]; then
                need_latency_check=true
                break
            fi
        done
    fi

    if [[ "$need_latency_check" == "true" ]]; then
        echo -e "  ${C}▸${NC} 检测 $((${#outbounds[@]}-1)) 个节点延迟中..." >&2
    fi

    local latency_results=()
    local idx=0
    for i in "${!display_names[@]}"; do
        local info="${display_names[$i]}"
        local type=$(echo "$info" | cut -d$'\t' -f2)
        if [[ "$info" == "DIRECT" || "$info" == "WARP" || "$type" == "balancer" ]]; then
            latency_results+=("-|$info|-")
        else
            if [[ "$check_mode" == "check_latency" ]]; then
                local node_name=$(echo "$info" | cut -d$'\t' -f1)
                local result=$(check_node_latency "$node_name" 2>/dev/null)
                latency_results+=("$result")
            else
                # 不检测延迟,使用占位符
                latency_results+=("-|$info|-")
            fi
        fi
        ((idx++))
        if [[ "$need_latency_check" == "true" ]]; then
            echo -ne "\r  ${C}▸${NC} 检测中... ($idx/${#outbounds[@]})  " >&2
        fi
    done
    if [[ "$need_latency_check" == "true" ]]; then
        echo -e "\r  ${G}✓${NC} 延迟检测完成                " >&2
    fi
    if [[ "$check_mode" != "check_latency" ]]; then
        echo "" >&2
    fi
    
    # 构建排序数据: latency_num|idx|latency_display|name|type|server|port
    local sort_data=()
    for i in "${!outbounds[@]}"; do
        local info="${display_names[$i]}"
        local result="${latency_results[$i]}"
        
        if [[ "$info" == "DIRECT" ]]; then
            # 直连放在最前面，排序值为 -1
            sort_data+=("-1|$i|DIRECT|直连 (本机出口)|direct|-|-")
        elif [[ "$info" == "WARP" ]]; then
            sort_data+=("0|$i|WARP|WARP|warp|-|-")
        else
            # display_names 用 tab 分隔: name\ttype\tserver\tport
            local name=$(echo "$info" | cut -d$'\t' -f1)
            local type=$(echo "$info" | cut -d$'\t' -f2)
            local server=$(echo "$info" | cut -d$'\t' -f3)
            local port=$(echo "$info" | cut -d$'\t' -f4)

            if [[ "$type" == "balancer" ]]; then
                # 负载均衡组排在 WARP 后面，排序值为 1
                sort_data+=("1|$i|-|${name}|balancer|${server}|${port}")
            else
                local latency="${result%%|*}"
                local latency_num=99999
                [[ "$latency" =~ ^[0-9]+$ ]] && latency_num="$latency"
                sort_data+=("${latency_num}|$i|${latency}|${name}|${type}|${server}|${port}")
            fi
        fi
    done
    
    # 按延迟排序并显示
    local sorted_indices=()
    local display_idx=1
    while IFS='|' read -r latency_num orig_idx latency name type server port; do
        sorted_indices+=("$orig_idx")
        
        local latency_badge=$(_format_latency_badge "$latency")
        local display_addr=$(_format_server_port "$server" "$port")
        
        if [[ "$name" == "直连 (本机出口)" ]]; then
            echo -e "  ${G}${display_idx}${NC}) ${C}直连${NC} ${D}(本机 IP 出口)${NC}" >&2
        elif [[ "$name" == "WARP" ]]; then
            echo -e "  ${G}${display_idx}${NC}) WARP" >&2
        elif [[ "$type" == "balancer" ]]; then
            # server 字段存储的是策略，port 字段存储的是节点数量
            echo -e "  ${G}${display_idx}${NC}) ${name} ${D}(负载均衡: ${server}, ${port})${NC}" >&2
        elif [[ -n "$latency_badge" ]]; then
            echo -e "  ${G}${display_idx}${NC}) ${latency_badge} ${name} ${D}(${type})${NC} ${D}${display_addr}${NC}" >&2
        else
            echo -e "  ${G}${display_idx}${NC}) ${name} ${D}(${type})${NC}" >&2
        fi
        ((display_idx++))
    done < <(printf '%s\n' "${sort_data[@]}" | sort -t'|' -k1 -n)
    
    # 返回选项
    echo -e "  ${G}0${NC}) 返回" >&2
    
    _line >&2
    read -rp "  $prompt [1]: " choice
    choice=${choice:-1}
    
    # 输入 0 返回
    if [[ "$choice" == "0" ]]; then
        return 1
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le ${#sorted_indices[@]} ]]; then
        local orig_idx="${sorted_indices[$((choice-1))]}"
        echo "${outbounds[$orig_idx]}"
        return 0
    fi
    
    return 1
}

# 获取出口的显示名称
_get_outbound_display_name() {
    local outbound="$1"
    case "$outbound" in
        direct) echo "直连" ;;
        warp) echo "WARP" ;;
        chain:*) echo "${outbound#chain:}" ;;
        *) echo "$outbound" ;;
    esac
}

# 生成多IP路由的outbound配置 (使用sendThrough指定出站IP)
gen_xray_ip_routing_outbounds() {
    # 检查是否启用多IP路由
    db_ip_routing_enabled || return
    
    local rules=$(db_get_ip_routing_rules)
    [[ -z "$rules" || "$rules" == "[]" ]] && return
    
    local result="[]"
    local added_ips=""  # 避免重复添加相同出站IP的outbound
    
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local outbound_ip=$(echo "$rule" | jq -r '.outbound_ip')
        [[ -z "$outbound_ip" ]] && continue
        
        # 检查是否已添加过这个出站IP
        if [[ " $added_ips " == *" $outbound_ip "* ]]; then
            continue
        fi
        added_ips+=" $outbound_ip"
        
        # 生成freedom outbound with sendThrough
        local tag="direct-ip-${outbound_ip//[.:]/-}"  # 将IP中的.和:替换为-作为tag
        result=$(echo "$result" | jq --arg tag "$tag" --arg ip "$outbound_ip" '
            . + [{
                "tag": $tag,
                "protocol": "freedom",
                "sendThrough": $ip,
                "settings": {}
            }]
        ')
    done < <(echo "$rules" | jq -c '.[]')
    
    [[ "$result" != "[]" ]] && echo "$result"
}

# 生成多IP路由的routing规则 (根据入站IP路由到对应出站)
# 参数: $1 = inbounds JSON 数组（可选，如果提供则从中提取匹配的 tag）
gen_xray_ip_routing_rules() {
    # 检查是否启用多IP路由
    db_ip_routing_enabled || return
    
    local rules=$(db_get_ip_routing_rules)
    [[ -z "$rules" || "$rules" == "[]" ]] && return
    
    local inbounds_json="${1:-}"
    local result="[]"
    
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local inbound_ip=$(echo "$rule" | jq -r '.inbound_ip')
        local outbound_ip=$(echo "$rule" | jq -r '.outbound_ip')
        [[ -z "$inbound_ip" || -z "$outbound_ip" ]] && continue
        
        local outbound_tag="direct-ip-${outbound_ip//[.:]/-}"
        local inbound_tag_prefix="ip-in-${inbound_ip//[.:]/-}-"
        
        # 收集所有匹配该入站IP的 inbound tag
        local matching_tags="[]"
        if [[ -n "$inbounds_json" && "$inbounds_json" != "[]" ]]; then
            # 从提供的 inbounds 中筛选匹配的 tag
            matching_tags=$(echo "$inbounds_json" | jq --arg prefix "$inbound_tag_prefix" '[.[] | select(.tag | startswith($prefix)) | .tag]')
        fi
        
        # 如果没有从参数获取到，尝试从现有配置文件读取
        if [[ "$matching_tags" == "[]" && -f "$CFG/config.json" ]]; then
            matching_tags=$(jq --arg prefix "$inbound_tag_prefix" '[.inbounds[]? | select(.tag | startswith($prefix)) | .tag]' "$CFG/config.json" 2>/dev/null || echo "[]")
        fi
        
        # 如果仍然没有匹配的 tag，跳过这条规则
        [[ "$matching_tags" == "[]" || -z "$matching_tags" ]] && continue
        
        result=$(echo "$result" | jq --argjson tags "$matching_tags" --arg out_tag "$outbound_tag" '
            . + [{
                "type": "field",
                "inboundTag": $tags,
                "outboundTag": $out_tag
            }]
        ')
    done < <(echo "$rules" | jq -c '.[]')
    
    [[ "$result" != "[]" ]] && echo "$result"
}

# 生成多IP路由的inbound配置 (复制现有协议inbound，监听不同IP)
# 注意：这个函数需要在已有协议inbound的基础上，为每个入站IP创建独立的inbound
# 由于实现较复杂，暂时采用简化方案：用户手动指定每个协议的监听IP

# 生成 Xray 分流路由配置 (支持多出口)
gen_xray_routing_rules() {
    local rules=$(db_get_routing_rules)
    [[ -z "$rules" || "$rules" == "[]" ]] && return
    
    local result="[]"
    local all_ipv6="[]"
    local all_ipv4="[]"
    local all_other="[]"
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local rule_type=$(echo "$rule" | jq -r '.type')
        local outbound=$(echo "$rule" | jq -r '.outbound')
        local domains=$(echo "$rule" | jq -r '.domains // ""')
        local ip_version=$(echo "$rule" | jq -r '.ip_version // "prefer_ipv4"')
        local ip_family_cidr=""
        case "$ip_version" in
            ipv4_only) ip_family_cidr="0.0.0.0/0" ;;
            ipv6_only) ip_family_cidr="::/0" ;;
        esac
        
        # 转换出口标识为 tag
        local tag="$outbound"
        local tag_key="outboundTag"
        if [[ "$outbound" == "direct" ]]; then
            case "$ip_version" in
                ipv4_only) tag="direct-ipv4" ;;
                ipv6_only) tag="direct-ipv6" ;;
                prefer_ipv6) tag="direct-prefer-ipv6" ;;
                as_is|asis) tag="direct-asis" ;;
                *) tag="direct-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == "warp" ]]; then
            case "$ip_version" in
                ipv4_only) tag="warp-ipv4" ;;
                ipv6_only) tag="warp-ipv6" ;;
                prefer_ipv6) tag="warp-prefer-ipv6" ;;
                *) tag="warp-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == "block" ]]; then
            tag="block"
        elif [[ "$outbound" == chain:* ]]; then
            local node_name="${outbound#chain:}"
            case "$ip_version" in
                ipv4_only) tag="chain-${node_name}-ipv4" ;;
                ipv6_only) tag="chain-${node_name}-ipv6" ;;
                prefer_ipv6) tag="chain-${node_name}-prefer-ipv6" ;;
                *) tag="chain-${node_name}-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == balancer:* ]]; then
            local group_name="${outbound#balancer:}"
            tag="balancer-${group_name}"
            tag_key="balancerTag"
        fi
        
        if [[ "$rule_type" == "all" ]]; then
            local rule_json=""
            if [[ -n "$ip_family_cidr" ]]; then
                rule_json=$(jq -n --arg tag "$tag" --arg key "$tag_key" --arg ip "$ip_family_cidr" \
                    '{"type":"field","network":"tcp,udp","ip":[$ip],($key):$tag}')
            else
                rule_json=$(jq -n --arg tag "$tag" --arg key "$tag_key" \
                    '{"type":"field","network":"tcp,udp",($key):$tag}')
            fi
            case "$ip_version" in
                ipv6_only) all_ipv6=$(echo "$all_ipv6" | jq --argjson r "$rule_json" '. + [$r]') ;;
                ipv4_only) all_ipv4=$(echo "$all_ipv4" | jq --argjson r "$rule_json" '. + [$r]') ;;
                *) all_other=$(echo "$all_other" | jq --argjson r "$rule_json" '. + [$r]') ;;
            esac
        elif [[ -n "$domains" ]]; then
            # 检测是否是 geosite 规则
            if [[ "$domains" == geosite:* ]]; then
                # 添加 domain 规则
                if [[ -n "$ip_family_cidr" ]]; then
                    result=$(echo "$result" | jq --arg geosite "$domains" --arg tag "$tag" --arg key "$tag_key" --arg ip "$ip_family_cidr" \
                        '. + [{"type": "field", "domain": [$geosite], "ip": [$ip], ($key): $tag}]')
                else
                    result=$(echo "$result" | jq --arg geosite "$domains" --arg tag "$tag" --arg key "$tag_key" \
                        '. + [{"type": "field", "domain": [$geosite], ($key): $tag}]')
                fi
                
                # 检查是否有对应的 geoip 规则需要添加（拆成独立规则，OR 关系）
                local geoip_rule="${ROUTING_PRESETS_IP[$rule_type]:-}"
                if [[ -n "$geoip_rule" && -z "$ip_family_cidr" ]]; then
                    result=$(echo "$result" | jq --arg geoip "$geoip_rule" --arg tag "$tag" --arg key "$tag_key" \
                        '. + [{"type": "field", "ip": [$geoip], ($key): $tag}]')
                fi
            elif [[ "$domains" =~ ^geoip:[^,]+(,geoip:[^,]+)*$ ]]; then
                # geoip 规则支持多个条目
                if [[ -z "$ip_family_cidr" ]]; then
                    local geoip_array
                    geoip_array=$(echo "$domains" | tr ',' '\n' | grep -v '^$' | jq -R . 2>/dev/null | jq -s . 2>/dev/null)
                    if [[ -n "$geoip_array" && "$geoip_array" != "[]" && "$geoip_array" != "null" ]] && echo "$geoip_array" | jq empty 2>/dev/null; then
                        result=$(echo "$result" | jq --argjson ips "$geoip_array" --arg tag "$tag" --arg key "$tag_key" \
                            '. + [{"type": "field", "ip": $ips, ($key): $tag}]')
                    fi
                fi
            else
                # 分离域名和 IP 地址
                local domain_list="" ip_list=""
                local item
                for item in $(echo "$domains" | tr ',' ' '); do
                    [[ -z "$item" ]] && continue
                    # 判断是否是 IP 地址 (IPv4/IPv6/CIDR)
                    if [[ "$item" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || [[ "$item" =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ ]]; then
                        if [[ "$ip_version" == "ipv4_only" && "$item" =~ : ]]; then
                            continue
                        fi
                        if [[ "$ip_version" == "ipv6_only" && "$item" =~ \. ]]; then
                            continue
                        fi
                        [[ -n "$ip_list" ]] && ip_list+=","
                        ip_list+="$item"
                    else
                        [[ -n "$domain_list" ]] && domain_list+=","
                        domain_list+="$item"
                    fi
                done
                
                # 生成域名规则
                if [[ -n "$domain_list" ]]; then
                    local domain_array
                    domain_array=$(echo "$domain_list" | tr ',' '\n' | grep -v '^$' | sed 's/^/domain:/' | jq -R . 2>/dev/null | jq -s . 2>/dev/null)
                    if [[ -n "$domain_array" && "$domain_array" != "[]" && "$domain_array" != "null" ]] && echo "$domain_array" | jq empty 2>/dev/null; then
                        if [[ -n "$ip_family_cidr" ]]; then
                            result=$(echo "$result" | jq --argjson domains "$domain_array" --arg tag "$tag" --arg key "$tag_key" --arg ip "$ip_family_cidr" \
                                '. + [{"type": "field", "domain": $domains, "ip": [$ip], ($key): $tag}]')
                        else
                            result=$(echo "$result" | jq --argjson domains "$domain_array" --arg tag "$tag" --arg key "$tag_key" \
                                '. + [{"type": "field", "domain": $domains, ($key): $tag}]')
                        fi
                    fi
                fi
                
                # 生成 IP 规则
                if [[ -n "$ip_list" ]]; then
                    local ip_array
                    ip_array=$(echo "$ip_list" | tr ',' '\n' | grep -v '^$' | jq -R . 2>/dev/null | jq -s . 2>/dev/null)
                    if [[ -n "$ip_array" && "$ip_array" != "[]" && "$ip_array" != "null" ]] && echo "$ip_array" | jq empty 2>/dev/null; then
                        result=$(echo "$result" | jq --argjson ips "$ip_array" --arg tag "$tag" --arg key "$tag_key" \
                            '. + [{"type": "field", "ip": $ips, ($key): $tag}]')
                    fi
                fi
            fi
        fi
    done < <(echo "$rules" | jq -c '.[]')
    
    result=$(echo "$result" | jq --argjson v6 "$all_ipv6" --argjson v4 "$all_ipv4" --argjson other "$all_other" '. + $v6 + $v4 + $other')
    [[ "$result" != "[]" ]] && echo "$result"
}

# 生成 Sing-box 分流路由配置 (支持多出口)
gen_singbox_routing_rules() {
    local rules=$(db_get_routing_rules)
    [[ -z "$rules" || "$rules" == "[]" ]] && return
    
    local result="[]"
    local all_ipv6="[]"
    local all_ipv4="[]"
    local all_other="[]"
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local rule_type=$(echo "$rule" | jq -r '.type')
        local outbound=$(echo "$rule" | jq -r '.outbound')
        local domains=$(echo "$rule" | jq -r '.domains // ""')
        local ip_version=$(echo "$rule" | jq -r '.ip_version // "prefer_ipv4"')
        local ip_family_cidr=""
        case "$ip_version" in
            ipv4_only) ip_family_cidr="0.0.0.0/0" ;;
            ipv6_only) ip_family_cidr="::/0" ;;
        esac
        
        # 转换出口标识为 tag
        local tag="$outbound"
        if [[ "$outbound" == "direct" ]]; then
            case "$ip_version" in
                ipv4_only) tag="direct-ipv4" ;;
                ipv6_only) tag="direct-ipv6" ;;
                prefer_ipv6) tag="direct-prefer-ipv6" ;;
                as_is|asis) tag="direct-asis" ;;
                *) tag="direct-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == "warp" ]]; then
            case "$ip_version" in
                ipv4_only) tag="warp-ipv4" ;;
                ipv6_only) tag="warp-ipv6" ;;
                prefer_ipv6) tag="warp-prefer-ipv6" ;;
                *) tag="warp-prefer-ipv4" ;;
            esac
        elif [[ "$outbound" == "block" ]]; then
            tag="block"
        elif [[ "$outbound" == chain:* ]]; then
            local node_name="${outbound#chain:}"
            case "$ip_version" in
                ipv4_only) tag="chain-${node_name}-ipv4" ;;
                ipv6_only) tag="chain-${node_name}-ipv6" ;;
                prefer_ipv6) tag="chain-${node_name}-prefer-ipv6" ;;
                *) tag="chain-${node_name}-prefer-ipv4" ;;
            esac
        fi
        
        if [[ "$rule_type" == "all" ]]; then
            local rule_json=""
            if [[ -n "$ip_family_cidr" ]]; then
                rule_json=$(jq -n --arg tag "$tag" --arg ip "$ip_family_cidr" \
                    '{"ip_cidr":[$ip],"outbound":$tag}')
            else
                rule_json=$(jq -n --arg tag "$tag" \
                    '{"outbound":$tag}')
            fi
            case "$ip_version" in
                ipv6_only) all_ipv6=$(echo "$all_ipv6" | jq --argjson r "$rule_json" '. + [$r]') ;;
                ipv4_only) all_ipv4=$(echo "$all_ipv4" | jq --argjson r "$rule_json" '. + [$r]') ;;
                *) all_other=$(echo "$all_other" | jq --argjson r "$rule_json" '. + [$r]') ;;
            esac
        elif [[ -n "$domains" ]]; then
            # 检测是否是 geosite 规则
            if [[ "$domains" == geosite:* ]]; then
                # Sing-box 使用 rule_set 格式，需要引用 geosite 规则集
                local geosite_name="${domains#geosite:}"
                if [[ -n "$ip_family_cidr" ]]; then
                    result=$(echo "$result" | jq --arg geosite "$geosite_name" --arg tag "$tag" --arg ip "$ip_family_cidr" \
                        '. + [{"rule_set": ["geosite-\($geosite)"], "ip_cidr": [$ip], "outbound": $tag}]')
                else
                    result=$(echo "$result" | jq --arg geosite "$geosite_name" --arg tag "$tag" \
                        '. + [{"rule_set": ["geosite-\($geosite)"], "outbound": $tag}]')
                fi
            elif [[ "$domains" =~ ^geoip:[^,]+(,geoip:[^,]+)*$ ]]; then
                # geoip 规则转换为对应 rule_set
                local geoip_rule_set
                geoip_rule_set=$(echo "$domains" | tr ',' '\n' | grep -v '^$' | sed 's/^geoip:/geoip-/' | jq -R . 2>/dev/null | jq -s . 2>/dev/null)
                if [[ -n "$geoip_rule_set" && "$geoip_rule_set" != "[]" && "$geoip_rule_set" != "null" ]] && echo "$geoip_rule_set" | jq empty 2>/dev/null; then
                    if [[ -n "$ip_family_cidr" ]]; then
                        result=$(echo "$result" | jq --argjson sets "$geoip_rule_set" --arg tag "$tag" --arg ip "$ip_family_cidr" \
                            '. + [{"rule_set": $sets, "ip_cidr": [$ip], "outbound": $tag}]')
                    else
                        result=$(echo "$result" | jq --argjson sets "$geoip_rule_set" --arg tag "$tag" \
                            '. + [{"rule_set": $sets, "outbound": $tag}]')
                    fi
                fi
            else
                # 分离域名和 IP 地址
                local domain_list="" ip_list=""
                local item
                for item in $(echo "$domains" | tr ',' ' '); do
                    [[ -z "$item" ]] && continue
                    # 判断是否是 IP 地址 (IPv4/IPv6/CIDR)
                    if [[ "$item" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || [[ "$item" =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ ]]; then
                        if [[ "$ip_version" == "ipv4_only" && "$item" =~ : ]]; then
                            continue
                        fi
                        if [[ "$ip_version" == "ipv6_only" && "$item" =~ \. ]]; then
                            continue
                        fi
                        [[ -n "$ip_list" ]] && ip_list+=","
                        ip_list+="$item"
                    else
                        [[ -n "$domain_list" ]] && domain_list+=","
                        domain_list+="$item"
                    fi
                done
                
                # 生成域名规则
                if [[ -n "$domain_list" ]]; then
                    local domain_array
                    domain_array=$(echo "$domain_list" | tr ',' '\n' | grep -v '^$' | jq -R . 2>/dev/null | jq -s . 2>/dev/null)
                    if [[ -n "$domain_array" && "$domain_array" != "[]" && "$domain_array" != "null" ]] && echo "$domain_array" | jq empty 2>/dev/null; then
                        if [[ -n "$ip_family_cidr" ]]; then
                            result=$(echo "$result" | jq --argjson domains "$domain_array" --arg tag "$tag" --arg ip "$ip_family_cidr" \
                                '. + [{"domain_suffix": $domains, "ip_cidr": [$ip], "outbound": $tag}]')
                        else
                            result=$(echo "$result" | jq --argjson domains "$domain_array" --arg tag "$tag" \
                                '. + [{"domain_suffix": $domains, "outbound": $tag}]')
                        fi
                    fi
                fi
                
                # 生成 IP 规则
                if [[ -n "$ip_list" ]]; then
                    local ip_array
                    ip_array=$(echo "$ip_list" | tr ',' '\n' | grep -v '^$' | jq -R . 2>/dev/null | jq -s . 2>/dev/null)
                    if [[ -n "$ip_array" && "$ip_array" != "[]" && "$ip_array" != "null" ]] && echo "$ip_array" | jq empty 2>/dev/null; then
                        result=$(echo "$result" | jq --argjson ips "$ip_array" --arg tag "$tag" '. + [{"ip_cidr": $ips, "outbound": $tag}]')
                    fi
                fi
            fi
        fi
    done < <(echo "$rules" | jq -c '.[]')
    
    result=$(echo "$result" | jq --argjson v6 "$all_ipv6" --argjson v4 "$all_ipv4" --argjson other "$all_other" '. + $v6 + $v4 + $other')
    [[ "$result" != "[]" ]] && echo "$result"
}

# 生成 Sing-box WARP outbound 配置 (支持 WireGuard 和 SOCKS5 双模式)
gen_singbox_warp_outbound() {
    local warp_mode=$(db_get_warp_mode)
    
    [[ -z "$warp_mode" || "$warp_mode" == "disabled" ]] && return
    
    # === 模式 A: 官方客户端 (SOCKS5) ===
    if [[ "$warp_mode" == "official" ]]; then
        # 检查官方客户端是否运行
        if ! check_cmd warp-cli; then
            return
        fi
        if [[ ! "$WARP_OFFICIAL_PORT" =~ ^[0-9]+$ ]] || [[ "$WARP_OFFICIAL_PORT" -lt 1 || "$WARP_OFFICIAL_PORT" -gt 65535 ]]; then
            return
        fi
        
        # 生成 SOCKS5 出站
        jq -n --argjson port "$WARP_OFFICIAL_PORT" '{
            tag: "warp",
            type: "socks",
            server: "127.0.0.1",
            server_port: $port,
            version: "5"
        }'
        return
    fi
    
    # === 模式 B: WGCF (WireGuard) ===
    [[ "$warp_mode" != "wgcf" ]] && return
    [[ ! -f "$WARP_CONF_FILE" ]] && return
    
    local private_key=$(jq -r '.private_key' "$WARP_CONF_FILE")
    local public_key=$(jq -r '.public_key' "$WARP_CONF_FILE")
    # 必须保留完整 CIDR 掩码，避免下游解析失败
    local address_v4=$(jq -r '.address_v4' "$WARP_CONF_FILE")
    local address_v6=$(jq -r '.address_v6' "$WARP_CONF_FILE")
    local endpoint=$(jq -r '.endpoint' "$WARP_CONF_FILE")
    
    # 正确解析 endpoint（支持 IPv6 格式 [host]:port）
    local ep_host ep_port
    if [[ "$endpoint" == \[*\]:* ]]; then
        # IPv6 格式: [2606:4700:d0::a29f:c001]:2408
        ep_host=$(echo "$endpoint" | sed 's/^\[\(.*\)\]:.*/\1/')
        ep_port=$(echo "$endpoint" | sed 's/.*\]://')
    else
        # IPv4 格式: 162.159.192.1:2408
        ep_host=$(echo "$endpoint" | cut -d':' -f1)
        ep_port=$(echo "$endpoint" | cut -d':' -f2)
    fi
    
    jq -n \
        --arg pk "$private_key" \
        --arg pub "$public_key" \
        --arg v4 "$address_v4" \
        --arg v6 "$address_v6" \
        --arg host "$ep_host" \
        --argjson port "$ep_port" \
    '{
        endpoint: {
            type: "wireguard",
            tag: "warp",
            system: false,
            name: "wg-warp",
            mtu: 1280,
            address: [$v4, $v6],
            private_key: $pk,
            peers: [{
                address: $host,
                port: $port,
                public_key: $pub,
                allowed_ips: ["0.0.0.0/0", "::/0"]
            }]
        }
    }'
}

# 显示当前分流状态 (多规则版本)
show_routing_status() {
    local warp_st=$(warp_status)
    
    echo ""
    echo -e "  ${C}出口状态${NC}"
    _line
    
    # 直连出口 IP 版本（默认 AsIs）
    local direct_ip_version="as_is"
    [[ -f "$CFG/direct_ip_version" ]] && direct_ip_version=$(cat "$CFG/direct_ip_version")
    local direct_display=""
    case "$direct_ip_version" in
        ipv4|ipv4_only) direct_display="仅 IPv4" ;;
        ipv6|ipv6_only) direct_display="仅 IPv6" ;;
        prefer_ipv4) direct_display="优先 IPv4" ;;
        prefer_ipv6) direct_display="优先 IPv6" ;;
        as_is|asis) direct_display="AsIs" ;;
        # 兜底展示异常值，避免界面空白
        *) direct_display="${Y}未知 ($direct_ip_version)${NC}" ;;
    esac
    echo -e "  直连: ${G}$direct_display${NC}"
    
    # WARP 状态
    case "$warp_st" in
        connected)
            echo -e "  WARP: ${G}● 已连接${NC} (官方客户端/TCP)"
            ;;
        registered)
            echo -e "  WARP: ${Y}● 已注册${NC} (未连接)"
            ;;
        configured)
            echo -e "  WARP: ${G}● 已配置${NC} (WGCF/UDP)"
            ;;
        *)
            echo -e "  WARP: ${D}○ 未配置${NC}"
            ;;
    esac
    
    # 链式代理节点数量
    local nodes=$(db_get_chain_nodes 2>/dev/null)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$node_count" -gt 0 ]]; then
        echo -e "  代理: ${G}● ${node_count} 个节点${NC}"
    else
        echo -e "  代理: ${D}○ 无节点${NC}"
    fi
    
    _line
    echo -e "  ${C}分流规则${NC}"
    _line
    
    # 显示分流规则 (优化：一次性提取所有字段，避免多次调用 jq)
    local rules=$(db_get_routing_rules)
    
    if [[ -n "$rules" && "$rules" != "[]" ]]; then
        local rule_count=0
        # 一次性提取 type, outbound, domains, ip_version，用 | 分隔
        while IFS='|' read -r rule_type outbound domains ip_version; do
            [[ -z "$rule_type" ]] && continue
            local outbound_name=$(_get_outbound_display_name "$outbound")
            
            local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
            if [[ "$rule_type" == "custom" ]]; then
                # 自定义规则显示域名
                if [[ -n "$domains" && "$domains" != "null" ]]; then
                    local display_domains="$domains"
                    if [[ ${#domains} -gt 20 ]]; then
                        display_domains="${domains:0:17}..."
                    fi
                    rule_name="自定义 (${display_domains})"
                else
                    rule_name="自定义"
                fi
            fi
            [[ "$rule_type" == "all" ]] && rule_name="所有流量"
            [[ "$rule_type" == "ads" ]] && rule_name="广告屏蔽"
            
            # IP 版本标记
            local ip_mark=""
            case "$ip_version" in
                ipv4_only) ip_mark=" ${C}[仅IPv4]${NC}" ;;
                ipv6_only) ip_mark=" ${C}[仅IPv6]${NC}" ;;
                prefer_ipv4) ip_mark=" ${C}[优先IPv4]${NC}" ;;
                prefer_ipv6) ip_mark=" ${C}[优先IPv6]${NC}" ;;
                as_is|asis) ip_mark=" ${C}[ALL]${NC}" ;;
            esac
            
            if [[ "$rule_type" == "all" ]]; then
                echo -e "  ${Y}●${NC} ${rule_name} → ${C}${outbound_name}${NC}${ip_mark}"
            elif [[ "$rule_type" == "ads" ]]; then
                echo -e "  ${R}●${NC} ${rule_name} → ${D}拦截${NC}"
            else
                echo -e "  ${G}●${NC} ${rule_name} → ${C}${outbound_name}${NC}${ip_mark}"
            fi
            
            ((rule_count++))
        done < <(echo "$rules" | jq -r '.[] | "\(.type)|\(.outbound)|\(.domains // "")|\(.ip_version // "prefer_ipv4")"')
        
        [[ $rule_count -eq 0 ]] && echo -e "  ${D}未配置分流规则${NC}"
    else
        echo -e "  ${D}未配置分流规则${NC}"
    fi
    _line
}

# 测试分流是否生效
test_routing() {
    local rules=$(db_get_routing_rules)
    
    # 检查是否有规则
    if [[ -z "$rules" || "$rules" == "[]" ]]; then
        _info "未配置分流规则"
        return 0
    fi
    
    echo ""
    _info "测试分流效果..."
    _line
    
    # 获取本机直连 IP
    local direct_ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    [[ -z "$direct_ip" ]] && direct_ip=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null)
    echo -e "  直连出口 IP: ${C}${direct_ip:-获取失败}${NC}"
    
    # 测试 WARP 出口
    local warp_st=$(warp_status)
    if [[ "$warp_st" == "connected" ]]; then
        local warp_ip=$(curl -s --connect-timeout 10 --socks5 127.0.0.1:$WARP_OFFICIAL_PORT https://api.ipify.org 2>/dev/null)
        [[ -n "$warp_ip" ]] && echo -e "  WARP 出口 IP: ${G}${warp_ip}${NC}"
    elif [[ "$warp_st" == "configured" ]]; then
        echo -e "  WARP: ${G}已配置${NC} (WGCF/UDP)"
    fi
    
    _line
    
    # 显示规则测试信息
    echo -e "  ${Y}已配置的分流规则:${NC}"
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local rule_type=$(echo "$rule" | jq -r '.type')
        local outbound=$(echo "$rule" | jq -r '.outbound')
        local domains=$(echo "$rule" | jq -r '.domains // ""')
        
        local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
        [[ "$rule_type" == "custom" ]] && rule_name="自定义"
        [[ "$rule_type" == "all" ]] && rule_name="所有流量"
        local outbound_name=$(_get_outbound_display_name "$outbound")
        
        # 获取测试域名
        if [[ "$rule_type" == "all" ]]; then
            echo -e "  ${G}●${NC} ${rule_name} → ${outbound_name}"
        else
            local test_domain=""
            [[ -n "$domains" && "$domains" != "null" ]] && test_domain=$(echo "$domains" | cut -d',' -f1)
            echo -e "  ${G}●${NC} ${rule_name} → ${outbound_name} (${test_domain:-N/A})"
        fi
    done < <(echo "$rules" | jq -c '.[]')
    
    echo ""
    echo -e "  ${G}✓${NC} 分流规则已配置"
    _line
    echo -e "  ${Y}验证方法:${NC}"
    echo -e "  • 手机访问 ${C}https://ip.sb${NC} 查看出口 IP"
    echo ""
    echo -e "  ${Y}调试命令 (Xray):${NC}"
    echo -e "  • 检查配置语法: ${C}xray run -test -c /etc/vless-reality/config.json${NC}"
    if [[ "$DISTRO" == "alpine" ]]; then
        # Alpine OpenRC 日志命令
        echo -e "  • 开启调试日志: ${C}sed -i 's/\"loglevel\":\"warning\"/\"loglevel\":\"debug\"/' /etc/vless-reality/config.json && rc-service vless-reality restart${NC}"
        echo -e "  • 查看实时日志: ${C}tail -f /var/log/vless/xray.log${NC}"
        echo -e "  • 关闭调试日志: ${C}sed -i 's/\"loglevel\":\"debug\"/\"loglevel\":\"warning\"/' /etc/vless-reality/config.json && rc-service vless-reality restart${NC}"
    else
        # systemd 日志命令
        echo -e "  • 开启调试日志: ${C}sed -i 's/\"loglevel\":\"warning\"/\"loglevel\":\"debug\"/' /etc/vless-reality/config.json && systemctl restart vless-reality${NC}"
        echo -e "  • 查看实时日志: ${C}journalctl -u vless-reality -f${NC}"
        echo -e "  • 关闭调试日志: ${C}sed -i 's/\"loglevel\":\"debug\"/\"loglevel\":\"warning\"/' /etc/vless-reality/config.json && systemctl restart vless-reality${NC}"
    fi
    
    # 检查是否有 sing-box 协议
    if db_exists "singbox" "hy2" || db_exists "singbox" "tuic"; then
        echo ""
        echo -e "  ${Y}调试命令 (Sing-box):${NC}"
        echo -e "  • 检查配置语法: ${C}sing-box check -c /etc/vless-reality/singbox.json${NC}"
        if [[ "$DISTRO" == "alpine" ]]; then
            # Alpine OpenRC 日志命令
            echo -e "  • 开启调试日志: ${C}sed -i 's/\"level\":\"warn\"/\"level\":\"debug\"/' /etc/vless-reality/singbox.json && rc-service vless-singbox restart${NC}"
            echo -e "  • 查看实时日志: ${C}tail -f /var/log/vless/singbox.log${NC}"
            echo -e "  • 关闭调试日志: ${C}sed -i 's/\"level\":\"debug\"/\"level\":\"warn\"/' /etc/vless-reality/singbox.json && rc-service vless-singbox restart${NC}"
        else
            # systemd 日志命令
            echo -e "  • 开启调试日志: ${C}sed -i 's/\"level\":\"warn\"/\"level\":\"debug\"/' /etc/vless-reality/singbox.json && systemctl restart vless-singbox${NC}"
            echo -e "  • 查看实时日志: ${C}journalctl -u vless-singbox -f${NC}"
            echo -e "  • 关闭调试日志: ${C}sed -i 's/\"level\":\"debug\"/\"level\":\"warn\"/' /etc/vless-reality/singbox.json && systemctl restart vless-singbox${NC}"
        fi
    fi
    
    return 0
}

# 配置分流规则
configure_routing_rules() {
    while true; do
        _header
        echo -e "  ${W}配置分流规则${NC}"
        show_routing_status
        
        _item "1" "添加分流规则"
        _item "2" "删除分流规则"
        _item "3" "清空所有规则"
        _item "4" "测试分流效果"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        
        case "$choice" in
            1) _add_routing_rule ;;
            2) _del_routing_rule ;;
            3)
                read -rp "  确认清空所有分流规则? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    db_clear_routing_rules
                    _regenerate_proxy_configs
                    _ok "已清空所有分流规则"
                fi
                _pause
                ;;
            4)
                _header
                echo -e "  ${W}测试分流效果${NC}"
                test_routing
                _pause
                ;;
            0) return ;;
        esac
    done
}

# 添加分流规则
_add_routing_rule() {
    _header
    echo -e "  ${W}添加分流规则${NC}"
    _line
    echo -e "  ${D}优先级: 直连规则 > 自定义规则 > 预设规则 > 全局规则${NC}"
    _line
    
    echo -e "  ${Y}选择规则类型:${NC}"
    echo ""
    _item "1" "OpenAI/ChatGPT"
    _item "2" "Netflix"
    _item "3" "Disney+"
    _item "4" "YouTube"
    _item "5" "Spotify"
    _item "6" "TikTok"
    _item "7" "Telegram"
    _item "8" "Google"
    _item "9" "AI服务(国际)"
    _item "d" "MyTVSuper"
    _item "c" "自定义域名"
    _item "b" "广告屏蔽 (geosite)"
    _item "a" "所有流量"
    _item "0" "返回"
    _line
    
    read -rp "  请选择: " rule_choice
    
    local rule_type="" custom_domains=""
    case "$rule_choice" in
        1) rule_type="openai" ;;
        2) rule_type="netflix" ;;
        3) rule_type="disney" ;;
        4) rule_type="youtube" ;;
        5) rule_type="spotify" ;;
        6) rule_type="tiktok" ;;
        7) rule_type="telegram" ;;
        8) rule_type="google" ;;
        9) rule_type="ai-intl" ;;
        d|D) rule_type="mytvsuper" ;;
        c|C)
            rule_type="custom"
            echo ""
            echo -e "  ${Y}输入要分流的匹配规则 (逗号分隔):${NC}"
            echo -e "  ${D}支持三种格式:${NC}"
            echo -e "  ${D}  1) 普通域名/IP: google.com,youtube.com 或 1.2.3.4,192.168.0.0/16${NC}"
            echo -e "  ${D}  2) geosite 规则: geosite:category-ads-all${NC}"
            echo -e "  ${D}  3) geoip 规则: geoip:cn,geoip:telegram${NC}"
            read -rp "  匹配规则: " custom_domains
            custom_domains=$(echo "$custom_domains" | tr -d ' \t')
            if [[ -z "$custom_domains" ]]; then
                _warn "输入不能为空"
                _pause
                return
            fi
            # 验证格式：域名包含点，IP 包含数字和点或冒号
            if [[ ! "$custom_domains" =~ [\.\:] ]]; then
                _warn "格式无效，请输入有效的域名或IP"
                _pause
                return
            fi
            ;;
        b|B) rule_type="ads" ;;
        a|A) rule_type="all" ;;
        0|"") return ;;
        *) _warn "无效选项"; _pause; return ;;
    esac
    
    # 广告屏蔽规则直接使用 block 出口，不需要选择
    if [[ "$rule_type" == "ads" ]]; then
        db_add_routing_rule "$rule_type" "block"
        _ok "已添加规则: 广告屏蔽 → 拦截"
        _info "更新代理配置..."
        _regenerate_proxy_configs
        _ok "配置已更新"
        _pause
        return
    fi
    
    # 选择出口
    echo ""
    echo -e "  ${Y}选择出口:${NC}"
    local outbound=$(_select_outbound "选择出口" "no_check")
    [[ -z "$outbound" ]] && return
    
    # 选择匹配的 IP 版本（用于 IPv4/IPv6 分流）
    local ip_version="as_is"  # 默认值
    echo ""
    echo -e "  ${Y}匹配的 IP 版本:${NC}"
    echo -e "  ${G}1)${NC} 仅 IPv4（只匹配 IPv4 流量）"
    echo -e "  ${G}2)${NC} 仅 IPv6（只匹配 IPv6 流量）"
    echo -e "  ${G}3)${NC} ALL（不限制，匹配全部）"
    read -rp "  请选择 [1-3，默认 3]: " ip_version_choice
    
    case "$ip_version_choice" in
        1) ip_version="ipv4_only" ;;
        2) ip_version="ipv6_only" ;;
        3|"") ip_version="as_is" ;;
    esac
    
    # 检查规则是否已存在 (custom 类型允许多条，不检查)
    if [[ "$rule_type" != "custom" ]]; then
        if [[ "$rule_type" == "all" ]]; then
            if db_has_routing_rule_by_type_and_ip_version "$rule_type" "$ip_version"; then
                local ip_text=""
                case "$ip_version" in
                    ipv4_only) ip_text="仅IPv4" ;;
                    ipv6_only) ip_text="仅IPv6" ;;
                    prefer_ipv4) ip_text="优先IPv4" ;;
                    prefer_ipv6) ip_text="优先IPv6" ;;
                    as_is|asis) ip_text="ALL" ;;
                esac
                _warn "所有流量 规则(${ip_text})已存在"
                read -rp "  是否覆盖? [y/N]: " overwrite
                [[ ! "$overwrite" =~ ^[Yy]$ ]] && return
            fi
        else
            if db_has_routing_rule "$rule_type"; then
                _warn "${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type} 规则已存在"
                read -rp "  是否覆盖? [y/N]: " overwrite
                [[ ! "$overwrite" =~ ^[Yy]$ ]] && return
            fi
        fi
    fi

    # 保存规则
    if [[ "$rule_type" == "custom" ]]; then
        db_add_routing_rule "$rule_type" "$outbound" "$custom_domains" "$ip_version"
    else
        db_add_routing_rule "$rule_type" "$outbound" "" "$ip_version"
    fi
    
    local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
    [[ "$rule_type" == "custom" ]] && rule_name="自定义"
    [[ "$rule_type" == "all" ]] && rule_name="所有流量"
    local outbound_name=$(_get_outbound_display_name "$outbound")
    
    # 显示 IP 版本标记
    local ip_version_mark=""
    case "$ip_version" in
        ipv4_only) ip_version_mark=" ${C}[仅IPv4]${NC}" ;;
        ipv6_only) ip_version_mark=" ${C}[仅IPv6]${NC}" ;;
        prefer_ipv4) ip_version_mark=" ${C}[优先IPv4]${NC}" ;;
        prefer_ipv6) ip_version_mark=" ${C}[优先IPv6]${NC}" ;;
        as_is|asis) ip_version_mark=" ${C}[ALL]${NC}" ;;
    esac
    
    _ok "已添加规则: ${rule_name} → ${outbound_name}${ip_version_mark}"
    
    # 更新配置
    _info "更新代理配置..."
    _regenerate_proxy_configs
    _ok "配置已更新"
    _pause
}

# 删除分流规则
_del_routing_rule() {
    _header
    echo -e "  ${W}删除分流规则${NC}"
    _line
    
    local rules=$(db_get_routing_rules)
    if [[ -z "$rules" || "$rules" == "[]" ]]; then
        _warn "没有分流规则"
        _pause
        return
    fi
    
    # 显示规则列表
    local idx=1
    local rule_ids=()
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local rule_id=$(echo "$rule" | jq -r '.id')
        local rule_type=$(echo "$rule" | jq -r '.type')
        local outbound=$(echo "$rule" | jq -r '.outbound')
        local domains=$(echo "$rule" | jq -r '.domains // ""')
        local ip_version=$(echo "$rule" | jq -r '.ip_version // "prefer_ipv4"')
        local rule_name="${ROUTING_PRESET_NAMES[$rule_type]:-$rule_type}"
        
        # 自定义规则显示域名
        if [[ "$rule_type" == "custom" ]]; then
            # 截取域名显示，过长则省略
            local display_domains="$domains"
            if [[ ${#domains} -gt 30 ]]; then
                display_domains="${domains:0:27}..."
            fi
            rule_name="自定义 (${display_domains})"
        fi
        [[ "$rule_type" == "all" ]] && rule_name="所有流量"
        local outbound_name=$(_get_outbound_display_name "$outbound")

        # IP 版本标记（广告屏蔽规则无需显示）
        local ip_mark=""
        if [[ "$rule_type" != "ads" ]]; then
            case "$ip_version" in
                ipv4_only) ip_mark=" ${C}[仅IPv4]${NC}" ;;
                ipv6_only) ip_mark=" ${C}[仅IPv6]${NC}" ;;
                prefer_ipv4) ip_mark=" ${C}[优先IPv4]${NC}" ;;
                prefer_ipv6) ip_mark=" ${C}[优先IPv6]${NC}" ;;
                as_is|asis) ip_mark=" ${C}[ALL]${NC}" ;;
            esac
        fi
        
        echo -e "  ${G}${idx})${NC} ${rule_name} → ${outbound_name}${ip_mark}"
        rule_ids+=("$rule_id")
        ((idx++))
    done < <(echo "$rules" | jq -c '.[]')
    
    echo ""
    read -rp "  输入序号删除 (0 返回): " del_choice
    
    if [[ "$del_choice" =~ ^[0-9]+$ ]] && [[ "$del_choice" -ge 1 && "$del_choice" -le ${#rule_ids[@]} ]]; then
        local del_id="${rule_ids[$((del_choice-1))]}"
        db_del_routing_rule "$del_id"
        _regenerate_proxy_configs
        _ok "已删除规则"
    fi
    _pause
}

# 重新生成代理配置的辅助函数
_regenerate_proxy_configs() {
    local xray_protocols=$(get_xray_protocols)
    if [[ -n "$xray_protocols" ]]; then
        generate_xray_config
        svc restart vless-reality 2>/dev/null
    fi
    
    local singbox_protocols=$(get_singbox_protocols)
    if [[ -n "$singbox_protocols" ]]; then
        generate_singbox_config
        svc restart vless-singbox 2>/dev/null
    fi
}

# WARP 管理菜单 (二选一模式)
manage_warp() {
    _header
    echo -e "  ${W}WARP 管理${NC}"
    
    local status=$(warp_status)
    local current_mode=$(db_get_warp_mode)
    
    _line
    case "$status" in
        connected)
            echo -e "  状态: ${G}● 已连接${NC}"
            echo -e "  模式: ${C}官方客户端 (TCP/SOCKS5)${NC}"
            echo -e "  代理: ${G}127.0.0.1:${WARP_OFFICIAL_PORT}${NC}"
            echo -e "  ${D}抗 UDP 封锁，稳定性好${NC}"
            ;;
        registered)
            echo -e "  状态: ${Y}● 已注册${NC} (未连接)"
            echo -e "  模式: ${C}官方客户端${NC}"
            ;;
        configured)
            echo -e "  状态: ${G}● 已配置${NC}"
            echo -e "  模式: ${C}WGCF (UDP/WireGuard)${NC}"
            if [[ -f "$WARP_CONF_FILE" ]]; then
                local endpoint=$(jq -r '.endpoint // "N/A"' "$WARP_CONF_FILE" 2>/dev/null)
                echo -e "  端点: ${D}${endpoint}${NC}"
            fi
            echo -e "  ${D}性能好，但可能被 UDP 封锁${NC}"
            ;;
        *)
            echo -e "  状态: ${D}○ 未配置${NC}"
            echo ""
            echo -e "  ${D}WARP 提供 Cloudflare 的干净 IP 出口${NC}"
            echo -e "  ${D}用于解锁 ChatGPT/Netflix 等服务${NC}"
            echo ""
            echo -e "  ${Y}两种模式:${NC}"
            echo -e "  ${D}• WGCF: UDP/WireGuard，性能好${NC}"
            echo -e "  ${D}• 官方客户端: TCP/SOCKS5，绕过 UDP 封锁${NC}"
            ;;
    esac
    _line
    
    if [[ "$status" == "not_configured" ]]; then
        _item "1" "配置 WGCF 模式 (UDP/WireGuard)"
        _item "2" "配置官方客户端 (TCP/SOCKS5)"
    else
        if [[ "$current_mode" == "official" ]]; then
            _item "1" "切换到 WGCF 模式"
            _item "2" "重新连接官方客户端"
            _item "3" "测试 WARP 连接"
            _item "4" "卸载官方客户端"
        else
            _item "1" "切换到官方客户端模式"
            _item "2" "重新获取 WGCF 配置"
            _item "3" "测试 WARP 连接"
            _item "4" "卸载 WGCF"
        fi
    fi
    _item "0" "返回"
    _line
    
    read -rp "  请选择: " choice
    choice=$(echo "$choice" | tr -d ' \t')
    
    if [[ "$status" == "not_configured" ]]; then
        case "$choice" in
            1)
                # 配置 WGCF
                if register_warp; then
                    db_set_warp_mode "wgcf"
                    _regenerate_proxy_configs
                    _ok "WGCF 模式配置完成"
                fi
                _pause
                ;;
            2)
                # 配置官方客户端
                if [[ "$DISTRO" == "alpine" ]]; then
                    _err "Alpine 系统不支持官方客户端"
                    _info "请使用 WGCF 模式"
                    _pause
                    return
                fi
                if install_warp_official; then
                    if configure_warp_official; then
                        _regenerate_proxy_configs
                        _ok "官方客户端模式配置完成"
                    fi
                fi
                _pause
                ;;
            0) return ;;
            *) _warn "无效选项" ;;
        esac
    else
        case "$choice" in
            1)
                # 切换模式
                if [[ "$current_mode" == "official" ]]; then
                    # 切换到 WGCF
                    _info "切换到 WGCF 模式..."
                    warp-cli disconnect 2>/dev/null
                    # 停止 warp-svc 服务，避免与 WGCF 冲突
                    systemctl stop warp-svc 2>/dev/null
                    systemctl disable warp-svc 2>/dev/null
                    if register_warp; then
                        db_set_warp_mode "wgcf"
                        _regenerate_proxy_configs
                        _ok "已切换到 WGCF 模式"
                    fi
                else
                    # 切换到官方客户端
                    if [[ "$DISTRO" == "alpine" ]]; then
                        _err "Alpine 系统不支持官方客户端"
                        _pause
                        return
                    fi
                    _info "切换到官方客户端模式..."
                    if install_warp_official; then
                        if configure_warp_official; then
                            _regenerate_proxy_configs
                            _ok "已切换到官方客户端模式"
                        fi
                    fi
                fi
                _pause
                ;;
            2)
                # 重新配置/连接
                if [[ "$current_mode" == "official" ]]; then
                    reconnect_warp_official
                else
                    refresh_warp_wgcf
                fi
                _pause
                ;;
            3)
                test_warp_connection
                _pause
                ;;
            4)
                echo ""
                read -rp "  确认卸载 WARP? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy] ]]; then
                    uninstall_warp
                fi
                _pause
                ;;
            0) return ;;
            *) _warn "无效选项" ;;
        esac
    fi
}

# 配置直连出口 IP 版本
configure_direct_outbound() {
    _header
    echo -e "  ${W}直连出口设置${NC}"
    _line
    echo -e "  ${D}设置直连流量使用的 IP 版本${NC}"
    echo -e "  ${D}适用于双栈服务器选择出口 IP${NC}"
    echo ""
    
    # 读取当前设置，默认 AsIs
    local current="as_is"
    [[ -f "$CFG/direct_ip_version" ]] && current=$(cat "$CFG/direct_ip_version")
    
    echo -e "  当前设置: ${G}$current${NC}"
    echo ""
    _item "1" "仅 IPv4（IPv6 受限或不稳定环境）"
    _item "2" "仅 IPv6（双栈环境，强制 IPv6）"
    _item "3" "优先 IPv4（双栈环境，优先 IPv4）"
    _item "4" "优先 IPv6（双栈环境，优先 IPv6）"
    _item "5" "AsIs（默认值，不做处理）"
    _item "0" "返回"
    _line
    
    read -rp "  请选择: " choice
    
    local new_setting=""
    case "$choice" in
        1) new_setting="ipv4_only" ;;
        2) new_setting="ipv6_only" ;;
        3) new_setting="prefer_ipv4" ;;
        4) new_setting="prefer_ipv6" ;;
        5) new_setting="as_is" ;;
        0|"") return ;;
        *) _warn "无效选项"; return ;;
    esac
    
    echo "$new_setting" > "$CFG/direct_ip_version"
    _ok "直连出口已设置为: $new_setting"
    
    # 重新生成配置
    local xray_protocols=$(get_xray_protocols)
    if [[ -n "$xray_protocols" ]]; then
        _info "重新生成 Xray 配置..."
        svc stop vless-reality 2>/dev/null
        generate_xray_config
        svc start vless-reality 2>/dev/null
    fi
    
    local singbox_protocols=$(get_singbox_protocols)
    if [[ -n "$singbox_protocols" ]]; then
        _info "重新生成 Sing-box 配置..."
        svc stop vless-singbox 2>/dev/null
        generate_singbox_config
    fi
}

# WARP → 落地 双层链式代理一键配置
setup_warp_ipv6_chain() {
    _header
    echo -e "  ${W}WARP → 落地 (双层链式代理)${NC}"
    _line
    echo -e "  ${C}功能说明:${NC}"
    echo -e "  ${D}通过 WARP 隧道连接落地机，实现双层链式代理${NC}"
    echo -e "  ${D}适用于需要通过 WARP 中转再连接落地机的场景${NC}"
    _line
    echo ""
    
    # 1. 检查/启用 WARP
    local warp_mode=$(db_get_warp_mode)
    if [[ -z "$warp_mode" || "$warp_mode" == "disabled" ]]; then
        _info "检测到 WARP 未启用，正在配置..."
        
        # 检查系统是否支持
        if [[ "$DISTRO" == "alpine" ]]; then
            echo -e "  ${Y}Alpine 系统仅支持 wgcf 模式${NC}"
        fi
        
        # 安装/注册 WARP
        if ! register_warp; then
            _err "WARP 配置失败"
            _pause
            return 1
        fi
        db_set_warp_mode "wgcf"
        _ok "WARP (wgcf) 配置成功"
    else
        echo -e "  WARP 状态: ${G}● 已启用${NC} (${warp_mode})"
    fi
    echo ""
    
    # 2. 选择落地节点 (从已有节点选择或添加新节点)
    _line
    echo -e "  ${W}选择落地节点${NC}"
    _line
    
    local nodes=$(db_get_chain_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    local selected_node_name=""
    
    if [[ "$node_count" -gt 0 ]]; then
        echo -e "  ${C}已有节点:${NC}"
        echo ""
        local i=1
        local node_names=()
        while IFS= read -r node_info; do
            local name=$(echo "$node_info" | jq -r '.name')
            local type=$(echo "$node_info" | jq -r '.type')
            local server=$(echo "$node_info" | jq -r '.server')
            local is_warp=$(echo "$node_info" | jq -r '.via_warp // false')
            node_names+=("$name")
            
            local warp_mark=""
            [[ "$is_warp" == "true" ]] && warp_mark=" ${Y}[WARP]${NC}"
            
            echo -e "  ${G}$i)${NC} $name ${D}($type @ $server)${NC}${warp_mark}"
            ((i++))
        done < <(echo "$nodes" | jq -c '.[]')
        
        echo ""
        echo -e "  ${G}$i)${NC} ${C}添加新节点${NC}"
        echo -e "  ${G}0)${NC} 取消"
        _line
        
        read -rp "  请选择: " node_choice
        
        if [[ "$node_choice" == "0" ]]; then
            return 0
        elif [[ "$node_choice" =~ ^[0-9]+$ ]] && [[ "$node_choice" -ge 1 ]] && [[ "$node_choice" -lt $i ]]; then
            # 选择已有节点
            selected_node_name="${node_names[$((node_choice-1))]}"
            
            # 标记该节点为通过 WARP 连接
            local tmp=$(mktemp)
            jq --arg name "$selected_node_name" '
                .chain_proxy.nodes = [.chain_proxy.nodes[]? | 
                    if .name == $name then .via_warp = true else . end
                ]
            ' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
            
            _ok "已选择节点: $selected_node_name (通过 WARP)"
        elif [[ "$node_choice" == "$i" ]]; then
            # 添加新节点
            echo ""
            echo -e "  ${D}请输入落地机的分享链接 (IPv4 或 IPv6 均可)${NC}"
            echo -e "  ${D}支持: vless://, vmess://, trojan://, ss://${NC}"
            echo ""
            
            local share_link
            read -rp "  分享链接: " share_link
            
            if [[ -z "$share_link" ]]; then
                _err "分享链接不能为空"
                _pause
                return 1
            fi
            
            local node_json=$(parse_share_link "$share_link")
            if [[ -z "$node_json" || "$node_json" == "null" ]]; then
                _err "无法解析分享链接"
                _pause
                return 1
            fi
            
            local node_name=$(echo "$node_json" | jq -r '.name')
            selected_node_name="warp-${node_name}"
            
            node_json=$(echo "$node_json" | jq --arg name "$selected_node_name" '.name = $name | .via_warp = true')
            
            if ! db_add_chain_node "$node_json"; then
                _err "保存节点失败"
                _pause
                return 1
            fi
            
            _ok "落地节点已添加: $selected_node_name"
        else
            _err "无效选择"
            _pause
            return 1
        fi
    else
        # 没有已有节点，直接添加
        echo -e "  ${D}暂无节点，请添加落地机分享链接${NC}"
        echo -e "  ${D}支持: vless://, vmess://, trojan://, ss://${NC}"
        echo ""
        
        local share_link
        read -rp "  分享链接: " share_link
        
        if [[ -z "$share_link" ]]; then
            _err "分享链接不能为空"
            _pause
            return 1
        fi
        
        local node_json=$(parse_share_link "$share_link")
        if [[ -z "$node_json" || "$node_json" == "null" ]]; then
            _err "无法解析分享链接"
            _pause
            return 1
        fi
        
        local node_name=$(echo "$node_json" | jq -r '.name')
        selected_node_name="warp-${node_name}"
        
        node_json=$(echo "$node_json" | jq --arg name "$selected_node_name" '.name = $name | .via_warp = true')
        
        if ! db_add_chain_node "$node_json"; then
            _err "保存节点失败"
            _pause
            return 1
        fi
        
        _ok "落地节点已添加: $selected_node_name"
    fi
    echo ""
    
    # 4. 配置分流规则
    _line
    echo -e "  ${W}选择分流模式${NC}"
    _line
    _item "1" "全部流量经过落地 (推荐)"
    _item "2" "仅指定规则经过落地"
    _item "0" "跳过分流配置"
    _line
    
    read -rp "  请选择: " routing_choice
    
    case "$routing_choice" in
        1)
            # 全部流量
            echo ""
            echo -e "  ${Y}是否区分 IPv4 / IPv6 出口:${NC}"
            _item "1" "不区分（全部流量 → WARP → 落地）"
            _item "2" "区分 IPv4 / IPv6（分别选择出口）"
            _item "0" "返回"
            _line

            read -rp "  请选择 [1]: " split_choice
            split_choice=${split_choice:-1}

            case "$split_choice" in
                1)
                    db_clear_routing_rules
                    db_add_routing_rule "all" "chain:$selected_node_name" "" "as_is"
                    _ok "已配置: 全部流量 → WARP → 落地"
                    ;;
                2)
                    db_clear_routing_rules
                    echo ""
                    _info "将分别为 IPv4 / IPv6 添加 all 规则"
                    echo -e "  ${Y}选择 IPv4 出口:${NC}"
                    local outbound_v4=$(_select_outbound "选择 IPv4 出口" "no_check")
                    [[ -z "$outbound_v4" ]] && return 1

                    echo ""
                    echo -e "  ${Y}选择 IPv6 出口:${NC}"
                    local outbound_v6=$(_select_outbound "选择 IPv6 出口" "no_check")
                    [[ -z "$outbound_v6" ]] && return 1

                    db_add_routing_rule "all" "$outbound_v4" "" "ipv4_only"
                    db_add_routing_rule "all" "$outbound_v6" "" "ipv6_only"

                    local outbound_v4_name=$(_get_outbound_display_name "$outbound_v4")
                    local outbound_v6_name=$(_get_outbound_display_name "$outbound_v6")
                    _ok "已配置: IPv4 → ${outbound_v4_name} / IPv6 → ${outbound_v6_name}"
                    ;;
                0)
                    return 0
                    ;;
                *)
                    _warn "无效选项"
                    return 1
                    ;;
            esac
            ;;
        2)
            # 进入分流规则配置
            configure_routing_rules
            ;;
        *)
            _info "跳过分流配置"
            ;;
    esac
    
    # 5. 重新生成配置
    echo ""
    _info "正在生成双层链式代理配置..."
    
    # 重新生成 Xray 配置
    local xray_protocols=$(get_xray_protocols)
    if [[ -n "$xray_protocols" ]]; then
        svc stop vless-reality 2>/dev/null
        generate_xray_config
        svc start vless-reality 2>/dev/null
        _ok "Xray 配置已更新"
    fi
    
    # 重新生成 Sing-box 配置
    local singbox_protocols=$(get_singbox_protocols)
    if [[ -n "$singbox_protocols" ]]; then
        svc stop vless-singbox 2>/dev/null
        generate_singbox_config
        svc start vless-singbox 2>/dev/null
        _ok "Sing-box 配置已更新"
    fi
    
    _ok "配置完成!"
    echo ""
    _dline
    echo -e "  ${G}双层链式代理已启用${NC}"
    _dline
    echo -e "  ${C}流量路径:${NC}"
    echo -e "  您的客户端 → 本服务器 → ${Y}WARP${NC} → ${G}落地机${NC}"
    _dline
    
    _pause
}

# 分流管理主菜单
manage_routing() {
    while true; do
        _header
        echo -e "  ${W}分流管理${NC}"
        show_routing_status
        
        _item "1" "WARP 管理"
        _item "2" "链式代理"
        _item "3" "配置分流规则"
        _item "4" "直连出口设置"
        _item "5" "多IP入出站配置"
        _item "6" "测试分流效果"
        _item "7" "查看当前配置"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        
        case "$choice" in
            1) manage_warp ;;
            2) manage_chain_proxy ;;
            3) configure_routing_rules ;;
            4) configure_direct_outbound ;;
            5) manage_ip_routing ;;
            6)
                _header
                echo -e "  ${W}测试分流效果${NC}"
                test_routing
                _pause
                ;;
            7)
                _header
                echo -e "  ${W}当前分流配置${NC}"
                _line
                local rules=$(db_get_routing_rules)
                if [[ -n "$rules" && "$rules" != "[]" ]]; then
                    echo "$rules" | jq .
                else
                    echo -e "  ${D}未配置分流规则${NC}"
                fi
                _line
                read -rp "  按回车返回..." _
                ;;
            0) return ;;
        esac
    done
}


#═══════════════════════════════════════════════════════════════════════════════
# 链式代理转发
#═══════════════════════════════════════════════════════════════════════════════

# 节点类型支持判断
_node_supports_xray() {
    local type="$1"
    case "$type" in
        socks|http|shadowsocks|vmess|vless|trojan) return 0 ;;
    esac
    return 1
}

_node_supports_singbox() {
    local type="$1"
    case "$type" in
        socks|http|shadowsocks|vmess|vless|trojan|hysteria2|tuic|naive) return 0 ;;
    esac
    return 1
}

_pick_latency_core() {
    local type="$1"
    if _node_supports_xray "$type" && check_cmd xray; then
        echo "xray"
        return 0
    fi
    if _node_supports_singbox "$type" && check_cmd sing-box; then
        echo "singbox"
        return 0
    fi
    return 1
}

_wait_local_port() {
    local port="$1"
    local retries=20
    while [[ "$retries" -gt 0 ]]; do
        if check_cmd nc; then
            if nc -z 127.0.0.1 "$port" &>/dev/null; then
                return 0
            fi
        elif timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/${port}" &>/dev/null; then
            return 0
        fi
        sleep 0.1
        ((retries--))
    done
    return 1
}

_core_latency_test() {
    local core="$1" node_json="$2" ip_mode="${3:-prefer_ipv4}"
    local tmp_dir cfg_file proxy_port outbound pid latency=""
    
    tmp_dir=$(mktemp -d) || return 1
    cfg_file="${tmp_dir}/core.json"
    proxy_port=$(gen_port)
    
    if [[ "$core" == "xray" ]]; then
        outbound=$(gen_xray_chain_outbound "$node_json" "proxy" "$ip_mode")
        if [[ -z "$outbound" ]]; then
            rm -rf "$tmp_dir"
            return 1
        fi
        cat > "$cfg_file" <<EOF
{
  "log": {"loglevel": "none"},
  "inbounds": [
    {"listen": "127.0.0.1", "port": $proxy_port, "protocol": "socks", "settings": {"udp": true}}
  ],
  "outbounds": [
    $outbound
  ]
}
EOF
        xray run -c "$cfg_file" >/dev/null 2>&1 &
        pid=$!
    else
        outbound=$(gen_singbox_chain_outbound "$node_json" "proxy" "$ip_mode")
        if [[ -z "$outbound" ]]; then
            rm -rf "$tmp_dir"
            return 1
        fi
        cat > "$cfg_file" <<EOF
{
  "log": {"level": "error"},
  "inbounds": [
    {"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": $proxy_port}
  ],
  "outbounds": [
    $outbound
  ],
  "route": {"final": "proxy"}
}
EOF
        sing-box run -c "$cfg_file" >/dev/null 2>&1 &
        pid=$!
    fi
    
    if [[ -z "$pid" ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi
    
    if ! _wait_local_port "$proxy_port"; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -rf "$tmp_dir"
        return 1
    fi
    
    local -a samples=()
    local probe_total=""
    local probe_count="$LATENCY_PROBES"
    local max_attempts="$LATENCY_MAX_ATTEMPTS"
    [[ -z "$probe_count" || "$probe_count" -lt 1 ]] && probe_count=1
    if [[ -z "$max_attempts" || "$max_attempts" -lt "$probe_count" ]]; then
        max_attempts=$((probe_count * 2))
    fi
    
    local attempts=0
    while [[ "${#samples[@]}" -lt "$probe_count" && "$attempts" -lt "$max_attempts" ]]; do
        ((attempts++))
        if probe_total=$(curl -s -o /dev/null -w "%{time_total}" \
            --connect-timeout "$CURL_TIMEOUT_FAST" \
            --max-time "$CURL_TIMEOUT_NORMAL" \
            --socks5-hostname "127.0.0.1:${proxy_port}" \
            "$LATENCY_TEST_URL"); then
            local ms=$(awk -v t="$probe_total" 'BEGIN {if (t ~ /^[0-9.]+$/) printf "%.0f", t*1000}')
            [[ -n "$ms" ]] && samples+=("$ms")
        fi
    done
    
    if [[ "${#samples[@]}" -gt 0 ]]; then
        local mid=$(( (${#samples[@]} + 1) / 2 ))
        latency=$(printf '%s\n' "${samples[@]}" | sort -n | awk -v m="$mid" 'NR==m {print; exit}')
    fi
    
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$tmp_dir"
    
    [[ -n "$latency" ]] && { echo "$latency"; return 0; }
    return 1
}

# 批量节点测速（并发执行）
# 用法: _batch_latency_nodes "结果文件" ["并发数"]
# stdin: 每行节点 JSON
_batch_latency_nodes() {
    local results_file="$1"
    local parallel="${2:-$LATENCY_PARALLEL}"
    local tmp_dir
    
    [[ -z "$results_file" ]] && return 1
    [[ -z "$parallel" || "$parallel" -lt 1 ]] && parallel=1
    
    tmp_dir=$(mktemp -d) || return 1
    
    local idx=0
    local -a pids=()
    while IFS= read -r node_json; do
        [[ -z "$node_json" ]] && continue
        local out_file="${tmp_dir}/${idx}"
        (
            if ! echo "$node_json" | jq empty 2>/dev/null; then
                exit 0
            fi
            local name=$(echo "$node_json" | jq -r '.name // "未知"')
            local type=$(echo "$node_json" | jq -r '.type // "?"')
            local server=$(echo "$node_json" | jq -r '.server // ""')
            local port=$(echo "$node_json" | jq -r '.port // ""')
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ -z "$port" ]] && port="-"
            [[ -z "$server" ]] && server="-"
            local result=$(check_node_latency "$node_json")
            local latency="${result%%|*}"
            local latency_num=99999
            [[ "$latency" =~ ^[0-9]+$ ]] && latency_num="$latency"
            printf '%s|%s|%s|%s|%s|%s\n' "$latency_num" "$latency" "$name" "$type" "$server" "$port" > "$out_file"
        ) &
        pids+=("$!")
        if [[ "${#pids[@]}" -ge "$parallel" ]]; then
            wait "${pids[0]}" 2>/dev/null
            pids=("${pids[@]:1}")
        fi
        ((idx++))
    done
    
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done
    
    if ls "$tmp_dir" >/dev/null 2>&1; then
        cat "$tmp_dir"/* >> "$results_file"
    fi
    rm -rf "$tmp_dir"
}

# 检测节点延迟和解析 IP
# 用法: check_node_latency "节点名" 或 "节点JSON"
# 返回: "延迟ms|解析IP" 或 "超时|-"
check_node_latency() {
    local node_ref="$1"
    local node=""
    local resolved_ip="" latency="" is_ipv6=false
    
    [[ -z "$node_ref" ]] && { echo "超时|-"; return; }
    if [[ "$node_ref" =~ ^\{ ]]; then
        node="$node_ref"
    else
        node=$(db_get_chain_node "$node_ref")
    fi
    
    if [[ -z "$node" || "$node" == "null" ]] || ! echo "$node" | jq empty 2>/dev/null; then
        echo "超时|-"
        return
    fi
    
    local type=$(echo "$node" | jq -r '
        (.type // "") | 
        if . == "socks5" then "socks"
        elif . == "hy2" then "hysteria2"
        else . end
    ')
    local server=$(echo "$node" | jq -r '.server // ""')
    local port=$(echo "$node" | jq -r '.port // ""')
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    
    if [[ -z "$type" || -z "$server" || ! "$port" =~ ^[0-9]+$ ]]; then
        echo "超时|-"
        return
    fi
    
    # 移除 server 可能带有的方括号 (IPv6 格式)
    server="${server#[}"
    server="${server%]}"
    
    # 判断地址类型
    if [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        resolved_ip="$server"
    elif [[ "$server" =~ : ]]; then
        resolved_ip="$server"
        is_ipv6=true
    else
        resolved_ip=$(dig +short "$server" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
        if [[ -z "$resolved_ip" ]]; then
            resolved_ip=$(dig +short "$server" AAAA 2>/dev/null | grep -E ':' | head -1)
            [[ -n "$resolved_ip" ]] && is_ipv6=true
        fi
        [[ -z "$resolved_ip" ]] && resolved_ip=$(host "$server" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    [[ -z "$resolved_ip" ]] && resolved_ip="-"
    
    local core=""
    core=$(_pick_latency_core "$type") || { echo "超时|$resolved_ip"; return; }
    
    local ip_mode="prefer_ipv4"
    [[ "$is_ipv6" == "true" ]] && ip_mode="prefer_ipv6"
    
    if latency=$(_core_latency_test "$core" "$node" "$ip_mode"); then
        echo "${latency}|${resolved_ip}"
    else
        echo "超时|${resolved_ip}"
    fi
}

# 数据库：链式代理节点操作
db_get_chain_nodes() { jq -r '.chain_proxy.nodes // []' "$DB_FILE" 2>/dev/null; }
db_get_chain_node() { jq -r --arg name "$1" '.chain_proxy.nodes[] | select(.name == $name)' "$DB_FILE" 2>/dev/null; }
db_get_chain_active() { jq -r '.chain_proxy.active // empty' "$DB_FILE" 2>/dev/null; }
db_set_chain_active() {
    local tmp=$(mktemp)
    jq --arg name "$1" '.chain_proxy.active = $name' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}
db_add_chain_node() {
    local node_json="$1"
    # 验证 JSON 格式
    if ! echo "$node_json" | jq empty 2>/dev/null; then
        return 1
    fi
    local tmp=$(mktemp)
    jq --argjson node "$node_json" '.chain_proxy.nodes = ((.chain_proxy.nodes // []) + [$node])' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}
db_del_chain_node() {
    local tmp=$(mktemp)
    jq --arg name "$1" '.chain_proxy.nodes = [.chain_proxy.nodes[] | select(.name != $name)]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
    # 如果删除的是当前激活节点，清空激活状态
    [[ "$(db_get_chain_active)" == "$1" ]] && jq 'del(.chain_proxy.active)' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
}

# 检查链式代理节点是否存在 (返回 0=存在, 1=不存在)
db_chain_node_exists() {
    local name="$1"
    local result=$(jq -r --arg name "$name" '.chain_proxy.nodes[]? | select(.name == $name) | .name' "$DB_FILE" 2>/dev/null)
    [[ -n "$result" && "$result" != "null" ]]
}

# 解析 host:port 格式（支持 IPv6）
# 用法: _parse_hostport "hostport_string" 
# 输出: host|port
_parse_hostport() {
    local hostport="$1"
    local host="" port=""
    
    # 处理 IPv6 地址 [xxxx]:port
    if [[ "$hostport" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$hostport" =~ ^\[([^\]]+)\]$ ]]; then
        host="${BASH_REMATCH[1]}"
        port=""
    elif [[ "$hostport" == "["* ]]; then
        # 备用方案：字符串处理
        local tmp="${hostport#\[}"
        if [[ "$tmp" == *"]:"* ]]; then
            host="${tmp%%\]:*}"
            port="${hostport##*\]:}"
        else
            host="${tmp%\]}"
            port=""
        fi
    else
        # IPv4 或域名
        host="${hostport%%:*}"
        port="${hostport##*:}"
        # 如果没有端口，port 会等于 host
        [[ "$host" == "$port" ]] && port=""
    fi
    
    echo "${host}|${port}"
}

# 解析代理链接 (支持 ss/vmess/vless/trojan/socks/naive)
parse_proxy_link() {
    local link="$1"
    local result=""
    
    case "$link" in
        socks://*|socks5://*)
            # SOCKS5 格式: socks://[user:pass@]host:port#name 或 socks5://...
            local content="${link#socks://}"
            content="${content#socks5://}"
            local name="" host="" port="" username="" password="" hostport=""
            
            # 提取名称
            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            
            # 移除查询参数
            content="${content%%\?*}"
            
            # 检查是否有认证信息
            if [[ "$content" == *"@"* ]]; then
                local userinfo="${content%%@*}"
                hostport="${content#*@}"
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
                # URL 解码
                username=$(urldecode "$username")
                password=$(urldecode "$password")
            else
                hostport="$content"
            fi
            
            # 解析 host:port
            local parsed=$(_parse_hostport "$hostport")
            host="${parsed%%|*}"
            port="${parsed##*|}"
            
            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            
            [[ -z "$name" ]] && name="SOCKS5-${host}:${port}"
            if [[ -n "$host" && -n "$port" ]]; then
                if [[ -n "$username" ]]; then
                    result=$(jq -nc \
                        --arg name "$name" --arg host "$host" --argjson port "$port" \
                        --arg username "$username" --arg password "$password" \
                        '{name:$name,type:"socks",server:$host,port:$port,username:$username,password:$password}')
                else
                    result=$(jq -nc \
                        --arg name "$name" --arg host "$host" --argjson port "$port" \
                        '{name:$name,type:"socks",server:$host,port:$port}')
                fi
            fi
            ;;
        naive+https://*|naiveproxy://*)
            # NaiveProxy 格式: naive+https://user:pass@host:port#name
            local content="${link#naive+https://}"
            content="${content#naiveproxy://}"
            local name="" host="" port="" username="" password="" hostport=""
            
            # 提取名称
            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            
            # 移除查询参数
            content="${content%%\?*}"
            
            # 解析认证信息
            if [[ "$content" == *"@"* ]]; then
                local userinfo="${content%%@*}"
                hostport="${content#*@}"
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
                # URL 解码
                username=$(urldecode "$username")
                password=$(urldecode "$password")
            else
                return 1  # NaiveProxy 必须有认证信息
            fi
            
            # 解析 host:port
            local parsed=$(_parse_hostport "$hostport")
            host="${parsed%%|*}"
            port="${parsed##*|}"
            
            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            
            [[ -z "$name" ]] && name="Naive-${host}:${port}"
            [[ -n "$host" && -n "$port" && -n "$username" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg username "$username" --arg password "$password" \
                '{name:$name,type:"naive",server:$host,port:$port,username:$username,password:$password}')
            ;;
        ss://*)
            # SS 格式: 
            # 1. ss://base64(method:password)@host:port?params#name (SIP002 格式)
            # 2. ss://base64(method:password@host:port)#name (旧格式)
            local encoded="${link#ss://}"
            local name="" host="" port="" method="" password=""
            
            # 提取名称 (URL 解码)
            [[ "$encoded" == *"#"* ]] && { name=$(urldecode "$(echo "$encoded" | sed 's/.*#//')"); encoded="${encoded%%#*}"; }
            
            # 移除查询参数 (如 ?type=tcp&plugin=xxx)
            local params=""
            [[ "$encoded" == *"?"* ]] && { params="${encoded#*\?}"; encoded="${encoded%%\?*}"; }
            
            # SIP002 格式: base64(method:password)@host:port
            if [[ "$encoded" == *"@"* ]]; then
                local userinfo="${encoded%%@*}"
                local hostport="${encoded#*@}"
                
                # 解码 userinfo (method:password)
                local decoded=$(echo "$userinfo" | base64 -d 2>/dev/null)
                if [[ -n "$decoded" && "$decoded" == *":"* ]]; then
                    method="${decoded%%:*}"
                    password="${decoded#*:}"
                else
                    # 如果 base64 解码失败，可能是 URL 编码的明文格式
                    method=$(urldecode "${userinfo%%:*}")
                    password=$(urldecode "${userinfo#*:}")
                fi
                
                # 解析 host:port（支持 IPv6）
                local parsed=$(_parse_hostport "$hostport")
                host="${parsed%%|*}"
                port="${parsed##*|}"
            else
                # 旧格式: 整体 base64 编码 (method:password@host:port)
                local decoded=$(echo "$encoded" | base64 -d 2>/dev/null)
                if [[ -n "$decoded" && "$decoded" == *"@"* ]]; then
                    method=$(echo "$decoded" | cut -d: -f1)
                    password=$(echo "$decoded" | cut -d: -f2 | cut -d@ -f1)
                    local hostport_part="${decoded#*@}"
                    # 支持 IPv6: [::1]:port 或 host:port
                    if [[ "$hostport_part" == "["* ]]; then
                        host=$(echo "$hostport_part" | sed 's/^\[\([^]]*\)\].*/\1/')
                        port=$(echo "$hostport_part" | sed 's/.*\]://')
                    else
                        host=$(echo "$hostport_part" | cut -d: -f1)
                        port=$(echo "$hostport_part" | rev | cut -d: -f1 | rev)
                    fi
                fi
            fi
            
            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            
            [[ -z "$name" ]] && name="SS-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$method" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg type "shadowsocks" --arg host "$host" \
                --argjson port "$port" --arg method "$method" --arg password "$password" \
                '{name:$name,type:$type,server:$host,port:$port,method:$method,password:$password}')
            ;;
        vmess://*)
            # VMess 格式: vmess://base64(json)
            local decoded=$(echo "${link#vmess://}" | base64 -d 2>/dev/null)
            [[ -z "$decoded" ]] && return 1
            
            local name=$(echo "$decoded" | jq -r '.ps // .name // "VMess"')
            local host=$(echo "$decoded" | jq -r '.add // .server')
            local port=$(echo "$decoded" | jq -r '.port')
            local uuid=$(echo "$decoded" | jq -r '.id // .uuid')
            local aid=$(echo "$decoded" | jq -r '.aid // 0')
            local net=$(echo "$decoded" | jq -r '.net // "tcp"')
            local tls=$(echo "$decoded" | jq -r '.tls // ""')
            local ws_path=$(echo "$decoded" | jq -r '.path // "/"')
            local ws_host=$(echo "$decoded" | jq -r '.host // ""')
            
            # 确保 port 和 aid 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            aid=$(echo "$aid" | tr -d '"' | tr -d ' ')
            [[ ! "$aid" =~ ^[0-9]+$ ]] && aid=0
            
            [[ -n "$host" && -n "$port" && -n "$uuid" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg uuid "$uuid" --argjson aid "$aid" --arg net "$net" \
                --arg tls "$tls" --arg path "$ws_path" --arg wshost "$ws_host" \
                '{name:$name,type:"vmess",server:$host,port:$port,uuid:$uuid,alterId:$aid,network:$net,tls:$tls,wsPath:$path,wsHost:$wshost}')
            ;;
        vless://*)
            # VLESS 格式: vless://uuid@host:port?params#name
            local content="${link#vless://}"
            local name="" uuid="" host="" port=""
            
            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            uuid="${content%%@*}"
            local hostpart="${content#*@}"
            hostpart="${hostpart%%\?*}"
            
            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$hostpart")
            host="${parsed%%|*}"
            port="${parsed##*|}"
            
            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            
            # 解析参数
            local params=""
            [[ "$content" == *"?"* ]] && params="${content#*\?}"
            local security=$(_get_query_param "$params" "security")
            [[ -z "$security" ]] && security="none"
            local sni=$(_get_query_param "$params" "sni")
            local fp=$(_get_query_param "$params" "fp")
            [[ -z "$fp" ]] && fp="chrome"
            local net=$(_get_query_param "$params" "type")
            [[ -z "$net" ]] && net="tcp"
            local pbk=$(_get_query_param "$params" "pbk")
            local sid=$(_get_query_param "$params" "sid")
            local flow=$(_get_query_param "$params" "flow")
            local encryption=$(_get_query_param "$params" "encryption")
            [[ -z "$encryption" ]] && encryption="none"
            # 提取 ws 协议的 path 和 host 参数
            local ws_path=$(_get_query_param "$params" "path")
            [[ -z "$ws_path" ]] && ws_path="/"
            ws_path=$(urldecode "$ws_path")  # URL 解码 path
            local ws_host=$(_get_query_param "$params" "host")
            
            [[ -z "$name" ]] && name="VLESS-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$uuid" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg uuid "$uuid" --arg security "$security" --arg sni "$sni" \
                --arg fp "$fp" --arg net "$net" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg enc "$encryption" \
                --arg wsPath "$ws_path" --arg wsHost "$ws_host" \
                '{name:$name,type:"vless",server:$host,port:$port,uuid:$uuid,security:$security,sni:$sni,fingerprint:$fp,network:$net,publicKey:$pbk,shortId:$sid,flow:$flow,encryption:$enc,wsPath:$wsPath,wsHost:$wsHost}')
            ;;
        trojan://*)
            # Trojan 格式: trojan://password@host:port?params#name
            local content="${link#trojan://}"
            local name="" password="" host="" port=""
            
            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            password="${content%%@*}"
            local hostpart="${content#*@}"
            hostpart="${hostpart%%\?*}"
            
            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$hostpart")
            host="${parsed%%|*}"
            port="${parsed##*|}"
            
            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            
            local params=""
            [[ "$content" == *"?"* ]] && params="${content#*\?}"
            local sni=$(_get_query_param "$params" "sni")
            [[ -z "$sni" ]] && sni="$host"
            
            [[ -z "$name" ]] && name="Trojan-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg password "$password" --arg sni "$sni" \
                '{name:$name,type:"trojan",server:$host,port:$port,password:$password,sni:$sni}')
            ;;
        hy2://*|hysteria2://*)
            # Hysteria2 格式: hy2://password@host:port?params#name
            local content="${link#hy2://}"
            content="${content#hysteria2://}"
            local name="" password="" host="" port=""
            
            [[ "$content" == *"#"* ]] && { name=$(urldecode "$(echo "$content" | sed 's/.*#//')"); content="${content%%#*}"; }
            password="${content%%@*}"
            local hostpart="${content#*@}"
            hostpart="${hostpart%%\?*}"
            
            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$hostpart")
            host="${parsed%%|*}"
            port="${parsed##*|}"
            
            # 确保 port 是纯数字
            port=$(echo "$port" | tr -d '"' | tr -d ' ')
            [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
            
            local params=""
            [[ "$content" == *"?"* ]] && params="${content#*\?}"
            local sni=$(_get_query_param "$params" "sni")
            [[ -z "$sni" ]] && sni="$host"
            local insecure=$(_get_query_param "$params" "insecure")
            [[ -z "$insecure" ]] && insecure="0"
            
            [[ -z "$name" ]] && name="HY2-${host##*.}"
            [[ -n "$host" && -n "$port" && -n "$password" ]] && result=$(jq -nc \
                --arg name "$name" --arg host "$host" --argjson port "$port" \
                --arg password "$password" --arg sni "$sni" --arg insecure "$insecure" \
                '{name:$name,type:"hysteria2",server:$host,port:$port,password:$password,sni:$sni,insecure:$insecure}')
            ;;
    esac
    
    [[ -n "$result" ]] && echo "$result" || return 1
}

# 解析订阅链接
parse_subscription() {
    local url="$1"
    local content nodes=()
    
    _info "获取订阅内容..."
    content=$(curl -sL --connect-timeout 10 "$url" 2>/dev/null)
    [[ -z "$content" ]] && { _err "获取订阅失败"; return 1; }
    
    # 尝试 base64 解码
    local decoded=$(echo "$content" | base64 -d 2>/dev/null)
    [[ -n "$decoded" ]] && content="$decoded"
    
    # 按行解析
    local count=0
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [[ -z "$line" || "$line" == "#"* ]] && continue
        
        local node=$(parse_proxy_link "$line")
        if [[ -n "$node" ]]; then
            echo "$node"
            ((count++))
        fi
    done <<< "$content"
    
    [[ $count -eq 0 ]] && { _err "未解析到有效节点"; return 1; }
    _ok "解析到 $count 个节点"
}

# 生成 Xray 链式代理 outbound (支持指定节点名/节点JSON和自定义 tag)
# 用法: gen_xray_chain_outbound [节点名|节点JSON] [tag] [ip_mode]
# 第三个参数 ip_mode: ipv4_only, ipv6_only, prefer_ipv4 (默认), prefer_ipv6
# 第四个参数 dialer_proxy: 可选，指定通过哪个 outbound 连接 (用于双层链式代理)
gen_xray_chain_outbound() {
    local node_ref="${1:-$(db_get_chain_active)}"
    local tag="${2:-chain}"
    local ip_mode="${3:-prefer_ipv4}"  # 第三个参数，默认 prefer_ipv4
    local dialer_proxy="${4:-}"  # 第四个参数，dialerProxy 用于双层链式代理
    [[ -z "$node_ref" ]] && return
    
    local node=""
    if [[ "$node_ref" =~ ^\{ ]]; then
        node="$node_ref"
    else
        node=$(db_get_chain_node "$node_ref")
    fi
    [[ -z "$node" || "$node" == "null" ]] && return
    
    # 自动检测 via_warp 标志 (用于双层链式代理: WARP → IPv6 落地)
    local node_via_warp=$(echo "$node" | jq -r '.via_warp // false')
    if [[ "$node_via_warp" == "true" && -z "$dialer_proxy" ]]; then
        # 检查 WARP 是否已配置
        local warp_mode=$(db_get_warp_mode)
        if [[ -n "$warp_mode" && "$warp_mode" != "disabled" ]]; then
            dialer_proxy="warp"
        fi
    fi
    
    local type=$(echo "$node" | jq -r '.type')
    local server=$(echo "$node" | jq -r '.server')
    local port=$(echo "$node" | jq -r '.port')
    
    # 确保 port 是纯数字（去除可能的引号和空白）
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    [[ ! "$port" =~ ^[0-9]+$ ]] && { echo ""; return 1; }
    
    # 根据 ip_mode 设置 Xray 的 domainStrategy
    local domain_strategy=""
    case "$ip_mode" in
        ipv6_only|prefer_ipv6)
            domain_strategy="UseIPv6"
            ;;
        ipv4_only|prefer_ipv4|*)
            domain_strategy="UseIPv4"
            ;;
    esac
    
    # 辅助函数：为 outbound 添加 dialerProxy (双层链式代理)
    _add_dialer_proxy() {
        local out_json="$1"
        if [[ -n "$dialer_proxy" ]]; then
            # 添加 streamSettings.sockopt.dialerProxy
            echo "$out_json" | jq --arg dp "$dialer_proxy" '
                if .streamSettings then
                    .streamSettings.sockopt.dialerProxy = $dp
                else
                    .streamSettings = {sockopt: {dialerProxy: $dp}}
                end
            '
        else
            echo "$out_json"
        fi
    }
    
    case "$type" in
        socks)
            local username=$(echo "$node" | jq -r '.username // ""')
            local password=$(echo "$node" | jq -r '.password // ""')
            local base_out=""
            if [[ -n "$username" && -n "$password" ]]; then
                base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    --arg user "$username" --arg pass "$password" \
                    '{tag:$tag,protocol:"socks",settings:{servers:[{address:$server,port:$port,users:[{user:$user,pass:$pass}]}]}}')
            else
                base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    '{tag:$tag,protocol:"socks",settings:{servers:[{address:$server,port:$port}]}}')
            fi
            # 添加 IPv6 策略和 dialerProxy
            if [[ -n "$domain_strategy" ]]; then
                base_out=$(echo "$base_out" | jq --arg ds "$domain_strategy" '.settings.domainStrategy = $ds')
            fi
            _add_dialer_proxy "$base_out"
            ;;
        http)
            local username=$(echo "$node" | jq -r '.username // ""')
            local password=$(echo "$node" | jq -r '.password // ""')
            local base_out=""
            if [[ -n "$username" && -n "$password" ]]; then
                base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    --arg user "$username" --arg pass "$password" \
                    '{tag:$tag,protocol:"http",settings:{servers:[{address:$server,port:$port,users:[{user:$user,pass:$pass}]}]}}')
            else
                base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    '{tag:$tag,protocol:"http",settings:{servers:[{address:$server,port:$port}]}}')
            fi
            # 添加 IPv6 策略和 dialerProxy
            if [[ -n "$domain_strategy" ]]; then
                base_out=$(echo "$base_out" | jq --arg ds "$domain_strategy" '.settings.domainStrategy = $ds')
            fi
            _add_dialer_proxy "$base_out"
            ;;
        shadowsocks)
            local method=$(echo "$node" | jq -r '.method')
            local password=$(echo "$node" | jq -r '.password')
            local base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg method "$method" --arg password "$password" \
                '{tag:$tag,protocol:"shadowsocks",settings:{servers:[{address:$server,port:$port,method:$method,password:$password}]}}')
            # 添加 IPv6 策略和 dialerProxy
            if [[ -n "$domain_strategy" ]]; then
                base_out=$(echo "$base_out" | jq --arg ds "$domain_strategy" '.settings.domainStrategy = $ds')
            fi
            _add_dialer_proxy "$base_out"
            ;;
        vmess)
            local uuid=$(echo "$node" | jq -r '.uuid')
            local aid=$(echo "$node" | jq -r '.alterId // 0')
            # 确保 aid 是数字
            aid=$(echo "$aid" | tr -d '"' | tr -d ' ')
            [[ ! "$aid" =~ ^[0-9]+$ ]] && aid=0
            local net=$(echo "$node" | jq -r '.network // "tcp"')
            local tls=$(echo "$node" | jq -r '.tls')
            local path=$(echo "$node" | jq -r '.wsPath // "/"')
            local wshost=$(echo "$node" | jq -r '.wsHost // ""')
            
            local stream='{"network":"tcp"}'
            [[ "$net" == "ws" ]] && stream=$(jq -n --arg net "$net" --arg path "$path" --arg host "$wshost" \
                '{network:$net,wsSettings:{path:$path,headers:{Host:$host}}}')
            [[ "$tls" == "tls" ]] && stream=$(echo "$stream" | jq --arg sni "$server" '.security="tls"|.tlsSettings={serverName:$sni}')
            
            local base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --argjson aid "$aid" --argjson stream "$stream" \
                '{tag:$tag,protocol:"vmess",settings:{vnext:[{address:$server,port:$port,users:[{id:$uuid,alterId:$aid}]}]},streamSettings:$stream}')
            # 添加 IPv6 策略和 dialerProxy
            if [[ -n "$domain_strategy" ]]; then
                base_out=$(echo "$base_out" | jq --arg ds "$domain_strategy" '.settings.domainStrategy = $ds')
            fi
            _add_dialer_proxy "$base_out"
            ;;
        vless)
            local uuid=$(echo "$node" | jq -r '.uuid')
            local security=$(echo "$node" | jq -r '.security // "none"')
            local sni=$(echo "$node" | jq -r '.sni // ""')
            local fp=$(echo "$node" | jq -r '.fingerprint // "chrome"')
            local pbk=$(echo "$node" | jq -r '.publicKey // ""')
            local sid=$(echo "$node" | jq -r '.shortId // ""')
            local flow=$(echo "$node" | jq -r '.flow // ""')
            local encryption=$(echo "$node" | jq -r '.encryption // "none"')
            local net=$(echo "$node" | jq -r '.network // "tcp"')
            local ws_path=$(echo "$node" | jq -r '.wsPath // "/"')
            local ws_host=$(echo "$node" | jq -r '.wsHost // ""')
            # 如果 encryption 为空，默认使用 none
            [[ -z "$encryption" ]] && encryption="none"
            
            local stream='{"network":"tcp"}'
            if [[ "$net" == "ws" ]]; then
                # WebSocket 传输
                if [[ "$security" == "tls" ]]; then
                    stream=$(jq -n --arg path "$ws_path" --arg host "$ws_host" --arg sni "$sni" --arg fp "$fp" \
                        '{network:"ws",wsSettings:{path:$path,headers:{Host:$host}},security:"tls",tlsSettings:{serverName:$sni,fingerprint:$fp}}')
                else
                    stream=$(jq -n --arg path "$ws_path" --arg host "$ws_host" \
                        '{network:"ws",wsSettings:{path:$path,headers:{Host:$host}}}')
                fi
            elif [[ "$security" == "reality" ]]; then
                stream=$(jq -n --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" \
                    '{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:$fp,publicKey:$pbk,shortId:$sid}}')
            elif [[ "$security" == "tls" ]]; then
                stream=$(jq -n --arg sni "$sni" --arg fp "$fp" \
                    '{network:"tcp",security:"tls",tlsSettings:{serverName:$sni,fingerprint:$fp}}')
            fi
            
            # 生成 outbound，如果有 flow 则添加
            local base_out=""
            if [[ -n "$flow" && "$flow" != "null" && "$flow" != "" ]]; then
                base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg enc "$encryption" --arg flow "$flow" --argjson stream "$stream" \
                    '{tag:$tag,protocol:"vless",settings:{vnext:[{address:$server,port:$port,users:[{id:$uuid,encryption:$enc,flow:$flow}]}]},streamSettings:$stream}')
            else
                base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg enc "$encryption" --argjson stream "$stream" \
                    '{tag:$tag,protocol:"vless",settings:{vnext:[{address:$server,port:$port,users:[{id:$uuid,encryption:$enc}]}]},streamSettings:$stream}')
            fi
            # 添加 IPv6 策略和 dialerProxy
            if [[ -n "$domain_strategy" ]]; then
                base_out=$(echo "$base_out" | jq --arg ds "$domain_strategy" '.settings.domainStrategy = $ds')
            fi
            _add_dialer_proxy "$base_out"
            ;;
        trojan)
            local password=$(echo "$node" | jq -r '.password')
            local sni=$(echo "$node" | jq -r '.sni // ""')
            [[ -z "$sni" ]] && sni="$server"
            
            local base_out=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" --arg sni "$sni" \
                '{tag:$tag,protocol:"trojan",settings:{servers:[{address:$server,port:$port,password:$password}]},streamSettings:{network:"tcp",security:"tls",tlsSettings:{serverName:$sni}}}')
            # 添加 IPv6 策略和 dialerProxy
            if [[ -n "$domain_strategy" ]]; then
                base_out=$(echo "$base_out" | jq --arg ds "$domain_strategy" '.settings.domainStrategy = $ds')
            fi
            _add_dialer_proxy "$base_out"
            ;;
        naive)
            # NaiveProxy 使用 HTTP/2 协议，Xray 不原生支持，需要通过 HTTP 代理模拟
            # 实际上 Xray 无法直接作为 NaiveProxy 客户端，这里返回空
            # 如果需要支持 NaiveProxy 链式代理，建议使用 Sing-box
            _warn "Xray 不支持 NaiveProxy 链式代理，请使用 Sing-box 协议 (如 HY2/TUIC)" >&2
            return 1
            ;;
    esac
}

# 生成 Sing-box 链式代理 outbound (支持指定节点名/节点JSON和自定义 tag)
# 用法: gen_singbox_chain_outbound [节点名|节点JSON] [tag] [ip_mode]
# 第三个参数 ip_mode: ipv4_only, ipv6_only, prefer_ipv4 (默认), prefer_ipv6
gen_singbox_chain_outbound() {
    local node_ref="${1:-$(db_get_chain_active)}"
    local tag="${2:-chain}"
    local ip_mode="${3:-prefer_ipv4}"  # 第三个参数，默认 prefer_ipv4
    [[ -z "$node_ref" ]] && return
    
    local node=""
    if [[ "$node_ref" =~ ^\{ ]]; then
        node="$node_ref"
    else
        node=$(db_get_chain_node "$node_ref")
    fi
    [[ -z "$node" || "$node" == "null" ]] && return
    
    local type=$(echo "$node" | jq -r '.type')
    local server=$(echo "$node" | jq -r '.server')
    local port=$(echo "$node" | jq -r '.port')
    
    # 根据 ip_mode 设置 Sing-box 的 domain_strategy
    local domain_strategy="prefer_ipv4"
    case "$ip_mode" in
        ipv6_only|prefer_ipv6)
            domain_strategy="prefer_ipv6"
            ;;
        ipv4_only|prefer_ipv4|*)
            domain_strategy="prefer_ipv4"
            ;;
    esac
    
    case "$type" in
        socks)
            local username=$(echo "$node" | jq -r '.username // ""')
            local password=$(echo "$node" | jq -r '.password // ""')
            if [[ -n "$username" && -n "$password" ]]; then
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    --arg user "$username" --arg pass "$password" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"socks",server:$server,server_port:$port,username:$user,password:$pass,domain_strategy:$ds}'
            else
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"socks",server:$server,server_port:$port,domain_strategy:$ds}'
            fi
            ;;
        http)
            local username=$(echo "$node" | jq -r '.username // ""')
            local password=$(echo "$node" | jq -r '.password // ""')
            if [[ -n "$username" && -n "$password" ]]; then
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    --arg user "$username" --arg pass "$password" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"http",server:$server,server_port:$port,username:$user,password:$pass,domain_strategy:$ds}'
            else
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg ds "$domain_strategy" \
                    '{tag:$tag,type:"http",server:$server,server_port:$port,domain_strategy:$ds}'
            fi
            ;;
        shadowsocks)
            local method=$(echo "$node" | jq -r '.method')
            local password=$(echo "$node" | jq -r '.password')
            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg method "$method" --arg password "$password" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"shadowsocks",server:$server,server_port:$port,method:$method,password:$password,domain_strategy:$ds}'
            ;;
        vmess)
            local uuid=$(echo "$node" | jq -r '.uuid')
            local aid=$(echo "$node" | jq -r '.alterId // 0')
            local tls=$(echo "$node" | jq -r '.tls')
            
            local base=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --argjson aid "$aid" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"vmess",server:$server,server_port:$port,uuid:$uuid,alter_id:$aid,domain_strategy:$ds}')
            [[ "$tls" == "tls" ]] && base=$(echo "$base" | jq --arg sni "$server" '.tls={enabled:true,server_name:$sni}')
            echo "$base"
            ;;
        vless)
            local uuid=$(echo "$node" | jq -r '.uuid')
            local security=$(echo "$node" | jq -r '.security // "none"')
            local sni=$(echo "$node" | jq -r '.sni // ""')
            local fp=$(echo "$node" | jq -r '.fingerprint // "chrome"')
            local pbk=$(echo "$node" | jq -r '.publicKey // ""')
            local sid=$(echo "$node" | jq -r '.shortId // ""')
            local flow=$(echo "$node" | jq -r '.flow // ""')
            local net=$(echo "$node" | jq -r '.network // "tcp"')
            local ws_path=$(echo "$node" | jq -r '.wsPath // "/"')
            local ws_host=$(echo "$node" | jq -r '.wsHost // ""')
            
            local base=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"vless",server:$server,server_port:$port,uuid:$uuid,domain_strategy:$ds}')
            
            # 添加 flow 字段（如 xtls-rprx-vision）
            if [[ -n "$flow" && "$flow" != "null" && "$flow" != "" ]]; then
                base=$(echo "$base" | jq --arg flow "$flow" '.flow = $flow')
            fi
            
            # 处理 WebSocket 传输
            if [[ "$net" == "ws" ]]; then
                base=$(echo "$base" | jq --arg path "$ws_path" --arg host "$ws_host" \
                    '.transport={type:"ws",path:$path,headers:{Host:$host}}')
                if [[ "$security" == "tls" ]]; then
                    base=$(echo "$base" | jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}')
                fi
            elif [[ "$security" == "reality" ]]; then
                base=$(echo "$base" | jq --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" \
                    '.tls={enabled:true,server_name:$sni,reality:{enabled:true,public_key:$pbk,short_id:$sid},utls:{enabled:true,fingerprint:$fp}}')
            elif [[ "$security" == "tls" ]]; then
                base=$(echo "$base" | jq --arg sni "$sni" '.tls={enabled:true,server_name:$sni}')
            fi
            echo "$base"
            ;;
        trojan)
            local password=$(echo "$node" | jq -r '.password')
            local sni=$(echo "$node" | jq -r '.sni // ""')
            [[ -z "$sni" ]] && sni="$server"
            
            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" --arg sni "$sni" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"trojan",server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni},domain_strategy:$ds}'
            ;;
        hysteria2)
            local password=$(echo "$node" | jq -r '.password')
            local sni=$(echo "$node" | jq -r '.sni // ""')
            local insecure=$(echo "$node" | jq -r '.insecure // "0"')
            [[ -z "$sni" ]] && sni="$server"
            
            local base=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" --arg sni "$sni" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"hysteria2",server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni},domain_strategy:$ds}')
            [[ "$insecure" == "1" ]] && base=$(echo "$base" | jq '.tls.insecure=true')
            echo "$base"
            ;;
        naive)
            # NaiveProxy (HTTP/2 代理)
            local username=$(echo "$node" | jq -r '.username')
            local password=$(echo "$node" | jq -r '.password')
            
            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg user "$username" --arg pass "$password" --arg ds "$domain_strategy" \
                '{tag:$tag,type:"naive",server:$server,server_port:$port,username:$user,password:$pass,tls:{enabled:true,server_name:$server},domain_strategy:$ds}'
            ;;
    esac
}

# 添加节点交互 (带解析预览和自定义名称)
_add_chain_node_interactive() {
    _header
    echo -e "  ${W}添加代理节点${NC}"
    _line
    echo -e "  ${D}支持: ss/vmess/vless/trojan/hysteria2/socks5/naive${NC}"
    echo ""
    
    echo -e "  ${Y}粘贴代理链接:${NC}"
    read -rp "  链接: " link
    [[ -z "$link" ]] && return
    
    # 解析链接
    echo ""
    echo -e "  ${C}▸${NC} 解析链接中..."
    local node=$(parse_proxy_link "$link")
    
    if [[ -z "$node" ]]; then
        _err "链接解析失败，请检查格式"
        _pause
        return
    fi
    
    # 提取节点信息
    local orig_name=$(echo "$node" | jq -r '.name // "未知"')
    local type=$(echo "$node" | jq -r '.type // "未知"')
    local server=$(echo "$node" | jq -r '.server // "未知"')
    local port=$(echo "$node" | jq -r '.port // "未知"')
    
    # 显示解析预览
    echo ""
    _line
    echo -e "  ${G}✓${NC} 解析成功"
    _line
    echo -e "  节点名称: ${C}$orig_name${NC}"
    echo -e "  协议类型: ${C}$type${NC}"
    echo -e "  服务器:   ${C}$server${NC}"
    echo -e "  端口:     ${C}$port${NC}"
    _line
    
    # 询问是否自定义名称
    echo ""
    echo -e "  ${D}直接回车使用原名称，或输入新名称${NC}"
    read -rp "  自定义名称 [$orig_name]: " custom_name
    
    local final_name="${custom_name:-$orig_name}"
    
    # 检查是否已存在同名节点
    if db_chain_node_exists "$final_name"; then
        echo ""
        _warn "节点 '$final_name' 已存在"
        read -rp "  是否覆盖? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            _info "已取消"
            _pause
            return
        fi
        db_del_chain_node "$final_name"
    fi
    
    # 更新节点名称
    if [[ "$final_name" != "$orig_name" ]]; then
        node=$(echo "$node" | jq --arg name "$final_name" '.name = $name')
    fi
    
    # 保存节点
    if db_add_chain_node "$node"; then
        echo ""
        _ok "节点已添加: $final_name"
        
        # 询问是否立即配置分流
        echo ""
        read -rp "  是否立即将此节点用于分流? [y/N]: " use_now
        if [[ "$use_now" =~ ^[Yy]$ ]]; then
            _add_routing_rule
            return
        fi
    else
        _err "添加节点失败"
    fi
    
    _pause
}

# 导入订阅交互 (带预览确认)
_import_subscription_interactive() {
    _header
    echo -e "  ${W}导入订阅${NC}"
    _line
    
    echo -e "  ${Y}输入订阅链接:${NC}"
    read -rp "  URL: " sub_url
    [[ -z "$sub_url" ]] && return
    
    echo ""
    echo -e "  ${C}▸${NC} 获取订阅内容..."
    
    # 解析订阅
    local parsed_nodes=$(parse_subscription "$sub_url")
    
    if [[ -z "$parsed_nodes" ]]; then
        _err "订阅解析失败，请检查链接"
        _pause
        return
    fi
    
    # 统计节点数量和类型
    local total_count=0
    declare -A types
    
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        if ! echo "$node" | jq empty 2>/dev/null; then
            continue
        fi
        ((total_count++))
        local t=$(echo "$node" | jq -r '.type // "unknown"' 2>/dev/null)
        [[ -z "$t" || "$t" == "null" ]] && t="unknown"
        ((types[$t]++))
    done <<< "$parsed_nodes"
    
    if [[ $total_count -eq 0 ]]; then
        _err "订阅中没有有效节点"
        _pause
        return
    fi
    
    # 显示协议统计
    echo ""
    _line
    echo -e "  ${G}✓${NC} 解析成功，共 ${C}$total_count${NC} 个节点"
    _line
    echo -e "  ${W}协议统计:${NC}"
    for t in "${!types[@]}"; do
        echo -e "    • $t: ${types[$t]} 个"
    done
    
    # 预览阶段：检测延迟并显示 (复用测试延迟的逻辑)
    echo ""
    echo -e "  ${C}▸${NC} 检测节点延迟中... (并发 ${LATENCY_PARALLEL})"
    
    local tmp_results=$(mktemp)
    local tmp_nodes=$(mktemp)
    local i=0
    
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        if ! echo "$node" | jq empty 2>/dev/null; then
            continue
        fi
        ((i++))
        
        # 保存原始节点 JSON 用于后续导入与批量测速
        echo "$node" >> "$tmp_nodes"
        
        printf "\r  ${C}▸${NC} 检测中... (%d/%d)  " "$i" "$total_count" >&2
    done <<< "$parsed_nodes"
    
    echo "" >&2
    _batch_latency_nodes "$tmp_results" "$LATENCY_PARALLEL" < "$tmp_nodes"
    
    echo ""
    echo -e "  ${W}节点列表 (按延迟排序):${NC}"
    _line
    
    _display_sorted_latencies "$tmp_results"
    
    _line
    
    # 确认导入
    echo ""
    read -rp "  确认导入这 $total_count 个节点? [Y/n]: " confirm
    
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        _info "已取消导入"
        rm -f "$tmp_results" "$tmp_nodes"
        _pause
        return
    fi
    
    # 执行导入
    echo ""
    echo -e "  ${C}▸${NC} 正在导入..."
    
    local added=0
    local skipped=0
    local failed=0
    
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        if ! echo "$node" | jq empty 2>/dev/null; then
            ((failed++))
            continue
        fi
        
        local name=$(echo "$node" | jq -r '.name' 2>/dev/null)
        
        # 检查是否已存在
        if db_chain_node_exists "$name"; then
            ((skipped++))
            continue
        fi
        
        if db_add_chain_node "$node"; then
            ((added++))
        else
            ((failed++))
        fi
    done < "$tmp_nodes"
    
    rm -f "$tmp_results" "$tmp_nodes"
    
    echo ""
    _ok "导入完成"
    echo -e "  新增: ${G}$added${NC} 个"
    [[ $skipped -gt 0 ]] && echo -e "  跳过 (已存在): ${Y}$skipped${NC} 个"
    [[ $failed -gt 0 ]] && echo -e "  失败: ${R}$failed${NC} 个"
    
    _pause
}

# 链式代理管理菜单
# 一键导入 Alice SOCKS5 节点 (8个出口)
_import_alice_nodes() {
    _header
    echo -e "  ${W}导入 Alice SOCKS5 节点${NC}"
    _line
    echo -e "  ${D}Alice 提供 8 个 SOCKS5 出口 (端口 10001-10008)${NC}"
    echo -e "  ${D}统一命名为 Alice-TW-SOCKS5-01 ~ 08${NC}"
    echo ""

    # 先删除所有旧的 Alice-TW-SOCKS5 节点
    local old_nodes=$(db_get_chain_nodes 2>/dev/null)
    local deleted=0
    if [[ -n "$old_nodes" && "$old_nodes" != "[]" ]]; then
        while IFS= read -r node_name; do
            if [[ "$node_name" =~ ^Alice-TW-SOCKS5- ]]; then
                db_del_chain_node "$node_name"
                ((deleted++))
            fi
        done < <(echo "$old_nodes" | jq -r '.[].name')
    fi

    if [[ $deleted -gt 0 ]]; then
        echo -e "  ${C}▸${NC} 清理了 $deleted 个旧节点"
        # 同时清理相关的分流规则
        local tmp=$(mktemp)
        jq '.routing_rules = [.routing_rules[]? | select(.outbound | (startswith("chain:Alice-TW-SOCKS5-") | not))]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
    fi

    local server="2a14:67c0:116::1"
    local username="alice"
    local password="alicefofo123..OVO"
    local base_port=10001
    local imported=0

    echo -e "  ${C}▸${NC} 开始导入 8 个节点..."
    echo ""

    for i in {1..8}; do
        local port=$((base_port + i - 1))

        # 生成节点名称: Alice-TW-SOCKS5-01, Alice-TW-SOCKS5-02, ...
        local name=$(printf "Alice-TW-SOCKS5-%02d" "$i")

        # 构建节点 JSON
        local node=$(jq -n \
            --arg name "$name" \
            --arg server "$server" \
            --argjson port "$port" \
            --arg username "$username" \
            --arg password "$password" \
            '{name:$name,type:"socks",server:$server,port:$port,username:$username,password:$password}')

        if db_add_chain_node "$node"; then
            echo -e "  ${G}✓${NC} $name ${D}(端口 $port)${NC}"
            ((imported++))
        else
            echo -e "  ${R}✗${NC} $name ${D}(端口 $port, 添加失败)${NC}"
        fi
    done
    
    echo ""
    _line
    if [[ $imported -eq 8 ]]; then
        _ok "成功导入全部 8 个节点"
    elif [[ $imported -gt 0 ]]; then
        _warn "导入了 $imported 个节点 (预期 8 个)"
    else
        _warn "没有成功导入任何节点"
    fi

    # 如果成功导入节点,询问是否创建负载均衡组
    if [[ $imported -gt 0 ]]; then
        echo ""
        _line
        echo -e "  ${W}负载均衡配置${NC}"
        echo ""

        # 检查是否已存在 Alice 负载均衡组
        local group_name="Alice-TW-SOCKS5-LB"
        local existing_group=$(db_get_balancer_group "$group_name" 2>/dev/null)

        if [[ -n "$existing_group" && "$existing_group" != "null" ]]; then
            echo -e "  ${Y}⚠${NC}  已存在负载均衡组: ${C}$group_name${NC}"
            local strategy=$(echo "$existing_group" | jq -r '.strategy')
            local node_count=$(echo "$existing_group" | jq -r '.nodes | length')
            echo -e "  策略: ${D}$strategy${NC}, 节点数: ${D}$node_count${NC}"
            echo ""
            echo -e "  ${W}选择操作:${NC}"
            echo -e "    ${C}1.${NC} 保持现有配置 ${D}(不修改)${NC}"
            echo -e "    ${C}2.${NC} 删除负载均衡组 ${D}(清除配置)${NC}"
            echo -e "    ${C}3.${NC} 重新创建负载均衡组 ${D}(覆盖现有)${NC}"
            echo ""

            local choice
            read -p "  请选择 [1-3, 默认 1]: " choice
            choice=${choice:-1}

            case "$choice" in
                2)
                    db_delete_balancer_group "$group_name"
                    _ok "已删除负载均衡组: $group_name"
                    echo ""
                    echo -e "  ${Y}提示:${NC} 请到 ${C}分流规则${NC} 中手动配置节点"
                    ;;
                3)
                    db_delete_balancer_group "$group_name"
                    _create_alice_balancer_inline "$imported"
                    ;;
                *)
                    _info "保持现有配置"
                    ;;
            esac
        else
            echo -e "  是否创建负载均衡组? ${D}(方便自动分配流量)${NC}"
            echo ""
            echo -e "    ${C}Y${NC} - 创建负载均衡组 ${D}(推荐)${NC}"
            echo -e "    ${C}N${NC} - 稍后手动配置"
            echo ""

            local create_lb
            read -p "  请选择 [Y/n]: " create_lb

            if [[ ! "$create_lb" =~ ^[Nn]$ ]]; then
                _create_alice_balancer_inline "$imported"
            else
                _info "跳过负载均衡配置"
                echo ""
                echo -e "  ${Y}提示:${NC} 请到 ${C}链式代理管理 → 创建负载均衡组${NC} 中配置"
            fi
        fi
    fi

    _pause
}

# 内联创建 Alice 负载均衡组 (供导入流程调用)
_create_alice_balancer_inline() {
    local node_count=${1:-8}

    echo ""
    echo -e "  ${W}配置负载均衡策略:${NC}"
    echo -e "    ${C}1.${NC} leastPing   ${D}(最低延迟 - 推荐)${NC}"
    echo -e "    ${C}2.${NC} random      ${D}(随机选择)${NC}"
    echo -e "    ${C}3.${NC} roundRobin  ${D}(轮询 - 流量均衡)${NC}"
    echo ""
    echo -e "  ${Y}说明:${NC} leastPing会自动选择延迟最低的节点"
    echo ""

    local strategy_choice
    read -p "  请选择策略 [1-3, 默认 1]: " strategy_choice
    strategy_choice=${strategy_choice:-1}

    local strategy
    case "$strategy_choice" in
        2) strategy="random" ;;
        3) strategy="roundRobin" ;;
        *) strategy="leastPing" ;;
    esac

    # 获取所有 Alice 节点
    local alice_nodes=()
    local all_nodes=$(db_get_chain_nodes)
    while IFS= read -r node_name; do
        [[ "$node_name" =~ ^Alice-TW-SOCKS5- ]] && alice_nodes+=("$node_name")
    done < <(echo "$all_nodes" | jq -r '.[].name')

    # 创建负载均衡组
    local group_name="Alice-TW-SOCKS5-LB"
    db_add_balancer_group "$group_name" "$strategy" "${alice_nodes[@]}"

    echo ""
    _ok "负载均衡组创建成功"
    echo ""
    echo -e "  组名: ${C}$group_name${NC}"
    echo -e "  策略: ${C}$strategy${NC}"
    echo -e "  节点数: ${G}${#alice_nodes[@]}${NC}"
    echo ""
    echo -e "  ${Y}下一步:${NC} 到 ${C}分流规则${NC} 中添加规则"
    echo -e "  出口选择: ${C}负载均衡:${group_name}${NC}"
}

# 一键导入 Akile SOCKS5 节点 (12个出口)
_import_akile_nodes() {
    _header
    echo -e "  ${W}导入 Akile SOCKS5 节点${NC}"
    _line
    echo -e "  ${D}Akile 提供 12 个 SOCKS5 出口 (多地区)${NC}"
    echo -e "  ${D}包括: HK/JP/KR/TW/SG/US/UK/DE 等地区${NC}"
    echo ""

    # 先删除所有旧的 Akile 节点
    local old_nodes=$(db_get_chain_nodes 2>/dev/null)
    local deleted=0
    if [[ -n "$old_nodes" && "$old_nodes" != "[]" ]]; then
        while IFS= read -r node_name; do
            if [[ "$node_name" =~ ^Akile- ]]; then
                db_del_chain_node "$node_name"
                ((deleted++))
            fi
        done < <(echo "$old_nodes" | jq -r '.[].name')
    fi

    if [[ $deleted -gt 0 ]]; then
        echo -e "  ${C}▸${NC} 清理了 $deleted 个旧节点"
        # 同时清理相关的分流规则
        local tmp=$(mktemp)
        jq '.routing_rules = [.routing_rules[]? | select(.outbound | (startswith("chain:Akile-") | not))]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
    fi

    local username="akilecloud"
    local password="akilecloud"
    local imported=0

    # 定义所有 Akile 节点: 名称|服务器|端口
    local nodes_data=(
        "Akile-HK-RANDOMIPV6|45.8.186.151|58888"
        "Akile-JP-RANDOMIPV6|203.10.99.23|58888"
        "Akile-KR-RANDOMIPV6|141.11.131.253|58888"
        "Akile-TW-RANDOMIPV6|45.207.158.22|58888"
        "Akile-SG-RANDOMIPV6|104.192.92.63|58888"
        "Akile-US-RANDOMIPV6|154.83.90.2|58888"
        "Akile-UK-RANDOMIPV6|212.135.39.2|58888"
        "Akile-DE-RANDOMIPV6|45.196.222.2|58888"
        "Akile-JP-SOFTBANK|141.11.131.205|58888"
        "Akile-JP-KDDI|141.11.131.205|59999"
        "Akile-TW-HINET|45.207.158.220|58888"
        "Akile-HK-HKBN|45.207.156.2|58888"
    )

    echo -e "  ${C}▸${NC} 开始导入 ${#nodes_data[@]} 个节点..."
    echo ""

    for node_info in "${nodes_data[@]}"; do
        IFS='|' read -r name server port <<< "$node_info"

        # 构建节点 JSON
        local node=$(jq -n \
            --arg name "$name" \
            --arg server "$server" \
            --argjson port "$port" \
            --arg username "$username" \
            --arg password "$password" \
            '{name:$name,type:"socks",server:$server,port:$port,username:$username,password:$password}')

        if db_add_chain_node "$node"; then
            echo -e "  ${G}✓${NC} $name ${D}($server:$port)${NC}"
            ((imported++))
        else
            echo -e "  ${R}✗${NC} $name ${D}($server:$port, 添加失败)${NC}"
        fi
    done
    
    echo ""
    _line
    if [[ $imported -eq ${#nodes_data[@]} ]]; then
        _ok "成功导入全部 ${#nodes_data[@]} 个节点"
    elif [[ $imported -gt 0 ]]; then
        _warn "导入了 $imported 个节点 (预期 ${#nodes_data[@]} 个)"
    else
        _warn "没有成功导入任何节点"
    fi

    # 如果成功导入节点,询问是否创建负载均衡组
    if [[ $imported -gt 0 ]]; then
        echo ""
        _line
        echo -e "  ${W}负载均衡配置${NC}"
        echo ""

        # 检查是否已存在 Akile 负载均衡组
        local group_name="Akile-SOCKS5-LB"
        local existing_group=$(db_get_balancer_group "$group_name" 2>/dev/null)

        if [[ -n "$existing_group" && "$existing_group" != "null" ]]; then
            echo -e "  ${Y}⚠${NC}  已存在负载均衡组: ${C}$group_name${NC}"
            local strategy=$(echo "$existing_group" | jq -r '.strategy')
            local node_count=$(echo "$existing_group" | jq -r '.nodes | length')
            echo -e "  策略: ${D}$strategy${NC}, 节点数: ${D}$node_count${NC}"
            echo ""
            echo -e "  ${W}选择操作:${NC}"
            echo -e "    ${C}1.${NC} 保持现有配置 ${D}(不修改)${NC}"
            echo -e "    ${C}2.${NC} 删除负载均衡组 ${D}(清除配置)${NC}"
            echo -e "    ${C}3.${NC} 重新创建负载均衡组 ${D}(覆盖现有)${NC}"
            echo ""

            local choice
            read -p "  请选择 [1-3, 默认 1]: " choice
            choice=${choice:-1}

            case "$choice" in
                2)
                    db_delete_balancer_group "$group_name"
                    _ok "已删除负载均衡组: $group_name"
                    echo ""
                    echo -e "  ${Y}提示:${NC} 请到 ${C}分流规则${NC} 中手动配置节点"
                    ;;
                3)
                    db_delete_balancer_group "$group_name"
                    _create_akile_balancer_inline "$imported"
                    ;;
                *)
                    _info "保持现有配置"
                    ;;
            esac
        else
            echo -e "  是否创建负载均衡组? ${D}(方便自动分配流量)${NC}"
            echo ""
            echo -e "    ${C}Y${NC} - 创建负载均衡组 ${D}(推荐)${NC}"
            echo -e "    ${C}N${NC} - 稍后手动配置"
            echo ""

            local create_lb
            read -p "  请选择 [Y/n]: " create_lb

            if [[ ! "$create_lb" =~ ^[Nn]$ ]]; then
                _create_akile_balancer_inline "$imported"
            else
                _info "跳过负载均衡配置"
                echo ""
                echo -e "  ${Y}提示:${NC} 请到 ${C}链式代理管理 → 创建负载均衡组${NC} 中配置"
            fi
        fi
    fi

    _pause
}

# 内联创建 Akile 负载均衡组 (供导入流程调用)
_create_akile_balancer_inline() {
    local node_count=${1:-12}

    echo ""
    echo -e "  ${W}配置负载均衡策略:${NC}"
    echo -e "    ${C}1.${NC} leastPing   ${D}(最低延迟 - 推荐)${NC}"
    echo -e "    ${C}2.${NC} random      ${D}(随机选择)${NC}"
    echo -e "    ${C}3.${NC} roundRobin  ${D}(轮询 - 流量均衡)${NC}"
    echo ""
    echo -e "  ${Y}说明:${NC} leastPing会自动选择延迟最低的节点"
    echo ""

    local strategy_choice
    read -p "  请选择策略 [1-3, 默认 1]: " strategy_choice
    strategy_choice=${strategy_choice:-1}

    local strategy
    case "$strategy_choice" in
        2) strategy="random" ;;
        3) strategy="roundRobin" ;;
        *) strategy="leastPing" ;;
    esac

    # 获取所有 Akile 节点
    local akile_nodes=()
    local all_nodes=$(db_get_chain_nodes)
    while IFS= read -r node_name; do
        [[ "$node_name" =~ ^Akile- ]] && akile_nodes+=("$node_name")
    done < <(echo "$all_nodes" | jq -r '.[].name')

    # 创建负载均衡组
    local group_name="Akile-SOCKS5-LB"
    db_add_balancer_group "$group_name" "$strategy" "${akile_nodes[@]}"

    echo ""
    _ok "负载均衡组创建成功"
    echo ""
    echo -e "  组名: ${C}$group_name${NC}"
    echo -e "  策略: ${C}$strategy${NC}"
    echo -e "  节点数: ${G}${#akile_nodes[@]}${NC}"
    echo ""
    echo -e "  ${Y}下一步:${NC} 到 ${C}分流规则${NC} 中添加规则"
    echo -e "  出口选择: ${C}负载均衡:${group_name}${NC}"
}

# 创建负载均衡组

create_load_balance_group() {
    _header
    echo -e "  ${W}创建负载均衡组${NC}"
    _line
    
    # 获取所有节点
    local nodes=$(db_get_chain_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$node_count" -eq 0 ]]; then
        echo -e "  ${R}✗${NC} 没有可用节点"
        echo -e "  ${Y}提示:${NC} 请先导入订阅或添加节点"
        _pause
        return
    fi
    
    echo -e "  ${G}找到 $node_count 个节点${NC}"
    echo ""
    echo -e "  ${Y}负载均衡策略:${NC}"
    echo -e "  ${G}1.${NC} leastPing   ${D}(最低延迟 - 推荐)${NC}"
    echo -e "  ${G}2.${NC} random      ${D}(随机选择)${NC}"
    echo -e "  ${G}3.${NC} roundRobin  ${D}(轮询 - 流量均衡)${NC}"
    echo -e "  ${G}0.${NC} 返回"
    _line
    
    read -rp "  请选择策略: " strategy_choice
    
    local strategy=""
    local strategy_name=""
    case "$strategy_choice" in
        1)
            strategy="leastPing"
            strategy_name="最低延迟"
            ;;
        2)
            strategy="random"
            strategy_name="随机选择"
            ;;
        3)
            strategy="roundRobin"
            strategy_name="轮询"
            ;;
        0)
            return
            ;;
        *)
            _err "无效选择"
            _pause
            return
            ;;
    esac
    
    echo ""
    echo -e "  ${Y}选择节点:${NC}"
    echo -e "  ${G}1.${NC} 使用所有节点 (推荐)"
    echo -e "  ${G}2.${NC} 手动选择节点"
    echo -e "  ${G}0.${NC} 返回"
    _line
    
    read -rp "  请选择: " node_choice
    
    local selected_nodes="[]"
    case "$node_choice" in
        1)
            # 使用所有节点
            selected_nodes=$(echo "$nodes" | jq '[.[].name]')
            ;;
        2)
            # 手动选择节点
            echo ""
            echo -e "  ${Y}可用节点列表:${NC}"
            local i=1
            echo "$nodes" | jq -r '.[] | .name' | while read -r name; do
                echo -e "  ${D}[$i]${NC} $name"
                ((i++))
            done
            
            echo ""
            echo -e "  ${Y}输入节点编号 (多个用空格分隔，如: 1 3 5):${NC}"
            read -rp "  > " indices
            
            if [[ -z "$indices" ]]; then
                _err "未选择节点"
                _pause
                return
            fi
            
            # 解析选择的节点
            selected_nodes="[]"
            for idx in $indices; do
                if [[ "$idx" =~ ^[0-9]+$ ]]; then
                    local node_name=$(echo "$nodes" | jq -r ".[$((idx-1))].name // empty")
                    if [[ -n "$node_name" ]]; then
                        selected_nodes=$(echo "$selected_nodes" | jq --arg n "$node_name" '. + [$n]')
                    fi
                fi
            done
            ;;
        0)
            return
            ;;
        *)
            _err "无效选择"
            _pause
            return
            ;;
    esac
    
    local selected_count=$(echo "$selected_nodes" | jq 'length')
    if [[ "$selected_count" -eq 0 ]]; then
        _err "未选择有效节点"
        _pause
        return
    fi
    
    echo ""
    echo -e "  ${G}✓${NC} 已选择 ${G}$selected_count${NC} 个节点"
    echo ""
    
    # 输入组名
    read -rp "  输入负载均衡组名称 (默认: ${strategy_name}组): " group_name
    [[ -z "$group_name" ]] && group_name="${strategy_name}组"
    
    # 创建负载均衡组配置
    local lb_config=$(jq -n \
        --arg name "$group_name" \
        --arg strategy "$strategy" \
        --argjson nodes "$selected_nodes" \
        '{
            name: $name,
            strategy: $strategy,
            nodes: $nodes,
            url: "http://www.gstatic.com/generate_204",
            interval: 300,
            tolerance: 50
        }')
    
    # 保存到数据库
    local tmp_file="${DB_FILE}.tmp"
    if jq --argjson cfg "$lb_config" \
        '.balancer_groups = ((.balancer_groups // []) + [$cfg])' \
        "$DB_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$DB_FILE"
        
        echo ""
        echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${G}✓ 负载均衡组创建成功!${NC}"
        echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  组名: ${C}$group_name${NC}"
        echo -e "  策略: ${C}$strategy_name${NC}"
        echo -e "  节点数: ${C}$selected_count${NC}"
        echo -e "  ${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${Y}下一步:${NC}"
        echo -e "  1. 在 ${G}配置分流规则${NC} 中使用该负载均衡组"
        echo -e "  2. 负载均衡组会自动管理节点切换"
    else
        rm -f "$tmp_file"
        _err "创建失败"
    fi
    
    _pause
}

manage_chain_proxy() {
    while true; do
        _header
        echo -e "  ${W}链式代理管理${NC}"
        _line
        
        # 显示当前状态
        local nodes=$(db_get_chain_nodes)
        local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
        
        # 获取分流规则使用的节点
        local routing_rules=$(db_get_routing_rules)
        local routing_count=0
        local routing_nodes=""
        if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
            while IFS= read -r line; do
                local r_type=$(echo "$line" | cut -d'|' -f1)
                local r_outbound=$(echo "$line" | cut -d'|' -f2)
                if [[ "$r_outbound" == chain:* ]]; then
                    local node_name="${r_outbound#chain:}"
                    routing_nodes+="    ${C}•${NC} ${node_name} ${D}← ${r_type}${NC}\n"
                    ((routing_count++))
                fi
            done < <(echo "$routing_rules" | jq -r '.[] | "\(.type)|\(.outbound)"')
        fi
        
        if [[ $routing_count -gt 0 ]]; then
            echo -e "  状态: ${G}● 分流已配置${NC} (${routing_count} 条规则)"
            echo -e "  使用节点:"
            echo -e "$routing_nodes"
        else
            echo -e "  状态: ${D}○ 未配置分流${NC}"
        fi
        echo -e "  节点总数: ${C}$node_count${NC}"
        _line
        
        _item "1" "添加节点 (分享链接)"
        _item "2" "导入订阅"
        _item "3" "一键导入 Alice SOCKS5 (8节点)"
        _item "4" "一键导入 Akile SOCKS5 (12节点)"
        echo -e "  ${D}───────────────────────────────────────────${NC}"
        _item "5" "多IP入出站配置"
        _item "6" "WARP 双层链式"
        _item "7" "创建负载均衡组"
        _item "8" "查看负载均衡组"
        echo -e "  ${D}───────────────────────────────────────────${NC}"
        _item "9" "测试所有节点延迟"
        _item "10" "删除节点"
        _item "11" "删除负载均衡组"
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice

        case "$choice" in
            1)
                _add_chain_node_interactive
                ;;
            2)
                _import_subscription_interactive
                ;;
            3)
                _import_alice_nodes
                ;;
            4)
                _import_akile_nodes
                ;;
            5)
                manage_ip_routing
                ;;
            6)
                setup_warp_ipv6_chain
                ;;
            7)
                create_load_balance_group
                ;;
            8)
                # 查看负载均衡组
                _header
                echo -e "  ${W}查看负载均衡组${NC}"
                _line
                
                local balancer_groups=$(db_get_balancer_groups)
                local group_count=$(echo "$balancer_groups" | jq 'length' 2>/dev/null || echo 0)
                
                if [[ "$group_count" -eq 0 ]]; then
                    echo -e "  ${D}暂无负载均衡组${NC}"
                    _pause
                    continue
                fi
                
                echo "$balancer_groups" | jq -c '.[]' | while read -r group; do
                    local name=$(echo "$group" | jq -r '.name')
                    local strategy=$(echo "$group" | jq -r '.strategy')
                    local nodes=$(echo "$group" | jq -r '.nodes')
                    local node_count=$(echo "$nodes" | jq 'length')
                    
                    local strategy_name=""
                    case "$strategy" in
                        leastPing) strategy_name="最低延迟" ;;
                        random) strategy_name="随机选择" ;;
                        roundRobin) strategy_name="轮询" ;;
                        *) strategy_name="$strategy" ;;
                    esac
                    
                    echo -e "  ${G}━━━ $name ━━━${NC}"
                    echo -e "  策略: ${C}$strategy_name${NC}  节点数: ${C}$node_count${NC}"
                    echo -e "  包含节点:"
                    echo "$nodes" | jq -r '.[]' | while read -r node_name; do
                        echo -e "    ${D}•${NC} $node_name"
                    done
                    echo ""
                done
                _line
                _pause
                ;;
            9)
                # 测试所有节点延迟
                _header
                echo -e "  ${W}测试节点延迟 ${D}(仅供参考)${NC}"
                _line
                
                local nodes=$(db_get_chain_nodes)
                local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
                
                if [[ "$count" -eq 0 ]]; then
                    echo -e "  ${D}暂无节点${NC}"
                    _pause
                    continue
                fi
                
                # 获取分流规则使用的节点
                local routing_rules=$(db_get_routing_rules)
                declare -A routing_marks
                if [[ -n "$routing_rules" && "$routing_rules" != "[]" ]]; then
                    while IFS= read -r line; do
                        local r_type=$(echo "$line" | cut -d'|' -f1)
                        local r_outbound=$(echo "$line" | cut -d'|' -f2)
                        if [[ "$r_outbound" == chain:* ]]; then
                            local node_name="${r_outbound#chain:}"
                            routing_marks["$node_name"]="$r_type"
                        fi
                    done < <(echo "$routing_rules" | jq -r '.[] | "\(.type)|\(.outbound)"')
                fi
                
                echo -e "  ${C}▸${NC} 检测 $count 个节点延迟中... (并发 ${LATENCY_PARALLEL})"
                
                local tmp_results=$(mktemp)
                local tmp_nodes=$(mktemp)
                echo "$nodes" | jq -c '.[]' > "$tmp_nodes"
                _batch_latency_nodes "$tmp_results" "$LATENCY_PARALLEL" < "$tmp_nodes"
                
                _ok "延迟检测完成 ($count 个节点)"
                echo ""
                echo -e "  ${W}延迟排序 (从低到高):${NC}"
                _line
                
                _display_sorted_latencies "$tmp_results" "routing_marks"
                
                rm -f "$tmp_results" "$tmp_nodes"
                _line
                _pause
                ;;
            10)
                _header
                echo -e "  ${W}删除节点${NC}"
                _line
                
                local nodes=$(db_get_chain_nodes)
                local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
                
                if [[ "$count" -eq 0 ]]; then
                    echo -e "  ${D}暂无节点${NC}"
                    _pause
                    continue
                fi
                
                local i=1
                echo "$nodes" | jq -r '.[] | .name' | while read -r name; do
                    echo -e "  ${C}$i)${NC} $name"
                    ((i++))
                done
                
                _line
                echo -e "  ${D}输入 all 删除全部, 0 返回${NC}"
                read -rp "  选择编号: " idx
                
                if [[ "$idx" == "0" ]]; then
                    continue
                elif [[ "$idx" == "all" ]]; then
                    local tmp=$(mktemp)
                    jq 'del(.chain_proxy)' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
                    # 清理所有引用链式代理节点的分流规则
                    tmp=$(mktemp)
                    jq '.routing_rules = [.routing_rules[]? | select(.outbound | startswith("chain:") | not)]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
                    _ok "已删除所有节点"
                    _ok "已清理相关分流规则"
                    _regenerate_proxy_configs
                elif [[ -n "$idx" && "$idx" =~ ^[0-9]+$ ]]; then
                    local name=$(echo "$nodes" | jq -r ".[$((idx-1))].name // empty")
                    if [[ -n "$name" ]]; then
                        db_del_chain_node "$name"
                        # 清理引用该节点的分流规则
                        local tmp=$(mktemp)
                        jq --arg out "chain:$name" '.routing_rules = [.routing_rules[]? | select(.outbound != $out)]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
                        _ok "已删除: $name"
                        _regenerate_proxy_configs
                    fi
                fi
                _pause
                ;;
            11)
                # 删除负载均衡组
                _header
                echo -e "  ${W}删除负载均衡组${NC}"
                _line
                
                local balancer_groups=$(db_get_balancer_groups)
                local group_count=$(echo "$balancer_groups" | jq 'length' 2>/dev/null || echo 0)
                
                if [[ "$group_count" -eq 0 ]]; then
                    echo -e "  ${D}暂无负载均衡组${NC}"
                    _pause
                    continue
                fi
                
                local idx=1
                echo "$balancer_groups" | jq -c '.[]' | while read -r group; do
                    local name=$(echo "$group" | jq -r '.name')
                    local strategy=$(echo "$group" | jq -r '.strategy')
                    local nodes=$(echo "$group" | jq -r '.nodes | length')
                    
                    local strategy_name=""
                    case "$strategy" in
                        leastPing) strategy_name="最低延迟" ;;
                        random) strategy_name="随机选择" ;;
                        roundRobin) strategy_name="轮询" ;;
                        *) strategy_name="$strategy" ;;
                    esac
                    
                    echo -e "  ${C}$idx)${NC} ${G}$name${NC} ${D}($strategy_name, $nodes 节点)${NC}"
                    ((idx++))
                done
                
                _line
                echo -e "  ${D}输入 all 删除全部, 0 返回${NC}"
                read -rp "  选择编号: " del_idx
                
                if [[ "$del_idx" == "0" ]]; then
                    continue
                elif [[ "$del_idx" == "all" ]]; then
                    local tmp=$(mktemp)
                    jq 'del(.balancer_groups)' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
                    _ok "已删除所有负载均衡组"
                    _regenerate_proxy_configs
                elif [[ -n "$del_idx" && "$del_idx" =~ ^[0-9]+$ ]]; then
                    local group_name=$(echo "$balancer_groups" | jq -r ".[$((del_idx-1))].name // empty")
                    if [[ -n "$group_name" ]]; then
                        local tmp=$(mktemp)
                        jq --arg name "$group_name" '.balancer_groups = [.balancer_groups[]? | select(.name != $name)]' "$DB_FILE" > "$tmp" && mv "$tmp" "$DB_FILE"
                        _ok "已删除: $group_name"
                        _regenerate_proxy_configs
                    else
                        _err "无效的编号"
                    fi
                fi
                _pause
                ;;
            0) return ;;
        esac
    done
}


# 多IP入出站配置管理菜单
manage_ip_routing() {
    while true; do
        _header
        echo -e "  ${W}多IP入出站配置${NC}"
        _line
        
        # 实时检测系统公网IP
        local system_ipv4=$(get_all_public_ipv4)
        local system_ipv6=$(get_all_public_ipv6)
        local all_ips=()
        
        # 收集所有IP
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && all_ips+=("$ip")
        done <<< "$system_ipv4"
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && all_ips+=("$ip")
        done <<< "$system_ipv6"
        
        local ip_count=${#all_ips[@]}
        
        # 检查功能是否启用
        local enabled_status="${R}○ 未启用${NC}"
        if db_ip_routing_enabled; then
            enabled_status="${G}● 已启用${NC}"
        fi
        
        # 获取已配置的规则
        local rules=$(db_get_ip_routing_rules)
        local rule_count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)
        
        echo -e "  状态: $enabled_status  规则数: ${C}$rule_count${NC}"
        echo -e "  检测到 ${C}$ip_count${NC} 个公网IP"
        _line
        
        # 显示IP列表及其配置状态
        if [[ $ip_count -gt 0 ]]; then
            echo -e "  ${W}系统公网IP:${NC}"
            local idx=1
            for ip in "${all_ips[@]}"; do
                local outbound_ip=$(db_get_ip_routing_outbound "$ip")
                if [[ -n "$outbound_ip" ]]; then
                    echo -e "    ${C}[$idx]${NC} $ip ${G}→${NC} $outbound_ip"
                else
                    echo -e "    ${C}[$idx]${NC} $ip ${D}(未配置)${NC}"
                fi
                ((idx++))
            done
            _line
        else
            echo -e "  ${D}未检测到公网IP${NC}"
            _line
        fi
        
        # 检查是否有失效的规则 (配置的IP已不存在)
        local invalid_rules=""
        if [[ "$rule_count" -gt 0 ]]; then
            while IFS= read -r rule; do
                local in_ip=$(echo "$rule" | jq -r '.inbound_ip')
                local out_ip=$(echo "$rule" | jq -r '.outbound_ip')
                local found=false
                for ip in "${all_ips[@]}"; do
                    [[ "$ip" == "$in_ip" ]] && found=true && break
                done
                if [[ "$found" == "false" ]]; then
                    invalid_rules+="  ${Y}⚠${NC} $in_ip → $out_ip ${D}(入站IP已不存在)${NC}\n"
                fi
            done < <(echo "$rules" | jq -c '.[]')
            
            if [[ -n "$invalid_rules" ]]; then
                echo -e "  ${W}失效规则:${NC}"
                echo -e "$invalid_rules"
                _line
            fi
        fi
        
        _item "1" "添加/修改映射规则"
        _item "2" "删除映射规则"
        _item "3" "清空所有规则"
        if db_ip_routing_enabled; then
            _item "4" "禁用多IP路由"
        else
            _item "4" "启用多IP路由"
        fi
        _item "5" "应用配置到Xray"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        
        case "$choice" in
            1)
                # 添加/修改映射规则
                if [[ $ip_count -lt 1 ]]; then
                    _err "没有检测到公网IP"
                    _pause
                    continue
                fi
                
                echo ""
                echo -e "  ${W}添加映射规则${NC}"
                _line
                
                # 显示可选IP
                echo -e "  ${Y}可用IP列表:${NC}"
                local idx=1
                for ip in "${all_ips[@]}"; do
                    echo -e "    ${C}[$idx]${NC} $ip"
                    ((idx++))
                done
                echo ""
                
                # 选择入站IP
                read -rp "  选择入站IP编号: " in_idx
                if [[ ! "$in_idx" =~ ^[0-9]+$ ]] || [[ "$in_idx" -lt 1 ]] || [[ "$in_idx" -gt $ip_count ]]; then
                    _err "无效的选择"
                    _pause
                    continue
                fi
                local inbound_ip="${all_ips[$((in_idx-1))]}"
                
                # 选择出站IP
                read -rp "  选择出站IP编号: " out_idx
                if [[ ! "$out_idx" =~ ^[0-9]+$ ]] || [[ "$out_idx" -lt 1 ]] || [[ "$out_idx" -gt $ip_count ]]; then
                    _err "无效的选择"
                    _pause
                    continue
                fi
                local outbound_ip="${all_ips[$((out_idx-1))]}"
                
                # 确认
                echo ""
                echo -e "  ${Y}确认:${NC} $inbound_ip ${G}→${NC} $outbound_ip"
                read -rp "  确认添加? [Y/n]: " confirm
                if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                    db_add_ip_routing_rule "$inbound_ip" "$outbound_ip"
                    _ok "规则已添加"
                fi
                _pause
                ;;
            2)
                # 删除映射规则
                if [[ "$rule_count" -eq 0 ]]; then
                    _err "没有已配置的规则"
                    _pause
                    continue
                fi
                
                echo ""
                echo -e "  ${W}删除映射规则${NC}"
                _line
                
                local idx=1
                local rule_array=()
                while IFS= read -r rule; do
                    local in_ip=$(echo "$rule" | jq -r '.inbound_ip')
                    local out_ip=$(echo "$rule" | jq -r '.outbound_ip')
                    echo -e "    ${C}[$idx]${NC} $in_ip → $out_ip"
                    rule_array+=("$in_ip")
                    ((idx++))
                done < <(echo "$rules" | jq -c '.[]')
                
                echo ""
                read -rp "  选择要删除的规则编号: " del_idx
                if [[ ! "$del_idx" =~ ^[0-9]+$ ]] || [[ "$del_idx" -lt 1 ]] || [[ "$del_idx" -gt ${#rule_array[@]} ]]; then
                    _err "无效的选择"
                    _pause
                    continue
                fi
                
                local del_ip="${rule_array[$((del_idx-1))]}"
                db_del_ip_routing_rule "$del_ip"
                _ok "规则已删除: $del_ip"
                _pause
                ;;
            3)
                # 清空所有规则
                echo ""
                read -rp "  确认清空所有规则? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    db_clear_ip_routing_rules
                    _ok "所有规则已清空"
                fi
                _pause
                ;;
            4)
                # 启用/禁用
                if db_ip_routing_enabled; then
                    db_set_ip_routing_enabled "false"
                    _info "正在禁用多IP路由..."
                    _regenerate_proxy_configs
                    _ok "多IP路由已禁用并应用配置"
                else
                    db_set_ip_routing_enabled "true"
                    _info "正在启用多IP路由..."
                    _regenerate_proxy_configs
                    _ok "多IP路由已启用并应用配置"
                fi
                _pause
                ;;
            5)
                # 应用配置到Xray
                _info "重新生成配置..."
                _regenerate_proxy_configs
                _ok "配置已应用"
                _pause
                ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# BBR 网络优化

#═══════════════════════════════════════════════════════════════════════════════

# 检查 BBR 状态
check_bbr_status() {
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]
}

# 一键开启 BBR 优化
enable_bbr() {
    _header
    echo -e "  ${W}BBR 网络优化${NC}"
    _line
    
    # 检查内核版本
    local kernel_ver=$(uname -r | cut -d'-' -f1)
    local kernel_major=$(echo "$kernel_ver" | cut -d'.' -f1)
    local kernel_minor=$(echo "$kernel_ver" | cut -d'.' -f2)
    
    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 9 ]]; then
        _err "内核版本 $(uname -r) 不支持 BBR (需要 4.9+)"
        _pause
        return 1
    fi
    
    # 系统信息检测
    local mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    local virt_type="unknown"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif grep -q -i "hypervisor" /proc/cpuinfo 2>/dev/null; then
        virt_type="KVM/VMware"
    fi
    
    echo -e "  ${C}系统信息${NC}"
    echo -e "  内核版本: ${G}$(uname -r)${NC} ✓"
    echo -e "  内存大小: ${G}${mem_mb}MB${NC}"
    echo -e "  CPU核心数: ${G}${cpu_cores}${NC}"
    echo -e "  虚拟化类型: ${G}${virt_type}${NC}"
    _line
    
    # 检查当前状态
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "  ${C}当前状态${NC}"
    echo -e "  拥塞控制: ${Y}$current_cc${NC}"
    echo -e "  队列调度: ${Y}$current_qdisc${NC}"
    
    # 显示当前 BBR 配置详情（如果已配置）
    local conf_file="/etc/sysctl.d/99-bbr-proxy.conf"
    if [[ -f "$conf_file" ]]; then
        echo ""
        echo -e "  ${C}已配置参数${NC}"
        local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
        local wmem=$(sysctl -n net.core.wmem_max 2>/dev/null)
        local somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null)
        local file_max=$(sysctl -n fs.file-max 2>/dev/null)
        echo -e "  读缓冲区: ${G}$((rmem/1024/1024))MB${NC}"
        echo -e "  写缓冲区: ${G}$((wmem/1024/1024))MB${NC}"
        echo -e "  最大连接队列: ${G}$somaxconn${NC}"
        echo -e "  最大文件句柄: ${G}$file_max${NC}"
    fi
    
    _line
    
    if check_bbr_status; then
        _ok "BBR 已启用"
        echo ""
        _item "1" "重新优化 (更新参数)"
        _item "2" "卸载 BBR 优化"
        _item "0" "返回"
        _line
        read -rp "  请选择: " choice
        case "$choice" in
            1) ;;  # 继续执行优化
            2)
                _info "卸载 BBR 优化配置..."
                rm -f "$conf_file"
                sysctl --system >/dev/null 2>&1
                _ok "BBR 优化配置已移除，系统恢复默认设置"
                _pause
                return 0
                ;;
            *) return 0 ;;
        esac
    else
        read -rp "  确认开启 BBR 优化? [Y/n]: " confirm
        [[ "$confirm" =~ ^[nN]$ ]] && return
    fi
    
    _info "加载 BBR 模块..."
    modprobe tcp_bbr 2>/dev/null || true
    
    # 检查 BBR 是否可用
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        _err "BBR 模块不可用，请检查内核配置"
        _pause
        return 1
    fi
    
    # 根据内存动态计算参数 (6档位)
    local vm_tier rmem_max wmem_max tcp_rmem tcp_wmem somaxconn netdev_backlog file_max conntrack_max
    if [[ $mem_mb -le 512 ]]; then
        vm_tier="经典级(≤512MB)"
        rmem_max=8388608; wmem_max=8388608
        tcp_rmem="4096 65536 8388608"; tcp_wmem="4096 65536 8388608"
        somaxconn=32768; netdev_backlog=16384; file_max=262144; conntrack_max=131072
    elif [[ $mem_mb -le 1024 ]]; then
        vm_tier="轻量级(512MB-1GB)"
        rmem_max=16777216; wmem_max=16777216
        tcp_rmem="4096 65536 16777216"; tcp_wmem="4096 65536 16777216"
        somaxconn=49152; netdev_backlog=24576; file_max=524288; conntrack_max=262144
    elif [[ $mem_mb -le 2048 ]]; then
        vm_tier="标准级(1GB-2GB)"
        rmem_max=33554432; wmem_max=33554432
        tcp_rmem="4096 87380 33554432"; tcp_wmem="4096 65536 33554432"
        somaxconn=65535; netdev_backlog=32768; file_max=1048576; conntrack_max=524288
    elif [[ $mem_mb -le 4096 ]]; then
        vm_tier="高性能级(2GB-4GB)"
        rmem_max=67108864; wmem_max=67108864
        tcp_rmem="4096 131072 67108864"; tcp_wmem="4096 87380 67108864"
        somaxconn=65535; netdev_backlog=65535; file_max=2097152; conntrack_max=1048576
    elif [[ $mem_mb -le 8192 ]]; then
        vm_tier="企业级(4GB-8GB)"
        rmem_max=134217728; wmem_max=134217728
        tcp_rmem="8192 131072 134217728"; tcp_wmem="8192 87380 134217728"
        somaxconn=65535; netdev_backlog=65535; file_max=4194304; conntrack_max=2097152
    else
        vm_tier="旗舰级(>8GB)"
        rmem_max=134217728; wmem_max=134217728
        tcp_rmem="8192 131072 134217728"; tcp_wmem="8192 87380 134217728"
        somaxconn=65535; netdev_backlog=65535; file_max=8388608; conntrack_max=2097152
    fi
    
    echo ""
    _info "应用 ${vm_tier} 优化配置..."
    
    cat > "$conf_file" << EOF
# ══════════════════════════════════════════════════════════════
# TCP/IP & BBR 优化配置 (由 vless 脚本自动生成)
# 生成时间: $(date)
# 针对硬件: ${mem_mb}MB 内存, ${cpu_cores}核CPU (${vm_tier})
# ══════════════════════════════════════════════════════════════

# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket 缓冲区
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_wmem = $tcp_wmem

# 连接队列
net.core.somaxconn = $somaxconn
net.core.netdev_max_backlog = $netdev_backlog
net.ipv4.tcp_max_syn_backlog = $somaxconn

# TCP 优化
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_max_tw_buckets = 180000
net.ipv4.tcp_slow_start_after_idle = 0

# 文件句柄
fs.file-max = $file_max

# 内存优化
vm.swappiness = 10
EOF

    # 如果支持 tcp_fastopen，添加配置
    if [[ -f /proc/sys/net/ipv4/tcp_fastopen ]]; then
        echo "" >> "$conf_file"
        echo "# TCP Fast Open" >> "$conf_file"
        echo "net.ipv4.tcp_fastopen = 3" >> "$conf_file"
    fi

    # 如果有 conntrack 模块，添加连接跟踪配置
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        echo "" >> "$conf_file"
        echo "# 连接跟踪" >> "$conf_file"
        echo "net.netfilter.nf_conntrack_max = $conntrack_max" >> "$conf_file"
    fi
    
    _info "应用配置..."
    # 使用 -p 逐个应用配置文件，忽略不支持的参数
    local sysctl_output
    sysctl_output=$(sysctl -p "$conf_file" 2>&1) || true
    
    # 检查是否有严重错误（排除 "unknown key" 警告）
    if echo "$sysctl_output" | grep -q "Invalid argument\|Permission denied"; then
        _err "配置应用失败"
        echo -e "  ${D}$sysctl_output${NC}"
        _pause
        return 1
    fi
    
    # 显示警告信息（如果有）
    if echo "$sysctl_output" | grep -q "unknown key"; then
        echo -e "  ${Y}部分参数不支持（已忽略）${NC}"
    fi
    
    _ok "配置已生效"
    
    # 验证结果
    _line
    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "  ${C}优化结果${NC}"
    echo -e "  配置档位: ${G}$vm_tier${NC}"
    echo -e "  拥塞控制: ${G}$new_cc${NC}"
    echo -e "  队列调度: ${G}$new_qdisc${NC}"
    echo -e "  读缓冲区: ${G}$((rmem_max/1024/1024))MB${NC}"
    echo -e "  写缓冲区: ${G}$((wmem_max/1024/1024))MB${NC}"
    echo -e "  最大连接队列: ${G}$somaxconn${NC}"
    echo -e "  最大文件句柄: ${G}$file_max${NC}"
    _line
    
    if [[ "$new_cc" == "bbr" && "$new_qdisc" == "fq" ]]; then
        _ok "BBR 优化已成功启用!"
    else
        _warn "BBR 可能未完全生效，请检查系统日志"
    fi
    
    _pause
}

#═══════════════════════════════════════════════════════════════════════════════
# 多协议管理菜单
#═══════════════════════════════════════════════════════════════════════════════

# 显示所有已安装协议的信息（带选择查看详情功能）
show_all_protocols_info() {
    local installed=$(get_installed_protocols)
    [[ -z "$installed" ]] && { _warn "未安装任何协议"; return; }
    
    while true; do
        _header
        echo -e "  ${W}已安装协议配置${NC}"
        _line
        
        local xray_protocols=$(get_xray_protocols)
        local singbox_protocols=$(get_singbox_protocols)
        local standalone_protocols=$(get_standalone_protocols)
        local all_protocols=()
        local idx=1
        
        if [[ -n "$xray_protocols" ]]; then
            echo -e "  ${Y}Xray 协议 (vless-reality 服务):${NC}"
            for protocol in $xray_protocols; do
                local port=""
                local cfg=""
                cfg=$(db_get "xray" "$protocol" 2>/dev/null || true)
                if [[ -n "$cfg" ]]; then
                    if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
                        port=$(echo "$cfg" | jq -r '.[].port' | tr '\n' ',' | sed 's/,$//')
                    else
                        port=$(echo "$cfg" | jq -r '.port // empty')
                    fi
                else
                    port=$(db_get_field "xray" "$protocol" "port")
                fi
                if [[ -n "$port" ]]; then
                    echo -e "    ${G}$idx${NC}) $(get_protocol_name $protocol) - 端口: ${G}$port${NC}"
                    all_protocols+=("$protocol")
                    ((idx++))
                fi
            done
            echo ""
        fi
        
        if [[ -n "$singbox_protocols" ]]; then
            echo -e "  ${Y}Sing-box 协议 (vless-singbox 服务):${NC}"
            for protocol in $singbox_protocols; do
                local port=$(db_get_field "singbox" "$protocol" "port")
                if [[ -n "$port" ]]; then
                    echo -e "    ${G}$idx${NC}) $(get_protocol_name $protocol) - 端口: ${G}$port${NC}"
                    all_protocols+=("$protocol")
                    ((idx++))
                fi
            done
            echo ""
        fi
        
        if [[ -n "$standalone_protocols" ]]; then
            echo -e "  ${Y}独立进程协议:${NC}"
            for protocol in $standalone_protocols; do
                local port=""
                local cfg=""
                # 同时检查 xray 和 singbox 核心（与 show_all_share_links 逻辑一致）
                if db_exists "xray" "$protocol"; then
                    cfg=$(db_get "xray" "$protocol" 2>/dev/null || true)
                elif db_exists "singbox" "$protocol"; then
                    cfg=$(db_get "singbox" "$protocol" 2>/dev/null || true)
                fi
                if [[ -n "$cfg" ]]; then
                    if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
                        port=$(echo "$cfg" | jq -r '.[].port' | tr '\n' ',' | sed 's/,$//')
                    else
                        port=$(echo "$cfg" | jq -r '.port // empty')
                    fi
                fi
                if [[ -n "$port" ]]; then
                    echo -e "    ${G}$idx${NC}) $(get_protocol_name $protocol) - 端口: ${G}$port${NC}"
                    all_protocols+=("$protocol")
                    ((idx++))
                fi
            done
            echo ""
        fi
        
        _line
        echo -e "  ${D}输入序号查看详细配置/链接/二维码${NC}"
        _item "a" "一键展示所有分享链接"
        _item "0" "返回"
        _line
        
        read -rp "  请选择 [0-$((idx-1))/a]: " choice
        
        if [[ "$choice" == "0" ]]; then
            return
        elif [[ "$choice" == "a" || "$choice" == "A" ]]; then
            show_all_share_links
            _pause
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -lt $idx ]]; then
            local selected_protocol="${all_protocols[$((choice-1))]}"
            show_single_protocol_info "$selected_protocol"
        else
            _err "无效选择"
            sleep 1
        fi
    done
}

# 一键展示所有分享链接
show_all_share_links() {
    _header
    echo -e "  ${W}所有协议分享链接${NC}"
    _line
    
    local xray_protocols=$(get_xray_protocols)
    local singbox_protocols=$(get_singbox_protocols)
    local standalone_protocols=$(get_standalone_protocols)
    local has_links=false
    
    # 获取 IP 地址
    local ipv4=$(get_ipv4)
    local ipv6=$(get_ipv6)
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")
    
    # 主协议端口（用于回落 WS/VMess）
    local master_port=""
    master_port=$(_get_master_port "")
    
    # 遍历所有协议生成链接
    for protocol in $xray_protocols $singbox_protocols $standalone_protocols; do
        local cfg=""
        if db_exists "xray" "$protocol"; then
            cfg=$(db_get "xray" "$protocol")
        elif db_exists "singbox" "$protocol"; then
            cfg=$(db_get "singbox" "$protocol")
        else
            continue
        fi
        [[ -z "$cfg" ]] && continue
        
        # 处理多端口数组
        local cfg_stream=""
        if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
            cfg_stream=$(echo "$cfg" | jq -c '.[]')
        else
            cfg_stream=$(echo "$cfg" | jq -c '.')
        fi
        
        echo -e "  ${Y}$(get_protocol_name $protocol)${NC}"
        
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            
            # 提取配置字段
            local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
            local port=$(echo "$cfg" | jq -r '.port // empty')
            local sni=$(echo "$cfg" | jq -r '.sni // empty')
            local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
            local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
            local path=$(echo "$cfg" | jq -r '.path // empty')
            local password=$(echo "$cfg" | jq -r '.password // empty')
            local username=$(echo "$cfg" | jq -r '.username // empty')
            local method=$(echo "$cfg" | jq -r '.method // empty')
            local psk=$(echo "$cfg" | jq -r '.psk // empty')
            local version=$(echo "$cfg" | jq -r '.version // empty')
            local domain=$(echo "$cfg" | jq -r '.domain // empty')
            local stls_password=$(echo "$cfg" | jq -r '.stls_password // empty')
            
            [[ -z "$port" ]] && continue
            
            # 检测回落协议端口
            local display_port="$port"
            if [[ -n "$master_port" && ("$protocol" == "vless-ws" || "$protocol" == "vmess-ws" || "$protocol" == "trojan-ws") ]]; then
                display_port="$master_port"
            fi
            
            # 生成 IPv4 链接
            if [[ -n "$ipv4" ]]; then
                local link=""
                local config_ip="$ipv4"
                
                case "$protocol" in
                    vless) link=$(gen_vless_link "$ipv4" "$display_port" "$uuid" "$public_key" "$short_id" "$sni" "$country_code") ;;
                    vless-xhttp) link=$(gen_vless_xhttp_link "$ipv4" "$display_port" "$uuid" "$public_key" "$short_id" "$sni" "$path" "$country_code") ;;
                    vless-vision) link=$(gen_vless_vision_link "$ipv4" "$display_port" "$uuid" "$sni" "$country_code") ;;
                    vless-ws) link=$(gen_vless_ws_link "$ipv4" "$display_port" "$uuid" "$sni" "$path" "$country_code") ;;
                    vmess-ws) link=$(gen_vmess_ws_link "$ipv4" "$display_port" "$uuid" "$sni" "$path" "$country_code") ;;
                    ss2022) link=$(gen_ss2022_link "$ipv4" "$display_port" "$method" "$password" "$country_code") ;;
                    ss-legacy) link=$(gen_ss_legacy_link "$ipv4" "$display_port" "$method" "$password" "$country_code") ;;
                    hy2) link=$(gen_hy2_link "$ipv4" "$display_port" "$password" "$sni" "$country_code") ;;
                    trojan) link=$(gen_trojan_link "$ipv4" "$display_port" "$password" "$sni" "$country_code") ;;
                    trojan-ws) link=$(gen_trojan_ws_link "$ipv4" "$display_port" "$password" "$sni" "$path" "$country_code") ;;
                    snell) link=$(gen_snell_link "$ipv4" "$display_port" "$psk" "$version" "$country_code") ;;
                    snell-v5) link=$(gen_snell_v5_link "$ipv4" "$display_port" "$psk" "$version" "$country_code") ;;
                    tuic) link=$(gen_tuic_link "$ipv4" "$display_port" "$uuid" "$password" "$sni" "$country_code") ;;
                    anytls) link=$(gen_anytls_link "$ipv4" "$display_port" "$password" "$sni" "$country_code") ;;
                    naive) link=$(gen_naive_link "$domain" "$display_port" "$username" "$password" "$country_code") ;;
                    socks) link=$(gen_socks_link "$ipv4" "$display_port" "$username" "$password" "$country_code") ;;
                    # ShadowTLS 组合协议：没有标准分享链接，显示 Surge/Loon 配置
                    snell-shadowtls)
                        echo -e "  ${Y}Surge:${NC}"
                        echo -e "  ${C}${country_code}-Snell-ShadowTLS = snell, ${config_ip}, ${display_port}, psk=${psk}, version=${version:-4}, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
                        has_links=true
                        ;;
                    snell-v5-shadowtls)
                        echo -e "  ${Y}Surge:${NC}"
                        echo -e "  ${C}${country_code}-Snell-v5-ShadowTLS = snell, ${config_ip}, ${display_port}, psk=${psk}, version=5, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
                        has_links=true
                        ;;
                    ss2022-shadowtls)
                        echo -e "  ${Y}Surge:${NC}"
                        echo -e "  ${C}${country_code}-SS2022-ShadowTLS = ss, ${config_ip}, ${display_port}, encrypt-method=${method}, password=${password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
                        echo -e "  ${Y}Loon:${NC}"
                        echo -e "  ${C}${country_code}-SS2022-ShadowTLS = shadowsocks, ${config_ip}, ${display_port}, ${method}, \"${password}\", shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}${NC}"
                        has_links=true
                        ;;
                esac
                [[ -n "$link" ]] && echo -e "  ${G}$link${NC}" && has_links=true
            fi
            
            # 生成 IPv6 链接
            if [[ -n "$ipv6" ]]; then
                local link=""
                local ip6="[$ipv6]"
                case "$protocol" in
                    vless) link=$(gen_vless_link "$ip6" "$display_port" "$uuid" "$public_key" "$short_id" "$sni" "$country_code") ;;
                    vless-xhttp) link=$(gen_vless_xhttp_link "$ip6" "$display_port" "$uuid" "$public_key" "$short_id" "$sni" "$path" "$country_code") ;;
                    vless-vision) link=$(gen_vless_vision_link "$ip6" "$display_port" "$uuid" "$sni" "$country_code") ;;
                    vless-ws) link=$(gen_vless_ws_link "$ip6" "$display_port" "$uuid" "$sni" "$path" "$country_code") ;;
                    vmess-ws) link=$(gen_vmess_ws_link "$ip6" "$display_port" "$uuid" "$sni" "$path" "$country_code") ;;
                    ss2022) link=$(gen_ss2022_link "$ip6" "$display_port" "$method" "$password" "$country_code") ;;
                    ss-legacy) link=$(gen_ss_legacy_link "$ip6" "$display_port" "$method" "$password" "$country_code") ;;
                    hy2) link=$(gen_hy2_link "$ip6" "$display_port" "$password" "$sni" "$country_code") ;;
                    trojan) link=$(gen_trojan_link "$ip6" "$display_port" "$password" "$sni" "$country_code") ;;
                    trojan-ws) link=$(gen_trojan_ws_link "$ip6" "$display_port" "$password" "$sni" "$path" "$country_code") ;;
                    snell) link=$(gen_snell_link "$ip6" "$display_port" "$psk" "$version" "$country_code") ;;
                    snell-v5) link=$(gen_snell_v5_link "$ip6" "$display_port" "$psk" "$version" "$country_code") ;;
                    tuic) link=$(gen_tuic_link "$ip6" "$display_port" "$uuid" "$password" "$sni" "$country_code") ;;
                    anytls) link=$(gen_anytls_link "$ip6" "$display_port" "$password" "$sni" "$country_code") ;;
                    naive) ;; # NaïveProxy 使用域名，不需要 IPv6 链接
                    socks) link=$(gen_socks_link "$ip6" "$display_port" "$username" "$password" "$country_code") ;;
                    # ShadowTLS 组合协议 IPv6：没有标准分享链接，显示 Surge/Loon 配置
                    snell-shadowtls)
                        echo -e "  ${Y}Surge (IPv6):${NC}"
                        echo -e "  ${C}${country_code}-Snell-ShadowTLS-v6 = snell, ${ipv6}, ${display_port}, psk=${psk}, version=${version:-4}, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
                        has_links=true
                        ;;
                    snell-v5-shadowtls)
                        echo -e "  ${Y}Surge (IPv6):${NC}"
                        echo -e "  ${C}${country_code}-Snell-v5-ShadowTLS-v6 = snell, ${ipv6}, ${display_port}, psk=${psk}, version=5, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
                        has_links=true
                        ;;
                    ss2022-shadowtls)
                        echo -e "  ${Y}Surge (IPv6):${NC}"
                        echo -e "  ${C}${country_code}-SS2022-ShadowTLS-v6 = ss, ${ipv6}, ${display_port}, encrypt-method=${method}, password=${password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
                        echo -e "  ${Y}Loon (IPv6):${NC}"
                        echo -e "  ${C}${country_code}-SS2022-ShadowTLS-v6 = shadowsocks, ${ipv6}, ${display_port}, ${method}, \"${password}\", shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}${NC}"
                        has_links=true
                        ;;
                esac
                [[ -n "$link" ]] && echo -e "  ${G}$link${NC}" && has_links=true
            fi
        done <<< "$cfg_stream"
        
        echo ""
    done
    
    if [[ "$has_links" == "false" ]]; then
        echo -e "  ${D}暂无已安装的协议${NC}"
    fi
    
    _line
}

# 显示单个协议的详细配置信息（包含链接和二维码）
# 参数: $1=协议名, $2=是否清屏(可选，默认true), $3=指定端口(可选)
show_single_protocol_info() {
    local protocol="$1"
    local clear_screen="${2:-true}"
    local specified_port="$3"
    
    # 从数据库读取配置
    local cfg=""
    local core="xray"
    if db_exists "xray" "$protocol"; then
        cfg=$(db_get "xray" "$protocol")
    elif db_exists "singbox" "$protocol"; then
        cfg=$(db_get "singbox" "$protocol")
        core="singbox"
    else
        _err "协议配置不存在: $protocol"
        return
    fi
    
    # 检查是否为数组（多端口）
    if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
        if [[ -n "$specified_port" ]]; then
            # 指定了端口：直接使用该端口的配置
            cfg=$(echo "$cfg" | jq --arg port "$specified_port" '.[] | select(.port == ($port | tonumber))')
            if [[ -z "$cfg" || "$cfg" == "null" ]]; then
                _err "未找到端口 $specified_port 的配置"
                return
            fi
        else
            # 未指定端口：显示选择菜单
            local ports=$(echo "$cfg" | jq -r '.[].port')
            local port_array=($ports)
            local port_count=${#port_array[@]}
            
            if [[ $port_count -gt 1 ]]; then
                echo ""
                echo -e "${CYAN}协议 ${YELLOW}$protocol${CYAN} 有 ${port_count} 个端口实例：${NC}"
                echo ""
                local i=1
                for p in "${port_array[@]}"; do
                    echo -e "  ${G}$i${NC}) 端口 ${G}$p${NC}"
                    ((i++))
                done
                echo "  0) 返回"
                echo ""
                
                local choice
                read -p "$(echo -e "  ${GREEN}请选择要查看的端口 [0-$port_count]:${NC} ")" choice
                
                if [[ "$choice" == "0" ]]; then
                    return
                elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$port_count" ]; then
                    # 提取选中端口的配置
                    cfg=$(echo "$cfg" | jq ".[$((choice-1))]")
                else
                    _err "无效选项"
                    return
                fi
            else
                # 只有一个端口，直接使用
                cfg=$(echo "$cfg" | jq ".[0]")
            fi
        fi
    fi
    
    # 从 JSON 提取字段
    local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
    local port=$(echo "$cfg" | jq -r '.port // empty')
    local sni=$(echo "$cfg" | jq -r '.sni // empty')
    local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
    local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
    local private_key=$(echo "$cfg" | jq -r '.private_key // empty')
    local path=$(echo "$cfg" | jq -r '.path // empty')
    local password=$(echo "$cfg" | jq -r '.password // empty')
    local username=$(echo "$cfg" | jq -r '.username // empty')
    local method=$(echo "$cfg" | jq -r '.method // empty')
    local psk=$(echo "$cfg" | jq -r '.psk // empty')
    local version=$(echo "$cfg" | jq -r '.version // empty')
    local ipv4=$(echo "$cfg" | jq -r '.ipv4 // empty')
    local ipv6=$(echo "$cfg" | jq -r '.ipv6 // empty')
    local hop_enable=$(echo "$cfg" | jq -r '.hop_enable // empty')
    local hop_start=$(echo "$cfg" | jq -r '.hop_start // empty')
    local hop_end=$(echo "$cfg" | jq -r '.hop_end // empty')
    local stls_password=$(echo "$cfg" | jq -r '.stls_password // empty')
    
    # 重新获取 IP（数据库中的可能是旧的）
    [[ -z "$ipv4" ]] && ipv4=$(get_ipv4)
    [[ -z "$ipv6" ]] && ipv6=$(get_ipv6)
    
    # 检测是否为回落子协议（WS 在有 TLS 主协议时使用主协议端口）
    # 注意：Reality 不支持 WS 回落，只有 Vision/Trojan 可以
    local display_port="$port"
    local is_fallback_protocol=false
    local master_name=""
    if [[ "$protocol" == "vless-ws" || "$protocol" == "vmess-ws" || "$protocol" == "trojan-ws" ]]; then
        # 检查是否有 TLS 主协议在 8443 端口 (仅 8443 端口才触发回落显示)
        # 注意：Reality 不支持 WS 回落，只有 Vision/Trojan 可以
        if db_exists "xray" "vless-vision"; then
            local master_port=$(db_get_field "xray" "vless-vision" "port" 2>/dev/null)
            if [[ "$master_port" == "8443" ]]; then
                display_port="$master_port"
                is_fallback_protocol=true
                master_name="Vision"
            fi
        fi
        if [[ "$is_fallback_protocol" == "false" ]] && db_exists "xray" "trojan"; then
            local master_port=$(db_get_field "xray" "trojan" "port" 2>/dev/null)
            if [[ "$master_port" == "8443" ]]; then
                display_port="$master_port"
                is_fallback_protocol=true
                master_name="Trojan"
            fi
        fi
    fi
    
    [[ "$clear_screen" == "true" ]] && _header
    _line
    echo -e "  ${W}$(get_protocol_name $protocol) 配置详情${NC}"
    _line
    
    [[ -n "$ipv4" ]] && echo -e "  IPv4: ${G}$ipv4${NC}"
    [[ -n "$ipv6" ]] && echo -e "  IPv6: ${G}$ipv6${NC}"
    echo -e "  端口: ${G}$display_port${NC}"
    [[ "$is_fallback_protocol" == "true" ]] && echo -e "  ${D}(通过 $master_name 主协议回落，内部端口: $port)${NC}"
    
    # 获取地区代码（只获取一次，用于所有显示）
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")
    
    # 确定用于配置显示的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6（带方括号）
    local config_ip="$ipv4"
    [[ -z "$config_ip" ]] && config_ip="[$ipv6]"
    
    case "$protocol" in
        vless)
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  公钥: ${G}$public_key${NC}"
            echo -e "  SNI: ${G}$sni${NC}  ShortID: ${G}$short_id${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-Vless-Reality = VLESS, ${config_ip}, ${display_port}, \"${uuid}\", transport=tcp, flow=xtls-rprx-vision, public-key=\"${public_key}\", short-id=${short_id}, udp=true, over-tls=true, sni=${sni}${NC}"
            ;;
        vless-xhttp)
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  公钥: ${G}$public_key${NC}"
            echo -e "  SNI: ${G}$sni${NC}  ShortID: ${G}$short_id${NC}"
            echo -e "  Path: ${G}$path${NC}"
            echo ""
            echo -e "  ${D}注: Loon/Surge 暂不支持 XHTTP 传输，请使用分享链接导入 Shadowrocket${NC}"
            ;;
        vless-xhttp-cdn)
            local domain=$(echo "$cfg" | jq -r '.domain // empty')
            echo -e "  域名: ${G}$domain${NC}"
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  Path: ${G}$path${NC}"
            echo -e "  外部端口: ${G}443${NC} (Nginx TLS)"
            echo -e "  内部端口: ${G}$port${NC} (Xray h2c)"
            echo ""
            echo -e "  ${Y}客户端配置:${NC}"
            echo -e "  ${C}地址=${domain}, 端口=443, TLS=开启${NC}"
            echo ""
            echo -e "  ${D}注: Loon/Surge 暂不支持 XHTTP 传输，请使用分享链接导入 Shadowrocket${NC}"
            ;;
        vless-vision)
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            [[ -n "$path" ]] && echo -e "  Path/ServiceName: ${G}$path${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-Vless-Vision = VLESS, ${config_ip}, ${display_port}, \"${uuid}\", transport=tcp, flow=xtls-rprx-vision, udp=true, over-tls=true, sni=${sni}, skip-cert-verify=true${NC}"
            ;;
        vless-ws)
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            [[ -n "$path" ]] && echo -e "  Path/ServiceName: ${G}$path${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-Vless-WS = VLESS, ${config_ip}, ${display_port}, \"${uuid}\", transport=ws, path=${path}, host=${sni}, udp=true, over-tls=true, sni=${sni}, skip-cert-verify=true${NC}"
            echo ""
            echo -e "  ${Y}Clash Meta 配置:${NC}"
            echo -e "  ${C}- name: ${country_code}-VLESS-WS-TLS${NC}"
            echo -e "  ${C}  type: vless${NC}"
            echo -e "  ${C}  server: ${config_ip}${NC}"
            echo -e "  ${C}  port: ${display_port}${NC}"
            echo -e "  ${C}  uuid: ${uuid}${NC}"
            echo -e "  ${C}  network: ws${NC}"
            echo -e "  ${C}  tls: true${NC}"
            echo -e "  ${C}  skip-cert-verify: true${NC}"
            echo -e "  ${C}  servername: ${sni}${NC}"
            echo -e "  ${C}  ws-opts:${NC}"
            echo -e "  ${C}    path: ${path}${NC}"
            echo -e "  ${C}    headers:${NC}"
            echo -e "  ${C}      Host: ${sni}${NC}"
            ;;
        vless-ws-notls)
            local host=$(echo "$cfg" | jq -r '.host // empty')
            echo -e "  UUID: ${G}$uuid${NC}"
            [[ -n "$path" ]] && echo -e "  Path: ${G}$path${NC}"
            [[ -n "$host" ]] && echo -e "  Host: ${G}$host${NC}"
            echo ""
            echo -e "  ${Y}注意: 此协议为无 TLS 模式，专为 CF Tunnel 设计${NC}"
            echo -e "  ${D}请配置 Cloudflare Tunnel 指向此端口${NC}"
            ;;
        vmess-ws)
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            [[ -n "$path" ]] && echo -e "  Path: ${G}$path${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-VMess-WS = vmess, ${config_ip}, ${display_port}, ${uuid}, tls=true, ws=true, ws-path=${path}, sni=${sni}, skip-cert-verify=true${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-VMess-WS = VMess, ${config_ip}, ${display_port}, aes-128-gcm, \"${uuid}\", transport=ws, path=${path}, host=${sni}, udp=true, over-tls=true, sni=${sni}, skip-cert-verify=true${NC}"
            echo ""
            echo -e "  ${Y}Clash 配置:${NC}"
            echo -e "  ${C}- name: ${country_code}-VMess-WS${NC}"
            echo -e "  ${C}  type: vmess${NC}"
            echo -e "  ${C}  server: ${config_ip}${NC}"
            echo -e "  ${C}  port: ${display_port}${NC}"
            echo -e "  ${C}  uuid: ${uuid}${NC}"
            echo -e "  ${C}  alterId: 0${NC}"
            echo -e "  ${C}  cipher: auto${NC}"
            echo -e "  ${C}  tls: true${NC}"
            echo -e "  ${C}  skip-cert-verify: true${NC}"
            echo -e "  ${C}  network: ws${NC}"
            echo -e "  ${C}  ws-opts:${NC}"
            echo -e "  ${C}    path: ${path}${NC}"
            echo -e "  ${C}    headers:${NC}"
            echo -e "  ${C}      Host: ${sni}${NC}"
            ;;
        ss2022)
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  加密: ${G}$method${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-SS2022 = ss, ${config_ip}, ${display_port}, encrypt-method=${method}, password=${password}${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-SS2022 = Shadowsocks, ${config_ip}, ${display_port}, ${method}, \"${password}\", udp=true${NC}"
            ;;
        ss-legacy)
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  加密: ${G}$method${NC}"
            echo -e "  ${D}(传统版, 无时间校验)${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-SS = ss, ${config_ip}, ${display_port}, encrypt-method=${method}, password=${password}${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-SS = Shadowsocks, ${config_ip}, ${display_port}, ${method}, \"${password}\", udp=true${NC}"
            ;;
        hy2)
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            if [[ "$hop_enable" == "1" ]]; then
                echo -e "  端口跳跃: ${G}${hop_start}-${hop_end}${NC}"
            fi
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-Hysteria2 = hysteria2, ${config_ip}, ${display_port}, password=${password}, sni=${sni}, skip-cert-verify=true${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-Hysteria2 = Hysteria2, ${config_ip}, ${display_port}, \"${password}\", udp=true, sni=${sni}, skip-cert-verify=true${NC}"
            echo ""
            echo -e "  ${Y}Clash Meta 配置:${NC}"
            echo -e "  ${C}- name: ${country_code}-Hysteria2${NC}"
            echo -e "  ${C}  type: hysteria2${NC}"
            echo -e "  ${C}  server: ${config_ip}${NC}"
            echo -e "  ${C}  port: ${display_port}${NC}"
            echo -e "  ${C}  password: ${password}${NC}"
            echo -e "  ${C}  sni: ${sni}${NC}"
            echo -e "  ${C}  skip-cert-verify: true${NC}"
            ;;
        trojan)
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-Trojan = trojan, ${config_ip}, ${display_port}, password=${password}, sni=${sni}, skip-cert-verify=true${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-Trojan = trojan, ${config_ip}, ${display_port}, \"${password}\", udp=true, over-tls=true, sni=${sni}${NC}"
            echo ""
            echo -e "  ${Y}Clash 配置:${NC}"
            echo -e "  ${C}- name: ${country_code}-Trojan${NC}"
            echo -e "  ${C}  type: trojan${NC}"
            echo -e "  ${C}  server: ${config_ip}${NC}"
            echo -e "  ${C}  port: ${display_port}${NC}"
            echo -e "  ${C}  password: ${password}${NC}"
            echo -e "  ${C}  sni: ${sni}${NC}"
            echo -e "  ${C}  skip-cert-verify: true${NC}"
            ;;
        trojan-ws)
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            [[ -n "$path" ]] && echo -e "  Path: ${G}$path${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-Trojan-WS = trojan, ${config_ip}, ${display_port}, password=${password}, sni=${sni}, ws=true, ws-path=${path}, skip-cert-verify=true${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-Trojan-WS = trojan, ${config_ip}, ${display_port}, \"${password}\", transport=ws, path=${path}, host=${sni}, udp=true, over-tls=true, sni=${sni}, skip-cert-verify=true${NC}"
            ;;
        anytls)
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-AnyTLS = anytls, ${config_ip}, ${display_port}, password=${password}, sni=${sni}, skip-cert-verify=true${NC}"
            ;;
        naive)
            local domain=$(echo "$cfg" | jq -r '.domain // empty')
            echo -e "  域名: ${G}$domain${NC}"
            echo -e "  用户名: ${G}$username${NC}"
            echo -e "  密码: ${G}$password${NC}"
            echo ""
            echo -e "  ${Y}Shadowrocket (HTTP/2):${NC}"
            echo -e "  ${C}http2://${username}:${password}@${domain}:${display_port}${NC}"
            ;;
        snell-shadowtls)
            echo -e "  PSK: ${G}$psk${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            echo -e "  版本: ${G}v${version:-4}${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-Snell-ShadowTLS = snell, ${config_ip}, ${display_port}, psk=${psk}, version=${version:-4}, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
            ;;
        snell-v5-shadowtls)
            echo -e "  PSK: ${G}$psk${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            echo -e "  版本: ${G}v${version:-5}${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-Snell5-ShadowTLS = snell, ${config_ip}, ${display_port}, psk=${psk}, version=${version:-5}, reuse=true, tfo=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
            ;;
        ss2022-shadowtls)
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  加密: ${G}$method${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-SS2022-ShadowTLS = ss, ${config_ip}, ${display_port}, encrypt-method=${method}, password=${password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
            echo ""
            echo -e "  ${Y}Loon 配置:${NC}"
            echo -e "  ${C}${country_code}-SS2022-ShadowTLS = Shadowsocks, ${config_ip}, ${display_port}, ${method}, \"${password}\", udp=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${sni}, shadow-tls-version=3${NC}"
            ;;
        snell|snell-v5)
            echo -e "  PSK: ${G}$psk${NC}"
            echo -e "  版本: ${G}v$version${NC}"
            echo ""
            echo -e "  ${Y}Surge 配置 (Snell 为 Surge 专属协议):${NC}"
            echo -e "  ${C}${country_code}-Snell = snell, ${config_ip}, ${display_port}, psk=${psk}, version=${version}, reuse=true, tfo=true${NC}"
            ;;
        tuic)
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$sni${NC}"
            if [[ "$hop_enable" == "1" ]]; then
                echo -e "  端口跳跃: ${G}${hop_start}-${hop_end}${NC}"
            fi
            echo ""
            echo -e "  ${Y}Surge 配置:${NC}"
            echo -e "  ${C}${country_code}-TUIC = tuic-v5, ${config_ip}, ${display_port}, password=${password}, uuid=${uuid}, sni=${sni}, skip-cert-verify=true, alpn=h3${NC}"

            ;;
        socks)
            local use_tls=$(echo "$cfg" | jq -r '.tls // "false"')
            local socks_sni=$(echo "$cfg" | jq -r '.sni // ""')
            echo -e "  用户名: ${G}$username${NC}"
            echo -e "  密码: ${G}$password${NC}"
            if [[ "$use_tls" == "true" ]]; then
                echo -e "  TLS: ${G}启用${NC} (SNI: $socks_sni)"
                echo ""
                echo -e "  ${Y}Surge 配置:${NC}"
                echo -e "  ${C}${country_code}-SOCKS5-TLS = socks5-tls, ${config_ip}, ${display_port}, ${username}, ${password}, skip-cert-verify=true, sni=${socks_sni}${NC}"
                echo ""
                echo -e "  ${Y}Clash 配置:${NC}"
                echo -e "  ${C}- name: ${country_code}-SOCKS5-TLS${NC}"
                echo -e "  ${C}  type: socks5${NC}"
                echo -e "  ${C}  server: ${config_ip}${NC}"
                echo -e "  ${C}  port: ${display_port}${NC}"
                echo -e "  ${C}  username: ${username}${NC}"
                echo -e "  ${C}  password: ${password}${NC}"
                echo -e "  ${C}  tls: true${NC}"
                echo -e "  ${C}  skip-cert-verify: true${NC}"
            else
                echo -e "  TLS: ${D}未启用${NC}"
                echo ""
                echo -e "  ${Y}Telegram 代理链接:${NC}"
                echo -e "  ${C}https://t.me/socks?server=${config_ip}&port=${display_port}&user=${username}&pass=${password}${NC}"
                echo ""
                echo -e "  ${Y}Surge 配置:${NC}"
                echo -e "  ${C}${country_code}-SOCKS5 = socks5, ${config_ip}, ${display_port}, ${username}, ${password}${NC}"
                echo ""
                echo -e "  ${Y}Loon 配置:${NC}"
                echo -e "  ${C}${country_code}-SOCKS5 = socks5, ${config_ip}, ${display_port}, ${username}, \"${password}\", udp=true${NC}"
            fi
            ;;
    esac
    
    _line
    
    # 获取地区代码（只获取一次，用于所有链接）
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")
    
    # 确定使用的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6
    local ip_addr=""
    if [[ -n "$ipv4" ]]; then
        ip_addr="$ipv4"
    elif [[ -n "$ipv6" ]]; then
        ip_addr="[$ipv6]"  # IPv6 需要用方括号包裹
    fi
    
    # 显示分享链接和二维码
    if [[ -n "$ip_addr" ]]; then
        local link_port="$display_port"
        
        local link join_code
        case "$protocol" in
            vless)
                link=$(gen_vless_link "$ip_addr" "$link_port" "$uuid" "$public_key" "$short_id" "$sni" "$country_code")
                join_code=$(echo "REALITY|${ip_addr}|${link_port}|${uuid}|${public_key}|${short_id}|${sni}" | base64 -w 0)
                ;;
            vless-xhttp)
                link=$(gen_vless_xhttp_link "$ip_addr" "$link_port" "$uuid" "$public_key" "$short_id" "$sni" "$path" "$country_code")
                join_code=$(echo "REALITY-XHTTP|${ip_addr}|${link_port}|${uuid}|${public_key}|${short_id}|${sni}|${path}" | base64 -w 0)
                ;;
            vless-xhttp-cdn)
                local domain=$(echo "$cfg" | jq -r '.domain // empty')
                # TLS+CDN 模式使用域名和 443 端口
                link=$(gen_vless_xhttp_cdn_link "$domain" "443" "$uuid" "$path" "$country_code")
                join_code=$(echo "VLESS-XHTTP-CDN|${domain}|443|${uuid}|${path}" | base64 -w 0)
                ;;
            vless-vision)
                link=$(gen_vless_vision_link "$ip_addr" "$link_port" "$uuid" "$sni" "$country_code")
                join_code=$(echo "VLESS-VISION|${ip_addr}|${link_port}|${uuid}|${sni}" | base64 -w 0)
                ;;
            vless-ws)
                link=$(gen_vless_ws_link "$ip_addr" "$link_port" "$uuid" "$sni" "$path" "$country_code")
                join_code=$(echo "VLESS-WS|${ip_addr}|${link_port}|${uuid}|${sni}|${path}" | base64 -w 0)
                ;;
            vless-ws-notls)
                local host=$(echo "$cfg" | jq -r '.host // empty')
                link=$(gen_vless_ws_notls_link "$ip_addr" "$link_port" "$uuid" "$path" "$host" "$country_code")
                join_code=$(echo "VLESS-WS-CF|${ip_addr}|${link_port}|${uuid}|${path}|${host}" | base64 -w 0)
                ;;
            vmess-ws)
                link=$(gen_vmess_ws_link "$ip_addr" "$link_port" "$uuid" "$sni" "$path" "$country_code")
                join_code=$(echo "VMESS-WS|${ip_addr}|${link_port}|${uuid}|${sni}|${path}" | base64 -w 0)
                ;;
            ss2022)
                link=$(gen_ss2022_link "$ip_addr" "$link_port" "$method" "$password" "$country_code")
                join_code=$(echo "SS2022|${ip_addr}|${link_port}|${method}|${password}" | base64 -w 0)
                ;;
            ss-legacy)
                link=$(gen_ss_legacy_link "$ip_addr" "$link_port" "$method" "$password" "$country_code")
                join_code=$(echo "SS|${ip_addr}|${link_port}|${method}|${password}" | base64 -w 0)
                ;;
            hy2)
                link=$(gen_hy2_link "$ip_addr" "$link_port" "$password" "$sni" "$country_code")
                join_code=$(echo "HY2|${ip_addr}|${link_port}|${password}|${sni}" | base64 -w 0)
                ;;
            trojan)
                link=$(gen_trojan_link "$ip_addr" "$link_port" "$password" "$sni" "$country_code")
                join_code=$(echo "TROJAN|${ip_addr}|${link_port}|${password}|${sni}" | base64 -w 0)
                ;;
            trojan-ws)
                link=$(gen_trojan_ws_link "$ip_addr" "$link_port" "$password" "$sni" "$path" "$country_code")
                join_code=$(echo "TROJAN-WS|${ip_addr}|${link_port}|${password}|${sni}|${path}" | base64 -w 0)
                ;;
            snell)
                link=$(gen_snell_link "$ip_addr" "$link_port" "$psk" "$version" "$country_code")
                join_code=$(echo "SNELL|${ip_addr}|${link_port}|${psk}|${version}" | base64 -w 0)
                ;;
            snell-v5)
                link=$(gen_snell_v5_link "$ip_addr" "$link_port" "$psk" "$version" "$country_code")
                join_code=$(echo "SNELL-V5|${ip_addr}|${link_port}|${psk}|${version}" | base64 -w 0)
                ;;
            snell-shadowtls|snell-v5-shadowtls)
                local stls_ver="${version:-4}"
                [[ "$protocol" == "snell-v5-shadowtls" ]] && stls_ver="5"
                join_code=$(echo "SNELL-SHADOWTLS|${ip_addr}|${link_port}|${psk}|${stls_ver}|${stls_password}|${sni}" | base64 -w 0)
                link=""
                ;;
            ss2022-shadowtls)
                join_code=$(echo "SS2022-SHADOWTLS|${ip_addr}|${link_port}|${method}|${password}|${stls_password}|${sni}" | base64 -w 0)
                link=""
                ;;
            tuic)
                link=$(gen_tuic_link "$ip_addr" "$link_port" "$uuid" "$password" "$sni" "$country_code")
                join_code=$(echo "TUIC|${ip_addr}|${link_port}|${uuid}|${password}|${sni}" | base64 -w 0)
                ;;
            anytls)
                link=$(gen_anytls_link "$ip_addr" "$link_port" "$password" "$sni" "$country_code")
                join_code=$(echo "ANYTLS|${ip_addr}|${link_port}|${password}|${sni}" | base64 -w 0)
                ;;
            naive)
                local domain=$(echo "$cfg" | jq -r '.domain // empty')
                link=$(gen_naive_link "$domain" "$link_port" "$username" "$password" "$country_code")
                join_code=$(echo "NAIVE|${domain}|${link_port}|${username}|${password}" | base64 -w 0)
                ;;
            socks)
                local use_tls=$(echo "$cfg" | jq -r '.tls // "false"')
                local socks_sni=$(echo "$cfg" | jq -r '.sni // ""')
                if [[ "$use_tls" == "true" ]]; then
                    link="socks5://${username}:${password}@${ip_addr}:${link_port}?tls=true&sni=${socks_sni}#SOCKS5-TLS-${ip_addr}"
                    join_code=$(echo "SOCKS-TLS|${ip_addr}|${link_port}|${username}|${password}|${socks_sni}" | base64 -w 0)
                else
                    link=$(gen_socks_link "$ip_addr" "$link_port" "$username" "$password" "$country_code")
                    join_code=$(echo "SOCKS|${ip_addr}|${link_port}|${username}|${password}" | base64 -w 0)
                fi
                ;;
        esac
        
        # 显示 JOIN 码 (根据开关控制)
        if [[ "$SHOW_JOIN_CODE" == "on" ]]; then
            echo -e "  ${C}JOIN码:${NC}"
            echo -e "  ${G}$join_code${NC}"
            echo ""
        fi
        
        # ShadowTLS 组合协议只显示 JOIN 码
        if [[ "$protocol" != "snell-shadowtls" && "$protocol" != "snell-v5-shadowtls" && "$protocol" != "ss2022-shadowtls" ]]; then
            if [[ "$protocol" == "socks" ]]; then
                local use_tls=$(echo "$cfg" | jq -r '.tls // "false"')
                local socks_sni=$(echo "$cfg" | jq -r '.sni // ""')
                local socks_link
                if [[ "$use_tls" == "true" ]]; then
                    socks_link="socks5://${username}:${password}@${ip_addr}:${link_port}?tls=true&sni=${socks_sni}#SOCKS5-TLS-${ip_addr}"
                else
                    socks_link="socks5://${username}:${password}@${ip_addr}:${link_port}#SOCKS5-${ip_addr}"
                fi
                echo -e "  ${C}分享链接:${NC}"
                echo -e "  ${G}$socks_link${NC}"
                echo ""
                echo -e "  ${C}二维码:${NC}"
                echo -e "  ${G}$(gen_qr "$socks_link")${NC}"
            else
                echo -e "  ${C}分享链接:${NC}"
                echo -e "  ${G}$link${NC}"
                echo ""
                echo -e "  ${C}二维码:${NC}"
                echo -e "  ${G}$(gen_qr "$link")${NC}"
            fi
        elif [[ "$SHOW_JOIN_CODE" != "on" ]]; then
            # ShadowTLS 协议且 JOIN 码关闭时，提示用户
            echo -e "  ${Y}提示: ShadowTLS 协议需要 JOIN 码才能配置客户端${NC}"
            echo -e "  ${D}如需显示 JOIN 码，请修改脚本头部 SHOW_JOIN_CODE=\"on\"${NC}"
            echo ""
        fi
    fi
    
    # IPv6 提示（仅双栈时显示，纯 IPv6 已经使用 IPv6 地址了）
    if [[ -n "$ipv4" && -n "$ipv6" ]]; then
        echo ""
        echo -e "  ${D}提示: 服务器支持 IPv6 ($ipv6)，如需使用请自行替换地址${NC}"
    fi
    
    # 自签名证书提示（VMess-WS、VLESS-WS、VLESS-Vision、Trojan、Trojan-WS、Hysteria2 使用自签名证书时）
    if [[ "$protocol" =~ ^(vmess-ws|vless-ws|vless-vision|trojan|trojan-ws|hy2)$ ]]; then
        # 检查是否是自签名证书（没有真实域名）
        local is_self_signed=true
        if [[ -f "$CFG/cert_domain" ]]; then
            local cert_domain=$(cat "$CFG/cert_domain")
            # 检查证书是否由 CA 签发
            if [[ -f "$CFG/certs/server.crt" ]]; then
                local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
                if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"ZeroSSL"* ]]; then
                    is_self_signed=false
                fi
            fi
        fi
        if [[ "$is_self_signed" == "true" ]]; then
            echo ""
            echo -e "  ${Y}⚠ 使用自签名证书，客户端需开启「跳过证书验证」或「允许不安全连接」${NC}"
        fi
    fi
    
    # Hysteria2 端口跳跃提示
    if [[ "$protocol" == "hy2" && "$hop_enable" == "1" ]]; then
        echo ""
        _line
        echo -e "  ${Y}⚠ 端口跳跃已启用${NC}"
        echo -e "  ${C}客户端请手动将端口改为: ${G}${hop_start}-${hop_end}${NC}"
        _line
    fi
    
    # 生成并显示订阅链接
    echo ""
    echo -e "  ${C}订阅链接:${NC}"
    
    local domain=""
    # 尝试获取域名
    if [[ -f "$CFG/cert_domain" ]]; then
        domain=$(cat "$CFG/cert_domain")
    fi
    
    # 检查Web服务状态
    local web_service_running=false
    local nginx_port=""
    
    # 检查是否有Reality协议（Reality 不需要 Nginx，不提供订阅服务）
    local has_reality=false
    if db_exists "xray" "vless" || db_exists "xray" "vless-xhttp"; then
        has_reality=true
        # Reality 协议不启用 Nginx，不设置 nginx_port
    fi
    
    # 检查是否有需要证书的协议（这些协议才需要 Nginx 订阅服务）
    local has_cert_protocol=false
    if db_exists "xray" "vless-ws" || db_exists "xray" "vless-vision" || db_exists "xray" "trojan"; then
        has_cert_protocol=true
        # 从 sub.info 读取实际配置的端口，否则使用默认 8443
        if [[ -f "$CFG/sub.info" ]]; then
            source "$CFG/sub.info"
            nginx_port="${sub_port:-8443}"
        else
            nginx_port="8443"
        fi
    fi
    
    # 判断Web服务是否运行 - 只有证书协议才检查
    if [[ -n "$nginx_port" ]]; then
        if ss -tlnp 2>/dev/null | grep -q ":${nginx_port} "; then
            web_service_running=true
        fi
    fi
    
    # 显示订阅链接提示
    if [[ "$has_cert_protocol" == "true" ]]; then
        # 有证书协议，显示订阅状态
        if [[ "$web_service_running" == "true" && -f "$CFG/sub.info" ]]; then
            source "$CFG/sub.info"
            local sub_protocol="http"
            [[ "$sub_https" == "true" ]] && sub_protocol="https"
            local base_url="${sub_protocol}://${sub_domain:-$ipv4}:${sub_port}/sub/${sub_uuid}"
            echo -e "  ${Y}Clash/Clash Verge:${NC}"
            echo -e "  ${G}$base_url/clash${NC}"
        elif [[ "$web_service_running" == "true" ]]; then
            echo -e "  ${Y}订阅服务未配置，请在主菜单选择「订阅管理」进行配置${NC}"
        else
            echo -e "  ${D}(Web服务未运行，订阅功能不可用)${NC}"
            echo -e "  ${D}提示: 请在主菜单选择「订阅管理」配置订阅服务${NC}"
        fi
    elif [[ "$has_reality" == "true" && ("$protocol" == "vless" || "$protocol" == "vless-xhttp") ]]; then
        # Reality 协议：订阅需要手动配置真实域名和启用
        if [[ -n "$domain" && -f "$CFG/sub.info" && "$web_service_running" == "true" ]]; then
            source "$CFG/sub.info"
            
            # Reality 真实域名模式时，检查订阅是否已手动启用
            if [[ "${sub_enabled:-false}" == "true" && -n "$sub_port" ]]; then
                local base_url="https://${sub_domain:-$domain}:${sub_port}/sub/${sub_uuid}"
                echo -e "  ${Y}Clash/Clash Verge:${NC}"
                echo -e "  ${G}$base_url/clash${NC}"
            else
                echo -e "  ${D}(订阅服务未启用，如需使用请在主菜单选择「订阅管理」)${NC}"
            fi
        else
            echo -e "  ${D}(直接使用分享链接即可)${NC}"
        fi
    else
        # Sing-box 协议 (hy2/tuic) 或其他协议
        echo -e "  ${D}(直接使用分享链接即可)${NC}"
    fi
    
    _line
    [[ "$clear_screen" == "true" ]] && _pause
}

# 管理协议服务
manage_protocol_services() {
    local installed=$(get_installed_protocols)
    [[ -z "$installed" ]] && { _warn "未安装任何协议"; return; }
    
    while true; do
        _header
        echo -e "  ${W}协议服务管理${NC}"
        _line
        show_protocols_overview  # 使用简洁概览
        
        _item "1" "重启所有服务"
        _item "2" "停止所有服务"
        _item "3" "启动所有服务"
        _item "4" "查看服务状态"
        _item "0" "返回"
        _line

        read -rp "  请选择: " choice
        case $choice in
            1)
                _info "重启所有服务..."
                stop_services; sleep 2; start_services && _ok "所有服务已重启"
                _pause
                ;;
            2)
                _info "停止所有服务..."
                stop_services; touch "$CFG/paused"; _ok "所有服务已停止"
                _pause
                ;;
            3)
                _info "启动所有服务..."
                start_services && _ok "所有服务已启动"
                _pause
                ;;
            4) show_services_status; _pause ;;
            0) return ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}

# 简洁的协议概览（用于服务管理页面）
show_protocols_overview() {
    local xray_protocols=$(get_xray_protocols)
    local singbox_protocols=$(get_singbox_protocols)
    local standalone_protocols=$(get_standalone_protocols)
    
    echo -e "  ${C}已安装协议概览${NC}"
    _line
    
    if [[ -n "$xray_protocols" ]]; then
        echo -e "  ${Y}Xray 协议 (共享服务):${NC}"
        for protocol in $xray_protocols; do
            # 获取所有端口实例
            local ports=$(db_list_ports "xray" "$protocol")
            if [[ -n "$ports" ]]; then
                local port_count=$(echo "$ports" | wc -l)
                if [[ $port_count -eq 1 ]]; then
                    # 单端口显示
                    echo -e "    ${G}●${NC} $(get_protocol_name $protocol) - 端口: ${G}$ports${NC}"
                else
                    # 多端口显示
                    echo -e "    ${G}●${NC} $(get_protocol_name $protocol) - 端口: ${G}$port_count 个实例${NC}"
                    echo "$ports" | while read -r port; do
                        echo -e "      ${C}├─${NC} 端口 ${G}$port${NC}"
                    done
                fi
            fi
        done
        echo ""
    fi
    
    if [[ -n "$singbox_protocols" ]]; then
        echo -e "  ${Y}Sing-box 协议 (共享服务):${NC}"
        for protocol in $singbox_protocols; do
            # 获取所有端口实例
            local ports=$(db_list_ports "singbox" "$protocol")
            if [[ -n "$ports" ]]; then
                local port_count=$(echo "$ports" | wc -l)
                if [[ $port_count -eq 1 ]]; then
                    # 单端口显示
                    echo -e "    ${G}●${NC} $(get_protocol_name $protocol) - 端口: ${G}$ports${NC}"
                else
                    # 多端口显示
                    echo -e "    ${G}●${NC} $(get_protocol_name $protocol) - 端口: ${G}$port_count 个实例${NC}"
                    echo "$ports" | while read -r port; do
                        echo -e "      ${C}├─${NC} 端口 ${G}$port${NC}"
                    done
                fi
            fi
        done
        echo ""
    fi
    
    if [[ -n "$standalone_protocols" ]]; then
        echo -e "  ${Y}独立协议 (独立服务):${NC}"
        for protocol in $standalone_protocols; do
            # 先从 xray 获取，如果为空再从 singbox 获取
            local port=$(db_get_field "xray" "$protocol" "port")
            [[ -z "$port" ]] && port=$(db_get_field "singbox" "$protocol" "port")
            [[ -n "$port" ]] && echo -e "    ${G}●${NC} $(get_protocol_name $protocol) - 端口: ${G}$port${NC}"
        done
        echo ""
    fi
    _line
}

# 显示服务状态
show_services_status() {
    _line
    echo -e "  ${C}服务状态${NC}"
    _line
    
    # Xray 服务状态 (TCP 协议)
    local xray_protocols=$(get_xray_protocols)
    if [[ -n "$xray_protocols" ]]; then
        if svc status vless-reality; then
            echo -e "  ${G}●${NC} Xray 服务 - ${G}运行中${NC}"
            for proto in $xray_protocols; do
                echo -e "      ${D}└${NC} $(get_protocol_name $proto)"
            done
        else
            echo -e "  ${R}●${NC} Xray 服务 - ${R}已停止${NC}"
        fi
    fi
    
    # Sing-box 服务状态 (UDP/QUIC 协议)
    local singbox_protocols=$(get_singbox_protocols)
    if [[ -n "$singbox_protocols" ]]; then
        if svc status vless-singbox 2>/dev/null; then
            echo -e "  ${G}●${NC} Sing-box 服务 - ${G}运行中${NC}"
            for proto in $singbox_protocols; do
                echo -e "      ${D}└${NC} $(get_protocol_name $proto)"
            done
        else
            echo -e "  ${R}●${NC} Sing-box 服务 - ${R}已停止${NC}"
        fi
    fi
    
    # 独立进程协议服务状态 (Snell 等)
    local standalone_protocols=$(get_standalone_protocols)
    for protocol in $standalone_protocols; do
        local service_name="vless-${protocol}"
        local proto_name=$(get_protocol_name $protocol)
        if svc status "$service_name" 2>/dev/null; then
            echo -e "  ${G}●${NC} $proto_name - ${G}运行中${NC}"
        else
            echo -e "  ${R}●${NC} $proto_name - ${R}已停止${NC}"
        fi
    done
    _line
}

# 选择要卸载的端口实例
# 参数: $1=protocol
# 返回: 选中的端口号，存储在 SELECTED_PORT 变量中
select_port_to_uninstall() {
    local protocol="$1"
    
    # 确定核心类型
    local core="xray"
    if [[ " $SINGBOX_PROTOCOLS " == *" $protocol "* ]]; then
        core="singbox"
    fi
    
    # 获取端口列表
    local ports=$(db_list_ports "$core" "$protocol")
    
    if [[ -z "$ports" ]]; then
        echo -e "${RED}错误: 未找到协议 $protocol 的端口实例${NC}"
        return 1
    fi
    
    # 转换为数组
    local port_array=($ports)
    local port_count=${#port_array[@]}
    
    # 只有一个端口，直接选择
    if [[ $port_count -eq 1 ]]; then
        SELECTED_PORT="${port_array[0]}"
        echo -e "${CYAN}检测到协议 $protocol 只有一个端口实例: $SELECTED_PORT${NC}"
        return 0
    fi
    
    # 多个端口，让用户选择
    echo ""
    echo -e "${CYAN}协议 ${YELLOW}$protocol${CYAN} 有以下端口实例：${NC}"
    echo ""
    
    local i=1
    for port in "${port_array[@]}"; do
        echo -e "  ${G}$i${NC}) 端口 ${G}$port${NC}"
        ((i++))
    done
    echo -e "  ${G}$i${NC}) 卸载所有端口"
    echo "  0) 返回"
    echo ""
    
    local choice
    read -p "$(echo -e "  ${GREEN}请选择要卸载的端口 [0-$i]:${NC} ")" choice
    
    if [[ "$choice" == "0" ]]; then
        echo -e "${YELLOW}已取消，返回上级菜单${NC}"
        return 1
    elif [[ "$choice" == "$i" ]]; then
        SELECTED_PORT="all"
        return 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
        SELECTED_PORT="${port_array[$((choice-1))]}"
        return 0
    else
        echo -e "${RED}无效选项${NC}"
        return 1
    fi
}

# 卸载指定协议
uninstall_specific_protocol() {
    local installed=$(get_installed_protocols)
    [[ -z "$installed" ]] && { _warn "未安装任何协议"; return; }
    
    _header
    echo -e "  ${W}卸载指定协议${NC}"
    _line
    
    echo -e "  ${Y}已安装的协议:${NC}"
    local i=1
    for protocol in $installed; do
        echo -e "    ${G}$i${NC}) $(get_protocol_name $protocol)"
        ((i++))
    done
    echo ""
    _item "0" "返回"
    _line
    
    read -rp "  选择要卸载的协议 [0-$((i-1))]: " choice
    [[ "$choice" == "0" ]] && return
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { _err "无效选择"; return; }
    
    local selected_protocol=$(echo "$installed" | sed -n "${choice}p")
    [[ -z "$selected_protocol" ]] && { _err "协议不存在"; return; }
    
    # 选择要卸载的端口
    select_port_to_uninstall "$selected_protocol" || return 1
    
    # 确定核心类型
    local core="xray"
    if [[ " $SINGBOX_PROTOCOLS " == *" $selected_protocol "* ]]; then
        core="singbox"
    elif [[ " $STANDALONE_PROTOCOLS " == *" $selected_protocol "* ]]; then
        core="standalone"
    fi
    
    echo -e "  将卸载: ${R}$(get_protocol_name $selected_protocol)${NC}"
    read -rp "  确认卸载? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && return
    
    _info "卸载 $selected_protocol..."
    
    # 停止相关服务
    if [[ " $XRAY_PROTOCOLS " == *" $selected_protocol "* ]]; then
        # Xray 协议：需要重新生成配置
        # 根据选择的端口进行卸载
        if [[ "$SELECTED_PORT" == "all" ]]; then
            echo -e "${CYAN}卸载协议 $selected_protocol 的所有端口实例...${NC}"
            unregister_protocol "$selected_protocol"
            rm -f "$CFG/${selected_protocol}.join"
        else
            echo -e "${CYAN}卸载协议 $selected_protocol 的端口 $SELECTED_PORT...${NC}"
            
            # 删除指定端口实例
            if [[ "$core" != "standalone" ]]; then
                db_remove_port "$core" "$selected_protocol" "$SELECTED_PORT"
                
                # 检查是否还有其他端口实例
                local remaining_ports=$(db_list_ports "$core" "$selected_protocol")
                if [[ -z "$remaining_ports" ]]; then
                    # 没有剩余端口，完全卸载
                    echo -e "${YELLOW}这是最后一个端口实例，将完全卸载协议${NC}"
                    db_del "$core" "$selected_protocol"
                    rm -f "$CFG/${selected_protocol}.join"
                else
                    echo -e "${GREEN}协议 $selected_protocol 还有其他端口实例在运行${NC}"
                fi
            else
                # 独立协议不支持多端口，直接卸载
                unregister_protocol "$selected_protocol"
                rm -f "$CFG/${selected_protocol}.join"
            fi
        fi
        
        # 检查是否还有其他 Xray 协议
        local remaining_xray=$(get_xray_protocols)
        if [[ -n "$remaining_xray" ]]; then
            _info "重新生成 Xray 配置..."
            svc stop vless-reality 2>/dev/null
            rm -f "$CFG/config.json"
            
            if generate_xray_config; then
                _ok "Xray 配置已更新"
                svc start vless-reality
            else
                _err "Xray 配置生成失败"
            fi
        else
            _info "没有其他 Xray 协议，停止 Xray 服务..."
            svc stop vless-reality 2>/dev/null
            rm -f "$CFG/config.json"
            _ok "Xray 服务已停止"
        fi
    elif [[ " $SINGBOX_PROTOCOLS " == *" $selected_protocol "* ]]; then
        # Sing-box 协议 (hy2/tuic)：需要重新生成配置
        
        # Hysteria2: 先清理 iptables 端口跳跃规则
        if [[ "$selected_protocol" == "hy2" ]]; then
            cleanup_hy2_nat_rules
            rm -rf "$CFG/certs/hy2"
        fi
        
        # TUIC: 先清理 iptables 端口跳跃规则，删除证书目录
        if [[ "$selected_protocol" == "tuic" ]]; then
            cleanup_hy2_nat_rules
            rm -rf "$CFG/certs/tuic"
        fi
        
        # 根据选择的端口进行卸载
        if [[ "$SELECTED_PORT" == "all" ]]; then
            echo -e "${CYAN}卸载协议 $selected_protocol 的所有端口实例...${NC}"
            unregister_protocol "$selected_protocol"
            rm -f "$CFG/${selected_protocol}.join"
        else
            echo -e "${CYAN}卸载协议 $selected_protocol 的端口 $SELECTED_PORT...${NC}"
            
            # 删除指定端口实例
            if [[ "$core" != "standalone" ]]; then
                db_remove_port "$core" "$selected_protocol" "$SELECTED_PORT"
                
                # 检查是否还有其他端口实例
                local remaining_ports=$(db_list_ports "$core" "$selected_protocol")
                if [[ -z "$remaining_ports" ]]; then
                    # 没有剩余端口，完全卸载
                    echo -e "${YELLOW}这是最后一个端口实例，将完全卸载协议${NC}"
                    db_del "$core" "$selected_protocol"
                    rm -f "$CFG/${selected_protocol}.join"
                else
                    echo -e "${GREEN}协议 $selected_protocol 还有其他端口实例在运行${NC}"
                fi
            else
                # 独立协议不支持多端口，直接卸载
                unregister_protocol "$selected_protocol"
                rm -f "$CFG/${selected_protocol}.join"
            fi
        fi
        
        # 检查是否还有其他 Sing-box 协议
        local remaining_singbox=$(get_singbox_protocols)
        if [[ -n "$remaining_singbox" ]]; then
            _info "重新生成 Sing-box 配置..."
            svc stop vless-singbox 2>/dev/null
            rm -f "$CFG/singbox.json"
            
            if generate_singbox_config; then
                _ok "Sing-box 配置已更新"
                svc start vless-singbox
            else
                _err "Sing-box 配置生成失败"
            fi
        else
            _info "没有其他 Sing-box 协议，停止 Sing-box 服务..."
            svc stop vless-singbox 2>/dev/null
            svc disable vless-singbox 2>/dev/null
            rm -f "$CFG/singbox.json"
            # 删除 Sing-box 服务文件
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-update del vless-singbox default 2>/dev/null
                rm -f "/etc/init.d/vless-singbox"
            else
                rm -f "/etc/systemd/system/vless-singbox.service"
                systemctl daemon-reload
            fi
            _ok "Sing-box 服务已停止"
        fi
    else
        # 独立协议 (Snell/AnyTLS/ShadowTLS)：停止服务，删除配置和服务文件
        local service_name="vless-${selected_protocol}"
        
        # 停止主服务
        svc stop "$service_name" 2>/dev/null
        
        # ShadowTLS 组合协议：还需要停止后端服务
        if [[ "$selected_protocol" == "snell-shadowtls" || "$selected_protocol" == "snell-v5-shadowtls" || "$selected_protocol" == "ss2022-shadowtls" ]]; then
            local backend_svc="${BACKEND_NAME[$selected_protocol]}"
            [[ -n "$backend_svc" ]] && svc stop "$backend_svc" 2>/dev/null
        fi
        
        # 根据选择的端口进行卸载
        if [[ "$SELECTED_PORT" == "all" ]]; then
            echo -e "${CYAN}卸载协议 $selected_protocol 的所有端口实例...${NC}"
            unregister_protocol "$selected_protocol"
            rm -f "$CFG/${selected_protocol}.join"
        else
            echo -e "${CYAN}卸载协议 $selected_protocol 的端口 $SELECTED_PORT...${NC}"
            
            # 删除指定端口实例
            if [[ "$core" != "standalone" ]]; then
                db_remove_port "$core" "$selected_protocol" "$SELECTED_PORT"
                
                # 检查是否还有其他端口实例
                local remaining_ports=$(db_list_ports "$core" "$selected_protocol")
                if [[ -z "$remaining_ports" ]]; then
                    # 没有剩余端口，完全卸载
                    echo -e "${YELLOW}这是最后一个端口实例，将完全卸载协议${NC}"
                    db_del "$core" "$selected_protocol"
                    rm -f "$CFG/${selected_protocol}.join"
                else
                    echo -e "${GREEN}协议 $selected_protocol 还有其他端口实例在运行${NC}"
                fi
            else
                # 独立协议不支持多端口，直接卸载
                unregister_protocol "$selected_protocol"
                rm -f "$CFG/${selected_protocol}.join"
            fi
        fi
        
        # 删除配置文件
        case "$selected_protocol" in
            snell) rm -f "$CFG/snell.conf" ;;
            snell-v5) rm -f "$CFG/snell-v5.conf" ;;
            snell-shadowtls) rm -f "$CFG/snell-shadowtls.conf" ;;
            snell-v5-shadowtls) rm -f "$CFG/snell-v5-shadowtls.conf" ;;
            ss2022-shadowtls) rm -f "$CFG/ss2022-shadowtls-backend.json" ;;
        esac
        
        # 删除服务文件
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-update del "$service_name" default 2>/dev/null
            rm -f "/etc/init.d/$service_name"
            # ShadowTLS 后端服务
            if [[ -n "${BACKEND_NAME[$selected_protocol]:-}" ]]; then
                rc-update del "${BACKEND_NAME[$selected_protocol]}" default 2>/dev/null
                rm -f "/etc/init.d/${BACKEND_NAME[$selected_protocol]}"
            fi
        else
            systemctl disable "$service_name" 2>/dev/null
            rm -f "/etc/systemd/system/${service_name}.service"
            # ShadowTLS 后端服务
            if [[ -n "${BACKEND_NAME[$selected_protocol]:-}" ]]; then
                systemctl disable "${BACKEND_NAME[$selected_protocol]}" 2>/dev/null
                rm -f "/etc/systemd/system/${BACKEND_NAME[$selected_protocol]}.service"
            fi
            systemctl daemon-reload
        fi
    fi
    
    # 检查是否还有需要订阅服务的协议
    local has_sub_protocol=false
    for proto in vless-ws vless-vision trojan vmess-ws; do
        if is_protocol_installed "$proto"; then
            has_sub_protocol=true
            break
        fi
    done
    
    # 如果没有需要订阅的协议了，清理订阅相关配置
    if [[ "$has_sub_protocol" == "false" ]]; then
        _info "清理订阅服务..."
        # 停止并删除 Nginx 订阅配置 (包括 Alpine 的 http.d 目录)
        rm -f /etc/nginx/conf.d/vless-sub.conf /etc/nginx/http.d/vless-sub.conf
        rm -f /etc/nginx/conf.d/vless-fake.conf /etc/nginx/http.d/vless-fake.conf
        nginx -s reload 2>/dev/null
        # 清理订阅目录和配置
        rm -rf "$CFG/subscription"
        rm -f "$CFG/sub.info"
        rm -f "$CFG/sub_uuid"
        _ok "订阅服务已清理"
    else
        # 还有其他协议，检查订阅服务是否已配置
        if [[ -f "$CFG/sub.info" ]] || [[ -d "$CFG/subscription" ]]; then
            _info "更新订阅文件..."
            generate_sub_files
        fi
    fi
    _ok "$selected_protocol 已卸载"
    _pause
}

#═══════════════════════════════════════════════════════════════════════════════
# 信息显示与卸载
#═══════════════════════════════════════════════════════════════════════════════

show_server_info() {
    [[ "$(get_role)" != "server" ]] && return
    
    # 多协议模式：显示所有协议的配置
    local installed=$(get_installed_protocols)
    local protocol_count=$(echo "$installed" | wc -w)
    
    if [[ $protocol_count -eq 1 ]]; then
        # 单协议：直接显示详细信息
        show_single_protocol_info "$installed"
    else
        # 多协议：显示协议列表供选择
        show_all_protocols_info
    fi
}

do_uninstall() {
    check_installed || { _warn "未安装"; return; }
    read -rp "  确认卸载? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && return

    local installed_protocols=""
    installed_protocols=$(get_installed_protocols 2>/dev/null || true)
    local has_naive=false
    if grep -qx "naive" <<<"$installed_protocols" || [[ -f "$CFG/naive.join" ]] || [[ -f "$CFG/Caddyfile" ]]; then
        has_naive=true
    fi
    
    _info "停止所有服务..."
    stop_services
    
    # 卸载 WARP (如果已安装)
    local warp_st=$(warp_status 2>/dev/null)
    if [[ "$warp_st" == "configured" || "$warp_st" == "connected" ]] || check_cmd warp-cli; then
        _info "卸载 WARP..."
        local warp_mode=$(db_get_warp_mode 2>/dev/null)
        if [[ "$warp_mode" == "official" ]] || check_cmd warp-cli; then
            # 卸载官方客户端
            warp-cli disconnect 2>/dev/null
            systemctl stop warp-svc 2>/dev/null
            systemctl disable warp-svc 2>/dev/null
            if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
                apt-get remove -y cloudflare-warp 2>/dev/null
                apt-get autoremove -y 2>/dev/null
                rm -f /etc/apt/sources.list.d/cloudflare-client.list
                rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            elif [[ "$DISTRO" == "centos" ]]; then
                yum remove -y cloudflare-warp 2>/dev/null
                rm -f /etc/yum.repos.d/cloudflare-warp.repo
            fi
        fi
        # 清理 WGCF 相关文件
        rm -f "$CFG/warp.json" 2>/dev/null
        rm -f /usr/local/bin/wgcf 2>/dev/null
        rm -f ~/.wgcf-account.toml 2>/dev/null
        # 清理分流配置
        db_clear_routing_rules 2>/dev/null
        _ok "WARP 已卸载"
    fi
    
    # 清理伪装网页服务和订阅文件
    local cleaned_items=()
    
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fake-web 2>/dev/null; then
        systemctl stop fake-web 2>/dev/null
        systemctl disable fake-web 2>/dev/null
        rm -f /etc/systemd/system/fake-web.service
        systemctl daemon-reload 2>/dev/null
        cleaned_items+=("fake-web服务")
    fi
    
    # 清理所有脚本生成的 Nginx 配置
    local nginx_cleaned=false
    
    # 删除 sites-available/enabled 配置 (包括 vless-* 和 xhttp-cdn)
    for cfg in /etc/nginx/sites-enabled/vless-* /etc/nginx/sites-available/vless-* \
               /etc/nginx/sites-enabled/xhttp-cdn /etc/nginx/sites-available/xhttp-cdn; do
        [[ -f "$cfg" || -L "$cfg" ]] && { rm -f "$cfg"; nginx_cleaned=true; }
    done
    
    # 删除 conf.d 配置 (Debian/Ubuntu/CentOS)
    for cfg in /etc/nginx/conf.d/vless-*.conf /etc/nginx/conf.d/xhttp-cdn.conf; do
        [[ -f "$cfg" ]] && { rm -f "$cfg"; nginx_cleaned=true; }
    done
    
    # 删除 http.d 配置 (Alpine)
    for cfg in /etc/nginx/http.d/vless-*.conf /etc/nginx/http.d/xhttp-cdn.conf; do
        [[ -f "$cfg" ]] && { rm -f "$cfg"; nginx_cleaned=true; }
    done
    
    # 检查是否还有其他站点使用 Nginx
    local nginx_has_other_sites=false
    if command -v nginx &>/dev/null; then
        # 检查是否有非默认的用户配置
        local other_configs=$(find /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/http.d \
            -type f -o -type l 2>/dev/null | grep -v default | wc -l)
        [[ "$other_configs" -gt 0 ]] && nginx_has_other_sites=true
    fi
    
    # 如果清理了配置
    if [[ "$nginx_cleaned" == "true" ]]; then
        if [[ "$nginx_has_other_sites" == "true" ]]; then
            # 还有其他站点，仅重载
            if nginx -t 2>/dev/null; then
                svc reload nginx 2>/dev/null || svc restart nginx 2>/dev/null
                cleaned_items+=("Nginx配置")
            fi
        else
            # 没有其他站点，停止并禁用 Nginx
            _info "停止 Nginx 服务..."
            svc stop nginx 2>/dev/null
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-update del nginx default 2>/dev/null
            else
                systemctl disable nginx 2>/dev/null
            fi
            cleaned_items+=("Nginx服务")
        fi
    fi
    
    # 显示清理结果
    if [[ ${#cleaned_items[@]} -gt 0 ]]; then
        echo "  ▸ 已清理: ${cleaned_items[*]}"
    fi
    
    # 清理网页文件
    rm -rf /var/www/html/index.html 2>/dev/null
    
    # 强力清理残留进程
    force_cleanup
    
    _info "删除服务文件..."
    if [[ "$DISTRO" == "alpine" ]]; then
        # Alpine: 删除所有 vless 相关的 OpenRC 服务
        for svc_file in /etc/init.d/vless-*; do
            [[ -f "$svc_file" ]] && {
                local svc_name=$(basename "$svc_file")
                rc-update del "$svc_name" default 2>/dev/null
                rm -f "$svc_file"
            }
        done
    else
        # Debian/Ubuntu/CentOS: 删除所有 vless 相关的 systemd 服务
        systemctl stop 'vless-*' 2>/dev/null
        systemctl disable 'vless-*' 2>/dev/null
        rm -f /etc/systemd/system/vless-*.service
        systemctl daemon-reload
    fi
    
    _info "删除配置目录..."
    
    # 保留证书目录和域名记录，避免重复申请
    local cert_backup_dir="/tmp/vless-certs-backup"
    if [[ -d "$CFG/certs" ]]; then
        _info "备份证书文件..."
        mkdir -p "$cert_backup_dir"
        cp -r "$CFG/certs" "$cert_backup_dir/" 2>/dev/null
        [[ -f "$CFG/cert_domain" ]] && cp "$CFG/cert_domain" "$cert_backup_dir/" 2>/dev/null
    fi
    
    # 删除配置目录（但保留证书）
    find "$CFG" -name "*.json" -delete 2>/dev/null
    find "$CFG" -name "*.join" -delete 2>/dev/null
    find "$CFG" -name "*.yaml" -delete 2>/dev/null
    find "$CFG" -name "*.conf" -delete 2>/dev/null
    rm -f "$CFG/installed_protocols" 2>/dev/null
    
    # 如果没有证书，删除整个目录
    if [[ ! -d "$CFG/certs" ]]; then
        rm -rf "$CFG"
    else
        _ok "证书已保留，配置文件已清理，下次安装将自动复用证书"
    fi
    
    _info "删除快捷命令..."
    rm -f /usr/local/bin/vless /usr/local/bin/vless.sh /usr/local/bin/vless-server.sh /usr/bin/vless 2>/dev/null
    
    # 清理 Caddy（如果存在）
    # 支持 NaïveProxy 自定义编译版本和标准版本
    if [[ -f "/usr/local/bin/caddy" ]]; then
        _info "清理 Caddy 二进制文件..."
        # 先停止可能存在的 Caddy 进程
        pkill -9 caddy 2>/dev/null
        # 删除二进制文件
        rm -f /usr/local/bin/caddy 2>/dev/null
        _ok "Caddy 已删除"
    fi
    
    _ok "卸载完成"
    echo ""
    echo -e "  ${Y}已保留的内容:${NC}"
    echo -e "  • 软件包: xray, sing-box, snell-server"
    echo -e "  • 软件包: anytls-server, shadow-tls, caddy"
    echo -e "  • ${G}域名证书: 下次安装将自动复用，无需重新申请${NC}"
    echo ""
    echo -e "  ${C}如需完全删除软件包，请执行:${NC}"
    echo -e "  ${G}rm -f /usr/local/bin/{xray,sing-box,snell-server*,anytls-*,shadow-tls,caddy}${NC}"
    echo ""
    echo -e "  ${C}如需删除证书，请执行:${NC}"
    echo -e "  ${G}rm -rf $CFG/certs $CFG/cert_domain${NC}"
    echo ""
    echo -e "  ${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${R}如需完全卸载并删除所有配置文件:${NC}"
    echo -e "  ${Y}所有配置文件位于: ${G}$CFG${NC}"
    echo -e "  ${Y}执行以下命令完全删除:${NC}"
    echo -e "  ${G}rm -rf $CFG${NC}"
    echo -e "  ${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

#═══════════════════════════════════════════════════════════════════════════════
# 协议安装流程
#═══════════════════════════════════════════════════════════════════════════════

# 协议选择菜单
select_protocol() {
    echo ""
    _line
    echo -e "  ${W}选择代理协议${NC}"
    _line
    _item "1" "VLESS + Reality ${D}(推荐, 抗封锁)${NC}"
    _item "2" "VLESS + Reality + XHTTP ${D}(多路复用)${NC}"
    _item "3" "VLESS + WS + TLS ${D}(CDN友好, 可作回落)${NC}"
    _item "4" "VMess + WS ${D}(回落分流/免流)${NC}"
    _item "5" "VLESS-XTLS-Vision ${D}(支持回落)${NC}"
    _item "6" "Trojan ${D}(支持回落)${NC}"
    _item "7" "Hysteria2 ${D}(UDP高速)${NC}"
    _item "8" "Shadowsocks"
    _item "9" "SOCKS5"
    _line
    echo -e "  ${W}Surge 专属${NC}"
    _line
    _item "10" "Snell v4"
    _item "11" "Snell v5"
    _line
    echo -e "  ${W}其他协议${NC}"
    _line
    _item "12" "AnyTLS"
    _item "13" "TUIC v5"
    _item "14" "NaïveProxy"
    _item "0" "返回"
    echo ""
    echo -e "  ${D}提示: 5/6 使用 8443 端口时，3/4 可作为回落共用${NC}"
    echo ""
    
    while true; do
        read -rp "  选择协议 [0-14]: " choice
        case $choice in
            0) SELECTED_PROTOCOL=""; return 1 ;;
            1) SELECTED_PROTOCOL="vless"; break ;;
            2) SELECTED_PROTOCOL="vless-xhttp"; break ;;
            3) SELECTED_PROTOCOL="vless-ws"; break ;;
            4) SELECTED_PROTOCOL="vmess-ws"; break ;;
            5) SELECTED_PROTOCOL="vless-vision"; break ;;
            6) SELECTED_PROTOCOL="trojan"; break ;;
            7) SELECTED_PROTOCOL="hy2"; break ;;
            8) select_ss_version || return 1; break ;;
            9) SELECTED_PROTOCOL="socks"; break ;;
            10) SELECTED_PROTOCOL="snell"; break ;;
            11) SELECTED_PROTOCOL="snell-v5"; break ;;
            12) SELECTED_PROTOCOL="anytls"; break ;;
            13) SELECTED_PROTOCOL="tuic"; break ;;
            14) SELECTED_PROTOCOL="naive"; break ;;
            *) _err "无效选择" ;;
        esac
    done
}

# Shadowsocks 版本选择子菜单
select_ss_version() {
    echo ""
    _line
    echo -e "  ${W}选择 Shadowsocks 版本${NC}"
    _line
    _item "1" "SS2022 ${D}(新版加密, 需时间同步)${NC}"
    _item "2" "SS 传统版 ${D}(兼容性好, 无时间校验)${NC}"
    _item "0" "返回"
    echo ""
    
    while true; do
        read -rp "  选择版本 [0-2]: " ss_choice
        case $ss_choice in
            1) SELECTED_PROTOCOL="ss2022"; return 0 ;;
            2) SELECTED_PROTOCOL="ss-legacy"; return 0 ;;
            0) SELECTED_PROTOCOL=""; return 1 ;;
            *) _err "无效选择" ;;
        esac
    done
}

do_install_server() {
    # check_installed && { _warn "已安装，请先卸载"; return; }
    _header
    echo -e "  ${W}服务端安装向导${NC}"
    echo -e "  系统: ${C}$DISTRO${NC}"
    
    # 选择协议
    select_protocol || return 1
    local protocol="$SELECTED_PROTOCOL"
    
    # 检查协议是否为空（用户选择返回）
    [[ -z "$protocol" ]] && return 1
    
    # 确定核心类型
    local core="xray"
    if [[ " $SINGBOX_PROTOCOLS " == *" $protocol "* ]]; then
        core="singbox"
    elif [[ " $STANDALONE_PROTOCOLS " == *" $protocol "* ]]; then
        core="standalone"
    fi
    
    # 检查该协议是否已安装
    if is_protocol_installed "$protocol"; then
        # 处理已安装协议的多端口选择
        if [[ "$core" != "standalone" ]]; then
            handle_existing_protocol "$protocol" "$core" || return 1
        else
            # 独立协议保持原有的重新安装确认
            echo -e "${YELLOW}检测到 $protocol 已安装，将清理旧配置...${NC}"
            read -rp "  是否重新安装? [y/N]: " reinstall
            [[ "$reinstall" =~ ^[yY]$ ]] || return
            _info "卸载现有 $protocol 协议..."
            
            # 独立协议 (Snell/AnyTLS/ShadowTLS)：停止服务，删除配置和服务文件
            local service_name="vless-${protocol}"
            
            # 停止主服务
            svc stop "$service_name" 2>/dev/null
            
            # ShadowTLS 组合协议：还需要停止后端服务
            if [[ "$protocol" == "snell-shadowtls" || "$protocol" == "snell-v5-shadowtls" || "$protocol" == "ss2022-shadowtls" ]]; then
                local backend_svc="${BACKEND_NAME[$protocol]}"
                [[ -n "$backend_svc" ]] && svc stop "$backend_svc" 2>/dev/null
            fi
            
            unregister_protocol "$protocol"
            rm -f "$CFG/${protocol}.join"
            
            # 删除配置文件
            case "$protocol" in
                snell) rm -f "$CFG/snell.conf" ;;
                snell-v5) rm -f "$CFG/snell-v5.conf" ;;
                snell-shadowtls) rm -f "$CFG/snell-shadowtls.conf" ;;
                snell-v5-shadowtls) rm -f "$CFG/snell-v5-shadowtls.conf" ;;
                ss2022-shadowtls) rm -f "$CFG/ss2022-shadowtls-backend.json" ;;
            esac
            
            # 删除服务文件
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-update del "$service_name" default 2>/dev/null
                rm -f "/etc/init.d/$service_name"
                # ShadowTLS 后端服务
                if [[ -n "${BACKEND_NAME[$protocol]:-}" ]]; then
                    rc-update del "${BACKEND_NAME[$protocol]}" default 2>/dev/null
                    rm -f "/etc/init.d/${BACKEND_NAME[$protocol]}"
                fi
            else
                systemctl disable "$service_name" 2>/dev/null
                rm -f "/etc/systemd/system/${service_name}.service"
                # ShadowTLS 后端服务
                if [[ -n "${BACKEND_NAME[$protocol]:-}" ]]; then
                    systemctl disable "${BACKEND_NAME[$protocol]}" 2>/dev/null
                    rm -f "/etc/systemd/system/${BACKEND_NAME[$protocol]}.service"
                fi
                systemctl daemon-reload
            fi
            
            _ok "旧配置已清理"
        fi
    fi
    
    # 只有 SS2022 需要时间同步
    if [[ "$protocol" == "ss2022" || "$protocol" == "ss2022-shadowtls" ]]; then
        sync_time
    fi

    # 检测并安装基础依赖
    _info "检测基础依赖..."
    check_dependencies || { _err "依赖检测失败"; _pause; return 1; }

    # 确保系统支持双栈监听（IPv4 + IPv6）
    ensure_dual_stack_listen

    _info "检测网络环境..."
    local ipv4=$(get_ipv4) ipv6=$(get_ipv6)
    echo -e "  IPv4: ${ipv4:-${R}无${NC}}"
    echo -e "  IPv6: ${ipv6:-${R}无${NC}}"
    [[ -z "$ipv4" && -z "$ipv6" ]] && { _err "无法获取公网IP"; _pause; return 1; }
    echo ""

    # === 主协议冲突检测 ===
    # Vision 和 Trojan 都是 443 端口主协议，不能同时安装
    local master_protocols="vless-vision trojan"
    if echo "$master_protocols" | grep -qw "$protocol"; then
        local existing_master=""
        local existing_master_name=""
        
        if [[ "$protocol" == "vless-vision" ]] && db_exists "xray" "trojan"; then
            existing_master="trojan"
            existing_master_name="Trojan"
        elif [[ "$protocol" == "trojan" ]] && db_exists "xray" "vless-vision"; then
            existing_master="vless-vision"
            existing_master_name="VLESS-XTLS-Vision"
        fi
        
        if [[ -n "$existing_master" ]]; then
            echo ""
            _warn "检测到已安装 $existing_master_name (443端口主协议)"
            echo ""
            echo -e "  ${Y}$existing_master_name 和 $(get_protocol_name $protocol) 都需要 443 端口${NC}"
            echo -e "  ${Y}它们不能同时作为主协议运行${NC}"
            echo ""
            echo -e "  ${W}选项：${NC}"
            echo -e "  1) 卸载 $existing_master_name，安装 $(get_protocol_name $protocol)"
            echo -e "  2) 使用其他端口安装 $(get_protocol_name $protocol) (非标准端口)"
            echo -e "  3) 取消安装"
            echo ""
            
            while true; do
                read -rp "  请选择 [1-3]: " master_choice
                case "$master_choice" in
                    1)
                        _info "卸载 $existing_master_name..."
                        unregister_protocol "$existing_master"
                        rm -f "$CFG/${existing_master}.join"
                        # 重新生成 Xray 配置
                        local remaining_xray=$(get_xray_protocols)
                        if [[ -n "$remaining_xray" ]]; then
                            svc stop vless-reality 2>/dev/null
                            rm -f "$CFG/config.json"
                            generate_xray_config
                            svc start vless-reality 2>/dev/null
                        else
                            svc stop vless-reality 2>/dev/null
                            rm -f "$CFG/config.json"
                        fi
                        _ok "$existing_master_name 已卸载"
                        break
                        ;;
                    2)
                        _warn "将使用非 443 端口，可能影响伪装效果"
                        break
                        ;;
                    3)
                        _info "已取消安装"
                        return
                        ;;
                    *)
                        _err "无效选择"
                        ;;
                esac
            done
        fi
    fi

    install_deps || { _err "依赖安装失败"; _pause; return 1; }
    
    # 根据协议安装对应软件
    case "$protocol" in
        vless|vless-xhttp|vless-ws|vless-ws-notls|vmess-ws|vless-vision|ss2022|ss-legacy|trojan|socks)
            install_xray || { _err "Xray 安装失败"; _pause; return 1; }
            ;;
        hy2|tuic)
            install_singbox || { _err "Sing-box 安装失败"; _pause; return 1; }
            ;;
        snell)
            install_snell || { _err "Snell 安装失败"; _pause; return 1; }
            ;;
        snell-v5)
            install_snell_v5 || { _err "Snell v5 安装失败"; _pause; return 1; }
            ;;
        snell-shadowtls)
            install_snell || { _err "Snell 安装失败"; _pause; return 1; }
            install_shadowtls || { _err "ShadowTLS 安装失败"; _pause; return 1; }
            ;;
        snell-v5-shadowtls)
            install_snell_v5 || { _err "Snell v5 安装失败"; _pause; return 1; }
            install_shadowtls || { _err "ShadowTLS 安装失败"; _pause; return 1; }
            ;;
        ss2022-shadowtls)
            install_xray || { _err "Xray 安装失败"; _pause; return 1; }
            install_shadowtls || { _err "ShadowTLS 安装失败"; _pause; return 1; }
            ;;
        anytls)
            install_anytls || { _err "AnyTLS 安装失败"; _pause; return 1; }
            ;;
        naive)
            install_naive || { _err "NaïveProxy 安装失败"; _pause; return 1; }
            ;;
    esac

    _info "生成配置参数..."
    
    # ===== 对于 Snell/SS2022，先询问是否启用 ShadowTLS =====
    local skip_port_ask=false
    if [[ "$protocol" == "snell" || "$protocol" == "snell-v5" || "$protocol" == "ss2022" ]]; then
        echo ""
        _line
        echo -e "  ${W}ShadowTLS 插件${NC}"
        _line
        echo -e "  ${D}Surge 用户通常建议直接使用 Snell。${NC}"
        echo -e "  ${D}但在高阻断环境下，您可能需要 ShadowTLS 伪装。${NC}"
        echo ""
        read -rp "  是否启用 ShadowTLS (v3) 插件? [y/N]: " enable_stls_pre
        
        if [[ "$enable_stls_pre" =~ ^[yY]$ ]]; then
            skip_port_ask=true  # 启用 ShadowTLS 时跳过第一次端口询问
        fi
    fi
    
    # 使用新的智能端口选择（ShadowTLS 模式下跳过）
    local port
    if [[ "$skip_port_ask" == "false" ]]; then
        port=$(ask_port "$protocol")
        if [[ $? -ne 0 || -z "$port" ]]; then
            _warn "已取消端口配置"
            return 1
        fi
    fi
    
    case "$protocol" in
        vless)
            local uuid=$(gen_uuid) sid=$(gen_sid)
            local keys=$(xray x25519 2>/dev/null)
            [[ -z "$keys" ]] && { _err "密钥生成失败"; _pause; return 1; }
            local privkey=$(echo "$keys" | grep "PrivateKey:" | awk '{print $2}')
            local pubkey=$(echo "$keys" | grep "Password:" | awk '{print $2}')
            [[ -z "$privkey" || -z "$pubkey" ]] && { _err "密钥提取失败"; _pause; return 1; }
            
            # 使用统一的证书和 Nginx 配置函数
            setup_cert_and_nginx "vless"
            local cert_domain="$CERT_DOMAIN"
            
            # 询问SNI配置
            local final_sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")
            
            # 如果没有真实域名，用选择的 SNI 重新生成自签证书
            if [[ -z "$cert_domain" ]]; then
                gen_self_cert "$final_sni"
            fi
            
            echo ""
            _line
            echo -e "  ${C}VLESS+Reality 配置${NC}"
            _line
            echo -e "  端口: ${G}$port${NC}  UUID: ${G}${uuid:0:8}...${NC}"
            echo -e "  SNI: ${G}$final_sni${NC}  ShortID: ${G}$sid${NC}"
            # Reality 真实域名模式时，订阅走 Reality 端口，不显示 Nginx 端口
            if [[ -n "$CERT_DOMAIN" && "$final_sni" == "$CERT_DOMAIN" ]]; then
                echo -e "  ${D}(订阅通过 Reality 端口访问)${NC}"
            fi
            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return
            
            _info "生成配置..."
            gen_server_config "$uuid" "$port" "$privkey" "$pubkey" "$sid" "$final_sni"
            ;;
        vless-xhttp)
            # 选择 XHTTP 模式
            echo ""
            _line
            echo -e "  ${W}选择 XHTTP 模式${NC}"
            _line
            echo -e "  ${G}1${NC}) Reality 模式 (伪装TLS，直连使用)"
            echo -e "  ${G}2${NC}) TLS+CDN 模式 (真实证书，可过Cloudflare CDN)"
            echo -e "  ${G}0${NC}) 取消"
            echo ""
            local xhttp_mode=""
            read -rp "  请选择 [1]: " xhttp_mode_choice
            xhttp_mode_choice="${xhttp_mode_choice:-1}"
            
            case "$xhttp_mode_choice" in
                1) xhttp_mode="reality" ;;
                2) xhttp_mode="tls-cdn" ;;
                0) return 0 ;;
                *) _err "无效选择"; return 1 ;;
            esac
            
            local uuid=$(gen_uuid) path="$(gen_xhttp_path)"
            
            if [[ "$xhttp_mode" == "reality" ]]; then
                # Reality 模式
                local sid=$(gen_sid)
                local keys=$(xray x25519 2>/dev/null)
                [[ -z "$keys" ]] && { _err "密钥生成失败"; _pause; return 1; }
                local privkey=$(echo "$keys" | grep "PrivateKey:" | awk '{print $2}')
                local pubkey=$(echo "$keys" | grep "Password:" | awk '{print $2}')
                [[ -z "$privkey" || -z "$pubkey" ]] && { _err "密钥提取失败"; _pause; return 1; }
                
                # 使用统一的证书和 Nginx 配置函数
                setup_cert_and_nginx "vless-xhttp"
                local cert_domain="$CERT_DOMAIN"
                
                # 询问SNI配置
                local final_sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")
                
                echo ""
                _line
                echo -e "  ${C}VLESS+Reality+XHTTP 配置${NC}"
                _line
                echo -e "  端口: ${G}$port${NC}  UUID: ${G}${uuid:0:8}...${NC}"
                echo -e "  SNI: ${G}$final_sni${NC}  ShortID: ${G}$sid${NC}"
                echo -e "  Path: ${G}$path${NC}"
                # Reality 真实域名模式时，订阅走 Reality 端口，不显示 Nginx 端口
                if [[ -n "$CERT_DOMAIN" && "$final_sni" == "$CERT_DOMAIN" ]]; then
                    echo -e "  ${D}(订阅通过 Reality 端口访问)${NC}"
                fi
                _line
                echo ""
                read -rp "  确认安装? [Y/n]: " confirm
                [[ "$confirm" =~ ^[nN]$ ]] && return
                
                _info "生成配置..."
                gen_vless_xhttp_server_config "$uuid" "$port" "$privkey" "$pubkey" "$sid" "$final_sni" "$path"
            else
                # TLS+CDN 模式
                echo ""
                _line
                echo -e "  ${W}TLS+CDN 模式配置${NC}"
                _line
                echo -e "  ${D}此模式需要真实域名和证书${NC}"
                echo -e "  ${D}Xray 监听本地，Nginx 反代并处理 TLS${NC}"
                echo -e "  ${D}客户端通过 Cloudflare CDN (小云朵) 访问${NC}"
                _line
                echo ""
                
                # 使用统一的证书和 Nginx 配置函数
                # TLS+CDN 模式必须有真实证书
                local cert_retry=true
                local domain=""
                while [[ "$cert_retry" == "true" ]]; do
                    setup_cert_and_nginx "vless-xhttp-cdn"
                    local setup_result=$?
                    domain="$CERT_DOMAIN"
                    
                    if [[ "$setup_result" -eq 0 && -n "$domain" ]]; then
                        # 证书配置成功
                        cert_retry=false
                    else
                        # 配置失败，询问是否重试
                        _err "证书配置失败"
                        echo ""
                        echo -e "  ${G}1)${NC} 重试"
                        echo -e "  ${G}2)${NC} 取消安装"
                        echo ""
                        read -rp "  请选择 [1]: " retry_choice
                        if [[ "$retry_choice" == "2" ]]; then
                            return 0
                        fi
                        # 清除失败的配置，准备重试
                        rm -f "$CFG/certs/server.crt" "$CFG/certs/server.key" "$CFG/cert_domain"
                    fi
                done
                
                # 选择内部监听端口
                local internal_port=18080
                echo ""
                read -rp "  XHTTP 内部监听端口 [$internal_port]: " _ip
                [[ -n "$_ip" ]] && internal_port="$_ip"
                
                echo ""
                _line
                echo -e "  ${C}VLESS+XHTTP+TLS+CDN 配置${NC}"
                _line
                echo -e "  域名: ${G}$domain${NC}"
                echo -e "  外部端口: ${G}443${NC} (Nginx TLS)"
                echo -e "  内部端口: ${G}$internal_port${NC} (Xray h2c)"
                echo -e "  Path: ${G}$path${NC}"
                echo -e "  UUID: ${G}${uuid:0:8}...${NC}"
                echo ""
                echo -e "  ${Y}请确保 Cloudflare 中该域名已开启小云朵代理${NC}"
                _line
                echo ""
                read -rp "  确认安装? [Y/n]: " confirm
                [[ "$confirm" =~ ^[nN]$ ]] && return
                
                _info "生成配置..."
                gen_vless_xhttp_tls_cdn_config "$uuid" "$internal_port" "$path" "$domain"
                
                # 切换协议为 vless-xhttp-cdn (用于后续显示配置信息)
                protocol="vless-xhttp-cdn"
                SELECTED_PROTOCOL="vless-xhttp-cdn"
                
                # 配置 Nginx 反代 XHTTP (h2c)
                _info "配置 Nginx..."
                _setup_nginx_xhttp_proxy "$domain" "$internal_port" "$path"
                
                # 保存配置到数据库 (使用 443 作为对外端口)
                echo "$domain" > "$CFG/cert_domain"
            fi
            ;;
        vless-ws)
            # 子菜单：选择 TLS 模式或 CF Tunnel 模式
            echo ""
            _line
            echo -e "  ${W}VLESS-WS 模式选择${NC}"
            _line
            _item "1" "TLS 模式 ${D}(标准模式, 需要证书)${NC}"
            _item "2" "CF Tunnel 模式 ${D}(无TLS, 配合 Cloudflare Tunnel)${NC}"
            _item "0" "返回"
            echo ""
            
            local ws_mode=""
            read -rp "  选择模式 [1]: " ws_mode
            ws_mode=${ws_mode:-1}
            
            case "$ws_mode" in
                0) return ;;
                2)
                    # 转到 vless-ws-notls 安装
                    protocol="vless-ws-notls"
                    local uuid=$(gen_uuid)
                    local path="/vless"
                    local host=""
                    
                    echo ""
                    _info "VLESS-WS-CF 协议设计用于 Cloudflare Tunnel"
                    _info "服务器端不需要 TLS，由 CF Tunnel 提供加密"
                    echo ""
                    
                    read -rp "  WS Path [回车默认 $path]: " _p
                    [[ -n "$_p" ]] && path="$_p"
                    [[ "$path" != /* ]] && path="/$path"
                    
                    read -rp "  Host 头 (可选，用于 CF Tunnel): " host
                    
                    echo ""
                    _line
                    echo -e "  ${C}VLESS-WS-CF 配置 (无TLS)${NC}"
                    _line
                    echo -e "  端口: ${G}$port${NC}  UUID: ${G}${uuid:0:8}...${NC}"
                    echo -e "  Path: ${G}$path${NC}"
                    [[ -n "$host" ]] && echo -e "  Host: ${G}$host${NC}"
                    echo -e "  ${Y}注意: 请配置 CF Tunnel 指向此端口${NC}"
                    _line
                    echo ""
                    read -rp "  确认安装? [Y/n]: " confirm
                    [[ "$confirm" =~ ^[nN]$ ]] && return
                    
                    _info "生成配置..."
                    gen_vless_ws_notls_server_config "$uuid" "$port" "$path" "$host"
                    ;;  # 结束 CF Tunnel 分支，进入外层 vless-ws case 结束
            esac
            
            # 只有 TLS 模式（ws_mode=1或空）才执行以下流程
            if [[ "$ws_mode" != "2" ]]; then
                # TLS 模式继续原有流程
                local uuid=$(gen_uuid) path="/vless"
                
                # 检查是否有主协议在 8443 端口（仅 8443 端口才作为回落）
                local master_domain=""
                local master_protocol=""
                local master_port=""
                for proto in vless vless-vision trojan; do
                    if db_exists "xray" "$proto"; then
                        master_port=$(db_get_port "xray" "$proto" 2>/dev/null)
                        if [[ "$master_port" == "8443" ]]; then
                            master_domain=$(db_get_field "xray" "$proto" "sni" 2>/dev/null)
                            master_protocol="$proto"
                            break
                        fi
                    fi
                done
                
                # 检查证书域名
                local cert_domain=""
                if [[ -f "$CFG/cert_domain" ]]; then
                    cert_domain=$(cat "$CFG/cert_domain")
                fi
                
                local final_sni=""
                # 如果是回落子协议，强制使用证书域名（必须和 TLS 证书匹配）
                if [[ -n "$master_protocol" ]]; then
                    if [[ -n "$cert_domain" ]]; then
                        final_sni="$cert_domain"
                        echo ""
                        _warn "作为回落子协议，SNI 必须与主协议证书域名一致"
                        _ok "自动使用证书域名: $cert_domain"
                    elif [[ -n "$master_domain" ]]; then
                        final_sni="$master_domain"
                        _ok "自动使用主协议 SNI: $master_domain"
                    else
                        # 使用统一的证书和 Nginx 配置函数
                        setup_cert_and_nginx "vless-ws"
                        cert_domain="$CERT_DOMAIN"
                        final_sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")
                    fi
                else
                    # 独立安装，使用统一的证书和 Nginx 配置函数
                    setup_cert_and_nginx "vless-ws"
                    cert_domain="$CERT_DOMAIN"
                    final_sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")
                fi
                
                read -rp "  WS Path [回车默认 $path]: " _p
                [[ -n "$_p" ]] && path="$_p"
                [[ "$path" != /* ]] && path="/$path"
                
                # 检测是否为真实证书（用于决定是否显示订阅端口）
                local _is_real_cert=false
                if [[ -f "$CFG/certs/server.crt" ]]; then
                    local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
                    [[ "$issuer" == *"Let's Encrypt"* || "$issuer" == *"R3"* || "$issuer" == *"R10"* || "$issuer" == *"R11"* || "$issuer" == *"E1"* || "$issuer" == *"ZeroSSL"* || "$issuer" == *"Buypass"* ]] && _is_real_cert=true
                fi
                
                echo ""
                _line
                echo -e "  ${C}VLESS+WS+TLS 配置${NC}"
                _line
                # 根据是否为回落模式显示不同提示
                if [[ -n "$master_protocol" ]]; then
                    echo -e "  内部端口: ${G}$port${NC} (回落模式，外部通过 8443 访问)"
                else
                    echo -e "  端口: ${G}$port${NC}"
                fi
                echo -e "  UUID: ${G}${uuid:0:8}...${NC}"
                echo -e "  SNI: ${G}$final_sni${NC}  Path: ${G}$path${NC}"
                [[ -n "$cert_domain" && "$_is_real_cert" == "true" ]] && echo -e "  订阅端口: ${G}${NGINX_PORT:-18443}${NC}"
                _line
                echo ""
                read -rp "  确认安装? [Y/n]: " confirm
                [[ "$confirm" =~ ^[nN]$ ]] && return
                
                _info "生成配置..."
                gen_vless_ws_server_config "$uuid" "$port" "$final_sni" "$path"
            fi
            ;;
        vmess-ws)
            local uuid=$(gen_uuid)

            # 检查是否有主协议在 8443 端口（仅 8443 端口才作为回落）
            local master_domain=""
            local master_protocol=""
            local master_port=""
            for proto in vless vless-vision trojan; do
                if db_exists "xray" "$proto"; then
                    master_port=$(db_get_port "xray" "$proto" 2>/dev/null)
                    if [[ "$master_port" == "8443" ]]; then
                        master_domain=$(db_get_field "xray" "$proto" "sni" 2>/dev/null)
                        master_protocol="$proto"
                        break
                    fi
                fi
            done
            
            # 检查证书域名
            local cert_domain=""
            if [[ -f "$CFG/cert_domain" ]]; then
                cert_domain=$(cat "$CFG/cert_domain")
            elif [[ -f "$CFG/certs/server.crt" ]]; then
                # 从证书中提取域名
                cert_domain=$(openssl x509 -in "$CFG/certs/server.crt" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
            fi
            
            local final_sni=""
            local use_new_cert=false
            # 如果是回落子协议，强制使用主协议的 SNI（必须和证书匹配）
            if [[ -n "$master_protocol" ]]; then
                if [[ -n "$cert_domain" ]]; then
                    final_sni="$cert_domain"
                    echo ""
                    _warn "作为回落子协议，SNI 必须与主协议证书域名一致"
                    _ok "自动使用证书域名: $cert_domain"
                elif [[ -n "$master_domain" ]]; then
                    final_sni="$master_domain"
                    _ok "自动使用主协议 SNI: $master_domain"
                else
                    final_sni=$(ask_sni_config "$(gen_sni)" "")
                fi
            else
                # 独立安装
                # 检查是否有真实证书（CA 签发的）
                local is_real_cert=false
                if [[ -f "$CFG/certs/server.crt" ]]; then
                    local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
                    if [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || [[ "$issuer" == *"R11"* ]] || [[ "$issuer" == *"E1"* ]] || [[ "$issuer" == *"ZeroSSL"* ]] || [[ "$issuer" == *"Buypass"* ]]; then
                        is_real_cert=true
                    fi
                fi
                
                if [[ "$is_real_cert" == "true" && -n "$cert_domain" ]]; then
                    # 有真实证书，强制使用证书域名
                    final_sni="$cert_domain"
                    echo ""
                    _ok "检测到真实证书 (域名: $cert_domain)"
                    _ok "SNI 将使用证书域名: $cert_domain"
                    use_new_cert=false
                else
                    # 没有证书或只有自签名证书，询问 SNI 并生成对应证书
                    use_new_cert=true
                    final_sni=$(ask_sni_config "$(gen_sni)" "")
                fi
            fi

            local path="/vmess"
            read -rp "  WS Path [回车默认 $path]: " _p
            [[ -n "$_p" ]] && path="$_p"
            [[ "$path" != /* ]] && path="/$path"

            # 避免和 vless-ws path 撞车（简单提示）
            if db_exists "xray" "vless-ws"; then
                local used_path=$(db_get_field "xray" "vless-ws" "path")
                if [[ -n "$used_path" && "$used_path" == "$path" ]]; then
                    _warn "该 Path 已被 vless-ws 使用：$used_path（回落会冲突），建议换一个"
                fi
            fi

            echo ""
            _line
            echo -e "  ${C}VMess + WS 配置${NC}"
            _line
            # 根据是否为回落模式显示不同提示
            if [[ -n "$master_protocol" ]]; then
                echo -e "  内部端口: ${G}$port${NC} (回落模式，外部通过 ${master_protocol} 的 8443 端口访问)"
            else
                echo -e "  端口: ${G}$port${NC}"
            fi
            echo -e "  UUID: ${G}$uuid${NC}"
            echo -e "  SNI/Host: ${G}$final_sni${NC}"
            echo -e "  WS Path: ${G}$path${NC}"
            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return

            _info "生成配置..."
            gen_vmess_ws_server_config "$uuid" "$port" "$final_sni" "$path" "$use_new_cert"
            ;;
        vless-vision)
            local uuid=$(gen_uuid)
            
            # 使用统一的证书和 Nginx 配置函数
            setup_cert_and_nginx "vless-vision"
            local cert_domain="$CERT_DOMAIN"
            
            # 询问SNI配置
            local final_sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")
            
            echo ""
            _line
            echo -e "  ${C}VLESS-XTLS-Vision 配置${NC}"
            _line
            echo -e "  端口: ${G}$port${NC}  UUID: ${G}${uuid:0:8}...${NC}"
            # 检测是否为真实证书
            local _is_real_cert=false
            if [[ -f "$CFG/certs/server.crt" ]]; then
                local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
                [[ "$issuer" == *"Let's Encrypt"* || "$issuer" == *"R3"* || "$issuer" == *"R10"* || "$issuer" == *"R11"* || "$issuer" == *"E1"* || "$issuer" == *"ZeroSSL"* || "$issuer" == *"Buypass"* ]] && _is_real_cert=true
            fi
            echo -e "  SNI: ${G}$final_sni${NC}"
            [[ -n "$CERT_DOMAIN" && "$_is_real_cert" == "true" ]] && echo -e "  订阅端口: ${G}$NGINX_PORT${NC}"
            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return
            
            _info "生成配置..."
            gen_vless_vision_server_config "$uuid" "$port" "$final_sni"
            ;;
        socks)
            local use_tls="false" sni=""
            local auth_mode="password" listen_addr=""
            local username="" password=""

            # 询问是否启用 TLS
            echo ""
            _line
            echo -e "  ${W}SOCKS5 安全设置${NC}"
            _line
            echo -e "  ${G}1)${NC} 不启用 TLS ${D}(明文传输，可能被 QoS)${NC}"
            echo -e "  ${G}2)${NC} 启用 TLS ${D}(加密传输，需要证书)${NC}"
            echo ""
            read -rp "  请选择 [1]: " tls_choice

            if [[ "$tls_choice" == "2" ]]; then
                use_tls="true"
                # 调用统一的证书配置函数
                setup_cert_and_nginx "socks"
                local cert_domain="$CERT_DOMAIN"

                # 询问 SNI 配置（与其他 TLS 协议一致）
                sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")

                # 如果没有真实证书，使用自签证书（用 SNI 作为 CN）
                if [[ -z "$cert_domain" ]]; then
                    gen_self_cert "$sni"
                fi
            fi

            # 询问认证模式
            echo ""
            _line
            echo -e "  ${W}SOCKS5 认证设置${NC}"
            _line
            echo -e "  ${G}1)${NC} 用户名密码认证 ${D}(推荐)${NC}"
            echo -e "  ${G}2)${NC} 无认证 ${D}(需指定监听地址)${NC}"
            echo ""
            read -rp "  请选择 [1]: " auth_choice

            if [[ "$auth_choice" == "2" ]]; then
                auth_mode="noauth"
                # 询问监听地址
                # 根据系统双栈支持选择默认本地监听地址
                local default_listen
                if _has_ipv6 && _can_dual_stack_listen; then
                    default_listen="::1"
                else
                    default_listen="127.0.0.1"
                fi
                echo ""
                _line
                echo -e "  ${W}监听地址配置${NC}"
                _line
                echo -e "  ${D}建议仅监听本地地址以提高安全性${NC}"
                echo -e "  ${D}双栈系统使用 ::1，仅 IPv4 使用 127.0.0.1${NC}"
                echo -e "  ${D}监听 0.0.0.0 或 :: 将允许所有地址访问${NC}"
                echo ""
                read -rp "  请输入监听地址 [回车使用 $default_listen]: " _listen
                listen_addr="${_listen:-$default_listen}"
            else
                # 用户名密码模式 - 询问用户名和密码
                username=$(ask_password 8 "SOCKS5用户名")
                password=$(ask_password 16 "SOCKS5密码")
            fi

            echo ""
            _line
            echo -e "  ${C}SOCKS5 配置${NC}"
            _line
            echo -e "  端口: ${G}$port${NC}"
            if [[ "$auth_mode" == "noauth" ]]; then
                echo -e "  认证: ${D}无认证${NC}"
                echo -e "  监听地址: ${G}$listen_addr${NC}"
            else
                echo -e "  认证: ${G}用户名密码${NC}"
                echo -e "  用户名: ${G}$username${NC}"
                echo -e "  密码: ${G}$password${NC}"
            fi
            if [[ "$use_tls" == "true" ]]; then
                echo -e "  TLS: ${G}启用${NC} (SNI: $sni)"
            else
                echo -e "  TLS: ${D}未启用${NC}"
            fi
            _line
            echo ""

            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return

            _info "生成配置..."
            gen_socks_server_config "$username" "$password" "$port" "$use_tls" "$sni" "$auth_mode" "$listen_addr"
            ;;
        ss2022)
            # SS2022 加密方式选择
            echo ""
            _line
            echo -e "  ${W}选择 SS2022 加密方式${NC}"
            _line
            _item "1" "2022-blake3-aes-128-gcm ${D}(推荐, 16字节密钥)${NC}"
            _item "2" "2022-blake3-aes-256-gcm ${D}(更强, 32字节密钥)${NC}"
            _item "3" "2022-blake3-chacha20-poly1305 ${D}(ARM优化, 32字节密钥)${NC}"
            echo ""
            
            local method key_len
            while true; do
                read -rp "  选择加密 [1-3]: " enc_choice
                case $enc_choice in
                    1) method="2022-blake3-aes-128-gcm"; key_len=16; break ;;
                    2) method="2022-blake3-aes-256-gcm"; key_len=32; break ;;
                    3) method="2022-blake3-chacha20-poly1305"; key_len=32; break ;;
                    *) _err "无效选择" ;;
                esac
            done
            
            local password=$(head -c $key_len /dev/urandom 2>/dev/null | base64 -w 0)
            
            # 使用前面询问的结果
            if [[ "$enable_stls_pre" =~ ^[yY]$ ]]; then
                # 安装 ShadowTLS
                _info "安装 ShadowTLS..."
                install_shadowtls || { _err "ShadowTLS 安装失败"; _pause; return 1; }
                
                # 启用 ShadowTLS 模式
                local stls_password=$(ask_password 16 "ShadowTLS密码")
                local default_sni=$(gen_sni)
                
                echo ""
                read -rp "  ShadowTLS 握手域名 [回车使用 $default_sni]: " final_sni
                final_sni="${final_sni:-$default_sni}"
                
                # ShadowTLS 监听端口（对外暴露）
                echo ""
                echo -e "  ${D}ShadowTLS 监听端口 (对外暴露，建议 443)${NC}"
                local stls_port=$(ask_port "ss2022-shadowtls")
                
                # SS2022 内部端口（自动随机生成）
                local internal_port=$(gen_port)
                
                echo ""
                _line
                echo -e "  ${C}SS2022 + ShadowTLS 配置${NC}"
                _line
                echo -e "  对外端口: ${G}$stls_port${NC} (ShadowTLS)"
                echo -e "  内部端口: ${G}$internal_port${NC} (SS2022, 自动生成)"
                echo -e "  加密: ${G}$method${NC}"
                echo -e "  SNI: ${G}$final_sni${NC}"
                _line
                echo ""
                read -rp "  确认安装? [Y/n]: " confirm
                [[ "$confirm" =~ ^[nN]$ ]] && return
                
                # 切换协议为 ss2022-shadowtls
                protocol="ss2022-shadowtls"
                SELECTED_PROTOCOL="ss2022-shadowtls"
                
                _info "生成配置..."
                gen_ss2022_shadowtls_server_config "$password" "$stls_port" "$method" "$final_sni" "$stls_password" "$internal_port"
            else
                # 普通 SS2022 模式
                echo ""
                _line
                echo -e "  ${C}Shadowsocks 2022 配置${NC}"
                _line
                echo -e "  端口: ${G}$port${NC}"
                echo -e "  加密: ${G}$method${NC}"
                echo -e "  密钥: ${G}$password${NC}"
                _line
                echo ""
                read -rp "  确认安装? [Y/n]: " confirm
                [[ "$confirm" =~ ^[nN]$ ]] && return
                
                _info "生成配置..."
                gen_ss2022_server_config "$password" "$port" "$method"
            fi
            ;;
        ss-legacy)
            # SS 传统版加密方式选择
            echo ""
            _line
            echo -e "  ${W}选择 Shadowsocks 加密方式${NC}"
            _line
            _item "1" "aes-256-gcm ${D}(推荐, 兼容性好)${NC}"
            _item "2" "aes-128-gcm"
            _item "3" "chacha20-ietf-poly1305 ${D}(ARM优化)${NC}"
            echo ""
            
            local method
            while true; do
                read -rp "  选择加密 [1-3]: " enc_choice
                case $enc_choice in
                    1) method="aes-256-gcm"; break ;;
                    2) method="aes-128-gcm"; break ;;
                    3) method="chacha20-ietf-poly1305"; break ;;
                    *) _err "无效选择" ;;
                esac
            done
            
            local password=$(ask_password 16 "SS2022密码")
            
            echo ""
            _line
            echo -e "  ${C}Shadowsocks 传统版配置${NC}"
            _line
            echo -e "  端口: ${G}$port${NC}"
            echo -e "  加密: ${G}$method${NC}"
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  ${D}(无时间校验，兼容性好)${NC}"
            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return
            
            _info "生成配置..."
            gen_ss_legacy_server_config "$password" "$port" "$method"
            ;;
        hy2)
            local password=$(ask_password 16 "Hysteria2密码")
            local cert_domain=$(ask_cert_config "$(gen_sni)")
            
            # 询问SNI配置（在证书申请完成后）
            local final_sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")
            
            # ===== 新增：端口跳跃开关 + 范围（默认不启用）=====
            local hop_enable=0
            local hop_start=20000
            local hop_end=50000

            echo ""
            _line
            echo -e "  ${C}Hysteria2 配置${NC}"
            _line
            echo -e "  端口: ${G}$port${NC} (UDP)"
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  伪装: ${G}$final_sni${NC}"
            echo ""

            echo -e "  ${W}端口跳跃(Port Hopping)${NC}"
            echo -e "  ${D}说明：会将一段 UDP 端口范围重定向到 ${G}$port${NC}；高位随机端口有暴露风险，默认关闭。${NC}"
            read -rp "  是否启用端口跳跃? [y/N]: " hop_ans
            if [[ "$hop_ans" =~ ^[yY]$ ]]; then
                hop_enable=1

                read -rp "  起始端口 [回车默认 $hop_start]: " _hs
                [[ -n "$_hs" ]] && hop_start="$_hs"
                read -rp "  结束端口 [回车默认 $hop_end]: " _he
                [[ -n "$_he" ]] && hop_end="$_he"

                # 基础校验：数字 + 范围 + start<end
                if ! [[ "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]] \
                   || [[ "$hop_start" -lt 1 || "$hop_start" -gt 65535 ]] \
                   || [[ "$hop_end" -lt 1 || "$hop_end" -gt 65535 ]] \
                   || [[ "$hop_start" -ge "$hop_end" ]]; then
                    _warn "端口范围无效，已自动关闭端口跳跃"
                    hop_enable=0
                    hop_start=20000
                    hop_end=50000
                else
                    echo -e "  ${C}将启用：${G}${hop_start}-${hop_end}${NC} → 转发至 ${G}$port${NC}"
                fi
            else
                echo -e "  ${D}已选择：不启用端口跳跃${NC}"
            fi

            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return

            _info "生成配置..."
            # ★改：把 hop 参数传进去
            gen_hy2_server_config "$password" "$port" "$final_sni" "$hop_enable" "$hop_start" "$hop_end"
            ;;
        trojan)
            local password=$(ask_password 16 "Trojan密码")
            
            # 选择传输模式
            echo ""
            _line
            echo -e "  ${C}选择 Trojan 传输模式${NC}"
            _line
            echo -e "  ${G}1)${NC} TCP+TLS (默认，支持回落)"
            echo -e "  ${G}2)${NC} WebSocket+TLS (支持 CDN 转发)"
            _line
            echo ""
            read -rp "  请选择 [1-2，回车默认1]: " trojan_mode
            trojan_mode="${trojan_mode:-1}"
            
            local use_ws=false
            local path="/trojan"
            [[ "$trojan_mode" == "2" ]] && use_ws=true
            
            # 使用统一的证书和 Nginx 配置函数
            if [[ "$use_ws" == "true" ]]; then
                setup_cert_and_nginx "trojan-ws"
            else
                setup_cert_and_nginx "trojan"
            fi
            local cert_domain="$CERT_DOMAIN"
            
            # 询问SNI配置
            local final_sni=$(ask_sni_config "$(gen_sni)" "$cert_domain")
            
            # WS 模式询问 path
            if [[ "$use_ws" == "true" ]]; then
                echo ""
                read -rp "  WebSocket 路径 [回车默认 $path]: " ws_path
                [[ -n "$ws_path" ]] && path="$ws_path"
            fi
            
            echo ""
            _line
            if [[ "$use_ws" == "true" ]]; then
                echo -e "  ${C}Trojan-WS 配置${NC}"
            else
                echo -e "  ${C}Trojan 配置${NC}"
            fi
            _line
            echo -e "  端口: ${G}$port${NC}"
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$final_sni${NC}"
            [[ "$use_ws" == "true" ]] && echo -e "  Path: ${G}$path${NC}"
            # 检测是否为真实证书
            local _is_real_cert=false
            if [[ -f "$CFG/certs/server.crt" ]]; then
                local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
                [[ "$issuer" == *"Let's Encrypt"* || "$issuer" == *"R3"* || "$issuer" == *"R10"* || "$issuer" == *"R11"* || "$issuer" == *"E1"* || "$issuer" == *"ZeroSSL"* || "$issuer" == *"Buypass"* ]] && _is_real_cert=true
            fi
            [[ -n "$CERT_DOMAIN" && "$_is_real_cert" == "true" ]] && echo -e "  订阅端口: ${G}$NGINX_PORT${NC}"
            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return
            
            _info "生成配置..."
            if [[ "$use_ws" == "true" ]]; then
                gen_trojan_ws_server_config "$password" "$port" "$final_sni" "$path"
                protocol="trojan-ws"  # 更新协议名，确保后续查找正确
            else
                gen_trojan_server_config "$password" "$port" "$final_sni"
            fi
            ;;
        snell|snell-v5)
            # 根据协议确定版本
            local version psk stls_protocol
            if [[ "$protocol" == "snell" ]]; then
                version="4"
                psk=$(head -c 16 /dev/urandom 2>/dev/null | base64 -w 0 | tr -d '/+=' | head -c 22)
                stls_protocol="snell-shadowtls"
            else
                version="5"
                psk=$(ask_password 16 "Snell v5 PSK")
                stls_protocol="snell-v5-shadowtls"
            fi
            
            # 使用前面询问的结果
            if [[ "$enable_stls_pre" =~ ^[yY]$ ]]; then
                # 安装 ShadowTLS
                _info "安装 ShadowTLS..."
                install_shadowtls || { _err "ShadowTLS 安装失败"; _pause; return 1; }
                
                # 启用 ShadowTLS 模式
                local stls_password=$(ask_password 16 "ShadowTLS密码")
                local default_sni=$(gen_sni)
                
                echo ""
                read -rp "  ShadowTLS 握手域名 [回车使用 $default_sni]: " final_sni
                final_sni="${final_sni:-$default_sni}"
                
                # ShadowTLS 监听端口（对外暴露）
                echo ""
                echo -e "  ${D}ShadowTLS 监听端口 (对外暴露，建议 443)${NC}"
                local stls_port=$(ask_port "$stls_protocol")
                
                # Snell 内部端口（自动随机生成）
                local internal_port=$(gen_port)
                
                echo ""
                _line
                echo -e "  ${C}Snell v${version} + ShadowTLS 配置${NC}"
                _line
                echo -e "  对外端口: ${G}$stls_port${NC} (ShadowTLS)"
                echo -e "  内部端口: ${G}$internal_port${NC} (Snell, 自动生成)"
                echo -e "  PSK: ${G}$psk${NC}"
                echo -e "  SNI: ${G}$final_sni${NC}"
                _line
                echo ""
                read -rp "  确认安装? [Y/n]: " confirm
                [[ "$confirm" =~ ^[nN]$ ]] && return
                
                # 切换协议
                protocol="$stls_protocol"
                SELECTED_PROTOCOL="$stls_protocol"
                
                _info "生成配置..."
                gen_snell_shadowtls_server_config "$psk" "$stls_port" "$final_sni" "$stls_password" "$version" "$internal_port"
            else
                # 普通 Snell 模式
                echo ""
                _line
                echo -e "  ${C}Snell v${version} 配置${NC}"
                _line
                echo -e "  端口: ${G}$port${NC}"
                echo -e "  PSK: ${G}$psk${NC}"
                echo -e "  版本: ${G}v$version${NC}"
                _line
                echo ""
                read -rp "  确认安装? [Y/n]: " confirm
                [[ "$confirm" =~ ^[nN]$ ]] && return
                
                _info "生成配置..."
                if [[ "$version" == "4" ]]; then
                    gen_snell_server_config "$psk" "$port" "$version"
                else
                    gen_snell_v5_server_config "$psk" "$port" "$version"
                fi
            fi
            ;;
        tuic)
            local uuid=$(gen_uuid)
            local password=$(ask_password 16 "TUIC密码")
            
            # TUIC不需要证书申请，直接询问SNI配置
            local final_sni=$(ask_sni_config "$(gen_sni)" "")
            
            # ===== 端口跳跃开关 + 范围（默认不启用）=====
            local hop_enable=0
            local hop_start=20000
            local hop_end=50000

            echo ""
            _line
            echo -e "  ${C}TUIC v5 配置${NC}"
            _line
            echo -e "  端口: ${G}$port${NC} (UDP/QUIC)"
            echo -e "  UUID: ${G}${uuid:0:8}...${NC}"
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$final_sni${NC}"
            echo ""

            echo -e "  ${W}端口跳跃(Port Hopping)${NC}"
            echo -e "  ${D}说明：会将一段 UDP 端口范围重定向到 ${G}$port${NC}；高位随机端口有暴露风险，默认关闭。${NC}"
            read -rp "  是否启用端口跳跃? [y/N]: " hop_ans
            if [[ "$hop_ans" =~ ^[yY]$ ]]; then
                hop_enable=1

                read -rp "  起始端口 [回车默认 $hop_start]: " _hs
                [[ -n "$_hs" ]] && hop_start="$_hs"
                read -rp "  结束端口 [回车默认 $hop_end]: " _he
                [[ -n "$_he" ]] && hop_end="$_he"

                # 基础校验：数字 + 范围 + start<end
                if ! [[ "$hop_start" =~ ^[0-9]+$ && "$hop_end" =~ ^[0-9]+$ ]] \
                   || [[ "$hop_start" -lt 1 || "$hop_start" -gt 65535 ]] \
                   || [[ "$hop_end" -lt 1 || "$hop_end" -gt 65535 ]] \
                   || [[ "$hop_start" -ge "$hop_end" ]]; then
                    _warn "端口范围无效，已自动关闭端口跳跃"
                    hop_enable=0
                    hop_start=20000
                    hop_end=50000
                else
                    echo -e "  ${C}将启用：${G}${hop_start}-${hop_end}${NC} → 转发至 ${G}$port${NC}"
                fi
            else
                echo -e "  ${D}已选择：不启用端口跳跃${NC}"
            fi

            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return
            
            _info "生成配置..."
            gen_tuic_server_config "$uuid" "$password" "$port" "$final_sni" "$hop_enable" "$hop_start" "$hop_end"
            ;;
        anytls)
            local password=$(ask_password 16 "AnyTLS密码")
            
            # AnyTLS不需要证书申请，直接询问SNI配置
            local final_sni=$(ask_sni_config "$(gen_sni)" "")
            
            echo ""
            _line
            echo -e "  ${C}AnyTLS 配置${NC}"
            _line
            echo -e "  端口: ${G}$port${NC}"
            echo -e "  密码: ${G}$password${NC}"
            echo -e "  SNI: ${G}$final_sni${NC}"
            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return
            
            _info "生成配置..."
            gen_anytls_server_config "$password" "$port" "$final_sni"
            ;;
        naive)
            local username=$(ask_password 8 "NaïveProxy用户名")
            local password=$(ask_password 16 "NaïveProxy密码")
            
            # NaïveProxy 推荐使用 443 端口
            echo ""
            _line
            echo -e "  ${W}NaïveProxy 配置${NC}"
            _line
            echo -e "  ${D}NaïveProxy 需要域名，Caddy 会自动申请证书${NC}"
            echo -e "  ${D}请确保域名已解析到本机 IP${NC}"
            echo ""
            
            local domain="" local_ipv4=$(get_ipv4) local_ipv6=$(get_ipv6)
            while true; do
                read -rp "  请输入域名: " domain
                [[ -z "$domain" ]] && { _err "域名不能为空"; continue; }
                
                # 验证域名解析
                _info "验证域名解析..."
                local resolved_ip=$(dig +short "$domain" A 2>/dev/null | head -1)
                local resolved_ip6=$(dig +short "$domain" AAAA 2>/dev/null | head -1)
                
                if [[ "$resolved_ip" == "$local_ipv4" ]] || [[ "$resolved_ip6" == "$local_ipv6" ]]; then
                    _ok "域名解析验证通过"
                    break
                else
                    _warn "域名解析不匹配"
                    echo -e "  ${D}本机 IP: ${local_ipv4:-无} / ${local_ipv6:-无}${NC}"
                    echo -e "  ${D}解析 IP: ${resolved_ip:-无} / ${resolved_ip6:-无}${NC}"
                    read -rp "  是否继续使用此域名? [y/N]: " force
                    [[ "$force" =~ ^[yY]$ ]] && break
                fi
            done
            
            # 端口选择
            echo ""
            local default_port="443"
            if ss -tuln 2>/dev/null | grep -q ":443 "; then
                default_port="8443"
                echo -e "  ${Y}443 端口已被占用${NC}"
            fi
            
            while true; do
                read -rp "  请输入端口 [回车使用 $default_port]: " port
                port="${port:-$default_port}"
                if ss -tuln 2>/dev/null | grep -q ":${port} "; then
                    _err "端口 $port 已被占用，请换一个"
                else
                    break
                fi
            done
            
            echo ""
            _line
            echo -e "  ${C}NaïveProxy 配置${NC}"
            _line
            echo -e "  域名: ${G}$domain${NC}"
            echo -e "  端口: ${G}$port${NC}"
            echo -e "  用户名: ${G}$username${NC}"
            echo -e "  密码: ${G}$password${NC}"
            _line
            echo ""
            read -rp "  确认安装? [Y/n]: " confirm
            [[ "$confirm" =~ ^[nN]$ ]] && return
            
            _info "生成配置..."
            gen_naive_server_config "$username" "$password" "$port" "$domain"
            ;;
    esac
    
    _info "创建服务..."
    create_server_scripts  # 生成服务端辅助脚本（watchdog、hy2-nat、tuic-nat）
    create_service "$protocol"
    _info "启动服务..."
    
    # 保存当前安装的协议名（防止被后续函数中的循环变量覆盖）
    local current_protocol="$protocol"
    
    if start_services; then
        create_shortcut   # 安装成功才创建快捷命令
        
        # 更新订阅文件（此时数据库已更新，订阅内容才会正确）
        if [[ -f "$CFG/sub.info" ]]; then
            generate_sub_files
        fi
        
        _dline
        _ok "服务端安装完成! 快捷命令: vless"
        _ok "协议: $(get_protocol_name $current_protocol)"
        _dline
        
        # UDP协议提示开放防火墙
        if [[ "$current_protocol" == "hy2" || "$current_protocol" == "tuic" ]]; then
            # 从数据库读取端口
            local port=""
            if db_exists "singbox" "$current_protocol"; then
                port=$(db_get_field "singbox" "$current_protocol" "port")
            fi
            if [[ -n "$port" ]]; then
                echo ""
                _warn "重要: 请确保云服务商安全组/防火墙开放 UDP 端口 $port"
                echo -e "  ${D}# 测试 UDP 是否开放 (在本地电脑执行):${NC}"
                echo -e "  ${C}nslookup google.com $(get_ipv4)${NC}"
                echo -e "  ${D}# 如果超时无响应，说明 UDP 被拦截，需要在云服务商控制台开放 UDP 端口${NC}"
                echo ""
                echo -e "  ${D}# 服务器防火墙示例 (通常不需要，云安全组更重要):${NC}"
                echo -e "  ${C}iptables -A INPUT -p udp --dport $port -j ACCEPT${NC}"
                echo ""
            fi
        fi
        
        # TUIC 协议需要客户端持有证书
        if [[ "$current_protocol" == "tuic" ]]; then
            echo ""
            _warn "TUIC v5 要求客户端必须持有服务端证书!"
            _line
            echo -e "  ${C}请在客户端执行以下命令下载证书:${NC}"
            echo ""
            echo -e "  ${G}mkdir -p /etc/vless-reality/certs${NC}"
            echo -e "  ${G}scp root@$(get_ipv4):$CFG/certs/server.crt /etc/vless-reality/certs/${NC}"
            echo ""
            echo -e "  ${D}或手动复制证书内容到客户端 /etc/vless-reality/certs/server.crt${NC}"
            _line
        fi
        
        # 清理临时文件
        rm -f "$CFG/.nginx_port_tmp" 2>/dev/null
        
        # 获取当前安装的端口号
        local installed_port=""
        if [[ "$INSTALL_MODE" == "replace" && -n "$REPLACE_PORT" ]]; then
            # 覆盖模式：使用被覆盖的端口（可能已更新为新端口）
            installed_port="$REPLACE_PORT"
        else
            # 添加/首次安装模式：从配置中获取端口
            if db_exists "xray" "$current_protocol"; then
                local cfg=$(db_get "xray" "$current_protocol")
                if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
                    # 数组：获取最后一个端口（最新添加的）
                    installed_port=$(echo "$cfg" | jq -r '.[-1].port')
                else
                    # 单对象：直接获取端口
                    installed_port=$(echo "$cfg" | jq -r '.port')
                fi
            elif db_exists "singbox" "$current_protocol"; then
                local cfg=$(db_get "singbox" "$current_protocol")
                installed_port=$(echo "$cfg" | jq -r '.port')
            fi
        fi

        # 显示刚安装的协议配置（不清屏，指定端口）
        show_single_protocol_info "$current_protocol" false "$installed_port"
        _pause
    else
        _err "安装失败"
        _pause
    fi
}


show_status() {
    # 优化：单次 jq 调用获取所有数据，输出为简单文本格式便于 bash 解析
    # 设置全局变量 _INSTALLED_CACHE 供 main_menu 复用，避免重复查询
    _INSTALLED_CACHE=""
    
    [[ ! -f "$DB_FILE" ]] && { echo -e "  状态: ${D}○ 未安装${NC}"; return; }
    
    # 一次 jq 调用，输出格式: XRAY:proto1,proto2 SINGBOX:proto3 PORTS:proto1=443|58380,proto2=8080 RULES:count
    # 兼容数组和对象两种格式：数组提取所有端口用|分隔，对象直接取端口
    local db_parsed=$(jq -r '
        "XRAY:" + ((.xray // {}) | keys | join(",")) +
        " SINGBOX:" + ((.singbox // {}) | keys | join(",")) +
        " RULES:" + ((.routing_rules // []) | length | tostring) +
        " PORTS:" + ([
            (.xray // {} | to_entries[] | "\(.key)=" + (if (.value | type) == "array" then ([.value[].port] | map(tostring) | join("|")) else (.value.port | tostring) end)),
            (.singbox // {} | to_entries[] | "\(.key)=" + (if (.value | type) == "array" then ([.value[].port] | map(tostring) | join("|")) else (.value.port | tostring) end))
        ] | join(","))
    ' "$DB_FILE" 2>/dev/null)
    
    # 解析结果
    local xray_keys="" singbox_keys="" rules_count="0" ports_map=""
    local part
    for part in $db_parsed; do
        case "$part" in
            XRAY:*) xray_keys="${part#XRAY:}" ;;
            SINGBOX:*) singbox_keys="${part#SINGBOX:}" ;;
            RULES:*) rules_count="${part#RULES:}" ;;
            PORTS:*) ports_map="${part#PORTS:}" ;;
        esac
    done
    
    # 转换逗号分隔为换行分隔
    local installed=$(echo -e "${xray_keys//,/\\n}\n${singbox_keys//,/\\n}" | grep -v '^$' | sort -u)
    [[ -z "$installed" ]] && { echo -e "  状态: ${D}○ 未安装${NC}"; return; }
    
    # 缓存已安装协议供 main_menu 使用
    _INSTALLED_CACHE="$installed"
    
    local status_icon status_text
    local protocol_count=$(echo "$installed" | wc -l)
    
    # 在内存中过滤协议类型
    local xray_protocols="" singbox_protocols="" standalone_protocols=""
    local p
    for p in $XRAY_PROTOCOLS; do
        [[ ",$xray_keys," == *",$p,"* ]] && xray_protocols="$xray_protocols $p"
    done
    for p in $SINGBOX_PROTOCOLS; do
        [[ ",$singbox_keys," == *",$p,"* ]] && singbox_protocols="$singbox_protocols $p"
    done
    for p in $STANDALONE_PROTOCOLS; do
        if [[ ",$xray_keys," == *",$p,"* ]] || [[ ",$singbox_keys," == *",$p,"* ]]; then
            standalone_protocols="$standalone_protocols $p"
        fi
    done
    xray_protocols="${xray_protocols# }"
    singbox_protocols="${singbox_protocols# }"
    standalone_protocols="${standalone_protocols# }"
    
    # 检查服务运行状态
    local xray_running=false singbox_running=false
    local standalone_running=0 standalone_total=0
    
    [[ -n "$xray_protocols" ]] && svc status vless-reality >/dev/null 2>&1 && xray_running=true
    [[ -n "$singbox_protocols" ]] && svc status vless-singbox >/dev/null 2>&1 && singbox_running=true
    
    local ind_proto
    for ind_proto in $standalone_protocols; do
        ((standalone_total++))
        svc status "vless-${ind_proto}" >/dev/null 2>&1 && ((standalone_running++))
    done
    
    # 计算运行状态
    local xray_count=0 singbox_count=0
    [[ -n "$xray_protocols" ]] && xray_count=$(echo "$xray_protocols" | wc -w)
    [[ -n "$singbox_protocols" ]] && singbox_count=$(echo "$singbox_protocols" | wc -w)
    local running_protocols=0
    
    [[ "$xray_running" == "true" ]] && running_protocols=$xray_count
    [[ "$singbox_running" == "true" ]] && running_protocols=$((running_protocols + singbox_count))
    running_protocols=$((running_protocols + standalone_running))
    
    if is_paused; then
        status_icon="${Y}⏸${NC}"; status_text="${Y}已暂停${NC}"
    elif [[ $running_protocols -eq $protocol_count ]]; then
        status_icon="${G}●${NC}"; status_text="${G}运行中${NC}"
    elif [[ $running_protocols -gt 0 ]]; then
        status_icon="${Y}●${NC}"; status_text="${Y}部分运行${NC} (${running_protocols}/${protocol_count})"
    else
        status_icon="${R}●${NC}"; status_text="${R}已停止${NC}"
    fi
    
    echo -e "  状态: $status_icon $status_text"
    
    # 从 ports_map 获取端口的辅助函数（纯字符串匹配）
    _get_port() {
        local proto=$1 pair
        for pair in ${ports_map//,/ }; do
            [[ "$pair" == "$proto="* ]] && echo "${pair#*=}" && return
        done
    }
    
    # 显示协议概要（统一使用列表格式）
    if [[ $protocol_count -eq 1 ]]; then
        echo -e "  协议: ${C}已安装 (${protocol_count}个)${NC}"
    else
        echo -e "  协议: ${C}已安装 (${protocol_count}个)${NC}"
    fi

    # 统一列表显示所有协议和端口
    for proto in $installed; do
        local proto_ports=$(_get_port "$proto")
        # 处理多端口显示（用|分隔）
        if [[ "$proto_ports" == *"|"* ]]; then
            echo -e "    ${G}•${NC} $(get_protocol_name $proto) ${D}- 端口: ${proto_ports//|/, }${NC}"
        else
            echo -e "    ${G}•${NC} $(get_protocol_name $proto) ${D}- 端口: ${proto_ports}${NC}"
        fi
    done
    
    # 显示分流状态
    if [[ "$rules_count" -gt 0 ]]; then
        local warp_st=$(warp_status)
        
        # 统计不同出口类型的数量
        local chain_count=0
        local warp_count=0
        local block_count=0
        local unique_nodes=""
        
        while IFS= read -r outbound; do
            [[ -z "$outbound" ]] && continue
            if [[ "$outbound" == chain:* ]]; then
                ((chain_count++))
                local node_name="${outbound#chain:}"
                # 收集唯一节点名
                if [[ ! "$unique_nodes" =~ "$node_name" ]]; then
                    [[ -n "$unique_nodes" ]] && unique_nodes+=","
                    unique_nodes+="$node_name"
                fi
            elif [[ "$outbound" == "warp" ]]; then
                ((warp_count++))
            elif [[ "$outbound" == "block" ]]; then
                ((block_count++))
            fi
        done < <(jq -r '.routing_rules[].outbound // ""' "$DB_FILE" 2>/dev/null)
        
        # 构建显示信息
        local display_info=""
        if [[ $chain_count -gt 0 ]]; then
            # 统计唯一节点数
            local node_count=$(echo "$unique_nodes" | tr ',' '\n' | wc -l)
            if [[ $node_count -eq 1 ]]; then
                display_info="→${unique_nodes}"
            else
                display_info="→${node_count}个节点"
            fi
        fi
        if [[ $warp_count -gt 0 ]]; then
            [[ -n "$display_info" ]] && display_info+=","
            display_info+="WARP"
        fi
        if [[ $block_count -gt 0 ]]; then
            [[ -n "$display_info" ]] && display_info+=","
            display_info+="屏蔽"
        fi
        
        echo -e "  分流: ${G}${rules_count}条规则${display_info}${NC}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════════
# 订阅与外部节点管理
#═══════════════════════════════════════════════════════════════════════════════

# 安装 Nginx
install_nginx() {
    if check_cmd nginx; then
        _ok "Nginx 已安装"
        return 0
    fi
    
    _info "安装 Nginx..."
    case "$DISTRO" in
        alpine) apk add --no-cache nginx ;;
        centos) yum install -y nginx ;;
        *) apt-get install -y -qq nginx ;;
    esac
    
    if check_cmd nginx; then
        _ok "Nginx 安装完成"
        return 0
    else
        _err "Nginx 安装失败"
        return 1
    fi
}

EXTERNAL_LINKS_FILE="$CFG/external_links.txt"
EXTERNAL_SUBS_FILE="$CFG/external_subs.txt"
EXTERNAL_CACHE_DIR="$CFG/external_nodes_cache"

# 解析 vless:// 链接
parse_vless_link() {
    local link="$1"
    # vless://uuid@server:port?params#name
    local content="${link#vless://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")  # URL 解码
    # 转义 JSON 特殊字符
    name="${name//\\/\\\\}"
    name="${name//\"/\\\"}"
    content="${content%%#*}"
    
    local uuid="${content%%@*}"
    content="${content#*@}"
    
    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"
    
    local params="${content#*\?}"
    
    # 解析参数
    local security="" type="" sni="" pbk="" sid="" flow="" path="" host="" fp="" encryption=""
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        value=$(printf '%b' "${value//%/\\x}")  # URL 解码
        case "$key" in
            security) security="$value" ;;
            type) type="$value" ;;
            sni) sni="$value" ;;
            pbk) pbk="$value" ;;
            sid) sid="$value" ;;
            flow) flow="$value" ;;
            path) path="$value" ;;
            host) host="$value" ;;
            fp) fp="$value" ;;
            encryption) encryption="$value" ;;
            headerType) ;; # 忽略
        esac
    done
    
    # 确保 port 是纯数字，无效则报错
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi
    
    # 输出 JSON 格式 (使用 jq 确保正确转义，port 使用 argjson 存储为数字)
    # 注意：字段名使用完整名称以便 gen_xray_chain_outbound 正确读取
    jq -nc \
        --arg type "vless" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg security "$security" \
        --arg transport "${type:-tcp}" \
        --arg sni "$sni" \
        --arg publicKey "$pbk" \
        --arg shortId "$sid" \
        --arg flow "$flow" \
        --arg path "$path" \
        --arg host "$host" \
        --arg fingerprint "${fp:-chrome}" \
        --arg encryption "$encryption" \
        '{type:$type,name:$name,server:$server,port:$port,uuid:$uuid,security:$security,transport:$transport,sni:$sni,publicKey:$publicKey,shortId:$shortId,flow:$flow,path:$path,host:$host,fingerprint:$fingerprint,encryption:$encryption}'
}

# 解析 vmess:// 链接
parse_vmess_link() {
    local link="$1"
    # vmess://base64(json)
    local content="${link#vmess://}"
    local json=$(echo "$content" | base64 -d 2>/dev/null)
    [[ -z "$json" ]] && return 1
    
    local name=$(echo "$json" | jq -r '.ps // .name // "VMess"')
    local server=$(echo "$json" | jq -r '.add // .server')
    local port=$(echo "$json" | jq -r '.port')
    local uuid=$(echo "$json" | jq -r '.id // .uuid')
    local aid=$(echo "$json" | jq -r '.aid // "0"')
    local net=$(echo "$json" | jq -r '.net // "tcp"')
    local type=$(echo "$json" | jq -r '.type // "none"')
    local host=$(echo "$json" | jq -r '.host // ""')
    local path=$(echo "$json" | jq -r '.path // ""')
    local tls=$(echo "$json" | jq -r '.tls // ""')
    local sni=$(echo "$json" | jq -r '.sni // ""')
    
    # 确保 port 和 aid 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi
    aid=$(echo "$aid" | tr -d '"' | tr -d ' ')
    [[ ! "$aid" =~ ^[0-9]+$ ]] && aid="0"
    
    # 使用 jq 生成 JSON，确保 port 和 aid 是数字
    jq -nc \
        --arg type "vmess" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --argjson aid "$aid" \
        --arg network "$net" \
        --arg host "$host" \
        --arg path "$path" \
        --arg tls "$tls" \
        --arg sni "$sni" \
        '{type:$type,name:$name,server:$server,port:$port,uuid:$uuid,aid:$aid,network:$network,host:$host,path:$path,tls:$tls,sni:$sni}'
}

# 解析 trojan:// 链接
parse_trojan_link() {
    local link="$1"
    # trojan://password@server:port?params#name
    local content="${link#trojan://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")  # URL 解码
    content="${content%%#*}"
    
    local password="${content%%@*}"
    content="${content#*@}"
    
    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"
    
    local params="${content#*\?}"
    local sni="" type="tcp"
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        case "$key" in
            sni) sni="$value" ;;
            type) type="$value" ;;
        esac
    done
    
    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi
    
    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "trojan" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg transport "$type" \
        '{type:$type,name:$name,server:$server,port:$port,password:$password,sni:$sni,transport:$transport}'
}

# 解析 ss:// 链接
parse_ss_link() {
    local link="$1"
    # ss://base64(method:password)@server:port#name
    # 或 ss://base64(method:password@server:port)#name
    local content="${link#ss://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")
    content="${content%%#*}"
    
    local server="" port="" method="" password=""
    
    if [[ "$content" == *"@"* ]]; then
        # 格式: base64@server:port
        local encoded="${content%%@*}"
        local decoded=$(echo "$encoded" | base64 -d 2>/dev/null)
        if [[ "$decoded" == *":"* ]]; then
            method="${decoded%%:*}"
            password="${decoded#*:}"
        fi
        local server_port="${content#*@}"
        # 解析 host:port（支持 IPv6）
        local parsed=$(_parse_hostport "$server_port")
        server="${parsed%%|*}"
        port="${parsed##*|}"
    else
        # 格式: base64(全部)
        local decoded=$(echo "$content" | base64 -d 2>/dev/null)
        if [[ "$decoded" == *"@"* ]]; then
            local method_pass="${decoded%%@*}"
            method="${method_pass%%:*}"
            password="${method_pass#*:}"
            local server_port="${decoded#*@}"
            # 解析 host:port（支持 IPv6）
            local parsed=$(_parse_hostport "$server_port")
            server="${parsed%%|*}"
            port="${parsed##*|}"
        fi
    fi
    
    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi
    
    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "ss" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg password "$password" \
        '{type:$type,name:$name,server:$server,port:$port,method:$method,password:$password}'
}

# 解析 hysteria2:// 链接
parse_hy2_link() {
    local link="$1"
    # hysteria2://password@server:port?params#name
    local content="${link#hysteria2://}"
    content="${content#hy2://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")  # URL 解码
    content="${content%%#*}"
    
    local password="${content%%@*}"
    content="${content#*@}"
    
    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"
    
    local params="${content#*\?}"
    local sni="" insecure="1"
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        case "$key" in
            sni) sni="$value" ;;
            insecure) insecure="$value" ;;
        esac
    done
    
    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi
    
    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "hysteria2" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        '{type:$type,name:$name,server:$server,port:$port,password:$password,sni:$sni}'
}

# 解析 anytls:// 链接
parse_anytls_link() {
    local link="$1"
    # anytls://password@server:port?sni=xxx#name
    local content="${link#anytls://}"
    local name="${content##*#}"
    name=$(printf '%b' "${name//%/\\x}")
    content="${content%%#*}"
    
    local password="${content%%@*}"
    content="${content#*@}"
    
    local server_port="${content%%\?*}"
    # 解析 host:port（支持 IPv6）
    local parsed=$(_parse_hostport "$server_port")
    local server="${parsed%%|*}"
    local port="${parsed##*|}"
    
    local params="${content#*\?}"
    local sni=""
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        case "$key" in
            sni) sni="$value" ;;
        esac
    done
    
    # 确保 port 是数字
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "错误: 无法解析端口号 '$port'" >&2
        return 1
    fi
    
    # 使用 jq 生成 JSON
    jq -nc \
        --arg type "anytls" \
        --arg name "$name" \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        '{type:$type,name:$name,server:$server,port:$port,password:$password,sni:$sni}'
}

# 解析任意分享链接
parse_share_link() {
    local link="$1"
    case "$link" in
        vless://*) parse_vless_link "$link" ;;
        vmess://*) parse_vmess_link "$link" ;;
        trojan://*) parse_trojan_link "$link" ;;
        ss://*) parse_ss_link "$link" ;;
        hysteria2://*|hy2://*) parse_hy2_link "$link" ;;
        anytls://*) parse_anytls_link "$link" ;;
        *) echo "" ;;
    esac
}

# 从分享链接提取节点名称
get_link_name() {
    local link="$1"
    local name="${link##*#}"
    name=$(printf '%b' "${name//%/\\x}")
    [[ -z "$name" || "$name" == "$link" ]] && name="未命名节点"
    echo "$name"
}

# 拉取订阅内容
fetch_subscription() {
    local url="$1"
    local content=$(curl -sL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null)
    [[ -z "$content" ]] && return 1
    
    # 尝试 Base64 解码
    local decoded=$(echo "$content" | base64 -d 2>/dev/null)
    if [[ -n "$decoded" && "$decoded" == *"://"* ]]; then
        echo "$decoded"
        return 0
    fi
    
    # 检查是否是 Clash YAML
    if [[ "$content" == *"proxies:"* ]]; then
        # 解析 Clash YAML 节点，转换为分享链接
        local links=""
        local in_proxies=false
        local current_proxy=""
        local name="" type="" server="" port="" uuid="" password="" method=""
        local network="" tls="" sni="" path="" host="" flow="" pbk="" sid=""
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            # 检测 proxies 段
            if [[ "$line" =~ ^proxies: ]]; then
                in_proxies=true
                continue
            fi
            
            # 检测离开 proxies 段
            if [[ "$in_proxies" == "true" && "$line" =~ ^[a-z-]+: && ! "$line" =~ ^[[:space:]] ]]; then
                in_proxies=false
            fi
            
            [[ "$in_proxies" != "true" ]] && continue
            
            # 新节点开始
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name: ]]; then
                # 保存上一个节点
                if [[ -n "$name" && -n "$type" && -n "$server" && -n "$port" ]]; then
                    case "$type" in
                        vless)
                            local link="vless://${uuid}@${server}:${port}?encryption=none"
                            [[ -n "$flow" ]] && link+="&flow=$flow"
                            [[ "$tls" == "true" ]] && link+="&security=reality&type=${network:-tcp}&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid" || link+="&security=none&type=${network:-tcp}"
                            [[ "$network" == "ws" ]] && link+="&type=ws&path=$(urlencode "$path")&host=$host"
                            link+="#$(urlencode "$name")"
                            links+="$link"$'\n'
                            ;;
                        vmess)
                            local vmess_json="{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$server\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"${network:-tcp}\",\"type\":\"none\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"$([[ "$tls" == "true" ]] && echo "tls" || echo "")\",\"sni\":\"$sni\"}"
                            links+="vmess://$(echo -n "$vmess_json" | base64 -w 0)"$'\n'
                            ;;
                        trojan)
                            links+="trojan://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                            ;;
                        ss)
                            local ss_encoded=$(echo -n "${method}:${password}" | base64 -w 0)
                            links+="ss://${ss_encoded}@${server}:${port}#$(urlencode "$name")"$'\n'
                            ;;
                        hysteria2)
                            links+="hysteria2://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                            ;;
                        tuic)
                            links+="tuic://${uuid}:${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                            ;;
                    esac
                fi
                # 重置变量
                name="" type="" server="" port="" uuid="" password="" method=""
                network="" tls="" sni="" path="" host="" flow="" pbk="" sid=""
                name=$(echo "$line" | sed 's/.*name:[[:space:]]*"\?\([^"]*\)"\?.*/\1/')
                continue
            fi
            
            # 解析属性 (去掉引号)
            _strip_quotes() { local v="$1"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"; echo "$v"; }
            [[ "$line" =~ ^[[:space:]]*type:[[:space:]]*(.*) ]] && type=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*server:[[:space:]]*(.*) ]] && server=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*port:[[:space:]]*(.*) ]] && port=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*uuid:[[:space:]]*(.*) ]] && uuid=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*password:[[:space:]]*(.*) ]] && password=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*cipher:[[:space:]]*(.*) ]] && method=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*network:[[:space:]]*(.*) ]] && network=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*tls:[[:space:]]*(.*) ]] && tls=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*sni:[[:space:]]*(.*) ]] && sni=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*servername:[[:space:]]*(.*) ]] && sni=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*flow:[[:space:]]*(.*) ]] && flow=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*path:[[:space:]]*(.*) ]] && path=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*Host:[[:space:]]*(.*) ]] && host=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*public-key:[[:space:]]*(.*) ]] && pbk=$(_strip_quotes "${BASH_REMATCH[1]}")
            [[ "$line" =~ ^[[:space:]]*short-id:[[:space:]]*(.*) ]] && sid=$(_strip_quotes "${BASH_REMATCH[1]}")
        done <<< "$content"
        
        # 处理最后一个节点
        if [[ -n "$name" && -n "$type" && -n "$server" && -n "$port" ]]; then
            case "$type" in
                vless)
                    local link="vless://${uuid}@${server}:${port}?encryption=none"
                    [[ -n "$flow" ]] && link+="&flow=$flow"
                    [[ "$tls" == "true" ]] && link+="&security=reality&type=${network:-tcp}&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid" || link+="&security=none&type=${network:-tcp}"
                    link+="#$(urlencode "$name")"
                    links+="$link"$'\n'
                    ;;
                vmess)
                    local vmess_json="{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$server\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"${network:-tcp}\",\"type\":\"none\",\"host\":\"$host\",\"path\":\"$path\",\"tls\":\"$([[ "$tls" == "true" ]] && echo "tls" || echo "")\",\"sni\":\"$sni\"}"
                    links+="vmess://$(echo -n "$vmess_json" | base64 -w 0)"$'\n'
                    ;;
                trojan)
                    links+="trojan://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                    ;;
                ss)
                    local ss_encoded=$(echo -n "${method}:${password}" | base64 -w 0)
                    links+="ss://${ss_encoded}@${server}:${port}#$(urlencode "$name")"$'\n'
                    ;;
                hysteria2)
                    links+="hysteria2://${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                    ;;
                tuic)
                    links+="tuic://${uuid}:${password}@${server}:${port}?sni=$sni#$(urlencode "$name")"$'\n'
                    ;;
            esac
        fi
        
        [[ -n "$links" ]] && echo "$links" && return 0
        return 1
    fi
    
    # 原样返回（可能已经是链接列表）
    if [[ "$content" == *"://"* ]]; then
        echo "$content"
        return 0
    fi
    
    return 1
}

# 刷新所有订阅
refresh_external_subs() {
    [[ ! -f "$EXTERNAL_SUBS_FILE" ]] && return 0
    
    mkdir -p "$EXTERNAL_CACHE_DIR"
    local count=0
    local idx=0
    
    while IFS= read -r url || [[ -n "$url" ]]; do
        [[ -z "$url" || "$url" == \#* ]] && continue
        ((idx++))
        
        _info "拉取订阅 $idx: $url"
        local content=$(fetch_subscription "$url")
        
        if [[ -n "$content" ]]; then
            echo "$content" > "$EXTERNAL_CACHE_DIR/sub_$idx.txt"
            local node_count=$(echo "$content" | grep -c '://' || echo 0)
            _ok "获取 $node_count 个节点"
            ((count+=node_count))
        else
            _warn "拉取失败: $url"
        fi
    done < "$EXTERNAL_SUBS_FILE"
    
    _ok "共刷新 $count 个外部节点"
    
    # 自动更新订阅文件
    [[ -f "$CFG/sub.info" ]] && generate_sub_files
}

# 获取所有外部节点链接
get_all_external_links() {
    local links=""
    
    # 直接添加的分享链接
    if [[ -f "$EXTERNAL_LINKS_FILE" ]]; then
        while IFS= read -r link || [[ -n "$link" ]]; do
            [[ -z "$link" || "$link" == \#* ]] && continue
            links+="$link"$'\n'
        done < "$EXTERNAL_LINKS_FILE"
    fi
    
    # 订阅缓存的节点
    if [[ -d "$EXTERNAL_CACHE_DIR" ]]; then
        for cache_file in "$EXTERNAL_CACHE_DIR"/*.txt; do
            [[ ! -f "$cache_file" ]] && continue
            while IFS= read -r link || [[ -n "$link" ]]; do
                [[ -z "$link" || "$link" == \#* ]] && continue
                [[ "$link" != *"://"* ]] && continue
                links+="$link"$'\n'
            done < "$cache_file"
        done
    fi
    
    echo -n "$links"
}

# 将外部节点转换为 Clash 格式
external_link_to_clash() {
    local link="$1"
    local json=$(parse_share_link "$link")
    [[ -z "$json" ]] && return
    
    local type=$(echo "$json" | jq -r '.type')
    local name=$(echo "$json" | jq -r '.name')
    local server=$(echo "$json" | jq -r '.server')
    local port=$(echo "$json" | jq -r '.port')
    
    # 给外部节点名称加上服务器标识，避免与本地节点重复
    local server_suffix=$(get_ip_suffix "$server")
    [[ -n "$server_suffix" && "$name" != *"-${server_suffix}"* && "$name" != *"-${server_suffix}" ]] && name="${name}-${server_suffix}"
    
    case "$type" in
        vless)
            local uuid=$(echo "$json" | jq -r '.uuid')
            local security=$(echo "$json" | jq -r '.security')
            local transport=$(echo "$json" | jq -r '.transport')
            local sni=$(echo "$json" | jq -r '.sni')
            local pbk=$(echo "$json" | jq -r '.pbk')
            local sid=$(echo "$json" | jq -r '.sid')
            local flow=$(echo "$json" | jq -r '.flow')
            local path=$(echo "$json" | jq -r '.path')
            
            if [[ "$security" == "reality" ]]; then
                cat << EOF
  - name: "$name"
    type: vless
    server: "$server"
    port: $port
    uuid: $uuid
    network: ${transport:-tcp}
    tls: true
    udp: true
    flow: $flow
    servername: $sni
    reality-opts:
      public-key: $pbk
      short-id: $sid
    client-fingerprint: chrome
EOF
            elif [[ "$transport" == "ws" ]]; then
                cat << EOF
  - name: "$name"
    type: vless
    server: "$server"
    port: $port
    uuid: $uuid
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $sni
    ws-opts:
      path: $path
      headers:
        Host: $sni
EOF
            else
                cat << EOF
  - name: "$name"
    type: vless
    server: "$server"
    port: $port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $sni
EOF
            fi
            ;;
        vmess)
            local uuid=$(echo "$json" | jq -r '.uuid')
            local network=$(echo "$json" | jq -r '.network')
            local tls=$(echo "$json" | jq -r '.tls')
            local sni=$(echo "$json" | jq -r '.sni')
            local path=$(echo "$json" | jq -r '.path')
            local host=$(echo "$json" | jq -r '.host')
            
            cat << EOF
  - name: "$name"
    type: vmess
    server: "$server"
    port: $port
    uuid: $uuid
    alterId: 0
    cipher: auto
    network: ${network:-tcp}
    tls: $([[ "$tls" == "tls" ]] && echo "true" || echo "false")
    skip-cert-verify: true
    servername: ${sni:-$host}
EOF
            if [[ "$network" == "ws" ]]; then
                cat << EOF
    ws-opts:
      path: ${path:-/}
      headers:
        Host: ${host:-$sni}
EOF
            fi
            ;;
        trojan)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            cat << EOF
  - name: "$name"
    type: trojan
    server: "$server"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true
    udp: true
EOF
            ;;
        ss)
            local method=$(echo "$json" | jq -r '.method')
            local password=$(echo "$json" | jq -r '.password')
            cat << EOF
  - name: "$name"
    type: ss
    server: "$server"
    port: $port
    cipher: $method
    password: $password
    udp: true
EOF
            ;;
        hysteria2)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            cat << EOF
  - name: "$name"
    type: hysteria2
    server: "$server"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true
EOF
            ;;
        anytls)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            cat << EOF
  - name: "$name"
    type: anytls
    server: "$server"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true
EOF
            ;;
    esac
}

# 将外部节点转换为 Surge 格式
external_link_to_surge() {
    local link="$1"
    local json=$(parse_share_link "$link")
    [[ -z "$json" ]] && return
    
    local type=$(echo "$json" | jq -r '.type')
    local name=$(echo "$json" | jq -r '.name')
    local server=$(echo "$json" | jq -r '.server')
    local port=$(echo "$json" | jq -r '.port')
    
    # 给外部节点名称加上服务器标识，避免与本地节点重复
    local server_suffix=$(get_ip_suffix "$server")
    [[ -n "$server_suffix" && "$name" != *"-${server_suffix}"* && "$name" != *"-${server_suffix}" ]] && name="${name}-${server_suffix}"
    
    case "$type" in
        vmess)
            local uuid=$(echo "$json" | jq -r '.uuid')
            local network=$(echo "$json" | jq -r '.network')
            local tls=$(echo "$json" | jq -r '.tls')
            local sni=$(echo "$json" | jq -r '.sni')
            local path=$(echo "$json" | jq -r '.path')
            if [[ "$network" == "ws" ]]; then
                echo "$name = vmess, $server, $port, $uuid, tls=$([[ "$tls" == "tls" ]] && echo "true" || echo "false"), ws=true, ws-path=${path:-/}, sni=$sni, skip-cert-verify=true"
            else
                echo "$name = vmess, $server, $port, $uuid, tls=$([[ "$tls" == "tls" ]] && echo "true" || echo "false"), skip-cert-verify=true"
            fi
            ;;
        trojan)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            echo "$name = trojan, $server, $port, password=$password, sni=$sni, skip-cert-verify=true"
            ;;
        ss)
            local method=$(echo "$json" | jq -r '.method')
            local password=$(echo "$json" | jq -r '.password')
            echo "$name = ss, $server, $port, encrypt-method=$method, password=$password"
            ;;
        hysteria2)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            echo "$name = hysteria2, $server, $port, password=$password, sni=$sni, skip-cert-verify=true"
            ;;
        anytls)
            local password=$(echo "$json" | jq -r '.password')
            local sni=$(echo "$json" | jq -r '.sni')
            echo "$name = anytls, $server, $port, password=$password, sni=$sni, skip-cert-verify=true"
            ;;
    esac
}

# 添加分享链接
add_external_link() {
    echo ""
    _line
    echo -e "  ${W}添加分享链接${NC}"
    echo -e "  ${D}支持: vless://, vmess://, trojan://, ss://, hysteria2://, anytls://${NC}"
    _line
    echo ""
    read -rp "  请输入分享链接: " link
    
    [[ -z "$link" ]] && return
    
    # 验证链接格式
    if [[ "$link" != *"://"* ]]; then
        _err "无效的链接格式"
        return 1
    fi
    
    # 检查是否已存在
    if [[ -f "$EXTERNAL_LINKS_FILE" ]] && grep -qF "$link" "$EXTERNAL_LINKS_FILE"; then
        _warn "该链接已存在"
        return 1
    fi
    
    # 解析获取名称
    local name=$(get_link_name "$link")
    
    # 保存
    mkdir -p "$(dirname "$EXTERNAL_LINKS_FILE")"
    echo "$link" >> "$EXTERNAL_LINKS_FILE"
    
    _ok "已添加节点: $name"
    
    # 自动更新订阅文件
    if [[ -f "$CFG/sub.info" ]]; then
        generate_sub_files
    fi
}

# 添加订阅链接
add_external_sub() {
    echo ""
    _line
    echo -e "  ${W}添加订阅链接${NC}"
    echo -e "  ${D}支持 V2Ray/Base64 订阅、Clash YAML 订阅${NC}"
    _line
    echo ""
    read -rp "  请输入订阅链接: " url
    
    [[ -z "$url" ]] && return
    
    # 验证 URL 格式
    if [[ "$url" != http://* && "$url" != https://* ]]; then
        _err "无效的 URL 格式"
        return 1
    fi
    
    # 检查是否已存在
    if [[ -f "$EXTERNAL_SUBS_FILE" ]] && grep -qF "$url" "$EXTERNAL_SUBS_FILE"; then
        _warn "该订阅已存在"
        return 1
    fi
    
    # 测试拉取
    _info "测试订阅链接..."
    local content=$(fetch_subscription "$url")
    
    if [[ -z "$content" ]]; then
        _err "无法获取订阅内容"
        return 1
    fi
    
    local node_count=$(echo "$content" | grep -c '://' || echo 0)
    
    # 保存
    mkdir -p "$(dirname "$EXTERNAL_SUBS_FILE")"
    echo "$url" >> "$EXTERNAL_SUBS_FILE"
    
    # 缓存节点
    mkdir -p "$EXTERNAL_CACHE_DIR"
    local idx=$(wc -l < "$EXTERNAL_SUBS_FILE" 2>/dev/null || echo 1)
    echo "$content" > "$EXTERNAL_CACHE_DIR/sub_$idx.txt"
    
    _ok "已添加订阅，包含 $node_count 个节点"
    
    # 自动更新订阅文件
    if [[ -f "$CFG/sub.info" ]]; then
        generate_sub_files
    fi
}

# 查看外部节点
show_external_nodes() {
    echo ""
    _line
    echo -e "  ${W}外部节点列表${NC}"
    _line
    
    local count=0
    
    # 显示分享链接
    if [[ -f "$EXTERNAL_LINKS_FILE" ]]; then
        echo -e "\n  ${Y}[分享链接]${NC}"
        local idx=0
        while IFS= read -r link || [[ -n "$link" ]]; do
            [[ -z "$link" || "$link" == \#* ]] && continue
            ((idx++))
            ((count++))
            local name=$(get_link_name "$link")
            local proto="${link%%://*}"
            echo -e "  ${G}$idx)${NC} [$proto] $name"
        done < "$EXTERNAL_LINKS_FILE"
        [[ $idx -eq 0 ]] && echo -e "  ${D}(无)${NC}"
    fi
    
    # 显示订阅
    if [[ -f "$EXTERNAL_SUBS_FILE" ]]; then
        echo -e "\n  ${Y}[订阅链接]${NC}"
        local idx=0
        while IFS= read -r url || [[ -n "$url" ]]; do
            [[ -z "$url" || "$url" == \#* ]] && continue
            ((idx++))
            local cache_file="$EXTERNAL_CACHE_DIR/sub_$idx.txt"
            local node_count=0
            [[ -f "$cache_file" ]] && node_count=$(grep -c '://' "$cache_file" 2>/dev/null || echo 0)
            ((count+=node_count))
            echo -e "  ${G}$idx)${NC} $url ${D}($node_count 个节点)${NC}"
        done < "$EXTERNAL_SUBS_FILE"
        [[ $idx -eq 0 ]] && echo -e "  ${D}(无)${NC}"
    fi
    
    echo ""
    _line
    echo -e "  ${C}共 $count 个外部节点${NC}"
    _line
}

# 删除外部节点
delete_external_node() {
    echo ""
    _line
    echo -e "  ${W}删除外部节点${NC}"
    _line
    echo -e "  ${G}1)${NC} 删除分享链接"
    echo -e "  ${G}2)${NC} 删除订阅链接"
    echo -e "  ${G}3)${NC} 清空所有外部节点"
    echo -e "  ${G}0)${NC} 返回"
    _line
    
    read -rp "  请选择: " choice
    
    case "$choice" in
        1)
            [[ ! -f "$EXTERNAL_LINKS_FILE" ]] && { _warn "没有分享链接"; return; }
            echo ""
            local idx=0
            while IFS= read -r link || [[ -n "$link" ]]; do
                [[ -z "$link" || "$link" == \#* ]] && continue
                ((idx++))
                local name=$(get_link_name "$link")
                echo -e "  ${G}$idx)${NC} $name"
            done < "$EXTERNAL_LINKS_FILE"
            echo ""
            read -rp "  输入序号删除 (0 取消): " del_idx
            [[ "$del_idx" == "0" || -z "$del_idx" ]] && return
            
            sed -i "${del_idx}d" "$EXTERNAL_LINKS_FILE" 2>/dev/null && _ok "已删除" || _err "删除失败"
            # 自动更新订阅文件
            [[ -f "$CFG/sub.info" ]] && generate_sub_files
            ;;
        2)
            [[ ! -f "$EXTERNAL_SUBS_FILE" ]] && { _warn "没有订阅链接"; return; }
            echo ""
            local idx=0
            while IFS= read -r url || [[ -n "$url" ]]; do
                [[ -z "$url" || "$url" == \#* ]] && continue
                ((idx++))
                echo -e "  ${G}$idx)${NC} $url"
            done < "$EXTERNAL_SUBS_FILE"
            echo ""
            read -rp "  输入序号删除 (0 取消): " del_idx
            [[ "$del_idx" == "0" || -z "$del_idx" ]] && return
            
            sed -i "${del_idx}d" "$EXTERNAL_SUBS_FILE" 2>/dev/null
            rm -f "$EXTERNAL_CACHE_DIR/sub_$del_idx.txt" 2>/dev/null
            _ok "已删除"
            # 自动更新订阅文件
            [[ -f "$CFG/sub.info" ]] && generate_sub_files
            ;;
        3)
            read -rp "  确认清空所有外部节点? [y/N]: " confirm
            [[ "$confirm" =~ ^[yY]$ ]] || return
            rm -f "$EXTERNAL_LINKS_FILE" "$EXTERNAL_SUBS_FILE"
            rm -rf "$EXTERNAL_CACHE_DIR"
            _ok "已清空所有外部节点"
            # 自动更新订阅文件
            [[ -f "$CFG/sub.info" ]] && generate_sub_files
            ;;
    esac
}

# 外部节点管理菜单
manage_external_nodes() {
    while true; do
        _header
        echo -e "  ${W}外部节点管理${NC}"
        _line
        _item "1" "添加分享链接"
        _item "2" "添加订阅链接"
        _item "3" "查看外部节点"
        _item "4" "删除外部节点"
        _item "5" "刷新订阅"
        _line
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        
        case "$choice" in
            1) add_external_link ;;
            2) add_external_sub ;;
            3) show_external_nodes ;;
            4) delete_external_node ;;
            5) refresh_external_subs ;;
            0|"") return ;;
            *) _err "无效选择" ;;
        esac
        
        echo ""
        read -rp "按回车继续..."
    done
}

# 获取或生成订阅 UUID
get_sub_uuid() {
    local uuid_file="$CFG/sub_uuid"
    if [[ -f "$uuid_file" ]]; then
        cat "$uuid_file"
    else
        local new_uuid=$(gen_uuid)
        echo "$new_uuid" > "$uuid_file"
        chmod 600 "$uuid_file"
        echo "$new_uuid"
    fi
}

# 重置订阅 UUID（生成新的）
reset_sub_uuid() {
    local uuid_file="$CFG/sub_uuid"
    local new_uuid=$(gen_uuid)
    echo "$new_uuid" > "$uuid_file"
    chmod 600 "$uuid_file"
    echo "$new_uuid"
}

# 生成 V2Ray/通用 Base64 订阅内容
gen_v2ray_sub() {
    local installed=$(get_installed_protocols)
    local links=""
    local ipv4=$(get_ipv4)
    local ipv6=$(get_ipv6)
    
    # 获取地区代码
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")
    
    # 确定使用的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6（带方括号）
    local server_ip="$ipv4"
    if [[ -z "$server_ip" && -n "$ipv6" ]]; then
        server_ip="[$ipv6]"
    fi
    
    # 检查是否有主协议（用于判断 WS 协议是否为回落子协议）
    local master_port=""
    master_port=$(_get_master_port "")
    
    for protocol in $installed; do
        # 从数据库读取配置
        local cfg=""
        if db_exists "xray" "$protocol"; then
            cfg=$(db_get "xray" "$protocol")
        elif db_exists "singbox" "$protocol"; then
            cfg=$(db_get "singbox" "$protocol")
        fi
        [[ -z "$cfg" ]] && continue
        
        # 检查是否为数组（多端口）
        local cfg_stream=""
        if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
            # 多端口：遍历每个端口实例
            cfg_stream=$(echo "$cfg" | jq -c '.[]')
        else
            # 单端口：使用原有逻辑
            cfg_stream=$(echo "$cfg" | jq -c '.')
        fi
        
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            
            # 提取字段
            local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
            local port=$(echo "$cfg" | jq -r '.port // empty')
            local sni=$(echo "$cfg" | jq -r '.sni // empty')
            local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
            local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
            local path=$(echo "$cfg" | jq -r '.path // empty')
            local password=$(echo "$cfg" | jq -r '.password // empty')
            local username=$(echo "$cfg" | jq -r '.username // empty')
            local method=$(echo "$cfg" | jq -r '.method // empty')
            local psk=$(echo "$cfg" | jq -r '.psk // empty')
            
            # 对于回落子协议，使用主协议端口
            local actual_port="$port"
            if [[ -n "$master_port" && ("$protocol" == "vless-ws" || "$protocol" == "vmess-ws") ]]; then
                actual_port="$master_port"
            fi
            
            local link=""
            case "$protocol" in
                vless)
                    [[ -n "$server_ip" ]] && link=$(gen_vless_link "$server_ip" "$actual_port" "$uuid" "$public_key" "$short_id" "$sni" "$country_code")
                    ;;
                vless-xhttp)
                    [[ -n "$server_ip" ]] && link=$(gen_vless_xhttp_link "$server_ip" "$actual_port" "$uuid" "$public_key" "$short_id" "$sni" "$path" "$country_code")
                    ;;
                vless-ws)
                    [[ -n "$server_ip" ]] && link=$(gen_vless_ws_link "$server_ip" "$actual_port" "$uuid" "$sni" "$path" "$country_code")
                    ;;
                vless-vision)
                    [[ -n "$server_ip" ]] && link=$(gen_vless_vision_link "$server_ip" "$actual_port" "$uuid" "$sni" "$country_code")
                    ;;
                vmess-ws)
                    [[ -n "$server_ip" ]] && link=$(gen_vmess_ws_link "$server_ip" "$actual_port" "$uuid" "$sni" "$path" "$country_code")
                    ;;
                trojan)
                    [[ -n "$server_ip" ]] && link=$(gen_trojan_link "$server_ip" "$actual_port" "$password" "$sni" "$country_code")
                    ;;
                ss2022)
                    [[ -n "$server_ip" ]] && link=$(gen_ss2022_link "$server_ip" "$actual_port" "$method" "$password" "$country_code")
                    ;;
                ss-legacy)
                    [[ -n "$server_ip" ]] && link=$(gen_ss_legacy_link "$server_ip" "$actual_port" "$method" "$password" "$country_code")
                    ;;
                hy2)
                    [[ -n "$server_ip" ]] && link=$(gen_hy2_link "$server_ip" "$actual_port" "$password" "$sni" "$country_code")
                    ;;
                tuic)
                    [[ -n "$server_ip" ]] && link=$(gen_tuic_link "$server_ip" "$actual_port" "$uuid" "$password" "$sni" "$country_code")
                    ;;
                anytls)
                    [[ -n "$server_ip" ]] && link=$(gen_anytls_link "$server_ip" "$actual_port" "$password" "$sni" "$country_code")
                    ;;
                snell)
                    [[ -n "$server_ip" ]] && link=$(gen_snell_link "$server_ip" "$actual_port" "$psk" "4" "$country_code")
                    ;;
                snell-v5)
                    [[ -n "$server_ip" ]] && link=$(gen_snell_v5_link "$server_ip" "$actual_port" "$psk" "5" "$country_code")
                    ;;
                socks)
                    [[ -n "$server_ip" ]] && link=$(gen_socks_link "$server_ip" "$actual_port" "$username" "$password" "$country_code")
                    ;;
            esac
            
            [[ -n "$link" ]] && links+="$link"$'\n'
        done <<< "$cfg_stream"
    done
    
    # 合并外部节点
    local external_links=$(get_all_external_links)
    [[ -n "$external_links" ]] && links+="$external_links"
    
    # Base64 编码
    printf '%s' "$links" | base64 -w 0 2>/dev/null || printf '%s' "$links" | base64
}

# 生成 Clash 订阅内容
gen_clash_sub() {
    local installed=$(get_installed_protocols)
    local ipv4=$(get_ipv4)
    local ipv6=$(get_ipv6)
    local proxies=""
    local proxy_names=""
    
    # 获取地区代码和IP后缀
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")
    
    # 确定使用的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6
    local server_ip="$ipv4"
    local ip_suffix="${ipv4##*.}"
    if [[ -z "$server_ip" && -n "$ipv6" ]]; then
        server_ip="$ipv6"
        ip_suffix=$(get_ip_suffix "$ipv6")
    fi
    
    # 检查是否有主协议（用于判断 WS 协议是否为回落子协议）
    local master_port=""
    master_port=$(_get_master_port "")
    
    for protocol in $installed; do
        # 从数据库读取配置
        local cfg=""
        if db_exists "xray" "$protocol"; then
            cfg=$(db_get "xray" "$protocol")
        elif db_exists "singbox" "$protocol"; then
            cfg=$(db_get "singbox" "$protocol")
        fi
        [[ -z "$cfg" ]] && continue
        
        # 检查是否为数组（多端口）
        local cfg_stream=""
        if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
            # 多端口：遍历每个端口实例
            cfg_stream=$(echo "$cfg" | jq -c '.[]')
        else
            # 单端口：使用原有逻辑
            cfg_stream=$(echo "$cfg" | jq -c '.')
        fi
        
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            
            # 提取字段
            local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
            local port=$(echo "$cfg" | jq -r '.port // empty')
            local sni=$(echo "$cfg" | jq -r '.sni // empty')
            local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
            local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
            local path=$(echo "$cfg" | jq -r '.path // empty')
            local password=$(echo "$cfg" | jq -r '.password // empty')
            local username=$(echo "$cfg" | jq -r '.username // empty')
            local method=$(echo "$cfg" | jq -r '.method // empty')
            local psk=$(echo "$cfg" | jq -r '.psk // empty')
            
            # 对于回落子协议，使用主协议端口
            local actual_port="$port"
            if [[ -n "$master_port" && ("$protocol" == "vless-ws" || "$protocol" == "vmess-ws") ]]; then
                actual_port="$master_port"
            fi
            
            local name="${country_code}-$(get_protocol_name $protocol)-${ip_suffix}"
            local proxy=""
            
            case "$protocol" in
            vless)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: vless
    server: \"$server_ip\"
    port: $actual_port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $sni
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: chrome"
                ;;
            vless-xhttp)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: vless
    server: \"$server_ip\"
    port: $actual_port
    uuid: $uuid
    network: xhttp
    tls: true
    udp: true
    servername: $sni
    xhttp-opts:
      path: $path
      mode: auto
    reality-opts:
      public-key: $public_key
      short-id: $short_id
    client-fingerprint: chrome"
                ;;
            vless-ws)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: vless
    server: \"$server_ip\"
    port: $actual_port
    uuid: $uuid
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    servername: $sni
    ws-opts:
      path: $path
      headers:
        Host: $sni"
                ;;
            vless-vision)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: vless
    server: \"$server_ip\"
    port: $actual_port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    skip-cert-verify: true
    servername: $sni
    client-fingerprint: chrome"
                ;;
            vmess-ws)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: vmess
    server: \"$server_ip\"
    port: $actual_port
    uuid: $uuid
    alterId: 0
    cipher: auto
    network: ws
    tls: true
    skip-cert-verify: true
    servername: $sni
    ws-opts:
      path: $path
      headers:
        Host: $sni"
                ;;
            trojan)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: trojan
    server: \"$server_ip\"
    port: $actual_port
    password: $password
    udp: true
    skip-cert-verify: true
    sni: $sni"
                ;;
            ss2022)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: ss
    server: \"$server_ip\"
    port: $port
    cipher: $method
    password: $password
    udp: true"
                ;;
            ss-legacy)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: ss
    server: \"$server_ip\"
    port: $port
    cipher: $method
    password: $password
    udp: true"
                ;;
            hy2)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: hysteria2
    server: \"$server_ip\"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true"
                ;;
            tuic)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: tuic
    server: \"$server_ip\"
    port: $port
    uuid: $uuid
    password: $password
    alpn: [h3]
    udp-relay-mode: native
    congestion-controller: bbr
    sni: $sni
    skip-cert-verify: true"
                ;;
            anytls)
                [[ -n "$server_ip" ]] && proxy="  - name: \"$name\"
    type: anytls
    server: \"$server_ip\"
    port: $port
    password: $password
    sni: $sni
    skip-cert-verify: true"
                ;;
            esac
            
            if [[ -n "$proxy" ]]; then
                proxies+="$proxy"$'\n'
                proxy_names+="      - \"$name\""$'\n'
            fi
        done <<< "$cfg_stream"
    done
    
    # 合并外部节点
    local external_links=$(get_all_external_links)
    while IFS= read -r link || [[ -n "$link" ]]; do
        [[ -z "$link" || "$link" != *"://"* ]] && continue
        local ext_proxy=$(external_link_to_clash "$link")
        if [[ -n "$ext_proxy" ]]; then
            proxies+="$ext_proxy"$'\n'
            # 从生成的 proxy 中提取名称
            local ext_name=$(echo "$ext_proxy" | grep -m1 'name:' | sed 's/.*name:[[:space:]]*"\([^"]*\)".*/\1/')
            proxy_names+="      - \"$ext_name\""$'\n'
        fi
    done <<< "$external_links"
    
    # 生成完整 Clash 配置
    cat << EOF
mixed-port: 7897
allow-lan: false
mode: rule
log-level: info

proxies:
$proxies
proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
$proxy_names
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF
}

# 生成 Surge 订阅内容
gen_surge_sub() {
    local installed=$(get_installed_protocols)
    local ipv4=$(get_ipv4)
    local ipv6=$(get_ipv6)
    local proxies=""
    local proxy_names=""
    
    # 获取地区代码
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")
    
    # 确定使用的 IP 地址：优先 IPv4，纯 IPv6 环境使用 IPv6
    local server_ip="$ipv4"
    local ip_suffix="${ipv4##*.}"
    if [[ -z "$server_ip" && -n "$ipv6" ]]; then
        server_ip="[$ipv6]"
        ip_suffix=$(get_ip_suffix "$ipv6")
    fi
    
    for protocol in $installed; do
        # 从数据库读取配置
        local cfg=""
        if db_exists "xray" "$protocol"; then
            cfg=$(db_get "xray" "$protocol")
        elif db_exists "singbox" "$protocol"; then
            cfg=$(db_get "singbox" "$protocol")
        fi
        [[ -z "$cfg" ]] && continue
        
        # 检查是否为数组（多端口）
        local cfg_stream=""
        if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
            # 多端口：遍历每个端口实例
            cfg_stream=$(echo "$cfg" | jq -c '.[]')
        else
            # 单端口：使用原有逻辑
            cfg_stream=$(echo "$cfg" | jq -c '.')
        fi
        
        while IFS= read -r cfg; do
            [[ -z "$cfg" ]] && continue
            
            # 提取字段
            local uuid=$(echo "$cfg" | jq -r '.uuid // empty')
            local port=$(echo "$cfg" | jq -r '.port // empty')
            local sni=$(echo "$cfg" | jq -r '.sni // empty')
            local password=$(echo "$cfg" | jq -r '.password // empty')
            local method=$(echo "$cfg" | jq -r '.method // empty')
            local psk=$(echo "$cfg" | jq -r '.psk // empty')
            local version=$(echo "$cfg" | jq -r '.version // empty')
            
            local name="${country_code}-$(get_protocol_name $protocol)-${ip_suffix}"
            local proxy=""
            
            case "$protocol" in
                trojan)
                    [[ -n "$server_ip" ]] && proxy="$name = trojan, $server_ip, $port, password=$password, sni=$sni, skip-cert-verify=true"
                    ;;
                ss2022)
                    [[ -n "$server_ip" ]] && proxy="$name = ss, $server_ip, $port, encrypt-method=$method, password=$password"
                    ;;
                ss-legacy)
                    [[ -n "$server_ip" ]] && proxy="$name = ss, $server_ip, $port, encrypt-method=$method, password=$password"
                    ;;
                hy2)
                    [[ -n "$server_ip" ]] && proxy="$name = hysteria2, $server_ip, $port, password=$password, sni=$sni, skip-cert-verify=true"
                    ;;
                tuic)
                    [[ -n "$server_ip" ]] && proxy="$name = tuic, $server_ip, $port, uuid=$uuid, password=$password, sni=$sni, skip-cert-verify=true, alpn=h3"
                    ;;
                anytls)
                    [[ -n "$server_ip" ]] && proxy="$name = anytls, $server_ip, $port, password=$password, sni=$sni, skip-cert-verify=true"
                    ;;
                snell|snell-v5|snell-shadowtls|snell-v5-shadowtls)
                    # Snell 和 Snell+ShadowTLS 都使用相同的 Surge 配置格式
                    [[ -n "$server_ip" ]] && proxy="$name = snell, $server_ip, $port, psk=$psk, version=${version:-4}"
                    ;;
            esac
            
            if [[ -n "$proxy" ]]; then
                proxies+="$proxy"$'\n'
                [[ -n "$proxy_names" ]] && proxy_names+=", "
                proxy_names+="$name"
            fi
        done <<< "$cfg_stream"
    done
    
    # 合并外部节点 (仅支持 vmess/trojan/ss/hysteria2)
    local external_links=$(get_all_external_links)
    while IFS= read -r link || [[ -n "$link" ]]; do
        [[ -z "$link" || "$link" != *"://"* ]] && continue
        local ext_proxy=$(external_link_to_surge "$link")
        if [[ -n "$ext_proxy" ]]; then
            proxies+="$ext_proxy"$'\n'
            # 从生成的 proxy 中提取名称
            local ext_name=$(echo "$ext_proxy" | cut -d'=' -f1 | xargs)
            [[ -n "$proxy_names" ]] && proxy_names+=", "
            proxy_names+="$ext_name"
        fi
    done <<< "$external_links"
    
    cat << EOF
[General]
loglevel = notify

[Proxy]
$proxies
[Proxy Group]
Proxy = select, $proxy_names

[Rule]
GEOIP,CN,DIRECT
FINAL,Proxy
EOF
}

# 生成订阅文件
generate_sub_files() {
    local sub_uuid=$(get_sub_uuid)
    local sub_dir="$CFG/subscription/$sub_uuid"
    mkdir -p "$sub_dir"
    
    _info "生成订阅文件..."
    
    # V2Ray/通用订阅
    gen_v2ray_sub > "$sub_dir/base64"
    
    # Clash 订阅
    gen_clash_sub > "$sub_dir/clash.yaml"
    
    # Surge 订阅
    gen_surge_sub > "$sub_dir/surge.conf"
    
    chmod -R 644 "$sub_dir"/*
    _ok "订阅文件已生成"
}

# 配置 Nginx 订阅服务
setup_nginx_sub() {
    local sub_uuid=$(get_sub_uuid)
    local sub_port="${1:-8443}" domain="${2:-}" use_https="${3:-true}"

    generate_sub_files
    local sub_dir="$CFG/subscription/$sub_uuid"
    local fake_conf="/etc/nginx/conf.d/vless-fake.conf"
    [[ -d "/etc/nginx/http.d" ]] && fake_conf="/etc/nginx/http.d/vless-fake.conf"

    # 检查现有配置：已存在且路由正确则直接复用
    if [[ -f "$fake_conf" ]] &&
       grep -q "listen.*$sub_port" "$fake_conf" 2>/dev/null &&
       grep -q "location.*sub.*alias.*subscription" "$fake_conf" 2>/dev/null; then
        _ok "Nginx 已配置订阅服务: 端口 $sub_port"
        return 0
    fi

    local cert_file="$CFG/certs/server.crt" key_file="$CFG/certs/server.key"
    # 根据系统选择正确的 nginx 配置目录
    local nginx_conf_dir="/etc/nginx/conf.d"
    [[ -d "/etc/nginx/http.d" ]] && nginx_conf_dir="/etc/nginx/http.d"
    local nginx_conf="$nginx_conf_dir/vless-sub.conf"
    rm -f "$nginx_conf" 2>/dev/null
    mkdir -p "$nginx_conf_dir"

    if [[ "$use_https" == "true" && ( ! -f "$cert_file" || ! -f "$key_file" ) ]]; then
        _warn "证书不存在，生成自签名证书..."
        gen_self_cert "${domain:-localhost}"
    fi
    if [[ "$use_https" == "true" && ( ! -f "$cert_file" || ! -f "$key_file" ) ]]; then
        _warn "证书仍不存在，切换到 HTTP 模式..."
        use_https="false"
    fi

    local ssl_listen="" ssl_block=""
    if [[ "$use_https" == "true" ]]; then
        ssl_listen=" ssl http2"
        ssl_block=$(cat <<EOF
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
EOF
)
    fi

    cat > "$nginx_conf" << EOF
server {
    listen $sub_port$ssl_listen;
    listen [::]:$sub_port$ssl_listen;
    server_name ${domain:-_};
$ssl_block
    # 订阅路径 (alias 直指文件，避免 try_files 误判)
    location /sub/$sub_uuid/ {
        alias $sub_dir/;
        default_type text/plain;
        add_header Content-Type 'text/plain; charset=utf-8';
    }

    location /sub/$sub_uuid/clash {
        alias $sub_dir/clash.yaml;
        default_type text/yaml;
        add_header Content-Disposition 'attachment; filename="clash.yaml"';
    }

    location /sub/$sub_uuid/surge {
        alias $sub_dir/surge.conf;
        default_type text/plain;
        add_header Content-Disposition 'attachment; filename="surge.conf"';
    }

    location /sub/$sub_uuid/v2ray {
        alias $sub_dir/base64;
        default_type text/plain;
    }

    # 伪装网页
    root /var/www/html;
    index index.html;

    location / { try_files \$uri \$uri/ =404; }

    # 隐藏 Nginx 版本
    server_tokens off;
}
EOF

    if nginx -t 2>/dev/null; then
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-service nginx restart 2>/dev/null || nginx -s reload
        else
            systemctl reload nginx 2>/dev/null || nginx -s reload
        fi
        _ok "Nginx 配置完成"
        return 0
    fi

    _err "Nginx 配置错误"
    rm -f "$nginx_conf"
    return 1
}


# 显示订阅链接
show_sub_links() {
    [[ ! -f "$CFG/sub.info" ]] && { _warn "订阅服务未配置"; return; }
    
    # 清除变量避免污染
    local sub_uuid="" sub_port="" sub_domain="" sub_https=""
    source "$CFG/sub.info"
    local ipv4=$(get_ipv4)
    local protocol="http"
    [[ "$sub_https" == "true" ]] && protocol="https"
    
    local base_url="${protocol}://${sub_domain:-$ipv4}:${sub_port}/sub/${sub_uuid}"
    
    _line
    echo -e "  ${W}订阅链接${NC}"
    _line
    echo -e "  ${Y}Clash/Clash Verge (推荐):${NC}"
    echo -e "  ${G}${base_url}/clash${NC}"
    echo ""
    echo -e "  ${Y}Surge:${NC}"
    echo -e "  ${G}${base_url}/surge${NC}"
    echo ""
    echo -e "  ${Y}V2Ray/Loon/通用:${NC}"
    echo -e "  ${G}${base_url}/v2ray${NC}"
    _line
    echo -e "  ${D}订阅路径包含随机UUID，请妥善保管${NC}"
    
    # HTTPS 自签名证书提示
    if [[ "$sub_https" == "true" && -z "$sub_domain" ]]; then
        echo -e "  ${Y}提示: 使用自签名证书，部分客户端可能无法解析订阅${NC}"
        echo -e "  ${D}建议使用 HTTP 或绑定真实域名申请证书${NC}"
    fi
}

# 订阅服务管理菜单
manage_subscription() {
    while true; do
        _header
        echo -e "  ${W}订阅服务管理${NC}"
        _line
        
        if [[ -f "$CFG/sub.info" ]]; then
            # 清除变量避免污染
            local sub_uuid="" sub_port="" sub_domain="" sub_https=""
            source "$CFG/sub.info"
            echo -e "  状态: ${G}已配置${NC}"
            echo -e "  端口: ${G}$sub_port${NC}"
            [[ -n "$sub_domain" ]] && echo -e "  域名: ${G}$sub_domain${NC}"
            echo -e "  HTTPS: ${G}$sub_https${NC}"
            echo ""
            _item "1" "查看订阅链接"
            _item "2" "更新订阅内容"
            _item "3" "外部节点管理"
            _item "4" "重新配置"
            _item "5" "停用订阅服务"
        else
            echo -e "  状态: ${D}未配置${NC}"
            echo ""
            _item "1" "启用订阅服务"
            _item "2" "外部节点管理"
        fi
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        
        if [[ -f "$CFG/sub.info" ]]; then
            case $choice in
                1) show_sub_links; _pause ;;
                2) generate_sub_files; _ok "订阅内容已更新"; _pause ;;
                3) manage_external_nodes ;;
                4) setup_subscription_interactive ;;
                5) 
                    # 获取订阅端口和域名信息
                    local sub_port="" sub_domain=""
                    if [[ -f "$CFG/sub.info" ]]; then
                        source "$CFG/sub.info"
                    fi
                    
                    # 删除配置文件
                    rm -f /etc/nginx/conf.d/vless-sub.conf /etc/nginx/http.d/vless-sub.conf "$CFG/sub.info"
                    rm -rf "$CFG/subscription"
                    
                    # 清理 hosts 记录
                    if [[ -n "$sub_domain" ]]; then
                        sed -i "/127.0.0.1 $sub_domain/d" /etc/hosts 2>/dev/null
                        _info "已清理 /etc/hosts 中的域名记录"
                    fi
                    
                    # 检查是否还有其他 nginx 配置，如果没有则停止 nginx
                    local other_configs=$(ls /etc/nginx/conf.d/*.conf /etc/nginx/http.d/*.conf 2>/dev/null | wc -l)
                    if [[ "$other_configs" -eq 0 ]]; then
                        _info "没有其他 Nginx 配置，停止 Nginx 服务..."
                        if [[ "$DISTRO" == "alpine" ]]; then
                            rc-service nginx stop 2>/dev/null
                        else
                            systemctl stop nginx 2>/dev/null
                        fi
                        _ok "Nginx 服务已停止"
                    else
                        _info "检测到其他 Nginx 配置，仅重载配置..."
                        nginx -s reload 2>/dev/null
                    fi
                    
                    _ok "订阅服务已停用"
                    _pause
                    ;;
                0) return ;;
            esac
        else
            case $choice in
                1) setup_subscription_interactive ;;
                2) manage_external_nodes ;;
                0) return ;;
            esac
        fi
    done
}

# 交互式配置订阅
setup_subscription_interactive() {
    _header
    echo -e "  ${W}配置订阅服务${NC}"
    _line
    
    # 询问是否重新生成 UUID
    if [[ -f "$CFG/sub_uuid" ]]; then
        echo -e "  ${Y}检测到已有订阅 UUID${NC}"
        read -rp "  是否重新生成 UUID? [y/N]: " regen_uuid
        if [[ "$regen_uuid" =~ ^[yY]$ ]]; then
            local old_uuid=$(cat "$CFG/sub_uuid")
            reset_sub_uuid
            local new_uuid=$(cat "$CFG/sub_uuid")
            _ok "UUID 已更新: ${old_uuid:0:8}... → ${new_uuid:0:8}..."
            # 清理旧的订阅目录
            rm -rf "$CFG/subscription/$old_uuid" 2>/dev/null
        fi
        echo ""
    fi
    
    # 安装 Nginx
    if ! check_cmd nginx; then
        _info "需要安装 Nginx..."
        install_nginx || { _err "Nginx 安装失败"; _pause; return; }
    fi
    
    # 端口（带冲突检测）
    local default_port=18443
    local sub_port=""
    
    while true; do
        read -rp "  订阅端口 [$default_port]: " sub_port
        sub_port="${sub_port:-$default_port}"
        
        # 检查是否被已安装协议占用
        local conflict_proto=$(is_internal_port_occupied "$sub_port")
        if [[ -n "$conflict_proto" ]]; then
            _err "端口 $sub_port 已被 [$conflict_proto] 协议占用"
            _warn "请选择其他端口"
            continue
        fi
        
        # 检查系统端口占用
        if ss -tuln 2>/dev/null | grep -q ":$sub_port " || netstat -tuln 2>/dev/null | grep -q ":$sub_port "; then
            _warn "端口 $sub_port 已被系统占用"
            read -rp "  是否强制使用? [y/N]: " force
            [[ "$force" =~ ^[yY]$ ]] && break
            continue
        fi
        
        break
    done
    
    # 域名
    echo -e "  ${D}留空使用服务器IP${NC}"
    read -rp "  域名 (可选): " sub_domain
    
    # HTTPS
    local use_https="true"
    read -rp "  启用 HTTPS? [Y/n]: " https_choice
    [[ "$https_choice" =~ ^[nN]$ ]] && use_https="false"
    
    # 生成订阅文件
    generate_sub_files
    
    # 获取订阅 UUID
    local sub_uuid=$(get_sub_uuid)
    local sub_dir="$CFG/subscription/$sub_uuid"
    local server_name="${sub_domain:-$(get_ipv4)}"
    
    # 配置 Nginx - 根据系统选择正确的配置目录
    local nginx_conf_dir="/etc/nginx/conf.d"
    [[ -d "/etc/nginx/http.d" ]] && nginx_conf_dir="/etc/nginx/http.d"
    local nginx_conf="$nginx_conf_dir/vless-sub.conf"
    mkdir -p "$nginx_conf_dir"
    
    # 删除可能冲突的旧配置 (包括 http.d 目录)
    rm -f /etc/nginx/conf.d/vless-fake.conf /etc/nginx/http.d/vless-fake.conf 2>/dev/null
    rm -f /etc/nginx/sites-enabled/vless-fake 2>/dev/null
    
    if [[ "$use_https" == "true" ]]; then
        # HTTPS 模式：需要证书
        local cert_file="$CFG/certs/server.crt"
        local key_file="$CFG/certs/server.key"
        
        # 检查证书是否存在，不存在则生成自签名证书
        if [[ ! -f "$cert_file" || ! -f "$key_file" ]]; then
            _info "生成自签名证书..."
            mkdir -p "$CFG/certs"
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$key_file" -out "$cert_file" \
                -subj "/CN=$server_name" 2>/dev/null
        fi
        
        cat > "$nginx_conf" << EOF
server {
    listen $sub_port ssl http2;
    listen [::]:$sub_port ssl http2;
    server_name $server_name;

    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.html;

    # 订阅路径
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }

    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }

    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    server_tokens off;
}
EOF
    else
        # HTTP 模式
        cat > "$nginx_conf" << EOF
server {
    listen $sub_port;
    listen [::]:$sub_port;
    server_name $server_name;

    root /var/www/html;
    index index.html;

    # 订阅路径
    location ~ ^/sub/([a-f0-9-]+)/v2ray\$ {
        alias $CFG/subscription/\$1/base64;
        default_type text/plain;
        add_header Content-Type "text/plain; charset=utf-8";
    }

    location ~ ^/sub/([a-f0-9-]+)/clash\$ {
        alias $CFG/subscription/\$1/clash.yaml;
        default_type text/yaml;
    }

    location ~ ^/sub/([a-f0-9-]+)/surge\$ {
        alias $CFG/subscription/\$1/surge.conf;
        default_type text/plain;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }

    server_tokens off;
}
EOF
    fi
    
    # 确保伪装网页存在
    mkdir -p /var/www/html
    if [[ ! -f "/var/www/html/index.html" ]]; then
        cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; text-align: center; }
        p { color: #666; line-height: 1.6; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to Our Website</h1>
        <p>This is a simple website hosted on our server.</p>
    </div>
</body>
</html>
HTMLEOF
    fi
    
    # 保存订阅配置
    cat > "$CFG/sub.info" << EOF
sub_uuid=$sub_uuid
sub_port=$sub_port
sub_domain=$sub_domain
sub_https=$use_https
EOF
    
    # 添加域名到 hosts（解决部分 VPS 环境下的本地回环问题）
    if [[ -n "$sub_domain" ]]; then
        if ! grep -q "127.0.0.1 $sub_domain" /etc/hosts 2>/dev/null; then
            echo "127.0.0.1 $sub_domain" >> /etc/hosts
            _info "已添加域名到 /etc/hosts（优化本地访问）"
        fi
    fi
    
    # 测试并重载 Nginx
    if nginx -t 2>/dev/null; then
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-update add nginx default 2>/dev/null
            rc-service nginx restart 2>/dev/null
        else
            systemctl enable nginx 2>/dev/null
            systemctl restart nginx 2>/dev/null
        fi
        _ok "订阅服务已配置"
    else
        _err "Nginx 配置错误"
        nginx -t
        rm -f "$nginx_conf"
        _pause
        return
    fi
    
    echo ""
    show_sub_links
    _pause
}

#═══════════════════════════════════════════════════════════════════════════════
# Cloudflare Tunnel 内网穿透
#═══════════════════════════════════════════════════════════════════════════════

# Cloudflare Tunnel 常量
readonly CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
readonly CLOUDFLARED_DIR="/etc/cloudflared"
readonly CLOUDFLARED_CONFIG="$CLOUDFLARED_DIR/config.yml"
readonly CLOUDFLARED_SERVICE="cloudflared"

# cloudflared 全局参数（支持 IPv6-only 机器）
# --edge-ip-version auto: 让 cloudflared 自动选择 IPv4/IPv6 连接 Cloudflare 边缘
readonly CLOUDFLARED_EDGE_OPTS="--edge-ip-version auto"

# 检测 cloudflared 是否已安装
_is_cloudflared_installed() {
    [[ -x "$CLOUDFLARED_BIN" ]] && return 0
    check_cmd cloudflared && return 0
    return 1
}

# 获取 cloudflared 版本
_get_cloudflared_version() {
    if _is_cloudflared_installed; then
        "$CLOUDFLARED_BIN" --version 2>/dev/null | awk '{print $3}' | head -1
    else
        echo "未安装"
    fi
}

# 获取隧道运行状态
_get_tunnel_status() {
    if ! _is_cloudflared_installed; then
        echo "未安装"
        return
    fi
    
    if [[ ! -f "$CLOUDFLARED_CONFIG" ]]; then
        echo "未配置"
        return
    fi
    
    # 检查服务状态
    if [[ "$DISTRO" == "alpine" ]]; then
        if rc-service "$CLOUDFLARED_SERVICE" status 2>/dev/null | grep -q "started"; then
            echo "运行中"
        else
            echo "已停止"
        fi
    else
        if systemctl is-active "$CLOUDFLARED_SERVICE" 2>/dev/null | grep -q "^active"; then
            echo "运行中"
        else
            echo "已停止"
        fi
    fi
}

# 获取当前隧道名称
_get_tunnel_name() {
    if [[ -f "$CLOUDFLARED_DIR/tunnel.info" ]]; then
        grep "^tunnel_name=" "$CLOUDFLARED_DIR/tunnel.info" 2>/dev/null | cut -d'=' -f2
    fi
}

# 获取当前隧道域名
_get_tunnel_hostname() {
    # 优先从 tunnel.info 读取
    if [[ -f "$CLOUDFLARED_DIR/tunnel.info" ]]; then
        local hostname=$(grep "^hostname=" "$CLOUDFLARED_DIR/tunnel.info" 2>/dev/null | cut -d'=' -f2)
        if [[ -n "$hostname" ]]; then
            echo "$hostname"
            return
        fi
    fi
    # 备用：从 config.yml 读取
    if [[ -f "$CLOUDFLARED_CONFIG" ]]; then
        grep "hostname:" "$CLOUDFLARED_CONFIG" 2>/dev/null | head -1 | sed 's/.*hostname:[[:space:]]*//'
    fi
}

# 同步隧道配置（协议安装后调用）
# 解决协议配置更新后隧道连接失败的问题
_sync_tunnel_config() {
    # 如果没有隧道配置，直接返回
    [[ ! -f "$CLOUDFLARED_DIR/tunnel.info" ]] && return 0
    [[ ! -f "$CLOUDFLARED_CONFIG" ]] && return 0
    
    local tunnel_protocol=$(grep "^protocol=" "$CLOUDFLARED_DIR/tunnel.info" 2>/dev/null | cut -d'=' -f2)
    [[ -z "$tunnel_protocol" ]] && return 0
    
    local need_restart=false
    
    # 1. 修复 Host header（如果存在 wsSettings）
    if [[ -f "$CFG/config.json" ]] && grep -q '"Host":' "$CFG/config.json" 2>/dev/null; then
        # 检查 Host 是否已经为空
        if ! grep -q '"Host": *""' "$CFG/config.json"; then
            # 清空 Host header
            sed -i 's/"Host": *"[^"]*"/"Host": ""/g' "$CFG/config.json" 2>/dev/null
            need_restart=true
        fi
    fi
    
    # 2. 根据当前模式更新 cloudflared 的 http/https 配置
    # 检测是否有主协议（如 REALITY），如果有则 WS 没有 TLS，用 http
    local current_scheme=""
    if grep -q "service: https://" "$CLOUDFLARED_CONFIG" 2>/dev/null; then
        current_scheme="https"
    elif grep -q "service: http://" "$CLOUDFLARED_CONFIG" 2>/dev/null; then
        current_scheme="http"
    fi
    
    local expected_scheme="http"
    # 如果 WS 配置有 TLS（独立模式），用 https
    if [[ -f "$CFG/config.json" ]]; then
        if grep -A20 "vless-ws" "$CFG/config.json" 2>/dev/null | grep -q '"security": *"tls"'; then
            expected_scheme="https"
        fi
    fi
    
    # 如果 scheme 不匹配，更新配置
    if [[ -n "$current_scheme" && "$current_scheme" != "$expected_scheme" ]]; then
        sed -i "s|service: ${current_scheme}://|service: ${expected_scheme}://|g" "$CLOUDFLARED_CONFIG" 2>/dev/null
        # 重启 cloudflared
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-service "$CLOUDFLARED_SERVICE" restart 2>/dev/null
        else
            systemctl restart "$CLOUDFLARED_SERVICE" 2>/dev/null
        fi
    fi
    
    # 3. 如果需要，重启 xray
    if [[ "$need_restart" == "true" ]]; then
        if [[ "$DISTRO" == "alpine" ]]; then
            rc-service xray restart 2>/dev/null || pkill -HUP xray 2>/dev/null
        else
            systemctl restart xray 2>/dev/null || pkill -HUP xray 2>/dev/null
        fi
    fi
    
    return 0
}

# 安装 cloudflared
install_cloudflared() {
    _header
    echo -e "  ${W}安装 cloudflared${NC}"
    _line
    
    if _is_cloudflared_installed; then
        local ver=$(_get_cloudflared_version)
        echo -e "  ${Y}cloudflared 已安装 (v$ver)${NC}"
        echo ""
        read -rp "  是否重新安装? [y/N]: " reinstall
        [[ ! "$reinstall" =~ ^[yY]$ ]] && return 0
    fi
    
    _info "检测系统架构..."
    local arch=$(uname -m)
    local dl_arch=""
    case "$arch" in
        x86_64|amd64)
            dl_arch="amd64"
            ;;
        aarch64|arm64)
            dl_arch="arm64"
            ;;
        armv7l|armhf)
            dl_arch="arm"
            ;;
        *)
            _err "不支持的架构: $arch"
            return 1
            ;;
    esac
    echo -e "  架构: ${G}$arch${NC} → ${G}linux-$dl_arch${NC}"
    
    _info "下载 cloudflared..."
    local dl_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$dl_arch"
    local tmp_file=$(mktemp)
    
    if curl -fsSL --connect-timeout 30 -o "$tmp_file" "$dl_url"; then
        chmod +x "$tmp_file"
        mv "$tmp_file" "$CLOUDFLARED_BIN"
        
        # 创建配置目录
        mkdir -p "$CLOUDFLARED_DIR"
        
        local ver=$(_get_cloudflared_version)
        _ok "cloudflared 安装成功 (v$ver)"
        return 0
    else
        rm -f "$tmp_file"
        _err "下载失败，请检查网络连接"
        return 1
    fi
}

# 登录认证
cloudflared_login() {
    _header
    echo -e "  ${W}Cloudflare 登录认证${NC}"
    _line
    
    if ! _is_cloudflared_installed; then
        _err "cloudflared 未安装，请先安装"
        _pause
        return 1
    fi
    
    # 检查是否已认证
    if [[ -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
        echo -e "  ${Y}检测到已有认证证书${NC}"
        read -rp "  是否重新认证? [y/N]: " reauth
        if [[ ! "$reauth" =~ ^[yY]$ ]]; then
            _ok "保留现有认证"
            return 0
        fi
    fi
    
    echo ""
    echo -e "  ${C}请在浏览器中打开以下链接完成认证:${NC}"
    echo ""
    
    # 运行登录命令
    "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel login
    
    if [[ -f "$HOME/.cloudflared/cert.pem" ]]; then
        # 移动证书到配置目录
        mkdir -p "$CLOUDFLARED_DIR"
        mv "$HOME/.cloudflared/cert.pem" "$CLOUDFLARED_DIR/cert.pem"
        _ok "认证成功"
        return 0
    elif [[ -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
        _ok "认证成功"
        return 0
    else
        _err "认证失败或已取消"
        return 1
    fi
}

# 创建隧道（交互式）- 合并创建和配置流程
create_tunnel_interactive() {
    _header
    echo -e "  ${W}创建/配置 Cloudflare Tunnel${NC}"
    _line
    
    if ! _is_cloudflared_installed; then
        _err "cloudflared 未安装"
        return 1
    fi
    
    if [[ ! -f "$CLOUDFLARED_DIR/cert.pem" ]]; then
        _err "未认证，请先登录"
        return 1
    fi
    
    # 检查现有隧道（本地配置）
    local existing_tunnel=$(_get_tunnel_name)
    local need_create=true
    
    # 初始化变量，防止后续引用报错
    local tunnel_name=""
    local tunnel_id=""
    
    # 同时检查 Cloudflare 远程是否有隧道（本地配置可能已丢失）
    if [[ -z "$existing_tunnel" ]]; then
        _info "检查 Cloudflare 账户中的隧道..."
        local remote_tunnels=$("$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel list 2>/dev/null) || true
        local tunnel_names=$(echo "$remote_tunnels" | grep -E "^[a-f0-9-]{36}" | awk '{print $2}' | head -5 || true)
        if [[ -n "$tunnel_names" ]]; then
            echo ""
            echo -e "  ${Y}Cloudflare 账户中已有隧道:${NC}"
            echo "$tunnel_names" | while read tname; do
                echo -e "    ${D}• $tname${NC}"
            done
            echo ""
            echo -e "  ${D}提示: 使用相同名称会创建失败，请选择不同的名称${NC}"
        fi
    fi
    
    if [[ -n "$existing_tunnel" ]]; then
        echo -e "  ${Y}检测到已有隧道: $existing_tunnel${NC}"
        echo ""
        echo -e "  ${G}1${NC}) 配置现有隧道"
        echo -e "  ${G}2${NC}) 删除并创建新隧道"
        echo -e "  ${G}0${NC}) 取消"
        echo ""
        read -rp "  请选择: " tunnel_choice
        
        case "$tunnel_choice" in
            1)
                need_create=false
                tunnel_name="$existing_tunnel"
                
                # 尝试从 tunnel.info 读取 ID
                if [[ -f "$CLOUDFLARED_DIR/tunnel.info" ]]; then
                    tunnel_id=$(grep "^tunnel_id=" "$CLOUDFLARED_DIR/tunnel.info" | cut -d'=' -f2)
                fi
                
                # 如果文件里没读到，尝试通过命令行获取
                if [[ -z "$tunnel_id" ]]; then
                    _info "正在获取隧道 ID..."
                    tunnel_id=$("$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel list 2>/dev/null | grep "$tunnel_name" | awk '{print $1}' | head -1)
                fi
                
                if [[ -z "$tunnel_id" ]]; then
                    _err "无法获取隧道 ID，建议选择删除并重建"
                    _pause
                    return 1
                fi
                
                # 确保 tunnel.info 文件存在且包含正确信息
                if [[ ! -f "$CLOUDFLARED_DIR/tunnel.info" ]] || ! grep -q "^tunnel_id=" "$CLOUDFLARED_DIR/tunnel.info"; then
                    cat > "$CLOUDFLARED_DIR/tunnel.info" << EOF
tunnel_name=$tunnel_name
tunnel_id=$tunnel_id
EOF
                fi
                ;;
            2)
                _info "删除现有隧道..."
                _stop_tunnel_service 2>/dev/null
                "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel delete "$existing_tunnel" 2>/dev/null
                rm -f "$CLOUDFLARED_DIR/tunnel.info"
                rm -f "$CLOUDFLARED_DIR/config.yml"
                rm -f "$CLOUDFLARED_DIR"/*.json
                ;;
            *)
                return 0
                ;;
        esac
    fi
    
    # 创建新隧道
    if [[ "$need_create" == "true" ]]; then
        echo ""
        echo -e "  ${D}隧道名称仅用于标识，不影响访问域名${NC}"
        local default_name="vless-tunnel"
        read -rp "  隧道名称 [$default_name]: " tunnel_name
        tunnel_name="${tunnel_name:-$default_name}"
        
        _info "创建隧道..."
        local output=$("$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel create "$tunnel_name" 2>&1)
        
        if echo "$output" | grep -q "Created tunnel"; then
            local tunnel_id=$(echo "$output" | awk '/Created tunnel/ {for(i=1;i<=NF;i++) if($i ~ /^[a-f0-9-]{36}$/) print $i}' | head -1)
            
            # 保存隧道信息
            cat > "$CLOUDFLARED_DIR/tunnel.info" << EOF
tunnel_name=$tunnel_name
tunnel_id=$tunnel_id
created=$(date '+%Y-%m-%d %H:%M:%S')
EOF
            
            # 移动凭证文件
            if [[ -f "$HOME/.cloudflared/$tunnel_id.json" ]]; then
                mv "$HOME/.cloudflared/$tunnel_id.json" "$CLOUDFLARED_DIR/"
            fi
            
            _ok "隧道创建成功"
            echo -e "  隧道名称: ${G}$tunnel_name${NC}"
            echo -e "  隧道 ID: ${G}$tunnel_id${NC}"
        elif echo "$output" | grep -q "tunnel with name already exists"; then
            # 隧道已存在于 Cloudflare，尝试同步到本地
            echo ""
            echo -e "  ${Y}隧道 '$tunnel_name' 已存在于 Cloudflare 账户中${NC}"
            echo ""
            echo -e "  ${G}1${NC}) 同步已有隧道到本地（复用）"
            echo -e "  ${G}2${NC}) 删除远程隧道并重新创建"
            echo -e "  ${G}3${NC}) 使用其他名称创建"
            echo -e "  ${G}0${NC}) 取消"
            echo ""
            read -rp "  请选择: " exist_choice
            
            case "$exist_choice" in
                1)
                    # 同步已有隧道
                    _info "同步隧道信息..."
                    local tunnel_info=$("$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel list 2>/dev/null | grep "$tunnel_name")
                    local tunnel_id=$(echo "$tunnel_info" | awk '{print $1}')
                    if [[ -n "$tunnel_id" && "$tunnel_id" =~ ^[a-f0-9-]{36}$ ]]; then
                        cat > "$CLOUDFLARED_DIR/tunnel.info" << EOF
tunnel_name=$tunnel_name
tunnel_id=$tunnel_id
created=$(date '+%Y-%m-%d %H:%M:%S')
synced=true
EOF
                        # 尝试下载凭证
                        if [[ ! -f "$CLOUDFLARED_DIR/$tunnel_id.json" ]]; then
                            _warn "凭证文件不存在，需要重新创建隧道或手动恢复凭证"
                            echo -e "  ${D}提示: 隧道凭证在创建时生成，无法重新下载${NC}"
                            echo -e "  ${D}      建议选择 2 删除后重新创建${NC}"
                            _pause
                            return 1
                        fi
                        _ok "隧道同步成功"
                        echo -e "  隧道 ID: ${G}$tunnel_id${NC}"
                    else
                        _err "无法获取隧道信息"
                        _pause
                        return 1
                    fi
                    ;;
                2)
                    # 删除远程隧道
                    _info "删除远程隧道..."
                    if "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel delete "$tunnel_name" 2>&1; then
                        _ok "远程隧道已删除"
                        # 递归调用重新创建
                        create_tunnel_interactive
                        return $?
                    else
                        _err "删除失败"
                        _pause
                        return 1
                    fi
                    ;;
                3)
                    # 重新选择名称
                    echo ""
                    read -rp "  请输入新的隧道名称: " new_name
                    if [[ -n "$new_name" ]]; then
                        tunnel_name="$new_name"
                        # 递归创建（简化处理）
                        local output2=$("$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel create "$tunnel_name" 2>&1)
                        if echo "$output2" | grep -q "Created tunnel"; then
                            local tunnel_id=$(echo "$output2" | awk '/Created tunnel/ {for(i=1;i<=NF;i++) if($i ~ /^[a-f0-9-]{36}$/) print $i}' | head -1)
                            cat > "$CLOUDFLARED_DIR/tunnel.info" << EOF
tunnel_name=$tunnel_name
tunnel_id=$tunnel_id
created=$(date '+%Y-%m-%d %H:%M:%S')
EOF
                            [[ -f "$HOME/.cloudflared/$tunnel_id.json" ]] && mv "$HOME/.cloudflared/$tunnel_id.json" "$CLOUDFLARED_DIR/"
                            _ok "隧道创建成功"
                            echo -e "  隧道 ID: ${G}$tunnel_id${NC}"
                        else
                            _err "创建失败"
                            echo "$output2"
                            _pause
                            return 1
                        fi
                    else
                        return 0
                    fi
                    ;;
                *)
                    return 0
                    ;;
            esac
        else
            _err "隧道创建失败"
            echo ""
            echo -e "  ${Y}错误输出:${NC}"
            echo "$output"
            echo ""
            echo -e "  ${D}提示: 如果是纯 IPv6 机器，请确保 cloudflared 版本 >= 2023.3.0${NC}"
            echo -e "  ${D}      可以尝试手动执行: cloudflared --edge-ip-version 6 tunnel create test${NC}"
            _pause
            return 1
        fi
    fi
    
    # 自动进入配置协议流程
    echo ""
    printf "  是否现在配置协议? [Y/n]: "
    config_now=""
    read config_now || true
    config_now="${config_now:-y}"
    
    # Alpine 兼容性：使用 case 替代正则表达式
    case "$config_now" in
        [nN]|[nN][oO])
            return 0
            ;;
        *)
            add_protocol_to_tunnel
            return $?
            ;;
    esac
}

# 快速隧道模式 (trycloudflare.com)
create_quick_tunnel() {
    _header
    echo -e "  ${W}快速隧道 (Quick Tunnel)${NC}"
    _line
    
    if ! _is_cloudflared_installed; then
        _err "cloudflared 未安装"
        _pause
        return 1
    fi
    
    echo -e "  ${Y}注意：快速隧道无需认证和域名${NC}"
    echo -e "  ${Y}      但域名每次重启会变化，仅适合临时测试${NC}"
    echo ""
    
    # 列出可用的 CDN 协议
    local ws_protocols=""
    local idx=1
    local proto_array=()
    
    if db_exists "xray" "vless-ws"; then
        local port=$(db_get_field "xray" "vless-ws" "port")
        echo -e "  ${G}$idx${NC}) VLESS-WS (端口: $port)"
        proto_array+=("vless-ws:$port")
        ((idx++))
    fi
    
    if db_exists "xray" "vmess-ws"; then
        local port=$(db_get_field "xray" "vmess-ws" "port")
        echo -e "  ${G}$idx${NC}) VMess-WS (端口: $port)"
        proto_array+=("vmess-ws:$port")
        ((idx++))
    fi
    
    if db_exists "xray" "vless-ws-notls"; then
        local port=$(db_get_field "xray" "vless-ws-notls" "port")
        echo -e "  ${G}$idx${NC}) VLESS-WS-CF (端口: $port, 无TLS)"
        proto_array+=("vless-ws-notls:$port")
        ((idx++))
    fi
    
    if [[ ${#proto_array[@]} -eq 0 ]]; then
        _warn "未找到支持 CDN 穿透的协议"
        echo -e "  ${D}快速隧道支持: VLESS-WS, VMess-WS, VLESS-WS-CF${NC}"
        _pause
        return 1
    fi
    
    echo -e "  ${G}0${NC}) 取消"
    echo ""
    read -rp "  选择要暴露的协议: " proto_choice
    
    if [[ "$proto_choice" == "0" || -z "$proto_choice" ]]; then
        return 0
    fi
    
    if [[ ! "$proto_choice" =~ ^[0-9]+$ ]] || [[ $proto_choice -gt ${#proto_array[@]} ]]; then
        _err "无效选择"
        return 1
    fi
    
    local selected="${proto_array[$((proto_choice-1))]}"
    local proto_name="${selected%%:*}"
    local proto_port="${selected##*:}"
    
    # 检测协议是否为独立模式（使用 TLS）
    # 回落模式监听 127.0.0.1，独立模式监听 0.0.0.0/::
    local is_standalone=false
    local tunnel_url="http://127.0.0.1:$proto_port"
    
    # 检查是否有主协议
    if ! _has_master_protocol; then
        is_standalone=true
        # 独立模式使用 HTTPS（跳过证书验证）
        tunnel_url="https://127.0.0.1:$proto_port"
        echo -e "  ${Y}检测到独立模式 (TLS)，将使用 HTTPS 转发${NC}"
    fi
    
    echo ""
    _info "启动快速隧道..."
    echo -e "  ${D}按 Ctrl+C 停止隧道${NC}"
    echo ""
    
    # 清理旧凭证避免配置冲突
    rm -rf "$HOME/.cloudflared" 2>/dev/null
    
    # 启动快速隧道
    if [[ "$is_standalone" == "true" ]]; then
        # 独立模式：使用 HTTPS 并跳过证书验证
        "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel --no-tls-verify --url "$tunnel_url"
    else
        # 回落模式：使用 HTTP
        "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel --url "$tunnel_url"
    fi
}

# 将协议添加到隧道
add_protocol_to_tunnel() {
    _header
    echo -e "  ${W}添加协议到隧道${NC}"
    _line
    
    if ! _is_cloudflared_installed; then
        _err "cloudflared 未安装"
        _pause
        return 1
    fi
    
    local tunnel_name=$(_get_tunnel_name)
    if [[ -z "$tunnel_name" ]]; then
        _err "未创建隧道，请先创建"
        _pause
        return 1
    fi
    
    # 获取隧道 ID
    local tunnel_id=""
    if [[ -f "$CLOUDFLARED_DIR/tunnel.info" ]]; then
        tunnel_id=$(grep "^tunnel_id=" "$CLOUDFLARED_DIR/tunnel.info" | cut -d'=' -f2)
    fi
    
    if [[ -z "$tunnel_id" ]]; then
        _err "隧道信息不完整"
        return 1
    fi
    
    echo -e "  当前隧道: ${G}$tunnel_name${NC}"
    echo ""
    
    # 列出可用的 CDN 协议 (WebSocket / XHTTP)
    echo -e "  ${W}选择要暴露的协议:${NC}"
    echo ""
    
    local ws_protocols=""
    local idx=1
    local proto_array=()
    
    if db_exists "xray" "vless-ws"; then
        local port=$(db_get_field "xray" "vless-ws" "port")
        local path=$(db_get_field "xray" "vless-ws" "path")
        echo -e "  ${G}$idx${NC}) VLESS-WS (端口: $port, 路径: ${path:-/vless})"
        proto_array+=("vless-ws:$port:${path:-/vless}")
        ((idx++))
    fi
    
    if db_exists "xray" "vmess-ws"; then
        local port=$(db_get_field "xray" "vmess-ws" "port")
        local path=$(db_get_field "xray" "vmess-ws" "path")
        echo -e "  ${G}$idx${NC}) VMess-WS (端口: $port, 路径: ${path:-/vmess})"
        proto_array+=("vmess-ws:$port:${path:-/vmess}")
        ((idx++))
    fi
    
    if db_exists "xray" "vless-ws-notls"; then
        local port=$(db_get_field "xray" "vless-ws-notls" "port")
        local path=$(db_get_field "xray" "vless-ws-notls" "path")
        echo -e "  ${G}$idx${NC}) VLESS-WS-CF (端口: $port, 路径: ${path:-/vless}, 无TLS)"
        proto_array+=("vless-ws-notls:$port:${path:-/vless}")
        ((idx++))
    fi
    
    if [[ ${#proto_array[@]} -eq 0 ]]; then
        _warn "未找到支持 CDN 穿透的协议"
        echo ""
        echo -e "  ${D}Cloudflare Tunnel 支持以下协议:${NC}"
        echo -e "  ${D}  - VLESS-WS (WebSocket)${NC}"
        echo -e "  ${D}  - VMess-WS (WebSocket)${NC}"
        echo -e "  ${D}  - VLESS-WS-CF (无TLS, 专为 CF Tunnel 设计)${NC}"
        echo ""
        echo -e "  ${D}请先安装上述协议${NC}"
        _pause
        return 1
    fi
    
    echo -e "  ${G}0${NC}) 取消"
    echo ""
    read -rp "  请选择: " proto_choice
    
    if [[ "$proto_choice" == "0" || -z "$proto_choice" ]]; then
        return 0
    fi
    
    # Alpine 兼容性：使用 case 替代正则
    case "$proto_choice" in
        ''|*[!0-9]*)
            _err "无效选择"
            return 1
            ;;
    esac
    if [[ $proto_choice -gt ${#proto_array[@]} ]]; then
        _err "无效选择"
        return 1
    fi
    
    local selected="${proto_array[$((proto_choice-1))]}"
    IFS=':' read -r proto_name proto_port proto_path <<< "$selected"
    
    echo ""
    echo -e "  ${D}输入要绑定的域名 (必须已在 Cloudflare 托管)${NC}"
    read -rp "  域名: " hostname
    
    if [[ -z "$hostname" ]]; then
        _err "域名不能为空"
        return 1
    fi
    
    # 询问是否修改协议监听地址
    echo ""
    echo -e "  ${Y}安全建议:${NC}"
    echo -e "  ${D}将协议监听地址改为 127.0.0.1 可防止直接访问${NC}"
    echo -e "  ${D}但这意味着只能通过隧道访问${NC}"
    echo ""
    read -rp "  是否修改监听为 127.0.0.1? [Y/n]: " modify_listen
    
    local listen_addr="127.0.0.1"
    # Alpine 兼容性：使用 case 替代正则
    case "$modify_listen" in
        [nN]) listen_addr="0.0.0.0" ;;
    esac
    
    _info "生成隧道配置..."
    
    # 检测是否为独立模式（使用 TLS）
    local service_scheme="http"
    local origin_tls_config=""
    if ! _has_master_protocol; then
        service_scheme="https"
        origin_tls_config="    originRequest:
      noTLSVerify: true"
        echo -e "  ${Y}检测到独立模式 (TLS)，将使用 HTTPS 转发${NC}"
    fi
    
    # 生成配置文件（不限制 path，由后端服务处理路由）
    cat > "$CLOUDFLARED_CONFIG" << EOF
tunnel: $tunnel_id
credentials-file: $CLOUDFLARED_DIR/$tunnel_id.json

ingress:
  - hostname: $hostname
    service: $service_scheme://$listen_addr:$proto_port
$origin_tls_config
  - service: http_status:404
EOF
    
    # 保存域名信息
    echo "hostname=$hostname" >> "$CLOUDFLARED_DIR/tunnel.info"
    echo "protocol=$proto_name" >> "$CLOUDFLARED_DIR/tunnel.info"
    echo "port=$proto_port" >> "$CLOUDFLARED_DIR/tunnel.info"
    
    _ok "隧道配置已生成"
    
    # 修改 xray 配置中的 Host header，使其兼容隧道域名
    if [[ -f "$CFG/config.json" ]]; then
        _info "更新 xray 配置以兼容隧道..."
        # 将 wsSettings.headers.Host 设置为空，允许任意 Host
        if grep -q '"Host":' "$CFG/config.json"; then
            # 使用 jq 修改（如果可用）
            if check_cmd jq; then
                local tmp_config=$(mktemp)
                jq '(.inbounds[] | select(.streamSettings.wsSettings != null) | .streamSettings.wsSettings.headers.Host) = ""' \
                    "$CFG/config.json" > "$tmp_config" 2>/dev/null && mv "$tmp_config" "$CFG/config.json"
            else
                # 使用 sed 替换（兼容无 jq 环境）
                sed -i 's/"Host": *"[^"]*"/"Host": ""/g' "$CFG/config.json"
            fi
            
            # 重启 xray 使配置生效
            if [[ "$DISTRO" == "alpine" ]]; then
                rc-service xray restart 2>/dev/null || pkill -HUP xray 2>/dev/null
            else
                systemctl restart xray 2>/dev/null || pkill -HUP xray 2>/dev/null
            fi
            _ok "xray 配置已更新"
        fi
    fi
    
    echo ""
    
    # 配置 DNS
    echo -e "  ${W}配置 DNS 记录${NC}"
    echo ""
    echo -e "  ${D}需要将域名指向隧道，有两种方式:${NC}"
    echo -e "  ${G}1${NC}) 自动配置 (使用 cloudflared)"
    echo -e "  ${G}2${NC}) 手动配置 CNAME"
    echo ""
    read -rp "  请选择 [1]: " dns_choice
    dns_choice="${dns_choice:-1}"
    
    if [[ "$dns_choice" == "1" ]]; then
        _info "配置 DNS..."
        if "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel route dns "$tunnel_name" "$hostname" 2>/dev/null; then
            _ok "DNS 配置成功"
        else
            _warn "DNS 自动配置失败，请手动添加 CNAME 记录"
            echo -e "  ${D}CNAME: $hostname → $tunnel_id.cfargotunnel.com${NC}"
        fi
    else
        echo ""
        echo -e "  ${C}请手动添加以下 DNS 记录:${NC}"
        echo -e "  类型: ${G}CNAME${NC}"
        echo -e "  名称: ${G}$hostname${NC}"
        echo -e "  目标: ${G}$tunnel_id.cfargotunnel.com${NC}"
        echo -e "  代理: ${G}已启用 (橙色云朵)${NC}"
    fi
    
    echo ""
    
    # 创建系统服务
    _setup_cloudflared_service
    
    echo ""
    read -rp "  是否立即启动隧道? [Y/n]: " start_now
    # Alpine 兼容性：使用 case 替代正则
    case "$start_now" in
        [nN]) ;; # 不启动
        *)
            _start_tunnel_service
            
        # 显示分享链接
        echo ""
        _line
        echo -e "  ${W}隧道连接信息${NC}"
        _line
        
        local uuid=""
        local path=""
        
        case "$proto_name" in
            "vless-ws")
                uuid=$(db_get_field "xray" "vless-ws" "uuid")
                path=$(db_get_field "xray" "vless-ws" "path")
                path="${path:-/vless}"
                
                if [[ -n "$uuid" ]]; then
                    local encoded_path=$(echo "$path" | sed 's/\//%2F/g')
                    local share_link="vless://${uuid}@${hostname}:443?encryption=none&security=tls&sni=${hostname}&type=ws&host=${hostname}&path=${encoded_path}#CF-VLESS-WS"
                    
                    echo -e "  ${C}分享链接:${NC}"
                    echo -e "  $share_link"
                fi
                ;;
            "vmess-ws")
                uuid=$(db_get_field "xray" "vmess-ws" "uuid")
                path=$(db_get_field "xray" "vmess-ws" "path")
                path="${path:-/vmess}"
                
                if [[ -n "$uuid" ]]; then
                    local vmess_json="{\"v\":\"2\",\"ps\":\"CF-VMess-WS\",\"add\":\"${hostname}\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${hostname}\",\"path\":\"${path}\",\"tls\":\"tls\",\"sni\":\"${hostname}\"}"
                    local vmess_b64=$(echo -n "$vmess_json" | base64 -w 0 2>/dev/null || echo -n "$vmess_json" | base64 2>/dev/null)
                    local share_link="vmess://${vmess_b64}"
                    
                    echo -e "  ${C}分享链接:${NC}"
                    echo -e "  $share_link"
                fi
                ;;
            "vless-xhttp")
                uuid=$(db_get_field "xray" "vless-xhttp" "uuid")
                path=$(db_get_field "xray" "vless-xhttp" "path")
                path="${path:-/xhttp}"
                
                if [[ -n "$uuid" ]]; then
                    local encoded_path=$(echo "$path" | sed 's/\//%2F/g')
                    # XHTTP 分享链接: type=xhttp, alpn=h2
                    local share_link="vless://${uuid}@${hostname}:443?encryption=none&security=tls&sni=${hostname}&type=xhttp&host=${hostname}&path=${encoded_path}&mode=auto#CF-VLESS-XHTTP"
                    
                    echo -e "  ${C}分享链接:${NC}"
                    echo -e "  $share_link"
                fi
                ;;
            "vless-ws-notls")
                uuid=$(db_get_field "xray" "vless-ws-notls" "uuid")
                path=$(db_get_field "xray" "vless-ws-notls" "path")
                path="${path:-/vless}"
                
                if [[ -n "$uuid" ]]; then
                    local encoded_path=$(echo "$path" | sed 's/\//%2F/g')
                    # CF Tunnel 提供 TLS，所以分享链接使用 TLS
                    local share_link="vless://${uuid}@${hostname}:443?encryption=none&security=tls&sni=${hostname}&type=ws&host=${hostname}&path=${encoded_path}#CF-VLESS-WS"
                    
                    echo -e "  ${C}分享链接:${NC}"
                    echo -e "  $share_link"
                fi
                ;;
        esac
        
        echo ""
        echo -e "  ${D}客户端配置: 地址=${hostname}, 端口=443, TLS=开启${NC}"
            ;;
    esac
    
    _pause
}

# 创建 systemd/openrc 服务
_setup_cloudflared_service() {
    _info "创建系统服务..."
    
    if [[ "$DISTRO" == "alpine" ]]; then
        # OpenRC 服务
        cat > "/etc/init.d/$CLOUDFLARED_SERVICE" << 'EOF'
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel"
command="/usr/local/bin/cloudflared"
command_args="--edge-ip-version auto tunnel run"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x "/etc/init.d/$CLOUDFLARED_SERVICE"
        rc-update add "$CLOUDFLARED_SERVICE" default 2>/dev/null
        _ok "OpenRC 服务已创建"
    else
        # systemd 服务
        cat > "/etc/systemd/system/${CLOUDFLARED_SERVICE}.service" << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=$CLOUDFLARED_BIN --edge-ip-version auto tunnel run
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$CLOUDFLARED_SERVICE" 2>/dev/null
        _ok "systemd 服务已创建"
    fi
}

# 启动隧道服务
_start_tunnel_service() {
    _info "启动隧道服务..."
    
    if [[ "$DISTRO" == "alpine" ]]; then
        rc-service "$CLOUDFLARED_SERVICE" start 2>/dev/null
    else
        systemctl start "$CLOUDFLARED_SERVICE" 2>/dev/null
    fi
    
    sleep 2
    
    local status=$(_get_tunnel_status)
    if [[ "$status" == "运行中" ]]; then
        _ok "隧道已启动"
    else
        _warn "隧道启动可能失败，请检查日志"
    fi
}

# 停止隧道服务
_stop_tunnel_service() {
    _info "停止隧道服务..."
    
    if [[ "$DISTRO" == "alpine" ]]; then
        rc-service "$CLOUDFLARED_SERVICE" stop 2>/dev/null
    else
        systemctl stop "$CLOUDFLARED_SERVICE" 2>/dev/null
    fi
    
    _ok "隧道已停止"
}

# 显示隧道状态
show_tunnel_status() {
    _header
    echo -e "  ${W}Cloudflare Tunnel 状态${NC}"
    _line
    
    local status=$(_get_tunnel_status)
    local tunnel_name=$(_get_tunnel_name)
    local hostname=$(_get_tunnel_hostname)
    local version=$(_get_cloudflared_version)
    
    echo -e "  cloudflared: ${G}v$version${NC}"
    echo ""
    
    case "$status" in
        "运行中")
            echo -e "  状态: ${G}● 运行中${NC}"
            ;;
        "已停止")
            echo -e "  状态: ${R}○ 已停止${NC}"
            ;;
        "未配置")
            echo -e "  状态: ${Y}◐ 未配置${NC}"
            ;;
        *)
            echo -e "  状态: ${D}未安装${NC}"
            _pause
            return
            ;;
    esac
    
    if [[ -n "$tunnel_name" ]]; then
        echo -e "  隧道: ${G}$tunnel_name${NC}"
    fi
    
    if [[ -n "$hostname" ]]; then
        echo -e "  域名: ${G}$hostname${NC}"
    fi
    
    # 显示配置的协议和分享链接
    if [[ -f "$CLOUDFLARED_DIR/tunnel.info" ]]; then
        local proto=$(grep "^protocol=" "$CLOUDFLARED_DIR/tunnel.info" 2>/dev/null | cut -d'=' -f2)
        local port=$(grep "^port=" "$CLOUDFLARED_DIR/tunnel.info" 2>/dev/null | cut -d'=' -f2)
        if [[ -n "$proto" ]]; then
            echo -e "  协议: ${G}$proto${NC} (端口: $port)"
        fi
        
        # 如果有域名和协议配置，显示隧道分享链接
        if [[ -n "$hostname" && -n "$proto" ]]; then
            echo ""
            _line
            echo -e "  ${W}隧道连接信息${NC}"
            _line
            
            # 获取协议配置
            local uuid=""
            local path=""
            
            case "$proto" in
                "vless-ws")
                    uuid=$(db_get_field "xray" "vless-ws" "uuid")
                    path=$(db_get_field "xray" "vless-ws" "path")
                    path="${path:-/vless}"
                    
                    if [[ -n "$uuid" ]]; then
                        local encoded_path=$(echo "$path" | sed 's/\//%2F/g')
                        local share_link="vless://${uuid}@${hostname}:443?encryption=none&security=tls&sni=${hostname}&type=ws&host=${hostname}&path=${encoded_path}#CF-VLESS-WS"
                        
                        echo -e "  ${C}分享链接:${NC}"
                        echo -e "  $share_link"
                        echo ""
                        echo -e "  ${C}二维码:${NC}"
                        echo -e "  $(gen_qr "$share_link")"
                        echo ""
                        echo -e "  ${D}客户端配置: 地址=${hostname}, 端口=443, TLS=开启${NC}"
                    fi
                    ;;
                "vmess-ws")
                    uuid=$(db_get_field "xray" "vmess-ws" "uuid")
                    path=$(db_get_field "xray" "vmess-ws" "path")
                    path="${path:-/vmess}"
                    
                    if [[ -n "$uuid" ]]; then
                        # VMess 需要 base64 编码的 JSON
                        local vmess_json="{\"v\":\"2\",\"ps\":\"CF-VMess-WS\",\"add\":\"${hostname}\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${hostname}\",\"path\":\"${path}\",\"tls\":\"tls\",\"sni\":\"${hostname}\"}"
                        local vmess_b64=$(echo -n "$vmess_json" | base64 -w 0 2>/dev/null || echo -n "$vmess_json" | base64 2>/dev/null)
                        local share_link="vmess://${vmess_b64}"
                        
                        echo -e "  ${C}分享链接:${NC}"
                        echo -e "  $share_link"
                        echo ""
                        echo -e "  ${C}二维码:${NC}"
                        echo -e "  $(gen_qr "$share_link")"
                        echo ""
                        echo -e "  ${D}客户端配置: 地址=${hostname}, 端口=443, TLS=开启${NC}"
                    fi
                    ;;
                "vless-ws-notls")
                    uuid=$(db_get_field "xray" "vless-ws-notls" "uuid")
                    path=$(db_get_field "xray" "vless-ws-notls" "path")
                    path="${path:-/vless}"
                    
                    if [[ -n "$uuid" ]]; then
                        local encoded_path=$(echo "$path" | sed 's/\//%2F/g')
                        # CF Tunnel 提供 TLS，所以分享链接使用 TLS
                        local share_link="vless://${uuid}@${hostname}:443?encryption=none&security=tls&sni=${hostname}&type=ws&host=${hostname}&path=${encoded_path}#CF-VLESS-WS"
                        
                        echo -e "  ${C}分享链接:${NC}"
                        echo -e "  $share_link"
                        echo ""
                        echo -e "  ${C}二维码:${NC}"
                        echo -e "  $(gen_qr "$share_link")"
                        echo ""
                        echo -e "  ${D}客户端配置: 地址=${hostname}, 端口=443, TLS=开启${NC}"
                    fi
                    ;;
            esac
        fi
    fi
    
    _pause
}

# 切换隧道服务状态
toggle_tunnel_service() {
    local status=$(_get_tunnel_status)
    
    if [[ "$status" == "运行中" ]]; then
        _stop_tunnel_service
    elif [[ "$status" == "已停止" ]]; then
        _start_tunnel_service
    else
        _warn "隧道未配置"
    fi
    
    _pause
}

# 查看隧道日志
show_tunnel_logs() {
    _header
    echo -e "  ${W}Cloudflare Tunnel 日志${NC}"
    _line
    
    if [[ "$DISTRO" == "alpine" ]]; then
        if [[ -f /var/log/cloudflared.log ]]; then
            tail -n 50 /var/log/cloudflared.log
        else
            _warn "日志文件不存在"
        fi
    else
        journalctl -u "$CLOUDFLARED_SERVICE" --no-pager -n 50 2>/dev/null || _warn "无法获取日志"
    fi
    
    _pause
}

# 卸载 cloudflared
uninstall_cloudflared() {
    _header
    echo -e "  ${W}卸载 Cloudflare Tunnel${NC}"
    _line
    
    if ! _is_cloudflared_installed; then
        _warn "cloudflared 未安装"
        _pause
        return
    fi
    
    echo -e "  ${Y}警告：这将删除所有隧道配置和认证信息${NC}"
    echo ""
    read -rp "  确认卸载? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        return
    fi
    
    # 停止服务
    _info "停止服务..."
    if [[ "$DISTRO" == "alpine" ]]; then
        rc-service "$CLOUDFLARED_SERVICE" stop 2>/dev/null
        rc-update del "$CLOUDFLARED_SERVICE" 2>/dev/null
        rm -f "/etc/init.d/$CLOUDFLARED_SERVICE"
    else
        systemctl stop "$CLOUDFLARED_SERVICE" 2>/dev/null
        systemctl disable "$CLOUDFLARED_SERVICE" 2>/dev/null
        rm -f "/etc/systemd/system/${CLOUDFLARED_SERVICE}.service"
        systemctl daemon-reload
    fi
    
    # 删除隧道
    local tunnel_name=$(_get_tunnel_name)
    if [[ -n "$tunnel_name" ]]; then
        _info "删除隧道..."
        "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel delete "$tunnel_name" 2>/dev/null
    fi
    
    # 删除文件
    _info "清理文件..."
    rm -f "$CLOUDFLARED_BIN"
    rm -rf "$CLOUDFLARED_DIR"
    rm -rf "$HOME/.cloudflared"
    
    _ok "cloudflared 已卸载"
    _pause
}

# 删除隧道（保留 cloudflared）
delete_tunnel() {
    _header
    echo -e "  ${W}删除 Cloudflare Tunnel${NC}"
    _line
    
    if ! _is_cloudflared_installed; then
        _err "cloudflared 未安装"
        _pause
        return
    fi
    
    # 获取所有远程隧道
    _info "获取 Cloudflare 账户中的隧道列表..."
    local tunnel_list=$("$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel list 2>/dev/null)
    
    if [[ -z "$tunnel_list" ]] || ! echo "$tunnel_list" | grep -q "^[a-f0-9]"; then
        _warn "没有找到任何隧道"
        _pause
        return
    fi
    
    echo ""
    echo -e "  ${W}Cloudflare 账户中的隧道:${NC}"
    echo ""
    
    # 解析并显示隧道列表
    local idx=1
    local tunnel_ids=()
    local tunnel_names=()
    
    while IFS= read -r line; do
        # 跳过表头
        [[ "$line" =~ ^ID ]] && continue
        [[ -z "$line" ]] && continue
        
        local tid=$(echo "$line" | awk '{print $1}')
        local tname=$(echo "$line" | awk '{print $2}')
        local tcreated=$(echo "$line" | awk '{print $3, $4}')
        local tconns=$(echo "$line" | awk '{print $5}')
        
        # 验证是否为有效 UUID
        if [[ "$tid" =~ ^[a-f0-9-]{36}$ ]]; then
            tunnel_ids+=("$tid")
            tunnel_names+=("$tname")
            
            # 标记本地配置的隧道
            local local_marker=""
            local local_name=$(_get_tunnel_name)
            if [[ "$tname" == "$local_name" ]]; then
                local_marker=" ${G}[本地]${NC}"
            fi
            
            echo -e "  ${G}$idx${NC}) $tname$local_marker"
            echo -e "     ${D}ID: $tid | 创建: $tcreated | 连接: $tconns${NC}"
            ((idx++))
        fi
    done <<< "$tunnel_list"
    
    if [[ ${#tunnel_ids[@]} -eq 0 ]]; then
        _warn "没有找到有效的隧道"
        _pause
        return
    fi
    
    echo ""
    echo -e "  ${G}0${NC}) 取消"
    echo ""
    read -rp "  选择要删除的隧道: " choice
    
    if [[ "$choice" == "0" || -z "$choice" ]]; then
        return
    fi
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -gt ${#tunnel_ids[@]} ]]; then
        _err "无效选择"
        _pause
        return
    fi
    
    local selected_id="${tunnel_ids[$((choice-1))]}"
    local selected_name="${tunnel_names[$((choice-1))]}"
    
    echo ""
    echo -e "  ${Y}警告：即将删除隧道 '$selected_name'${NC}"
    echo -e "  ${D}ID: $selected_id${NC}"
    echo ""
    read -rp "  确认删除? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        return
    fi
    
    # 停止服务（如果是本地配置的隧道）
    local local_name=$(_get_tunnel_name)
    if [[ "$selected_name" == "$local_name" ]]; then
        _info "停止本地隧道服务..."
        _stop_tunnel_service 2>/dev/null
    fi
    
    # 尝试清理连接
    _info "清理隧道连接..."
    "$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel cleanup "$selected_name" 2>/dev/null
    
    # 删除隧道
    _info "删除隧道..."
    local delete_output=$("$CLOUDFLARED_BIN" $CLOUDFLARED_EDGE_OPTS tunnel delete "$selected_name" 2>&1)
    local delete_exit_code=$?
    
    # 调试：显示错误信息以便诊断
    if [[ $delete_exit_code -eq 0 ]] || echo "$delete_output" | grep -qiE "deleted|success"; then
        _ok "隧道 '$selected_name' 已删除"
        
        # 如果是本地配置的隧道，清理本地文件
        if [[ "$selected_name" == "$local_name" ]]; then
            rm -f "$CLOUDFLARED_DIR/tunnel.info"
            rm -f "$CLOUDFLARED_CONFIG"
            rm -f "$CLOUDFLARED_DIR/$selected_id.json"
            _info "本地配置文件已清理"
        fi
        
        echo ""
        echo -e "  ${Y}提示: 相关的 DNS 记录可能需要手动在 Cloudflare 后台删除${NC}"
    else
        _err "删除失败"
        echo ""
        echo -e "  ${Y}错误信息:${NC}"
        echo "$delete_output"
    fi
    
    _pause
}

# Cloudflare Tunnel 管理菜单
manage_cloudflare_tunnel() {
    while true; do
        _header
        echo -e "  ${W}Cloudflare Tunnel 内网穿透${NC}"
        _line
        
        # 显示当前状态
        local status=$(_get_tunnel_status)
        local tunnel_name=$(_get_tunnel_name)
        local hostname=$(_get_tunnel_hostname)
        
        case "$status" in
            "运行中")
                echo -e "  状态: ${G}● 运行中${NC}"
                [[ -n "$tunnel_name" ]] && echo -e "  隧道: ${G}$tunnel_name${NC}"
                [[ -n "$hostname" ]] && echo -e "  域名: ${G}$hostname${NC}"
                ;;
            "已停止")
                echo -e "  状态: ${R}○ 已停止${NC}"
                [[ -n "$tunnel_name" ]] && echo -e "  隧道: ${D}$tunnel_name${NC}"
                ;;
            "未配置")
                echo -e "  状态: ${Y}◐ 已安装 (未配置)${NC}"
                ;;
            *)
                echo -e "  状态: ${D}未安装${NC}"
                ;;
        esac
        
        echo ""
        _line
        
        if _is_cloudflared_installed; then
            _item "1" "安装/重装 cloudflared"
            _item "2" "登录 Cloudflare 认证"
            _item "3" "创建/配置隧道"
            _item "4" "快速隧道 (临时测试)"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            _item "5" "查看隧道状态"
            _item "6" "启动/停止隧道"
            _item "7" "查看隧道日志"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            _item "8" "删除隧道"
            _item "9" "卸载 cloudflared"
        else
            _item "1" "安装 cloudflared"
        fi
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        
        case $choice in
            1) install_cloudflared; _pause ;;
            2) 
                if _is_cloudflared_installed; then
                    cloudflared_login
                    _pause
                else
                    _err "请先安装 cloudflared"
                    _pause
                fi
                ;;
            3) 
                if _is_cloudflared_installed; then
                    create_tunnel_interactive
                else
                    _err "请先安装 cloudflared"
                    _pause
                fi
                ;;
            4)
                if _is_cloudflared_installed; then
                    create_quick_tunnel
                else
                    _err "请先安装 cloudflared"
                    _pause
                fi
                ;;
            5) show_tunnel_status ;;
            6) toggle_tunnel_service ;;
            7) show_tunnel_logs ;;
            8) delete_tunnel ;;
            9) uninstall_cloudflared ;;
            0) return ;;
            *) _err "无效选择"; _pause ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 日志查看
#═══════════════════════════════════════════════════════════════════════════════

show_logs() {
    _header
    echo -e "  ${W}运行日志${NC}"
    _line
    
    echo -e "  ${G}1${NC}) 查看脚本日志 (最近 50 行)"
    echo -e "  ${G}2${NC}) 查看 Watchdog 日志 (最近 50 行)"
    echo -e "  ${G}3${NC}) 查看服务日志 (按协议选择)"
    echo -e "  ${G}4${NC}) 实时跟踪脚本日志"
    echo -e "  ${G}0${NC}) 返回"
    _line
    
    read -rp "  请选择: " log_choice
    
    case $log_choice in
        1)
            _line
            echo -e "  ${C}脚本日志 ($LOG_FILE):${NC}"
            _line
            if [[ -f "$LOG_FILE" ]]; then
                tail -n 50 "$LOG_FILE"
            else
                _warn "日志文件不存在"
            fi
            _pause
            ;;
        2)
            _line
            echo -e "  ${C}Watchdog 日志:${NC}"
            _line
            if [[ -f "/var/log/vless-watchdog.log" ]]; then
                tail -n 50 /var/log/vless-watchdog.log
            else
                _warn "Watchdog 日志文件不存在"
            fi
            _pause
            ;;
        3)
            show_service_logs
            ;;
        4)
            _line
            echo -e "  ${C}实时跟踪日志 (Ctrl+C 退出):${NC}"
            _line
            if [[ -f "$LOG_FILE" ]]; then
                tail -f "$LOG_FILE"
            else
                _warn "日志文件不存在"
            fi
            ;;
        0|"")
            return
            ;;
        *)
            _err "无效选择"
            ;;
    esac
}

# 按协议查看服务日志
show_service_logs() {
    _header
    echo -e "  ${W}服务日志${NC}"
    _line
    
    local installed=$(get_installed_protocols)
    if [[ -z "$installed" ]]; then
        _warn "未安装任何协议"
        return
    fi
    
    # 构建菜单
    local idx=1
    local proto_array=()
    
    # Xray 协议组
    local xray_protocols=$(get_xray_protocols)
    if [[ -n "$xray_protocols" ]]; then
        echo -e "  ${G}$idx${NC}) Xray 服务日志 (vless/vmess/trojan/ss2022/socks)"
        proto_array+=("xray")
        ((idx++))
    fi
    
    # Sing-box 协议组 (hy2/tuic)
    local singbox_protocols=$(get_singbox_protocols)
    if [[ -n "$singbox_protocols" ]]; then
        echo -e "  ${G}$idx${NC}) Sing-box 服务日志 (hy2/tuic)"
        proto_array+=("singbox")
        ((idx++))
    fi
    
    # 独立进程协议 (Snell/AnyTLS/ShadowTLS)
    local standalone_protocols=$(get_standalone_protocols)
    for proto in $standalone_protocols; do
        local proto_name=$(get_protocol_name $proto)
        echo -e "  ${G}$idx${NC}) $proto_name 服务日志"
        proto_array+=("$proto")
        ((idx++))
    done
    
    echo -e "  ${G}0${NC}) 返回"
    _line
    
    read -rp "  请选择: " svc_choice
    
    if [[ "$svc_choice" == "0" || -z "$svc_choice" ]]; then
        return
    fi
    
    if ! [[ "$svc_choice" =~ ^[0-9]+$ ]] || [[ $svc_choice -lt 1 ]] || [[ $svc_choice -ge $idx ]]; then
        _err "无效选择"
        return
    fi
    
    local selected="${proto_array[$((svc_choice-1))]}"
    local service_name=""
    local proc_name=""
    
    case "$selected" in
        xray)
            service_name="vless-reality"
            proc_name="xray"
            ;;
        singbox)
            service_name="vless-singbox"
            proc_name="sing-box"
            ;;
        snell)
            service_name="vless-snell"
            proc_name="snell-server"
            ;;
        snell-v5)
            service_name="vless-snell-v5"
            proc_name="snell-server-v5"
            ;;
        snell-shadowtls|snell-v5-shadowtls|ss2022-shadowtls)
            service_name="vless-${selected}"
            proc_name="shadow-tls"
            ;;
        anytls)
            service_name="vless-anytls"
            proc_name="anytls-server"
            ;;
    esac
    
    _line
    echo -e "  ${C}$selected 服务日志 (最近 50 行):${NC}"
    _line
    
    if [[ "$DISTRO" == "alpine" ]]; then
        # Alpine: 从系统日志中过滤
        if [[ -f /var/log/messages ]]; then
            grep -iE "$proc_name|$service_name" /var/log/messages 2>/dev/null | tail -n 50
            if [[ $? -ne 0 ]]; then
                _warn "未找到相关日志"
            fi
        else
            _warn "系统日志不可用 (/var/log/messages)"
        fi
    else
        # systemd: 使用 journalctl
        if journalctl -u "$service_name" --no-pager -n 50 2>/dev/null; then
            :
        else
            _warn "无法获取服务日志，尝试从系统日志查找..."
            journalctl --no-pager -n 50 2>/dev/null | grep -iE "$proc_name|$service_name" || _warn "未找到相关日志"
        fi
    fi
    _pause
}

#═══════════════════════════════════════════════════════════════════════════════
#  用户管理菜单
#═══════════════════════════════════════════════════════════════════════════════

# 选择协议 (用于用户管理)
_select_protocol_for_users() {
    local protocols=$(db_get_all_protocols)
    [[ -z "$protocols" ]] && { _err "没有已安装的协议"; return 1; }
    
    echo ""
    _line
    echo -e "  ${W}选择协议${NC}"
    _line
    
    local i=1
    local proto_array=()
    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue
        local core="xray"
        db_exists "singbox" "$proto" && core="singbox"
        local user_count=$(db_count_users "$core" "$proto")
        local proto_name=$(get_protocol_name "$proto")
        _item "$i" "$proto_name ${D}($user_count 用户)${NC}"
        proto_array+=("$core:$proto")
        ((i++))
    done <<< "$protocols"
    
    _item "0" "返回"
    _line
    
    local max=$((i-1))
    while true; do
        read -rp "  请选择 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            SELECTED_CORE="${proto_array[$((choice-1))]%%:*}"
            SELECTED_PROTO="${proto_array[$((choice-1))]#*:}"
            return 0
        fi
        _err "无效选择"
    done
}

# 显示用户列表
_show_users_list() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    echo ""
    _dline
    echo -e "  ${C}$proto_name 用户列表${NC}"
    _dline
    
    local stats=$(db_get_users_stats "$core" "$proto")
    if [[ -z "$stats" ]]; then
        echo -e "  ${D}暂无用户${NC}"
        _line
        return
    fi
    
    printf "  ${W}%-10s %-9s %-9s %-7s %-4s %-10s${NC}\n" "用户名" "已用" "配额" "使用率" "状态" "到期"
    _line
    
    local user_list=()
    while IFS='|' read -r name uuid used quota enabled port routing expire_date; do
        [[ -z "$name" ]] && continue
        user_list+=("$name")
        
        local used_fmt=$(format_bytes "$used")
        local quota_fmt="无限"
        local percent="-"
        local status_icon="${G}●${NC}"
        local expire_fmt="永久"
        
        if [[ "$quota" -gt 0 ]]; then
            quota_fmt=$(format_bytes "$quota")
            percent=$(awk -v u="$used" -v q="$quota" 'BEGIN {printf "%.0f%%", (u/q)*100}')
            
            local pct_num=$(awk -v u="$used" -v q="$quota" 'BEGIN {printf "%.0f", (u/q)*100}')
            if [[ "$pct_num" -ge 100 ]]; then
                percent="${R}${percent}${NC}"
            elif [[ "$pct_num" -ge 80 ]]; then
                percent="${Y}${percent}${NC}"
            fi
        fi
        
        # 到期日期处理
        if [[ -n "$expire_date" ]]; then
            local days_left=$(db_get_user_days_left "$core" "$proto" "$name")
            if [[ -n "$days_left" ]]; then
                if [[ "$days_left" -lt 0 ]]; then
                    expire_fmt="${R}已过期${NC}"
                    status_icon="${R}○${NC}"
                elif [[ "$days_left" -eq 0 ]]; then
                    expire_fmt="${R}今天${NC}"
                    status_icon="${R}●${NC}"
                elif [[ "$days_left" -le 3 ]]; then
                    expire_fmt="${Y}${days_left}天${NC}"
                    status_icon="${Y}●${NC}"
                else
                    expire_fmt="${days_left}天"
                fi
            fi
        fi
        
        [[ "$enabled" != "true" ]] && status_icon="${R}○${NC}"
        
        printf "  %-10s %-9s %-9s %-7s %b  %b\n" "$name" "$used_fmt" "$quota_fmt" "$percent" "$status_icon" "$expire_fmt"
    done <<< "$stats"
    
    _line
}

# 生成用户的分享链接（根据协议类型）
_gen_user_share_link() {
    local core="$1" proto="$2" uuid="$3" user_name="$4"
    
    # 获取协议配置
    local cfg=$(db_get "$core" "$proto")
    [[ -z "$cfg" || "$cfg" == "null" ]] && return
    
    # 检查是否为多端口数组格式
    local is_array=false
    if echo "$cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
        is_array=true
        # 多端口：从第一个端口实例获取配置
        cfg=$(echo "$cfg" | jq '.[0]')
    fi
    
    # 提取配置字段
    local port=$(echo "$cfg" | jq -r '.port // empty')
    local sni=$(echo "$cfg" | jq -r '.sni // empty')
    local short_id=$(echo "$cfg" | jq -r '.short_id // empty')
    local public_key=$(echo "$cfg" | jq -r '.public_key // empty')
    local path=$(echo "$cfg" | jq -r '.path // empty')
    local method=$(echo "$cfg" | jq -r '.method // empty')
    local domain=$(echo "$cfg" | jq -r '.domain // empty')
    
    # 获取 IP 地址
    local ipv4=$(get_ipv4)
    local ipv6=$(get_ipv6)
    local country_code=$(get_ip_country "$ipv4")
    [[ -z "$country_code" ]] && country_code=$(get_ip_country "$ipv6")
    
    # 检测回落协议端口
    local display_port="$port"
    if [[ "$proto" == "vless-ws" || "$proto" == "vmess-ws" ]]; then
        if db_exists "xray" "vless-vision"; then
            local vision_cfg=$(db_get "xray" "vless-vision")
            if echo "$vision_cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
                display_port=$(echo "$vision_cfg" | jq -r '.[0].port // empty')
            else
                display_port=$(echo "$vision_cfg" | jq -r '.port // empty')
            fi
        elif db_exists "xray" "trojan"; then
            local trojan_cfg=$(db_get "xray" "trojan")
            if echo "$trojan_cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
                display_port=$(echo "$trojan_cfg" | jq -r '.[0].port // empty')
            else
                display_port=$(echo "$trojan_cfg" | jq -r '.port // empty')
            fi
        elif db_exists "xray" "vless"; then
            local vless_cfg=$(db_get "xray" "vless")
            if echo "$vless_cfg" | jq -e 'type == "array"' >/dev/null 2>&1; then
                display_port=$(echo "$vless_cfg" | jq -r '.[0].port // empty')
            else
                display_port=$(echo "$vless_cfg" | jq -r '.port // empty')
            fi
        fi
        [[ -z "$display_port" ]] && display_port="$port"
    fi
    
    local remark="${country_code}-${user_name}"
    
    # 生成 IPv4 链接
    if [[ -n "$ipv4" ]]; then
        local link=""
        case "$proto" in
            vless) link=$(gen_vless_link "$ipv4" "$display_port" "$uuid" "$public_key" "$short_id" "$sni" "$remark") ;;
            vless-xhttp) link=$(gen_vless_xhttp_link "$ipv4" "$display_port" "$uuid" "$public_key" "$short_id" "$sni" "$path" "$remark") ;;
            vless-vision) link=$(gen_vless_vision_link "$ipv4" "$display_port" "$uuid" "$sni" "$remark") ;;
            vless-ws) link=$(gen_vless_ws_link "$ipv4" "$display_port" "$uuid" "$sni" "$path" "$remark") ;;
            vmess-ws) link=$(gen_vmess_ws_link "$ipv4" "$display_port" "$uuid" "$sni" "$path" "$remark") ;;
            ss2022) link=$(gen_ss2022_link "$ipv4" "$display_port" "$method" "$uuid" "$remark") ;;
            hy2) link=$(gen_hy2_link "$ipv4" "$display_port" "$uuid" "$sni" "$remark") ;;
            trojan) link=$(gen_trojan_link "$ipv4" "$display_port" "$uuid" "$sni" "$remark") ;;
            tuic) 
                local password=$(echo "$cfg" | jq -r '.password // empty')
                link=$(gen_tuic_link "$ipv4" "$display_port" "$uuid" "$password" "$sni" "$remark") 
                ;;
            socks) link=$(gen_socks_link "$ipv4" "$display_port" "$user_name" "$uuid" "$remark") ;;
        esac
        [[ -n "$link" ]] && echo "$link"
    fi
}

# 显示用户分享链接菜单
_show_user_share_links() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    while true; do
        _header
        echo -e "  ${W}$proto_name 用户分享链接${NC}"
        _dline
        
        local stats=$(db_get_users_stats "$core" "$proto")
        if [[ -z "$stats" ]]; then
            echo -e "  ${D}暂无用户${NC}"
            _line
            _pause
            return
        fi
        
        # 显示用户列表
        local users=()
        local uuids=()
        local idx=1
        
        while IFS='|' read -r name uuid used quota enabled port routing; do
            [[ -z "$name" ]] && continue
            users+=("$name")
            uuids+=("$uuid")
            echo -e "  ${G}$idx${NC}) $name"
            ((idx++))
        done <<< "$stats"
        
        _line
        echo -e "  ${D}输入序号查看详细配置/链接${NC}"
        _item "a" "一键展示所有用户分享链接"
        _item "0" "返回"
        _line
        
        read -rp "  请选择 [0-$((idx-1))/a]: " choice
        
        if [[ "$choice" == "0" ]]; then
            return
        elif [[ "$choice" == "a" || "$choice" == "A" ]]; then
            # 展示所有用户分享链接
            echo ""
            _dline
            echo -e "  ${W}$proto_name 所有用户分享链接${NC}"
            _dline
            
            for i in "${!users[@]}"; do
                local user="${users[$i]}"
                local uuid="${uuids[$i]}"
                echo -e "  ${Y}$user:${NC}"
                local link=$(_gen_user_share_link "$core" "$proto" "$uuid" "$user")
                [[ -n "$link" ]] && echo -e "  ${C}$link${NC}"
                echo ""
            done
            
            _line
            _pause
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#users[@]}" ]]; then
            # 显示单个用户链接
            local user="${users[$((choice-1))]}"
            local uuid="${uuids[$((choice-1))]}"
            
            echo ""
            _dline
            echo -e "  ${W}$user 分享链接${NC}"
            _dline
            
            local link=$(_gen_user_share_link "$core" "$proto" "$uuid" "$user")
            if [[ -n "$link" ]]; then
                echo -e "  ${C}$link${NC}"
                echo ""
                
                # 生成二维码（如果可用）
                if command -v qrencode &>/dev/null; then
                    echo -e "  ${D}二维码:${NC}"
                    qrencode -t ANSIUTF8 "$link" 2>/dev/null
                fi
            else
                echo -e "  ${D}无法生成链接${NC}"
            fi
            
            _line
            _pause
        else
            _err "无效选择"
        fi
    done
}

# 用户路由选择函数
# 用法: _select_user_routing [当前路由值]
# 设置全局变量 SELECTED_ROUTING 为选择的路由值
_select_user_routing() {
    local current_routing="${1:-}"
    SELECTED_ROUTING=""
    
    echo ""
    _line
    echo -e "  ${W}选择用户路由${NC}"
    echo -e "  ${D}用户级路由优先于全局分流规则${NC}"
    _line
    
    local idx=1
    local options=()
    
    # 选项1: 使用全局规则
    echo -e "  ${G}1${NC}) 使用全局规则 (默认)"
    options+=("")
    ((idx++))
    
    # 选项2: 直连
    echo -e "  ${G}$idx${NC}) 直连"
    options+=("direct")
    ((idx++))
    
    # 选项3: WARP (仅当已安装时显示)
    if warp_status &>/dev/null || [[ -f "/usr/local/bin/warp-go" ]] || command -v warp-cli &>/dev/null; then
        echo -e "  ${G}$idx${NC}) WARP 代理"
        options+=("warp")
        ((idx++))
    fi
    
    # 选项N: 链式代理节点
    if [[ -f "$DB_FILE" ]]; then
        local chain_nodes=$(jq -r '.chain_proxy.nodes[]?.name // empty' "$DB_FILE" 2>/dev/null)
        if [[ -n "$chain_nodes" ]]; then
            echo -e "  ${D}──链式代理节点──${NC}"
            while IFS= read -r node; do
                [[ -z "$node" ]] && continue
                echo -e "  ${G}$idx${NC}) 链路→$node"
                options+=("chain:$node")
                ((idx++))
            done <<< "$chain_nodes"
        fi
    fi
    
    # 选项M: 负载均衡组
    if [[ -f "$DB_FILE" ]]; then
        local balancers=$(jq -r '.balancer_groups[]?.name // empty' "$DB_FILE" 2>/dev/null)
        if [[ -n "$balancers" ]]; then
            echo -e "  ${D}──负载均衡组──${NC}"
            while IFS= read -r group; do
                [[ -z "$group" ]] && continue
                echo -e "  ${G}$idx${NC}) 负载→$group"
                options+=("balancer:$group")
                ((idx++))
            done <<< "$balancers"
        fi
    fi
    
    echo -e "  ${G}0${NC}) 取消"
    _line
    
    local max=$((idx-1))
    while true; do
        read -rp "  请选择 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return 1
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            SELECTED_ROUTING="${options[$((choice-1))]}"
            
            # 如果选择 WARP 但未安装，提示安装
            if [[ "$SELECTED_ROUTING" == "warp" ]]; then
                if ! warp_status &>/dev/null && [[ ! -f "/usr/local/bin/warp-go" ]] && ! command -v warp-cli &>/dev/null; then
                    _warn "WARP 未安装"
                    read -rp "  是否现在安装 WARP? [Y/n]: " install_warp
                    if [[ ! "$install_warp" =~ ^[nN]$ ]]; then
                        install_warp_go
                        if ! warp_status &>/dev/null; then
                            _err "WARP 安装失败，请稍后重试"
                            return 1
                        fi
                    else
                        _err "已取消"
                        return 1
                    fi
                fi
            fi
            
            return 0
        fi
        _err "无效选择"
    done
}

# 修改用户路由
_set_user_routing() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }
    
    echo ""
    _line
    echo -e "  ${W}修改用户路由 - $proto_name${NC}"
    _line
    
    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local current_routing=$(db_get_user_routing "$core" "$proto" "$user")
        local routing_fmt=$(_format_user_routing "$current_routing")
        _item "$i" "$user ${D}(当前: $routing_fmt)${NC}"
        user_array+=("$user")
        ((i++))
    done <<< "$users"
    
    _item "0" "返回"
    _line
    
    local max=$((i-1))
    while true; do
        read -rp "  选择用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            local current=$(db_get_user_routing "$core" "$proto" "$name")
            
            if _select_user_routing "$current"; then
                if db_set_user_routing "$core" "$proto" "$name" "$SELECTED_ROUTING"; then
                    local new_fmt=$(_format_user_routing "$SELECTED_ROUTING")
                    _ok "用户 $name 路由已设置为: $new_fmt"
                else
                    _err "设置失败"
                fi
            fi
            return
        fi
        _err "无效选择"
    done
}

# 添加用户
_add_user() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    # 检查是否为独立协议（不支持多用户）
    if is_standalone_protocol "$proto"; then
        echo ""
        _err "$proto_name 为独立协议，不支持多用户管理"
        _info "该协议使用配置文件中的固定密钥，无需添加用户"
        return 1
    fi
    
    echo ""
    _line
    echo -e "  ${W}添加用户 - $proto_name${NC}"
    _line
    
    # 输入用户名
    local name
    while true; do
        read -rp "  用户名: " name
        [[ -z "$name" ]] && { _err "用户名不能为空"; continue; }
        [[ "$name" =~ [^a-zA-Z0-9_-] ]] && { _err "用户名只能包含字母、数字、下划线和横线"; continue; }
        
        # 检查是否已存在（精确匹配）
        local exists=$(db_get_user "$core" "$proto" "$name")
        [[ -n "$exists" ]] && { _err "用户 $name 已存在"; continue; }
        
        # 检查大小写冲突（Xray email 不区分大小写）
        local name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        local conflict=false
        local existing_users=$(db_list_users "$core" "$proto")
        if [[ -n "$existing_users" ]]; then
            while IFS= read -r existing_name; do
                [[ -z "$existing_name" ]] && continue
                local existing_lower=$(echo "$existing_name" | tr '[:upper:]' '[:lower:]')
                if [[ "$name_lower" == "$existing_lower" && "$name" != "$existing_name" ]]; then
                    _err "用户名 $name 与已存在的用户 $existing_name 冲突"
                    conflict=true
                    break
                fi
            done <<< "$existing_users"
        fi
        [[ "$conflict" == true ]] && continue
        
        break
    done
    
    # 生成 UUID/密码
    local uuid
    case "$proto" in
        vless|vless-xhttp|vless-ws|vless-vision|tuic)
            uuid=$(gen_uuid)
            ;;
        ss2022)
            # SS2022 需要根据加密方式生成密钥
            local method=$(db_get_field "$core" "$proto" "method")
            local key_len=16
            [[ "$method" == *"256"* ]] && key_len=32
            uuid=$(head -c $key_len /dev/urandom 2>/dev/null | base64 -w 0)
            ;;
        *)
            uuid=$(ask_password 16 "用户密码")
            ;;
    esac
    
    # 输入配额
    echo ""
    echo -e "  ${D}流量配额 (GB)，0 表示无限制${NC}"
    local quota_gb
    while true; do
        read -rp "  配额 [0]: " quota_gb
        quota_gb="${quota_gb:-0}"
        [[ "$quota_gb" =~ ^[0-9]+$ ]] && break
        _err "请输入有效数字"
    done
    
    # 输入到期日期
    echo ""
    echo -e "  ${D}到期日期: 输入天数(如30) 或日期(如2026-03-01)，留空表示永不过期${NC}"
    local expire_date=""
    local expire_display="永不过期"
    read -rp "  到期 [永不过期]: " expire_input
    if [[ -n "$expire_input" ]]; then
        if [[ "$expire_input" =~ ^[0-9]+$ ]]; then
            # 输入的是天数
            expire_date=$(date -d "+${expire_input} days" '+%Y-%m-%d' 2>/dev/null)
            if [[ -z "$expire_date" ]]; then
                # macOS 兼容
                expire_date=$(date -v+${expire_input}d '+%Y-%m-%d' 2>/dev/null)
            fi
            expire_display="$expire_date (${expire_input}天后)"
        elif [[ "$expire_input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            # 输入的是日期
            expire_date="$expire_input"
            expire_display="$expire_date"
        else
            _warn "无效日期格式，将设置为永不过期"
        fi
    fi
    
    # 选择路由 (可选)
    local user_routing=""
    echo ""
    read -rp "  是否为此用户配置专属路由? [y/N]: " config_routing
    if [[ "$config_routing" =~ ^[yY]$ ]]; then
        if _select_user_routing; then
            user_routing="$SELECTED_ROUTING"
        fi
    fi
    
    # 确认
    local routing_display=$(_format_user_routing "$user_routing")
    echo ""
    _line
    echo -e "  用户名: ${G}$name${NC}"
    echo -e "  凭证: ${G}${uuid:0:16}...${NC}"
    echo -e "  配额: ${G}${quota_gb:-无限制} GB${NC}"
    echo -e "  到期: ${G}$expire_display${NC}"
    echo -e "  路由: ${G}$routing_display${NC}"
    _line
    
    read -rp "  确认添加? [Y/n]: " confirm
    [[ "$confirm" =~ ^[nN]$ ]] && return
    
    # 添加到数据库 (包含 expire_date)
    if db_add_user "$core" "$proto" "$name" "$uuid" "$quota_gb" "$expire_date"; then
        _ok "用户 $name 添加成功"
        
        # 如果有自定义路由，设置路由
        if [[ -n "$user_routing" ]]; then
            db_set_user_routing "$core" "$proto" "$name" "$user_routing"
            _ok "路由配置: $routing_display"
        fi
        
        # 重新生成配置
        _info "更新配置..."
        _regenerate_config "$core" "$proto"
        
        _ok "配置已更新"
    else
        _err "添加失败"
    fi
}

# 删除用户
_delete_user() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户可删除"; return; }
    
    echo ""
    _line
    echo -e "  ${W}删除用户 - $proto_name${NC}"
    _line
    
    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        _item "$i" "$user"
        user_array+=("$user")
        ((i++))
    done <<< "$users"
    
    _item "0" "返回"
    _line
    
    local max=$((i-1))
    while true; do
        read -rp "  选择要删除的用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            
            # 禁止删除 default 用户
            if [[ "$name" == "default" ]]; then
                _err "default 用户不能删除"
                _info "default 是协议的默认用户，删除会导致协议无法正常工作"
                return
            fi
            
            # 确认删除
            read -rp "  确认删除用户 $name? [y/N]: " confirm
            [[ ! "$confirm" =~ ^[yY]$ ]] && return
            
            if db_del_user "$core" "$proto" "$name"; then
                _ok "用户 $name 已删除"
                
                # 重新生成配置
                _info "更新配置..."
                _regenerate_config "$core" "$proto"
                
                _ok "配置已更新"
            else
                _err "删除失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 设置用户配额
_set_user_quota() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }
    
    echo ""
    _line
    echo -e "  ${W}设置配额 - $proto_name${NC}"
    _line
    
    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local quota=$(db_get_user_field "$core" "$proto" "$user" "quota")
        local quota_fmt="无限制"
        [[ "$quota" -gt 0 ]] && quota_fmt=$(format_bytes "$quota")
        _item "$i" "$user ${D}(当前: $quota_fmt)${NC}"
        user_array+=("$user")
        ((i++))
    done <<< "$users"
    
    _item "0" "返回"
    _line
    
    local max=$((i-1))
    while true; do
        read -rp "  选择用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            
            echo ""
            echo -e "  ${D}输入新配额 (GB)，0 表示无限制${NC}"
            local quota_gb
            while true; do
                read -rp "  新配额: " quota_gb
                [[ "$quota_gb" =~ ^[0-9]+$ ]] && break
                _err "请输入有效数字"
            done
            
            if db_set_user_quota "$core" "$proto" "$name" "$quota_gb"; then
                local quota_fmt="无限制"
                [[ "$quota_gb" -gt 0 ]] && quota_fmt="${quota_gb} GB"
                _ok "用户 $name 配额已设置为 $quota_fmt"
            else
                _err "设置失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 重置用户流量
_reset_user_traffic() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }
    
    echo ""
    _line
    echo -e "  ${W}重置流量 - $proto_name${NC}"
    _line
    
    _item "a" "重置所有用户"
    
    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local used=$(db_get_user_field "$core" "$proto" "$user" "used")
        local used_fmt=$(format_bytes "$used")
        _item "$i" "$user ${D}(已用: $used_fmt)${NC}"
        user_array+=("$user")
        ((i++))
    done <<< "$users"
    
    _item "0" "返回"
    _line
    
    local max=$((i-1))
    while true; do
        read -rp "  选择 [0-$max/a]: " choice
        [[ "$choice" == "0" ]] && return
        
        if [[ "$choice" == "a" || "$choice" == "A" ]]; then
            read -rp "  确认重置所有用户流量? [y/N]: " confirm
            [[ ! "$confirm" =~ ^[yY]$ ]] && return
            
            for user in $users; do
                db_reset_user_traffic "$core" "$proto" "$user"
            done
            _ok "所有用户流量已重置"
            return
        fi
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            
            read -rp "  确认重置用户 $name 的流量? [y/N]: " confirm
            [[ ! "$confirm" =~ ^[yY]$ ]] && return
            
            if db_reset_user_traffic "$core" "$proto" "$name"; then
                _ok "用户 $name 流量已重置"
            else
                _err "重置失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 启用/禁用用户
_toggle_user() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }
    
    echo ""
    _line
    echo -e "  ${W}启用/禁用用户 - $proto_name${NC}"
    _line
    
    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local enabled=$(db_get_user_field "$core" "$proto" "$user" "enabled")
        local status="${G}● 启用${NC}"
        [[ "$enabled" != "true" ]] && status="${R}○ 禁用${NC}"
        _item "$i" "$user $status"
        user_array+=("$user")
        ((i++))
    done <<< "$users"
    
    _item "0" "返回"
    _line
    
    local max=$((i-1))
    while true; do
        read -rp "  选择用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            local enabled=$(db_get_user_field "$core" "$proto" "$name" "enabled")
            
            local new_state="true"
            local action="启用"
            if [[ "$enabled" == "true" ]]; then
                new_state="false"
                action="禁用"
            fi
            
            if db_set_user_enabled "$core" "$proto" "$name" "$new_state"; then
                _ok "用户 $name 已${action}"
                
                # 重新生成配置
                _info "更新配置..."
                _regenerate_config "$core" "$proto"
                
                _ok "配置已更新"
            else
                _err "操作失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 设置用户到期日期
_set_user_expire_date() {
    local core="$1" proto="$2"
    local proto_name=$(get_protocol_name "$proto")
    
    local users=$(db_list_users "$core" "$proto")
    [[ -z "$users" ]] && { _err "没有用户"; return; }
    
    echo ""
    _line
    echo -e "  ${W}设置到期日期 - $proto_name${NC}"
    _line
    
    local i=1
    local user_array=()
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        local expire_date=$(db_get_user_expire_date "$core" "$proto" "$user")
        local expire_info="永久"
        if [[ -n "$expire_date" ]]; then
            local days_left=$(db_get_user_days_left "$core" "$proto" "$user")
            if [[ "$days_left" -lt 0 ]]; then
                expire_info="${R}已过期 ($expire_date)${NC}"
            else
                expire_info="$expire_date (剩余 ${days_left} 天)"
            fi
        fi
        _item "$i" "$user ${D}($expire_info)${NC}"
        user_array+=("$user")
        ((i++))
    done <<< "$users"
    
    _item "0" "返回"
    _line
    
    local max=$((i-1))
    while true; do
        read -rp "  选择用户 [0-$max]: " choice
        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
            local name="${user_array[$((choice-1))]}"
            
            echo ""
            echo -e "  ${D}输入天数(如30) 或日期(2026-03-01)，输入 0 取消到期限制${NC}"
            local expire_input
            read -rp "  新到期: " expire_input
            
            local new_expire=""
            if [[ "$expire_input" == "0" ]]; then
                new_expire=""
            elif [[ "$expire_input" =~ ^[0-9]+$ ]]; then
                new_expire=$(date -d "+${expire_input} days" '+%Y-%m-%d' 2>/dev/null)
                [[ -z "$new_expire" ]] && new_expire=$(date -v+${expire_input}d '+%Y-%m-%d' 2>/dev/null)
            elif [[ "$expire_input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                new_expire="$expire_input"
            else
                _err "无效格式"
                return
            fi
            
            if db_set_user_expire_date "$core" "$proto" "$name" "$new_expire"; then
                if [[ -z "$new_expire" ]]; then
                    _ok "用户 $name 已设为永不过期"
                else
                    _ok "用户 $name 到期日期已设为 $new_expire"
                fi
                
                # 如果用户之前被禁用且设置了有效期，询问是否启用
                local enabled=$(db_get_user_field "$core" "$proto" "$name" "enabled")
                if [[ "$enabled" != "true" && -n "$new_expire" ]]; then
                    read -rp "  用户当前已禁用，是否启用? [y/N]: " enable_now
                    if [[ "$enable_now" =~ ^[yY]$ ]]; then
                        db_set_user_enabled "$core" "$proto" "$name" true
                        _regenerate_config "$core" "$proto"
                        _ok "用户已启用"
                    fi
                fi
            else
                _err "设置失败"
            fi
            return
        fi
        _err "无效选择"
    done
}

# 重新生成配置 (添加/删除用户后调用)
# 更新 Xray/Sing-box 配置文件中的用户列表、用户级路由规则、链式代理和负载均衡并重载服务
_regenerate_config() {
    local core="$1" proto="$2"
    local config_file=""
    local service_name=""
    
    # 确定配置文件路径和服务名称
    if [[ "$core" == "xray" ]]; then
        config_file="$CFG/config.json"
        service_name="vless-reality"
    elif [[ "$core" == "singbox" ]]; then
        config_file="$CFG/singbox/config.json"
        service_name="vless-singbox"
    fi
    
    # 检查配置文件是否存在
    if [[ ! -f "$config_file" ]]; then
        _info "用户信息已保存到数据库"
        return 0
    fi
    
    # 从数据库读取用户列表
    local db_users=$(db_get_field "$core" "$proto" "users")
    local users_json=""
    local xray_user_rules="[]"
    local xray_balancer_rules="[]"
    local needed_chain_nodes=""
    local needed_balancer_groups=""
    
    if [[ -n "$db_users" && "$db_users" != "null" ]]; then
        # 有用户列表，转换为 Xray 格式的 clients 数组
        # email 格式为 用户名@协议，用于流量统计
        users_json=$(echo "$db_users" | jq -c --arg proto "$proto" '[.[] | select(.enabled == true) | {id: .uuid, email: (.name + "@" + $proto), flow: "xtls-rprx-vision"}]' 2>/dev/null)
        
        # 生成用户级路由规则
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local user_name=$(echo "$line" | jq -r '.name')
            local user_routing=$(echo "$line" | jq -r '.routing // ""')
            
            [[ -z "$user_name" || -z "$user_routing" ]] && continue
            
            # user 字段需要匹配 clients 中的 email 格式：用户名@协议
            local user_email="${user_name}@${proto}"
            
            case "$user_routing" in
                direct)
                    xray_user_rules=$(echo "$xray_user_rules" | jq --arg user "$user_email" \
                        '. + [{"type": "field", "user": [$user], "outboundTag": "direct"}]')
                    ;;
                warp)
                    xray_user_rules=$(echo "$xray_user_rules" | jq --arg user "$user_email" \
                        '. + [{"type": "field", "user": [$user], "outboundTag": "warp"}]')
                    ;;
                chain:*)
                    local node_name="${user_routing#chain:}"
                    xray_user_rules=$(echo "$xray_user_rules" | jq --arg user "$user_email" --arg tag "chain-${node_name}-prefer-ipv4" \
                        '. + [{"type": "field", "user": [$user], "outboundTag": $tag}]')
                    needed_chain_nodes="$needed_chain_nodes $node_name"
                    ;;
                balancer:*)
                    local group_name="${user_routing#balancer:}"
                    # 负载均衡使用 balancerTag 而不是 outboundTag
                    xray_balancer_rules=$(echo "$xray_balancer_rules" | jq --arg user "$user_email" --arg tag "$group_name" \
                        '. + [{"type": "field", "user": [$user], "balancerTag": $tag}]')
                    needed_balancer_groups="$needed_balancer_groups $group_name"
                    ;;
            esac
        done < <(echo "$db_users" | jq -c '.[] | select(.enabled == true and .routing != null and .routing != "")')
    else
        # 使用默认 UUID
        local default_uuid=$(db_get_field "$core" "$proto" "uuid")
        if [[ -n "$default_uuid" ]]; then
            users_json="[{\"id\": \"$default_uuid\", \"email\": \"default@${proto}\", \"flow\": \"xtls-rprx-vision\"}]"
        fi
    fi
    
    # 从数据库读取链式代理节点配置
    local chain_outbounds="[]"
    if [[ -n "$needed_chain_nodes" && -f "$DB_FILE" ]]; then
        for node_name in $needed_chain_nodes; do
            local node_config=$(jq -r --arg n "$node_name" '.chain_proxy.nodes[] | select(.name == $n)' "$DB_FILE" 2>/dev/null)
            if [[ -n "$node_config" ]]; then
                local node_type=$(echo "$node_config" | jq -r '.type')
                local server=$(echo "$node_config" | jq -r '.server')
                local port=$(echo "$node_config" | jq -r '.port')
                local username=$(echo "$node_config" | jq -r '.username // ""')
                local password=$(echo "$node_config" | jq -r '.password // ""')
                
                if [[ "$node_type" == "socks" ]]; then
                    local outbound="{\"tag\": \"chain-${node_name}-prefer-ipv4\", \"protocol\": \"socks\", \"settings\": {\"servers\": [{\"address\": \"$server\", \"port\": $port"
                    if [[ -n "$username" && -n "$password" ]]; then
                        outbound="$outbound, \"users\": [{\"user\": \"$username\", \"pass\": \"$password\"}]"
                    fi
                    outbound="$outbound}]}}"
                    chain_outbounds=$(echo "$chain_outbounds" | jq --argjson ob "$outbound" '. + [$ob]')
                fi
            fi
        done
    fi
    
    # 从数据库读取负载均衡组配置
    local xray_balancers="[]"
    if [[ -n "$needed_balancer_groups" && -f "$DB_FILE" ]]; then
        for group_name in $needed_balancer_groups; do
            local group_config=$(jq -r --arg n "$group_name" '.balancer_groups[] | select(.name == $n)' "$DB_FILE" 2>/dev/null)
            if [[ -n "$group_config" ]]; then
                local strategy=$(echo "$group_config" | jq -r '.strategy // "random"')
                local nodes=$(echo "$group_config" | jq -r '.nodes[]' 2>/dev/null)
                
                # 构建 selector 列表（每个节点对应一个 outbound tag）
                local selectors="[]"
                for node in $nodes; do
                    selectors=$(echo "$selectors" | jq --arg s "proxy-${node}" '. + [$s]')
                    # 确保这些节点也被添加到 chain_outbounds
                    needed_chain_nodes="$needed_chain_nodes $node"
                done
                
                # 构建 balancer
                local balancer="{\"tag\": \"$group_name\", \"selector\": $selectors, \"strategy\": {\"type\": \"$strategy\"}}"
                xray_balancers=$(echo "$xray_balancers" | jq --argjson b "$balancer" '. + [$b]')
            fi
        done
        
        # 重新生成需要的链式代理节点 outbounds
        chain_outbounds="[]"
        for node_name in $needed_chain_nodes; do
            # 检查是否已添加
            local exists=$(echo "$chain_outbounds" | jq --arg t "chain-${node_name}-prefer-ipv4" '[.[] | select(.tag == $t)] | length')
            [[ "$exists" != "0" ]] && continue
            
            local node_config=$(jq -r --arg n "$node_name" '.chain_proxy.nodes[] | select(.name == $n)' "$DB_FILE" 2>/dev/null)
            if [[ -n "$node_config" ]]; then
                local node_type=$(echo "$node_config" | jq -r '.type')
                local server=$(echo "$node_config" | jq -r '.server')
                local port=$(echo "$node_config" | jq -r '.port')
                local username=$(echo "$node_config" | jq -r '.username // ""')
                local password=$(echo "$node_config" | jq -r '.password // ""')
                
                if [[ "$node_type" == "socks" ]]; then
                    local outbound="{\"tag\": \"chain-${node_name}-prefer-ipv4\", \"protocol\": \"socks\", \"settings\": {\"servers\": [{\"address\": \"$server\", \"port\": $port"
                    if [[ -n "$username" && -n "$password" ]]; then
                        outbound="$outbound, \"users\": [{\"user\": \"$username\", \"pass\": \"$password\"}]"
                    fi
                    outbound="$outbound}]}}"
                    chain_outbounds=$(echo "$chain_outbounds" | jq --argjson ob "$outbound" '. + [$ob]')
                fi
            fi
        done
    fi
    
    # 合并 outboundTag 规则和 balancerTag 规则
    local all_user_rules=$(echo "$xray_user_rules" | jq --argjson br "$xray_balancer_rules" '. + $br')
    
    # 更新配置文件
    if [[ -n "$users_json" ]]; then
        local tmp=$(mktemp)
        
        # 使用 jq 更新配置
        if jq --argjson clients "$users_json" \
              --argjson user_rules "$all_user_rules" \
              --argjson chain_obs "$chain_outbounds" \
              --argjson balancers "$xray_balancers" '
            # 更新 clients (通过 protocol 查找 VLESS inbound，避免索引问题)
            (.inbounds[] | select(.protocol == "vless")).settings.clients = $clients |
            
            # 确保 routing 结构存在
            if .routing == null then .routing = {"domainStrategy": "AsIs", "rules": []} else . end |
            if .routing.rules == null then .routing.rules = [] else . end |
            
            # 确保 api 和 stats 存在（用于流量统计）
            if .api == null then .api = {"tag": "api", "services": ["StatsService"]} else . end |
            if .stats == null then .stats = {} else . end |
            if .policy == null then .policy = {"system": {"statsInboundUplink": true, "statsInboundDownlink": true}, "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}} else . end |
            if .policy.system == null then .policy.system = {"statsInboundUplink": true, "statsInboundDownlink": true} else . end |
            if .policy.levels == null then .policy.levels = {"0": {"statsUserUplink": true, "statsUserDownlink": true}} else . end |
            if .policy.levels["0"] == null then .policy.levels["0"] = {"statsUserUplink": true, "statsUserDownlink": true} else . end |
            .policy.system.statsInboundUplink = true |
            .policy.system.statsInboundDownlink = true |
            .policy.levels["0"].statsUserUplink = true |
            .policy.levels["0"].statsUserDownlink = true |
            
            # 确保有 API inbound（监听 127.0.0.1:10085）
            if ([.inbounds[] | select(.tag == "api")] | length) == 0 then
                .inbounds += [{"tag": "api", "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}]
            else . end |
            
            # 确保有 API outbound
            if ([.outbounds[] | select(.tag == "api")] | length) == 0 then
                .outbounds += [{"tag": "api", "protocol": "blackhole", "settings": {}}]
            else . end |
            
            # 添加链式代理 outbounds（先移除旧的 proxy-* outbounds）
            .outbounds = ([.outbounds[] | select(.tag | startswith("proxy-") | not)] + $chain_obs) |
            
            # 添加/更新负载均衡器
            if ($balancers | length) > 0 then
                .routing.balancers = $balancers
            else . end |
            
            # 确保 routing 中有 API 规则
            if ([.routing.rules[]? | select(.inboundTag != null and (.inboundTag | contains(["api"])))] | length) == 0 then
                .routing.rules = [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}] + (.routing.rules // [])
            else . end |
            
            # 更新用户级路由规则
            # 用户级规则优先于全局规则：API规则 > 用户规则 > 其他规则
            .routing.rules = (
                # 1. API 规则必须在最前
                [.routing.rules[]? | select(.inboundTag != null and (.inboundTag | contains(["api"])))] +
                # 2. 用户级路由规则（高优先级）
                $user_rules +
                # 3. 其他规则（全局规则等）
                [.routing.rules[]? | select(
                    (.user == null or (.user | type) != "array") and
                    (.inboundTag == null or (.inboundTag | contains(["api"])) | not)
                )]
            )
        ' "$config_file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$config_file"
        else
            rm -f "$tmp"
            # 如果完整更新失败，至少尝试更新 clients
            tmp=$(mktemp)
            if jq --argjson clients "$users_json" '(.inbounds[] | select(.protocol == "vless")).settings.clients = $clients' "$config_file" > "$tmp" 2>/dev/null; then
                mv "$tmp" "$config_file"
            else
                rm -f "$tmp"
            fi
        fi
    fi
    
    _info "用户信息已保存到数据库"
    
    # 重载服务使配置生效
    if [[ "$DISTRO" == "alpine" ]]; then
        rc-service "$service_name" restart 2>/dev/null || true
    elif systemctl is-active --quiet "$service_name" 2>/dev/null; then
        systemctl reload "$service_name" 2>/dev/null || systemctl restart "$service_name" 2>/dev/null
    fi
}

# 配置 TG 通知
_configure_tg_notify() {
    init_tg_config
    
    while true; do
        # 每次循环都重新读取配置，确保显示最新状态
        local enabled=$(tg_get_config "enabled")
        local bot_token=$(tg_get_config "bot_token")
        local chat_id=$(tg_get_config "chat_id")
        local daily_enabled=$(tg_get_config "notify_daily")
        local report_hour=$(tg_get_config "daily_report_hour")
        local report_minute=$(tg_get_config "daily_report_minute")
        report_hour=${report_hour:-9}
        report_minute=${report_minute:-0}
        local report_time=$(printf "%02d:%02d" "$report_hour" "$report_minute")
        
        _header
        echo -e "  ${W}TG 通知配置${NC}"
        _dline
        
        local status="${R}○ 未启用${NC}"
        [[ "$enabled" == "true" ]] && status="${G}● 已启用${NC}"
        
        local daily_status="${D}○ 关闭${NC}"
        [[ "$daily_enabled" == "true" ]] && daily_status="${G}● 每天 ${report_time}${NC}"
        
        # 检查定时任务状态
        local cron_status="${R}○ 未启用${NC}"
        local current_interval=$(get_traffic_interval)
        if crontab -l 2>/dev/null | grep -q "sync-traffic"; then
            cron_status="${G}● 每${current_interval}分钟${NC}"
        fi
        
        echo -e "  TG 通知: $status"
        echo -e "  流量检测: $cron_status"
        echo -e "  每日报告: $daily_status"
        echo -e "  Bot Token: ${bot_token:+${G}已配置${NC}}${bot_token:-${D}未配置${NC}}"
        echo -e "  Chat ID: ${chat_id:+${G}$chat_id${NC}}${chat_id:-${D}未配置${NC}}"
        _line
        
        _item "1" "设置 Bot Token"
        _item "2" "设置 Chat ID"
        _item "3" "测试发送"
        if [[ "$enabled" == "true" ]]; then
            _item "4" "禁用通知"
        else
            _item "4" "启用通知"
        fi
        _item "5" "设置检测间隔"
        _item "6" "每日报告设置"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        case $choice in
            1)
                echo ""
                echo -e "  ${D}从 @BotFather 获取 Bot Token${NC}"
                read -rp "  Bot Token: " new_token
                if [[ -n "$new_token" ]]; then
                    tg_set_config "bot_token" "$new_token"
                    bot_token="$new_token"
                    _ok "Bot Token 已保存"
                fi
                _pause
                ;;
            2)
                echo ""
                echo -e "  ${D}从 @userinfobot 获取 Chat ID${NC}"
                read -rp "  Chat ID: " new_chat_id
                if [[ -n "$new_chat_id" ]]; then
                    tg_set_config "chat_id" "$new_chat_id"
                    chat_id="$new_chat_id"
                    _ok "Chat ID 已保存"
                fi
                _pause
                ;;
            3)
                if [[ -z "$bot_token" || -z "$chat_id" ]]; then
                    _err "请先配置 Bot Token 和 Chat ID"
                else
                    _info "发送测试消息..."
                    local current_enabled=$(tg_get_config "enabled")
                    [[ "$current_enabled" != "true" ]] && tg_set_config "enabled" "true"
                    if tg_send_message "🔔 测试消息 - VLESS 流量监控已配置成功!"; then
                        _ok "测试消息发送成功"
                    else
                        _err "发送失败，请检查配置"
                    fi
                    [[ "$current_enabled" != "true" ]] && tg_set_config "enabled" "false"
                fi
                _pause
                ;;
            4)
                if [[ "$enabled" == "true" ]]; then
                    tg_set_config "enabled" "false"
                    _ok "TG 通知已禁用"
                else
                    if [[ -z "$bot_token" || -z "$chat_id" ]]; then
                        _err "请先配置 Bot Token 和 Chat ID"
                    else
                        tg_set_config "enabled" "true"
                        _ok "TG 通知已启用"
                        
                        # 自动启动流量统计定时任务
                        if ! crontab -l 2>/dev/null | grep -q "sync-traffic"; then
                            echo ""
                            _info "TG 通知需要定时任务来检测流量..."
                            setup_traffic_cron
                        fi
                    fi
                fi
                _pause
                ;;
            5)
                echo ""
                echo -e "  ${D}设置流量检测间隔 (分钟)${NC}"
                local current_interval=$(get_traffic_interval)
                read -rp "  检测间隔 (1-60) [${current_interval}]: " new_interval
                new_interval="${new_interval:-$current_interval}"
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [[ "$new_interval" -ge 1 ]] && [[ "$new_interval" -le 60 ]]; then
                    if crontab -l 2>/dev/null | grep -q "sync-traffic"; then
                        setup_traffic_cron "$new_interval"
                    else
                        set_traffic_interval "$new_interval"
                        _ok "检测间隔已设置为 ${new_interval} 分钟"
                    fi
                else
                    _err "无效的间隔"
                fi
                _pause
                ;;
            6)
                # 检查并自动设置为中国时区（海外服务器需要）
                local current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")
                if [[ "$current_tz" != "Asia/Shanghai" ]]; then
                    _info "检测到服务器时区为 ${current_tz}，自动设置为中国时区 (Asia/Shanghai)..."
                    timedatectl set-timezone Asia/Shanghai 2>/dev/null && _ok "时区已设置为 Asia/Shanghai"
                fi
                
                echo ""
                echo -e "  ${W}每日报告设置${NC}"
                _line
                if [[ "$daily_enabled" == "true" ]]; then
                    echo -e "  当前状态: ${G}已启用${NC} (每天 ${report_time})"
                    echo ""
                    echo -e "  ${D}1) 修改发送时间${NC}"
                    echo -e "  ${D}2) 关闭每日报告${NC}"
                    echo -e "  ${D}0) 返回${NC}"
                    read -rp "  请选择 [0]: " daily_choice
                    case "$daily_choice" in
                        1)
                            echo ""
                            echo -e "  ${D}设置发送时间 (格式: HH:MM 或 HH)${NC}"
                            read -rp "  发送时间 [${report_time}]: " new_time
                            new_time="${new_time:-$report_time}"
                            local new_hour new_minute
                            if [[ "$new_time" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]]; then
                                new_hour="${BASH_REMATCH[1]}"
                                new_minute="${BASH_REMATCH[2]}"
                            elif [[ "$new_time" =~ ^[0-9]{1,2}$ ]]; then
                                new_hour="$new_time"
                                new_minute="0"
                            else
                                _err "无效的时间格式"
                                continue
                            fi
                            # 移除前导零进行数值比较
                            new_hour=$((10#$new_hour))
                            new_minute=$((10#$new_minute))
                            if [[ "$new_hour" -ge 0 ]] && [[ "$new_hour" -le 23 ]] && \
                               [[ "$new_minute" -ge 0 ]] && [[ "$new_minute" -le 59 ]]; then
                                tg_set_config "daily_report_hour" "$new_hour"
                                tg_set_config "daily_report_minute" "$new_minute"
                                # 清空上次发送日期，允许今天再次发送
                                tg_set_config "last_report_date" ""
                                _ok "发送时间已更新为 $(printf '%02d:%02d' $new_hour $new_minute)"
                            else
                                _err "无效的时间 (小时: 0-23, 分钟: 0-59)"
                            fi
                            ;;
                        2)
                            tg_set_config "notify_daily" "false"
                            _ok "每日报告已关闭"
                            ;;
                    esac
                else
                    echo -e "  当前状态: ${D}未启用${NC}"
                    read -rp "  是否启用每日报告? [Y/n]: " enable_daily
                    if [[ ! "$enable_daily" =~ ^[nN]$ ]]; then
                        echo ""
                        echo -e "  ${D}设置发送时间 (格式: HH:MM 或 HH，例如: 9:30 或 9)${NC}"
                        read -rp "  发送时间 [9:00]: " new_time
                        new_time="${new_time:-9:00}"
                        local new_hour new_minute
                        if [[ "$new_time" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]]; then
                            new_hour="${BASH_REMATCH[1]}"
                            new_minute="${BASH_REMATCH[2]}"
                        elif [[ "$new_time" =~ ^[0-9]{1,2}$ ]]; then
                            new_hour="$new_time"
                            new_minute="0"
                        else
                            _err "无效的时间格式"
                            continue
                        fi
                        # 移除前导零进行数值比较
                        new_hour=$((10#$new_hour))
                        new_minute=$((10#$new_minute))
                        if [[ "$new_hour" -ge 0 ]] && [[ "$new_hour" -le 23 ]] && \
                           [[ "$new_minute" -ge 0 ]] && [[ "$new_minute" -le 59 ]]; then
                            tg_set_config "notify_daily" "true"
                            tg_set_config "daily_report_hour" "$new_hour"
                            tg_set_config "daily_report_minute" "$new_minute"
                            # 清空上次发送日期，允许今天立即发送
                            tg_set_config "last_report_date" ""
                            _ok "每日报告已启用，将在每天 $(printf '%02d:%02d' $new_hour $new_minute) 发送"
                        else
                            _err "无效的时间 (小时: 0-23, 分钟: 0-59)"
                        fi
                    fi
                fi
                _pause
                ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

# 检测当前运行的核心类型
# 返回: xray, singbox, standalone, none
_detect_current_core() {
    # 优先检查 Xray
    if _pgrep xray &>/dev/null; then
        echo "xray"
        return
    fi
    
    # 检查 sing-box
    if _pgrep sing-box &>/dev/null || _pgrep singbox &>/dev/null; then
        echo "singbox"
        return
    fi
    
    # 检查独立协议
    if _pgrep hysteria &>/dev/null || _pgrep naive &>/dev/null || _pgrep tuic &>/dev/null; then
        echo "standalone"
        return
    fi
    
    # 检查是否有安装但未运行的情况（通过配置文件判断）
    if [[ -f "$XRAY_CONFIG" ]]; then
        echo "xray"
        return
    fi
    
    if [[ -f "$SINGBOX_CONFIG" ]]; then
        echo "singbox"
        return
    fi
    
    # 检查独立协议配置
    if [[ -f "/etc/hysteria/config.yaml" ]] || [[ -f "/etc/naive/config.json" ]]; then
        echo "standalone"
        return
    fi
    
    echo "none"
}

# 显示实时流量统计
_show_realtime_traffic() {
    _header
    echo -e "  ${W}实时流量统计${NC}"
    _dline
    
    # 检查是否有运行中的核心
    local has_xray=false
    local has_singbox=false
    
    if _pgrep xray &>/dev/null; then
        has_xray=true
    fi
    if _pgrep sing-box &>/dev/null; then
        has_singbox=true
    fi
    
    if [[ "$has_xray" == "false" && "$has_singbox" == "false" ]]; then
        echo ""
        _warn "未检测到运行中的代理核心"
        echo ""
        echo -e "  ${D}请先安装并启动 Xray 或 Sing-box 核心的协议。${NC}"
        return
    fi
    
    echo ""
    printf "  ${W}%-12s %-12s %-12s %-12s %-12s${NC}\n" "协议" "用户" "上行" "下行" "总计"
    _line
    
    local stats=$(get_all_traffic_stats)
    if [[ -z "$stats" ]]; then
        echo -e "  ${D}暂无流量数据${NC}"
    else
        while IFS='|' read -r proto user uplink downlink total; do
            [[ -z "$proto" ]] && continue
            local proto_name=$(get_protocol_name "$proto")
            local up_fmt=$(format_bytes "$uplink")
            local down_fmt=$(format_bytes "$downlink")
            local total_fmt=$(format_bytes "$total")
            printf "  %-12s %-12s %-12s %-12s %-12s\n" "$proto_name" "$user" "$up_fmt" "$down_fmt" "$total_fmt"
        done <<< "$stats"
    fi
    
    _line
    echo ""
    
    # 显示提示
    echo -e "  ${D}提示: 此为 Xray 启动后的累计流量，同步后会重置${NC}"
    
    # 如果有 Sing-box 运行，提示不支持流量统计
    if [[ "$has_singbox" == "true" ]]; then
        echo -e "  ${D}注意: Sing-box (hy2/tuic) 暂不支持流量统计（需完整版编译）${NC}"
    fi
}

# 立即同步流量数据
_sync_traffic_now() {
    _header
    echo -e "  ${W}同步流量数据${NC}"
    _dline
    
    # 检查是否有运行中的核心
    local has_xray=false
    local has_singbox=false
    
    if _pgrep xray &>/dev/null; then
        has_xray=true
    fi
    if _pgrep sing-box &>/dev/null; then
        has_singbox=true
    fi
    
    if [[ "$has_xray" == "false" && "$has_singbox" == "false" ]]; then
        echo ""
        _warn "未检测到运行中的代理核心"
        echo ""
        echo -e "  ${D}请先安装并启动 Xray 或 Sing-box 核心的协议。${NC}"
        return
    fi
    
    _info "正在同步流量数据..."
    
    if sync_all_user_traffic "true"; then
        _ok "流量数据已同步到数据库"
        echo ""
        
        # 显示同步后的统计
        echo -e "  ${W}用户流量统计:${NC}"
        _line
        
        # 显示 Xray 协议流量
        if [[ "$has_xray" == "true" ]]; then
            for proto in $(db_list_protocols "xray"); do
                local proto_name=$(get_protocol_name "$proto")
                local users=$(db_get_users_stats "xray" "$proto")
                [[ -z "$users" ]] && continue
                
                echo -e "  ${C}$proto_name${NC}"
                while IFS='|' read -r name uuid used quota enabled port routing; do
                    [[ -z "$name" ]] && continue
                    local used_fmt=$(format_bytes "$used")
                    local quota_fmt="无限制"
                    local status="${G}●${NC}"
                    
                    if [[ "$quota" -gt 0 ]]; then
                        quota_fmt=$(format_bytes "$quota")
                        local percent=$((used * 100 / quota))
                        if [[ "$percent" -ge 100 ]]; then
                            status="${R}✗${NC}"
                        elif [[ "$percent" -ge 80 ]]; then
                            status="${Y}⚠${NC}"
                        fi
                    fi
                    
                    [[ "$enabled" != "true" ]] && status="${R}○${NC}"
                    
                    echo -e "    $status $name: $used_fmt / $quota_fmt"
                done <<< "$users"
            done
        fi
        
        # Sing-box 协议 (hy2/tuic) 提示不支持流量统计
        if [[ "$has_singbox" == "true" ]]; then
            echo ""
            echo -e "  ${D}注意: Sing-box (hy2/tuic) 暂不支持流量统计（需完整版编译）${NC}"
        fi
        
        _line
    else
        _err "同步失败"
    fi
}

# 流量统计设置
_configure_traffic_stats() {
    while true; do
        _header
        echo -e "  ${W}流量统计设置${NC}"
        _dline
        
        # 检查定时任务状态
        local cron_status="${R}○ 未启用${NC}"
        local current_interval=$(get_traffic_interval)
        if crontab -l 2>/dev/null | grep -q "sync-traffic"; then
            cron_status="${G}● 已启用 (每${current_interval}分钟)${NC}"
        fi
        
        local notify_percent=$(tg_get_config "notify_quota_percent")
        notify_percent=${notify_percent:-80}
        
        echo -e "  自动同步: $cron_status"
        echo -e "  检测间隔: ${G}${current_interval} 分钟${NC}"
        echo -e "  告警阈值: ${G}${notify_percent}%${NC}"
        _line
        
        _item "1" "启用自动同步"
        _item "2" "禁用自动同步"
        _item "3" "设置检测间隔"
        _item "4" "设置告警阈值"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        case $choice in
            1)
                setup_traffic_cron "$current_interval"
                _pause
                ;;
            2)
                remove_traffic_cron
                _pause
                ;;
            3)
                echo ""
                echo -e "  ${D}设置流量检测间隔 (分钟)${NC}"
                echo -e "  ${D}建议: 1-5分钟 (实时性高), 10-30分钟 (节省资源)${NC}"
                read -rp "  检测间隔 (1-60) [${current_interval}]: " new_interval
                new_interval="${new_interval:-$current_interval}"
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [[ "$new_interval" -ge 1 ]] && [[ "$new_interval" -le 60 ]]; then
                    if crontab -l 2>/dev/null | grep -q "sync-traffic"; then
                        setup_traffic_cron "$new_interval"
                    else
                        set_traffic_interval "$new_interval"
                        _ok "检测间隔已设置为 ${new_interval} 分钟"
                        echo -e "  ${D}下次启用自动同步时生效${NC}"
                    fi
                else
                    _err "无效的间隔 (请输入 1-60)"
                fi
                _pause
                ;;
            4)
                echo ""
                echo -e "  ${D}当用户流量达到配额的 X% 时发送告警${NC}"
                read -rp "  告警阈值 (1-99) [${notify_percent}]: " new_percent
                new_percent="${new_percent:-$notify_percent}"
                if [[ "$new_percent" =~ ^[0-9]+$ ]] && [[ "$new_percent" -ge 1 ]] && [[ "$new_percent" -le 99 ]]; then
                    tg_set_config "notify_quota_percent" "$new_percent"
                    _ok "告警阈值已设置为 ${new_percent}%"
                else
                    _err "无效的阈值"
                fi
                _pause
                ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

# 用户管理主菜单
manage_users() {
    while true; do
        _header
        echo -e "  ${W}用户管理${NC}"
        _dline
        
        # 显示所有协议的用户统计
        local protocols=$(db_get_all_protocols)
        if [[ -n "$protocols" ]]; then
            echo -e "  ${D}已安装协议:${NC}"
            while IFS= read -r proto; do
                [[ -z "$proto" ]] && continue
                local core="xray"
                db_exists "singbox" "$proto" && core="singbox"
                local user_count=$(db_count_users "$core" "$proto")
                local proto_name=$(get_protocol_name "$proto")
                echo -e "  • $proto_name: ${G}$user_count${NC} 用户"
            done <<< "$protocols"
        fi
        
        _line
        _item "1" "查看用户列表"
        _item "2" "添加用户"
        _item "3" "删除用户"
        _item "4" "设置用户配额"
        _item "5" "重置用户流量"
        _item "6" "启用/禁用用户"
        _item "e" "设置到期日期"
        _item "r" "修改用户路由"
        _item "s" "查看用户分享链接"
        _line
        _item "7" "实时流量统计"
        _item "8" "同步流量数据"
        _item "9" "流量统计设置"
        _line
        _item "t" "TG 通知配置"
        _item "0" "返回"
        _line
        
        read -rp "  请选择: " choice
        case $choice in
            1)
                if _select_protocol_for_users; then
                    _show_users_list "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            2)
                if _select_protocol_for_users; then
                    _add_user "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            3)
                if _select_protocol_for_users; then
                    _delete_user "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            4)
                if _select_protocol_for_users; then
                    _set_user_quota "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            5)
                if _select_protocol_for_users; then
                    _reset_user_traffic "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            6)
                if _select_protocol_for_users; then
                    _toggle_user "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            e|E)
                if _select_protocol_for_users; then
                    _set_user_expire_date "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            r|R)
                if _select_protocol_for_users; then
                    _set_user_routing "$SELECTED_CORE" "$SELECTED_PROTO"
                    _pause
                fi
                ;;
            7)
                _show_realtime_traffic
                _pause
                ;;
            8)
                _sync_traffic_now
                _pause
                ;;
            9)
                _configure_traffic_stats
                ;;
            s|S)
                if _select_protocol_for_users; then
                    _show_user_share_links "$SELECTED_CORE" "$SELECTED_PROTO"
                fi
                ;;
            t|T)
                _configure_tg_notify
                ;;
            0) return ;;
            *) _err "无效选择" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════════════
# 脚本更新与主入口
#═══════════════════════════════════════════════════════════════════════════════

do_update() {
    _header
    echo -e "  ${W}脚本更新${NC}"
    _line
    
    echo -e "  当前版本: ${G}v${VERSION}${NC}"
    _info "检查最新版本..."
    
    _init_version_cache
    local tmp_file="" remote_ver=""
    remote_ver=$(_get_latest_script_version "true" "false")
    if [[ -z "$remote_ver" ]]; then
        _err "无法获取远程版本信息"
        return 1
    fi
    
    echo -e "  最新版本: ${C}v${remote_ver}${NC}"
    
    # 比较版本 - 只有远程版本更新时才提示更新
    if ! _version_gt "$remote_ver" "$VERSION"; then
        _ok "已是最新版本"
        return 0
    fi
    
    _line
    read -rp "  发现新版本，是否更新? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        return 0
    fi
    
    _info "更新中..."
    tmp_file=$(_fetch_script_tmp 10)
    if [[ -z "$tmp_file" || ! -f "$tmp_file" ]]; then
        _err "下载失败，请检查网络连接"
        return 1
    fi
    local downloaded_ver
    downloaded_ver=$(_extract_script_version "$tmp_file")
    if [[ -n "$downloaded_ver" && "$downloaded_ver" != "$remote_ver" ]]; then
        remote_ver="$downloaded_ver"
        echo "$remote_ver" > "$SCRIPT_VERSION_CACHE_FILE" 2>/dev/null
    fi
    
    # 获取当前脚本路径
    local script_path=$(readlink -f "$0")
    local script_dir=$(dirname "$script_path")
    local script_name=$(basename "$script_path")
    
    # 系统目录的脚本路径
    local system_script="/usr/local/bin/vless-server.sh"
    
    # 备份当前脚本
    cp "$script_path" "${script_path}.bak" 2>/dev/null
    
    # 替换当前运行的脚本
    if mv "$tmp_file" "$script_path" && chmod +x "$script_path"; then
        # 如果当前脚本不是系统目录的脚本，也更新系统目录
        if [[ "$script_path" != "$system_script" && -f "$system_script" ]]; then
            cp -f "$script_path" "$system_script" 2>/dev/null
            chmod +x "$system_script" 2>/dev/null
            _info "已同步更新系统目录脚本"
        fi
        
        _ok "更新成功! v${VERSION} -> v${remote_ver}"
        echo ""
        echo -e "  ${C}请重新运行脚本以使用新版本${NC}"
        echo -e "  ${D}备份文件: ${script_path}.bak${NC}"
        _line
        exit 0
    else
        # 恢复备份
        [[ -f "${script_path}.bak" ]] && mv "${script_path}.bak" "$script_path"
        rm -f "$tmp_file"
        _err "更新失败"
        return 1
    fi
}

main_menu() {
    check_root
    init_log  # 初始化日志
    init_db   # 初始化 JSON 数据库
    db_migrate_to_multiuser  # 迁移旧的单用户配置到多用户格式

    # 自动更新系统脚本 (确保 vless 命令始终是最新版本)
    _auto_update_system_script

    # 初始化版本缓存目录
    _init_version_cache

    # 启动时立即异步获取最新版本（后台执行，不阻塞主界面）
    # 使用统一函数，一次请求同时获取稳定版和测试版（减少API请求次数）
    _update_all_versions_async "XTLS/Xray-core"
    _update_all_versions_async "SagerNet/sing-box"
    _check_script_update_async

    # 自动同步隧道配置
    _sync_tunnel_config 2>/dev/null

    while true; do
        _header
        echo -e "  ${W}服务端管理${NC}"

        # 获取系统版本信息
        local os_version="$DISTRO"
        if [[ -f /etc/os-release ]]; then
            local version_id=$(grep "^VERSION_ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
            [[ -n "$version_id" ]] && os_version="$DISTRO $version_id"
        elif [[ -f /etc/lsb-release ]]; then
            local version_id=$(grep "^DISTRIB_RELEASE=" /etc/lsb-release | cut -d'=' -f2)
            [[ -n "$version_id" ]] && os_version="$DISTRO $version_id"
        fi

        # 获取内核版本
        local kernel_version=$(uname -r)

        # 初始化版本缓存（确保缓存目录存在）
        _init_version_cache

        # 获取核心版本及状态（使用公共方法）
        local xray_ver_with_status singbox_ver_with_status
        xray_ver_with_status=$(_get_core_version_with_status "xray" "XTLS/Xray-core")
        singbox_ver_with_status=$(_get_core_version_with_status "sing-box" "SagerNet/sing-box")
        local script_update_ver=""
        if _has_script_update; then
            script_update_ver=$(_get_script_update_info)
        fi

        # 启动异步版本检查（后台，仅首次进入时触发）
        if [[ -z "$_version_check_started" ]]; then
            local xray_current singbox_current
            xray_current=$(_get_core_version "xray")
            singbox_current=$(_get_core_version "sing-box")
            _check_version_updates_async "$xray_current" "$singbox_current"
            _version_check_started=1
        fi

        # 显示版本信息（已包含状态标识）
        echo -e "  ${D}系统: ${os_version} | ${kernel_version}${NC}"
        echo -e "  ${D}核心: Xray ${xray_ver_with_status} | Sing-box ${singbox_ver_with_status}${NC}"
        if [[ -n "$script_update_ver" ]]; then
            echo -e "  ${Y}提示: 脚本有新版本 v${script_update_ver}，可在菜单选择「检查脚本更新」${NC}"
        fi
        echo ""
        show_status
        echo ""
        _line

        # 复用 show_status 缓存的结果，避免重复查询数据库
        local installed="$_INSTALLED_CACHE"
        if [[ -n "$installed" ]]; then
            # 多协议服务端菜单
            _item "1" "安装新协议 (多协议共存)"
            _item "2" "核心版本管理 (Xray/Sing-box)"
            _item "3" "卸载指定协议"
            _item "4" "用户管理 (多用户/流量/通知)"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            _item "5" "查看协议配置"
            _item "6" "订阅服务管理"
            _item "7" "管理协议服务"
            _item "8" "分流管理"
            _item "9" "CF Tunnel(Argo)"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            _item "10" "BBR 网络优化"
            _item "11" "查看运行日志"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            local script_update_item="检查脚本更新"
            [[ -n "$script_update_ver" ]] && script_update_item="检查脚本更新 ${Y}[有更新 v${script_update_ver}]${NC}"
            _item "12" "$script_update_item"
            _item "13" "完全卸载"
        else
            _item "1" "安装协议"
            echo -e "  ${D}───────────────────────────────────────────${NC}"
            local script_update_item="检查脚本更新"
            [[ -n "$script_update_ver" ]] && script_update_item="检查脚本更新 ${Y}[有更新 v${script_update_ver}]${NC}"
            _item "12" "$script_update_item"
        fi
        _item "0" "退出"
        _line

        read -rp "  请选择: " choice || exit 0
        
        local skip_pause=false
        if [[ -n "$installed" ]]; then
            case $choice in
                1) do_install_server; skip_pause=true ;;
                2) update_core_menu; skip_pause=true ;;
                3) uninstall_specific_protocol; skip_pause=true ;;
                4) manage_users; skip_pause=true ;;
                5) show_all_protocols_info; skip_pause=true ;;
                6) manage_subscription; skip_pause=true ;;
                7) manage_protocol_services; skip_pause=true ;;
                8) manage_routing; skip_pause=true ;;
                9) manage_cloudflare_tunnel; skip_pause=true ;;
                10) enable_bbr; skip_pause=true ;;
                11) show_logs; skip_pause=true ;;
                12) do_update ;;
                13) do_uninstall ;;
                0) exit 0 ;;
                *) _err "无效选择"; skip_pause=true ;;
            esac
        else
            case $choice in
                1) do_install_server; skip_pause=true ;;
                12) do_update ;;
                0) exit 0 ;;
                *) _err "无效选择"; skip_pause=true ;;
            esac
        fi
        [[ "$skip_pause" == "false" ]] && _pause
    done
}

# 命令行参数处理
case "${1:-}" in
    --sync-traffic)
        # 静默模式：用于定时任务
        init_db
        sync_all_user_traffic "true"
        exit 0
        ;;
    --show-traffic)
        # 显示流量统计
        init_db
        get_all_traffic_stats
        exit 0
        ;;
    --check-expire)
        # 检查并禁用过期用户，发送提醒
        init_db
        echo "检查用户到期状态..."
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始过期检查..." >> "$CFG/expire.log"
        # 发送即将过期提醒 (3天内)
        warnings=$(send_expire_warnings 3)
        echo "  发送 $warnings 条过期提醒" >> "$CFG/expire.log"
        # 禁用过期用户
        if [[ "${2:-}" == "--notify" ]]; then
            disabled=$(check_and_disable_expired_users --notify)
        else
            disabled=$(check_and_disable_expired_users)
        fi
        echo "  禁用 $disabled 个过期用户" >> "$CFG/expire.log"
        # 输出结果到终端
        echo "  即将过期提醒: $warnings 条"
        echo "  禁用过期用户: $disabled 个"
        echo "完成。日志: $CFG/expire.log"
        exit 0
        ;;
    --setup-expire-cron)
        # 安装过期检查定时任务
        init_db
        install_expire_check_cron
        exit 0
        ;;
    --help|-h)
        echo "用法: $0 [选项]"
        echo ""
        echo "选项:"
        echo "  --sync-traffic       同步流量数据到数据库 (用于定时任务)"
        echo "  --show-traffic       显示实时流量统计"
        echo "  --check-expire       检查并禁用过期用户 (用于定时任务)"
        echo "  --setup-expire-cron  安装过期检查定时任务"
        echo "  --help, -h           显示帮助信息"
        echo ""
        echo "无参数时启动交互式菜单"
        exit 0
        ;;
    "")
        # 无参数，启动主菜单
        main_menu
        ;;
    *)
        echo "未知参数: $1"
        echo "使用 --help 查看帮助"
        exit 1
        ;;
esac