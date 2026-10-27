import XCTest
import AppKit
@testable import CodexChats

final class WindowPresentationStateTests: XCTestCase {
    private var directory: URL!
    private var library: ExplorerLibrary!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("window-presentation-\(UUID())")
        library = ExplorerLibrary(directory: directory)
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func snapshot() -> ChatSnapshot {
        let a = ProjectReference(identity: .assigned(kind: "fixture", id: "a"), name: "Project A", originalAssignment: nil, originalProject: nil)
        let b = ProjectReference(identity: .assigned(kind: "fixture", id: "b"), name: "Project B", originalAssignment: nil, originalProject: nil)
        var chats = [Chat]()
        for index in 0..<80 {
            let id = "fixture-\(index)"
            let title = "Fixture \(index)"
            let createdAt = Date(timeIntervalSince1970: TimeInterval(10000 - index))
            let archived = index % 2 == 0
            let project: ProjectReference = archived ? a : b
            let chat = Chat(original: [:], id: id, title: title, createdAt: createdAt,
                            archived: archived, issues: [], project: project)
            chats.append(chat)
        }
        let url = directory.appendingPathComponent("unavailable-state.sqlite")
        return ChatSnapshot(chats: chats, sourceURL: url, observedAt: Date(), excludedSubagents: 0, projectSourceURL: url, projectSourceIssue: nil)
    }
    private func root(_ snapshot: ChatSnapshot, workspace: ChatCanvasWorkspace? = nil) -> ChatRootView {
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false,
                                library: library, canvasWorkspace: workspace, sharedReconciliation: true, persistViewDefaults: false)
        root.show(snapshot); root.layoutSubtreeIfNeeded()
        return root
    }
    private func message(chat: Chat, source: URL) -> RecordedMessage {
        let text = (0..<150).map { "Recorded line \($0) remains available." }.joined(separator: "\n")
        let payload = try! JSONSerialization.data(withJSONObject: ["type": "agentMessage", "text": text])
        return RecordedMessage(row: ["thread_id": .text(Data(chat.id.utf8)), "turn_id": .text(Data("turn".utf8)),
            "item_id": .text(Data("item".utf8)), "rollout_ordinal": .integer(1), "item_type": .text(Data("agentMessage".utf8)),
            "item_json": .text(payload), "payload_bytes": .integer(Int64(payload.count))], source: source)
    }

    func testDuplicateCopiesLoadedDataAndKeepsNavigationAndScaleIndependent() {
        let metadata = snapshot(), first = root(snapshot()), second = root(snapshot())
        let columns = ColumnsSnapshot(gaps: nil, day: "2026-10-26", scope: "loaded fixture", chats: [])
        first.showColumns(columns)
        first.showLanes(LaneSnapshot(chats: metadata.chats, events: [], issues: 0))
        first.showMessageDay(MessageDay(interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86400), lanes: [], source: metadata.sourceURL, unreadableRows: []))
        var state = first.capturePresentationState()
        state.timeline.presentation = .date; state.timeline.archiveFilter = .archived
        state.timeline.projectScope = .project; state.dateSearch?.query = "Fixture  2"
        state.textMagnification = 1.4; state.timelineFeed = false
        state.messageDay.zoom = 4; state.messageDay.fullDay = true
        state.lanes.from = "2026-10-01"; state.lanes.to = "2026-10-26"; state.lanes.focus = 2
        first.restorePresentationState(state)
        second.restorePresentationState(first.capturePresentationState())
        let copied = second.capturePresentationState()
        XCTAssertNotEqual(first.windowInstanceID, second.windowInstanceID)
        XCTAssertEqual(copied.dateSearch?.query, "Fixture  2")
        XCTAssertEqual(copied.timeline.archiveFilter, .archived)
        XCTAssertEqual(copied.columns?.scope, "loaded fixture")
        XCTAssertEqual(copied.lanes.snapshot?.chats.count, metadata.chats.count)
        XCTAssertEqual(copied.lanes.from, "2026-10-01"); XCTAssertEqual(copied.lanes.focus, 2)
        XCTAssertEqual(copied.messageDay.zoom, 4); XCTAssertTrue(copied.messageDay.fullDay)
        XCTAssertEqual(copied.textMagnification, 1.4, accuracy: 0.0001)
        second.adjustTextSize(by: 1.1); second.setDateArchiveFilter(.nonArchived)
        XCTAssertEqual(first.textMagnification, 1.4, accuracy: 0.0001)
        XCTAssertEqual(first.timeline.dateArchiveFilter, .archived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.sourceURL.path))
    }

    func testSharedWorkspaceObserversDoNotOverwriteEachOtherAndRebindingUnsubscribes() {
        let metadata = snapshot(), workspace = ChatCanvasWorkspace(persist: false), other = ChatCanvasWorkspace(persist: false)
        var legacy = 0; workspace.onSelectionChanged = { _ in legacy += 1 }
        let first = root(metadata, workspace: workspace), second = root(metadata, workspace: workspace)
        workspace.set(["fixture-0"], included: true)
        XCTAssertEqual(first.timeline.canvasSelectedIDs, ["fixture-0"])
        XCTAssertEqual(second.timeline.canvasSelectedIDs, ["fixture-0"])
        second.bindCanvasWorkspace(other)
        workspace.set(["fixture-1"], included: true)
        XCTAssertEqual(first.timeline.canvasSelectedIDs, ["fixture-0", "fixture-1"])
        XCTAssertTrue(second.timeline.canvasSelectedIDs.isEmpty)
        other.set(["fixture-2"], included: true)
        XCTAssertEqual(second.timeline.canvasSelectedIDs, ["fixture-2"])
        XCTAssertEqual(legacy, 2)
    }

    func testSharedLibraryRefreshPreservesLoadedReaderBytesSelectionAndScroll() throws {
        let metadata = snapshot(), first = root(snapshot()), second = root(snapshot())
        let chat = metadata.chats[0], recorded = message(chat: metadata.chats[0], source: metadata.sourceURL)
        var state = first.capturePresentationState()
        state.overlay = .history
        state.history.chat = chat; state.history.snapshot = metadata
        state.history.page = HistoryPage(messages: [recorded], total: 1, hasMore: false, sourceURL: metadata.sourceURL)
        state.history.title = chat.title; state.history.wasLoading = false
        first.restorePresentationState(state)
        state = first.capturePresentationState()
        state.history.selection = (state.history.text as NSString).range(of: "Recorded line 80")
        state.history.scrollOffset = NSPoint(x: 0, y: 300)
        first.restorePresentationState(state)
        second.restorePresentationState(first.capturePresentationState())
        let before = second.capturePresentationState().history
        try library.setLabel(DerivedChatLabel(text: "Shared label", provider: "Fixture", model: "none", generatedAt: Date(), sourceReferences: []), chatID: chat.id)
        let after = second.capturePresentationState().history
        XCTAssertTrue(after.text.contains("Shared label"))
        XCTAssertEqual((after.text as NSString).substring(with: after.selection), "Recorded line 80")
        XCTAssertEqual(after.scrollOffset.y, before.scrollOffset.y, accuracy: 0.5)
        XCTAssertEqual(after.page?.messages.first?.rawPayload, recorded.rawPayload)
        XCTAssertTrue(first.timeline.derivedLabels[chat.id] == "Shared label")
    }

    func testFindCopyRetainsQueryResultsAndSelectionWithoutCopyingARequest() {
        let metadata = snapshot(), first = root(snapshot()), second = root(snapshot())
        first.showFind()
        var state = first.capturePresentationState()
        state.search.query = "literal fixture query"
        state.search.selectedRows = IndexSet(integer: 2)
        state.search.wasSearching = true
        second.restorePresentationState(state)
        let copied = second.capturePresentationState()
        XCTAssertEqual(copied.search.query, "literal fixture query")
        XCTAssertEqual(copied.search.hits.count, metadata.chats.count)
        XCTAssertEqual(copied.search.selectedRows, IndexSet(integer: 2))
        XCTAssertFalse(copied.search.wasSearching)
        XCTAssertTrue(copied.search.status.contains("Copied available results"))
        XCTAssertEqual(first.capturePresentationState().search.query, "")
    }

    func testProjectHuesMergeWhileConnectionSelectionsRemainPerView() {
        let suite = "project-hues-\(UUID())", metadata = snapshot()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = TimelineView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), persistExpansion: false, persistHues: true, hueDefaults: defaults)
        let b = TimelineView(frame: a.frame, persistExpansion: false, persistHues: true, hueDefaults: defaults)
        a.setSnapshot(metadata); b.setSnapshot(metadata); a.setPresentation(.date); b.setPresentation(.date)
        let first = metadata.chats[0].project, second = metadata.chats[1].project
        a.toggleDateConnections(first); b.toggleDateConnections(second)
        let saved = defaults.dictionary(forKey: "dateProjectConnectionHues") ?? [:]
        XCTAssertEqual(Set(saved.keys), [first.identity.savedKey, second.identity.savedKey])
        XCTAssertEqual(Set(a.dateConnectionProjects.keys), [first.identity])
        XCTAssertEqual(Set(b.dateConnectionProjects.keys), [second.identity])
    }

    func testNativeWindowReplacesResizeOverlayOnContentTransfer() {
        let window = ChatWindow(contentSize: NSSize(width: 940, height: 650))
        defer { window.contentView = nil; window.close() }
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 650)), second = NSView(frame: first.frame)
        window.contentView = first
        XCTAssertEqual(first.subviews.filter { $0 is WindowResizeEdges }.count, 1)
        window.contentView = first
        XCTAssertEqual(first.subviews.filter { $0 is WindowResizeEdges }.count, 1)
        window.contentView = second
        XCTAssertEqual(first.subviews.filter { $0 is WindowResizeEdges }.count, 0)
        XCTAssertEqual(second.subviews.filter { $0 is WindowResizeEdges }.count, 1)
        window.contentView = nil
        XCTAssertTrue(second.subviews.isEmpty)
    }
}
