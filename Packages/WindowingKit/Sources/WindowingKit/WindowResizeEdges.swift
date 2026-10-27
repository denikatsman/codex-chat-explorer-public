import AppKit

/// Visual edges: top/bottom retain their meaning in either coordinate system.
public enum ResizeEdge: CaseIterable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

    fileprivate var left: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    fileprivate var right: Bool { self == .right || self == .topRight || self == .bottomRight }
    fileprivate var top: Bool { self == .top || self == .topLeft || self == .topRight }
    fileprivate var bottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    fileprivate var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if self == .left || self == .right { return .resizeLeftRight }
        if self == .top || self == .bottom { return .resizeUpDown }
        return .crosshair
    }
}

public struct ResizeEdgeRegion {
    public let edge: ResizeEdge
    public let rect: NSRect
    public init(edge: ResizeEdge, rect: NSRect) { self.edge = edge; self.rect = rect }
}

public enum WindowResizeGeometry {
    /// Delta uses the same coordinates as original. Only dragged axes change;
    /// the opposite edges stay anchored even when the size reaches a limit.
    public static func resized(_ original: NSRect, edge: ResizeEdge, delta: NSPoint,
                        isFlipped: Bool, minimumSize: NSSize, maximumSize: NSSize) -> NSRect? {
        guard original.size.width > 0, original.size.height > 0,
              CursorGeometry.isUsable(original), delta.x.isFinite, delta.y.isFinite,
              minimumSize.width.isFinite, minimumSize.height.isFinite,
              maximumSize.width.isFinite, maximumSize.height.isFinite,
              minimumSize.width > 0, minimumSize.height > 0,
              maximumSize.width >= minimumSize.width, maximumSize.height >= minimumSize.height else { return nil }
        var result = original
        if edge.left || edge.right {
            result.size.width = min(maximumSize.width, max(minimumSize.width, original.width + (edge.left ? -delta.x : delta.x)))
            if edge.left { result.origin.x = original.maxX - result.width }
        }
        if edge.top || edge.bottom {
            let changesMinimumY = isFlipped ? edge.top : edge.bottom
            result.size.height = min(maximumSize.height, max(minimumSize.height, original.height + (changesMinimumY ? -delta.y : delta.y)))
            if changesMinimumY { result.origin.y = original.maxY - result.height }
        }
        return CursorGeometry.isUsable(result) ? result : nil
    }

    /// Corners occupy an L-shaped piece of the thin perimeter, never a square
    /// covering nearby content. Regions are disjoint and safe to clip for AppKit.
    public static func regions(in bounds: NSRect, thickness: CGFloat = 6, cornerLength: CGFloat = 18,
                        isFlipped: Bool) -> [ResizeEdgeRegion] {
        guard bounds.size.width > 0, bounds.size.height > 0,
              CursorGeometry.isUsable(bounds), thickness.isFinite, thickness > 0,
              cornerLength.isFinite, cornerLength > 0 else { return [] }
        let band = min(thickness, min(bounds.width, bounds.height) / 2)
        let cornerX = min(max(band, cornerLength), bounds.width / 2)
        let cornerY = min(max(band, cornerLength), bounds.height / 2)
        let low: ResizeEdge = isFlipped ? .top : .bottom
        let high: ResizeEdge = isFlipped ? .bottom : .top
        let lowLeft: ResizeEdge = isFlipped ? .topLeft : .bottomLeft
        let lowRight: ResizeEdge = isFlipped ? .topRight : .bottomRight
        let highLeft: ResizeEdge = isFlipped ? .bottomLeft : .topLeft
        let highRight: ResizeEdge = isFlipped ? .bottomRight : .topRight
        let x = bounds.minX, y = bounds.minY, w = bounds.width, h = bounds.height
        let candidates: [(ResizeEdge, NSRect)] = [
            (lowLeft, NSRect(x:x,y:y,width:cornerX,height:band)),
            (low, NSRect(x:x+cornerX,y:y,width:w-2*cornerX,height:band)),
            (lowRight, NSRect(x:bounds.maxX-cornerX,y:y,width:cornerX,height:band)),
            (highLeft, NSRect(x:x,y:bounds.maxY-band,width:cornerX,height:band)),
            (high, NSRect(x:x+cornerX,y:bounds.maxY-band,width:w-2*cornerX,height:band)),
            (highRight, NSRect(x:bounds.maxX-cornerX,y:bounds.maxY-band,width:cornerX,height:band)),
            (lowLeft, NSRect(x:x,y:y+band,width:band,height:cornerY-band)),
            (lowRight, NSRect(x:bounds.maxX-band,y:y+band,width:band,height:cornerY-band)),
            (.left, NSRect(x:x,y:y+cornerY,width:band,height:h-2*cornerY)),
            (.right, NSRect(x:bounds.maxX-band,y:y+cornerY,width:band,height:h-2*cornerY)),
            (highLeft, NSRect(x:x,y:bounds.maxY-cornerY,width:band,height:cornerY-band)),
            (highRight, NSRect(x:bounds.maxX-band,y:bounds.maxY-cornerY,width:band,height:cornerY-band))
        ]
        return candidates.compactMap { edge, rect in
            CursorGeometry.clipped(rect, to:bounds).map { ResizeEdgeRegion(edge:edge,rect:$0) }
        }
    }
}

/// Add above the target's content and size to its bounds. Interior hit testing
/// returns nil, so controls, scrolling, selection and native drags pass through.
public final class WindowResizeEdges: NSView {
    public override var isFlipped: Bool { superview?.isFlipped ?? false }
    public var isEnabled = true { didSet { window?.invalidateCursorRects(for:self) } }
    public var thickness: CGFloat = 6 { didSet { window?.invalidateCursorRects(for:self) } }
    public var cornerLength: CGFloat = 18 { didSet { window?.invalidateCursorRects(for:self) } }
    public var onBegin: (() -> Void)?
    public var onEnd: (() -> Void)?
    private var originalFrame: (() -> NSRect?)?
    private var eventPoint: ((NSEvent) -> NSPoint?)?
    private var coordinateSpaceIsFlipped: (() -> Bool)?
    private var sizeLimits: (() -> (NSSize, NSSize))?
    private var applyFrame: ((NSRect) -> Void)?

    public override init(frame: NSRect) {
        super.init(frame:frame)
        // Recent AppKit versions allow an unclipped view's visibleRect to be
        // infinite. A border overlay always owns only its finite bounds.
        clipsToBounds = true
        autoresizingMask = [.width,.height]
    }
    public required init?(coder: NSCoder) { fatalError("Not used") }

    public func configure(view: NSView, minimumSize: NSSize, maximumSize: NSSize,
                   onResize: @escaping (NSRect) -> Void) {
        originalFrame = { [weak view] in view?.superview == nil ? nil : view?.frame }
        eventPoint = { [weak view] event in view?.superview?.convert(event.locationInWindow,from:nil) }
        coordinateSpaceIsFlipped = { [weak view] in view?.superview?.isFlipped ?? false }
        sizeLimits = { (minimumSize, maximumSize) }
        applyFrame = onResize
    }

    public func configure(window: NSWindow, onResize: ((NSRect) -> Void)? = nil) {
        originalFrame = { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen), window.styleMask.contains(.resizable) else { return nil }
            return window.frame
        }
        eventPoint = { [weak window] event in window?.convertPoint(toScreen:event.locationInWindow) }
        coordinateSpaceIsFlipped = { false }
        sizeLimits = { [weak window] in (window?.minSize ?? .zero, window?.maxSize ?? .zero) }
        applyFrame = onResize ?? { [weak window] rect in window?.setFrame(rect,display:true) }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public func cursorRegions(in visible: NSRect) -> [ResizeEdgeRegion] {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, originalFrame?() != nil else { return [] }
        return WindowResizeGeometry.regions(in:bounds,thickness:thickness,cornerLength:cornerLength,isFlipped:isFlipped).compactMap { region in
            CursorGeometry.clipped(region.rect,to:visible).map { ResizeEdgeRegion(edge:region.edge,rect:$0) }
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point,from:superview)
        return cursorRegions(in:visibleRect).contains { $0.rect.contains(local) } ? self : nil
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        for region in cursorRegions(in:visibleRect) { addCursorRect(region.rect,cursor:region.edge.cursor) }
    }

    public override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow,from:nil)
        guard let edge = cursorRegions(in:visibleRect).first(where: { $0.rect.contains(local) })?.edge,
              let window, let original = originalFrame?(), let start = eventPoint?(event),
              let (minimum, maximum) = sizeLimits?(), let isFlipped = coordinateSpaceIsFlipped?() else { return }
        onBegin?()
        edge.cursor.push()
        defer { NSCursor.pop(); onEnd?() }
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp],until:.distantFuture,inMode:.eventTracking,dequeue:true) {
            guard self.window === window, isEnabled, !isHiddenOrHasHiddenAncestor,
                  originalFrame?() != nil, let point = eventPoint?(next) else { break }
            let delta = NSPoint(x:point.x-start.x,y:point.y-start.y)
            if let rect = WindowResizeGeometry.resized(original,edge:edge,delta:delta,isFlipped:isFlipped,minimumSize:minimum,maximumSize:maximum) { applyFrame?(rect) }
            if next.type == .leftMouseUp { break }
        }
    }
}
