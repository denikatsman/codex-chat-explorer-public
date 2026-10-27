import XCTest
import AppKit
@testable import CodexChats

final class CanvasExplorerTests: XCTestCase {
    private func snapshot() -> ChatSnapshot {
        let project=ProjectReference(identity:.assigned(kind:"fixture",id:"project"),name:"Fixture project",originalAssignment:nil,originalProject:nil)
        let chats=(0..<60).map { Chat(original:[:],id:"fixture-\($0)",title:"Fixture \($0)",createdAt:Date(timeIntervalSince1970:10000-Double($0)),archived:$0%2==0,issues:[],project:project) }
        let source=URL(fileURLWithPath:"/unavailable-canvas-explorer-fixture/state_5.sqlite")
        return ChatSnapshot(chats:chats,sourceURL:source,observedAt:Date(),excludedSubagents:0,projectSourceURL:source,projectSourceIssue:nil)
    }
    private func setup(activateWindows: Bool = false) throws -> (ChatRootView,ChatWindow,CanvasExplorerHost,ChatCanvasRoot) {
        _ = NSApplication.shared
        let root=ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
        let window=ChatWindow(contentSize:root.frame.size);window.contentView=root
        let host=CanvasExplorerHost(explorer:root,window:window,activateWindows:activateWindows)
        root.show(snapshot());root.setPresentation(.date);root.layoutSubtreeIfNeeded()
        host.workspace.set(["fixture-0","fixture-2"],included:true);host.workspace.open(activate:false)
        let canvas=try XCTUnwrap(host.workspace.root)
        addTeardownBlock { host.restore(showWindow:false);host.workspace.window?.close();window.contentView=nil;window.close() }
        return (root,window,host,canvas)
    }
    func testLiveViewFiltersScrollAndCardsSurviveRoundTrip() throws {
        let (root,window,host,canvas)=try setup()
        let library=root.library, cards=canvas.layoutSnapshot
        root.timeline.setDateArchiveFilter(.archived)
        root.timeline.setDateProjectScope(.project)
        root.layoutSubtreeIfNeeded();root.scroll.contentView.scroll(to:NSPoint(x:0,y:100))
        let before=root.scroll.contentView.bounds.origin
        let button=try XCTUnwrap(canvas.subviews.compactMap{$0 as? NSButton}.first{$0.title=="EXPLORER"})
        button.performClick(nil)
        let panel=try XCTUnwrap(canvas.explorerPanel)
        XCTAssertTrue(panel.explorer === root);XCTAssertTrue(root.library === library)
        XCTAssertTrue(root.window === canvas.window);XCTAssertNil(window.contentView)
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertEqual(root.timeline.dateArchiveFilter,.archived);XCTAssertEqual(root.timeline.dateProjectScope,.project)
        XCTAssertEqual(root.scroll.contentView.bounds.origin.y,before.y,accuracy:0.5)
        XCTAssertEqual(canvas.layoutSnapshot,cards)
        host.restore(showWindow:false)
        XCTAssertTrue(window.contentView === root);XCTAssertTrue(root.window === window)
        XCTAssertFalse(window.isExcludedFromWindowsMenu);XCTAssertNil(canvas.explorerPanel)
        XCTAssertEqual(root.scroll.contentView.bounds.origin.y,before.y,accuracy:0.5)
        XCTAssertEqual(canvas.layoutSnapshot,cards)
    }
    func testOnePanelRetainsAllViewsAndRoutesZoomByFocus() throws {
        let (root,_,host,canvas)=try setup();host.embed(in:canvas)
        let panel=try XCTUnwrap(canvas.explorerPanel)
        for presentation in [ChatPresentation.date,.project,.timeline,.columns,.lanes,.active] {
            root.setPresentation(presentation);root.layoutSubtreeIfNeeded()
            XCTAssertEqual(root.timeline.presentation,presentation)
            XCTAssertTrue(panel.explorer === root)
        }
        host.embed(in:canvas);XCTAssertTrue(canvas.explorerPanel === panel)
        let before=root.textMagnification
        canvas.adjustCanvasZoom(0.15);XCTAssertGreaterThan(root.textMagnification,before)
        let changed=root.textMagnification
        canvas.noteMouseDown(NSPoint(x:-500,y:-500));canvas.adjustCanvasZoom(-0.15)
        XCTAssertEqual(root.textMagnification,changed)
        host.restore(showWindow:false)
        XCTAssertEqual(root.timeline.presentation,.active)
    }
    func testCollapseResizeAndCanvasCloseRestoreTheLiveView() throws {
        let (root,window,host,canvas)=try setup();host.embed(in:canvas)
        let panel=try XCTUnwrap(canvas.explorerPanel)
        panel.resize(to:NSSize(width:760,height:520));panel.move(to:NSPoint(x:13000,y:12800))
        XCTAssertEqual(panel.frame.size,NSSize(width:760,height:520))
        root.minimizeWindow();XCTAssertTrue(panel.isCollapsed);XCTAssertTrue(root.isHidden)
        XCTAssertGreaterThan(root.frame.height,0)
        canvas.revealExplorer();XCTAssertFalse(panel.isCollapsed);XCTAssertFalse(root.isHidden)
        XCTAssertEqual(panel.frame.size,NSSize(width:760,height:520))
        panel.resize(to:NSSize(width:0,height:-10));XCTAssertEqual(panel.frame.size,CanvasExplorerPanel.explorerMinimumSize)
        let valid=panel.frame;panel.move(to:NSPoint(x:CGFloat.nan,y:0));panel.resize(to:NSSize(width:CGFloat.infinity,height:0))
        XCTAssertEqual(panel.frame,valid)
        host.workspace.window?.close()
        XCTAssertTrue(window.contentView === root);XCTAssertNil(root.canvasExplorerPanel);XCTAssertNil(canvas.explorerPanel)
    }
    func testNewChatCardsDoNotCoverTheEmbeddedExplorer() throws {
        let (root,_,host,canvas)=try setup();host.embed(in:canvas)
        let panel=try XCTUnwrap(canvas.explorerPanel)
        host.workspace.set(["fixture-4"],included:true)
        XCTAssertTrue(panel.superview?.subviews.last === panel)
        XCTAssertEqual(canvas.layoutSnapshot.count,3)
        let restore=root.hostingStateRestoration()
        root.scroll.contentView.scroll(to:NSPoint(x:0,y:200))
        restore();XCTAssertEqual(root.scroll.contentView.bounds.origin.y,0,accuracy:0.5)
    }

    func testHostReleaseBreaksCanvasOwnershipCycle() throws {
        _ = NSApplication.shared
        weak var weakRoot:ChatRootView?, weakPanel:CanvasExplorerPanel?
        autoreleasepool {
            var root:ChatRootView?=ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
            let window=ChatWindow(contentSize:root!.frame.size);window.contentView=root
            var host:CanvasExplorerHost?=CanvasExplorerHost(explorer:root!,window:window,activateWindows:false)
            root!.show(snapshot());host!.workspace.open(activate:false)
            let workspace=host!.workspace
            host!.embed(in:workspace.root!);weakRoot=root;weakPanel=workspace.root!.explorerPanel
            host=nil
            XCTAssertNil(workspace.root!.explorerPanel);XCTAssertTrue(window.contentView === root)
            workspace.window?.close();window.contentView=nil;window.close();root=nil
        }
        XCTAssertNil(weakPanel);XCTAssertNil(weakRoot)
    }
    func testExplicitRevealExpandsAnInitiallyHiddenPanel() throws {
        let (root, _, host, canvas) = try setup()
        let placement = ExplorerPanelPlacement(id: "hidden", x: 12312, y: 12312, width: 942, height: 700, collapsed: true)
        host.embed(in: canvas, placement: placement, reveal: false)
        XCTAssertTrue(try XCTUnwrap(root.canvasExplorerPanel).isCollapsed)
        host.reveal()
        XCTAssertFalse(try XCTUnwrap(root.canvasExplorerPanel).isCollapsed)
    }

    func testPanelDismissKeepsTheNativeViewHiddenUntilCanvasCloses() throws {
        let (root, window, host, canvas) = try setup(activateWindows: true)
        window.orderFront(nil)
        host.embed(in: canvas)
        host.restore(showWindow: true)
        host.embed(in: canvas)
        host.workspace.window?.close()
        host.workspace.open()
        let reopened = try XCTUnwrap(host.workspace.root)
        host.embed(in: reopened)
        try XCTUnwrap(reopened.explorerPanel).dismiss()
        XCTAssertTrue(window.contentView === root)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(host.isEmbedded)
        XCTAssertNil(reopened.explorerPanel)
        host.workspace.window?.close()
        XCTAssertTrue(window.isVisible)
    }

    func testFailedDuplicatePanelIDKeepsTheExistingPresentation() throws {
        let (root, _, host, canvas) = try setup()
        let placement = ExplorerPanelPlacement(id: "shared-id", x: 12312, y: 12312, width: 942, height: 700)
        host.embed(in: canvas, placement: placement, reveal: false)
        let original = try XCTUnwrap(root.canvasExplorerPanel)
        let second = ChatRootView(frame: root.frame, persistTheme: false, loadOnDemand: false)
        let secondWindow = ChatWindow(contentSize: second.frame.size); secondWindow.contentView = second
        let secondHost = CanvasExplorerHost(explorer: second, window: secondWindow, activateWindows: false)
        defer { secondHost.restore(showWindow: false); secondWindow.contentView = nil; secondWindow.close() }
        var result: Bool?
        secondHost.embed(in: canvas, placement: placement, reveal: false) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertTrue(canvas.explorerPanels[placement.id] === original)
        XCTAssertTrue(root.canvasExplorerPanel === original)
        XCTAssertTrue(secondWindow.contentView === second)
        XCTAssertNil(second.canvasExplorerPanel)
    }

}
