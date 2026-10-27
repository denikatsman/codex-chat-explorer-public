import AppKit
import CSQLite

struct MessageMark {
    let original: [String: SQLiteValue]
    let time: Date
    let user: Bool
}

struct MessageLane {
    let chat: Chat
    let messages: [MessageMark]
}

struct MessageDay {
    let interval: DateInterval
    let lanes: [MessageLane]
    let source: URL
    let unreadableRows: [[String: SQLiteValue]]
    var unreadableRecords: Int { unreadableRows.count }
    var count: Int { lanes.reduce(0) { $0 + $1.messages.count } }
}

enum MessageTimelineStore {
    static func load(_ snapshot: ChatSnapshot, day: Date, calendar: Calendar = .current, cancellation: HistoryCancellation = HistoryCancellation()) throws -> MessageDay {
        let budget = SourceReadBudget(cancellation: cancellation)
        try budget.check()
        let interval = calendar.dateInterval(of: .day, for: day)!
        let source = snapshot.sourceURL.deletingLastPathComponent().appendingPathComponent("thread_history_1.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw StoreError(message: "Message index unavailable.")
        }
        defer { sqlite3_close(db) }
        budget.install(on: db)
        defer { budget.remove(from: db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw StoreError(message: "Message index is not read-only.") }
        sqlite3_busy_timeout(db, 1500)
        try ChatStore.execute(db, "PRAGMA query_only=ON")
        try ChatStore.execute(db, "BEGIN")
        defer { try? ChatStore.execute(db, "ROLLBACK") }
        let start = Int64(interval.start.timeIntervalSince1970)
        let end = Int64(interval.end.timeIntervalSince1970)
        let chats = Dictionary(snapshot.chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Turn metadata is small and indexed message reads use exact thread/turn identity.
        var turns = try ChatStore.rows(db, "SELECT thread_id,turn_id FROM thread_turns WHERE (started_at < \(end) AND (started_at >= \(start) OR completed_at >= \(start) OR status IN ('inProgress','running'))) OR started_at IS NULL OR typeof(started_at) NOT IN ('integer','real')", maxRows: 100_000)
        turns += try ChatStore.rows(db, "SELECT t.thread_id,t.turn_id FROM thread_turns t CROSS JOIN thread_items i ON i.thread_id=t.thread_id AND i.item_id=t.first_user_item_id WHERE t.started_at>=\(end) AND i.created_at_ms>=\(start * 1000) AND i.created_at_ms<\(end * 1000)", maxRows: 100_000 - turns.count)
        var marks = [String: [MessageMark]]()
        var unreadable = [[String: SQLiteValue]]()
        var count = 0
        var seen = Set<[String]>()
        for turn in turns {
            try budget.check()
            guard let thread = turn["thread_id"]?.string, chats[thread] != nil,
                  let turnID = turn["turn_id"]?.string, seen.insert([thread,turnID]).inserted else { continue }
            let rows = try ChatStore.rows(db, "SELECT thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_type FROM thread_items WHERE thread_id=? AND turn_id=? AND created_at_ms >= \(start * 1000) AND created_at_ms < \(end * 1000) AND item_type IN ('userMessage','agentMessage') ORDER BY rollout_ordinal", bindings: [thread, turnID], maxRows: 200_000 - count)
            count += rows.count
            for row in rows {
                guard case .integer(let ms)? = row["created_at_ms"], row["item_id"]?.string != nil,
                      let kind = row["item_type"]?.string else { unreadable.append(row); continue }
                marks[thread, default: []].append(MessageMark(original: row, time: Date(timeIntervalSince1970: Double(ms) / 1000), user: kind == "userMessage"))
            }
        }
        try budget.check()
        let lanes = snapshot.chats.compactMap { chat -> MessageLane? in
            let messages = (marks[chat.id] ?? []).sorted { $0.time < $1.time }
            let createdToday = chat.createdAt.map { $0 >= interval.start && $0 < interval.end } ?? false
            return messages.isEmpty && !createdToday ? nil : MessageLane(chat: chat, messages: messages)
        }.sorted {
            ($0.messages.last?.time ?? $0.chat.createdAt ?? .distantPast) > ($1.messages.last?.time ?? $1.chat.createdAt ?? .distantPast)
        }
        return MessageDay(interval: interval, lanes: lanes, source: source, unreadableRows: unreadable)
    }
}
