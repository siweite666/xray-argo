#!/usr/bin/env bash
#
# uninstall.sh - 卸载 Xray + Argo 隧道部署
# 只删除本脚本安装的内容，不动系统其他部分
#
set -euo pipefail

readonly APP_DIR="/etc/xray-argo"
readonly SVC_NAME="xray-argo"
readonly CF_SVC_NAME="cloudflared-argo"
readonly XA_PATH="/usr/local/bin/xa"

if [ -t 1 ]; then
    C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;91m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请以 root 身份运行"; exit 1; }

echo "开始卸载 Xray + Argo 隧道部署..."

# ---------- systemd ----------
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    for s in "$CF_SVC_NAME" "$SVC_NAME"; do
        systemctl stop "$s" 2>/dev/null || true
        systemctl disable "$s" 2>/dev/null || true
    done
    rm -f "/etc/systemd/system/${SVC_NAME}.service"
    rm -f "/etc/systemd/system/${CF_SVC_NAME}.service"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed 2>/dev/null || true
# ---------- OpenRC ----------
elif command -v rc-service >/dev/null 2>&1; then
    for s in "$CF_SVC_NAME" "$SVC_NAME"; do
        rc-service "$s" stop >/dev/null 2>&1 || true
        rc-update del "$s" default >/dev/null 2>&1 || true
    done
    rm -f "/etc/init.d/${SVC_NAME}"
    rm -f "/etc/init.d/${CF_SVC_NAME}"
else
    warn "未检测到 systemd / OpenRC，跳过服务清理"
fi

# ---------- 残留进程（按可执行文件路径精确匹配，避免误杀同名进程）----------
pkill -f "${APP_DIR}/xray" 2>/dev/null || true
pkill -f "${APP_DIR}/cloudflared" 2>/dev/null || true

# ---------- 文件 ----------
rm -rf "$APP_DIR"
rm -f "$XA_PATH"

# ---------- 验证 ----------
leftover=0
[ -e "$APP_DIR" ] && { err "残留：${APP_DIR}"; leftover=1; }
[ -e "$XA_PATH" ] && { err "残留：${XA_PATH}"; leftover=1; }

if [ "$leftover" -eq 0 ]; then
    ok "卸载完成。已删除："
    echo "  - 服务 ${SVC_NAME} / ${CF_SVC_NAME}"
    echo "  - 目录 ${APP_DIR}"
    echo "  - 命令 ${XA_PATH}"
    echo "未改动系统其他内容。"
else
    err "部分内容未能删除，请手动检查上面列出的路径"
    exit 1
fi
