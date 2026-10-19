#!/bin/bash
# opencode.app 启动检查（2026-10-19 起由原生壳 src/ShellApp.swift 调用）
#
# 职责只有一件：确保 opencode 托管服务就绪，并把要加载的 URL 打印到 stdout。
# 窗口、红叉、菜单全部归原生壳，本脚本不再碰任何浏览器。
#
# 用法：
#   launcher.sh --url    ensure 服务就绪 → stdout 打印**一个**目标 URL
#   launcher.sh          同上但不打印 URL（只 ensure，退出码表示成败）
#
# 契约（原生壳按这个解析）：
#   - --url 的 stdout **只允许出现一个 URL**，不得有 echo/进度/通知；
#   - 失败时 exit 非 0 且 stdout 为空；
#   - 诊断信息一律走 stderr（含 token 的 URL 绝不写 stderr）。
#
# 就绪判据：HTTP 状态码 200/204/302/401 都算（loopback 裸访问实测 200，
# 未登录时也仍是 200 → 不能用状态码判断登录态）。
#
# 服务由 launchd 托管（~/Library/LaunchAgents/ai.opencode.web.plist，
# RunAtLoad+KeepAlive）。本脚本不自己 nohup 起服务，避免与 launchd 抢端口。
set -u

PORT=49374
URL="http://127.0.0.1:${PORT}"
LABEL="ai.opencode.web"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OC="$HOME/.npm-global/bin/opencode"
LOG_DIR="$HOME/.local/share/opencode/log"

# 诊断日志：只写 stderr，壳会原样落到 shell.log（不含 URL/token）。
log() { printf '[launcher] %s\n' "$1" >&2; }

probe_code() {
  curl -s -o /dev/null -w "%{http_code}" --noproxy '*' --max-time 2 "$URL/" 2>/dev/null
}

ready() {
  case "$(probe_code)" in 200|204|302|401) return 0 ;; esac
  return 1
}

# 取一次性配对链接：Web UI 未登录时会停在 pairing 页（curl 仍是 200）。
# `opencode pair` 打印 http://127.0.0.1:PORT/auth/connect/<token>，
# 浏览器/WebView 打开后服务端 302 + Set-Cookie，种下 30 天会话 cookie。
# ⚠️ 输出里带 token，调用方不得记录。
pair_url() {
  local u
  [ -x "$OC" ] || return 1
  u="$("$OC" pair 2>/dev/null | grep -o "http://127\.0\.0\.1:[0-9]*/auth/connect/[A-Za-z0-9_-]*" | head -1)"
  [ -n "$u" ] || return 1
  printf '%s' "$u"
}

# 服务没响应 → 按 kickstart → bootstrap → 手工 nohup 三级兜底拉起。
# ⚠️ 本函数必须由 .app（经 LaunchServices 启动）调用：终端/IDE 进程调用
# launchctl bootstrap 会报 5: Input/output error（2026-10-18 实测）。
start_service() {
  [ -x "$OC" ] || { log "未找到 opencode（$OC）"; return 1; }

  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 && { log "kickstart 已发出"; return 0; }
  fi
  if [ -f "$PLIST" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 && { log "bootstrap 已发出"; return 0; }
  fi

  # 兜底：launchd 两条路都不通 → 自己起一个（此时 launchd 未托管，不冲突）
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    log "服务在 launchd 托管下但无法重启，请先 launchctl bootout 再重试"
    return 1
  fi
  mkdir -p "$LOG_DIR"
  nohup "$OC" serve --port "$PORT" --hostname 127.0.0.1 \
    >> "$LOG_DIR/web.log" 2>> "$LOG_DIR/web.err.log" &
  log "已手工拉起 serve（$!）"
  return 0
}

# 服务就绪：已在跑直接返回；否则拉起后最多等 30s。
ensure_ready() {
  ready && return 0
  start_service || return 1
  local i
  for i in $(seq 1 60); do
    ready && return 0
    sleep 0.5
  done
  log "服务 30 秒未就绪，请看 $LOG_DIR/web.err.log"
  return 1
}

case "${1:-}" in
  --url)
    ensure_ready || exit 1
    # pair_url 优先；取不到才回落到裸 URL（此时页面停在 pairing 页）
    pair_url || printf '%s' "$URL"
    exit 0
    ;;
  --ensure|"")
    ensure_ready || exit 1
    log "服务就绪：$URL"
    exit 0
    ;;
  *)
    log "未知参数：$1（用法：launcher.sh [--url|--ensure]）"
    exit 2
    ;;
esac
