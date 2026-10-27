import Foundation

/// Main-thread scheduler. The serial queue owns the database and model provider;
/// every queued unit yields before another indexing batch can be admitted.
final class SemanticCoordinator {
    static let shared = SemanticCoordinator(allowedSource: ChatStore.defaultURL)
    typealias StatusObserver = (String, SemanticCounts, Bool) -> Void
    // Retained for existing single-client callers. Views use tokenized subscriptions.
    var onStatus: StatusObserver? {
        didSet { publish() }
    }
    private var statusObservers = [UUID: StatusObserver]()
    private let queue = DispatchQueue(label: "explorer.semantic-work", qos: .utility, autoreleaseFrequency: .workItem)
    private let allowedSource: URL?
    private let allowWork: Bool
    private let databaseURL: URL
    private let defaults: UserDefaults
    private let makeProvider: () throws -> SemanticEmbeddingProvider
    private var store: SemanticIndexStore?
    private var provider: SemanticEmbeddingProvider?
    private var snapshot: ChatSnapshot?
    private var batchToken = HistoryCancellation(), queryToken = HistoryCancellation()
    private var timer: DispatchSourceTimer?
    private var memoryObserver: DispatchSourceMemoryPressure?
    private var memoryConstrained = false
    private var enabled = false, paused = false, stopped = false
    private var scheduled = false, working = false, searching = false, needsImport = true
    private var queryGeneration = UUID()
    private var queryOwner: UUID?
    private var cachedCounts = SemanticCounts()
    private var savedCountsRequested = false
    private var state = "Index not started. Start indexing to enable meaning search."
    private var fingerprint = ""
    private var includeTools = false
    private var sourceRejected = false
    private(set) var semanticEnabled: Bool
    var indexingState: String {
        if !semanticEnabled { return "Semantic OFF · Indexing OFF" }
        if !enabled { return "Indexing STOPPED" }
        if paused { return "Indexing PAUSED" }
        if searching { return "Indexing waiting for search" }
        return working ? "Indexing ACTIVE" : "Indexing enabled"
    }
    private(set) var options: SemanticOptions
    private var loadedOptions: SemanticOptions { options }

    init(databaseURL: URL? = nil, defaults: UserDefaults = .standard,
         provider: (() throws -> SemanticEmbeddingProvider)? = nil, allowWork: Bool = true, allowedSource: URL? = nil) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexChatExplorer/SemanticSearch", isDirectory: true)
        self.allowedSource = allowedSource?.resolvingSymlinksInPath().standardizedFileURL
        self.allowWork = allowWork
        self.databaseURL = databaseURL ?? directory.appendingPathComponent("index-v1.sqlite")
        self.defaults = defaults
        makeProvider = provider ?? { try SemanticModelRuntime(directory: directory) }
        options = defaults.data(forKey: "semantic.options.v1").flatMap { try? JSONDecoder().decode(SemanticOptions.self, from: $0) } ?? SemanticOptions()
        semanticEnabled = defaults.object(forKey: "semantic.module.enabled.v1") == nil || defaults.bool(forKey: "semantic.module.enabled.v1")
        enabled = allowWork && semanticEnabled && defaults.bool(forKey: "semantic.index.enabled.v1")
        paused = defaults.bool(forKey: "semantic.index.paused.v1")
        if !semanticEnabled { state = "Semantic search is OFF. Exact search and saved sources remain available." }
        else if enabled { state = paused ? "Index paused. Resume to update conversations." : "Checking saved index…" }
    }
    deinit { memoryObserver?.cancel(); timer?.cancel(); batchToken.cancel(); queryToken.cancel() }
    @discardableResult func observeStatus(_ observer: @escaping StatusObserver) -> UUID {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = UUID()
        statusObservers[token] = observer
        observer(state, cachedCounts, semanticEnabled && enabled && !paused && !stopped)
        return token
    }
    func removeStatusObserver(_ token: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        statusObservers.removeValue(forKey: token)
    }
    private func publish(_ text: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let text { state = text }
        let observers = Array(statusObservers.values)
        let text = state, counts = cachedCounts, running = semanticEnabled && enabled && !paused && !stopped
        onStatus?(text, counts, running)
        observers.forEach { $0(text, counts, running) }
    }
    func updateSnapshot(_ value: ChatSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let allowedSource, value.sourceURL.resolvingSymlinksInPath().standardizedFileURL != allowedSource {
            sourceRejected = true
            publish("This view uses a different source. The production search index is unchanged.")
            return
        }
        // Multiple roots receive the same app-owned metadata revision. Admit it once.
        let alreadyReceived = !sourceRejected && snapshot?.sourceURL == value.sourceURL && snapshot?.observedAt == value.observedAt
        sourceRejected = false
        guard !alreadyReceived else { return }
        let changed = Set(snapshot?.chats.map(\.id) ?? []) != Set(value.chats.map(\.id))
        snapshot = value
        if allowWork, !stopped, !savedCountsRequested, FileManager.default.fileExists(atPath: databaseURL.path) {
            savedCountsRequested = true
            queue.async { [weak self] in
                guard let self else { return }
                let result = Result { try self.resources().counts(modelDigest: SemanticModelRuntime.expectedDigest) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped, !self.sourceRejected else { return }
                    switch result {
                    case .success(let counts):
                        self.cachedCounts = counts
                        if !self.working && !self.searching { self.publish() }
                    case .failure(let error):
                        if !self.working && !self.searching { self.publish("Saved index counts unavailable: \(error.localizedDescription)") }
                    }
                }
            }
        }
        if changed { needsImport = true }
        if enabled && !paused { installTimer(); schedule() }
    }
    func configureSourceScope(includeTools: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.includeTools != includeTools else { return }
        self.includeTools = includeTools; needsImport = true; batchToken.cancel()
        publish(includeTools ? "Tool indexing requested; Start / Resume updates the selected scope." : "Searching conversation messages and replies.")
        schedule()
    }
    func setOptions(_ value: SemanticOptions) {
        dispatchPrecondition(condition: .onQueue(.main))
        options = value
        if allowWork, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "semantic.options.v1") }
        let warm = value.keepWarm
        queue.async { [weak self] in self?.provider?.keepWarm = warm }
        publish()
    }
    func startIndex() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard allowWork, !stopped else { publish("Indexing is disabled in this render / fixture view."); return }
        guard semanticEnabled else { publish("Semantic search is OFF. Turn it on before starting indexing."); return }
        guard !sourceRejected else { publish("Alternate-source views cannot update the production search index."); return }
        guard !memoryConstrained else { publish("Index waiting for available memory."); return }
        enabled = true; paused = false; needsImport = true
        defaults.set(true, forKey: "semantic.index.enabled.v1"); defaults.set(false, forKey: "semantic.index.paused.v1")
        installTimer(); publish("Preparing local conversations…"); schedule()
    }
    func pauseIndex() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard allowWork else { return }
        paused = true; batchToken.cancel(); defaults.set(true, forKey: "semantic.index.paused.v1")
        publish("Index paused; completed passages retained. Search remains available.")
    }
    func cancelIndex() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard allowWork else { return }
        enabled = false; paused = true; batchToken.cancel(); timer?.cancel(); timer = nil
        defaults.set(false, forKey: "semantic.index.enabled.v1")
        publish("Indexing stopped; saved passages retained. Start to resume.")
    }
    func setSemanticEnabled(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard allowWork, !stopped, !sourceRejected, value != semanticEnabled else { return }
        semanticEnabled = value
        defaults.set(value, forKey: "semantic.module.enabled.v1")
        if value {
            publish("Semantic search is ON. Start / Resume to update the saved index.")
            return
        }
        enabled = false; paused = true
        defaults.set(false, forKey: "semantic.index.enabled.v1")
        defaults.set(true, forKey: "semantic.index.paused.v1")
        batchToken.cancel(); cancelSearch()
        timer?.cancel(); timer = nil; memoryObserver?.cancel(); memoryObserver = nil; memoryConstrained = false
        publish("Semantic search is OFF; stopping model work. Saved index retained.")
        queue.async { [weak self] in
            guard let self else { return }
            self.provider?.stop()
            let confirmed = self.provider?.cleanupConfirmed ?? true
            if confirmed { self.provider = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.semanticEnabled, !self.stopped else { return }
                self.publish(confirmed ? "Semantic search is OFF. Models released; saved index and Exact search retained." : "Semantic search is OFF. Model cleanup could not be confirmed; toggle on and off to retry.")
            }
        }
    }
    func handleMemoryPressure(constrained: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard allowWork, semanticEnabled else { return }
        memoryConstrained = constrained
        guard constrained else { return }
        paused = true; batchToken.cancel(); cancelSearch()
        defaults.set(true, forKey: "semantic.index.paused.v1")
        queue.async { [weak self] in self?.provider?.stop() }
        publish("Index paused for macOS memory pressure; owned models are being released. Resume when memory is available.")
    }
    private func installTimer() {
        if memoryObserver == nil {
            let observer = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            observer.setEventHandler { [weak self] in
                guard let self, let observer = self.memoryObserver else { return }
                self.handleMemoryPressure(constrained: !observer.data.contains(.normal))
            }
            memoryObserver = observer; observer.resume()
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self, self.enabled, !self.paused, !self.stopped, let snapshot = self.snapshot else { return }
            let source = HistoryStore.source(for: snapshot)
            let key = [source.path, source.path + "-wal", snapshot.sourceURL.path, snapshot.sourceURL.path + "-wal"].map { path -> String in
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return "\(attrs?[.modificationDate] ?? "missing")/\(attrs?[.size] ?? 0)"
            }.joined(separator: "|")
            if key != self.fingerprint { self.fingerprint = key; self.needsImport = true; self.schedule() }
        }
        self.timer = timer; timer.resume()
    }
    private func resources() throws -> SemanticIndexStore {
        guard allowWork else { throw SemanticFailure("Search work is disabled in this render / fixture view.") }
        if let store { return store }
        let value = try SemanticIndexStore(url: databaseURL); store = value; return value
    }
    private func model() throws -> SemanticEmbeddingProvider {
        guard allowWork else { throw SemanticFailure("Models are disabled in this render / fixture view.") }
        if let provider { return provider }
        let value = try makeProvider(); provider = value; return value
    }
    private func schedule(after delay: TimeInterval = 0) {
        guard semanticEnabled, enabled, !paused, !stopped, !scheduled, !working, !searching, snapshot != nil else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }; self.scheduled = false; self.beginBatch()
        }
    }
    private func beginBatch() {
        guard semanticEnabled, enabled, !paused, !stopped, !working, !searching, let snapshot else { return }
        if [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) {
            publish("Index waiting for the Mac to cool; search remains available."); schedule(after: 10); return
        }
        working = true
        let token = HistoryCancellation(); batchToken = token
        let refresh = needsImport, selectedOptions = options, toolScope = includeTools
        if refresh { needsImport = false }
        publish(refresh ? "Updating local source index…" : "Embedding passages locally…")
        let started = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<(SemanticCounts, Bool), Error> = Result {
                let store = try self.resources()
                if refresh {
                    let fresh = try ChatStore.load(from: snapshot.sourceURL)
                    try store.importSources(chats: fresh.chats, source: HistoryStore.source(for: fresh), cancellation: token, includeTools: toolScope, progressModelDigest: SemanticModelRuntime.expectedDigest) { counts in
                        DispatchQueue.main.async { [weak self] in guard let self, !token.cancelled else { return }; self.cachedCounts = counts; self.publish("Reading source conversations…") }
                    }
                }
                guard !token.cancelled else { throw SemanticFailure("Index paused or superseded.") }
                let provider = try self.model(); provider.keepWarm = selectedOptions.keepWarm
                let pending = try store.pending(limit: selectedOptions.throttle ? 2 : 8, modelDigest: provider.modelDigest)
                if !pending.isEmpty {
                    let vectors = try provider.embed(pending.map(\.context), cancellation: token)
                    guard !token.cancelled else { throw SemanticFailure("Index paused or superseded.") }
                    try store.saveEmbeddings(passages: pending, vectors: vectors, modelDigest: provider.modelDigest)
                }
                return (try store.counts(modelDigest: provider.modelDigest), !pending.isEmpty)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.working = false
                switch result {
                case .success(let (counts, hadWork)):
                    self.cachedCounts = counts
                    guard self.semanticEnabled, !self.paused, !self.stopped else { self.publish(); return }
                    self.publish(counts.pending == 0 ? "Index ready · updates checked while Explorer is open." : "\(counts.embedded)/\(counts.passages) passages embedded · \(counts.pending) pending")
                    if hadWork && counts.pending > 0 {
                        let elapsed = ProcessInfo.processInfo.systemUptime - started
                        self.schedule(after: selectedOptions.throttle ? min(3, max(0.5, elapsed)) : 0.02)
                    } else if self.needsImport { self.schedule(after: 1) }
                case .failure(let error):
                    if refresh { self.needsImport = true }
                    if token.cancelled { if !self.paused && !self.stopped { self.schedule(after: 0.2) } }
                    else { self.paused = true; self.defaults.set(true, forKey: "semantic.index.paused.v1"); self.publish("Index paused: \(error.localizedDescription). Start to retry.") }
                }
            }
        }
    }
    func search(query: String, mode: SemanticSearchMode, filters: SemanticFilters, owner: UUID? = nil,
                completion: @escaping (Result<[SemanticHit], Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !searching || queryOwner == owner else {
            completion(.failure(SemanticFailure("A search is already running in another Explorer window. Wait for it to finish or cancel it there.")))
            return
        }
        cancelSearch(); batchToken.cancel()
        guard allowWork, !stopped else { completion(.failure(SemanticFailure("Search is shutting down."))); return }
        guard semanticEnabled || mode == .exact else { completion(.failure(SemanticFailure("Semantic search is OFF. Turn it on or use Exact search."))); return }
        guard !sourceRejected else { completion(.failure(SemanticFailure("Alternate-source views cannot search the production index."))); return }
        guard !memoryConstrained else { completion(.failure(SemanticFailure("Search is waiting for macOS memory pressure to clear."))); return }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.utf8.count <= 8192 else { completion(.failure(SemanticFailure("Enter a question up to 8,192 UTF-8 bytes."))); return }
        let token = HistoryCancellation(); queryToken = token; let id = UUID(); queryGeneration = id
        queryOwner = owner; searching = true; publish("Searching saved passages…")
        let selectedOptions = options
        queue.async { [weak self] in
            guard let self else { return }
            var note: String?
            let result: Result<[SemanticHit], Error> = Result {
                guard !token.cancelled else { throw SemanticFailure("Search cancelled before admission.") }
                let store = try self.resources()
                let provider = mode == .exact ? nil : try self.model()
                provider?.keepWarm = selectedOptions.keepWarm
                let digest = provider?.modelDigest ?? ""
                let vector: [Float]?
                if let provider {
                    guard (try store.counts(modelDigest: digest)).embedded > 0 else { throw SemanticFailure("No embeddings are ready yet. Start indexing, or use Exact search.") }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.queryGeneration == id, !token.cancelled else { return }
                        self.publish("Encoding your question locally; a cold model takes longer. Cancel stops the request.")
                    }
                    vector = try provider.embed(["Instruct: Retrieve original conversation passages relevant to the user's question.\nQuery: \(term)"], cancellation: token).first
                } else { vector = nil }
                var hits = try store.search(query: term, vector: vector, mode: mode, filters: filters, modelDigest: digest, limit: 80, cancellation: token)
                if selectedOptions.rerank, mode != .exact, let provider, !hits.isEmpty {
                    let candidates: [SemanticHit]
                    if mode == .combined {
                        let meaning = try store.search(query: term, vector: vector, mode: .meaning, filters: filters, modelDigest: digest, limit: 12, cancellation: token)
                        let words = try store.search(query: term, vector: nil, mode: .exact, filters: filters, modelDigest: digest, limit: 12, cancellation: token)
                        candidates = SemanticRanking.shortlist(meaning: meaning, words: words, fallback: hits)
                    } else { candidates = Array(hits.prefix(12)) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.queryGeneration == id, !token.cancelled else { return }
                        self.publish("Reranking \(candidates.count) candidate passages locally… Cancel stops model work.")
                    }
                    do {
                        if let scores = try provider.rerank(query: term, passages: candidates.map { $0.passage.context }, cancellation: token), scores.count == candidates.count, scores.allSatisfy(\.isFinite) {
                            hits = SemanticRanking.applying(scores, candidates: candidates, fallback: hits)
                            note = "Reranked \(candidates.count) candidates from the retrieval shortlist."
                        } else { note = "Reranker unavailable; original retrieval order shown." }
                    } catch { if token.cancelled { throw error }; note = "Reranker unavailable: \(error.localizedDescription). Original retrieval order shown." }
                }
                guard !token.cancelled else { throw SemanticFailure("Search cancelled.") }
                return hits
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.queryGeneration == id else { return }
                self.searching = false; self.queryOwner = nil
                if !token.cancelled {
                    switch result { case .success(let hits): self.publish("\(hits.count) passage matches. \(note ?? "Ranked relevance; scores are not probabilities.")")
                    case .failure(let error): self.publish(error.localizedDescription) }
                    completion(result)
                }
                self.schedule(after: 0.3)
            }
        }
    }
    func isSearching(owner: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return searching && queryOwner == owner
    }
    /// A pane may cancel only its own search. The nil default preserves explicit global shutdown/OFF calls.
    func cancelSearch(owner: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let owner, !isSearching(owner: owner) { return }
        queryToken.cancel(); queryGeneration = UUID(); queryOwner = nil; searching = false; schedule(after: 0.3)
    }
    func sourcePayload(for passage: SemanticPassage, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.resources().rawPayload(for: passage) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func shutdown() { shutdown(completion: {}) }
    func shutdown(completion: @escaping () -> Void) { shutdownForTermination { _ in completion() } }
    func shutdownForTermination(completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = true; batchToken.cancel(); cancelSearch(); timer?.cancel(); timer = nil; memoryObserver?.cancel(); memoryObserver = nil
        queue.async { [weak self] in
            self?.provider?.stop()
            let confirmed = self?.provider?.cleanupConfirmed ?? true
            if confirmed { self?.provider = nil; self?.store = nil }
            DispatchQueue.main.async { [weak self] in
                if !confirmed { self?.publish("Owned model cleanup could not be confirmed. Quit was cancelled; retry Quit to check again.") }
                completion(confirmed)
            }
        }
    }
}
