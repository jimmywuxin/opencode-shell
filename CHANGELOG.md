# CHANGELOG

## 未发布

**为分享做的可移植性改造**

- `src/launcher.sh`、`src/supervisor.sh`、`build.sh`：opencode CLI 不再写死 `~/.npm-global/bin/opencode`，改为 `OPENCODE_BIN` → `PATH` → `~/.npm-global/bin` → `~/.opencode/bin` → `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin` 依次探测（launchd 的 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，必须显式探测）；找不到时 supervisor 记日志退出，不再每 20s 刷 command not found
- `build.sh`：新增 `OPENCODE_APP_DIR`（默认 `~/Applications`），并在替换前 `mkdir -p`
- 新增 `LICENSE`（MIT）
- README 重写：体积对比（612 KB vs 官方 Electron 约 144 MB）、适用边界（诚实写明上游为何选 Electron）、安装步骤、环境变量、非官方声明

## v1.1.1 — 2026-10-19

**应用图标重绘**

- 参照 `opencode-desktop-icon.png` 重做图标：深炭色 squircle 底 + 银色金属框（竖向渐变、开口下沿高光倒角）+ 内嵌暗屏（黑→灰反射带→暖黑），比例与配色按参考图 240×240 逐点采样还原（框占 22.5%–76.7% × 15.8%–83.8%，屏占 36.2%–63.3% × 29.2%–70.0%）
- 新增 `tools/render_icon.swift`：图标源随代码进仓库，改尺寸/配色重跑一条命令即可，不再需要外部图形软件
- `assets/icon_1024.png` 更新；`build.sh` 仍按 10 档尺寸生成 `AppIcon.icns`

## v1.1.0 — 2026-10-19

窗口层从「exec Edge `--app`」换成原生 NSWindow + WKWebView，红叉改为隐藏窗口（飞书式）。服务层（launchd / supervisor）不动。

**新增**

- `src/ShellApp.swift`：原生壳。红叉 / `⌘W` = `orderOut` 隐藏窗口（Dock 不留缩略图、页面状态保留），点 Dock 图标或「窗口 → 显示主窗口」恢复；`⌘Q` 退出，`⌘M` 标准最小化，`⌘R` 重新连接；菜单（App/编辑/视图/窗口）；`<input type=file>` → `NSOpenPanel`；`window.open`/`target=_blank` → 同源本窗口、外链系统浏览器；主框架跳外站一律 `NSWorkspace`；下载 `WKDownloadDelegate` + `NSSavePanel`；媒体权限 `.deny`；`isInspectable`；`.default()` data store 持久化 cookie。
- `launcher.sh --url`：ensure 服务就绪后把目标 URL 打到 stdout（契约：stdout 只有一个 URL、失败非 0 且为空、诊断走 stderr）。

**变更**

- `src/launcher.sh`：删掉全部浏览器逻辑（`BROWSER` / `BROWSER_PROFILE` / `open_window` / `reap_zombie_browser` / `disable_browser_translate`），只保留「探活 → kickstart / bootstrap / nohup 三级兜底 → 等 30s」。`--ensure` 保留为无参默认行为。
- `build.sh`：`swiftc -O -parse-as-library` 编译原生壳；`launcher.sh` 从 `Contents/MacOS` 移到 `Contents/Resources`；先组装 `build/opencode.app.new` 再替换旧产物（失败不留空档）；全部资源就位后 ad-hoc 签名。
- `src/Info.plist`：加 `NSAppTransportSecurity`（`NSAllowsLocalNetworking` + `NSAllowsArbitraryLoads`），`LSMinimumSystemVersion` 11.0 → 12.0。
- 认证仍走 `opencode pair`，但改由壳执行 launcher 取 URL；`shell.log`（0600，`~/.local/share/opencode/log/`）只记长度/标题/cookie 名，URL 与 token 不落盘，另加 `/auth/connect/<token>` 兜底脱敏。

**验证**

- WebKit 探针：标题 `OpenCode`、600 个元素、无 JS 错误、`opencode_session_49374` cookie 已种下、`takeSnapshot` 截图正常。
- 启动：`ensure exit=0`、`url acquired (len=58)`、`page title: OpenCode`、进程存活、49374 有 ESTABLISHED、窗口 `CGWindowList` 归属本 app。
- 红叉自测：`after close: visible=false miniaturized=false` → `after reopen: visible=true` → `second close: visible=false`。

**已知行为**

- 服务端口固定 49374（opencode 托管服务默认值）。改端口需同步 `src/supervisor.sh` 的 `PORT`、`src/ShellApp.swift` 的 `baseURL` 与同源判定。
- `launchctl` 在 WorkBuddy/IDE 进程内不可用（error 5），`--reload` 必须在真终端执行。
- 不再需要 Microsoft Edge；旧 `~/.local/share/opencode/edge-profile`（约 550MB）稳定后可删。

## v1.0.0 — 2026-10-18

首个版本，把手工搭的三层结构收进仓库。

**新增**

- `build.sh`：图标生成（assets/icon_1024.png → AppIcon.icns）、.app 组装、supervisor 安装、launchd plist 渲染；版本号取 git tag，plist 内容未变不重写。
- `src/launcher.sh`：探测 `127.0.0.1:49374` → 取 `opencode pair` 一次性链接 → `exec` Edge `--app` 独立 profile；服务缺失时按 kickstart → bootstrap → nohup 三级兜底。
- `src/supervisor.sh`：launchd 前台常驻，20s 探活，`opencode service` 挂了重拉；收 TERM 时停服务。
- `src/ai.opencode.web.plist`：`ai.opencode.web`，RunAtLoad + KeepAlive，cwd 钉 HOME，Umask 077。
- `src/Info.plist`：bundle 元数据（版本/构建号由 build.sh 注入）。
- 图标：深炭色 squircle + 琥珀 `>_` 提示符，10 档尺寸 iconset。

**已知行为**

- 服务端口固定 49374（opencode 托管服务默认值）。改端口需同步 `src/supervisor.sh` 的 `PORT`。
- `launchctl` 在 WorkBuddy/IDE 进程内不可用（error 5），`--reload` 必须在真终端执行。
- Edge 独立 profile 与日常浏览数据完全隔离，登录态靠 launcher 每次生成的 pair 链接维持。
