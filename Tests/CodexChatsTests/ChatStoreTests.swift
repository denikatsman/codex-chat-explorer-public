import XCTest
import CSQLite
import AppKit
@testable import CodexChats

final class ChatStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL!
    private var db: OpaquePointer?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-chats-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("fixture.sqlite")
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        try sql("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, created_at INTEGER, created_at_ms INTEGER, updated_at INTEGER, archived INTEGER, source TEXT, thread_source TEXT, cwd TEXT, rollout_path TEXT)")
        try sql("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT)")
        try writeProjects()
    }

    override func tearDownWithError() throws {
        sqlite3_close(db)
        try FileManager.default.removeItem(at: directory)
    }

    private func sql(_ statement: String) throws {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private var projectURL: URL { directory.appendingPathComponent(".codex-global-state.json") }

    private func writeProjects(assignments: [String: Any] = [:], projects: [String: Any] = [:]) throws {
        let value: [String: Any] = ["thread-project-assignments": assignments, "local-projects": projects, "projectless-thread-ids": []]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: projectURL)
    }

    private func insert(_ id: String, seconds: Int, ms: Int? = nil, updated: Int = 0,
                        archived: Bool = false, source: String = "vscode", name: String? = nil) throws {
        let escapedSource = source.replacingOccurrences(of: "'", with: "''")
        let escapedName = name.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        try sql("INSERT INTO threads VALUES ('\(id)', 'Same title', \(escapedName), \(seconds), \(ms.map(String.init) ?? "NULL"), \(updated), \(archived ? 1 : 0), '\(escapedSource)', 'user', '/fixture', '/fixture/rollout.jsonl')")
    }

    func testCreationOrderingNamesArchivesAndDistinctIdentities() throws {
        try insert("old", seconds: 100, updated: 999999, archived: true, name: "Renamed by user")
        try insert("new", seconds: 200, ms: 200999)
        try insert("same-second", seconds: 200, ms: 200001)
        let snapshot = try ChatStore.load(from: url)
        XCTAssertEqual(snapshot.chats.map(\.id), ["new", "same-second", "old"])
        XCTAssertEqual(snapshot.chats.last?.title, "Renamed by user")
        XCTAssertEqual(snapshot.archivedCount, 1)
        XCTAssertEqual(snapshot.chats[0].createdAt?.timeIntervalSince1970 ?? 0, 200.999, accuracy: 0.00001)
        XCTAssertEqual(snapshot.chats.last?.original["created_at"], .integer(100))
        XCTAssertEqual(snapshot.chats.last?.original["name"], .text(Data("Renamed by user".utf8)))
        // Identical titles do not collapse separate IDs. Updated time never affects sorting.
        XCTAssertEqual(snapshot.chats.count, 3)
    }

    func testRecordedSubagentsExcludedWithoutGuessingFromTitleOrFolder() throws {
        try insert("parent", seconds: 100)
        try insert("edge-child", seconds: 110)
        try sql("INSERT INTO thread_spawn_edges VALUES ('parent', 'edge-child', 'running')")
        // Repeated edge records must not duplicate a chat.
        try sql("INSERT INTO thread_spawn_edges VALUES ('parent', 'edge-child', 'done')")
        try insert("source-child", seconds: 120, source: "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"parent\"}}}")
        try insert("guardian", seconds: 130, source: "{\"subagent\":{\"other\":\"guardian\"}}")
        try insert("same-folder", seconds: 140, name: "subagent is just a title")
        let snapshot = try ChatStore.load(from: url)
        XCTAssertEqual(snapshot.chats.map(\.id), ["same-folder", "parent"])
        XCTAssertEqual(snapshot.excludedSubagents, 3)
    }

    func testMalformedMetadataRetainsOriginalTypesAndBytes() throws {
        try insert("malformed", seconds: 100, source: "{unfinished")
        try sql("UPDATE threads SET created_at='bad date', created_at_ms=NULL, title=CAST(X'FFFE' AS TEXT), name=NULL, archived=NULL WHERE id='malformed'")
        try insert("valid", seconds: 200)
        let snapshot = try ChatStore.load(from: url)
        XCTAssertEqual(snapshot.chats.map(\.id), ["valid", "malformed"])
        let chat = try XCTUnwrap(snapshot.chats.last)
        XCTAssertNil(chat.createdAt)
        XCTAssertEqual(chat.title, "Untitled chat")
        XCTAssertEqual(chat.original["title"], .text(Data([0xff, 0xfe])))
        XCTAssertEqual(chat.original["created_at"], .text(Data("bad date".utf8)))
        XCTAssertEqual(chat.original["archived"], .null)
        XCTAssertEqual(chat.issues.count, 4)
        XCTAssertEqual(snapshot.issueCount, 1)
    }

    func testReadOnlySourceAndTranscriptSeparation() throws {
        try insert("chat", seconds: 100)
        let originalDB = try Data(contentsOf: url)
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        let originalBytes = Data("{\"type\":\"compacted\",\"payload\":{\"unknown\":true}}\n{partial".utf8) + Data([0xff])
        try originalBytes.write(to: rollout)
        try sql("UPDATE threads SET rollout_path='\(rollout.path)' WHERE id='chat'")
        let beforeRead = try Data(contentsOf: url)
        let originalProjectBytes = try Data(contentsOf: projectURL)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        _ = try ChatStore.load(from: url)
        XCTAssertEqual(try Data(contentsOf: url), beforeRead)
        XCTAssertEqual(try Data(contentsOf: rollout), originalBytes)
        XCTAssertEqual(try Data(contentsOf: projectURL), originalProjectBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), filesBefore)
        XCTAssertNotEqual(originalDB, beforeRead) // Fixture setup actually changed the recorded path.
    }

    func testWALSnapshotIncludesCommittedRowsAndLeavesConnectionUsable() throws {
        try sql("PRAGMA journal_mode=WAL")
        try insert("first", seconds: 100)
        XCTAssertEqual(try ChatStore.load(from: url).chats.map(\.id), ["first"])
        try insert("second", seconds: 200)
        XCTAssertEqual(try ChatStore.load(from: url).chats.map(\.id), ["second", "first"])
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_db_readonly(reader, "main"), 1)
        XCTAssertEqual(sqlite3_exec(reader, "DELETE FROM threads", nil, nil, nil), SQLITE_READONLY)
        XCTAssertEqual(try ChatStore.load(from: url).chats.count, 2)
    }

    func testMissingCorruptAndEmptySourcesAreDistinct() throws {
        XCTAssertTrue(try ChatStore.load(from: url).chats.isEmpty)
        let missing = directory.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try ChatStore.load(from: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let corrupt = directory.appendingPathComponent("corrupt.sqlite")
        let bytes = Data([0xff, 0xfe, 0x7b, 0x00])
        try bytes.write(to: corrupt)
        XCTAssertThrowsError(try ChatStore.load(from: corrupt))
        XCTAssertEqual(try Data(contentsOf: corrupt), bytes)
    }

    func testLegacySchemaAndUnknownColumnsDoNotBlockList() throws {
        try sql("DROP TABLE threads")
        try sql("CREATE TABLE threads (id TEXT, title TEXT, created_at INTEGER, archived INTEGER, source TEXT, future_field BLOB)")
        try sql("INSERT INTO threads VALUES ('legacy', 'Legacy title', 100, 1, 'unknown', X'ABCD')")
        let snapshot = try ChatStore.load(from: url)
        XCTAssertEqual(snapshot.chats.first?.title, "Legacy title")
        XCTAssertEqual(snapshot.chats.first?.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.archivedCount, 1)
    }

    func testGroupsUseRecordedIdentityKeepCreationOrderAndNoProjectLast() throws {
        try insert("old", seconds: 100, archived: true)
        try insert("new", seconds: 200)
        try insert("other", seconds: 300)
        try insert("unassigned", seconds: 999)
        try writeProjects(assignments: [
            "old": ["projectKind": "local", "projectId": "one"],
            "new": ["projectKind": "local", "projectId": "one"],
            "other": ["projectKind": "local", "projectId": "two"]
        ], projects: ["one": ["name": "Same name"], "two": ["name": "Same name"]])
        let snapshot = try ChatStore.load(from: url)
        let groups = snapshot.groups
        XCTAssertEqual(groups.map(\.project.identity), [.assigned(kind: "local", id: "two"), .assigned(kind: "local", id: "one"), .noProject])
        XCTAssertEqual(groups[1].chats.map(\.id), ["new", "old"])
        XCTAssertEqual(groups.last?.project.name, "No project")
        XCTAssertTrue(groups[1].chats.last?.archived == true)
        XCTAssertEqual(groups.flatMap(\.chats).count, snapshot.chats.count)
    }

    func testDesktopAssignmentWinsOverCoreIDAndNeverGuessesFromFolder() throws {
        try insert("assigned", seconds: 100)
        try insert("same-folder", seconds: 200)
        try sql("ALTER TABLE threads ADD COLUMN project_id TEXT")
        try sql("UPDATE threads SET project_id='core-only' WHERE id='assigned'")
        try writeProjects(assignments: ["assigned": ["projectKind": "local", "projectId": "desktop", "future": "preserved"]],
                          projects: ["desktop": ["name": "Actual project", "rootPaths": ["/fixture"], "future": 7]])
        let snapshot = try ChatStore.load(from: url)
        let assigned = try XCTUnwrap(snapshot.chats.first { $0.id == "assigned" })
        XCTAssertEqual(assigned.project.identity, .assigned(kind: "local", id: "desktop"))
        XCTAssertEqual(assigned.original["project_id"], .text(Data("core-only".utf8)))
        XCTAssertEqual((assigned.project.originalAssignment as? [String: Any])?["future"] as? String, "preserved")
        XCTAssertEqual((assigned.project.originalProject as? [String: Any])?["future"] as? Int, 7)
        XCTAssertEqual(snapshot.chats.first { $0.id == "same-folder" }?.project.identity, .noProject)
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as? [String: Any])
        state["projectless-thread-ids"] = ["assigned"]
        try JSONSerialization.data(withJSONObject: state).write(to: projectURL)
        let conflicting = try XCTUnwrap(ChatStore.load(from: url).chats.first { $0.id == "assigned" })
        XCTAssertEqual(conflicting.project.identity, .assigned(kind: "local", id: "desktop"))
        XCTAssertTrue(conflicting.issues.contains { $0.contains("Conflicting projectless flag") })
    }

    func testMissingOrMalformedProjectMetadataIsNotUnassigned() throws {
        try insert("chat", seconds: 100)
        try FileManager.default.removeItem(at: projectURL)
        var snapshot = try ChatStore.load(from: url)
        XCTAssertNotNil(snapshot.projectSourceIssue)
        XCTAssertEqual(snapshot.groups.first?.project.identity, .unavailable)
        let malformed = Data("{partial".utf8)
        try malformed.write(to: projectURL)
        snapshot = try ChatStore.load(from: url)
        XCTAssertEqual(snapshot.chats.count, 1)
        XCTAssertEqual(snapshot.groups.first?.project.identity, .unavailable)
        XCTAssertEqual(try Data(contentsOf: projectURL), malformed)
        try writeProjects()
        snapshot = try ChatStore.load(from: url)
        XCTAssertNil(snapshot.projectSourceIssue)
        XCTAssertEqual(snapshot.groups.first?.project.identity, .noProject)
    }

    func testUnknownProjectsAndMalformedAssignmentsRemainVisible() throws {
        try insert("missing-name", seconds: 100)
        try insert("bad-assignment", seconds: 200)
        try writeProjects(assignments: [
            "missing-name": ["projectKind": "local", "projectId": "deleted-project"],
            "bad-assignment": NSNull()
        ])
        let snapshot = try ChatStore.load(from: url)
        XCTAssertEqual(snapshot.chats.count, 2)
        XCTAssertEqual(snapshot.groups.first?.project.identity, .assigned(kind: "local", id: "deleted-project"))
        XCTAssertEqual(snapshot.groups.last?.project.identity, .unavailable)
        XCTAssertTrue(snapshot.chats.first?.project.originalAssignment is NSNull)
        XCTAssertEqual(snapshot.issueCount, 2)
    }

    func testViewButtonsRestoreChronologyAndPreserveCollapsedProjects() throws {
        _ = NSApplication.shared
        try insert("old", seconds: 100, archived: true)
        try insert("new", seconds: 200)
        try insert("unassigned", seconds: 999)
        try insert("unknown", seconds: 0)
        try sql("UPDATE threads SET created_at='unknown' WHERE id='unknown'")
        try writeProjects(assignments: ["old": ["projectKind": "local", "projectId": "one"], "new": ["projectKind": "local", "projectId": "one"]],
                          projects: ["one": ["name": "Project one"]])
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false)
        root.show(try ChatStore.load(from: url))
        let identity = ProjectIdentity.assigned(kind: "local", id: "one")
        root.timeline.toggleGroup(identity)
        let date = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { ($0.toolTip ?? $0.accessibilityHelp()) == "Show all chats by creation date" })
        let project = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { ($0.toolTip ?? $0.accessibilityHelp()) == "Show chats grouped by project" })
        date.performClick(nil)
        XCTAssertEqual(root.timeline.presentation, .date)
        XCTAssertEqual(root.timeline.entries.compactMap(\.chat).map(\.id), ["unassigned", "new", "old", "unknown"])
        XCTAssertTrue(root.timeline.entries.compactMap(\.group).isEmpty)
        XCTAssertTrue(root.timeline.entries.compactMap(\.chat).first { $0.id == "old" }?.archived == true)
        XCTAssertEqual(root.timeline.entries.compactMap(\.day).last, "UNKNOWN DATE")
        try insert("arriving", seconds: 450)
        root.show(try ChatStore.load(from: url))
        XCTAssertEqual(root.timeline.presentation, .date)
        XCTAssertEqual(root.timeline.entries.compactMap(\.chat).map(\.id), ["unassigned", "arriving", "new", "old", "unknown"])
        project.performClick(nil)
        XCTAssertEqual(root.timeline.presentation, .project)
        XCTAssertFalse(root.timeline.isExpanded(identity))
        XCTAssertEqual(root.timeline.groups.flatMap(\.chats).count, 5)
        root.timeline.toggleGroup(identity)
        XCTAssertEqual(root.timeline.entries.compactMap(\.chat).map(\.id), ["new", "old"])
    }

    func testDateArchiveFiltersCombineWithProjectsAndKeepUnknownStatusInAll() throws {
        _ = NSApplication.shared
        try insert("a-old", seconds: 100, archived: true)
        try insert("a-new", seconds: 200000)
        try insert("b-old", seconds: 300000, archived: true)
        try insert("b-new", seconds: 400000)
        try insert("unknown-status", seconds: 500000)
        try sql("UPDATE threads SET archived=NULL WHERE id='unknown-status'")
        try insert("unknown-date", seconds: 0)
        try sql("UPDATE threads SET created_at='unknown' WHERE id='unknown-date'")
        try writeProjects(assignments: [
            "a-old": ["projectKind": "local", "projectId": "a"],
            "a-new": ["projectKind": "local", "projectId": "a"],
            "b-old": ["projectKind": "local", "projectId": "b"],
            "b-new": ["projectKind": "local", "projectId": "b"]
        ], projects: ["a": ["name": "A"], "b": ["name": "B"]])
        let snapshot = try ChatStore.load(from: url)
        let before = try Data(contentsOf: url)
        let originalProjects = try Data(contentsOf: projectURL)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false)
        root.show(snapshot); root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        func ids() -> [String] { root.timeline.entries.compactMap(\.chat).map(\.id) }
        XCTAssertEqual(root.timeline.dateArchiveFilter, .all)
        XCTAssertEqual(ids(), snapshot.chats.map(\.id))
        root.setDateArchiveFilter(.nonArchived)
        XCTAssertEqual(ids(), ["b-new", "a-new", "unknown-date"])
        XCTAssertEqual(root.timeline.dateArchivedCount, 0)
        XCTAssertEqual(root.timeline.entries.compactMap(\.day).last, "UNKNOWN DATE")
        root.setDateArchiveFilter(.archived)
        XCTAssertEqual(ids(), ["b-old", "a-old"])
        XCTAssertEqual(root.timeline.entries.compactMap(\.day).count, 2)
        XCTAssertEqual(root.timeline.dateArchivedCount, 2)
        let a = try XCTUnwrap(snapshot.chats.first { $0.id == "a-new" }?.project)
        root.timeline.toggleDateConnections(a); root.toggleDateSelectionFilter()
        XCTAssertEqual(ids(), ["a-old"])
        root.setDateArchiveFilter(.nonArchived)
        XCTAssertEqual(ids(), ["a-new"])
        root.setDateArchiveFilter(.all)
        XCTAssertEqual(ids(), ["a-new", "a-old"])
        root.setDateArchiveFilter(.archived)
        XCTAssertTrue(root.clearDateSelectionFilter())
        XCTAssertEqual(root.timeline.dateArchiveFilter, .archived)
        XCTAssertEqual(ids(), ["b-old", "a-old"])
        root.setPresentation(.project)
        XCTAssertEqual(root.timeline.groups.flatMap(\.chats).count, snapshot.chats.count)
        root.setPresentation(.date)
        XCTAssertEqual(ids(), ["b-old", "a-old"])
        root.toggleDateSelectionFilter()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try Data(contentsOf: projectURL), originalProjects)
        try sql("UPDATE threads SET archived=0 WHERE id='a-old'")
        root.show(try ChatStore.load(from: url))
        XCTAssertEqual(root.timeline.dateArchiveFilter, .archived)
        XCTAssertEqual(root.timeline.dateChatCount, 0)
        XCTAssertTrue(root.timeline.entries.isEmpty)
        root.setDateArchiveFilter(.all)
        XCTAssertEqual(ids(), ["a-new", "a-old"])
        XCTAssertEqual(snapshot.chats.count, 6)
    }

    func testDateProjectScopesCombineWithArchiveAndSelectionWithoutChangingSources() throws {
        _ = NSApplication.shared
        try insert("assigned", seconds: 300)
        try insert("unassigned", seconds: 200)
        try insert("archived", seconds: 100, archived: true)
        try insert("unknown", seconds: 50)
        try writeProjects(assignments: [
            "assigned": ["projectKind": "local", "projectId": "a"],
            "archived": ["projectKind": "local", "projectId": "a"],
            "unknown": "invalid assignment"
        ], projects: ["a": ["name": "No project"]])
        let snapshot = try ChatStore.load(from: url)
        let originalDB = try Data(contentsOf: url), originalProjects = try Data(contentsOf: projectURL)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 1100, height: 650), persistTheme: false, loadOnDemand: false)
        root.show(snapshot); root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        let funnel = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Filter selected projects" })
        func ids() -> [String] { root.timeline.entries.compactMap(\.chat).map(\.id) }
        XCTAssertEqual(ids(), ["assigned", "unassigned", "archived", "unknown"])
        let project = try XCTUnwrap(snapshot.chats.first { $0.id == "assigned" }?.project)
        root.timeline.toggleDateConnections(project); root.toggleDateSelectionFilter()
        root.setDateProjectScope(.nonProject)
        XCTAssertEqual(ids(), ["unassigned"])
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        XCTAssertFalse(funnel.isEnabled)
        XCTAssertEqual(root.timeline.dateConnectionProjects.count, 1)
        root.timeline.setDateSelectionFilterEnabled(true)
        root.toggleDateSelectionFilter()
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        root.setDateProjectScope(.project)
        XCTAssertEqual(ids(), ["assigned", "archived"], "Use membership identity, not a project's display name")
        XCTAssertTrue(funnel.isEnabled)
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        root.setDateArchiveFilter(.archived)
        XCTAssertEqual(ids(), ["archived"])
        root.setDateProjectScope(.nonProject)
        XCTAssertTrue(ids().isEmpty)
        root.setDateArchiveFilter(.all)
        root.setDateProjectScope(.all)
        XCTAssertEqual(ids(), snapshot.chats.map(\.id), "Unknown membership remains visible in ALL")
        root.setDateProjectScope(.project); root.toggleDateSelectionFilter()
        XCTAssertTrue(root.timeline.dateSelectionFilterEnabled)
        root.setPresentation(.project); root.setPresentation(.date)
        XCTAssertEqual(root.timeline.dateProjectScope, .project)
        XCTAssertEqual(ids(), ["assigned", "archived"])
        XCTAssertEqual(try Data(contentsOf: url), originalDB)
        XCTAssertEqual(try Data(contentsOf: projectURL), originalProjects)
    }

    func testDateArchiveControlFitsNarrowWindowAndKeepsSelectionAcrossTabs() throws {
        _ = NSApplication.shared
        try insert("chat", seconds: 100)
        let snapshot = try ChatStore.load(from: url)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false)
        root.show(snapshot); root.setPresentation(.date)
        let controls = root.subviews.compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel()?.hasPrefix("Archive filter:") == true }.sorted { $0.tag < $1.tag }
        let scopes = root.subviews.compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel()?.hasPrefix("Project scope:") == true }.sorted { $0.tag < $1.tag }
        XCTAssertEqual(controls.count, 3)
        XCTAssertEqual(scopes.map(\.title), ["ALL", "NON-PROJECT", "PROJECT"])
        let date = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { ($0.toolTip ?? $0.accessibilityHelp()) == "Show all chats by creation date" })
        let active = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { ($0.toolTip ?? $0.accessibilityHelp()) == "Show confirmed live activity in local desktop chats" })
        for width: CGFloat in [600, 940, 966, 1100] {
            root.setFrameSize(NSSize(width: width, height: 650)); root.needsLayout = true; root.layoutSubtreeIfNeeded()
            if width < 966 { XCTAssertGreaterThan(scopes[0].frame.minY, date.frame.maxY) }
            else { XCTAssertGreaterThanOrEqual(scopes[0].frame.minX, active.frame.maxX + 11.9) }
            XCTAssertEqual(controls[0].frame.minX - scopes[2].frame.maxX, 12)
            XCTAssertEqual(controls[2].frame.maxX, width - 22)
            for control in controls + scopes {
                XCTAssertEqual(control.frame.minY, width < 966 ? 70 : date.frame.minY)
                XCTAssertEqual(control.frame.height, date.frame.height)
                XCTAssertFalse(control.isHidden)
                XCTAssertNil(control.toolTip)
                XCTAssertLessThanOrEqual(control.attributedTitle.size().width + 8, control.frame.width)
            }
            XCTAssertEqual(controls[0].frame.maxX, controls[1].frame.minX)
            XCTAssertEqual(controls[1].frame.maxX, controls[2].frame.minX)
        }
        for (index, scope) in DateProjectScope.allCases.enumerated() {
            scopes[index].performClick(nil)
            XCTAssertEqual(root.timeline.dateProjectScope, scope)
            XCTAssertEqual(scopes.filter { $0.accessibilityLabel()?.hasSuffix(", selected") == true }.count, 1)
        }
        for (index, filter) in DateArchiveFilter.allCases.enumerated() {
            controls[index].performClick(nil)
            XCTAssertEqual(root.timeline.dateArchiveFilter, filter)
            XCTAssertEqual(controls.filter { $0.accessibilityLabel()?.hasSuffix(", selected") == true }.count, 1)
            XCTAssertTrue(controls[index].accessibilityLabel()?.hasSuffix(", selected") == true)
        }
        root.setPresentation(.project)
        XCTAssertTrue((controls + scopes).allSatisfy(\.isHidden))
        root.setPresentation(.date)
        XCTAssertTrue(controls.allSatisfy { !$0.isHidden })
        XCTAssertEqual(root.timeline.dateArchiveFilter, .archived)
        XCTAssertEqual(root.timeline.dateProjectScope, .project)
    }

    func testDateSelectionFilterUsesIdentityUnionAndKeepsSourceChronology() throws {
        _ = NSApplication.shared
        try insert("a-old", seconds: 100, archived: true)
        try insert("a-new", seconds: 200000)
        try insert("b", seconds: 100000)
        try insert("c", seconds: 250000)
        try insert("none", seconds: 300000)
        try writeProjects(assignments: [
            "a-old": ["projectKind": "local", "projectId": "a"],
            "a-new": ["projectKind": "local", "projectId": "a"],
            "b": ["projectKind": "local", "projectId": "b"],
            "c": ["projectKind": "local", "projectId": "c"]
        ], projects: ["a": ["name": "Same name"], "b": ["name": "Same name"], "c": ["name": "Other"]])
        let snapshot = try ChatStore.load(from: url)
        let originalDB = try Data(contentsOf: url), originalProjects = try Data(contentsOf: projectURL)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false)
        root.show(snapshot); root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        func ids() -> [String] { root.timeline.entries.compactMap(\.chat).map(\.id) }
        let a = try XCTUnwrap(snapshot.chats.first { $0.id == "a-new" }?.project)
        let b = try XCTUnwrap(snapshot.chats.first { $0.id == "b" }?.project)
        root.timeline.toggleDateConnections(a); root.timeline.toggleDateConnections(b)
        XCTAssertEqual(ids(), snapshot.chats.map(\.id))
        root.toggleDateSelectionFilter()
        XCTAssertEqual(ids(), ["a-new", "b", "a-old"])
        XCTAssertEqual(root.timeline.dateChatCount, 3)
        XCTAssertEqual(root.timeline.dateArchivedCount, 1)
        root.setPresentation(.project)
        XCTAssertEqual(root.timeline.groups.flatMap(\.chats).count, 5)
        root.setPresentation(.date)
        XCTAssertEqual(ids(), ["a-new", "b", "a-old"])
        root.timeline.toggleDateConnections(b)
        XCTAssertEqual(ids(), ["a-new", "a-old"], "Removing a project updates the active filter by identity, even for matching names")
        root.timeline.toggleDateConnections(b)
        XCTAssertEqual(ids(), ["a-new", "b", "a-old"])
        XCTAssertEqual(try Data(contentsOf: url), originalDB)
        XCTAssertTrue(root.clearDateSelectionFilter())
        XCTAssertEqual(root.timeline.dateConnectionProjects.count, 2)
        XCTAssertEqual(ids(), snapshot.chats.map(\.id))
        root.toggleDateSelectionFilter()
        // Removing the last selection automatically returns to the complete list.
        root.timeline.toggleDateConnections(a); root.timeline.toggleDateConnections(b)
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        XCTAssertEqual(ids(), snapshot.chats.map(\.id))
        root.timeline.toggleDateConnections(a); root.toggleDateSelectionFilter()
        // Refresh removes vanished project identities and cannot strand an empty active filter.
        try sql("DELETE FROM threads WHERE id LIKE 'a-%'")
        let refreshed = try ChatStore.load(from: url)
        root.show(refreshed)
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        XCTAssertTrue(root.timeline.dateConnectionProjects.isEmpty)
        XCTAssertEqual(ids(), refreshed.chats.map(\.id))
        XCTAssertEqual(try Data(contentsOf: projectURL), originalProjects)
    }

    func testDateSelectionFilterAccessibleClickClearEscapeAndScrollRestoration() throws {
        _ = NSApplication.shared
        var assignments = [String: Any]()
        for index in 0..<50 {
            let id = "chat-\(index)"
            try insert(id, seconds: index + 1)
            assignments[id] = ["projectKind": "local", "projectId": index.isMultiple(of: 2) ? "a" : "b"]
        }
        try writeProjects(assignments: assignments, projects: ["a": ["name": "One"], "b": ["name": "Two"]])
        let snapshot = try ChatStore.load(from: url)
        let originalDB = try Data(contentsOf: url)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false)
        let window = ChatWindow(contentSize: root.frame.size)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        root.show(snapshot); root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        root.scroll.contentView.scroll(to: NSPoint(x: 0, y: 420))
        let before = root.scroll.contentView.bounds.origin
        let filterButton = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Filter selected projects" })
        XCTAssertFalse(filterButton.isEnabled)
        XCTAssertNil(filterButton.toolTip)
        XCTAssertEqual(filterButton.accessibilityHelp(), "Select projects using the connection buttons.")
        root.toggleDateSelectionFilter()
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        XCTAssertFalse(root.timeline.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.contains { $0.accessibilityLabel()?.contains("filter by project") == true } ?? true)
        let connectionsButton = try XCTUnwrap(root.timeline.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel()?.contains("show project connections") == true })
        XCTAssertTrue(connectionsButton.accessibilityPerformPress())
        let connectedProject = try XCTUnwrap(root.timeline.dateConnectionProjects.keys.first)
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        XCTAssertEqual(root.timeline.entries.compactMap(\.chat).map(\.id), snapshot.chats.map(\.id))
        XCTAssertTrue(filterButton.isEnabled)
        filterButton.performClick(nil)
        XCTAssertTrue(root.timeline.dateSelectionFilterEnabled)
        XCTAssertNotNil(root.timeline.dateConnectionProjects[connectedProject])
        XCTAssertEqual(root.scroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(filterButton.state, .on)
        filterButton.performClick(nil)
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        XCTAssertNotNil(root.timeline.dateConnectionProjects[connectedProject])
        XCTAssertEqual(root.scroll.contentView.bounds.origin, before)
        root.toggleDateSelectionFilter()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        XCTAssertFalse(root.timeline.dateSelectionFilterEnabled)
        XCTAssertEqual(root.scroll.contentView.bounds.origin, before)
        XCTAssertEqual(try Data(contentsOf: url), originalDB)
        root.toggleDateSelectionFilter()
        // A new chat above the saved position should not change the restored chat.
        try insert("arriving", seconds: 100)
        root.show(try ChatStore.load(from: url))
        XCTAssertTrue(root.clearDateSelectionFilter())
        let arrivingHeight = try XCTUnwrap(root.timeline.entries.first(where: { $0.chat?.id == "arriving" })).height
        XCTAssertEqual(root.scroll.contentView.bounds.origin.y, before.y + arrivingHeight)
    }

    func testCollapsingAndRefreshingRetainEveryChatAndArchiveState() throws {
        try insert("old", seconds: 100, archived: true)
        try insert("new", seconds: 200)
        try writeProjects(assignments: ["old": ["projectKind": "local", "projectId": "one"], "new": ["projectKind": "local", "projectId": "one"]],
                          projects: ["one": ["name": "Project one"]])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistExpansion: false)
        var snapshot = try ChatStore.load(from: url)
        view.setSnapshot(snapshot)
        let identity = ProjectIdentity.assigned(kind: "local", id: "one")
        XCTAssertEqual(view.entries.compactMap(\.chat).map(\.id), ["new", "old"])
        // Exercise the accessible heading's press action, not only a model method.
        let header = try XCTUnwrap(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertTrue(header.accessibilityPerformPress())
        XCTAssertTrue(view.entries.compactMap(\.chat).isEmpty)
        XCTAssertEqual(view.groups.flatMap(\.chats).count, 2)
        try insert("arriving", seconds: 300)
        try writeProjects(assignments: ["old": ["projectKind": "local", "projectId": "one"], "new": ["projectKind": "local", "projectId": "one"], "arriving": ["projectKind": "local", "projectId": "one"]],
                          projects: ["one": ["name": "Renamed project"]])
        snapshot = try ChatStore.load(from: url)
        view.setSnapshot(snapshot)
        XCTAssertFalse(view.isExpanded(identity))
        XCTAssertEqual(view.groups.first?.project.name, "Renamed project")
        XCTAssertEqual(view.groups.flatMap(\.chats).count, 3)
        view.toggleGroup(identity)
        XCTAssertEqual(view.entries.compactMap(\.chat).map(\.id), ["arriving", "new", "old"])
        XCTAssertTrue(view.entries.compactMap(\.chat).last?.archived == true)
    }
    func testColumnsScopeKeepsOriginalBytesDuplicatesAndMalformedRecords() throws {
        try insert("one", seconds: 100)
        let rollout = directory.appendingPathComponent("source.jsonl")
        try sql("UPDATE threads SET rollout_path='\(rollout.path)' WHERE id='one'")
        let record = Data("{\"timestamp\":\"2026-10-13T10:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"text\":\"Same message\"}]}}\n".utf8)
        let compaction = Data("{\"type\":\"compacted\",\"payload\":{\"opaque\":\"unchanged\"}}\n".utf8)
        let partial = Data([123, 255, 0])
        let bytes = record + record + compaction + partial
        try bytes.write(to: rollout)
        let metadata = try ChatStore.load(from: url)
        let before = try Data(contentsOf: url)
        let data = try ColumnsStore.load(metadata, now: ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!)
        XCTAssertEqual(data.messageCount, 2)
        let messages = try XCTUnwrap(data.chats.first?.messages)
        XCTAssertNotEqual(messages[0].id, messages[1].id)
        XCTAssertEqual(messages.map { Data(base64Encoded: $0.raw_base64!)! }, [record, record])
        XCTAssertEqual(messages.map(\.source_offset), [0, record.count])
        XCTAssertEqual(data.gaps?.count, 1)
        XCTAssertEqual(Data(base64Encoded: data.gaps![0].raw_base64!), partial)
        XCTAssertEqual(try Data(contentsOf: rollout), bytes)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testEveryTabRetainsItsDocumentPositionAndLaneFocus() throws {
        _ = NSApplication.shared
        for index in 0..<50 { try insert("chat-\(index)", seconds: index + 1) }
        let metadata = try ChatStore.load(from: url)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false)
        root.show(metadata)
        let object: [String: Any] = ["day": "2026-10-13", "scope": "TEST FIXTURE", "chats": (0..<4).map { index in
            ["id": "chat-\(index)", "title": "Chat \(index)", "messages": (0..<20).map { minute in
                ["id": "\(index):\(minute)", "timestamp": String(format: "2026-10-13T10:%02d:00Z", minute), "role": "user", "text": "Fixture text"]
            }] as [String: Any]
        }]
        root.setPresentation(.columns)
        root.layoutSubtreeIfNeeded()
        root.showColumns(try JSONDecoder().decode(ColumnsSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertGreaterThanOrEqual(root.columnsView?.frame.width ?? 0, 4 * 320)
        XCTAssertGreaterThan(root.columnsView?.frame.height ?? 0, 650)
        let events = (0..<20).map { index in LaneEvent(key: "event-\(index)", chatIndex: 0, kind: .userMessage, date: Date(timeIntervalSince1970: Double(index + 1)), preview: "Fixture", originalMessage: nil, originalTimestamp: .integer(Int64(index + 1))) }
        root.showLanes(LaneSnapshot(chats: Array(metadata.chats.prefix(1)), events: events, issues: 0))
        root.lanePanel.setFocus(0)
        let order = root.lanePanel.canvas.events.map(\.key)
        func press(_ tip: String) throws {
            let button = try XCTUnwrap(root.subviews.compactMap { $0 as? NSButton }.first { ($0.toolTip ?? $0.accessibilityHelp()) == tip })
            button.performClick(nil); root.layoutSubtreeIfNeeded()
        }
        try press("Show time-aligned message columns")
        XCTAssertTrue(root.scroll.documentView === root.columnsView)
        root.scroll.contentView.scroll(to: NSPoint(x: 100, y: 250))
        let position = root.scroll.contentView.bounds.origin
        try press("Show recorded user messages in colored chat lanes")
        XCTAssertFalse(root.lanePanel.isHidden)
        XCTAssertTrue(root.scroll.isHidden)
        try press("Show all chats by creation date")
        XCTAssertTrue(root.scroll.documentView === root.timeline)
        try press("Show messages across chats on one daily timeline")
        XCTAssertTrue(root.scroll.documentView === root.messageDay)
        try press("Show chats grouped by project")
        try press("Show time-aligned message columns")
        XCTAssertEqual(root.scroll.contentView.bounds.origin, position)
        XCTAssertEqual(root.lanePanel.canvas.focus, 0)
        XCTAssertEqual(root.lanePanel.canvas.events.map(\.key), order)
    }

    func testColumnsRejectsOversizedRecordsWithoutChangingSources() throws {
        try insert("oversized", seconds: 100)
        let rollout = directory.appendingPathComponent("large.jsonl")
        let bytes = Data(repeating: 120, count: ColumnsStore.maximumRecordBytes + 1)
        try bytes.write(to: rollout)
        try sql("UPDATE threads SET rollout_path='\(rollout.path)' WHERE id='oversized'")
        let metadata = try ChatStore.load(from: url)
        let result = try ColumnsStore.load(metadata)
        XCTAssertEqual(result.messageCount, 0)
        XCTAssertTrue(result.scope.contains("NON-ARCHIVED"))
        XCTAssertTrue(result.chats[0].source_issue?.contains("16 MiB") == true)
        XCTAssertEqual(try Data(contentsOf: rollout), bytes)
        let cancelled = HistoryCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try ColumnsStore.load(metadata, cancellation: cancelled))
        XCTAssertThrowsError(try LaneStore.load(home: directory, metadata: metadata, cancellation: cancelled))
        XCTAssertThrowsError(try MessageTimelineStore.load(metadata, day: Date(), cancellation: cancelled))
    }

    func testColumnPreviewIsBoundedSeparatelyFromCapturedBytes() throws {
        let value: [String: Any] = ["id":"message", "timestamp":"2026-10-22T10:00:00Z", "role":"user", "text":String(repeating:"x",count:20_000), "raw_base64":"b3JpZ2luYWw="]
        let message = try JSONDecoder().decode(ColumnsSnapshot.Message.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(message.text.count, 20_000)
        XCTAssertLessThan(message.displayText.count, 12_100)
        XCTAssertEqual(Data(base64Encoded: message.raw_base64!), Data("original".utf8))
    }

    func testSQLReadBudgetInterruptsWorkAndBoundsMaterializedRows() throws {
        let token = HistoryCancellation()
        let budget = SourceReadBudget(cancellation: token, seconds: 0.02)
        let handle = try XCTUnwrap(db)
        budget.install(on: handle)
        XCTAssertThrowsError(try ChatStore.rows(handle, "WITH RECURSIVE numbers(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM numbers WHERE n<1000000000) SELECT sum(n) FROM numbers"))
        budget.remove(from: handle)
        XCTAssertThrowsError(try budget.check())
        XCTAssertThrowsError(try ChatStore.rows(handle, "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3", maxRows: 2))
        XCTAssertEqual(try ChatStore.rows(handle, "SELECT 1 AS value").first?["value"], .integer(1))
    }

    func testThemesReachEveryViewAndWindowReturnsToSquareFrame() throws {
        _ = NSApplication.shared
        let root = ChatRootView(frame: NSRect(x:0,y:0,width:940,height:650), persistTheme:false, loadOnDemand:false)
        let window = ChatWindow(contentSize: root.frame.size); window.contentView = root
        defer { window.contentView = nil; window.close() }
        for theme in AppTheme.allCases {
            root.setTheme(theme)
            XCTAssertEqual(root.timeline.dark, theme.isDark)
            XCTAssertEqual(root.timeline.green, theme == .green)
            XCTAssertEqual(root.activeChats.green, theme == .green)
            XCTAssertEqual(root.messageDay.green, theme == .green)
            XCTAssertEqual(root.lanePanel.canvas.green, theme == .green)
            let actual = try XCTUnwrap(window.backgroundColor.usingColorSpace(.sRGB))
            let expected = try XCTUnwrap(AppTheme.background(dark: theme.isDark).usingColorSpace(.sRGB))
            for (a,b) in zip([actual.redComponent,actual.greenComponent,actual.blueComponent,actual.alphaComponent],
                             [expected.redComponent,expected.greenComponent,expected.blueComponent,expected.alphaComponent]) {
                XCTAssertEqual(a,b,accuracy:0.00001)
            }
        }
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        window.styleMask.insert(.titled)
        window.windowDidExitFullScreen(Notification(name:NSWindow.didExitFullScreenNotification,object:window))
        XCTAssertFalse(window.styleMask.contains(.titled))
        window.styleMask.insert(.titled); window.windowDidFailToEnterFullScreen(window)
        XCTAssertFalse(window.styleMask.contains(.titled))
    }

    func testLaneAdapterPreservesCrossChatCopiesMalformedPayloadAndSourceBytes() throws {
        try insert("one", seconds: 100)
        try insert("two", seconds: 200, archived: true)
        let metadata = try ChatStore.load(from: url)
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(history.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        func execute(_ statement: String) throws {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
        }
        try execute("CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER, created_at_ms, item_type TEXT, item_json TEXT)")
        let payload = "{\"content\":[{\"type\":\"text\",\"text\":\"Duplicate copy\"}]}"
        for id in ["one", "two"] {
            try execute("INSERT INTO thread_items VALUES ('\(id)','turn','same-item',0,300000,'userMessage','\(payload)')")
        }
        try execute("INSERT INTO thread_items VALUES ('one','turn','broken',1,NULL,'userMessage',CAST(X'FF7B' AS TEXT))")
        try execute("INSERT INTO thread_items VALUES ('one','turn','tool',2,400000,'commandExecution','{}')")
        sqlite3_close(db)
        let original = try Data(contentsOf: history)
        let lanes = try LaneStore.load(home: directory, metadata: metadata)
        XCTAssertEqual(lanes.chats.count, 2)
        XCTAssertEqual(lanes.messageCount, 3)
        XCTAssertEqual(lanes.events.filter { $0.preview == "Duplicate copy" }.count, 2)
        XCTAssertTrue(lanes.chats.contains { $0.archived })
        XCTAssertEqual(lanes.events.last?.originalMessage, .text(Data([255, 123])))
        XCTAssertEqual(lanes.events.last?.originalTimestamp, .null)
        XCTAssertEqual(lanes.issues, 2)
        XCTAssertEqual(try Data(contentsOf: history), original)
    }

    func testLaneOverviewDefersLargeBodiesWithoutDroppingMessageIdentity() throws {
        try insert("one", seconds:100)
        let metadata = try ChatStore.load(from:url)
        let history = directory.appendingPathComponent("thread_history_1.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(history.path,&handle),SQLITE_OK)
        let connection = try XCTUnwrap(handle)
        XCTAssertEqual(sqlite3_exec(connection,"CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_type TEXT,item_json TEXT)",nil,nil,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection,"INSERT INTO thread_items VALUES('one','turn','large',1,200000,'userMessage',CAST(zeroblob(1048577) AS TEXT))",nil,nil,nil),SQLITE_OK)
        sqlite3_close(connection)
        let original = try Data(contentsOf:history)
        let lanes = try LaneStore.load(home:directory,metadata:metadata)
        let event = try XCTUnwrap(lanes.events.first { $0.kind == .userMessage })
        XCTAssertEqual(lanes.messageCount,1)
        XCTAssertEqual(event.key,"message:one:turn:large")
        XCTAssertNil(event.originalMessage)
        XCTAssertTrue(event.preview.contains("1048577"))
        XCTAssertEqual(try Data(contentsOf:history),original)
    }

}
