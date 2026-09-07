import AppKit
import QuartzCore

struct OpenCodeLocation: Equatable {
    var location = "Terminal"
    var activity: TaskActivity = .unread
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
                let color: NSColor = location.activity == .running ? .systemBlue : location.activity == .unread ? .systemRed : .systemGreen
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

    private func output(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath); process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
                let before = index + 1 < ordered.count ? ordered[index + 1].startedAt : nil
                let attention = latestNeedsAttention(in: process.directory, after: process.startedAt, before: before)
                let running = latestAssistantRunning(in: process.directory, after: process.startedAt, before: before)
                found.append(OpenCodeLocation(location: process.host.name, activity: attention ? .unread : running ? .running : .idle,
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
        locations = next
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
        return output("/usr/bin/sqlite3", [path, "SELECT \(expression) FROM message m JOIN session s ON s.id=m.session_id WHERE s.directory='\(escaped)' AND s.time_created >= \(after)\(upper) ORDER BY m.time_created DESC LIMIT 1;"]) ?? ""
    }
    private func latestAssistantRunning(in cwd: String, after: Int64, before: Int64?) -> Bool {
        sql(cwd, after: after, before: before, expression: "CASE WHEN json_extract(m.data,'$.role')='assistant' AND json_extract(m.data,'$.time.completed') IS NULL THEN '1' ELSE '0' END") == "1"
    }
    private func latestNeedsAttention(in cwd: String, after: Int64, before: Int64?) -> Bool {
        let expression = "EXISTS(SELECT 1 FROM part p WHERE p.session_id=s.id AND json_extract(p.data,'$.type')='tool' AND json_extract(p.data,'$.state.status')='pending')"
        return sql(cwd, after: after, before: before, expression: expression) == "1"
    }
    private func publish(_ next: OpenCodeState) {
        guard next != state else { return }; state = next; onChange?(next)
    }
}

func openCodeSelfTest() {
    let state = OpenCodeState(locations: [.init(location: "VS Code", activity: .running, hostPID: 1), .init()])
    precondition(state.visible && state.locations.map(\.location) == ["VS Code", "Terminal"])
    print("PASS: OpenCode horizontal locations")
}
