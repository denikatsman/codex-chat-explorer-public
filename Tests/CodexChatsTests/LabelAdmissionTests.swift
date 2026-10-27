import XCTest
import ModelSupport
@testable import CodexChats

final class LabelAdmissionTests: XCTestCase {
    private let sample = LabelSample(prompt: "Offline admission fixture; no model or network.", references: ["fixture@1"], hashes: [:], totalMessages: 1, sampledMessages: 1)

    private func fixture(body: String) throws -> (root: URL, worker: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("label-admission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let worker = root.appendingPathComponent("worker")
        // The job marker is already provided to every worker by LabelPolicy.
        let source = """
        #!/bin/sh
        read -r request || exit 2
        id="$EXPLORER_LABEL_JOB"
        \(body)
        """
        try source.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        return (root, worker)
    }

    private let waitingWorker = #"""
    printf '{"kind":"ready","jobID":"%s"}\n' "$id"
    read -r cancellation
    printf '{"kind":"cancelled","jobID":"%s"}\n' "$id"
    """#

    func testProductionGateRejectsOtherWindowWithoutCancellingItsJob() throws {
        let fixture = try fixture(body: waitingWorker)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = LabelCoordinator(workerURL: fixture.worker, jobRoot: fixture.root.appendingPathComponent("first"))
        let second = LabelCoordinator(workerURL: fixture.worker, jobRoot: fixture.root.appendingPathComponent("second"))
        let firstReady = expectation(description: "First worker ready")
        let firstSettled = expectation(description: "First worker exited")
        var firstEvents = [LabelWorkerEvent](), secondEvents = [LabelWorkerEvent]()
        first.onEvent = { event in
            firstEvents.append(event)
            if event.kind == "ready" { firstReady.fulfill() }
            if event.kind == "settled" { firstSettled.fulfill() }
        }
        second.onEvent = { secondEvents.append($0) }
        let firstID = try first.start(provider: .luna, sample: sample)
        wait(for: [firstReady], timeout: 5)
        XCTAssertTrue(LabelCoordinator.hasRunningRequest)
        XCTAssertThrowsError(try second.start(provider: .luna, sample: sample)) { error in
            XCTAssertTrue(error.localizedDescription.contains("another Explorer window"))
        }
        var idleCancellationCompleted = false
        second.cancel { idleCancellationCompleted = true }
        XCTAssertTrue(idleCancellationCompleted)
        XCTAssertTrue(first.isRunning)
        XCTAssertFalse(second.isRunning)
        XCTAssertEqual(second.startedRequests, 0)
        XCTAssertTrue(secondEvents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("second").path))

        first.cancel()
        wait(for: [firstSettled], timeout: 5)
        XCTAssertFalse(LabelCoordinator.hasRunningRequest)
        let secondReady = expectation(description: "Second worker ready")
        let secondSettled = expectation(description: "Second worker exited")
        second.onEvent = { event in
            secondEvents.append(event)
            if event.kind == "ready" { secondReady.fulfill() }
            if event.kind == "settled" { secondSettled.fulfill() }
        }
        let secondID = try second.start(provider: .luna, sample: sample)
        wait(for: [secondReady], timeout: 5)
        first.cancel() // Cancelling the now-idle first window cannot stop the second.
        XCTAssertTrue(second.isRunning)
        second.cancel()
        wait(for: [secondSettled], timeout: 5)
        XCTAssertTrue(firstEvents.allSatisfy { $0.jobID == firstID })
        XCTAssertTrue(secondEvents.allSatisfy { $0.jobID == secondID })
        XCTAssertFalse(LabelCoordinator.hasRunningRequest)
    }

    func testResultDoesNotReleaseAdmissionUntilWorkerExits() throws {
        let fixture = try fixture(body: #"""
        printf '{"kind":"result","jobID":"%s","label":"Offline admission test summary label"}\n' "$id"
        read -r cancellation
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = LabelAdmission()
        let first = LabelCoordinator(workerURL: fixture.worker, jobRoot: fixture.root.appendingPathComponent("jobs"), admission: gate)
        let second = LabelCoordinator(workerURL: fixture.worker, admission: gate)
        let result = expectation(description: "Result precedes exit")
        let settled = expectation(description: "Successful worker exited")
        first.onEvent = { event in
            if event.kind == "result" { result.fulfill() }
            if event.kind == "settled" { XCTAssertEqual(event.label, "Offline admission test summary label"); settled.fulfill() }
        }
        try first.start(provider: .luna, sample: sample)
        wait(for: [result], timeout: 5)
        XCTAssertTrue(gate.isRunning)
        XCTAssertThrowsError(try second.start(provider: .luna, sample: sample))
        first.cancel()
        wait(for: [settled], timeout: 5)
        XCTAssertFalse(gate.isRunning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("jobs").path), [])
    }

    func testSynchronousAndAsynchronousLaunchFailuresReleaseAdmission() throws {
        let fixture = try fixture(body: "exit 1")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = LabelAdmission()
        let missing = LabelCoordinator(workerURL: fixture.root.appendingPathComponent("missing"), jobRoot: fixture.root.appendingPathComponent("missing-jobs"), admission: gate)
        XCTAssertThrowsError(try missing.start(provider: .luna, sample: sample))
        XCTAssertFalse(gate.isRunning)
        XCTAssertEqual(missing.startedRequests, 0)
        let blockedRoot = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedRoot)
        let blocked = LabelCoordinator(workerURL: fixture.worker, jobRoot: blockedRoot, admission: gate)
        XCTAssertThrowsError(try blocked.start(provider: .luna, sample: sample))
        XCTAssertFalse(gate.isRunning)

        // Executable permissions pass validation, but a missing interpreter fails Process.run.
        try "#!/not/an/interpreter\n".write(to: fixture.worker, atomically: false, encoding: .utf8)
        let invalid = LabelCoordinator(workerURL: fixture.worker, jobRoot: fixture.root.appendingPathComponent("invalid-jobs"), admission: gate)
        let settled = expectation(description: "Launch failure settled")
        invalid.onEvent = { event in if event.kind == "settled" { XCTAssertNil(event.label); settled.fulfill() } }
        try invalid.start(provider: .luna, sample: sample)
        wait(for: [settled], timeout: 5)
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(invalid.isRunning)
    }

    func testWorkerErrorAndTimeoutReleaseAdmission() throws {
        let gate = LabelAdmission()
        let errorFixture = try fixture(body: #"""
        printf '{"kind":"error","jobID":"%s","message":"Offline fixture failure"}\n' "$id"
        """#)
        let timeoutFixture = try fixture(body: waitingWorker)
        defer { try? FileManager.default.removeItem(at: errorFixture.root); try? FileManager.default.removeItem(at: timeoutFixture.root) }
        let failed = LabelCoordinator(workerURL: errorFixture.worker, jobRoot: errorFixture.root.appendingPathComponent("jobs"), admission: gate)
        let failedSettled = expectation(description: "Worker failure settled")
        failed.onEvent = { event in if event.kind == "settled" { XCTAssertEqual(event.message, "Offline fixture failure"); failedSettled.fulfill() } }
        try failed.start(provider: .luna, sample: sample)
        wait(for: [failedSettled], timeout: 5)
        XCTAssertFalse(gate.isRunning)

        let timedOut = LabelCoordinator(workerURL: timeoutFixture.worker, jobRoot: timeoutFixture.root.appendingPathComponent("jobs"), admission: gate, workerTimeout: 0.2)
        let timedOutSettled = expectation(description: "Watchdog stopped worker")
        timedOut.onEvent = { event in if event.kind == "settled" { timedOutSettled.fulfill() } }
        try timedOut.start(provider: .luna, sample: sample)
        wait(for: [timedOutSettled], timeout: 5)
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(timedOut.isRunning)
    }

    func testCoordinatorDeinitStopsWorkerBeforeReleasingAdmission() throws {
        let fixture = try fixture(body: waitingWorker)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = LabelAdmission()
        var owner: LabelCoordinator? = LabelCoordinator(workerURL: fixture.worker, jobRoot: fixture.root.appendingPathComponent("jobs"), admission: gate)
        weak var weakOwner = owner
        let ready = expectation(description: "Owned worker ready")
        owner?.onEvent = { event in if event.kind == "ready" { ready.fulfill() } }
        let jobID = try XCTUnwrap(owner).start(provider: .luna, sample: sample)
        wait(for: [ready], timeout: 5)
        owner = nil
        XCTAssertNil(weakOwner)
        let released = expectation(description: "Orphan worker cleanup released admission")
        DispatchQueue.global().async {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while gate.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            released.fulfill()
        }
        wait(for: [released], timeout: 6)
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("jobs/\(jobID)").path))
    }
}
