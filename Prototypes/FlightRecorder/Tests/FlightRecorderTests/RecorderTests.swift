import XCTest
import Darwin
@testable import FlightRecorder

final class RecorderTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    func recorder(_ root: URL, config: RecorderConfiguration = .init()) -> FlightRecorder {
        FlightRecorder(root:root,identity:RecorderIdentity(bundleID:"test.recorder",version:"test",build:"1"),configuration:config)
    }
    func events(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).filter{$0.pathExtension == "jsonl"}.sorted{$0.path < $1.path}
    }
    func records(_ r: FlightRecorder) throws -> [DiagnosticRecord] {
        var all = [DiagnosticRecord]()
        for url in try events(r.sessionURL) { try DiagnosticReader.scan(url) { all.append($0) } }; return all
    }
    func testCPUMetricsUseNanoseconds() throws {
        let before = RecorderMetrics.sample()
        let end = DispatchTime.now().uptimeNanoseconds + 50_000_000
        while DispatchTime.now().uptimeNanoseconds < end { _ = RecorderMetrics.sample() }
        let after = RecorderMetrics.sample()
        guard case .integer(let u0) = before["cpu_user_ns"], case .integer(let s0) = before["cpu_system_ns"],
              case .integer(let u1) = after["cpu_user_ns"], case .integer(let s1) = after["cpu_system_ns"] else { return XCTFail("CPU counters unavailable") }
        XCTAssertGreaterThan(u1+s1-u0-s0,1_000_000)
        XCTAssertLessThan(u1+s1-u0-s0,1_000_000_000)
    }
    func testIdentityOrderNonfiniteAndBoundedFields() throws {
        let r = recorder(try temporary()); XCTAssertTrue(r.flush(timeout:5))
        r.record("geometry",fields:["x":.number(.infinity),"y":.number(-.infinity),"zoom":.number(.nan),"title":.text(String(repeating:"😺",count:10000))])
        let op = r.begin("read"); r.end("read",op)
        XCTAssertTrue(r.close(timeout:5))
        let data = try records(r)
        XCTAssertEqual(data.map(\.sequence),Array(1...UInt64(data.count)))
        XCTAssertEqual(Set(data.map(\.session)),[r.identity.session])
        XCTAssertEqual(data.first?.event,"session.start"); XCTAssertEqual(data.last?.event,"session.end")
        XCTAssertEqual(data[1].fields["x"],.text("nonfinite:+Infinity"))
        XCTAssertEqual(data[1].fields["zoom"],.text("nonfinite:NaN"))
        XCTAssertEqual(data[2].operation,data[3].operation)
        XCTAssertEqual(r.status.truncatedFields,1)
        XCTAssertNotNil(r.identity.binaryUUID); XCTAssertNotNil(r.identity.processStart)
        XCTAssertFalse(r.record("after.close")); XCTAssertEqual(r.status.rejectedAfterClose,1)
        XCTAssertTrue(zip(data,data.dropFirst()).allSatisfy{$0.uptimeNS <= $1.uptimeNS})
    }
    func testConcurrentBackpressureAndAccounting() throws {
        var c = RecorderConfiguration(); c.maxPending = 8
        let r = recorder(try temporary(),config:c)
        DispatchQueue.concurrentPerform(iterations:8) { worker in
            for n in 0..<3000 { r.record("load",fields:["worker":.integer(Int64(worker)),"n":.integer(Int64(n))]) }
        }
        XCTAssertTrue(r.close(timeout:10))
        let s = r.status, data = try records(r)
        XCTAssertGreaterThan(s.droppedQueue,0); XCTAssertLessThanOrEqual(s.highWater,8)
        XCTAssertEqual(s.attempted,s.written+s.droppedQueue+s.droppedRate+s.encodingFailures+s.lostIO)
        XCTAssertEqual(s.written,UInt64(data.count)); XCTAssertEqual(s.pending,0)
        XCTAssertEqual(Set(data.map(\.sequence)).count,data.count)
        XCTAssertTrue(zip(data,data.dropFirst()).allSatisfy{$0.sequence < $1.sequence})
    }
    func testRateLimitReservesNavigationCapacity() throws {
        var c = RecorderConfiguration(); c.maxEventsPerSecond = 32
        let r = recorder(try temporary(),config:c); XCTAssertTrue(r.flush(timeout:5))
        for _ in 0..<80 { r.record("noisy.event") }
        XCTAssertTrue(r.record("navigation.back", critical:true))
        XCTAssertTrue(r.close(timeout:5))
        XCTAssertGreaterThan(r.status.droppedRate,0)
        XCTAssertTrue(try records(r).contains{$0.event == "navigation.back"})
    }
    func testRotationKeepsRecentEvidenceAndLossCounts() throws {
        var c = RecorderConfiguration(); c.segmentBytes = 16384; c.segments = 2; c.maxEventsPerSecond = 2000
        let r = recorder(try temporary(),config:c)
        for n in 0..<3000 {
            r.record("viewport",fields:["n":.integer(Int64(n)),"padding":.text(String(repeating:"x",count:256))])
            if n % 100 == 0 { XCTAssertTrue(r.flush(timeout:5)) }
        }
        r.record("last.marker", critical:true); XCTAssertTrue(r.close(timeout:5))
        let files = try events(r.sessionURL), data = try records(r)
        XCTAssertEqual(files.count,2); XCTAssertGreaterThan(r.status.rotatedRecords,0)
        XCTAssertEqual(UInt64(data.count)+r.status.rotatedRecords,r.status.written)
        XCTAssertTrue(data.contains{$0.event == "last.marker"})
        for url in files { XCTAssertLessThanOrEqual(try Data(contentsOf:url).count,16384) }
    }
    func testMalformedPartialUnknownAndOversizedAreReportedWithoutRepair() throws {
        let r = recorder(try temporary()); XCTAssertTrue(r.close(timeout:5))
        let original = try Data(contentsOf:events(r.sessionURL)[0])
        let url = r.root.appendingPathComponent("corrupt-fixture.jsonl")
        let record = try XCTUnwrap(records(r).first)
        let future = DiagnosticRecord(schema:99,session:record.session,sequence:record.sequence,wallTime:record.wallTime,uptimeNS:record.uptimeNS,event:"future",operation:nil,fields:[:])
        var bytes = original
        bytes.append(contentsOf:[0xff,10]); bytes.append(try JSONEncoder().encode(future)); bytes.append(10)
        bytes.append(Data(repeating:65,count:20000)); bytes.append(10); bytes.append(Data("{partial".utf8))
        try bytes.write(to:url)
        let result = try DiagnosticReader.scan(url) { _ in }
        XCTAssertEqual(result.records,2); XCTAssertEqual(result.malformed,1); XCTAssertEqual(result.partial,1)
        XCTAssertEqual(result.unknownSchema,1); XCTAssertEqual(result.oversized,1)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testMidSessionRotationFailurePreservesExistingEvidence() throws {
        var c = RecorderConfiguration(); c.segmentBytes = 16384; c.maxEventsPerSecond = 2000
        let r = recorder(try temporary(),config:c); XCTAssertTrue(r.flush(timeout:5))
        let collision = r.sessionURL.appendingPathComponent("events-0000000001.jsonl")
        let sentinel = Data("do not overwrite".utf8); try sentinel.write(to:collision)
        for _ in 0..<200 { r.record("fill",fields:["padding":.text(String(repeating:"x",count:256))]) }
        XCTAssertFalse(r.flush(timeout:5)); XCTAssertTrue(r.status.disabled)
        XCTAssertGreaterThan(r.status.lostIO,0); XCTAssertFalse(r.close(timeout:5))
        XCTAssertEqual(try Data(contentsOf:collision),sentinel)
        XCTAssertGreaterThan(try records(r).count,1)
        let status = try JSONDecoder().decode(RecorderStatus.self,from:Data(contentsOf:r.sessionURL.appendingPathComponent("status.json")))
        XCTAssertTrue(status.disabled); XCTAssertGreaterThan(status.ioFailures,0)
    }
    func testUnavailableStorageDisablesWithoutThrowingAtCaller() throws {
        let root = try temporary().appendingPathComponent("file"); try Data([1]).write(to:root)
        let r = recorder(root); r.record("still-safe")
        XCTAssertFalse(r.flush(timeout:5)); XCTAssertTrue(r.status.disabled)
        XCTAssertFalse(r.close(timeout:5)); XCTAssertGreaterThan(r.status.ioFailures,0)
        XCTAssertEqual(try Data(contentsOf:root),Data([1]))
    }
    func testFIFOIsRejectedWithoutWaitingForAWriter() throws {
        let path = try temporary().appendingPathComponent("events-fifo.jsonl")
        XCTAssertEqual(mkfifo(path.path,0o600),0)
        XCTAssertThrowsError(try DiagnosticReader.scan(path) { _ in })
    }
    func testSymlinkStorageCannotOverwriteTarget() throws {
        let root = try temporary(), target = root.appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        let r = recorder(link); XCTAssertFalse(r.flush(timeout:5)); XCTAssertFalse(r.close(timeout:5))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:target.path),[])
    }
    func testRetentionProtectsActiveAndRecentUncleanAndLeavesUnknownAlone() throws {
        let root = try temporary(); var c = RecorderConfiguration(); c.retainedSessions = 2; c.retainedUncleanSessions = 1
        let active = recorder(root,config:c); XCTAssertTrue(active.flush(timeout:5))
        var unclean: FlightRecorder? = recorder(root,config:c); XCTAssertTrue(unclean!.flush(timeout:5))
        let uncleanURL = unclean!.sessionURL; unclean = nil
        // Release a recorder without close, modeling an unfinished session (not asserting a crash).
        for _ in 0..<5 { let r = recorder(root,config:c); XCTAssertTrue(r.close(timeout:5)) }
        let unknown = root.appendingPathComponent(UUID().uuidString.lowercased()); try FileManager.default.createDirectory(at:unknown,withIntermediateDirectories:false)
        let r = recorder(root,config:c); XCTAssertTrue(r.close(timeout:5))
        XCTAssertTrue(FileManager.default.fileExists(atPath:active.sessionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:uncleanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:unknown.path))
        let receipt = try JSONDecoder().decode(RetentionReceipt.self,from:Data(contentsOf:root.appendingPathComponent("retention.json")))
        XCTAssertGreaterThan(receipt.removedSessions,0); XCTAssertGreaterThan(receipt.skippedActive,0)
        XCTAssertTrue(active.close(timeout:5))
    }
    func testExportCopiesExactBytesAndSkipsOtherActiveSession() throws {
        let root = try temporary(), r = recorder(root), other = recorder(root)
        XCTAssertTrue(other.flush(timeout:5)); r.record("reference",fields:["chat_id":.text("known-id")])
        let out = try temporary().appendingPathComponent("export"), done = expectation(description:"export")
        r.export(to:out) { result in
            if case .failure(let error) = result { XCTFail("Export failed: \(error)") }; done.fulfill()
        }
        wait(for:[done],timeout:5)
        let receipt = try JSONDecoder().decode(BundleReceipt.self,from:Data(contentsOf:out.appendingPathComponent("bundle.json")))
        XCTAssertTrue(receipt.omissions.contains(other.identity.session+":other-active-session"))
        for file in receipt.files where file.path != "README.txt" {
            XCTAssertEqual(try Data(contentsOf:out.appendingPathComponent(file.path)),try Data(contentsOf:root.appendingPathComponent(file.path)))
        }
        XCTAssertTrue(r.close(timeout:5)); XCTAssertTrue(other.close(timeout:5))
        XCTAssertThrowsError(try DiagnosticBundle.export(root:root,currentSession:r.identity.session,to:out))
    }
}
