import Cocoa
import WebKit

// opencode-shell 的原生壳（2026-10-19 取代 Edge --app 窗口）。
//
// 为什么换成原生壳：Edge `--app` 窗口的红叉由 Chromium 写死为「关闭窗口」，
// 关掉最后一个窗口浏览器即退出，没有任何开关能改。只有自家 NSWindow
// 才能定义 windowShouldClose 的行为。
//
// 壳只做三件事：
//   1) 调 bundle 里的 launcher.sh --url 把 launchd 服务等到就绪，并拿到目标 URL；
//   2) 用 WKWebView 加载该 URL（opencode pair 链接会 302 + Set-Cookie，
//      种下 30 天会话 cookie；cookie 存 .default() 所以能跨启动保留）；
//   3) 红叉 / ⌘W = 隐藏窗口（飞书式：Dock 只留应用图标、不留窗口缩略图），
//      点 Dock 图标或「窗口 → 显示主窗口」恢复。
//
// 认证不要照抄 dsh：opencode 没有 HMAC 铸 cookie 那套，走 `opencode pair` 的
// 一次性链接即可。pair token 等同登录凭据 → 日志不记 URL 全文、不记 cookie 值。
//
// 日志：~/.local/share/opencode/log/shell.log（0600）

private let baseURL = URL(string: "http://127.0.0.1:49374/")!
private let windowFrameName = "opencodeMainWindow"

// 窗口稳定状态下的样式掩码。WKWebView 进元素全屏后可能给窗口加上
// .fullSizeContentView 之类的位且退出时不还原，标题栏会变成浮在内容上的
// 一层、交通灯位置随之错乱 —— 所以退出全屏后要按这个基准复位。
private let baseStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

// MARK: - 日志（脱敏）

private let logQueue = DispatchQueue(label: "com.jimmy.opencode-shell.log")

private func shellLog(_ message: String) {
    let sanitized = redactSecrets(message)
    logQueue.async {
        let fileManager = FileManager.default
        let dir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/log", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("shell.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(sanitized)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: path.path) {
            fileManager.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

// 兜底脱敏：pair token 就是登录凭据，任何写日志的路径都不允许原文落盘。
private func redactSecrets(_ text: String) -> String {
    guard var result = Optional(text) else { return "" }
    if let regex = try? NSRegularExpression(pattern: "/auth/connect/[^\\s?#\"']+") {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "/auth/connect/<redacted>")
    }
    return result
}

private let appDelegate = AppDelegate()

@main
struct ShellApp {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.regular)   // 保证 Dock 里有图标
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var connecting = false

    // 内容进程崩溃计数（5s 窗口内），见 webViewWebContentProcessDidTerminate
    private var contentCrashCount = 0
    private var lastContentCrashAt = Date.distantPast

    // 标题栏自愈状态：baseline 只在启动稳定时采一次，之后全部相对它判断
    private var healthyCloseCenter: NSPoint?
    private var pendingRepair: DispatchWorkItem?
    private var repairAttempts = 0
    private var repairing = false
    private var lastRepairAt = Date.distantPast
    private var savedFrameBeforeFullScreen: NSRect?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        connect()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        shellLog("launch: v\(version)")
    }

    // 关掉窗口（其实只是 orderOut）不退出应用
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 点 Dock 图标（应用已在运行）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // 从 Cmd+Tab / 点图标激活：窗口被 orderOut 过就拉回来
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // 红叉 / ⌘W = 隐藏窗口（飞书式）：窗口从桌面消失、Dock 里不留缩略图，
    // 应用继续运行、图标留在 Dock；页面状态留在内存里。
    // 返回 false 阻止窗口真正关闭。**不要**用 performMiniaturize（那是黄点）
    // 也**不要**用 NSApp.hide（菜单栏会一起消失）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: - 窗口

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // 持久化 cookie，否则每次启动都掉登录
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: baseStyleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "OpenCode"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self        // 漏了这行 windowShouldClose 永不触发

        // 用普通容器承载 WKWebView，而不是让 webView 直接当 contentView：
        // 直接当的话，全屏退出后窗口/contentView 的 frame 账容易算错，
        // 交通灯与标题栏可能错位（2026-11-03 清单 P0-3）。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860))
        container.autoresizesSubviews = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container

        if !window.setFrameUsingName(windowFrameName) { window.center() }
        window.setFrameAutosaveName(windowFrameName)
        window.makeKeyAndOrderFront(nil)
        activateApp()

        // 启动稳定后记一次正常几何，后面靠它判断标题栏是否被全屏搞乱
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureHealthyBaseline()
        }
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 标题栏自愈（全屏进出后按钮/标题错位）

    private func fmt(_ r: NSRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", r.minX, r.minY, r.width, r.height)
    }

    private func fmt(_ p: NSPoint) -> String {
        String(format: "%.1f,%.1f", p.x, p.y)
    }

    /// 红绿灯（关闭按钮）中心点，换算到窗口坐标系
    private func closeButtonCenterInWindow() -> NSPoint? {
        guard let button = window.standardWindowButton(.closeButton),
              let superview = button.superview else { return nil }
        return superview.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: nil)
    }

    /// 标题栏高度 = 窗口高 - 内容布局区高。正常约 28；被 .fullSizeContentView 吃掉时变 0
    private var titleBarHeight: CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    private func captureHealthyBaseline() {
        guard let center = closeButtonCenterInWindow() else { return }
        healthyCloseCenter = center
        shellLog("baseline: close=\(fmt(center)) barH=\(titleBarHeight) mask=\(window.styleMask.rawValue) frame=\(fmt(window.frame))")
    }

    /// 标题栏是否被搞乱。判据全部相对窗口自身几何，不依赖绝对坐标（窗口大小可变）：
    /// 按钮相对左边距应与基准一致、应垂直居中于标题栏、标题栏高度应正常。
    private func titleBarIsBroken() -> Bool {
        guard !window.styleMask.contains(.fullScreen) else { return false }
        guard let baseline = healthyCloseCenter else { return false }
        guard let center = closeButtonCenterInWindow() else {
            return window.styleMask.contains(.titled)   // 该有按钮却没有 = 已坏
        }
        if abs(center.x - baseline.x) > 3 { return true }
        let bar = titleBarHeight
        if bar < 20 { return true }                                     // 标题栏被内容吃掉
        if center.y < window.contentLayoutRect.height { return true }   // 按钮掉进内容区
        if center.y > window.frame.height { return true }               // 按钮顶出窗口
        let expectedY = window.frame.height - bar / 2
        if abs(center.y - expectedY) > 6 { return true }                // 未垂直居中
        return false
    }

    private func scheduleTitleBarRepair(_ reason: String, delay: TimeInterval) {
        pendingRepair?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRepair = nil
            self.repairTitleBarIfNeeded(reason)
        }
        pendingRepair = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func repairTitleBarIfNeeded(_ reason: String) {
        guard window != nil, !window.styleMask.contains(.fullScreen) else { return }
        guard !repairing else { return }
        guard titleBarIsBroken() else {
            repairAttempts = 0
            return
        }
        // 冷却（自愈动作会自身触发 resize/becomeKey）：被挡下就排一次重试，
        // 但不无限重排——最多 6 次仍修不好就记日志收手。
        if Date().timeIntervalSince(lastRepairAt) < 1.0 {
            guard repairAttempts < 6 else { return }
            repairAttempts += 1
            scheduleTitleBarRepair("\(reason) retry", delay: 1.2)
            return
        }

        repairing = true
        lastRepairAt = Date()
        defer { repairing = false }

        shellLog("titlebar broken (\(reason)): close=\(closeButtonCenterInWindow().map { fmt($0) } ?? "nil") barH=\(titleBarHeight) mask=\(window.styleMask.rawValue) frame=\(fmt(window.frame))")

        // ① 复位样式掩码：WebKit 全屏常残留 .fullSizeContentView，标题栏会变成浮层
        if window.styleMask != baseStyleMask {
            window.styleMask = baseStyleMask
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            if !titleBarIsBroken() { shellLog("repair ok: styleMask reset"); return }
        }

        // ② 尺寸微调 1pt 再还原，逼 AppKit 按新宽度重排标题栏与交通灯
        let frame = window.frame
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width + 1, height: frame.height),
                        display: true)
        window.setFrame(frame, display: true)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if !titleBarIsBroken() { shellLog("repair ok: frame nudge"); return }

        // ③ 翻转 .titled 位，让 AppKit 重建标题栏容器
        window.styleMask = baseStyleMask.subtracting(.titled)
        window.styleMask = baseStyleMask
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if !titleBarIsBroken() { shellLog("repair ok: titled toggle"); return }

        // ④ 刷新透明标题栏状态（会连带重算交通灯位置）。本项目从不设透明标题栏，
        //    这里只是触发一次重排，结尾必须回到 false。
        window.titlebarAppearsTransparent = true
        window.titlebarAppearsTransparent = false
        shellLog(titleBarIsBroken() ? "repair failed: still broken" : "repair ok: titlebar refresh")
    }

    // MARK: - 全屏事件

    func windowWillEnterFullScreen(_ notification: Notification) {
        savedFrameBeforeFullScreen = window.frame
        shellLog("enter fullscreen: saved=\(fmt(window.frame))")
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        shellLog("did enter fullscreen: frame=\(fmt(window.frame))")
        scheduleTitleBarRepair("didEnterFullScreen", delay: 0.3)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        shellLog("did exit fullscreen: frame=\(fmt(window.frame))")
        // WebKit 元素全屏常把窗口撑到整屏却不缩回：恢复到进全屏前的尺寸
        if let saved = savedFrameBeforeFullScreen {
            savedFrameBeforeFullScreen = nil
            let screenHeight = window.screen?.visibleFrame.height ?? 0
            if saved.width > 0, window.frame.height >= screenHeight - 2 {
                window.setFrame(saved, display: true)
                shellLog("restored frame: \(fmt(saved))")
            }
        }
        scheduleTitleBarRepair("didExitFullScreen", delay: 0.25)
    }

    func windowDidResize(_ notification: Notification) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        scheduleTitleBarRepair("resize", delay: 0.3)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleTitleBarRepair("becomeKey", delay: 0.2)
    }

    // MARK: - 连接

    private func connect() {
        if connecting { return }
        connecting = true
        shellLog("connect: ensuring service")
        loadMessagePage(title: "正在连接 OpenCode…", detail: nil)

        resolveTargetURL { [weak self] url in
            guard let self else { return }
            self.connecting = false
            guard let url else {
                shellLog("connect: no target url (ensure failed)")
                self.loadMessagePage(
                    title: "无法连接 OpenCode",
                    detail: "服务 30 秒内没有就绪，或取不到配对链接。\n请查看 ~/.local/share/opencode/log/web.err.log，然后按 ⌘R 重试。"
                )
                return
            }
            // ⚠️ 不记录 URL 全文：pair 链接里的 token 就是登录凭据
            shellLog("connect: url acquired (len=\(url.absoluteString.count)), loading")
            self.webView.load(URLRequest(url: url))
        }
    }

    // 执行 launcher.sh --url：等服务就绪 → stdout 拿一个 URL。
    // 契约：stdout 只有 URL、无其它输出；失败时非 0 且 stdout 空。
    private func resolveTargetURL(completion: @escaping (URL?) -> Void) {
        guard let script = Bundle.main.url(forResource: "launcher", withExtension: "sh") else {
            shellLog("ensure: launcher.sh missing from bundle")
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, "--url"]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                shellLog("ensure: failed to run launcher: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            process.waitUntilExit()

            let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            shellLog("ensure: exit=\(process.terminationStatus)")
            for line in errText.split(separator: "\n").prefix(10) {
                shellLog("launcher: \(line)")   // redactSecrets 会兜底抹掉 token
            }

            var url: URL?
            if process.terminationStatus == 0, !outText.isEmpty {
                url = URL(string: outText)
                if url == nil { shellLog("ensure: stdout is not a valid url (len=\(outText.count))") }
            } else if process.terminationStatus == 0 {
                shellLog("ensure: stdout empty")
            }
            DispatchQueue.main.async { completion(url) }
        }
    }

    private func loadMessagePage(title: String, detail: String?) {
        let escapedTitle = escapeHTML(title)
        let detailBlock = detail.map { "<p>\(escapeHTML($0))</p>" } ?? ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{height:100%;margin:0}
        body{background:#17181c;color:#c8c9cc;font:14px -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;
             display:flex;align-items:center;justify-content:center;text-align:center}
        div{max-width:560px;line-height:1.6}
        h1{font-size:16px;font-weight:600;margin:0 0 8px;color:#e6e7e9}
        p{margin:0;color:#9a9ba1;white-space:pre-wrap}
        </style></head><body><div><h1>\(escapedTitle)</h1>\(detailBlock)</div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let aboutItem = NSMenuItem(
            title: "关于 OpenCode",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏 OpenCode", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)
        let hideOthersItem = NSMenuItem(
            title: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)
        let showAllItem = NSMenuItem(
            title: "全部显示",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 OpenCode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        viewItem.submenu = viewMenu
        let reloadItem = NSMenuItem(title: "重新连接", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewMenu.addItem(.separator())
        let zoomInItem = NSMenuItem(title: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)
        let zoomResetItem = NSMenuItem(title: "实际大小", action: #selector(zoomReset(_:)), keyEquivalent: "0")
        zoomResetItem.target = self
        viewMenu.addItem(zoomResetItem)
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(
            title: "进入全屏幕",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        // 隐藏窗口后的兜底入口：万一某台机器 reopen 没按预期触发，菜单里也能找回来
        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindowAction(_:)), keyEquivalent: "")
        showItem.target = self
        windowMenu.addItem(showItem)
        // ⌘W：走 performClose → windowShouldClose → orderOut（与红叉一致）
        let closeItem = NSMenuItem(title: "隐藏窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = nil   // 走 first responder，由窗口处理
        windowMenu.addItem(closeItem)
        windowMenu.addItem(.separator())
        let minimizeItem = NSMenuItem(
            title: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let frontItem = NSMenuItem(
            title: "前置全部窗口",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        frontItem.target = NSApp
        windowMenu.addItem(frontItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func reloadPage(_ sender: Any?) { connect() }

    @objc private func showMainWindowAction(_ sender: Any?) { showMainWindow() }

    private func showMainWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activateApp()
    }

    @objc private func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc private func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc private func zoomReset(_ sender: Any?) { webView.pageZoom = 1.0 }

    // MARK: - WKNavigationDelegate

    // 主框架跳去外部站点 → 交系统浏览器并取消，别把壳变成浏览器
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame?.isMainFrame == true,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }
        if !isLocalEndpoint(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func isLocalEndpoint(_ url: URL) -> Bool {
        url.host == baseURL.host && (url.port ?? 80) == (baseURL.port ?? 80)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 只记长度级信息，不记 URL（pair 链接带 token）
        shellLog("loaded: \(webView.title ?? "")")
        webView.evaluateJavaScript("document.title") { value, _ in
            shellLog("page title: \(value as? String ?? "")")
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let names = cookies.map(\.name).sorted().joined(separator: ",")
            shellLog("cookies: \(cookies.count) [\(names)]")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failPage(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failPage(error)
    }

    private func failPage(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        shellLog("load failed: \(error.localizedDescription)")
        connecting = false
        loadMessagePage(title: "页面加载失败", detail: "\(error.localizedDescription)\n按 ⌘R 重新连接。")
    }

    // MARK: - 内容进程回收

    // WebKit 内容进程被系统回收（opencode 是长会话 + 大段代码渲染，内存压力大）
    // 时窗口会永久停在白屏，只能 ⌘Q 重开。cookie 存在 .default() store 里，
    // reload 不掉登录 —— 但页面本身必崩时会无限重载，所以 5s 窗口内最多重载
    // 2 次，超限改走 connect() 重新配对（2026-11-03 清单 P0-2）。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        if now.timeIntervalSince(lastContentCrashAt) > 5 { contentCrashCount = 0 }
        lastContentCrashAt = now
        contentCrashCount += 1

        guard webView.url != nil else {
            shellLog("web content process terminated before any page: reconnecting")
            contentCrashCount = 0
            connect()
            return
        }
        if contentCrashCount > 2 {
            shellLog("web content process terminated \(contentCrashCount) times in 5s: reconnecting")
            contentCrashCount = 0
            connect()
            return
        }
        shellLog("web content process terminated: reloading (\(contentCrashCount)/2)")
        webView.reload()
    }

    // MARK: - WKUIDelegate

    // window.open / target=_blank：同源在本窗口加载，外链交系统浏览器
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternallyOrInPlace(url) }
        return nil
    }

    private func openExternallyOrInPlace(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if (scheme == "http" || scheme == "https") && isLocalEndpoint(url) {
            webView.load(URLRequest(url: url))
        } else if scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "tel" {
            NSWorkspace.shared.open(url)
        }
    }

    // <input type=file>：不实现这个，点「上传/附件」静默无反应
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // opencode Web UI 不需要麦克风/摄像头
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: - 下载

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        shellLog("download finished")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        shellLog("download failed: \(error.localizedDescription)")
    }
}
