import Foundation
import CSQLite

/// Bounds observational work. A stopped read is unavailable, never an empty result.
final class SourceReadBudget {
    let cancellation: HistoryCancellation
    private let deadline: TimeInterval
    init(cancellation: HistoryCancellation, seconds: TimeInterval = 5) {
        self.cancellation = cancellation
        deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds)
    }
    var stopped: Bool { cancellation.cancelled || ProcessInfo.processInfo.systemUptime >= deadline }
    func check() throws {
        if cancellation.cancelled { throw StoreError(message: "Source read cancelled.") }
        if stopped { throw StoreError(message: "Source read exceeded its five-second budget. Open an individual chat or refresh to retry.") }
    }
    func install(on db: OpaquePointer) {
        sqlite3_progress_handler(db, 10_000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<SourceReadBudget>.fromOpaque(pointer).takeUnretainedValue().stopped ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func remove(from db: OpaquePointer) { sqlite3_progress_handler(db, 0, nil, nil) }
}
