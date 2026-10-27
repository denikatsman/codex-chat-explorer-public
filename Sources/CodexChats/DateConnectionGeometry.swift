import AppKit

/// Cached presentation geometry. Coordinates are relative to the square's right
/// edge; scrolling never assigns lanes or changes a project's rail position.
struct DateConnectionGeometry {
    static let anchorOffset: CGFloat = 8
    static let firstRailOffset: CGFloat = 35
    static let railSpacing: CGFloat = 20
    static let cornerRadius: CGFloat = 8
    static let lineWidth: CGFloat = 1.4
    static let nodeRadius: CGFloat = 2.5
    static let crossingHalfGap: CGFloat = 3.5

    struct Series { let identity: ProjectIdentity; let points: [CGFloat] }
    struct Branch { let identity: ProjectIdentity; let y: CGFloat; let endX: CGFloat }
    struct Node { let identity: ProjectIdentity; let y: CGFloat }
    struct Rail {
        let identity: ProjectIdentity
        let lane: Int
        let points: [CGFloat]
        let x: CGFloat
        let radius: CGFloat
        var gaps: [ClosedRange<CGFloat>]
        var segments: [ClosedRange<CGFloat>]
    }
    let rails: [Rail]
    let branches: [Branch]
    let nodes: [Node]

    init(_ series: [Series] = []) {
        var order = [ProjectIdentity](), grouped = [ProjectIdentity: [CGFloat]]()
        for value in series {
            guard case .assigned = value.identity else { continue }
            if grouped[value.identity] == nil { order.append(value.identity) }
            grouped[value.identity, default: []].append(contentsOf: value.points.filter { $0.isFinite && $0 >= 0 })
        }
        var rails = [Rail](), branches = [Branch](), nodes = [Node]()
        for identity in order {
            let ys = Array(Set(grouped[identity] ?? [])).sorted()
            nodes.append(contentsOf: ys.map { Node(identity: identity, y: $0) })
            // A single matching chat is a node, never an unconnected branch.
            guard ys.count > 1, let first = ys.first, let last = ys.last else { continue }
            let lane = rails.count, x = Self.firstRailOffset + CGFloat(lane) * Self.railSpacing
            let radius = min(Self.cornerRadius, (last - first) / 2)
            rails.append(Rail(identity: identity, lane: lane, points: ys, x: x, radius: radius, gaps: [], segments: []))
            for (index, y) in ys.enumerated() {
                branches.append(Branch(identity: identity, y: y, endX: index == 0 || index == ys.count - 1 ? x - radius : x))
            }
        }
        // Cut actual intervals out of the crossed spine. No background masks
        // can erase another rail's corner or the branch's own junction.
        for index in rails.indices {
            let rail = rails[index], start = rail.points[0] + rail.radius, end = rail.points[rail.points.count - 1] - rail.radius
            var gaps = [ClosedRange<CGFloat>]()
            for branch in branches where branch.identity != rail.identity && branch.endX > rail.x + Self.lineWidth / 2 && branch.y > start && branch.y < end {
                let next = Self.lowerBound(rail.points, at: branch.y)
                if next < rail.points.count && rail.points[next] == branch.y { continue }
                let lower = max(start, branch.y - Self.crossingHalfGap, rail.points[max(0, next - 1)] + Self.lineWidth)
                let upper = min(end, branch.y + Self.crossingHalfGap, rail.points[min(next, rail.points.count - 1)] - Self.lineWidth)
                if lower < upper { gaps.append(lower...upper) }
            }
            gaps.sort { $0.lowerBound < $1.lowerBound }
            var merged = [ClosedRange<CGFloat>]()
            for gap in gaps {
                if let previous = merged.last, gap.lowerBound <= previous.upperBound {
                    merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, gap.upperBound)
                } else { merged.append(gap) }
            }
            var cursor = start, segments = [ClosedRange<CGFloat>]()
            for gap in merged {
                if cursor < gap.lowerBound { segments.append(cursor...gap.lowerBound) }
                cursor = max(cursor, gap.upperBound)
            }
            if cursor < end { segments.append(cursor...end) }
            rails[index].gaps = merged; rails[index].segments = segments
        }
        self.rails = rails
        self.branches = branches.sorted { $0.y < $1.y }
        self.nodes = nodes.sorted { $0.y < $1.y }
    }

    static func extent(railCount: Int) -> CGFloat {
        railCount > 0 ? firstRailOffset + CGFloat(railCount - 1) * railSpacing : anchorOffset + nodeRadius + 1
    }
    static func minimumDocumentWidth(railCount: Int, viewportWidth: CGFloat) -> CGFloat {
        let preferredBody: CGFloat = viewportWidth < 350 ? 185 : viewportWidth < 520 ? 350 : 520
        let body = max(0, min(preferredBody, viewportWidth - 16 - extent(railCount: 0)))
        return max(1, body + 16 + extent(railCount: railCount))
    }
    private static func lowerBound<T>(_ values: [T], at target: CGFloat, key: (T) -> CGFloat) -> Int {
        var lo = 0, hi = values.count
        while lo < hi { let mid = (lo + hi) / 2; if key(values[mid]) < target { lo = mid + 1 } else { hi = mid } }
        return lo
    }
    private static func lowerBound(_ values: [CGFloat], at target: CGFloat) -> Int { lowerBound(values, at: target, key: { $0 }) }

    func draw(in dirtyRect: NSRect, originX: CGFloat, color: (ProjectIdentity) -> NSColor) {
        guard !dirtyRect.isEmpty, originX.isFinite, dirtyRect.minX.isFinite, dirtyRect.minY.isFinite, dirtyRect.maxX.isFinite, dirtyRect.maxY.isFinite else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: dirtyRect).addClip()
        let low = dirtyRect.minY - Self.nodeRadius - Self.lineWidth, high = dirtyRect.maxY + Self.nodeRadius + Self.lineWidth
        let k: CGFloat = 0.5522847498307936
        for rail in rails {
            guard let first = rail.points.first, let last = rail.points.last, first <= high, last >= low else { continue }
            let x = originX + rail.x, r = rail.radius
            if x + Self.lineWidth < dirtyRect.minX || x - r - Self.lineWidth > dirtyRect.maxX { continue }
            let path = NSBezierPath(); path.lineWidth = Self.lineWidth; path.lineCapStyle = .butt
            if first + r >= low && first <= high {
                path.move(to: NSPoint(x: x-r, y: first))
                path.curve(to: NSPoint(x: x, y: first+r), controlPoint1: NSPoint(x: x-r+k*r, y: first), controlPoint2: NSPoint(x: x, y: first+r-k*r))
            }
            let segmentStart = Self.lowerBound(rail.segments, at: low, key: { $0.upperBound })
            for segment in rail.segments[segmentStart...] {
                if segment.lowerBound > high { break }
                path.move(to: NSPoint(x: x, y: segment.lowerBound)); path.line(to: NSPoint(x: x, y: segment.upperBound))
            }
            if last - r <= high && last >= low {
                path.move(to: NSPoint(x: x, y: last-r))
                path.curve(to: NSPoint(x: x-r, y: last), controlPoint1: NSPoint(x: x, y: last-r+k*r), controlPoint2: NSPoint(x: x-r+k*r, y: last))
            }
            color(rail.identity).setStroke(); path.stroke()
        }
        let branchStart = Self.lowerBound(branches, at: low, key: { $0.y })
        for branch in branches[branchStart...] {
            if branch.y > high { break }
            if originX + branch.endX + Self.lineWidth < dirtyRect.minX || originX + Self.anchorOffset - Self.lineWidth > dirtyRect.maxX { continue }
            let path = NSBezierPath(); path.lineWidth = Self.lineWidth; path.lineCapStyle = .butt
            path.move(to: NSPoint(x: originX + Self.anchorOffset, y: branch.y)); path.line(to: NSPoint(x: originX + branch.endX, y: branch.y))
            color(branch.identity).setStroke(); path.stroke()
        }
        guard originX + Self.anchorOffset + Self.nodeRadius >= dirtyRect.minX, originX + Self.anchorOffset - Self.nodeRadius <= dirtyRect.maxX else { return }
        let nodeStart = Self.lowerBound(nodes, at: low, key: { $0.y })
        for node in nodes[nodeStart...] {
            if node.y > high { break }
            color(node.identity).setFill()
            NSBezierPath(ovalIn: NSRect(x: originX + Self.anchorOffset - Self.nodeRadius, y: node.y - Self.nodeRadius, width: Self.nodeRadius * 2, height: Self.nodeRadius * 2)).fill()
        }
    }
}
