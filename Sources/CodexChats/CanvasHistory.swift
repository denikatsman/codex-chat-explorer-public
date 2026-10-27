import Foundation

struct CanvasMessageReference {
    let chatID: String
    let ordinal: Int64
    let itemID: String
    let role: String
    let createdAt: Date?
    let bytes: Int
    var key: String { "\(chatID)/\(itemID)@\(ordinal)" }
}

struct CanvasHistoryIndex {
    let messages: [CanvasMessageReference]
    let issues: [String]
}

/// Metadata is small; message payloads are read only for visible table rows.
/// Inherited history is bounded by the recorded fork cutoffs, never parent recency.
enum CanvasHistoryStore {
    private static let headers = TurnHeaderCache()

    static func index(chat: Chat, chats: [String: Chat], source: URL, cancellation: HistoryCancellation) throws -> CanvasHistoryIndex {
        let budget = SourceReadBudget(cancellation: cancellation)
        var lineage = [(String, Int64?)](), seen = Set<String>(), current = chat
        var upper: Int64?, issues = [String]()
        while true {
            try budget.check()
            guard seen.insert(current.id).inserted, lineage.count < 32 else { throw StoreError(message: "Inherited history is cyclic or exceeds 32 levels.") }
            lineage.append((current.id, upper))
            guard let path = current.original["rollout_path"]?.string else {
                issues.append("Session header unavailable; inherited history could not be checked."); break
            }
            do {
                let header = try headers.read(URL(fileURLWithPath: path), id: current.id, budget: budget)
                if let issue = header.issue { issues.append(issue); break }
                guard let base = header.base else { break }
                guard let parent = chats[base.threadID] else {
                    issues.append("Inherited source chat is unavailable: \(base.threadID)"); break
                }
                upper = base.ordinal; current = parent
            } catch {
                if cancellation.cancelled { throw error }
                issues.append("Session header unavailable: \(error.localizedDescription)"); break
            }
        }
        return try HistoryStore.withDB(source, cancellation: cancellation, timeout: 5) { db in
            var messages = [CanvasMessageReference](), messageKeys = Set<String>()
            for (id, end) in lineage.reversed() {
                try budget.check()
                let cutoff = end.map { " AND i.rollout_ordinal<\($0)" } ?? ""
                // Unknown phases are admitted only through the turn's explicit final-item pointer.
                let phase = "CASE WHEN json_valid(i.item_json) THEN lower(COALESCE(json_extract(i.item_json,'$.phase'),json_extract(i.item_json,'$.channel'),'')) ELSE '' END"
                let sql = """
                SELECT i.thread_id,i.rollout_ordinal,i.item_id,i.item_type,i.created_at_ms,
                       length(CAST(i.item_json AS BLOB)) AS payload_bytes
                FROM thread_items i WHERE i.thread_id=? \(cutoff)
                AND (i.item_type='userMessage' OR (i.item_type='agentMessage' AND
                    ((\(phase)) IN ('final','final_answer') OR ((\(phase))='' AND EXISTS
                     (SELECT 1 FROM thread_turns t WHERE t.thread_id=i.thread_id AND t.turn_id=i.turn_id AND t.final_agent_item_id=i.item_id)))))
                ORDER BY i.rollout_ordinal
                """
                for row in try ChatStore.rows(db, sql, bindings: [id]) {
                    guard case .integer(let ordinal)? = row["rollout_ordinal"], ordinal >= 0,
                          let itemID = row["item_id"]?.string else { issues.append("A message has malformed source identity."); continue }
                    let key = id + "/" + itemID + "@" + String(ordinal)
                    guard messageKeys.insert(key).inserted else { continue }
                    let date = row["created_at_ms"]?.number.flatMap { $0.isFinite && (-62_135_596_800_000...253_402_300_799_000).contains($0) ? Date(timeIntervalSince1970: $0 / 1000) : nil }
                    messages.append(CanvasMessageReference(chatID: id, ordinal: ordinal, itemID: itemID,
                        role: row["item_type"]?.string == "userMessage" ? "YOU" : "ASSISTANT", createdAt: date,
                        bytes: Int(row["payload_bytes"]?.number ?? 0)))
                }
            }
            return CanvasHistoryIndex(messages: messages, issues: issues)
        }
    }
}
