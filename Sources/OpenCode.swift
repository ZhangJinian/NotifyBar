import AppKit
import QuartzCore

struct OpenCodeLocation: Equatable {
    var location = "Terminal"
    var activity: TaskActivity = .idle
    var processPID: pid_t = 0
    var title = "OpenCode"
    var hostPID: pid_t?
    var tty = ""
    var directory = ""
}

struct OpenCodeState: Equatable {
    var locations: [OpenCodeLocation] = []
    var visible: Bool { !locations.isEmpty }
}

private struct OpenCodeProcess {
    let pid: pid_t
    let directory: String
    let host: (name: String, pid: pid_t?)
    let tty: String
    let startedAt: Int64
}

private func waitingForOpenCodeInput(session: String, log: String) -> Bool {
    let lines = log.split(separator: "\n")
    guard let loop = lines.lastIndex(where: { $0.contains("message=loop session.id=\(session)") }) else { return false }
    return lines[lines.index(after: loop)...].contains { $0.contains("message=asking id=per_") || $0.contains("message=asking id=que_") }
}

final class OpenCodeView: NSButton {
    static let blockSize = NSSize(width: 198, height: 30)
    var displayState = OpenCodeState() { didSet { needsDisplay = true; updateLight() } }
    var onTap: (() -> Void)?
    private var lights: [CAShapeLayer] = []
    private static let icon = Bundle.main.url(forResource: "opencode", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    private var groups: [(String, [OpenCodeLocation])] {
        let grouped = Dictionary(grouping: displayState.locations, by: \.location)
        return grouped.keys.sorted { $0 == "VS Code" && $1 != "VS Code" }.map { ($0, grouped[$0]!) }
    }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.blockSize))
        title = ""; isBordered = false; target = self; action = #selector(tapped)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.blockSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.blockSize.height).isActive = true
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("OpenCode，点击打开")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { Self.blockSize }
    @objc private func tapped() { onTap?() }

    private func updateLight() {
        lights.forEach { $0.removeFromSuperlayer() }
        lights = []
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        var x: CGFloat = 43
        for (name, locations) in groups {
            for location in locations {
                let light = CAShapeLayer()
                light.path = CGPath(ellipseIn: NSRect(x: x, y: 19, width: 6, height: 6), transform: nil)
                let color: NSColor = location.activity == .running ? .systemBlue : location.activity == .attention ? .systemOrange : location.activity == .unread ? .systemRed : .systemGreen
                light.fillColor = color.cgColor
                layer?.addSublayer(light); lights.append(light)
                if location.activity == .running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 0.3; animation.toValue = 1; animation.duration = 1.6
                    animation.autoreverses = true; animation.repeatCount = .infinity
                    light.add(animation, forKey: "breathe")
                }
                x += 9
            }
            x += ceil((name as NSString).size(withAttributes: attributes).width) + 9
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        Self.icon?.draw(in: NSRect(x: 12, y: 4, width: 22, height: 22))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        ("OpenCode" as NSString).draw(in: NSRect(x: 43, y: 1, width: 143, height: 14), withAttributes: attributes)
        var x: CGFloat = 43
        for (name, locations) in groups {
            x += CGFloat(locations.count * 9)
            let width = ceil((name as NSString).size(withAttributes: attributes).width)
            (name as NSString).draw(in: NSRect(x: x, y: 15, width: width, height: 14), withAttributes: attributes)
            x += width + 9
        }
    }
}

final class OpenCodeMonitor {
    var onChange: ((OpenCodeState) -> Void)?
    private let queue = DispatchQueue(label: "mytouchbar.opencode", qos: .utility)
    private let activationQueue = DispatchQueue(label: "mytouchbar.opencode.activate", qos: .userInitiated)
    private var timer: Timer?
    private var state = OpenCodeState()
    private var locations: [OpenCodeLocation] = []
    private var unreadProcesses = Set<pid_t>()
    private var selected = 0

    func start() {
        queue.async { [weak self] in self?.poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.queue.async { [weak self] in self?.poll() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func activate() {
        guard !locations.isEmpty else { return }
        let location = locations[selected]
        if location.activity == .unread {
            unreadProcesses.remove(location.processPID)
            locations[selected].activity = .idle
            publish(OpenCodeState(locations: locations))
        }
        if location.location == "VS Code", !location.directory.isEmpty {
            var route = URLComponents()
            route.scheme = "vscode"; route.host = "file"; route.path = location.directory
            if let url = route.url { NSWorkspace.shared.open(url) }
        }
        activationQueue.async { [weak self] in
            if location.location == "VS Code", !location.directory.isEmpty {
                let script = "delay 0.12\ntell application \"Visual Studio Code\" to activate\ntell application \"System Events\" to keystroke \"`\" using control down"
                _ = self?.output("/usr/bin/osascript", ["-e", script])
            } else if location.location == "Terminal", !location.tty.isEmpty {
                let script = "tell application \"Terminal\" to repeat with w in windows\nrepeat with t in tabs of w\nif tty of t is \"/dev/\(location.tty)\" then\nset selected of t to true\nset index of w to 1\nactivate\nreturn\nend if\nend repeat\nend repeat"
                _ = self?.output("/usr/bin/osascript", ["-e", script])
            } else if let pid = location.hostPID, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
            }
        }
        guard locations.count > 1 else { return }
        selected = (selected + 1) % locations.count
    }
    func activate(processPID: pid_t) {
        guard let index = locations.firstIndex(where: { $0.processPID == processPID }) else { return }
        selected = index
        activate()
    }

    private func output(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath); process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func poll() {
        guard let raw = output("/usr/bin/pgrep", ["-x", "opencode"]) else {
            DispatchQueue.main.async { [weak self] in self?.apply([]) }; return
        }
        let processes = raw.split(separator: "\n").compactMap { pid_t($0) }.map { pid -> OpenCodeProcess in
            let cwd = output("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])?.split(separator: "\n").first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) } ?? ""
            return OpenCodeProcess(pid: pid, directory: cwd, host: hostApp(startingAt: pid),
                tty: output("/bin/ps", ["-p", "\(pid)", "-o", "tty="]) ?? "", startedAt: processStartedAt(pid))
        }
        var found: [OpenCodeLocation] = []
        for group in Dictionary(grouping: processes, by: \.directory).values {
            let ordered = group.sorted { $0.startedAt < $1.startedAt }
            for (index, process) in ordered.enumerated() {
                // A TUI can resume a session created before its process; with one process in a directory, use that directory's current session.
                let after = ordered.count == 1 ? 0 : process.startedAt
                let before = index + 1 < ordered.count ? ordered[index + 1].startedAt : nil
                let attention = latestNeedsAttention(in: process.directory, after: after, before: before)
                let running = latestAssistantRunning(in: process.directory, after: after, before: before)
                found.append(OpenCodeLocation(location: process.host.name, activity: attention ? .attention : running ? .running : .idle,
                    processPID: process.pid, title: latestTitle(in: process.directory, after: after, before: before),
                    hostPID: process.host.pid, tty: process.tty, directory: process.directory))
            }
        }
        let next = found.sorted {
            if $0.location != $1.location { return $0.location == "VS Code" }
            return $0.tty < $1.tty
        }
        DispatchQueue.main.async { [weak self] in self?.apply(next) }
    }

    private func apply(_ next: [OpenCodeLocation]) {
        let previous = Dictionary(uniqueKeysWithValues: locations.map { ($0.processPID, $0.activity) })
        let live = Set(next.map(\.processPID))
        unreadProcesses.formIntersection(live)
        locations = next.map { location in
            var location = location
            if location.activity == .running || location.activity == .attention {
                unreadProcesses.remove(location.processPID)
            } else if previous[location.processPID] == .running || previous[location.processPID] == .attention {
                unreadProcesses.insert(location.processPID)
            }
            if unreadProcesses.contains(location.processPID) { location.activity = .unread }
            return location
        }
        if locations.isEmpty { selected = 0; publish(OpenCodeState()); return }
        selected = min(selected, locations.count - 1)
        publish(OpenCodeState(locations: locations))
    }

    private func hostApp(startingAt pid: pid_t) -> (name: String, pid: pid_t?) {
        var current = pid
        for _ in 0..<12 {
            guard let line = output("/bin/ps", ["-p", "\(current)", "-o", "ppid="]), let parent = pid_t(line) else { break }
            if let app = NSRunningApplication(processIdentifier: parent), let bundle = app.bundleIdentifier {
                if bundle == "com.microsoft.VSCode" || bundle == "com.microsoft.VSCodeInsiders" { return ("VS Code", parent) }
                if bundle == "com.apple.Terminal" { return ("Terminal", parent) }
            }
            current = parent
        }
        return ("Terminal", nil)
    }

    private func processStartedAt(_ pid: pid_t) -> Int64 {
        guard let text = output("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]) else { return 0 }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return Int64((formatter.date(from: text)?.timeIntervalSince1970 ?? 0) * 1000)
    }

    private func sql(_ cwd: String, after: Int64, before: Int64?, expression: String) -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        let escaped = cwd.replacingOccurrences(of: "'", with: "''")
        let upper = before.map { " AND s.time_created < \($0)" } ?? ""
        return output("/usr/bin/sqlite3", [path, "SELECT \(expression) FROM message m JOIN session s ON s.id=m.session_id WHERE s.directory='\(escaped)' AND s.time_created >= \(after)\(upper) ORDER BY s.time_updated DESC,m.time_created DESC LIMIT 1;"]) ?? ""
    }
    private func latestAssistantRunning(in cwd: String, after: Int64, before: Int64?) -> Bool {
        sql(cwd, after: after, before: before, expression: "CASE WHEN json_extract(m.data,'$.role')='assistant' AND json_extract(m.data,'$.time.completed') IS NULL THEN '1' ELSE '0' END") == "1"
    }
    private func latestTitle(in cwd: String, after: Int64, before: Int64?) -> String {
        let title = sql(cwd, after: after, before: before, expression: "s.title")
        return title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title
    }
    private func latestNeedsAttention(in cwd: String, after: Int64, before: Int64?) -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        let session = sql(cwd, after: after, before: before, expression: "s.id")
        let escaped = session.replacingOccurrences(of: "'", with: "''")
        let query = "SELECT CASE WHEN json_extract(data,'$.state.status')='pending' OR (json_extract(data,'$.tool')='question' AND json_extract(data,'$.state.status')='running') THEN '1' ELSE '0' END FROM part WHERE session_id='\(escaped)' AND json_extract(data,'$.type')='tool' ORDER BY time_created DESC LIMIT 1;"
        if output("/usr/bin/sqlite3", [path, query]) == "1" { return true }
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/log/opencode.log").path
        guard !session.isEmpty, let text = output("/usr/bin/tail", ["-n", "500", log]) else { return false }
        return waitingForOpenCodeInput(session: session, log: text)
    }
    private func publish(_ next: OpenCodeState) {
        guard next != state else { return }; state = next; onChange?(next)
    }
}

func openCodeSelfTest() {
    let state = OpenCodeState(locations: [.init(location: "VS Code", activity: .running, hostPID: 1), .init()])
    precondition(state.visible && state.locations.map(\.location) == ["VS Code", "Terminal"])
    precondition(waitingForOpenCodeInput(session: "s1", log: "message=loop session.id=s1\nmessage=asking id=per_1"))
    precondition(!waitingForOpenCodeInput(session: "s1", log: "message=loop session.id=s1\nmessage=asking id=per_1\nmessage=loop session.id=s1"))
    print("PASS: OpenCode horizontal locations")
}
