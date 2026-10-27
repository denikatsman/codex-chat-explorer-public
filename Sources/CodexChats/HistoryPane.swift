import AppKit
import ExplorerDiagnosticsBridge

final class FlatActionButton: NSButton {
    var dark = false { didSet { needsDisplay = true } }
    var green = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    // The system monospaced face caused a reproducible CoreText exception in FIND's
    // custom-button render path. An explicit public fixed-pitch face avoids it.
    private static let titleFont = NSFont(name: "Menlo-Bold", size: 10) ?? NSFont.boldSystemFont(ofSize: 10)
    override func draw(_ dirtyRect: NSRect) {
        let ink = AppTheme.ink(dark: dark, green: green), paper: NSColor = AppTheme.background(dark:dark)
        (state == .on ? AppTheme.palette(dark:dark,green:green).selection : paper).setFill(); bounds.fill()
        (isEnabled ? AppTheme.border(dark:dark,green:green) : AppTheme.muted(dark:dark,green:green)).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = .center
        let titleColor = isEnabled ? (state == .on ? AppTheme.palette(dark:dark,green:green).onSelection : ink) : AppTheme.muted(dark: dark, green: green)
        (title as NSString).draw(in: NSRect(x: 3, y: max(0, (bounds.height - 15) / 2), width: bounds.width - 6, height: 16), withAttributes: [.font:Self.titleFont, .foregroundColor:titleColor, .paragraphStyle:paragraph])
    }
}

final class HistoryPane: NSView, NSTextViewDelegate {
    struct PresentationState {
        var chat: Chat?; var snapshot: ChatSnapshot?; var page: HistoryPage?
        var rawMessage: RecordedMessage?; var expandedOrdinal: Int64?; var savedExcerpt: SavedExcerpt?
        var title: String; var titleTip: String?; var text: String; var status: String
        var selection: NSRange; var scrollOffset: NSPoint; var wasLoading: Bool
    }
    func capturePresentationState() -> PresentationState {
        PresentationState(chat: chat, snapshot: snapshot, page: page, rawMessage: rawMessage,
                          expandedOrdinal: expandedOrdinal, savedExcerpt: savedExcerpt, title: titleField.stringValue,
                          titleTip: titleField.toolTip, text: textView.string, status: info.stringValue,
                          selection: textView.selectedRange(), scrollOffset: scroll.contentView.bounds.origin, wasLoading: loading)
    }
    func restorePresentationState(_ state: PresentationState) {
        cancellation.cancel(); request = UUID(); loading = false
        chat = state.chat; snapshot = state.snapshot; page = state.page; rawMessage = state.rawMessage
        expandedOrdinal = state.expandedOrdinal; savedExcerpt = state.savedExcerpt
        titleField.stringValue = state.title; titleField.toolTip = state.titleTip
        if page != nil { render(updateViewport: false) }
        else {
            renderedTextStyle = nil
            textView.string = state.wasLoading ? "This read is still running in the original window. Choose Latest to read this chat here." : state.text
        }
        info.stringValue = state.wasLoading ? "No read was started by duplication." : state.status
        textView.setSelectedRange(WindowPresentationState.selection(state.selection, length: textView.string.utf16.count))
        WindowPresentationState.scroll(scroll, to: state.scrollOffset)
        refreshButtons()
    }
    func refreshOwnedData() {
        let position = scroll.contentView.bounds.origin, selection = textView.selectedRange()
        let anchor = ranges.first { NSLocationInRange(selection.location, $0.0) }.map { ($0.1.reference, selection.location - $0.0.location) }
        render(preservingSelection: true)
        if let anchor, let range = ranges.first(where: { $0.1.reference == anchor.0 })?.0 {
            textView.setSelectedRange(WindowPresentationState.selection(NSRange(location: range.location + min(anchor.1, range.length), length: selection.length), length: textView.string.utf16.count))
        }
        WindowPresentationState.scroll(scroll, to: position)
        refreshButtons()
    }
    override var isFlipped: Bool { true }
    var onBack: (() -> Void)?
    var onLibraryChanged: (() -> Void)?
    var onGenerateLabel: ((Chat, ChatSnapshot) -> Void)?
    private let back = FlatActionButton(), earlier = FlatActionButton(), later = FlatActionButton(), latest = FlatActionButton(), raw = FlatActionButton(), full = FlatActionButton(), copy = FlatActionButton(), save = FlatActionButton(), star = FlatActionButton()
    let labelButton = FlatActionButton()
    private let titleField = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    let scroll = NSScrollView()
    private let textView = NSTextView()
    private let worker = DispatchQueue(label: "explorer.history-reader", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let library: ExplorerLibrary
    private var request = UUID()
    private var cancellation = HistoryCancellation()
    private(set) var chat: Chat?
    private var snapshot: ChatSnapshot?
    private var page: HistoryPage?
    private var ranges = [(NSRange, RecordedMessage)]()
    private var rawMessage: RecordedMessage?
    private var expandedOrdinal: Int64?
    private var savedExcerpt: SavedExcerpt?
    private var dark = false, green = false
    private var scale: CGFloat = 1
    private var renderedTextStyle: (dark: Bool, green: Bool, scale: CGFloat, ink: NSColor, muted: NSColor)?
    private(set) var loading = false
    var displayedMessageCount: Int { page?.messages.count ?? 0 }
    var statusText: String { info.stringValue }
    private var actions: [FlatActionButton] { [earlier,later,latest,raw,full,copy,save,star] }
    private var allButtons: [FlatActionButton] { [back] + actions + [labelButton] }
    init(library: ExplorerLibrary) {
        self.library = library
        super.init(frame: .zero)
        back.title = "‹ BACK"; earlier.title = "EARLIER"; later.title = "LATER"; latest.title = "LATEST"; raw.title = "RAW"; full.title = "LOAD"; copy.title = "COPY"; save.title = "SAVE EXCERPT"; star.title = "STAR"; labelButton.title = "AI SUMMARY"
        let selectors: [Selector] = [#selector(goBack),#selector(previousPage),#selector(nextPage),#selector(latestPage),#selector(toggleRaw),#selector(loadFull),#selector(copyText),#selector(saveExcerpt),#selector(toggleStar),#selector(generateLabel)]
        for (button, selector) in zip([back] + actions + [labelButton], selectors) { button.target = self; button.action = selector; addSubview(button) }
        labelButton.isHidden = true
        full.toolTip = "Load the full selected message, up to 64 MiB."
        raw.toolTip = "Inspect the original indexed JSON payload for the message at the text cursor."
        save.toolTip = "Save selected displayed text with exact source-message references; originals stay unchanged."
        addSubview(titleField); addSubview(info)
        titleField.font = .monospacedSystemFont(ofSize: 12, weight: .bold); titleField.lineBreakMode = .byTruncatingTail
        info.font = .monospacedSystemFont(ofSize: 9, weight: .regular); info.lineBreakMode = .byTruncatingTail
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.delegate = self
        scroll.documentView = textView; addSubview(scroll)
        setAccessibilityRole(.group); setAccessibilityLabel("Recorded chat reader")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit { cancellation.cancel() }
    func show(chat: Chat, snapshot: ChatSnapshot, focus: Int64? = nil) {
        self.chat = chat; self.snapshot = snapshot; rawMessage = nil; expandedOrdinal = nil; savedExcerpt = nil
        titleField.stringValue = chat.title
        titleField.toolTip = "\(chat.title)\nChat ID: \(chat.id)\n\(chat.project.name)"
        load(after: nil, before: focus.map { $0 == Int64.max ? $0 : $0 + 1 }, focus: focus)
        refreshButtons()
    }
    func showSaved(_ excerpt: SavedExcerpt) {
        cancellation.cancel(); request = UUID(); loading = false; chat = nil; snapshot = nil; ranges.removeAll(); rawMessage = nil; savedExcerpt = excerpt
        renderedTextStyle = nil
        page = HistoryPage(messages: [], total: 0, hasMore: false, sourceURL: URL(fileURLWithPath: excerpt.sourcePath))
        titleField.stringValue = excerpt.chatTitle
        textView.string = excerpt.text
        textView.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        info.stringValue = "Saved displayed excerpt · original source may be unavailable · saved \(ISO8601DateFormatter().string(from: excerpt.savedAt))"
        refreshButtons()
    }
    func showUnavailable(title: String, reason: String) {
        let excerpt = SavedExcerpt(id: UUID(), chatID: title, chatTitle: title, messageReferences: [], ordinal: nil, sourcePath: "", text: reason, savedAt: Date())
        showSaved(excerpt); info.stringValue = "SOURCE UNAVAILABLE · this is not an empty conversation"
    }
    func hideReader() { ExplorerDiagnostics.event("reader.hide", ["loading": .flag(loading), "chat_id": chat.map { .text($0.id) } ?? .null]); cancellation.cancel(); request = UUID(); loading = false; page = nil; renderedTextStyle = nil; ranges.removeAll(); rawMessage = nil; textView.string = ""; refreshButtons() }
    func setTheme(dark: Bool, green: Bool, scale: CGFloat) {
        let ink = AppTheme.ink(dark: dark, green: green), muted = AppTheme.muted(dark: dark, green: green)
        let needsTranscriptRefresh: Bool
        if let style = renderedTextStyle {
            needsTranscriptRefresh = style.dark != dark || style.green != green || style.scale != scale
                || !style.ink.isEqual(ink) || !style.muted.isEqual(muted)
        } else { needsTranscriptRefresh = true }
        self.dark = dark; self.green = green; self.scale = scale
        let paper: NSColor = AppTheme.background(dark:dark)
        titleField.textColor = ink; info.textColor = muted
        textView.backgroundColor = paper
        // Setting textColor rewrites foreground attributes, including muted metadata.
        // Keep the resident attributed transcript intact when only reparenting/layout repeats.
        if needsTranscriptRefresh { textView.textColor = ink }
        textView.insertionPointColor = AppTheme.palette(dark:dark,green:green).accent
        textView.selectedTextAttributes=[.backgroundColor:AppTheme.palette(dark:dark,green:green).selection.withAlphaComponent(0.3)]
        scroll.backgroundColor = paper
        for button in allButtons { button.dark = dark; button.green = green }
        if needsTranscriptRefresh { refreshOwnedData() }
        needsDisplay = true
    }
    func refreshLabel() { refreshOwnedData() }
    override func layout() {
        super.layout()
        back.frame = NSRect(x: 16, y: 8, width: 58, height: 24)
        let labelWidth: CGFloat = labelButton.isHidden ? 0 : 106
        labelButton.frame = NSRect(x: bounds.width - 122, y: 8, width: 106, height: 24)
        titleField.frame = NSRect(x: 84, y: 11, width: max(1, bounds.width - 100 - labelWidth), height: 20)
        var x: CGFloat = 16
        for (button, width) in zip(actions, [62,62,62,44,54,48,104,54] as [CGFloat]) {
            button.frame = NSRect(x: x, y: 40, width: width, height: 24); x += width + 6
        }
        info.frame = NSRect(x: 16, y: 71, width: bounds.width - 32, height: 18)
        scroll.frame = NSRect(x: 1, y: 94, width: max(1, bounds.width - 2), height: max(1, bounds.height - 95))
        textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(textView.frame.height, scroll.contentSize.height)))
        textView.textContainer?.containerSize = NSSize(width: max(1, scroll.contentSize.width - 28), height: .greatestFiniteMagnitude)
    }
    override func draw(_ dirtyRect: NSRect) { (AppTheme.background(dark:dark)).setFill(); bounds.fill() }
    private func load(after: Int64?, before: Int64?, focus: Int64? = nil) {
        guard let chat, let snapshot else { return }
        cancellation.cancel(); let token = HistoryCancellation(); cancellation = token
        let id = UUID(); request = id; loading = true
        page = nil; renderedTextStyle = nil; ranges.removeAll(); rawMessage = nil
        textView.string = "Reading recorded messages…"; info.stringValue = "Reading recorded messages…"; refreshButtons()
        let source = HistoryStore.source(for: snapshot)
        let operation = ExplorerDiagnostics.begin("reader.page", ["chat_id": .text(chat.id), "after_ordinal": after.map(DiagnosticValue.integer) ?? .null, "before_ordinal": before.map(DiagnosticValue.integer) ?? .null])
        worker.async { [weak self] in
            ExplorerDiagnostics.event("reader.queue.start", operation: operation?.id, ["queue_wait_ms": .number(operation?.elapsedMS ?? 0)])
            let read = ExplorerDiagnostics.begin("reader.read", ["chat_id": .text(chat.id), "parent_operation": operation.map { .text($0.id) } ?? .null])
            let result = Result { try HistoryStore.page(chatID: chat.id, source: source, after: after, before: before, cancellation: token) }
            ExplorerDiagnostics.end("reader.read", read, ["cancelled": .flag(token.cancelled)])
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == id, !token.cancelled else { ExplorerDiagnostics.end("reader.page", operation, ["outcome": .text("discarded"), "cancelled": .flag(token.cancelled)]); return }
                self.loading = false
                switch result {
                case .success(let page): self.page = page; self.rawMessage = nil; self.render(focus: focus); ExplorerDiagnostics.end("reader.page", operation, ["outcome": .text("ok"), "messages": .integer(Int64(page.messages.count)), "total": .integer(Int64(page.total))])
                case .failure(let error): self.info.stringValue = "UNAVAILABLE · \(error.localizedDescription)"; self.textView.string = "The source could not be read. This is not an empty conversation."; ExplorerDiagnostics.end("reader.page", operation, ExplorerDiagnostics.error(error))
                }
                self.refreshButtons()
            }
        }
    }
    private func selectedMessage() -> RecordedMessage? {
        if let rawMessage { return rawMessage }
        let position = textView.selectedRange().location
        return ranges.first { NSLocationInRange(position, $0.0) }?.1 ?? ranges.first?.1
    }
    private func render(focus: Int64? = nil, preservingSelection: Bool = false, updateViewport: Bool = true) {
        guard let page else { return }
        let operation = ExplorerDiagnostics.begin("reader.render", ["messages": .integer(Int64(page.messages.count)), "raw": .flag(rawMessage != nil)])
        defer { ExplorerDiagnostics.end("reader.render", operation, ["display_utf16": .integer(Int64(textView.textStorage?.length ?? 0))]) }
        let selected = textView.selectedRange()
        let buffer = NSMutableAttributedString()
        let ink = AppTheme.ink(dark: dark, green: green), muted = AppTheme.muted(dark: dark, green: green)
        let font = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        ranges.removeAll(keepingCapacity: true)
        if let savedExcerpt {
            buffer.append(NSAttributedString(string: savedExcerpt.text, attributes: [.font: font, .foregroundColor: ink]))
            info.stringValue = "Saved displayed excerpt · original source may be unavailable · saved \(ISO8601DateFormatter().string(from: savedExcerpt.savedAt))"
        } else if let rawMessage {
            let display = rawMessage.rawDisplay
            buffer.append(NSAttributedString(string: String(display.prefix(200_000)), attributes: [.font: font, .foregroundColor: ink]))
            info.stringValue = "RAW · captured \(ISO8601DateFormatter().string(from: rawMessage.observedAt)) · \(rawMessage.payloadBytes) bytes\(display.count > 200_000 ? " · display limited; export for complete bytes" : "")"
        } else {
            if let chat, let label = library.state.labels[chat.id] {
                let sampled = label.sampledMessages.flatMap { count in label.totalMessages.map { " · \(count)/\($0) sampled messages" } } ?? ""
                let clock = DateFormatter(); clock.dateFormat = "d MMM yyyy HH:mm"
                buffer.append(NSAttributedString(string: "APP LABEL · \(label.provider) · \(clock.string(from: label.generatedAt))\(sampled)\n\(label.text)\nOriginal title: \(chat.title)\n\n", attributes: [.font: font, .foregroundColor: muted]))
            }
            let clock = ISO8601DateFormatter(); clock.timeZone = .current
            for message in page.messages {
                let start = buffer.length
                let stamp = message.createdAt.map { clock.string(from: $0) } ?? "UNKNOWN TIME"
                buffer.append(NSAttributedString(string: "\(message.role) · \(stamp)\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10 * scale, weight: .bold), .foregroundColor: muted]))
                let limit = expandedOrdinal == message.ordinal ? 200_000 : 20_000
                let text = String(message.text.prefix(limit)) + (message.text.count > limit ? "\n[Display preview limited. Use LOAD for this message or RAW to export its complete payload.]" : "")
                buffer.append(NSAttributedString(string: text + "\n\n", attributes: [.font: font, .foregroundColor: ink]))
                ranges.append((NSRange(location: start, length: buffer.length - start), message))
            }
            if page.messages.isEmpty { buffer.append(NSAttributedString(string: "No indexed user/assistant messages in this page. The local projection can omit history.", attributes: [.font: font, .foregroundColor: muted])) }
            info.stringValue = "\(page.messages.count) of \(page.total) indexed inputs/replies · tools/events excluded · select text to save an excerpt"
        }
        textView.textStorage?.setAttributedString(buffer)
        renderedTextStyle = (dark, green, scale, ink, muted)
        if updateViewport {
            if let focus, let range = ranges.first(where: { $0.1.ordinal == focus })?.0 { textView.setSelectedRange(NSRange(location: range.location, length: 0)); textView.scrollRangeToVisible(range) }
            else if preservingSelection { let safe = NSRange(location: min(selected.location, buffer.length), length: min(selected.length, max(0, buffer.length - min(selected.location, buffer.length)))); textView.setSelectedRange(safe); textView.scrollRangeToVisible(safe) }
            else { textView.setSelectedRange(NSRange(location: 0, length: 0)); scroll.contentView.scroll(to: .zero) }
        }
        refreshButtons()
    }
    private func refreshButtons() {
        for button in actions { button.isEnabled = !loading && page != nil }
        earlier.isEnabled = !loading && page?.hasEarlier == true
        later.isEnabled = !loading && page?.hasMore == true
        raw.state = rawMessage == nil ? .off : .on
        raw.isEnabled = !loading && selectedMessage() != nil
        full.isEnabled = !loading && selectedMessage().map { $0.rawPayload == nil || ($0.text.count > 20_000 && expandedOrdinal != $0.ordinal) } == true
        save.title = rawMessage == nil ? "SAVE EXCERPT" : "EXPORT RAW"
        star.state = chat.map { library.state.favoriteChatIDs.contains($0.id) } == true ? .on : .off
        star.isEnabled = !loading && chat != nil
        latest.isEnabled = !loading && chat != nil
        save.isEnabled = !loading && (chat != nil || rawMessage != nil)
        labelButton.isEnabled = !loading && chat != nil
    }
    func textViewDidChangeSelection(_ notification: Notification) { refreshButtons() }
    @objc private func goBack() { hideReader(); onBack?() }
    @objc private func previousPage() { load(after: nil, before: page?.messages.first?.ordinal) }
    @objc private func nextPage() { load(after: page?.messages.last?.ordinal, before: nil) }
    @objc private func latestPage() { load(after: nil, before: Int64.max) }
    @objc private func toggleRaw() { if rawMessage != nil { let focus = rawMessage?.ordinal; rawMessage = nil; render(focus: focus) } else { rawMessage = selectedMessage(); render() } }
    @objc private func copyText() {
        let range = textView.selectedRange()
        let text = range.length > 0 ? (textView.string as NSString).substring(with: range) : (rawMessage?.rawDisplay ?? selectedMessage()?.text ?? textView.string)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func loadFull() {
        guard let selected = selectedMessage() else { return }
        cancellation.cancel(); let token = HistoryCancellation(); cancellation = token; let id = UUID(); request = id; loading = true; refreshButtons()
        worker.async { [weak self] in
            let result = Result { () -> (RecordedMessage, HistoryPage) in
                let message = try HistoryStore.full(chatID: selected.chatID, ordinal: selected.ordinal, source: selected.sourceURL, cancellation: token)
                let neighbors = try HistoryStore.page(chatID: selected.chatID, source: selected.sourceURL, after: selected.ordinal - 1, limit: 1, cancellation: token)
                return (message, neighbors)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == id, !token.cancelled else { return }; self.loading = false
                switch result {
                case .success(let result): let (message, neighbors) = result; self.expandedOrdinal = message.ordinal; self.page = HistoryPage(messages: [message], total: neighbors.total, hasMore: neighbors.hasMore, sourceURL: selected.sourceURL, hasEarlier: neighbors.hasEarlier); self.rawMessage = nil; self.render(focus: message.ordinal)
                case .failure(let error): self.info.stringValue = error.localizedDescription
                }
                self.refreshButtons()
            }
        }
    }
    @objc private func saveExcerpt() {
        if let rawMessage { exportRaw(rawMessage); return }
        guard let chat else { return }
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 64_000 else { info.stringValue = "Select an excerpt of 1–64,000 characters first."; return }
        let text = (textView.string as NSString).substring(with: range)
        let sources = ranges.filter { NSIntersectionRange($0.0, range).length > 0 }.map(\.1)
        guard !sources.isEmpty else { info.stringValue = "Select text within a recorded message."; return }
        do {
            try library.save(SavedExcerpt(id: UUID(), chatID: chat.id, chatTitle: chat.title, messageReferences: sources.map(\.reference), ordinal: sources.first?.ordinal, sourcePath: page?.sourceURL.path ?? "", text: text, savedAt: Date(), sourceHashes: Dictionary(sources.compactMap { message in message.payloadDigest.map { (message.reference, $0) } }, uniquingKeysWith: { first,_ in first })))
            info.stringValue = "Excerpt saved locally with source references. Original chat unchanged."; onLibraryChanged?()
        } catch { info.stringValue = error.localizedDescription }
    }
    private func exportRaw(_ message: RecordedMessage) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "message-\(message.ordinal).json"; panel.title = "Export original indexed payload"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.info.stringValue = "Exporting original bytes…"
            let token = HistoryCancellation(); self.cancellation.cancel(); self.cancellation = token
            self.worker.async { [weak self] in
                let result = Result {
                    if message.rawPayload != nil { try HistoryStore.exportCaptured(message, to: url) }
                    else { try HistoryStore.export(chatID: message.chatID, ordinal: message.ordinal, source: message.sourceURL, to: url, cancellation: token) }
                }
                DispatchQueue.main.async { [weak self] in
                    switch result { case .success: self?.info.stringValue = message.rawPayload != nil ? "Captured payload bytes exported exactly as observed." : "Current source payload exported; it was not cached in the preview."; case .failure(let error): self?.info.stringValue = error.localizedDescription }
                }
            }
        }
    }
    @objc private func toggleStar() { guard let chat else { return }; do { try library.toggleFavorite(chat.id); refreshButtons(); onLibraryChanged?() } catch { info.stringValue = error.localizedDescription } }
    @objc private func generateLabel() { if let chat, let snapshot { onGenerateLabel?(chat, snapshot) } }
}
