import AppKit

/// Fixed action columns keep every project name and square aligned at each zoom.
struct DateProjectControls {
    enum Action { case filter, connections }
    let name: NSRect
    let connections: NSRect
    let contentRight: CGFloat
    let anchorX: CGFloat
    let spineX: CGFloat
    let trackSpacing: CGFloat

    init(width: CGFloat, rowY: CGFloat, connectionTrackCount: Int = 0, layoutWidth: CGFloat? = nil) {
        let viewportWidth = layoutWidth ?? width
        let micro = viewportWidth < 350, compact = viewportWidth < 520
        let squareRight = width - 16 - DateConnectionGeometry.extent(railCount: connectionTrackCount)
        contentRight = squareRight + 8
        trackSpacing = DateConnectionGeometry.railSpacing
        anchorX = squareRight + DateConnectionGeometry.anchorOffset
        spineX = squareRight + DateConnectionGeometry.firstRailOffset
        let y = rowY + (micro ? 64 : compact ? 42 : 9)
        connections = NSRect(x: contentRight - 32, y: y, width: 24, height: 24)
        let right = connections.minX - 7
        let left = micro ? 22 : compact ? 116 : right - min(220, max(112, width * 0.22))
        name = NSRect(x: left, y: y, width: max(1, right - left), height: 24)
    }

    static func draw(_ action: Action, in rect: NSRect, selected: Bool, enabled: Bool = true,
                     ink: NSColor, paper: NSColor, accent: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 24, yBy: rect.height / 24)
        transform.concat()
        let rect = NSRect(x: 0, y: 0, width: 24, height: 24)
        let color = (selected ? (action == .connections ? accent : AppearanceSettings.shared.activePalette?.selection ?? ink) : ink).withAlphaComponent(enabled ? 1 : 0.25)
        if selected { color.setFill(); rect.fill() }
        (selected ? color : AppearanceSettings.shared.activePalette?.border ?? color).setStroke(); NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let icon = selected && action == .filter ? AppearanceSettings.shared.activePalette?.onSelection ?? paper : selected ? paper : color
        icon.setStroke(); icon.setFill()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + 5 + x * 0.875, y: rect.minY + 5 + y * 0.875) }
        let path = NSBezierPath(); path.lineWidth = 1.2
        if action == .filter {
            path.move(to: p(2, 3)); path.line(to: p(14, 3)); path.line(to: p(9.5, 8))
            path.line(to: p(9.5, 13)); path.line(to: p(6.5, 14)); path.line(to: p(6.5, 8)); path.close()
        } else {
            path.move(to: p(4, 3)); path.line(to: p(10, 3))
            path.curve(to: p(13, 6), controlPoint1: p(13, 3), controlPoint2: p(13, 3))
            path.line(to: p(13, 10)); path.curve(to: p(10, 13), controlPoint1: p(13, 13), controlPoint2: p(13, 13))
            path.line(to: p(4, 13)); path.move(to: p(13, 8)); path.line(to: p(4, 8))
            for y: CGFloat in [3, 8, 13] { let center = p(3, y); NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8)).fill() }
        }
        path.stroke()
    }
}

enum DateProjectColors {
    static func hue(for identity: ProjectIdentity) -> CGFloat {
        // Swift's Hasher is randomized between launches. This hash is stable
        // across launches, project renames, filtering and selection order.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.savedKey.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return CGFloat(hash & 0xFFFFFF) / 16_777_216
    }

    static func color(for identity: ProjectIdentity, dark: Bool, hue assignedHue: CGFloat? = nil) -> NSColor {
        let hue = assignedHue ?? hue(for: identity)
        let saturation: CGFloat = 0.76
        var brightness: CGFloat = dark ? 0.96 : 0.82
        func color(_ brightness: CGFloat) -> NSColor {
            let value = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            return value.usingColorSpace(.sRGB) ?? value
        }
        // Keep small project labels legible on white, including yellow hues.
        if !dark && AppearanceSettings.shared.activePalette == nil {
            while brightness > 0.3 {
                let rgb = color(brightness)
                func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
                let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                if 1.05 / (luminance + 0.05) >= 4.5 { break }
                brightness -= 0.02
            }
        }
        return AppTheme.semantic(color(brightness))
    }
}
