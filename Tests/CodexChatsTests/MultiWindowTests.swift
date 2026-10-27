import XCTest
import AppKit
@testable import CodexChats

final class MultiWindowTests:XCTestCase {
    private func fixture() -> ChatSnapshot {
        let project=ProjectReference(identity:.assigned(kind:"fixture",id:"p"),name:"Project",originalAssignment:nil,originalProject:nil)
        let chats=(0..<20).map{Chat(original:[:],id:"chat-\($0)",title:"Fixture \($0)",createdAt:Date(timeIntervalSince1970:10000-Double($0)),archived:false,issues:[],project:project)}
        let url=URL(fileURLWithPath:"/unavailable-multiwindow-fixture/state_5.sqlite")
        return ChatSnapshot(chats:chats,sourceURL:url,observedAt:Date(),excludedSubagents:0,projectSourceURL:url,projectSourceIssue:nil)
    }
    private func manager() -> ExplorerWindowCoordinator {
        _ = NSApplication.shared
        let manager=ExplorerWindowCoordinator(persist:false,activateWindows:false);manager.update(fixture())
        addTeardownBlock{manager.closeAllWindows()};return manager
    }
    func testTenExplorerViewsShareLibraryButNotNavigation() throws {
        let manager=manager(),first=manager.newExplorer(show:false)
        first.window.setFrame(NSRect(x:100,y:100,width:760,height:560),display:false)
        first.root.setPresentation(.project)
        for _ in 0..<9{manager.duplicateExplorer(first)}
        XCTAssertEqual(manager.explorers.count,10)
        XCTAssertEqual(Set(manager.explorers.values.map(\.root.windowInstanceID)).count,10)
        let roots=Array(manager.explorers.values.map(\.root))
        XCTAssertTrue(manager.explorers.values.allSatisfy{$0.window.frame.size==first.window.frame.size})
        XCTAssertTrue(roots.allSatisfy{$0.library === manager.library})
        XCTAssertTrue(roots.allSatisfy{$0.timeline.presentation == .project})
        let second=try XCTUnwrap(roots.first{$0 !== first.root});second.setPresentation(.date)
        XCTAssertEqual(first.root.timeline.presentation,.project)
        try first.root.library.toggleFavorite("chat-0");try second.library.toggleFavorite("chat-1")
        XCTAssertEqual(manager.library.state.favoriteChatIDs,["chat-0","chat-1"])
        XCTAssertEqual(manager.canvases.documents.count,1)
    }
    func testDuplicateCanvasIsSameDocumentWithIndependentViewportAndReaderState() throws {
        let manager=manager(),workspace=manager.workspace(manager.primaryCanvasID)
        workspace.set(["chat-0"],included:true)
        let first=try XCTUnwrap(workspace.newWindow(activate:false));first.layoutSubtreeIfNeeded()
        first.window?.setFrame(NSRect(x:100,y:100,width:850,height:620),display:false);first.layoutSubtreeIfNeeded()
        first.restoreViewport((NSPoint(x:12200,y:12500),1))
        let second=try XCTUnwrap(workspace.newWindow(copying:first,activate:false));second.layoutSubtreeIfNeeded()
        XCTAssertEqual(second.window?.frame.size,first.window?.frame.size)
        second.restoreViewport((NSPoint(x:12300,y:12800),0.9))
        let id=try XCTUnwrap(workspace.document.chats.first?.presentationID)
        var a=CanvasReaderState();a.y=40;var b=CanvasReaderState();b.y=80
        first.restoreChatReadingState(id,a);second.restoreChatReadingState(id,b)
        let firstViewport=first.viewportState,secondViewport=second.viewportState
        var moved=try XCTUnwrap(first.chatPlacement(id));moved.x += 70
        workspace.applyChatChanges([moved])
        XCTAssertEqual(manager.canvases.documents.count,1)
        XCTAssertEqual(first.canvasID,second.canvasID);XCTAssertNotEqual(first.canvasViewID,second.canvasViewID)
        XCTAssertEqual(first.chatPlacement(id)?.x,second.chatPlacement(id)?.x)
        XCTAssertEqual(first.viewportState.0,firstViewport.0);XCTAssertEqual(second.viewportState.0,secondViewport.0)
        XCTAssertEqual(first.chatReadingState(id)?.y,40);XCTAssertEqual(second.chatReadingState(id)?.y,80)
        workspace.rebase(dx:12288,dy:12288)
        XCTAssertEqual(first.viewportState.0.x,firstViewport.0.x+12288,accuracy:0.5)
        XCTAssertEqual(second.viewportState.0.y,secondViewport.0.y+12288,accuracy:0.5)
        XCTAssertEqual(first.chatPlacement(id)?.x,second.chatPlacement(id)?.x)
    }
    func testChatDuplicatesHaveDistinctPresentationIDsAndOneSourceChat() throws {
        let manager=manager()
        for _ in 0..<10{XCTAssertNotNil(manager.openChatWindow("chat-0"))}
        XCTAssertEqual(manager.chatWindows.count,10)
        XCTAssertEqual(Set(manager.chatWindows.values.map{$0.placement.presentationID}).count,10)
        XCTAssertEqual(Set(manager.chatWindows.values.map{$0.placement.id}),["chat-0"])
        let workspace=manager.workspace(manager.primaryCanvasID);workspace.set(["chat-0"],included:true)
        let canvas=try XCTUnwrap(workspace.newWindow(activate:false))
        let original=try XCTUnwrap(canvas.layoutSnapshot.first)
        workspace.duplicateChat(original.presentationID,from:canvas)
        XCTAssertEqual(workspace.document.chats.count,2)
        XCTAssertEqual(Set(workspace.document.chats.map(\.presentationID)).count,2)
        XCTAssertEqual(workspace.selected,["chat-0"])
        workspace.removeChat(original.presentationID)
        XCTAssertEqual(workspace.document.chats.count,1);XCTAssertEqual(workspace.selected,["chat-0"])
    }
    func testExplorerMirrorsMoveBetweenBoardsAndDetachWithoutDuplicates() throws {
        let manager=manager(),first=manager.newExplorer(show:false)
        let workspace=manager.workspace(manager.primaryCanvasID)
        let a=try XCTUnwrap(workspace.newWindow(activate:false));a.layoutSubtreeIfNeeded()
        manager.addExplorer(first,to:a,at:NSPoint(x:12312,y:12312))
        let panelID=try XCTUnwrap(first.location?.panelID)
        let b=try XCTUnwrap(workspace.newWindow(copying:a,activate:false));b.layoutSubtreeIfNeeded()
        let deadline=Date().addingTimeInterval(3)
        while manager.pendingExplorerViews>0 && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
        XCTAssertEqual(workspace.document.explorers.count,1)
        XCTAssertNotNil(a.explorerPanels[panelID]);XCTAssertNotNil(b.explorerPanels[panelID])
        XCTAssertFalse(a.explorerPanels[panelID]?.explorer === b.explorerPanels[panelID]?.explorer)
        first.root.setPresentation(.project)
        XCTAssertEqual(b.explorerPanels[panelID]?.explorer.timeline.presentation,.date)
        let newID=try XCTUnwrap(manager.canvases.createCanvas()),other=manager.workspace(newID)
        let target=try XCTUnwrap(other.newWindow(activate:false));target.layoutSubtreeIfNeeded()
        XCTAssertTrue(manager.moveExplorer(first,to:target,at:NSPoint(x:12340,y:12350)))
        XCTAssertTrue(workspace.document.explorers.isEmpty);XCTAssertEqual(other.document.explorers.count,1)
        XCTAssertNil(a.explorerPanels[panelID]);XCTAssertNil(b.explorerPanels[panelID])
        XCTAssertTrue(target.explorerPanels[panelID]?.explorer === first.root)
        XCTAssertEqual(first.root.timeline.presentation,.project)
        manager.detachExplorer(first,at:NSPoint(x:100,y:600))
        XCTAssertTrue(other.document.explorers.isEmpty);XCTAssertNil(first.location)
        XCTAssertTrue(first.window.contentView === first.root)
    }
    func testClosingCanvasViewPreservesBoardAndOtherView() throws {
        let manager=manager(),workspace=manager.workspace(manager.primaryCanvasID)
        workspace.set(["chat-0","chat-1"],included:true)
        let first=try XCTUnwrap(workspace.newWindow(activate:false)),second=try XCTUnwrap(workspace.newWindow(copying:first,activate:false))
        first.window?.close()
        XCTAssertEqual(workspace.canvasViews.count,1)
        XCTAssertTrue(workspace.canvasViews.first === second)
        XCTAssertEqual(workspace.document.chats.count,2)
        XCTAssertEqual(second.layoutSnapshot.count,2)
    }
    func testInvalidExplorerTransferLeavesOriginalWindowAndDocument() throws {
        let manager=manager(),controller=manager.newExplorer(show:false),workspace=manager.workspace(manager.primaryCanvasID)
        let canvas=try XCTUnwrap(workspace.newWindow(activate:false))
        XCTAssertFalse(manager.moveExplorer(controller,to:canvas,at:NSPoint(x:Double.infinity,y:10)))
        XCTAssertTrue(controller.window.contentView === controller.root)
        XCTAssertNil(controller.location);XCTAssertTrue(workspace.document.explorers.isEmpty)
    }
}
