import Foundation
import CryptoKit
import ModelSupport

/// Only talks to the private child worker. Never contacts or stops the shared Ollama service.
final class SemanticModelRuntime: SemanticEmbeddingProvider {
    static let expectedDigest = "64b933495768fbd3b87c20583d379728a07471e0c66733a9df87cd1901b3c44b"
    let modelDigest = SemanticModelRuntime.expectedDigest
    private let directory: URL
    private let operation = NSLock(), state = NSLock()
    private var worker: OwnedModelProcess?
    private var warm = false
    private var lastCleanupConfirmed = true
    var cleanupConfirmed: Bool { state.lock(); defer { state.unlock() }; return lastCleanupConfirmed }
    var keepWarm: Bool {
        get { state.lock(); defer { state.unlock() }; return warm }
        set {
            state.lock(); let changed = warm != newValue; warm = newValue; let current = changed ? worker : nil; state.unlock()
            // Updates the idle policy even if no further search is performed.
            do { try current?.sendBounded(["policy": true, "keepWarm": newValue], deadline: ProcessInfo.processInfo.systemUptime + 0.25, cancelled: { false }) }
            catch { stop() }
        }
    }
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Chat Explorer/SemanticSearch/Runtime")) { self.directory = directory }
    deinit { stop() }

    func embed(_ texts: [String], cancellation: HistoryCancellation) throws -> [[Float]] {
        guard !texts.isEmpty, texts.count <= 8, texts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 12_000 }), texts.reduce(0, { $0 + $1.utf8.count }) <= 64_000 else { throw SemanticFailure("Embedding input exceeds the eight-passage/64 KB request limit.") }
        return try autoreleasepool {
            let result = try request(["kind": "embed", "texts": texts], cancellation: cancellation)
            guard let values = result["vectors"] as? [[NSNumber]], values.count == texts.count else { throw SemanticFailure("The local embedding worker returned an invalid vector count.") }
            return try values.map { row in
                let vector = row.map { $0.floatValue }
                let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
                guard vector.count == 4096, vector.allSatisfy({ $0.isFinite }), norm.isFinite, abs(norm - 1) < 0.01 else { throw SemanticFailure("The embedding model returned an invalid, non-unit or non-4096-dimensional vector.") }
                return vector
            }
        }
    }
    func rerank(query: String, passages: [String], cancellation: HistoryCancellation) throws -> [Double]? {
        guard !query.isEmpty, query.utf8.count <= 8_000, !passages.isEmpty, passages.count <= 12, passages.allSatisfy({ $0.utf8.count <= 12_000 }) else { throw SemanticFailure("Reranking exceeds the bounded twelve-passage input limit.") }
        return try autoreleasepool {
            let result = try request(["kind": "rerank", "query": query, "passages": passages], cancellation: cancellation)
            guard let values = result["scores"] as? [Double], values.count == passages.count, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw SemanticFailure("The reranker returned invalid relevance scores.") }
            return values
        }
    }
    private func request(_ payload: [String: Any], cancellation: HistoryCancellation) throws -> [String: Any] {
        // Serial model work bounds memory and prevents a search racing an indexing batch.
        operation.lock(); defer { operation.unlock() }
        guard !cancellation.cancelled else { throw SemanticFailure("The local model request was cancelled.") }
        let process = try start()
        var value = payload; value["keepWarm"] = keepWarm
        let deadline = ProcessInfo.processInfo.systemUptime + 240
        do {
            try process.sendBounded(value, deadline: deadline, cancelled: { cancellation.cancelled })
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard !cancellation.cancelled else { throw SemanticFailure("The local model request was cancelled.") }
                do {
                    let result = try process.nextJSON(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.2), cancellation: nil, maximumBytes: 1_048_576)
                    if let error = result["error"] as? String { throw SemanticFailure(error) }
                    return result
                } catch let error as LabelFailure where error.message == "The model-runtime response reached its time limit." { continue }
            }
            throw SemanticFailure("The local model request reached its four-minute limit.")
        } catch {
            // Cancelling the request also terminates in-flight inference and frees model memory.
            stop()
            guard cleanupConfirmed else { throw SemanticFailure("\(error.localizedDescription) Cleanup of the owned model process could not be confirmed; retry Stop before quitting.") }
            throw error
        }
    }
    private func start() throws -> OwnedModelProcess {
        state.lock(); defer { state.unlock() }
        if let worker {
            if lastCleanupConfirmed && worker.process.isRunning { return worker }
            lastCleanupConfirmed = worker.stop()
            guard lastCleanupConfirmed else { throw SemanticFailure("A previous owned model process still needs cleanup. Retry Stop before starting another model request.") }
            self.worker = nil
        }
        let base = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [base?.deletingLastPathComponent().appendingPathComponent("Helpers/SemanticModelWorker").path, base?.appendingPathComponent("SemanticModelWorker").path, URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("SemanticModelWorker").path].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw SemanticFailure("SemanticModelWorker is missing from this application build.") }
        let manifest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Local AI Models/ollama/manifests/registry.ollama.ai/library/qwen3-embedding/8b")
        let handle = try FileHandle(forReadingFrom: manifest)
        defer { try? handle.close() }
        let raw = try handle.read(upToCount: 1_048_577) ?? Data()
        guard raw.count <= 1_048_576 else { throw SemanticFailure("The local model manifest exceeds its 1 MB size limit.") }
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard digest == modelDigest else { throw SemanticFailure("The installed embedding model digest differs from this index's Qwen3-Embedding-8B model.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let process = try OwnedModelProcess(executable: executable, arguments: [], environment: LabelPolicy.safeEnvironment(jobID: id), directory: directory.path, jobID: id)
        worker = process
        return process
    }
    func stop() {
        state.lock(); let current = worker; state.unlock()
        guard let current else { return }
        let confirmed = current.stop()
        state.lock()
        lastCleanupConfirmed = confirmed
        if confirmed, worker === current { worker = nil }
        // Preserve the identity/handle after unsuccessful cleanup so Stop can retry safely.
        state.unlock()
    }
}
