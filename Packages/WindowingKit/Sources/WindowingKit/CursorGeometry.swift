import AppKit

public struct CursorRegion {
    public enum Kind { case row, control }
    public let rect: NSRect
    public let kind: Kind
    public init(rect: NSRect, kind: Kind) { self.rect = rect; self.kind = kind }
}

public enum CursorGeometry {
    public static func isUsable(_ rect: NSRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
            && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }

    public static func clipped(_ rect: NSRect, to visible: NSRect) -> NSRect? {
        guard isUsable(rect), isUsable(visible) else { return nil }
        let clipped = rect.intersection(visible)
        return isUsable(clipped) ? clipped : nil
    }
}
