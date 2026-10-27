import XCTest
import CSQLite
@testable import CodexChats

final class DayFeedTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var db: OpaquePointer?
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Zurich")!; return value }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("day-feed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("history.sqlite")
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        try sql("CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT)")
        try sql("CREATE UNIQUE INDEX messages_page ON thread_items(thread_id,rollout_ordinal)")
        try sql("CREATE INDEX messages_turn ON thread_items(thread_id,turn_id,rollout_ordinal)")
        try sql("CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,started_at INTEGER,completed_at INTEGER,status TEXT,first_user_item_id TEXT,PRIMARY KEY(thread_id,turn_id))")
    }
    override func tearDownWithError() throws { sqlite3_close(db); try FileManager.default.removeItem(at: directory) }
    private func sql(_ value: String) throws { guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) } }
    private func insert(_ chat: String, _ ordinal: Int, _ date: Date, user: Bool = true) throws {
        let value = user ? "{\"content\":[{\"type\":\"text\",\"text\":\"Exploration \(ordinal)\"}]}" : "{\"text\":\"Reply \(ordinal)\"}"
        try sql("INSERT INTO thread_items VALUES('\(chat)','t','m-\(ordinal)',\(ordinal),\(Int64(date.timeIntervalSince1970 * 1000)),'\(user ? "userMessage" : "agentMessage")','\(value)')")
        let seconds = Int64(date.timeIntervalSince1970)
        try sql("INSERT INTO thread_turns VALUES('\(chat)','t',\(seconds),\(seconds),'completed','m-\(ordinal)') ON CONFLICT(thread_id,turn_id) DO UPDATE SET started_at=min(started_at,excluded.started_at),completed_at=max(completed_at,excluded.completed_at)")
    }
    private func chat(_ id: String) -> Chat { Chat(original: [:], id: id, title: id, createdAt: nil, archived: false, issues: [], project: ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil)) }
    func testDayInterleavesChatsRolesAndContinuesWithoutDuplicates() throws {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22))!
        try insert("a",1,day.addingTimeInterval(10)); try insert("b",1,day.addingTimeInterval(20),user:false)
        try insert("a",2,day.addingTimeInterval(30)); try insert("hidden-subagent",1,day.addingTimeInterval(15))
        try insert("b",2,day.addingTimeInterval(-1))
        let before = try Data(contentsOf: source)
        let first = try DayFeedStore.load(chats: [chat("a"),chat("b")], source: source, day: day, limit: 2, calendar: calendar)
        XCTAssertEqual(first.messages.map(\.chatID), ["a","b"]); XCTAssertNotNil(first.cursor)
        let next = try DayFeedStore.load(chats: [chat("b"),chat("a")], source: source, day: day, after: first.cursor, limit: 2, calendar: calendar)
        XCTAssertEqual(next.messages.map(\.ordinal), [2]); XCTAssertNil(next.cursor)
        XCTAssertEqual(Set((first.messages+next.messages).map(\.reference)).count,3)
        let inputs = try DayFeedStore.load(chats: [chat("a"),chat("b")], source: source, day: day, role: .inputs, calendar: calendar)
        XCTAssertEqual(inputs.messages.map(\.role),["USER","USER"])
        let replies = try DayFeedStore.load(chats: [chat("a"),chat("b")], source: source, day: day, role: .replies, calendar: calendar)
        XCTAssertEqual(replies.messages.map(\.role),["ASSISTANT"])
        XCTAssertEqual(try Data(contentsOf: source),before)
    }
    func testQueuedInputAtMidnightUsesItsRecordedMessageTimestamp() throws {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))!
        let end = calendar.dateInterval(of: .day, for: day)!.end
        try insert("a",1,end.addingTimeInterval(-10))
        try sql("UPDATE thread_turns SET started_at=\(Int64(end.timeIntervalSince1970)+60),completed_at=\(Int64(end.timeIntervalSince1970)+120)")
        let result = try DayFeedStore.load(chats:[chat("a")],source:source,day:day,calendar:calendar)
        XCTAssertEqual(result.messages.map(\.ordinal),[1])
        let chartSource = directory.appendingPathComponent("thread_history_1.sqlite")
        try FileManager.default.copyItem(at: source, to: chartSource)
        let metadata = ChatSnapshot(chats:[chat("a")],sourceURL:directory.appendingPathComponent("state_5.sqlite"),observedAt:Date(),excludedSubagents:0,projectSourceURL:directory,projectSourceIssue:nil)
        let chart = try MessageTimelineStore.load(metadata,day:day,calendar:calendar)
        XCTAssertEqual(chart.count,1)
        XCTAssertEqual(chart.lanes[0].messages[0].original["rollout_ordinal"],.integer(1))
    }

    func testDSTDaysUseCalendarBoundariesRatherThanTwentyFourHours() throws {
        for (month,day,hours) in [(3,29,23),(10,25,25)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
            let interval = calendar.dateInterval(of: .day,for:date)!
            XCTAssertEqual(interval.duration,Double(hours*3600))
            let id = "day-\(month)"
            try insert(id,1,interval.start); try insert(id,2,interval.end.addingTimeInterval(-1)); try insert(id,3,interval.end)
            let result = try DayFeedStore.load(chats:[chat(id)],source:source,day:date,calendar:calendar)
            XCTAssertEqual(result.messages.map(\.ordinal),[1,2])
        }
    }
}
