import AppKit

func laneText(_ text: String, _ rect: NSRect, size: CGFloat = 12, bold: Bool = false, color: NSColor, twoLines: Bool = false) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = twoLines ? .byWordWrapping : .byTruncatingTail
    (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular),
        .foregroundColor: color, .paragraphStyle: style
    ])
}

func laneLine(_ from: NSPoint, _ to: NSPoint, color: NSColor, width: CGFloat = 1) {
    color.setStroke()
    let path = NSBezierPath(); path.lineWidth = width
    path.move(to: from); path.line(to: to); path.stroke()
}

func chatColor(_ index: Int, dark: Bool, green: Bool = false) -> NSColor {
    if green { return AppTheme.phosphor }
    let hues: [CGFloat] = [0.12, 0.92, 0.49, 0.35, 0.60, 0.76, 0.05, 0.66, 0.42, 0.82, 0.20, 0.55]
    return AppTheme.semantic(NSColor(calibratedHue:hues[index % hues.count],saturation:dark ? 0.50 : 0.80,brightness:dark ? 0.90 : 0.65,alpha:1))
}

final class NativeLaneCanvas: NSView {
    var onOpenChat: ((String, Int64?) -> Void)?
    struct Row { let y: CGFloat; let event: LaneEvent?; let day: String? }
    static let rowHeight: CGFloat = 64
    static let laneWidth: CGFloat = 30
    override var isFlipped: Bool { true }
    var green = false { didSet { needsDisplay = true } }
    var dark = false { didSet { needsDisplay = true } }
    var focus: Int? { didSet { needsDisplay = true } }
    var laneOffset: CGFloat = 0 { didSet { needsDisplay = true } }
    var onHorizontalScroll: ((CGFloat) -> Void)?
    private(set) var snapshot: LaneSnapshot?
    private(set) var events = [LaneEvent]()
    private(set) var rows = [Row]()
    private var spans = [Int: (CGFloat, CGFloat)]()
    private let dayFormatter = DateFormatter()
    private let timeFormatter = DateFormatter()
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private var paper: NSColor { AppTheme.background(dark:dark) }
    var eventLeft: CGFloat { min(max(270, 116 + CGFloat(snapshot?.chats.count ?? 5) * Self.laneWidth), max(270, bounds.width - min(460, bounds.width * 0.42))) }
    var graphRect: NSRect { NSRect(x: 96, y: 0, width: max(30, eventLeft - 110), height: bounds.height) }
    var maxLaneOffset: CGFloat { max(0, CGFloat(snapshot?.chats.count ?? 0) * Self.laneWidth - graphRect.width) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for formatter in [dayFormatter, timeFormatter] {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
        }
        dayFormatter.dateFormat = "EEEE, d MMMM yyyy"
        timeFormatter.dateFormat = "HH:mm"
        setAccessibilityRole(.list)
        setAccessibilityLabel("Recorded chat creation and your messages, oldest first")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func show(_ snapshot: LaneSnapshot, from: Date, until: Date) {
        self.snapshot = snapshot
        events = snapshot.events.filter { $0.date.map { $0 >= from && $0 < until } ?? true }
        rows.removeAll(keepingCapacity: true); spans.removeAll(keepingCapacity: true)
        var y: CGFloat = 0, previousDay = ""
        for event in events {
            let day = event.date.map { dayFormatter.string(from: $0).uppercased() } ?? "UNKNOWN RECORDED DATE"
            if day != previousDay { rows.append(Row(y: y, event: nil, day: day)); y += 34; previousDay = day }
            rows.append(Row(y: y, event: event, day: nil))
            let center = y + Self.rowHeight / 2
            let prior = spans[event.chatIndex]
            spans[event.chatIndex] = (prior?.0 ?? center, center)
            y += Self.rowHeight
        }
        setFrameSize(NSSize(width: max(1, frame.width), height: max(y + 20, enclosingScrollView?.contentSize.height ?? 1)))
        laneOffset = min(laneOffset, maxLaneOffset)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2, let event = rows.first(where: { $0.event != nil && point.y >= $0.y && point.y < $0.y + Self.rowHeight })?.event,
           let snapshot, snapshot.chats.indices.contains(event.chatIndex) {
            let ordinal = event.kind == .userMessage ? event.key.split(separator: ":").last.flatMap { Int64($0) } : nil
            onOpenChat?(snapshot.chats[event.chatIndex].id, ordinal)
        } else { super.mouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); dirtyRect.fill()
        guard let snapshot else { return }
        let graph = graphRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: graph.intersection(dirtyRect)).addClip()
        let first = max(0, Int(laneOffset / Self.laneWidth))
        let last = min(snapshot.chats.count, first + Int(graph.width / Self.laneWidth) + 2)
        for chat in first..<max(first, last) {
            guard let span = spans[chat] else { continue }
            let x = graph.minX + CGFloat(chat) * Self.laneWidth + 15 - laneOffset
            let alpha: CGFloat = focus == nil || focus == chat ? 0.65 : 0.13
            laneLine(NSPoint(x: x, y: span.0), NSPoint(x: x, y: span.1), color: chatColor(chat, dark: dark, green: green).withAlphaComponent(alpha), width: 1.5)
        }
        NSGraphicsContext.restoreGraphicsState()
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].y + Self.rowHeight < dirtyRect.minY { lo = mid + 1 } else { hi = mid }
        }
        for row in rows[lo...] {
            if row.y > dirtyRect.maxY { break }
            if let day = row.day {
                paper.setFill(); NSRect(x: 0, y: row.y, width: bounds.width, height: 34).fill()
                laneText(day, NSRect(x: 16, y: row.y + 10, width: bounds.width - 32, height: 18), size: 10, bold: true, color: ink)
                continue
            }
            guard let event = row.event else { continue }
            let chat = snapshot.chats[event.chatIndex]
            let alpha: CGFloat = focus == nil || focus == event.chatIndex ? 1 : 0.25
            let color = chatColor(event.chatIndex, dark: dark, green: green).withAlphaComponent(alpha)
            laneText(event.date.map { timeFormatter.string(from: $0) } ?? "--:--", NSRect(x: 16, y: row.y + 25, width: 70, height: 18), size: 11, color: ink.withAlphaComponent(alpha * 0.65))
            let x = graph.minX + CGFloat(event.chatIndex) * Self.laneWidth + 15 - laneOffset
            if x >= graph.minX + 5 && x <= graph.maxX - 5 {
                if event.kind == .creation {
                    let diamond = NSBezierPath()
                    diamond.move(to: NSPoint(x: x, y: row.y + 26))
                    diamond.line(to: NSPoint(x: x + 6, y: row.y + 32))
                    diamond.line(to: NSPoint(x: x, y: row.y + 38))
                    diamond.line(to: NSPoint(x: x - 6, y: row.y + 32))
                    diamond.close(); paper.setFill(); diamond.fill(); color.setStroke(); diamond.lineWidth = 1.5; diamond.stroke()
                } else { color.setFill(); NSBezierPath(ovalIn: NSRect(x: x - 4, y: row.y + 28, width: 8, height: 8)).fill() }
            }
            let meta = "\(event.kind == .creation ? "NEW CHAT" : "YOUR MESSAGE") · \(event.chatIndex + 1) · \(chat.title)\(chat.archived ? " · ARCHIVED" : "")"
            laneText(meta, NSRect(x: eventLeft, y: row.y + 8, width: bounds.width - eventLeft - 16, height: 15), size: 9, color: color)
            let preview = event.preview.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            laneText(preview, NSRect(x: eventLeft, y: row.y + 25, width: bounds.width - eventLeft - 16, height: 34), size: 12, bold: event.kind == .creation, color: ink.withAlphaComponent(alpha * (chat.archived ? 0.65 : 1)), twoLines: true)
            laneLine(NSPoint(x: eventLeft, y: row.y + 63.5), NSPoint(x: bounds.width - 16, y: row.y + 63.5), color: ink.withAlphaComponent(0.16))
        }
        if events.isEmpty { laneText("No recorded events in these dates.", NSRect(x: 16, y: 25, width: bounds.width - 32, height: 25), color: ink) }
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { onHorizontalScroll?(-event.scrollingDeltaX) }
        else { super.scrollWheel(with: event) }
    }
}

private final class NativeChatChip: NSButton {
    var green = false
    var dark = false
    var selected = false
    override func draw(_ dirtyRect: NSRect) {
        (AppTheme.background(dark:dark)).setFill(); bounds.fill()
        AppTheme.ink(dark: dark, green: green).withAlphaComponent(selected ? 1 : 0.45).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = selected ? 2 : 1; border.stroke()
        super.draw(dirtyRect)
    }
}

final class NativeLaneRoot: NSView, NSTextFieldDelegate {
    struct PresentationState {
        var snapshot: LaneSnapshot?
        var from: String; var to: String
        var focus: Int?; var laneOffset: CGFloat
        var scrollOffset: NSPoint; var chipOffset: NSPoint
        var error: String?
    }
    func capturePresentationState() -> PresentationState {
        PresentationState(snapshot: snapshot, from: fromField.stringValue, to: toField.stringValue,
                          focus: canvas.focus, laneOffset: canvas.laneOffset, scrollOffset: scroll.contentView.bounds.origin,
                          chipOffset: chipScroll.contentView.bounds.origin, error: errorText)
    }
    func restorePresentationState(_ state: PresentationState) {
        if let snapshot = state.snapshot { show(snapshot) }
        fromField.stringValue = state.from; toField.stringValue = state.to
        if state.snapshot != nil { datesChanged() }
        canvas.focus = state.focus.flatMap { snapshot?.chats.indices.contains($0) == true ? $0 : nil }
        if state.laneOffset.isFinite { canvas.laneOffset = min(canvas.maxLaneOffset, max(0, state.laneOffset)) }
        errorText = state.error; updateScroller(); applyTheme()
        WindowPresentationState.scroll(scroll, to: state.scrollOffset)
        WindowPresentationState.scroll(chipScroll, to: state.chipOffset)
    }
    override var isFlipped: Bool { true }
    let canvas = NativeLaneCanvas(frame: .zero)
    let scroll = NSScrollView()
    private let chipScroll = NSScrollView()
    private let chipDocument = NSView()
    private let horizontal = NSScroller()
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private var chips = [NativeChatChip]()
    private(set) var snapshot: LaneSnapshot?
    private var errorText: String?
    private var green = false
    private var dark = false
    private let dateFormatter = DateFormatter()
    private var calendar = Calendar(identifier: .gregorian)
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private var paper: NSColor { AppTheme.background(dark:dark) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone; dateFormatter.dateFormat = "yyyy-MM-dd"
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.documentView = canvas; canvas.autoresizingMask = [.width]; addSubview(scroll)
        chipScroll.hasHorizontalScroller = true; chipScroll.autohidesScrollers = true
        chipScroll.scrollerStyle = .overlay; chipScroll.borderType = .noBorder; chipScroll.drawsBackground = false
        chipScroll.documentView = chipDocument; addSubview(chipScroll)
        horizontal.target = self; horizontal.action = #selector(scrollLanes); addSubview(horizontal)
        for field in [fromField, toField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.isBezeled = false; field.isBordered = true; field.drawsBackground = true
            field.focusRingType = .none; field.delegate = self
            field.target = self; field.action = #selector(datesChanged); addSubview(field)
        }
        fromField.setAccessibilityLabel("From date, YYYY-MM-DD")
        toField.setAccessibilityLabel("To date, YYYY-MM-DD")
        canvas.onHorizontalScroll = { [weak self] delta in self?.panLanes(delta) }
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func layout() {
        super.layout()
        fromField.frame = NSRect(x: 61, y: 8, width: 132, height: 25)
        toField.frame = NSRect(x: 236, y: 8, width: 132, height: 25)
        chipScroll.frame = NSRect(x: 16, y: 46, width: bounds.width - 32, height: 35)
        scroll.frame = NSRect(x: 1, y: 109, width: bounds.width - 2, height: max(1, bounds.height - 171))
        canvas.setFrameSize(NSSize(width: scroll.contentView.bounds.width, height: max(canvas.frame.height, scroll.contentView.bounds.height)))
        horizontal.frame = NSRect(x: 97, y: bounds.height - 56, width: max(30, canvas.graphRect.width), height: 15)
        updateScroller()
    }

    func show(_ snapshot: LaneSnapshot) {
        let previousOffset = scroll.contentView.bounds.origin
        let previousFrom = fromField.stringValue, previousTo = toField.stringValue
        let focusID = canvas.focus.flatMap { index in self.snapshot?.chats.indices.contains(index) == true ? self.snapshot?.chats[index].id : nil }
        let hadSnapshot = self.snapshot != nil
        self.snapshot = snapshot; errorText = nil
        if let first = snapshot.events.compactMap(\.date).min(), let last = snapshot.events.compactMap(\.date).max() {
            fromField.stringValue = dateFormatter.string(from: first)
            toField.stringValue = dateFormatter.string(from: last)
        }
        if snapshot.events.isEmpty {
            fromField.stringValue = dateFormatter.string(from: Date()); toField.stringValue = fromField.stringValue
        }
        chips.forEach { $0.removeFromSuperview() }; chips.removeAll()
        let indices = [-1] + Array(snapshot.chats.indices.suffix(5))
        var x: CGFloat = 0
        for index in indices {
            let chip = NativeChatChip(frame: NSRect(x: x, y: 0, width: index < 0 ? 86 : 180, height: 25))
            chip.isBordered = false; chip.target = self; chip.action = #selector(focusChat)
            chip.tag = index; chip.lineBreakMode = .byTruncatingTail
            chip.toolTip = index < 0 ? "Show every chat at full emphasis" : snapshot.chats[index].title
            chipDocument.addSubview(chip); chips.append(chip); x += chip.frame.width + 7
        }
        chipDocument.frame = NSRect(x: 0, y: 0, width: x, height: 25)
        if hadSnapshot { fromField.stringValue = previousFrom; toField.stringValue = previousTo }
        canvas.focus = focusID.flatMap { id in snapshot.chats.firstIndex { $0.id == id } }
        applyTheme(); datesChanged()
        if hadSnapshot { scroll.contentView.scroll(to: previousOffset); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    func showError(_ message: String) { errorText = message; needsDisplay = true }
    func showOverlap() {
        // Choose an initial viewport containing multiple chats; the date scope and row order stay intact.
        layoutSubtreeIfNeeded()
        var days = [Date: Set<Int>]()
        for event in canvas.events {
            if let date = event.date { days[calendar.startOfDay(for: date), default: []].insert(event.chatIndex) }
        }
        guard let day = days.keys.sorted().first(where: { (days[$0]?.count ?? 0) >= 3 }),
              let index = canvas.rows.firstIndex(where: { $0.event?.date.map { $0 >= day } ?? false }) else { return }
        let row = canvas.rows[max(0, index - 1)]
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(row.y, max(0, canvas.frame.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func setDark(_ value: Bool) { setTheme(value ? .dark : .light) }
    func setTheme(_ theme: AppTheme) { dark = theme.isDark; green = theme == .green; applyTheme() }
    func setFocus(_ index: Int?) {
        canvas.focus = index
        if let index {
            canvas.laneOffset = min(canvas.maxLaneOffset, max(0, CGFloat(index) * NativeLaneCanvas.laneWidth - canvas.graphRect.width / 2))
        }
        updateScroller(); applyTheme()
    }

    @objc private func focusChat(_ sender: NSButton) { setFocus(sender.tag < 0 || canvas.focus == sender.tag ? nil : sender.tag) }
    @objc private func datesChanged() {
        guard let snapshot else { return }
        guard let from = dateFormatter.date(from: fromField.stringValue), let to = dateFormatter.date(from: toField.stringValue), from <= to,
              let until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) else {
            errorText = "Enter a valid date range as YYYY-MM-DD."; needsDisplay = true; return
        }
        errorText = nil
        canvas.show(snapshot, from: calendar.startOfDay(for: from), until: until)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        updateScroller(); needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { datesChanged() }
    @objc private func scrollLanes() { canvas.laneOffset = CGFloat(horizontal.doubleValue) * canvas.maxLaneOffset; needsDisplay = true }
    private func panLanes(_ delta: CGFloat) { canvas.laneOffset = min(canvas.maxLaneOffset, max(0, canvas.laneOffset + delta)); updateScroller(); needsDisplay = true }
    private func updateScroller() {
        let total = max(1, CGFloat(snapshot?.chats.count ?? 0) * NativeLaneCanvas.laneWidth)
        horizontal.knobProportion = min(1, canvas.graphRect.width / total)
        horizontal.doubleValue = canvas.maxLaneOffset > 0 ? Double(canvas.laneOffset / canvas.maxLaneOffset) : 0
        horizontal.isEnabled = canvas.maxLaneOffset > 0
    }
    private func applyTheme() {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        canvas.dark = dark; canvas.green = green
        for field in [fromField, toField] { field.textColor = ink; field.backgroundColor = paper }
        for chip in chips {
            chip.dark = dark; chip.green = green; chip.selected = canvas.focus == nil ? chip.tag < 0 : canvas.focus == chip.tag
            let title = chip.tag < 0 ? "ALL CHATS" : "\(chip.tag + 1) \(snapshot?.chats[chip.tag].title ?? "")"
            chip.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: chip.tag < 0 ? ink : chatColor(chip.tag, dark: dark, green: green)])
            chip.needsDisplay = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); bounds.fill(); AppTheme.border(dark:dark,green:green).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        laneText("FROM", NSRect(x: 16, y: 15, width: 40, height: 16), size: 10, color: ink)
        laneText("TO", NSRect(x: 211, y: 15, width: 25, height: 16), size: 10, color: ink)
        laneText("OLDEST FIRST ↓", NSRect(x: bounds.width - 146, y: 15, width: 130, height: 16), size: 10, color: ink)
        laneText("TIME", NSRect(x: 16, y: 92, width: 70, height: 16), size: 10, color: ink)
        laneText("EVENT", NSRect(x: canvas.eventLeft, y: 92, width: 100, height: 16), size: 10, color: ink)
        let first = max(0, Int(canvas.laneOffset / NativeLaneCanvas.laneWidth))
        let last = min(snapshot?.chats.count ?? 0, first + Int(canvas.graphRect.width / NativeLaneCanvas.laneWidth) + 1)
        for index in first..<max(first, last) {
            let x = canvas.graphRect.minX + CGFloat(index) * NativeLaneCanvas.laneWidth + 5 - canvas.laneOffset
            laneText("\(index + 1)", NSRect(x: x, y: 92, width: 28, height: 16), size: 10, color: chatColor(index, dark: dark, green: green))
        }
        laneLine(NSPoint(x: 0, y: 108.5), NSPoint(x: bounds.width, y: 108.5), color: ink)
        laneLine(NSPoint(x: 0, y: bounds.height - 35.5), NSPoint(x: bounds.width, y: bounds.height - 35.5), color: ink)
        let footer = errorText ?? "\(snapshot?.chats.count ?? 0) CHATS · \(snapshot?.issues ?? 0) SOURCE ISSUES · ◇ CHAT CREATED   ● YOUR MESSAGE   · \(canvas.events.count) EVENTS · RECORDED SNAPSHOT"
        laneText(footer, NSRect(x: 16, y: bounds.height - 25, width: bounds.width - 32, height: 18), size: 9, color: ink)
        if snapshot == nil, let errorText { laneText(errorText, NSRect(x: 16, y: 140, width: bounds.width - 32, height: 80), color: ink) }
    }

    func render(to url: URL) throws {
        layoutSubtreeIfNeeded(); displayIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { throw StoreError(message: "Cannot render prototype.") }
        cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw StoreError(message: "Cannot encode preview.") }
        try png.write(to: url)
    }
}
