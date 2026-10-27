import Foundation
import CSQLite

// Keep SQLite storage classes and original text bytes separate from display values.
enum SQLiteValue: Equatable {
    case null, integer(Int64), real(Double), text(Data), blob(Data)

    var string: String? {
        guard case .text(let bytes) = self else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    var number: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return nil
        }
    }
}

struct Chat {
    let original: [String: SQLiteValue]
    let id: String
    let title: String
    let createdAt: Date?
    let archived: Bool
    let issues: [String]
    let project: ProjectReference

    var folder: String { original["cwd"]?.string ?? "" }
}

struct ChatSnapshot {
    let chats: [Chat]
    let sourceURL: URL
    let observedAt: Date
    let excludedSubagents: Int
    let projectSourceURL: URL
    let projectSourceIssue: String?
    var lastReplies: LastReplySnapshot? = nil
    var archivedCount: Int { chats.filter(\.archived).count }
    var issueCount: Int { chats.filter { !$0.issues.isEmpty }.count }
    var groups: [ProjectGroup] { ProjectGroup.make(from: chats) }
}

struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ChatStore {
    static var defaultURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("state_5.sqlite")
    }

    static func load(from url: URL = defaultURL, projectStateURL: URL? = nil) throws -> ChatSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError(message: "Local Codex index is missing: \(url.path)")
        }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let handle { sqlite3_close(handle) }
            throw StoreError(message: reason)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1 else {
            throw StoreError(message: "The source connection is not read-only.")
        }
        sqlite3_busy_timeout(db, 1500)
        try execute(db, "PRAGMA query_only=ON")
        try execute(db, "BEGIN")
        defer { try? execute(db, "ROLLBACK") }

        let schema = try rows(db, "PRAGMA table_info(threads)")
        let columns = Set(schema.compactMap { $0["name"]?.string })
        let required: Set<String> = ["id", "title", "created_at", "source", "archived"]
        guard required.isSubset(of: columns) else {
            throw StoreError(message: "Unsupported Codex index: missing \(required.subtracting(columns).sorted().joined(separator: ", ")).")
        }
        let selected = ["id", "name", "title", "created_at", "created_at_ms", "archived", "source", "thread_source", "cwd", "rollout_path", "project_id"].filter { columns.contains($0) }
        let edgeSchema = try rows(db, "PRAGMA table_info(thread_spawn_edges)")
        var childIDs = Set<String>()
        if !edgeSchema.isEmpty {
            guard edgeSchema.contains(where: { $0["name"]?.string == "child_thread_id" }) else {
                throw StoreError(message: "Unsupported subagent relationship schema.")
            }
            childIDs = Set(try rows(db, "SELECT child_thread_id FROM thread_spawn_edges").compactMap { $0["child_thread_id"]?.string })
        }

        let projectURL = projectStateURL ?? url.deletingLastPathComponent().appendingPathComponent(".codex-global-state.json")
        let catalog: ProjectCatalog?
        let projectIssue: String?
        do { catalog = try ProjectCatalog.load(from: projectURL); projectIssue = nil }
        catch { catalog = nil; projectIssue = "Project metadata unavailable: \(error.localizedDescription)" }
        var chats = [Chat]()
        var excluded = 0
        // No transcript reads, joins or preview cap. One row is one recorded thread identity.
        for original in try rows(db, "SELECT \(selected.joined(separator: ",")) FROM threads") {
            let id = original["id"]?.string ?? ""
            var issues = [String]()
            let source = original["source"]?.string
            var isSubagent = childIDs.contains(id) || original["thread_source"]?.string == "subagent"
            if let source, source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                if let data = source.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    isSubagent = isSubagent || json["subagent"] != nil
                } else {
                    issues.append("Unrecognized source metadata; row retained.")
                }
            } else if source == nil {
                issues.append("Source metadata is not valid text; row retained.")
            }
            if isSubagent { excluded += 1; continue }
            if id.isEmpty { issues.append("Missing or malformed chat identity.") }

            let savedName = original["name"]?.string
            let sourceTitle = original["title"]?.string
            let title = [savedName, sourceTitle].compactMap { $0 }.first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? "Untitled chat"
            if sourceTitle == nil { issues.append("Title is not valid UTF-8 text; original value retained.") }
            let milliseconds = original["created_at_ms"] ?? .null
            var seconds = original["created_at"]?.number
            if milliseconds != .null {
                if let value = milliseconds.number, value.isFinite { seconds = value / 1000 }
                else { issues.append("Malformed millisecond creation date; using recorded seconds when available.") }
            }
            var date: Date?
            if let seconds, seconds.isFinite, (-62_135_596_800...253_402_300_799).contains(seconds) {
                date = Date(timeIntervalSince1970: seconds)
            } else { issues.append("Creation date unavailable; row placed under Unknown date.") }
            let archived = (original["archived"]?.number ?? 0) != 0
            if original["archived"]?.number == nil { issues.append("Archive status unavailable.") }
            let project: ProjectReference
            if let catalog {
                let resolved = catalog.project(for: id)
                project = resolved.0
                if let issue = resolved.1 { issues.append(issue) }
            } else {
                project = ProjectReference(identity: .unavailable, name: "Projects unavailable", originalAssignment: nil, originalProject: nil)
                issues.append(projectIssue ?? "Project metadata unavailable.")
            }
            chats.append(Chat(original: original, id: id, title: title, createdAt: date, archived: archived, issues: issues, project: project))
        }
        chats.sort {
            switch ($0.createdAt, $1.createdAt) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id > $1.id
            }
        }
        let turnSource = url.deletingLastPathComponent().appendingPathComponent("thread_history_1.sqlite")
        let lastReplies: LastReplySnapshot
        do { lastReplies = try LastReplyStore.load(chatIDs: chats.map(\.id), from: turnSource, rolloutPaths: LastReplyStore.rolloutPaths(for: chats)) }
        catch { lastReplies = LastReplySnapshot(sourceURL: turnSource, replies: [:], issue: error.localizedDescription) }
        return ChatSnapshot(chats: chats, sourceURL: url, observedAt: Date(), excludedSubagents: excluded,
                            projectSourceURL: projectURL, projectSourceIssue: projectIssue, lastReplies: lastReplies)
    }

    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    static func rows(_ db: OpaquePointer, _ sql: String, bindings: [String] = [], maxRows: Int? = nil) throws -> [[String: SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
        }
        var result = [[String: SQLiteValue]]()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
            if let maxRows, result.count >= maxRows { throw StoreError(message: "Source exceeds this view's record budget. Open a narrower date or an individual chat.") }
            result.append(row(statement))
        }
    }

    static func row(_ statement: OpaquePointer) -> [String: SQLiteValue] {
        var row = [String: SQLiteValue]()
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
            case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
            case SQLITE_TEXT:
                let count = Int(sqlite3_column_bytes(statement, column))
                row[name] = .text(sqlite3_column_text(statement, column).map { Data(bytes: $0, count: count) } ?? Data())
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, column))
                row[name] = .blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data())
            default: row[name] = .null
            }
        }
        return row
    }
}
