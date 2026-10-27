import Foundation
import CryptoKit
import CSQLite
import Accelerate

/// A replaceable, app-owned index. Connections to original history are always read-only.
/// Each instance is serialized; callers run it on their worker queue, never the main thread.
final class SemanticIndexStore {
    static let dimensions = 4_096
    static let maximumDecodedPayloadBytes = 64 * 1_024 * 1_024
    let url: URL
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer!
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        let sourceRoot = ChatStore.defaultURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !target.hasPrefix(sourceRoot + "/"), target != sourceRoot else { throw SemanticFailure("Search indexes must be outside the original Codex source directory.") }
        if FileManager.default.fileExists(atPath:url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) <= 1 else { throw SemanticFailure("Search index cannot be a hard link to another file.") }
            var existing: OpaquePointer?
            // A checkpointed SQLite backup may retain a WAL-mode header without sidecars.
            // Apple's read-only VFS cannot open that schema normally (CANTOPEN/ENOENT).
            // Immutable mode is used only to verify ownership of this sidecar-free snapshot;
            // the actual owned index is subsequently opened through the normal writable VFS.
            let snapshotOnly = !FileManager.default.fileExists(atPath:url.path + "-wal") && !FileManager.default.fileExists(atPath:url.path + "-shm")
            let verificationPath = snapshotOnly ? url.absoluteString + "?mode=ro&immutable=1" : url.path
            let verificationFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | (snapshotOnly ? SQLITE_OPEN_URI : 0)
            let opened = sqlite3_open_v2(verificationPath,&existing,verificationFlags,nil)
            guard opened == SQLITE_OK, let existing else { if let existing { sqlite3_close(existing) }; throw SemanticFailure("Cannot verify existing search index ownership.") }
            defer { sqlite3_close(existing) }
            let names = Set(try ChatStore.rows(existing,"SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.string })
            guard names.contains("semantic_meta"), names.contains("semantic_passages") else { throw SemanticFailure("Existing file is not an app-owned semantic index; it was left unchanged.") }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }; throw SemanticFailure("Cannot open the local semantic search index.")
        }
        db = handle
        do {
            sqlite3_busy_timeout(db, 2_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS semantic_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS semantic_chats(id TEXT PRIMARY KEY,missing INTEGER NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE IF NOT EXISTS semantic_signatures(chat_id TEXT PRIMARY KEY,signature TEXT NOT NULL)")
            let policy = "chunk-v1:chars=\(SemanticChunker.maximumCharacters):bytes=\(SemanticChunker.maximumUTF8Bytes):context-chars=\(SemanticChunker.maximumContextCharacters):context-bytes=\(SemanticChunker.maximumContextUTF8Bytes)"
            if try scalar("SELECT value FROM semantic_meta WHERE key='chunk_policy'")?.string != policy {
                try execute("DELETE FROM semantic_signatures")
                try execute("INSERT OR REPLACE INTO semantic_meta VALUES('chunk_policy',?)", [text(policy)])
            }
            try execute("CREATE TABLE IF NOT EXISTS semantic_raw(digest TEXT NOT NULL,part INTEGER NOT NULL,bytes BLOB NOT NULL,PRIMARY KEY(digest,part))")
            try execute("CREATE TABLE IF NOT EXISTS semantic_revisions(record_key TEXT NOT NULL,fingerprint TEXT NOT NULL,metadata BLOB NOT NULL,payload_digest TEXT NOT NULL,storage TEXT NOT NULL,issue TEXT,source_path TEXT NOT NULL,observed_at REAL NOT NULL,PRIMARY KEY(record_key,fingerprint))")
            let revisionColumns = Set(try rows("PRAGMA table_info(semantic_revisions)").compactMap { $0["name"]?.string })
            if !revisionColumns.contains("source_path") { try execute("ALTER TABLE semantic_revisions ADD COLUMN source_path TEXT NOT NULL DEFAULT ''") }
            if !revisionColumns.contains("observed_at") { try execute("ALTER TABLE semantic_revisions ADD COLUMN observed_at REAL NOT NULL DEFAULT 0") }
            try execute("CREATE TABLE IF NOT EXISTS semantic_records(record_key TEXT PRIMARY KEY,chat_id TEXT NOT NULL,fingerprint TEXT NOT NULL,body TEXT NOT NULL,role TEXT NOT NULL,phase TEXT NOT NULL,issue TEXT,generation TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS semantic_records_chat ON semantic_records(chat_id)")
            try execute("CREATE INDEX IF NOT EXISTS semantic_records_role ON semantic_records(role)")
            try execute("CREATE INDEX IF NOT EXISTS semantic_records_issues ON semantic_records(issue) WHERE issue IS NOT NULL")
            try execute("CREATE TABLE IF NOT EXISTS semantic_passages(id TEXT PRIMARY KEY,record_key TEXT NOT NULL,chat_id TEXT NOT NULL,role TEXT NOT NULL,phase TEXT NOT NULL,digest TEXT NOT NULL,payload BLOB NOT NULL,search_text TEXT NOT NULL,FOREIGN KEY(record_key) REFERENCES semantic_records(record_key) ON DELETE CASCADE)")
            try execute("CREATE INDEX IF NOT EXISTS semantic_passages_chat ON semantic_passages(chat_id)")
            try execute("CREATE INDEX IF NOT EXISTS semantic_passages_record ON semantic_passages(record_key)")
            try execute("CREATE TABLE IF NOT EXISTS semantic_vectors(passage_id TEXT NOT NULL,model_digest TEXT NOT NULL,source_digest TEXT NOT NULL,vector BLOB NOT NULL,PRIMARY KEY(passage_id,model_digest),FOREIGN KEY(passage_id) REFERENCES semantic_passages(id) ON DELETE CASCADE)")
            try execute("CREATE INDEX IF NOT EXISTS semantic_vectors_model ON semantic_vectors(model_digest,passage_id,source_digest)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS semantic_fts USING fts5(id UNINDEXED,search_text,tokenize='unicode61')")
            // Older derived indexes deleted FTS rows by an UNINDEXED text column, making
            // each revised record scan the entire table. Align FTS rowids once, atomically.
            if try scalar("SELECT value FROM semantic_meta WHERE key='fts_rowid_version'")?.string != "1" {
                try transaction {
                    for name in ["semantic_passage_delete","semantic_passage_insert","semantic_passage_update"] { try execute("DROP TRIGGER IF EXISTS \(name)") }
                    try execute("DELETE FROM semantic_fts")
                    try execute("INSERT INTO semantic_fts(rowid,id,search_text) SELECT rowid,id,search_text FROM semantic_passages")
                    try createFTSTriggers()
                    try execute("INSERT OR REPLACE INTO semantic_meta VALUES('fts_rowid_version','1')")
                }
            } else { try createFTSTriggers() }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    private func createFTSTriggers() throws {
        try execute("CREATE TRIGGER IF NOT EXISTS semantic_passage_delete AFTER DELETE ON semantic_passages BEGIN DELETE FROM semantic_fts WHERE rowid=old.rowid; END")
        try execute("CREATE TRIGGER IF NOT EXISTS semantic_passage_insert AFTER INSERT ON semantic_passages BEGIN INSERT INTO semantic_fts(rowid,id,search_text) VALUES(new.rowid,new.id,new.search_text); END")
        try execute("CREATE TRIGGER IF NOT EXISTS semantic_passage_update AFTER UPDATE ON semantic_passages BEGIN DELETE FROM semantic_fts WHERE rowid=old.rowid; INSERT INTO semantic_fts(rowid,id,search_text) VALUES(new.rowid,new.id,new.search_text); END")
    }

    deinit { if db != nil { sqlite3_close(db) } }

    func importSources(chats: [Chat], source: URL, cancellation: HistoryCancellation, includeTools: Bool = false, progressModelDigest: String = "", progress: (SemanticCounts) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard url.resolvingSymlinksInPath().standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else { throw SemanticFailure("The source and search index must be separate files.") }
        try check(cancellation)
        // Validate the new source before replacing any previously usable derived scope.
        try HistoryStore.withDB(source,cancellation:cancellation) { original in
            let names = Set(try ChatStore.rows(original,"PRAGMA table_info(thread_items)").compactMap { $0["name"]?.string })
            guard Set(["thread_id","turn_id","item_id","rollout_ordinal","item_type","item_json"]).isSubset(of:names) else { throw SemanticFailure("Unsupported recorded history schema.") }
        }
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath:source.path)
        let indexAttributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard sourceAttributes[.systemNumber] as? NSNumber != indexAttributes[.systemNumber] as? NSNumber || sourceAttributes[.systemFileNumber] as? NSNumber != indexAttributes[.systemFileNumber] as? NSNumber else { throw SemanticFailure("Source and index refer to the same file.") }
        let unique = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
        let scope = source.resolvingSymlinksInPath().standardizedFileURL.path
        // Changing the selected source replaces only the derived active index; raw revisions survive.
        if try scalar("SELECT value FROM semantic_meta WHERE key='source'")?.string != scope {
            try transaction {
                try execute("DELETE FROM semantic_passages"); try execute("DELETE FROM semantic_records"); try execute("DELETE FROM semantic_chats"); try execute("DELETE FROM semantic_signatures")
                try execute("INSERT OR REPLACE INTO semantic_meta VALUES('source',?)", [.text(Data(scope.utf8))])
            }
        }
        // Explicit source metadata is the scope authority. Never traverse fork ancestry implicitly.
        let requested = Set(unique.map(\.id))
        let prior = try rows("SELECT id FROM semantic_chats").compactMap { $0["id"]?.string }
        try transaction {
            for id in prior where !requested.contains(id) {
                try execute("DELETE FROM semantic_records WHERE chat_id=?", [text(id)])
                try execute("DELETE FROM semantic_chats WHERE id=?", [text(id)])
                try execute("DELETE FROM semantic_signatures WHERE chat_id=?", [text(id)])
            }
        }
        var visited = 0, lastProgressVisit = 0
        var lastProgressAt = ProcessInfo.processInfo.systemUptime
        for chat in unique {
            try check(cancellation)
            let filesystem = try FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)
            if let free = filesystem[.systemFreeSize] as? NSNumber, free.int64Value < 1_073_741_824 {
                throw SemanticFailure("Index paused to preserve the last 1 GiB of free storage. Saved data remains available; free space and resume.")
            }
            try HistoryStore.withDB(source, cancellation: cancellation, timeout: 120) { original in
                let schema = try ChatStore.rows(original, "PRAGMA table_info(thread_items)")
                let columns = schema.compactMap { $0["name"]?.string }
                guard Set(["thread_id","turn_id","item_id","rollout_ordinal","item_type","item_json"]).isSubset(of: Set(columns)) else { throw SemanticFailure("Unsupported recorded history schema; search index remains resumable.") }
                let toolKinds = "'commandExecution','mcpToolCall','fileChange','collabAgentToolCall','functionCallOutput','dynamicToolCall','webSearch','functionCall','function_call','function_call_output','customToolCall','customToolCallOutput','custom_tool_call','custom_tool_call_output','toolCall','toolResult','mcpToolCallOutput'"
                // Filesystem metadata is cheap and also wakes a previously missing rollout fallback.
                let recordedFallbackPath = chat.original["rollout_path"]?.string
                let fallbackSignature = SemanticRolloutAdapter.signature(path:recordedFallbackPath)
                let kindFilter = "item_type IN ('userMessage','agentMessage'" + (includeTools ? "," + toolKinds : "") + ")"
                let sourceIdentity = "\(sourceAttributes[.systemNumber] as? NSNumber ?? 0)/\(sourceAttributes[.systemFileNumber] as? NSNumber ?? 0)"
                let priorSignature = try scalar("SELECT signature FROM semantic_signatures WHERE chat_id=?",[text(chat.id)])?.string
                let versioned = columns.contains("updated_at_ordinal")
                var canReuseCapturedRows = versioned && priorSignature?.contains(":" + sourceIdentity + ":") == true
                var signature: String?
                if versioned {
                    // This source explicitly versions edits in updated_at_ordinal. Count and ordinal
                    // sums also detect deletions/rebuilds. Schemas without it get full byte checks.
                    let summary = try ChatStore.rows(original,"SELECT count(*) AS n,max(updated_at_ordinal) AS revision,sum(updated_at_ordinal) AS revisions,sum(CASE WHEN typeof(updated_at_ordinal)='integer' AND updated_at_ordinal>=0 THEN 0 ELSE 1 END) AS invalid_versions FROM thread_items WHERE thread_id=?",bindings:[chat.id]).first ?? [:]
                    let schemaFingerprint = Self.hash(try JSONSerialization.data(withJSONObject:columns))
                    if (summary["invalid_versions"]?.number ?? 0) == 0 {
                        signature = "covering-v2:" + Self.hash(try Self.encodeMetadata(summary)) + ":" + sourceIdentity + ":" + schemaFingerprint + (includeTools ? "-tools" : "-messages") + ":" + fallbackSignature
                        if priorSignature == signature { return }
                    } else { canReuseCapturedRows = false }
                }
                // Only changed chats reach payload-sensitive type filtering. Stable chats return
                // from the covering updated_at_ordinal signature without touching record payloads.
                let ownMessageCount = try ChatStore.rows(original,"SELECT count(*) AS n FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage')",bindings:[chat.id]).first?["n"]?.number ?? 0
                let fallbackPath = ownMessageCount == 0 ? recordedFallbackPath : nil
                let metadataFields = columns.filter { $0 != "item_json" }.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
                let duplicateOrdinals = Set(try ChatStore.rows(original,"SELECT rollout_ordinal FROM thread_items WHERE thread_id=? AND \(kindFilter) GROUP BY rollout_ordinal HAVING count(*)>1",bindings:[chat.id]).compactMap { row -> Int64? in
                    if case .integer(let value)? = row["rollout_ordinal"] { return value }; return nil
                })
                let payloadSizeExpression = versioned ? "NULL" : "length(CAST(item_json AS BLOB))"
                let statement = try prepare(original, "SELECT rowid AS semantic_rowid,\(metadataFields),typeof(item_json) AS semantic_storage,\(payloadSizeExpression) AS semantic_bytes FROM thread_items WHERE thread_id=? AND \(kindFilter) ORDER BY rollout_ordinal,rowid", [text(chat.id)])
                defer { sqlite3_finalize(statement) }
                let generation = UUID().uuidString
                var questions: [String: String] = [:]
                try transaction {
                    var status = sqlite3_step(statement)
                    while status == SQLITE_ROW {
                        try check(cancellation)
                        try autoreleasepool {
                        let metadata = readRow(statement)
                        let rowID = metadata["semantic_rowid"]?.number.map(Int64.init) ?? -1
                        let rawKey = Self.hash(Data("\(scope)\u{0}\(chat.id)\u{0}\(metadata["turn_id"]?.string ?? "")\u{0}\(metadata["item_id"]?.string ?? "")\u{0}\(metadata["rollout_ordinal"]?.number ?? -1)\u{0}\(rowID)".utf8))
                        let metadataData = try Self.encodeMetadata(metadata.filter { !$0.key.hasPrefix("semantic_") })
                        let storage = metadata["semantic_storage"]?.string ?? "null"
                        let size = Int(metadata["semantic_bytes"]?.number ?? -1)
                        var reusable: [String:SQLiteValue]?
                        if canReuseCapturedRows, case .integer(let revision)? = metadata["updated_at_ordinal"], revision >= 0,
                           let candidate = try rows("SELECT r.body,r.role,r.phase,r.issue,v.metadata,v.payload_digest FROM semantic_records r JOIN semantic_revisions v ON v.record_key=r.record_key AND v.fingerprint=r.fingerprint WHERE r.record_key=?",[text(rawKey)]).first,
                           case .blob(let previousMetadata)? = candidate["metadata"], previousMetadata == metadataData { reusable = candidate }
                        let capture: (digest:String,bytes:Data?)
                        if let digest = reusable?["payload_digest"]?.string { capture = (digest,nil) }
                        else { capture = try capturePayload(original,rowID:rowID,storage:storage,size:size,cancellation:cancellation) }
                        let fingerprint = Self.hash(metadataData + Data(capture.digest.utf8))
                        let turn = metadata["turn_id"]?.string ?? ""
                        let item = metadata["item_id"]?.string ?? ""
                        let kind = metadata["item_type"]?.string ?? ""
                        let ordinal: Int64
                        if case .integer(let value)? = metadata["rollout_ordinal"] { ordinal = value } else { ordinal = -1 }
                        var body = "", role = "", phase = "", issue: String?
                        let cached = try reusable ?? rows("SELECT body,role,phase,issue FROM semantic_records WHERE record_key=? AND fingerprint=?", [text(rawKey),text(fingerprint)]).first
                        if let cached {
                            body = cached["body"]?.string ?? ""; role = cached["role"]?.string ?? ""; phase = cached["phase"]?.string ?? ""; issue = cached["issue"]?.string
                            if issue?.hasPrefix("Ambiguous duplicate source ordinal") == true { issue = nil }
                        } else if storage != "text" {
                            issue = "Payload storage is \(storage); original typed value retained, text not indexed."
                        } else if capture.bytes == nil {
                            issue = "Payload exceeds 64 MiB decoding limit; complete raw bytes retained, text not indexed."
                        } else if let bytes = capture.bytes, let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                            (body,role,phase,issue) = Self.extract(object, kind: kind)
                        } else { issue = "Malformed or partial JSON; complete original bytes retained, text not indexed." }
                        if duplicateOrdinals.contains(ordinal) { issue = "Ambiguous duplicate source ordinal; all raw copies retained, text not indexed because source navigation cannot distinguish them." }
                        if ordinal < 0 || item.isEmpty || turn.isEmpty { issue = "Malformed message identity or missing turn; original row retained, text not indexed." }
                        try execute("INSERT OR IGNORE INTO semantic_revisions VALUES(?,?,?,?,?,?,?,?)", [text(rawKey),text(fingerprint),.blob(metadataData),text(capture.digest),text(storage),issue.map(text) ?? .null,text(scope),.real(Date().timeIntervalSince1970)])
                        try execute("INSERT INTO semantic_records VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(record_key) DO UPDATE SET fingerprint=excluded.fingerprint,body=excluded.body,role=excluded.role,phase=excluded.phase,issue=excluded.issue,generation=excluded.generation", [text(rawKey),text(chat.id),text(fingerprint),text(body),text(role),text(phase),issue.map(text) ?? .null,text(generation)])
                        var active = Set<String>()
                        if issue == nil && !body.isEmpty {
                            if role == "USER" { questions[turn] = SemanticChunker.questionContext(body) }
                            let contextQuestion = role == "USER" ? nil : questions[turn]
                            for (index, piece) in SemanticChunker.chunks(body).enumerated() {
                                let id = Self.hash(Data("\(rawKey)\u{0}\(index)".utf8)); active.insert(id)
                                let context = SemanticChunker.context(question: contextQuestion, role: role, text: piece)
                                let digest = Self.hash(Data("chunk-v1\u{0}\(fingerprint)\u{0}\(context)".utf8))
                                let date = metadata["created_at_ms"]?.number.flatMap { $0.isFinite && abs($0) < 253_402_300_799_000 ? $0 / 1000 : nil }
                                let passage = SemanticPassage(id: id, chatID: chat.id, itemID: item, turnID: turn, ordinal: ordinal, role: role, phase: phase, text: piece, context: context, createdAt: date, sourceDigest: digest, sourcePath:scope)
                                if try scalar("SELECT digest FROM semantic_passages WHERE id=?", [text(id)])?.string != digest {
                                    try execute("DELETE FROM semantic_vectors WHERE passage_id=?", [text(id)])
                                    let encoded = try JSONEncoder().encode(passage)
                                    try execute("INSERT INTO semantic_passages VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET role=excluded.role,phase=excluded.phase,digest=excluded.digest,payload=excluded.payload,search_text=excluded.search_text", [text(id),text(rawKey),text(chat.id),text(role),text(phase),text(digest),.blob(encoded),text(piece)])
                                }
                            }
                        }
                        for old in try rows("SELECT id FROM semantic_passages WHERE record_key=?", [text(rawKey)]).compactMap({ $0["id"]?.string }) where !active.contains(old) { try execute("DELETE FROM semantic_passages WHERE id=?", [text(old)]) }
                        } // Release Foundation JSON temporaries before processing the next record.
                        status = sqlite3_step(statement)
                    }
                    guard status == SQLITE_DONE else { throw failure(original) }
                    var fallbackMessages = 0
                    if ownMessageCount == 0 {
                        fallbackMessages = try importRollout(chat:chat,path:fallbackPath,generation:generation,cancellation:cancellation)
                    }
                    try execute("DELETE FROM semantic_records WHERE chat_id=? AND generation<>?", [text(chat.id),text(generation)])
                    try execute("INSERT INTO semantic_chats VALUES(?,?) ON CONFLICT(id) DO UPDATE SET missing=excluded.missing", [text(chat.id),.integer(ownMessageCount > 0 || fallbackMessages > 0 ? 0 : 1)])
                    if let signature { try execute("INSERT OR REPLACE INTO semantic_signatures VALUES(?,?)",[text(chat.id),text(signature)]) }
                    else { try execute("DELETE FROM semantic_signatures WHERE chat_id=?",[text(chat.id)]) }
                }
            }
            visited += 1
            let now = ProcessInfo.processInfo.systemUptime
            if visited == 1 || now - lastProgressAt >= 0.5 {
                progress(try counts(modelDigest:progressModelDigest)); lastProgressAt = now; lastProgressVisit = visited
            }
        }
        if visited != lastProgressVisit || visited == 0 { progress(try counts(modelDigest:progressModelDigest)) }
    }

    /// Called inside the chat transaction. A failed verification/read rolls back every fallback
    /// record before writing a separate, explicit unavailable-coverage status.
    private func importRollout(chat: Chat, path: String?, generation: String, cancellation: HistoryCancellation) throws -> Int {
        guard let path, path.hasPrefix("/"), FileManager.default.fileExists(atPath:path) else { return 0 }
        let source = URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL
        var questions = [String:String]()
        try execute("SAVEPOINT semantic_fallback")
        do {
            let summary = try SemanticRolloutAdapter.scan(chatID:chat.id,source:source,cancellation:cancellation) { record in
                let rawKey = Self.hash(Data("rollout-v1\u{0}\(source.path)\u{0}\(chat.id)\u{0}\(record.offset)".utf8))
                let payloadDigest = Self.hash(record.raw)
                let metadataData = try JSONSerialization.data(withJSONObject:["source_kind":"rollout-jsonl","source_path":source.path,"chat_id":chat.id,"byte_offset":record.offset,"byte_count":record.raw.count,"record_ordinal":record.ordinal],options:[.sortedKeys])
                let fingerprint = Self.hash(metadataData + Data(payloadDigest.utf8))
                var offset = 0, part = 0
                repeat {
                    let end = min(offset + 65_536,record.raw.count)
                    try execute("INSERT OR IGNORE INTO semantic_raw VALUES(?,?,?)",[text(payloadDigest),.integer(Int64(part)),.blob(Data(record.raw[offset..<end]))])
                    offset = end; part += 1
                } while offset < record.raw.count
                try execute("INSERT OR IGNORE INTO semantic_revisions VALUES(?,?,?,?,?,?,?,?)",[text(rawKey),text(fingerprint),.blob(metadataData),text(payloadDigest),text("jsonl-record"),record.issue.map(text) ?? .null,text(source.path),.real(Date().timeIntervalSince1970)])
                try execute("INSERT INTO semantic_records VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(record_key) DO UPDATE SET fingerprint=excluded.fingerprint,body=excluded.body,role=excluded.role,phase=excluded.phase,issue=excluded.issue,generation=excluded.generation",[text(rawKey),text(chat.id),text(fingerprint),text(record.body),text(record.role),text(record.phase),record.issue.map(text) ?? .null,text(generation)])
                var active = Set<String>()
                if record.issue == nil, !record.body.isEmpty, record.role == "USER" || record.role == "ASSISTANT" {
                    if record.role == "USER", !record.turnID.isEmpty { questions[record.turnID] = SemanticChunker.questionContext(record.body) }
                    for (index,piece) in SemanticChunker.chunks(record.body).enumerated() {
                        let id = Self.hash(Data("\(rawKey)\u{0}\(index)".utf8)); active.insert(id)
                        let question = record.turnID.isEmpty ? nil : questions[record.turnID]
                        let context = SemanticChunker.context(question:question,role:record.role,text:piece)
                        let digest = Self.hash(Data("chunk-v1\u{0}\(fingerprint)\u{0}\(context)".utf8))
                        let passage = SemanticPassage(id:id,chatID:chat.id,itemID:"rollout:\(record.offset)",turnID:record.turnID,ordinal:record.ordinal,role:record.role,phase:record.phase,text:piece,context:context,createdAt:record.createdAt,sourceDigest:digest,sourcePath:source.path)
                        if try scalar("SELECT digest FROM semantic_passages WHERE id=?",[text(id)])?.string != digest {
                            try execute("DELETE FROM semantic_vectors WHERE passage_id=?",[text(id)])
                            try execute("INSERT INTO semantic_passages VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET role=excluded.role,phase=excluded.phase,digest=excluded.digest,payload=excluded.payload,search_text=excluded.search_text",[text(id),text(rawKey),text(chat.id),text(record.role),text(record.phase),text(digest),.blob(try JSONEncoder().encode(passage)),text(piece)])
                        }
                    }
                }
                for old in try rows("SELECT id FROM semantic_passages WHERE record_key=?",[text(rawKey)]).compactMap({ $0["id"]?.string }) where !active.contains(old) { try execute("DELETE FROM semantic_passages WHERE id=?",[text(old)]) }
            }
            try execute("RELEASE semantic_fallback")
            return summary.messages
        } catch {
            try execute("ROLLBACK TO semantic_fallback"); try execute("RELEASE semantic_fallback")
            try check(cancellation)
            let key = Self.hash(Data("rollout-unavailable\u{0}\(chat.id)\u{0}\(source.path)".utf8))
            try execute("INSERT INTO semantic_records VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(record_key) DO UPDATE SET issue=excluded.issue,generation=excluded.generation",[text(key),text(chat.id),text("unavailable"),text(""),text("UNAVAILABLE"),text(""),text(error.localizedDescription),text(generation)])
            return 0
        }
    }

    func counts(modelDigest: String) throws -> SemanticCounts {
        lock.lock(); defer { lock.unlock() }
        func count(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int { Int(try scalar(sql, bindings)?.number ?? 0) }
        return try SemanticCounts(chats: count("SELECT count(*) FROM semantic_chats"), messages: count("SELECT count(*) FROM semantic_records WHERE role IN ('USER','ASSISTANT')"), passages: count("SELECT count(*) FROM semantic_passages"), embedded: count("SELECT count(*) FROM semantic_vectors v JOIN semantic_passages p ON p.id=v.passage_id AND p.digest=v.source_digest WHERE v.model_digest=?", [text(modelDigest)]), skipped: count("SELECT count(*) FROM semantic_records WHERE issue IS NOT NULL"), missing: count("SELECT count(*) FROM semantic_chats WHERE missing=1"))
    }

    func pending(limit: Int, modelDigest: String) throws -> [SemanticPassage] {
        lock.lock(); defer { lock.unlock() }
        return try rows("SELECT p.payload FROM semantic_passages p LEFT JOIN semantic_vectors v ON p.id=v.passage_id AND p.digest=v.source_digest AND v.model_digest=? WHERE v.passage_id IS NULL ORDER BY p.chat_id,p.id LIMIT ?", [text(modelDigest),.integer(Int64(max(1,min(128,limit))))]).map(decode)
    }

    func saveEmbeddings(passages: [SemanticPassage], vectors: [[Float]], modelDigest: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !modelDigest.isEmpty, passages.count == vectors.count else { throw SemanticFailure("Embedding response count or model identity is invalid.") }
        let normalized = try vectors.map(Self.normalized)
        try transaction {
            for (passage, vector) in zip(passages, normalized) {
                guard try scalar("SELECT digest FROM semantic_passages WHERE id=?", [text(passage.id)])?.string == passage.sourceDigest else { continue } // Superseded input never attaches to a newer passage.
                let bytes = vector.withUnsafeBytes { Data($0) }
                try execute("INSERT OR REPLACE INTO semantic_vectors VALUES(?,?,?,?)", [text(passage.id),text(modelDigest),text(passage.sourceDigest),.blob(bytes)])
            }
        }
    }

    func search(query: String, vector: [Float]?, mode: SemanticSearchMode, filters: SemanticFilters, modelDigest: String, limit: Int, cancellation: HistoryCancellation) throws -> [SemanticHit] {
        lock.lock(); defer { lock.unlock() }
        try check(cancellation)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else { return [] }
        let size = min(500,limit), shortlist = max(100,min(1_000,limit * 4))
        var predicate = filters.includeTools ? "1" : "p.role IN ('USER','ASSISTANT')"
        if filters.finalOnly { predicate += " AND (p.role='USER' OR (p.role='ASSISTANT' AND p.phase IN ('final_answer','final')))" }
        var lexical = [SemanticHit](), dense = [SemanticHit]()
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let quoted = term.count >= 2 && term.first == "\"" && term.last == "\""
        let identifier = !term.contains(where: { $0.isWhitespace }) && term.rangeOfCharacter(from:CharacterSet(charactersIn:"_./:-%")) != nil
        if mode == .exact && (quoted || identifier) {
            let literal = quoted ? String(term.dropFirst().dropLast()) : term
            guard !literal.isEmpty else { return [] }
            // instr is literal: SQL LIKE wildcards, FTS operators and punctuation retain their
            // recorded meaning here. Combined mode deliberately keeps the BM25 baseline below.
            let statement = try prepare(db,"SELECT p.payload FROM semantic_passages p WHERE instr(lower(p.search_text),lower(?))>0 AND \(predicate) ORDER BY p.chat_id,p.id LIMIT ?",[text(literal),.integer(Int64(size))])
            defer { sqlite3_finalize(statement) }
            var state = sqlite3_step(statement)
            while state == SQLITE_ROW { try check(cancellation); lexical.append(SemanticHit(passage:try decode(readRow(statement)),score:1)); state = sqlite3_step(statement) }
            guard state == SQLITE_DONE else { throw failure(db) }
            return lexical
        }
        if mode != .meaning {
            let words = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let tokens = Array(NSOrderedSet(array: Array(words.prefix(64))).array.compactMap { $0 as? String })
            if !tokens.isEmpty {
                let match = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
                let statement = try prepare(db, "SELECT p.payload,bm25(semantic_fts) AS score FROM semantic_fts JOIN semantic_passages p ON p.id=semantic_fts.id WHERE semantic_fts MATCH ? AND \(predicate) ORDER BY bm25(semantic_fts),p.id LIMIT ?", [text(match),.integer(Int64(shortlist))])
                defer { sqlite3_finalize(statement) }
                var state = sqlite3_step(statement)
                while state == SQLITE_ROW { try check(cancellation); let row = readRow(statement); lexical.append(SemanticHit(passage: try decode(row), score: -(row["score"]?.number ?? 0))); state = sqlite3_step(statement) }
                guard state == SQLITE_DONE else { throw failure(db) }
            }
        }
        if mode != .exact, let vector {
            let queryVector = try Self.normalized(vector)
            let statement = try prepare(db, "SELECT p.payload,v.vector FROM semantic_vectors v JOIN semantic_passages p ON p.id=v.passage_id AND p.digest=v.source_digest WHERE v.model_digest=? AND \(predicate)", [text(modelDigest)])
            defer { sqlite3_finalize(statement) }
            var state = sqlite3_step(statement)
            while state == SQLITE_ROW {
                try check(cancellation)
                guard sqlite3_column_bytes(statement,1) == Self.dimensions * MemoryLayout<Float>.size, let base = sqlite3_column_blob(statement,1) else { throw SemanticFailure("A stored embedding has invalid dimensions; rebuild this index.") }
                // SQLite's blob alignment is unspecified; copy one vector, never the whole matrix.
                var stored = [Float](repeating: 0,count: Self.dimensions)
                stored.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start:base,count:Self.dimensions * 4)) }
                var score: Float = 0
                vDSP_dotpr(queryVector,1,stored,1,&score,vDSP_Length(Self.dimensions))
                guard score.isFinite else { throw SemanticFailure("A stored embedding contains invalid values.") }
                if dense.count < shortlist || Double(score) > dense.last!.score {
                    let hit = SemanticHit(passage: try decode(readRow(statement)),score:Double(score))
                    let insertion = dense.firstIndex { $0.score < hit.score || ($0.score == hit.score && $0.passage.id > hit.passage.id) } ?? dense.endIndex
                    dense.insert(hit,at:insertion); if dense.count > shortlist { dense.removeLast() }
                }
                state = sqlite3_step(statement)
            }
            guard state == SQLITE_DONE else { throw failure(db) }
        }
        if mode == .exact { return Array(lexical.prefix(size)) }
        if mode == .meaning { return Array(dense.prefix(size)) }
        var fused = [String: SemanticHit]()
        for ranking in [lexical,dense] {
            for (rank, hit) in ranking.enumerated() {
                let contribution = 1 / Double(60 + rank + 1)
                if var existing = fused[hit.passage.id] { existing.score += contribution; fused[hit.passage.id] = existing }
                else { fused[hit.passage.id] = SemanticHit(passage:hit.passage,score:contribution) }
            }
        }
        return Array(fused.values.sorted { $0.score == $1.score ? $0.passage.id < $1.passage.id : $0.score > $1.score }.prefix(size))
    }

    func rawPayload(for passage: SemanticPassage) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let row = try rows("SELECT r.record_key,r.fingerprint FROM semantic_records r JOIN semantic_passages p ON p.record_key=r.record_key WHERE p.id=? AND p.digest=?", [text(passage.id),text(passage.sourceDigest)]).first,
              let key = row["record_key"]?.string, let fingerprint = row["fingerprint"]?.string else { throw SemanticFailure("This search passage has been superseded; search again to inspect its current captured source.") }
        return try capturedPayload(recordKey:key,fingerprint:fingerprint)
    }

    /// Exact captured payload bytes remain available even after originals change or disappear.
    func capturedPayload(recordKey: String, fingerprint: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let digest = try scalar("SELECT payload_digest FROM semantic_revisions WHERE record_key=? AND fingerprint=?", [text(recordKey),text(fingerprint)])?.string else { throw SemanticFailure("Captured source revision is unavailable.") }
        let byteCount = try scalar("SELECT sum(length(bytes)) FROM semantic_raw WHERE digest=?",[text(digest)])?.number ?? 0
        guard byteCount <= Double(Self.maximumDecodedPayloadBytes) else { throw SemanticFailure("Captured payload exceeds the 64 MiB in-memory viewing limit; raw chunk bytes remain preserved.") }
        var result = Data()
        for row in try rows("SELECT bytes FROM semantic_raw WHERE digest=? ORDER BY part", [text(digest)]) { if case .blob(let data)? = row["bytes"] { result.append(data) } }
        return result
    }

    private func capturePayload(_ original: OpaquePointer, rowID: Int64, storage: String, size expectedSize: Int, cancellation: HistoryCancellation) throws -> (digest: String, bytes: Data?) {
        guard storage == "text" || storage == "blob" else {
            let row = try ChatStore.rows(original,"SELECT item_json FROM thread_items WHERE rowid=\(rowID)").first ?? [:]
            let data = try Self.encodeMetadata(row)
            let digest = Self.hash(data)
            try execute("INSERT OR IGNORE INTO semantic_raw VALUES(?,0,?)", [text(digest),.blob(data)])
            return (digest,nil)
        }
        var pointer: OpaquePointer?
        guard sqlite3_blob_open(original,"main","thread_items","item_json",rowID,0,&pointer) == SQLITE_OK, let blob = pointer else { throw failure(original) }
        defer { sqlite3_blob_close(blob) }
        let size = Int(sqlite3_blob_bytes(blob))
        guard expectedSize < 0 || size == expectedSize else { throw SemanticFailure("Source payload changed during a read transaction.") }
        var hash = SHA256(), decoded: Data? = size <= Self.maximumDecodedPayloadBytes ? Data() : nil
        var offset = 0, part = 0
        // Temporary key keeps the full payload stream off the heap; renamed to its checksum afterward.
        let temporary = "pending-" + UUID().uuidString
        repeat {
            try check(cancellation)
            let count = min(65_536,size-offset)
            var chunk = Data(count:count)
            if count > 0 { guard chunk.withUnsafeMutableBytes({ sqlite3_blob_read(blob,$0.baseAddress,Int32(count),Int32(offset)) }) == SQLITE_OK else { throw failure(original) } }
            hash.update(data:chunk); decoded?.append(chunk)
            try execute("INSERT INTO semantic_raw VALUES(?,?,?)", [text(temporary),.integer(Int64(part)),.blob(chunk)])
            offset += count; part += 1
        } while offset < size
        let digest = hash.finalize().map { String(format:"%02x",$0) }.joined()
        try execute("INSERT OR IGNORE INTO semantic_raw SELECT ?,part,bytes FROM semantic_raw WHERE digest=?", [text(digest),text(temporary)])
        try execute("DELETE FROM semantic_raw WHERE digest=?", [text(temporary)])
        return (digest,decoded)
    }

    private static func extract(_ object: [String:Any], kind: String) -> (String,String,String,String?) {
        if kind == "userMessage" {
            if let text = object["text"] as? String { return (text,"USER","",nil) }
            if let content = object["content"] as? [[String:Any]] {
                let texts = content.compactMap { $0["text"] as? String }
                return (texts.joined(separator:"\n"),"USER","",texts.isEmpty ? "Attachment-only message has no searchable text; original payload retained." : nil)
            }
            return ("","USER","","No recognized user text; original attachment/payload retained.")
        }
        if kind == "agentMessage" {
            let phase = object["phase"] as? String ?? object["channel"] as? String ?? "unknown"
            if let text = object["text"] as? String { return (text,"ASSISTANT",phase,nil) }
            if let content = object["content"] as? [[String:Any]] {
                let texts = content.compactMap { $0["text"] as? String }
                return (texts.joined(separator:"\n"),"ASSISTANT",phase,texts.isEmpty ? "Assistant payload has no searchable text; original payload retained." : nil)
            }
            return ("","ASSISTANT",phase,"No recognized assistant text; original payload retained.")
        }
        let tools: Set<String> = ["functionCall","functionCallOutput","function_call","function_call_output","customToolCall","customToolCallOutput","custom_tool_call","custom_tool_call_output","commandExecution","fileChange","collabAgentToolCall","dynamicToolCall","webSearch","toolCall","toolResult","mcpToolCall","mcpToolCallOutput"]
        if tools.contains(kind) {
            // Tool records are data, never executed. Include all recorded fields rather than guessing
            // one provider's output shape, so nested structured results remain searchable.
            let bytes = (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.fragmentsAllowed])) ?? Data()
            return (String(data:bytes,encoding:.utf8) ?? "","TOOL","tool",nil)
        }
        return ("","UNKNOWN","","Unsupported recorded item type '\(kind)'; raw payload retained, text not indexed.")
    }

    private static func normalized(_ vector: [Float]) throws -> [Float] {
        guard vector.count == dimensions, vector.allSatisfy(\.isFinite) else { throw SemanticFailure("Embedding must contain exactly 4,096 finite coordinates.") }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-12 else { throw SemanticFailure("Embedding has zero or invalid magnitude.") }
        return vector.map { Float(Double($0)/norm) }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func encodeMetadata(_ row: [String:SQLiteValue]) throws -> Data {
        let values = row.mapValues { value -> [String:String] in
            switch value {
            case .null: return ["storage":"null"]
            case .integer(let n): return ["storage":"integer","value":String(n)]
            case .real(let n): return ["storage":"real","value":String(n)]
            case .text(let bytes): return ["storage":"text","base64":bytes.base64EncodedString()]
            case .blob(let bytes): return ["storage":"blob","base64":bytes.base64EncodedString()]
            }
        }
        return try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys])
    }
    private func decode(_ row: [String:SQLiteValue]) throws -> SemanticPassage {
        guard case .blob(let bytes)? = row["payload"] else { throw SemanticFailure("Malformed passage in the local search index.") }
        return try JSONDecoder().decode(SemanticPassage.self,from:bytes)
    }
    private func check(_ cancellation: HistoryCancellation) throws { if cancellation.cancelled { throw SemanticFailure("Semantic search cancelled.") } }
    private func text(_ value: String) -> SQLiteValue { .text(Data(value.utf8)) }
    private func failure(_ connection: OpaquePointer?) -> SemanticFailure { SemanticFailure("Local semantic index: \(String(cString:sqlite3_errmsg(connection)))") }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteValue? { try rows(sql,bindings).first?.values.first }
    private func rows(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[String:SQLiteValue]] {
        let statement = try prepare(db,sql,bindings); defer { sqlite3_finalize(statement) }
        var result = [[String:SQLiteValue]](), state = sqlite3_step(statement)
        while state == SQLITE_ROW { result.append(readRow(statement)); state = sqlite3_step(statement) }
        guard state == SQLITE_DONE else { throw failure(db) }; return result
    }
    private func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(db,sql,bindings); defer { sqlite3_finalize(statement) }
        let state = sqlite3_step(statement)
        guard state == SQLITE_DONE || state == SQLITE_ROW else { throw failure(db) }
    }
    private func prepare(_ connection: OpaquePointer, _ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw failure(connection) }
        do {
            for (offset,value) in bindings.enumerated() {
                let index = Int32(offset+1), code: Int32
                switch value {
                case .null: code = sqlite3_bind_null(statement,index)
                case .integer(let n): code = sqlite3_bind_int64(statement,index,n)
                case .real(let n): code = sqlite3_bind_double(statement,index,n)
                case .text(let bytes): code = bytes.withUnsafeBytes { sqlite3_bind_text(statement,index,$0.baseAddress?.assumingMemoryBound(to:CChar.self) ?? UnsafePointer<CChar>(bitPattern:1),Int32(bytes.count),transient) }
                case .blob(let bytes): code = bytes.withUnsafeBytes { sqlite3_bind_blob(statement,index,$0.baseAddress ?? UnsafeRawPointer(bitPattern:1),Int32(bytes.count),transient) }
                }
                guard code == SQLITE_OK else { throw failure(connection) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func readRow(_ statement: OpaquePointer) -> [String:SQLiteValue] {
        var row = [String:SQLiteValue]()
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString:sqlite3_column_name(statement,index))
            switch sqlite3_column_type(statement,index) {
            case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement,index))
            case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement,index))
            case SQLITE_TEXT,SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement,index))
                let bytes = sqlite3_column_blob(statement,index).map { Data(bytes:$0,count:count) } ?? Data()
                row[name] = sqlite3_column_type(statement,index) == SQLITE_TEXT ? .text(bytes) : .blob(bytes)
            default: row[name] = .null
            }
        }
        return row
    }
}
