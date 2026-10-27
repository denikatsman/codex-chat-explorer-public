import XCTest
import CSQLite
@testable import CodexChats

final class SemanticIndexTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var db: OpaquePointer?
    private var index: SemanticIndexStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-fixture-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        source = root.appendingPathComponent("source.sqlite")
        XCTAssertEqual(sqlite3_open(source.path,&db),SQLITE_OK)
        try sql("CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT,future_field BLOB)")
        try sql("CREATE INDEX source_thread ON thread_items(thread_id,rollout_ordinal)")
        index = try SemanticIndexStore(url:root.appendingPathComponent("owned/index.sqlite"))
    }
    override func tearDownWithError() throws {
        index = nil; sqlite3_close(db); db = nil
        try FileManager.default.removeItem(at:root)
    }
    private func sql(_ value: String) throws { guard sqlite3_exec(db,value,nil,nil,nil) == SQLITE_OK else { throw StoreError(message:String(cString:sqlite3_errmsg(db))) } }
    private func chat(_ id: String) -> Chat { Chat(original:[:],id:id,title:"Fixture \(id)",createdAt:nil,archived:id == "b",issues:[],project:ProjectReference(identity:.noProject,name:"No project",originalAssignment:nil,originalProject:nil)) }
    @discardableResult private func insert(_ text: String, chat: String = "a", turn: String = "turn", ordinal: Int = 1, type: String = "userMessage", phase: String? = nil, raw: Data? = nil, item: String? = nil) throws -> Data {
        var object: [String:Any] = ["type":type,"text":text]
        if let phase { object["phase"] = phase }
        let bytes = try raw ?? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        let hex = bytes.map { String(format:"%02x",$0) }.joined()
        try sql("INSERT INTO thread_items(thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_type,item_json,future_field) VALUES('\(chat)','\(turn)','\(item ?? "item-\(ordinal)")',\(ordinal),\(ordinal * 1000),'\(type)',CAST(X'\(hex)' AS TEXT),X'0001FF')")
        return bytes
    }
    private func ingest(_ ids: [String] = ["a"], tools: Bool = false, token: HistoryCancellation = HistoryCancellation()) throws { try index.importSources(chats:ids.map(chat),source:source,cancellation:token,includeTools:tools,progress:{ _ in }) }
    private func hits(_ query: String, mode: SemanticSearchMode = .exact, vector: [Float]? = nil, filters: SemanticFilters = SemanticFilters()) throws -> [SemanticHit] { try index.search(query:query,vector:vector,mode:mode,filters:filters,modelDigest:"fixture",limit:100,cancellation:HistoryCancellation()) }
    private func unit(_ axis: Int = 0) -> [Float] { var result = [Float](repeating:0,count:4_096); result[axis] = 1; return result }

    func testReadOnlyCaptureExactBytesIdentityDuplicatesAndArchives() throws {
        let raw = try insert("Unicode candle 🍀 café 含义")
        try insert("Unicode candle 🍀 café 含义",ordinal:2)
        try insert("Unicode candle 🍀 café 含义",chat:"b")
        let before = try Data(contentsOf:source)
        try ingest(["a","b","a","missing"])
        let found = try hits("candle")
        XCTAssertEqual(found.count,3); XCTAssertEqual(Set(found.map(\.passage.id)).count,3)
        XCTAssertEqual(Set(found.map(\.passage.chatID)),["a","b"])
        XCTAssertEqual(try index.rawPayload(for:found[0].passage),raw)
        XCTAssertEqual(try Data(contentsOf:source),before)
        let counts = try index.counts(modelDigest:"fixture")
        XCTAssertEqual(counts.chats,3); XCTAssertEqual(counts.messages,3); XCTAssertEqual(counts.missing,1)
        try ingest(["a","b","missing"])
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,3)
        XCTAssertEqual(Set(try hits("candle").map(\.passage.id)),Set(found.map(\.passage.id)))
    }

    func testChangedQuestionInvalidatesDependentContextWithoutCrossChatTurnLeak() throws {
        try insert("Explain semantic fields",ordinal:1)
        try insert("It depends on surrounding relationships",ordinal:2,type:"agentMessage",phase:"final_answer")
        try insert("Other independent answer",chat:"b",ordinal:1,type:"agentMessage",phase:"final_answer")
        try insert("New turn has no question",turn:"other",ordinal:3,type:"agentMessage",phase:"commentary")
        try ingest(["a","b"])
        let passages = try index.pending(limit:100,modelDigest:"fixture")
        XCTAssertEqual(passages.count,4)
        let answer = try XCTUnwrap(passages.first { $0.itemID == "item-2" })
        XCTAssertTrue(answer.context.contains("Explain semantic fields"))
        XCTAssertFalse(try XCTUnwrap(passages.first { $0.chatID == "b" }).context.contains("Explain semantic fields"))
        XCTAssertFalse(try XCTUnwrap(passages.first { $0.turnID == "other" }).context.contains("Explain semantic fields"))
        try index.saveEmbeddings(passages:passages,vectors:passages.map { _ in unit() },modelDigest:"fixture")
        XCTAssertEqual(try index.counts(modelDigest:"fixture").embedded,4)
        try sql("UPDATE thread_items SET item_json='{\"text\":\"Explain liquidity pools\"}' WHERE thread_id='a' AND item_id='item-1'")
        try ingest(["a","b"])
        let changed = try index.pending(limit:100,modelDigest:"fixture")
        XCTAssertEqual(changed.count,2)
        let revised = try XCTUnwrap(changed.first { $0.itemID == "item-2" })
        XCTAssertEqual(revised.id,answer.id); XCTAssertNotEqual(revised.sourceDigest,answer.sourceDigest)
        XCTAssertTrue(revised.context.contains("liquidity pools"))
        try index.saveEmbeddings(passages:[answer],vectors:[unit()],modelDigest:"fixture")
        XCTAssertEqual(try index.counts(modelDigest:"fixture").embedded,2)
        XCTAssertThrowsError(try index.rawPayload(for:answer))
    }

    func testToolOptInFinalFilterAndUnknownMalformedCoverage() throws {
        try insert("Ordinary source",ordinal:1)
        try insert("Final source",ordinal:2,type:"agentMessage",phase:"final_answer")
        try insert("Progress source",ordinal:3,type:"agentMessage",phase:"commentary")
        let tool = try JSONSerialization.data(withJSONObject:["type":"mcpToolCall","arguments":["query":"buried_tool_identifier"],"result":["content":[["text":"Full tool result source"]]]])
        try insert("",ordinal:4,type:"mcpToolCall",raw:tool)
        try insert("",ordinal:5,raw:Data("{unfinished".utf8))
        try insert("",ordinal:6,raw:Data([0xff,0xfe]))
        try insert("Internal opaque",ordinal:7,type:"reasoning")
        try insert("Compaction replacement",ordinal:8,type:"contextCompaction")
        try ingest()
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,3)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").skipped,2)
        XCTAssertEqual(try hits("source",filters:SemanticFilters(includeTools:false,finalOnly:true)).count,2)
        XCTAssertTrue(try hits("buried_tool_identifier",filters:SemanticFilters(includeTools:true)).isEmpty)
        try ingest(tools:true)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,4)
        XCTAssertTrue(try hits("buried_tool_identifier").isEmpty)
        let toolResults = try hits("buried_tool_identifier",filters:SemanticFilters(includeTools:true))
        XCTAssertEqual(toolResults.count,1); XCTAssertEqual(toolResults[0].passage.role,"TOOL")
        XCTAssertEqual(try index.rawPayload(for:toolResults[0].passage),tool)
        XCTAssertFalse(try hits("source",filters:SemanticFilters(includeTools:true,finalOnly:true)).contains { $0.passage.isTool })
    }

    func testDenseRankingHybridFusingModelIsolationAndInvalidVectorsAreAtomic() throws {
        try insert("Candles semantic anchor",ordinal:1)
        try insert("Cache exact identifier cache_exact_identifier",ordinal:2)
        try insert("Unrelated ordinary paragraph",ordinal:3)
        try ingest()
        let p = try index.pending(limit:100,modelDigest:"fixture")
        let vectors = p.map { $0.itemID == "item-1" ? unit(0) : unit(1) }
        XCTAssertThrowsError(try index.saveEmbeddings(passages:p,vectors:[unit()],modelDigest:"fixture"))
        XCTAssertThrowsError(try index.saveEmbeddings(passages:p,vectors:p.map { _ in [Float](repeating:0,count:4_096) },modelDigest:"fixture"))
        var bad = unit(); bad[0] = .nan
        XCTAssertThrowsError(try index.saveEmbeddings(passages:p,vectors:[bad,unit(),unit()],modelDigest:"fixture"))
        XCTAssertEqual(try index.counts(modelDigest:"fixture").embedded,0)
        try index.saveEmbeddings(passages:p,vectors:vectors,modelDigest:"fixture")
        XCTAssertEqual(try hits("An unseen paraphrase",mode:.meaning,vector:unit()).first?.passage.itemID,"item-1")
        let hybrid = try hits("Cache",mode:.combined,vector:unit())
        XCTAssertEqual(hybrid.first?.passage.itemID,"item-2") // Appears in both rankings.
        XCTAssertEqual(try hits("Cache").first?.passage.itemID,"item-2")
        XCTAssertTrue(try index.pending(limit:100,modelDigest:"fixture").isEmpty)
        XCTAssertEqual(try index.pending(limit:100,modelDigest:"other").count,3)
        XCTAssertThrowsError(try hits("x",mode:.meaning,vector:[1]))
        XCTAssertTrue(try hits("\" OR NEAR(*) : / - [ ]").isEmpty)
        XCTAssertFalse(try hits("cache_exact_identifier").isEmpty)
    }

    func testDeletionScopeChangesCancellationAndPayloadsBeyondPreviewCap() throws {
        let large = String(repeating:"Long original café 🧠 paragraph.\n",count:40_000)
        let raw = try insert(large,ordinal:1)
        XCTAssertGreaterThan(raw.count,1_048_576)
        try insert("Second independent source",ordinal:2)
        try insert("Outside scope",chat:"b")
        let before = try Data(contentsOf:source)
        try ingest(["a","b"])
        let found = try XCTUnwrap(hits("café").first)
        XCTAssertEqual(try index.rawPayload(for:found.passage),raw)
        XCTAssertGreaterThan(try index.counts(modelDigest:"fixture").passages,100)
        try sql("DELETE FROM thread_items WHERE item_id='item-1' AND thread_id='a'")
        try ingest(["a"])
        XCTAssertTrue(try hits("café").isEmpty); XCTAssertTrue(try hits("Outside").isEmpty)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,1)
        let token = HistoryCancellation(); token.cancel()
        XCTAssertThrowsError(try ingest(token:token))
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,1)
        XCTAssertThrowsError(try index.search(query:"source",vector:nil,mode:.exact,filters:SemanticFilters(),modelDigest:"fixture",limit:10,cancellation:token))
        XCTAssertNotEqual(try Data(contentsOf:source),before) // Only our fixture mutation changed it.
    }

    func testChunkBoundariesRetainUnicodeAndCompleteText() {
        let input = String(repeating:"First 👨‍👩‍👧‍👦 paragraph café.\n\n第二段。 ",count:200) + String(repeating:"z",count:3_000)
        let pieces = SemanticChunker.chunks(input)
        XCTAssertEqual(pieces.joined(),input)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= SemanticChunker.maximumCharacters })
        let emojiHeavy = String(repeating:"👨‍👩‍👧‍👦",count:500)
        let bounded = SemanticChunker.chunks(emojiHeavy)
        XCTAssertEqual(bounded.joined(),emojiHeavy)
        XCTAssertTrue(bounded.allSatisfy { $0.utf8.count <= SemanticChunker.maximumUTF8Bytes })
        let context = SemanticChunker.context(question:emojiHeavy,role:"ASSISTANT",text:"Answer")
        XCTAssertLessThan(context.utf8.count,2_200)
        XCTAssertEqual(SemanticChunker.chunks(""),[])
        XCTAssertEqual(SemanticChunker.chunks("anything",maximum:0),[])
    }

    func testVersionedSourceSkipsUnchangedAndDetectsRevisionAndDeletion() throws {
        try sql("ALTER TABLE thread_items ADD COLUMN updated_at_ordinal INTEGER DEFAULT 0")
        try insert("Initial text",ordinal:1)
        try ingest()
        let original = try index.pending(limit:100,modelDigest:"fixture")
        try index.saveEmbeddings(passages:original,vectors:[unit()],modelDigest:"fixture")
        try ingest()
        XCTAssertEqual(try index.counts(modelDigest:"fixture").embedded,1)
        try sql("UPDATE thread_items SET item_json='{\"text\":\"Revised text\"}',updated_at_ordinal=2 WHERE thread_id='a'")
        try ingest()
        XCTAssertEqual(try index.counts(modelDigest:"fixture").embedded,0)
        XCTAssertEqual(try hits("Revised").count,1)
        try sql("DELETE FROM thread_items")
        try ingest()
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,0)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").missing,1)
    }

    func testForeignDatabaseSymlinkAndHardlinkAreNeverModified() throws {
        try insert("Original source bytes")
        let before = try Data(contentsOf:source)
        XCTAssertThrowsError(try SemanticIndexStore(url:source))
        let symlink = root.appendingPathComponent("source-symlink.sqlite")
        try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:source)
        XCTAssertThrowsError(try SemanticIndexStore(url:symlink))
        let hardlink = root.appendingPathComponent("source-hardlink.sqlite")
        try FileManager.default.linkItem(at:source,to:hardlink)
        XCTAssertThrowsError(try SemanticIndexStore(url:hardlink))
        XCTAssertEqual(try Data(contentsOf:source),before)
        try ingest()
        let previous = try index.counts(modelDigest:"fixture").passages
        XCTAssertThrowsError(try index.importSources(chats:[chat("a")],source:root.appendingPathComponent("missing.sqlite"),cancellation:HistoryCancellation(),progress:{ _ in }))
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,previous)
    }

    func testAmbiguousOrdinalsAndMalformedIdentitiesRemainExplicitlyUnavailable() throws {
        try insert("Duplicate first",ordinal:1,item:"first")
        try insert("Duplicate second",ordinal:1,item:"second")
        try insert("Missing turn",turn:"",ordinal:2)
        try insert("Attachment",ordinal:3,raw:try JSONSerialization.data(withJSONObject:["content":[["type":"image","image_url":"private-original"]]]))
        try ingest()
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,0)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").skipped,4)
        XCTAssertTrue(try hits("Duplicate").isEmpty)
    }

    func testCancellationAfterChatBoundaryResumesWithoutDuplicatingPassages() throws {
        try insert("Chat A",chat:"a")
        try insert("Chat B",chat:"b")
        let token = HistoryCancellation()
        XCTAssertThrowsError(try index.importSources(chats:[chat("a"),chat("b")],source:source,cancellation:token,progress:{ _ in token.cancel() }))
        XCTAssertEqual(try index.counts(modelDigest:"fixture").chats,1)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,1)
        try ingest(["a","b"])
        XCTAssertEqual(try index.counts(modelDigest:"fixture").chats,2)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,2)
    }

    private func fallbackChat(_ id: String = "a", rollout: URL) -> Chat {
        Chat(original:["rollout_path":.text(Data(rollout.path.utf8))],id:id,title:"Fallback fixture",createdAt:nil,archived:false,issues:[],project:ProjectReference(identity:.noProject,name:"No project",originalAssignment:nil,originalProject:nil))
    }
    @discardableResult private func rollout(_ objects: [[String:Any]], tail: Data = Data()) throws -> (URL,[Data]) {
        let records = try objects.map { object -> Data in
            var raw = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]); raw.append(10); return raw
        }
        let path = root.appendingPathComponent("fallback.jsonl")
        var bytes = records.reduce(into:Data()) { $0.append($1) }; bytes.append(tail)
        try bytes.write(to:path,options:.atomic)
        return (path,records)
    }
    private func response(_ body: String, id: String, role: String = "user", turn: String? = "fallback-turn") -> [String:Any] {
        var payload: [String:Any] = ["type":"message","id":id,"role":role,"content":[["type":role == "user" ? "input_text" : "output_text","text":body]]]
        if let turn { payload["internal_chat_message_metadata_passthrough"] = ["turn_id":turn] }
        if role == "assistant" { payload["phase"] = "final_answer" }
        return ["type":"response_item","timestamp":"2026-10-22T10:00:00.000Z","payload":payload]
    }
    private func fallbackIngest(_ path: URL) throws { try index.importSources(chats:[fallbackChat(rollout:path)],source:source,cancellation:HistoryCancellation(),progress:{ _ in }) }

    func testRolloutFallbackThirtyFourMessagesExactOffsetsMirrorsAndResume() throws {
        var objects: [[String:Any]] = [["type":"session_meta","payload":["id":"a","history_base":["id":"unrelated-ancestor"]]]]
        for number in 0..<17 {
            objects.append(response("Question candle \(number) café 🧠",id:"u-\(number)",turn:"turn-\(number)"))
            objects.append(["type":"event_msg","payload":["type":"user_message","message":"Question candle mirror must not duplicate"]])
            objects.append(response("Answer candle \(number) explained",id:"a-\(number)",role:"assistant",turn:"turn-\(number)"))
            objects.append(["type":"event_msg","payload":["type":"agent_message","message":"Answer candle mirror must not duplicate"]])
        }
        // This alternate response shape is explicitly subagent-attributed, not the regular chat's reply.
        objects.append(["type":"response_item","payload":["type":"agent_message","author":"/root/child","id":"subagent","content":[["type":"text","text":"SUBAGENT-ONLY-SECRET"],["type":"encrypted","encrypted_content":"opaque"]]]])
        let (path,records) = try rollout(objects)
        let original = try Data(contentsOf:path)
        try fallbackIngest(path)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").messages,34)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").missing,0)
        let matches = try hits("candle")
        XCTAssertEqual(matches.count,34)
        XCTAssertTrue(matches.allSatisfy { $0.passage.itemID.hasPrefix("rollout:") && $0.passage.sourcePath == path.path })
        XCTAssertTrue(try hits("mirror").isEmpty)
        XCTAssertTrue(try hits("SUBAGENT-ONLY-SECRET").isEmpty)
        let user = try XCTUnwrap(matches.first { $0.passage.itemID == "rollout:\(records[0].count)" })
        XCTAssertEqual(try index.rawPayload(for:user.passage),records[1])
        XCTAssertEqual(user.passage.ordinal,1) // JSONL record ordinal, explicitly NOT a SQLite source ordinal.
        let answer = try XCTUnwrap(matches.first { $0.passage.text == "Answer candle 0 explained" })
        XCTAssertTrue(answer.passage.context.contains("Question candle 0"))
        XCTAssertEqual(try Data(contentsOf:path),original)
        let pending = try index.pending(limit:100,modelDigest:"fixture")
        try index.saveEmbeddings(passages:pending,vectors:pending.map { _ in unit() },modelDigest:"fixture")
        try fallbackIngest(path)
        XCTAssertTrue(try index.pending(limit:100,modelDigest:"fixture").isEmpty)
        XCTAssertEqual(Set(try hits("candle").map(\.passage.id)),Set(matches.map(\.passage.id)))
    }

    func testRolloutFallbackMalformedTailCapturedDuplicatesAndUnknownTurnIsolation() throws {
        let message = response("Retained fallback source",id:"same-id",role:"assistant",turn:nil)
        let malformed = Data("{partial-tail-without-newline".utf8)
        let (path,_) = try rollout([
            ["type":"session_meta","payload":["id":"a"]],
            response("Question from previous turn",id:"question",turn:"known"),
            message,message,
            ["type":"future_unrecognized_record","payload":["unknown":"Retain everything"]]
        ],tail:malformed)
        try fallbackIngest(path)
        XCTAssertEqual(try hits("Retained").count,1)
        let hit = try XCTUnwrap(hits("Retained").first)
        XCTAssertEqual(hit.passage.turnID,"")
        XCTAssertFalse(hit.passage.context.contains("Question from previous turn"))
        XCTAssertEqual(try index.counts(modelDigest:"fixture").skipped,3) // Duplicate, unknown, partial.
        let revisions = try HistoryStore.withDB(index.url,cancellation:HistoryCancellation()) { db in
            try ChatStore.rows(db,"SELECT record_key,fingerprint,issue FROM semantic_revisions WHERE issue IS NOT NULL")
        }
        let tail = try XCTUnwrap(revisions.first { $0["issue"]?.string?.contains("partial rollout") == true })
        XCTAssertEqual(try index.capturedPayload(recordKey:try XCTUnwrap(tail["record_key"]?.string),fingerprint:try XCTUnwrap(tail["fingerprint"]?.string)),malformed)
    }

    func testRolloutWrongIdentityAndLegacyFormatNeverIndexAndSQLiteTakesPrecedence() throws {
        let (path,_) = try rollout([["type":"session_meta","payload":["id":"different-chat"]],response("Foreign private content",id:"foreign")])
        let before = try Data(contentsOf:path)
        try fallbackIngest(path)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,0)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").missing,1)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").skipped,1)
        XCTAssertEqual(try Data(contentsOf:path),before)
        let legacy = try JSONSerialization.data(withJSONObject:["session_meta":["id":"a"],"messages":["legacy-unknown"]],options:[.prettyPrinted])
        try legacy.write(to:path,options:.atomic)
        try fallbackIngest(path)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,0)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").missing,1)
        try insert("SQL source takes precedence")
        try fallbackIngest(path)
        XCTAssertEqual(try hits("precedence").count,1)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").skipped,0)
        XCTAssertFalse(try XCTUnwrap(hits("precedence").first).passage.itemID.hasPrefix("rollout:"))
    }

    func testRolloutIdentityFailureRollsBackPriorRecordsAndCancellationIsBounded() throws {
        let (path,_) = try rollout([
            ["type":"session_meta","payload":["id":"a"]],response("Valid earlier record",id:"first"),
            ["type":"session_meta","payload":["id":"different-chat"]]
        ])
        try fallbackIngest(path)
        XCTAssertTrue(try hits("earlier").isEmpty)
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,0)
        let token = HistoryCancellation()
        var callbacks = 0
        XCTAssertThrowsError(try SemanticRolloutAdapter.scan(chatID:"a",source:path,cancellation:token) { _ in callbacks += 1; token.cancel() })
        XCTAssertEqual(callbacks,1)
    }

    func testExactTechnicalIdentifiersQuotedPhrasesAndLiteralWildcards() throws {
        try insert("SOURCE_11 references File.m",ordinal:1)
        try insert("SOURCE_22 references File.swift and https://example.invalid/source_22",ordinal:2)
        try insert("A red candle appears here",ordinal:3)
        try insert("A candle red appears elsewhere",ordinal:4)
        try insert("A literal discount is 50%_off",ordinal:5)
        try insert("Wildcard-looking contrast 50ZZXoff",ordinal:6)
        try ingest()
        XCTAssertEqual(try hits("source_22").map(\.passage.itemID),["item-2"])
        XCTAssertEqual(try hits("File.swift").map(\.passage.itemID),["item-2"])
        XCTAssertEqual(try hits("https://example.invalid/source_22").map(\.passage.itemID),["item-2"])
        XCTAssertEqual(try hits("\"red candle\"").map(\.passage.itemID),["item-3"])
        XCTAssertEqual(try hits("50%_off").map(\.passage.itemID),["item-5"])
        XCTAssertEqual(try hits("%").map(\.passage.itemID),["item-5"])
        XCTAssertEqual(Set(try hits("_").map(\.passage.itemID)),["item-1","item-2","item-5"])
        XCTAssertTrue(try hits("\"\"").isEmpty)
        // The Combined comparison baseline retains token OR semantics, including SOURCE_11.
        XCTAssertEqual(Set(try hits("SOURCE_22",mode:.combined).map(\.passage.itemID)),["item-1","item-2"])
    }

    func testExactLiteralBranchPreservesRoleAndFinalFilters() throws {
        try insert("SOURCE_22 user",ordinal:1)
        try insert("SOURCE_22 progress",ordinal:2,type:"agentMessage",phase:"commentary")
        try insert("SOURCE_22 final",ordinal:3,type:"agentMessage",phase:"final_answer")
        try insert("SOURCE_22 tool",ordinal:4,type:"mcpToolCall")
        try ingest(tools:true)
        XCTAssertEqual(try hits("SOURCE_22").count,3)
        XCTAssertEqual(try hits("SOURCE_22",filters:SemanticFilters(includeTools:true)).count,4)
        XCTAssertEqual(try hits("SOURCE_22",filters:SemanticFilters(includeTools:true,finalOnly:true)).count,2)
    }

    func testIndexCanBeCreatedReopenedAndReadInPathsContainingSpaces() throws {
        let path = root.appendingPathComponent("Application Support/Chat Explorer/Search Index.sqlite")
        var spaced: SemanticIndexStore? = try SemanticIndexStore(url:path)
        try insert("Space-containing index path preserves records")
        try spaced?.importSources(chats:[chat("a")],source:source,cancellation:HistoryCancellation(),progress:{ _ in })
        XCTAssertEqual(try spaced?.counts(modelDigest:"fixture").passages,1)
        spaced = nil
        spaced = try SemanticIndexStore(url:path)
        let found = try spaced?.search(query:"records",vector:nil,mode:.exact,filters:SemanticFilters(),modelDigest:"fixture",limit:10,cancellation:HistoryCancellation())
        XCTAssertEqual(found?.count,1)
        spaced = nil
    }

    func testFTSRowIDMigrationIsIdempotentAndIndexedAcrossUpdatesAndDeletion() throws {
        try insert("Initial migration source",ordinal:1)
        try insert("Second migration source",ordinal:2)
        try ingest()
        let path = index.url
        index = nil
        // Reproduce the old app-owned FTS format with intentionally unrelated FTS rowids.
        var owned: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path,&owned),SQLITE_OK)
        func change(_ sql: String) throws { guard sqlite3_exec(owned,sql,nil,nil,nil) == SQLITE_OK else { throw SemanticFailure(String(cString:sqlite3_errmsg(owned))) } }
        try change("DROP TRIGGER semantic_passage_delete; DROP TRIGGER semantic_passage_insert; DROP TRIGGER semantic_passage_update; DELETE FROM semantic_meta WHERE key='fts_rowid_version'; DELETE FROM semantic_fts; INSERT INTO semantic_fts(rowid,id,search_text) SELECT rowid+1000,id,search_text FROM semantic_passages; CREATE TRIGGER semantic_passage_delete AFTER DELETE ON semantic_passages BEGIN DELETE FROM semantic_fts WHERE id=old.id; END; CREATE TRIGGER semantic_passage_insert AFTER INSERT ON semantic_passages BEGIN INSERT INTO semantic_fts(id,search_text) VALUES(new.id,new.search_text); END; CREATE TRIGGER semantic_passage_update AFTER UPDATE ON semantic_passages BEGIN DELETE FROM semantic_fts WHERE id=old.id; INSERT INTO semantic_fts(id,search_text) VALUES(new.id,new.search_text); END;")
        sqlite3_close(owned); owned = nil
        index = try SemanticIndexStore(url:path)
        func inspect(_ query: String) throws -> [[String:SQLiteValue]] {
            try HistoryStore.withDB(path,cancellation:HistoryCancellation()) { try ChatStore.rows($0,query) }
        }
        XCTAssertEqual(try inspect("SELECT count(*) AS n FROM semantic_passages p JOIN semantic_fts f ON p.rowid=f.rowid AND p.id=f.id").first?["n"]?.number,2)
        let plan = try inspect("EXPLAIN QUERY PLAN SELECT id FROM semantic_passages WHERE record_key='fixture'")
        XCTAssertTrue(plan.compactMap { $0["detail"]?.string }.contains { $0.contains("semantic_passages_record") && $0.contains("SEARCH") })
        let triggers = try inspect("SELECT sql FROM sqlite_master WHERE type='trigger' AND name LIKE 'semantic_passage_%'").compactMap { $0["sql"]?.string }
        XCTAssertEqual(triggers.count,3)
        XCTAssertTrue(triggers.filter { $0.contains("DELETE FROM") }.allSatisfy { $0.contains("WHERE rowid=old.rowid") })
        let identities = Set(try hits("migration").map(\.passage.id))
        try ingest()
        XCTAssertEqual(Set(try hits("migration").map(\.passage.id)),identities)
        try sql("UPDATE thread_items SET item_json='{\"text\":\"Revised migration target\"}' WHERE item_id='item-1'")
        try ingest()
        XCTAssertEqual(try hits("Revised").count,1)
        XCTAssertTrue(try hits("Initial").isEmpty)
        try sql("DELETE FROM thread_items WHERE item_id='item-2'")
        try ingest()
        XCTAssertEqual(try hits("migration").count,1)
        XCTAssertEqual(try inspect("SELECT count(*) AS n FROM semantic_fts").first?["n"]?.number,1)
        XCTAssertEqual(try inspect("SELECT count(*) AS n FROM semantic_passages p JOIN semantic_fts f ON p.rowid=f.rowid AND p.id=f.id").first?["n"]?.number,1)
        index = nil; index = try SemanticIndexStore(url:path)
        XCTAssertEqual(try hits("migration").count,1)
    }

    func testLargeChatImportAndUnchangedRefreshDoNotHaveQuadraticPassageScans() throws {
        let total = 6_229
        try sql("ALTER TABLE thread_items ADD COLUMN updated_at_ordinal INTEGER DEFAULT 0; BEGIN")
        // One prepared fixture insert avoids measuring SQL compilation of the synthetic source.
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO thread_items(thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_type,item_json) VALUES('a',?,?,?,?,?,?)",-1,&statement,nil),SQLITE_OK)
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for number in 0..<total {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            let payload = try JSONSerialization.data(withJSONObject:["text":"Scale fixture source paragraph \(number). " + String(repeating:"Bounded semantic context. ",count:14)])
            for (offset,value) in ["turn-\(number)","item-\(number)"].enumerated() { value.withCString { _ = sqlite3_bind_text(statement,Int32(offset+1),$0,-1,transient) } }
            sqlite3_bind_int64(statement,3,Int64(number)); sqlite3_bind_int64(statement,4,Int64(number))
            "userMessage".withCString { _ = sqlite3_bind_text(statement,5,$0,-1,transient) }
            payload.withUnsafeBytes { _ = sqlite3_bind_text(statement,6,$0.baseAddress?.assumingMemoryBound(to:CChar.self),Int32(payload.count),transient) }
            XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE)
        }
        sqlite3_finalize(statement); try sql("COMMIT")
        let begin = ProcessInfo.processInfo.systemUptime
        try ingest()
        let imported = ProcessInfo.processInfo.systemUptime - begin
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,total)
        let refreshBegin = ProcessInfo.processInfo.systemUptime
        try ingest()
        let refresh = ProcessInfo.processInfo.systemUptime - refreshBegin
        XCTAssertLessThan(imported,30,"6,229-message fixture must not approach the 120-second source budget")
        XCTAssertLessThan(refresh,3,"Versioned unchanged source should skip payload processing")
        print("Semantic scale fixture: \(total) messages, initial \(imported)s, unchanged \(refresh)s")
    }

    func testCoveringSourceSignatureAndManyChatRefreshThrottleProgress() throws {
        try sql("ALTER TABLE thread_items ADD COLUMN updated_at_ordinal INTEGER DEFAULT 0; CREATE INDEX source_updated_cover ON thread_items(thread_id,updated_at_ordinal); BEGIN")
        var insert: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO thread_items(thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_type,item_json,updated_at_ordinal) VALUES(?,'turn',?,?,1,'userMessage','{\"text\":\"Many-chat source record\"}',?)",-1,&insert,nil),SQLITE_OK)
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        let ids = (0..<1_281).map { String(format:"chat-%04d",$0) }
        for id in ids {
            for ordinal in 0..<4 {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                id.withCString { _ = sqlite3_bind_text(insert,1,$0,-1,transient) }
                "item-\(ordinal)".withCString { _ = sqlite3_bind_text(insert,2,$0,-1,transient) }
                sqlite3_bind_int64(insert,3,Int64(ordinal)); sqlite3_bind_int64(insert,4,Int64(ordinal))
                XCTAssertEqual(sqlite3_step(insert),SQLITE_DONE)
            }
        }
        sqlite3_finalize(insert); try sql("COMMIT")
        let plan = try HistoryStore.withDB(source,cancellation:HistoryCancellation()) {
            try ChatStore.rows($0,"EXPLAIN QUERY PLAN SELECT count(*) AS n,max(updated_at_ordinal) AS revision,sum(updated_at_ordinal) AS revisions,sum(CASE WHEN typeof(updated_at_ordinal)='integer' AND updated_at_ordinal>=0 THEN 0 ELSE 1 END) AS invalid_versions FROM thread_items WHERE thread_id=?",bindings:[ids[0]])
        }
        XCTAssertTrue(plan.compactMap { $0["detail"]?.string }.contains { $0.contains("COVERING INDEX source_updated_cover") })
        var callbacks = 0
        try index.importSources(chats:ids.map(chat),source:source,cancellation:HistoryCancellation(),progress:{ _ in callbacks += 1 })
        XCTAssertEqual(try index.counts(modelDigest:"fixture").passages,5_124)
        XCTAssertLessThan(callbacks,100)
        let path = index.url; index = nil; index = try SemanticIndexStore(url:path)
        callbacks = 0
        let begin = ProcessInfo.processInfo.systemUptime
        try index.importSources(chats:ids.map(chat),source:source,cancellation:HistoryCancellation(),progress:{ _ in callbacks += 1 })
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        XCTAssertLessThan(callbacks,20,"Unchanged chats must not count the entire corpus per chat")
        XCTAssertLessThan(elapsed,5,"Consecutive-process refresh must stay bounded across 1,281 chats")
        print("Semantic many-chat fixture: 1,281 chats/5,124 records, reopened hot refresh \(elapsed)s, \(callbacks) progress callbacks")
    }

    func testVersionedActiveChatReusesCapturedRawAndSourceReplacementDoesNot() throws {
        try sql("ALTER TABLE thread_items ADD COLUMN updated_at_ordinal INTEGER DEFAULT 0; CREATE INDEX source_updated_cover ON thread_items(thread_id,updated_at_ordinal)")
        try insert("Original user question",ordinal:1)
        let answerRaw = try insert("Original answer content",ordinal:2,type:"agentMessage",phase:"final_answer")
        try ingest()
        var owned: OpaquePointer?
        XCTAssertEqual(sqlite3_open(index.url.path,&owned),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(owned,"CREATE TRIGGER reject_restream BEFORE INSERT ON semantic_raw WHEN EXISTS(SELECT 1 FROM semantic_raw WHERE digest=NEW.digest) BEGIN SELECT RAISE(ABORT,'Unchanged payload streamed again'); END",nil,nil,nil),SQLITE_OK)
        sqlite3_close(owned)
        try sql("UPDATE thread_items SET item_json='{\"text\":\"Changed user question\"}',updated_at_ordinal=3 WHERE item_id='item-1'")
        try ingest() // The unchanged answer must use captured bytes; the fixture trigger rejects a restream.
        let answer = try XCTUnwrap(hits("answer").first)
        XCTAssertTrue(answer.passage.context.contains("Changed user question"))
        XCTAssertEqual(try index.rawPayload(for:answer.passage),answerRaw)
        XCTAssertEqual(sqlite3_open(index.url.path,&owned),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(owned,"DROP TRIGGER reject_restream",nil,nil,nil),SQLITE_OK); sqlite3_close(owned)
        sqlite3_close(db); db = nil
        let replacement = root.appendingPathComponent("replacement.sqlite")
        try FileManager.default.copyItem(at:source,to:replacement)
        XCTAssertEqual(sqlite3_open(replacement.path,&db),SQLITE_OK)
        try sql("UPDATE thread_items SET item_json='{\"text\":\"Replaced source identity\"}' WHERE item_id='item-1'")
        sqlite3_close(db); db = nil
        try FileManager.default.removeItem(at:source); try FileManager.default.moveItem(at:replacement,to:source)
        XCTAssertEqual(sqlite3_open(source.path,&db),SQLITE_OK)
        try ingest()
        XCTAssertEqual(try hits("Replaced").count,1)
        XCTAssertTrue(try hits("Changed").isEmpty)
    }

    func testMalformedVersionValuesForceFullByteValidation() throws {
        try sql("ALTER TABLE thread_items ADD COLUMN updated_at_ordinal INTEGER DEFAULT 0")
        try insert("Initial source text")
        try ingest()
        try sql("UPDATE thread_items SET updated_at_ordinal='invalid',item_json='{\"text\":\"First changed source\"}'")
        try ingest()
        XCTAssertEqual(try hits("First").count,1)
        try sql("UPDATE thread_items SET item_json='{\"text\":\"Second changed source\"}'")
        try ingest()
        XCTAssertEqual(try hits("Second").count,1)
        XCTAssertTrue(try hits("First").isEmpty)
    }

    func testFinalFilterRetainsUserInputsAndBothRecordedFinalPhaseAliases() throws {
        try insert("Alias marker user",ordinal:1)
        try insert("Alias marker legacy",ordinal:2,type:"agentMessage",phase:"final")
        try insert("Alias marker modern",ordinal:3,type:"agentMessage",phase:"final_answer")
        try insert("Alias marker progress",ordinal:4,type:"agentMessage",phase:"commentary")
        try ingest()
        let results = try hits("Alias",filters:SemanticFilters(finalOnly:true))
        XCTAssertEqual(results.count,3)
        XCTAssertEqual(Set(results.map(\.passage.phase)),["","final","final_answer"])
    }

    func testCheckpointedWALBackupWithoutSidecarsCanBeVerifiedAndReopened() throws {
        try insert("Checkpointed backup source")
        try ingest()
        let backupURL = root.appendingPathComponent("Application Support/Backup Index.sqlite")
        try FileManager.default.createDirectory(at:backupURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        var from: OpaquePointer?, to: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(index.url.path,&from,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_open(backupURL.path,&to),SQLITE_OK)
        let backup = try XCTUnwrap(sqlite3_backup_init(to,"main",from,"main"))
        XCTAssertEqual(sqlite3_backup_step(backup,-1),SQLITE_DONE)
        XCTAssertEqual(sqlite3_backup_finish(backup),SQLITE_OK)
        sqlite3_close(to); sqlite3_close(from)
        // Reproduce the fully checkpointed WAL-header snapshot produced by Python's backup API.
        // Only this disposable, closed backup is changed; original source/index are untouched.
        var bytes = try Data(contentsOf:backupURL)
        bytes[18] = 2; bytes[19] = 2
        try bytes.write(to:backupURL,options:.atomic)
        XCTAssertFalse(FileManager.default.fileExists(atPath:backupURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:backupURL.path + "-shm"))
        let reopened = try SemanticIndexStore(url:backupURL)
        XCTAssertEqual(try reopened.counts(modelDigest:"fixture").passages,1)
        XCTAssertEqual(try reopened.search(query:"Checkpointed",vector:nil,mode:.exact,filters:SemanticFilters(),modelDigest:"fixture",limit:10,cancellation:HistoryCancellation()).count,1)
    }
}
