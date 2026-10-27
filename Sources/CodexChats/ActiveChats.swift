import AppKit
import ModelSupport

private final class ActiveOpenAccessibility: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}

/// The snapshot remains authoritative for membership; annotations only reorder its rows.
struct ActiveRowLayout {
    struct Entry {
        let row: ActiveChatRow
        let y: CGFloat
        let pinned: Bool
    }
    static let rowHeight: CGFloat = 100
    static let startY: CGFloat = 51
    static let sectionHeight: CGFloat = 24
    let entries: [Entry]
    let pinnedHeadingY: CGFloat?
    let otherHeadingY: CGFloat?
    let height: CGFloat

    init(snapshot: ActiveSnapshot, pinnedIDs: Set<String>) {
        var seen = Set<String>()
        let unique = snapshot.rows.filter { seen.insert($0.id).inserted }
        func active(_ row: ActiveChatRow) -> Bool {
            snapshot.connected && row.host == "local" && row.confirmedAt != nil && ["working", "waiting"].contains(row.state)
        }
        let pinned = unique.filter { pinnedIDs.contains($0.id) && active($0) }
        let other = unique.filter { !pinnedIDs.contains($0.id) || !active($0) }
        var result = [Entry](), y = Self.startY
        var pinY: CGFloat?, otherY: CGFloat?
        if !pinned.isEmpty {
            pinY = y; y += Self.sectionHeight
            for row in pinned { result.append(Entry(row: row, y: y, pinned: true)); y += Self.rowHeight }
            if !other.isEmpty { otherY = y; y += Self.sectionHeight }
        }
        for row in other { result.append(Entry(row: row, y: y, pinned: false)); y += Self.rowHeight }
        entries = result; pinnedHeadingY = pinY; otherHeadingY = otherY; height = y + 24
    }
    enum Hit { case pin, tag, summary, row, none }
    static func controlRects(_ entry: Entry, width: CGFloat) -> (pin: NSRect, tag: NSRect, summary: NSRect) {
        let right = max(174, width - 22)
        let y = entry.y + (width >= 640 ? (rowHeight - 24) / 2 : 70)
        return (NSRect(x: right - 152, y: y + 2, width: 20, height: 20),
                NSRect(x: right - 126, y: y + 2, width: 20, height: 20),
                NSRect(x: right - 100, y: y, width: 100, height: 24))
    }
    static func textRects(_ entry: Entry, width: CGFloat) -> (status: NSRect, title: NSRect, metadata: NSRect) {
        let y = entry.y
        if width >= 640 {
            let right = controlRects(entry, width: width).pin.minX - 14
            return (NSRect(x: 22, y: y + 40, width: 106, height: 20),
                    NSRect(x: 134, y: y + 31, width: max(1, right - 134), height: 20),
                    NSRect(x: 134, y: y + 53, width: max(1, right - 134), height: 16))
        }
        return (NSRect(x: 22, y: y + 6, width: 115, height: 20),
                NSRect(x: 22, y: y + 28, width: max(1, width - 44), height: 20),
                NSRect(x: 22, y: y + 50, width: max(1, width - 44), height: 18))
    }
    static func hit(_ point: NSPoint, entry: Entry, width: CGFloat) -> Hit {
        let row = NSRect(x: 22, y: entry.y, width: max(1, width - 44), height: rowHeight)
        guard row.contains(point) else { return .none }
        let controls = controlRects(entry, width: width)
        if controls.pin.contains(point) { return .pin }
        if controls.tag.contains(point) { return .tag }
        if controls.summary.contains(point) { return .summary }
        return .row
    }
    static func showsWorking(_ row: ActiveChatRow, connected: Bool) -> Bool {
        connected && row.host == "local" && row.confirmedAt != nil && row.state == "working"
    }
}

final class ActiveChatsView: NSView {
    override var isFlipped: Bool { true }
    var dark = false { didSet { needsDisplay = true; updateWorkingIndicators() } }
    var green = false { didSet { needsDisplay = true; updateWorkingIndicators() } }
    private(set) var snapshot: ActiveSnapshot?
    private var annotations = ExplorerLibraryState()
    private var layoutRows: ActiveRowLayout?
    private var failure: String?
    var onOpenChat: ((String) -> Void)?
    var onTogglePinned: ((String) -> Void)?
    var onSetTag: ((String, ChatTagColor?) -> Void)?
    var onSummarize: ((String, LabelProvider) -> Void)?
    var projects = [String: String]() { didSet { accessibleRows = nil; needsDisplay = true } }
    private var accessibleRows: [NSAccessibilityElement]?
    private var accessibleRect = NSRect.zero
    private var accessibleWindow = NSRect.zero
    private var workingIndicators = [String: DateWorkingIndicator]()
    private var workingScrollObservation: NSObjectProtocol?
    private var workingWindowObservations = [NSObjectProtocol]()
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private var muted: NSColor { AppTheme.muted(dark: dark, green: green) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.list)
        setAccessibilityLabel("Connecting to live Codex activity")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    var summary: String {
        guard let snapshot else { return failure ?? "Connecting to Codex…" }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
        let state = snapshot.connected ? "STREAM CONNECTED" : "DISCONNECTED"
        return "\(state) · \(clock.string(from: Date(timeIntervalSince1970: snapshot.observedAt))) · \(snapshot.pending) CANDIDATES UNCONFIRMED"
    }
    func setAnnotations(_ state: ExplorerLibraryState) {
        annotations = state
        rebuildRows()
    }
    func show(_ value: ActiveSnapshot) {
        let changed = snapshot?.rows != value.rows || snapshot?.connected != value.connected || snapshot?.warning != value.warning
        snapshot = value; failure = nil
        if changed { rebuildRows() }
        updateAccessibilityLabel()
    }
    func showError(_ text: String) {
        failure = text
        if let old = snapshot {
            snapshot = ActiveSnapshot(connected: false, sequence: old.sequence, observedAt: old.observedAt,
                rows: old.rows.map { ActiveChatRow(id: $0.id, host: $0.host, title: $0.title, state: "unknown", confirmedAt: $0.confirmedAt) },
                pending: old.pending, warning: text, queryMs: old.queryMs, bytesReceived: old.bytesReceived)
        }
        rebuildRows()
        updateAccessibilityLabel()
    }
    private func updateAccessibilityLabel() {
        let count = snapshot?.confirmedCount ?? 0
        setAccessibilityLabel("\(count) confirmed active local chats. \(summary)")
    }
    private func rebuildRows() {
        // Retain the top visible source identity and offset when pinning reorders rows.
        let top = visibleRect.minY
        let anchor = top > ActiveRowLayout.startY ? layoutRows?.entries.first { $0.y + ActiveRowLayout.rowHeight > top } : nil
        let offset = anchor.map { top - $0.y }
        layoutRows = snapshot.map { ActiveRowLayout(snapshot: $0, pinnedIDs: annotations.pinnedChatIDs) }
        setFrameSize(NSSize(width: frame.width, height: max(layoutRows?.height ?? 75, enclosingScrollView?.contentView.bounds.height ?? 500)))
        if let anchor, let offset, let entry = layoutRows?.entries.first(where: { $0.row.id == anchor.row.id }), let clip = enclosingScrollView?.contentView {
            let maxY = max(0, bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, min(maxY, entry.y + offset))))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        accessibleRows = nil; needsDisplay = true; updateWorkingIndicators()
    }
    private func rowRect(_ entry: ActiveRowLayout.Entry) -> NSRect {
        NSRect(x: 22, y: entry.y, width: max(1, bounds.width - 44), height: ActiveRowLayout.rowHeight)
    }
    private func controlRects(_ entry: ActiveRowLayout.Entry) -> (pin: NSRect, tag: NSRect, summary: NSRect) {
        ActiveRowLayout.controlRects(entry, width: bounds.width)
    }
    private func makeMenu(_ id: String) -> NSMenu {
        ChatRowAppearance.menu(chatID: id, state: annotations, onPin: onTogglePinned, onTag: onSetTag, onSummary: onSummarize)
    }
    override func accessibilityChildren() -> [Any]? {
        if let accessibleRows, accessibleRect == visibleRect, accessibleWindow == (window?.frame ?? .zero) { return accessibleRows }
        var elements = [NSAccessibilityElement]()
        for entry in layoutRows?.entries ?? [] {
            let rect = rowRect(entry)
            guard rect.intersects(visibleRect) else { continue }
            let row = entry.row
            func add(_ name: String, rect: NSRect, press: @escaping () -> Void) {
                let element = ActiveOpenAccessibility(); element.press = press
                element.setAccessibilityElement(true); element.setAccessibilityEnabled(true); element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(name); element.setAccessibilityParent(self)
                element.setAccessibilityFrame(window?.convertToScreen(convert(rect, to: nil)) ?? .zero)
                elements.append(element)
            }
            let confirmed = row.confirmedAt.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) } ?? "unconfirmed"
            let state = ActiveRowLayout.showsWorking(row, connected: snapshot?.connected == true) ? "working" : (snapshot?.connected == true && row.host == "local" && row.confirmedAt != nil && row.state == "waiting") ? "waiting" : "unknown"
            let description = "\(state), \(row.title), \(projects[row.id] ?? "Project unavailable"), last runtime confirmation \(confirmed), chat \(row.id)"
            add(description, rect: rect) { [weak self] in self?.onOpenChat?(row.id) }
            let controls = controlRects(entry)
            let pinLabel = annotations.pinnedChatIDs.contains(row.id)
                ? (entry.pinned ? "Unpin \(row.title)" : "Unpin \(row.title). Pinned in DATE; activity unconfirmed")
                : "Pin \(row.title)"
            add(pinLabel, rect: controls.pin) { [weak self] in self?.onTogglePinned?(row.id) }
            add("Color tag for \(row.title)", rect: controls.tag) { [weak self] in self?.showMenu(for: row.id, at: controls.tag) }
            add("\(ChatRowAppearance.summaryText(for: row.id, in: annotations) == nil ? "Generate" : "Regenerate") local summary for \(row.title)", rect: controls.summary) { [weak self] in self?.onSummarize?(row.id, .local) }
        }
        accessibleRows = elements; accessibleRect = visibleRect; accessibleWindow = window?.frame ?? .zero
        return elements
    }
    private func showMenu(for id: String, at rect: NSRect) {
        let menu = makeMenu(id)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let entry = layoutRows?.entries.first(where: { rowRect($0).contains(point) }) else { return super.menu(for: event) }
        return makeMenu(entry.row.id)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let entry = layoutRows?.entries.first(where: { rowRect($0).contains(point) }) else { super.mouseDown(with: event); return }
        let controls = controlRects(entry)
        switch ActiveRowLayout.hit(point, entry: entry, width: bounds.width) {
        case .pin: if event.clickCount == 1 { onTogglePinned?(entry.row.id) }
        case .tag: if event.clickCount == 1 { showMenu(for: entry.row.id, at: controls.tag) }
        case .summary: if event.clickCount == 1 { onSummarize?(entry.row.id, .local) }
        case .row: if event.clickCount >= 2 { onOpenChat?(entry.row.id) } else { super.mouseDown(with: event) }
        case .none: super.mouseDown(with: event)
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeWorkingViewport() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeWorkingViewport() }
    override func viewDidHide() { super.viewDidHide(); updateWorkingIndicators() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateWorkingIndicators() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); accessibleRows = nil; updateWorkingIndicators() }
    private func observeWorkingViewport() {
        if let workingScrollObservation { NotificationCenter.default.removeObserver(workingScrollObservation) }
        workingScrollObservation = nil
        for observation in workingWindowObservations { NotificationCenter.default.removeObserver(observation) }
        workingWindowObservations.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
                workingWindowObservations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    if name == NSWindow.willCloseNotification { self?.removeWorkingIndicators() }
                    else { self?.updateWorkingIndicators() }
                })
            }
        }
        if window != nil, let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            workingScrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.updateWorkingIndicators() }
        }
        updateWorkingIndicators()
    }
    private func updateWorkingIndicators() {
        var visible = Set<String>()
        if let snapshot, snapshot.connected, let window, window.isVisible, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor {
            for entry in layoutRows?.entries ?? [] where ActiveRowLayout.showsWorking(entry.row, connected: snapshot.connected) {
                let status = ActiveRowLayout.textRects(entry, width: bounds.width).status
                let rect = NSRect(x: 22, y: status.midY - 6, width: 12, height: 12)
                guard rect.intersects(visibleRect) else { continue }
                visible.insert(entry.row.id)
                let indicator = workingIndicators[entry.row.id] ?? DateWorkingIndicator(frame: rect)
                indicator.frame = rect; indicator.contentTintColor = ink
                if indicator.superview == nil { addSubview(indicator) }
                workingIndicators[entry.row.id] = indicator
            }
        }
        for id in Array(workingIndicators.keys) where !visible.contains(id) {
            workingIndicators.removeValue(forKey: id)?.removeFromSuperview()
        }
    }
    private func removeWorkingIndicators() {
        for indicator in workingIndicators.values { indicator.removeFromSuperview() }
        workingIndicators.removeAll()
    }
    deinit {
        if let workingScrollObservation { NotificationCenter.default.removeObserver(workingScrollObservation) }
        for observation in workingWindowObservations { NotificationCenter.default.removeObserver(observation) }
    }
    override func draw(_ dirtyRect: NSRect) {
        AppTheme.background(dark: dark).setFill(); dirtyRect.fill()
        guard let snapshot else {
            label(failure ?? "Connecting to Codex's current runtime…", in: NSRect(x: 22, y: 25, width: max(1, bounds.width-44), height: 50), size: 12, color: muted); return
        }
        label(snapshot.warning.isEmpty ? "Confirmed local desktop activity · new chats discovered within 5 s" : snapshot.warning,
              in: NSRect(x: 22, y: 15, width: max(1, bounds.width-44), height: 30), size: 10, color: muted)
        if snapshot.rows.isEmpty {
            label("No confirmed active chats.\(snapshot.pending > 0 ? " Awaiting candidate confirmation." : "")",
                  in: NSRect(x: 22, y: 58, width: max(1, bounds.width-44), height: 40), size: 12, color: ink)
        }
        if let y = layoutRows?.pinnedHeadingY { label("PINNED", in: NSRect(x: 22, y: y+4, width: 100, height: 18), size: 10, weight: .bold, color: muted) }
        if let y = layoutRows?.otherHeadingY { label("OTHER", in: NSRect(x: 22, y: y+4, width: 100, height: 18), size: 10, weight: .bold, color: muted) }
        for (index, entry) in (layoutRows?.entries ?? []).enumerated() {
            let row = entry.row, rect = rowRect(entry), y = entry.y
            guard rect.intersects(dirtyRect) else { continue }
            let tag = annotations.tag(for: row.id)
            let summary = ChatRowAppearance.summaryText(for: row.id, in: annotations)
            ChatRowAppearance.draw(in: rect, alternate: index % 2 == 1, summarized: summary != nil, dark: dark, green: green)
            let working = ActiveRowLayout.showsWorking(row, connected: snapshot.connected)
            let state = working ? "RUNNING" : (snapshot.connected && row.host == "local" && row.confirmedAt != nil && row.state == "waiting") ? "◈ WAITING" : "? UNKNOWN"
            let text = ActiveRowLayout.textRects(entry, width: bounds.width)
            var statusRect = text.status
            if working { statusRect.origin.x += 17; statusRect.size.width -= 17 }
            ChatRowAppearance.drawText(state, in: statusRect, size: 11, weight: .bold, color: state == "? UNKNOWN" ? muted : ink)
            let controls = controlRects(entry)
            ChatRowAppearance.drawText(row.title, in: text.title, size: 13, color: ink)
            let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
            let confirmation = row.confirmedAt.map { "LAST CONFIRMED " + clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "NO RUNTIME CONFIRMATION"
            let metadata = summary.map { "AI · \($0) · " } ?? ""
            ChatRowAppearance.drawText("\(metadata)\(projects[row.id] ?? "Project unavailable") · \(confirmation) · \(row.id)", in: text.metadata, size: 10, color: muted)
            ChatRowAppearance.drawPin(in: controls.pin, pinned: annotations.pinnedChatIDs.contains(row.id), color: ink)
            let dot = NSRect(x: controls.tag.midX - 4, y: controls.tag.midY - 4, width: 8, height: 8)
            if let tag { ChatRowAppearance.tagColor(tag).setFill(); NSBezierPath(ovalIn: dot).fill() }
            else { muted.setStroke(); NSBezierPath(ovalIn: dot).stroke() }
            ChatRowAppearance.drawSummaryButton(in: controls.summary, summarized: summary != nil, dark: dark, green: green)
            line(from: NSPoint(x: 22, y: y+98.5), to: NSPoint(x: bounds.width-22, y: y+98.5), color: muted.withAlphaComponent(0.4))
        }
    }
}
