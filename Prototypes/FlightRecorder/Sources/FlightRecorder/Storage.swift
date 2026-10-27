import Foundation
import Darwin

struct RecorderFailure: Error { let code: Int32 }
enum RecorderFiles {
    static func children(_ url: URL, limit: Int) throws -> (urls:[URL], truncated:Bool) {
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at:url,includingPropertiesForKeys:nil,options:[.skipsSubdirectoryDescendants],errorHandler:{ _,error in failure = error; return false }) else { throw RecorderFailure(code:EIO) }
        var urls = [URL]()
        while let entry = iterator.nextObject() as? URL {
            if urls.count == limit { return (urls,true) }; urls.append(entry)
        }
        if let failure { throw failure }; return (urls,false)
    }
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid() else { throw RecorderFailure(code: EACCES) }
        guard chmod(url.path, 0o700) == 0 else { throw RecorderFailure(code: errno) }
    }
    static func openFile(_ url: URL, flags: Int32, mode: mode_t = 0o600) throws -> Int32 {
        let fd = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode)
        guard fd >= 0 else { throw RecorderFailure(code: errno) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1 else {
            Darwin.close(fd); throw RecorderFailure(code: EACCES)
        }
        return fd
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RecorderFailure(code: count == 0 ? EIO : errno) }
                offset += count
            }
        }
    }
    static func atomic<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { Darwin.close(fd); unlink(temporary.path) }
        try write(data, to: fd)
        guard fsync(fd) == 0 else { throw RecorderFailure(code: errno) }
        guard rename(temporary.path, url.path) == 0 else { throw RecorderFailure(code: errno) }
    }
    static func read(_ url: URL, limit: Int = 128*1024) throws -> Data {
        let fd = try openFile(url, flags: O_RDONLY); defer { Darwin.close(fd) }
        var s = stat(); guard fstat(fd,&s) == 0, s.st_size <= limit else { throw RecorderFailure(code: EFBIG) }
        var data = Data(), buffer = [UInt8](repeating:0,count:min(limit+1,65536))
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw RecorderFailure(code: errno) }
            if n == 0 { return data }
            guard data.count + n <= limit else { throw RecorderFailure(code:EFBIG) }
            data.append(buffer, count:n)
        }
    }
}
struct SessionManifest: Codable {
    let schema: Int
    let identity: RecorderIdentity
    let configuration: RecorderConfiguration
    let coverage: [String]
}
struct RetentionReceipt: Codable {
    var removedSessions = 0
    var removedUncleanSessions = 0
    var removedBytes: UInt64 = 0
    var skippedActive = 0
    var skippedUnknown = 0
    var budgetUnmet = false
    var pendingDeletion: String?
    var interruptedPrunes = 0
    var observedAt = Date().timeIntervalSince1970
}
/// Only unlocked, schema-recognized recorder sessions are eligible. Unknown files are never pruned.
enum RecorderRetention {
    static func apply(root: URL, configuration: RecorderConfiguration) throws -> RetentionReceipt {
        let lockURL = root.appendingPathComponent("retention.lock")
        let lock = try RecorderFiles.openFile(lockURL, flags: O_RDWR | O_CREAT)
        defer { flock(lock,LOCK_UN); Darwin.close(lock) }
        guard flock(lock,LOCK_EX | LOCK_NB) == 0 else { return RetentionReceipt() }
        struct Candidate { let url: URL; let time: Double; let unclean: Bool; let bytes: UInt64; let lock: Int32 }
        var candidates = [Candidate](), receipt = (try? JSONDecoder().decode(RetentionReceipt.self, from: RecorderFiles.read(root.appendingPathComponent("retention.json")))) ?? RetentionReceipt()
        if receipt.pendingDeletion != nil { receipt.interruptedPrunes += 1; receipt.pendingDeletion = nil }
        receipt.skippedActive = 0; receipt.skippedUnknown = 0; receipt.budgetUnmet = false; receipt.observedAt = Date().timeIntervalSince1970
        defer { for c in candidates { flock(c.lock,LOCK_UN); Darwin.close(c.lock) } }
        // The directory is app-owned. Cap inspection as well as retained output.
        let listing = try RecorderFiles.children(root,limit:256)
        receipt.budgetUnmet = listing.truncated
        for url in listing.urls where UUID(uuidString:url.lastPathComponent) != nil {
            var s = stat()
            guard lstat(url.path,&s) == 0, s.st_mode & S_IFMT == S_IFDIR,
                  let manifest = try? JSONDecoder().decode(SessionManifest.self,from:RecorderFiles.read(url.appendingPathComponent("session.json"))),
                  manifest.schema == 1, manifest.identity.session == url.lastPathComponent else { receipt.skippedUnknown += 1; continue }
            let listing = try RecorderFiles.children(url,limit:32)
            let files = listing.urls
            var size: UInt64 = 0, safe = !listing.truncated
            for file in files {
                let n = file.lastPathComponent
                let known = ["session.json","status.json","session.lock","closed.json"].contains(n) || (n.hasPrefix("events-") && n.hasSuffix(".jsonl") && n.count == 23)
                if !known || lstat(file.path,&s) != 0 || s.st_mode & S_IFMT != S_IFREG || s.st_nlink != 1 { safe = false; break }
                size += UInt64(max(0,s.st_size))
            }
            guard safe, let fd = try? RecorderFiles.openFile(url.appendingPathComponent("session.lock"),flags:O_RDWR) else { receipt.skippedUnknown += 1; continue }
            guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); receipt.skippedActive += 1; continue }
            let closed = (try? JSONDecoder().decode(RecorderStatus.self,from:RecorderFiles.read(url.appendingPathComponent("closed.json"))))?.cleanShutdown == true
            candidates.append(Candidate(url:url,time:manifest.identity.recorderStart,unclean:!closed,bytes:size,lock:fd))
        }
        // Reserve recent unclean sessions first. No exit cause is inferred.
        let recentUnclean = candidates.filter(\.unclean).sorted{$0.time > $1.time}.prefix(configuration.retainedUncleanSessions)
        let protected = Set(recentUnclean.map{$0.url})
        let ordered = candidates.sorted { a,b in
            if protected.contains(a.url) != protected.contains(b.url) { return protected.contains(a.url) }
            return a.time > b.time
        }
        var count = 0, bytes: UInt64 = 0
        // Allow headroom for the current session; simultaneous active sessions are skipped explicitly.
        let budget = UInt64(max(0, configuration.totalBytes - configuration.segmentBytes*configuration.segments))
        for c in ordered {
            if count < configuration.retainedSessions && bytes + c.bytes <= budget { count += 1; bytes += c.bytes; continue }
            do {
                receipt.pendingDeletion = c.url.lastPathComponent
                try RecorderFiles.atomic(receipt,to:root.appendingPathComponent("retention.json"))
                try FileManager.default.removeItem(at:c.url)
                receipt.removedSessions += 1; receipt.removedBytes += c.bytes
                if c.unclean { receipt.removedUncleanSessions += 1 }
                receipt.pendingDeletion = nil
                try RecorderFiles.atomic(receipt,to:root.appendingPathComponent("retention.json"))
            } catch { receipt.budgetUnmet = true }
        }
        try RecorderFiles.atomic(receipt,to:root.appendingPathComponent("retention.json"))
        return receipt
    }
}
