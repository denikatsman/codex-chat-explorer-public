import XCTest
import AppKit
@testable import CodexChats

final class SemanticUITests: XCTestCase {
    func testControlsFitNarrowFindPaneWithoutOverlappingRows() {
        _ = NSApplication.shared
        for width: CGFloat in [268, 468, 500, 568] {
            let controls = SemanticControlsView(frame: NSRect(x: 0, y: 0, width: width, height: SemanticControlsView.preferredHeight(forWidth: width)))
            controls.layout()
            let visible = controls.subviews.filter { !$0.isHidden }
            for view in visible {
                XCTAssertGreaterThanOrEqual(view.frame.minX, 0)
                XCTAssertLessThanOrEqual(view.frame.maxX, controls.bounds.width)
                XCTAssertLessThanOrEqual(view.frame.maxY, controls.bounds.height)
            }
            for (index, first) in visible.enumerated() {
                for second in visible.dropFirst(index + 1) { XCTAssertFalse(first.frame.intersects(second.frame), "Controls overlap at \(width): \(first), \(second)") }
            }
            XCTAssertEqual(controls.searchMode, .combined)
            XCTAssertFalse(controls.filters.includeTools)
            XCTAssertFalse(controls.filters.finalOnly)
            XCTAssertEqual(controls.tools.accessibilityRole(), .checkBox)
            XCTAssertEqual(controls.finals.accessibilityRole(), .checkBox)
        }
    }

    func testOptionsAreIndependentAndOnlyExplicitActionsInvokeWork() {
        _ = NSApplication.shared
        let controls = SemanticControlsView(frame: .zero)
        var starts = 0, pauses = 0, cancels = 0, settings = 0
        controls.onStart = { starts += 1 }; controls.onPause = { pauses += 1 }
        controls.onCancel = { cancels += 1 }; controls.onSettings = { settings += 1 }
        for warm in [false, true] {
            for throttle in [false, true] {
                controls.show(options: SemanticOptions(keepWarm: warm, throttle: throttle, rerank: true))
                XCTAssertEqual(controls.options.keepWarm, warm)
                XCTAssertEqual(controls.options.throttle, throttle)
                XCTAssertTrue(controls.options.rerank)
            }
        }
        XCTAssertEqual(starts + pauses + cancels + settings, 0)
        for (index, expected) in SemanticSearchMode.allCases.enumerated() {
            controls.mode.selectItem(at: index)
            XCTAssertEqual(controls.searchMode, expected)
        }
        controls.tools.performClick(nil)
        XCTAssertTrue(controls.filters.includeTools)
        XCTAssertFalse(controls.filters.finalOnly)
        controls.finals.performClick(nil)
        XCTAssertTrue(controls.filters.includeTools)
        XCTAssertTrue(controls.filters.finalOnly)
        XCTAssertEqual(settings, 2)
        XCTAssertEqual(starts + pauses + cancels, 0)
        controls.showStatus("Indexing", counts: SemanticCounts(chats: 5, messages: 10, passages: 12, embedded: 4, skipped: 1, missing: 2), running: true)
        XCTAssertFalse(controls.start.isEnabled); XCTAssertTrue(controls.pause.isEnabled); XCTAssertTrue(controls.cancel.isEnabled)
        controls.pause.performClick(nil); controls.cancel.performClick(nil)
        XCTAssertEqual(pauses, 1); XCTAssertEqual(cancels, 1); XCTAssertEqual(starts, 0)
        controls.showStatus("Paused", counts: SemanticCounts(), running: false)
        XCTAssertTrue(controls.start.isEnabled); XCTAssertFalse(controls.pause.isEnabled); XCTAssertFalse(controls.cancel.isEnabled)
        controls.start.performClick(nil); XCTAssertEqual(starts, 1)
        XCTAssertTrue(controls.status.stringValue.contains("0/0"))
    }
    func testExactModeDisablesRerankingWithoutDiscardingPreference() {
        _ = NSApplication.shared
        let controls = SemanticControlsView(frame:.zero)
        controls.show(options:SemanticOptions(keepWarm:false,throttle:true,rerank:true))
        controls.mode.selectItem(at:2); controls.refreshModeState()
        XCTAssertFalse(controls.rerank.isEnabled); XCTAssertTrue(controls.options.rerank)
        controls.mode.selectItem(at:0); controls.refreshModeState()
        XCTAssertTrue(controls.rerank.isEnabled); XCTAssertTrue(controls.options.rerank)
    }
    func testPowerControlKeepsExactAvailableAndRestoresSelectedMeaningMode() {
        _ = NSApplication.shared
        let controls = SemanticControlsView(frame:.zero)
        controls.mode.selectItem(at:1)
        var selected: Bool?
        controls.onEnabledChanged = { selected = $0 }
        controls.power.performClick(nil); XCTAssertEqual(selected,false)
        controls.showStatus("Models released",counts:SemanticCounts(passages:12,embedded:8),running:false,semanticEnabled:false,indexingState:"Semantic OFF · Indexing OFF")
        XCTAssertEqual(controls.power.title,"SEMANTIC OFF")
        XCTAssertEqual(controls.searchMode,.exact); XCTAssertFalse(controls.mode.isEnabled)
        for control in [controls.start,controls.pause,controls.cancel,controls.warmth,controls.throttle,controls.rerank] as [NSControl] { XCTAssertFalse(control.isEnabled) }
        XCTAssertTrue(controls.status.stringValue.hasPrefix("Semantic OFF · Indexing OFF"))
        controls.power.performClick(nil); XCTAssertEqual(selected,true)
        controls.showStatus("Ready",counts:SemanticCounts(),running:false,semanticEnabled:true,indexingState:"Indexing STOPPED")
        XCTAssertEqual(controls.searchMode,.meaning); XCTAssertTrue(controls.mode.isEnabled)
        XCTAssertTrue(controls.start.isEnabled); XCTAssertTrue(controls.rerank.isEnabled)
        XCTAssertTrue(controls.status.stringValue.hasPrefix("Indexing STOPPED"))
    }
    func testControlsRenderOffscreenAtMinimumWidth() throws {
        _ = NSApplication.shared
        let width: CGFloat = 268
        let controls = SemanticControlsView(frame: NSRect(x: 0, y: 0, width: width, height: SemanticControlsView.preferredHeight(forWidth: width)))
        controls.show(options: SemanticOptions(keepWarm:false,throttle:true,rerank:false))
        controls.showStatus("Index paused; saved passages searchable", counts: SemanticCounts(chats:1263,messages:49700,passages:80000,embedded:12000,skipped:3,missing:16), running:false)
        controls.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(controls.bitmapImageRepForCachingDisplay(in: controls.bounds))
        controls.cacheDisplay(in: controls.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using:.png, properties:[:]))
        XCTAssertGreaterThan(png.count,500)
        if let destination = ProcessInfo.processInfo.environment["SEMANTIC_UI_SNAPSHOT"] { try png.write(to: URL(fileURLWithPath: destination)) }
    }
    private func passage(_ id: String, chat: String, tool: Bool = false) -> SemanticPassage {
        SemanticPassage(id: id, chatID: chat, itemID: "item-" + id, turnID: "turn-1", ordinal: 42,
                        role: tool ? "TOOL" : "ASSISTANT", phase: "final", text: "Normalized excerpt", context: "Context", createdAt: nil, sourceDigest: "source-digest")
    }
    func testGroupingRetainsRankAndExpandsOnlyTheSelectedChat() {
        let input = [SemanticHit(passage: passage("a1", chat: "a"), score: 0.9),
                     SemanticHit(passage: passage("b1", chat: "b"), score: 0.8),
                     SemanticHit(passage: passage("a2", chat: "a"), score: 0.7),
                     SemanticHit(passage: passage("a3", chat: "a"), score: 0.6)]
        let groups = SemanticResultGroups.groups(input)
        XCTAssertEqual(groups.map { $0.map { $0.passage.id } }, [["a1", "a2", "a3"], ["b1"]])
        func visible(_ expanded: Set<String>) -> [String] {
            groups.flatMap { group in SemanticResultGroups.visible(group, expanded: expanded.contains(group[0].passage.chatID)) }.map { $0.passage.id }
        }
        XCTAssertEqual(visible([]), ["a1", "b1"])
        XCTAssertEqual(visible(["a"]), ["a1", "a2", "a3", "b1"])
        XCTAssertEqual(visible(["b"]), ["a1", "b1"])
        XCTAssertEqual(SemanticResultGroups.groups([]).count, 0)
    }
    func testToolSourcePresentationPreservesOriginalTextAndProvenance() {
        let source = passage("tool", chat: "chat-id", tool: true)
        let original = "{ \"text\": \"Original  bytes\n\" }"
        let rendered = SemanticSourcePresentation.render(source, result: .success(Data(original.utf8)))
        XCTAssertTrue(rendered.hasSuffix(original))
        for expected in ["chat-id", "item-tool", "turn-1", "42", "source-digest"] { XCTAssertTrue(rendered.contains(expected)) }
        XCTAssertFalse(rendered.contains(source.text))
        XCTAssertTrue(SemanticSourcePresentation.render(source, result: .success(Data([0xff]))).contains("not UTF-8"))
        XCTAssertTrue(SemanticSourcePresentation.render(source, result: .failure(SemanticFailure("Missing captured version"))).contains("UNAVAILABLE · Missing captured version"))
    }

}
