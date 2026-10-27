import Foundation
import CSQLite

struct LaneEvent {
    enum Kind { case creation, userMessage }
    let key: String
    let chatIndex: Int
    let kind: Kind
    let date: Date?
    let preview: String
    let originalMessage: SQLiteValue?
    let originalTimestamp: SQLiteValue?
}

struct LaneSnapshot {
    let chats: [Chat]
    let events: [LaneEvent]
    let issues: Int
    var messageCount: Int { events.filter { $0.kind == .userMessage }.count }
}

enum LaneStore {
    static func load(home: URL = ChatStore.defaultURL.deletingLastPathComponent(), chatLimit: Int = 5, metadata supplied: ChatSnapshot? = nil, cancellation: HistoryCancellation = HistoryCancellation()) throws -> LaneSnapshot {
        let budget = SourceReadBudget(cancellation: cancellation)
        try budget.check()
        let metadata = try supplied ?? ChatStore.load(from: home.appendingPathComponent("state_5.sqlite"))
        let source = home.appendingPathComponent("thread_history_1.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else { throw StoreError(message: "Recorded message index is unavailable.") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw StoreError(message: "Cannot open recorded messages read-only.")
        }
        defer { sqlite3_close(db) }
        budget.install(on: db)
        defer { budget.remove(from: db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw StoreError(message: "Source connection is not read-only.") }
        sqlite3_busy_timeout(db, 1500)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        // Select by recorded user-message recency before reading any message bodies.
        var recency = [String: Double]()
        for start in stride(from: 0, to: metadata.chats.count, by: 400) {
            try budget.check()
            let batch = Array(metadata.chats[start..<min(start + 400, metadata.chats.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let sql = "SELECT thread_id,max(created_at_ms) FROM thread_items WHERE item_type='userMessage' AND thread_id IN (\(placeholders)) GROUP BY thread_id"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(statement) }
            for (index, chat) in batch.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), chat.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
                if let id = cell(statement, 0).string { recency[id] = cell(statement, 1).number ?? -.infinity }
            }
        }
        let chosen = metadata.chats.filter { recency[$0.id] != nil }.sorted {
            if recency[$0.id] != recency[$1.id] { return (recency[$0.id] ?? -.infinity) > (recency[$1.id] ?? -.infinity) }
            return $0.id < $1.id
        }.prefix(max(0, chatLimit))
        let chats = chosen.sorted {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
            return $0.id < $1.id
        }
        let positions = Dictionary(uniqueKeysWithValues: chats.enumerated().map { ($0.element.id, $0.offset) })
        var events = chats.enumerated().map { index, chat in
            LaneEvent(key: "creation:\(chat.id)", chatIndex: index, kind: .creation, date: chat.createdAt,
                      preview: chat.title, originalMessage: nil,
                      originalTimestamp: chat.original["created_at_ms"] ?? chat.original["created_at"])
        }
        var issues = 0
        var retainedBytes = 0
        // All selected user-message identities are kept. Oversized bodies are
        // deferred to the paged reader rather than retained by this overview.
        for start in stride(from: 0, to: chats.count, by: 400) {
            let batch = Array(chats[start..<min(start + 400, chats.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let sql = "SELECT thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,CASE WHEN length(CAST(item_json AS BLOB))>1048576 THEN NULL ELSE item_json END,length(CAST(item_json AS BLOB)) FROM thread_items WHERE item_type='userMessage' AND thread_id IN (\(placeholders)) ORDER BY thread_id,rollout_ordinal"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw StoreError(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            for (index, chat) in batch.enumerated() {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, Int32(index + 1), chat.id, -1, transient)
            }
            while true {
                try budget.check()
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
                let parent = cell(statement, 0).string ?? ""
                guard let chatIndex = positions[parent] else { throw StoreError(message: "A message has an unresolved recorded chat identity.") }
                let turn = cell(statement, 1).string ?? ""
                let item = cell(statement, 2).string ?? ""
                let stamp = cell(statement, 4)
                let payload = cell(statement, 5)
                let size = Int(sqlite3_column_int64(statement, 6))
                let deferred = size > 1_048_576
                retainedBytes += deferred ? 0 : size
                guard retainedBytes <= 64 * 1024 * 1024, events.count < 100_000 else { throw StoreError(message: "LANES exceeds its overview memory budget. Use the paged chat reader to inspect this history.") }
                let date = stamp.number.flatMap { value -> Date? in
                    guard value.isFinite, (-62_135_596_800_000...253_402_300_799_000).contains(value) else { return nil }
                    return Date(timeIntervalSince1970: value / 1000)
                }
                var preview = "Recorded message text unavailable"
                if case .text(let bytes) = payload,
                   let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   let content = object["content"] as? [[String: Any]] {
                    let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                    // Explicit scheduler envelopes are user-role input, not a message written by the user.
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("<heartbeat>"), trimmed.contains("<automation_id>") { continue }
                    preview = text.isEmpty ? "Message with non-text content" : String(text.prefix(400))
                } else { issues += 1; if deferred { preview = "Large message (\(size) bytes); open chat to read it." } }
                if date == nil { issues += 1 }
                events.append(LaneEvent(key: "message:\(parent):\(turn):\(item)", chatIndex: chatIndex, kind: .userMessage,
                                        date: date, preview: preview, originalMessage: deferred ? nil : payload, originalTimestamp: stamp))
            }
        }
        try budget.check()
        events.sort {
            if $0.date != $1.date { return ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            if $0.chatIndex != $1.chatIndex { return $0.chatIndex < $1.chatIndex }
            if $0.kind != $1.kind { return $0.kind == .creation }
            return $0.key < $1.key
        }
        return LaneSnapshot(chats: chats, events: events, issues: issues)
    }

    private static func cell(_ statement: OpaquePointer, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            return .text(sqlite3_column_text(statement, column).map { Data(bytes: $0, count: count) } ?? Data())
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            return .blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data())
        default: return .null
        }
    }
}
