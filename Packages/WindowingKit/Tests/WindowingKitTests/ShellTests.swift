import AppKit
import XCTest
@testable import WindowingKit

final class ShellTests: XCTestCase {
    func testFullscreenCleanupPreservesConfiguredNativeFrameStyle() {
        let borderless = WorkspaceWindow(contentSize: NSSize(width: 400, height: 300))
        borderless.styleMask.insert(.titled)
        borderless.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: borderless))
        XCTAssertFalse(borderless.styleMask.contains(.titled))
        let native = WorkspaceWindow(contentSize: NSSize(width: 400, height: 300), style: [.titled, .closable, .resizable], hideNativeControls: false)
        native.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: native))
        XCTAssertTrue(native.styleMask.contains(.titled))
        native.windowDidFailToEnterFullScreen(native)
        XCTAssertTrue(native.styleMask.contains(.titled))
    }
    func testPanelRestoresExpandedGeometryAndRejectsInvalidSharedFrame() {
        let panel = ContentPanel(content: WindowContent(view: NSView()), frame: NSRect(x: 12, y: 20, width: 400, height: 260), id: "one", title: "Example", minimumSize: NSSize(width: 200, height: 150))
        panel.setCollapsed(true)
        XCTAssertEqual(panel.frame.height, 34)
        XCTAssertEqual(panel.expandedFrame, NSRect(x: 12, y: 20, width: 400, height: 260))
        panel.applyShared(frame: NSRect(x: -2, y: 0, width: 500, height: 300), collapsed: false)
        XCTAssertTrue(panel.isCollapsed)
        panel.setCollapsed(false)
        XCTAssertEqual(panel.frame, NSRect(x: 12, y: 20, width: 400, height: 260))
    }
    func testHostRestoresViewAndNativeStateAndCompletesOnce() {
        let window = WorkspaceWindow(contentSize: NSSize(width: 400, height: 300))
        let view = NSView(); view.autoresizingMask = [.width, .height]; window.contentView = view
        window.isExcludedFromWindowsMenu = false
        let destination = NSView(); var removed = 0; var results: [Bool] = []
        let host = ContentHost(content: WindowContent(view: view), window: window, activateWindows: false)
        host.embed(isAvailable: { true }, install: { destination.addSubview(view); return true }, remove: { removed += 1 }, reveal: {}, destinationWindow: { nil }) { results.append($0) }
        XCTAssertEqual(results, [true]); XCTAssertTrue(host.isEmbedded); XCTAssertTrue(window.isExcludedFromWindowsMenu)
        host.restore(showWindow: false); host.restore(showWindow: false)
        XCTAssertTrue(window.contentView === view); XCTAssertEqual(view.autoresizingMask, [.width, .height])
        XCTAssertFalse(window.isExcludedFromWindowsMenu); XCTAssertEqual(removed, 1); XCTAssertEqual(results, [true])
    }
    func testFailedInstallRestoresOriginalContent() {
        let window = WorkspaceWindow(contentSize: NSSize(width: 400, height: 300))
        let view = NSView(); window.contentView = view; var result: Bool?
        let host = ContentHost(content: WindowContent(view: view), window: window, activateWindows: false)
        host.embed(isAvailable: { true }, install: { false }, remove: {}, reveal: {}, destinationWindow: { nil }) { result = $0 }
        XCTAssertEqual(result, false); XCTAssertFalse(host.isEmbedded); XCTAssertTrue(window.contentView === view)
    }
}

private final class ObservedWindow: WorkspaceWindow {
    var orderedOutCount = 0
    var madeKeyCount = 0
    override func orderOut(_ sender: Any?) { orderedOutCount += 1; super.orderOut(sender) }
    override func makeKeyAndOrderFront(_ sender: Any?) { madeKeyCount += 1 }
}

extension ShellTests {
    func testHiddenRestoreOverridesVisibilityChangesFromContentPreservation() {
        let source = WorkspaceWindow(contentSize: NSSize(width: 400, height: 300))
        let view = NSView(); source.contentView = view
        let destination = NSView(); var exposeSource = false
        let content = WindowContent(view: view, preservePresentation: { body in
            body()
            if exposeSource { source.orderFront(nil) }
        })
        let host = ContentHost(content: content, window: source, activateWindows: true)
        defer { source.close() }
        host.embed(isAvailable: { true }, install: { destination.addSubview(view); return true }, remove: {}, reveal: {}, destinationWindow: { nil })
        exposeSource = true
        host.restore(showWindow: false)
        XCTAssertTrue(source.contentView === view)
        XCTAssertFalse(source.isVisible)
        XCTAssertFalse(host.isEmbedded)
    }
    func testExplicitRevealActivatesEvenWhenAutomaticActivationIsDisabled() {
        let source = ObservedWindow(contentSize: NSSize(width: 400, height: 300))
        let target = ObservedWindow(contentSize: NSSize(width: 400, height: 300))
        let view = NSView(); source.contentView = view; let destination = NSView()
        let host = ContentHost(content: WindowContent(view: view), window: source, activateWindows: false)
        var reveals = 0
        host.embed(isAvailable: { true }, install: { destination.addSubview(view); return true }, remove: {}, reveal: { reveals += 1 }, destinationWindow: { target })
        XCTAssertEqual(target.madeKeyCount, 0)
        host.reveal()
        XCTAssertEqual(reveals, 1); XCTAssertEqual(target.madeKeyCount, 1)
        host.restore(showWindow: false)
        host.reveal()
        XCTAssertEqual(source.madeKeyCount, 1)
    }
    func testCancellationDuringInstallRollsBackOnceWithoutHidingSource() {
        let source = ObservedWindow(contentSize: NSSize(width: 400, height: 300))
        let view = NSView(); view.autoresizingMask = [.width, .height]; source.contentView = view
        let destination = NSView(); let host = ContentHost(content: WindowContent(view: view), window: source, activateWindows: false)
        var results: [Bool] = []; var removals = 0
        host.embed(isAvailable: { true }, install: {
            destination.addSubview(view); host.restore(showWindow: false); return true
        }, remove: { removals += 1 }, reveal: {}, destinationWindow: { nil }) { results.append($0) }
        XCTAssertEqual(results, [false]); XCTAssertEqual(removals, 1); XCTAssertEqual(source.orderedOutCount, 0)
        XCTAssertTrue(source.contentView === view); XCTAssertFalse(host.isEmbedded); XCTAssertFalse(source.isExcludedFromWindowsMenu)
        XCTAssertEqual(view.autoresizingMask, [.width, .height])
    }
    func testCancellationAfterPreservationBodyAlsoRollsBack() {
        let source = ObservedWindow(contentSize: NSSize(width: 400, height: 300))
        let view = NSView(); source.contentView = view; let destination = NSView()
        var host: ContentHost!; var first = true; var results: [Bool] = []; var removals = 0
        let content = WindowContent(view: view, preservePresentation: { body in
            body()
            if first { first = false; host.restore(showWindow: false) }
        })
        host = ContentHost(content: content, window: source, activateWindows: false)
        host.embed(isAvailable: { true }, install: { destination.addSubview(view); return true }, remove: { removals += 1 }, reveal: {}, destinationWindow: { nil }) { results.append($0) }
        XCTAssertEqual(results, [false]); XCTAssertEqual(removals, 1); XCTAssertEqual(source.orderedOutCount, 0)
        XCTAssertTrue(source.contentView === view); XCTAssertFalse(host.isEmbedded)
    }
    func testNestedEmbedDuringPreservationIsRejectedWithoutDisplacingOuterTransfer() {
        let source = ObservedWindow(contentSize: NSSize(width: 400, height: 300))
        let view = NSView(); source.contentView = view; let destination = NSView()
        var host: ContentHost!; var nested: [Bool] = []; var outer: [Bool] = []; var attempted = false
        let content = WindowContent(view: view, preservePresentation: { body in
            if !attempted {
                attempted = true
                host.embed(isAvailable: { true }, install: { XCTFail("Nested install must not run"); return true }, remove: {}, reveal: {}, destinationWindow: { nil }) { nested.append($0) }
            }
            body()
        })
        host = ContentHost(content: content, window: source, activateWindows: false)
        host.embed(isAvailable: { true }, install: { destination.addSubview(view); return true }, remove: {}, reveal: {}, destinationWindow: { nil }) { outer.append($0) }
        XCTAssertEqual(nested, [false]); XCTAssertEqual(outer, [true]); XCTAssertTrue(host.isEmbedded)
        XCTAssertTrue(view.superview === destination)
    }
}
