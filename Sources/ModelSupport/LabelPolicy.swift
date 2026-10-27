import Foundation

public enum LabelProvider: String, Codable { case local, luna }
public enum LabelPolicy {
    public static let maximumInputBytes = 6_000
    public static let maximumLabelCharacters = 80
    public static let maximumOutputBytes = 1_024
    public static let deadlineSeconds: TimeInterval = 45
    public static let localOutputTokens = 128
    public static let cloudModel = "gpt-6-luna"
    public static func validatedLabel(_ raw: String) throws -> String {
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.split(whereSeparator: { $0.isWhitespace }).count == 5,
              text.count <= maximumLabelCharacters, text.utf8.count <= maximumOutputBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw LabelFailure("The model did not return exactly five valid words. The saved label was not changed.") }
        return text
    }
    public static func validatedWords(_ words: [String]) throws -> String {
        guard words.count == 5, words.allSatisfy({ word in
            !word.isEmpty && !word.contains(where: { $0.isWhitespace }) &&
            !word.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw LabelFailure("The model did not return exactly five valid words. The saved label was not changed.") }
        return try validatedLabel(words.joined(separator: " "))
    }
    public static func lowestEffort(_ supported: [String]) throws -> String {
        guard let value = ["none","minimal","low","medium","high","xhigh","max"].first(where: { supported.contains($0) }) else { throw LabelFailure("Luna's supported reasoning settings could not be verified.") }
        return value
    }
    public static func safeEnvironment(jobID: String) -> [String: String] {
        let allowed = Set(["HOME","USER","LOGNAME","TMPDIR","PATH","LANG","LC_ALL","SHELL","CODEX_HOME","SSL_CERT_FILE","SSL_CERT_DIR","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY"])
        var values = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        values["EXPLORER_LABEL_JOB"] = jobID
        values["RUST_LOG"] = "off"; values["OTEL_SDK_DISABLED"] = "true"
        return values
    }
}
public struct LabelFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = String(message.prefix(240)) }
    public var errorDescription: String? { message }
}
public struct LabelWorkerRequest: Codable {
    public let jobID: String
    public let provider: LabelProvider
    public let prompt: String
    public let localModel: String
    public let modelsDirectory: String
    public let codexExecutable: String
    public let ollamaExecutable: String
    public let jobDirectory: String
    public init(jobID: String, provider: LabelProvider, prompt: String, localModel: String, modelsDirectory: String, codexExecutable: String, ollamaExecutable: String, jobDirectory: String) {
        self.jobID = jobID; self.provider = provider; self.prompt = prompt; self.localModel = localModel; self.modelsDirectory = modelsDirectory; self.codexExecutable = codexExecutable; self.ollamaExecutable = ollamaExecutable; self.jobDirectory = jobDirectory
    }
    public func validate() throws {
        guard UUID(uuidString: jobID) != nil, !prompt.isEmpty, prompt.utf8.count <= LabelPolicy.maximumInputBytes else { throw LabelFailure("The selected excerpts exceed the bounded label input.") }
        guard localModel.count <= 160, !localModel.contains("\n"), jobDirectory.hasPrefix("/") else { throw LabelFailure("Invalid model request configuration.") }
    }
}
public struct LabelBackendIdentity: Codable {
    public let pid: Int32
    public let generation: UInt64
    public let executable: String
    public let jobID: String
    public init(pid: Int32, generation: UInt64, executable: String, jobID: String) { self.pid=pid; self.generation=generation; self.executable=executable; self.jobID=jobID }
}
public struct LabelWorkerEvent: Codable {
    public let kind: String
    public let jobID: String
    public var message: String?
    public var label: String?
    public var model: String?
    public var effort: String?
    public var backend: LabelBackendIdentity?
    public var cancellationAcknowledged: Bool?
    public var ephemeralThreadID: String?
    public init(kind: String, jobID: String, message: String? = nil, label: String? = nil, model: String? = nil, effort: String? = nil, backend: LabelBackendIdentity? = nil, cancellationAcknowledged: Bool? = nil, ephemeralThreadID: String? = nil) {
        self.kind=kind; self.jobID=jobID; self.message=message; self.label=label; self.model=model; self.effort=effort; self.backend=backend; self.cancellationAcknowledged=cancellationAcknowledged; self.ephemeralThreadID=ephemeralThreadID
    }
}
public final class LabelCancellation {
    private let lock = NSLock()
    private var stopped = false
    public let deadline: TimeInterval
    public init(seconds: TimeInterval = LabelPolicy.deadlineSeconds) { deadline=ProcessInfo.processInfo.systemUptime+max(0.1,min(LabelPolicy.deadlineSeconds,seconds)) }
    public func cancel() { lock.lock(); stopped=true; lock.unlock() }
    public var cancelled: Bool { lock.lock(); defer {lock.unlock()}; return stopped || ProcessInfo.processInfo.systemUptime >= deadline }
    public func check() throws { if cancelled { throw LabelFailure("The label request was cancelled or reached its time limit.") } }
}
