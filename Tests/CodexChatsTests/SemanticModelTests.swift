import XCTest
import Foundation
import ModelSupport
import Darwin
@testable import CodexChats

final class SemanticModelTests: XCTestCase {
    func testBoundsRejectBeforeRuntimeStartup() throws {
        let runtime = SemanticModelRuntime(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertThrowsError(try runtime.embed([], cancellation: HistoryCancellation()))
        XCTAssertThrowsError(try runtime.embed(Array(repeating: "x", count: 9), cancellation: HistoryCancellation()))
        XCTAssertThrowsError(try runtime.embed([String(repeating: "x", count: 12_001)], cancellation: HistoryCancellation()))
        XCTAssertThrowsError(try runtime.rerank(query: "x", passages: Array(repeating: "x", count: 13), cancellation: HistoryCancellation()))
        runtime.stop(); runtime.stop()
        XCTAssertTrue(runtime.cleanupConfirmed)
    }
    func testCancelledRequestDoesNotStartModel() throws {
        let runtime = SemanticModelRuntime()
        let token = HistoryCancellation(); token.cancel()
        XCTAssertThrowsError(try runtime.embed(["A source passage"], cancellation: token)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cancelled"))
        }
    }
    func testWarmPolicyCanChangeWithoutStartingWorker() {
        let runtime = SemanticModelRuntime()
        XCTAssertFalse(runtime.keepWarm)
        runtime.keepWarm = true; XCTAssertTrue(runtime.keepWarm)
        runtime.keepWarm = false; XCTAssertFalse(runtime.keepWarm)
        runtime.stop()
    }
    func testUnresponsiveOwnedRuntimeAndDescendantAreForceStoppedWithinBound() throws {
        let id = UUID().uuidString
        let fixture = "import signal,subprocess,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print('{\"ready\":true}',flush=True); time.sleep(60)"
        let owned = try OwnedModelProcess(executable: "/usr/bin/python3", arguments: ["-c", fixture], environment: LabelPolicy.safeEnvironment(jobID: id), directory: FileManager.default.temporaryDirectory.path, jobID: id, captureOutput: true)
        let ready = try owned.nextJSON(deadline: ProcessInfo.processInfo.systemUptime + 3, cancellation: nil)
        XCTAssertEqual(ready["ready"] as? Bool, true)
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(owned.stop(), "Forced cleanup must remove the entire marked process group")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 4.5)
        // Foundation may deliver its termination notification slightly after SIGKILL. Verify
        // actual generation/state and all marked group members rather than that cached flag.
        XCTAssertTrue(OwnedModelProcess.isStopped(owned.identity))
    }

    func testLargeBlockedWriteCanBeCancelledAndStopped() throws {
        let id = UUID().uuidString
        let fixture = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('{\"ready\":true}',flush=True); time.sleep(60)"
        let owned = try OwnedModelProcess(executable: "/usr/bin/python3", arguments: ["-c", fixture], environment: LabelPolicy.safeEnvironment(jobID: id), directory: FileManager.default.temporaryDirectory.path, jobID: id)
        _ = try owned.nextJSON(deadline: ProcessInfo.processInfo.systemUptime + 3, cancellation: nil)
        let cancelled = HistoryCancellation(), completed = expectation(description: "bounded pipe writer returns")
        DispatchQueue.global().async {
            do {
                try owned.sendBounded(["text": String(repeating: "x", count: 65_536)], deadline: ProcessInfo.processInfo.systemUptime + 30, cancelled: { cancelled.cancelled })
                XCTFail("A full pipe must not bypass cancellation")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("cancelled"), error.localizedDescription)
            }
            completed.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.15)
        let began = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        XCTAssertTrue(owned.stop())
        wait(for: [completed], timeout: 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 4.5)
    }

    func testLargeBlockedWriteHasItsOwnDeadline() throws {
        let id = UUID().uuidString
        let fixture = "import time; print('{\"ready\":true}',flush=True); time.sleep(60)"
        let owned = try OwnedModelProcess(executable: "/usr/bin/python3", arguments: ["-c", fixture], environment: LabelPolicy.safeEnvironment(jobID: id), directory: FileManager.default.temporaryDirectory.path, jobID: id)
        _ = try owned.nextJSON(deadline: ProcessInfo.processInfo.systemUptime + 3, cancellation: nil)
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try owned.sendBounded(["text": String(repeating: "x", count: 200_000)], deadline: began + 0.25, cancelled: { false })) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertTrue(owned.stop())
    }

    private func worker() throws -> (Process, Pipe, Pipe) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/SemanticModelWorker")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build SemanticModelWorker to exercise its process lifecycle.") }
        let input = Pipe(), output = Pipe(), process = Process()
        process.executableURL = executable; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "EXPLORER_LABEL_JOB": UUID().uuidString]
        try process.run()
        return (process, input, output)
    }
    private func wait(_ process: Process, maximum: TimeInterval = 4) {
        let deadline = ProcessInfo.processInfo.systemUptime + maximum
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(process.isRunning, "The owned model worker must stop within four seconds")
        if process.isRunning {
            if getpgid(process.processIdentifier) == process.processIdentifier { kill(-process.processIdentifier, SIGKILL) }
            else { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
    func testWorkerExitsWhenParentPipeCloses() throws {
        let (process, input, _) = try worker()
        try input.fileHandleForWriting.close()
        wait(process)
        XCTAssertEqual(process.terminationStatus, 0)
    }
    func testWorkerRejectsMalformedAndOversizedInput() throws {
        for bytes in [Data("not-json\n".utf8), Data(repeating: 120, count: 262_145)] {
            let (process, input, _) = try worker()
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
            wait(process)
        }
    }
    func testWorkerRejectsUnknownRequestsAndStopsAfterEOF() throws {
        let (process, input, output) = try worker()
        try input.fileHandleForWriting.write(contentsOf: Data("{\"kind\":\"unrecognized\"}\n".utf8))
        try input.fileHandleForWriting.close()
        wait(process)
        // EOF can win the race before work starts: neither branch starts a model.
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        if !data.isEmpty { XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("error")) }
    }
}
