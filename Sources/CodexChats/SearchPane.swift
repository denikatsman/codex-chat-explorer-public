import AppKit

private final class ExplorerResultRow: NSTableRowView {
    var ink = NSColor.labelColor
    override func drawSelection(in dirtyRect: NSRect) { ink.withAlphaComponent(0.16).setFill(); bounds.fill() }
}

final class SearchPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode { case chats, messages, saved, day }
    struct Hit {
        let chatID: String
        let ordinal: Int64?
        let title: String
        let detail: String
        let text: String
        let excerpt: SavedExcerpt?
        var semantic: SemanticPassage? = nil
        var groupCount = 0
    }
    struct PresentationState {
        var snapshot: ChatSnapshot?; var mode: Mode; var query: String; var hits: [Hit]
        var semanticHits: [SemanticHit]; var expandedChats: Set<String>
        var searchMode: SemanticSearchMode; var filters: SemanticFilters
        var cursor: HistorySearchCursor?; var scanned: Int; var deferred: Int
        var searchChats: [Chat]; var activeQuery: String
        var day: Date; var dayRole: DayFeedRole; var dayCursor: DayFeedCursor?; var dayLoaded: Bool
        var status: String; var selectedRows: IndexSet; var scrollOffset: NSPoint; var wasSearching: Bool
    }
    func capturePresentationState() -> PresentationState {
        PresentationState(snapshot: snapshot, mode: mode, query: query.stringValue, hits: hits,
                          semanticHits: semanticHits, expandedChats: expandedChats, searchMode: semanticControls.searchMode,
                          filters: semanticControls.filters, cursor: cursor, scanned: scanned, deferred: deferred,
                          searchChats: searchChats, activeQuery: activeQuery, day: day, dayRole: dayRole,
                          dayCursor: dayCursor, dayLoaded: dayLoaded, status: info.stringValue,
                          selectedRows: table.selectedRowIndexes, scrollOffset: scroll.contentView.bounds.origin, wasSearching: cancel.isEnabled)
    }
    func restorePresentationState(_ state: PresentationState) {
        cancellation.cancel(); request = UUID(); coordinator.cancelSearch(owner: searchOwner)
        snapshot = state.snapshot; mode = state.mode; query.stringValue = state.query; hits = state.hits
        semanticHits = state.semanticHits; expandedChats = state.expandedChats
        semanticControls.mode.selectItem(at: coordinator.semanticEnabled ? (SemanticSearchMode.allCases.firstIndex(of: state.searchMode) ?? 0) : 2)
        semanticControls.tools.state = state.filters.includeTools ? .on : .off
        semanticControls.finals.state = state.filters.finalOnly ? .on : .off
        previousToolFilter = state.filters.includeTools
        semanticControls.show(options: coordinator.options); semanticControls.refreshModeState()
        cursor = state.cursor; scanned = state.scanned; deferred = state.deferred
        searchChats = state.searchChats; activeQuery = state.activeQuery
        day = state.day; dayRole = state.dayRole; dayCursor = state.dayCursor; dayLoaded = state.dayLoaded
        back.title = mode == .day ? "CHART" : "‹ BACK"
        chatsButton.title = mode == .day ? "ALL" : "CHATS"
        messagesButton.title = mode == .day ? "INPUTS" : "MESSAGES"
        savedButton.title = mode == .day ? "REPLIES" : "SAVED"
        query.placeholderString = mode == .day ? "Find text in the selected day…" : "Find chats, topics or recorded text…"
        chatsButton.state = (mode == .day ? dayRole == .all : mode == .chats) ? .on : .off
        messagesButton.state = (mode == .day ? dayRole == .inputs : mode == .messages) ? .on : .off
        savedButton.state = (mode == .day ? dayRole == .replies : mode == .saved) ? .on : .off
        info.stringValue = state.wasSearching ? "Copied available results. Press Return to search in this window." : state.status
        cancel.isEnabled = false; more.isEnabled = mode == .day ? dayCursor != nil : cursor != nil
        table.rowHeight = resultRowHeight; table.reloadData(); needsLayout = true; layoutSubtreeIfNeeded()
        table.selectRowIndexes(IndexSet(state.selectedRows.filter { hits.indices.contains($0) }), byExtendingSelection: false)
        WindowPresentationState.scroll(scroll, to: state.scrollOffset)
    }
    override var isFlipped: Bool { true }
    var onBack: (() -> Void)?
    var onSummaryChanged: (() -> Void)?
    var onOpen: ((String, Int64?, SavedExcerpt?) -> Void)?
    private let back = FlatActionButton(), submit = FlatActionButton(), more = FlatActionButton(), cancel = FlatActionButton(), open = FlatActionButton(), copy = FlatActionButton()
    private let chatsButton = FlatActionButton(), messagesButton = FlatActionButton(), savedButton = FlatActionButton()
    private let query = NSSearchField()
    private let info = NSTextField(labelWithString: "")
    private let semanticControls = SemanticControlsView(frame: .zero)
    private let coordinator: SemanticCoordinator
    private let searchOwner = UUID()
    private var statusObservation: UUID?
    private var previousToolFilter = false
    private var semanticHits = [SemanticHit]()
    private var expandedChats = Set<String>()
    private var rawPanel: NSPanel?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let library: ExplorerLibrary
    private let worker = DispatchQueue(label: "explorer.history-search", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var cancellation = HistoryCancellation()
    private var request = UUID()
    private var snapshot: ChatSnapshot?
    private var mode: Mode = .chats
    private var hits = [Hit]()
    private var cursor: HistorySearchCursor?
    private var scanned = 0, deferred = 0
    private var searchChats = [Chat]()
    private var activeQuery = ""
    private var day = Date()
    private var dayRole: DayFeedRole = .all
    private var dayCursor: DayFeedCursor?
    private var dayLoaded = false
    var feedSummary: String { "\(hits.count) SHOWN\(dayCursor != nil ? " · MORE AVAILABLE" : "")" }
    private var dark = false, green = false
    private var scale: CGFloat = 1
    private var buttons: [FlatActionButton] { [back,submit,more,cancel,open,copy,chatsButton,messagesButton,savedButton] }
    init(library: ExplorerLibrary, coordinator: SemanticCoordinator = .shared) {
        self.library = library; self.coordinator = coordinator; super.init(frame: .zero)
        for (button, title, action) in [(back,"‹ BACK",#selector(goBack)), (submit,"FIND",#selector(search)), (more,"CONTINUE",#selector(continueSearch)), (cancel,"CANCEL",#selector(stop)), (open,"OPEN",#selector(openSelected)), (copy,"COPY",#selector(copySelected)), (chatsButton,"CHATS",#selector(showChats)), (messagesButton,"MESSAGES",#selector(showMessages)), (savedButton,"SAVED",#selector(showSaved))] {
            button.title = title; button.target = self; button.action = action; addSubview(button)
        }
        query.placeholderString = "Find chats, topics or recorded text…"
        query.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        query.target = self; query.action = #selector(search); query.sendsSearchStringImmediately = false; query.sendsWholeSearchString = true
        addSubview(query)
        info.font = .monospacedSystemFont(ofSize: 9, weight: .regular); info.lineBreakMode = .byTruncatingTail; addSubview(info)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); column.title = "Results"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 76; table.intercellSpacing = .zero
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Search results. Double-click to read a source chat.")
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = table; scroll.borderType = .noBorder; addSubview(scroll)
        addSubview(semanticControls); semanticControls.isHidden = true
        semanticControls.show(options: coordinator.options)
        semanticControls.onSettings = { [weak self] in
            guard let self else { return }; self.coordinator.cancelSearch(owner: self.searchOwner); self.request = UUID(); self.cancel.isEnabled = false
            self.coordinator.setOptions(self.semanticControls.options)
            let includeTools = self.semanticControls.filters.includeTools
            if includeTools != self.previousToolFilter {
                self.previousToolFilter = includeTools
                self.coordinator.configureSourceScope(includeTools: includeTools)
            }
            self.info.stringValue = "Settings changed. Press Return to search. Start / Resume updates the source index if paused."
        }
        semanticControls.onStart = { [weak self] in self?.coordinator.startIndex() }
        semanticControls.onPause = { [weak self] in self?.coordinator.pauseIndex() }
        semanticControls.onCancel = { [weak self] in self?.coordinator.cancelIndex() }
        semanticControls.onEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            self.request = UUID(); self.cancel.isEnabled = false
            self.coordinator.setSemanticEnabled(enabled)
            self.info.stringValue = enabled ? "Semantic search enabled. Start / Resume indexing when ready." : "Semantic search off. Exact search uses saved text; your index is retained."
        }
        statusObservation = coordinator.observeStatus { [weak self] text, counts, running in
            guard let self else { return }
            // Shared options must reach hidden panes too, before their next control edit.
            self.semanticControls.show(options: self.coordinator.options)
            self.semanticControls.showStatus(text, counts: counts, running: running, semanticEnabled: self.coordinator.semanticEnabled, indexingState: self.coordinator.indexingState)
            if self.mode == .messages && !self.coordinator.isSearching(owner: self.searchOwner) { self.cancel.isEnabled = false }
        }
        setAccessibilityRole(.group); setAccessibilityLabel("Find chats and saved excerpts")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit {
        if let statusObservation { coordinator.removeStatusObserver(statusObservation) }
        coordinator.cancelSearch(owner: searchOwner)
        cancellation.cancel(); rawPanel?.close()
    }
    func show(snapshot: ChatSnapshot, mode: Mode = .chats) {
        self.snapshot = snapshot; self.mode = mode
        back.title = "‹ BACK"; chatsButton.title = "CHATS"; messagesButton.title = "MESSAGES"; savedButton.title = "SAVED"
        query.placeholderString = "Find chats, topics or recorded text…"
        query.stringValue = ""; search(); window?.makeFirstResponder(query)
    }
    /// Production-context render hook: saved results only; never starts model/source work.
    func showSemanticPreview(snapshot: ChatSnapshot, hits: [SemanticHit], counts: SemanticCounts) {
        self.snapshot = snapshot; mode = .messages; query.stringValue = "model"
        semanticControls.mode.selectItem(at: 2); semanticControls.refreshModeState()
        chatsButton.state = .off; messagesButton.state = .on; savedButton.state = .off
        semanticHits = hits; expandedChats.removeAll(); rebuildSemanticRows()
        semanticControls.showStatus("Saved local index · Exact search preview · no model call", counts: counts, running: false)
        info.stringValue = "\(hits.count) saved passages in \(Set(hits.map { $0.passage.chatID }).count) chats · double-click to open source"
        more.isEnabled = false; cancel.isEnabled = false
        table.rowHeight = resultRowHeight; table.reloadData(); needsLayout = true
    }
    func showDay(snapshot: ChatSnapshot, day: Date, force: Bool = false) {
        self.snapshot = snapshot
        if mode == .day, Calendar.current.isDate(self.day, inSameDayAs: day), dayLoaded, !force { return }
        let firstDayView = mode != .day
        mode = .day; self.day = day
        if firstDayView { query.stringValue = ""; dayRole = .all }
        back.title = "CHART"; chatsButton.title = "ALL"; messagesButton.title = "INPUTS"; savedButton.title = "REPLIES"
        query.placeholderString = "Find text in the selected day…"
        search()
    }
    func focusQuery() { window?.makeFirstResponder(query); query.selectText(nil) }
    func refreshOwnedData() {
        guard mode == .chats || mode == .saved else { return }
        let position = scroll.contentView.bounds.origin
        let selection = hits.indices.contains(table.selectedRow) ? hits[table.selectedRow] : nil
        search()
        if let selection, let index = hits.firstIndex(where: { $0.chatID == selection.chatID && $0.ordinal == selection.ordinal && $0.excerpt?.id == selection.excerpt?.id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        scroll.contentView.scroll(to: position); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func updateSnapshot(_ value: ChatSnapshot) { snapshot = value; coordinator.updateSnapshot(value) }
    func hideSearch() {
        cancellation.cancel(); request = UUID()
        if mode == .messages { coordinator.cancelSearch(owner: searchOwner) }
        if cancel.isEnabled {
            cancel.isEnabled = false
            more.isEnabled = mode == .day ? dayCursor != nil : cursor != nil
            info.stringValue = "Read cancelled. Existing results are retained; search again or Continue."
        }
    }
    func setTheme(dark: Bool, green: Bool, scale: CGFloat) {
        self.dark = dark; self.green = green; self.scale = scale
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let paper: NSColor = AppTheme.background(dark:dark), ink = AppTheme.ink(dark: dark, green: green)
        for button in buttons { button.dark = dark; button.green = green }
        query.textColor = ink; query.backgroundColor = paper
        info.textColor = AppTheme.muted(dark: dark, green: green)
        semanticControls.setTheme(dark: dark, green: green)
        table.backgroundColor = paper; table.rowHeight = resultRowHeight
        scroll.backgroundColor = paper
        table.reloadData(); needsDisplay = true
    }
    override func layout() {
        super.layout()
        back.isHidden = mode == .day
        back.frame = NSRect(x: 16, y: 8, width: 58, height: 24)
        let queryX: CGFloat = mode == .day ? 16 : 84
        query.frame = NSRect(x: queryX, y: 8, width: max(80, bounds.width - queryX - 94), height: 24)
        submit.frame = NSRect(x: bounds.width - 78, y: 8, width: 62, height: 24)
        var x: CGFloat = 16
        for (button,width) in [(chatsButton,CGFloat(68)),(messagesButton,88),(savedButton,68)] { button.frame = NSRect(x: x, y: 40, width: width, height: 24); x += width + 6 }
        let actionY: CGFloat = bounds.width < 660 ? 70 : 40
        let actionScale = min(1, max(0, (bounds.width - 50) / 276))
        let actionWidths: [CGFloat] = [82, 66, 62, 66].map { $0 * actionScale }
        var actionX = bounds.width - 16 - actionWidths.reduce(0, +) - 18
        for (button, width) in zip([more, cancel, copy, open], actionWidths) {
            button.frame = NSRect(x: actionX, y: actionY, width: width, height: 24)
            actionX += width + 6
        }
        var contentY = actionY + 31
        semanticControls.isHidden = mode != .messages
        if mode == .messages {
            let controlWidth = max(1, bounds.width - 32)
            let controlHeight = SemanticControlsView.preferredHeight(forWidth: controlWidth)
            semanticControls.frame = NSRect(x: 16, y: contentY, width: controlWidth, height: controlHeight)
            semanticControls.needsLayout = true
            contentY += controlHeight + 4
        }
        info.frame = NSRect(x: 16, y: contentY, width: max(1, bounds.width - 32), height: 18)
        scroll.frame = NSRect(x: 1, y: contentY + 23, width: max(1, bounds.width - 2), height: max(1, bounds.height - contentY - 24))
    }
    private var resultRowHeight: CGFloat { mode == .messages ? max(152, 52 + 100 * scale) : max(76, 28 + 48 * scale) }
    override func draw(_ dirtyRect: NSRect) { (AppTheme.background(dark:dark)).setFill(); bounds.fill() }
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ExplorerResultRow(); view.ink = AppTheme.palette(dark:dark,green:green).selection; return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard hits.indices.contains(row) else { return nil }
        let hit = hits[row]
        let identifier = NSUserInterfaceItemIdentifier("history-search-hit")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.rowHeight))
        view.identifier = identifier
        let title: NSTextField, detail: NSTextField
        if let existing = view.textField, let subtitle = view.viewWithTag(2) as? NSTextField { title = existing; detail = subtitle }
        else {
            title = NSTextField(labelWithString: ""); detail = NSTextField(labelWithString: ""); detail.tag = 2
            for field in [title,detail] { field.lineBreakMode = .byTruncatingTail; field.autoresizingMask = [.width]; view.addSubview(field) }
            view.textField = title
        }
        title.stringValue = hit.title; detail.stringValue = hit.detail
        let disclosure: NSButton
        if let existing = view.viewWithTag(3) as? NSButton { disclosure = existing }
        else { disclosure = NSButton(title: "", target: self, action: #selector(toggleChat(_:))); disclosure.tag = 3; disclosure.bezelStyle = .inline; view.addSubview(disclosure) }
        disclosure.isHidden = hit.groupCount < 2
        disclosure.title = "\(expandedChats.contains(hit.chatID) ? "▾" : "▸") \(hit.groupCount - 1) more passages"
        disclosure.identifier = NSUserInterfaceItemIdentifier(hit.chatID)
        disclosure.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        disclosure.attributedTitle = NSAttributedString(string: disclosure.title, attributes: [.foregroundColor: AppTheme.ink(dark: dark, green: green), .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
        disclosure.setAccessibilityLabel("\(expandedChats.contains(hit.chatID) ? "Collapse" : "Expand") additional matches in \(hit.title)")
        disclosure.frame = NSRect(x: 16, y: 6, width: 190, height: 22)
        var preview = view.viewWithTag(4) as? NSTextField
        if preview == nil {
            preview = NSTextField(wrappingLabelWithString: ""); preview!.tag = 4; preview!.maximumNumberOfLines = 3
            preview!.lineBreakMode = .byTruncatingTail; preview!.autoresizingMask = [.width]; view.addSubview(preview!)
        }
        preview!.isHidden = hit.semantic == nil
        if hit.semantic != nil {
            preview!.stringValue = String(hit.text.prefix(1500))
            preview!.font = .systemFont(ofSize: 12 * scale); preview!.textColor = AppTheme.ink(dark: dark, green: green)
            preview!.frame = NSRect(x: 16, y: hit.groupCount > 1 ? 32 : 10, width: max(1, tableView.bounds.width - 36), height: 54 * scale)
        }
        title.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular); title.textColor = AppTheme.ink(dark: dark, green: green)
        detail.font = .monospacedSystemFont(ofSize: 10 * scale, weight: .regular); detail.textColor = AppTheme.muted(dark: dark, green: green)
        title.frame = NSRect(x: 16, y: hit.semantic == nil ? 14 + 24 * scale : tableView.rowHeight - 30 * scale, width: max(1, tableView.bounds.width - 32), height: 24 * scale)
        detail.frame = NSRect(x: 16, y: hit.semantic == nil ? 10 : tableView.rowHeight - 52 * scale, width: max(1, tableView.bounds.width - 32), height: 22 * scale)
        view.toolTip = "\(hit.title)\n\(String(hit.text.prefix(1200)))\nChat: \(hit.chatID)\nDouble-click to open recorded messages."
        view.setAccessibilityLabel("\(hit.title), \(hit.detail)\(hit.semantic == nil ? "" : ", " + String(hit.text.prefix(600)))")
        return view
    }
    @objc private func showChats() { if mode == .day { dayRole = .all } else { mode = .chats }; search() }
    @objc private func showMessages() { if mode == .day { dayRole = .inputs } else { mode = .messages }; search() }
    @objc private func showSaved() { if mode == .day { dayRole = .replies } else { mode = .saved }; search() }
    @objc private func search() {
        cancellation.cancel(); coordinator.cancelSearch(owner: searchOwner); request = UUID(); cursor = nil; dayCursor = nil; scanned = 0; deferred = 0; hits.removeAll()
        semanticHits.removeAll(); expandedChats.removeAll()
        table.rowHeight = resultRowHeight; needsLayout = true
        if mode == .day {
            chatsButton.state = dayRole == .all ? .on : .off; messagesButton.state = dayRole == .inputs ? .on : .off; savedButton.state = dayRole == .replies ? .on : .off
            runDay(continuing: false); return
        }
        copy.toolTip = mode == .messages || mode == .day ? "Copy the result preview. Open its source chat for the complete recorded message." : "Copy the selected chat title or saved excerpt."
        chatsButton.state = mode == .chats ? .on : .off; messagesButton.state = mode == .messages ? .on : .off; savedButton.state = mode == .saved ? .on : .off
        more.isEnabled = false; cancel.isEnabled = false
        guard let snapshot else { info.stringValue = "Chat metadata unavailable."; table.reloadData(); return }
        let term = query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = library.state
        func matches(_ text: String) -> Bool { term.isEmpty || text.range(of: term, options: [.caseInsensitive,.diacriticInsensitive]) != nil }
        if mode == .chats {
            hits = snapshot.chats.filter { matches($0.title + " " + $0.project.name + " " + (saved.labels[$0.id]?.text ?? "")) }.map { chat in
                Hit(chatID: chat.id, ordinal: nil, title: (saved.favoriteChatIDs.contains(chat.id) ? "★ " : "") + chat.title,
                    detail: "\(chat.project.name)\(chat.archived ? " · ARCHIVED" : "")\(saved.labels[chat.id].map { " · \($0.text)" } ?? "")", text: saved.labels[chat.id]?.text ?? chat.title, excerpt: nil)
            }
            info.stringValue = "\(hits.count) chats · titles, projects and app-owned labels · double-click to read"
        } else if mode == .saved {
            hits = saved.excerpts.reversed().filter { matches($0.text + " " + $0.chatTitle) }.map {
                Hit(chatID: $0.chatID, ordinal: $0.ordinal, title: $0.chatTitle, detail: String($0.text.replacingOccurrences(of: "\n", with: " ").prefix(220)), text: $0.text, excerpt: $0)
            }
            hits += snapshot.chats.filter { saved.favoriteChatIDs.contains($0.id) && matches($0.title + " " + $0.project.name) }.map { Hit(chatID: $0.id, ordinal: nil, title: "★ " + $0.title, detail: $0.project.name, text: $0.title, excerpt: nil) }
            info.stringValue = library.issue ?? "\(hits.count) saved excerpts/starred chats · originals stay unchanged"
        } else {
            coordinator.updateSnapshot(snapshot)
            if term.isEmpty { info.stringValue = "Enter a question and press Return. Local sources stay unchanged; results open their original conversation." }
            else { runSemanticSearch(); return }
        }
        table.reloadData()
    }
    @objc private func continueSearch() { if mode == .day { runDay(continuing: true) } else { runSearch(continuing: true) } }
    private func runDay(continuing: Bool) {
        guard let snapshot else { return }
        cancellation.cancel(); let token = HistoryCancellation(); cancellation = token
        let id = UUID(); request = id; let cursor = continuing ? dayCursor : nil
        let selectedDay = day, role = dayRole, term = query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = HistoryStore.source(for: snapshot)
        let metadata = Dictionary(snapshot.chats.map { ($0.id, $0) }, uniquingKeysWith: { first,_ in first })
        cancel.isEnabled = true; more.isEnabled = false; info.stringValue = "Reading the selected day's recorded inputs and replies…"
        worker.async { [weak self] in
            let result = Result { try DayFeedStore.load(chats: snapshot.chats, source: source, day: selectedDay, role: role, query: term, after: cursor, cancellation: token) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == id, !token.cancelled else { return }
                self.cancel.isEnabled = false; self.dayLoaded = true
                switch result {
                case .success(let page):
                    self.dayCursor = page.cursor; self.scanned += page.scanned; self.deferred += page.deferred
                    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
                    for message in page.messages {
                        let title = metadata[message.chatID]?.title ?? message.chatID
                        let stamp = message.createdAt.map { clock.string(from: $0) } ?? "UNKNOWN TIME"
                        self.hits.append(Hit(chatID: message.chatID, ordinal: message.ordinal, title: "\(stamp) · \(message.role) · \(title)", detail: self.snippet(message.text, term: term), text: self.snippet(message.text, term: term, limit: 4000), excerpt: nil))
                    }
                    self.more.isEnabled = page.cursor != nil
                    self.info.stringValue = "\(self.hits.count) shown · \(self.scanned) records read · \(page.cursor == nil ? "day finished" : "Continue for more")\(self.deferred > 0 ? " · \(self.deferred) payloads need inspection" : "") · window focus is not recorded"
                case .failure(let error): self.info.stringValue = "UNAVAILABLE · \(error.localizedDescription)"
                }
                self.table.reloadData(); self.onSummaryChanged?()
            }
        }
    }

    private func runSearch(continuing: Bool) { runSemanticSearch() }
    private func runSemanticSearch() {
        let term = query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let id = UUID(); request = id; cancel.isEnabled = true; more.isEnabled = false
        table.reloadData(); info.stringValue = "Searching the local passage index…"
        coordinator.search(query: term, mode: semanticControls.searchMode, filters: semanticControls.filters, owner: searchOwner) { [weak self] result in
            guard let self, self.request == id, self.mode == .messages else { return }
            self.cancel.isEnabled = false
            switch result {
            case .success(let results):
                self.semanticHits = results; self.rebuildSemanticRows()
                let chats = Set(results.map { $0.passage.chatID }).count
                self.info.stringValue = "\(results.count) passages in \(chats) chats · ranked matches, not certainty · double-click to open source"
            case .failure(let error): self.info.stringValue = "UNAVAILABLE · \(error.localizedDescription)"
            }
            self.info.toolTip = self.info.stringValue; self.table.reloadData()
        }
    }
    private func rebuildSemanticRows() {
        let metadata = Dictionary((snapshot?.chats ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        hits = SemanticResultGroups.groups(semanticHits).flatMap { matches -> [Hit] in
            guard let chatID = matches.first?.passage.chatID else { return [] }
            return SemanticResultGroups.visible(matches, expanded: expandedChats.contains(chatID)).enumerated().compactMap { index, match in
                let passage = match.passage, chat = metadata[chatID]
                let date = passage.createdAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Time unavailable"
                return Hit(chatID: chatID, ordinal: passage.ordinal, title: chat?.title ?? chatID,
                           detail: "\(passage.role) · \(date) · \(chat?.project.name ?? "Project unavailable")\(chat?.archived == true ? " · ARCHIVED" : "")\(passage.isTool ? " · RAW TOOL SOURCE" : "")",
                           text: passage.text, excerpt: nil, semantic: passage, groupCount: index == 0 ? matches.count : 0)
            }
        }
    }
    @objc private func toggleChat(_ sender: NSButton) {
        guard let chatID = sender.identifier?.rawValue else { return }
        if expandedChats.contains(chatID) { expandedChats.remove(chatID) } else { expandedChats.insert(chatID) }
        rebuildSemanticRows(); table.reloadData()
    }
    private func snippet(_ text: String, term: String, limit: Int = 220) -> String {
        guard let range = text.range(of: term, options: [.caseInsensitive,.diacriticInsensitive]) else { return String(text.prefix(limit)) }
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        return (start > text.startIndex ? "…" : "") + String(text[start...].prefix(limit)).replacingOccurrences(of: "\n", with: " ")
    }
    @objc private func stop() { coordinator.cancelSearch(owner: searchOwner); cancellation.cancel(); request = UUID(); cancel.isEnabled = false; more.isEnabled = cursor != nil; info.stringValue = "Search cancelled. Existing results are retained." }
    @objc private func goBack() { hideSearch(); onBack?() }
    @objc private func openSelected() { let index = table.selectedRow; guard hits.indices.contains(index) else { return }; let hit = hits[index]
        if let passage = hit.semantic, passage.isTool || passage.itemID.hasPrefix("rollout:") { openRawSource(passage); return }
        onOpen?(hit.chatID,hit.ordinal,hit.excerpt)
    }
    private func openRawSource(_ passage: SemanticPassage) {
        rawPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Captured source passage · \(passage.chatID)"
        let scrolling = NSScrollView(frame: panel.contentView!.bounds); scrolling.autoresizingMask = [.width, .height]; scrolling.hasVerticalScroller = true
        let text = NSTextView(frame: scrolling.bounds); text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = SemanticSourcePresentation.header(passage) + "Loading captured bytes…"
        coordinator.sourcePayload(for: passage) { [weak text, weak panel] result in
            guard let text, panel?.isVisible == true else { return }
            text.string = SemanticSourcePresentation.render(passage, result: result)
        }
        text.textContainerInset = NSSize(width: 16, height: 16); text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scrolling.documentView = text; panel.contentView?.addSubview(scrolling); panel.center(); panel.makeKeyAndOrderFront(nil); rawPanel = panel
    }
    @objc private func copySelected() { let index = table.selectedRow; guard hits.indices.contains(index) else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hits[index].text, forType: .string) }
}
