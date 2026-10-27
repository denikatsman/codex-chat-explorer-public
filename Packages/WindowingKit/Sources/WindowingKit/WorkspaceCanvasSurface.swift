import AppKit

/// Content-independent canvas background: pan, box selection and host-approved drops.
open class WorkspaceCanvasSurface: NSView {
    public override var isFlipped: Bool { true }
    public var backgroundColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    public var gridColor: NSColor = .separatorColor { didSet { needsDisplay = true } }
    public var selectionColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    public private(set) var isPanning = false
    public var onPanEnd: (() -> Void)?
    public var onClearSelection: (() -> Void)?
    public var onSelectAll: (() -> Void)?
    public var onBeginBox: (() -> Void)?
    public var onBoxSelection: ((NSRect) -> Void)?
    /// Hosts choose which payloads and operations their content accepts.
    public var canAcceptDrop: ((NSDraggingInfo) -> Bool)?
    public var dropOperation: ((NSDraggingInfo) -> NSDragOperation)?
    public var onDrop: ((NSDraggingInfo, NSPoint) -> Bool)?
    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation?(sender) ?? (canAcceptDrop?(sender) == true ? .move : [])
    }
    open override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    open override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !draggingEntered(sender).isEmpty else { return false }
        return onDrop?(sender, convert(sender.draggingLocation, from: nil)) ?? false
    }
    private var marquee: NSRect?
    public override var acceptsFirstResponder: Bool { true }
    @objc open override func selectAll(_ sender: Any?) { onSelectAll?() }
    open override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClearSelection?() } else { super.keyDown(with:event) }
    }
    open override func draw(_ dirtyRect: NSRect) {
        let area = dirtyRect.intersection(visibleRect)
        guard CursorGeometry.isUsable(area) else { return }
        backgroundColor.setFill(); area.fill(); gridColor.setFill()
        for x in stride(from: floor(area.minX/24)*24,through:area.maxX,by:24) {
            for y in stride(from: floor(area.minY/24)*24,through:area.maxY,by:24) { NSRect(x:x,y:y,width:1,height:1).fill() }
        }
        if let marquee {
            let color = selectionColor
            color.withAlphaComponent(0.1).setFill(); marquee.fill(); color.setStroke()
            let border = NSBezierPath(rect:marquee); border.setLineDash([5,3],count:2,phase:0); border.stroke()
        }
    }
    open override func mouseDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView, let window else { return }
        window.makeFirstResponder(self)
        if event.modifierFlags.contains(.shift) {
            onBeginBox?()
            let start = convert(event.locationInWindow,from:nil)
            while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let end = convert(next.locationInWindow,from:nil)
                let previous = marquee ?? .zero
                let rect = NSRect(x:min(start.x,end.x),y:min(start.y,end.y),width:abs(end.x-start.x),height:abs(end.y-start.y))
                marquee = rect; setNeedsDisplay(previous.union(rect).insetBy(dx:-2,dy:-2)); onBoxSelection?(rect)
            }
            if let marquee { setNeedsDisplay(marquee.insetBy(dx:-2,dy:-2)) }; marquee = nil
            return
        }
        isPanning = true
        defer { isPanning = false; onPanEnd?() }
        let start = event.locationInWindow, origin = scroll.contentView.bounds.origin
        var moved = false
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let p = next.locationInWindow, scale = scroll.magnification
            guard scale.isFinite, scale > 0 else { break }
            moved = true
            scroll.contentView.scroll(to:NSPoint(x:origin.x-(p.x-start.x)/scale,y:origin.y+(p.y-start.y)/scale))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if !moved { onClearSelection?() }
    }
}
