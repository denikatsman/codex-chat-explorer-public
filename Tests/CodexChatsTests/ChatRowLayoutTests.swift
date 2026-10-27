import AppKit
import XCTest
@testable import CodexChats

final class ChatRowLayoutTests: XCTestCase {
    func testWideActiveTextAndActionsShareTheRowCenter() {
        let row = ActiveChatRow(id: "fixture", host: "local", title: "Example", state: "working", confirmedAt: 1)
        let snapshot = ActiveSnapshot(connected: true, sequence: 1, observedAt: 1, rows: [row], pending: 0, warning: "", queryMs: 0, bytesReceived: 0)
        let entry = ActiveRowLayout(snapshot: snapshot, pinnedIDs: []).entries[0]
        for width: CGFloat in [640, 940, 1420] {
            let text = ActiveRowLayout.textRects(entry, width: width)
            let controls = ActiveRowLayout.controlRects(entry, width: width)
            let middle = entry.y + ActiveRowLayout.rowHeight / 2
            XCTAssertEqual(text.title.union(text.metadata).midY, middle, accuracy: 0.01)
            for rect in [text.status, controls.pin, controls.tag, controls.summary] {
                XCTAssertEqual(rect.midY, middle, accuracy: 0.01)
            }
            XCTAssertLessThan(text.title.maxX, controls.pin.minX)
            XCTAssertFalse(controls.summary.intersects(text.metadata))
        }
    }
    func testNarrowActiveContentGroupIsCenteredWithoutOverlaps() {
        let row = ActiveChatRow(id: "fixture", host: "local", title: "Example", state: "working", confirmedAt: 1)
        let snapshot = ActiveSnapshot(connected: true, sequence: 1, observedAt: 1, rows: [row], pending: 0, warning: "", queryMs: 0, bytesReceived: 0)
        let entry = ActiveRowLayout(snapshot: snapshot, pinnedIDs: []).entries[0]
        for width: CGFloat in [240, 440, 600] {
            let text = ActiveRowLayout.textRects(entry, width: width)
            let controls = ActiveRowLayout.controlRects(entry, width: width)
            let group = text.status.union(text.title).union(text.metadata).union(controls.summary)
            XCTAssertEqual(group.midY, entry.y + ActiveRowLayout.rowHeight / 2, accuracy: 0.01)
            XCTAssertFalse(text.title.intersects(text.metadata))
            XCTAssertFalse(text.metadata.intersects(controls.summary))
        }
    }
}
