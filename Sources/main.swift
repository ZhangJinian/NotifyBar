import AppKit
import UserNotifications

private func completed<Key: Hashable>(_ activity: TaskActivity, key: Key, active: inout Set<Key>) -> Bool {
    if activity == .running || activity == .attention { active.insert(key) }
    return activity == .unread && active.remove(key) != nil
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let activityMonitor = TaskActivityMonitor()
    private let client = CodexAppServerClient()
    private let strip = CompactTouchBar()
    private let quota = QuotaView()
    private let openCode = OpenCodeView()
    private let openCodeMonitor = OpenCodeMonitor()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var refreshing = false
    private var visible = false
    private var lastUpdate: Date?
    private let info = NSMenuItem(title: "正在读取额度…", action: nil, keyEquivalent: "")
    private var codexTasks: [CodexMenuEntry] = []
    private var openCodeTasks: [OpenCodeLocation] = []
    private var activeCodexTasks = Set<String>()
    private var activeOpenCodeTasks = Set<pid_t>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = QuotaView.icon?.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = icon
        statusItem.button?.setAccessibilityLabel("mytouchbar Codex 额度")
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        quota.onTap = { [weak self] in self?.activityMonitor.openBestTask() }
        strip.item.view = quota
        strip.openCodeItem.view = openCode
        openCode.onTap = { [weak self] in self?.openCodeMonitor.activate() }
        openCodeMonitor.onChange = { [weak self] state in
            self?.notifyCompletedOpenCodeTasks(state.locations)
            self?.openCode.displayState = state
            self?.strip.setOpenCodeVisible(state.visible)
            self?.openCodeTasks = state.locations
        }
        openCodeMonitor.start()
        activityMonitor.onChange = { [weak self] in self?.quota.activity = $0 }
        activityMonitor.onTasksChange = { [weak self] tasks in self?.notifyCompletedCodexTasks(tasks); self?.codexTasks = tasks }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(info); menu.addItem(.separator())
        addSection("Codex", entries: codexTasks.map { ($0.title, $0.activity) }, action: #selector(openCodex(_:)), to: menu)
        addSection("OpenCode", entries: openCodeTasks.map { ("\($0.title) · \($0.location)", $0.activity) }, action: #selector(openOpenCode(_:)), to: menu)
        menu.addItem(.separator())
        for (title, action) in [("刷新额度", #selector(refresh)), ("重新显示小块", #selector(show)), ("隐藏小块", #selector(hide)), ("退出", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
    }

    private func addSection(_ title: String, entries: [(String, TaskActivity)], action: Selector, to menu: NSMenu) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: ""); header.isEnabled = false; menu.addItem(header)
        if entries.isEmpty { let empty = NSMenuItem(title: "  无对话", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty); return }
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: "  \(entry.0) — \(statusName(entry.1))", action: action, keyEquivalent: "")
            item.target = self; item.tag = index; item.image = statusIcon(entry.1); menu.addItem(item)
        }
    }

    private func statusName(_ activity: TaskActivity) -> String {
        switch activity { case .running: return "处理中"; case .attention: return "待操作"; case .unread: return "未读"; case .idle: return "空闲" }
    }
    private func statusIcon(_ activity: TaskActivity) -> NSImage {
        let color: NSColor = switch activity {
        case .running: .systemBlue
        case .attention: .systemOrange
        case .unread: .systemRed
        case .idle: .systemGray
        }
        let image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            color.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        image.accessibilityDescription = statusName(activity)
        return image
    }
    @objc private func openCodex(_ sender: NSMenuItem) {
        guard codexTasks.indices.contains(sender.tag) else { return }; activityMonitor.open(codexTasks[sender.tag])
    }
    @objc private func openOpenCode(_ sender: NSMenuItem) {
        guard openCodeTasks.indices.contains(sender.tag) else { return }; openCodeMonitor.activate(processPID: openCodeTasks[sender.tag].processPID)
    }

    private func notifyCompletedCodexTasks(_ tasks: [CodexMenuEntry]) {
        for task in tasks {
            let key = "\(task.host):\(task.id)"
            if completed(task.activity, key: key, active: &activeCodexTasks) {
                notify(title: "Codex 任务已完成", body: task.title, id: "codex:\(key)", userInfo: ["source": "codex", "id": task.id, "host": task.host])
            }
        }
    }

    private func notifyCompletedOpenCodeTasks(_ tasks: [OpenCodeLocation]) {
        for task in tasks {
            if completed(task.activity, key: task.processPID, active: &activeOpenCodeTasks) {
                notify(title: "OpenCode 任务已完成", body: "\(task.title) · \(task.location)", id: "opencode:\(task.processPID)", userInfo: ["source": "opencode", "pid": Int(task.processPID)])
            }
        }
    }

    private func notify(title: String, body: String, id: String, userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default; content.userInfo = userInfo
        UNUserNotificationCenter.current().add(.init(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async { [weak self] in
            if info["source"] as? String == "codex", let id = info["id"] as? String, let host = info["host"] as? String {
                TaskLauncher.open(.init(id: id, host: host))
            } else if info["source"] as? String == "opencode", let pid = info["pid"] as? Int {
                self?.openCodeMonitor.activate(processPID: pid_t(pid))
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

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
        openCodeMonitor.stop()
        timer?.invalidate()
        strip.hide()
        client.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

if CommandLine.arguments.contains("--self-test") {
    var notificationTasks = Set<String>()
    precondition(!completed(.unread, key: "old", active: &notificationTasks))
    precondition(!completed(.running, key: "new", active: &notificationTasks))
    precondition(completed(.unread, key: "new", active: &notificationTasks))
    try selfTest()
    activitySelfTest()
    quotaColorSelfTest()
    openCodeSelfTest()
} else if let index = CommandLine.arguments.firstIndex(of: "--route-probe"), CommandLine.arguments.count > index + 1 {
    let target = TaskOpenTarget(id: CommandLine.arguments[index + 1], host: "local")
    print(TaskLauncher.preferredURL(for: target)?.absoluteString ?? "--")
} else if CommandLine.arguments.contains("--activity-probe") {
    let monitor = TaskActivityMonitor()
    monitor.onChange = { print("Activity: \($0.rawValue)") }
    monitor.start()
    RunLoop.current.run(until: Date().addingTimeInterval(8))
    monitor.stop()
} else if CommandLine.arguments.contains("--opencode-probe") {
    let monitor = OpenCodeMonitor()
    monitor.onChange = { print("OpenCode: visible=\($0.visible) locations=\($0.locations.map { "\($0.location):\($0.activity.rawValue)" }.joined(separator: ","))") }
    monitor.start()
    RunLoop.current.run(until: Date().addingTimeInterval(10))
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
