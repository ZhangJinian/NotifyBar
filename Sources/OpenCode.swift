import AppKit
import QuartzCore

struct OpenCodeState: Equatable {
    var visible = false
    var model = "--"
    var location = "系统终端"
    var activity: TaskActivity = .idle
    var hostPID: pid_t?
}

final class OpenCodeView: NSButton {
    static let blockSize = NSSize(width: 198, height: 30)
    var displayState = OpenCodeState() { didSet { needsDisplay = true; updateBorder() } }
    var onTap: (() -> Void)?
    private let border = CAShapeLayer()
    private static let icon = Bundle.main.url(forResource: "opencode", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.blockSize))
        title = ""; isBordered = false; target = self; action = #selector(tapped)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.blockSize.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.blockSize.height).isActive = true
        wantsLayer = true
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 5, cornerHeight: 5, transform: nil)
        border.fillColor = NSColor.clear.cgColor; border.lineWidth = 1.5
        layer?.addSublayer(border)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("OpenCode，点击打开")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { Self.blockSize }
    @objc private func tapped() { onTap?() }

    private func updateBorder() {
        border.removeAnimation(forKey: "breathe")
        border.strokeColor = (displayState.activity == .unread ? NSColor.systemRed : NSColor(calibratedRed: 0.55, green: 0.8, blue: 1, alpha: 1)).cgColor
        border.opacity = displayState.activity == .idle ? 0 : displayState.activity == .unread ? 0.9 : 0.5
        if displayState.activity == .running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.2; animation.toValue = 0.65; animation.duration = 1.6
            animation.autoreverses = true; animation.repeatCount = .infinity
            border.add(animation, forKey: "breathe")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        Self.icon?.draw(in: NSRect(x: 12, y: 4, width: 22, height: 22))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        (displayState.model as NSString).draw(in: NSRect(x: 43, y: 15, width: 143, height: 14), withAttributes: attributes)
        ("OpenCode · \(displayState.location)" as NSString).draw(in: NSRect(x: 43, y: 1, width: 143, height: 14), withAttributes: attributes)
    }
}

final class OpenCodeMonitor {
    var onChange: ((OpenCodeState) -> Void)?
    private var timer: Timer?
    private var state = OpenCodeState()
    private var wasRunning = false

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func activate() {
        guard let pid = state.hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    private func output(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath); process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func poll() {
        guard let raw = output("/usr/bin/pgrep", ["-x", "opencode"]), let pid = pid_t(raw.split(separator: "\n").first ?? "") else {
            publish(OpenCodeState()); wasRunning = false; return
        }
        let cwd = output("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])?.split(separator: "\n").first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) } ?? ""
        let host = hostApp(startingAt: pid)
        let model = latestModel(in: cwd)
        let running = latestAssistantRunning(in: cwd)
        let hostActive = host.pid.flatMap(NSRunningApplication.init(processIdentifier:))?.isActive == true
        let activity: TaskActivity = running ? .running : (wasRunning && !hostActive ? .unread : (state.activity == .unread && !hostActive ? .unread : .idle))
        wasRunning = running
        publish(OpenCodeState(visible: true, model: model, location: host.name, activity: activity, hostPID: host.pid))
    }

    private func hostApp(startingAt pid: pid_t) -> (name: String, pid: pid_t?) {
        var current = pid
        for _ in 0..<12 {
            guard let line = output("/bin/ps", ["-p", "\(current)", "-o", "ppid="]), let parent = pid_t(line) else { break }
            if let app = NSRunningApplication(processIdentifier: parent), let bundle = app.bundleIdentifier {
                if bundle == "com.microsoft.VSCode" || bundle.hasPrefix("com.microsoft.VSCode") { return ("VS Code", parent) }
                if bundle == "com.apple.Terminal" { return ("系统终端", parent) }
            }
            current = parent
        }
        return ("系统终端", nil)
    }

    private func sql(_ cwd: String, expression: String) -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        let escaped = cwd.replacingOccurrences(of: "'", with: "''")
        return output("/usr/bin/sqlite3", [path, "SELECT \(expression) FROM message m JOIN session s ON s.id=m.session_id WHERE s.directory='\(escaped)' ORDER BY m.time_created DESC LIMIT 1;"]) ?? ""
    }
    private func latestModel(in cwd: String) -> String {
        sql(cwd, expression: "COALESCE(json_extract(m.data,'$.model.modelID'),json_extract(m.data,'$.modelID'),s.model,'--')")
    }
    private func latestAssistantRunning(in cwd: String) -> Bool {
        sql(cwd, expression: "CASE WHEN json_extract(m.data,'$.role')='assistant' AND json_extract(m.data,'$.time.completed') IS NULL THEN '1' ELSE '0' END") == "1"
    }
    private func publish(_ next: OpenCodeState) {
        guard next != state else { return }; state = next; onChange?(next)
    }
}

func openCodeSelfTest() {
    precondition(OpenCodeState(visible: true, model: "k3", location: "VS Code", activity: .running, hostPID: 1).location == "VS Code")
    print("PASS: OpenCode state model")
}
