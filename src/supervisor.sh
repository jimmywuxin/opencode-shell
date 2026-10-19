#!/bin/bash
# opencode 服务守护脚本（由 launchd 的 ai.opencode.web 调用，保持前台常驻）
#
# 为什么不让 launchd 直接跑 `opencode serve`：
#   v2 的 `opencode pair`（生成浏览器登录链接）只认「托管后台服务」，
#   会和独立 serve 进程抢端口报 "port already in use"（2026-10-18 实测）。
#   所以托管方必须是 `opencode service start/stop`。
#
# 为什么还需要这个脚本：
#   `service start` 起完就退出（daemonize），launchd 没法 KeepAlive 它。
#   本脚本 = 常驻前台 + 每 20 秒探一次端口，挂了就重新 start。
set -u

# 找 opencode 可执行文件：launchd 的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
# 必须按常见安装位置探；OPENCODE_BIN 可强制指定。
resolve_oc() {
  local c
  if [ -n "${OPENCODE_BIN:-}" ] && [ -x "${OPENCODE_BIN}" ]; then
    printf '%s' "$OPENCODE_BIN"; return 0
  fi
  for c in "$(command -v opencode 2>/dev/null)" \
           "$HOME/.npm-global/bin/opencode" \
           "$HOME/.opencode/bin/opencode" \
           "$HOME/.local/bin/opencode" \
           /opt/homebrew/bin/opencode \
           /usr/local/bin/opencode; do
    if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}
OC="$(resolve_oc || true)"
LOG_DIR="$HOME/.local/share/opencode/log"
PORT=49374
URL="http://127.0.0.1:${PORT}"
mkdir -p "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$1" >> "$LOG_DIR/supervisor.log"; }

# 找不到 CLI 就别进入循环（否则每 20s 刷一次 command not found）
if [ -z "$OC" ]; then
  log "未找到 opencode 命令（试过 PATH、~/.npm-global/bin、~/.opencode/bin、~/.local/bin、/opt/homebrew/bin、/usr/local/bin）"
  log "可用 OPENCODE_BIN=/path/to/opencode 指定，或在 launchd plist 里加该环境变量"
  exit 1
fi

cleanup() {
  log "收到退出信号，停止托管服务"
  "$OC" service stop >/dev/null 2>&1
  exit 0
}
trap cleanup TERM INT

alive() {
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" --noproxy '*' --max-time 3 "$URL/" 2>/dev/null)"
  [ "$code" = "200" ] || [ "$code" = "401" ]
}

if alive; then
  log "端口 $PORT 已有服务在跑，接管守护"
else
  log "启动托管服务"
  "$OC" service start >> "$LOG_DIR/supervisor.log" 2>&1
fi

while :; do
  sleep 20
  if ! alive; then
    log "服务无响应，重新拉起"
    "$OC" service stop >/dev/null 2>&1
    sleep 1
    "$OC" service start >> "$LOG_DIR/supervisor.log" 2>&1
  fi
done
