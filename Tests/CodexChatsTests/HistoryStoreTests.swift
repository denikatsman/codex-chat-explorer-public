import XCTest
import AppKit
import CSQLite
import ModelSupport
@testable import CodexChats

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var db: OpaquePointer?
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("history.sqlite")
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        try sql("CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT,PRIMARY KEY(thread_id,item_id))")
        try sql("CREATE UNIQUE INDEX items_page ON thread_items(thread_id,rollout_ordinal)")
    }
    override func tearDownWithError() throws { sqlite3_close(db); try FileManager.default.removeItem(at: directory) }
    private func sql(_ value: String) throws { guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) } }
    private func insert(chat: String = "a", ordinal: Int, text: String, raw: Data? = nil, user: Bool = true) throws {
        let data = try raw ?? JSONSerialization.data(withJSONObject: user ? ["type":"userMessage","content":[["type":"text","text":text]]] : ["type":"agentMessage","text":text])
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try sql("INSERT INTO thread_items VALUES('\(chat)','turn','item-\(ordinal)',\(ordinal),\(ordinal * 1000),'\(user ? "userMessage" : "agentMessage")',CAST(X'\(hex)' AS TEXT))")
    }
    private func chat(_ id: String) -> Chat { Chat(original: ["archived":.integer(0)], id: id, title: "Fixture \(id)", createdAt: nil, archived: false, issues: [], project: ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil)) }
    func testPagingIdentityDuplicatesMalformedValuesAndReadOnlyBytes() throws {
        for index in 1...6 { try insert(ordinal: index, text: "Same retained text", user: index.isMultiple(of: 2)) }
        try insert(chat: "b", ordinal: 1, text: "Same retained text")
        try insert(ordinal: 7, text: "", raw: Data([0xff,0xfe]))
        try sql("UPDATE thread_items SET created_at_ms='unknown' WHERE item_id='item-7'")
        let before = try Data(contentsOf: source)
        let first = try HistoryStore.page(chatID: "a", source: source, limit: 3)
        XCTAssertEqual(first.messages.map(\.ordinal), [1,2,3]); XCTAssertFalse(first.hasEarlier); XCTAssertTrue(first.hasMore)
        let next = try HistoryStore.page(chatID: "a", source: source, after: 3, limit: 3)
        XCTAssertEqual(next.messages.map(\.ordinal), [4,5,6]); XCTAssertTrue(next.hasEarlier); XCTAssertTrue(next.hasMore)
        let previous = try HistoryStore.page(chatID: "a", source: source, before: 4, limit: 3)
        XCTAssertEqual(previous.messages.map(\.ordinal), [1,2,3]); XCTAssertFalse(previous.hasEarlier); XCTAssertTrue(previous.hasMore)
        let last = try HistoryStore.page(chatID: "a", source: source, before: Int64.max, limit: 3)
        XCTAssertEqual(last.messages.map(\.ordinal), [5,6,7]); XCTAssertTrue(last.hasEarlier); XCTAssertFalse(last.hasMore)
        XCTAssertEqual(Set(first.messages.map(\.reference)).count, 3)
        XCTAssertNotEqual(first.messages.first?.reference, try HistoryStore.page(chatID: "b", source: source).messages.first?.reference)
        let bad = try XCTUnwrap(last.messages.last)
        XCTAssertNil(bad.createdAt); XCTAssertNotNil(bad.issue)
        XCTAssertEqual(bad.rawPayload, .text(Data([0xff,0xfe])))
        XCTAssertEqual(bad.originalMetadata["created_at_ms"], .text(Data("unknown".utf8)))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testSearchIsResumableAndPreservesCrossChatMatches() throws {
        for index in 1...130 { try insert(ordinal: index, text: "Buried cache exploration \(index)") }
        try insert(chat: "b", ordinal: 1, text: "Buried cache exploration")
        let before = try Data(contentsOf: source)
        let first = try HistoryStore.search(query: "CACHE", chats: [chat("b"),chat("a")], source: source, budget: 5)
        XCTAssertEqual(first.messages.count, 100); XCTAssertFalse(first.complete)
        let second = try HistoryStore.search(query: "CACHE", chats: [chat("a"),chat("b")], source: source, cursor: first.cursor, budget: 5)
        XCTAssertTrue(second.complete); XCTAssertEqual(second.messages.count, 31)
        XCTAssertEqual(Set((first.messages + second.messages).map(\.reference)).count, 131)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let token = HistoryCancellation(); token.cancel()
        XCTAssertThrowsError(try HistoryStore.page(chatID: "a", source: source, cancellation: token))
        XCTAssertThrowsError(try HistoryStore.search(query: "cache", chats: [chat("a")], source: source, cancellation: token))
    }
    func testLargePayloadDeferralFullReadAndExactStreamingExport() throws {
        let content = String(repeating: "Exact source bytes\n", count: 70_000)
        let payload = try JSONSerialization.data(withJSONObject: ["type":"agentMessage","text":content])
        try insert(ordinal: 1, text: "", raw: payload, user: false)
        let before = try Data(contentsOf: source)
        let preview = try XCTUnwrap(HistoryStore.page(chatID: "a", source: source).messages.first)
        XCTAssertNil(preview.rawPayload); XCTAssertEqual(preview.payloadBytes, payload.count)
        let full = try HistoryStore.full(chatID: "a", ordinal: 1, source: source)
        XCTAssertEqual(full.rawPayload, .text(payload)); XCTAssertEqual(full.text, content)
        let destination = directory.appendingPathComponent("export.json")
        try HistoryStore.export(chatID: "a", ordinal: 1, source: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertThrowsError(try HistoryStore.export(chatID: "a", ordinal: 1, source: source, to: source))
    }
    func testCapturedExportRemainsExactAfterTheSourceChanges() throws {
        try insert(ordinal: 1, text: "Original recorded reply")
        let captured = try XCTUnwrap(HistoryStore.page(chatID: "a", source: source).messages.first)
        try sql("UPDATE thread_items SET item_json='{\"type\":\"agentMessage\",\"text\":\"Later version\"}' WHERE thread_id='a'")
        let destination = directory.appendingPathComponent("captured.json")
        try HistoryStore.exportCaptured(captured, to: destination)
        guard case .text(let bytes)? = captured.rawPayload else { return XCTFail("Missing captured bytes") }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertNotNil(captured.payloadDigest)
        XCTAssertNotEqual(try HistoryStore.full(chatID: "a", ordinal: 1, source: source).payloadDigest, captured.payloadDigest)
    }

    func testChatReadingAccessibilityActionsAreEnabledAndDoNotRetainTheirView() {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: "/fixture/state_5.sqlite")
        let snapshot = ChatSnapshot(chats: [chat("a")], sourceURL: source, observedAt: Date(), excludedSubagents: 0, projectSourceURL: source, projectSourceIssue: nil)
        weak var released: TimelineView?
        autoreleasepool {
            let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistExpansion: false)
            view.setPresentation(.date); view.setSnapshot(snapshot)
            let buttons = view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == .button } ?? []
            XCTAssertFalse(buttons.isEmpty)
            let connections = buttons.filter { $0.accessibilityLabel()?.contains("project connections") == true }
            let readingAndFiltering = buttons.filter { $0.accessibilityLabel()?.contains("project connections") != true }
            XCTAssertEqual(connections.count, 1)
            XCTAssertTrue(connections.allSatisfy { !$0.isAccessibilityEnabled() }) // No project has no recorded membership to connect.
            XCTAssertFalse(readingAndFiltering.isEmpty)
            XCTAssertTrue(readingAndFiltering.allSatisfy { $0.isAccessibilityEnabled() })
            released = view
        }
        XCTAssertNil(released)
    }

    func testLabelSamplingIsBoundedAndSkipsInjectedContextWithoutChangingSources() throws {
        try insert(ordinal: 1, text: "# AGENTS.md instructions\nGLOBAL_CONTEXT_SHOULD_NOT_LABEL_THE_CHAT")
        for index in 2...17 { try insert(ordinal: index, text: "Explore native chat history topic \(index). " + String(repeating: "Details of the exploration. ", count: 100)) }
        try insert(ordinal: 18, text: "# Files mentioned\n\n## My request:\nReview day feed browsing and preserve original source names.")
        try insert(ordinal: 19, text: "Implemented paged history browsing and source-aware extraction", user: false)
        let indexed = directory.appendingPathComponent("thread_history_1.sqlite")
        try FileManager.default.linkItem(at: source, to: indexed)
        let before = try Data(contentsOf: source)
        let snapshot = ChatSnapshot(chats: [chat("a")], sourceURL: directory.appendingPathComponent("state_5.sqlite"), observedAt: Date(), excludedSubagents: 0, projectSourceURL: directory, projectSourceIssue: nil)
        let sample = try LabelSampler.prepare(chat: chat("a"), snapshot: snapshot, cancellation: HistoryCancellation())
        XCTAssertLessThanOrEqual(sample.prompt.utf8.count, LabelPolicy.maximumInputBytes)
        XCTAssertEqual(sample.totalMessages,19)
        XCTAssertEqual(Set(sample.references).count,sample.sampledMessages)
        XCTAssertEqual(sample.hashes.count,sample.sampledMessages)
        XCTAssertFalse(sample.prompt.contains("GLOBAL_CONTEXT_SHOULD_NOT_LABEL_THE_CHAT"))
        XCTAssertTrue(sample.prompt.contains("preserve original source names"))
        XCTAssertEqual(try Data(contentsOf: source),before)
    }

    func testManualLabelResultIsSavedSeparatelyAfterTheWorkerSettles() throws {
        _ = NSApplication.shared
        try insert(ordinal: 1, text: "Explore a native conversation browser")
        try FileManager.default.linkItem(at: source, to: directory.appendingPathComponent("thread_history_1.sqlite"))
        let original = try Data(contentsOf: source)
        let fake = directory.appendingPathComponent("fake-label-worker.swift")
        let script = #"""
        #!/usr/bin/swift
        import Foundation
        guard let line=readLine(),let data=line.data(using:.utf8),let request=try JSONSerialization.jsonObject(with:data) as? [String:Any],let id=request["jobID"] as? String else{exit(2)}
        let event:[String:Any]=["kind":"result","jobID":id,"label":"Offline source-aware browser summary label","model":"offline-fixture","effort":"low"]
        let bytes=try JSONSerialization.data(withJSONObject:event)
        print(String(data:bytes,encoding:.utf8)!);fflush(stdout)
        Thread.sleep(forTimeInterval:0.1)
        """#
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: fake.path)
        let coordinator = LabelCoordinator(workerURL: fake, jobRoot: directory.appendingPathComponent("jobs"))
        let library = ExplorerLibrary(directory: directory.appendingPathComponent("owned-library"))
        let metadata = ChatSnapshot(chats: [chat("a")], sourceURL: directory.appendingPathComponent("state_5.sqlite"), observedAt: Date(), excludedSubagents: 0, projectSourceURL: directory, projectSourceIssue: nil)
        let root = ChatRootView(frame: NSRect(x:0,y:0,width:940,height:650), persistTheme:false, loadOnDemand:false, library:library, labelCoordinator:coordinator)
        root.show(metadata); root.openChat("a")
        let reader = try XCTUnwrap(root.subviews.compactMap { $0 as? HistoryPane }.first)
        func until(_ description: String, _ predicate: @escaping () -> Bool) {
            let done = expectation(description: description)
            var timer: Timer?
            timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in if predicate() { timer?.invalidate(); timer = nil; done.fulfill() } }
            wait(for:[done],timeout:15); timer?.invalidate(); timer = nil
        }
        until("Reader loaded") { reader.labelButton.isEnabled }
        XCTAssertEqual(root.labelRequestCount,0)
        reader.labelButton.performClick(nil)
        let pane = try XCTUnwrap(root.subviews.compactMap { $0 as? LabelPane }.first)
        let provider = try XCTUnwrap(pane.subviews.compactMap { $0 as? FlatActionButton }.first { $0.title == "CODEX · LUNA" })
        until("Samples prepared without inference") { provider.isEnabled }
        XCTAssertEqual(root.labelRequestCount,0)
        provider.performClick(nil)
        until("Result saved after worker exit") { !root.hasLabelWork && library.state.labels["a"] != nil }
        XCTAssertEqual(root.labelRequestCount,1)
        let label = try XCTUnwrap(library.state.labels["a"])
        XCTAssertEqual(label.text,"Offline source-aware browser summary label")
        XCTAssertEqual(label.sourceReferences,["a/item-1@1"])
        XCTAssertEqual(label.sourceHashes?.count,1)
        XCTAssertEqual(metadata.chats[0].title,"Fixture a")
        XCTAssertEqual(try Data(contentsOf: source),original)
    }

    func testLibraryPersistsOnlyAppOwnedDataAndPreservesCorruptFiles() throws {
        let folder = directory.appendingPathComponent("saved")
        let library = ExplorerLibrary(directory: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try library.toggleFavorite("a")
        let excerpt = SavedExcerpt(id: UUID(), chatID: "a", chatTitle: "Original title", messageReferences: ["a/item-1@1"], ordinal: 1, sourcePath: source.path, text: "Selected displayed text", savedAt: Date())
        try library.save(excerpt)
        let reopened = ExplorerLibrary(directory: folder)
        XCTAssertTrue(reopened.state.favoriteChatIDs.contains("a")); XCTAssertEqual(reopened.state.excerpts.first?.text, excerpt.text)
        let file = folder.appendingPathComponent("library-v1.json")
        let broken = Data("{unfinished original".utf8); try broken.write(to: file)
        let damaged = ExplorerLibrary(directory: folder)
        XCTAssertNotNil(damaged.issue); XCTAssertThrowsError(try damaged.toggleFavorite("b"))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
}
