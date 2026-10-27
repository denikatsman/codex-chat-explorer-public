import Foundation
import FRSystem

/// Flat typed fields only. Callers pass IDs and measurements, never transcript or error text.
public enum DiagnosticValue: Codable, Equatable, Sendable {
    case text(String), integer(Int64), number(Double), flag(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .flag(x) }
        else if let x = try? c.decode(Int64.self) { self = .integer(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else { self = .text(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let x): try c.encode(x)
        case .integer(let x): try c.encode(x)
        case .flag(let x): try c.encode(x)
        case .null: try c.encodeNil()
        case .number(let x):
            if x.isFinite { try c.encode(x) }
            else { try c.encode(x.isNaN ? "nonfinite:NaN" : x > 0 ? "nonfinite:+Infinity" : "nonfinite:-Infinity") }
        }
    }
}
public struct DiagnosticRecord: Codable, Sendable {
    public let schema: Int
    public let session: String
    public let sequence: UInt64
    public let wallTime: Double
    public let uptimeNS: UInt64
    public let event: String
    public let operation: String?
    public let fields: [String: DiagnosticValue]
}
public struct RecorderIdentity: Codable, Sendable {
    public let session: String
    public let pid: Int32
    public let processStart: Double?
    public let recorderStart: Double
    public let binaryUUID: String?
    public let bundleID: String
    public let version: String
    public let build: String
    public let revision: String
    public let sourceDirty: Bool?
    public let os: String
    public init(bundleID: String, version: String, build: String, revision: String = "unrecorded", sourceDirty: Bool? = nil) {
        session = UUID().uuidString.lowercased(); pid = ProcessInfo.processInfo.processIdentifier
        let start = fr_process_start(); processStart = start > 0 ? start : nil
        recorderStart = Date().timeIntervalSince1970
        var uuid = [CChar](repeating: 0, count: 37)
        binaryUUID = fr_binary_uuid(&uuid) == 1 ? String(cString: uuid) : nil
        self.bundleID = String(bundleID.prefix(200)); self.version = String(version.prefix(80))
        self.build = String(build.prefix(80)); self.revision = String(revision.prefix(80)); self.sourceDirty = sourceDirty
        os = ProcessInfo.processInfo.operatingSystemVersionString
    }
}
public struct RecorderConfiguration: Codable, Sendable {
    public var maxPending = 512
    public var maxEventsPerSecond = 500
    public var maxFields = 40
    public var maxStringBytes = 256
    public var segmentBytes = 2 * 1024 * 1024
    public var segments = 4
    public var retainedSessions = 12
    public var retainedUncleanSessions = 8
    public var totalBytes = 128 * 1024 * 1024
    public var syncInterval = 1.0
    public init() {}
    func validated() -> Self {
        var c = self
        c.maxEventsPerSecond = min(2000, max(32, c.maxEventsPerSecond))
        c.maxPending = min(2048, max(8, c.maxPending)); c.maxFields = min(40, max(1, c.maxFields))
        c.maxStringBytes = min(256, max(16, c.maxStringBytes)); c.segmentBytes = min(8*1024*1024, max(16384, c.segmentBytes))
        c.segments = min(8, max(2, c.segments)); c.retainedSessions = min(32, max(1, c.retainedSessions))
        c.retainedUncleanSessions = min(c.retainedSessions, max(1, c.retainedUncleanSessions))
        c.totalBytes = min(512*1024*1024, max(c.segmentBytes*c.segments, c.totalBytes))
        c.syncInterval = c.syncInterval.isFinite ? min(10, max(0.1, c.syncInterval)) : 1
        return c
    }
}
public struct RecorderStatus: Codable, Sendable {
    public var attempted: UInt64 = 0
    public var written: UInt64 = 0
    public var lastWrittenSequence: UInt64?
    public var droppedQueue: UInt64 = 0
    public var droppedRate: UInt64 = 0
    public var rejectedAfterClose: UInt64 = 0
    public var truncatedFields: UInt64 = 0
    public var encodingFailures: UInt64 = 0
    public var ioFailures: UInt64 = 0
    public var lostIO: UInt64 = 0
    public var rotatedRecords: UInt64 = 0
    public var rotatedBytes: UInt64 = 0
    public var pendingRotation: String?
    public var pending = 0
    public var highWater = 0
    public var disabled = false
    public var lastErrorCode: Int32?
    public var cleanShutdown = false
}
public struct DiagnosticOperation: Sendable {
    public let id: String
    public let started: UInt64
    public init() { id = UUID().uuidString.lowercased(); started = DispatchTime.now().uptimeNanoseconds }
    public var elapsedMS: Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 }
}
public enum RecorderMetrics {
    public static func sample() -> [String: DiagnosticValue] {
        let m = fr_metrics()
        guard m.available == 1 else { return ["available": .flag(false)] }
        return ["available": .flag(true), "resident_bytes": .integer(Int64(clamping:m.resident_bytes)),
                "virtual_bytes": .integer(Int64(clamping:m.virtual_bytes)), "cpu_user_ns": .integer(Int64(clamping:m.cpu_user_ns)),
                "cpu_system_ns": .integer(Int64(clamping:m.cpu_system_ns)), "threads": .integer(Int64(m.threads))]
    }
}
