import Foundation
import AppKit
import ModelSupport

/// One admission slot across all production windows. Tests may inject a private gate.
final class LabelAdmission {
    static let shared = LabelAdmission()
    private let lock = NSLock()
    private var jobID: String?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return jobID != nil }
    fileprivate func acquire(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard jobID == nil else { throw LabelFailure("A label request is already running in another Explorer window. Wait for it to finish or cancel it in that window.") }
        jobID = id
    }
    fileprivate func release(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if jobID == id { jobID = nil }
    }
}

final class LabelCoordinator {
    private let overrideWorker: URL?
    private let overrideJobRoot: URL?
    private let admission: LabelAdmission
    private let workerTimeout: TimeInterval
    private var job: LabelWorkerJob?
    init(workerURL: URL? = nil, jobRoot: URL? = nil, admission: LabelAdmission = .shared, workerTimeout: TimeInterval = 55) {
        overrideWorker = workerURL; overrideJobRoot = jobRoot
        self.admission = admission; self.workerTimeout = workerTimeout
    }
    private var exitCallbacks = [() -> Void]()
    private(set) var isRunning = false
    private(set) var startedRequests = 0
    var onEvent: ((LabelWorkerEvent) -> Void)?
    static var hasRunningRequest: Bool { LabelAdmission.shared.isRunning }
    deinit { job?.cancel() }
    var workerURL:URL {overrideWorker ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ExplorerModelWorker")}
    @discardableResult func start(provider:LabelProvider,sample:LabelSample)throws->String{
        precondition(Thread.isMainThread)
        guard !isRunning else{throw LabelFailure("One label request is already running. Cancel it before starting another.")}
        let jobID=UUID().uuidString
        try admission.acquire(jobID)
        var started = false
        defer { if !started { admission.release(jobID) } }
        let root=overrideJobRoot ?? ExplorerLibrary.defaultDirectory.appendingPathComponent("label-jobs",isDirectory:true)
        let folder=root.appendingPathComponent(jobID,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let home=FileManager.default.homeDirectoryForCurrentUser
        let codexCandidates=[home.appendingPathComponent(".local/bin/codex"),URL(fileURLWithPath:"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")]
        let ollamaCandidates=[URL(fileURLWithPath:"/usr/local/bin/ollama"),URL(fileURLWithPath:"/opt/homebrew/bin/ollama")]
        let codex=codexCandidates.first{FileManager.default.isExecutableFile(atPath:$0.path)}?.resolvingSymlinksInPath().path ?? ""
        let ollama=ollamaCandidates.first{FileManager.default.isExecutableFile(atPath:$0.path)}?.resolvingSymlinksInPath().path ?? ""
        let models=home.appendingPathComponent("Local AI Models/ollama")
        let request=LabelWorkerRequest(jobID:jobID,provider:provider,prompt:sample.prompt,localModel:"qwen3.6",modelsDirectory:models.path,codexExecutable:codex,ollamaExecutable:ollama,jobDirectory:folder.path)
        do{
            try request.validate()
            guard FileManager.default.isExecutableFile(atPath:workerURL.path) else{throw LabelFailure("The signed label worker is not bundled in this app build.")}
            if overrideWorker != nil { /* injected offline worker; no real runtime is invoked */ }
            else if provider == .local {guard !ollama.isEmpty,FileManager.default.fileExists(atPath:models.appendingPathComponent("manifests/registry.ollama.ai/library/qwen3.6/latest").path) else{throw LabelFailure("The installed local Qwen model/runtime could not be found. No download or request was started.")}}
            else{guard !codex.isEmpty else{throw LabelFailure("The Codex runtime is unavailable. No request was started.")}}
        }catch{try? FileManager.default.removeItem(at:folder);throw error}
        isRunning=true; startedRequests+=1
        let job = LabelWorkerJob(admission: admission, workerTimeout: workerTimeout) { [weak self] event in
            guard let self else { return }
            if event.kind == "settled" {
                self.job = nil; self.isRunning = false
                let callbacks = self.exitCallbacks; self.exitCallbacks = []
                self.onEvent?(event)
                callbacks.forEach { $0() }
            } else { self.onEvent?(event) }
        }
        self.job = job; started = true
        job.start(request, worker: workerURL)
        return jobID
    }
    func cancel(completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        if let completion { if isRunning { exitCallbacks.append(completion) } else { completion(); return } }
        guard isRunning else { return }
        job?.cancel()
    }
}

/// Keeps cleanup and the admission slot alive if its originating window goes away.
/// The running Process retains this job until finish removes its termination handler.
private final class LabelWorkerJob {
    private let admission: LabelAdmission
    private let workerTimeout: TimeInterval
    private let onEvent: (LabelWorkerEvent) -> Void
    private let queue=DispatchQueue(label:"explorer.label-coordinator",qos:.userInitiated,autoreleaseFrequency:.workItem)
    private var process:Process?,input:Pipe?,output:FileHandle?,watchdog:DispatchSourceTimer?
    private var buffer=Data(),request:LabelWorkerRequest?,lastResult:LabelWorkerEvent?
    private var backends=[LabelBackendIdentity]()
    private var cancellationReceipt: Bool?
    private var cancellationRequested = false

    init(admission: LabelAdmission, workerTimeout: TimeInterval, onEvent: @escaping (LabelWorkerEvent) -> Void) {
        self.admission = admission; self.workerTimeout = workerTimeout; self.onEvent = onEvent
    }
    func start(_ request: LabelWorkerRequest, worker: URL) {
        queue.async { self.launch(request, worker: worker) }
    }
    private func launch(_ request:LabelWorkerRequest,worker:URL){
        let task=Process(),stdin=Pipe(),stdout=Pipe()
        task.executableURL=worker;task.arguments=[];task.environment=LabelPolicy.safeEnvironment(jobID:request.jobID)
        task.standardInput=stdin;task.standardOutput=stdout;task.standardError=FileHandle.nullDevice
        self.request=request;self.input=stdin;self.output=stdout.fileHandleForReading;buffer=Data();lastResult=nil;backends=[];cancellationReceipt=nil
        let id=request.jobID
        output?.readabilityHandler={[weak self] handle in
            // Read only while FileHandle reports readiness; a queued second read
            // could otherwise block the same queue that must cancel the worker.
            let data = handle.availableData
            self?.queue.async{[weak self] in
                guard let self,self.request?.jobID==id else{return}
                self.consume(data)
            }
        }
        task.terminationHandler={ [self] task in queue.async { self.ended(task,id:id) } }
        do{
            try task.run();self.process=task
            let data=try JSONEncoder().encode(request)+Data([10]);try stdin.fileHandleForWriting.write(contentsOf:data)
            let timer=DispatchSource.makeTimerSource(queue:queue);timer.schedule(deadline:.now()+workerTimeout)
            timer.setEventHandler{[weak self] in self?.forceStop(id:id)};watchdog=timer;timer.resume()
        }catch{
            let event=LabelWorkerEvent(kind:"error",jobID:id,message:"The label worker could not start or receive its bounded input.")
            if task.isRunning { self.process=task; self.lastResult=event; forceStop(id:id) }
            else { task.terminationHandler=nil; finish(event) }
        }
    }
    private func consume(_ data:Data){
        guard let request else{return}
        guard buffer.count+data.count<=65_536 else{forceStop(id:request.jobID);return}
        buffer.append(data)
        while let end=buffer.firstIndex(of:10){
            let line=Data(buffer[..<end]);buffer.removeSubrange(...end)
            guard let decoded=try? JSONDecoder().decode(LabelWorkerEvent.self,from:line),decoded.jobID==request.jobID else{continue}
            var event = decoded
            if decoded.kind == "result" {
                if let label = decoded.label, let validated = try? LabelPolicy.validatedLabel(label) {
                    event.label = validated
                } else {
                    event = LabelWorkerEvent(kind:"error",jobID:request.jobID,message:"The model did not return exactly five valid words. The saved label was not changed.")
                }
            }
            if let backend=event.backend,backend.jobID==request.jobID,let process,OwnedModelProcess.verify(backend,parent:process.processIdentifier) {backends.append(backend)}
            if event.kind=="cancellation" { cancellationReceipt=event.cancellationAcknowledged }
            if ["result","error","cancelled"].contains(event.kind) {
                var final=event
                if cancellationReceipt==false {
                    final.cancellationAcknowledged=false
                    final.message=String((event.message ?? "Request stopped.").prefix(150))+" Provider cancellation receipt unavailable."
                }
                lastResult=final
            }
            DispatchQueue.main.async { [onEvent] in onEvent(event) }
        }
    }
    private func ended(_ task:Process,id:String){
        guard request?.jobID==id,process===task else{return}
        output?.readabilityHandler=nil
        if let output,let remainder=try? output.readToEnd(){consume(remainder)}
        for backend in backends{OwnedModelProcess.cleanup(backend)}
        let event=lastResult ?? LabelWorkerEvent(kind:"error",jobID:id,message:"The model worker exited without a result. No automatic retry was made.")
        finish(event)
    }
    private func finish(_ event:LabelWorkerEvent){
        watchdog?.setEventHandler{};watchdog?.cancel();watchdog=nil
        output?.readabilityHandler=nil;try? output?.close();output=nil
        try? input?.fileHandleForWriting.close();input=nil
        process?.terminationHandler=nil;process=nil
        if let request{try? FileManager.default.removeItem(at:URL(fileURLWithPath:request.jobDirectory))}
        request=nil;buffer=Data();backends=[];lastResult=nil;cancellationReceipt=nil
        admission.release(event.jobID)
        DispatchQueue.main.async { [onEvent] in
            onEvent(LabelWorkerEvent(kind:"settled",jobID:event.jobID,message:event.message,label:event.label,model:event.model,effort:event.effort,cancellationAcknowledged:event.cancellationAcknowledged))
        }
    }
    func cancel() {
        queue.async { [self] in
            guard let request, !cancellationRequested else { return }
            cancellationRequested = true
            let id=request.jobID
            try? input?.fileHandleForWriting.write(contentsOf:Data("{\"cancel\":true}\n".utf8));try? input?.fileHandleForWriting.close()
            queue.asyncAfter(deadline:.now()+7){[weak self] in self?.forceStop(id:id)}
        }
    }
    private func forceStop(id:String){
        guard request?.jobID==id else{return}
        for backend in backends{OwnedModelProcess.cleanup(backend)}
        if process?.isRunning==true{process?.terminate()}
        queue.asyncAfter(deadline:.now()+2){[weak self] in
            guard let self,self.request?.jobID==id else{return}
            for backend in self.backends{OwnedModelProcess.cleanup(backend,force:true)}
            if let process=self.process,process.isRunning{let marker="EXPLORER_LABEL_JOB=\(id)";OwnedModelProcess.forceWorker(pid:process.processIdentifier,marker:marker)}
        }
    }
}
