import AppKit
import XCTest
@testable import CodexChats

final class ActiveChatControlsTests: XCTestCase {
    private func row(_ id: String, state: String = "working", host: String = "local", confirmed: Double? = 1) -> ActiveChatRow {
        ActiveChatRow(id: id, host: host, title: id, state: state, confirmedAt: confirmed)
    }
    private func snapshot(_ rows: [ActiveChatRow], connected: Bool = true) -> ActiveSnapshot {
        ActiveSnapshot(connected: connected, sequence: 1, observedAt: 1, rows: rows, pending: 0, warning: "", queryMs: 0, bytesReceived: 0)
    }
    func testPinnedSectionOnlyContainsConfirmedActiveSnapshotRows() {
        let rows = [row("a"), row("b", state: "waiting"), row("c", state: "unknown"), row("d", confirmed: nil), row("e", host: "remote")]
        let layout = ActiveRowLayout(snapshot: snapshot(rows), pinnedIDs: ["b", "c", "d", "e", "missing"])
        XCTAssertEqual(layout.entries.map(\.row.id), ["b", "a", "c", "d", "e"])
        XCTAssertEqual(layout.entries.filter(\.pinned).map(\.row.id), ["b"])
        XCTAssertNotNil(layout.pinnedHeadingY)
        XCTAssertNotNil(layout.otherHeadingY)
        let disconnected = ActiveRowLayout(snapshot: snapshot(rows, connected: false), pinnedIDs: ["a", "b"])
        XCTAssertEqual(disconnected.entries.map(\.row.id), rows.map(\.id))
        XCTAssertNil(disconnected.pinnedHeadingY)
    }
    func testStableIdentityAndNoDuplicatesAcrossPinChanges() {
        let rows = [row("a"), row("b"), row("a"), row("c")]
        let original = ActiveRowLayout(snapshot: snapshot(rows), pinnedIDs: [])
        let pinned = ActiveRowLayout(snapshot: snapshot(rows), pinnedIDs: ["c", "a"])
        XCTAssertEqual(original.entries.map(\.row.id), ["a", "b", "c"])
        XCTAssertEqual(pinned.entries.map(\.row.id), ["a", "c", "b"])
        XCTAssertEqual(Set(original.entries.map(\.row.id)), Set(pinned.entries.map(\.row.id)))
        XCTAssertTrue(zip(pinned.entries, pinned.entries.dropFirst()).allSatisfy { pair in pair.0.y < pair.1.y })
    }
    func testOnlyConfirmedConnectedLocalWorkingRowsAnimate() {
        XCTAssertTrue(ActiveRowLayout.showsWorking(row("a"), connected: true))
        XCTAssertFalse(ActiveRowLayout.showsWorking(row("a"), connected: false))
        XCTAssertFalse(ActiveRowLayout.showsWorking(row("a", state: "waiting"), connected: true))
        XCTAssertFalse(ActiveRowLayout.showsWorking(row("a", state: "unknown"), connected: true))
        XCTAssertFalse(ActiveRowLayout.showsWorking(row("a", confirmed: nil), connected: true))
        XCTAssertFalse(ActiveRowLayout.showsWorking(row("a", host: "remote"), connected: true))
    }
    func testConfirmedCountOnlyCountsUniqueCurrentlyConfirmedLocalActiveChats() {
        let rows = [row("a"), row("a"), row("b", state: "waiting"), row("c", state: "unknown"),
                    row("d", confirmed: nil), row("e", host: "remote"), row("f", state: "idle")]
        XCTAssertEqual(snapshot(rows).confirmedCount, 2)
        XCTAssertEqual(snapshot(rows, connected: false).confirmedCount, 0)
    }
    func testControlHitRegionsRemainDistinctAtNarrowAndWideWidths() {
        let entry = ActiveRowLayout(snapshot: snapshot([row("a")]), pinnedIDs: []).entries[0]
        for width: CGFloat in [240, 500, 900] {
            let controls = ActiveRowLayout.controlRects(entry, width: width)
            func center(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
            XCTAssertEqual(ActiveRowLayout.hit(center(controls.pin), entry: entry, width: width), .pin)
            XCTAssertEqual(ActiveRowLayout.hit(center(controls.tag), entry: entry, width: width), .tag)
            XCTAssertEqual(ActiveRowLayout.hit(center(controls.summary), entry: entry, width: width), .summary)
            let text = ActiveRowLayout.textRects(entry, width: width)
            let state = text.status, title = text.title, metadata = text.metadata
            for control in [controls.pin, controls.tag, controls.summary] {
                XCTAssertFalse(control.intersects(state)); XCTAssertFalse(control.intersects(title)); XCTAssertFalse(control.intersects(metadata))
                XCTAssertLessThanOrEqual(control.maxY, entry.y + ActiveRowLayout.rowHeight)
            }
            XCTAssertEqual(ActiveRowLayout.hit(NSPoint(x: 30, y: entry.y + 40), entry: entry, width: width), .row)
            XCTAssertEqual(ActiveRowLayout.hit(NSPoint(x: 30, y: entry.y - 1), entry: entry, width: width), .none)
        }
    }
    func testPinnedUnknownRowExplainsItsUnconfirmedStatus() {
        let view = ActiveChatsView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        var state = ExplorerLibraryState(); state.pinnedChatIDs.insert("a")
        view.setAnnotations(state)
        view.show(snapshot([row("a", state: "unknown")]))
        let elements = view.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        XCTAssertEqual(elements.count, 4)
        XCTAssertTrue(elements[1].accessibilityLabel()?.contains("Pinned in DATE; activity unconfirmed") == true)
    }
    func testInvisibleViewDoesNotCreateIndicatorsAndAccessibleControlsAddressCorrectID() {
        let view = ActiveChatsView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        var pinned: String?, summarized: String?
        view.onTogglePinned = { pinned = $0 }
        view.onSummarize = { id, provider in if provider == .local { summarized = id } }
        view.show(snapshot([row("a")]))
        XCTAssertFalse(view.subviews.contains { $0 is DateWorkingIndicator })
        let elements = view.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        XCTAssertEqual(elements.count, 4)
        XCTAssertTrue(elements[1].accessibilityPerformPress())
        XCTAssertEqual(pinned, "a")
        XCTAssertTrue(elements[3].accessibilityPerformPress())
        XCTAssertEqual(summarized, "a")
        view.show(snapshot([row("a", state: "waiting")]))
        XCTAssertFalse(view.subviews.contains { $0 is DateWorkingIndicator })
    }
}
