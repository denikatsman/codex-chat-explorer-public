import Foundation

struct ActiveChatRow: Codable, Equatable {
    let id: String
    let host: String
    let title: String
    let state: String
    let confirmedAt: Double?
    var turnID: String? = nil
}
struct ActiveSnapshot: Codable {
    let connected: Bool
    let sequence: Int
    let observedAt: Double
    let rows: [ActiveChatRow]
    let pending: Int
    let warning: String
    let queryMs: Double
    let bytesReceived: Int
    var confirmedCount: Int {
        guard connected else { return 0 }
        return Set(rows.lazy.filter {
            $0.host == "local" && $0.confirmedAt != nil && ["working", "waiting"].contains($0.state)
        }.map(\.id)).count
    }
}

// Every revision belongs to a particular owner. A lost owner can never leave a
// confirmed RUNNING row behind while the broker socket itself remains connected.
struct ActiveLifecycle {
    struct Receipt {
        var owner: String
        var revision: Int
        var state: [String: Any]?
        var confirmedAt: Double?
        var awaitingSnapshot: Bool
        var lastResync: Double = 0
        var latestTurnID: String? {
            guard let turns = state?["turns"] as? [[String: Any]], let last = turns.last else { return nil }
            return last["id"] as? String ?? last["turnId"] as? String
        }
    }
    var metadata = [String: String]()
    var candidates = [String: Int]()
    var discovered = Set<String>()
    var receipts = [String: Receipt]()
    var suppressed = [String: Int]()
    var warning = ""
    private(set) var retiredOwners = Set<String>()

    var targets: Set<String> {
        let known = Set(metadata.keys)
        let active = receipts.filter { Self.status($0.value.state) != "idle" }.map(\.key)
        return Set(candidates.keys).union(discovered).union(active).intersection(known).filter { suppressed[$0] != (candidates[$0] ?? -1) }
    }
    static func status(_ state: [String: Any]?) -> String {
        guard let state else { return "unknown" }
        let runtime = state["threadRuntimeStatus"]
        let object = runtime as? [String: Any]
        let kind = object?["type"] as? String ?? object?["status"] as? String ?? runtime as? String ?? ""
        if ["idle", "completed", "failed", "interrupted"].contains(kind) { return "idle" }
        if ["notLoaded", "systemError"].contains(kind) { return "unknown" }
        let requests = state["requests"]
        let pending = (requests as? [Any])?.count ?? (requests as? [String: Any])?.count ?? 0
        let flags = object?["activeFlags"] as? [String] ?? []
        if pending > 0 || ["waitingForApproval", "waitingForInput"].contains(kind) || flags.contains(where: { $0.lowercased().contains("waiting") }) { return "waiting" }
        if ["active", "running", "busy"].contains(kind) { return "working" }
        let turns = state["turns"] as? [[String: Any]] ?? []
        if turns.contains(where: { ["inProgress", "running"].contains($0["status"] as? String ?? "") }) { return "working" }
        if !turns.isEmpty && turns.allSatisfy({ ["completed", "failed", "interrupted", "idle"].contains($0["status"] as? String ?? "") }) { return "idle" }
        return "unknown"
    }
    mutating func disconnected(_ reason: String) {
        for id in receipts.keys { receipts[id]?.state = nil; receipts[id]?.awaitingSnapshot = true }
        retiredOwners.removeAll(); warning = reason
    }
    mutating func invalidateOwner(_ owner: String) -> Set<String> {
        let affected = Set(receipts.filter { $0.value.owner == owner }.map(\.key))
        if !affected.isEmpty {
            retiredOwners.insert(owner)
            if retiredOwners.count > 256, let oldest = retiredOwners.first(where: { $0 != owner }) { retiredOwners.remove(oldest) }
        }
        for id in affected { receipts[id]?.state = nil; receipts[id]?.awaitingSnapshot = true }
        return affected
    }
    mutating func reconcileTerminal(_ id: String, turnID: String, completedAt: Double, now: Double) -> Bool {
        guard var receipt = receipts[id], receipt.latestTurnID == turnID,
              ["working", "waiting"].contains(Self.status(receipt.state)),
              completedAt >= floor(receipt.confirmedAt ?? 0), now - receipt.lastResync > 5 else { return false }
        receipt.state = nil; receipt.awaitingSnapshot = true; receipt.lastResync = now
        receipts[id] = receipt; warning = "Reconfirming a runtime/history mismatch."
        return true
    }
    mutating func message(_ message: [String: Any], clientID: String, now: Double) -> Set<String> {
        guard message["type"] as? String == "broadcast" else { return [] }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "client-status-changed", params["status"] as? String == "disconnected", let owner = params["clientId"] as? String { return invalidateOwner(owner) }
        if method == "ipc-connection-reset" { disconnected("Codex connection reset; reconfirming statuses."); return targets }
        guard (params["hostId"] as? String ?? "local") == "local", let id = params["conversationId"] as? String, metadata[id] != nil else { return [] }
        let owner = message["sourceClientId"] as? String ?? ""
        guard owner != clientID else { return [] }
        if method == "thread-stream-following-changed" {
            if params["following"] as? Bool == true {
                // A viewer opening an idle chat is not an activity hint. Avoid
                // eagerly transferring its full conversation just to learn that.
                guard candidates[id] != nil || receipts[id] != nil else { return [] }
                discovered.insert(id); suppressed.removeValue(forKey: id); return [id]
            }
            if receipts[id]?.owner == owner { receipts[id]?.state = nil; receipts[id]?.awaitingSnapshot = true; return [id] }
            return []
        }
        if method == "thread-stream-following-status-requested" { return targets.contains(id) ? [id] : [] }
        guard method == "thread-stream-state-changed" else { return [] }
        // The broker can publish unrelated viewers' packets. They must not
        // create a receipt/subscription and prefetch an idle chat's history.
        guard targets.contains(id) else { return [] }
        guard message["version"] as? Int == 11, !owner.isEmpty, !retiredOwners.contains(owner) else {
            if message["version"] as? Int != 11 { warning = "Unsupported Codex live protocol; statuses are unconfirmed."; receipts[id]?.state = nil }
            return []
        }
        let change = params["change"] as? [String: Any] ?? [:]
        guard let revision = change["revision"] as? Int else { return invalidate(id, owner: owner, now: now) }
        let previous = receipts[id]
        let snapshot = change["type"] as? String == "snapshot"
        // A snapshot selects the publishing owner. Like the desktop follower,
        // ignore another client's stale patches; they don't revoke that owner.
        if !snapshot, let previous, previous.owner != owner { return [] }
        if let previous, previous.owner == owner, revision <= previous.revision, !(snapshot && previous.awaitingSnapshot) { return [] }
        do {
            var state: [String: Any]
            var relevant = snapshot
            if snapshot {
                guard let value = change["conversationState"] as? [String: Any] else { throw StoreError(message: "Missing runtime snapshot.") }
                state = value
            } else {
                guard change["type"] as? String == "patches", let previous, previous.owner == owner,
                      !previous.awaitingSnapshot, previous.revision == change["baseRevision"] as? Int,
                      let existing = previous.state, let patches = change["patches"] as? [[String: Any]] else {
                    let cause = previous == nil ? "initial runtime snapshot pending" : previous?.owner != owner ? "stream owner changed" : previous?.awaitingSnapshot == true ? "replacement runtime snapshot pending" : "runtime revision gap"
                    return invalidate(id, owner: owner, now: now, reason: cause)
                }
                state = existing
                for patch in patches {
                    let path = patch["path"] as? [Any] ?? []
                    let field = path.first as? String ?? ""
                    guard path.isEmpty || ["threadRuntimeStatus", "requests", "turns"].contains(field) else { continue }
                    if field == "requests", path.count > 2 { continue }
                    if field == "turns", path.count > 2, !["id", "turnId", "status"].contains(path[2] as? String ?? "") { continue }
                    relevant = true
                    var node: Any = state
                    try Self.apply(&node, path: path, operation: patch["op"] as? String ?? "", value: patch["value"] ?? NSNull())
                    guard let updated = node as? [String: Any] else { throw StoreError(message: "Invalid runtime patch.") }
                    state = updated
                }
            }
            receipts[id] = Receipt(owner: owner, revision: revision, state: state,
                confirmedAt: relevant ? now : previous?.confirmedAt, awaitingSnapshot: false, lastResync: previous?.lastResync ?? 0)
            if Self.status(state) == "idle" { suppressed[id] = candidates[id] ?? -1; discovered.remove(id) }
            if warning.hasPrefix("Reconfirming") { warning = "" }
            return []
        } catch { return invalidate(id, owner: owner, now: now, reason: "unsupported lifecycle patch: \(error.localizedDescription)") }
    }
    private mutating func invalidate(_ id: String, owner: String, now: Double, reason: String = "missing or restarted runtime stream") -> Set<String> {
        let last = receipts[id]?.lastResync ?? 0
        receipts[id] = Receipt(owner: owner, revision: receipts[id]?.revision ?? -1, state: nil,
            confirmedAt: receipts[id]?.confirmedAt, awaitingSnapshot: true, lastResync: last)
        warning = "Reconfirming \(reason)."
        guard now - last >= 5 else { return [] }
        receipts[id]?.lastResync = now
        return [id]
    }
    private static func apply(_ node: inout Any, path: [Any], operation: String, value: Any) throws {
        guard ["add", "replace", "remove"].contains(operation) else { throw StoreError(message: "Unknown runtime patch operation.") }
        if path.isEmpty { guard operation == "replace" else { throw StoreError(message: "Invalid runtime root patch.") }; node = value; return }
        let key = String(describing: path[0])
        if var dictionary = node as? [String: Any] {
            if path.count == 1 {
                if operation == "remove" { dictionary.removeValue(forKey: key) } else { dictionary[key] = value }
            } else {
                guard var child = dictionary[key] else { throw StoreError(message: "Missing runtime patch parent.") }
                try apply(&child, path: Array(path.dropFirst()), operation: operation, value: value); dictionary[key] = child
            }
            node = dictionary; return
        }
        if var array = node as? [Any] {
            let index = key == "-" ? array.count : Int(key) ?? -1
            if path.count == 1, operation == "add", (0...array.count).contains(index) { array.insert(value, at: index) }
            else {
                guard array.indices.contains(index) else { throw StoreError(message: "Invalid runtime patch index.") }
                if path.count == 1 {
                    if operation == "remove" { array.remove(at: index) } else { array[index] = value }
                } else { var child = array[index]; try apply(&child, path: Array(path.dropFirst()), operation: operation, value: value); array[index] = child }
            }
            node = array; return
        }
        throw StoreError(message: "Invalid runtime patch target.")
    }
    func rows(connected: Bool) -> [ActiveChatRow] {
        receipts.compactMap { id, receipt in
            let state = connected ? Self.status(receipt.state) : "unknown"
            guard metadata[id] != nil, state != "idle" else { return nil }
            return ActiveChatRow(id: id, host: "local", title: metadata[id] ?? id, state: state, confirmedAt: receipt.confirmedAt, turnID: receipt.latestTurnID)
        }.sorted { ($0.state == "unknown" ? 1 : 0, $0.title, $0.id) < ($1.state == "unknown" ? 1 : 0, $1.title, $1.id) }
    }
}
