import AppKit
import CSQLite
import ModelSupport

/// Explicit synthetic UI workflow. Uses private annotations and never changes source chats.
final class ChatRowWorkflowCheck {
    private let output: URL, realLocal: Bool
    private var root: ChatRootView!, mirror: ChatRootView!, window: ChatWindow!, library: ExplorerLibrary!, coordinator: LabelCoordinator!
    private var snapshot: ChatSnapshot!, active: ActiveSnapshot!
    private var timer: Timer?, phase = "starting", deadline = Date().addingTimeInterval(80)
    private var checks = [String: Bool](), sourceBytes = Data(), history: URL!
    private var summaryFailure: String?
    init(output: URL, realLocal: Bool) { self.output = output; self.realLocal = realLocal }
    func start() {
        do {
            // Debug executables have a different defaults domain. Read the app's
            // saved appearance/zoom for representative captures without writing it.
            UserDefaults.standard.addSuite(named: "local.ai-context-systems-management.codex-chats")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            history = output.appendingPathComponent("thread_history_1.sqlite")
            var db: OpaquePointer?
            guard sqlite3_open(history.path, &db) == SQLITE_OK else { throw LabelFailure("Fixture database unavailable") }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, "CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT);", nil, nil, nil) == SQLITE_OK else { throw LabelFailure("Fixture database creation failed") }
            for n in 0..<8 {
                let text = "Build a desktop chat browser with pinned conversations, colored dots and manually generated local five word summaries. Keep original records read only and share annotations across windows."
                let json = String(data: try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]]), encoding: .utf8)!.replacingOccurrences(of: "'", with: "''")
                let sql = "INSERT INTO thread_items VALUES('fixture-\(n)','turn','item',1,1000,'userMessage','\(json)');"
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LabelFailure("Fixture insertion failed") }
            }
            sqlite3_close(db); db = nil
            sourceBytes = try Data(contentsOf: history)
            let project = ProjectReference(identity: .assigned(kind: "fixture", id: "rows"), name: "Interface", originalAssignment: nil, originalProject: nil)
            let titles = ["Keep original chat records intact", "Add pinned chats and colored dots", "Inspect waiting state and activity", "Understand unconfirmed runtime evidence", "Organize a small library of tools", "Read previous conversation messages", "Review controls at narrow widths", "Leave inactive pinned chats in DATE"]
            let chats = titles.enumerated().map { n, title in Chat(original: [:], id: "fixture-\(n)", title: title, createdAt: Date().addingTimeInterval(Double(-n * 300)), archived: false, issues: [], project: project) }
            let source = output.appendingPathComponent("state_5.sqlite")
            snapshot = ChatSnapshot(chats: chats, sourceURL: source, observedAt: Date(), excludedSubagents: 0, projectSourceURL: source, projectSourceIssue: nil)
            library = ExplorerLibrary(directory: output.appendingPathComponent("annotations"))
            let fake = output.appendingPathComponent("offline-worker")
            if !realLocal {
                let code = "#!/bin/sh\nread -r request || exit 2\nprintf '{\"kind\":\"result\",\"jobID\":\"%s\",\"label\":\"Pinned chats gain colored summaries\",\"model\":\"offline-synthetic\"}\\n' \"$EXPLORER_LABEL_JOB\"\n"
                try code.write(to: fake, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            }
            AppearanceSettings.shared.activate() // Read the saved palette; this check never flushes it.
            coordinator = LabelCoordinator(workerURL: realLocal ? nil : fake, jobRoot: output.appendingPathComponent("jobs"), admission: LabelAdmission())
            root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 1420, height: 820), persistTheme: false, loadOnDemand: false, library: library, labelCoordinator: coordinator)
            let handler = coordinator.onEvent
            coordinator.onEvent = { [weak self] event in
                handler?(event)
                if event.kind == "settled", event.label == nil { self?.summaryFailure = event.message ?? "Summary did not produce a saved result" }
            }
            mirror = ChatRootView(frame: root.frame, persistTheme: false, loadOnDemand: false, library: library)
            for view in [root!, mirror!] {
                view.show(snapshot); view.setPresentation(.date); view.setDark(AppearanceSettings.shared.current.isDark)
                view.adjustTextSize(by: TextSizing.restored(from: .standard))
            }
            window = ChatWindow(contentSize: root.frame.size); window.title = "Chat row verification"; window.contentView = root
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let now = Date().timeIntervalSince1970
            active = ActiveSnapshot(connected: true, sequence: 1, observedAt: now, rows: [ActiveChatRow(id: "fixture-1", host: "local", title: titles[1], state: "working", confirmedAt: now), ActiveChatRow(id: "fixture-2", host: "local", title: titles[2], state: "waiting", confirmedAt: now), ActiveChatRow(id: "fixture-3", host: "local", title: titles[3], state: "unknown", confirmedAt: nil)], pending: 1, warning: "Synthetic verification data", queryMs: 0, bytesReceived: 0)
            root.showActive(active); mirror.showActive(active)
            phase = "date"; deadline = Date().addingTimeInterval(80)
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        } catch { finish(error.localizedDescription) }
    }
    private func tick() {
        if Date() > deadline { finish("Timed out in \(phase); label busy=\(coordinator?.isRunning ?? false)"); return }
        do {
            switch phase {
            case "date":
                guard window.isVisible, NSApp.isActive else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
                root.layoutSubtreeIfNeeded()
                guard press(prefix: "Pin chat: Add pinned", view: root.timeline) else { throw LabelFailure("Pin action unavailable") }
                try library.togglePinned("fixture-7")
                let menu = ChatRowAppearance.menu(chatID: "fixture-1", state: library.state, onPin: root.timeline.onTogglePinned, onTag: root.timeline.onSetTag, onSummary: root.timeline.onSummarize)
                let green = menu.items.first { $0.title == "Colored Dot" }?.submenu?.items.first { $0.title == "Green" }
                guard let green, let action = green.action, NSApp.sendAction(action, to: green.target, from: green) else { throw LabelFailure("Tag menu action unavailable") }
                guard library.state.pinnedChatIDs == ["fixture-1", "fixture-7"], library.state.tag(for: "fixture-1") == .green,
                      mirror.timeline.entries.compactMap(\.chat).prefix(2).map(\.id) == ["fixture-1", "fixture-7"] else { throw LabelFailure("Pins or tags failed to synchronize") }
                checks["shared_pin_and_tag_actions"] = true
                root.scroll.contentView.scroll(to: .zero); root.scroll.reflectScrolledClipView(root.scroll.contentView)
                capture("date-before.png")
                root.setPresentation(.active); phase = "active"
            case "active":
                guard let view = root.scroll.documentView as? ActiveChatsView else { throw LabelFailure("ACTIVE view unavailable") }
                let labels = (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
                guard !labels.contains(where: { $0.contains("Leave inactive pinned") }) else { throw LabelFailure("Inactive pin leaked into ACTIVE") }
                guard view.subviews.compactMap({ $0 as? DateWorkingIndicator }).count == 1 else { return }
                checks["active_only_pins_and_running_indicator"] = true
                capture("active.png")
                let ended = ActiveSnapshot(connected: true, sequence: 2, observedAt: Date().timeIntervalSince1970, rows: Array(active.rows.dropFirst()), pending: 1, warning: "Synthetic verification data", queryMs: 0, bytesReceived: 0)
                root.showActive(ended)
                guard view.subviews.compactMap({ $0 as? DateWorkingIndicator }).isEmpty, library.state.pinnedChatIDs.contains("fixture-1") else { throw LabelFailure("Ended work retained its spinner or lost its pin") }
                checks["ended_activity_keeps_date_pin"] = true
                root.setPresentation(.date); root.layoutSubtreeIfNeeded()
                root.scroll.contentView.scroll(to: .zero); root.scroll.reflectScrolledClipView(root.scroll.contentView)
                guard press(prefix: "AI summary for Add pinned", view: root.timeline) else { throw LabelFailure("Row summary action unavailable") }
                phase = "summary"
            case "summary":
                if let summaryFailure { throw LabelFailure(summaryFailure) }
                guard let saved = library.state.labels["fixture-1"] else { return }
                guard !coordinator.isRunning, coordinator.startedRequests == 1, saved.provider == "Local",
                      (try? LabelPolicy.validatedLabel(saved.text)) != nil else { throw LabelFailure("Summary provider, size or request count differs") }
                checks["one_explicit_local_five_word_summary"] = true
                guard root.scroll.documentView === root.timeline else { throw LabelFailure("Completed row summary did not return to DATE") }
                capture("date-completed.png")
                window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 690, height: 820)), display: true); root.needsLayout = true; root.layoutSubtreeIfNeeded()
                phase = "narrow"
            case "narrow":
                capture("date-narrow.png")
                guard try Data(contentsOf: history) == sourceBytes else { throw LabelFailure("Synthetic source bytes changed") }
                guard ExplorerLibrary(directory: output.appendingPathComponent("annotations")).state.pinnedChatIDs == library.state.pinnedChatIDs else { throw LabelFailure("Annotation reload lost pins") }
                checks["source_bytes_and_annotation_reload"] = true
                finish(nil)
            default: break
            }
        } catch { finish(error.localizedDescription) }
    }
    private func press(prefix: String, view: NSView) -> Bool {
        guard let element = (view.accessibilityChildren() ?? []).compactMap({ $0 as? NSAccessibilityElement }).first(where: { $0.accessibilityLabel()?.hasPrefix(prefix) == true }) else { return false }
        return element.accessibilityPerformPress()
    }
    private func capture(_ name: String) {
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if let image = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: image)
            if let bytes = image.representation(using: .png, properties: [:]) { try? bytes.write(to: output.appendingPathComponent(name)) }
        }
    }
    private func finish(_ error: String?) {
        guard phase != "finished" else { return }; phase = "finished"; timer?.invalidate(); timer = nil
        let done = { [self] in
            let result: [String: Any] = ["success": error == nil, "failure": error ?? NSNull(), "checks": checks, "real_local_model": realLocal, "requests": coordinator?.startedRequests ?? 0, "saved_summary": library?.state.labels["fixture-1"]?.text ?? NSNull(), "user_data_writes": false]
            if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? bytes.write(to: output.appendingPathComponent("result.json")) }
            window?.close()
            if let error { fputs("FAIL: \(error)\n", stderr); exit(1) }
            print("PASS: native pin/tag actions, active-only pins and spinner cleanup, local-default five-word summary, completion return, source bytes and reload."); exit(0)
        }
        if let root { root.stopLabelWork(completion: done) } else { done() }
    }
}
