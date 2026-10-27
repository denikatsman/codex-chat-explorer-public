import XCTest
import AppKit
import CSQLite
@testable import CodexChats

final class LastReplyTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("last-reply-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("thread_history_1.sqlite")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ statements: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE IF NOT EXISTS thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,started_at INTEGER,completed_at INTEGER,final_agent_item_id TEXT,PRIMARY KEY(thread_id,turn_id));
        CREATE INDEX IF NOT EXISTS turns_page ON thread_turns(thread_id,rollout_ordinal);
        \(statements)
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
    }

    func testLatestAttemptIdentitySourceBytesAndRefresh() throws {
        try fixture("""
        INSERT INTO thread_turns VALUES('a','old',1,'completed',100,150,'reply-old');
        INSERT INTO thread_turns VALUES('a','latest',3,'completed',200,240,'reply-latest');
        INSERT INTO thread_turns VALUES('a','running',8,'inProgress',300,NULL,'partial');
        INSERT INTO thread_turns VALUES('a','failed',7,'failed',280,290,'error');
        INSERT INTO thread_turns VALUES('a','interrupted',6,'interrupted',270,279,'partial');
        INSERT INTO thread_turns VALUES('a','no-reply',5,'completed',250,260,NULL);
        INSERT INTO thread_turns VALUES('b','latest',2,'completed',100,180,'reply-b');
        INSERT INTO thread_turns VALUES('unrequested','other',100,'completed',100,999,'other-reply');
        """)
        let before = try Data(contentsOf: source)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let snapshot = try LastReplyStore.load(chatIDs: ["a", "b", "a", "none"], from: source)
        XCTAssertEqual(snapshot.replies.count, 2)
        XCTAssertEqual(snapshot.replies["a"]?.original["turn_id"]?.string, "running")
        XCTAssertEqual(snapshot.replies["a"]?.original["completed_at"], .null)
        XCTAssertNil(snapshot.replies["a"]?.finishedAt)
        XCTAssertEqual(snapshot.replies["b"]?.original["final_agent_item_id"]?.string, "reply-b")
        XCTAssertNil(snapshot.replies["none"])
        XCTAssertNil(snapshot.replies["unrequested"])
        XCTAssertNil(snapshot.issue)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), names)
        try fixture("UPDATE thread_turns SET status='completed',completed_at=350,final_agent_item_id='reply-new' WHERE thread_id='a' AND turn_id='running';")
        let refreshed = try LastReplyStore.load(chatIDs: ["a"], from: source)
        XCTAssertEqual(refreshed.replies["a"]?.finishedAt, Date(timeIntervalSince1970: 350))
        XCTAssertNil(snapshot.replies["a"]?.finishedAt)
    }

    func testMalformedAndMissingFinishTimesAreRetainedWithoutFallback() throws {
        try fixture("""
        INSERT INTO thread_turns VALUES('a','old',1,'completed',100,150,'old');
        INSERT INTO thread_turns VALUES('a','bad',2,'completed',200,'broken','latest');
        INSERT INTO thread_turns VALUES('b','null',1,'completed',200,NULL,'reply');
        INSERT INTO thread_turns VALUES('c','reversed',1,'completed',200,150,'reply');
        """)
        let before = try Data(contentsOf: source)
        let snapshot = try LastReplyStore.load(chatIDs: ["a", "b", "c", "empty"], from: source)
        XCTAssertEqual(snapshot.replies["a"]?.original["completed_at"], .text(Data("broken".utf8)))
        XCTAssertEqual(snapshot.replies["a"]?.original["turn_id"]?.string, "bad")
        XCTAssertEqual(snapshot.replies["b"]?.original["completed_at"], .null)
        for id in ["a", "b", "c"] { XCTAssertNil(snapshot.replies[id]?.finishedAt) }
        XCTAssertNil(snapshot.replies["empty"])
        XCTAssertEqual(try Data(contentsOf: source), before)
        let missing = directory.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try LastReplyStore.load(chatIDs: ["a"], from: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try fixture("DROP INDEX turns_page;")
        XCTAssertThrowsError(try LastReplyStore.load(chatIDs: ["a"], from: source))
    }

    func testDateFormattingAndUnavailableStates() throws {
        _ = NSApplication.shared
        let calendar = Calendar.current
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 3, second: 2))!
        }
        let creation = date(2026, 10, 12, 13)
        let project = ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil)
        let chat = Chat(original: [:], id: "a", title: "Fixture", createdAt: creation, archived: false, issues: [], project: project)
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 940, height: 600), persistExpansion: false)
        func show(_ finish: Date?, issue: String? = nil, hasRecord: Bool = true) {
            let row: [String: SQLiteValue] = ["status": .text(Data("completed".utf8)), "completed_at": finish.map { .integer(Int64($0.timeIntervalSince1970)) } ?? .null]
            let last = LastReplySnapshot(sourceURL: source, replies: hasRecord ? ["a": LastReply(original: row)] : [:], issue: issue)
            view.setSnapshot(ChatSnapshot(chats: [chat], sourceURL: source, observedAt: Date(), excludedSubagents: 0, projectSourceURL: source, projectSourceIssue: nil, lastReplies: last))
        }
        show(date(2026, 10, 12, 14))
        XCTAssertEqual(view.lastTurnText(for: chat), "14:03:02")
        show(date(2026, 10, 21, 22))
        XCTAssertEqual(view.lastTurnText(for: chat), "21 Oct · 22:03:02")
        show(date(2027, 1, 1, 10))
        XCTAssertEqual(view.lastTurnText(for: chat), "1 Jan 2027 · 10:03:02")
        show(nil)
        XCTAssertEqual(view.lastTurnText(for: chat), "END UNKNOWN")
        show(nil, hasRecord: false)
        XCTAssertEqual(view.lastTurnText(for: chat), "—")
        show(nil, issue: "Fixture source unavailable")
        XCTAssertEqual(view.lastTurnText(for: chat), "UNAVAILABLE")
    }
}
