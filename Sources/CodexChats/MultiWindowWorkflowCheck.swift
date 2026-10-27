import AppKit
import ExplorerDiagnosticsBridge

/// Explicit private-state workload; shared services are real, model work and user-state persistence are disabled.
final class MultiWindowWorkflowCheck:NSObject {
    private let source:URL, output:URL
    private let preview:Bool
    private var manager:ExplorerWindowCoordinator!
    private var timer:Timer?
    private var phase="loading",deadline=Date().addingTimeInterval(30)
    private var chatID="",sourceChats=0,step=0
    private var first:ExplorerWindowController!
    private var firstCanvas:ChatCanvasRoot!
    private var creationMS=[Double](),lastTick=ProcessInfo.processInfo.systemUptime,maxTickGap=0.0
    private var checks=[String:Bool]()
    private var actionMS=[String:Double]()
    private var targetCanvas:ChatCanvasRoot?
    private var settleAfter=0.0
    init(source:URL,output:URL,preview:Bool = false){self.source=source;self.output=output;self.preview=preview;super.init()}
    func start(){
        do{try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)}catch{exit(1)}
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result {()->(ChatSnapshot,String) in
                let snapshot=try ChatStore.load(from:self.source),history=HistoryStore.source(for:snapshot)
                let preferred=Array(snapshot.chats.prefix(20))
                for chat in preferred {if let page=try? HistoryStore.page(chatID:chat.id,source:history,limit:1),!page.messages.isEmpty{return(snapshot,chat.id)}}
                throw StoreError(message:"No readable chat for multiwindow verification")
            }
            DispatchQueue.main.async{
                switch result{case .success(let value):self.prepare(value.0,chatID:value.1);case .failure(let error):self.finish(error.localizedDescription)}
            }
        }
        timer=Timer.scheduledTimer(withTimeInterval:0.05,repeats:true){[weak self] _ in self?.tick()}
    }
    private func prepare(_ snapshot:ChatSnapshot,chatID:String){
        self.chatID=chatID;sourceChats=snapshot.chats.count
        manager=ExplorerWindowCoordinator(persist:false);manager.update(snapshot)
        first=manager.newExplorer();NSApp.activate(ignoringOtherApps:true);first.window.makeKeyAndOrderFront(nil)
        if preview {
            ExplorerDiagnostics.shared.start(root:output.appendingPathComponent("diagnostics"))
            let menu=NSMenu(),item=NSMenuItem(),sub=NSMenu(title:"Preview")
            for (title,action) in [("Arrange Preview",#selector(arrangePreview)),("Show Explorer",#selector(revealPreviewExplorer)),("Show Canvas",#selector(revealPreviewCanvas))] {let entry=NSMenuItem(title:title,action:action,keyEquivalent:"");entry.target=self;sub.addItem(entry)}
            sub.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=sub;menu.addItem(item)
            let windowItem=NSMenuItem(),windowMenu=NSMenu(title:"Window");windowItem.submenu=windowMenu;menu.addItem(windowItem);NSApp.mainMenu=menu;NSApp.windowsMenu=windowMenu
            let workspace=manager.workspace(manager.primaryCanvasID);workspace.set([chatID],included:true);workspace.open();firstCanvas=workspace.root
            arrangePreview()
            phase="preview";timer?.invalidate();timer=nil
            print("READY: private multiwindow preview; no saved canvas or app preference writes.");fflush(stdout);return
        }
        first.root.openChat(chatID)
        phase="reader";deadline=Date().addingTimeInterval(20)
    }
    @objc private func arrangePreview() {
        guard let screen=NSScreen.screens.first else{return}
        let visible=screen.visibleFrame,h=min(800,visible.height-80),left=min(900,visible.width*0.4),right=min(1300,visible.width-left-120)
        first.window.setFrame(NSRect(x:visible.minX+30,y:visible.maxY-h-40,width:left,height:h),display:true)
        firstCanvas?.window?.setFrame(NSRect(x:visible.minX+left+60,y:visible.maxY-h-40,width:max(600,right),height:h),display:true)
    }
    @objc private func revealPreviewExplorer(){
        NSApp.activate(ignoringOtherApps:true);first.host.reveal()
        let point=first.window.convertPoint(toScreen:first.root.convert(NSPoint(x:240,y:18),to:nil))
        let data:[String:Any]=["id":first.window.windowNumber,"frame":NSStringFromRect(first.window.frame),"visible":first.window.isVisible,"active_space":first.window.isOnActiveSpace,"occluded":!first.window.occlusionState.contains(.visible),"alpha":first.window.alphaValue,"ignores_mouse":first.window.ignoresMouseEvents,"key":first.window.isKeyWindow,"app_active":NSApp.isActive,"point":NSStringFromPoint(point),"hit_window":NSWindow.windowNumber(at:point,belowWindowWithWindowNumber:0)]
        if let bytes=try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]){try? bytes.write(to:output.appendingPathComponent("input-window.json"))}
    }
    @objc private func revealPreviewCanvas(){NSApp.activate(ignoringOtherApps:true);firstCanvas?.window?.makeKeyAndOrderFront(nil)}
    private func tick(){
        guard phase != "finished" else{return}
        let now=ProcessInfo.processInfo.systemUptime;maxTickGap=max(maxTickGap,now-lastTick);lastTick=now
        if Date()>deadline{finish("Timed out in \(phase)");return}
        switch phase{
        case "reader":
            guard let reader=first.root.subviews.compactMap({$0 as? HistoryPane}).first,!reader.loading else{return}
            guard reader.displayedMessageCount>0 else{finish("Reader page unavailable");return}
            phase="create";deadline=Date().addingTimeInterval(60)
        case "create":
            let started=ProcessInfo.processInfo.systemUptime
            if step<9 {manager.duplicateExplorer(first)}
            else if step<19 {_=manager.openChatWindow(chatID)}
            else {
                let workspace=manager.workspace(manager.primaryCanvasID)
                if firstCanvas==nil {
                    var value=CanvasPlacement(id:chatID,x:12312,y:12312,width:448,height:520,expanded:true);value.instanceID=UUID().uuidString
                    _=manager.canvases.change(manager.primaryCanvasID){$0.chats.append(value)}
                    firstCanvas=workspace.newWindow()
                } else {_=workspace.newWindow(copying:firstCanvas)}
            }
            creationMS.append((ProcessInfo.processInfo.systemUptime-started)*1000);step += 1
            if step==29 {phase="verify";deadline=Date().addingTimeInterval(20)}
        case "verify":
            let workspace=manager.workspace(manager.primaryCanvasID)
            guard manager.explorers.count==10,manager.chatWindows.count==10,workspace.canvasViews.count==10,manager.canvases.documents.count==1 else{finish("Duplicate window counts or document identity differ");return}
            guard manager.explorers.values.allSatisfy({$0.root.library === manager.library}),Set(manager.chatWindows.values.map{$0.placement.id})==[chatID] else{finish("Shared content identity differs");return}
            checks["ten_each_window_type"]=true;checks["shared_content_identity"]=true
            guard let placement=firstCanvas.layoutSnapshot.first else{finish("Shared chat panel missing");return}
            var moved=placement;moved.x += 50;workspace.applyChatChanges([moved])
            guard workspace.canvasViews.allSatisfy({$0.chatPlacement(placement.presentationID)?.x==moved.x}) else{finish("Canvas arrangements did not synchronize");return}
            checks["shared_canvas_arrangement"]=true
            let before=workspace.canvasViews.map{($0,$0.viewportState)}
            workspace.rebase(dx:12288,dy:12288)
            guard before.allSatisfy({abs($0.0.viewportState.0.x-$0.1.0.x-12288)<0.5 && abs($0.0.viewportState.0.y-$0.1.0.y-12288)<0.5}) else{finish("Board rebase changed another window's view");return}
            checks["independent_viewports"]=true
            phase="embed";deadline=Date().addingTimeInterval(30)
        case "embed":
            let start=ProcessInfo.processInfo.systemUptime
            let workspace=manager.workspace(manager.primaryCanvasID)
            manager.addExplorer(first,to:firstCanvas,at:NSPoint(x:firstCanvas.visibleCanvasRect.minX+24,y:firstCanvas.visibleCanvasRect.minY+24))
            actionMS["embed_into_ten_canvas_views"]=(ProcessInfo.processInfo.systemUptime-start)*1000
            guard first.root.canvasExplorerPanel != nil else{finish("Explorer panel missing");return}
            phase="mirrors_ready";deadline=Date().addingTimeInterval(30)
        case "mirrors_ready":
            guard manager.pendingExplorerViews==0 else{return}
            let workspace=manager.workspace(manager.primaryCanvasID)
            guard let panel=first.root.canvasExplorerPanel,workspace.canvasViews.allSatisfy({$0.explorerPanels[panel.id] != nil}) else{finish("Explorer panel mirrors missing");return}
            phase="move";deadline=Date().addingTimeInterval(30)
        case "move":
            let start=ProcessInfo.processInfo.systemUptime
            let workspace=manager.workspace(manager.primaryCanvasID)
            let otherID=manager.canvases.createCanvas()!,other=manager.workspace(otherID),target=other.newWindow()!
            targetCanvas=target
            guard manager.moveExplorer(first,to:target,at:NSPoint(x:12312,y:12312)),workspace.document.explorers.isEmpty,other.document.explorers.count==1 else{finish("Cross-canvas Explorer move failed");return}
            actionMS["move_between_boards"]=(ProcessInfo.processInfo.systemUptime-start)*1000
            phase="detach";deadline=Date().addingTimeInterval(20)
        case "detach":
            let start=ProcessInfo.processInfo.systemUptime
            manager.detachExplorer(first,at:NSPoint(x:100,y:700))
            guard first.location==nil,first.window.contentView === first.root,let target=targetCanvas,manager.workspace(target.canvasID).document.explorers.isEmpty else{finish("Explorer desktop move failed");return}
            actionMS["detach_to_desktop"]=(ProcessInfo.processInfo.systemUptime-start)*1000
            checks["explorer_cross_canvas_and_desktop"]=true;checks["new_canvas_is_distinct"]=manager.canvases.documents.count==2
            phase="final_embed";deadline=Date().addingTimeInterval(30)
        case "final_embed":
            firstCanvas.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            let start=ProcessInfo.processInfo.systemUptime
            manager.addExplorer(first,to:firstCanvas,at:NSPoint(x:firstCanvas.visibleCanvasRect.minX+24,y:firstCanvas.visibleCanvasRect.minY+24))
            actionMS["repeat_embed"]=(ProcessInfo.processInfo.systemUptime-start)*1000
            settleAfter=ProcessInfo.processInfo.systemUptime+1
            phase="settle";deadline=Date().addingTimeInterval(15)
        case "settle":
            guard ProcessInfo.processInfo.systemUptime>=settleAfter,manager.pendingExplorerViews==0 else{return}
            // Mirrored Explorer windows can cover every chat. Expose one real
            // reader before testing the visibility-driven admission policy.
            if let chat=manager.chatWindows.values.sorted(by:{$0.window.windowNumber<$1.window.windowNumber}).first {
                chat.window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            }
            phase="reader_visible";settleAfter=ProcessInfo.processInfo.systemUptime+0.3
        case "reader_visible":
            guard ProcessInfo.processInfo.systemUptime>=settleAfter else{return}
            firstCanvas.resume();for chat in manager.chatWindows.values{chat.updateReaderVisibility()}
            manager.resources.readers.refresh()
            guard manager.resources.readers.admittedCount>0 else{return}
            guard manager.resources.readers.admittedCount<=16,!LabelCoordinator.hasRunningRequest,manager.explorers.values.allSatisfy({$0.root.labelRequestCount==0}) else{finish("Global reader/model admission bound failed");return}
            checks["global_render_budget"]=true;checks["no_label_requests"]=true
            capture();finish(nil)
        default:break
        }
    }
    private func capture(){
        firstCanvas.layoutSubtreeIfNeeded();firstCanvas.window?.displayIfNeeded()
        if let bitmap=firstCanvas.bitmapImageRepForCachingDisplay(in:firstCanvas.bounds){firstCanvas.cacheDisplay(in:firstCanvas.bounds,to:bitmap);if let data=bitmap.representation(using:.png,properties:[:]){try? data.write(to:output.appendingPathComponent("multiwindow.png"))}}
    }
    private func finish(_ failure:String?){
        guard phase != "finished" else{return};phase="finished";timer?.invalidate();timer=nil
        let sorted=creationMS.sorted()
        let readerWindows=(manager?.chatWindows.values.map {chat -> [String:Any] in
            let window=chat.window
            return ["window_id":window.windowNumber,"visible":window.isVisible,"occluded":!window.occlusionState.contains(.visible),"key":window.isKeyWindow,"active_space":window.isOnActiveSpace]
        } ?? []).sorted{($0["window_id"] as? Int ?? 0)<($1["window_id"] as? Int ?? 0)}
        let result:[String:Any]=["success":failure==nil,"failure":failure ?? NSNull(),"source_chats":sourceChats,"created_window_steps":step,"observed_checks":checks,"creation_median_ms":sorted.isEmpty ? 0:sorted[sorted.count/2],"creation_max_ms":sorted.last ?? 0,"max_main_loop_gap_ms":maxTickGap*1000,"action_ms":actionMS,"reader_clients":manager?.resources.readers.registeredCount ?? 0,"admitted_readers":manager?.resources.readers.admittedCount ?? 0,"pending_explorer_views":manager?.pendingExplorerViews ?? 0,"reader_windows":readerWindows,"app_active":NSApp.isActive,"persistence_enabled":false]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:output.appendingPathComponent("result.json"),options:.atomic)}
        manager?.closeAllWindows()
        if let failure{fputs("FAIL: \(failure)\n",stderr);exit(1)}
        print("PASS: ten Explorer, ten chat and ten canvas views; shared content/arrangements; independent views; distinct New Canvas; Explorer transfers; bounded renderers.");exit(0)
    }
}
