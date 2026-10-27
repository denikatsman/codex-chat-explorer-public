import AppKit

/// Opt-in real-data UI check; neither app preferences nor the ordinary recorder are started.
final class CanvasExplorerWorkflowCheck {
    private let source:URL, output:URL
    private var root:ChatRootView!, window:ChatWindow!, host:CanvasExplorerHost!, canvas:ChatCanvasRoot!
    private var reader:HistoryPane!
    private var timer:Timer?, observer:NSObjectProtocol?
    private var phase="loading", deadline=Date().addingTimeInterval(30)
    private var enteredFullScreen=false
    private var chatID="", chatCount=0, readerOffset=NSPoint.zero
    private var cards=[CanvasPlacement](), checkedViews=[String](), viewIndex=0
    private let views:[ChatPresentation]=[.date,.project,.timeline,.columns,.lanes,.active]
    private var failure:String?
    private var checks=[String:Bool]()
    init(source:URL,output:URL) { self.source=source;self.output=output }
    func start() {
        do { try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true) }
        catch { fputs("Cannot create canvas verification output.\n",stderr);exit(1) }
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result { () -> (ChatSnapshot,String) in
                let snapshot=try ChatStore.load(from:self.source), history=HistoryStore.source(for:snapshot)
                for chat in snapshot.chats.prefix(20) {
                    if let page=try? HistoryStore.page(chatID:chat.id,source:history),!page.messages.isEmpty { return (snapshot,chat.id) }
                }
                throw StoreError(message:"No readable real chat for canvas verification")
            }
            DispatchQueue.main.async {
                switch result { case .success(let value):self.prepare(value.0,chatID:value.1);case .failure(let error):self.finish(error.localizedDescription) }
            }
        }
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in self?.tick() }
    }
    private func prepare(_ snapshot:ChatSnapshot,chatID:String) {
        self.chatID=chatID;chatCount=snapshot.chats.count
        root=ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:true)
        window=ChatWindow(contentSize:root.frame.size);window.title="Explorer-in-canvas verification";window.contentView=root
        host=CanvasExplorerHost(explorer:root,window:window)
        root.show(snapshot);root.setDark(true);root.setPresentation(.date)
        host.workspace.set(Array(snapshot.chats.prefix(3).map(\.id)),included:true)
        reader=root.subviews.compactMap{$0 as? HistoryPane}.first
        guard reader != nil else { finish("Reader unavailable");return }
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        root.openChat(chatID);phase="reading";deadline=Date().addingTimeInterval(20)
    }
    private func tick() {
        guard phase != "finished" else { return }
        if Date()>deadline { finish("Timed out in \(phase); active=\(NSApp.isActive), key=\(window?.isKeyWindow ?? false), fullscreen=\(window?.styleMask.contains(.fullScreen) ?? false)");return }
        switch phase {
        case "reading":
            guard !reader.loading else { return }
            guard reader.displayedMessageCount>0 else { finish("Real reader page unavailable");return }
            guard NSApp.isActive,window.isKeyWindow,window.isVisible else {
                NSApp.activate(ignoringOtherApps:true);window.makeMain();window.makeKeyAndOrderFront(nil);return
            }
            observer=NotificationCenter.default.addObserver(forName:NSWindow.didEnterFullScreenNotification,object:window,queue:.main) { [weak self] _ in self?.enteredFullScreen=true }
            window.toggleFullScreen(nil);phase="fullscreen";deadline=Date().addingTimeInterval(15)
        case "fullscreen":
            guard enteredFullScreen else { return }
            reader.scroll.contentView.scroll(to:NSPoint(x:0,y:100));readerOffset=reader.scroll.contentView.bounds.origin
            host.workspace.open();canvas=host.workspace.root;cards=canvas.layoutSnapshot
            phase="embed";deadline=Date().addingTimeInterval(15)
        case "embed":
            guard let button=canvas.subviews.compactMap({$0 as? NSButton}).first(where:{$0.title=="EXPLORER"}) else { finish("EXPLORER button missing");return }
            button.performClick(nil);phase="embedded";deadline=Date().addingTimeInterval(15)
        case "embedded":
            guard host.isEmbedded else { return }
            let state:[String:Any] = ["same_view":canvas.explorerPanel?.explorer === root,"window_is_canvas":root.window === canvas.window,"old_content_nil":window.contentView == nil,"old_window_visible":window.isVisible,"same_chat":reader.chat?.id==chatID,"reader_hidden":reader.isHidden,"messages":reader.displayedMessageCount,"reader_y_before":readerOffset.y,"reader_y_after":reader.scroll.contentView.bounds.minY]
            if let data=try? JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:output.appendingPathComponent("embedded-state.json")) }
            capture("embedded-reader.png")
            guard canvas.explorerPanel?.explorer === root,root.window === canvas.window,window.contentView == nil,!window.isVisible,
                  reader.chat?.id==chatID,!reader.isHidden,reader.displayedMessageCount>0,
                  abs(reader.scroll.contentView.bounds.minY-readerOffset.y)<0.5 else { finish("Live reader or position was not preserved");return }
            checks["live_reader_preserved"]=true
            guard let back=reader.subviews.compactMap({$0 as? NSButton}).first(where:{$0.title=="‹ BACK"}) else { finish("Back unavailable");return }
            back.performClick(nil);root.layoutSubtreeIfNeeded();capture("embedded-explorer.png")
            phase="tab";deadline=Date().addingTimeInterval(20)
        case "tab":
            let view=views[viewIndex]
            guard let button=root.subviews.compactMap({$0 as? NSButton}).first(where:{$0.frame.minY==43 && $0.title.hasPrefix(view.rawValue.uppercased())}) else { finish("View button missing: \(view.rawValue)");return }
            button.performClick(nil);phase="view_ready";deadline=Date().addingTimeInterval(20)
        case "view_ready":
            let view=views[viewIndex]
            guard root.timeline.presentation==view else { finish("Tab did not select \(view.rawValue)");return }
            if view == .columns && root.columnsView == nil { return }
            if view == .lanes && root.lanePanel.snapshot == nil { return }
            checkedViews.append(view.rawValue);viewIndex += 1
            phase=viewIndex==views.count ? "geometry" : "tab";deadline=Date().addingTimeInterval(20)
        case "geometry":
            guard let panel=canvas.explorerPanel else { finish("Explorer panel disappeared");return }
            let before=panel.frame
            drag(panel,from:NSPoint(x:150,y:16),to:NSPoint(x:210,y:56))
            guard abs(panel.frame.minX-before.minX-60)<0.5,abs(panel.frame.minY-before.minY-40)<0.5 else { finish("Native header drag failed: \(NSStringFromRect(before)) → \(NSStringFromRect(panel.frame))");return }
            checks["native_drag"]=true
            let moved=panel.frame
            drag(panel,from:NSPoint(x:panel.bounds.width-6,y:panel.bounds.height-6),to:NSPoint(x:panel.bounds.width-66,y:panel.bounds.height-46))
            guard abs(panel.frame.width-moved.width+60)<0.5,abs(panel.frame.height-moved.height+40)<0.5 else { finish("Native resize grip failed: \(NSStringFromRect(moved)) → \(NSStringFromRect(panel.frame))");return }
            checks["native_resize"]=true
            root.minimizeWindow();guard panel.isCollapsed,root.isHidden else { finish("Panel collapse failed");return }
            canvas.revealExplorer();guard !panel.isCollapsed,!root.isHidden,canvas.explorerPanel === panel else { finish("Panel expansion duplicated or lost Explorer");return }
            checks["collapse_and_expand"]=true
            root.setPresentation(.date);root.layoutSubtreeIfNeeded();capture("embedded-moved-resized.png")
            host.restore(showWindow:true);phase="popped_out";deadline=Date().addingTimeInterval(10)
        case "popped_out":
            guard window.contentView === root,root.window === window,window.isVisible,canvas.explorerPanel == nil,sameCards(canvas.layoutSnapshot,cards) else { finish("Pop Out changed the live view or chat cards");return }
            checks["pop_out"]=true
            host.embed(in:canvas);phase="repeat_embedded";deadline=Date().addingTimeInterval(15)
        case "repeat_embedded":
            guard host.isEmbedded else { return }
            host.workspace.window?.close();phase="canvas_closed";deadline=Date().addingTimeInterval(10)
        case "canvas_closed":
            guard window.contentView === root,root.window === window,window.isVisible,!host.isEmbedded else { finish("Canvas close stranded the Explorer");return }
            checks["canvas_close_restore"]=true
            host.workspace.open();canvas=host.workspace.root;host.embed(in:canvas);phase="dismiss_embedded";deadline=Date().addingTimeInterval(15)
        case "dismiss_embedded":
            guard host.isEmbedded else { return }
            canvas.explorerPanel?.dismiss()
            guard window.contentView === root,!window.isVisible,!host.isEmbedded else { finish("Panel close did not retain the Explorer safely: content=\(window.contentView === root), visible=\(window.isVisible), embedded=\(host.isEmbedded), panel=\(canvas.explorerPanel != nil)");return }
            host.workspace.window?.close();phase="dismissed_closed";deadline=Date().addingTimeInterval(10)
        case "dismissed_closed":
            guard window.contentView === root,window.isVisible,!host.isEmbedded else { finish("Closing canvas after dismissing the panel stranded Explorer: visible=\(window.isVisible), embedded=\(host.isEmbedded)");return }
            checks["dismiss_then_close_restore"]=true
            guard sameCards(canvas.layoutSnapshot,cards) else { finish("Chat card placements changed during hosting");return }
            checks["chat_placements_preserved"]=true
            finish(nil)
        default:break
        }
    }
    private func sameCards(_ lhs:[CanvasPlacement],_ rhs:[CanvasPlacement]) -> Bool {
        // Existing card suspension saves the initial read offset as 0 rather than nil.
        func normalize(_ values:[CanvasPlacement]) -> [CanvasPlacement] {
            values.map { value in var copy=value;copy.readY=copy.readY ?? 0;return copy }.sorted { $0.id < $1.id }
        }
        return normalize(lhs)==normalize(rhs)
    }
    private func drag(_ panel:CanvasExplorerPanel,from:NSPoint,to:NSPoint) {
        guard let window=panel.window else { return }
        NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
        func event(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent? {
            NSEvent.mouseEvent(with:type,location:panel.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)
        }
        guard let down=event(.leftMouseDown,from),let drag=event(.leftMouseDragged,to),let up=event(.leftMouseUp,to) else { return }
        NSApp.postEvent(drag,atStart:true);NSApp.postEvent(up,atStart:false);window.sendEvent(down)
    }
    private func capture(_ name:String) {
        canvas.layoutSubtreeIfNeeded();canvas.window?.displayIfNeeded()
        if let bitmap=canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds) {
            canvas.cacheDisplay(in:canvas.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) { try? data.write(to:output.appendingPathComponent(name)) }
        }
    }
    private func finish(_ failure:String?) {
        guard phase != "finished" else { return };phase="finished";timer?.invalidate();timer=nil
        if let observer { NotificationCenter.default.removeObserver(observer) };observer=nil
        host?.restore(showWindow:false)
        let result:[String:Any]=["success":failure == nil,"failure":failure ?? NSNull(),"real_chat_count":chatCount,"checked_views":checkedViews,"native_fullscreen_before_embedding":enteredFullScreen,"same_live_view":checks["live_reader_preserved"] as Any? ?? NSNull(),"native_drag_and_resize":checks["native_resize"] as Any? ?? NSNull(),"canvas_close_restored_window":checks["canvas_close_restore"] as Any? ?? NSNull(),"observed_checks":checks,"saved_state_writes":false]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:output.appendingPathComponent("result.json"),options:.atomic) }
        host?.workspace.window?.close();window?.close()
        if let failure { fputs("FAIL: \(failure)\n",stderr);exit(1) }
        print("PASS: same live Explorer, six view tabs, real reader/Back, native panel drag/resize, collapse/expand, Pop Out and canvas-close restoration.")
        exit(0)
    }
}
