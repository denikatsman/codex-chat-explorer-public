import XCTest
import AppKit
import CSQLite
@testable import CodexChats

/// End-to-end FIND workflow, using native controls and isolated synthetic sources/models.
/// Views remain unattached to a window; production preview validates AppKit drawing separately.
final class SemanticFindFlowTests: XCTestCase {
    private final class Provider: SemanticEmbeddingProvider {
        let modelDigest = "native-find-fixture"
        private let lock = NSLock()
        private var callCount = 0, blocked = false
        var keepWarm = false
        var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
        func hold(_ value: Bool) { lock.lock(); blocked = value; lock.unlock() }
        func embed(_ texts: [String], cancellation: HistoryCancellation) throws -> [[Float]] {
            lock.lock(); callCount += 1; lock.unlock()
            let deadline = Date().addingTimeInterval(5)
            while true {
                guard !cancellation.cancelled else { throw SemanticFailure("Fixture cancelled") }
                lock.lock(); let wait = blocked; lock.unlock()
                if !wait { break }
                guard Date() < deadline else { throw SemanticFailure("Fixture bounded hold expired") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return texts.map { _ in [1] + [Float](repeating:0,count:4095) }
        }
        func rerank(query: String, passages: [String], cancellation: HistoryCancellation) throws -> [Double]? { nil }
        func stop() { hold(false) }
    }
    private var directory: URL!, defaults: UserDefaults!, suite: String!
    private var coordinator: SemanticCoordinator!, provider: Provider!, pane: SearchPane!
    private var snapshot: ChatSnapshot!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-find-fixture-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let state = directory.appendingPathComponent("state_5.sqlite")
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        try sql(state,"CREATE TABLE threads(id TEXT,title TEXT,created_at INTEGER,source TEXT,archived INTEGER); INSERT INTO threads VALUES('a','Offline cache investigation',1,'vscode',0),('b','Archived cache recovery',2,'vscode',1)")
        try sql(history,"CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT)")
        for (chat,ordinal,description) in [("a",11,"The cache is retained when indexing pauses."),("a",22,"Resume indexing to reuse saved embeddings."),("b",33,"Archived chats remain available in cache search.")] {
            let payload = try JSONSerialization.data(withJSONObject:["type":"agentMessage","text":"SOURCE_\(ordinal) · \(description)","phase":"final"])
            let hex = payload.map { String(format:"%02x",$0) }.joined()
            try sql(history,"INSERT INTO thread_items VALUES('\(chat)','turn-\(ordinal)','item-\(ordinal)',\(ordinal),1000,'agentMessage',CAST(X'\(hex)' AS TEXT))")
        }
        snapshot = try ChatStore.load(from:state,projectStateURL:directory.appendingPathComponent("no-projects.json"))
        suite = "native-find-test-\(UUID())"; defaults = UserDefaults(suiteName:suite)!
        provider = Provider(); let selected = provider!
        coordinator = SemanticCoordinator(databaseURL:directory.appendingPathComponent("owned/index.sqlite"),defaults:defaults,provider:{ selected })
        coordinator.setOptions(SemanticOptions(keepWarm:false,throttle:false,rerank:false))
        pane = SearchPane(library:ExplorerLibrary(directory:directory.appendingPathComponent("library")),coordinator:coordinator)
        pane.frame = NSRect(x:0,y:0,width:600,height:850)
        pane.setTheme(dark:false,green:false,scale:1)
        pane.show(snapshot:snapshot,mode:.messages); pane.layoutSubtreeIfNeeded()
    }
    override func tearDownWithError() throws {
        pane.hideSearch()
        let stopped = expectation(description:"Fixture model cleanup")
        coordinator.shutdown { stopped.fulfill() }; wait(for:[stopped],timeout:8)
        pane = nil; coordinator = nil
        defaults.removePersistentDomain(forName:suite)
        try FileManager.default.removeItem(at:directory)
    }
    private func sql(_ url: URL, _ statement: String) throws {
        var db: OpaquePointer?; guard sqlite3_open(url.path,&db) == SQLITE_OK else { throw SemanticFailure("Fixture database open failed") }; defer { sqlite3_close(db) }
        guard sqlite3_exec(db,statement,nil,nil,nil) == SQLITE_OK else { throw SemanticFailure(String(cString:sqlite3_errmsg(db))) }
    }
    private func children(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + children($0) } }
    private func control<T: NSView>(_ type: T.Type) throws -> T { try XCTUnwrap(children(pane).compactMap { $0 as? T }.first) }
    private func button(_ title: String) throws -> NSButton { try XCTUnwrap(children(pane).compactMap { $0 as? NSButton }.first { $0.title == title }) }
    private func until(_ description: String, _ condition: @escaping () -> Bool) throws {
        if condition() { return }
        let done = expectation(description:description)
        let timer = Timer.scheduledTimer(withTimeInterval:0.01,repeats:true) { timer in if condition() { timer.invalidate(); done.fulfill() } }
        wait(for:[done],timeout:8); timer.invalidate()
        guard condition() else {
            let status = (try? control(SemanticControlsView.self))?.status.stringValue ?? "No status control"
            throw SemanticFailure("\(description): \(status); model calls: \(provider.calls)")
        }
    }
    private func index() throws {
        let controls = try control(SemanticControlsView.self)
        controls.start.performClick(nil)
        try until("Native start finishes three passages") { controls.status.stringValue.contains("3/3 passages indexed") }
        controls.pause.performClick(nil)
        try until("Native pause active") { controls.start.isEnabled && !controls.pause.isEnabled }
    }
    private func query(_ text: String) throws {
        let field = try control(NSSearchField.self); field.stringValue = text
        XCTAssertTrue(field.sendAction(field.action,to:field.target))
    }
    func testNativeStartManualSearchGroupingExpansionAndExactSourceNavigation() throws {
        let field = try control(NSSearchField.self), table = try control(NSTableView.self)
        field.stringValue = "cache"; pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(provider.calls,0,"Typing and browsing must not invoke a model")
        try index(); let before = provider.calls
        try query("cache")
        try until("Combined search grouped into two chats") { table.numberOfRows == 2 }
        XCTAssertEqual(provider.calls,before + 1)
        var groupRow: Int?
        for row in 0..<table.numberOfRows {
            if let view = table.view(atColumn:0,row:row,makeIfNecessary:true), let disclosure = view.viewWithTag(3) as? NSButton, !disclosure.isHidden { groupRow = row; disclosure.performClick(nil); break }
        }
        XCTAssertNotNil(groupRow); XCTAssertEqual(table.numberOfRows,3)
        let expanded = (groupRow ?? 0) + 1
        let row = try XCTUnwrap(table.view(atColumn:0,row:expanded,makeIfNecessary:true))
        let preview = try XCTUnwrap(row.viewWithTag(4) as? NSTextField)
        let expectedOrdinal: Int64 = preview.stringValue.contains("SOURCE_11") ? 11 : 22
        XCTAssertTrue(preview.stringValue.contains("SOURCE_\(expectedOrdinal)"))
        var opened: (String,Int64?)?
        pane.onOpen = { id,ordinal,_ in opened = (id,ordinal) }
        table.selectRowIndexes(IndexSet(integer:expanded),byExtendingSelection:false)
        try button("OPEN").performClick(nil)
        XCTAssertEqual(opened?.0,"a"); XCTAssertEqual(opened?.1,expectedOrdinal)
        let controls = try control(SemanticControlsView.self)
        controls.mode.selectItem(at:2); XCTAssertTrue(controls.mode.sendAction(controls.mode.action,to:controls.mode.target))
        let calls = provider.calls
        try query("reuse")
        try until("Exact query shows source") { table.numberOfRows == 1 }
        XCTAssertEqual(provider.calls,calls,"Exact search must not call the embedding model")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try button("OPEN").performClick(nil)
        XCTAssertEqual(opened?.0,"a"); XCTAssertEqual(opened?.1,22)
        XCTAssertNil(pane.window)
    }
    func testNativeCancellationResumeAndFullPaneOffscreenLayout() throws {
        try index(); let controls = try control(SemanticControlsView.self), table = try control(NSTableView.self)
        provider.hold(true); let calls = provider.calls
        try query("blocked query")
        try until("Search model admitted") { self.provider.calls > calls }
        try button("CANCEL").performClick(nil); provider.hold(false)
        controls.start.performClick(nil); controls.cancel.performClick(nil)
        XCTAssertTrue(controls.start.isEnabled)
        XCTAssertTrue(controls.status.stringValue.contains("stopped"))
        controls.start.performClick(nil)
        try until("Index resumed from saved vectors") { controls.status.stringValue.contains("3/3 passages indexed") && controls.pause.isEnabled }
        controls.pause.performClick(nil)
        try query("cache")
        try until("Results available for rendered fixture") { table.numberOfRows == 2 }
        for width in [CGFloat(600),940] {
            for scale in [CGFloat(1),2] {
                pane.frame.size = NSSize(width:width,height:1000); pane.setTheme(dark:false,green:false,scale:scale)
                pane.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
                for view in pane.subviews where !view.isHidden {
                    XCTAssertGreaterThanOrEqual(view.frame.minX,0); XCTAssertLessThanOrEqual(view.frame.maxX,pane.bounds.width)
                    XCTAssertGreaterThanOrEqual(view.frame.minY,0); XCTAssertLessThanOrEqual(view.frame.maxY,pane.bounds.height)
                }
                let first = try XCTUnwrap(table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSTableCellView)
                let labels = [first.textField,first.viewWithTag(2) as? NSTextField,first.viewWithTag(4) as? NSTextField].compactMap { $0 }
                XCTAssertEqual(labels.count,3)
                for label in labels { XCTAssertFalse(label.stringValue.isEmpty); XCTAssertGreaterThan(label.frame.width,100); XCTAssertGreaterThan(label.frame.height,10) }
                for (index,a) in labels.enumerated() { for b in labels.dropFirst(index + 1) { XCTAssertFalse(a.frame.intersects(b.frame),"Source preview overlaps metadata at scale \(scale)") } }

            }
        }
        XCTAssertNil(pane.window)
    }
    func testNativeSemanticPowerSwitchCancelsSearchAndKeepsExactSourceResults() throws {
        try index()
        let controls = try control(SemanticControlsView.self), table = try control(NSTableView.self)
        provider.hold(true); let calls = provider.calls
        try query("blocked")
        try until("Active search model admitted") { self.provider.calls > calls }
        controls.power.performClick(nil)
        XCTAssertFalse(coordinator.semanticEnabled)
        XCTAssertEqual(controls.searchMode,.exact)
        try until("Owned model released") { controls.status.stringValue.contains("Models released") }
        let stoppedCalls = provider.calls
        try query("reuse")
        try until("Exact result available with semantic power off") { table.numberOfRows == 1 }
        XCTAssertEqual(provider.calls,stoppedCalls)
        XCTAssertTrue(controls.status.stringValue.hasPrefix("Semantic OFF · Indexing OFF"))
        controls.power.performClick(nil)
        XCTAssertTrue(coordinator.semanticEnabled)
        XCTAssertEqual(controls.searchMode,.combined)
        XCTAssertTrue(controls.status.stringValue.hasPrefix("Indexing STOPPED"))
    }
    func testFullFindNativeRenderingDoesNotCrashCoreText() throws {
        try index(); try query("cache")
        let table = try control(NSTableView.self)
        try until("Real result views ready to draw") { table.numberOfRows == 2 }
        let window = NSWindow(contentRect:pane.bounds,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = pane
        defer { window.contentView = nil; window.close() }
        for dark in [false,true] {
            pane.setTheme(dark:dark,green:false,scale:1)
            pane.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in:pane.bounds))
            pane.cacheDisplay(in:pane.bounds,to:bitmap)
            let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            XCTAssertGreaterThan(png.count,1000)
        }
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
    }

}
