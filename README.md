# opencode-shell

把 [opencode](https://opencode.ai) 2.x 的 Web 服务做成 macOS 原生形态：**开机自启的后台服务 + 双击图标进独立全屏窗口**，形态对齐本机 `dsh-shell`。

## 它解决什么

opencode 2.0 的 Web UI 只有 `opencode serve` / `opencode service`，用起来有两个不便：

1. 每次都要开终端起服务，关终端就断；
2. 浏览器要手动敲地址、手动配对登录，还混在日常浏览器窗口里。

本项目补两层壳：

| 层 | 实现 |
|---|---|
| 服务层 | launchd `ai.opencode.web` → `supervisor.sh` → `opencode service start`（20s 探活，挂了重拉） |
| 窗口层 | `opencode.app` → 自动取 `opencode pair` 一次性链接 → `exec` Edge `--app` 独立 profile |

地址固定 `http://127.0.0.1:49374`，登录态由 launcher 每次自动带入，无需手输密码。

## 构建

```bash
bash build.sh            # 组装 app + 装 supervisor + 渲染 plist
bash build.sh --reload   # 同上，并重载 launchd（须在真终端；WorkBuddy 内跑 launchctl 必失败）
```

产物：

| 路径 | 内容 |
|---|---|
| `~/Applications/opencode.app` | 应用本体（launcher + AppIcon.icns） |
| `~/.local/share/opencode/supervisor.sh` | 服务守护脚本 |
| `~/Library/LaunchAgents/ai.opencode.web.plist` | 开机自启配置 |
| `~/.local/share/opencode/log/` | supervisor / opencode / launchd 日志 |

依赖：`opencode` CLI（`npm i -g @opencode/cli`）、Microsoft Edge、系统自带 `sips` + `iconutil`（构建图标用）。

## 日常操作

```bash
launchctl print gui/$(id -u)/ai.opencode.web   # 服务状态
launchctl bootout gui/$(id -u)/ai.opencode.web # 停服务（pkill 会被 KeepAlive 复活）
opencode service status                        # opencode 视角的状态
```

双击 `opencode.app` 即可：服务没跑会先拉起，再开窗口。

## 关键取舍与踩坑（都实测过）

- **不让 launchd 直接跑 `opencode serve`**：`opencode pair` 只认「托管服务」，独立 `serve` 会占端口，导致 pair 报 `Managed service port ... already in use`。
- **`service start` 会 daemonize 后退出**，launchd 的 KeepAlive 抓不住它 → 需要 `supervisor.sh` 常驻前台做探活。
- **Web UI 未登录时 HTTP 仍是 200**，不能靠状态码判断登录态；pair 链接还要求 `Accept: text/html` 才返回 302 + `Set-Cookie`。
- **`--app` 窗口必须 `exec`**（ppid 要是 LaunchServices）。用 `nohup ... &` 起的浏览器进程不会开窗，与 dsh-shell 的结论一致。
- **Edge 独立 profile 的副作用**：首次弹「欢迎使用 Edge」向导、每次弹翻译气泡 → 需 `--no-first-run --no-default-browser-check --disable-features=msEdgeFirstRunExperience`，并往 profile 的 `Preferences` 写 `translate.*`（块不存在时要 `-insert`，`-replace` 会 Key path not found）。
- **launchctl 权限边界**：WorkBuddy/IDE 这类进程调用 `launchctl bootstrap/bootout` 一律 `error 5: Input/output error`（连空壳 plist 也复现）；`osascript do shell script` 同样不行；**只有经 LaunchServices 启动的 .app 可以**。所以 launcher 自带 bootstrap 兜底，`build.sh --reload` 必须人工在终端跑。
- **端口 49374**：opencode 在 macOS 的托管服务默认端口，改端口要同步 `src/supervisor.sh` 的 `PORT` 与 plist（launcher 从 pair 输出里取 URL，不写死）。

## 卸载

```bash
launchctl bootout gui/$(id -u)/ai.opencode.web
rm -f ~/Library/LaunchAgents/ai.opencode.web.plist
mv ~/Applications/opencode.app ~/.Trash/
```

数据与配置（`~/.config/opencode/`、`~/.local/share/opencode/`）不随卸载删除。
