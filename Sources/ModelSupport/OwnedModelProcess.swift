import Foundation
import Darwin
import CProcessIdentity

public final class OwnedModelProcess {
    public let process = Process()
    private let input = Pipe(), output = Pipe()
    private let writeLock = NSLock(), lifecycleLock = NSLock()
    private var stopRequested = false
    public private(set) var identity: LabelBackendIdentity!
    private var buffer = Data()
    private var inputClosed = false
    public init(executable: String, arguments: [String], environment: [String:String], directory: String, jobID: String, captureOutput: Bool = true) throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw LabelFailure("The selected model runtime is unavailable.") }
        process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments;process.environment=environment;process.currentDirectoryURL=URL(fileURLWithPath:directory)
        process.standardInput=input;process.standardOutput=captureOutput ? output : FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        let pid=process.processIdentifier
        let generation=explorer_process_generation(pid)
        guard getpgid(pid)==pid, generation>0 else { process.terminate(); throw LabelFailure("The model runtime could not be isolated into its own process group.") }
        identity=LabelBackendIdentity(pid:pid,generation:generation,executable:executable,jobID:jobID)
        let descriptor=output.fileHandleForReading.fileDescriptor
        _=fcntl(descriptor,F_SETFL,O_NONBLOCK)
    }
    deinit { _ = stop() }
    public func send(_ object:[String:Any]) throws {
        let data=try JSONSerialization.data(withJSONObject:object)+Data([10])
        writeLock.lock();defer{writeLock.unlock()}
        guard !inputClosed,process.isRunning else {throw LabelFailure("The model runtime closed its input.")}
        try input.fileHandleForWriting.write(contentsOf:data)
    }
    /// Bounded writes for large semantic batches. A live child which stops reading cannot
    /// block cancellation or closeInput while holding the writer lock indefinitely.
    public func sendBounded(_ object: [String: Any], deadline: TimeInterval, cancelled: () -> Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
        guard data.count <= 262_144 else { throw LabelFailure("The model-runtime request exceeds its bounded input.") }
        func check() throws {
            lifecycleLock.lock(); let stopping = stopRequested; lifecycleLock.unlock()
            if stopping || cancelled() || ProcessInfo.processInfo.systemUptime >= deadline { throw LabelFailure("The model-runtime write was cancelled or timed out.") }
        }
        while !writeLock.try() { try check(); Thread.sleep(forTimeInterval: 0.01) }
        defer { writeLock.unlock() }
        try check()
        guard !inputClosed, process.isRunning else { throw LabelFailure("The model runtime closed its input.") }
        let fd = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0, fcntl(fd, F_SETNOSIGPIPE, 1) >= 0 else { throw LabelFailure("Cannot configure the bounded model-runtime connection.") }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try check()
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 || errno == EAGAIN || errno == EWOULDBLOCK else { throw LabelFailure("The model runtime stopped accepting input.") }
                var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&item, 1, 100)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0, item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw LabelFailure("The model-runtime input connection failed.") }
            }
        }
    }

    public func nextJSON(deadline:TimeInterval,cancellation:LabelCancellation?,maximumBytes:Int=1_048_576) throws -> [String:Any] {
        let fd=output.fileHandleForReading.fileDescriptor
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let cancellation {try cancellation.check()}
            if let end=buffer.firstIndex(of:10) {
                let raw=Data(buffer[..<end]);buffer.removeSubrange(...end)
                guard let result=try JSONSerialization.jsonObject(with:raw) as? [String:Any] else {throw LabelFailure("Invalid model-runtime response.")}
                return result
            }
            var item=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            let ready=poll(&item,1,100)
            if ready<0 {if errno==EINTR {continue};throw LabelFailure("The model-runtime connection failed.")}
            if ready==0 {continue}
            var bytes=[UInt8](repeating:0,count:16_384)
            let count=read(fd,&bytes,bytes.count)
            if count==0 {throw LabelFailure("The model runtime exited before completing the label.")}
            if count<0 {if errno==EAGAIN || errno==EWOULDBLOCK || errno==EINTR {continue};throw LabelFailure("Cannot read the model runtime.")}
            guard buffer.count+count<=maximumBytes else {throw LabelFailure("The model-runtime response exceeded the bounded buffer.")}
            buffer.append(contentsOf:bytes.prefix(count))
        }
        throw LabelFailure("The model-runtime response reached its time limit.")
    }
    public func closeInput() {lifecycleLock.lock();stopRequested=true;lifecycleLock.unlock();writeLock.lock();defer{writeLock.unlock()};if !inputClosed {try? input.fileHandleForWriting.close();inputClosed=true}}
    @discardableResult public func stop() -> Bool {
        closeInput()
        guard let identity else { if process.isRunning { process.terminate() }; return true }
        let soft=ProcessInfo.processInfo.systemUptime+0.4
        while process.isRunning && ProcessInfo.processInfo.systemUptime<soft {Thread.sleep(forTimeInterval:0.02)}
        if process.isRunning,explorer_process_generation(identity.pid)==identity.generation {kill(-identity.pid,SIGTERM)}
        let grace=ProcessInfo.processInfo.systemUptime+2
        while process.isRunning && ProcessInfo.processInfo.systemUptime<grace {Thread.sleep(forTimeInterval:0.02)}
        let marker="EXPLORER_LABEL_JOB=\(identity.jobID)"
        if explorer_owned_group(identity.pid,marker)>0 {kill(-identity.pid,SIGKILL)}
        let end=ProcessInfo.processInfo.systemUptime+1
        while !Self.isStopped(identity) && ProcessInfo.processInfo.systemUptime<end {Thread.sleep(forTimeInterval:0.02)}
        if !process.isRunning {process.waitUntilExit()}
        return Self.isStopped(identity)
    }
    public static func isStopped(_ identity: LabelBackendIdentity) -> Bool {
        explorer_owned_group(identity.pid, "EXPLORER_LABEL_JOB=\(identity.jobID)") == 0 && explorer_process_identity_live(identity.pid, identity.generation) == 0
    }
    /// Used by the semantic helper after stopping all its direct servers: a detached runner
    /// must not survive a parent EOF or an idle unload. This can only kill the caller's group.
    public static func terminateCurrentGroupIfDescendantsRemain() {
        let leader = getpid()
        guard leader > 1, getpgrp() == leader else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while explorer_group_has_other_live_members(leader, leader) != 0 {
            if ProcessInfo.processInfo.systemUptime >= deadline { kill(-leader, SIGKILL); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    public static func verify(_ identity:LabelBackendIdentity,parent:Int32)->Bool {
        identity.pid>1 && explorer_process_generation(identity.pid)==identity.generation && getpgid(identity.pid)==identity.pid && (explorer_process_parent(identity.pid)==parent || explorer_owned_group(identity.pid,"EXPLORER_LABEL_JOB=\(identity.jobID)")>0)
    }
    public static func cleanup(_ identity:LabelBackendIdentity,force:Bool=false) {
        let marker="EXPLORER_LABEL_JOB=\(identity.jobID)"
        if explorer_owned_group(identity.pid,marker)>0 {kill(-identity.pid,force ? SIGKILL:SIGTERM)}
    }
    public static func forceWorker(pid:Int32,marker:String) {
        if pid>1,explorer_owned_group(pid,marker)>0 {kill(-pid,SIGKILL)}
    }
}
