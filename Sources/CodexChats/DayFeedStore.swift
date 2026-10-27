import Foundation

struct DayFeedCursor { let milliseconds: Double; let chatID: String; let ordinal: Int64 }
struct DayFeedPage {
    let messages: [RecordedMessage]
    let cursor: DayFeedCursor?
    let scanned: Int
    let deferred: Int
}
enum DayFeedRole { case all, inputs, replies }
enum DayFeedStore {
    static func load(chats: [Chat], source: URL, day: Date, role: DayFeedRole = .all, query: String = "", after: DayFeedCursor? = nil, limit: Int = 100, calendar: Calendar = .current, cancellation: HistoryCancellation = HistoryCancellation()) throws -> DayFeedPage {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { throw StoreError(message: "The selected day is unavailable.") }
        let start = interval.start.timeIntervalSince1970 * 1000, end = interval.end.timeIntervalSince1970 * 1000
        if let after, !after.milliseconds.isFinite { throw StoreError(message: "Invalid day continuation.") }
        let kind = role == .inputs ? "item_type='userMessage'" : role == .replies ? "item_type='agentMessage'" : "item_type IN ('userMessage','agentMessage')"
        let size = min(200, max(1, limit)), ids = Array(Set(chats.map(\.id))).sorted()
        return try HistoryStore.withDB(source, cancellation: cancellation, timeout: 5) { db in
            var combined = [RecordedMessage]()
            let known = Set(ids)
            // Time bounds are found in the compact turn index first. Looking for
            // timestamps across every message would scan large historical blobs.
            var turns = try ChatStore.rows(db, "SELECT thread_id,turn_id FROM thread_turns WHERE (started_at<\(end / 1000) AND (started_at>=\(start / 1000) OR completed_at>=\(start / 1000) OR status IN ('inProgress','running'))) OR started_at IS NULL OR typeof(started_at) NOT IN ('integer','real')")
            // A queued input can belong to a turn that starts on the following
            // day. Follow the explicit first-user-item identity, not a guessed time.
            turns += try ChatStore.rows(db, "SELECT t.thread_id,t.turn_id FROM thread_turns t CROSS JOIN thread_items i ON i.thread_id=t.thread_id AND i.item_id=t.first_user_item_id WHERE t.started_at>=\(end / 1000) AND i.created_at_ms>=\(start) AND i.created_at_ms<\(end)")
            var seen = Set<[String]>()
            for turn in turns {
                guard !cancellation.cancelled else { throw StoreError(message: "Day read cancelled.") }
                guard let thread = turn["thread_id"]?.string, known.contains(thread), let turnID = turn["turn_id"]?.string, seen.insert([thread,turnID]).inserted else { continue }
                var bindings = [thread,turnID]
                var cursor = ""
                if let after {
                    cursor = " AND (created_at_ms>\(after.milliseconds) OR (created_at_ms=\(after.milliseconds) AND (thread_id>? OR (thread_id=? AND rollout_ordinal>\(after.ordinal)))))"
                    bindings += [after.chatID,after.chatID]
                }
                let sql = "SELECT \(HistoryStore.previewFields) FROM thread_items WHERE thread_id=? AND turn_id=? AND \(kind) AND typeof(created_at_ms) IN ('integer','real') AND created_at_ms>=\(start) AND created_at_ms<\(end)\(cursor) ORDER BY created_at_ms,thread_id,rollout_ordinal LIMIT \(size+1)"
                combined += try ChatStore.rows(db, sql, bindings: bindings).map { try HistoryStore.message($0, source: source) }
                combined.sort {
                    let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
                    if a != b { return a < b }; if $0.chatID != $1.chatID { return $0.chatID < $1.chatID }; return $0.ordinal < $1.ordinal
                }
                if combined.count > size + 1 { combined.removeLast(combined.count - size - 1) }
            }
            let scanned = Array(combined.prefix(size))
            let selected = query.isEmpty ? scanned : scanned.filter { $0.issue == nil && $0.recordedText?.range(of: query, options: [.caseInsensitive,.diacriticInsensitive]) != nil }
            let cursor = combined.count > size ? scanned.last.flatMap { message in message.createdAt.map { DayFeedCursor(milliseconds: $0.timeIntervalSince1970 * 1000, chatID: message.chatID, ordinal: message.ordinal) } } : nil
            return DayFeedPage(messages: selected, cursor: cursor, scanned: scanned.count, deferred: scanned.filter { $0.rawPayload == nil || $0.issue != nil }.count)
        }
    }
}
