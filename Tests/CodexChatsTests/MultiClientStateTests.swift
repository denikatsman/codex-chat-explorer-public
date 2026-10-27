import XCTest
import AppKit
@testable import CodexChats

/// Temporary app-owned state and Exact search only. No personal sources or model workers.
final class MultiClientStateTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var coordinator: SemanticCoordinator!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-multiclient-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "explorer-multiclient-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        coordinator = SemanticCoordinator(databaseURL: directory.appendingPathComponent("index.sqlite"), defaults: defaults, provider: {
            XCTFail("Multi-client tests must never create a model provider")
            throw SemanticFailure("No model work allowed in this fixture")
        })
    }
    override func tearDownWithError() throws {
        let stopped = expectation(description: "Shared coordinator drained")
        coordinator.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
        coordinator = nil
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func snapshot() -> ChatSnapshot {
        let source = directory.appendingPathComponent("unavailable-state.sqlite")
        return ChatSnapshot(chats: [], sourceURL: source, observedAt: Date(), excludedSubagents: 0, projectSourceURL: source, projectSourceIssue: nil)
    }
    private func controls(in pane: SearchPane) throws -> SemanticControlsView {
        try XCTUnwrap(pane.subviews.compactMap { $0 as? SemanticControlsView }.first)
    }

    func testLibraryNotificationCanReadCommittedStateAndAllEditsSurviveReload() throws {
        let library = ExplorerLibrary(directory: directory)
        var observed = [ExplorerLibraryState]()
        let observer = NotificationCenter.default.addObserver(forName: ExplorerLibrary.changed, object: library, queue: nil) { note in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(note.object as? ExplorerLibrary === library)
            // Reentrant reads require the writer to release its lock before publication.
            observed.append(library.state)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let excerpt = SavedExcerpt(id: UUID(), chatID: "a", chatTitle: "Fixture", messageReferences: ["item-1"], ordinal: 1, sourcePath: "fixture", text: "Preserved excerpt", savedAt: Date())
        try library.toggleFavorite("a")
        try library.save(excerpt)
        try library.toggleFavorite("b")
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed[0].favoriteChatIDs, ["a"])
        XCTAssertEqual(observed[1].excerpts.map(\.id), [excerpt.id])
        let reopened = ExplorerLibrary(directory: directory).state
        XCTAssertEqual(reopened.favoriteChatIDs, ["a", "b"])
        XCTAssertEqual(reopened.excerpts.map(\.id), [excerpt.id])
    }

    func testStatusSubscribersReplayOptionsAndUnsubscribeIndependently() {
        var first = [Bool](), second = [Bool](), legacyCalls = 0
        coordinator.onStatus = { _, _, _ in legacyCalls += 1 }
        let a = coordinator.observeStatus { [unowned self] _, _, _ in first.append(self.coordinator.options.keepWarm) }
        let b = coordinator.observeStatus { [unowned self] _, _, _ in second.append(self.coordinator.options.keepWarm) }
        XCTAssertEqual(first.count, 1); XCTAssertEqual(second.count, 1)
        coordinator.setOptions(SemanticOptions(keepWarm: true, throttle: false, rerank: false))
        XCTAssertEqual(first.last, true); XCTAssertEqual(second.last, true)
        coordinator.removeStatusObserver(a)
        let count = first.count
        coordinator.setOptions(SemanticOptions(keepWarm: false, throttle: true, rerank: false))
        XCTAssertEqual(first.count, count); XCTAssertEqual(second.last, false)
        XCTAssertEqual(legacyCalls, 3)
        coordinator.removeStatusObserver(b)
    }

    func testDifferentOwnerCannotCancelOrReplaceSearchAndCanSearchAfterCompletion() {
        let first = UUID(), second = UUID()
        let completed = expectation(description: "First owner completes")
        coordinator.search(query: "fixture", mode: .exact, filters: SemanticFilters(), owner: first) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        XCTAssertTrue(coordinator.isSearching(owner: first))
        coordinator.cancelSearch(owner: second)
        var rejected = false
        coordinator.search(query: "other", mode: .exact, filters: SemanticFilters(), owner: second) { result in
            if case .failure(let error) = result {
                rejected = true
                XCTAssertTrue(error.localizedDescription.contains("another Explorer window"))
            } else { XCTFail("A different owner must not replace an active search") }
        }
        XCTAssertTrue(rejected)
        XCTAssertTrue(coordinator.isSearching(owner: first))
        wait(for: [completed], timeout: 5)
        XCTAssertFalse(coordinator.isSearching(owner: first))
        let next = expectation(description: "Second owner admitted after completion")
        coordinator.search(query: "other", mode: .exact, filters: SemanticFilters(), owner: second) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            next.fulfill()
        }
        wait(for: [next], timeout: 5)
    }

    func testOwnerCancellationSuppressesItsCompletionAndReleasesAdmission() {
        let first = UUID(), second = UUID()
        var obsolete = false
        coordinator.search(query: "old", mode: .exact, filters: SemanticFilters(), owner: first) { _ in obsolete = true }
        coordinator.cancelSearch(owner: first)
        let completed = expectation(description: "Replacement client completes")
        coordinator.search(query: "new", mode: .exact, filters: SemanticFilters(), owner: second) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        XCTAssertFalse(obsolete)
    }

    func testBrowsingRefreshingAndClosingAnotherPaneDoesNotCancelAnActiveSearch() {
        _ = NSApplication.shared
        let owner = UUID()
        let completed = expectation(description: "Search survives other pane navigation")
        coordinator.search(query: "fixture", mode: .exact, filters: SemanticFilters(), owner: owner) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        var pane: SearchPane? = SearchPane(library: ExplorerLibrary(directory: directory.appendingPathComponent("library")), coordinator: coordinator)
        pane?.show(snapshot: snapshot(), mode: .chats)
        pane?.refreshOwnedData()
        pane?.show(snapshot: snapshot(), mode: .messages)
        pane?.hideSearch()
        pane = nil
        XCTAssertTrue(coordinator.isSearching(owner: owner))
        wait(for: [completed], timeout: 5)
    }

    func testHiddenPanesApplyCurrentOptionsBeforeTheirNextEdit() throws {
        _ = NSApplication.shared
        let library = ExplorerLibrary(directory: directory.appendingPathComponent("library"))
        let first = SearchPane(library: library, coordinator: coordinator)
        let second = SearchPane(library: library, coordinator: coordinator)
        let a = try controls(in: first), b = try controls(in: second)
        var status = ""
        let observation = coordinator.observeStatus { text, _, _ in status = text }
        defer { coordinator.removeStatusObserver(observation) }
        a.tools.state = .on
        a.warmth.selectItem(at: 1)
        a.onSettings?()
        XCTAssertTrue(status.hasPrefix("Tool indexing requested"))
        XCTAssertEqual(b.warmth.indexOfSelectedItem, 1)
        b.throttle.state = .on
        b.onSettings?()
        XCTAssertTrue(coordinator.options.keepWarm)
        XCTAssertTrue(coordinator.options.throttle)
        XCTAssertEqual(a.throttle.state, .on)
        XCTAssertTrue(status.hasPrefix("Tool indexing requested"), "Editing another option must not reset the global tool-index scope from a window's local filter")
        coordinator.setSemanticEnabled(false)
        XCTAssertEqual(a.power.state, .off); XCTAssertEqual(b.power.state, .off)
    }
}
