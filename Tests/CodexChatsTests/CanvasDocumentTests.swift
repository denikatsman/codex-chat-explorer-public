import XCTest
import AppKit
@testable import CodexChats

final class CanvasDocumentTests: XCTestCase {
    private let primary=CanvasDocumentStore.primaryID
    private func chat(_ instance:String="instance-a",readY:Double?=nil)->CanvasPlacement {
        CanvasPlacement(id:"recorded-chat",x:120,y:150,width:448,height:520,expanded:true,readY:readY,instanceID:instance)
    }
    private func panel(_ id:String="explorer-a")->ExplorerPanelPlacement {
        ExplorerPanelPlacement(id:id,x:160,y:180,width:700,height:560)
    }
    private func temporaryDirectory() throws -> URL {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-document-tests-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
        return directory
    }
    private struct FixtureFile:Codable {var version=1;var documents:[CanvasDocument]}

    func testMalformedExistingFileIsPreservedAndCannotBeOverwrittenByFallback() throws {
        let file=try temporaryDirectory().appendingPathComponent("boards.json")
        let bytes=Data("{\"version\":1,\"documents\":[unfinished".utf8)
        try bytes.write(to:file)
        let store=CanvasDocumentStore(file:file,legacy:try JSONEncoder().encode([chat()]))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.issue)
        var reported:String?
        store.onIssue={reported=$0}
        XCTAssertEqual(reported,store.issue)
        XCTAssertNil(store.createCanvas())
        XCTAssertFalse(store.change(primary){$0.chats.append(self.chat())})
        XCTAssertFalse(store.flush())
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }

    func testInvalidVersionsAndDuplicateIdentitiesArePreserved() throws {
        let file=try temporaryDirectory().appendingPathComponent("boards.json")
        let board=CanvasDocument(id:primary,name:"Canvas",chats:[chat()])
        for fixture in [FixtureFile(version:2,documents:[board]),
                        FixtureFile(documents:[board,board]),
                        FixtureFile(documents:[CanvasDocument(id:primary,name:"Canvas",chats:[chat(),chat()])]),
                        FixtureFile(documents:[CanvasDocument(id:primary,name:"Canvas",chats:[],explorers:[panel(),panel()])])] {
            let bytes=try JSONEncoder().encode(fixture)
            try bytes.write(to:file)
            let store=CanvasDocumentStore(file:file)
            XCTAssertTrue(store.isReadOnly)
            XCTAssertFalse(store.flush())
            XCTAssertEqual(try Data(contentsOf:file),bytes)
        }
    }

    func testLegacyMigrationPreservesInstancesAndOriginalInput() throws {
        let file=try temporaryDirectory().appendingPathComponent("boards.json")
        let values=[chat("first",readY:20),chat("second",readY:50)]
        let legacy=try JSONEncoder().encode(values),original=legacy
        let store=CanvasDocumentStore(file:file,legacy:legacy)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(store.document(primary)?.chats,values)
        XCTAssertTrue(store.flush())
        XCTAssertEqual(legacy,original)
        XCTAssertEqual(CanvasDocumentStore(file:file).document(primary)?.chats,values)
    }

    func testMalformedLegacyDoesNotCreateReplacementFile() throws {
        let file=try temporaryDirectory().appendingPathComponent("boards.json")
        let store=CanvasDocumentStore(file:file,legacy:Data("broken preference".utf8))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertFalse(store.flush())
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }

    func testDistinctBoardsAndChatInstancesHaveIndependentGeometry() throws {
        let store=CanvasDocumentStore()
        let first=try XCTUnwrap(store.createCanvas()),second=try XCTUnwrap(store.createCanvas())
        XCTAssertEqual(Set([primary,first,second]).count,3)
        XCTAssertTrue(store.change(first){$0.chats=[self.chat("one"),self.chat("two")]})
        XCTAssertTrue(store.change(first){$0.chats[0].width=600;$0.chats[0].x=900})
        XCTAssertEqual(store.document(first)?.chats[1],chat("two"))
        XCTAssertEqual(store.document(second)?.chats,[])
        let original=store.documents
        var notifications=0
        let token=store.observe{_ in notifications += 1}
        XCTAssertFalse(store.change(first){$0.chats.append(self.chat("one"))})
        XCTAssertFalse(store.change(first){$0.id=second})
        XCTAssertFalse(store.change(first){$0.name=""})
        XCTAssertEqual(store.documents,original)
        XCTAssertEqual(notifications,0)
        store.removeObserver(token)
    }

    func testCrossBoardChatMoveSeedsCurrentReadingPositionAndPublishesAtomically() throws {
        let store=CanvasDocumentStore(),target=try XCTUnwrap(store.createCanvas())
        let old=chat(readY:15)
        XCTAssertTrue(store.change(primary){$0.chats=[old]})
        var incoming=old;incoming.readY=875
        var notifications:[String]=[]
        let token=store.observe { id in
            notifications.append(id)
            XCTAssertTrue(store.document(self.primary)!.chats.isEmpty)
            XCTAssertEqual(store.document(target)?.chats.first?.readY,875)
        }
        XCTAssertTrue(store.moveChat(old.presentationID,from:primary,to:target,at:NSPoint(x:500,y:600),incoming:incoming))
        XCTAssertEqual(Set(notifications),Set([primary,target]))
        XCTAssertEqual(store.document(target)?.chats.first?.x,500)
        store.removeObserver(token)
    }

    func testSameBoardMoveKeepsReadingSeedAndRejectsMismatchedIncomingIdentity() throws {
        let store=CanvasDocumentStore(),target=try XCTUnwrap(store.createCanvas())
        let old=chat(readY:15)
        XCTAssertTrue(store.change(primary){$0.chats=[old]})
        var incoming=old;incoming.readY=875
        XCTAssertTrue(store.moveChat(old.presentationID,from:primary,to:primary,at:NSPoint(x:200,y:300),incoming:incoming))
        XCTAssertEqual(store.document(primary)?.chats.first?.readY,15)
        let original=store.documents
        var wrongChat=CanvasPlacement(id:"another-chat",x:0,y:0,width:448,height:520,expanded:true,instanceID:old.presentationID)
        for invalid in [wrongChat,chat("another-instance")] {
            XCTAssertFalse(store.moveChat(old.presentationID,from:primary,to:target,at:.zero,incoming:invalid))
        }
        wrongChat=old;wrongChat.readY = .nan
        XCTAssertFalse(store.moveChat(old.presentationID,from:primary,to:target,at:.zero,incoming:wrongChat))
        XCTAssertEqual(store.documents,original)
    }

    func testExplorerCommitMovesMembershipBeforeEitherBoardIsObserved() throws {
        let store=CanvasDocumentStore(),target=try XCTUnwrap(store.createCanvas())
        var moved=panel()
        XCTAssertTrue(store.change(primary){$0.explorers=[moved]})
        moved.x=900;moved.collapsed=true
        let original=store.documents
        XCTAssertTrue(store.preflightExplorerTransfer(placement:moved,fromCanvas:primary,toCanvas:target))
        XCTAssertEqual(store.documents,original)
        var notifications:[String]=[]
        let token=store.observe { id in
            notifications.append(id)
            XCTAssertTrue(store.document(self.primary)!.explorers.isEmpty)
            XCTAssertEqual(store.document(target)?.explorers,[moved])
        }
        XCTAssertTrue(store.commitExplorerTransfer(placement:moved,fromCanvas:primary,toCanvas:target))
        XCTAssertEqual(Set(notifications),Set([primary,target]))
        XCTAssertEqual(notifications.count,2)
        store.removeObserver(token)
    }

    func testExplorerRejectsInvalidAndStaleTransfersWithoutPartialChanges() throws {
        let store=CanvasDocumentStore(),target=try XCTUnwrap(store.createCanvas())
        let placement=panel()
        XCTAssertTrue(store.change(primary){$0.explorers=[placement]})
        let original=store.documents
        var notifications=0
        let token=store.observe{_ in notifications += 1}
        var invalid=placement;invalid.x=100_000_001
        for (value,source,destination) in [(invalid,primary,target),(placement,"missing",target),
                                          (placement,primary,"missing"),(panel("wrong-instance"),primary,target)] {
            XCTAssertFalse(store.preflightExplorerTransfer(placement:value,fromCanvas:source,toCanvas:destination))
            XCTAssertFalse(store.commitExplorerTransfer(placement:value,fromCanvas:source,toCanvas:destination))
        }
        XCTAssertEqual(store.documents,original)
        XCTAssertEqual(notifications,0)
        XCTAssertTrue(store.preflightExplorerTransfer(placement:placement,fromCanvas:primary,toCanvas:target))
        XCTAssertTrue(store.change(primary){$0.explorers=[]})
        notifications=0
        let afterRemoval=store.documents
        XCTAssertFalse(store.commitExplorerTransfer(placement:placement,fromCanvas:primary,toCanvas:target))
        XCTAssertEqual(store.documents,afterRemoval)
        XCTAssertEqual(notifications,0)
        store.removeObserver(token)
    }

    func testDesktopAndExistingDestinationExplorerRecordsAreAddedOrReplaced() throws {
        let store=CanvasDocumentStore(),target=try XCTUnwrap(store.createCanvas())
        var placement=panel()
        XCTAssertTrue(store.commitExplorerTransfer(placement:placement,fromCanvas:nil,toCanvas:target))
        placement.width=920
        XCTAssertTrue(store.commitExplorerTransfer(placement:placement,fromCanvas:nil,toCanvas:target))
        XCTAssertEqual(store.document(target)?.explorers,[placement])
        XCTAssertFalse(store.preflightExplorerTransfer(placement:placement,fromCanvas:nil,toCanvas:primary))
        XCTAssertTrue(store.change(primary){$0.explorers=[self.panel()]})
        XCTAssertFalse(store.moveExplorer(placement.id,from:primary,to:target,at:.zero))
        XCTAssertTrue(store.commitExplorerTransfer(placement:placement,fromCanvas:primary,toCanvas:target))
        XCTAssertTrue(store.document(primary)!.explorers.isEmpty)
        XCTAssertEqual(store.document(target)?.explorers,[placement])
    }

    func testFlushPersistsLatestGeometryAndCancelledDebounceCannotOverwriteIt() throws {
        let file=try temporaryDirectory().appendingPathComponent("boards.json")
        let store=CanvasDocumentStore(file:file)
        XCTAssertTrue(store.change(primary){$0.chats=[self.chat()]})
        for value in 1...40 {XCTAssertTrue(store.change(primary){$0.chats[0].x=Double(value)})}
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(store.flush())
        XCTAssertFalse(store.hasUnsavedChanges)
        let settled=expectation(description:"Cancelled delayed jobs have passed their deadline")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3){settled.fulfill()}
        wait(for:[settled],timeout:2)
        XCTAssertEqual(CanvasDocumentStore(file:file).documents,store.documents)
        XCTAssertEqual(CanvasDocumentStore(file:file).document(primary)?.chats.first?.x,40)
        XCTAssertNil(store.issue)
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testWriteFailureIsReportedAndFlushRetriesLatestUnsavedGeometry() throws {
        let blocker=try temporaryDirectory().appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to:blocker)
        let file=blocker.appendingPathComponent("boards.json")
        let store=CanvasDocumentStore(file:file)
        let failure=expectation(description:"Asynchronous save failure is visible")
        var issueEvents:[String?]=[]
        store.onIssue={value in issueEvents.append(value);if value != nil{failure.fulfill()}}
        XCTAssertTrue(store.change(primary){$0.chats=[self.chat()]})
        wait(for:[failure],timeout:3)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertNotNil(store.issue)
        // Editing remains safe because failed writes keep the complete model.
        XCTAssertTrue(store.change(primary){$0.chats[0].x=999})
        try FileManager.default.removeItem(at:blocker)
        XCTAssertTrue(store.flush())
        XCTAssertNil(store.issue)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(issueEvents.compactMap{$0}.count,1)
        XCTAssertNil(issueEvents.first ?? nil)
        XCTAssertNil(issueEvents.last ?? nil)
        XCTAssertEqual(CanvasDocumentStore(file:file).document(primary)?.chats.first?.x,999)
    }
    func testLiteralVersionOneFileKeepsLegacyPresentationIdentityAndReadingSeed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("canvas-documents-v1.json")
        let bytes = Data(#"{"version":1,"documents":[{"id":"primary","name":"Canvas","chats":[{"id":"source-chat","x":12312,"y":12312,"width":448,"height":520,"expanded":true,"readY":42}],"explorers":[{"id":"explorer-view","x":12312,"y":12312,"width":942,"height":700,"collapsed":true}]}]}"#.utf8)
        try bytes.write(to: file)
        let store = CanvasDocumentStore(file: file, legacy: Data("invalid ignored legacy".utf8))
        let board = try XCTUnwrap(store.document("primary"))
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(board.chats.first?.presentationID, "source-chat")
        XCTAssertEqual(board.chats.first?.readY, 42)
        XCTAssertEqual(board.explorers.first?.id, "explorer-view")
        XCTAssertEqual(board.explorers.first?.collapsed, true)
        XCTAssertTrue(store.flush())
        let reopened = CanvasDocumentStore(file: file)
        XCTAssertEqual(reopened.documents, store.documents)
    }

}
