import AppKit

final class MessageDayView: NSView, NSViewToolTipOwner {
    struct PresentationState { var data: MessageDay?; var zoom: CGFloat; var fullDay: Bool; var status: String; var wasLoading: Bool }
    func capturePresentationState() -> PresentationState { PresentationState(data: data, zoom: zoom, fullDay: fullDay, status: status, wasLoading: loading) }
    func restorePresentationState(_ state: PresentationState) {
        data = state.data; zoom = state.zoom.isFinite ? min(256, max(1, state.zoom)) : 1
        fullDay = state.fullDay; loading = false
        status = state.wasLoading ? "The original window is loading this day. Refresh to read it here." : state.status
        rebuild()
    }
    var onOpenChat: ((String, Int64?) -> Void)?
    private struct Cluster { let marks: [MessageMark]; let x: CGFloat }
    private struct Lane { let source: MessageLane; let y: CGFloat; let clusters: [Cluster] }
    override var isFlipped: Bool { true }
    var green = false { didSet { needsDisplay = true } }
    var dark = false { didSet { styleButtons(); needsDisplay = true } }
    private(set) var data: MessageDay?
    private(set) var loading = false
    var status = "Loading message times…" { didSet { needsDisplay = true } }
    private var viewportWidth: CGFloat = 940
    private var zoom: CGFloat = 1
    private var fullDay = false
    private var cachedRange: DateInterval?
    private var lanes = [Lane]()
    private let fitButton = NSButton(), dayButton = NSButton(), minusButton = NSButton(), plusButton = NSButton()
    private var observer: NSObjectProtocol?
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private var paper: NSColor { AppTheme.background(dark:dark) }
    private var muted: NSColor { AppTheme.muted(dark: dark, green: green) }
    private var left: CGFloat { min(380, max(280, viewportWidth * 0.27)) }
    private var plotWidth: CGFloat { max(180, viewportWidth - left - 24) * zoom }
    private var range: DateInterval {
        if let cachedRange { return cachedRange }
        guard let data else { return DateInterval(start: Date(), duration: 86400) }
        if fullDay { return data.interval }
        let times = data.lanes.flatMap { $0.messages.map(\.time) } + data.lanes.compactMap(\.chat.createdAt).filter { $0 >= data.interval.start && $0 < data.interval.end }
        guard let first = times.min(), let last = times.max() else { return data.interval }
        let padding = max(300, last.timeIntervalSince(first) * 0.03)
        return DateInterval(start: max(data.interval.start, first.addingTimeInterval(-padding)), end: min(data.interval.end, last.addingTimeInterval(padding)))
    }
    private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, action, tip) in [(fitButton, #selector(fit), "Fit all recorded activity"), (dayButton, #selector(day), "Show the full day"), (minusButton, #selector(zoomOut), "Zoom out"), (plusButton, #selector(zoomIn), "Zoom in; scroll horizontally to move through time")] {
            button.isBordered = false; button.target = self; button.action = action
            button.toolTip = tip; button.setAccessibilityLabel(tip); addSubview(button)
        }
        setAccessibilityRole(.list)
        setAccessibilityLabel("Message timeline with counted bursts and a shared time axis")
        styleButtons()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let clip = superview as? NSClipView {
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.needsLayout = true; self?.needsDisplay = true }
        }
    }

    func setViewportWidth(_ width: CGFloat) {
        guard abs(viewportWidth - width) > 0.5 else { return }
        viewportWidth = width; rebuild()
    }
    func show(_ data: MessageDay) {
        self.data = data; loading = false
        status = data.lanes.isEmpty ? "No indexed messages or new chats on this day." : ""
        rebuild()
    }
    func beginLoading() { data = nil; loading = true; status = "Loading message times…"; rebuild() }
    func showError(_ message: String) { data = nil; loading = false; status = message; rebuild() }

    private func x(_ date: Date) -> CGFloat { left + 24 + CGFloat(date.timeIntervalSince(range.start) / range.duration) * (plotWidth - 48) }
    private func rebuild() {
        cachedRange = nil
        cachedRange = range
        lanes = (data?.lanes ?? []).enumerated().map { index, lane in
            var clusters = [[MessageMark]]()
            for mark in lane.messages {
                if let first = clusters.last?.first, x(mark.time) - x(first.time) < 80 { clusters[clusters.count - 1].append(mark) }
                else { clusters.append([mark]) }
            }
            return Lane(source: lane, y: 94 + CGFloat(index) * 104, clusters: clusters.map { Cluster(marks: $0, x: x($0[0].time)) })
        }
        setFrameSize(NSSize(width: left + plotWidth + 24, height: max(CGFloat(lanes.count) * 104 + 100, enclosingScrollView?.contentSize.height ?? 1)))
        removeAllToolTips(); addToolTip(bounds, owner: self, userData: nil)
        needsLayout = true; needsDisplay = true; styleButtons()
    }

    @objc private func fit() { fullDay = false; setZoom(1) }
    @objc private func day() { fullDay = true; setZoom(1) }
    @objc private func zoomIn() { setZoom(min(256, zoom * 2)) }
    @objc private func zoomOut() { setZoom(max(1, zoom / 2)) }
    private func setZoom(_ value: CGFloat) {
        let clip = enclosingScrollView?.contentView
        let center = clip.map { $0.bounds.minX + (left + $0.bounds.width) / 2 } ?? left + plotWidth / 2
        let fraction = max(0, min(1, (center - left) / plotWidth))
        zoom = value; rebuild()
        if let scroll = enclosingScrollView {
            let px = value == 1 ? 0 : max(0, min(frame.width - scroll.contentSize.width, left + fraction * plotWidth - (left + scroll.contentSize.width) / 2))
            scroll.contentView.scroll(to: NSPoint(x: px, y: scroll.contentView.bounds.minY)); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount >= 2, let lane = lanes.first(where: { point.y >= $0.y && point.y < $0.y + 104 }) else { super.mouseDown(with: event); return }
        let cluster = lane.clusters.first { abs($0.x - point.x) < 16 }
        let mark = cluster?.marks.count == 1 ? cluster?.marks.first : nil
        let ordinal: Int64?
        if case .integer(let value)? = mark?.original["rollout_ordinal"] { ordinal = value } else { ordinal = nil }
        onOpenChat?(lane.source.chat.id, ordinal)
    }

    override func magnify(with event: NSEvent) { setZoom(max(1, min(256, zoom * (1 + event.magnification)))) }

    override func layout() {
        super.layout()
        let top = visibleRect.minY, end = visibleRect.maxX - 22
        fitButton.frame = NSRect(x: end - 148, y: top + 9, width: 44, height: 23)
        dayButton.frame = NSRect(x: end - 104, y: top + 9, width: 44, height: 23)
        minusButton.frame = NSRect(x: end - 60, y: top + 9, width: 30, height: 23)
        plusButton.frame = NSRect(x: end - 30, y: top + 9, width: 30, height: 23)
    }
    private func styleButtons() {
        for (button, title) in [(fitButton, "FIT"), (dayButton, "DAY"), (minusButton, "−"), (plusButton, "+")] {
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: ink])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); dirtyRect.fill()
        guard let data else { label(status, in: NSRect(x: visibleRect.minX + 22, y: visibleRect.minY + 45, width: viewportWidth - 44, height: 25), size: 12, color: muted); return }
        let visible = visibleRect, duration = range.duration
        let desired = duration * 90 / Double(plotWidth)
        let step = [60.0, 300, 900, 1800, 3600, 7200, 14400, 21600].first { $0 >= desired } ?? 21600
        let base = data.interval.start.timeIntervalSince1970
        var ticks = [Date]()
        var value = ceil((range.start.timeIntervalSince1970 - base) / step) * step + base
        while value <= range.end.timeIntervalSince1970 { ticks.append(Date(timeIntervalSince1970: value)); value += step }
        for tick in ticks {
            let px = x(tick)
            if px >= visible.minX + left && px <= visible.maxX - 20 { line(from: NSPoint(x: px, y: visible.minY + 87), to: NSPoint(x: px, y: visible.maxY), color: muted.withAlphaComponent(0.2)) }
        }
        for lane in lanes where lane.y + 104 >= dirtyRect.minY && lane.y <= dirtyRect.maxY {
            let color = lane.source.chat.archived ? muted : ink
            line(from: NSPoint(x: left, y: lane.y + 52.5), to: NSPoint(x: frame.width - 24, y: lane.y + 52.5), color: muted.withAlphaComponent(0.35))
            if let created = lane.source.chat.createdAt, created >= range.start && created <= range.end {
                let px = x(created), diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: px, y: lane.y + 15)); diamond.line(to: NSPoint(x: px + 5, y: lane.y + 21))
                diamond.line(to: NSPoint(x: px, y: lane.y + 27)); diamond.line(to: NSPoint(x: px - 5, y: lane.y + 21)); diamond.close(); color.setStroke(); diamond.stroke()
            }
            for cluster in lane.clusters where cluster.x > visible.minX + left - 20 && cluster.x < visible.maxX + 20 {
                color.setFill(); color.setStroke()
                if cluster.marks.count == 1 {
                    let rect = NSRect(x: cluster.x - 4, y: lane.y + 48, width: 8, height: 8)
                    if cluster.marks[0].user { rect.fill() } else { NSBezierPath(ovalIn: rect).fill() }
                } else {
                    let width = max(24, CGFloat(String(cluster.marks.count).count) * 7 + 10)
                    let rect = NSRect(x: cluster.x - width / 2, y: lane.y + 42, width: width, height: 21)
                    paper.setFill(); rect.fill(); color.setStroke(); NSBezierPath(rect: rect).stroke()
                    label(String(cluster.marks.count), in: rect.insetBy(dx: 2, dy: 2), size: 12, weight: .bold, color: color, alignment: .center)
                }
                let firstTime = clock.string(from: cluster.marks[0].time)
                let lastTime = clock.string(from: cluster.marks.last!.time)
                let timeText = firstTime == lastTime ? firstTime : "\(firstTime)–\(lastTime)"
                label(timeText, in: NSRect(x: max(left + 2, cluster.x - 35), y: lane.y + 70, width: 76, height: 18), size: 10, color: color)
            }
        }
        // Chat names stay visible when panning, and the clock stays visible when scrolling.
        paper.setFill(); NSRect(x: visible.minX, y: visible.minY, width: left, height: visible.height).fill()
        for lane in lanes where lane.y + 104 >= dirtyRect.minY && lane.y <= dirtyRect.maxY {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            (lane.source.chat.title as NSString).draw(in: NSRect(x: visible.minX + 22, y: lane.y + 10, width: left - 40, height: 56), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: lane.source.chat.archived ? muted : ink, .paragraphStyle: paragraph])
            label("\(lane.source.messages.count) MESSAGES\(lane.source.chat.archived ? " · ARCHIVED" : "")", in: NSRect(x: visible.minX + 22, y: lane.y + 75, width: left - 40, height: 18), size: 10, color: muted)
        }
        paper.setFill(); NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: 91).fill()
        label("Each row is a chat. Time runs left → right.", in: NSRect(x: visible.minX + 22, y: visible.minY + 13, width: max(1, visible.width - 202), height: 20), size: 11, color: ink)
        label("◇ Chat created · □ User · ● Assistant · Number = grouped messages", in: NSRect(x: visible.minX + 22, y: visible.minY + 39, width: visible.width - 44, height: 20), size: 11, color: muted)
        for tick in ticks {
            let px = x(tick)
            if px >= visible.minX + left + 20 && px <= visible.maxX - 28 { label(clock.string(from: tick), in: NSRect(x: px - 22, y: visible.minY + 67, width: 48, height: 18), size: 11, color: ink) }
        }
        ink.setStroke(); for button in [fitButton, dayButton, minusButton, plusButton] { NSBezierPath(rect: button.frame).stroke() }
        if lanes.isEmpty { label(status, in: NSRect(x: visible.minX + 22, y: visible.minY + 80, width: viewportWidth - 44, height: 25), size: 12, color: muted) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        guard let lane = lanes.first(where: { point.y >= $0.y && point.y < $0.y + 104 }) else { return status }
        let cluster = lane.clusters.first { abs($0.x - point.x) < 26 }
        let detail = cluster.map { "\($0.marks.count) messages · \(clock.string(from: $0.marks.first!.time))–\(clock.string(from: $0.marks.last!.time))" } ?? ""
        return "\(lane.source.chat.title)\n\(lane.source.messages.count) recorded messages\n\(detail)\nZoom to separate grouped markers. Double-click a chat row or single-message mark to read it.\nChat ID: \(lane.source.chat.id)"
    }
}
