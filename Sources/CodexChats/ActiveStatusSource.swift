import Foundation
import Darwin
import CSQLite

struct ActiveDiscovery {
    let metadata: [String: String]
    let candidates: [String: Int]
    let terminal: [(String, String, Double)]
    static func read(home: URL, receipts: [String: ActiveLifecycle.Receipt]) throws -> ActiveDiscovery {
        let metadata: [String: String] = try readOnly(home.appendingPathComponent("state_5.sqlite")) { db in
            let children = Set(try ChatStore.rows(db, "SELECT child_thread_id FROM thread_spawn_edges").compactMap { $0["child_thread_id"]?.string })
            var result = [String: String]()
            for row in try ChatStore.rows(db, "SELECT id,name,title,source,thread_source FROM threads") {
                guard let id = row["id"]?.string, !id.isEmpty, !children.contains(id), row["thread_source"]?.string != "subagent" else { continue }
                if let source = row["source"]?.string, let raw = source.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], object["subagent"] != nil { continue }
                result[id] = [row["name"]?.string, row["title"]?.string].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Untitled chat"
            }
            return result
        }
        return try readOnly(home.appendingPathComponent("thread_history_1.sqlite")) { db in
            var candidates = [String: Int](), terminal = [(String, String, Double)]()
            for row in try ChatStore.rows(db, "SELECT thread_id,max(rollout_ordinal) AS ordinal FROM thread_turns WHERE status IN ('inProgress','running') GROUP BY thread_id") {
                if let id = row["thread_id"]?.string, metadata[id] != nil, case .integer(let ordinal)? = row["ordinal"], let value = Int(exactly: ordinal) { candidates[id] = value }
            }
            for (id, receipt) in receipts where ["working", "waiting"].contains(ActiveLifecycle.status(receipt.state)) {
                guard let turn = receipt.latestTurnID else { continue }
                let rows = try ChatStore.rows(db, "SELECT status,completed_at FROM thread_turns WHERE thread_id=? AND turn_id=?", bindings: [id, turn])
                if let row = rows.first, ["completed", "failed", "interrupted"].contains(row["status"]?.string ?? ""), let time = row["completed_at"]?.number, time.isFinite { terminal.append((id, turn, time)) }
            }
            return ActiveDiscovery(metadata: metadata, candidates: candidates, terminal: terminal)
        }
    }
    private static func readOnly<T>(_ url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }; throw StoreError(message: "Local activity metadata unavailable.")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw StoreError(message: "Activity source is not read-only.") }
        sqlite3_busy_timeout(db, 150)
        let budget = Unmanaged.passRetained(NSNumber(value: ProcessInfo.processInfo.systemUptime + 0.5))
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<NSNumber>.fromOpaque(pointer).takeUnretainedValue().doubleValue < ProcessInfo.processInfo.systemUptime ? 1 : 0
        }, budget.toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); budget.release() }
        try ChatStore.execute(db, "PRAGMA query_only=ON"); try ChatStore.execute(db, "BEGIN")
        defer { try? ChatStore.execute(db, "ROLLBACK") }
        return try body(db)
    }
}

final class ActiveStatusSource {
    private let queue = DispatchQueue(label: "explorer.active-status", qos: .utility, autoreleaseFrequency: .workItem)
    private let key = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var reader: DispatchSourceRead?
    private var socket: Int32 = -1
    private var clientID: String?
    private var received = ActiveFrameBuffer()
    private var followed = Set<String>()
    private var lifecycle = ActiveLifecycle()
    private var retryAt: TimeInterval = 0
    private var connectedAt: TimeInterval = 0
    private var discoverAt: TimeInterval = 0
    private var publishAt: TimeInterval = 0
    private var sequence = 0
    private var bytesReceived = 0
    private var queryMs = 0.0
    private let home: URL
    private var stopped = true
    private let deliveryLock = NSLock()
    private var deliveryGeneration = 0
    private var lastEmission: Double = 0
    private var lastRows = [ActiveChatRow]()
    private var lastConnected = false
    private var lastWarning = ""
    private var lastPending = -1
    var onSnapshot: ((ActiveSnapshot) -> Void)?
    var onFailure: ((String) -> Void)?
    init(home: URL = ChatStore.defaultURL.deletingLastPathComponent()) {
        self.home = home; queue.setSpecific(key: key, value: true)
    }
    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.stopped = false; self.retryAt = 0; self.discoverAt = 0; self.lastEmission = 0
            self.deliveryLock.lock(); self.deliveryGeneration += 1; self.deliveryLock.unlock()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in autoreleasepool { self?.step() } }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        let cleanup = {
            self.deliveryLock.lock(); self.deliveryGeneration += 1; self.deliveryLock.unlock()
            self.stopped = true; self.timer?.setEventHandler {}; self.timer?.cancel(); self.timer = nil
            self.disconnect("Stopped", retry: false)
        }
        if DispatchQueue.getSpecific(key: key) == true { cleanup() } else { queue.sync(execute: cleanup) }
    }
    deinit { stop() }
    private func step() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if socket < 0, now >= retryAt { connect() }
        if socket >= 0, clientID == nil, now - connectedAt > 3 { disconnect("Codex did not complete the observer handshake.") }
        if now >= discoverAt {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let found = try ActiveDiscovery.read(home: home, receipts: lifecycle.receipts)
                lifecycle.metadata = found.metadata; lifecycle.candidates = found.candidates
                lifecycle.discovered.formIntersection(found.metadata.keys)
                lifecycle.receipts = lifecycle.receipts.filter { found.metadata[$0.key] != nil }
                lifecycle.suppressed = lifecycle.suppressed.filter { found.metadata[$0.key] != nil }
                for (id, turn, time) in found.terminal {
                    if lifecycle.reconcileTerminal(id, turnID: turn, completedAt: time, now: Date().timeIntervalSince1970) { follow(id, force: true) }
                }
                if lifecycle.warning.hasPrefix("Metadata unavailable") { lifecycle.warning = "" }
                synchronizeFollowing()
            } catch { lifecycle.warning = "Metadata unavailable; live coverage may be incomplete." }
            queryMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
            discoverAt = now + 5
        }
        if now >= publishAt { publish(); publishAt = now + 2 }
    }
    private func connect() {
        let path = home.appendingPathComponent("ipc/ipc.sock").path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), path.utf8.count < 104 else {
            disconnect("Codex desktop connection unavailable."); return
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { disconnect("Cannot open local Codex connection."); return }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: Array(path.utf8) + [0])
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); disconnect("Codex desktop connection unavailable."); return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        socket = fd; connectedAt = ProcessInfo.processInfo.systemUptime
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in autoreleasepool { self?.receive() } }
        source.setCancelHandler { close(fd) }
        reader = source; source.resume()
        send(["type": "request", "requestId": UUID().uuidString, "method": "initialize", "version": 0,
              "params": ["clientType": "codex-chat-explorer-observer"]])
    }
    private func disconnect(_ reason: String, retry: Bool = true) {
        if let reader { reader.setEventHandler {}; reader.cancel(); self.reader = nil }
        else if socket >= 0 { close(socket) }
        socket = -1; clientID = nil; received = ActiveFrameBuffer(); followed.removeAll()
        lifecycle.disconnected(reason); retryAt = ProcessInfo.processInfo.systemUptime + (retry ? 5 : .infinity)
        if !stopped { publish() }
    }
    private func send(_ object: [String: Any]) {
        guard socket >= 0, let raw = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(raw.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(raw)
        let count = frame.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
        if count != frame.count { disconnect("Codex observer connection interrupted.") }
    }
    private func follow(_ id: String, force: Bool = false) {
        guard let clientID, socket >= 0, force || !followed.contains(id) else { return }
        let base: [String: Any] = ["hostId": "local", "conversationId": id]
        if force {
            send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1, "sourceClientId": clientID,
                  "params": base.merging(["following": false]) { _, last in last }])
        }
        send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1, "sourceClientId": clientID,
              "params": base.merging(["following": true]) { _, last in last }])
        if socket >= 0 { followed.insert(id) }
    }
    private func synchronizeFollowing() {
        guard let clientID else { return }
        let targets = lifecycle.targets
        for id in followed.subtracting(targets) {
            send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1, "sourceClientId": clientID,
                  "params": ["hostId": "local", "conversationId": id, "following": false]])
            followed.remove(id); lifecycle.receipts.removeValue(forKey: id)
        }
        for id in targets { follow(id) }
    }
    private func receive() {
        guard socket >= 0 else { return }
        defer { received.compact() }
        var chunk = [UInt8](repeating: 0, count: 65_536), readBytes = 0
        while readBytes < 2 * 1024 * 1024 {
            let count = Darwin.read(socket, &chunk, chunk.count)
            if count < 0 { if errno == EAGAIN || errno == EWOULDBLOCK { break }; disconnect("Codex observer disconnected."); return }
            if count == 0 { disconnect("Codex disconnected; previous activity is unconfirmed."); return }
            bytesReceived += count; readBytes += count
            do {
                try received.append(Data(chunk.prefix(count)))
                while try autoreleasepool(invoking: { () throws -> Bool in
                    guard let raw = try received.next() else { return false }
                    handle(try ActiveJSONReader.decode(raw, clientID: clientID))
                    return true
                }) {
                    if socket < 0 { return }
                }
            } catch { disconnect("Malformed or oversized Codex runtime stream; statuses unconfirmed."); return }
        }
    }
    private func handle(_ message: [String: Any]) {
        if message["type"] as? String == "client-discovery-request", let request = message["requestId"] {
            send(["type": "client-discovery-response", "requestId": request, "response": ["canHandle": false]]); return
        }
        if message["type"] as? String == "response", message["method"] as? String == "initialize" {
            guard let result = message["result"] as? [String: Any], let client = result["clientId"] as? String else {
                disconnect("Codex rejected the observer handshake."); return
            }
            clientID = client; lifecycle.warning = ""; synchronizeFollowing(); publish(); return
        }
        guard let clientID, message["type"] as? String == "broadcast", let method = message["method"] as? String,
              ["client-status-changed", "ipc-connection-reset", "thread-stream-following-changed", "thread-stream-following-status-requested", "thread-stream-state-changed"].contains(method) else { return }
        let refresh = lifecycle.message(message, clientID: clientID, now: Date().timeIntervalSince1970)
        for id in refresh { follow(id, force: lifecycle.receipts[id]?.awaitingSnapshot == true) }
        synchronizeFollowing()
        publish()
    }
    private func publish() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let rows = lifecycle.rows(connected: clientID != nil)
        let pending = lifecycle.targets.subtracting(lifecycle.receipts.keys).count
        guard now - lastEmission >= 0.25 else { return }
        guard rows != lastRows || (clientID != nil) != lastConnected || lifecycle.warning != lastWarning || pending != lastPending || now - lastEmission >= 2 else { return }
        lastEmission = now; lastRows = rows; lastConnected = clientID != nil; lastWarning = lifecycle.warning; lastPending = pending
        sequence += 1
        let snapshot = ActiveSnapshot(connected: clientID != nil, sequence: sequence,
            observedAt: Date().timeIntervalSince1970, rows: rows, pending: pending, warning: lifecycle.warning,
            queryMs: queryMs, bytesReceived: bytesReceived)
        deliveryLock.lock(); let generation = deliveryGeneration; deliveryLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock(); let current = self.deliveryGeneration == generation; self.deliveryLock.unlock()
            if current { self.onSnapshot?(snapshot) }
        }
    }
}
