#!/bin/bash
# opencode-shell 构建脚本
#   1) 图标：assets/icon_1024.png → build/AppIcon.icns（临时 iconset 用 trap 清理）
#   2) 组装 .app → ~/Applications/opencode.app（launcher + 图标 + Info.plist）
#   3) 安装 supervisor.sh → ~/.local/share/opencode/supervisor.sh
#   4) 渲染 launchd 模板 → ~/Library/LaunchAgents/ai.opencode.web.plist（内容有变才写）
#
# 用法：bash build.sh [--reload]
#   --reload  重载 launchd 服务（bootout + bootstrap）。
#             ⚠️ 只在**真终端**里有效：从 WorkBuddy/IDE 等受限进程调用 launchctl
#             一律 error 5（2026-10-18 实测，连空壳 plist 也失败）。
set -euo pipefail
cd "$(dirname "$0")"

RELOAD=0
for arg in "$@"; do
  [ "$arg" = "--reload" ] && RELOAD=1
done

APP="$HOME/Applications/opencode.app"
PLIST_DST="$HOME/Library/LaunchAgents/ai.opencode.web.plist"
STATE_DIR="$HOME/.local/share/opencode"
LOG_DIR="$STATE_DIR/log"
BACKUP_DIR="$STATE_DIR/backups"
BUILD_DIR="$PWD/build"
DOMAIN="gui/$(id -u)"
LABEL="ai.opencode.web"

OC="$(command -v opencode || echo "$HOME/.npm-global/bin/opencode")"

# 版本号从 git tag 取，缺 tag（浅克隆/非仓库）退到 0.0.0，不让构建失败
APP_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$APP_VERSION" ] || APP_VERSION="0.0.0"
APP_BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
[ -n "$APP_BUILD" ] || APP_BUILD=0

# ── 0) 前置检查（失败即停，不先拆旧产物）─────────────────────────
if [ ! -x "$OC" ]; then
  echo "错误：未找到 opencode（$OC）。先装：npm i -g @opencode/cli" >&2
  exit 1
fi
if [ ! -f src/launcher.sh ] || [ ! -f src/supervisor.sh ] || [ ! -f src/ai.opencode.web.plist ]; then
  echo "错误：src/ 缺文件（launcher.sh / supervisor.sh / ai.opencode.web.plist）" >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$BUILD_DIR"

# ── 1) 图标 ────────────────────────────────────────────────────
# 用系统自带 sips 缩放，不依赖 Pillow（源图已是 1024，只需出各档尺寸）
# ⚠️ iconutil 要求目录名以 .iconset 结尾，否则报 "Invalid Iconset"（2026-10-18 实踩）
TMPD="$(mktemp -d)"
ICONSET="$TMPD/AppIcon.iconset"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$ICONSET"
gen() { # $1=输出名 $2=像素
  sips -z "$2" "$2" assets/icon_1024.png --out "$ICONSET/$1" >/dev/null 2>&1
}
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
gen icon_512x512@2x.png 1024
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

# ── 2) 组装 .app ───────────────────────────────────────────────
# 旧产物移废纸篓而不是 rm（生成的 bundle，重建无损失，但仍按规矩可恢复）
if [ -e "$APP" ]; then
  mkdir -p "$HOME/.Trash"
  mv "$APP" "$HOME/.Trash/opencode.app.bak-$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 src/launcher.sh "$APP/Contents/MacOS/opencode"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/@VERSION@/$APP_VERSION/g" -e "s/@BUILD@/$APP_BUILD/g" \
  src/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
touch "$APP"

# ── 3) supervisor.sh ──────────────────────────────────────────
# 用 cp 覆盖而不是 mv：正在运行的旧 supervisor 进程是 exec 自旧 inode 的副本，
# 覆盖文件不会打断它；mv 会让正在跑的那个路径消失（活文件只 cp 的规矩）。
install -m 755 src/supervisor.sh "$STATE_DIR/supervisor.sh"

# ── 4) launchd plist（内容有变才写，避免无谓重载）──────────────
NEW_PLIST="$BUILD_DIR/ai.opencode.web.plist"
sed "s|@HOME@|$HOME|g" src/ai.opencode.web.plist > "$NEW_PLIST"
plutil -lint "$NEW_PLIST" >/dev/null
PLIST_CHANGED=0
if [ -f "$PLIST_DST" ]; then
  if ! cmp -s "$NEW_PLIST" "$PLIST_DST"; then
    cp "$PLIST_DST" "$BACKUP_DIR/ai.opencode.web.plist.$(date +%Y%m%d%H%M%S)"
    install -m 644 "$NEW_PLIST" "$PLIST_DST"
    PLIST_CHANGED=1
  fi
else
  install -m 644 "$NEW_PLIST" "$PLIST_DST"
  PLIST_CHANGED=1
fi

# ── 5) 结果 ───────────────────────────────────────────────────
echo "app:      $APP ($APP_VERSION build $APP_BUILD)"
echo "plist:    $PLIST_DST $([ "$PLIST_CHANGED" = 1 ] && echo '(已更新)' || echo '(未变)')"
echo "supervisor: $STATE_DIR/supervisor.sh"

if [ "$RELOAD" = 1 ]; then
  echo "重载服务…"
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "$DOMAIN" "$PLIST_DST"
  echo "已重载：launchctl print $DOMAIN/$LABEL"
elif [ "$PLIST_CHANGED" = 1 ] && launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  cat <<EOF

⚠️  plist 有变更但服务仍在按旧配置跑。真终端里执行：
    launchctl bootout $DOMAIN/$LABEL && launchctl bootstrap $DOMAIN "$PLIST_DST"
  或者直接双击 ${APP}（launcher 会在服务不可用时 bootstrap）。
EOF
fi
