import XCTest
@testable import CodexChats

final class ActiveStatusTests: XCTestCase {
    private func frame(owner: String = "owner-a", revision: Int = 1, runtime: String = "running", turnStatus: String = "inProgress") -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": owner, "version": 11,
         "params": ["hostId": "local", "conversationId": "chat", "change": ["type": "snapshot", "revision": revision,
           "conversationState": ["threadRuntimeStatus": runtime, "turns": [["id": "turn", "status": turnStatus]], "requests": [:]]]]]
    }
    private func patches(_ values: [[String: Any]], revision: Int, base: Int) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": "owner-a", "version": 11,
         "params": ["hostId": "local", "conversationId": "chat", "change": ["type": "patches", "baseRevision": base, "revision": revision, "patches": values]]]
    }
    private func initial() -> ActiveLifecycle {
        var state = ActiveLifecycle(); state.metadata = ["chat": "Fixture"]; state.candidates = ["chat": 1]; return state
    }
    func testOwnerLossInvalidatesEvenWhenBrokerRemainsConnected() {
        var state = initial()
        _ = state.message(frame(), clientID: "observer", now: 100)
        XCTAssertEqual(state.rows(connected: true).first?.state, "working")
        let lost: [String: Any] = ["type": "broadcast", "method": "client-status-changed", "params": ["clientId": "owner-a", "status": "disconnected"]]
        XCTAssertEqual(state.message(lost, clientID: "observer", now: 101), ["chat"])
        XCTAssertEqual(state.rows(connected: true).first?.state, "unknown")
        _ = state.message(frame(owner: "owner-b", revision: 0, runtime: "waitingForInput"), clientID: "observer", now: 102)
        XCTAssertEqual(state.rows(connected: true).first?.state, "waiting")
        _ = state.message(frame(revision: 999), clientID: "observer", now: 103)
        XCTAssertEqual(state.rows(connected: true).first?.state, "waiting")
        state.disconnected("Lost broker")
        XCTAssertEqual(state.rows(connected: false).first?.state, "unknown")
    }
    func testRevisionGapResetAndTerminalUpdate() {
        var state = initial()
        _ = state.message(frame(revision: 9), clientID: "observer", now: 100)
        let broken = patches([["op": "replace", "path": ["threadRuntimeStatus"], "value": "idle"]], revision: 11, base: 10)
        XCTAssertEqual(state.message(broken, clientID: "observer", now: 110), ["chat"])
        XCTAssertEqual(state.rows(connected: true).first?.state, "unknown")
        _ = state.message(frame(revision: 0), clientID: "observer", now: 111)
        XCTAssertEqual(state.rows(connected: true).first?.state, "working")
        let finished = patches([["op": "replace", "path": ["threadRuntimeStatus"], "value": "idle"]], revision: 1, base: 0)
        _ = state.message(finished, clientID: "observer", now: 112)
        XCTAssertTrue(state.rows(connected: true).isEmpty)
        XCTAssertFalse(state.targets.contains("chat"))
    }
    func testMissingTerminalReceiptRequiresConfirmationWithoutInferringIdle() {
        var state = initial()
        _ = state.message(frame(), clientID: "observer", now: 100.8)
        XCTAssertTrue(state.reconcileTerminal("chat", turnID: "turn", completedAt: 100, now: 110))
        XCTAssertEqual(state.rows(connected: true).first?.state, "unknown")
        _ = state.message(frame(revision: 2, runtime: "idle", turnStatus: "completed"), clientID: "observer", now: 111)
        XCTAssertTrue(state.rows(connected: true).isEmpty)
    }
    func testOpaqueBodiesAreSkippedAndDoNotPretendToConfirmStatus() throws {
        var message = frame()
        var params = message["params"] as! [String: Any]
        var change = params["change"] as! [String: Any]
        var content = change["conversationState"] as! [String: Any]
        content["turns"] = [["id": "turn", "status": "inProgress", "items": [["secret": String(repeating: "private content ", count: 300_000)]]]]
        change["conversationState"] = content; params["change"] = change; message["params"] = params
        let bytes = try JSONSerialization.data(withJSONObject: message)
        let projected = try ActiveJSONReader.decode(bytes, clientID: "observer")
        let compact = try JSONSerialization.data(withJSONObject: projected)
        XCTAssertLessThan(compact.count, 1000)
        XCTAssertFalse(String(data: compact, encoding: .utf8)!.contains("private content"))
        var state = initial(); _ = state.message(projected, clientID: "observer", now: 100)
        let opaque = patches([["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "more private content"]], revision: 2, base: 1)
        _ = state.message(opaque, clientID: "observer", now: 101)
        XCTAssertEqual(state.receipts["chat"]?.revision, 2)
        XCTAssertEqual(state.receipts["chat"]?.confirmedAt, 100)
        XCTAssertThrowsError(try ActiveJSONReader.decode(Data("{partial".utf8), clientID: "observer"))
        var unsupported = frame(); unsupported["version"] = 999
        _ = state.message(unsupported, clientID: "observer", now: 102)
        XCTAssertEqual(state.rows(connected: true).first?.state, "unknown")
    }
    func testOpeningIdleChatsDoesNotCauseHistoryPrefetch() {
        var state = ActiveLifecycle(); state.metadata = ["idle": "Idle fixture"]
        let message: [String: Any] = ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "another-viewer",
            "params": ["hostId": "local", "conversationId": "idle", "following": true]]
        XCTAssertTrue(state.message(message, clientID: "observer", now: 100).isEmpty)
        XCTAssertTrue(state.targets.isEmpty)
        var unrelated = frame(); var parameters = unrelated["params"] as! [String:Any]
        parameters["conversationId"] = "idle"; unrelated["params"] = parameters
        XCTAssertTrue(state.message(unrelated,clientID:"observer",now:101).isEmpty)
        XCTAssertTrue(state.receipts.isEmpty)
        state.candidates["idle"] = 1
        XCTAssertEqual(state.message(message, clientID: "observer", now: 101), ["idle"])
    }

    func testResnapshotDoesNotResetReconfirmationBackoff() {
        var state=initial()
        _=state.message(frame(revision:1),clientID:"observer",now:100)
        let gap=patches([],revision:4,base:3)
        XCTAssertEqual(state.message(gap,clientID:"observer",now:110),["chat"])
        _=state.message(frame(revision:4),clientID:"observer",now:111)
        let nextGap=patches([],revision:8,base:7)
        XCTAssertTrue(state.message(nextGap,clientID:"observer",now:112).isEmpty)
        XCTAssertEqual(state.receipts["chat"]?.lastResync,110)
        XCTAssertEqual(state.rows(connected:true).first?.state,"unknown")
    }

    func testStaleOtherOwnerPatchesDoNotCauseSnapshotPingPong() {
        var state=initial()
        _=state.message(frame(),clientID:"observer",now:100)
        var other=patches([],revision:400,base:399); other["sourceClientId"]="other-client"
        XCTAssertTrue(state.message(other,clientID:"observer",now:101).isEmpty)
        XCTAssertEqual(state.receipts["chat"]?.owner,"owner-a")
        XCTAssertEqual(state.rows(connected:true).first?.state,"working")
        _=state.message(frame(owner:"owner-b",revision:0,runtime:"waitingForInput"),clientID:"observer",now:102)
        XCTAssertTrue(state.message(patches([],revision:2,base:1),clientID:"observer",now:103).isEmpty)
        XCTAssertEqual(state.receipts["chat"]?.owner,"owner-b")
        XCTAssertEqual(state.rows(connected:true).first?.state,"waiting")
        XCTAssertEqual(state.receipts["chat"]?.revision,0)
    }

    func testSocketFramesReleaseConsumedStorageAndHandleFragmentedPackets() throws {
        let payload = Data(repeating:120,count:256)
        var length=UInt32(payload.count).littleEndian
        let packet=withUnsafeBytes(of:&length){Data($0)}+payload
        var buffer=ActiveFrameBuffer(maximumPayload:1024)
        for _ in 0..<100_000 {
            try buffer.append(packet.prefix(3)); XCTAssertNil(try buffer.next())
            try buffer.append(Data(packet.dropFirst(3)))
            XCTAssertEqual(try buffer.next(),payload)
            XCTAssertEqual(buffer.pendingBytes,0)
            XCTAssertEqual(buffer.retainedBytes,0)
        }
        try buffer.append(packet+packet.prefix(3))
        XCTAssertEqual(try buffer.next(),payload); XCTAssertNil(try buffer.next())
        buffer.compact(); XCTAssertEqual(buffer.retainedBytes,3)
        try buffer.append(Data(packet.dropFirst(3)))
        XCTAssertEqual(try buffer.next(),payload); XCTAssertEqual(buffer.retainedBytes,0)
        var invalid=ActiveFrameBuffer(maximumPayload:32)
        try invalid.append(Data([33,0,0,0])); XCTAssertThrowsError(try invalid.next())
        var overflow=ActiveFrameBuffer(maximumPayload:32)
        XCTAssertThrowsError(try overflow.append(Data(repeating:0,count:65_537)))
    }

    func testNativeObserverStopsAndDoesNotCreateSourcesOrAHelper() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("active-source-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = expectation(description: "Explicit unavailable status")
        var delivered = false
        let source = ActiveStatusSource(home: home)
        source.onSnapshot = { value in
            if !delivered { delivered = true; XCTAssertFalse(value.connected); first.fulfill() }
        }
        source.start()
        wait(for: [first], timeout: 3)
        source.stop()
        let after = expectation(description: "No update after stop"); after.isInverted = true
        source.onSnapshot = { _ in after.fulfill() }
        wait(for: [after], timeout: 0.15)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }
}
