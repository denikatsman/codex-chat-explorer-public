import AppKit

public struct ContentPanelStyle {
    public var background: NSColor
    public var border: NSColor
    public var ink: NSColor
    public init(background: NSColor, border: NSColor, ink: NSColor) {
        self.background = background; self.border = border; self.ink = ink
    }
    public static var standard: Self { .init(background: .windowBackgroundColor, border: .separatorColor, ink: .labelColor) }
}

private final class PanelHeader: NSView {
    weak var panel: ContentPanel?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { panel?.track(event, resize: false) }
    override func resetCursorRects() { super.resetCursorRects(); if let rect = CursorGeometry.clipped(bounds, to: visibleRect) { addCursorRect(rect, cursor: .openHand) } }
}
private final class PanelGrip: NSView {
    weak var panel: ContentPanel?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { panel?.track(event, resize: true) }
    override func draw(_ dirtyRect: NSRect) {
        (panel?.style.ink ?? .secondaryLabelColor).setStroke()
        for offset: CGFloat in [4, 8, 12] {
            let p = NSBezierPath(); p.move(to: NSPoint(x: bounds.width-offset, y: bounds.height-2)); p.line(to: NSPoint(x: bounds.width-2, y: bounds.height-offset)); p.stroke()
        }
    }
    override func resetCursorRects() { super.resetCursorRects(); if let rect = CursorGeometry.clipped(bounds, to: visibleRect) { addCursorRect(rect, cursor: .crosshair) } }
}

/// Canvas chrome around one live view. Content, shared identity and persistence remain app-owned.
open class ContentPanel: NSView {
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public let content: WindowContent
    public var contentView: NSView { content.view }
    public let id: String
    public var title: String { didSet { needsDisplay = true } }
    public let minimumSize: NSSize
    public let maximumSize: NSSize
    public var onPopOut: (() -> Void)?
    public var onDismiss: (() -> Void)?
    public var onGeometry: (() -> Void)?
    public var onFocus: (() -> Void)?
    public var onDuplicate: (() -> Void)?
    public var onNativeDrag: ((NSEvent) -> Void)?
    /// Emitted once after a collapse change or a completed header/grip gesture.
    public var onInteraction: ((String) -> Void)?
    public var style: ContentPanelStyle { didSet { updateStyle() } }
    private let resizeEdges = WindowResizeEdges(frame: .zero)
    private var duplicateAction: DuplicateWindowAction!
    private let header = PanelHeader(), grip = PanelGrip(), collapse = NSButton()
    private var expandedSize: NSSize
    public private(set) var isCollapsed = false
    public var expandedFrame: NSRect { NSRect(origin: frame.origin, size: expandedSize) }

    public init(content: WindowContent, frame: NSRect, id: String = UUID().uuidString, title: String, minimumSize: NSSize, maximumSize: NSSize = NSSize(width: 3000, height: 3000), style: ContentPanelStyle = .standard) {
        self.content = content; self.id = id; self.title = title; self.minimumSize = minimumSize; self.maximumSize = maximumSize; self.style = style; expandedSize = frame.size
        super.init(frame: frame)
        header.panel = self; grip.panel = self; content.view.autoresizingMask = []
        addSubview(header); addSubview(content.view); addSubview(grip)
        collapse.isBordered = false; collapse.focusRingType = .none; collapse.target = self; collapse.action = #selector(toggleCollapsed); header.addSubview(collapse)
        duplicateAction = DuplicateWindowAction { [weak self] in self?.onDuplicate?() }
        header.menu = duplicateAction.menu(); menu = duplicateAction.menu()
        resizeEdges.configure(view: self, minimumSize: minimumSize, maximumSize: maximumSize) { [weak self] rect in self?.resizeFrame(rect) }
        resizeEdges.onBegin = { [weak self] in self?.onFocus?() }; resizeEdges.onEnd = { [weak self] in self?.onGeometry?() }; addSubview(resizeEdges)
        setAccessibilityRole(.group); setAccessibilityLabel("\(title) inside canvas"); updateStyle()
    }
    public required init?(coder: NSCoder) { fatalError("Not used") }
    private func updateStyle() {
        collapse.title = isCollapsed ? "EXPAND" : "COLLAPSE"
        collapse.setAccessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(title) panel")
        collapse.attributedTitle = NSAttributedString(string: collapse.title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: style.ink])
        grip.needsDisplay = true; needsDisplay = true
    }
    public func setCollapsed(_ value: Bool) {
        guard value != isCollapsed else { return }
        if value { expandedSize = frame.size }
        isCollapsed = value; contentView.isHidden = value; grip.isHidden = value
        setFrameSize(value ? NSSize(width: expandedSize.width, height: 34) : expandedSize)
        updateStyle(); needsLayout = true; layoutSubtreeIfNeeded(); onGeometry?(); onInteraction?("collapse")
    }
    @objc private func toggleCollapsed() { onFocus?(); setCollapsed(!isCollapsed) }
    public func dismiss() { onDismiss?() }
    public func move(to point: NSPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        setFrameOrigin(NSPoint(x: max(0, min(100_000_000, point.x)), y: max(0, min(100_000_000, point.y)))); onGeometry?()
    }
    public func resizeFrame(_ rect: NSRect) {
        guard !isCollapsed, CursorGeometry.isUsable(rect) else { return }
        let origin = NSPoint(x: max(0, rect.minX), y: max(0, rect.minY))
        let size = NSSize(width: rect.maxX-origin.x, height: rect.maxY-origin.y)
        guard size.width >= minimumSize.width, size.height >= minimumSize.height, size.width <= maximumSize.width, size.height <= maximumSize.height else { return }
        expandedSize = size
        content.preservePresentation { self.setFrameOrigin(origin); self.setFrameSize(size); self.needsLayout = true; self.layoutSubtreeIfNeeded() }; onGeometry?()
    }
    public func resize(to size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, !isCollapsed else { return }
        expandedSize = NSSize(width: max(minimumSize.width, min(maximumSize.width, size.width)), height: max(minimumSize.height, min(maximumSize.height, size.height)))
        content.preservePresentation { self.setFrameSize(self.expandedSize); self.needsLayout = true; self.layoutSubtreeIfNeeded() }; onGeometry?()
    }
    public func applyShared(frame: NSRect, collapsed: Bool) {
        guard CursorGeometry.isUsable(frame), frame.width >= minimumSize.width, frame.height >= minimumSize.height, frame.width <= maximumSize.width, frame.height <= maximumSize.height, frame.minX >= 0, frame.minY >= 0 else { return }
        content.preservePresentation {
            self.expandedSize = frame.size; self.setFrameOrigin(frame.origin); self.isCollapsed = collapsed
            self.contentView.isHidden = collapsed; self.grip.isHidden = collapsed
            self.setFrameSize(collapsed ? NSSize(width: frame.width, height: 34) : frame.size)
            self.updateStyle(); self.needsLayout = true; self.layoutSubtreeIfNeeded()
        }
    }
    open override func layout() {
        super.layout(); header.frame = NSRect(x: 1, y: 1, width: bounds.width-2, height: 32); collapse.frame = NSRect(x: 10, y: 6, width: 76, height: 20)
        resizeEdges.frame = bounds; resizeEdges.isEnabled = !isCollapsed
        if !isCollapsed { contentView.frame = NSRect(x: 1, y: 34, width: max(0, bounds.width-2), height: max(0, bounds.height-50)) }
        grip.frame = NSRect(x: bounds.width-19, y: bounds.height-17, width: 17, height: 15)
    }
    open override func draw(_ dirtyRect: NSRect) {
        style.background.setFill(); bounds.fill(); style.border.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 100, y: 9, width: max(0, bounds.width-210), height: 18), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: style.ink, .paragraphStyle: paragraph])
        let path = NSBezierPath(); path.move(to: NSPoint(x: 0, y: 33.5)); path.line(to: NSPoint(x: bounds.width, y: 33.5)); path.stroke()
    }
    public func track(_ event: NSEvent, resize: Bool) {
        guard let parent = superview, let window else { return }
        onFocus?(); parent.addSubview(self, positioned: .above, relativeTo: nil)
        let start = parent.convert(event.locationInWindow, from: nil), original = frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = parent.convert(next.locationInWindow, from: nil), dx = point.x-start.x, dy = point.y-start.y
            if !resize, let onNativeDrag {
                let screen = window.convertPoint(toScreen: next.locationInWindow)
                let hit = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
                if !window.frame.contains(screen) || (hit != 0 && hit != window.windowNumber) { setFrameOrigin(original.origin); onGeometry?(); onNativeDrag(next); return }
            }
            if resize { self.resize(to: NSSize(width: original.width+dx, height: original.height+dy)) }
            else { move(to: NSPoint(x: original.minX+dx, y: original.minY+dy)) }
        }
        onInteraction?(resize ? "resize" : "move")
    }
}
