import Foundation

enum SemanticSearchMode: String, CaseIterable { case combined, meaning, exact }
struct SemanticFilters { var includeTools = false; var finalOnly = false }
struct SemanticPassage: Codable, Equatable {
    let id: String
    let chatID: String
    let itemID: String
    let turnID: String
    let ordinal: Int64
    let role: String
    let phase: String
    let text: String
    let context: String
    let createdAt: Double?
    let sourceDigest: String
    var sourcePath: String? = nil
    var isTool: Bool { role == "TOOL" }
}
struct SemanticHit { let passage: SemanticPassage; var score: Double }
struct SemanticCounts {
    var chats = 0, messages = 0, passages = 0, embedded = 0, skipped = 0, missing = 0
    var pending: Int { max(0, passages - embedded) }
}
struct SemanticOptions: Codable {
    var keepWarm = false
    var throttle = true
    var rerank = true
}
protocol SemanticEmbeddingProvider: AnyObject {
    var modelDigest: String { get }
    var cleanupConfirmed: Bool { get }
    func embed(_ texts: [String], cancellation: HistoryCancellation) throws -> [[Float]]
    func rerank(query: String, passages: [String], cancellation: HistoryCancellation) throws -> [Double]?
    func stop()
    var keepWarm: Bool { get set }
}
struct SemanticFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension SemanticEmbeddingProvider { var cleanupConfirmed: Bool { true } }
