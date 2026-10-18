# CHANGELOG

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
