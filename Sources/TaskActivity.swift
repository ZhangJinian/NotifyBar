import AppKit
import Darwin

enum TaskActivity: String {
    case idle, running, unread
    static func resolve(running: Bool, unread: Bool) -> Self { unread ? .unread : running ? .running : .idle }
}

struct TaskStatus {
    var revision: Int
    var running: Bool
    var owner: String
    var id: String
    var host: String
    var updatedAt: Double

    mutating func apply(_ change: [String: Any]) -> Bool {
        guard let next = change["revision"] as? Int else { return false }
        if change["type"] as? String == "snapshot", let state = change["conversationState"] as? [String: Any] {
            running = (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "active"
            updatedAt = (state["updatedAt"] as? NSNumber)?.doubleValue ?? updatedAt
        } else if change["type"] as? String == "patches", change["baseRevision"] as? Int == revision,
                  let patches = change["patches"] as? [[String: Any]] {
            for patch in patches {
                let path = patch["path"] as? [Any] ?? []
                if path.isEmpty, let state = patch["value"] as? [String: Any] {
                    running = (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "active"
                } else if path.first as? String == "threadRuntimeStatus" {
                    if path.count == 1 { running = (patch["value"] as? [String: Any])?["type"] as? String == "active" }
                    else if path.count == 2, path[1] as? String == "type" { running = patch["value"] as? String == "active" }
                }
            }
        } else { return false }
        revision = next
        return true
    }
}

struct TaskOpenTarget: Equatable {
    let id: String
    let host: String
}

enum TaskLauncher {
    static func url(for target: TaskOpenTarget, vscode: Bool) -> URL? {
        let value = vscode && target.host == "local"
            ? "vscode://codex/local/\(target.id)"
            : "codex://threads/\(target.id)" + (target.host == "local" ? "" : "?hostId=\(target.host)")
        return URL(string: value)
    }

    static func open(_ target: TaskOpenTarget?) {
        guard let target else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                configuration: .init(), completionHandler: nil)
            return
        }
        guard let url = preferredURL(for: target) else { return }
        NSWorkspace.shared.open(url)
    }

    static func preferredURL(for target: TaskOpenTarget) -> URL? {
        url(for: target, vscode: isVSCodeThread(target.id))
    }

    private static func isVSCodeThread(_ id: String) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User")
        let needle = Data("openai-codex://route/local/\(id)".utf8)
        let global = root.appendingPathComponent("globalStorage/state.vscdb")
        if let data = try? Data(contentsOf: global), data.range(of: needle) != nil { return true }
        guard let files = FileManager.default.enumerator(at: root.appendingPathComponent("workspaceStorage"),
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in files where file.lastPathComponent == "state.vscdb" {
            if let data = try? Data(contentsOf: file), data.range(of: needle) != nil { return true }
        }
        return false
    }
}

// Read-only desktop IPC follower: retains runtime flags, never conversation text.
final class TaskActivityMonitor {
    var onChange: ((TaskActivity) -> Void)?
    private let queue = DispatchQueue(label: "mytouchbar.activity", qos: .utility)
    private let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    private var timer: DispatchSourceTimer?
    private var socketHandle: FileHandle?
    private var buffer = Data()
    private var clientID: String?
    private var subscribed = Set<String>()
    private var statuses: [String: TaskStatus] = [:]
    private var unreadKeys = Set<String>()
    private var current: TaskActivity = .idle

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }
    func stop() { queue.sync { timer?.cancel(); timer = nil; disconnect() } }

    func openBestTask() {
        queue.async {
            let unread = self.statuses.values.filter { self.unreadKeys.contains("\($0.host):\($0.id)") }
            let target = (unread.max { $0.updatedAt < $1.updatedAt }
                ?? self.statuses.values.filter(\.running).max { $0.updatedAt < $1.updatedAt })
                .map { TaskOpenTarget(id: $0.id, host: $0.host) }
            DispatchQueue.main.async { TaskLauncher.open(target) }
        }
    }

    private func disconnect() {
        socketHandle?.readabilityHandler = nil
        try? socketHandle?.close()
        socketHandle = nil; clientID = nil; buffer.removeAll(); subscribed.removeAll(); statuses.removeAll()
        publish()
    }

    private func connect() {
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strcpy($0, path) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        socketHandle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                guard let self, self.socketHandle === handle else { return }
                if data.isEmpty { self.disconnect() } else { self.consume(data) }
            }
        }
        send(["type": "request", "method": "initialize", "requestId": UUID().uuidString,
              "version": 0, "params": ["clientType": "mytouchbar"]])
    }

    private func send(_ message: [String: Any]) {
        guard let socketHandle else { return }
        do {
            let body = try JSONSerialization.data(withJSONObject: message)
            var size = UInt32(body.count).littleEndian
            var frame = withUnsafeBytes(of: &size) { Data($0) }
            frame.append(body)
            try socketHandle.write(contentsOf: frame)
        } catch { disconnect() }
    }

    private func subscribe(_ key: String) {
        guard let clientID, key.count > 37 else { return }
        let thread = String(key.suffix(36)), host = String(key.dropLast(37))
        guard UUID(uuidString: thread) != nil, !host.isEmpty else { return }
        subscribed.insert(key)
        send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
              "sourceClientId": clientID, "params": ["conversationId": thread, "hostId": host, "following": true]])
    }

    private func poll() {
        if socketHandle == nil { connect() }
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atoms = state["electron-persisted-atom-state"] as? [String: Any] else { return }
        if let byHost = atoms["unread-thread-ids-by-host-v1"] as? [String: [String]] {
            unreadKeys = Set(byHost.flatMap { host, ids in ids.map { "\(host):\($0)" } })
        }
        for key in atoms.keys where key.hasPrefix("thread-client-id-v1:") {
            let threadKey = String(key.dropFirst("thread-client-id-v1:".count)).removingPercentEncoding ?? ""
            if !subscribed.contains(threadKey) { subscribe(threadKey) }
        }
        publish()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let size = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            // Same 256 MiB frame ceiling as desktop IPC; reconnect on corrupt frames.
            guard size > 0, size <= 268_435_456 else { disconnect(); return }
            guard buffer.count >= size + 4 else { return }
            let body = Data(buffer.dropFirst(4).prefix(size))
            buffer.removeFirst(size + 4)
            guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { disconnect(); return }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if message["type"] as? String == "client-discovery-request", let id = message["requestId"] {
            send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            return
        }
        if message["method"] as? String == "initialize", let result = message["result"] as? [String: Any] {
            clientID = result["clientId"] as? String; poll(); return
        }
        guard message["type"] as? String == "broadcast", let params = message["params"] as? [String: Any] else { return }
        let source = message["sourceClientId"] as? String ?? ""
        switch message["method"] as? String {
        case "client-status-changed":
            if params["status"] as? String == "disconnected" { statuses = statuses.filter { $0.value.owner != source } }
            else { subscribed.removeAll(); poll() }
        case "thread-stream-state-changed":
            guard message["version"] as? Int == 11, let host = params["hostId"] as? String,
                  let id = params["conversationId"] as? String, let change = params["change"] as? [String: Any] else { return }
            let key = "\(host):\(id)"
            var status = statuses[key] ?? TaskStatus(revision: -1, running: false, owner: source,
                id: id, host: host, updatedAt: 0)
            status.owner = source
            if status.apply(change) { statuses[key] = status } else { subscribe(key) }
        case "thread-read-state-changed": poll()
        case "thread-stream-following-changed":
            if let host = params["hostId"] as? String, let id = params["conversationId"] as? String {
                let key = "\(host):\(id)"
                if !subscribed.contains(key) { subscribe(key) }
            }
        default: break
        }
        publish()
    }

    private func publish() {
        let value = TaskActivity.resolve(running: statuses.values.contains(where: { $0.running }), unread: !unreadKeys.isEmpty)
        guard value != current else { return }
        current = value
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }
}

func activitySelfTest() {
    precondition(TaskActivity.resolve(running: true, unread: true) == .unread)
    precondition(TaskActivity.resolve(running: true, unread: false) == .running)
    precondition(TaskActivity.resolve(running: false, unread: false) == .idle)
    precondition(TaskLauncher.url(for: .init(id: "00000000-0000-4000-8000-000000000001", host: "local"), vscode: true)?.absoluteString
        == "vscode://codex/local/00000000-0000-4000-8000-000000000001")
    precondition(TaskLauncher.url(for: .init(id: "00000000-0000-4000-8000-000000000001", host: "local"), vscode: false)?.absoluteString
        == "codex://threads/00000000-0000-4000-8000-000000000001")
    var status = TaskStatus(revision: -1, running: false, owner: "test",
        id: "00000000-0000-4000-8000-000000000001", host: "local", updatedAt: 0)
    precondition(status.apply(["type": "snapshot", "revision": 1, "conversationState": ["threadRuntimeStatus": ["type": "active"]]]))
    precondition(status.running)
    precondition(status.apply(["type": "patches", "baseRevision": 1, "revision": 2,
        "patches": [["path": ["threadRuntimeStatus", "type"], "value": "idle"]]]))
    precondition(!status.running)
    precondition(!status.apply(["type": "patches", "baseRevision": 0, "revision": 3, "patches": []]))
    precondition(status.apply(["type": "patches", "baseRevision": 2, "revision": 4,
        "patches": [["path": ["threadRuntimeStatus"], "value": ["type": "active"]]]]))
    precondition(status.running)
    print("PASS: live task state, revision recovery, Codex and VS Code task links")
}
