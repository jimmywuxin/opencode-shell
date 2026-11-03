#!/bin/bash
# launcher.sh / supervisor.sh 共用的常量与判据（被 source，不单独执行）。
#
# 为什么要有这个文件：
#   1) 就绪判据分叉过一次 —— supervisor 只认 200/401，launcher 认 200/204/302/401，
#      服务一进入 302 就被自己人每 20s 重启一次（2026-11-03 清单 P0-1）；
#   2) resolve_oc 在两个脚本里重复了 60 行；
#   3) 端口原来写死在三处（launcher / supervisor / Swift 的 baseURL），
#      换端口漏一处就是「壳连不上、服务好好跑着」（清单 P2-2）。
#
# 端口现在只有这里一个来源：build.sh 读它渲染 Info.plist 的 OpencodeServiceURL，
# 壳从 bundle 读；两个脚本直接 source 本文件。
#
# 约定：调用方先 `set -u`，再 source。
#
# 服务由 launchd 托管（~/Library/LaunchAgents/ai.opencode.web.plist，
# RunAtLoad+KeepAlive）。调用方不自己 nohup 起服务，避免与 launchd 抢端口。

PORT=49374
URL="http://127.0.0.1:${PORT}"
LABEL="ai.opencode.web"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/.local/share/opencode/log"

# 就绪判据（唯一来源）：200/204/302/401 都算。
# loopback 裸访问实测 200，未登录时也仍是 200 → 不能用状态码判断登录态；
# 302 是内部重定向到 pairing 页，同样属于「服务活着」。
oc_ready() {
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" --noproxy '*' --max-time 3 "$URL/" 2>/dev/null)"
  case "$code" in 200|204|302|401) return 0 ;; esac
  return 1
}

# 找 opencode 可执行文件。launchd/LaunchServices 给的 PATH 极简（/usr/bin:/bin:...），
# 所以不能只靠 command -v；按常见安装位置依次探测，OPENCODE_BIN 可强制指定。
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
