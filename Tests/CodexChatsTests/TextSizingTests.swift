import XCTest
import AppKit
@testable import CodexChats

final class TextSizingTests: XCTestCase {
    func testRestorationAndBoundsDoNotAcceptNonFiniteValues() throws {
        let name = "explorer-text-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TextSizing.restored(from: defaults), 1)
        defaults.set(1.6, forKey: TextSizing.preferenceKey)
        XCTAssertEqual(TextSizing.restored(from: defaults), 1.6)
        XCTAssertEqual(TextSizing.clamp(.infinity), 1)
        XCTAssertEqual(TextSizing.clamp(.nan), 1)
        XCTAssertEqual(TextSizing.clamp(-100), 0.75)
        XCTAssertEqual(TextSizing.clamp(100), 2.5)
    }
    func testLargeContentZoomStacksDateMetadataInsteadOfHidingTitles() throws {
        _ = NSApplication.shared
        let project = ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil)
        let chat = Chat(original: ["archived": .integer(1)], id: "fixture", title: "An archived exploration remains readable", createdAt: Date(timeIntervalSince1970: 100), archived: true, issues: [], project: project)
        let source = URL(fileURLWithPath: "/fixture")
        let snapshot = ChatSnapshot(chats: [chat], sourceURL: source, observedAt: Date(), excludedSubagents: 0, projectSourceURL: source, projectSourceIssue: nil)
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 600, height: 650), persistTheme: false, loadOnDemand: false)
        root.show(snapshot); root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        let baseline = try XCTUnwrap(root.timeline.entries.first(where: { $0.chat != nil })?.height)
        XCTAssertGreaterThanOrEqual(baseline, 42)
        root.adjustTextSize(by: 2.5)
        XCTAssertLessThan(root.timeline.frame.width, 520)
        let zoomed = try XCTUnwrap(root.timeline.entries.first(where: { $0.chat != nil })?.height)
        XCTAssertGreaterThan(zoomed, baseline)
        root.resetTextSize()
        XCTAssertEqual(root.timeline.entries.first(where: { $0.chat != nil })?.height, baseline)
    }

    func testContentZoomKeepsToolbarAndDocumentsWithinTheirLogicalViewport() {
        _ = NSApplication.shared
        let root = ChatRootView(frame: NSRect(x: 0, y: 0, width: 940, height: 650), persistTheme: false, loadOnDemand: false)
        root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        let date = root.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel()?.hasPrefix("Date view") == true }!
        let toolbar = date.frame
        for _ in 0..<20 { root.adjustTextSize(by: TextSizing.step) }
        XCTAssertEqual(root.textMagnification, 2.5)
        XCTAssertEqual(root.scroll.magnification, 2.5)
        XCTAssertEqual(root.lanePanel.scroll.magnification, 2.5)
        XCTAssertEqual(root.timeline.frame.width, root.scroll.contentView.bounds.width, accuracy: 1)
        XCTAssertEqual(date.frame, toolbar)
        root.setPresentation(.project)
        XCTAssertEqual(root.scroll.magnification, 2.5)
        root.setPresentation(.columns)
        XCTAssertEqual(root.scroll.magnification, 2.5)
        root.setPresentation(.lanes)
        XCTAssertEqual(root.lanePanel.scroll.magnification, 2.5)
        for _ in 0..<40 { root.adjustTextSize(by: 1 / TextSizing.step) }
        XCTAssertEqual(root.textMagnification, 0.75)
        root.resetTextSize()
        XCTAssertEqual(root.scroll.magnification, 1)
        XCTAssertEqual(root.lanePanel.scroll.magnification, 1)
    }
}
