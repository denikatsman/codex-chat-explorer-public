import XCTest
import AppKit
@testable import CodexChats

final class CursorGeometryTests: XCTestCase {
    private func snapshot(_ count: Int = 40) -> ChatSnapshot {
        let project = ProjectReference(identity: .assigned(kind: "fixture", id: "project"), name: "Fixture", originalAssignment: nil, originalProject: nil)
        let chats = (0..<count).map { Chat(original: [:], id: "fixture-\($0)", title: "Fixture \($0)", createdAt: Date(timeIntervalSince1970: 10000 - Double($0)), archived: false, issues: [], project: project) }
        let url = URL(fileURLWithPath: "/unavailable-cursor-fixture/state_5.sqlite")
        return ChatSnapshot(chats: chats, sourceURL: url, observedAt: Date(), excludedSubagents: 0, projectSourceURL: url, projectSourceIssue: nil)
    }
    private func view(width: CGFloat = 940, count: Int = 40) -> TimelineView {
        _ = NSApplication.shared
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 2000), persistExpansion: false)
        view.setPresentation(.date); view.setSnapshot(snapshot(count)); view.fitViewport(NSSize(width: width, height: 200))
        return view
    }

    func testCrashIntersectionIsRejectedBeforeAppKit() {
        let label = NSRect(x: 650, y: 53, width: 220, height: 24)
        let checkbox = NSRect(x: 22, y: 56, width: 16, height: 16)
        let viewport = NSRect(x: 0, y: 74, width: 940, height: 500)
        XCTAssertFalse(label.intersection(viewport).isEmpty)
        XCTAssertTrue(checkbox.intersection(viewport).isNull)
        XCTAssertFalse(checkbox.intersection(viewport).origin.x.isFinite)
        XCTAssertNil(CursorGeometry.clipped(checkbox, to: viewport))
    }

    func testNonfiniteEmptyAndOverflowingInputNeverProducesCursorRegions() {
        let valid = NSRect(x: 0, y: 0, width: 940, height: 600)
        let invalid: [NSRect] = [.null, .infinite, .zero,
            NSRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            NSRect(x: 0, y: CGFloat.infinity, width: 10, height: 10),
            NSRect(x: 0, y: 0, width: -10, height: 10),
            NSRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 10)]
        for rect in invalid {
            XCTAssertNil(CursorGeometry.clipped(rect, to: valid))
            XCTAssertNil(CursorGeometry.clipped(valid, to: rect))
        }
    }

    func testEachControlIsClippedIndependentlyOfProjectLabel() throws {
        let list = view(count: 1)
        let row = try XCTUnwrap(list.entries.first { $0.chat != nil })
        let checkbox = try XCTUnwrap(list.cursorRegions(in: NSRect(x: 20, y: row.y, width: 30, height: row.height)).first { $0.kind == .control })
        let topClipped = list.cursorRegions(in: NSRect(x: 0, y: checkbox.rect.maxY + 0.5, width: 940, height: 100))
        XCTAssertFalse(topClipped.isEmpty)
        XCTAssertFalse(topClipped.contains { $0.kind == .control && $0.rect.minX == 22 })
        let bodyOnly = list.cursorRegions(in: NSRect(x: 100, y: row.y, width: 100, height: row.height))
        XCTAssertEqual(bodyOnly.count, 1)
        XCTAssertEqual(bodyOnly.first?.kind, .row, "Visible row remains draggable even when the project label is offscreen")
        let checkboxOnly = list.cursorRegions(in: NSRect(x: 20, y: row.y, width: 30, height: row.height))
        XCTAssertTrue(checkboxOnly.contains { $0.kind == .control })
    }

    func testCursorGeometryAcrossClippingZoomLayoutsAndHorizontalScroll() {
        for width: CGFloat in [300, 450, 940, 2400, 3840] {
            let list = view(width: width)
            for x: CGFloat in [0, 15, 40, width - 25] {
                for y in stride(from: CGFloat(0), through: 200, by: 2.5) {
                    for height: CGFloat in [1, 17, 200, 800] {
                        let visible = NSRect(x: x, y: y, width: width, height: height)
                        for region in list.cursorRegions(in: visible) {
                            XCTAssertTrue(CursorGeometry.isUsable(region.rect))
                            XCTAssertTrue(visible.contains(region.rect))
                            XCTAssertTrue(list.bounds.contains(region.rect))
                        }
                    }
                }
            }
        }
    }

    func testActualCursorRegistrationSurvivesScrolledAndHiddenViews() {
        let list = view()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = list
        let window = ChatWindow(contentSize: scroll.frame.size); window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        for point in [NSPoint(x: 0, y: 74), NSPoint(x: 40, y: 74), NSPoint(x: 0, y: 54), NSPoint(x: 300, y: 116)] {
            scroll.contentView.setBoundsOrigin(point)
            for hidden in [false, true, false] {
                scroll.isHidden = hidden
                list.resetCursorRects()
                XCTAssertTrue(list.cursorRegions(in: list.visibleRect).allSatisfy { CursorGeometry.isUsable($0.rect) })
            }
        }
    }

    func testReaderBackAndUnchangedZoomRetainHorizontalDatePosition() throws {
        _ = NSApplication.shared
        let projects = (0..<24).map { ProjectReference(identity:.assigned(kind:"fixture",id:String($0)),name:"Project \($0)",originalAssignment:nil,originalProject:nil) }
        let chats = (0..<48).map { Chat(original:[:],id:"wide-\($0)",title:"Wide fixture",createdAt:Date(timeIntervalSince1970:10000-Double($0)),archived:false,issues:[],project:projects[$0%24]) }
        let url=URL(fileURLWithPath:"/unavailable-cursor-fixture/state_5.sqlite")
        let data=ChatSnapshot(chats:chats,sourceURL:url,observedAt:Date(),excludedSubagents:0,projectSourceURL:url,projectSourceIssue:nil)
        let root=ChatRootView(frame:NSRect(x:0,y:0,width:600,height:650),persistTheme:false,loadOnDemand:false)
        root.show(data);root.setPresentation(.date);root.layoutSubtreeIfNeeded()
        for project in projects { root.timeline.toggleDateConnections(project) }
        root.layoutSubtreeIfNeeded()
        root.scroll.contentView.scroll(to:NSPoint(x:120,y:80))
        let before=root.scroll.contentView.bounds.origin
        XCTAssertGreaterThan(before.x,0)
        root.adjustTextSize(by:1)
        XCTAssertEqual(root.scroll.contentView.bounds.origin.x,before.x,accuracy:0.5)
        root.openChat(chats[2].id)
        let reader=try XCTUnwrap(root.subviews.compactMap { $0 as? HistoryPane }.first)
        let back=try XCTUnwrap(reader.subviews.compactMap { $0 as? NSButton }.first { $0.title == "‹ BACK" })
        back.performClick(nil);root.layoutSubtreeIfNeeded()
        XCTAssertTrue(reader.isHidden)
        XCTAssertEqual(root.scroll.contentView.bounds.origin.x,before.x,accuracy:0.5)
        XCTAssertEqual(root.scroll.contentView.bounds.origin.y,before.y,accuracy:0.5)
    }

    func testCancelledReadDoesNotLeaveSavedExcerptControlsDisabled() throws {
        _ = NSApplication.shared
        let library = ExplorerLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let pane = HistoryPane(library: library), data = snapshot(1)
        pane.show(chat: data.chats[0], snapshot: data)
        XCTAssertTrue(pane.loading)
        let excerpt = SavedExcerpt(id: UUID(), chatID: "saved", chatTitle: "Saved", messageReferences: [], ordinal: nil, sourcePath: "/fixture", text: "Saved text", savedAt: Date())
        pane.showSaved(excerpt)
        XCTAssertFalse(pane.loading)
        let copy = try XCTUnwrap(pane.subviews.compactMap { $0 as? NSButton }.first { $0.title == "COPY" })
        XCTAssertTrue(copy.isEnabled)
        pane.hideReader(); XCTAssertFalse(pane.loading); XCTAssertFalse(copy.isEnabled)
    }

    func testNewOrFailedReadCannotRenderPreviousContent() throws {
        _ = NSApplication.shared
        let library = ExplorerLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let pane = HistoryPane(library: library), data = snapshot(1)
        pane.showSaved(SavedExcerpt(id: UUID(), chatID: "saved", chatTitle: "Saved", messageReferences: [], ordinal: nil, sourcePath: "/fixture", text: "PREVIOUS CONTENT", savedAt: Date()))
        pane.show(chat: data.chats[0], snapshot: data)
        let text = try XCTUnwrap(pane.scroll.documentView as? NSTextView)
        XCTAssertFalse(text.string.contains("PREVIOUS CONTENT"))
        let deadline = Date().addingTimeInterval(2)
        while pane.loading && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(pane.loading)
        XCTAssertTrue(pane.statusText.hasPrefix("UNAVAILABLE"))
        pane.setTheme(dark: true, green: false, scale: 1.3225)
        XCTAssertFalse(text.string.contains("PREVIOUS CONTENT"))
        XCTAssertEqual(pane.displayedMessageCount, 0)
        XCTAssertFalse(pane.subviews.compactMap { $0 as? NSButton }.first { $0.title == "RAW" }?.isEnabled ?? true)
    }
}
