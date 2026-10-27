import Foundation

/// One app-owned reader for recorded last-turn reconciliation. Main-thread callers feed
/// existing metadata/activity snapshots; there is no timer or inferred activity state.
final class LastTurnReconciler {
    typealias Read = ([String], URL, [String: URL]) throws -> LastReplySnapshot
    var onUpdate: ((LastReplySnapshot, Set<String>) -> Void)?
    private(set) var latest: LastReplySnapshot?
    private let allowWork: Bool
    private let clock: () -> TimeInterval
    private let read: Read
    private let queue = DispatchQueue(label: "explorer.last-turn-reads", qos: .utility, autoreleaseFrequency: .workItem)
    private var metadata: ChatSnapshot?
    private var activity: ActiveSnapshot?
    private struct Pending {
        let ticket = UUID()
        let expectedID: String?
        let needsEnding: Bool
        let deadline: TimeInterval
    }
    private var pending = [String: Pending]()
    private(set) var isReading = false
    private var generation = 0
    private var cancellation: HistoryCancellation?
    private var stopped = false

    init(allowWork: Bool = true,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         read: @escaping Read = { try LastReplyStore.load(chatIDs: $0, from: $1, rolloutPaths: $2) }) {
        self.allowWork = allowWork; self.clock = clock; self.read = read
    }
    deinit { cancellation?.cancel() }

    func updateMetadata(_ snapshot: ChatSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else { return }
        generation += 1; cancellation?.cancel()
        metadata = snapshot; latest = snapshot.lastReplies
    }
    func updateActive(_ snapshot: ActiveSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !stopped else { return }
        func current(_ value: ActiveSnapshot?) -> [String: ActiveChatRow] {
            guard let value, value.connected else { return [:] }
            return Dictionary(value.rows.filter {
                $0.host == "local" && $0.confirmedAt != nil && ["working", "waiting"].contains($0.state)
            }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let old = current(activity), new = current(snapshot)
        let known = Set(metadata?.chats.map(\.id) ?? [])
        for id in Set(old.keys).union(new.keys).intersection(known) {
            if old[id]?.state != new[id]?.state || old[id]?.turnID != new[id]?.turnID {
                pending[id] = Pending(expectedID: new[id]?.turnID ?? old[id]?.turnID,
                                      needsEnding: new[id] == nil, deadline: clock() + 15)
            }
        }
        activity = snapshot
        refreshIfNeeded()
    }
    /// Drops queued/pending results. An already executing bounded read may finish, but cannot publish.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation += 1; cancellation?.cancel(); pending.removeAll()
    }
    func shutdown() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = true; cancel()
    }

    private func refreshIfNeeded() {
        guard allowWork, !stopped, let metadata, !isReading else { return }
        let now = clock(), known = Set(metadata.chats.map(\.id))
        pending = pending.filter { known.contains($0.key) && $0.value.deadline > now }
        let batch = Dictionary(pending.prefix(128).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard !batch.isEmpty else { return }
        isReading = true
        let admittedGeneration = generation, token = HistoryCancellation()
        cancellation = token
        let source = HistoryStore.source(for: metadata), paths = LastReplyStore.rolloutPaths(for: metadata.chats)
        let read = self.read
        queue.async { [weak self] in
            let result = Result {
                guard !token.cancelled else { throw StoreError(message: "Last-turn reconciliation cancelled.") }
                return try read(Array(batch.keys), source, paths)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReading = false
                guard !self.stopped, !token.cancelled, self.generation == admittedGeneration else { return }
                let applicable = Set(batch.keys.filter { self.pending[$0]?.ticket == batch[$0]?.ticket })
                guard !applicable.isEmpty else { return }
                let patch: LastReplySnapshot
                switch result {
                case .success(let value): patch = value
                case .failure(let error): patch = LastReplySnapshot(sourceURL: source, replies: [:], issue: error.localizedDescription)
                }
                self.merge(patch, for: applicable)
                for id in applicable {
                    guard let pending = batch[id], patch.issue == nil, patch.issues[id] == nil else { continue }
                    let turn = patch.replies[id]
                    let matches = pending.expectedID == nil || pending.expectedID == turn?.turnID
                    if matches && (!pending.needsEnding || (turn?.isTerminal == true && turn?.finishedAt != nil)) {
                        self.pending.removeValue(forKey: id)
                    }
                }
                self.onUpdate?(patch, applicable)
            }
        }
    }
    private func merge(_ patch: LastReplySnapshot, for ids: Set<String>) {
        var replies = latest?.replies ?? [:], issues = latest?.issues ?? [:]
        for id in ids {
            if patch.issue == nil { replies[id] = patch.replies[id] }
            issues[id] = patch.issue ?? patch.issues[id]
        }
        latest = LastReplySnapshot(sourceURL: patch.sourceURL, replies: replies, issue: latest?.issue, issues: issues)
    }
}
