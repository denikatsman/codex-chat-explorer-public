import AppKit
import ExplorerDiagnosticsBridge

private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: ChatWindow!
    private var root: ChatRootView!
    private var explorerHost: CanvasExplorerHost?
    private var windows:ExplorerWindowCoordinator?
    private var canvasMenu:NSMenu?
    private var openWindowsMenu:NSMenu?
    private var reading = false
    private var cursorWorkflowCheck: CursorWorkflowCheck?
    private var canvasExplorerCheck: CanvasExplorerWorkflowCheck?
    private var chatRowCheck: ChatRowWorkflowCheck?
    private var multiWindowCheck:MultiWindowWorkflowCheck?
    private lazy var activeSource = ActiveStatusSource(home: source.deletingLastPathComponent())
    private let source = argument("--source").map { URL(fileURLWithPath: $0) } ?? ChatStore.defaultURL

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path=argument("--preview-multiwindow") {
            let check=MultiWindowWorkflowCheck(source:source,output:URL(fileURLWithPath:path,isDirectory:true),preview:true);multiWindowCheck=check;check.start();return
        }
        if let path = argument("--check-chat-rows") {
            let check = ChatRowWorkflowCheck(output: URL(fileURLWithPath: path, isDirectory: true), realLocal: CommandLine.arguments.contains("--real-local-summary"))
            chatRowCheck = check; check.start(); return
        }
        if let path=argument("--check-multiwindow") {
            let check=MultiWindowWorkflowCheck(source:source,output:URL(fileURLWithPath:path,isDirectory:true));multiWindowCheck=check;check.start();return
        }
        if let path = argument("--check-canvas-explorer") {
            let check=CanvasExplorerWorkflowCheck(source:source,output:URL(fileURLWithPath:path,isDirectory:true))
            canvasExplorerCheck=check;check.start();return
        }
        if let path = argument("--check-reader-cycle") {
            let check = CursorWorkflowCheck(source:source,output:URL(fileURLWithPath:path,isDirectory:true),captureDiagnostics:CommandLine.arguments.contains("--record-diagnostics"))
            cursorWorkflowCheck = check;check.start();return
        }
        if let path = argument("--render-find") {
            do { try renderSemanticPreview(to: URL(fileURLWithPath: path)); print("Rendered FIND from saved local data without model inference."); NSApp.terminate(nil) }
            catch { fputs("FIND render failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if let value = argument("--check-day") {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let day = formatter.date(from: value), formatter.string(from: day) == value else { fputs("Use --check-day YYYY-MM-DD.\n", stderr); exit(2) }
            do {
                let snapshot = try ChatStore.load(from: source), started = ProcessInfo.processInfo.systemUptime
                let page = try DayFeedStore.load(chats: snapshot.chats, source: HistoryStore.source(for: snapshot), day: day)
                let data = try JSONSerialization.data(withJSONObject: ["messages": page.messages.count, "hasMore": page.cursor != nil, "deferred": page.deferred, "elapsedMs": (ProcessInfo.processInfo.systemUptime-started)*1000])
                print(String(data: data, encoding: .utf8)!); NSApp.terminate(nil)
            } catch { fputs("Day check unavailable: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if let value = argument("--check-active") {
            guard let seconds = Double(value), seconds.isFinite, (1...30).contains(seconds) else { fputs("Use --check-active with 1–30 seconds.\n", stderr); exit(2) }
            activeSource.onSnapshot = { value in
                if let data = try? JSONEncoder().encode(value), let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
            }
            activeSource.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.activeSource.stop(); NSApp.terminate(nil) }
            return
        }
        if argument("--render") == nil { ExplorerDiagnostics.shared.start() }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let appearanceItem=NSMenuItem(title:"Appearance…",action:#selector(AppearancePanel.show(_:)),keyEquivalent:",")
        appearanceItem.target=AppearancePanel.shared;appMenu.addItem(appearanceItem);appMenu.addItem(.separator())
        let diagnostics = NSMenuItem(title: "Local Diagnostics…", action: #selector(ExplorerDiagnostics.show(_:)), keyEquivalent: "")
        diagnostics.target = ExplorerDiagnostics.shared; appMenu.addItem(diagnostics); appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppBranding.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let refreshItem = NSMenuItem(title: "Refresh Chats", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self; fileMenu.addItem(refreshItem)
        let findItem = NSMenuItem(title: "Find Chats and Messages…", action: #selector(findChats), keyEquivalent: "f")
        findItem.target = self; fileMenu.addItem(findItem)
        let savedItem = NSMenuItem(title: "Saved Excerpts and Stars…", action: #selector(showSaved), keyEquivalent: "b")
        savedItem.keyEquivalentModifierMask = [.command, .shift]; savedItem.target = self; fileMenu.addItem(savedItem)
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(closeWindow), keyEquivalent: "w")
        closeItem.target = self; fileMenu.addItem(closeItem)
        let newExplorer=NSMenuItem(title:"New Explorer Window",action:#selector(newExplorerWindow),keyEquivalent:"n");newExplorer.target=self;fileMenu.insertItem(newExplorer,at:0)
        let duplicate=NSMenuItem(title:"Duplicate Window",action:#selector(duplicateWindow),keyEquivalent:"d");duplicate.target=self;duplicate.keyEquivalentModifierMask=[.command,.shift];fileMenu.insertItem(duplicate,at:1)
        let newCanvas=NSMenuItem(title:"New Canvas",action:#selector(newCanvasWindow),keyEquivalent:"n");newCanvas.target=self;newCanvas.keyEquivalentModifierMask=[.command,.shift];fileMenu.insertItem(newCanvas,at:2)
        let boards=NSMenuItem(title:"Open Canvas",action:nil,keyEquivalent:"");let submenu=NSMenu(title:"Open Canvas");submenu.delegate=self;boards.submenu=submenu;canvasMenu=submenu;fileMenu.insertItem(boards,at:3)
        fileMenu.insertItem(.separator(),at:4)
        fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (title, action, key) in [
            ("Increase Text Size", #selector(increaseTextSize), "+"),
            ("Decrease Text Size", #selector(decreaseTextSize), "-"),
            ("Actual Text Size", #selector(resetTextSize), "0")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; item.keyEquivalentModifierMask = [.command]
            viewMenu.addItem(item)
        }
        // Also accept Command-= without requiring the Shift key.
        let equalsAlias = NSMenuItem(title: "Increase Text Size", action: #selector(increaseTextSize), keyEquivalent: "=")
        equalsAlias.target = self; equalsAlias.keyEquivalentModifierMask = [.command]
        equalsAlias.isHidden = true; equalsAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(equalsAlias)
        let appearanceViewItem=NSMenuItem(title:"Appearance…",action:#selector(AppearancePanel.show(_:)),keyEquivalent:"")
        appearanceViewItem.target=AppearancePanel.shared;viewMenu.addItem(.separator());viewMenu.addItem(appearanceViewItem)
        viewItem.submenu = viewMenu; menu.addItem(viewItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let fullScreenItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(minimizeItem); windowMenu.addItem(fullScreenItem)
        windowMenu.delegate=self;openWindowsMenu=windowMenu
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu

        let rendering = argument("--render")
        if rendering == nil {
            let manager=ExplorerWindowCoordinator();windows=manager
            let initial=manager.newExplorer(show:false);window=initial.window;root=initial.root
            ExplorerDiagnostics.shared.captureView={ [weak manager] in
                var fields=manager?.focusedExplorer()?.root.diagnosticState() ?? [:]
                fields["explorer_views"] = .integer(Int64(manager?.explorers.count ?? 0));fields["chat_windows"] = .integer(Int64(manager?.chatWindows.count ?? 0));return fields
            }
        } else {
            window=ChatWindow(contentSize:NSSize(width:940,height:650))
            root=ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
            window.contentView=root;window.center()
        }
        if let rendering {
            do {
                let snapshot = try ChatStore.load(from: source)
                root.show(snapshot)
                let directory = URL(fileURLWithPath: rendering, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for dark in [false, true] {
                    root.setDark(dark)
                    root.setPresentation(.project)
                    let theme = dark ? "dark" : "light"
                    root.scroll.contentView.scroll(to: .zero)
                    root.scroll.reflectScrolledClipView(root.scroll.contentView)
                    try root.render(to: directory.appendingPathComponent("chats-\(theme).png"))
                    if let group = root.timeline.groups.first(where: { $0.chats.contains(where: \.archived) }) {
                        let expanded = root.timeline.isExpanded(group.project.identity)
                        if !expanded { root.timeline.toggleGroup(group.project.identity) }
                        if let firstArchive = root.timeline.entries.first(where: { $0.chat?.archived == true }) {
                            root.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, firstArchive.y - 44)))
                            root.scroll.reflectScrolledClipView(root.scroll.contentView)
                            try root.render(to: directory.appendingPathComponent("chats-\(theme)-archived.png"))
                        }
                        if !expanded { root.timeline.toggleGroup(group.project.identity) }
                    }
                    if let group = root.timeline.groups.first(where: { $0.project.identity == .noProject }) {
                        let expanded = root.timeline.isExpanded(.noProject)
                        if !expanded { root.timeline.toggleGroup(.noProject) }
                        if let header = root.timeline.entries.first(where: { $0.group?.project.identity == .noProject }) {
                            root.scroll.contentView.scroll(to: NSPoint(x: 0, y: header.y))
                            root.scroll.reflectScrolledClipView(root.scroll.contentView)
                            try root.render(to: directory.appendingPathComponent("chats-\(theme)-no-project.png"))
                        }
                        if !expanded { root.timeline.toggleGroup(group.project.identity) }
                    }
                    root.setPresentation(.date)
                    root.scroll.contentView.scroll(to: .zero)
                    root.scroll.reflectScrolledClipView(root.scroll.contentView)
                    try root.render(to: directory.appendingPathComponent("chats-date-\(theme).png"))
                }
                let day = try MessageTimelineStore.load(snapshot, day: Date())
                let columns = try ColumnsStore.load(snapshot)
                let lanes = try LaneStore.load(home: snapshot.sourceURL.deletingLastPathComponent(), metadata: snapshot)
                root.setTimelineFeed(false)
                root.showMessageDay(day); root.showColumns(columns); root.showLanes(lanes)
                for dark in [false, true] {
                    root.setDark(dark)
                    for presentation in [ChatPresentation.timeline, .columns, .lanes] {
                        root.setPresentation(presentation)
                        try root.render(to: directory.appendingPathComponent("chats-\(presentation.rawValue)-\(dark ? "dark" : "light").png"))
                    }
                }
                print("Unified views: \(day.count) daily message marks, \(columns.messageCount) column messages (\(columns.gaps?.count ?? 0) gaps), \(lanes.messageCount) user-message lane events (\(lanes.issues) issues).")
                let unassigned = snapshot.groups.first { $0.project.identity == .noProject }?.chats.count ?? 0
                print("Rendered \(snapshot.groups.count) project groups, \(snapshot.chats.count) chats (\(snapshot.archivedCount) archived, \(unassigned) with no project); \(snapshot.excludedSubagents) subagents excluded; \(snapshot.issueCount) metadata warnings.")
                NSApp.terminate(nil)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        activeSource.onSnapshot = { [weak self] value in self?.windows?.updateActive(value) }
        activeSource.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        root=nil;window=nil
    }

    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if cursorWorkflowCheck != nil || canvasExplorerCheck != nil || multiWindowCheck != nil || chatRowCheck != nil {return .terminateNow}
        if let windows,!windows.saveState() {
            let alert=NSAlert();alert.messageText="Canvas changes are not saved";alert.informativeText=windows.canvases.issue ?? "The saved canvas file could not be written. Keep the app open to retain the current changes."
            alert.addButton(withTitle:"Keep Open");alert.addButton(withTitle:"Quit Without Saving")
            if alert.runModal() != .alertSecondButtonReturn{return .terminateCancel}
        }
        let finish={ SemanticCoordinator.shared.shutdownForTermination {sender.reply(toApplicationShouldTerminate:$0)} }
        if let windows{windows.shutdownLabels(completion:finish)}else{finish()}
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows?.revealExplorer()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        windows?.flush()
        ExplorerDiagnostics.shared.stop()
        if cursorWorkflowCheck == nil && canvasExplorerCheck == nil && multiWindowCheck == nil && chatRowCheck == nil { AppearanceSettings.shared.flush();activeSource.stop() }
    }
    func applicationDidBecomeActive(_ notification: Notification) { if windows != nil || root != nil { refresh() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {multiWindowCheck == nil && chatRowCheck == nil}
    @objc private func findChats() { windows?.find() }
    @objc private func showSaved() { windows?.saved() }
    @objc private func increaseTextSize() {
        if let canvas = NSApp.keyWindow?.contentView as? CanvasZoomCommands { canvas.adjustCanvasZoom(0.15) }
        else { windows?.focusedExplorer()?.root.adjustTextSize(by:TextSizing.step) }
    }
    @objc private func decreaseTextSize() {
        if let canvas = NSApp.keyWindow?.contentView as? CanvasZoomCommands { canvas.adjustCanvasZoom(-0.15) }
        else { windows?.focusedExplorer()?.root.adjustTextSize(by:1/TextSizing.step) }
    }
    @objc private func resetTextSize() {
        if let canvas = NSApp.keyWindow?.contentView as? CanvasZoomCommands { canvas.resetCanvasZoom() }
        else { windows?.focusedExplorer()?.root.resetTextSize() }
    }
    @objc private func closeWindow() { NSApp.keyWindow?.close() }
    @objc private func newExplorerWindow() { _=windows?.newExplorer() }
    @objc private func duplicateWindow() { windows?.duplicateFocusedWindow() }
    @objc private func newCanvasWindow() { windows?.newCanvas() }
    @objc private func openCanvasDocument(_ sender:NSMenuItem) {if let id=sender.representedObject as? String{windows?.openCanvas(id)}}
    @objc private func showOpenWindow(_ sender:NSMenuItem){if let id=sender.representedObject as? String{windows?.showWindow(id)}}
    func menuNeedsUpdate(_ menu:NSMenu) {
        if menu === openWindowsMenu {
            for item in menu.items where item.tag==901{menu.removeItem(item)}
            let separator=NSMenuItem.separator();separator.tag=901;menu.addItem(separator)
            for (id,window) in windows?.windowEntries ?? [] {let item=NSMenuItem(title:window.title,action:#selector(showOpenWindow(_:)),keyEquivalent:"");item.target=self;item.representedObject=id;item.tag=901;menu.addItem(item)}
            return
        }
        guard menu === canvasMenu else{return};menu.removeAllItems()
        for document in windows?.canvases.documents ?? [] {
            let item=NSMenuItem(title:document.name,action:#selector(openCanvasDocument(_:)),keyEquivalent:"");item.target=self;item.representedObject=document.id;menu.addItem(item)
        }
    }

    @objc private func refresh() {
        guard !reading else { ExplorerDiagnostics.event("metadata.refresh.coalesced"); return }
        reading = true
        let url = source
        let operation = ExplorerDiagnostics.begin("metadata.refresh")
        DispatchQueue.global(qos: .userInitiated).async {
            ExplorerDiagnostics.event("metadata.queue.start", operation: operation?.id, ["queue_wait_ms": .number(operation?.elapsedMS ?? 0)])
            let read = ExplorerDiagnostics.begin("metadata.read", ["parent_operation": operation.map { .text($0.id) } ?? .null])
            let result = Result { try ChatStore.load(from: url) }
            ExplorerDiagnostics.end("metadata.read", read)
            DispatchQueue.main.async {
                self.reading = false
                switch result {
                case .success(let snapshot):
                    if let windows=self.windows{windows.update(snapshot)}else{self.root?.show(snapshot)}
                    ExplorerDiagnostics.end("metadata.refresh", operation, ["outcome": .text("ok"), "chats": .integer(Int64(snapshot.chats.count)), "issues": .integer(Int64(snapshot.issueCount))])
                case .failure(let error):
                    if let windows=self.windows{windows.showError(error.localizedDescription)}else{self.root?.showError(error.localizedDescription)}
                    ExplorerDiagnostics.end("metadata.refresh", operation, ExplorerDiagnostics.error(error))
                }
            }
        }
    }
}

if let configuration = argument("--semantic-evaluate") { exit(runSemanticCLI(configuration)) }

let application = NSApplication.shared
application.setActivationPolicy(argument("--render") == nil && argument("--render-find") == nil && argument("--check-active") == nil && argument("--check-day") == nil ? .regular : .prohibited)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
