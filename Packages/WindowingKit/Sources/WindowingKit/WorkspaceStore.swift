import Foundation

private struct WorkspaceFile<Document: Codable>: Codable {
    var version = 1
    var documents: [Document]
}

/// A shared, main-thread workspace model with a serial, debounced file writer.
/// Invalid files remain untouched and put the store in read-only mode.
public final class WorkspaceStore<Document: Codable & Equatable & Identifiable> where Document.ID == String {
    public private(set) var documents: [Document]
    public private(set) var issue: String?
    public private(set) var isReadOnly = false
    public private(set) var hasUnsavedChanges = false
    public var onIssue: ((String?) -> Void)? { didSet { onIssue?(issue) } }

    private let file: URL?
    private let valid: (Document) -> Bool
    private let writer = DispatchQueue(label: "windowing-kit.workspace-writer", qos: .utility)
    private var saveWork: DispatchWorkItem?
    private var saveTicket: SaveTicket?
    private var listeners = [UUID: (String) -> Void]()
    private var isMutating = false

    private final class SaveTicket {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    /// Existing files take precedence over host-provided initial or legacy data.
    /// An initial issue means that the host could not safely restore its seed.
    public init(file: URL? = nil, initialDocuments: [Document],
                initialHasUnsavedChanges: Bool = false, initialIssue: String? = nil,
                valid: @escaping (Document) -> Bool) {
        self.file = file
        self.valid = valid
        self.documents = initialDocuments
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do {
                let decoded = try JSONDecoder().decode(WorkspaceFile<Document>.self, from: Data(contentsOf: file))
                guard decoded.version == 1, Self.validDocuments(decoded.documents, valid: valid) else {
                    throw InvalidWorkspace()
                }
                documents = decoded.documents
            } catch {
                isReadOnly = true
                issue = "Workspace data is unavailable; its original file has been preserved. This store is read-only."
            }
        } else if let initialIssue {
            isReadOnly = true
            issue = initialIssue
        } else if !Self.validDocuments(initialDocuments, valid: valid) {
            isReadOnly = true
            issue = "Initial workspace data is invalid. This store is read-only."
        } else {
            hasUnsavedChanges = file != nil && initialHasUnsavedChanges
        }
    }

    private struct InvalidWorkspace: Error {}

    private static func validDocuments(_ documents: [Document], valid: (Document) -> Bool) -> Bool {
        !documents.isEmpty && documents.allSatisfy { !$0.id.isEmpty && valid($0) }
            && Set(documents.map(\.id)).count == documents.count
    }

    public func document(_ id: String) -> Document? { documents.first { $0.id == id } }
    public func document(id: String) -> Document? { document(id) }
    @discardableResult public func observe(_ callback: @escaping (String) -> Void) -> UUID {
        let id = UUID(); listeners[id] = callback; return id
    }
    public func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }

    @discardableResult public func change(_ id: String, _ body: (inout Document) -> Void) -> Bool {
        transaction { next in
            guard let index = next.firstIndex(where: { $0.id == id }) else { return false }
            body(&next[index])
            return next[index].id == id
        }
    }

    /// The closure edits a copy. Failure, invalid documents or duplicate IDs
    /// leave the model, observers and persistence untouched. Nested mutations
    /// from the editing closure are rejected; observers may mutate after commit.
    @discardableResult public func transaction(_ body: (inout [Document]) -> Bool) -> Bool {
        guard !isReadOnly, !isMutating else { return false }
        var next = documents
        isMutating = true
        let accepted = body(&next)
        let validResult = accepted && Self.validDocuments(next, valid: valid)
        isMutating = false
        guard validResult else { return false }
        guard next != documents else { return true }
        let old = documents
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        // Appending or removing an item does not change the relative order of
        // surviving documents. Only publish surviving IDs whose positions in
        // that shared order actually moved.
        let oldCommon = old.map(\.id).filter { nextByID[$0] != nil }
        let nextCommon = next.map(\.id).filter { oldByID[$0] != nil }
        let oldPositions = Dictionary(uniqueKeysWithValues: oldCommon.enumerated().map { ($0.element, $0.offset) })
        let nextPositions = Dictionary(uniqueKeysWithValues: nextCommon.enumerated().map { ($0.element, $0.offset) })
        var ids = [String]()
        var included = Set<String>()
        for doc in old where nextByID[doc.id] != doc || oldPositions[doc.id] != nextPositions[doc.id] {
            ids.append(doc.id); included.insert(doc.id)
        }
        for doc in next where !included.contains(doc.id) && (oldByID[doc.id] != doc || oldPositions[doc.id] != nextPositions[doc.id]) {
            ids.append(doc.id); included.insert(doc.id)
        }
        documents = next
        scheduleSave()
        for id in ids { for callback in Array(listeners.values) { callback(id) } }
        return true
    }

    private func scheduleSave() {
        guard let file, !isReadOnly else { return }
        cancelSave(); hasUnsavedChanges = true
        let snapshot = WorkspaceFile(documents: documents), ticket = SaveTicket()
        saveTicket = ticket
        let work = DispatchWorkItem { [weak self] in
            guard !ticket.isCancelled else { return }
            let failure = Self.save(snapshot, to: file)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.saveTicket === ticket, !ticket.isCancelled else { return }
                self.saveWork = nil; self.saveTicket = nil
                self.hasUnsavedChanges = failure != nil; self.reportIssue(failure)
            }
        }
        saveWork = work
        writer.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func cancelSave() { saveTicket?.cancel(); saveTicket = nil; saveWork?.cancel(); saveWork = nil }
    private func reportIssue(_ value: String?) {
        guard issue != value else { return }; issue = value; onIssue?(value)
    }
    private static func save(_ snapshot: WorkspaceFile<Document>, to file: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return nil
        } catch {
            return "Workspace changes have not been saved. They remain in memory; retry saving before quitting. \(error.localizedDescription)"
        }
    }
    /// A failed restoration never overwrites the unreadable original. Ordinary
    /// write failures remain retryable through another call to flush().
    @discardableResult public func flush() -> Bool {
        guard !isReadOnly, !isMutating else { return false }
        guard let file else { return true }
        cancelSave()
        let snapshot = WorkspaceFile(documents: documents)
        let failure = writer.sync { Self.save(snapshot, to: file) }
        hasUnsavedChanges = failure != nil; reportIssue(failure)
        return failure == nil
    }
}
