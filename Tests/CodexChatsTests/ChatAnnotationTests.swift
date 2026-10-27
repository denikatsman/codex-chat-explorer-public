import XCTest
@testable import CodexChats

final class ChatAnnotationTests: XCTestCase {
    func testLegacyLibraryRoundTripsAndAnnotationsPersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library-v1.json")
        let legacy = """
        {"version":1,"favoriteChatIDs":["favorite"],"excerpts":[{"id":"00000000-0000-0000-0000-000000000001","chatID":"chat","chatTitle":"Original","messageReferences":["fixture@1"],"ordinal":1,"sourcePath":"/fixture","text":"excerpt","savedAt":0}],"labels":{"chat":{"text":"Old short label","provider":"Fixture","model":"old","generatedAt":0,"sourceReferences":["fixture@1"]}}}
        """
        try Data(legacy.utf8).write(to: file)
        let library = ExplorerLibrary(directory: directory)
        XCTAssertNil(library.issue)
        XCTAssertEqual(library.state.labels["chat"]?.text, "Old short label")
        XCTAssertEqual(library.state.excerpts.first?.text, "excerpt")
        XCTAssertEqual(library.state.favoriteChatIDs, ["favorite"])
        try library.togglePinned("inactive-chat")
        try library.setTag(.purple, chatID: "chat")
        let reloaded = ExplorerLibrary(directory: directory)
        XCTAssertEqual(reloaded.state.pinnedChatIDs, ["inactive-chat"])
        XCTAssertEqual(reloaded.state.chatTags["chat"], .purple)
        XCTAssertEqual(reloaded.state.tag(for: "chat"), .purple)
        XCTAssertEqual(reloaded.state.favoriteChatIDs, ["favorite"])
        XCTAssertEqual(reloaded.state.labels["chat"]?.text, "Old short label")
        XCTAssertEqual(reloaded.state.excerpts.first?.messageReferences, ["fixture@1"])
        try reloaded.setTag(nil, chatID: "chat")
        try reloaded.togglePinned("inactive-chat")
        let cleared = ExplorerLibrary(directory: directory)
        XCTAssertTrue(cleared.state.pinnedChatIDs.isEmpty)
        XCTAssertNil(cleared.state.chatTags["chat"])
        XCTAssertEqual(cleared.state.favoriteChatIDs, ["favorite"])
    }

    func testUnknownColorIsPreservedAndBadFilesAreNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-unknown-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library-v1.json")
        let futureColor = Data(#"{"version":1,"favoriteChatIDs":[],"excerpts":[],"labels":{},"chatTags":{"future":"ultraviolet"}}"#.utf8)
        try futureColor.write(to: file)
        let library = ExplorerLibrary(directory: directory)
        XCTAssertNil(library.issue)
        XCTAssertNil(library.state.chatTags["future"])
        XCTAssertNil(library.state.tag(for: "future"))
        try library.togglePinned("chat")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((object["chatTags"] as? [String: String])?["future"], "ultraviolet")
        for raw in [#"{"version":2,"favoriteChatIDs":[],"excerpts":[],"labels":{}}"#, #"{"version":1,"favoriteChatIDs":[],"excerpts":[],"labels":{},"chatTags":{"x":7}}"#, "{broken"] {
            let original = Data(raw.utf8)
            try original.write(to: file)
            let rejected = ExplorerLibrary(directory: directory)
            XCTAssertNotNil(rejected.issue)
            XCTAssertThrowsError(try rejected.togglePinned("chat"))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testNotificationsArriveAfterMutationAndUnlock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-notify-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ExplorerLibrary(directory: directory)
        let notified = expectation(description: "Observer can read committed state")
        let observer = NotificationCenter.default.addObserver(forName: ExplorerLibrary.changed, object: nil, queue: nil) { notification in
            guard notification.object as? ExplorerLibrary === library else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(library.state.pinnedChatIDs, ["chat"])
            notified.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try library.togglePinned("chat")
        wait(for: [notified], timeout: 2)
    }
}
