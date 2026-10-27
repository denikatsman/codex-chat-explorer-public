import XCTest
import AppKit
@testable import CodexChats

final class DateConnectionTests: XCTestCase {
    private func id(_ name: String) -> ProjectIdentity { .assigned(kind: "fixture", id: name) }
    private func series(_ name: String, _ ys: [CGFloat]) -> DateConnectionGeometry.Series { .init(identity: id(name), points: ys) }
    private var interleaved: DateConnectionGeometry {
        DateConnectionGeometry([series("a", [40,160,280]), series("b", [80,200,320]), series("c", [120,240,360])])
    }

    func testSingletonIsOnlyADotAndNeverOccupiesARail() {
        let geometry = DateConnectionGeometry([series("single", [80])])
        XCTAssertEqual(geometry.nodes.count, 1)
        XCTAssertTrue(geometry.rails.isEmpty)
        XCTAssertTrue(geometry.branches.isEmpty)
        let mixed = DateConnectionGeometry([series("single", [80]), series("empty", []), series("multi", [40,120])])
        XCTAssertEqual(mixed.rails.map(\.identity), [id("multi")])
        XCTAssertEqual(mixed.rails.map(\.lane), [0])
        XCTAssertEqual(mixed.rails[0].x, 35)
    }

    func testMalformedAndDuplicatePositionsCannotMakeBrokenPaths() {
        let geometry = DateConnectionGeometry([series("a", [.nan,.infinity,-10,80,80]), series("a", [40,80]), .init(identity: .noProject, points: [20,120])])
        XCTAssertEqual(geometry.rails.count, 1)
        XCTAssertEqual(geometry.rails[0].points, [40,80])
        XCTAssertEqual(geometry.nodes.count, 2)
        XCTAssertEqual(geometry.branches.count, 2)
        XCTAssertTrue(geometry.nodes.allSatisfy { $0.identity == id("a") })
    }

    func testEveryBranchEndsAtItsOwnSpineOrCorner() throws {
        let geometry = interleaved
        XCTAssertEqual(geometry.rails.map(\.lane), [0,1,2])
        XCTAssertEqual(geometry.rails.map(\.x), [35,55,75])
        for branch in geometry.branches {
            let rail = try XCTUnwrap(geometry.rails.first { $0.identity == branch.identity })
            let endpoint = branch.y == rail.points.first || branch.y == rail.points.last
            XCTAssertEqual(branch.endX, rail.x - (endpoint ? rail.radius : 0), accuracy: 0.00001)
            XCTAssertGreaterThan(branch.endX, DateConnectionGeometry.anchorOffset)
            XCTAssertFalse(rail.gaps.contains { $0.contains(branch.y) }, "A crossing must never erase the owning junction")
            if !endpoint { XCTAssertTrue(rail.segments.contains { $0.contains(branch.y) }) }
        }
    }

    func testCrossingsAreActualGapsOnlyOnOtherSpines() {
        let geometry = interleaved
        XCTAssertEqual(geometry.rails.map { $0.gaps.count }, [4,2,0])
        XCTAssertEqual(geometry.rails[0].gaps.map { ($0.lowerBound + $0.upperBound) / 2 }, [80,120,200,240])
        for rail in geometry.rails {
            for gap in rail.gaps {
                XCTAssertFalse(rail.segments.contains { $0.overlaps(gap) && $0.lowerBound < gap.upperBound && $0.upperBound > gap.lowerBound })
            }
            XCTAssertEqual(rail.segments.first?.lowerBound, rail.points[0] + rail.radius)
            XCTAssertEqual(rail.segments.last?.upperBound, rail.points.last! - rail.radius)
        }
    }

    func testNarrowWindowsAndManyProjectsNeverCompressOrClipTracks() {
        for viewport: CGFloat in [240,400,600,940,1560] {
            for count in [0,1,2,3,8,16,64] {
                let width = max(viewport, DateConnectionGeometry.minimumDocumentWidth(railCount: count,viewportWidth:viewport))
                let controls = DateProjectControls(width: width, rowY: 0, connectionTrackCount: count,layoutWidth:viewport)
                XCTAssertEqual(controls.spineX - controls.connections.maxX, 35)
                XCTAssertEqual(controls.trackSpacing, 20)
                XCTAssertGreaterThanOrEqual(controls.name.width, 1)
                if count > 0 {
                    let lastX = controls.spineX + CGFloat(count - 1) * controls.trackSpacing
                    XCTAssertEqual(lastX, width - 16, accuracy: 0.00001)
                }
            }
        }
    }

    private func project(_ name: String) -> ProjectReference {
        ProjectReference(identity: id(name), name: "Same name", originalAssignment: nil, originalProject: nil)
    }
    private func snapshot(_ chats: [Chat]) -> ChatSnapshot {
        let source = URL(fileURLWithPath: "/fixture")
        return ChatSnapshot(chats: chats, sourceURL: source, observedAt: Date(), excludedSubagents: 0, projectSourceURL: source, projectSourceIssue: nil)
    }
    private func chats(_ count: Int, project: ProjectReference, archived: Bool = false) -> [Chat] {
        (0..<count).map { index in
            Chat(original: ["archived": .integer(archived ? 1 : 0)], id: "\(project.identity.savedKey)-\(index)-\(archived)", title: "Fixture chat \(index)", createdAt: Date(timeIntervalSince1970: Double(10000-index*60)), archived: archived, issues: [], project: project)
        }
    }

    func testRemovingFilteringAndRefreshingPackOnlyRenderableRails() {
        _ = NSApplication.shared
        let a = project("a"), b = project("b"), single = project("single")
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistExpansion: false)
        view.setPresentation(.date)
        let all = chats(2,project:a) + chats(1,project:b,archived:true) + chats(1,project:b) + chats(1,project:single)
        view.setSnapshot(snapshot(all))
        for project in [single,a,b] { view.toggleDateConnections(project) }
        XCTAssertEqual(view.dateConnectionGeometry.rails.map(\.identity), [a.identity,b.identity])
        view.toggleDateConnections(a)
        XCTAssertEqual(view.dateConnectionGeometry.rails.map(\.lane), [0])
        XCTAssertEqual(view.dateConnectionGeometry.rails[0].identity, b.identity)
        view.toggleDateConnections(a)
        view.setDateArchiveFilter(.nonArchived)
        XCTAssertEqual(view.dateConnectionGeometry.rails.map(\.identity), [a.identity])
        XCTAssertEqual(view.dateConnectionGeometry.nodes.filter { $0.identity == b.identity }.count, 1)
        XCTAssertFalse(view.dateConnectionGeometry.branches.contains { $0.identity == b.identity })
        XCTAssertEqual(view.dateConnectionProjects.count, 3)
        view.toggleDateConnections(a); view.toggleDateConnections(b)
        view.setDateSelectionFilterEnabled(true)
        XCTAssertTrue(view.dateConnectionGeometry.rails.isEmpty)
        XCTAssertTrue(view.dateConnectionGeometry.branches.isEmpty)
        XCTAssertEqual(view.dateConnectionGeometry.nodes.count, 1)
        view.setDateSelectionFilterEnabled(false); view.setDateArchiveFilter(.all)
        view.toggleDateConnections(b); view.toggleDateConnections(a)
        XCTAssertEqual(view.dateConnectionGeometry.rails.map(\.identity), [b.identity,a.identity])
        view.setSnapshot(snapshot(chats(2,project:b)))
        XCTAssertEqual(view.dateConnectionProjects.count, 1)
        XCTAssertEqual(view.dateConnectionGeometry.rails.map(\.lane), [0])
        XCTAssertEqual(view.dateConnectionGeometry.rails[0].identity, b.identity)
    }

    func testCrowdedDateViewUsesHorizontalOverflowInsteadOfClipping() {
        _ = NSApplication.shared
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 600, height: 650), persistTheme: false, loadOnDemand: false)
        let projects = (0..<24).map { project(String($0)) }
        root.show(snapshot(projects.flatMap { chats(2,project:$0) })); root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        let rowHeight = root.timeline.entries.first(where: { $0.chat != nil })?.height
        for project in projects { root.timeline.toggleDateConnections(project) }
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(root.scroll.hasHorizontalScroller)
        XCTAssertGreaterThan(root.timeline.frame.width, root.scroll.contentView.bounds.width)
        XCTAssertEqual(root.timeline.dateConnectionGeometry.rails.map(\.lane), Array(0..<24))
        XCTAssertEqual(root.timeline.entries.first(where: { $0.chat != nil })?.height,rowHeight,"Toggling connections must not move rows into a different layout mode")
        for _ in 0..<5 { root.adjustTextSize(by: TextSizing.step) }
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.timeline.dateConnectionGeometry.rails.count, 24)
        let controls = DateProjectControls(width: root.timeline.bounds.width, rowY: 0, connectionTrackCount: 24)
        XCTAssertEqual(controls.spineX + 23 * 20, root.timeline.bounds.width - 16)
        root.scroll.contentView.scroll(to:NSPoint(x:root.timeline.frame.width-root.scroll.contentView.bounds.width,y:140))
        let originalOffset = root.scroll.contentView.bounds.origin
        XCTAssertGreaterThan(originalOffset.x, 0)
        root.toggleDateSelectionFilter(); root.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.timeline.dateConnectionGeometry.rails.map(\.lane), Array(0..<24))
        XCTAssertLessThanOrEqual(root.scroll.contentView.bounds.maxX,root.timeline.frame.width+1)
        XCTAssertTrue(root.clearDateSelectionFilter())
        XCTAssertEqual(root.scroll.contentView.bounds.origin.x, originalOffset.x, accuracy: 0.5)
        XCTAssertEqual(root.scroll.contentView.bounds.origin.y, originalOffset.y, accuracy: 0.5)
    }

    func testGlobalFilterAlignmentZoomAndNativeRendering() throws {
        _ = NSApplication.shared
        let projects = [project("a"), project("b"), project("c")]
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false)
        let window = ChatWindow(contentSize: root.frame.size); window.contentView = root
        defer { window.contentView = nil; window.close() }
        root.show(snapshot(projects.flatMap { chats(3, project: $0) })); root.setPresentation(.date)
        for project in projects.prefix(2) { root.timeline.toggleDateConnections(project) }
        let button = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Filter selected projects" })
        for width: CGFloat in [600,940,1100] {
            root.setFrameSize(NSSize(width: width, height: 650)); root.needsLayout = true
            root.resetTextSize(); root.layoutSubtreeIfNeeded()
            let column = root.timeline.convert(root.timeline.dateConnectionsColumn, to: root)
            XCTAssertEqual(button.frame.midX, column.midX, accuracy: 1)
            XCTAssertEqual(button.frame.size, column.size)
            for _ in 0..<5 { root.adjustTextSize(by: TextSizing.step) }
            XCTAssertGreaterThanOrEqual(button.frame.minX, 330)
            XCTAssertLessThanOrEqual(button.frame.maxX, width - 22)
            XCTAssertEqual(button.frame.minY, (width < 966 ? 103 : 76) + DateSearchBar.rowHeight, "Global action stays above the scrollable timeline")
            let zoomedColumn = root.timeline.convert(root.timeline.dateConnectionsColumn, to: root)
            XCTAssertEqual(button.frame.width, zoomedColumn.width, accuracy: 0.001)
            XCTAssertEqual(button.frame.height, zoomedColumn.height, accuracy: 0.001)
            XCTAssertLessThan(button.frame.maxY, root.scroll.frame.minY)
            XCTAssertNil(button.toolTip)
        }
        root.setFrameSize(NSSize(width:940,height:650)); root.resetTextSize(); root.layoutSubtreeIfNeeded()
        button.performClick(nil)
        XCTAssertEqual(root.timeline.dateChatCount,6)
        XCTAssertEqual(button.state,.on)
        if let directory = ProcessInfo.processInfo.environment["DATE_SELECTION_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            // Use real local chat metadata for visual review when explicitly requested.
            root.show(try ChatStore.load())
            for selected in Array(root.timeline.dateConnectionProjects.values) { root.timeline.toggleDateConnections(selected) }
            for group in root.timeline.groups.filter({ if case .assigned = $0.project.identity { return true }; return false }).prefix(3) {
                root.timeline.toggleDateConnections(group.project)
            }
            root.toggleDateSelectionFilter()
            for dark in [false,true] {
                root.setDark(dark); root.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in:root.bounds,to:rep)
                try rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent(dark ? "selection-dark.png" : "selection-light.png"))
            }
        }
    }

    private func render(_ geometry: DateConnectionGeometry, dark: Bool = false, tiled: Bool = false, scale: Int = 2) throws -> NSBitmapImageRep {
        let width = 180, height = 400
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width*scale, pixelsHigh: height*scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let transform = NSAffineTransform(); transform.translateX(by: 0, yBy: CGFloat(height*scale)); transform.scaleX(by: CGFloat(scale), yBy: -CGFloat(scale)); transform.concat()
        (dark ? NSColor.black : NSColor.white).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        var rects = [NSRect(x: 0, y: 0, width: width, height: height)]
        if tiled {
            rects = []
            for y in stride(from:0,to:height,by:37) {
                for x in stride(from:0,to:width,by:43) { rects.append(NSRect(x:x,y:y,width:min(43,width-x),height:min(37,height-y))) }
            }
        }
        let hues: [ProjectIdentity: CGFloat] = [id("a"):0.02,id("b"):0.56,id("c"):0.80]
        for rect in rects { geometry.draw(in: rect, originX: 40) { DateProjectColors.color(for: $0, dark: dark, hue:hues[$0]) } }
        return rep
    }

    func testFullAndDirtyRectangleRendersMatchExactly() throws {
        for dark in [false,true] {
            for scale in [1,2,3] {
                let full = try render(interleaved,dark:dark,scale:scale), tiled = try render(interleaved,dark:dark,tiled:true,scale:scale)
                let bytes = full.bytesPerRow * full.pixelsHigh
                XCTAssertEqual(Data(bytes: try XCTUnwrap(full.bitmapData),count:bytes), Data(bytes:try XCTUnwrap(tiled.bitmapData),count:bytes), "Dirty repaint changed geometry at scale \(scale), dark \(dark)")
            }
        }
        if let directory = ProcessInfo.processInfo.environment["DATE_CONNECTION_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for dark in [false,true] {
                let rep = try render(interleaved,dark:dark)
                try rep.representation(using:.png,properties:[:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(dark ? "crossings-dark.png" : "crossings-light.png"))
            }
        }
    }

    func testSingletonRasterHasNoHorizontalStick() throws {
        let rep = try render(DateConnectionGeometry([series("one",[80])]), scale: 1)
        for x in 53..<170 {
            let color = try XCTUnwrap(rep.colorAt(x:x,y:80)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(color.redComponent,0.99)
            XCTAssertGreaterThan(color.greenComponent,0.99)
            XCTAssertGreaterThan(color.blueComponent,0.99)
        }
        let dot = try XCTUnwrap(rep.colorAt(x:48,y:80)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(min(dot.redComponent,dot.greenComponent,dot.blueComponent),0.9)
    }

    func testRasterShowsAnOverpassGapAndContinuousOwningCorners() throws {
        let rep = try render(interleaved,scale:1)
        func isPaper(_ x: Int, _ y: Int) throws -> Bool {
            let color = try XCTUnwrap(rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
            return min(color.redComponent,color.greenComponent,color.blueComponent) > 0.99
        }
        // B's branch crosses A's x=75 spine at y=80. The branch is continuous;
        // the spine has paper immediately above/below, and resumes beyond it.
        XCTAssertFalse(try isPaper(75,80))
        XCTAssertTrue(try isPaper(75,78))
        XCTAssertTrue(try isPaper(75,82))
        XCTAssertFalse(try isPaper(75,74))
        XCTAssertFalse(try isPaper(75,86))
        // The first/last horizontal arms meet their own rounded corners.
        for point in [(66,40),(67,40),(73,42),(75,48),(75,272),(73,277),(67,280)] {
            XCTAssertFalse(try isPaper(point.0,point.1),"Missing corner/junction at \(point)")
        }
    }

    func testThousandsOfRowsKeepDenseRailsAndCompleteEndpoints() {
        var inputs = [DateConnectionGeometry.Series]()
        for index in 0..<64 {
            var positions = [CGFloat]()
            for row in 0..<48 { positions.append(CGFloat((row * 64 + index) * 42 + 40)) }
            inputs.append(series(String(index), positions))
        }
        let geometry = DateConnectionGeometry(inputs)
        XCTAssertEqual(geometry.rails.map(\.lane),Array(0..<64))
        XCTAssertEqual(geometry.branches.count,3072)
        XCTAssertEqual(geometry.nodes.count,3072)
        XCTAssertTrue(geometry.branches.allSatisfy { $0.endX.isFinite && $0.endX > DateConnectionGeometry.anchorOffset })
    }
}
