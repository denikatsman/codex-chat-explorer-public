import XCTest
@testable import CodexChats

/// Injected recorded values only; these tests open no source database and create no windows.
final class LastTurnReconcilerTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixture/thread_history_1.sqlite")
    private final class Reader {
        struct Call { let ids: Set<String>; let source: URL; let paths: [String: URL] }
        private let lock = NSLock()
        private var recorded = [Call]()
        private var result: Result<LastReplySnapshot, Error>
        private var entered: XCTestExpectation?
        private var gate: DispatchSemaphore?
        init(_ snapshot: LastReplySnapshot) { result = .success(snapshot) }
        var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
        func configure(_ result: Result<LastReplySnapshot, Error>, entered: XCTestExpectation? = nil, gate: DispatchSemaphore? = nil) {
            lock.lock(); self.result = result; self.entered = entered; self.gate = gate; lock.unlock()
        }
        func load(_ ids: [String], _ source: URL, _ paths: [String: URL]) throws -> LastReplySnapshot {
            lock.lock()
            recorded.append(Call(ids: Set(ids), source: source, paths: paths))
            let result = self.result, entered = self.entered, gate = self.gate
            lock.unlock()
            entered?.fulfill()
            if let gate, gate.wait(timeout: .now() + 4) != .success { throw StoreError(message: "Fixture gate timed out") }
            return try result.get()
        }
    }
    private func metadata(_ ids: [String], seed: LastReplySnapshot? = nil, directory: String = "/fixture") -> ChatSnapshot {
        let project = ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil)
        let chats = ids.map { id in
            Chat(original: ["rollout_path": .text(Data("/fixture/\(id).jsonl".utf8))], id: id, title: id, createdAt: nil, archived: false, issues: [], project: project)
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("state_5.sqlite")
        return ChatSnapshot(chats: chats, sourceURL: url, observedAt: Date(), excludedSubagents: 0, projectSourceURL: url, projectSourceIssue: nil, lastReplies: seed)
    }
    private func row(_ id: String, turn: String = "turn", state: String = "working", host: String = "local", confirmed: Double? = 1) -> ActiveChatRow {
        ActiveChatRow(id: id, host: host, title: id, state: state, confirmedAt: confirmed, turnID: turn)
    }
    private func active(_ rows: [ActiveChatRow], connected: Bool = true) -> ActiveSnapshot {
        ActiveSnapshot(connected: connected, sequence: 1, observedAt: 1, rows: rows, pending: 0, warning: "", queryMs: 0, bytesReceived: 0)
    }
    private func turn(_ id: String = "turn", status: String = "inProgress", finished: SQLiteValue = .null) -> LastReply {
        LastReply(original: ["turn_id": .text(Data(id.utf8)), "status": .text(Data(status.utf8)), "started_at": .integer(100), "completed_at": finished])
    }
    private func patch(_ replies: [String: LastReply] = [:], issue: String? = nil) -> LastReplySnapshot {
        LastReplySnapshot(sourceURL: source, replies: replies, issue: issue)
    }
    @discardableResult private func refresh(_ service: LastTurnReconciler, reader: Reader, active: ActiveSnapshot, result: Result<LastReplySnapshot, Error>) -> Set<String> {
        reader.configure(result)
        var ids = Set<String>()
        let published = expectation(description: "Applicable recorded patch published")
        service.onUpdate = { _, affected in ids = affected; published.fulfill() }
        service.updateActive(active)
        wait(for: [published], timeout: 5)
        service.onUpdate = nil
        return ids
    }
    private func waitForRead(_ service: LastTurnReconciler) {
        let done = expectation(description: "Bounded read drained")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { timer in
            if !service.isReading { timer.invalidate(); done.fulfill() }
        }
        wait(for: [done], timeout: 5); timer.invalidate()
    }

    func testOnlyKnownConfirmedLocalActivityTriggersOneReadAndPreservesOtherRows() {
        let initial = patch(["b": turn("saved")]), reader = Reader(patch())
        let service = LastTurnReconciler(read: reader.load)
        service.updateMetadata(metadata(["a", "b", "c"], seed: initial))
        let activity = active([row("a"), row("b", host: "remote"), row("c", confirmed: nil), row("unknown")])
        XCTAssertEqual(refresh(service, reader: reader, active: activity, result: .success(patch(["a": turn()]))), ["a"])
        XCTAssertEqual(reader.calls.count, 1)
        XCTAssertEqual(reader.calls.first?.ids, ["a"])
        XCTAssertEqual(reader.calls.first?.source, source)
        XCTAssertEqual(reader.calls.first?.paths["a"]?.path, "/fixture/a.jsonl")
        XCTAssertEqual(service.latest?.replies["b"]?.turnID, "saved")
        for _ in 0..<10 { service.updateActive(activity) }
        XCTAssertEqual(reader.calls.count, 1, "Identical activity must not cause duplicate per-window reconciliation")
        service.shutdown()
    }

    func testEndingRetriesWrongIDsMalformedEndingsAndReadFailuresUntilRecordedTerminalEnd() {
        let reader = Reader(patch()), service = LastTurnReconciler(read: { ids, source, paths in try reader.load(ids, source, paths) })
        service.updateMetadata(metadata(["a"]))
        refresh(service, reader: reader, active: active([row("a")]), result: .success(patch(["a": turn()])))
        let ended = active([])
        refresh(service, reader: reader, active: ended, result: .success(patch(["a": turn("wrong", status: "completed", finished: .integer(200))])))
        refresh(service, reader: reader, active: ended, result: .success(patch(["a": turn(status: "completed", finished: .text(Data("malformed".utf8)))])))
        refresh(service, reader: reader, active: ended, result: .failure(StoreError(message: "Temporary read failure")))
        XCTAssertEqual(service.latest?.replies["a"]?.original["completed_at"], .text(Data("malformed".utf8)))
        XCTAssertEqual(service.latest?.issues["a"], "Temporary read failure")
        refresh(service, reader: reader, active: ended, result: .success(patch(["a": turn(status: "interrupted", finished: .integer(200))])))
        XCTAssertNil(service.latest?.issues["a"])
        XCTAssertEqual(service.latest?.replies["a"]?.finishedAt, Date(timeIntervalSince1970: 200))
        service.updateActive(ended)
        XCTAssertEqual(reader.calls.count, 5)
        service.shutdown()
    }

    func testNewTurnTicketRejectsInFlightOldTurnAndSerializesReads() {
        let reader = Reader(patch()), service = LastTurnReconciler(read: reader.load)
        service.updateMetadata(metadata(["a"]))
        let gate = DispatchSemaphore(value: 0), entered = expectation(description: "Old read entered")
        reader.configure(.success(patch(["a": turn("old")])), entered: entered, gate: gate)
        var updates = 0; service.onUpdate = { _, _ in updates += 1 }
        service.updateActive(active([row("a", turn: "old")]))
        wait(for: [entered], timeout: 5)
        let replacement = active([row("a", turn: "new")])
        for _ in 0..<10 { service.updateActive(replacement) }
        XCTAssertEqual(reader.calls.count, 1)
        gate.signal(); waitForRead(service)
        XCTAssertEqual(updates, 0)
        XCTAssertNil(service.latest)
        refresh(service, reader: reader, active: replacement, result: .success(patch(["a": turn("new")])))
        XCTAssertEqual(service.latest?.replies["a"]?.turnID, "new")
        XCTAssertEqual(reader.calls.count, 2)
        service.shutdown()
    }

    func testMetadataReplacementRejectsOldReadAndUsesLatestSourceOnRetry() {
        let reader = Reader(patch()), service = LastTurnReconciler(read: reader.load)
        service.updateMetadata(metadata(["a"]))
        let gate = DispatchSemaphore(value: 0), entered = expectation(description: "Old metadata read entered")
        reader.configure(.success(patch(["a": turn("stale")])), entered: entered, gate: gate)
        var updates = 0; service.onUpdate = { _, _ in updates += 1 }
        let activity = active([row("a")])
        service.updateActive(activity); wait(for: [entered], timeout: 5)
        service.updateMetadata(metadata(["a"], seed: patch(["a": turn("refreshed")]), directory: "/replacement"))
        gate.signal(); waitForRead(service)
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(service.latest?.replies["a"]?.turnID, "refreshed")
        refresh(service, reader: reader, active: activity, result: .success(patch(["a": turn()])))
        XCTAssertEqual(reader.calls.last?.source.path, "/replacement/thread_history_1.sqlite")
        service.shutdown()
    }

    func testDeadlineAndBatchLimitAreBoundedWithoutATimer() {
        var now: TimeInterval = 100
        let reader = Reader(patch()), service = LastTurnReconciler(clock: { now }, read: reader.load)
        service.updateMetadata(metadata(["a"]))
        let activity = active([row("a")])
        refresh(service, reader: reader, active: activity, result: .success(patch(["a": turn("wrong")])))
        now = 114.99
        refresh(service, reader: reader, active: activity, result: .success(patch(["a": turn("wrong")])))
        now = 115
        service.updateActive(activity)
        XCTAssertEqual(reader.calls.count, 2)
        service.shutdown()

        let batchReader = Reader(patch()), batchService = LastTurnReconciler(read: batchReader.load)
        let ids = (0..<200).map { "chat-\($0)" }
        batchService.updateMetadata(metadata(ids))
        let allActive = active(ids.map { row($0) }), allReplies = patch(Dictionary(uniqueKeysWithValues: ids.map { ($0, turn()) }))
        let first = refresh(batchService, reader: batchReader, active: allActive, result: .success(allReplies))
        let second = refresh(batchService, reader: batchReader, active: allActive, result: .success(allReplies))
        XCTAssertEqual(first.count, 128); XCTAssertEqual(second.count, 72)
        XCTAssertTrue(first.isDisjoint(with: second)); XCTAssertEqual(first.union(second), Set(ids))
        XCTAssertEqual(batchReader.calls.map { $0.ids.count }, [128, 72])
        batchService.shutdown()
    }

    func testCancelShutdownAndDisabledViewsNeverPublishLateResultsOrAdmitNewWork() {
        let reader = Reader(patch()), service = LastTurnReconciler(read: reader.load)
        service.updateMetadata(metadata(["a"]))
        let gate = DispatchSemaphore(value: 0), entered = expectation(description: "Cancelled read entered")
        reader.configure(.success(patch(["a": turn()])), entered: entered, gate: gate)
        var updates = 0; service.onUpdate = { _, _ in updates += 1 }
        let activity = active([row("a")])
        service.updateActive(activity); wait(for: [entered], timeout: 5)
        service.cancel(); service.shutdown(); gate.signal(); waitForRead(service)
        service.updateActive(active([row("a", turn: "new")]))
        XCTAssertEqual(updates, 0); XCTAssertEqual(reader.calls.count, 1)

        let inert = LastTurnReconciler(allowWork: false, read: { _, _, _ in
            XCTFail("Disabled fixture views cannot read recorded turns")
            throw StoreError(message: "Disabled")
        })
        inert.updateMetadata(metadata(["a"], seed: patch(["a": turn("seed")])))
        inert.updateActive(activity)
        XCTAssertFalse(inert.isReading)
        XCTAssertEqual(inert.latest?.replies["a"]?.turnID, "seed")
        inert.shutdown()
    }
}
