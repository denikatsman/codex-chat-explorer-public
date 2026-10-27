import WindowingKit
import AppKit
import ExplorerDiagnosticsBridge

final class ExplorerWindowController {
    let id=UUID().uuidString
    let window:ChatWindow
    let root:ChatRootView
    let host:CanvasExplorerHost
    var location:(canvasID:String,viewID:String,panelID:String)?
    var closeObserver:NSObjectProtocol?
    var closing=false
    var applyingGeometry=false
    var duplicateAction:DuplicateWindowAction!
    init(root:ChatRootView,window:ChatWindow) {
        self.root=root;self.window=window
        root.windowInstanceID=id
        host=CanvasExplorerHost(explorer:root,window:window,activateWindows:false,manageWorkspace:false)
    }
    deinit {if let closeObserver{NotificationCenter.default.removeObserver(closeObserver)}}
}

/// One app session owns data/observers/models. Windows own only their presentation state.
final class ExplorerWindowCoordinator {
    let library:ExplorerLibrary
    let canvases:CanvasDocumentStore
    let resources=SharedCanvasResources()
    let lastTurns:LastTurnReconciler
    private let persist:Bool
    private let activateWindows:Bool
    private(set) var snapshot:ChatSnapshot?
    private var active:ActiveSnapshot?
    private(set) var explorers=[String:ExplorerWindowController]()
    private(set) var chatWindows=[String:DetachedChatController]()
    private var retired=[String:ExplorerWindowController]()
    private var workspaces=[String:ChatCanvasWorkspace]()
    private var templates=[String:WindowPresentationState]()
    private var synchronizing=false
    private var pendingExplorerKeys=Set<String>()
    private var pendingExplorerBuilds=[()->Void]()
    private var buildingExplorer=false
    var pendingExplorerViews:Int {pendingExplorerKeys.count}
    private var appearanceObserver:NSObjectProtocol?
    private var transfers=[UUID:TransferTicket]()
    var onCanvasListChanged:(()->Void)?
    private final class TransferTicket {
        let started=DispatchTime.now().uptimeNanoseconds
        var source:WindowTransferSource?
        var sourceCanvasID:String?
        var readingState:CanvasReaderState?
        var chat:CanvasPlacement?
        weak var sourceCanvas:ChatCanvasRoot?
        var chatWindow:DetachedChatController?
        var explorer:ExplorerWindowController?
        var sourceView:NSView?
        var originalWindowFrame:NSRect?
        init() {}
    }
    init(persist:Bool = true,library:ExplorerLibrary? = nil,canvases:CanvasDocumentStore? = nil,activateWindows:Bool = true) {
        self.persist=persist;self.activateWindows=activateWindows
        self.library=library ?? ExplorerLibrary(directory:persist ? ExplorerLibrary.defaultDirectory : FileManager.default.temporaryDirectory.appendingPathComponent("multiwindow-library-\(UUID())"))
        self.canvases=canvases ?? (persist ? .persistent() : CanvasDocumentStore())
        lastTurns=LastTurnReconciler(allowWork:persist)
        self.canvases.onIssue={ [weak self] issue in for workspace in self?.workspaces.values ?? Dictionary<String,ChatCanvasWorkspace>().values {for canvas in workspace.canvasViews{canvas.canvasIssue=issue;canvas.needsDisplay=true}} }
        lastTurns.onUpdate={ [weak self] patch,ids in for c in self?.explorers.values ?? Dictionary<String,ExplorerWindowController>().values {c.root.timeline.mergeLastTurns(patch,for:ids)} }
        appearanceObserver=NotificationCenter.default.addObserver(forName:AppearanceSettings.changed,object:nil,queue:.main) { [weak self] _ in self?.updateTheme() }
    }
    deinit {if let appearanceObserver{NotificationCenter.default.removeObserver(appearanceObserver)};lastTurns.shutdown()}
    var primaryCanvasID:String {canvases.document(CanvasDocumentStore.primaryID)?.id ?? canvases.documents[0].id}
    func workspace(_ id:String)->ChatCanvasWorkspace {
        if let existing=workspaces[id]{return existing}
        let value=ChatCanvasWorkspace(persist:persist,store:canvases,canvasID:id,resources:resources)
        value.coordinator=self;workspaces[id]=value
        if let snapshot{value.update(snapshot)}
        let settings=AppearanceSettings.shared;value.setTheme(dark:settings.current.isDark,green:!settings.isCustom && settings.preset == .green)
        return value
    }
    func update(_ snapshot:ChatSnapshot) {
        self.snapshot=snapshot;resources.invalidate(notify:false);lastTurns.updateMetadata(snapshot)
        for workspace in workspaces.values{workspace.update(snapshot)}
        for controller in Array(explorers.values){controller.root.show(snapshot)}
        for controller in chatWindows.values{controller.update(snapshot)}
    }
    func showError(_ message:String) {for controller in explorers.values{controller.root.showError(message)}}
    func updateActive(_ value:ActiveSnapshot) {
        active=value;lastTurns.updateActive(value)
        for controller in explorers.values{controller.root.showActive(value)}
    }
    private func updateTheme() {
        let settings=AppearanceSettings.shared,dark=settings.current.isDark,green = !settings.isCustom && settings.preset == .green
        for workspace in workspaces.values{workspace.setTheme(dark:dark,green:green)}
        for chat in chatWindows.values{chat.setTheme(dark:dark,green:green)}
    }
    @discardableResult func newExplorer(copying state:WindowPresentationState? = nil,canvasID:String? = nil,show:Bool = true,frame:NSRect? = nil)->ExplorerWindowController {
        let board=workspace(canvasID ?? primaryCanvasID)
        let restoreDefaults=persist && state == nil && explorers.isEmpty
        let root=ChatRootView(frame:NSRect(origin:.zero,size:frame?.size ?? NSSize(width:940,height:650)),persistTheme:persist,loadOnDemand:true,library:library,canvasWorkspace:board,sharedReconciliation:true,persistViewDefaults:restoreDefaults)
        let window=ChatWindow(contentSize:root.frame.size);window.contentView=root;if let frame{window.setFrame(frame,display:false)}else{window.center()}
        let controller=ExplorerWindowController(root:root,window:window)
        explorers[controller.id]=controller
        controller.duplicateAction=DuplicateWindowAction { [weak self,weak controller] in if let controller{self?.duplicateExplorer(controller)} }
        window.duplicateWindowAction=controller.duplicateAction
        root.onDuplicateWindow={ [weak self,weak controller] in if let controller{self?.duplicateExplorer(controller)} }
        root.onWindowDrag={ [weak self,weak controller] event in if let controller{self?.beginExplorerWindowDrag(controller,event:event)} }
        root.onLabelSettled={ [weak self,weak controller] in if let controller{self?.releaseRetired(controller)} }
        controller.host.onDuplicate={ [weak self,weak controller] in if let controller{self?.duplicateExplorer(controller)} }
        controller.host.onDismiss={ [weak self,weak controller] in if let controller{self?.closeExplorer(controller)} }
        controller.host.onDragOutside={ [weak self,weak controller] panel,event in if let controller{self?.beginExplorerTransfer(controller,view:panel,event:event)} }
        controller.host.onPanelGeometry={ [weak self,weak controller] panel in
            guard let self,let controller,!controller.applyingGeometry,let place=controller.location else{return}
            let f=panel.expandedFrame
            _=self.canvases.change(place.canvasID){document in if let i=document.explorers.firstIndex(where:{$0.id==place.panelID}) {document.explorers[i]=ExplorerPanelPlacement(id:place.panelID,x:f.minX,y:f.minY,width:f.width,height:f.height,collapsed:panel.isCollapsed)}}
        }
        controller.closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self,weak controller] _ in
            guard let controller,!controller.closing,controller.location==nil else{return};self?.retire(controller)
        }
        if let snapshot{root.show(snapshot)}
        if let state{root.restorePresentationState(state)}else if !restoreDefaults{root.setPresentation(.date)}
        if let latest=lastTurns.latest{root.timeline.mergeLastTurns(latest,for:Set(snapshot?.chats.map(\.id) ?? []))}
        if let active{root.showActive(active)}
        if explorers.count>1{window.title="Codex Chat Explorer — View \(explorers.count)"}
        if show && activateWindows {window.makeKeyAndOrderFront(nil)}
        ExplorerDiagnostics.event("window.explorer.created",["view_id":.text(controller.id)])
        return controller
    }
    func newCanvas() {
        guard let id=canvases.createCanvas() else{showStorageIssue();return}
        workspace(id).open(activate:activateWindows);onCanvasListChanged?()
    }
    func openCanvas(_ id:String) {guard canvases.document(id) != nil else{return};workspace(id).open(activate:activateWindows)}
    var windowEntries:[(String,NSWindow)] {
        let explorer=explorers.values.filter{$0.location==nil && !$0.closing}.map{($0.id,$0.window as NSWindow)}
        let chats=chatWindows.values.map{($0.id,$0.window as NSWindow)}
        let boards=workspaces.values.flatMap{workspace in workspace.canvasViews.compactMap{root in root.window.map{(root.canvasViewID,$0)}}}
        return (explorer+chats+boards).sorted{$0.1.title.localizedStandardCompare($1.1.title) == .orderedAscending}
    }
    func showWindow(_ id:String) {guard let window=windowEntries.first(where:{$0.0==id})?.1 else{return};if window.isMiniaturized{window.deminiaturize(nil)};window.makeKeyAndOrderFront(nil)}
    func revealExplorer() {
        if let current=focusedExplorer(){current.host.reveal();return}
        if let current=explorers.values.first{current.host.reveal();return}
        _=newExplorer()
    }
    func focusedExplorer()->ExplorerWindowController? {
        if let view=(NSApp.keyWindow?.contentView as? ChatCanvasRoot)?.focusedExplorer{return explorers.values.first{$0.root===view}}
        return explorers.values.first{$0.window===NSApp.keyWindow}
    }
    func find() {revealExplorer();(focusedExplorer() ?? explorers.values.first)?.root.showFind()}
    func saved() {revealExplorer();(focusedExplorer() ?? explorers.values.first)?.root.showSavedItems()}
    func duplicateFocusedWindow() {NSApp.keyWindow.flatMap{$0 as? ChatWindow}?.duplicateWindowAction?.perform?()}
    func showExplorer(in canvas:ChatCanvasRoot) {
        guard !canvases.isReadOnly else{showStorageIssue();return}
        if let panel=canvas.explorerPanel{canvas.revealExplorer(panel.id);return}
        let controller=explorers.values.first{$0.location==nil && $0.window.isVisible} ?? newExplorer(canvasID:canvas.canvasID,show:false)
        addExplorer(controller,to:canvas,at:NSPoint(x:canvas.visibleCanvasRect.minX+24,y:canvas.visibleCanvasRect.minY+24))
    }
    func addExplorer(_ controller:ExplorerWindowController,to canvas:ChatCanvasRoot,at point:NSPoint,panelID:String = UUID().uuidString,fromCanvas:String? = nil) {
        let size=NSSize(width:max(602,controller.root.bounds.width+2),height:max(370,controller.root.bounds.height+50))
        let placement=ExplorerPanelPlacement(id:panelID,x:max(0,point.x),y:max(0,point.y),width:min(3000,size.width),height:min(3000,size.height))
        guard canvases.preflightExplorerTransfer(placement:placement,fromCanvas:fromCanvas,toCanvas:canvas.canvasID) else{showStorageIssue();return}
        controller.root.bindCanvasWorkspace(workspace(canvas.canvasID))
        controller.applyingGeometry=true
        controller.host.embed(in:canvas,placement:placement) { [weak self,weak controller,weak canvas] ok in
            guard let self,let controller else{return};controller.applyingGeometry=false
            guard ok,let canvas,self.workspace(canvas.canvasID).canvasViews.contains(where:{$0===canvas}) else {controller.host.restore(showWindow:true);return}
            controller.location=(canvas.canvasID,canvas.canvasViewID,panelID)
            self.templates[panelID]=controller.root.capturePresentationState()
            if !self.canvases.commitExplorerTransfer(placement:placement,fromCanvas:fromCanvas,toCanvas:canvas.canvasID) {
                controller.location=nil;controller.host.restore(showWindow:true);self.showStorageIssue();return
            }
            if self.activateWindows{canvas.window?.makeKeyAndOrderFront(nil)}
        }
    }
    func synchronizeExplorers(in workspace:ChatCanvasWorkspace,copying source:ChatCanvasRoot? = nil) {
        guard !synchronizing else{return};synchronizing=true;defer{synchronizing=false}
        let records=workspace.document.explorers,valid=Set(records.map(\.id))
        let old=Array(explorers.values).filter{$0.location?.canvasID==workspace.canvasID}
        for controller in old where !valid.contains(controller.location!.panelID){retire(controller)}
        for canvas in workspace.canvasViews {
            canvas.pruneExplorerPlaceholders(valid)
            for record in records {
                if let controller=explorers.values.first(where:{$0.location?.viewID==canvas.canvasViewID && $0.location?.panelID==record.id}) {
                    if let panel=controller.root.canvasExplorerPanel, panel.expandedFrame != record.frame || panel.isCollapsed != record.collapsed {
                        controller.applyingGeometry=true;panel.applyShared(record);controller.applyingGeometry=false
                    }
                    continue
                }
                let key=canvas.canvasViewID+"/"+record.id
                canvas.showExplorerPlaceholder(record)
                guard pendingExplorerKeys.insert(key).inserted else{continue}
                let state=source?.explorerPanels[record.id]?.explorer.capturePresentationState() ?? explorers.values.first(where:{$0.location?.panelID==record.id})?.root.capturePresentationState() ?? templates[record.id]
                pendingExplorerBuilds.append { [weak self,weak canvas] in
                    guard let self else{return};defer{self.pendingExplorerKeys.remove(key)}
                    guard let canvas,self.workspace(workspace.canvasID).canvasViews.contains(where:{$0===canvas}),
                          let current=self.canvases.document(workspace.canvasID)?.explorers.first(where:{$0.id==record.id}) else{return}
                    if self.explorers.values.contains(where:{$0.location?.viewID==canvas.canvasViewID && $0.location?.panelID==record.id}){canvas.removeExplorerPlaceholder(record.id);return}
                    let controller=self.newExplorer(copying:state,canvasID:workspace.canvasID,show:false)
                    controller.location=(workspace.canvasID,canvas.canvasViewID,record.id)
                    canvas.removeExplorerPlaceholder(record.id)
                    controller.applyingGeometry=true;controller.host.embed(in:canvas,placement:current,reveal:false);controller.applyingGeometry=false
                }

            }
        }
        scheduleExplorerBuild()
    }
    private func scheduleExplorerBuild() {
        guard !buildingExplorer,!pendingExplorerBuilds.isEmpty else{return};buildingExplorer=true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.01) { [weak self] in
            guard let self else{return}
            let build=self.pendingExplorerBuilds.removeFirst();build()
            self.buildingExplorer=false;self.scheduleExplorerBuild()
        }
    }
    func canvasClosed(_ canvas:ChatCanvasRoot,in workspace:ChatCanvasWorkspace) {
        for controller in Array(explorers.values) where controller.location?.viewID==canvas.canvasViewID {retire(controller)}
    }
    func duplicateExplorer(_ controller:ExplorerWindowController) {
        if controller.location != nil && canvases.isReadOnly{showStorageIssue();return}
        let state=controller.root.capturePresentationState()
        if let location=controller.location,let canvas=workspace(location.canvasID).canvasViews.first(where:{$0.canvasViewID==location.viewID}),let old=canvases.document(location.canvasID)?.explorers.first(where:{$0.id==location.panelID}) {
            let copy=newExplorer(copying:state,canvasID:location.canvasID,show:false,frame:NSRect(x:0,y:0,width:old.width-2,height:old.height-50))
            addExplorer(copy,to:canvas,at:NSPoint(x:old.x+24,y:old.y+24))
            if old.collapsed,let id=copy.location?.panelID{_=canvases.change(location.canvasID){d in if let i=d.explorers.firstIndex(where:{$0.id==id}){d.explorers[i].collapsed=true}}}
        } else {
            let copy=newExplorer(copying:state,show:false,frame:controller.window.frame.offsetBy(dx:24,dy:-24))
            if activateWindows{copy.window.makeKeyAndOrderFront(nil)}
        }
        ExplorerDiagnostics.event("window.duplicate",["kind":.text("explorer"),"source_view":.text(controller.id)])
    }
    private func closeExplorer(_ controller:ExplorerWindowController) {
        if let location=controller.location{_=canvases.change(location.canvasID){$0.explorers.removeAll{$0.id==location.panelID}}}
        else{controller.window.close()}
    }
    private func retire(_ controller:ExplorerWindowController) {
        guard !controller.closing else{return};controller.closing=true
        if let location=controller.location{templates[location.panelID]=controller.root.capturePresentationState()}
        controller.host.restore(showWindow:false);controller.location=nil;controller.window.orderOut(nil)
        explorers.removeValue(forKey:controller.id)
        if controller.root.hasLabelWork{retired[controller.id]=controller}
        else{controller.window.contentView=nil;controller.window.close()}
    }
    private func releaseRetired(_ controller:ExplorerWindowController) {
        guard !controller.root.hasLabelWork,retired.removeValue(forKey:controller.id) != nil else{return}
        controller.window.contentView=nil;controller.window.close()
    }
    @discardableResult func openChatWindow(_ chatID:String,at point:NSPoint? = nil,placement:CanvasPlacement? = nil)->DetachedChatController? {
        guard let snapshot,snapshot.chats.contains(where:{$0.id==chatID}) else{return nil}
        var value=placement ?? CanvasPlacement(id:chatID,x:0,y:0,width:448,height:620,expanded:true)
        if value.instanceID==nil{value.instanceID=UUID().uuidString}
        let settings=AppearanceSettings.shared
        let controller=DetachedChatController(chatID:chatID,snapshot:snapshot,resources:resources,dark:settings.current.isDark,green:!settings.isCustom && settings.preset == .green,placement:value)
        chatWindows[controller.id]=controller
        controller.onClose={ [weak self,weak controller] in if let controller{self?.chatWindows.removeValue(forKey:controller.id)} }
        controller.onDuplicate={ [weak self,weak controller] in
            guard let self,let controller else{return};var copy=controller.placement;copy.instanceID=UUID().uuidString
            let duplicate=self.openChatWindow(chatID,at:NSPoint(x:controller.window.frame.minX+24,y:controller.window.frame.maxY-24),placement:copy);duplicate?.restoreReadingState(controller.readingState)
        }
        controller.onTransfer={ [weak self] controller,view,event in self?.beginChatWindowDrag(controller,view:view,event:event) }
        let frame=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        controller.show(at:point ?? NSPoint(x:frame.midX-value.width/2,y:frame.midY+value.height/2),activate:activateWindows)
        return controller
    }
    private func beginChatWindowDrag(_ controller:DetachedChatController,view:NSView,event:NSEvent) {
        guard let next=dragThreshold(in:controller.window,event:event) else{return}
        let ticket=TransferTicket();ticket.chat=controller.placement;ticket.readingState=controller.readingState;ticket.chatWindow=controller;ticket.sourceView=view;ticket.originalWindowFrame=controller.window.frame
        begin(ticket,kind:.chat,id:controller.id,view:view,event:next,title:controller.window.title)
    }
    func beginChatTransfer(_ value:CanvasPlacement,from canvas:ChatCanvasRoot,view:NSView,event:NSEvent) {
        let ticket=TransferTicket();ticket.chat=value;ticket.readingState=canvas.chatReadingState(value.presentationID);ticket.sourceCanvasID=canvas.canvasID;ticket.sourceCanvas=canvas;ticket.sourceView=view
        begin(ticket,kind:.chat,id:canvas.canvasViewID+":"+value.presentationID,view:view,event:event,title:"Chat")
    }
    private func beginExplorerWindowDrag(_ controller:ExplorerWindowController,event:NSEvent) {
        guard !controller.window.styleMask.contains(.fullScreen),let next=dragThreshold(in:controller.window,event:event) else{return}
        beginExplorerTransfer(controller,view:controller.root,event:next)
    }
    private func beginExplorerTransfer(_ controller:ExplorerWindowController,view:NSView,event:NSEvent) {
        let ticket=TransferTicket();ticket.explorer=controller;ticket.sourceView=view;ticket.originalWindowFrame=controller.window.frame
        if let location=controller.location{ticket.sourceCanvasID=location.canvasID;ticket.sourceCanvas=workspace(location.canvasID).canvasViews.first{$0.canvasViewID==location.viewID}}
        begin(ticket,kind:.explorer,id:controller.id,view:view,event:event,title:"Codex Chat Explorer")
    }
    private func dragThreshold(in window:NSWindow,event:NSEvent)->NSEvent? {
        let start=event.locationInWindow
        while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp{return nil}
            if hypot(next.locationInWindow.x-start.x,next.locationInWindow.y-start.y)>=5{return next}
        };return nil
    }
    private func begin(_ ticket:TransferTicket,kind:WindowTransferKind,id:String,view:NSView,event:NSEvent,title:String) {
        let source=WindowTransferSource(kind:kind,presentationID:id),key=source.payload.transferID
        ticket.source=source;transfers[key]=ticket
        ExplorerDiagnostics.event("window.transfer.begin",operation:key.uuidString,["kind":.text(kind.rawValue),"view_id":.text(id),"source_canvas":ticket.sourceCanvasID.map(DiagnosticValue.text) ?? .null])
        source.shouldDropOnDesktop={ [weak ticket] point in
            guard let canvas=ticket?.sourceCanvas,let window=canvas.window else{return true}
            let target=NSWindow.windowNumber(at:point,belowWindowWithWindowNumber:0)
            return !window.frame.contains(point) || (target != 0 && target != window.windowNumber)
        }
        source.onStarted={ [weak ticket] in
            if let chat=ticket?.chatWindow{chat.setTransferring(true)}
            if let explorer=ticket?.explorer,explorer.location==nil{explorer.window.ignoresMouseEvents=true;explorer.window.alphaValue=0}
        }
        source.onCancelled={ [weak ticket] in
            if let chat=ticket?.chatWindow{chat.setTransferring(false)}
            if let explorer=ticket?.explorer,!explorer.closing,explorer.location==nil{explorer.window.ignoresMouseEvents=false;explorer.window.alphaValue=1;explorer.window.makeKeyAndOrderFront(nil)}
            ExplorerDiagnostics.event("window.transfer.cancelled",operation:key.uuidString)
        }
        source.onDesktopDrop={ [weak self,weak ticket] point in
            if let explorer=ticket?.explorer{explorer.window.ignoresMouseEvents=false;explorer.window.alphaValue=1}
            if let ticket{self?.dropOnDesktop(ticket,at:point)}
            ExplorerDiagnostics.event("window.transfer.end",operation:key.uuidString,["destination":.text("desktop")])
        }
        source.onAccepted={ [weak ticket] destination in
            if let explorer=ticket?.explorer{explorer.window.ignoresMouseEvents=false;explorer.window.alphaValue=1}
            if let chat=ticket?.chatWindow{chat.window.close()}
            ExplorerDiagnostics.event("window.transfer.end",operation:key.uuidString,["destination":.text("canvas"),"canvas_id":.text(destination.canvasID)])
        }
        source.onFinished={ [weak self] _ in self?.transfers.removeValue(forKey:key) }
        let settings=AppearanceSettings.shared
        if !source.begin(from:view,event:event,title:title,subtitle:"Move between canvas and desktop",ink:AppTheme.ink(dark:settings.current.isDark,green:!settings.isCustom && settings.preset == .green),paper:AppTheme.background(dark:settings.current.isDark)){transfers.removeValue(forKey:key)}
    }
    func accept(_ source:WindowTransferSource,in canvas:ChatCanvasRoot,at point:NSPoint)->Bool {
        guard let ticket=transfers[source.payload.transferID] else{return false}
        return source.accept(canvasID:canvas.canvasID,at:point) { [self] in
            if var chat=ticket.chat {
                let success:Bool
                if let old=ticket.sourceCanvasID {success=canvases.moveChat(chat.presentationID,from:old,to:canvas.canvasID,at:point,incoming:chat)}
                else {chat.x=max(0,point.x);chat.y=max(0,point.y);success=canvases.change(canvas.canvasID){document in if !document.chats.contains(where:{$0.presentationID==chat.presentationID}){document.chats.append(chat)}}}
                if success,ticket.sourceCanvasID != canvas.canvasID,let state=ticket.readingState {for view in workspace(canvas.canvasID).canvasViews{view.restoreChatReadingState(chat.presentationID,state)}}
                return success
            }
            guard let controller=ticket.explorer,!controller.closing else{return false}
            return moveExplorer(controller,to:canvas,at:point)
        }
    }
    @discardableResult func moveExplorer(_ controller:ExplorerWindowController,to canvas:ChatCanvasRoot,at point:NSPoint)->Bool {
        guard !controller.closing else{return false}
            if let location=controller.location,location.canvasID==canvas.canvasID {return canvases.moveExplorer(location.panelID,from:location.canvasID,to:canvas.canvasID,at:point)}
            let old=controller.location
            let panelID=old?.panelID ?? UUID().uuidString
            let frame=controller.root.canvasExplorerPanel?.expandedFrame ?? NSRect(origin:.zero,size:NSSize(width:controller.root.bounds.width+2,height:controller.root.bounds.height+50))
            let placement=ExplorerPanelPlacement(id:panelID,x:max(0,point.x),y:max(0,point.y),width:min(3000,max(602,frame.width)),height:min(3000,max(370,frame.height)))
            guard canvases.preflightExplorerTransfer(placement:placement,fromCanvas:old?.canvasID,toCanvas:canvas.canvasID) else{return false}
            controller.applyingGeometry=true;controller.host.restore(showWindow:false);controller.applyingGeometry=false;controller.location=nil
            addExplorer(controller,to:canvas,at:point,panelID:panelID,fromCanvas:old?.canvasID)
            return controller.location?.canvasID==canvas.canvasID
    }
    func detachExplorer(_ controller:ExplorerWindowController,at point:NSPoint) {
        guard !controller.closing,!canvases.isReadOnly else{return}
        let old=controller.location;controller.host.restore(showWindow:false);controller.location=nil
        if let old{_=canvases.change(old.canvasID){$0.explorers.removeAll{$0.id==old.panelID}}}
        if let screen=NSScreen.screens.first(where:{$0.frame.contains(point)}) ?? NSScreen.main {controller.window.setFrame(ChatWindowDrop.frame(at:point,size:controller.window.frame.size,visible:screen.visibleFrame),display:true)}
        if activateWindows{controller.window.makeKeyAndOrderFront(nil)}
    }
    private func dropOnDesktop(_ ticket:TransferTicket,at point:NSPoint) {
        if let chat=ticket.chat {
            if let window=ticket.chatWindow{window.setTransferring(false);window.show(at:point);return}
            guard let opened=openChatWindow(chat.id,at:point,placement:chat) else{return}
            if let state=ticket.readingState{opened.restoreReadingState(state)}
            if let canvasID=ticket.sourceCanvasID{workspace(canvasID).removeChat(chat.presentationID)}
        } else if let controller=ticket.explorer {detachExplorer(controller,at:point)}
    }

    func closeAllWindows() {
        for workspace in Array(workspaces.values){workspace.closeViews()}
        for controller in Array(chatWindows.values){controller.window.close()}
        for controller in Array(explorers.values){controller.window.close()}
    }
    func shutdownLabels(completion:@escaping()->Void) {
        let roots=Array(explorers.values)+Array(retired.values)
        let busy=roots.filter{$0.root.hasLabelWork}
        guard !busy.isEmpty else{completion();return}
        var remaining=busy.count
        for c in busy{c.root.stopLabelWork {remaining -= 1;if remaining==0{completion()}}}
    }
    func saveState()->Bool {if canvases.isReadOnly && !canvases.hasUnsavedChanges{return true};return canvases.flush()}
    func flush() {_=canvases.flush();lastTurns.shutdown()}
    private func showStorageIssue() {guard activateWindows else{return};let alert=NSAlert();alert.messageText="Canvas unavailable";alert.informativeText=canvases.issue ?? "Canvas state could not be changed.";alert.runModal()}
}
