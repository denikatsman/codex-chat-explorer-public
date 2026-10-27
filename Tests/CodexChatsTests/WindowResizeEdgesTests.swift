import AppKit
import XCTest
@testable import CodexChats

final class WindowResizeEdgesTests: XCTestCase {
    private let original = NSRect(x:100,y:200,width:400,height:300)
    private let minimum = NSSize(width:200,height:100)
    private let maximum = NSSize(width:500,height:600)

    private func resized(_ edge: ResizeEdge, delta: NSPoint = NSPoint(x:30,y:40), flipped: Bool) -> NSRect? {
        WindowResizeGeometry.resized(original,edge:edge,delta:delta,isFlipped:flipped,minimumSize:minimum,maximumSize:maximum)
    }

    func testEveryEdgeAndCornerInBothCoordinateSystems() {
        let expected: [(ResizeEdge, NSRect, NSRect)] = [
            (.left, NSRect(x:130,y:200,width:370,height:300), NSRect(x:130,y:200,width:370,height:300)),
            (.right, NSRect(x:100,y:200,width:430,height:300), NSRect(x:100,y:200,width:430,height:300)),
            (.top, NSRect(x:100,y:200,width:400,height:340), NSRect(x:100,y:240,width:400,height:260)),
            (.bottom, NSRect(x:100,y:240,width:400,height:260), NSRect(x:100,y:200,width:400,height:340)),
            (.topLeft, NSRect(x:130,y:200,width:370,height:340), NSRect(x:130,y:240,width:370,height:260)),
            (.topRight, NSRect(x:100,y:200,width:430,height:340), NSRect(x:100,y:240,width:430,height:260)),
            (.bottomLeft, NSRect(x:130,y:240,width:370,height:260), NSRect(x:130,y:200,width:370,height:340)),
            (.bottomRight, NSRect(x:100,y:240,width:430,height:260), NSRect(x:100,y:200,width:430,height:340))
        ]
        for (edge, unflipped, flipped) in expected {
            XCTAssertEqual(resized(edge,flipped:false),unflipped,"\(edge)")
            XCTAssertEqual(resized(edge,flipped:true),flipped,"\(edge)")
        }
    }

    func testClampingKeepsOppositeEdgesAnchored() throws {
        for flipped in [false,true] {
            for magnitude: CGFloat in [-10_000,10_000] {
                for edge in ResizeEdge.allCases {
                    let result = try XCTUnwrap(resized(edge,delta:NSPoint(x:magnitude,y:magnitude),flipped:flipped))
                    XCTAssertTrue((minimum.width...maximum.width).contains(result.width))
                    XCTAssertTrue((minimum.height...maximum.height).contains(result.height))
                    if [.left,.topLeft,.bottomLeft].contains(edge) { XCTAssertEqual(result.maxX,original.maxX) }
                    else { XCTAssertEqual(result.minX,original.minX) }
                    let changesMinY = flipped ? [.top,.topLeft,.topRight].contains(edge) : [.bottom,.bottomLeft,.bottomRight].contains(edge)
                    if changesMinY { XCTAssertEqual(result.maxY,original.maxY) }
                    else { XCTAssertEqual(result.minY,original.minY) }
                }
            }
        }
        XCTAssertEqual(resized(.left,flipped:true)?.height,original.height)
        XCTAssertEqual(resized(.top,flipped:true)?.width,original.width)
    }

    func testMalformedGeometryAndConstraintsDoNotEscape() throws {
        let invalid: [NSRect] = [.null,.infinite,.zero,NSRect(x:CGFloat.nan,y:0,width:10,height:10),NSRect(x:0,y:0,width:-1,height:10),NSRect(x:CGFloat.greatestFiniteMagnitude,y:0,width:CGFloat.greatestFiniteMagnitude,height:10)]
        for rect in invalid {
            XCTAssertNil(WindowResizeGeometry.resized(rect,edge:.bottomRight,delta:.zero,isFlipped:true,minimumSize:minimum,maximumSize:maximum))
            XCTAssertTrue(WindowResizeGeometry.regions(in:rect,isFlipped:true).isEmpty)
        }
        for delta in [NSPoint(x:CGFloat.nan,y:0),NSPoint(x:0,y:CGFloat.infinity)] { XCTAssertNil(resized(.right,delta:delta,flipped:true)) }
        for limits in [(NSSize.zero,maximum),(minimum,NSSize(width:100,height:100)),(minimum,NSSize(width:CGFloat.infinity,height:600))] {
            XCTAssertNil(WindowResizeGeometry.resized(original,edge:.right,delta:.zero,isFlipped:true,minimumSize:limits.0,maximumSize:limits.1))
        }
        // Finite deltas that overflow addition are still bounded by finite limits.
        let huge = CGFloat.greatestFiniteMagnitude
        let result = try XCTUnwrap(WindowResizeGeometry.resized(NSRect(x:0,y:0,width:huge,height:300),edge:.right,delta:NSPoint(x:huge,y:0),isFlipped:true,minimumSize:minimum,maximumSize:maximum))
        XCTAssertEqual(result.width,maximum.width)
        XCTAssertTrue(CursorGeometry.isUsable(result))
    }

    func testPerimeterRegionsPreserveInteriorAndMapVisualCorners() {
        let bounds = NSRect(x:20,y:30,width:400,height:300)
        for flipped in [false,true] {
            let regions = WindowResizeGeometry.regions(in:bounds,isFlipped:flipped)
            XCTAssertEqual(Set(regions.map(\.edge)),Set(ResizeEdge.allCases))
            for region in regions {
                XCTAssertTrue(CursorGeometry.isUsable(region.rect))
                XCTAssertTrue(bounds.contains(region.rect))
                XCTAssertFalse(region.rect.intersects(bounds.insetBy(dx:6,dy:6)))
            }
            for (index, region) in regions.enumerated() {
                XCTAssertFalse(regions.dropFirst(index+1).contains { $0.rect.intersects(region.rect) })
            }
            XCTAssertEqual(regions.first { $0.rect.contains(NSPoint(x:22,y:32)) }?.edge,flipped ? .topLeft : .bottomLeft)
            XCTAssertEqual(regions.first { $0.rect.contains(NSPoint(x:418,y:328)) }?.edge,flipped ? .bottomRight : .topRight)
            XCTAssertFalse(regions.contains { $0.rect.contains(NSPoint(x:30,y:40)) },"Corner hit targets must stay in the perimeter, not cover 18-point squares")
        }
        for size in [NSSize(width:1,height:1),NSSize(width:10,height:40),NSSize(width:400,height:4)] {
            let tiny = NSRect(origin:.zero,size:size)
            XCTAssertTrue(WindowResizeGeometry.regions(in:tiny,isFlipped:true).allSatisfy { CursorGeometry.isUsable($0.rect) && tiny.contains($0.rect) })
        }
    }

    func testOverlayHitTestingAndSafeCursorClipping() throws {
        _ = NSApplication.shared
        let container = NSView(frame:NSRect(x:0,y:0,width:800,height:600))
        let panel = NSView(frame:NSRect(x:100,y:80,width:400,height:300))
        let button = NSButton(frame:NSRect(x:100,y:100,width:100,height:40))
        container.addSubview(panel);panel.addSubview(button)
        let edges = WindowResizeEdges(frame:panel.bounds)
        panel.addSubview(edges)
        edges.configure(view:panel,minimumSize:minimum,maximumSize:maximum) { [weak panel] in panel?.frame = $0 }
        XCTAssertTrue(panel.hitTest(NSPoint(x:102,y:180)) === edges)
        XCTAssertTrue(panel.hitTest(NSPoint(x:250,y:200)) === button)
        XCTAssertNil(edges.hitTest(NSPoint(x:10,y:10)))
        XCTAssertNil(edges.hitTest(NSPoint(x:200,y:150)))
        let visible = NSRect(x:0,y:50,width:50,height:50)
        let regions = edges.cursorRegions(in:visible)
        XCTAssertFalse(regions.isEmpty)
        XCTAssertTrue(regions.allSatisfy { CursorGeometry.isUsable($0.rect) && visible.contains($0.rect) })
        XCTAssertTrue(edges.cursorRegions(in:.null).isEmpty)
        edges.resetCursorRects()
        edges.isEnabled = false;XCTAssertNil(edges.hitTest(NSPoint(x:2,y:100)))
        edges.isEnabled = true;panel.isHidden = true
        XCTAssertTrue(edges.cursorRegions(in:edges.bounds).isEmpty)
    }

    func testNativeTrackingDeliversWholeFrameAndEndsOnce() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame:NSRect(x:0,y:0,width:800,height:600))
        window.contentView = container
        defer { window.contentView = nil;window.close() }
        let panel = NSView(frame:original)
        container.addSubview(panel)
        let edges = WindowResizeEdges(frame:panel.bounds)
        panel.addSubview(edges)
        var began = 0, ended = 0
        edges.onBegin = { began += 1 };edges.onEnd = { ended += 1 }
        edges.configure(view:panel,minimumSize:minimum,maximumSize:maximum) { [weak panel] in panel?.frame = $0 }
        let start = edges.convert(NSPoint(x:2,y:298),to:nil)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
        }
        let end = NSPoint(x:start.x+30,y:start.y+40)
        NSApp.postEvent(try event(.leftMouseDragged,end),atStart:true)
        NSApp.postEvent(try event(.leftMouseUp,end),atStart:false)
        edges.mouseDown(with:try event(.leftMouseDown,start))
        XCTAssertEqual(panel.frame,NSRect(x:130,y:200,width:370,height:340))
        XCTAssertEqual(began,1);XCTAssertEqual(ended,1)
        XCTAssertFalse(window.isVisible,"The native tracking fixture must remain offscreen")
    }
}
