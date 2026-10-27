import Foundation
import Darwin
import ModelSupport

struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }

final class Lifetime {
    let condition = NSCondition()
    var requests = [[String: Any]]()
    var ended = false
    var warm = false
    var changedPolicy = false
    var cancelled: Bool { condition.lock(); defer { condition.unlock() }; return ended }
    func end() { condition.lock(); ended = true; condition.broadcast(); condition.unlock() }
    func submit(_ value: [String: Any]) {
        condition.lock(); defer { condition.unlock() }
        if value["policy"] as? Bool == true { warm = value["keepWarm"] as? Bool ?? false; changedPolicy = true }
        else if requests.isEmpty { requests.append(value) }
        else { ended = true }
        condition.broadcast()
    }
}
let lifetime = Lifetime()
func check(_ deadline: TimeInterval) throws {
    if lifetime.cancelled { throw Failure("The model worker's parent disconnected.") }
    if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure("The private model request reached its time limit.") }
}

/// Every owned server inherits the worker's process group. App-side group cleanup reaches runners too.
final class Child {
    var pid: pid_t = 0
    init(executable: String, arguments: [String], extra: [String: String] = [:]) throws {
        guard getpgrp() == getpid() else { throw Failure("The semantic model worker is not isolated into its own process group.") }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw Failure("Required model executable is unavailable: \(executable)") }
        var env = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "EXPLORER_LABEL_JOB"].contains($0.key) }
        env.merge(extra) { _, new in new }
        let args = ([executable] + arguments).map { strdup($0) } + [nil]
        let vars = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; vars.forEach { free($0) } }
        var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, getpgrp())
        var actions: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let status = args.withUnsafeBufferPointer { argv in vars.withUnsafeBufferPointer { envp in
            posix_spawn(&pid, executable, &actions, &attr, UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
        } }
        guard status == 0 else { throw Failure("Cannot start the private model runtime (\(status)).") }
    }
    var running: Bool { guard pid > 0 else { return false }; var status: Int32 = 0; return waitpid(pid, &status, WNOHANG) == 0 }
    func stop() {
        guard pid > 0 else { return }
        if running { kill(pid, SIGTERM) }
        let end = ProcessInfo.processInfo.systemUptime + 1.5
        while running && ProcessInfo.processInfo.systemUptime < end { usleep(20_000) }
        if running {
            // A wedged server may leave a separate runner alive when only its PID is killed.
            // This helper owns its entire private group; abort all descendants together.
            kill(-getpgrp(), SIGKILL)
            _exit(137)
        }
        pid = 0
    }
    deinit { stop() }
}

final class HTTP: NSObject, URLSessionDataDelegate {
    private let condition = NSCondition()
    private var bytes = Data(), done = false, failure: Error?, status = 0
    private let maximum = 1_048_576
    func request(url: String, payload: [String: Any]? = nil, deadline: TimeInterval, key: String? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = max(0.1, deadline - ProcessInfo.processInfo.systemUptime)
        if let payload { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: payload); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]; configuration.urlCache = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request); task.resume()
        defer { task.cancel(); session.invalidateAndCancel() }
        condition.lock()
        while !done {
            if lifetime.cancelled || ProcessInfo.processInfo.systemUptime >= deadline { condition.unlock(); throw Failure("The private model request was cancelled or timed out.") }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        let data = bytes, error = failure, code = status; condition.unlock()
        if let error { throw error }
        guard (200...299).contains(code) else { throw Failure("The private model server returned HTTP \(code). \(String(data: data.prefix(240), encoding: .utf8) ?? "")") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("The private model server returned malformed JSON.") }
        return object
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        condition.lock(); status = (response as? HTTPURLResponse)?.statusCode ?? 0; condition.unlock()
        completionHandler(response.expectedContentLength > maximum ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard bytes.count + data.count <= maximum else { failure = Failure("Private model response exceeded 1 MB."); dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { condition.lock(); failure = failure ?? error; done = true; condition.broadcast(); condition.unlock() }
}
func privatePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw Failure("Cannot reserve a model port.") }; defer { close(fd) }
    var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    guard bound == 0, named == 0 else { throw Failure("Cannot reserve a private model port.") }
    return UInt16(bigEndian: address.sin_port)
}

final class Models {
    var embedding: Child?, ranking: Child?
    var embedURL = "", rankURL = "", rankKey = ""
    var lastUse = ProcessInfo.processInfo.systemUptime
    let home = FileManager.default.homeDirectoryForCurrentUser
    func stop() { embedding?.stop(); embedding = nil; ranking?.stop(); ranking = nil; OwnedModelProcess.terminateCurrentGroupIfDescendantsRemain() }
    func retainEmbedding() {
        guard embedding != nil else { return }
        // Ollama accepts an empty input list as an explicit model-residency request.
        // Update an already loaded Balanced model's TTL when Keep warm is selected.
        do { _ = try HTTP().request(url: embedURL + "/api/embed", payload: ["model": "qwen3-embedding:8b", "input": [String](), "keep_alive": -1, "truncate": false, "options": ["num_ctx": 8192, "num_thread": 6, "num_batch": 256]], deadline: ProcessInfo.processInfo.systemUptime + 120) }
        catch { embedding?.stop(); embedding = nil }
    }
    func readiness(_ child: Child, base: String, route: String, key: String? = nil, deadline: TimeInterval) throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try check(deadline)
            guard child.running else { throw Failure("The private model server exited during startup.") }
            do { _ = try HTTP().request(url: base + route, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.4), key: key); return } catch { usleep(100_000) }
        }
        throw Failure("The private model server did not become ready.")
    }
    func embed(_ texts: [String], warm: Bool, deadline: TimeInterval) throws -> [String: Any] {
        guard texts.count > 0, texts.count <= 8, texts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 12_000 }), texts.reduce(0, { $0 + $1.utf8.count }) <= 64_000 else { throw Failure("Invalid bounded embedding input.") }
        // Balanced keeps only one 8B model resident, including during pipeline transitions.
        // Stop and verify the previous owned server/runner group before loading the next model.
        if !warm, ranking != nil { stop() }
        if embedding == nil {
            let port = try privatePort(); embedURL = "http://127.0.0.1:\(port)"
            let executable = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
            embedding = try Child(executable: executable, arguments: ["serve"], extra: ["OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_MODELS": home.appendingPathComponent("Local AI Models/ollama").path, "OLLAMA_NO_CLOUD": "1", "OLLAMA_NOPRUNE": "1", "OLLAMA_KEEP_ALIVE": "60s", "OLLAMA_MAX_LOADED_MODELS": "1", "OLLAMA_NUM_PARALLEL": "1", "OLLAMA_MAX_QUEUE": "1", "OLLAMA_CONTEXT_LENGTH": "8192", "OLLAMA_LOAD_TIMEOUT": "120s", "OLLAMA_GPU_OVERHEAD": "1073741824"])
            try readiness(embedding!, base: embedURL, route: "/api/version", deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 30))
        }
        let result = try HTTP().request(url: embedURL + "/api/embed", payload: ["model": "qwen3-embedding:8b", "input": texts, "truncate": false, "keep_alive": warm ? -1 : 60, "options": ["num_ctx": 8192, "num_thread": 6, "num_batch": 256]], deadline: deadline)
        guard let vectors = result["embeddings"] else { throw Failure("The embedding model did not return vectors.") }
        lastUse = ProcessInfo.processInfo.systemUptime
        return ["vectors": vectors]
    }
    func rerank(_ query: String, _ passages: [String], warm: Bool, deadline: TimeInterval) throws -> [String: Any] {
        guard !query.isEmpty, query.utf8.count <= 8_000, !passages.isEmpty, passages.count <= 12, passages.allSatisfy({ $0.utf8.count <= 12_000 }) else { throw Failure("Invalid bounded reranker input.") }
        if !warm, embedding != nil { stop() }
        if ranking == nil {
            let path = home.appendingPathComponent("Local AI Models/Qwen3-Reranker-8B/Qwen3-Reranker-8B-Q4_K_M.gguf").path
            guard FileManager.default.fileExists(atPath: path) else { throw Failure("Qwen3-Reranker-8B is not installed yet. The optional reranker download must complete first.") }
            let port = try privatePort(); rankURL = "http://127.0.0.1:\(port)"; rankKey = UUID().uuidString
            ranking = try Child(executable: "/opt/homebrew/bin/llama-server", arguments: ["--model", path, "--host", "127.0.0.1", "--port", String(port), "--api-key", rankKey, "--ctx-size", "8192", "--parallel", "1", "--threads", "6", "--batch-size", "256", "--ubatch-size", "128", "--n-gpu-layers", "99", "--no-webui", "--no-slots", "--no-context-shift", "--cache-ram", "0", "--no-cache-prompt", "--threads-http", "2", "--timeout", "240"])
            try readiness(ranking!, base: rankURL, route: "/health", key: rankKey, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 120))
        }
        let yes = try token("yes", deadline: deadline), no = try token("no", deadline: deadline)
        var scores = [Double]()
        for passage in passages {
            try check(deadline)
            let prompt = "<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct provided. Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n<|im_start|>user\n<Instruct>: Given a search query, retrieve relevant original conversation passages that answer the query\n<Query>: \(query)\n<Document>: \(passage)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
            let result = try HTTP().request(url: rankURL + "/completion", payload: ["prompt": prompt, "n_predict": 1, "n_probs": 2, "post_sampling_probs": true, "temperature": 1, "top_k": 0, "top_p": 1, "min_p": 0, "repeat_penalty": 1, "samplers": ["temperature"], "logit_bias": [[yes, 100], [no, 100]], "grammar": "root ::= <[\(yes)]> | <[\(no)]>", "cache_prompt": false, "stream": false], deadline: deadline, key: rankKey)
            guard let probs = result["completion_probabilities"] as? [[String: Any]] ?? result["probs"] as? [[String: Any]], let top = probs.first?["top_probs"] as? [[String: Any]], !top.isEmpty, top.allSatisfy({ ($0["id"] as? Int) == yes || ($0["id"] as? Int) == no }) else { throw Failure("The reranker did not expose the required yes/no token probabilities; reranking was not applied.") }
            // Equal logit bias promotes both classifier tokens into the bounded top-two response.
            // It cancels exactly in their conditional probability; normalization also cancels
            // the full-vocabulary denominator when grammar rejection sampling was unnecessary.
            guard top.count == 2,
                  let positive = top.first(where: { ($0["id"] as? Int) == yes })?["prob"] as? Double,
                  let negative = top.first(where: { ($0["id"] as? Int) == no })?["prob"] as? Double,
                  positive.isFinite, negative.isFinite, positive >= 0, negative >= 0 else { throw Failure("The reranker omitted one of its two classifier probabilities; reranking was not applied.") }
            let score = positive / (positive + negative)
            guard score.isFinite, (0...1).contains(score) else { throw Failure("Invalid reranker yes/no probabilities.") }
            scores.append(score)
        }
        lastUse = ProcessInfo.processInfo.systemUptime
        return ["scores": scores]
    }
    private func token(_ text: String, deadline: TimeInterval) throws -> Int {
        let result = try HTTP().request(url: rankURL + "/tokenize", payload: ["content": text, "add_special": false], deadline: deadline, key: rankKey)
        guard let tokens = result["tokens"] as? [Int], tokens.count == 1 else { throw Failure("The reranker tokenizer does not have a single yes/no token.") }
        return tokens[0]
    }
    deinit { stop() }
}

signal(SIGPIPE, SIG_IGN)
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let signals = [SIGTERM, SIGINT].map { signalNumber -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility)); source.setEventHandler { lifetime.end() }; source.resume(); return source
}
DispatchQueue.global(qos: .utility).async {
    var buffer = Data()
    while true {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let count = read(STDIN_FILENO, &chunk, chunk.count)
        if count <= 0 { if count < 0 && errno == EINTR { continue }; lifetime.end(); return }
        buffer.append(contentsOf: chunk.prefix(count))
        guard buffer.count <= 262_144 else { lifetime.end(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { lifetime.end(); return }
            lifetime.submit(value)
        }
    }
}
let models = Models()
while true {
    lifetime.condition.lock()
    if lifetime.requests.isEmpty && !lifetime.ended { _ = lifetime.condition.wait(until: Date(timeIntervalSinceNow: 1)) }
    let ended = lifetime.ended, warm = lifetime.warm, changed = lifetime.changedPolicy
    lifetime.changedPolicy = false
    let request = lifetime.requests.isEmpty ? nil : lifetime.requests.removeFirst()
    lifetime.condition.unlock()
    if ended { break }
    if !warm && ProcessInfo.processInfo.systemUptime - models.lastUse > 60 { models.stop() }
    if changed { if warm { models.retainEmbedding() } else { models.stop() } } // explicit residency policy change
    guard let request else { continue }
    let keepWarm = request["keepWarm"] as? Bool ?? false
    lifetime.condition.lock(); lifetime.warm = keepWarm; lifetime.condition.unlock()
    autoreleasepool {
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 235
            let result: [String: Any]
            switch request["kind"] as? String {
            case "embed": result = try models.embed(request["texts"] as? [String] ?? [], warm: keepWarm, deadline: deadline)
            case "rerank": result = try models.rerank(request["query"] as? String ?? "", request["passages"] as? [String] ?? [], warm: keepWarm, deadline: deadline)
            default: throw Failure("Unknown semantic-model request.")
            }
            let data = try JSONSerialization.data(withJSONObject: result)
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        } catch {
            models.stop()
            if let raw = try? JSONSerialization.data(withJSONObject: ["error": String(error.localizedDescription.prefix(500))]) { try? FileHandle.standardOutput.write(contentsOf: raw + Data([10])) }
        }
    }
}
models.stop()
