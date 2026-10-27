import Foundation

/// A bounded length-prefixed socket buffer. Consumed prefixes must be released:
/// Data.removeFirst() advances its slice index and can retain earlier packets.
struct ActiveFrameBuffer {
    private var storage = Data()
    private var cursor = 0
    let maximumPayload: Int
    init(maximumPayload: Int = 64 * 1024 * 1024) { self.maximumPayload = maximumPayload }
    var pendingBytes: Int { storage.count - cursor }
    var retainedBytes: Int { storage.count }
    mutating func compact() {
        guard cursor > 0 else { return }
        storage = cursor == storage.count ? Data() : storage.subdata(in: cursor..<storage.count)
        cursor = 0
    }
    mutating func append(_ bytes: Data) throws {
        compact()
        guard bytes.count <= 65_536, storage.count + bytes.count <= maximumPayload + 4 + 65_536 else {
            throw StoreError(message: "Codex status buffer exceeded its bounded frame capacity.")
        }
        storage.append(bytes)
    }
    mutating func next() throws -> Data? {
        guard pendingBytes >= 4 else { return nil }
        let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(storage[cursor + $1]) << (8 * $1) }
        guard size > 0, size <= maximumPayload else { throw StoreError(message: "Codex status frame exceeds the supported size boundary.") }
        let end = cursor + 4 + Int(size)
        guard storage.count >= end else { return nil }
        let result = storage.subdata(in: (cursor + 4)..<end)
        cursor = end
        if cursor == storage.count { storage = Data(); cursor = 0 }
        return result
    }
}
