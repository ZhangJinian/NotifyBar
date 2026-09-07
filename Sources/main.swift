import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let activityMonitor = TaskActivityMonitor()
    private let client = CodexAppServerClient()
    private let strip = CompactTouchBar()
    private let quota = QuotaView()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var refreshing = false
    private var visible = false
    private var lastUpdate: Date?
    private let info = NSMenuItem(title: "正在读取额度…", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = QuotaView.icon?.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("mytouchbar Codex 额度")
        let menu = NSMenu()
        menu.addItem(info)
        menu.addItem(.separator())
        for (title, action) in [("刷新额度", #selector(refresh)), ("重新显示小块", #selector(show)), ("隐藏小块", #selector(hide)), ("退出", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        quota.refresh = { [weak self] in self?.refresh() }
        strip.item.view = quota
        activityMonitor.onChange = { [weak self] in self?.quota.activity = $0 }
        activityMonitor.start()
        client.onRateLimitsUpdated = { [weak self] in self?.refresh() }
        show()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func show() {
        visible = strip.show()
        if !visible { info.title = "系统不支持后台 Touch Bar 接口" }
    }
    @objc private func hide() { strip.hide(); visible = false }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func wake() { if visible { show() }; refresh() }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        client.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.client.readRateLimits { [weak self] result in self?.receive(result) }
            case .failure(let error): self.receive(.failure(error))
            }
        }
    }

    private func receive(_ result: Result<GetAccountRateLimitsResponse, Error>) {
        refreshing = false
        switch result {
        case .success(let response):
            quota.fiveHour = response.windows.fiveHour
            quota.weekly = response.windows.weekly
            quota.stale = false
            lastUpdate = Date()
            info.title = "5h 剩余 \(quota.fiveHour?.remaining ?? "--") · 7d 剩余 \(quota.weekly?.remaining ?? "--")"
            if quota.fiveHour == nil || quota.weekly == nil { info.title += "（-- 表示接口未提供）" }
            statusItem.button?.toolTip = "\(info.title)\n时间为本地重置时间；每分钟刷新"
        case .failure(let error):
            quota.stale = true
            let previous = lastUpdate.map { "；保留 \($0.formatted(date: .omitted, time: .standard)) 的数据" } ?? ""
            info.title = "读取失败\(previous)"
            statusItem.button?.toolTip = error.localizedDescription
            client.stop()
        }
        quota.updateAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        activityMonitor.stop()
        timer?.invalidate()
        strip.hide()
        client.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

if CommandLine.arguments.contains("--self-test") {
    try selfTest()
    activitySelfTest()
    quotaColorSelfTest()
} else if CommandLine.arguments.contains("--activity-probe") {
    let monitor = TaskActivityMonitor()
    monitor.onChange = { print("Activity: \($0.rawValue)") }
    monitor.start()
    RunLoop.current.run(until: Date().addingTimeInterval(8))
    monitor.stop()
} else if CommandLine.arguments.contains("--probe") {
    let client = CodexAppServerClient()
    var finished = false
    var succeeded = false
    client.start { result in
        switch result {
        case .success:
            client.readRateLimits { result in
                switch result {
                case .success(let response):
                    print("5h: \(response.windows.fiveHour?.remaining ?? "--"), reset \(response.windows.fiveHour?.reset ?? "--")")
                    print("7d: \(response.windows.weekly?.remaining ?? "--"), reset \(response.windows.weekly?.reset ?? "--")")
                    succeeded = true
                case .failure(let error): print("ERROR: \(error.localizedDescription)")
                }
                finished = true
            }
        case .failure(let error): print("ERROR: \(error.localizedDescription)"); finished = true
        }
    }
    let deadline = Date().addingTimeInterval(35)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    client.stop()
    exit(succeeded ? 0 : 1)
} else if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
    _ = NSApplication.shared
    let view = QuotaView()
    view.fiveHour = RateLimitWindow(usedPercent: 12, windowDurationMins: 300, resetsAt: 1800000000)
    view.weekly = RateLimitWindow(usedPercent: 33, windowDurationMins: 10080, resetsAt: 1800500000)
    if CommandLine.arguments.contains("--running") { view.activity = .running }
    if CommandLine.arguments.contains("--unread") { view.activity = .unread }
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    print("Preview: \(Int(view.bounds.width)) × \(Int(view.bounds.height))")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
