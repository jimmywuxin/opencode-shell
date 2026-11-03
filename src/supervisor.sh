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

# 端口、日志目录、CLI 探测、就绪判据全部来自同目录 common.sh（单一来源）。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SELF_DIR/common.sh" || { echo "[supervisor] 缺 common.sh（$SELF_DIR），无法探活" >&2; exit 1; }

OC="$(resolve_oc || true)"
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

# 判据本体在 common.sh 的 oc_ready()，与 launcher 共用一份 —— 分叉过一次，
# 只认 200/401 时服务一进 302 就被自己人每 20s 重启（2026-11-03 清单 P0-1）。
alive() { oc_ready; }

# 二进制指纹 = 目标文件 mtime + size。
# 用途：npm 升级只替换磁盘文件，长驻的 `serve --service` 进程仍跑旧二进制、
# 前端资源也还是旧的 → app 里永远看到旧版（2026-10-26 实踩）。
# -L 必须加：~/.npm-global/bin/opencode 是软链，不跟随就永远读到软链自身的 mtime。
fp() {
  stat -L -f '%m-%z' "$OC" 2>/dev/null || printf 'unknown'
}

# 升级后停止服务 → supervisor 自己继续活着，只换被托管的 daemon。
# stop 后等 2s 让端口释放，避免 start 撞 "port already in use"。
restart_service() { # $1 = 触发原因（写日志用）
  log "$1，重启托管服务"
  "$OC" service stop >/dev/null 2>&1
  sleep 2
  "$OC" service start >> "$LOG_DIR/supervisor.log" 2>&1
}

if alive; then
  log "端口 $PORT 已有服务在跑，接管守护"
  # 接管的进程可能是旧二进制起的（supervisor 中断期间发生过升级、或别人手动起的）。
  # 必须在这里校验：下面 OC_FP 记的是磁盘当前指纹，若接管的是旧进程，
  # 之后「磁盘指纹 vs OC_FP」永远相等 → 永不换血（2026-11-04 实踩）。
  oc_service_fresh
  case $? in
    1) restart_service "接管的进程是旧二进制（$(oc_running_fp) ≠ $(oc_disk_fp)）" ;;
    2) log "接管进程版本无法判断，按现状守护" ;;
  esac
else
  log "启动托管服务"
  "$OC" service start >> "$LOG_DIR/supervisor.log" 2>&1
fi

OC_FP="$(fp)"

while :; do
  sleep 20

  # 先查换血，再查存活：升级后端口通常仍通，只查 alive 发现不了
  NEW_FP="$(fp)"
  if [ "$NEW_FP" != "$OC_FP" ] && [ "$NEW_FP" != "unknown" ] && [ "$OC_FP" != "unknown" ]; then
    log "检测到 opencode 二进制已更新（$OC_FP → $NEW_FP），需要重启服务加载新版本"
    restart_service "二进制变更"
    OC_FP="$NEW_FP"
    continue
  fi

  if ! alive; then
    restart_service "服务无响应"
  fi
done
