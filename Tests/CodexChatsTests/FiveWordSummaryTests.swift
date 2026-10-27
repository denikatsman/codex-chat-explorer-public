import XCTest
import ModelSupport
@testable import CodexChats

final class FiveWordSummaryTests: XCTestCase {
    func testExactlyFiveWordsWithoutFabricationOrTruncation() throws {
        XCTAssertEqual(try LabelPolicy.validatedLabel("  one\ntwo   three four five  "), "one two three four five")
        for text in ["one two three four", "one two three four five six", "one two three four fi\u{0000}ve", String(repeating: "a", count: 81) + " b c d e"] {
            XCTAssertThrowsError(try LabelPolicy.validatedLabel(text), "Unexpectedly accepted \(text)")
        }
    }

    func testStructuredWordsRetainEachModelWordExactly() throws {
        let words = ["Pin", "color-coded", "chats", "safely", "today"]
        XCTAssertEqual(try LabelPolicy.validatedWords(words), words.joined(separator: " "))
        for invalid in [["one", "two", "three", "four"], ["one", "two", "three", "four", "five", "six"], ["one", "two words", "three", "four", "five"], ["one", "", "three", "four", "five"], ["one", " two", "three", "four", "five"], ["one", "two\u{0000}", "three", "four", "five"]] {
            XCTAssertThrowsError(try LabelPolicy.validatedWords(invalid))
        }
    }

    func testInvalidWorkerResultCannotReplaceLegacyLabel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-summary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ExplorerLibrary(directory: directory)
        try library.setLabel(DerivedChatLabel(text: "Legacy three words", provider: "Fixture", model: "none", generatedAt: Date(), sourceReferences: []), chatID: "chat")
        let worker = directory.appendingPathComponent("worker")
        let source = #"""
        #!/bin/sh
        read -r request || exit 2
        printf '{"kind":"result","jobID":"%s","label":"too few words"}\n' "$EXPLORER_LABEL_JOB"
        """#
        try source.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let coordinator = LabelCoordinator(workerURL: worker, jobRoot: directory.appendingPathComponent("jobs"), admission: LabelAdmission())
        let settled = expectation(description: "Invalid result rejected")
        var errorSeen = false
        coordinator.onEvent = { event in
            if event.kind == "error" { errorSeen = true; XCTAssertNil(event.label) }
            if event.kind == "settled" {
                XCTAssertNil(event.label)
                XCTAssertTrue(event.message?.contains("exactly five") == true)
                settled.fulfill()
            }
        }
        let sample = LabelSample(prompt: "Synthetic fixture only", references: [], hashes: [:], totalMessages: 1, sampledMessages: 1)
        try coordinator.start(provider: .local, sample: sample)
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(errorSeen)
        XCTAssertEqual(coordinator.startedRequests, 1)
        XCTAssertEqual(ExplorerLibrary(directory: directory).state.labels["chat"]?.text, "Legacy three words")
    }
}
