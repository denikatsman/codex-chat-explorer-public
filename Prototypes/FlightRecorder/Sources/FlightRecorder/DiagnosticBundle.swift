import Foundation
import Darwin
import CryptoKit

public struct RecoverySummary: Codable {
    public var records = 0, malformed = 0, partial = 0, oversized = 0, unknownSchema = 0
    public var bytes: UInt64 = 0
}
public enum DiagnosticReader {
    /// Reads without repairing or rewriting evidence. Partial/oversized lines remain in the original file.
    @discardableResult public static func scan(_ url: URL, receive: (DiagnosticRecord) -> Void) throws -> RecoverySummary {
        let fd = try RecorderFiles.openFile(url,flags:O_RDONLY); defer { Darwin.close(fd) }
        var result = RecoverySummary(), line = Data(), skipping = false
        var buffer = [UInt8](repeating:0,count:65536)
        while true {
            let count = Darwin.read(fd,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RecorderFailure(code:errno) }
            if count == 0 { break }
            result.bytes += UInt64(count)
            for b in buffer.prefix(count) {
                if b == 10 {
                    if skipping { result.oversized += 1 }
                    else if let record = try? JSONDecoder().decode(DiagnosticRecord.self,from:line) {
                        if record.schema == 1 { result.records += 1; receive(record) } else { result.unknownSchema += 1 }
                    } else { result.malformed += 1 }
                    line.removeAll(keepingCapacity:true); skipping = false
                } else if !skipping {
                    if line.count >= 16384 { skipping = true; line.removeAll(keepingCapacity:true) } else { line.append(b) }
                }
            }
        }
        if skipping { result.oversized += 1; result.partial += 1 }
        else if !line.isEmpty { result.partial += 1 }
        return result
    }
}
struct BundleFile: Codable { let path: String; let bytes: Int; let sha256: String }
struct BundleReceipt: Codable {
    let schema: Int
    let created: Double
    let snapshotStarted: Double
    let currentSequence: UInt64?
    let currentSession: String
    let files: [BundleFile]
    let omissions: [String]
    let consistency: String
}
public enum DiagnosticBundle {
    public static func export(root: URL,currentSession: String,to destination: URL,analysisTool: URL? = nil,currentSequence: UInt64? = nil) throws -> URL {
        let snapshotStarted = Date().timeIntervalSince1970
        guard !destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw RecorderFailure(code:EINVAL) }
        // mkdir is exclusive: no merging with, replacing or deleting a user's destination.
        guard mkdir(destination.path,0o700) == 0 else { throw RecorderFailure(code:errno) }
        var receipts = [BundleFile](), omissions = [String](), total = 0
        let limit = 160*1024*1024
        func store(_ bytes: Data,_ relative: String) throws {
            guard total + bytes.count <= limit else { throw RecorderFailure(code:EFBIG) }
            let target = destination.appendingPathComponent(relative)
            let fd = try RecorderFiles.openFile(target,flags:O_WRONLY | O_CREAT | O_EXCL)
            defer { Darwin.close(fd) }
            try RecorderFiles.write(bytes,to:fd)
            total += bytes.count
            receipts.append(BundleFile(path:relative,bytes:bytes.count,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()))
        }
        func copy(_ source: URL,_ relative: String) throws {
            try store(RecorderFiles.read(source,limit:8*1024*1024+16384),relative)
        }
        let rootLock = try RecorderFiles.openFile(root.appendingPathComponent("retention.lock"),flags:O_RDWR | O_CREAT)
        defer { flock(rootLock,LOCK_UN); Darwin.close(rootLock) }
        guard flock(rootLock,LOCK_SH | LOCK_NB) == 0 else { throw RecorderFailure(code:EBUSY) }
        let listing = try RecorderFiles.children(root,limit:256)
        if listing.truncated { omissions.append("root-entry-count-limit") }
        let urls = listing.urls.filter{UUID(uuidString:$0.lastPathComponent) != nil}.sorted{$0.lastPathComponent < $1.lastPathComponent}
        for session in urls.prefix(64) {
            var s = stat()
            guard lstat(session.path,&s) == 0, s.st_mode & S_IFMT == S_IFDIR,
                  let manifest = try? JSONDecoder().decode(SessionManifest.self,from:RecorderFiles.read(session.appendingPathComponent("session.json"))),
                  manifest.schema == 1, manifest.identity.session == session.lastPathComponent else { omissions.append(session.lastPathComponent+":unknown-session"); continue }
            var lock: Int32 = -1
            if session.lastPathComponent != currentSession {
                lock = (try? RecorderFiles.openFile(session.appendingPathComponent("session.lock"),flags:O_RDWR)) ?? -1
                guard lock >= 0 else { omissions.append(session.lastPathComponent+":lock-unavailable"); continue }
                if flock(lock,LOCK_EX | LOCK_NB) != 0 { Darwin.close(lock); omissions.append(session.lastPathComponent+":other-active-session"); continue }
            }
            defer { if lock >= 0 { flock(lock,LOCK_UN); Darwin.close(lock) } }
            let name = session.lastPathComponent
            try RecorderFiles.directory(destination.appendingPathComponent(name))
            let listing = try RecorderFiles.children(session,limit:32)
            let files = listing.urls.sorted{$0.lastPathComponent < $1.lastPathComponent}
            for file in files {
                let n = file.lastPathComponent
                guard ["session.json","status.json","closed.json"].contains(n) || (n.hasPrefix("events-") && n.hasSuffix(".jsonl") && n.count == 23) else { continue }
                do { try copy(file,name+"/"+n) }
                catch { omissions.append(name+"/"+n+":unreadable-or-budget-exceeded") }
            }
            if listing.truncated { omissions.append(name+":file-count-limit") }
        }
        if urls.count > 64 { omissions.append("session-count-limit") }
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("retention.json").path) { try copy(root.appendingPathComponent("retention.json"),"retention.json") }
        if let analysisTool { try copy(analysisTool,"diagnostics.py") }
        else { omissions.append("Query tool unavailable in this build; use Prototypes/FlightRecorder/diagnostics.py from the source repository") }
        let guide = """
        Explorer local diagnostics, schema 1. No transcript text or source files are captured.
        Each session.json identifies the process, executable UUID, configuration and instrumentation coverage.
        Events are original newline-delimited JSON. Sequence/monotonic order is per session; wallTime is Unix UTC seconds.
        Missing closed.json means active or interrupted, not a confirmed crash. status.json is a checkpoint; closed.json is the final status when present.
        Loss counters, rotation and retention receipts declare omitted history. Corrupt/partial bytes are retained exactly.
        bundle.json is the completion and SHA-256 manifest, including explicit export omissions.
        If diagnostics.py is present, run with Python 3:
          python3 diagnostics.py verify .
          python3 diagnostics.py summary .
          python3 diagnostics.py events . --event navigation.back.begin --limit 20
          python3 diagnostics.py correlate . --reports ~/Library/Logs/DiagnosticReports
        Correlation reads only matching app report filenames in the explicitly supplied directory; it requires PID, process start, main binary UUID and bundle/version/build identity.
        No command contacts a service or writes back to captured records. An unmatched report or absent event does not prove absence of a failure.
        Keep exports private; record IDs can still link to personal conversations.
        """
        try store(Data(guide.utf8),"README.txt")
        omissions.append("OS reports not collected; an unclosed session is not proof of a crash")
        let receipt = BundleReceipt(schema:1,created:Date().timeIntervalSince1970,snapshotStarted:snapshotStarted,currentSequence:currentSequence,currentSession:currentSession,files:receipts,omissions:omissions,
            consistency:"Current recorder writes flushed and paused during copy; events arriving afterward are outside this snapshot; unlocked prior sessions copied under session locks. Original bytes retained, including corrupt/partial records. Manifest is the completion marker.")
        try RecorderFiles.atomic(receipt,to:destination.appendingPathComponent("bundle.json"))
        return destination
    }
}
