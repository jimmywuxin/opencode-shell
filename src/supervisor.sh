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

OC="$HOME/.npm-global/bin/opencode"
LOG_DIR="$HOME/.local/share/opencode/log"
PORT=49374
URL="http://127.0.0.1:${PORT}"
mkdir -p "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$1" >> "$LOG_DIR/supervisor.log"; }

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
