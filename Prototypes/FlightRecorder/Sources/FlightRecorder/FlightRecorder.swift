import Foundation
import Darwin

/// Application-local diagnostics. Never accesses source chats or installs crash/signal handlers.
public final class FlightRecorder: @unchecked Sendable {
    public let identity: RecorderIdentity
    public let configuration: RecorderConfiguration
    public let root: URL
    public let sessionURL: URL
    private let mutex = NSLock()
    private let worker = DispatchQueue(label:"explorer.flight-recorder",qos:.utility,autoreleaseFrequency:.workItem)
    private var pending = [DiagnosticRecord]()
    private var state = RecorderStatus()
    private var accepting = true, scheduled = false
    private var rateWindow: UInt64 = 0
    private var rateUsed = 0, criticalUsed = 0
    // The following are worker-confined.
    private var fd: Int32 = -1, sessionLock: Int32 = -1
    private var segment = 0, size = 0, recordsInSegment: UInt64 = 0
    private var retained = [(url:URL,bytes:Int,records:UInt64)]()
    private var timer: DispatchSourceTimer?
    private var lastSync: UInt64 = 0
    private let encoder = JSONEncoder()
    private let coverage: [String]
    private let analysisTool: URL?

    public init(root: URL, identity: RecorderIdentity, configuration: RecorderConfiguration = .init(), coverage: [String] = [], analysisTool: URL? = nil) {
        self.root = root; self.identity = identity; self.configuration = configuration.validated(); self.analysisTool = analysisTool
        self.coverage = Array(coverage.prefix(64)).map { String($0.prefix(200)) }
        sessionURL = root.appendingPathComponent(identity.session,isDirectory:true)
        worker.async { [self] in
            do {
                try RecorderFiles.directory(root); try RecorderFiles.directory(sessionURL)
                sessionLock = try RecorderFiles.openFile(sessionURL.appendingPathComponent("session.lock"),flags:O_RDWR | O_CREAT | O_EXCL)
                guard flock(sessionLock,LOCK_EX | LOCK_NB) == 0 else { throw RecorderFailure(code:errno) }
                try RecorderFiles.atomic(SessionManifest(schema:1,identity:identity,configuration:self.configuration,coverage:self.coverage),to:sessionURL.appendingPathComponent("session.json"))
                try openSegment()
                _ = try RecorderRetention.apply(root:root,configuration:self.configuration)
                let t = DispatchSource.makeTimerSource(queue:worker)
                t.schedule(deadline:.now()+self.configuration.syncInterval,repeating:self.configuration.syncInterval,leeway:.milliseconds(100))
                t.setEventHandler { [weak self] in self?.checkpoint() }
                timer = t; t.resume()
            } catch { fail(error, lost:0) }
        }
        record("session.start", critical:true)
    }
    deinit {
        timer?.cancel()
        if fd >= 0 { Darwin.close(fd) }
        if sessionLock >= 0 { flock(sessionLock,LOCK_UN); Darwin.close(sessionLock) }
    }
    public var status: RecorderStatus {
        mutex.lock(); defer { mutex.unlock() }
        var s = state; s.pending = pending.count; return s
    }
    /// O(maxFields * maxStringBytes); no disk I/O, formatting, dispatch-sync or unbounded task allocation.
    @discardableResult public func record(_ event: String, operation: String? = nil, fields: [String:DiagnosticValue] = [:], critical: Bool = false) -> Bool {
        mutex.lock()
        guard accepting else { state.rejectedAfterClose += 1; mutex.unlock(); return false }
        state.attempted += 1
        guard !state.disabled else { state.lostIO += 1; mutex.unlock(); return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - rateWindow >= 1_000_000_000 { rateWindow = now; rateUsed = 0; criticalUsed = 0 }
        if critical ? criticalUsed >= 64 : rateUsed >= configuration.maxEventsPerSecond { state.droppedRate += 1; mutex.unlock(); return false }
        let capacity = critical ? configuration.maxPending : configuration.maxPending - max(1,configuration.maxPending/8)
        guard pending.count < capacity else { state.droppedQueue += 1; mutex.unlock(); return false }
        if critical { criticalUsed += 1 } else { rateUsed += 1 }
        var bounded = [String:DiagnosticValue]()
        var truncated: UInt64 = UInt64(max(0, fields.count - configuration.maxFields))
        for (key,value) in fields.prefix(configuration.maxFields) {
            // Reject long keys instead of truncating into a colliding identity.
            guard key.utf8.prefix(65).count <= 64 else { truncated += 1; continue }
            if case .text(let text) = value {
                let bytes = Array(text.utf8.prefix(configuration.maxStringBytes+1))
                if bytes.count > configuration.maxStringBytes { truncated += 1 }
                bounded[key] = .text(String(decoding:bytes.prefix(configuration.maxStringBytes),as:UTF8.self))
            } else { bounded[key] = value }
        }
        state.truncatedFields += truncated
        if truncated > 0 { bounded["recorder_truncated_fields"] = .integer(Int64(truncated)) }
        pending.append(DiagnosticRecord(schema:1,session:identity.session,sequence:state.attempted,
            wallTime:Date().timeIntervalSince1970,uptimeNS:DispatchTime.now().uptimeNanoseconds,
            event:String(decoding:event.utf8.prefix(96),as:UTF8.self),operation:operation.map{String(decoding:$0.utf8.prefix(80),as:UTF8.self)},fields:bounded))
        state.highWater = max(state.highWater,pending.count)
        if !scheduled { scheduled = true; worker.async { [weak self] in self?.drain() } }
        mutex.unlock(); return true
    }
    @discardableResult public func begin(_ event: String, fields: [String:DiagnosticValue] = [:], critical: Bool = false) -> DiagnosticOperation {
        let op = DiagnosticOperation(); record(event+".begin",operation:op.id,fields:fields,critical:critical); return op
    }
    public func end(_ event: String, _ op: DiagnosticOperation, fields: [String:DiagnosticValue] = [:], critical: Bool = false) {
        var f = fields; f["duration_ms"] = .number(op.elapsedMS); record(event+".end",operation:op.id,fields:f,critical:critical)
    }
    private func takePending() -> [DiagnosticRecord] {
        mutex.lock(); defer { mutex.unlock() }
        let batch = pending; pending.removeAll(keepingCapacity:true); return batch
    }
    private func drain() {
        write(takePending())
        mutex.lock()
        if pending.isEmpty { scheduled = false } else { worker.async { [weak self] in self?.drain() } }
        mutex.unlock()
    }
    private func write(_ batch: [DiagnosticRecord]) {
        for (index,record) in batch.enumerated() {
            if status.disabled { mutex.lock(); state.lostIO += UInt64(batch.count-index); mutex.unlock(); return }
            let data: Data
            do { var d = try encoder.encode(record); d.append(10); data = d }
            catch { mutex.lock(); state.encodingFailures += 1; mutex.unlock(); continue }
            guard data.count <= 16384 else { mutex.lock(); state.encodingFailures += 1; mutex.unlock(); continue }
            do {
                if size + data.count > configuration.segmentBytes { try rotate() }
                try RecorderFiles.write(data,to:fd); size += data.count; recordsInSegment += 1
                mutex.lock(); state.written += 1; state.lastWrittenSequence = record.sequence; mutex.unlock()
            } catch { fail(error,lost:UInt64(batch.count-index)); return }
        }
    }
    private func openSegment() throws {
        let url = sessionURL.appendingPathComponent(String(format:"events-%010d.jsonl",segment))
        fd = try RecorderFiles.openFile(url,flags:O_WRONLY | O_CREAT | O_EXCL)
        size = 0; recordsInSegment = 0
    }
    private func rotate() throws {
        guard fsync(fd) == 0 else { throw RecorderFailure(code:errno) }
        Darwin.close(fd); fd = -1
        retained.append((sessionURL.appendingPathComponent(String(format:"events-%010d.jsonl",segment)),size,recordsInSegment))
        // Remove before opening another segment, enforcing the per-session byte bound.
        while retained.count >= configuration.segments {
            let old = retained.removeFirst()
            mutex.lock(); state.pendingRotation = old.url.lastPathComponent; mutex.unlock()
            try RecorderFiles.atomic(status,to:sessionURL.appendingPathComponent("status.json"))
            try FileManager.default.removeItem(at:old.url)
            mutex.lock(); state.rotatedBytes += UInt64(old.bytes); state.rotatedRecords += old.records; state.pendingRotation = nil; mutex.unlock()
            try RecorderFiles.atomic(status,to:sessionURL.appendingPathComponent("status.json"))
        }
        segment += 1; try openSegment()
    }
    private func fail(_ error: Error,lost: UInt64) {
        mutex.lock(); state.disabled = true; state.ioFailures += 1; state.lostIO += lost
        state.lastErrorCode = (error as? RecorderFailure)?.code ?? Int32((error as NSError).code); mutex.unlock()
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        // One bounded best-effort failure receipt; never recurse or retry indefinitely.
        try? RecorderFiles.atomic(status,to:sessionURL.appendingPathComponent("status.json"))
    }
    private func checkpoint(forceFailureReceipt: Bool = false) {
        guard !status.disabled else {
            if forceFailureReceipt { try? RecorderFiles.atomic(status,to:sessionURL.appendingPathComponent("status.json")) }; return
        }
        do {
            if fd >= 0 { guard fsync(fd) == 0 else { throw RecorderFailure(code:errno) } }
            lastSync = DispatchTime.now().uptimeNanoseconds
            try RecorderFiles.atomic(status,to:sessionURL.appendingPathComponent("status.json"))
        } catch { fail(error,lost:0) }
    }
    /// Completion is off the main thread. A timeout never claims the records were flushed.
    public func flush(completion: @escaping @Sendable (RecorderStatus) -> Void) {
        worker.async { [self] in write(takePending()); checkpoint(forceFailureReceipt:true); completion(status) }
    }
    @discardableResult public func flush(timeout: TimeInterval) -> Bool {
        let signal = DispatchSemaphore(value:0); flush { _ in signal.signal() }
        return signal.wait(timeout:.now()+(timeout.isFinite ? min(10,max(0,timeout)) : 0)) == .success && !status.disabled
    }
    public func close(completion: @escaping @Sendable (RecorderStatus) -> Void) {
        record("session.end", critical:true)
        mutex.lock(); accepting = false; mutex.unlock()
        worker.async { [self] in
            timer?.cancel(); timer = nil; write(takePending()); checkpoint(forceFailureReceipt:true)
            if !status.disabled {
                do {
                    var final = status; final.cleanShutdown = true
                    try RecorderFiles.atomic(final,to:sessionURL.appendingPathComponent("closed.json"))
                    mutex.lock(); state.cleanShutdown = true; mutex.unlock()
                } catch { fail(error,lost:0) }
            }
            if fd >= 0 { Darwin.close(fd); fd = -1 }
            if sessionLock >= 0 { flock(sessionLock,LOCK_UN); Darwin.close(sessionLock); sessionLock = -1 }
            completion(status)
        }
    }
    @discardableResult public func close(timeout: TimeInterval) -> Bool {
        let signal = DispatchSemaphore(value:0); close { _ in signal.signal() }
        return signal.wait(timeout:.now()+(timeout.isFinite ? min(10,max(0,timeout)) : 0)) == .success && status.cleanShutdown
    }
    /// Serializes with this recorder's writes. Other live instances are omitted, explicitly.
    public func export(to destination: URL, completion: @escaping @Sendable (Result<URL,Error>) -> Void) {
        worker.async { [self] in
            write(takePending()); checkpoint(forceFailureReceipt:true)
            completion(Result { try DiagnosticBundle.export(root:root,currentSession:identity.session,to:destination,analysisTool:analysisTool,currentSequence:status.lastWrittenSequence) })
        }
    }
}
