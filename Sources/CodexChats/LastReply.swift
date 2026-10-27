import Foundation
import CSQLite

struct TurnHistoryBoundary: Hashable {
    let threadID: String
    let ordinal: Int64
    let byteOffset: Int64
}

// Legacy type name; the record now represents the latest attempt.
struct LastReply {
    let original: [String: SQLiteValue]
    var endingVisible = true
    var inheritedThrough = [TurnHistoryBoundary]()
    var turnID: String? { original["turn_id"]?.string }
    var status: String? { endingVisible ? original["status"]?.string : nil }
    var isTerminal: Bool { ["completed", "failed", "interrupted"].contains(status ?? "") }
    var outcome: String {
        switch status {
        case "failed": return "FAILED"
        case "interrupted": return "INTERRUPTED"
        default: return ""
        }
    }
    var finishedAt: Date? {
        guard endingVisible, isTerminal,
              let seconds = original["completed_at"]?.number, seconds.isFinite,
              (-62_135_596_800...253_402_300_799).contains(seconds) else { return nil }
        if let start = original["started_at"]?.number, seconds < start { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

struct LastReplySnapshot {
    let sourceURL: URL
    let replies: [String: LastReply]
    let issue: String?
    var issues = [String: String]()
    func explanation(for chatID: String) -> String {
        let source = "Source: \(sourceURL.path)"
        if let issue = issue ?? issues[chatID] { return "Last turn unavailable: \(issue)\n\(source)" }
        guard let reply = replies[chatID] else { return "No turn recorded for this chat.\n\(source)" }
        let time = reply.finishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "End unknown; no valid ending is recorded within this history."
        let inherited = reply.inheritedThrough.map { "Inherited history: \($0.threadID), before ordinal \($0.ordinal), through byte \($0.byteOffset)." }.joined(separator: "\n")
        return "Last turn ended: \(time)\nOutcome: \(reply.status ?? "unknown")\nTurn ID: \(reply.turnID ?? "")\nRecorded under chat: \(reply.original["thread_id"]?.string ?? chatID)\n\(inherited)\n\(source)"
    }
}

struct TurnHeader {
    var base: TurnHistoryBoundary?
    var issue: String?
    var endByteOffset: Int64 = 0
}

// Bounded cache of small pointers, never transcript bodies.
final class TurnHeaderCache {
    private struct Entry { let signature: String; let header: TurnHeader }
    private var entries = [String: Entry]()
    private let lock = NSLock()
    func read(_ url: URL, id: String, budget: SourceReadBudget) throws -> TurnHeader {
        try budget.check()
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let signature = "\(a[.systemFileNumber] ?? "")|\(a[.size] ?? "")|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let key = url.path + "|" + id
        lock.lock(); let cached = entries[key]; lock.unlock()
        if let cached, cached.signature == signature { return cached.header }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data(), complete = false
        while bytes.count < 1_048_576 {
            try budget.check()
            guard let chunk = try file.read(upToCount: min(4096, 1_048_576 - bytes.count)), !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 10) {
                bytes.append(contentsOf: chunk[..<newline]); complete = true; break
            }
            bytes.append(chunk)
        }
        var header = TurnHeader()
        header.endByteOffset = Int64(bytes.count + 1)
        if !complete { header.issue = "Session header is partial or exceeds the bounded read." }
        else if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                object["type"] as? String == "session_meta",
                let payload = object["payload"] as? [String: Any], payload["id"] as? String == id {
            if let value = payload["history_base"], !(value is NSNull) {
                if let base = value as? [String: Any], let parent = base["thread_id"] as? String, !parent.isEmpty,
                   let ordinal = Self.integer(base["end_ordinal_exclusive"]), let offset = Self.integer(base["end_byte_offset"]) {
                    header.base = TurnHistoryBoundary(threadID: parent, ordinal: ordinal, byteOffset: offset)
                } else { header.issue = "Inherited history has a malformed boundary." }
            } else if let parent = payload["forked_from_id"] as? String, !parent.isEmpty {
                header.issue = "A fork is recorded without a usable inherited-history boundary."
            }
        } else { header.issue = "Session header identity or format is unavailable." }
        lock.lock()
        if entries.count >= 4096, let old = entries.keys.first { entries.removeValue(forKey: old) }
        entries[key] = Entry(signature: signature, header: header)
        lock.unlock()
        return header
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c",
              let integer = Int64(n.stringValue), integer >= 0 else { return nil }
        return integer
    }
}

enum LastReplyStore {
    private static let headers = TurnHeaderCache()
    private struct Key: Hashable { let id: String; let ordinal: Int64; let byteOffset: Int64 }
    private enum Resolution { case turn(LastReply), empty, unavailable(String) }

    static func rolloutPaths(for chats: [Chat]) -> [String: URL] {
        Dictionary(chats.compactMap { chat in
            chat.original["rollout_path"]?.string.map { (chat.id, URL(fileURLWithPath: $0)) }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func load(chatIDs: [String], from source: URL, rolloutPaths: [String: URL] = [:]) throws -> LastReplySnapshot {
        guard FileManager.default.fileExists(atPath: source.path) else { throw StoreError(message: "Recorded turn index is missing.") }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open recorded turns."
            if let handle { sqlite3_close(handle) }
            throw StoreError(message: reason)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw StoreError(message: "Turn index is not read-only.") }
        sqlite3_busy_timeout(db, 1500)
        try ChatStore.execute(db, "PRAGMA query_only=ON")
        try ChatStore.execute(db, "BEGIN")
        defer { try? ChatStore.execute(db, "ROLLBACK") }
        let budget = SourceReadBudget(cancellation: HistoryCancellation())
        budget.install(on: db); defer { budget.remove(from: db) }
        let required: Set<String> = ["thread_id", "turn_id", "rollout_ordinal", "status", "started_at", "completed_at", "final_agent_item_id"]
        let columns = Set(try ChatStore.rows(db, "PRAGMA table_info(thread_turns)").compactMap { $0["name"]?.string })
        guard required.isSubset(of: columns) else { throw StoreError(message: "Recorded turn index has an unsupported schema.") }
        var indexed = false
        for index in try ChatStore.rows(db, "PRAGMA index_list(thread_turns)") where index["partial"]?.number == 0 {
            guard let name = index["name"]?.string else { continue }
            let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
            let keys = try ChatStore.rows(db, "PRAGMA index_info(\"\(quoted)\")").compactMap { $0["name"]?.string }
            if Array(keys.prefix(2)) == ["thread_id", "rollout_ordinal"] { indexed = true; break }
        }
        guard indexed else { throw StoreError(message: "An efficient recorded-turn lookup index is unavailable.") }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
            return pointer
        }
        let own = try prepare("SELECT * FROM thread_turns WHERE thread_id=? ORDER BY rollout_ordinal DESC,turn_id DESC LIMIT 1")
        defer { sqlite3_finalize(own) }
        let inheritedStatement = try prepare("SELECT * FROM thread_turns WHERE thread_id=? AND rollout_ordinal<? ORDER BY rollout_ordinal DESC,turn_id DESC LIMIT 1")
        defer { sqlite3_finalize(inheritedStatement) }
        var cache = [Key: Resolution]()

        func resolve(_ id: String, boundary: TurnHistoryBoundary? = nil, ancestors: Set<String> = []) throws -> Resolution {
            try budget.check()
            if boundary?.ordinal == 0 || boundary?.byteOffset == 0 { return .empty }
            guard ancestors.count < 64, !ancestors.contains(id) else { return .unavailable("Inherited history is cyclic or exceeds the ancestry limit.") }
            let key = Key(id: id, ordinal: boundary?.ordinal ?? Int64.max, byteOffset: boundary?.byteOffset ?? Int64.max)
            if let cached = cache[key] { return cached }
            let statement = boundary == nil ? own : inheritedStatement
            guard sqlite3_reset(statement) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
            let bound = id.withCString { sqlite3_bind_text(statement, 1, $0, Int32(id.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard bound == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
            if boundary != nil, sqlite3_bind_int64(statement, 2, key.ordinal) != SQLITE_OK { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
            let result: Resolution
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let row = ChatStore.row(statement)
                var turn = LastReply(original: row)
                if case .integer(let start)? = row["rollout_ordinal"], start >= 0 {} else { turn.endingVisible = false }
                if let boundary {
                    // A mutable projected row may contain an ending AFTER the fork.
                    if case .integer(let start)? = row["rollout_ordinal"],
                       case .integer(let startOffset)? = row["rollout_byte_offset"],
                       case .integer(let end)? = row["rollout_end_ordinal"],
                       case .integer(let offset)? = row["rollout_end_byte_offset"] {
                        turn.endingVisible = start >= 0 && startOffset >= 0 && end >= start && end < boundary.ordinal
                            && offset >= startOffset && offset <= boundary.byteOffset
                    } else { turn.endingVisible = false }
                }
                result = .turn(turn)
            case SQLITE_DONE:
                if let path = rolloutPaths[id] {
                    do {
                        let header = try headers.read(path, id: id, budget: budget)
                        if let issue = header.issue { result = .unavailable(issue) }
                        else if let boundary, boundary.byteOffset < header.endByteOffset { result = .unavailable("Inherited history ends inside an incomplete session header.") }
                        else if let base = header.base {
                            let inherited = try resolve(base.threadID, boundary: base, ancestors: ancestors.union([id]))
                            if case .turn(var turn) = inherited { turn.inheritedThrough.insert(base, at: 0); result = .turn(turn) }
                            else { result = inherited }
                        } else { result = .empty }
                    } catch { result = .unavailable(error.localizedDescription) }
                } else { result = ancestors.isEmpty && rolloutPaths.isEmpty ? .empty : .unavailable("Session source is unavailable for inherited-history resolution.") }
            default: throw StoreError(message: String(cString: sqlite3_errmsg(db)))
            }
            cache[key] = result
            return result
        }
        var replies = [String: LastReply](), issues = [String: String]()
        for id in Set(chatIDs) {
            do {
                switch try resolve(id) {
                case .turn(let turn): replies[id] = turn
                case .unavailable(let reason): issues[id] = reason
                case .empty: break
                }
            } catch { issues[id] = error.localizedDescription }
        }
        return LastReplySnapshot(sourceURL: source, replies: replies, issue: nil, issues: issues)
    }
}
