import Foundation
import CryptoKit
import Darwin

/// Headless, explicitly invoked real-corpus evaluation. Never runs during ordinary launch.
/// All configuration/results remain local; it creates only the declared derived index.
func runSemanticCLI(_ configurationPath: String) -> Int32 {
    let token = HistoryCancellation()
    var signals = [DispatchSourceSignal]()
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { token.cancel() }; source.resume(); signals.append(source)
    }
    defer { for source in signals { source.cancel() } }
    func emit(_ object: [String: Any]) {
        if let raw = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let line = String(data: raw, encoding: .utf8) { print(line); fflush(stdout) }
    }
    do {
        let raw = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
        guard raw.count <= 1_048_576, let config = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let destination = config["index"] as? String, destination.hasPrefix("/") else { throw SemanticFailure("Evaluation requires a bounded JSON configuration with an absolute index path.") }
        let source = (config["source"] as? String).map { URL(fileURLWithPath: $0) } ?? ChatStore.defaultURL
        let snapshot = try ChatStore.load(from: source)
        let chosen = Set(config["chatIDs"] as? [String] ?? [])
        let chats = chosen.isEmpty ? snapshot.chats : snapshot.chats.filter { chosen.contains($0.id) }
        let store = try SemanticIndexStore(url: URL(fileURLWithPath: destination))
        let provider = try SemanticModelRuntime(directory: URL(fileURLWithPath: destination).deletingLastPathComponent())
        defer { provider.stop(); emit(["event":"model_stopped"]) }
        provider.keepWarm = true
        emit(["event":"begin","chats":chats.count,"modelDigest":provider.modelDigest])
        if config["import"] as? Bool ?? true {
            try store.importSources(chats: chats, source: HistoryStore.source(for: snapshot), cancellation: token, includeTools: config["includeTools"] as? Bool ?? false, progressModelDigest: provider.modelDigest) { counts in
                if counts.chats % 25 == 0 { emit(["event":"source_progress","chats":counts.chats,"messages":counts.messages,"passages":counts.passages]) }
            }
        }
        let batchLimit = max(0, min(100_000, config["maxBatches"] as? Int ?? 100_000))
        let batchSize = max(1, min(8, config["batchSize"] as? Int ?? 8))
        let started = ProcessInfo.processInfo.systemUptime
        for batch in 0..<batchLimit {
            guard !token.cancelled else { throw SemanticFailure("Evaluation cancelled.") }
            let pending = try store.pending(limit: batchSize, modelDigest: provider.modelDigest)
            if pending.isEmpty { break }
            let vectors = try provider.embed(pending.map(\.context), cancellation: token)
            try store.saveEmbeddings(passages: pending, vectors: vectors, modelDigest: provider.modelDigest)
            let counts = try store.counts(modelDigest: provider.modelDigest)
            emit(["event":"embedding_progress","batch":batch+1,"embedded":counts.embedded,"passages":counts.passages,"elapsed":ProcessInfo.processInfo.systemUptime-started])
        }
        let counts = try store.counts(modelDigest: provider.modelDigest)
        emit(["event":"index_status","chats":counts.chats,"messages":counts.messages,"passages":counts.passages,"embedded":counts.embedded,"missing":counts.missing,"skipped":counts.skipped])
        for query in config["queries"] as? [[String:Any]] ?? [] {
            guard let question = query["query"] as? String, !question.isEmpty else { continue }
            let expected = Set(query["expectedChatIDs"] as? [String] ?? [])
            let expectedItems = Set(query["expectedItemIDs"] as? [String] ?? [])
            let began = ProcessInfo.processInfo.systemUptime
            let vector = try provider.embed(["Instruct: Retrieve original conversation passages relevant to the user's question.\nQuery: \(question)"], cancellation: token)[0]
            let embeddingSeconds = ProcessInfo.processInfo.systemUptime - began
            for mode in SemanticSearchMode.allCases {
                let modeStart = ProcessInfo.processInfo.systemUptime
                let hits = try store.search(query: question, vector: mode == .exact ? nil : vector, mode: mode, filters: SemanticFilters(includeTools: config["includeTools"] as? Bool ?? false, finalOnly: false), modelDigest: provider.modelDigest, limit: 80, cancellation: token)
                let rank = hits.firstIndex { (expected.isEmpty || expected.contains($0.passage.chatID)) && (expectedItems.isEmpty || expectedItems.contains($0.passage.itemID)) }
                emit(["event":"query","query":question,"mode":mode.rawValue,"seconds":ProcessInfo.processInfo.systemUptime-modeStart,"queryEmbeddingSeconds":embeddingSeconds,"expectedRank":rank.map { $0 + 1 } ?? NSNull(),"expectedChatRank":hits.firstIndex { expected.contains($0.passage.chatID) }.map { $0+1 } ?? NSNull(),"hits":hits.prefix(10).map { ["chatID":$0.passage.chatID,"itemID":$0.passage.itemID,"ordinal":$0.passage.ordinal,"score":$0.score] as [String:Any] }])
                if mode == .combined, config["rerank"] as? Bool == true, !hits.isEmpty {
                    let began = ProcessInfo.processInfo.systemUptime
                    let meaning = try store.search(query: question, vector: vector, mode: .meaning, filters: SemanticFilters(), modelDigest: provider.modelDigest, limit: 12, cancellation: token)
                    let words = try store.search(query: question, vector: nil, mode: .exact, filters: SemanticFilters(), modelDigest: provider.modelDigest, limit: 12, cancellation: token)
                    let candidates = SemanticRanking.shortlist(meaning: meaning, words: words, fallback: hits)
                    if let scores = try provider.rerank(query: question, passages: candidates.map { $0.passage.context }, cancellation: token), scores.count == candidates.count {
                        let reranked = SemanticRanking.applying(scores, candidates:candidates, fallback:hits)
                        let rank = reranked.firstIndex { (expected.isEmpty || expected.contains($0.passage.chatID)) && (expectedItems.isEmpty || expectedItems.contains($0.passage.itemID)) }
                        emit(["event":"rerank","query":question,"seconds":ProcessInfo.processInfo.systemUptime-began,"expectedRank":rank.map { $0+1 } ?? NSNull(),"hits":reranked.prefix(10).map { ["chatID":$0.passage.chatID,"itemID":$0.passage.itemID,"score":$0.score] as [String:Any] }])
                    } else { emit(["event":"rerank_unavailable"]) }
                }
            }
        }
        return 0
    } catch { emit(["event":"error","message":error.localizedDescription]); return 1 }
}
