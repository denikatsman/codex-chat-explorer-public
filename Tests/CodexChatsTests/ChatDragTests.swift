import XCTest
import AppKit
import WebKit
@testable import CodexChats

final class ChatDragTests: XCTestCase {
    func testPayloadIsBoundedVersionedAndLocalToThisAppSession() throws {
        let data = try XCTUnwrap(ChatDragPayload(chatID: "recorded-chat").data)
        XCTAssertEqual(ChatDragPayload.read(data)?.chatID, "recorded-chat")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        value["version"] = 2
        XCTAssertNil(ChatDragPayload.read(try JSONSerialization.data(withJSONObject: value)))
        value["version"] = 1; value["session"] = "another-process"
        XCTAssertNil(ChatDragPayload.read(try JSONSerialization.data(withJSONObject: value)))
        XCTAssertNil(ChatDragPayload.read(ChatDragPayload(chatID: "").data))
        XCTAssertNil(ChatDragPayload.read(ChatDragPayload(chatID: String(repeating: "x", count: 513)).data))
        XCTAssertNil(ChatDragPayload.read(Data(repeating: 0, count: 4097)))
        XCTAssertNil(ChatDragPayload.read(Data("partial {".utf8)))
        XCTAssertNil(ChatDragPayload.read(nil))
    }

    func testDesktopCompletionRejectsCancellationAndAcceptedCanvasDrops() {
        XCTAssertTrue(ChatWindowDrop.shouldOpen(operation: [], cancelled: false, mouseReleased: true))
        XCTAssertFalse(ChatWindowDrop.shouldOpen(operation: .copy, cancelled: false, mouseReleased: true))
        XCTAssertFalse(ChatWindowDrop.shouldOpen(operation: [], cancelled: true, mouseReleased: true))
        XCTAssertFalse(ChatWindowDrop.shouldOpen(operation: [], cancelled: false, mouseReleased: false))
    }

    func testTransferCompletionRequiresNativeAcceptanceAndKeepsCancellationSafe() {
        XCTAssertEqual(ChatDragResolution.resolve(operation:.copy,destination:.canvas,cancelled:false,mouseReleased:true,outside:false),.accepted(.canvas))
        XCTAssertEqual(ChatDragResolution.resolve(operation:.copy,destination:.date,cancelled:false,mouseReleased:true,outside:false),.accepted(.date))
        XCTAssertEqual(ChatDragResolution.resolve(operation:.copy,destination:nil,cancelled:false,mouseReleased:true,outside:true),.cancelled)
        XCTAssertEqual(ChatDragResolution.resolve(operation:[],destination:.canvas,cancelled:false,mouseReleased:true,outside:true),.cancelled)
        XCTAssertEqual(ChatDragResolution.resolve(operation:.copy,destination:.canvas,cancelled:true,mouseReleased:true,outside:false),.cancelled)
        XCTAssertEqual(ChatDragResolution.resolve(operation:[],destination:nil,cancelled:false,mouseReleased:true,outside:true),.outside)
        XCTAssertEqual(ChatDragResolution.resolve(operation:[],destination:nil,cancelled:false,mouseReleased:false,outside:true),.cancelled)
    }

    func testReturningToDateRevealsTheRecordAndClearsOnlyBlockingScopes() throws {
        _ = NSApplication.shared
        let project = ProjectReference(identity:.assigned(kind:"fixture",id:"project"),name:"Fixture",originalAssignment:nil,originalProject:nil)
        let chat = Chat(original:["archived":.integer(1)],id:"return",title:"A returned chat",createdAt:Date(),archived:true,issues:[],project:project)
        let url = URL(fileURLWithPath:"/fixture.sqlite")
        let snapshot = ChatSnapshot(chats:[chat],sourceURL:url,observedAt:Date(),excludedSubagents:0,projectSourceURL:url,projectSourceIssue:nil)
        let root = ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
        root.show(snapshot);root.setPresentation(.date)
        root.timeline.setDateArchiveFilter(.nonArchived);root.timeline.setDateProjectScope(.nonProject)
        let bar = try XCTUnwrap(root.subviews.compactMap { $0 as? DateSearchBar }.first)
        let field = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Search DATE chats and projects" })
        field.stringValue="absent";bar.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
        XCTAssertTrue(root.timeline.entries.compactMap(\.chat).isEmpty)
        XCTAssertTrue(root.revealDateChat("return"))
        XCTAssertEqual(root.timeline.entries.compactMap(\.chat).map(\.id),["return"])
        XCTAssertEqual(root.timeline.dateArchiveFilter,.all);XCTAssertEqual(root.timeline.dateProjectScope,.all)
        XCTAssertEqual(field.stringValue,"")
        root.timeline.setDateArchiveFilter(.archived);root.timeline.setDateProjectScope(.project)
        field.stringValue="returned";bar.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
        XCTAssertTrue(root.revealDateChat("return"))
        XCTAssertEqual(root.timeline.dateArchiveFilter,.archived);XCTAssertEqual(root.timeline.dateProjectScope,.project)
        XCTAssertEqual(field.stringValue,"returned")
        XCTAssertFalse(root.revealDateChat("missing"))
        XCTAssertEqual(snapshot.chats.first?.original["archived"],.integer(1))
    }

    func testNativeCanvasReceiverCommitsBeforeSourceCleanupIncludingReaderDrops() throws {
        _ = NSApplication.shared
        let chat = fixtureChat()
        let root = ChatCanvasRoot(frame:NSRect(x:0,y:0,width:940,height:650),placements:[])
        root.update(fixtureSnapshot(chat),placements:[])
        let scroll = try XCTUnwrap(root.subviews.compactMap { $0 as? NSScrollView }.first)
        let surface = try XCTUnwrap(scroll.documentView)
        let reader = CanvasMarkdownView(chatID:chat.id,dark:true,state:CanvasReaderState())
        surface.addSubview(reader);defer { reader.close();reader.removeFromSuperview() }
        let web = try XCTUnwrap(reader.subviews.compactMap { $0 as? WKWebView }.first)
        let source = ChatDragSource(chatID:chat.id,origin:.window)
        source.placement=CanvasPlacement(id:chat.id,x:0,y:0,width:630,height:780,expanded:true,readY:73)
        let info = FixtureChatDraggingInfo(source:source,point:NSPoint(x:120,y:150))
        var cleanup = 0
        source.onAccepted = { destination in XCTAssertEqual(destination,.canvas);cleanup += 1 }
        XCTAssertEqual(web.draggingEntered(info),.move)
        XCTAssertTrue(web.performDragOperation(info))
        XCTAssertEqual(cleanup,0,"The destination commits before the source can close")
        XCTAssertEqual(root.layoutSnapshot.count,1)
        XCTAssertEqual(root.layoutSnapshot[0].width,630);XCTAssertEqual(root.layoutSnapshot[0].readY,73)
        source.complete(operation:.copy,mouseReleased:true,outside:false)
        XCTAssertEqual(cleanup,1)
        source.complete(operation:.copy,mouseReleased:true,outside:false)
        XCTAssertEqual(cleanup,1,"Duplicate completion cannot remove a second presentation")
    }

    func testNativeDateTabAndListAcceptReturningPresentationsWithoutDuplicatingRecords() throws {
        _ = NSApplication.shared
        let chat = fixtureChat(), snapshot = fixtureSnapshot(fixtureChat())
        let root = ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
        root.show(snapshot);root.setPresentation(.date)
        let button = try XCTUnwrap(root.subviews.compactMap { $0 as? ChatReturnDropButton }.first)
        for target in [button as NSView,root.timeline] {
            let source = ChatDragSource(chatID:chat.id,origin:target === button ? .canvas : .window)
            var returned = false;source.onAccepted = { XCTAssertEqual($0,.date);returned=true }
            let info = FixtureChatDraggingInfo(source:source,point:.zero)
            XCTAssertEqual(target.draggingEntered(info),.move)
            XCTAssertTrue(target.performDragOperation(info));XCTAssertFalse(returned)
            source.complete(operation:.copy,mouseReleased:true,outside:false)
            XCTAssertTrue(returned)
            XCTAssertEqual(root.timeline.entries.compactMap(\.chat).map(\.id),[chat.id])
        }
        let source = ChatDragSource(chatID:chat.id,origin:.date)
        XCTAssertEqual(button.draggingEntered(FixtureChatDraggingInfo(source:source,point:.zero)),[])
    }

    private func fixtureChat() -> Chat {
        Chat(original:[:],id:"transfer-fixture",title:"Transfer fixture",createdAt:Date(),archived:false,issues:[],project:ProjectReference(identity:.noProject,name:"No project",originalAssignment:nil,originalProject:nil))
    }
    private func fixtureSnapshot(_ chat: Chat) -> ChatSnapshot {
        let url=URL(fileURLWithPath:"/fixture.sqlite")
        return ChatSnapshot(chats:[chat],sourceURL:url,observedAt:Date(),excludedSubagents:0,projectSourceURL:url,projectSourceIssue:nil)
    }

    func testTearOffAllowsOtherAppsAndDesktopButRejectsExplorerWindows() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100), point = CGPoint(x: 50, y: 50)
        let wallpaper = ChatWindowDrop.Window(bounds: rect, layer: -1000, owner: 20, alpha: 1)
        let overlay = ChatWindowDrop.Window(bounds: rect, layer: 500, owner: 10, alpha: 1)
        let own = ChatWindowDrop.Window(bounds: rect, layer: 0, owner: 10, alpha: 1)
        let other = ChatWindowDrop.Window(bounds: rect, layer: 0, owner: 30, alpha: 1)
        XCTAssertTrue(ChatWindowDrop.isOutsideExplorer(point: point, windows: [wallpaper, overlay], ownPID: 10))
        XCTAssertFalse(ChatWindowDrop.isOutsideExplorer(point: point, windows: [overlay, own, wallpaper], ownPID: 10))
        XCTAssertFalse(ChatWindowDrop.isOutsideExplorer(point: point, windows: [own, other], ownPID: 10))
        XCTAssertTrue(ChatWindowDrop.isOutsideExplorer(point: point, windows: [other, own], ownPID: 10))
        XCTAssertTrue(ChatWindowDrop.isOutsideExplorer(point: CGPoint(x: 200, y: 200), windows: [own], ownPID: 10))
    }

    func testDetachedWindowFrameFitsSecondaryDisplaysWithoutChangingTheirOrigin() {
        for visible in [NSRect(x: 0, y: 0, width: 1440, height: 860), NSRect(x: -1280, y: -500, width: 1280, height: 720)] {
            for point in [NSPoint(x: visible.minX, y: visible.minY), NSPoint(x: visible.maxX - 1, y: visible.maxY - 1)] {
                let frame = ChatWindowDrop.frame(at: point, size: NSSize(width: 448, height: 620), visible: visible)
                XCTAssertTrue(visible.contains(frame))
            }
            XCTAssertEqual(ChatWindowDrop.frame(at: visible.origin, size: NSSize(width: 9000, height: 9000), visible: visible), visible)
        }
    }

    func testDateBodyClickSelectionWaitsForMouseUpAndDoubleClickStillOpensReader() throws {
        _ = NSApplication.shared
        let project = ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil)
        let chat = Chat(original: [:], id: "chat", title: "Fixture", createdAt: Date(), archived: false, issues: [], project: project)
        let url = URL(fileURLWithPath: "/fixture.sqlite")
        let view = TimelineView(frame: NSRect(x:0,y:0,width:940,height:650),persistExpansion:false)
        let window = ChatWindow(contentSize:view.frame.size); window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.setPresentation(.date)
        view.setSnapshot(ChatSnapshot(chats:[chat],sourceURL:url,observedAt:Date(),excludedSubagents:0,projectSourceURL:url,projectSourceIssue:nil))
        let row = try XCTUnwrap(view.entries.first { $0.chat != nil })
        let point = view.convert(NSPoint(x:250,y:row.y+12),to:nil)
        var toggled = [String](), opened = [String]()
        view.onToggleCanvasChat = { toggled.append($0) }; view.onOpenChat = { id,_ in opened.append(id) }
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:point,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:1))
        }
        view.mouseDown(with:try event(.leftMouseDown,modifiers:.command))
        XCTAssertTrue(toggled.isEmpty,"A modifier must not consume a potential drag on mouse down")
        view.mouseUp(with:try event(.leftMouseUp))
        XCTAssertEqual(toggled,["chat"])
        view.mouseDown(with:try event(.leftMouseDown)); view.mouseUp(with:try event(.leftMouseUp))
        XCTAssertEqual(toggled,["chat"],"An ordinary body click does not change canvas membership")
        view.mouseDown(with:try event(.leftMouseDown,clicks:2))
        XCTAssertEqual(opened,["chat"])
    }

    func testCanvasDropUsesIdentityPreservesOtherCardsAndPublishesMembership() throws {
        _ = NSApplication.shared
        let project = ProjectReference(identity: .noProject, name: "No project", originalAssignment: nil, originalProject: nil)
        let chats = ["first", "second"].map {
            Chat(original: [:], id: $0, title: "Same title", createdAt: Date(), archived: $0 == "second", issues: [], project: project)
        }
        let url = URL(fileURLWithPath: "/fixture.sqlite")
        let snapshot = ChatSnapshot(chats: chats, sourceURL: url, observedAt: Date(), excludedSubagents: 0, projectSourceURL: url, projectSourceIssue: nil)
        let first = CanvasPlacement(id: "first", x: 100, y: 200, width: 650, height: 900, expanded: true, readY: 42)
        let root = ChatCanvasRoot(frame: NSRect(x: 0, y: 0, width: 940, height: 650), placements: [first])
        root.update(snapshot, placements: [first])
        var published = [CanvasPlacement]()
        root.onChange = { published = $0 }
        XCTAssertTrue(root.dropChat("second", at: NSPoint(x: 1200, y: 300)))
        XCTAssertEqual(published.first { $0.id == "first" }, first)
        XCTAssertEqual(Set(published.map(\.id)), ["first", "second"])
        XCTAssertEqual(published.first { $0.id == "second" }?.x, 1200)
        XCTAssertTrue(published.first { $0.id == "second" }?.expanded == true)
        XCTAssertTrue(root.dropChat("second", at: NSPoint(x: 1700, y: 400)))
        XCTAssertEqual(root.layoutSnapshot.count, 2, "An existing chat is repositioned, not duplicated")
        XCTAssertEqual(published.first { $0.id == "second" }?.x, 1700)
        let carried = CanvasPlacement(id:"second",x:0,y:0,width:720,height:880,expanded:false,readY:123)
        XCTAssertTrue(root.dropChat("second",at:NSPoint(x:1900,y:450),placement:carried,replacingExisting:true))
        let transferred = try XCTUnwrap(root.layoutSnapshot.first { $0.id == "second" })
        XCTAssertEqual(transferred.width,720);XCTAssertEqual(transferred.height,880)
        XCTAssertEqual(transferred.readY,123);XCTAssertFalse(transferred.expanded)
        let before = root.layoutSnapshot
        var invalid = carried;invalid.height = .nan
        XCTAssertFalse(root.dropChat("second",at:NSPoint(x:0,y:0),placement:invalid,replacingExisting:true))
        XCTAssertFalse(root.dropChat("first",at:NSPoint(x:0,y:0),placement:carried))
        XCTAssertEqual(root.layoutSnapshot,before)
        XCTAssertFalse(root.dropChat("missing", at: NSPoint(x: 10, y: 10)))
        XCTAssertFalse(root.dropChat("first", at: NSPoint(x: CGFloat.nan, y: 10)))
        XCTAssertFalse(root.dropChat("first", at: NSPoint(x: -1, y: 10)))
        XCTAssertEqual(root.layoutSnapshot, before)
        XCTAssertEqual(snapshot.chats.map(\.id), ["first", "second"], "A drop never moves or deletes DATE records")
    }
}


private final class FixtureChatDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { (draggingSource as? ChatDragSource)?.preferredOperation ?? [] }
    let draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(source:ChatDragSource,point:NSPoint) {
        draggingSource=source;draggingLocation=point
        draggingPasteboard=NSPasteboard(name:NSPasteboard.Name("chat-transfer-test-"+UUID().uuidString))
        super.init()
        draggingPasteboard.setData(ChatDragPayload(chatID:source.chatID).data,forType:ChatDragPayload.type)
    }
    deinit { draggingPasteboard.releaseGlobally() }
    func slideDraggedImage(to screenPoint:NSPoint) { }
    override func namesOfPromisedFilesDropped(atDestination dropDestination:URL) -> [String]? { nil }
    func resetSpringLoading() { }
    func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions,for view:NSView?,classes:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:@escaping (NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) { }
}
