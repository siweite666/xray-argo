#!/usr/bin/env bash
#
# install.sh - VLESS + XHTTP 经 Cloudflare 固定 Argo 隧道的一键部署脚本
#
# 特点：VPS 不对外开放任何代理端口，真实 IP 不暴露。
# 用法：bash <(curl -Ls https://raw.githubusercontent.com/<user>/<repo>/main/install.sh) \
#         token="" domain="" port="8001" protocol="quic" path="" uuid="" vmess="n" cfip=""
#
set -euo pipefail

# ============================================================
# 全局常量
# ============================================================
readonly APP_DIR="/etc/xray-argo"
readonly SVC_NAME="xray-argo"
readonly CF_SVC_NAME="cloudflared-argo"
readonly XA_PATH="/usr/local/bin/xa"
readonly XRAY_REPO="XTLS/Xray-core"
readonly CF_REPO="cloudflare/cloudflared"
readonly ENV_FILE="${APP_DIR}/install.env"

# 颜色（非 TTY 时降级为纯文本，避免日志里出现控制字符）
if [ -t 1 ]; then
    C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;91m'
    C_CYAN=$'\033[1;36m';  C_RESET=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_RESET=""
fi

log()  { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die()  { err "错误：$*"; exit 1; }

# ============================================================
# 参数解析
# 支持两种写法：key="value" （推荐）与 key"value"（兼容旧脚本风格）
# 未提供的项使用默认值；token / domain 为空时交互式询问
# ============================================================
ARG_TOKEN=""
ARG_DOMAIN=""
ARG_PORT="8001"
ARG_PROTOCOL="quic"
ARG_PATH=""
ARG_UUID=""
ARG_VMESS="n"
ARG_CFIP=""

parse_args() {
    local arg key val
    for arg in "$@"; do
        # 去掉整体包裹的引号
        arg="${arg%\"}"; arg="${arg#\"}"
        arg="${arg%\'}"; arg="${arg#\'}"

        if [[ "$arg" == *=* ]]; then
            key="${arg%%=*}"
            val="${arg#*=}"
        elif [[ "$arg" =~ ^([a-zA-Z_]+)[\"\'](.*)[\"\']$ ]]; then
            # 兼容 token"xxx" 形式
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
        else
            continue
        fi
        # 值里可能残留引号
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"

        case "${key,,}" in
            token)    ARG_TOKEN="$val" ;;
            domain)   ARG_DOMAIN="$val" ;;
            port)     ARG_PORT="$val" ;;
            protocol) ARG_PROTOCOL="$val" ;;
            path)     ARG_PATH="$val" ;;
            uuid)     ARG_UUID="$val" ;;
            vmess)    ARG_VMESS="$val" ;;
            cfip)     ARG_CFIP="$val" ;;
            *)        warn "忽略未知参数：$key" ;;
        esac
    done

    # 交互式补全必填项
    if [ -z "$ARG_TOKEN" ]; then
        printf '请输入 Cloudflare 固定隧道 Token: '
        read -r ARG_TOKEN || true
    fi
    if [ -z "$ARG_DOMAIN" ]; then
        printf '请输入隧道 Public Hostname 的完整域名（如 node.example.com）: '
        read -r ARG_DOMAIN || true
    fi

    [ -n "$ARG_TOKEN" ]  || die "token 不能为空"
    [ -n "$ARG_DOMAIN" ] || die "domain 不能为空"

    # 域名规范化：去掉协议、路径、末尾斜杠
    ARG_DOMAIN="${ARG_DOMAIN#http://}"
    ARG_DOMAIN="${ARG_DOMAIN#https://}"
    ARG_DOMAIN="${ARG_DOMAIN%%/*}"
    ARG_DOMAIN="${ARG_DOMAIN%.}"

    # 端口合法性
    [[ "$ARG_PORT" =~ ^[0-9]+$ ]] || die "port 必须是数字，当前：${ARG_PORT}"
    if [ "$ARG_PORT" -lt 1 ] || [ "$ARG_PORT" -gt 65535 ]; then
        die "port 超出范围 1-65535"
    fi

    # 协议合法性
    ARG_PROTOCOL="${ARG_PROTOCOL,,}"
    case "$ARG_PROTOCOL" in
        quic|http2) ;;
        *) die "protocol 只能是 quic 或 http2，当前：${ARG_PROTOCOL}" ;;
    esac

    # vmess 开关
    ARG_VMESS="${ARG_VMESS,,}"
    case "$ARG_VMESS" in
        y|yes|1|true) ARG_VMESS="y" ;;
        *)            ARG_VMESS="n" ;;
    esac
}

# ============================================================
# 环境检查
# ============================================================
check_root() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 身份运行"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-}"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"; OS_VER="$(cat /etc/alpine-release)"
    else
        die "无法识别系统（缺少 /etc/os-release）"
    fi
    log "系统：${OS_ID} ${OS_VER}"

    if command -v apk >/dev/null 2>&1; then
        PKG="apk"
        INIT_SYS="openrc"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG="apt"
        INIT_SYS="systemd"
    elif command -v dnf >/dev/null 2>&1; then
        PKG="dnf"
        INIT_SYS="systemd"
    elif command -v yum >/dev/null 2>&1; then
        PKG="yum"
        INIT_SYS="systemd"
    else
        die "不支持的包管理器（需要 apk / apt / dnf / yum）"
    fi
    log "包管理器：${PKG}，init：${INIT_SYS}"
}

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)   XRAY_ARCH="64";         CF_ARCH="amd64" ;;
        aarch64|arm64)  XRAY_ARCH="arm64-v8a";  CF_ARCH="arm64" ;;
        *) die "不支持的架构：${m}（仅支持 amd64 / arm64）" ;;
    esac
    log "架构：${m} → Xray(${XRAY_ARCH}) / cloudflared(${CF_ARCH})"
}

install_deps() {
    log "正在安装依赖..."
    case "$PKG" in
        apt)
            apt-get update -qq || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                curl unzip openssl ca-certificates >/dev/null 2>&1 || true
            ;;
        dnf)
            dnf install -y -q curl unzip openssl ca-certificates >/dev/null 2>&1 || true
            ;;
        yum)
            yum install -y -q curl unzip openssl ca-certificates >/dev/null 2>&1 || true
            ;;
        apk)
            apk update >/dev/null 2>&1 || true
            apk add --no-cache bash curl unzip openssl ca-certificates >/dev/null 2>&1 || true
            ;;
    esac

    local c
    for c in curl unzip openssl; do
        command -v "$c" >/dev/null 2>&1 || die "依赖缺失：${c}"
    done
    ok "依赖就绪"
}

# ============================================================
# 下载与校验
# 只从官方 GitHub Release 下载；GH_PROXY 仅供用户自行指定镜像
# Xray zip 用官方 .dgst 里的 SHA2-256 校验，校验失败立即退出
# ============================================================
official_url() {
    local repo="$1" file="$2"
    printf 'https://github.com/%s/releases/latest/download/%s' "$repo" "$file"
}

fetch() {
    # fetch <输出文件> <官方URL>
    local out="$1" url="$2"
    local proxy="${GH_PROXY:-}"

    # 先直连官方
    if curl -fsSL --connect-timeout 10 --max-time 300 -o "$out" "$url" 2>/dev/null \
        && [ -s "$out" ]; then
        return 0
    fi

    # 用户明确提供的代理才使用（不做任何第三方默认镜像）
    if [ -n "$proxy" ]; then
        warn "官方源直连失败，尝试 GH_PROXY：${proxy}"
        local purl
        case "$proxy" in
            */) purl="${proxy}${url}" ;;
            *)  purl="${proxy}/${url}" ;;
        esac
        if curl -fsSL --connect-timeout 10 --max-time 300 -o "$out" "$purl" 2>/dev/null \
            && [ -s "$out" ]; then
            return 0
        fi
    fi
    return 1
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

download_xray() {
    local zip="${APP_DIR}/xray.zip"
    local dgst="${APP_DIR}/xray.zip.dgst"
    local base="Xray-linux-${XRAY_ARCH}.zip"

    log "下载 Xray-core（官方 Release）..."
    fetch "$zip"  "$(official_url "$XRAY_REPO" "$base")"       || die "Xray-core 下载失败（可设置 GH_PROXY 指定代理）"
    fetch "$dgst" "$(official_url "$XRAY_REPO" "${base}.dgst")" || die "Xray .dgst 下载失败"

    local want have
    want="$(grep -o 'SHA2-256=[[:space:]]*[0-9a-fA-F]*' "$dgst" | head -1 | sed 's/.*=[[:space:]]*//' | tr 'A-F' 'a-f')"
    [ -n "$want" ] || die ".dgst 文件里没有 SHA2-256，无法校验"
    have="$(sha256_of "$zip" | tr 'A-F' 'a-f')"

    if [ "$want" != "$have" ]; then
        rm -f "$zip" "$dgst"
        die "Xray 校验失败！期望 ${want}，实际 ${have}"
    fi
    ok "Xray 校验通过（SHA256 ${have:0:16}...）"

    unzip -qo "$zip" -d "$APP_DIR" || die "解压 Xray 失败"
    rm -f "$zip" "$dgst"
    chmod +x "${APP_DIR}/xray"
    XRAY_VER="$("${APP_DIR}/xray" version 2>/dev/null | head -1 || echo unknown)"
    ok "Xray 就绪：${XRAY_VER}"
}

download_cloudflared() {
    local out="${APP_DIR}/cloudflared"
    log "下载 cloudflared（官方 Release）..."
    fetch "$out" "$(official_url "$CF_REPO" "cloudflared-linux-${CF_ARCH}")" \
        || die "cloudflared 下载失败（可设置 GH_PROXY 指定代理）"
    chmod +x "$out"
    CF_VER="$("$out" --version 2>/dev/null | head -1 || echo unknown)"
    ok "cloudflared 就绪：${CF_VER}"
}

# ============================================================
# 生成随机参数
# ============================================================
gen_uuid() {
    if [ -n "$ARG_UUID" ]; then
        printf '%s' "$ARG_UUID"
        return
    fi
    # 已安装过则复用，保证幂等（重复运行不换 UUID）
    if [ -f "$ENV_FILE" ]; then
        local old
        old="$(grep -E '^XRAY_UUID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
        if [ -n "$old" ]; then printf '%s' "$old"; return; fi
    fi
    if [ -x "${APP_DIR}/xray" ]; then
        "${APP_DIR}/xray" uuid
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
    fi
}

gen_token_str() {
    # gen_token_str <长度>：生成 URL 安全的随机串
    #
    # 注意：不能用 `tr < /dev/urandom | head -c N`。
    # 在 set -o pipefail 下，head 读够 N 字节就退出，tr 随之收到 SIGPIPE，
    # 整条管道返回 141，配合 set -e 会让脚本静默中断（踩过）。
    # 改为先取定长随机字节再过滤，全程不产生 SIGPIPE。
    local n="${1:-20}" raw out
    # 多取 4 倍字节，过滤后仍能凑够 n 个
    raw="$(od -An -tx1 -N "$((n * 4))" /dev/urandom 2>/dev/null | tr -d ' \n')"
    if [ -z "$raw" ] && command -v openssl >/dev/null 2>&1; then
        raw="$(openssl rand -hex "$((n * 2))")"
    fi
    out="$(printf '%s' "$raw" | tr -dc 'A-Za-z0-9' | cut -c "1-${n}")"
    # 万一过滤后不够长，用时间戳+pid 补齐
    while [ "${#out}" -lt "$n" ]; do
        out="${out}$(date +%s%N | tr -dc '0-9')"
    done
    printf '%s' "${out:0:n}"
}

# URL 编码（纯 bash，避免依赖 python / jq）
urlencode() {
    local s="$1" out="" c i hex
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

b64() { printf '%s' "$1" | base64 | tr -d '\n\r'; }

# ============================================================
# 配置生成
# ============================================================
build_config() {
    local xhttp_path="$1" ws_path="$2" vmess_on="$3"

    # XHTTP 入站：仅监听 127.0.0.1，由 cloudflared 反代进来
    # mode=auto 兼容客户端 packet-up / stream-up
    # xPaddingBytes 保留默认 100-1000，增加流量随机性
    local inbounds
    inbounds=$(cat <<EOF
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": ${ARG_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${xhttp_path}",
          "mode": "auto",
          "xPaddingBytes": "100-1000"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
EOF
)

    # 可选备用入站：VMess + WS，同样只监听本地
    if [ "$vmess_on" = "y" ]; then
        inbounds="${inbounds},
    {
      \"tag\": \"vmess-ws\",
      \"listen\": \"127.0.0.1\",
      \"port\": ${VMESS_PORT},
      \"protocol\": \"vmess\",
      \"settings\": {
        \"clients\": [{ \"id\": \"${UUID}\" }]
      },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"wsSettings\": { \"path\": \"${ws_path}\" }
      },
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"http\", \"tls\", \"quic\"]
      }
    }"
    fi

    # 路由：屏蔽私有地址与国内 IP，避免节点被当成跳板
    cat > "${APP_DIR}/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "ip": ["geoip:private", "geoip:cn"]
      }
    ]
  }
}
EOF
    chmod 600 "${APP_DIR}/config.json"
}

test_config() {
    log "校验 Xray 配置..."
    local out
    if ! out="$("${APP_DIR}/xray" run -test -config "${APP_DIR}/config.json" 2>&1)"; then
        err "$out"
        die "Xray 配置校验失败"
    fi
    if ! printf '%s' "$out" | grep -q 'Configuration OK'; then
        err "$out"
        die "Xray 配置校验未通过"
    fi
    ok "配置校验通过"
}

# ============================================================
# 服务安装（幂等：先移除旧单元再写入）
# ============================================================
write_systemd() {
    # xray 服务
    cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=Xray (VLESS+XHTTP behind Cloudflare Argo tunnel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=${APP_DIR}
ExecStart=${APP_DIR}/xray run -config ${APP_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    # cloudflared 服务
    # Token 通过 EnvironmentFile 传入，不出现在命令行参数里（避免 ps 泄露）
    cat > "/etc/systemd/system/${CF_SVC_NAME}.service" <<EOF
[Unit]
Description=Cloudflare Argo tunnel for Xray
After=network-online.target ${SVC_NAME}.service
Wants=network-online.target
Requires=${SVC_NAME}.service

[Service]
Type=simple
User=root
EnvironmentFile=${APP_DIR}/cloudflared.env
ExecStart=${APP_DIR}/cloudflared tunnel --no-autoupdate run --protocol ${ARG_PROTOCOL}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SVC_NAME}" "${CF_SVC_NAME}" >/dev/null 2>&1 || true
}

write_openrc() {
    cat > "/etc/init.d/${SVC_NAME}" <<EOF
#!/sbin/openrc-run
description="Xray (VLESS+XHTTP behind Cloudflare Argo tunnel)"

command="${APP_DIR}/xray"
command_args="run -config ${APP_DIR}/config.json"
command_background=true
pidfile="/run/${SVC_NAME}.pid"
export XRAY_LOCATION_ASSET="${APP_DIR}"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "/etc/init.d/${SVC_NAME}"

    cat > "/etc/init.d/${CF_SVC_NAME}" <<EOF
#!/sbin/openrc-run
description="Cloudflare Argo tunnel for Xray"

command="${APP_DIR}/cloudflared"
command_args="tunnel --no-autoupdate run --protocol ${ARG_PROTOCOL}"
command_background=true
pidfile="/run/${CF_SVC_NAME}.pid"

depend() {
    need net
    after ${SVC_NAME}
}
EOF
    chmod +x "/etc/init.d/${CF_SVC_NAME}"

    # OpenRC 通过 env 文件注入 token
    set -a
    # shellcheck disable=SC1090,SC1091
    . "${APP_DIR}/cloudflared.env"
    set +a

    rc-update add "${SVC_NAME}" default >/dev/null 2>&1 || true
    rc-update add "${CF_SVC_NAME}" default >/dev/null 2>&1 || true
}

write_cloudflared_env() {
    # 600 权限，token 不落日志、不进命令行
    umask 077
    cat > "${APP_DIR}/cloudflared.env" <<EOF
TUNNEL_TOKEN=${ARG_TOKEN}
EOF
    chmod 600 "${APP_DIR}/cloudflared.env"

    # cloudflared 原生支持 TUNNEL_TOKEN 环境变量，故 unit 里不写 --token
    umask 022
}

start_services() {
    log "启动服务..."
    if [ "$INIT_SYS" = "systemd" ]; then
        systemctl restart "${SVC_NAME}" 2>/dev/null || systemctl start "${SVC_NAME}"
        sleep 2
        systemctl restart "${CF_SVC_NAME}" 2>/dev/null || systemctl start "${CF_SVC_NAME}"
        sleep 3

        local bad=0 s
        for s in "${SVC_NAME}" "${CF_SVC_NAME}"; do
            if ! systemctl is-active --quiet "$s"; then
                err "服务 $s 未运行，最近 20 行日志："
                journalctl -u "$s" -n 20 --no-pager 2>/dev/null || true
                bad=1
            fi
        done
        [ "$bad" -eq 0 ] || die "服务启动失败"
    else
        rc-service "${SVC_NAME}" restart >/dev/null 2>&1 || rc-service "${SVC_NAME}" start
        sleep 2
        rc-service "${CF_SVC_NAME}" restart >/dev/null 2>&1 || rc-service "${CF_SVC_NAME}" start
        sleep 3

        local bad=0 s
        for s in "${SVC_NAME}" "${CF_SVC_NAME}"; do
            if ! rc-service "$s" status >/dev/null 2>&1; then
                err "服务 $s 未运行，最近日志："
                tail -n 20 "/var/log/${s}.log" 2>/dev/null || true
                bad=1
            fi
        done
        [ "$bad" -eq 0 ] || die "服务启动失败"
    fi
    ok "两个服务均已启动"
}

# ============================================================
# 客户端链接生成
# 禁止 allowInsecure=1：TLS 由 Cloudflare 边缘提供，证书有效
# ============================================================
write_links() {
    local cfip="${ARG_CFIP:-$ARG_DOMAIN}"
    local enc_path
    enc_path="$(urlencode "$XHTTP_PATH")"
    : > "${APP_DIR}/url.txt"

    # 节点 A：h2
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&host=%s&alpn=h2&fp=chrome&type=xhttp&mode=packet-up&path=%s#Argo-XHTTP-H2\n' \
        "$UUID" "$cfip" "$ARG_DOMAIN" "$ARG_DOMAIN" "$enc_path" >> "${APP_DIR}/url.txt"

    # 节点 B：h3
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&host=%s&alpn=h3&fp=chrome&type=xhttp&mode=packet-up&path=%s#Argo-XHTTP-H3\n' \
        "$UUID" "$cfip" "$ARG_DOMAIN" "$ARG_DOMAIN" "$enc_path" >> "${APP_DIR}/url.txt"

    # 可选：VMess + WS + TLS（需在 Cloudflare 为 vmess 子域名另建 Public Hostname → localhost:VMESS_PORT）
    if [ "$ARG_VMESS" = "y" ]; then
        local vmess_host="vmess.${ARG_DOMAIN}"
        local ws_enc
        ws_enc="$(urlencode "$WS_PATH")"
        local vjson
        vjson=$(printf '{"v":"2","ps":"Argo-VMess-WS","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":"h2,http/1.1","fp":"chrome"}' \
            "$cfip" "$UUID" "$vmess_host" "$ws_enc" "$vmess_host")
        printf 'vmess://%s\n' "$(b64 "$vjson")" >> "${APP_DIR}/url.txt"
    fi

    chmod 600 "${APP_DIR}/url.txt"

    # base64 订阅内容
    b64 "$(cat "${APP_DIR}/url.txt")" > "${APP_DIR}/sub.txt"
    chmod 600 "${APP_DIR}/sub.txt"
}

show_links() {
    [ -f "${APP_DIR}/url.txt" ] || { err "链接文件不存在，请先运行安装"; return 1; }
    printf '\n%s\n' "${C_CYAN}================ 客户端节点链接 ================${C_RESET}"
    cat "${APP_DIR}/url.txt"
    printf '\n%s\n' "${C_CYAN}================ Base64 订阅 ================${C_RESET}"
    cat "${APP_DIR}/sub.txt"
    printf '\n%s\n' "${C_CYAN}============================================${C_RESET}"
    printf '说明：h3 为日常首选（UDP，抗 QoS），h2 为限速或断流时的备用。\n\n'
}

# ============================================================
# xa 管理命令
# ============================================================
install_xa() {
    cat > "$XA_PATH" <<'XAEOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="/etc/xray-argo"
SVC="xray-argo"
CF_SVC="cloudflared-argo"
ENVF="${APP_DIR}/install.env"

c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;91m'; c_c=$'\033[1;36m'; c_0=$'\033[0m'
[ -t 1 ] || { c_g=""; c_y=""; c_r=""; c_c=""; c_0=""; }

need_root() { [ "$(id -u)" -eq 0 ] || { echo "请以 root 运行" >&2; exit 1; }; }
load_env() { [ -f "$ENVF" ] && . "$ENVF" || true; }

svc_ctl() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl "$@" 2>/dev/null
    else
        local a="$1"; shift
        case "$a" in
            restart) rc-service "$1" restart ;;
            status)  rc-service "$1" status ;;
            *)       rc-service "$1" "$a" ;;
        esac
    fi
}

case "${1:-}" in
  links)
      [ -f "${APP_DIR}/url.txt" ] || { echo "没有找到链接文件"; exit 1; }
      printf '%s\n' "${c_c}================ 节点链接 ================${c_0}"
      cat "${APP_DIR}/url.txt"
      printf '\n%s\n' "${c_c}================ Base64 订阅 ================${c_0}"
      cat "${APP_DIR}/sub.txt"
      printf '\n'
      ;;
  status)
      need_root
      echo "=== ${SVC} ==="
      svc_ctl status "$SVC" || true
      echo "=== ${CF_SVC} ==="
      svc_ctl status "$CF_SVC" || true
      ;;
  restart)
      need_root
      svc_ctl restart "$SVC"
      sleep 1
      svc_ctl restart "$CF_SVC"
      echo "已重启 ${SVC} 和 ${CF_SVC}"
      ;;
  proto)
      need_root
      p="${2:-}"
      case "$p" in
          quic|http2) ;;
          *) echo "用法：xa proto quic|http2" >&2; exit 1 ;;
      esac
      load_env
      if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
          sed -i "s|--protocol [a-z0-9]*|--protocol ${p}|" "/etc/systemd/system/${CF_SVC}.service"
          systemctl daemon-reload
          systemctl restart "$CF_SVC"
      else
          sed -i "s|--protocol [a-z0-9]*|--protocol ${p}|" "/etc/init.d/${CF_SVC}"
          rc-service "$CF_SVC" restart
      fi
      echo "${c_g}cloudflared 协议已切换为 ${p}${c_0}"
      ;;
  update)
      need_root
      echo "更新 Xray-core 与 cloudflared..."
      ARCH="$(uname -m)"
      case "$ARCH" in
          x86_64|amd64)  XA="64";        CFA="amd64" ;;
          aarch64|arm64) XA="arm64-v8a"; CFA="arm64" ;;
          *) echo "不支持的架构：$ARCH" >&2; exit 1 ;;
      esac
      PROXY="${GH_PROXY:-}"
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      xurl="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XA}.zip"
      durl="${xurl}.dgst"
      if ! curl -fsSL --max-time 300 -o "$tmp/x.zip" "$xurl"; then
          [ -n "$PROXY" ] && curl -fsSL --max-time 300 -o "$tmp/x.zip" "${PROXY%/}/${xurl}" \
              || { echo "Xray 下载失败" >&2; exit 1; }
      fi
      curl -fsSL --max-time 60 -o "$tmp/x.dgst" "$durl" || { echo ".dgst 下载失败" >&2; exit 1; }

      want="$(grep -o 'SHA2-256=[[:space:]]*[0-9a-fA-F]*' "$tmp/x.dgst" | head -1 | sed 's/.*=[[:space:]]*//' | tr 'A-F' 'a-f')"
      have="$(sha256sum "$tmp/x.zip" | awk '{print $1}')"
      [ "$want" = "$have" ] || { echo "Xray 校验失败" >&2; exit 1; }

      svc_ctl stop "$SVC" || true
      svc_ctl stop "$CF_SVC" || true

      unzip -qo "$tmp/x.zip" -d "$APP_DIR"
      chmod +x "${APP_DIR}/xray"

      curl -fsSL --max-time 300 -o "${APP_DIR}/cloudflared" \
          "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CFA}" \
          || { echo "cloudflared 下载失败" >&2; exit 1; }
      chmod +x "${APP_DIR}/cloudflared"

      svc_ctl start "$SVC"
      sleep 2
      svc_ctl start "$CF_SVC"
      echo "${c_g}更新完成${c_0}"
      "${APP_DIR}/xray" version | head -1
      "${APP_DIR}/cloudflared" --version 2>/dev/null | head -1 || true
      ;;
  ""|-h|--help|help)
      cat <<'USAGE'
用法：xa <命令>

  links              重新显示节点链接与订阅
  status             查看两个服务状态
  restart            重启 xray 与 cloudflared
  proto quic|http2   切换 cloudflared 隧道协议并重启
  update             更新 Xray-core 与 cloudflared 到最新版
USAGE
      ;;
  *)
      echo "未知命令：$1（xa help 查看用法）" >&2
      exit 1
      ;;
esac
XAEOF
    chmod +x "$XA_PATH"
    ok "管理命令已安装：xa"
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_args "$@"

    log "=================================================="
    log " VLESS + XHTTP + Cloudflare Argo 隧道 部署脚本"
    log "=================================================="

    check_root
    detect_os
    detect_arch
    install_deps

    mkdir -p "$APP_DIR"
    chmod 700 "$APP_DIR"

    # 幂等：先停掉旧服务，避免端口占用与重复单元
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$CF_SVC_NAME" 2>/dev/null || true
        systemctl stop "$SVC_NAME" 2>/dev/null || true
    else
        rc-service "$CF_SVC_NAME" stop >/dev/null 2>&1 || true
        rc-service "$SVC_NAME" stop >/dev/null 2>&1 || true
    fi

    download_xray
    download_cloudflared

    # 生成或复用 UUID
    UUID="$(gen_uuid)"
    [ -n "$UUID" ] || die "UUID 生成失败"

    # XHTTP 路径：未指定则生成 24 位随机串，幂等复用旧值
    if [ -n "$ARG_PATH" ]; then
        XHTTP_PATH="/${ARG_PATH#/}"
    elif [ -f "$ENV_FILE" ]; then
        old="$(grep -E '^XHTTP_PATH=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
        XHTTP_PATH="${old:-/$(gen_token_str 24)}"
    else
        XHTTP_PATH="/$(gen_token_str 24)"
    fi
    XHTTP_PATH="${XHTTP_PATH#/}"; XHTTP_PATH="/${XHTTP_PATH}"

    # VMess WS 路径与端口
    VMESS_PORT="$((ARG_PORT + 1))"
    if [ -f "$ENV_FILE" ]; then
        old="$(grep -E '^WS_PATH=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
        WS_PATH="${old:-/$(gen_token_str 20)}"
    else
        WS_PATH="/$(gen_token_str 20)"
    fi

    ok "路径：XHTTP ${XHTTP_PATH}"
    [ "$ARG_VMESS" = "y" ] && ok "VMess 端口：${VMESS_PORT}"

    build_config "$XHTTP_PATH" "$WS_PATH" "$ARG_VMESS"
    test_config
    write_cloudflared_env

    if [ "$INIT_SYS" = "systemd" ]; then
        write_systemd
    else
        write_openrc
    fi

    start_services
    write_links

    # 保存安装参数供 xa 使用（600 权限，token 不落日志）
    umask 077
    cat > "$ENV_FILE" <<EOF
XRAY_UUID=${UUID}
XHTTP_PATH=${XHTTP_PATH}
WS_PATH=${WS_PATH}
VMESS_PORT=${VMESS_PORT}
DOMAIN=${ARG_DOMAIN}
CFIP=${ARG_CFIP}
PORT=${ARG_PORT}
PROTOCOL=${ARG_PROTOCOL}
VMESS=${ARG_VMESS}
EOF
    chmod 600 "$ENV_FILE"
    umask 022

    install_xa
    show_links

    ok "部署完成。VPS 未开放任何代理端口，全部流量经 Cloudflare Argo 隧道。"
    log "管理命令：xa links | xa status | xa restart | xa proto http2 | xa update"
}

main "$@"
