#!/bin/bash
# opencode.app 启动入口（仿 dsh.app 形态）
# 职责：确保 opencode v2 服务在跑 → 等就绪 → 开 Edge --app 独立窗口
#
# 服务由 launchd 托管（~/Library/LaunchAgents/ai.opencode.web.plist，
# RunAtLoad+KeepAlive）。登录时 launchd 自动拉起；本脚本不自己 nohup，
# 避免与 launchd 抢同一个端口产生双实例。
#
# 就绪判据：HTTP 状态码 200/401 都算（loopback 裸访问实测 200，不需要密码）。
set -u

PORT=49374
URL="http://127.0.0.1:${PORT}"
LABEL="ai.opencode.web"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/ai.opencode.web.plist"
OC="$HOME/.npm-global/bin/opencode"
LOG_DIR="$HOME/.local/share/opencode/log"
BROWSER="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
BROWSER_PROFILE="$HOME/.local/share/opencode/edge-profile"

notify() { osascript -e "display notification \"$1\" with title \"OpenCode\"" >/dev/null 2>&1; }

if [ ! -x "$BROWSER" ]; then
  notify "未找到 Microsoft Edge，无法打开窗口"
  exit 1
fi

probe_code() {
  curl -s -o /dev/null -w "%{http_code}" --noproxy '*' --max-time 2 "$URL/" 2>/dev/null
}

# 清掉上次的 opencode 浏览器实例：exec 后进程被浏览器顶替，不清残留
# 会导致「再点一次 app 不重跑 launcher、只 activate 旧进程」。
reap_zombie_browser() {
  pgrep -f "user-data-dir=$BROWSER_PROFILE" >/dev/null 2>&1 || return 0
  pkill -f "user-data-dir=$BROWSER_PROFILE" 2>/dev/null
  local i
  for i in $(seq 1 10); do
    pgrep -f "user-data-dir=$BROWSER_PROFILE" >/dev/null 2>&1 || return 0
    sleep 0.3
  done
  return 0
}

# 关掉「是否翻译此页面」气泡：独立 profile 每次新建都「从未翻译过」，
# UI 是英文 + 本机 zh-CN → 每次开窗都弹（dsh 同款问题，同一套解法）。
# 坑：translate 块不存在时 plutil -replace 会报 Key path not found 并短路，
# 必须先判块在不在，不在就 -insert 建出来。
disable_browser_translate() {
  local prefs="$BROWSER_PROFILE/Default/Preferences" want='{"enabled":false,"blocked_languages":["en"]}'
  [ -f "$prefs" ] || return 0
  cp "$prefs" "$prefs.oc-bak" 2>/dev/null
  if grep -q '"translate"' "$prefs" 2>/dev/null; then
    plutil -replace translate.enabled -bool NO "$prefs" \
      && plutil -replace translate.blocked_languages -json '["en"]' "$prefs"
  else
    plutil -insert translate -json "$want" "$prefs"
  fi || cp "$prefs.oc-bak" "$prefs" 2>/dev/null
  return 0
}

open_window() {
  mkdir -p "$BROWSER_PROFILE"
  reap_zombie_browser
  disable_browser_translate
  # exec：让浏览器顶替本进程（ppid 变 LaunchServices），否则 --app 窗口不开
  # --no-first-run / --no-default-browser-check：独立 profile 首次启动会弹
  # 「欢迎使用 Edge / 设为默认浏览器」向导，盖住应用窗口（2026-10-18 实测踩到）
  exec "$BROWSER" \
    --user-data-dir="$BROWSER_PROFILE" \
    --no-first-run \
    --no-default-browser-check \
    --disable-features=msEdgeFirstRunExperience \
    --app="$1"
}

# 取一次性配对链接：Web UI 未登录时会停在 pairing 页（curl 仍是 200，
# 所以不能靠状态码判断登录态）。opencode pair 会打印
# http://127.0.0.1:PORT/auth/connect/<token>，浏览器打开即种下 30 天会话 cookie。
pair_url() {
  local u
  [ -x "$OC" ] || return 1
  u="$("$OC" pair 2>/dev/null | grep -o "http://127\.0\.0\.1:[0-9]*/auth/connect/[A-Za-z0-9_-]*" | head -1)"
  [ -n "$u" ] || return 1
  printf '%s' "$u"
}

ready_or_open() {
  local code target
  code="$(probe_code)"
  case "$code" in
    200|204|302|401)
      target="$(pair_url || printf '%s' "$URL")"
      open_window "$target"
      ;;
    *) return 1 ;;
  esac
}

# 1) 服务已在跑 → 直接开窗
ready_or_open && exit 0

# 2) 没跑 → 交给 launchd 拉起（已装载则 kickstart，未装载则从 plist bootstrap）
STARTED=""
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 && STARTED=kickstart
fi
if [ -z "$STARTED" ] && [ -f "$PLIST" ]; then
  launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 && STARTED=bootstrap
fi

if [ -z "$STARTED" ]; then
  # 兜底：launchd 两条路都不通 → 自己起一个（此时 launchd 未托管，不冲突）
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    notify "服务在 launchd 托管下但无法重启，请先 launchctl bootout 再点本图标"
    exit 1
  fi
  if [ ! -x "$OC" ]; then
    notify "未找到 opencode（$OC）"
    exit 1
  fi
  mkdir -p "$LOG_DIR"
  nohup "$OC" serve --port "$PORT" --hostname 127.0.0.1 \
    >> "$LOG_DIR/web.log" 2>> "$LOG_DIR/web.err.log" &
  STARTED=manual
fi

# 3) 等就绪，最多 30s
for _i in $(seq 1 60); do
  ready_or_open && exit 0
  sleep 0.5
done

notify "opencode 服务 30 秒未就绪（${STARTED}），请看 $LOG_DIR/web.err.log"
exit 1
