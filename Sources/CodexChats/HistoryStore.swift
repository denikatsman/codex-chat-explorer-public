import Foundation
import CSQLite
import CryptoKit

final class HistoryCancellation {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct RecordedMessage {
    let chatID: String
    let turnID: String
    let itemID: String
    let ordinal: Int64
    let createdAt: Date?
    let role: String
    let text: String
    let recordedText: String?
    let rawPayload: SQLiteValue?
    let payloadBytes: Int
    let issue: String?
    let sourceURL: URL
    let originalMetadata: [String: SQLiteValue]
    let observedAt = Date()
    var payloadDigest: String? {
        switch rawPayload {
        case .text(let data), .blob(let data): return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default: return nil
        }
    }
    var reference: String { "\(chatID)/\(itemID)@\(ordinal)" }
    var rawDisplay: String {
        switch rawPayload {
        case .text(let data): return String(data: data, encoding: .utf8) ?? "Invalid UTF-8; original bytes (base64):\n\(data.base64EncodedString())"
        case .blob(let data): return "Recorded BLOB (base64):\n\(data.base64EncodedString())"
        case .null: return "Recorded SQL NULL"
        case .integer(let n): return "Recorded INTEGER: \(n)"
        case .real(let n): return "Recorded REAL: \(n)"
        case nil: return "Payload deferred (\(payloadBytes) bytes). Load this message explicitly to inspect the full record."
        }
    }
    init(row: [String: SQLiteValue], source: URL) {
        originalMetadata = row.filter { !["item_json", "payload_bytes", "payload_deferred"].contains($0.key) }
        chatID = row["thread_id"]?.string ?? ""
        turnID = row["turn_id"]?.string ?? ""
        itemID = row["item_id"]?.string ?? ""
        if case .integer(let value)? = row["rollout_ordinal"] { ordinal = value } else { ordinal = -1 }
        role = row["item_type"]?.string == "userMessage" ? "USER" : "ASSISTANT"
        if let ms = row["created_at_ms"]?.number, ms.isFinite, (-62_135_596_800_000...253_402_300_799_000).contains(ms) { createdAt = Date(timeIntervalSince1970: ms / 1000) } else { createdAt = nil }
        payloadBytes = Int(row["payload_bytes"]?.number ?? 0)
        let omitted = row["payload_deferred"]?.number == 1
        rawPayload = omitted ? nil : row["item_json"] ?? .null
        sourceURL = source
        if omitted { recordedText = nil; text = "Large recorded message (\(payloadBytes) bytes). Select Load full to read it."; issue = "Payload deferred until explicitly requested."; return }
        guard case .text(let data)? = rawPayload, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            recordedText = nil
            text = "Recorded message payload is missing or malformed. Raw bytes remain available."; issue = "Cannot decode recorded message text."; return
        }
        if let body = object["text"] as? String { recordedText = body; text = body; issue = nil; return }
        if let content = object["content"] as? [[String: Any]] {
            let bodies = content.compactMap { $0["text"] as? String }
            recordedText = bodies.isEmpty ? nil : bodies.joined(separator: "\n")
            text = bodies.isEmpty ? "No text in this recorded message. Inspect Raw for attachment metadata." : bodies.joined(separator: "\n")
            issue = nil; return
        }
        recordedText = nil
        text = "Recorded payload has an unfamiliar text shape. Inspect Raw."
        issue = "Unrecognized message shape; original payload retained."
    }
}
struct HistoryPage {
    let messages: [RecordedMessage]
    let total: Int
    let hasMore: Bool
    let sourceURL: URL
    var hasEarlier = false
}
struct HistorySearchCursor: Codable { let chatIndex: Int; let ordinal: Int64? }
struct HistorySearchResult {
    let messages: [RecordedMessage]
    let cursor: HistorySearchCursor?
    let scanned: Int
    let deferred: Int
    let complete: Bool
}

enum HistoryStore {
    private static let fields = "thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_type,length(CAST(item_json AS BLOB)) AS payload_bytes"
    static let previewFields = fields + ",CASE WHEN length(CAST(item_json AS BLOB))>1048576 THEN NULL ELSE item_json END AS item_json,CASE WHEN length(CAST(item_json AS BLOB))>1048576 THEN 1 ELSE 0 END AS payload_deferred"
    static func source(for snapshot: ChatSnapshot) -> URL { snapshot.sourceURL.deletingLastPathComponent().appendingPathComponent("thread_history_1.sqlite") }
    static func page(chatID: String, source: URL, after: Int64? = nil, before: Int64? = nil, limit: Int = 40, cancellation: HistoryCancellation = HistoryCancellation()) throws -> HistoryPage {
        try withDB(source, cancellation: cancellation) { db in
            let size = min(100, max(1, limit))
            let position = after.map { " AND rollout_ordinal>\($0)" } ?? before.map { " AND rollout_ordinal<\($0)" } ?? ""
            let order = before == nil ? "ASC" : "DESC"
            let sql = "SELECT \(previewFields) FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage')\(position) ORDER BY rollout_ordinal \(order) LIMIT \(size + 1)"
            let rows = try ChatStore.rows(db, sql, bindings: [chatID])
            var messages = try rows.prefix(size).map { try message($0, source: source) }
            if before != nil { messages.reverse() }
            let count = try ChatStore.rows(db, "SELECT count(*) AS count FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage')", bindings: [chatID]).first?["count"]?.number ?? 0
            let first = messages.first?.ordinal, last = messages.last?.ordinal
            let older = try first.map { !((try ChatStore.rows(db, "SELECT 1 FROM thread_items WHERE thread_id=? AND rollout_ordinal<\($0) AND item_type IN ('userMessage','agentMessage') LIMIT 1", bindings: [chatID])).isEmpty) } ?? false
            let newer = try last.map { !((try ChatStore.rows(db, "SELECT 1 FROM thread_items WHERE thread_id=? AND rollout_ordinal>\($0) AND item_type IN ('userMessage','agentMessage') LIMIT 1", bindings: [chatID])).isEmpty) } ?? false
            return HistoryPage(messages: messages, total: Int(count), hasMore: newer, sourceURL: source, hasEarlier: older)
        }
    }
    static func full(chatID: String, ordinal: Int64, source: URL, cancellation: HistoryCancellation = HistoryCancellation()) throws -> RecordedMessage {
        try withDB(source, cancellation: cancellation) { db in
            let predicate = "thread_id=? AND rollout_ordinal=\(ordinal)"
            guard let size = try ChatStore.rows(db, "SELECT length(CAST(item_json AS BLOB)) AS bytes FROM thread_items WHERE \(predicate) LIMIT 1", bindings: [chatID]).first else { throw StoreError(message: "The referenced source message is no longer available.") }
            guard (size["bytes"]?.number ?? 0) <= 64 * 1024 * 1024 else { throw StoreError(message: "This record exceeds the 64 MiB in-memory viewing limit. RAW export can preserve its complete payload.") }
            guard let row = try ChatStore.rows(db, "SELECT \(fields),item_json,0 AS payload_deferred FROM thread_items WHERE \(predicate) LIMIT 1", bindings: [chatID]).first else { throw StoreError(message: "The referenced source message is no longer available.") }
            return try message(row, source: source)
        }
    }
    static func search(query: String, chats: [Chat], source: URL, cursor: HistorySearchCursor? = nil, budget: TimeInterval = 2, cancellation: HistoryCancellation = HistoryCancellation()) throws -> HistorySearchResult {
        let ordered = chats.sorted { $0.id < $1.id }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return HistorySearchResult(messages: [], cursor: nil, scanned: 0, deferred: 0, complete: true) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, min(5, budget))
        return try withDB(source, cancellation: cancellation, timeout: 8) { db in
            var found = [RecordedMessage](), scanned = 0, deferred = 0
            var index = cursor?.chatIndex ?? 0
            var after = cursor?.ordinal
            while index < ordered.count {
                if cancellation.cancelled { throw StoreError(message: "Search cancelled.") }
                let position = after.map { " AND rollout_ordinal>\($0)" } ?? ""
                let rows = try ChatStore.rows(db, "SELECT \(previewFields) FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage')\(position) ORDER BY rollout_ordinal LIMIT 40", bindings: [ordered[index].id])
                if rows.isEmpty { index += 1; after = nil }
                else {
                    for row in rows {
                        let message = try message(row, source: source)
                        scanned += 1; after = message.ordinal
                        if message.rawPayload == nil || message.issue != nil { deferred += 1 }
                        else if let text = message.recordedText, message.issue == nil, text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { found.append(message) }
                        if found.count >= 100 || ProcessInfo.processInfo.systemUptime >= deadline {
                            return HistorySearchResult(messages: found, cursor: HistorySearchCursor(chatIndex: index, ordinal: after), scanned: scanned, deferred: deferred, complete: false)
                        }
                    }
                    if rows.count < 40 { index += 1; after = nil }
                }
                if ProcessInfo.processInfo.systemUptime >= deadline, index < ordered.count {
                    return HistorySearchResult(messages: found, cursor: HistorySearchCursor(chatIndex: index, ordinal: after), scanned: scanned, deferred: deferred, complete: false)
                }
            }
            return HistorySearchResult(messages: found, cursor: nil, scanned: scanned, deferred: deferred, complete: true)
        }
    }
    static func message(_ row: [String: SQLiteValue], source: URL) throws -> RecordedMessage {
        guard case .integer(let ordinal)? = row["rollout_ordinal"], ordinal >= 0,
              let chatID = row["thread_id"]?.string, !chatID.isEmpty,
              let itemID = row["item_id"]?.string, !itemID.isEmpty else { throw StoreError(message: "A recorded message has malformed identity/ordinal metadata; the source row is preserved.") }
        return RecordedMessage(row: row, source: source)
    }

    private static func exportTarget(_ destination: URL, source: URL) throws -> URL {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        let protected = source.resolvingSymlinksInPath().standardizedFileURL
        let home = ChatStore.defaultURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard target.path != protected.path, !target.path.hasPrefix(home.path + "/") else { throw StoreError(message: "Choose an export destination outside the original Codex sources.") }
        return target
    }
    static func exportCaptured(_ message: RecordedMessage, to destination: URL) throws {
        let target = try exportTarget(destination, source: message.sourceURL)
        let bytes: Data
        switch message.rawPayload {
        case .text(let value), .blob(let value): bytes = value
        default: throw StoreError(message: "This read did not capture text/blob payload bytes.")
        }
        try bytes.write(to: target, options: [.atomic])
    }

    static func export(chatID: String, ordinal: Int64, source: URL, to destination: URL, cancellation: HistoryCancellation = HistoryCancellation()) throws {
        let target = try exportTarget(destination, source: source)
        try withDB(source, cancellation: cancellation, timeout: 30) { db in
            guard let row = try ChatStore.rows(db, "SELECT rowid,typeof(item_json) AS storage FROM thread_items WHERE thread_id=? AND rollout_ordinal=\(ordinal) LIMIT 1", bindings: [chatID]).first,
                  case .integer(let rowID)? = row["rowid"], ["text", "blob"].contains(row["storage"]?.string ?? "") else { throw StoreError(message: "The source payload has no exportable text/blob bytes.") }
            var pointer: OpaquePointer?
            guard sqlite3_blob_open(db, "main", "thread_items", "item_json", rowID, 0, &pointer) == SQLITE_OK, let blob = pointer else { throw StoreError(message: "Cannot stream the selected raw payload.") }
            defer { sqlite3_blob_close(blob) }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".explorer-export-\(UUID())")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw StoreError(message: "Cannot create the export file.") }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            let size = Int(sqlite3_blob_bytes(blob)); var offset = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while offset < size {
                guard !cancellation.cancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw StoreError(message: "Export cancelled or timed out; original sources were not changed.") }
                let count = min(65_536, size - offset)
                var bytes = Data(count: count)
                let read = bytes.withUnsafeMutableBytes { sqlite3_blob_read(blob, $0.baseAddress, Int32(count), Int32(offset)) }
                guard read == SQLITE_OK else { throw StoreError(message: "Could not read the original payload bytes.") }
                try output.write(contentsOf: bytes); offset += count
            }
            try output.synchronize(); try output.close()
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: target) }
        }
    }

    static func withDB<T>(_ source: URL, cancellation: HistoryCancellation, timeout: TimeInterval = 3, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard !cancellation.cancelled else { throw StoreError(message: "History request cancelled.") }
        guard FileManager.default.fileExists(atPath: source.path) else { throw StoreError(message: "Recorded message index is unavailable.") }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let db = handle else { if let handle { sqlite3_close(handle) }; throw StoreError(message: "Cannot read the recorded message index.") }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw StoreError(message: "History source is not read-only.") }
        sqlite3_busy_timeout(db, 250)
        let progress = HistoryProgress(cancellation: cancellation, deadline: ProcessInfo.processInfo.systemUptime + timeout)
        let retained = Unmanaged.passRetained(progress)
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }
            let value = Unmanaged<HistoryProgress>.fromOpaque(pointer).takeUnretainedValue()
            return value.cancellation.cancelled || ProcessInfo.processInfo.systemUptime > value.deadline ? 1 : 0
        }, retained.toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); retained.release() }
        try ChatStore.execute(db, "PRAGMA query_only=ON"); try ChatStore.execute(db, "BEGIN")
        defer { try? ChatStore.execute(db, "ROLLBACK") }
        return try body(db)
    }
}
private final class HistoryProgress {
    let cancellation: HistoryCancellation
    let deadline: TimeInterval
    init(cancellation: HistoryCancellation, deadline: TimeInterval) { self.cancellation = cancellation; self.deadline = deadline }
}
