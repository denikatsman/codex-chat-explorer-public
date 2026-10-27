import AppKit
import XCTest
@testable import WindowingKit

final class CoreTests: XCTestCase {
    private struct Document: Codable, Equatable, Identifiable {
        var id: String
        var value: String
    }
    private func store(_ file: URL? = nil) -> WorkspaceStore<Document> {
        WorkspaceStore(file: file, initialDocuments: [Document(id: "a", value: "one"), Document(id: "b", value: "two")], valid: { !$0.value.isEmpty })
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUnknownTransferKindRoundTripsAndCompletionIsOneUse() throws {
        let kind = WindowTransferKind(rawValue: "custom.panel")
        let source = WindowTransferSource(kind: kind, presentationID: "item")
        let data = try XCTUnwrap(source.payload.data)
        XCTAssertEqual(WindowTransferPayload.read(data)?.kind, kind)
        XCTAssertEqual(String(data: try JSONEncoder().encode(kind), encoding: .utf8), "\"custom.panel\"")
        var accepted = 0, cancelled = 0, finished = 0
        source.onAccepted = { _ in accepted += 1 }
        source.onCancelled = { cancelled += 1 }
        source.onFinished = { _ in finished += 1 }
        XCTAssertTrue(source.accept(canvasID: "destination", at: .zero) { true })
        XCTAssertFalse(source.accept(canvasID: "destination", at: .zero) { true })
        source.markCancelled()
        source.complete(operation: [], mouseReleased: true)
        source.complete(operation: [], mouseReleased: true)
        XCTAssertEqual(accepted, 1); XCTAssertEqual(cancelled, 0); XCTAssertEqual(finished, 1)
    }

    func testTransactionPublishesCompleteStateAndRejectsInvalidChanges() {
        let model = store()
        var observed = [[Document]]()
        _ = model.observe { _ in observed.append(model.documents) }
        XCTAssertTrue(model.transaction { documents in
            documents[0].value = "new a"; documents[1].value = "new b"; return true
        })
        XCTAssertEqual(observed.count, 2)
        XCTAssertTrue(observed.allSatisfy { $0 == model.documents })
        let before = model.documents
        XCTAssertFalse(model.transaction { documents in documents[1].id = documents[0].id; return true })
        XCTAssertFalse(model.transaction { documents in documents[0].value = ""; return true })
        XCTAssertFalse(model.transaction { documents in documents.removeAll(); return true })
        XCTAssertFalse(model.transaction { documents in documents[0].value = "rejected"; return false })
        XCTAssertEqual(model.documents, before); XCTAssertEqual(observed.count, 2)
    }

    func testNestedMutationIsRejectedButObserversMayMutateAfterCommit() {
        let model = store()
        var nestedAccepted = true
        XCTAssertTrue(model.transaction { documents in
            documents[0].value = "outer"
            nestedAccepted = model.change("b") { $0.value = "inner" }
            XCTAssertFalse(model.flush())
            return true
        })
        XCTAssertFalse(nestedAccepted)
        XCTAssertEqual(model.document("a")?.value, "outer")
        XCTAssertEqual(model.document("b")?.value, "two")
        var didMutate = false
        _ = model.observe { id in
            if id == "a", !didMutate {
                didMutate = true
                XCTAssertTrue(model.change("b") { $0.value = "observer" })
            }
        }
        XCTAssertTrue(model.change("a") { $0.value = "next" })
        XCTAssertTrue(didMutate)
        XCTAssertEqual(model.document("b")?.value, "observer")
    }

    func testNotificationsReflectChangesAndRelativeReordering() {
        let model = store()
        var ids = [String]()
        _ = model.observe { ids.append($0) }
        XCTAssertTrue(model.transaction { $0.append(Document(id: "c", value: "three")); return true })
        XCTAssertEqual(ids, ["c"]); ids.removeAll()
        XCTAssertTrue(model.transaction { $0.removeAll { $0.id == "b" }; return true })
        XCTAssertEqual(ids, ["b"]); ids.removeAll()
        XCTAssertTrue(model.transaction { $0.swapAt(0, 1); return true })
        XCTAssertEqual(ids, ["a", "c"]); ids.removeAll()
        XCTAssertTrue(model.change("c") { $0.value = "changed" })
        XCTAssertEqual(ids, ["c"])
    }

    func testVersionOneLiteralAndExistingFilePrecedeInvalidLegacySeed() throws {
        let file = try temporaryDirectory().appendingPathComponent("workspace.json")
        let bytes = Data(#"{"version":1,"documents":[{"id":"existing","value":"saved"}]}"#.utf8)
        try bytes.write(to: file)
        let model = WorkspaceStore(file: file, initialDocuments: [Document(id: "fallback", value: "initial")],
                                   initialIssue: "Legacy seed failed", valid: { !$0.value.isEmpty })
        XCTAssertFalse(model.isReadOnly); XCTAssertNil(model.issue)
        XCTAssertEqual(model.documents, [Document(id: "existing", value: "saved")])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPersistencePreservesMalformedFileAndRetriesFailure() throws {
        let directory = try temporaryDirectory()
        let malformed = directory.appendingPathComponent("malformed.json")
        let original = Data("{invalid".utf8)
        try original.write(to: malformed)
        let broken = store(malformed)
        XCTAssertTrue(broken.isReadOnly); XCTAssertNotNil(broken.issue)
        XCTAssertFalse(broken.flush()); XCTAssertEqual(try Data(contentsOf: malformed), original)

        let blocker = directory.appendingPathComponent("blocker")
        try Data("file".utf8).write(to: blocker)
        let target = blocker.appendingPathComponent("workspace.json")
        let model = store(target)
        XCTAssertTrue(model.change("a") { $0.value = "changed" })
        XCTAssertFalse(model.flush()); XCTAssertTrue(model.hasUnsavedChanges); XCTAssertNotNil(model.issue)
        try FileManager.default.removeItem(at: blocker)
        XCTAssertTrue(model.flush()); XCTAssertFalse(model.hasUnsavedChanges); XCTAssertNil(model.issue)
        XCTAssertEqual(store(target).document("a")?.value, "changed")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
    }

    func testCancelledDebouncedWriteCannotReplaceFlushedSnapshot() throws {
        let target = try temporaryDirectory().appendingPathComponent("workspace.json")
        let model = store(target)
        XCTAssertTrue(model.change("a") { $0.value = "first" })
        XCTAssertTrue(model.change("a") { $0.value = "last" })
        XCTAssertTrue(model.flush())
        let done = expectation(description: "cancelled debounce interval passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(store(target).document("a")?.value, "last")
        XCTAssertFalse(model.hasUnsavedChanges)
    }
}
