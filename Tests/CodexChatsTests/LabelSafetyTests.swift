import XCTest
import AppKit
import Darwin
import ModelSupport
@testable import CodexChats

final class LabelSafetyTests:XCTestCase {
    func testPolicyUsesExactLunaLowestEffortAndFiniteBounds()throws{
        XCTAssertEqual(LabelPolicy.cloudModel,"gpt-6-luna")
        XCTAssertEqual(try LabelPolicy.lowestEffort(["medium","low","high"]),"low")
        XCTAssertThrowsError(try LabelPolicy.lowestEffort(["unknown"]))
        XCTAssertEqual(try LabelPolicy.validatedLabel("  Explore\nchat   history safely today "),"Explore chat history safely today")
        XCTAssertThrowsError(try LabelPolicy.validatedLabel(String(repeating:"x",count:81)))
        let environment=LabelPolicy.safeEnvironment(jobID:UUID().uuidString)
        XCTAssertNil(environment["OPENAI_API_KEY"]);XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(environment["OTEL_SDK_DISABLED"],"true")
        let request=LabelWorkerRequest(jobID:UUID().uuidString,provider:.luna,prompt:String(repeating:"x",count:LabelPolicy.maximumInputBytes+1),localModel:"qwen3.6",modelsDirectory:"/fixture",codexExecutable:"/fixture/codex",ollamaExecutable:"/fixture/ollama",jobDirectory:"/fixture")
        XCTAssertThrowsError(try request.validate())
    }
    func testCancellationDeadlineAndOwnedGroupCleanup()throws{
        let token=LabelCancellation(seconds:0.1);Thread.sleep(forTimeInterval:0.12);XCTAssertThrowsError(try token.check())
        let id=UUID().uuidString
        let child=try OwnedModelProcess(executable:"/bin/sleep",arguments:["20"],environment:LabelPolicy.safeEnvironment(jobID:id),directory:FileManager.default.temporaryDirectory.path,jobID:id)
        let identity=try XCTUnwrap(child.identity)
        XCTAssertTrue(OwnedModelProcess.verify(identity,parent:getpid()))
        let falseIdentity=LabelBackendIdentity(pid:identity.pid,generation:identity.generation,executable:identity.executable,jobID:UUID().uuidString)
        OwnedModelProcess.cleanup(falseIdentity)
        XCTAssertTrue(child.process.isRunning)
        XCTAssertTrue(child.stop());XCTAssertFalse(child.process.isRunning)
    }
    func testParentEOFStopsWorkerAndItsOwnedBackendWithoutAnyInference()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("label-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let fake=root.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\n/bin/sleep 30\n".utf8).write(to:fake)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:fake.path)
        let worker=Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ExplorerModelWorker")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:worker.path))
        let task=Process(),input=Pipe(),output=Pipe();task.executableURL=worker;task.standardInput=input;task.standardOutput=output;task.standardError=FileHandle.nullDevice
        try task.run()
        let id=UUID().uuidString
        let request=LabelWorkerRequest(jobID:id,provider:.luna,prompt:"Synthetic lifetime fixture only",localModel:"qwen3.6",modelsDirectory:root.path,codexExecutable:fake.path,ollamaExecutable:"/nonexistent",jobDirectory:root.path)
        try input.fileHandleForWriting.write(contentsOf:JSONEncoder().encode(request)+Data([10]))
        let fd=output.fileHandleForReading.fileDescriptor
        _=fcntl(fd,F_SETFL,O_NONBLOCK)
        var bytes=Data(),backend:LabelBackendIdentity?
        let deadline=ProcessInfo.processInfo.systemUptime+4
        while ProcessInfo.processInfo.systemUptime<deadline,backend==nil{
            var value=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            if poll(&value,1,100)>0{
                var chunk=[UInt8](repeating:0,count:4096);let count=read(fd,&chunk,chunk.count)
                if count>0{bytes.append(contentsOf:chunk.prefix(count))}
                while let end=bytes.firstIndex(of:10){let line=Data(bytes[..<end]);bytes.removeSubrange(...end);if let event=try? JSONDecoder().decode(LabelWorkerEvent.self,from:line),let found=event.backend{backend=found}}
            }
        }
        let identity=try XCTUnwrap(backend)
        try input.fileHandleForWriting.close() // simulate app exit/crash
        let stopped=ProcessInfo.processInfo.systemUptime+6
        while task.isRunning && ProcessInfo.processInfo.systemUptime<stopped{Thread.sleep(forTimeInterval:0.03)}
        if task.isRunning{task.terminate()}
        XCTAssertFalse(task.isRunning)
        XCTAssertNotEqual(kill(identity.pid,0),0)
    }
    func testBrowsingRefreshAndLabelPreparationDoNotStartModels(){
        _=NSApplication.shared
        let source=URL(fileURLWithPath:"/fixture/state_5.sqlite")
        let snapshot=ChatSnapshot(chats:[],sourceURL:source,observedAt:Date(),excludedSubagents:0,projectSourceURL:source,projectSourceIssue:nil)
        let root=ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
        root.show(snapshot);root.setPresentation(.date);root.setDateArchiveFilter(.archived);root.showFind();root.showSavedItems();root.setPresentation(.timeline);root.show(snapshot)
        XCTAssertEqual(root.labelRequestCount,0);XCTAssertFalse(root.hasLabelWork)
    }
}

extension LabelSafetyTests {
    func testCoordinatorWaitsForWorkerExitAndAcceptsOnlyOneRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("worker.swift")
        let source = #"""
        #!/usr/bin/swift
        import Foundation
        guard let line=readLine(),let bytes=line.data(using:.utf8),let request=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],let id=request["jobID"] as? String else{exit(2)}
        let value:[String:Any]=["kind":"result","jobID":id,"label":"Offline source-aware browser summary label","model":"offline-fixture","effort":"disabled"]
        let output=try JSONSerialization.data(withJSONObject:value)
        print(String(data:output,encoding:.utf8)!);fflush(stdout)
        Thread.sleep(forTimeInterval:0.3)
        """#
        try source.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:fake.path)
        let coordinator = LabelCoordinator(workerURL: fake, jobRoot: root.appendingPathComponent("jobs"))
        let sample = LabelSample(prompt:"Synthetic fixture; no network or model.",references:["fixture/item@1"],hashes:[:],totalMessages:1,sampledMessages:1)
        let settled = expectation(description:"Worker exited and request settled")
        var resultBeforeExit = false
        coordinator.onEvent = { value in
            if value.kind == "result" { resultBeforeExit = true; XCTAssertTrue(coordinator.isRunning) }
            if value.kind == "settled" { XCTAssertEqual(value.label,"Offline source-aware browser summary label"); XCTAssertFalse(coordinator.isRunning); settled.fulfill() }
        }
        try coordinator.start(provider:.luna,sample:sample)
        XCTAssertThrowsError(try coordinator.start(provider:.luna,sample:sample))
        wait(for:[settled],timeout:15)
        XCTAssertTrue(resultBeforeExit)
        XCTAssertEqual(coordinator.startedRequests,1)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("jobs").path).isEmpty) == true)
    }
}
