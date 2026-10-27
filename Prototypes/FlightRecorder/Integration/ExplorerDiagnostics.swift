import AppKit
@_exported import FlightRecorder

/// The bridge owns only Explorer observations. Starting it is explicit in the ordinary app launch path.
public final class ExplorerDiagnostics: NSObject, @unchecked Sendable {
    public static let shared = ExplorerDiagnostics()
    private let lock = NSLock()
    private var instance: FlightRecorder?
    private var observers = [NSObjectProtocol]()
    private var timer: DispatchSourceTimer?
    private let sampling = DispatchQueue(label:"explorer.diagnostic-sampling",qos:.utility)
    private var awaitingMain: UInt64?
    private var recent = [String:UInt64]() // main-thread confined, capped
    private var exporting = false
    public var captureView: (() -> [String:DiagnosticValue])?
    public var recorder: FlightRecorder? { lock.lock(); defer { lock.unlock() }; return instance }
    private static func critical(_ name: String) -> Bool { name.hasPrefix("navigation.") || name.hasPrefix("window.fullscreen.") || name.hasSuffix(".error") }
    public static func event(_ name: String, operation: String? = nil, _ fields: [String:DiagnosticValue] = [:]) {
        shared.recorder?.record(name,operation:operation,fields:fields,critical:critical(name))
    }
    public static func begin(_ name: String, _ fields: [String:DiagnosticValue] = [:]) -> DiagnosticOperation? { shared.recorder?.begin(name,fields:fields,critical:critical(name)) }
    public static func end(_ name: String, _ operation: DiagnosticOperation?, _ fields: [String:DiagnosticValue] = [:]) {
        guard let operation else { return }; shared.recorder?.end(name,operation,fields:fields,critical:critical(name))
    }
    public static func error(_ error: Error) -> [String:DiagnosticValue] {
        let e = error as NSError; return ["error_domain":.text(e.domain),"error_code":.integer(Int64(e.code))]
    }
    public static func rect(_ rect: CGRect, prefix: String) -> [String:DiagnosticValue] {
        [prefix+"_x":.number(rect.origin.x),prefix+"_y":.number(rect.origin.y),prefix+"_w":.number(rect.size.width),prefix+"_h":.number(rect.size.height)]
    }
    public func start(root override: URL? = nil) {
        guard Thread.isMainThread, recorder == nil else { return }
        let bundle = Bundle.main
        let root = override ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CodexChatExplorer/Diagnostics",isDirectory:true)
        let identity = RecorderIdentity(bundleID:bundle.bundleIdentifier ?? "unbundled-explorer",version:bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development",build:bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unrecorded",revision:bundle.object(forInfoDictionaryKey:"ExplorerSourceRevision") as? String ?? "unrecorded",sourceDirty:bundle.object(forInfoDictionaryKey:"ExplorerSourceDirty") as? Bool)
        let recorder = FlightRecorder(root:root,identity:identity,coverage:[
            "app launch, activation and graceful termination", "window geometry and native full-screen notifications",
            "view changes, reader open/back, viewport and cursor-region reset snapshots",
            "metadata refresh queue/read/apply; reader page queue/read/render/stale result",
            "canvas index/message queue/read/HTML preparation/cache hit/miss/stale result",
            "own-process CPU totals, resident memory and thread count every 5 seconds",
            "main queue response delay: one outstanding probe, every 5 seconds",
            "Excluded: transcript/title/search text, source paths, credentials, other processes, network telemetry",
            "Not instrumented: GPU, individual SQL queries, WebKit paint completion, model worker internals, legacy view stage timings",
            "No crash handler; queued tail may be lost. Unclosed session is not a crash diagnosis."
        ], analysisTool:Bundle.main.url(forResource:"diagnostics",withExtension:"py"))
        lock.lock(); instance = recorder; lock.unlock()
        let names: [(Notification.Name,String)] = [
            (NSWindow.willEnterFullScreenNotification,"window.fullscreen.will_enter"),(NSWindow.didEnterFullScreenNotification,"window.fullscreen.did_enter"),
            (NSWindow.willExitFullScreenNotification,"window.fullscreen.will_exit"),(NSWindow.didExitFullScreenNotification,"window.fullscreen.did_exit"),
            (NSWindow.didResizeNotification,"window.resize"),(NSWindow.didMoveNotification,"window.move"),
            (NSWindow.didMiniaturizeNotification,"window.minimize"),(NSWindow.didDeminiaturizeNotification,"window.restore"),
            (NSWindow.willCloseNotification,"window.close"),(NSWindow.didBecomeKeyNotification,"window.key"),(NSWindow.didResignKeyNotification,"window.resign_key")]
        for (name,event) in names {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] n in
                guard let self, let w = n.object as? NSWindow else { return }
                if ["window.resize","window.move"].contains(event), !self.admit(event+".\(w.windowNumber)",interval:0.5) { return }
                var fields = Self.rect(w.frame,prefix:"frame")
                fields.merge(Self.rect(w.contentView?.bounds ?? .zero,prefix:"content"),uniquingKeysWith:{$1})
                fields["window"] = .integer(Int64(w.windowNumber)); fields["fullscreen"] = .flag(w.styleMask.contains(.fullScreen))
                fields["visible"] = .flag(w.isVisible); fields["minimized"] = .flag(w.isMiniaturized)
                Self.event(event,fields)
            })
        }
        for (name,event) in [(NSApplication.didBecomeActiveNotification,"app.active"),(NSApplication.didResignActiveNotification,"app.inactive")] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { _ in Self.event(event) })
        }
        let t = DispatchSource.makeTimerSource(queue:sampling)
        t.schedule(deadline:.now()+1,repeating:5,leeway:.milliseconds(500))
        t.setEventHandler { [weak self] in self?.sample() }; timer = t; t.resume()
    }
    /// Main-thread sampling gate. Repeated scroll/layout notifications do not create queued closures.
    public func admit(_ key: String,interval: Double = 0.5) -> Bool {
        guard Thread.isMainThread, recorder != nil else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous = recent[key], Double(now-previous)/1_000_000_000 < interval { return false }
        if recent.count >= 128 { recent.removeAll(keepingCapacity:true) }
        recent[key] = now; return true
    }
    private func sample() {
        Self.event("resource.sample",RecorderMetrics.sample())
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if let start = awaitingMain {
            lock.unlock(); Self.event("main_queue.pending",["wait_ms":.number(Double(now-start)/1_000_000)]); return
        }
        awaitingMain = now; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.event("main_queue.response",["delay_ms":.number(Double(DispatchTime.now().uptimeNanoseconds-now)/1_000_000)])
            if let capture = self.captureView { Self.event("viewport.periodic",capture()) }
            self.lock.lock(); self.awaitingMain = nil; self.lock.unlock()
        }
    }
    public func stop(timeout: Double = 0.5) {
        timer?.cancel(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        captureView = nil
        _ = recorder?.close(timeout:timeout)
    }
    @objc public func show(_ sender: Any?) {
        guard let recorder else { return }
        let s = recorder.status
        let alert = NSAlert(); alert.messageText = "Local Diagnostics"
        alert.informativeText = "Session \(recorder.identity.session)\n\(s.disabled ? "Recording unavailable (error code \(s.lastErrorCode ?? 0))." : "Recording this app’s operation locally.")\n\(s.written) events written · \(s.pending) queued · \(s.droppedQueue + s.droppedRate + s.lostIO + s.encodingFailures) lost · \(s.rotatedRecords) rotated out\n\nUp to 8 MiB per session; recent sessions share a 128 MiB retention budget. Recent unfinished sessions receive priority within that limit. Other running instances are retained.\n\nExports contain record IDs, geometry, timings, resource measurements and build identity. They exclude transcript text and credentials. An unfinished session alone does not prove a crash."
        alert.addButton(withTitle:exporting ? "Export in progress…" : "Export…"); alert.buttons[0].isEnabled = !exporting
        alert.addButton(withTitle:"Open Folder"); alert.addButton(withTitle:"Close")
        switch alert.runModal() {
        case .alertFirstButtonReturn: export(recorder)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(recorder.root)
        default: break
        }
    }
    private func export(_ recorder: FlightRecorder) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Explorer-\(Int(Date().timeIntervalSince1970)).explorerdiagnostics"
        panel.title = "Export Local Diagnostics"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true; Self.event("diagnostics.export.request")
        recorder.export(to:url) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                self?.exporting = false
                let alert = NSAlert()
                switch result {
                case .success(let result): alert.messageText = "Diagnostics exported"; alert.informativeText = result.path
                case .failure(let error): alert.messageText = "Export unavailable"; alert.informativeText = "The export did not complete (code \((error as NSError).code)). Choose a new destination. Existing recorder evidence is retained."
                }
                alert.runModal()
            }
        }
    }
}
