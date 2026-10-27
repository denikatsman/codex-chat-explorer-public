import XCTest
import CSQLite
@testable import CodexChats

/// All model work below is a controllable offline fixture. No personal sources or real models.
final class SemanticCoordinatorTests: XCTestCase {
    private final class Provider: SemanticEmbeddingProvider {
        let modelDigest = "offline-fixture-model"
        private let lock = NSLock()
        private var jobs = 0, peak = 0, calls = 0, stopped = 0, block = false, warm = false
        var keepWarm: Bool { get { lock.lock(); defer { lock.unlock() }; return warm } set { lock.lock(); warm = newValue; lock.unlock() } }
        var metrics: (calls: Int, peak: Int, stopped: Int) { lock.lock(); defer { lock.unlock() }; return (calls,peak,stopped) }
        func hold(_ value: Bool) { lock.lock(); block = value; lock.unlock() }
        func embed(_ texts: [String], cancellation: HistoryCancellation) throws -> [[Float]] {
            lock.lock(); calls += 1; jobs += 1; peak = max(peak,jobs); lock.unlock()
            defer { lock.lock(); jobs -= 1; lock.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while true {
                if cancellation.cancelled { throw SemanticFailure("Fixture cancelled") }
                lock.lock(); let waiting = block; lock.unlock()
                if !waiting { break }
                guard Date() < deadline else { throw SemanticFailure("Fixture bounded hold expired") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return texts.map { _ in [1] + [Float](repeating: 0, count: 4095) }
        }
        func rerank(query: String, passages: [String], cancellation: HistoryCancellation) throws -> [Double]? { nil }
        func stop() { lock.lock(); stopped += 1; block = false; lock.unlock() }
    }
    private var directory: URL!, state: URL!, history: URL!, index: URL!
    private var suite: String!, defaults: UserDefaults!, coordinator: SemanticCoordinator!, provider: Provider!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-scheduler-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        state = directory.appendingPathComponent("state_5.sqlite"); history = directory.appendingPathComponent("thread_history_1.sqlite"); index = directory.appendingPathComponent("owned/index.sqlite")
        try sql(state, "CREATE TABLE threads(id TEXT,title TEXT,created_at INTEGER,source TEXT,archived INTEGER); INSERT INTO threads VALUES('fixture','Offline scheduler fixture',1,'vscode',0)")
        try sql(history, "CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT)")
        for ordinal in 1...12 {
            let payload = try JSONSerialization.data(withJSONObject: ["type":"userMessage","content":[["type":"text","text":"Offline cache search passage number \(ordinal)"]]])
            let hex = payload.map { String(format: "%02x",$0) }.joined()
            try sql(history, "INSERT INTO thread_items VALUES('fixture','turn-\(ordinal)','item-\(ordinal)',\(ordinal),1,'userMessage',CAST(X'\(hex)' AS TEXT))")
        }
        suite = "semantic-scheduler-tests-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        provider = Provider()
        let selected = provider!
        coordinator = SemanticCoordinator(databaseURL: index, defaults: defaults, provider: { selected })
    }
    override func tearDownWithError() throws {
        if let coordinator { let done = expectation(description: "Owned scheduler stopped"); coordinator.shutdown { done.fulfill() }; wait(for: [done],timeout: 8) }
        coordinator = nil; defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func sql(_ url: URL, _ text: String) throws {
        var db: OpaquePointer?; guard sqlite3_open(url.path,&db) == SQLITE_OK else { throw SemanticFailure("Fixture open failed") }; defer { sqlite3_close(db) }
        guard sqlite3_exec(db,text,nil,nil,nil) == SQLITE_OK else { throw SemanticFailure(String(cString: sqlite3_errmsg(db))) }
    }
    private func snapshot() throws -> ChatSnapshot { try ChatStore.load(from: state, projectStateURL: directory.appendingPathComponent("no-projects.json")) }
    private func until(_ description: String, timeout: TimeInterval = 8, _ predicate: @escaping () -> Bool) {
        if predicate() { return }
        let done = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in if predicate() { timer.invalidate(); done.fulfill() } }
        wait(for: [done],timeout: timeout); timer.invalidate()
    }
    private func ready() throws {
        coordinator.updateSnapshot(try snapshot()); coordinator.setOptions(SemanticOptions(keepWarm:false,throttle:false,rerank:false))
        var complete = false
        coordinator.onStatus = { _,counts,_ in if counts.passages > 0 && counts.pending == 0 { complete = true } }
        coordinator.startIndex(); until("All fixture passages embedded") { complete }
    }
    func testPausedReopenShowsSavedCountsWithoutModelOrSourceImport() throws {
        try ready(); coordinator.pauseIndex()
        let savedSnapshot = try snapshot()
        let stopped = expectation(description:"Original fixture coordinator stopped")
        coordinator.shutdown { stopped.fulfill() }; wait(for:[stopped],timeout:5)
        // The saved index alone must be sufficient; attempting source import now would fail.
        try FileManager.default.moveItem(at:history,to:directory.appendingPathComponent("retained-history.sqlite"))
        let indexBefore = try Data(contentsOf:index)
        let previousCalls = provider.metrics.calls
        coordinator = SemanticCoordinator(databaseURL:index,defaults:defaults,provider:{ throw SemanticFailure("Saved-count display must not create a provider") },allowedSource:state)
        var counts = SemanticCounts(), status = "", running = true
        coordinator.onStatus = { text,value,active in status = text; counts = value; running = active }
        coordinator.updateSnapshot(savedSnapshot)
        until("Paused reopen publishes saved source counts") { counts.passages == 12 }
        XCTAssertEqual(counts.chats,1); XCTAssertEqual(counts.messages,12)
        XCTAssertFalse(running); XCTAssertTrue(status.hasPrefix("Index paused"))
        XCTAssertTrue(defaults.bool(forKey:"semantic.index.enabled.v1"))
        XCTAssertTrue(defaults.bool(forKey:"semantic.index.paused.v1"))
        XCTAssertEqual(provider.metrics.calls,previousCalls)
        XCTAssertEqual(try Data(contentsOf:index),indexBefore)
        // A later metadata refresh keeps the same paused status and does not import.
        coordinator.updateSnapshot(savedSnapshot)
        XCTAssertEqual(counts.passages,12); XCTAssertFalse(running)
    }
    func testInertAndAlternateSourceViewsDoNotLoadExistingSavedCounts() throws {
        try ready(); coordinator.pauseIndex()
        let stopped = expectation(description:"Fixture seed stopped")
        coordinator.shutdown { stopped.fulfill() }; wait(for:[stopped],timeout:5)
        let savedSnapshot = try snapshot()
        var received = SemanticCounts()
        let inert = SemanticCoordinator(databaseURL:index,defaults:defaults,provider:{ throw SemanticFailure("Inert provider") },allowWork:false)
        inert.onStatus = { _,counts,_ in received = counts }
        inert.updateSnapshot(savedSnapshot)
        let alternate = SemanticCoordinator(databaseURL:index,defaults:defaults,provider:{ throw SemanticFailure("Alternate provider") },allowedSource:directory.appendingPathComponent("different-state.sqlite"))
        alternate.onStatus = { _,counts,_ in received = counts }
        alternate.updateSnapshot(savedSnapshot)
        let drained = expectation(description:"Idle fixture queues drained"); drained.expectedFulfillmentCount = 2
        inert.shutdown { drained.fulfill() }; alternate.shutdown { drained.fulfill() }
        wait(for:[drained],timeout:5)
        XCTAssertEqual(received.passages,0)
        XCTAssertTrue(defaults.bool(forKey:"semantic.index.paused.v1"))
    }
    func testBrowsingSettingsAndPausedSourceScopeNeverInvokeModels() throws {
        coordinator.updateSnapshot(try snapshot())
        coordinator.setOptions(SemanticOptions(keepWarm:true,throttle:false,rerank:true))
        coordinator.configureSourceScope(includeTools: true)
        let flushed = expectation(description: "Exact search uses no provider")
        coordinator.search(query:"cache",mode:.exact,filters:SemanticFilters()) { _ in flushed.fulfill() }
        wait(for:[flushed],timeout:5)
        XCTAssertEqual(provider.metrics.calls,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path + "-journal"))
    }
    func testPauseCancelAndResumeRetainCompletedVectorsAndCleanOwnedProvider() throws {
        try ready()
        coordinator.pauseIndex()
        let before = provider.metrics.calls
        let searched = expectation(description:"Saved vectors searchable while paused")
        coordinator.search(query:"cache",mode:.meaning,filters:SemanticFilters()) { result in
            XCTAssertFalse((try? result.get())?.isEmpty ?? true); searched.fulfill()
        }
        wait(for:[searched],timeout:5)
        XCTAssertEqual(provider.metrics.calls,before + 1)
        coordinator.cancelIndex()
        let original = try Data(contentsOf: history)
        var readyAgain = false
        coordinator.onStatus = { text,counts,_ in readyAgain = text.hasPrefix("Index ready") && counts.passages == 12 && counts.pending == 0 }
        coordinator.startIndex(); until("Resume uses saved vectors") { readyAgain }
        // Flush the serial queue after resume so a hidden redundant embed cannot escape the check.
        let flushed = expectation(description:"Resume queue drained")
        coordinator.search(query:"cache",mode:.exact,filters:SemanticFilters()) { _ in flushed.fulfill() }
        wait(for:[flushed],timeout:5)
        XCTAssertEqual(provider.metrics.calls,before + 1)
        XCTAssertEqual(try Data(contentsOf: history),original)
        XCTAssertEqual(provider.metrics.peak,1)
    }
    func testSemanticOffCancelsActiveSearchReleasesProviderAndRetainsExactSearch() throws {
        try ready(); coordinator.pauseIndex(); provider.hold(true)
        let original = try Data(contentsOf: history), before = provider.metrics.calls
        var obsolete = false
        coordinator.search(query:"blocked",mode:.meaning,filters:SemanticFilters()) { _ in obsolete = true }
        until("Model search admitted") { self.provider.metrics.calls > before }
        coordinator.setSemanticEnabled(false)
        until("Off drains cancelled request and releases provider") { self.provider.metrics.stopped == 1 }
        XCTAssertFalse(coordinator.semanticEnabled); XCTAssertFalse(obsolete)
        XCTAssertEqual(coordinator.indexingState,"Semantic OFF · Indexing OFF")
        XCTAssertFalse(defaults.bool(forKey:"semantic.module.enabled.v1"))
        XCTAssertFalse(defaults.bool(forKey:"semantic.index.enabled.v1"))
        coordinator.startIndex(); coordinator.updateSnapshot(try snapshot())
        coordinator.search(query:"cache",mode:.combined,filters:SemanticFilters()) { result in
            if case .success = result { XCTFail("Off must reject model search") }
        }
        let exact = expectation(description:"Exact search remains available while off")
        coordinator.search(query:"cache",mode:.exact,filters:SemanticFilters()) { result in
            XCTAssertFalse((try? result.get())?.isEmpty ?? true); exact.fulfill()
        }
        wait(for:[exact],timeout:5)
        XCTAssertEqual(provider.metrics.calls,before + 1)
        XCTAssertEqual(try Data(contentsOf:history),original)
    }
    func testSemanticOffCancelsPartialIndexAndRequiresExplicitResumeAfterTurningOn() throws {
        coordinator.updateSnapshot(try snapshot())
        coordinator.setOptions(SemanticOptions(keepWarm:false,throttle:false,rerank:false))
        coordinator.onStatus = { [weak self] _,counts,_ in if counts.embedded == 8 { self?.provider.hold(true) } }
        coordinator.startIndex()
        until("Second batch admitted after first eight saved passages") { self.provider.metrics.calls >= 2 }
        coordinator.onStatus = nil; coordinator.setSemanticEnabled(false)
        until("Index model released") { self.provider.metrics.stopped == 1 }
        let calls = provider.metrics.calls
        coordinator.setSemanticEnabled(true)
        let flushed = expectation(description:"Turning on alone leaves indexing stopped")
        coordinator.search(query:"cache",mode:.exact,filters:SemanticFilters()) { _ in flushed.fulfill() }
        wait(for:[flushed],timeout:5)
        XCTAssertEqual(provider.metrics.calls,calls)
        XCTAssertEqual(coordinator.indexingState,"Indexing STOPPED")
        var complete = false
        coordinator.onStatus = { _,counts,_ in if counts.embedded == 12 { complete = true } }
        coordinator.startIndex(); until("Resume finishes only remaining passages") { complete }
        XCTAssertEqual(provider.metrics.calls,calls + 1)
    }
    func testSemanticOffPersistsAcrossReopenEvenWithOldIndexEnabledPreference() throws {
        try ready(); coordinator.setSemanticEnabled(false)
        let done = expectation(description:"Initial coordinator drained")
        coordinator.shutdown { done.fulfill() }; wait(for:[done],timeout:5)
        defaults.set(true,forKey:"semantic.index.enabled.v1")
        let calls = provider.metrics.calls
        coordinator = SemanticCoordinator(databaseURL:index,defaults:defaults,provider:{ throw SemanticFailure("Off must not create a provider") })
        XCTAssertFalse(coordinator.semanticEnabled)
        coordinator.updateSnapshot(try snapshot()); coordinator.startIndex()
        let exact = expectation(description:"Saved index works after disabled reopen")
        coordinator.search(query:"cache",mode:.exact,filters:SemanticFilters()) { result in
            XCTAssertFalse((try? result.get())?.isEmpty ?? true); exact.fulfill()
        }
        wait(for:[exact],timeout:5)
        XCTAssertEqual(provider.metrics.calls,calls)
        XCTAssertEqual(coordinator.indexingState,"Semantic OFF · Indexing OFF")
    }
    func testSupersededAndCancelledQueriesCannotPublishAndIndexingResumes() throws {
        try ready(); provider.hold(true)
        let initial = provider.metrics.calls
        var obsolete = false, cancelled = false
        coordinator.search(query:"obsolete",mode:.meaning,filters:SemanticFilters()) { _ in obsolete = true }
        until("First query admitted") { self.provider.metrics.calls > initial }
        coordinator.search(query:"replacement",mode:.meaning,filters:SemanticFilters()) { _ in cancelled = true }
        until("Replacement query admitted") { self.provider.metrics.calls >= initial + 2 }
        coordinator.cancelSearch(); provider.hold(false)
        let done = expectation(description:"Newest query completes")
        coordinator.search(query:"cache",mode:.meaning,filters:SemanticFilters()) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }; done.fulfill()
        }
        wait(for:[done],timeout:5)
        XCTAssertFalse(obsolete); XCTAssertFalse(cancelled)
        XCTAssertEqual(provider.metrics.peak,1)
        coordinator.pauseIndex()
    }
    func testCancellingPrioritySearchResumesPartiallyCompletedIndex() throws {
        coordinator.updateSnapshot(try snapshot())
        coordinator.setOptions(SemanticOptions(keepWarm:false,throttle:false,rerank:false))
        var complete = false
        coordinator.onStatus = { [weak self] _,counts,_ in
            guard let self else { return }
            if counts.embedded == 8 { self.provider.hold(true) }
            if counts.passages == 12 && counts.pending == 0 { complete = true }
        }
        coordinator.startIndex()
        until("Second indexing batch held after eight saved passages") { self.provider.metrics.calls >= 2 }
        var cancelledCallback = false
        coordinator.search(query:"priority",mode:.meaning,filters:SemanticFilters()) { _ in cancelledCallback = true }
        until("Priority query replaces cancelled batch") { self.provider.metrics.calls >= 3 }
        coordinator.cancelSearch()
        // Prevent the existing-progress callback from re-applying the controlled hold.
        coordinator.onStatus = { _,counts,_ in if counts.passages == 12 && counts.pending == 0 { complete = true } }
        provider.hold(false)
        until("Pending passages finish after query cancellation") { complete }
        XCTAssertFalse(cancelledCallback)
        XCTAssertEqual(provider.metrics.peak,1)
        XCTAssertGreaterThanOrEqual(provider.metrics.calls,4)
    }
    func testShutdownCancelsAnActiveJobStopsProviderAndRejectsLaterWork() throws {
        try ready(); provider.hold(true)
        let calls = provider.metrics.calls
        var lateCompletion = false
        coordinator.search(query:"blocked",mode:.meaning,filters:SemanticFilters()) { _ in lateCompletion = true }
        until("Blocked search admitted") { self.provider.metrics.calls > calls }
        let stopped = expectation(description:"Shutdown drains cancelled work")
        coordinator.shutdown { stopped.fulfill() }; wait(for:[stopped],timeout:5)
        XCTAssertFalse(lateCompletion); XCTAssertEqual(provider.metrics.stopped,1)
        let rejected = expectation(description:"After shutdown rejected")
        coordinator.search(query:"cache",mode:.meaning,filters:SemanticFilters()) { result in
            if case .success = result { XCTFail("Shutdown must reject admission") }; rejected.fulfill()
        }
        wait(for:[rejected],timeout:2)
        XCTAssertEqual(provider.metrics.calls,calls + 1)
    }
    func testRenderAdmissionCannotUsePersistedEnabledIndexOrMutatePreferences() throws {
        defaults.set(true, forKey: "semantic.index.enabled.v1")
        let before = defaults.persistentDomain(forName: suite) as NSDictionary?
        let selected = provider!
        let path = directory.appendingPathComponent("must-not-be-created/index.sqlite")
        let inert = SemanticCoordinator(databaseURL: path, defaults: defaults, provider: { selected }, allowWork: false)
        inert.updateSnapshot(try snapshot())
        inert.startIndex(); inert.setOptions(SemanticOptions(keepWarm:true,throttle:true,rerank:true))
        inert.pauseIndex(); inert.cancelIndex()
        let rejected = expectation(description: "Render model admission rejected")
        inert.search(query:"cache",mode:.meaning,filters:SemanticFilters()) { result in
            if case .success = result { XCTFail("Render must not admit a search") }; rejected.fulfill()
        }
        wait(for:[rejected],timeout:2)
        let done = expectation(description:"Inert cleanup")
        inert.shutdown { done.fulfill() }; wait(for:[done],timeout:2)
        XCTAssertEqual(selected.metrics.calls,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
        XCTAssertEqual(defaults.persistentDomain(forName:suite) as NSDictionary?,before)
    }

    func testMemoryPressurePausesAdmissionAndKeepsSavedIndex() throws {
        try ready()
        let calls = provider.metrics.calls
        coordinator.handleMemoryPressure(constrained:true)
        let rejected = expectation(description:"Memory pressure rejects model work")
        coordinator.search(query:"cache",mode:.meaning,filters:SemanticFilters()) { result in
            if case .success = result { XCTFail("Memory pressure must reject model admission") }; rejected.fulfill()
        }
        wait(for:[rejected],timeout:2)
        XCTAssertEqual(provider.metrics.calls,calls)
        coordinator.handleMemoryPressure(constrained:false)
        let available = expectation(description:"Saved vectors survive pressure pause")
        coordinator.search(query:"cache",mode:.meaning,filters:SemanticFilters()) { result in
            XCTAssertFalse((try? result.get())?.isEmpty ?? true); available.fulfill()
        }
        wait(for:[available],timeout:5)
        XCTAssertTrue(defaults.bool(forKey:"semantic.index.paused.v1"))
    }

    func testProductionSourceGateRejectsFixtureSnapshotsBeforeAnyWork() throws {
        defaults.set(true,forKey:"semantic.index.enabled.v1")
        let selected = provider!
        let path = directory.appendingPathComponent("guarded/index.sqlite")
        let guarded = SemanticCoordinator(databaseURL:path,defaults:defaults,provider:{ selected },allowedSource:directory.appendingPathComponent("expected-original/state_5.sqlite"))
        var rejectedSource = false
        guarded.onStatus = { text,_,_ in if text.contains("different source") { rejectedSource = true } }
        guarded.updateSnapshot(try snapshot())
        let rejected = expectation(description:"Wrong source search rejected")
        guarded.search(query:"cache",mode:.exact,filters:SemanticFilters()) { result in
            if case .success = result { XCTFail("Wrong-source search must fail before touching the production index") }; rejected.fulfill()
        }
        wait(for:[rejected],timeout:2)
        let done = expectation(description:"Source guard cleanup")
        guarded.shutdown { done.fulfill() }; wait(for:[done],timeout:2)
        XCTAssertTrue(rejectedSource); XCTAssertEqual(selected.metrics.calls,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
    }

}
