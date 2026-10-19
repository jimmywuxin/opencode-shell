# opencode-shell

把 [opencode](https://opencode.ai) 2.x 的 Web 服务做成 macOS 原生形态：**开机自启的后台服务 + 双击图标进独立窗口**，形态对齐本机 `dsh-shell`。

## 它解决什么

opencode 2.0 的 Web UI 只有 `opencode serve` / `opencode service`，用起来有两个不便：

1. 每次都要开终端起服务，关终端就断；
2. 浏览器要手动敲地址、手动配对登录，还混在日常浏览器窗口里。

本项目补两层壳：

| 层 | 实现 |
|---|---|
| 服务层 | launchd `ai.opencode.web` → `supervisor.sh` → `opencode service start`（20s 探活，挂了重拉） |
| 窗口层 | `opencode.app`（原生 NSWindow + WKWebView）→ 调 `launcher.sh --url` 等服务就绪并取 `opencode pair` 一次性链接 → WKWebView 加载 |

地址固定 `http://127.0.0.1:49374`，登录态由 launcher 每次自动带入，无需手输密码。**不再依赖任何浏览器**（2026-10-19 起）。

## 窗口行为（飞书式单窗口）

| 操作 | 行为 |
|---|---|
| 红叉 / `⌘W` | 隐藏窗口：窗口消失、**Dock 里不留缩略图**、应用继续运行、页面状态不丢 |
| 点 Dock 图标 | 窗口恢复 |
| 黄点 / `⌘M` | 标准最小化（Dock 右侧缩略图）——与红叉区分 |
| `⌘Q` | 真正退出 |
| `⌘R` | 重新连接（重新 ensure 服务 + 重新取 pair URL + 重新加载） |
| `⌘+` / `⌘-` / `⌘0` | 缩放 / 重置 |
| 窗口 → 显示主窗口 | 隐藏后的兜底入口（万一 reopen 没触发） |

## 构建

```bash
bash build.sh            # 编译原生壳 + 组装 app + 装 supervisor + 渲染 plist
bash build.sh --reload   # 同上，并重载 launchd（须在真终端；WorkBuddy 内跑 launchctl 必失败）
```

产物：

| 路径 | 内容 |
|---|---|
| `~/Applications/opencode.app` | 应用本体（Swift 二进制 + `Contents/Resources/launcher.sh` + AppIcon.icns） |
| `~/.local/share/opencode/supervisor.sh` | 服务守护脚本 |
| `~/Library/LaunchAgents/ai.opencode.web.plist` | 开机自启配置 |
| `~/.local/share/opencode/log/` | supervisor / opencode / shell 日志 |

依赖：`opencode` CLI（`npm i -g @opencode/cli`）、macOS 12+、Command Line Tools（`swiftc`）、系统自带 `sips` + `iconutil`（构建图标用）。**不需要 Edge。**

`build.sh` 先组装 `build/opencode.app.new`，全部成功后才把旧产物移进废纸篓换新，中途失败不会留下空壳。

## 日常操作

```bash
launchctl print gui/$(id -u)/ai.opencode.web   # 服务状态
launchctl bootout gui/$(id -u)/ai.opencode.web # 停服务（pkill 会被 KeepAlive 复活）
opencode service status                        # opencode 视角的状态
tail -20 ~/.local/share/opencode/log/shell.log # 壳的日志（不含 URL/token）
```

双击 `opencode.app` 即可：服务没跑会先拉起，再开窗口。

## 关键取舍与踩坑（都实测过）

- **换掉 Edge `--app` 的唯一原因**：窗口按钮归 Chromium 进程，红叉只能是「关闭窗口」，没有命令行开关能改；只有自家 `NSWindow` 能定义 `windowShouldClose`。
- **红叉必须 `orderOut` + `windowShouldClose` 返回 `false`**：`performMiniaturize` 会留 Dock 缩略图（那是黄点），`NSApp.hide` 会把菜单栏一起藏掉，`close()` 会丢窗口状态。
- **`window.delegate = self` 忘了设 = 红叉拦不住**；`applicationShouldTerminateAfterLastWindowClosed` 必须 `false`。
- **认证走 `opencode pair`，不抄 dsh 的 cookie 铸造**：pair 链接里的 token 就是登录凭据，WKWebView 加载后服务端 `302 + Set-Cookie` 种下 30 天会话 cookie；cookie 存 `.default()` data store 才能跨启动保留。
- **pair token 是凭据**：`shell.log`（0600）只记 `ensure exit=`、URL 长度、页面标题、cookie 名；不记 URL 全文、不记 cookie 值。`redactSecrets()` 还会把任何 `/auth/connect/<token>` 兜底抹成 `<redacted>`。
- **pair 链接只加载一次**：失败就重新取，不重放旧 URL。
- **ATS 必须放行** `http://127.0.0.1`（`NSAllowsLocalNetworking`），否则 WKWebView 直接 `NSURLError`。
- **WKWebView 不自动给浏览器能力**：`<input type=file>` 要 `runOpenPanelWith`（否则附件按钮静默无反应）、`target=_blank`/`window.open` 要 `createWebViewWith`、外部链接要在 `decidePolicyFor` 拦下交 `NSWorkspace`、下载要 `WKDownloadDelegate` + `NSSavePanel`。
- **签名顺序**：二进制、launcher、Info.plist、图标全部就位后才 `codesign --force --sign -`。
- **不让 launchd 直接跑 `opencode serve`**：`opencode pair` 只认「托管服务」，独立 `serve` 会占端口，导致 pair 报 `Managed service port ... already in use`。
- **`service start` 会 daemonize 后退出**，launchd 的 KeepAlive 抓不住它 → 需要 `supervisor.sh` 常驻前台做探活。
- **Web UI 未登录时 HTTP 仍是 200**，不能靠状态码判断登录态。
- **launchctl 权限边界**：WorkBuddy/IDE 这类进程调用 `launchctl bootstrap/bootout` 一律 `error 5: Input/output error`（连空壳 plist 也复现）；**只有经 LaunchServices 启动的 .app 可以**。所以 ensure 必须由壳调用，`build.sh --reload` 必须人工在终端跑。
- **端口 49374**：opencode 在 macOS 的托管服务默认端口，改端口要同步 `src/supervisor.sh`、`src/ShellApp.swift`（`baseURL`、同源判定）与 plist。

## 迁移遗留

`~/.local/share/opencode/edge-profile`（约 550MB）是旧 Edge 壳的独立 profile，新壳不再使用。确认新壳稳定后可删：

```bash
mv ~/.local/share/opencode/edge-profile ~/.Trash/
```

## 卸载

```bash
launchctl bootout gui/$(id -u)/ai.opencode.web
rm -f ~/Library/LaunchAgents/ai.opencode.web.plist
mv ~/Applications/opencode.app ~/.Trash/
```

数据与配置（`~/.config/opencode/`、`~/.local/share/opencode/`）不随卸载删除。
