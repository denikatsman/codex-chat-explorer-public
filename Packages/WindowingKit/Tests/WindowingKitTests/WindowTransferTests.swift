import XCTest
import AppKit
@testable import WindowingKit

final class WindowTransferTests: XCTestCase {
    func testPayloadIsSmallAndBindsKindPresentationProcessSessionAndAttempt() throws {
        let source = WindowTransferSource(kind: .explorer, presentationID: "explorer-instance")
        let data = try XCTUnwrap(source.payload.data)
        let payload = try XCTUnwrap(WindowTransferPayload.read(data))
        XCTAssertEqual(payload, source.payload)
        XCTAssertLessThan(data.count, 512)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(original.keys), ["version", "kind", "presentationID", "transferID", "processID", "session"])
        // The reusable transport accepts host-defined kinds; source/process/session
        // validation still binds each reference to its actual drag operation.
        var custom = original; custom["kind"] = "canvas"
        XCTAssertEqual(WindowTransferPayload.read(try JSONSerialization.data(withJSONObject: custom))?.kind.rawValue, "canvas")
        for (key, value) in [("version", 2 as Any),
                             ("presentationID", "" as Any), ("presentationID", String(repeating: "x", count: 513) as Any),
                             ("processID", -1 as Any), ("session", UUID().uuidString as Any),
                             ("transferID", "not-a-uuid" as Any)] {
            var modified = original
            modified[key] = value
            XCTAssertNil(WindowTransferPayload.read(try JSONSerialization.data(withJSONObject: modified)), key)
        }
        XCTAssertNil(WindowTransferPayload.read(nil))
        XCTAssertNil(WindowTransferPayload.read(Data("partial {".utf8)))
        XCTAssertNil(WindowTransferPayload.read(Data(repeating: 0, count: 4097)))
    }

    func testReceiverRequiresExactNativeSourceAndFreshDragAttempt() throws {
        let source = WindowTransferSource(kind: .chat, presentationID: "chat-instance")
        let info = FixtureWindowDraggingInfo(source: source)
        XCTAssertEqual(WindowTransferPayload.read(info), source.payload)
        let nextAttempt = WindowTransferSource(kind: .chat, presentationID: source.presentationID)
        XCTAssertNotEqual(source.payload.transferID, nextAttempt.payload.transferID)
        info.draggingPasteboard.setData(nextAttempt.payload.data, forType: WindowTransferPayload.type)
        XCTAssertNil(WindowTransferPayload.read(info))
        for alternate in [WindowTransferSource(kind: .chat, presentationID: "another-instance"),
                          WindowTransferSource(kind: .explorer, presentationID: source.presentationID)] {
            info.draggingPasteboard.setData(alternate.payload.data, forType: WindowTransferPayload.type)
            XCTAssertNil(WindowTransferPayload.read(info))
        }
        info.draggingPasteboard.setData(source.payload.data, forType: WindowTransferPayload.type)
        info.operationMask = .copy
        XCTAssertNil(WindowTransferPayload.read(info))
        info.operationMask = .move
        info.draggingSource = NSObject()
        XCTAssertNil(WindowTransferPayload.read(info))
    }

    func testDestinationCommitsBeforeSourceCleanupAndCompletesExactlyOnce() {
        let source = WindowTransferSource(kind: .explorer, presentationID: "explorer-instance")
        let point = NSPoint(x: 120, y: 340)
        var events: [String] = []
        source.onAccepted = { destination in
            XCTAssertEqual(destination, WindowTransferDestination(canvasID: "canvas-b", point: point))
            events.append("source-cleanup")
            source.complete(operation: .move, mouseReleased: true)
        }
        source.onCancelled = { XCTFail("Committed transfer must not cancel") }
        source.onDesktopDrop = { _ in XCTFail("Committed transfer must not fall back") }
        source.onFinished = { value in XCTAssertTrue(value === source); events.append("finished") }
        XCTAssertTrue(source.accept(canvasID: "canvas-b", at: point) {
            events.append("destination-installed")
            XCTAssertFalse(source.accept(canvasID: "reentrant", at: .zero) { XCTFail(); return true })
            return true
        })
        XCTAssertEqual(events, ["destination-installed"])
        XCTAssertFalse(source.accept(canvasID: "duplicate", at: .zero) { XCTFail(); return true })
        source.markCancelled()
        source.complete(operation: [], mouseReleased: true)
        source.complete(operation: .move, mouseReleased: true)
        XCTAssertEqual(events, ["destination-installed", "source-cleanup", "finished"])
        XCTAssertNil(WindowTransferPayload.read(FixtureWindowDraggingInfo(source: source)))
    }

    func testFailedDestinationLeavesSourceAvailableForAnotherReceiver() {
        let source = WindowTransferSource(kind: .chat, presentationID: "chat-instance")
        XCTAssertFalse(source.accept(canvasID: "unavailable", at: .zero) { false })
        XCTAssertTrue(source.canAccept)
        XCTAssertTrue(source.accept(canvasID: "available", at: .zero) { true })
        XCTAssertFalse(source.canAccept)
    }

    func testInvalidDestinationNeverInvokesTransfer() {
        let source = WindowTransferSource(kind: .chat, presentationID: "chat-instance")
        for (canvasID, point) in [("", NSPoint.zero), (String(repeating: "x", count: 513), .zero),
                                  ("canvas", NSPoint(x: CGFloat.nan, y: 0)),
                                  ("canvas", NSPoint(x: 0, y: CGFloat.infinity))] {
            XCTAssertFalse(source.accept(canvasID: canvasID, at: point) { XCTFail(); return true })
        }
        XCTAssertTrue(source.canAccept)
    }

    func testCancellationRejectsReceiversAndDesktopFallbackExactlyOnce() {
        let source = WindowTransferSource(kind: .chat, presentationID: "chat-instance")
        var events: [String] = []
        source.shouldDropOnDesktop = { _ in XCTFail("Cancelled drag must not consult fallback"); return true }
        source.onCancelled = { events.append("cancelled") }
        source.onDesktopDrop = { _ in XCTFail() }
        source.onAccepted = { _ in XCTFail() }
        source.onFinished = { _ in events.append("finished") }
        source.markCancelled()
        XCTAssertNil(WindowTransferPayload.read(FixtureWindowDraggingInfo(source: source)))
        XCTAssertFalse(source.accept(canvasID: "canvas", at: .zero) { XCTFail(); return true })
        source.complete(operation: [], mouseReleased: true)
        source.complete(operation: [], mouseReleased: true)
        XCTAssertEqual(events, ["cancelled", "finished"])
    }

    func testDesktopFallbackUsesOwnerScreenPointPolicy() {
        let source = WindowTransferSource(kind: .explorer, presentationID: "explorer-instance")
        let point = NSPoint(x: -800, y: 600)
        var events: [String] = []
        source.shouldDropOnDesktop = { received in XCTAssertEqual(received, point); return true }
        source.onDesktopDrop = { received in XCTAssertEqual(received, point); events.append("desktop") }
        source.onCancelled = { XCTFail() }
        source.onFinished = { _ in events.append("finished") }
        source.complete(operation: [], mouseReleased: true, at: point)
        source.complete(operation: [], mouseReleased: true, at: point)
        XCTAssertEqual(events, ["desktop", "finished"])
    }

    func testUnacceptedOperationHeldMouseInvalidPointAndRejectedPolicyCancel() {
        for (operation, released, point, allow) in [(NSDragOperation.move, true, NSPoint.zero, true),
                                                  ([], false, .zero, true),
                                                  ([], true, NSPoint(x: CGFloat.nan, y: 0), true),
                                                  ([], true, .zero, false)] {
            let source = WindowTransferSource(kind: .chat, presentationID: "chat-instance")
            var cancelled = 0, finished = 0
            source.shouldDropOnDesktop = { _ in allow }
            source.onDesktopDrop = { _ in XCTFail() }
            source.onCancelled = { cancelled += 1 }
            source.onFinished = { _ in finished += 1 }
            source.complete(operation: operation, mouseReleased: released, at: point)
            XCTAssertEqual(cancelled, 1)
            XCTAssertEqual(finished, 1)
        }
    }
}

private final class FixtureWindowDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var operationMask: NSDragOperation = .move
    var draggingSourceOperationMask: NSDragOperation { operationMask }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("window-transfer-test-" + UUID().uuidString))
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(source: WindowTransferSource) {
        draggingSource = source
        super.init()
        draggingPasteboard.setData(source.payload.data, forType: WindowTransferPayload.type)
    }
    deinit { draggingPasteboard.releaseGlobally() }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() { }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
}
