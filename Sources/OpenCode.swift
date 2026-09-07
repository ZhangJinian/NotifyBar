import AppKit
import QuartzCore

struct OpenCodeLocation: Equatable {
    var location = "Terminal"
    var activity: TaskActivity = .unread
    var hostPID: pid_t?
}

struct OpenCodeState: Equatable {
    var locations: [OpenCodeLocation] = []
    var visible: Bool { !locations.isEmpty }
}

final class OpenCodeView: NSButton {
    static let blockSize = NSSize(width: 198, height: 30)
    var displayState = OpenCodeState() { didSet { needsDisplay = true; updateLight() } }
    var onTap: (() -> Void)?
    private var lights: [CAShapeLayer] = []
    private static let icon = Bundle.main.url(forResource: "opencode", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

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
        for location in displayState.locations {
            let light = CAShapeLayer()
            light.path = CGPath(ellipseIn: NSRect(x: x, y: 19, width: 6, height: 6), transform: nil)
            light.fillColor = (location.activity == .running ? NSColor.systemGreen : NSColor.systemRed).cgColor
            layer?.addSublayer(light); lights.append(light)
            if location.activity == .running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 0.3; animation.toValue = 1; animation.duration = 1.6
                animation.autoreverses = true; animation.repeatCount = .infinity
                light.add(animation, forKey: "breathe")
            }
            x += 11 + ceil((location.location as NSString).size(withAttributes: attributes).width) + 9
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        Self.icon?.draw(in: NSRect(x: 12, y: 4, width: 22, height: 22))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        ("OpenCode" as NSString).draw(in: NSRect(x: 43, y: 1, width: 143, height: 14), withAttributes: attributes)
        var x: CGFloat = 54
        for location in displayState.locations {
            let width = ceil((location.location as NSString).size(withAttributes: attributes).width)
            (location.location as NSString).draw(in: NSRect(x: x, y: 15, width: width, height: 14), withAttributes: attributes)
            x += width + 20
        }
    }
}

final class OpenCodeMonitor {
    var onChange: ((OpenCodeState) -> Void)?
    private let queue = DispatchQueue(label: "mytouchbar.opencode", qos: .utility)
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
        guard let pid = location.hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
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
        let found = raw.split(separator: "\n").compactMap { pid_t($0) }.map { pid -> OpenCodeLocation in
            let cwd = output("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])?.split(separator: "\n").first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) } ?? ""
            let host = hostApp(startingAt: pid)
            return OpenCodeLocation(location: host.name,
                activity: latestAssistantRunning(in: cwd) ? .running : .unread, hostPID: host.pid)
        }
        let grouped = Dictionary(grouping: found, by: { $0.location })
        let preferred = grouped.values.compactMap { group in
            group.first(where: { $0.activity == .running }) ?? group.first
        }
        let next = preferred.sorted { $0.location == "VS Code" && $1.location != "VS Code" }
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
                if bundle == "com.microsoft.VSCode" || bundle.hasPrefix("com.microsoft.VSCode") { return ("VS Code", parent) }
                if bundle == "com.apple.Terminal" { return ("Terminal", parent) }
            }
            current = parent
        }
        return ("Terminal", nil)
    }

    private func sql(_ cwd: String, expression: String) -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        let escaped = cwd.replacingOccurrences(of: "'", with: "''")
        return output("/usr/bin/sqlite3", [path, "SELECT \(expression) FROM message m JOIN session s ON s.id=m.session_id WHERE s.directory='\(escaped)' ORDER BY m.time_created DESC LIMIT 1;"]) ?? ""
    }
    private func latestAssistantRunning(in cwd: String) -> Bool {
        sql(cwd, expression: "CASE WHEN json_extract(m.data,'$.role')='assistant' AND json_extract(m.data,'$.time.completed') IS NULL THEN '1' ELSE '0' END") == "1"
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
