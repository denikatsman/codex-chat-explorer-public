import Foundation
import CryptoKit

/// A bounded fallback for a regular chat with no own indexed SQLite messages. It never
/// traverses history_base/forked_from pointers and never treats event mirrors as messages.
enum SemanticRolloutAdapter {
    static let maximumFileBytes = 64 * 1_024 * 1_024
    static let maximumDecodedRecordBytes = 8 * 1_024 * 1_024
    struct Record {
        let offset: Int64
        let ordinal: Int64
        let raw: Data
        let body: String
        let role: String
        let phase: String
        let turnID: String
        let createdAt: Double?
        let issue: String?
    }
    struct Summary { let messages: Int; let records: Int }

    static func signature(path: String?) -> String {
        guard let path else { return "rollout-unavailable" }
        let url = URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL
        guard let values = try? FileManager.default.attributesOfItem(atPath:url.path) else { return "rollout-missing:" + path }
        return "rollout-v1:\(url.path):\(values[.systemFileNumber] ?? "?"):\(values[.size] ?? "?"):\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    static func scan(chatID: String, source: URL, cancellation: HistoryCancellation, timeout: TimeInterval = 5, record: (Record) throws -> Void) throws -> Summary {
        let attributes = try FileManager.default.attributesOfItem(atPath:source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maximumFileBytes else { throw SemanticFailure("Rollout fallback is unavailable: file is not regular or exceeds the 64 MiB streaming limit.") }
        let input = try FileHandle(forReadingFrom:source)
        defer { try? input.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01,min(5,timeout))
        func check() throws {
            guard !cancellation.cancelled else { throw SemanticFailure("Rollout fallback cancelled.") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SemanticFailure("Rollout fallback exceeded its five-second read budget; no partial fallback was committed.") }
        }
        var pending = Data(), searched = 0, readBytes = 0
        var offset: Int64 = 0, ordinal: Int64 = 0, verified = false, activeTurn: String?
        var messages = 0, records = 0, seenMessageIDs = Set<String>()
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let secondsTimestamp = ISO8601DateFormatter()
        secondsTimestamp.formatOptions = [.withInternetDateTime]
        func emit(_ raw: Data) throws {
            try check()
            defer { offset += Int64(raw.count); ordinal += 1; records += 1 }
            try autoreleasepool {
                var body = "", role = "EXCLUDED", phase = "", turn = ""
                var createdAt: Double?, issue: String?
                if raw.count > maximumDecodedRecordBytes { issue = "Rollout record exceeds the 8 MiB decoding limit; complete raw record retained." }
                else if let object = try? JSONSerialization.jsonObject(with:raw) as? [String:Any], let kind = object["type"] as? String, let payload = object["payload"] as? [String:Any] {
                    if let value = object["timestamp"] as? String { createdAt = (timestamp.date(from:value) ?? secondsTimestamp.date(from:value))?.timeIntervalSince1970 }
                    switch kind {
                    case "session_meta":
                        guard let id = payload["id"] as? String, id == chatID else { throw SemanticFailure("Rollout session identity does not match the selected chat; no fallback text was indexed.") }
                        verified = true
                    case "turn_context": activeTurn = payload["turn_id"] as? String
                    case "event_msg":
                        if payload["type"] as? String == "task_started" { activeTurn = payload["turn_id"] as? String }
                        if payload["type"] as? String == "task_complete" { activeTurn = nil }
                        // event_msg user/agent/item_completed copies are mirrors, not a second source message.
                    case "response_item":
                        let type = payload["type"] as? String ?? ""
                        if type == "message", let author = payload["role"] as? String, author == "user" || author == "assistant" {
                            role = author == "user" ? "USER" : "ASSISTANT"
                            phase = author == "assistant" ? (payload["phase"] as? String ?? payload["channel"] as? String ?? "unknown") : ""
                            let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String:Any]
                            turn = metadata?["turn_id"] as? String ?? payload["turn_id"] as? String ?? activeTurn ?? ""
                            if let time = metadata?["create_time"] as? Double, time.isFinite { createdAt = time }
                            if let text = payload["text"] as? String { body = text }
                            else if let content = payload["content"] as? [[String:Any]] {
                                let text = content.compactMap { element -> String? in
                                    // Opaque/encrypted entries never become invented plaintext.
                                    guard ["input_text","output_text","text"].contains(element["type"] as? String ?? "") else { return nil }
                                    return element["text"] as? String
                                }
                                body = text.joined(separator:"\n")
                                if text.isEmpty { issue = "Rollout message has no supported text content; complete raw record retained." }
                            } else { issue = "Rollout message has an unfamiliar content shape; complete raw record retained." }
                            if let id = payload["id"] as? String, !id.isEmpty {
                                let digest = SHA256.hash(data:Data((role + "\u{0}" + phase + "\u{0}" + body).utf8)).map { String(format:"%02x",$0) }.joined()
                                if !seenMessageIDs.insert(id + ":" + digest).inserted { issue = "Duplicate rollout response message ID/content; raw copy retained, text not indexed twice." }
                            }
                            if issue == nil, !body.isEmpty { messages += 1 }
                        }
                        // reasoning, tool records, developer context and agent_message with subagent
                        // authors are outside fallback's declared regular user/assistant text scope.
                    case "compacted": break
                    default: issue = "Unsupported rollout record type '\(kind)'; complete raw record retained, text not indexed."
                    }
                } else { issue = "Malformed or partial rollout JSON record; exact original record bytes retained." }
                try record(Record(offset:offset,ordinal:ordinal,raw:raw,body:body,role:role,phase:phase,turnID:turn,createdAt:createdAt,issue:issue))
            }
        }
        while true {
            try check()
            guard let chunk = try input.read(upToCount:65_536), !chunk.isEmpty else { break }
            readBytes += chunk.count
            guard readBytes <= maximumFileBytes else { throw SemanticFailure("Rollout grew beyond the 64 MiB fallback limit during reading.") }
            pending.append(chunk)
            while let newline = pending[searched...].firstIndex(of:10) {
                let end = pending.index(after:newline)
                try emit(Data(pending[..<end]))
                pending.removeSubrange(..<end); searched = pending.startIndex
            }
            searched = pending.endIndex
        }
        if !pending.isEmpty { try emit(pending) }
        guard verified else { throw SemanticFailure("Rollout has no matching session_meta identity; legacy/unknown format remains unavailable for search.") }
        try check()
        return Summary(messages:messages,records:records)
    }
}
