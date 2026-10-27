import Foundation

// The original prototype's declared scope: latest eight text records today,
// from fifteen newest non-archived desktop chats. Original line bytes stay separate.
enum ColumnsStore {
    static let maximumRecordBytes = 16 * 1024 * 1024
    static func load(_ metadata: ChatSnapshot, now: Date = Date(), cancellation: HistoryCancellation = HistoryCancellation()) throws -> ColumnsSnapshot {
        let budget = SourceReadBudget(cancellation: cancellation)
        try budget.check()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let interval = calendar.dateInterval(of: .day, for: now)!
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainClock = ISO8601DateFormatter()
        let day = DateFormatter(); day.calendar = calendar; day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        var chats = [[String: Any]](), gaps = [[String: Any]]()
        var retainedBytes = 0
        for chat in metadata.chats.filter({ !$0.archived && $0.original["source"]?.string == "vscode" }).prefix(15) {
            try budget.check()
            let path = chat.original["rollout_path"]?.string ?? ""
            var messages = [[String: Any]](), available = 0
            var issue: String?
            do {
                guard !path.isEmpty else { throw StoreError(message: "Rollout source unavailable") }
                let stream = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? stream.close() }
                var pending = Data(), offset = 0, ordinal = 0, searchOffset = 0
                func consume(_ raw: Data) throws {
                    try budget.check()
                    guard raw.count <= maximumRecordBytes else { throw StoreError(message: "Record exceeds the 16 MiB COLUMNS limit at byte \(offset). Open its source chat; this file is only partially displayed.") }
                    defer { offset += raw.count; ordinal += 1 }
                    func retain(_ count: Int) throws {
                        guard retainedBytes + count <= 32 * 1024 * 1024 else { throw StoreError(message: "COLUMNS reached its 32 MiB captured-byte budget; source reading stopped with partial coverage.") }
                        retainedBytes += count
                    }
                    func gap(_ reason: String) throws {
                        try retain(raw.count)
                        gaps.append(["source": path, "offset": offset, "raw_base64": raw.base64EncodedString(), "reason": reason])
                    }
                    guard let record = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { try gap("Malformed, partial or unsupported record"); return }
                    guard let payload = record["payload"] as? [String: Any] else { try gap("Unsupported payload shape"); return }
                    guard record["type"] as? String == "response_item", payload["type"] as? String == "message",
                          let role = payload["role"] as? String, ["user", "assistant"].contains(role) else { return }
                    let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    guard !text.isEmpty else { return }
                    if role == "user", ["# AGENTS.md instructions", "<environment_context>", "<external_codex_apps_open_page>"].contains(where: { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0) }) { return }
                    guard let stamp = record["timestamp"] as? String, let date = clock.date(from: stamp) ?? plainClock.date(from: stamp) else { try gap("Message time unavailable"); return }
                    guard date >= interval.start && date < interval.end else { return }
                    available += 1
                    // Count every retained candidate conservatively. A very large
                    // file is visibly partial instead of allocating without bound.
                    try retain(raw.count)
                    messages.append(["id": "\(chat.id):\(record["ordinal"] ?? ordinal)", "timestamp": stamp, "role": role, "text": text,
                                     "source_offset": offset, "raw_base64": raw.base64EncodedString()])
                    if messages.count > 8 { messages.removeFirst() }
                }
                while let chunk = try stream.read(upToCount: 65536), !chunk.isEmpty {
                    try budget.check()
                    pending.append(chunk)
                    var start = pending.startIndex
                    var search = pending.startIndex + searchOffset
                    while let newline = pending[search...].firstIndex(of: 10) {
                        let end = pending.index(after: newline)
                        try autoreleasepool { try consume(Data(pending[start..<end])) }; start = end; search = end
                    }
                    // Scan each byte once, and don't repeatedly copy an unfinished
                    // large line while waiting for its newline.
                    if start != pending.startIndex { pending = Data(pending[start...]) }
                    searchOffset = pending.count
                    guard pending.count <= maximumRecordBytes else { throw StoreError(message: "Record exceeds the 16 MiB COLUMNS limit at byte \(offset). Open its source chat; this file is only partially displayed.") }
                }
                if !pending.isEmpty { try autoreleasepool { try consume(pending) } }
            } catch {
                try budget.check()
                issue = "Source incomplete: \(error.localizedDescription)"
                gaps.append(["source": path, "reason": issue!])
            }
            var row: [String: Any] = ["id": chat.id, "title": chat.title, "source_path": path, "messages": messages, "available_today": available]
            if let issue { row["source_issue"] = issue }
            chats.append(row)
        }
        try budget.check()
        let object: [String: Any] = ["day": day.string(from: now), "scope": "TODAY · 15 NEWEST NON-ARCHIVED DESKTOP CHATS · LAST 8 TEXT RECORDS EACH", "chats": chats, "gaps": gaps]
        return try JSONDecoder().decode(ColumnsSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
