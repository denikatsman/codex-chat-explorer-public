import WindowingKit
import AppKit
import ExplorerDiagnosticsBridge

/// Explicit native smoke check. Uses the real reader and window event loop,
/// but nonpersistent viewer state and read-only source connections.
final class CursorWorkflowCheck {
    private let source: URL
    private let output: URL
    private let captureDiagnostics: Bool
    private var window: ChatWindow!
    private var root: ChatRootView!
    private var reader: HistoryPane!
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var chats = [Chat]()
    private var events = [[String: Any]]()
    private var phase = "loading"
    private var deadline = Date().addingTimeInterval(30)
    private var enteredFullScreen = false, exitedFullScreen = false
    private var index = 0
    private var scales = [CGFloat]()
    private var before = NSPoint.zero
    private var failure: String?
    private var banner: NSTextField!

    init(source: URL, output: URL, captureDiagnostics: Bool = false) { self.source = source; self.output = output; self.captureDiagnostics = captureDiagnostics }

    func start() {
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        catch { fputs("Cannot create verification output: \(error)\n", stderr); exit(1) }
        if captureDiagnostics { ExplorerDiagnostics.shared.start(root:output.appendingPathComponent("recorder",isDirectory:true)) }
        record("start", ["source":source.path])
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (ChatSnapshot, [Chat]) in
                let snapshot = try ChatStore.load(from: self.source)
                let history = HistoryStore.source(for: snapshot)
                var selected = [Chat]()
                for chat in snapshot.chats.prefix(20) {
                    if let page = try? HistoryStore.page(chatID: chat.id, source: history), !page.messages.isEmpty { selected.append(chat) }
                    if selected.count == 3 { break }
                }
                guard selected.count == 3 else { throw StoreError(message:"Three readable real chats are required for this check") }
                return (snapshot, selected)
            }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): self.fail(error.localizedDescription)
                case .success(let value): self.prepare(value.0, chats:value.1)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { [weak self] _ in self?.tick() }
    }

    private func prepare(_ snapshot: ChatSnapshot, chats: [Chat]) {
        self.chats = chats
        root = ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
        if captureDiagnostics { ExplorerDiagnostics.shared.captureView = { [weak root = self.root] in root?.diagnosticState() ?? [:] } }
        window = ChatWindow(contentSize:root.frame.size)
        window.title = "Reader workflow verification"
        window.contentView = root
        root.show(snapshot);root.setPresentation(.date);root.layoutSubtreeIfNeeded()
        reader = root.subviews.compactMap { $0 as? HistoryPane }.first
        guard reader != nil else { fail("Reader view is missing");return }
        banner = NSTextField(labelWithString:"AUTOMATED VERIFICATION · no saved-state changes")
        banner.font = .monospacedSystemFont(ofSize:9,weight:.bold)
        banner.textColor = AppTheme.ink(dark:false,green:false)
        banner.frame = NSRect(x:160,y:12,width:360,height:18)
        root.addSubview(banner)
        scales = [1,CGFloat(TextSizing.restored(from:.standard)),2.5]
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        for (name, action) in [(NSWindow.didEnterFullScreenNotification, "entered"),(NSWindow.didExitFullScreenNotification,"exited")] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                guard let self else { return }
                if action == "entered" { self.enteredFullScreen = true } else { self.exitedFullScreen = true }
                self.record("full_screen_"+action,["frame":NSStringFromRect(self.window.frame)])
            })
        }
        phase = "entering";deadline = Date().addingTimeInterval(15)
        window.toggleFullScreen(nil)
    }

    private func tick() {
        if Date() > deadline { fail("Timed out in phase: \(phase)");return }
        switch phase {
        case "entering":
            if enteredFullScreen && window.styleMask.contains(.fullScreen) { phase = "open";deadline = Date().addingTimeInterval(15) }
        case "open": openNext()
        case "reading":
            guard !reader.loading else { return }
            guard !reader.isHidden, reader.chat?.id == chats[index % 3].id, reader.displayedMessageCount > 0 else {
                fail("Reader did not load the requested real chat: \(reader.statusText)");return
            }
            window.displayIfNeeded()
            record("reader_loaded",["chat_id":chats[index % 3].id,"messages":reader.displayedMessageCount])
            phase = "back";deadline = Date().addingTimeInterval(10)
        case "back":
            guard let back = reader.subviews.compactMap({ $0 as? NSButton }).first(where:{ $0.title == "‹ BACK" }) else { fail("Back button missing");return }
            back.performClick(nil)
            phase = "returned";deadline = Date().addingTimeInterval(10)
        case "returned":
            root.layoutSubtreeIfNeeded();window.displayIfNeeded()
            guard reader.isHidden, !root.scroll.isHidden else { fail("Back did not restore DATE");return }
            let after = root.scroll.contentView.bounds.origin
            guard abs(after.x-before.x) < 0.5 && abs(after.y-before.y) < 0.5 else { fail("Back changed DATE scroll position: \(before) → \(after)");return }
            root.timeline.resetCursorRects()
            guard root.timeline.cursorRegions(in:root.timeline.visibleRect).allSatisfy({ CursorGeometry.isUsable($0.rect) }) else { fail("Invalid cursor region survived filtering");return }
            record("back_verified",["chat_id":chats[index % 3].id,"scroll":NSStringFromPoint(after),"viewport":NSStringFromRect(root.timeline.visibleRect),"zoom":root.scroll.magnification])
            index += 1
            if index == scales.count * 3 {
                try? root.render(to:output.appendingPathComponent("fullscreen-after-cycles.png"))
                phase = "exiting";deadline = Date().addingTimeInterval(15);window.toggleFullScreen(nil)
            } else { phase = "open";deadline = Date().addingTimeInterval(15) }
        case "exiting":
            if exitedFullScreen && !window.styleMask.contains(.fullScreen) {
                guard !window.styleMask.contains(.titled) else { fail("Window did not return to its normal frame style");return }
                finish()
            }
        case "cleanup":
            if !window.styleMask.contains(.fullScreen) { finish() }
        default: break
        }
    }

    private func openNext() {
        let scale = scales[index / 3]
        if abs(root.scroll.magnification-scale) > 0.000001 { root.resetTextSize();root.adjustTextSize(by:scale) }
        root.layoutSubtreeIfNeeded()
        let chat = chats[index % 3]
        guard let row = root.timeline.entries.first(where:{ $0.chat?.id == chat.id }) else { fail("DATE row missing");return }
        // Clip the checkbox while part of the same row remains visible: this is
        // the geometry missed by the original label-only visibility guard.
        root.scroll.contentView.scroll(to:NSPoint(x:0,y:row.y+30))
        root.scroll.reflectScrolledClipView(root.scroll.contentView)
        before = root.scroll.contentView.bounds.origin
        root.timeline.resetCursorRects();window.invalidateCursorRects(for:root.timeline);window.displayIfNeeded()
        let visible = root.timeline.visibleRect
        let local = NSPoint(x:min(200,visible.midX),y:max(row.y+14,visible.minY+2))
        guard local.y < row.y+row.height else { fail("No visible point remains in the target row");return }
        let point = root.timeline.convert(local,to:nil)
        banner.stringValue = "VERIFYING CHAT \(index+1)/\(scales.count*3) · ZOOM \(String(format:"%.2f",Double(scale)))"
        record("double_click",["chat_id":chat.id,"scroll":NSStringFromPoint(before),"viewport":NSStringFromRect(visible),"zoom":scale])
        phase = "reading";deadline = Date().addingTimeInterval(15)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:index+1,clickCount:2,pressure:1) else { fail("Could not construct native mouse event");return }
            window.sendEvent(event)
        }
    }

    private func record(_ event: String, _ fields: [String:Any] = [:]) {
        var entry = fields;entry["event"] = event;entry["time"] = ISO8601DateFormatter().string(from:Date())
        events.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject:events,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:output.appendingPathComponent("events.json"),options:.atomic) }
    }
    private func fail(_ message: String) {
        if failure == nil { failure = message;record("failed",["reason":message]) }
        if let window, window.styleMask.contains(.fullScreen), phase != "cleanup" {
            phase = "cleanup";deadline = Date().addingTimeInterval(10);window.toggleFullScreen(nil)
        } else { finish() }
    }
    private func finish() {
        guard phase != "finished" else { return }; phase = "finished"
        timer?.invalidate();timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) };observers.removeAll()
        reader?.hideReader()
        if captureDiagnostics, let recorder = ExplorerDiagnostics.shared.recorder {
            recorder.export(to:output.appendingPathComponent("workflow.explorerdiagnostics",isDirectory:true)) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    do {
                        let bundle = try result.get()
                        var events = [DiagnosticRecord]()
                        let session = bundle.appendingPathComponent(recorder.identity.session)
                        for file in try FileManager.default.contentsOfDirectory(at:session,includingPropertiesForKeys:nil).filter({ $0.pathExtension == "jsonl" }).sorted(by:{ $0.path < $1.path }) {
                            let recovered = try DiagnosticReader.scan(file) { events.append($0) }
                            guard recovered.malformed == 0, recovered.partial == 0, recovered.oversized == 0 else { throw StoreError(message:"Diagnostic bundle has damaged records") }
                        }
                        let count: (String) -> Int = { name in events.filter { $0.event == name }.count }
                        guard count("window.fullscreen.did_enter") == 1, count("window.fullscreen.did_exit") == 1,
                              count("navigation.open.begin") == 9, count("navigation.back.end") == 9,
                              events.filter({ $0.event == "reader.page.end" && $0.fields["outcome"] == .text("ok") }).count == 9,
                              events.filter({ $0.event == "navigation.open.begin" }).allSatisfy({ $0.fields["fullscreen"] == .flag(true) && $0.fields["viewport_y"] != nil && $0.fields["chat_id"] != nil }) else {
                            throw StoreError(message:"Expected native navigation diagnostic evidence is incomplete")
                        }
                        let status = recorder.status
                        guard status.droppedQueue == 0, status.droppedRate == 0, status.encodingFailures == 0, status.lostIO == 0 else { throw StoreError(message:"Recorder lost workflow events") }
                        guard FileManager.default.fileExists(atPath:bundle.appendingPathComponent("diagnostics.py").path) else { throw StoreError(message:"Packaged diagnostic query tool missing from export") }
                        self.record("diagnostics_verified", ["events":events.count,"session":recorder.identity.session,"native_fullscreen_notifications":2,"reader_back_cycles":9,"dropped":0])
                    } catch { if self.failure == nil { self.failure = "Diagnostic verification: \(error.localizedDescription)" } }
                    ExplorerDiagnostics.shared.stop(timeout:5)
                    self.complete()
                }
            }
        } else { complete() }
    }
    private func complete() {
        let result: [String:Any] = ["success":failure == nil,"failure":failure ?? NSNull(),"native_full_screen_entered":enteredFullScreen,"native_full_screen_exited":exitedFullScreen,"completed_reader_back_cycles":index,"chat_ids":chats.map(\.id),"zoom_factors":scales,"saved_state_writes":false,"diagnostics_isolated":captureDiagnostics]
        if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:output.appendingPathComponent("result.json"),options:.atomic) }
        window?.close()
        if let failure { fputs("FAIL: \(failure)\n",stderr);exit(1) }
        print("PASS: native full-screen entry/exit; \(index) real-chat double-click/Back cycles at \(scales.count) zoom factors; finite cursor regions and retained DATE position; isolated diagnostics \(captureDiagnostics).")
        exit(0)
    }
}
