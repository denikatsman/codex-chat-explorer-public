import XCTest
import AppKit
import CSQLite
import ModelSupport
@testable import CodexChats

final class DateChatControlsTests: XCTestCase {
    private func fixture(_ directory: URL) -> ChatSnapshot {
        let project = ProjectReference(identity: .assigned(kind: "local", id: "p"), name: "Fixture", originalAssignment: nil, originalProject: nil)
        let chats = ["new", "old", "archived"].enumerated().map { index, id in
            Chat(original: ["archived": .integer(id == "archived" ? 1 : 0)], id: id, title: "Original \(id)", createdAt: Date(timeIntervalSince1970: Double(300 - index * 100)), archived: id == "archived", issues: [], project: project)
        }
        let source = directory.appendingPathComponent("state_5.sqlite")
        return ChatSnapshot(chats: chats, sourceURL: source, observedAt: Date(), excludedSubagents: 0, projectSourceURL: source, projectSourceIssue: nil)
    }
    func testPinsAreSharedUniqueAndRespectArchiveFilter() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("date-controls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ExplorerLibrary(directory: directory)
        let first = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 600), persistTheme: false, loadOnDemand: false, library: library)
        let second = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 600), persistTheme: false, loadOnDemand: false, library: library)
        for root in [first, second] { root.show(fixture(directory)); root.setPresentation(.date) }
        first.timeline.onTogglePinned?("old")
        XCTAssertEqual(second.timeline.entries.compactMap(\.chat).map(\.id), ["old", "new", "archived"])
        XCTAssertEqual(second.timeline.entries.compactMap(\.day).first, "PINNED")
        XCTAssertTrue(second.timeline.entries.compactMap(\.day).contains("CHATS"))
        try library.togglePinned("archived")
        second.setDateArchiveFilter(.nonArchived)
        XCTAssertEqual(second.timeline.entries.compactMap(\.chat).map(\.id), ["old", "new"])
        XCTAssertEqual(Set(second.timeline.entries.compactMap(\.chat).map(\.id)).count, 2)
        XCTAssertEqual(first.labelRequestCount, 0); XCTAssertEqual(second.labelRequestCount, 0)
        XCTAssertEqual(fixture(directory).chats.map(\.title), ["Original new", "Original old", "Original archived"])
    }
    func testDoubleClickPinDoesNotToggleReorderedRowTwice() throws {
        _ = NSApplication.shared
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 940, height: 600), persistExpansion: false)
        let window = ChatWindow(contentSize: view.frame.size)
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.setSnapshot(fixture(FileManager.default.temporaryDirectory)); view.setPresentation(.date)
        var state = ExplorerLibraryState(), toggles = [String](), opened = [String]()
        view.onTogglePinned = { id in
            toggles.append(id)
            if !state.pinnedChatIDs.insert(id).inserted { state.pinnedChatIDs.remove(id) }
            view.setAnnotations(state)
        }
        view.onOpenChat = { id, _ in opened.append(id) }
        let original = try XCTUnwrap(view.entries.first { $0.chat?.id == "old" })
        let pin = try XCTUnwrap((view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Pin chat: Original old" })
        let frame = window.convertFromScreen(pin.accessibilityFrame())
        let point = view.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)
        func down(_ clicks: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: clicks, clickCount: clicks, pressure: 1))
        }
        view.mouseDown(with: try down(1))
        let moved = try XCTUnwrap(view.entries.first { $0.chat?.id == "old" })
        XCTAssertNotEqual(moved.y, original.y)
        XCTAssertTrue(point.y >= moved.y && point.y < moved.y + moved.height)
        view.mouseDown(with: try down(2))
        XCTAssertEqual(toggles, ["old"])
        XCTAssertEqual(state.pinnedChatIDs, ["old"])
        XCTAssertTrue(opened.isEmpty)
    }
    func testHistoryLabelBackReturnsToReader() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-label-\(UUID())")
        let snapshot = fixture(directory)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 600), persistTheme: false, loadOnDemand: false)
        root.show(snapshot); root.setPresentation(.date); root.openChat("new")
        let history = try XCTUnwrap(root.subviews.compactMap { $0 as? HistoryPane }.first)
        history.onGenerateLabel?(snapshot.chats[0], snapshot)
        let label = try XCTUnwrap(root.subviews.compactMap { $0 as? LabelPane }.first)
        XCTAssertFalse(label.isHidden)
        label.onBack?()
        XCTAssertFalse(history.isHidden)
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(root.labelRequestCount, 0)
    }
    func testExplicitRowSummaryUsesLocalOnceAndLeavesSourceBytesUntouched() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("date-summary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(history.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT);
        INSERT INTO thread_items VALUES('new','turn','item',1,1000,'userMessage','{"content":[{"type":"text","text":"A synthetic fixture message"}]}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let original = try Data(contentsOf: history)
        let worker = directory.appendingPathComponent("worker.py"), observed = directory.appendingPathComponent("provider")
        let script = """
        #!/usr/bin/python3
        import json, sys
        request = json.loads(sys.stdin.readline())
        with open(\(String(reflecting: observed.path)), 'w') as output: output.write(request['provider'])
        print(json.dumps({'kind':'result','jobID':request['jobID'],'label':'Synthetic five word chat summary','model':'fixture'}), flush=True)
        """
        try script.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let library = ExplorerLibrary(directory: directory.appendingPathComponent("library"))
        let coordinator = LabelCoordinator(workerURL: worker, jobRoot: directory.appendingPathComponent("jobs"), admission: LabelAdmission())
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 600), persistTheme: false, loadOnDemand: false, library: library, labelCoordinator: coordinator)
        root.show(fixture(directory)); root.setPresentation(.date)
        XCTAssertEqual(root.labelRequestCount, 0)
        root.timeline.onSummarize?("new", .local)
        let deadline = Date().addingTimeInterval(10)
        while library.state.labels["new"] == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(root.labelRequestCount, 1)
        XCTAssertEqual(try String(contentsOf: observed, encoding: .utf8), "local")
        XCTAssertEqual(library.state.labels["new"]?.text, "Synthetic five word chat summary")
        XCTAssertEqual(root.timeline.presentation, .date)
        XCTAssertTrue(root.subviews.compactMap { $0 as? LabelPane }.allSatisfy(\.isHidden))
        XCTAssertFalse(try XCTUnwrap(root.timeline.enclosingScrollView).isHidden)
        XCTAssertEqual(try Data(contentsOf: history), original)
    }
}
