import AppKit

struct ColumnsSnapshot: Decodable {
    struct Message: Decodable {
        let raw_base64: String?
        let source_offset: Int?
        let id: String
        let timestamp: String
        let role: String
        let text: String
        var displayText: String {
            var result = text
            if role == "user", text.hasPrefix("# Files mentioned"), let marker = text.range(of: "## My request:\n") {
                result = String(text[marker.upperBound...])
                if let image = result.range(of: "\n<image name=") { result = String(result[..<image.lowerBound]) }
            }
            if role == "assistant", let citation = result.range(of: "\n<oai-mem-citation>"), result.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("</oai-mem-citation>") {
                result = String(result[..<citation.lowerBound])
            }
            return result.count > 12_000 ? String(result.prefix(12_000)) + "\n[Preview shortened; double-click to open the source chat.]" : result
        }
        var date: Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        }
    }
    struct Chat: Decodable { let id: String; let title: String; let messages: [Message]; let source_issue: String?; let source_path: String?; let available_today: Int? }
    struct Gap: Decodable { let source: String; let reason: String; let offset: Int?; let raw_base64: String? }
    let gaps: [Gap]?
    let day: String
    let scope: String
    let chats: [Chat]
    var messageCount: Int { chats.reduce(0) { $0 + $1.messages.count } }
    static func load(_ url: URL) throws -> ColumnsSnapshot { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}

final class ChatColumnsView: NSView {
    var onOpenChat: ((String) -> Void)?
    struct Card { let rect: NSRect; let message: ColumnsSnapshot.Message }
    struct TimeRow { let y: CGFloat; let minute: Int64 }
    override var isFlipped: Bool { true }
    private(set) var snapshot: ColumnsSnapshot
    var green = false { didSet { needsDisplay = true } }
    var dark = false { didSet { needsDisplay = true } }
    private var cards = [Card]()
    private var rows = [TimeRow]()
    private var lastWidth: CGFloat = -1
    private(set) var initialOffset: CGFloat = 0
    private var boundsObserver: NSObjectProtocol?
    private let gutter: CGFloat = 76
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private var paper: NSColor { AppTheme.background(dark:dark) }
    private var muted: NSColor { AppTheme.muted(dark: dark, green: green) }
    private var responseFill: NSColor { AppTheme.palette(dark:dark,green:green).assistant }
    private var columnFill: NSColor { AppTheme.palette(dark:dark,green:green).header }
    private let bodyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var columnWidth: CGFloat { max(100, (bounds.width - gutter - 14) / CGFloat(max(1, snapshot.chats.count))) }

    init(snapshot: ColumnsSnapshot) {
        self.snapshot = snapshot
        super.init(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Messages aligned by recorded minute, with one column per chat")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func show(_ data: ColumnsSnapshot) {
        snapshot = data; lastWidth = -1
        arrange(width: enclosingScrollView?.contentSize.width ?? 940)
    }

    func pinHeader(to clip: NSClipView) {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    func arrange(width: CGFloat) {
        guard width > 0, width != lastWidth else { return }
        lastWidth = width
        let documentWidth = max(width, gutter + CGFloat(snapshot.chats.count) * 320 + 14)
        setFrameSize(NSSize(width: documentWidth, height: frame.height))
        cards.removeAll(); rows.removeAll()
        var byMinute = [Int64: [(Int, ColumnsSnapshot.Message)]]()
        for (column, chat) in snapshot.chats.enumerated() {
            for message in chat.messages {
                if let date = message.date { byMinute[Int64(floor(date.timeIntervalSince1970 / 60)), default: []].append((column, message)) }
            }
        }
        var y: CGFloat = 84
        for minute in byMinute.keys.sorted() {
            rows.append(TimeRow(y: y, minute: minute))
            var bottoms = [CGFloat](repeating: y + 8, count: snapshot.chats.count)
            for (column, message) in byMinute[minute]!.sorted(by: { $0.1.timestamp < $1.1.timestamp }) {
                let cardWidth = columnWidth - 14
                let textHeight = (message.displayText as NSString).boundingRect(with: NSSize(width: cardWidth - 20, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: bodyFont]).height
                let height = max(60, ceil(textHeight) + 43)
                let rect = NSRect(x: gutter + CGFloat(column) * columnWidth + 5, y: bottoms[column], width: cardWidth, height: height)
                cards.append(Card(rect: rect, message: message))
                bottoms[column] += height + 9
            }
            y = (bottoms.max() ?? y + 60) + 15
        }
        let visibleCount = max(1, Int((width - gutter) / columnWidth))
        let shared = byMinute.keys.sorted().first { Set(byMinute[$0]!.filter { $0.0 < visibleCount }.map { $0.0 }).count > 1 }
        let firstPerChat = snapshot.chats.prefix(visibleCount).compactMap { $0.messages.compactMap(\.date).min() }.max().map { Int64(floor($0.timeIntervalSince1970 / 60)) }
        if let minute = shared ?? firstPerChat, let index = rows.firstIndex(where: { $0.minute >= minute }) {
            initialOffset = max(0, rows[max(0, index - 1)].y - 80)
        }
        setFrameSize(NSSize(width: documentWidth, height: max(y + 20, enclosingScrollView?.contentSize.height ?? 600)))
        needsDisplay = true
    }

    private func text(_ value: String, rect: NSRect, size: CGFloat = 12, bold: Bool = false, color: NSColor? = nil) {
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular), .foregroundColor: color ?? ink])
    }
    private func rule(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, color: NSColor) {
        color.setStroke(); let path = NSBezierPath(); path.move(to: NSPoint(x: x1, y: y1)); path.line(to: NSPoint(x: x2, y: y2)); path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(floor((point.x - gutter) / columnWidth))
        if event.clickCount >= 2, snapshot.chats.indices.contains(column), cards.contains(where: { $0.rect.contains(point) }) { onOpenChat?(snapshot.chats[column].id) }
        else { super.mouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); dirtyRect.fill()
        for index in snapshot.chats.indices where index % 2 == 1 {
            columnFill.setFill()
            NSRect(x: gutter + CGFloat(index) * columnWidth, y: dirtyRect.minY, width: columnWidth, height: dirtyRect.height).fill()
        }
        let time = DateFormatter(); time.dateFormat = "HH:mm"; time.timeZone = TimeZone(identifier: "Europe/Zurich")
        for row in rows where row.y >= dirtyRect.minY - 3000 && row.y <= dirtyRect.maxY {
            rule(8, row.y + 0.5, bounds.width - 10, row.y + 0.5, color: muted)
        }
        for card in cards where card.rect.intersects(dirtyRect) {
            (card.message.role == "assistant" ? responseFill : AppTheme.palette(dark:dark,green:green).user).setFill(); card.rect.fill()
            AppTheme.border(dark:dark,green:green).setStroke(); NSBezierPath(rect: card.rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            text(card.message.role == "user" ? "YOU" : "ASSISTANT", rect: NSRect(x: card.rect.minX + 10, y: card.rect.minY + 9, width: card.rect.width - 20, height: 16), size: 10, bold: true, color: muted)
            text(card.message.displayText, rect: NSRect(x: card.rect.minX + 10, y: card.rect.minY + 30, width: card.rect.width - 20, height: card.rect.height - 38))
        }
        // Keep the chat names visible during shared vertical scrolling.
        let top = visibleRect.minY
        let left = visibleRect.minX
        paper.setFill(); NSRect(x: 0, y: top, width: bounds.width, height: 78).fill()
        for (index, chat) in snapshot.chats.enumerated() {
            text((chat.source_issue == nil ? "" : "! ") + chat.title, rect: NSRect(x: gutter + CGFloat(index) * columnWidth + 8, y: top + 36, width: columnWidth - 20, height: 34), size: 11, bold: true)
            if chat.source_issue != nil, !chat.messages.isEmpty {
                text("! PARTIAL SOURCE · open chat to inspect", rect: NSRect(x: gutter + CGFloat(index) * columnWidth + 8, y: top + 62, width: columnWidth - 20, height: 14), size: 9, color: muted)
            }
            if chat.messages.isEmpty {
                text(chat.source_issue ?? "No text in this snapshot", rect: NSRect(x: gutter + CGFloat(index) * columnWidth + 12, y: top + 96, width: columnWidth - 24, height: 36), size: 11, color: muted)
            }
        }
        for index in 0...snapshot.chats.count {
            let x = gutter + CGFloat(index) * columnWidth + 0.5
            rule(x, top + 32, x, visibleRect.maxY, color: muted)
        }
        // Pin the time gutter when panning across the wider set of columns.
        paper.setFill(); NSRect(x: left, y: top + 32, width: gutter, height: visibleRect.height).fill()
        text("MESSAGES · \(snapshot.day)", rect: NSRect(x: left + 14, y: top + 9, width: visibleRect.width - 28, height: 20), size: 13, bold: true)
        text("TIME", rect: NSRect(x: left + 14, y: top + 42, width: 58, height: 20), size: 10, bold: true, color: muted)
        for row in rows where row.y >= top + 78 && row.y <= visibleRect.maxY {
            text(time.string(from: Date(timeIntervalSince1970: Double(row.minute * 60))), rect: NSRect(x: left + 13, y: row.y + 10, width: 60, height: 18), size: 11, bold: true)
        }
        rule(left + gutter - 0.5, top + 32, left + gutter - 0.5, visibleRect.maxY, color: ink)
        rule(0, top + 77.5, bounds.width, top + 77.5, color: ink)
    }
}
