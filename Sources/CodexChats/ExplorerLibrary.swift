import Foundation

struct SavedExcerpt: Codable, Identifiable {
    let id: UUID
    let chatID: String
    let chatTitle: String
    let messageReferences: [String]
    let ordinal: Int64?
    let sourcePath: String
    let text: String
    let savedAt: Date
    var sourceHashes: [String: String]? = nil
}
struct DerivedChatLabel: Codable {
    let text: String
    let provider: String
    let model: String
    let generatedAt: Date
    let sourceReferences: [String]
    var effort: String? = nil
    var sourceHashes: [String: String]? = nil
    var sampledMessages: Int? = nil
    var totalMessages: Int? = nil
    var inputBytes: Int? = nil
}
enum ChatTagColor: String, Codable, CaseIterable {
    case red, yellow, green, blue, purple, orange
}
struct ExplorerLibraryState: Codable {
    var version = 1
    var favoriteChatIDs = Set<String>()
    var excerpts = [SavedExcerpt]()
    var labels = [String: DerivedChatLabel]()
    var pinnedChatIDs = Set<String>()
    // Keep future color strings intact when other annotations are changed.
    private var storedChatTags = [String: String]()
    var chatTags: [String: ChatTagColor] {
        storedChatTags.compactMapValues(ChatTagColor.init(rawValue:))
    }
    func tag(for chatID: String) -> ChatTagColor? {
        storedChatTags[chatID].flatMap(ChatTagColor.init(rawValue:))
    }

    init() {}
    private enum CodingKeys: String, CodingKey { case version, favoriteChatIDs, excerpts, labels, pinnedChatIDs, chatTags }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        favoriteChatIDs = try container.decode(Set<String>.self, forKey: .favoriteChatIDs)
        excerpts = try container.decode([SavedExcerpt].self, forKey: .excerpts)
        labels = try container.decode([String: DerivedChatLabel].self, forKey: .labels)
        pinnedChatIDs = container.contains(.pinnedChatIDs) ? try container.decode(Set<String>.self, forKey: .pinnedChatIDs) : []
        storedChatTags = container.contains(.chatTags) ? try container.decode([String: String].self, forKey: .chatTags) : [:]
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(favoriteChatIDs, forKey: .favoriteChatIDs)
        try container.encode(excerpts, forKey: .excerpts)
        try container.encode(labels, forKey: .labels)
        try container.encode(pinnedChatIDs, forKey: .pinnedChatIDs)
        try container.encode(storedChatTags, forKey: .chatTags)
    }
    mutating func setTag(_ color: ChatTagColor?, chatID: String) {
        storedChatTags[chatID] = color?.rawValue
    }
}
final class ExplorerLibrary {
    /// Observe the injected app-owned instance; delivered on main after its write lock is released.
    static let changed = Notification.Name("ExplorerLibraryChanged")
    static var defaultDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexChatExplorer", isDirectory: true) }
    private let lock = NSLock()
    private let file: URL
    private var value = ExplorerLibraryState()
    private(set) var issue: String?
    init(directory: URL = ExplorerLibrary.defaultDirectory) {
        file = directory.appendingPathComponent("library-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                let decoded = try JSONDecoder().decode(ExplorerLibraryState.self, from: data)
                if decoded.version != 1 { throw StoreError(message: "Unsupported saved-library version.") }
                value = decoded
            } catch { issue = "Saved items could not be read; the original file was preserved." }
        }
    }
    var state: ExplorerLibraryState { lock.lock(); defer { lock.unlock() }; return value }
    func toggleFavorite(_ id: String) throws {
        try update { state in if !state.favoriteChatIDs.insert(id).inserted { state.favoriteChatIDs.remove(id) } }
    }
    func togglePinned(_ id: String) throws {
        try update { state in if !state.pinnedChatIDs.insert(id).inserted { state.pinnedChatIDs.remove(id) } }
    }
    func setTag(_ color: ChatTagColor?, chatID: String) throws { try update { $0.setTag(color, chatID: chatID) } }
    func save(_ excerpt: SavedExcerpt) throws { try update { $0.excerpts.append(excerpt) } }
    func setLabel(_ label: DerivedChatLabel, chatID: String) throws { try update { $0.labels[chatID] = label } }
    private func update(_ body: (inout ExplorerLibraryState) -> Void) throws {
        lock.lock()
        var committed = false
        defer {
            lock.unlock()
            if committed {
                let notify = { NotificationCenter.default.post(name: Self.changed, object: self) }
                if Thread.isMainThread { notify() } else { DispatchQueue.main.async(execute: notify) }
            }
        }
        guard issue == nil else { throw StoreError(message: issue!) }
        var next = value; body(&next)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(next)
        try encoded.write(to: file, options: [.atomic])
        value = next
        committed = true
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
