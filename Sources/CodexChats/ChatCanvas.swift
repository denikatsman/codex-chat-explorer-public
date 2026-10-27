import WindowingKit
import AppKit
import ExplorerDiagnosticsBridge

struct CanvasPlacement: Codable, Equatable {
    let id: String
    var x: Double, y: Double, width: Double, height: Double
    var expanded: Bool
    var readY: Double? = nil
    var instanceID: String? = nil
    var presentationID: String { instanceID ?? id }
    var isValidTransfer: Bool {
        !id.isEmpty && [x,y,width,height].allSatisfy(\.isFinite)
            && (0...100_000_000).contains(x) && (0...100_000_000).contains(y)
            && (300...3000).contains(width) && (220...10_000).contains(height)
            && (readY.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

protocol CanvasZoomCommands: AnyObject {
    func adjustCanvasZoom(_ delta: CGFloat)
    func resetCanvasZoom()
}

final class ChatCanvasWorkspace {
    let store:CanvasDocumentStore
    let canvasID:String
    let resources:SharedCanvasResources
    weak var coordinator:ExplorerWindowCoordinator?
    var onSelectionChanged:((Set<String>)->Void)?
    var onExplorer:((ChatCanvasRoot)->Void)?
    var onClose:(()->Void)?
    private var selectionObservers=[UUID:(Set<String>)->Void]()
    private var views=[String:CanvasWindowView]()
    private var recentViewID:String?
    private var rebasing=false
    private var viewOrdinal=0
    private var observation:UUID?
    private var detached=[String:DetachedChatController]()
    private(set) var snapshot:ChatSnapshot?
    private var dark=true,green=false
    var document:CanvasDocument { store.document(canvasID) ?? CanvasDocument(id:canvasID,name:"Unavailable canvas",chats:[]) }
    var selected:Set<String> { Set(document.chats.map(\.id)) }
    var window:ChatWindow? { recentViewID.flatMap{views[$0]?.window} ?? views.values.first?.window }
    var root:ChatCanvasRoot? { recentViewID.flatMap{views[$0]?.root} ?? views.values.first?.root }
    var canvasViews:[ChatCanvasRoot] { views.values.map(\.root) }
    init(persist:Bool,store:CanvasDocumentStore? = nil,canvasID:String = CanvasDocumentStore.primaryID,resources:SharedCanvasResources? = nil) {
        self.store=store ?? (persist ? .persistent() : CanvasDocumentStore())
        self.canvasID=canvasID;self.resources=resources ?? SharedCanvasResources()
        observation=self.store.observe { [weak self] id in if id==self?.canvasID { self?.documentChanged() } }
    }
    deinit { if let observation { store.removeObserver(observation) } }
    @discardableResult func observeSelection(_ callback:@escaping(Set<String>)->Void)->UUID { let id=UUID();selectionObservers[id]=callback;return id }
    func removeSelectionObserver(_ id:UUID) { selectionObservers.removeValue(forKey:id) }
    func update(_ snapshot:ChatSnapshot) {
        guard self.snapshot?.observedAt != snapshot.observedAt || self.snapshot?.sourceURL != snapshot.sourceURL else{return}
        self.snapshot=snapshot
        for view in views.values { view.apply(snapshot,document:document) }
        for controller in detached.values { controller.update(snapshot) }
    }
    private func documentChanged() {
        if let snapshot { for view in Array(views.values){view.apply(snapshot,document:document)} }
        onSelectionChanged?(selected);for callback in Array(selectionObservers.values){callback(selected)}
        coordinator?.synchronizeExplorers(in:self)
    }
    func toggle(_ id:String) { set([id],included:!selected.contains(id)) }
    func set(_ ids:[String],included:Bool) {
        _ = store.change(canvasID) { document in
            if !included { document.chats.removeAll{ids.contains($0.id)};return }
            for id in ids where !document.chats.contains(where:{$0.id==id}) {
                var slot=0,rect=NSRect.zero
                repeat { rect=NSRect(x:12312+Double(slot%3)*472,y:12312+Double(slot/3)*600,width:448,height:520);slot += 1 }
                while document.chats.contains{NSRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height).intersects(rect)}
                var value=CanvasPlacement(id:id,x:rect.minX,y:rect.minY,width:448,height:520,expanded:false);value.instanceID=UUID().uuidString;document.chats.append(value)
            }
        }
    }
    func setTheme(dark:Bool,green:Bool) {
        self.dark=dark;self.green=green
        for view in views.values { view.root.setTheme(dark:dark,green:green) }
        for controller in detached.values { controller.setTheme(dark:dark,green:green) }
    }
    func open(activate:Bool = true) {
        if let root,let window { if activate {window.makeKeyAndOrderFront(nil)};root.resume();return }
        _ = newWindow(copying:nil,activate:activate)
    }
    @discardableResult func newWindow(copying source:ChatCanvasRoot? = nil,activate:Bool = true) -> ChatCanvasRoot? {
        guard let snapshot else{return nil}
        let view=CanvasWindowView(workspace:self,snapshot:snapshot,document:document)
        viewOrdinal += 1
        view.window.title=document.name+" — View \(viewOrdinal) — Codex Chat Explorer"
        views[view.id]=view;recentViewID=view.id
        view.root.setTheme(dark:dark,green:green);view.root.canvasIssue=store.issue
        if let source {
            if let window=source.window{view.window.setFrame(window.frame.offsetBy(dx:24,dy:-24),display:false);view.root.layoutSubtreeIfNeeded()}
            view.root.restoreViewport(source.viewportState);view.root.copyReaderLocations(from:source)
        }
        coordinator?.synchronizeExplorers(in:self,copying:source)
        if source == nil{view.root.homeToContents()}
        if activate {view.window.makeKeyAndOrderFront(nil)};view.root.resume()
        ExplorerDiagnostics.event("canvas.window.open",["canvas_id":.text(canvasID),"view_id":.text(view.id)])
        return view.root
    }
    fileprivate func closed(_ id:String) {
        guard let view=views.removeValue(forKey:id) else{return}
        coordinator?.canvasClosed(view.root,in:self)
        view.root.suspend();if recentViewID==id {recentViewID=views.keys.first}
        onClose?()
    }
    func closeViews() { for view in Array(views.values){view.window.close()} }
    func rebase(dx:CGFloat,dy:CGFloat) {
        guard !rebasing else{return};rebasing=true;defer{rebasing=false}
        let positions=canvasViews.map{($0,$0.viewportState)}
        let changed=store.change(canvasID){document in
            for i in document.chats.indices{document.chats[i].x += dx;document.chats[i].y += dy}
            for i in document.explorers.indices{document.explorers[i].x += dx;document.explorers[i].y += dy}
        }
        if changed {for (root,old) in positions{root.restoreRebasedViewport(old,dx:dx,dy:dy)}}
    }
    func applyChatChanges(_ changed:[CanvasPlacement]) {
        _ = store.change(canvasID) { document in
            for incoming in changed {
                if let i=document.chats.firstIndex(where:{$0.presentationID==incoming.presentationID}) {
                    var value=incoming;value.readY=document.chats[i].readY;document.chats[i]=value
                } else {document.chats.append(incoming)}
            }
        }
    }
    func removeChat(_ instance:String) { _ = store.change(canvasID){$0.chats.removeAll{$0.presentationID==instance}} }
    func duplicateChat(_ instance:String,from root:ChatCanvasRoot) {
        guard var copy=root.chatPlacement(instance) else{return};let state=root.chatReadingState(instance)
        copy.instanceID=UUID().uuidString;copy.x += 24;copy.y += 24
        _ = store.change(canvasID){$0.chats.append(copy)}
        if let state {for view in canvasViews{view.restoreChatReadingState(copy.presentationID,state)}}
    }
    @discardableResult func openDetached(_ id:String,at point:NSPoint,placement:CanvasPlacement? = nil) -> Bool {
        if let coordinator {return coordinator.openChatWindow(id,at:point,placement:placement) != nil}
        guard let snapshot,snapshot.chats.contains(where:{$0.id==id}) else{return false}
        var value=placement ?? CanvasPlacement(id:id,x:0,y:0,width:448,height:620,expanded:true)
        if value.instanceID==nil {value.instanceID=UUID().uuidString}
        let controller=DetachedChatController(chatID:id,snapshot:snapshot,resources:resources,dark:dark,green:green,placement:value)
        let key=controller.id;detached[key]=controller
        controller.onClose={ [weak self] in self?.detached.removeValue(forKey:key) }
        controller.show(at:point);return true
    }
}

private final class CanvasWindowView {
    let id=UUID().uuidString
    let window:ChatWindow
    let root:ChatCanvasRoot
    private weak var workspace:ChatCanvasWorkspace?
    private var closeObserver:NSObjectProtocol?
    private var duplicateAction:DuplicateWindowAction!
    init(workspace:ChatCanvasWorkspace,snapshot:ChatSnapshot,document:CanvasDocument) {
        self.workspace=workspace
        let size=NSSize(width:min(1440,(NSScreen.main?.visibleFrame.width ?? 1500)-60),height:min(860,(NSScreen.main?.visibleFrame.height ?? 940)-60))
        window=ChatWindow(contentSize:size);window.title=document.name+" — Codex Chat Explorer"
        root=ChatCanvasRoot(frame:NSRect(origin:.zero,size:size),placements:document.chats,resources:workspace.resources)
        root.canvasID=workspace.canvasID;root.canvasViewID=id
        root.onRebase={ [weak workspace] dx,dy in workspace?.rebase(dx:dx,dy:dy) }
        root.canvasTitle=document.name
        root.onGeometryChanges={ [weak self] values in self?.workspace?.applyChatChanges(values) }
        root.onRemove={ [weak workspace] id in workspace?.removeChat(id) }
        root.onDuplicateChat={ [weak workspace,weak root] id in if let root{workspace?.duplicateChat(id,from:root)} }
        root.onExplorer={ [weak workspace,weak root] in guard let root else{return};if let manager=workspace?.coordinator { manager.showExplorer(in:root) } else {workspace?.onExplorer?(root)} }
        root.onDetachChat={ [weak workspace] id,placement,point in workspace?.openDetached(id,at:point,placement:placement) ?? false }
        root.onWindowTransfer={ [weak workspace,weak root] source,point in guard let root else{return false};return workspace?.coordinator?.accept(source,in:root,at:point) ?? false }
        root.onChatTransfer={ [weak workspace,weak root] placement,view,event in guard let root else{return};workspace?.coordinator?.beginChatTransfer(placement,from:root,view:view,event:event) }
        duplicateAction=DuplicateWindowAction { [weak workspace,weak root] in _=workspace?.newWindow(copying:root) }
        root.menu=duplicateAction.menu();window.duplicateWindowAction=duplicateAction
        window.contentView=root;window.center();root.update(snapshot,placements:document.chats)
        closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in guard let self else{return};self.workspace?.closed(self.id) }
    }
    deinit {if let closeObserver{NotificationCenter.default.removeObserver(closeObserver)}}
    func apply(_ snapshot:ChatSnapshot,document:CanvasDocument) {root.update(snapshot,placements:document.chats)}
}

final class CanvasMessageBox: NSObject {
    let message: RecordedMessage
    let html: String
    init(_ message: RecordedMessage, html: String) { self.message = message; self.html = html }
}

private final class CanvasDragHeader: NSView {
    weak var card: CanvasChatCard?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { card?.track(event, resize: false) }
    override func draw(_ dirtyRect: NSRect) { card?.drawHeader(in: bounds) }
}

private final class CanvasResizeGrip: NSView {
    weak var card: CanvasChatCard?
    override func mouseDown(with event: NSEvent) { card?.track(event, resize: true) }
    override func draw(_ dirtyRect: NSRect) {
        (card?.muted ?? NSColor.gray).setStroke()
        for n: CGFloat in [4,8,12] {
            let p = NSBezierPath(); p.move(to: NSPoint(x: bounds.maxX - n, y: 1)); p.line(to: NSPoint(x: bounds.maxX - 1, y: n)); p.stroke()
        }
    }
}

private final class CanvasReaderHost: NSView { override var isFlipped: Bool { true } }

private final class CanvasChatCard: NSView {
    override var isFlipped: Bool { true }
    var placement: CanvasPlacement
    var onChange: (() -> Void)?
    var onRemove: (() -> Void)?
    var onMove: ((CanvasChatCard,NSEvent) -> Void)?
    var onWindowResize: ((NSEvent) -> Void)?
    var isCanvasSelected = false { didSet { needsDisplay = true; header.needsDisplay = true } }
    private let header = CanvasDragHeader(), grip = CanvasResizeGrip()
    private let disclosure = NSButton(), remove = NSButton()
    private let readerHost = CanvasReaderHost()
    private let readerHint = NSTextField(wrappingLabelWithString:"Select this card’s header to show its reader.")
    private var reader: CanvasMarkdownView?
    private var readerState = CanvasReaderState()
    private var readerVisible = false
    private let status = NSTextField(labelWithString: "")
    private let retry = NSButton()
    private let resources:SharedCanvasResources
    private var queue:DispatchQueue {resources.queue}
    private var cache:NSCache<NSString,CanvasMessageBox> {resources.cache}
    private var readerAdmission:UUID?
    private var invalidationObserver:NSObjectProtocol?
    private let resizeEdges=WindowResizeEdges(frame:.zero)
    var onDuplicate:(()->Void)?
    private var duplicateAction:DuplicateWindowAction!
    private var snapshot: ChatSnapshot?
    private var chat: Chat?
    private var references = [CanvasMessageReference]()
    private var preparedRows=[[String:String]]()
    private var failures = [String: String]()
    private var pending = Set<String>()
    private var reading = false, indexed = false, suspended = false
    private var wantsReader=false
    private var cancellation = HistoryCancellation()
    private var generation = UUID()
    private var dark = true, green = false
    private let formatter = DateFormatter()
    var muted: NSColor { AppTheme.muted(dark: dark, green: green) }
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private var paper: NSColor { AppTheme.background(dark:dark) }

    init(placement: CanvasPlacement, resources:SharedCanvasResources) {
        self.placement = placement; self.resources=resources
        super.init(frame: NSRect(x: placement.x, y: placement.y, width: placement.width, height: placement.expanded ? placement.height : 54))
        header.card = self; grip.card = self
        formatter.dateStyle = .medium; formatter.timeStyle = .medium
        readerState.y = max(0, placement.readY ?? 0)
        for (button, title, action) in [(disclosure, "▸", #selector(toggle)), (remove, "×", #selector(removeCard)), (retry, "RELOAD", #selector(reload))] {
            button.title = title; button.isBordered = false; button.target = self; button.action = action; button.focusRingType = .none
        }
        disclosure.setAccessibilityLabel("Expand chat: \(placement.id)")
        remove.setAccessibilityLabel("Remove chat from canvas")
        retry.setAccessibilityLabel("Reload canvas chat history")
        header.addSubview(disclosure); header.addSubview(remove)
        readerHint.font = .systemFont(ofSize:12); readerHost.addSubview(readerHint)
        status.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        for view in [header, readerHost, status, retry, grip] { addSubview(view) }
        duplicateAction=DuplicateWindowAction { [weak self] in self?.onDuplicate?() }
        resizeEdges.configure(view:self,minimumSize:NSSize(width:300,height:220),maximumSize:NSSize(width:3000,height:10000)) { [weak self] rect in
            guard let self,self.placement.expanded else{return}
            self.frame=rect;self.placement.x=rect.minX;self.placement.y=rect.minY;self.placement.width=rect.width;self.placement.height=rect.height
            self.needsLayout=true;self.layoutSubtreeIfNeeded()
        }
        resizeEdges.onEnd={ [weak self] in self?.onChange?() };addSubview(resizeEdges)
        readerAdmission=resources.readers.register(self) { [weak self] active in self?.applyReaderAdmission(active) }
        invalidationObserver=NotificationCenter.default.addObserver(forName:SharedCanvasResources.invalidated,object:resources,queue:.main) { [weak self] note in
            guard let self,(note.userInfo?["chatID"] as? String).map({$0==self.placement.id}) ?? true else{return};self.reloadLocal()
        }
        applyTheme(); updateExpansion()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit {if let invalidationObserver{NotificationCenter.default.removeObserver(invalidationObserver)}; if let readerAdmission {resources.readers.unregister(readerAdmission)};cancellation.cancel(); reader?.close() }

    func update(_ snapshot: ChatSnapshot) {
        if self.snapshot?.observedAt != snapshot.observedAt, self.snapshot != nil { releaseReader();indexed=false;references=[] }
        self.snapshot = snapshot; chat = snapshot.chats.first { $0.id == placement.id }
        let context = duplicateAction.menu(appending:ChatContextMenu.make(chatID: placement.id))
        menu = context; header.menu = context; readerHost.menu = context
        disclosure.setAccessibilityLabel("\(placement.expanded ? "Collapse" : "Expand") chat: \(chat?.title ?? placement.id)")
        header.needsDisplay = true
        if readerVisible && placement.expanded && !indexed && !reading && !suspended { loadIndex() }
    }
    func setTheme(dark: Bool, green: Bool) { self.dark = dark; self.green = green; applyTheme() }
    private func applyTheme() {
        reader?.setTheme(dark:dark,green:green); status.textColor = muted; readerHint.textColor = muted
        for button in [disclosure,remove,retry] {
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: button === retry ? 9 : 17, weight: .regular), .foregroundColor: ink])
        }
        needsDisplay = true; header.needsDisplay = true
    }
    override func layout() {
        super.layout()
        header.frame = NSRect(x: 1, y: 1, width: bounds.width - 2, height: 52)
        disclosure.frame = NSRect(x: 4, y: 5, width: 28, height: 28)
        remove.frame = NSRect(x: header.bounds.width - 27, y: 6, width: 24, height: 24)
        readerHost.frame = NSRect(x:1,y:54,width:bounds.width-2,height:max(1,bounds.height-81))
        readerHint.frame = NSRect(x:18,y:18,width:max(1,readerHost.bounds.width-36),height:44)
        reader?.frame = readerHost.bounds
        status.frame = NSRect(x: 12, y: bounds.height - 21, width: max(1, bounds.width - 101), height: 16)
        retry.frame = NSRect(x: bounds.width - 83, y: bounds.height - 24, width: 62, height: 20)
        grip.frame = NSRect(x: bounds.width - 17, y: bounds.height - 17, width: 16, height: 16)
        resizeEdges.frame=bounds;resizeEdges.isEnabled=placement.expanded && onWindowResize == nil
    }
    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); bounds.fill(); (isCanvasSelected ? AppTheme.palette(dark:dark,green:green).selection : AppTheme.border(dark:dark,green:green)).setStroke()
        let border = NSBezierPath(rect:bounds.insetBy(dx:isCanvasSelected ? 1.5 : 0.5,dy:isCanvasSelected ? 1.5 : 0.5))
        border.lineWidth = isCanvasSelected ? 3 : 1; border.stroke()
        if placement.expanded { line(from: NSPoint(x: 1,y: 53.5), to: NSPoint(x: bounds.width-1,y: 53.5), color: muted) }
    }
    func drawHeader(in bounds: NSRect) {
        if isCanvasSelected { AppTheme.palette(dark:dark,green:green).selection.withAlphaComponent(0.12).setFill(); bounds.insetBy(dx:2,dy:2).fill() }
        label(chat?.title ?? "Source chat unavailable", in: NSRect(x: 38,y: 8,width: bounds.width-72,height: 19),size: 12,weight: .bold,color: ink)
        label(chat?.project.name ?? placement.id, in: NSRect(x: 38,y: 29,width: bounds.width-50,height: 15),size: 9,color: muted)
    }
    @objc private func toggle() {
        if placement.expanded { releaseReader() }
        placement.expanded.toggle()
        updateExpansion(); onChange?()
    }
    private func updateExpansion() {
        setFrameSize(NSSize(width:placement.width,height:placement.expanded ? placement.height : 54))
        disclosure.title = placement.expanded ? "▾" : "▸"
        disclosure.setAccessibilityLabel("\(placement.expanded ? "Collapse" : "Expand") chat: \(chat?.title ?? placement.id)")
        for view in [readerHost,status,retry,grip] { view.isHidden = !placement.expanded }
        needsLayout = true; layoutSubtreeIfNeeded(); applyTheme()
    }
    var readingState:CanvasReaderState {readerState}
    func restoreReadingState(_ value:CanvasReaderState) {
        releaseReader();readerState=value;placement.readY=value.y
        if readerVisible && !suspended {if indexed{attachReader()}else{loadIndex()}}
    }
    var transferPlacement: CanvasPlacement {
        var value = placement; value.readY = readerState.y; return value
    }
    func applyTransfer(_ value: CanvasPlacement) {
        releaseReader(); placement = value
        readerState = CanvasReaderState(); readerState.y = max(0, value.readY ?? 0)
        setFrameOrigin(NSPoint(x:value.x,y:value.y)); updateExpansion()
        if readerVisible && !suspended { if indexed { attachReader() } else { loadIndex() } }
    }
    func applySharedGeometry(_ value:CanvasPlacement) {
        let expandedChanged=placement.expanded != value.expanded
        var next=value;next.readY=readerState.y;placement=next
        setFrameOrigin(NSPoint(x:value.x,y:value.y))
        if expandedChanged {updateExpansion()} else {setFrameSize(NSSize(width:value.width,height:value.expanded ? value.height : 54));needsLayout=true}
    }
    func makeDragSource(origin: ChatDragOrigin) -> ChatDragSource {
        let source = ChatDragSource(chatID: placement.id, origin: origin)
        source.placement = transferPlacement
        return source
    }
    func beginTransfer(_ source: ChatDragSource, event: NSEvent) {
        source.begin(from: self, event: event, title: chat?.title ?? placement.id, project: chat?.project.name ?? "", ink: ink, paper: paper)
    }
    func useStandaloneControls() { remove.setAccessibilityLabel("Close chat window") }
    func place(at point: NSPoint, expand: Bool = true) {
        placement.x = point.x; placement.y = point.y; placement.expanded = placement.expanded || expand
        setFrameOrigin(point); updateExpansion()
    }
    @objc private func removeCard() { onRemove?() }
    @objc private func reload() {resources.invalidate(chatID:placement.id)}
    private func reloadLocal() {
        releaseReader(); indexed = false; references = []; failures = [:]
        readerState.heights = [:]; readerState.hasAnchor = false
        if readerVisible { loadIndex() }
    }
    func suspend() { suspended = true;setReaderVisible(false);releaseReader(); references = []; indexed = false }
    func resume() { suspended = false }
    func setReaderVisible(_ visible:Bool,priority:Int = 0,focused:Bool = false) {
        wantsReader=visible && !suspended && placement.expanded
        guard let readerAdmission else{return}
        resources.readers.update(readerAdmission,wantsVisible:wantsReader,priority:priority,focused:focused)
        if visible && !resources.readers.isAdmitted(readerAdmission) { readerHint.stringValue="Reader waiting for a visible-window slot. Focus this window to read." }
    }
    private func applyReaderAdmission(_ visible: Bool) {
        readerVisible = visible
        guard visible, !suspended, placement.expanded else {
            if reader != nil || reading {releaseReader()}
            if wantsReader{readerHint.stringValue="Reader deferred to keep other windows responsive. Select this card's header to read."}
            return
        }
        if indexed { attachReader() } else if !reading { loadIndex() }
    }
    private func releaseReader() {
        reader?.close(); reader?.removeFromSuperview(); reader = nil
        readerHint.isHidden = false
        placement.readY = readerState.y
        cancellation.cancel(); cancellation = HistoryCancellation(); reading = false; generation = UUID(); pending.removeAll()
    }
    private func attachReader() {
        guard reader == nil, readerVisible, !suspended, placement.expanded else { return }
        let view = CanvasMarkdownView(chatID:placement.id,dark:dark,green:green,state:readerState)
        view.onNeed = { [weak self] indices in indices.forEach { self?.requestMessage($0) } }
        view.onState = { [weak self] value in self?.readerState = value; self?.placement.readY = value.y }
        view.onFailure = { [weak self] message in self?.status.stringValue = message }
        reader = view; view.frame = readerHost.bounds; readerHint.isHidden = true; readerHost.addSubview(view)
        view.layoutSubtreeIfNeeded()
        view.setRows(preparedRows)
    }

    private func loadIndex() {
        guard !suspended, !reading, let chat, let snapshot else { status.stringValue = "Source chat unavailable"; return }
        cancellation.cancel(); cancellation = HistoryCancellation(); generation = UUID(); reading = true
        let cancel = cancellation, request = generation, source = HistoryStore.source(for: snapshot)
        let resources=self.resources
        let chats = Dictionary(snapshot.chats.map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        status.stringValue = "READING MESSAGE INDEX…"
        let operation = ExplorerDiagnostics.begin("canvas.index", ["chat_id": .text(chat.id)])
        queue.async { [weak self] in
            ExplorerDiagnostics.event("canvas.queue.start", operation: operation?.id, ["queue_wait_ms": .number(operation?.elapsedMS ?? 0)])
            let result = Result { try resources.index(chat:chat,chats:chats,source:source,revision:snapshot.observedAt,cancellation:cancel) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request, !cancel.cancelled else { ExplorerDiagnostics.end("canvas.index", operation, ["outcome": .text("discarded")]); return }
                defer { ExplorerDiagnostics.end("canvas.index", operation, ["messages": .integer(Int64(self.references.count))]) }
                self.reading = false
                switch result {
                case .success(let prepared):
                    let value=prepared.index;self.preparedRows=prepared.rows
                    self.references = value.messages; self.indexed = true
                    self.status.stringValue = (value.messages.isEmpty ? "NO INDEXED INPUTS / FINAL REPLIES AVAILABLE" : "\(value.messages.count) MESSAGES · INPUTS + FINAL REPLIES") + (value.issues.isEmpty ? "" : " · INCOMPLETE: \(value.issues.joined(separator: "; "))")
                    self.status.setAccessibilityHelp(value.issues.joined(separator: "\n"))
                case .failure(let error): self.status.stringValue = "UNAVAILABLE · \(error.localizedDescription)"; ExplorerDiagnostics.event("canvas.index.error", operation: operation?.id, ExplorerDiagnostics.error(error))
                }
                self.attachReader()
            }
        }
    }
    private func requestMessage(_ row: Int) {
        guard !suspended, readerVisible, placement.expanded, references.indices.contains(row), let snapshot else { return }
        let ref = references[row]
        if let saved = cache.object(forKey:ref.key as NSString) { ExplorerDiagnostics.event("canvas.cache.hit", ["chat_id": .text(ref.chatID), "ordinal": .integer(ref.ordinal)]); reader?.setMessage(row,html:saved.html); return }
        if let failure = failures[ref.key] { reader?.setMessage(row,html:CanvasMarkdown.html(failure)); return }
        guard pending.insert(ref.key).inserted else { ExplorerDiagnostics.event("canvas.queue.coalesced"); return }
        let operation = ExplorerDiagnostics.begin("canvas.message", ["chat_id": .text(ref.chatID), "ordinal": .integer(ref.ordinal), "cache_hit": .flag(false), "pending": .integer(Int64(pending.count))])
        let cancel = cancellation, request = generation, source = HistoryStore.source(for: snapshot)
        let cache=self.cache
        queue.async { [weak self] in
            guard !cancel.cancelled else { ExplorerDiagnostics.end("canvas.message", operation, ["outcome": .text("cancelled_before_read")]); return }
            ExplorerDiagnostics.event("canvas.queue.start", operation: operation?.id, ["queue_wait_ms": .number(operation?.elapsedMS ?? 0)])
            let result = Result {
                if let saved=cache.object(forKey:ref.key as NSString) {return saved}
                let read = ExplorerDiagnostics.begin("canvas.message.read", ["parent_operation": operation.map { .text($0.id) } ?? .null])
                let value: RecordedMessage
                do { value = try HistoryStore.full(chatID:ref.chatID,ordinal:ref.ordinal,source:source,cancellation:cancel); ExplorerDiagnostics.end("canvas.message.read", read) }
                catch { ExplorerDiagnostics.end("canvas.message.read", read, ExplorerDiagnostics.error(error)); throw error }
                guard !cancel.cancelled else { throw StoreError(message:"Read cancelled.") }
                let render = ExplorerDiagnostics.begin("canvas.html.prepare", ["parent_operation": operation.map { .text($0.id) } ?? .null])
                let box = CanvasMessageBox(value,html:CanvasMarkdown.html(value))
                ExplorerDiagnostics.end("canvas.html.prepare", render, ["html_bytes": .integer(Int64(box.html.utf8.count))])
                cache.setObject(box,forKey:ref.key as NSString,cost:max(ref.bytes,box.message.text.utf8.count)+box.html.utf8.count*2)
                return box
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request, !cancel.cancelled else { ExplorerDiagnostics.end("canvas.message", operation, ["outcome": .text("discarded")]); return }
                defer { ExplorerDiagnostics.end("canvas.message", operation, ["pending": .integer(Int64(self.pending.count))]) }
                self.pending.remove(ref.key)
                switch result {
                case .success(let value):
                    self.cache.setObject(value,forKey:ref.key as NSString,cost:max(ref.bytes,value.message.text.utf8.count)+value.html.utf8.count*2)
                    self.reader?.setMessage(row,html:value.html)
                case .failure(let error):
                    ExplorerDiagnostics.event("canvas.message.error", operation: operation?.id, ExplorerDiagnostics.error(error))
                    let failure = "UNAVAILABLE · \(error.localizedDescription)"
                    self.failures[ref.key] = failure; self.reader?.setMessage(row,html:CanvasMarkdown.html(failure))
                }
            }
        }
    }
    func track(_ event: NSEvent, resize: Bool) {
        if !resize { onMove?(self,event); return }
        if let onWindowResize { onWindowResize(event); return }
        guard let parent = superview, let window else { return }
        parent.addSubview(self, positioned:.above,relativeTo:nil)
        let start = parent.convert(event.locationInWindow,from:nil), original = frame
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let p = parent.convert(next.locationInWindow,from:nil), dx = p.x-start.x, dy = p.y-start.y
            if resize {
                placement.width = Double(min(3000,max(300,original.width+dx))); placement.height = Double(min(10000,max(220,original.height+dy)))
                setFrameSize(NSSize(width:placement.width,height:placement.height)); needsLayout = true; layoutSubtreeIfNeeded()
            } else { setFrameOrigin(NSPoint(x:original.minX+dx,y:original.minY+dy)); placement.x = frame.minX; placement.y = frame.minY }
        }
        onChange?()
    }
}

/// Explorer supplies theme and chat acceptance; canvas input mechanics live in WindowingKit.
private final class CanvasSurface: WorkspaceCanvasSurface {
    var dark = true { didSet { updateColors() } }
    var green = false { didSet { updateColors() } }
    var canDropChat: ((String) -> Bool)?
    var onDropChat: ((ChatDragSource, NSPoint) -> Bool)?
    var onWindowTransfer: ((WindowTransferSource, NSPoint) -> Bool)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        dropOperation = { [weak self] sender in
            if WindowTransferPayload.read(sender) != nil { return .move }
            guard let payload = ChatDragPayload.read(sender), self?.canDropChat?(payload.chatID) == true else { return [] }
            return (sender.draggingSource as? ChatDragSource)?.preferredOperation ?? []
        }
        onDrop = { [weak self] sender, point in
            if WindowTransferPayload.read(sender) != nil, let source = sender.draggingSource as? WindowTransferSource {
                return self?.onWindowTransfer?(source, point) ?? false
            }
            guard ChatDragPayload.read(sender) != nil, let source = sender.draggingSource as? ChatDragSource,
                  self?.onDropChat?(source, point) == true else { return false }
            source.accept(.canvas); return true
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func updateColors() {
        backgroundColor = AppTheme.palette(dark: dark, green: green).canvas
        gridColor = NativePalette.adjust(AppTheme.muted(dark: dark, green: green), against: backgroundColor).withAlphaComponent(0.2)
        selectionColor = AppTheme.ink(dark: dark, green: green)
    }
}

final class ChatCanvasRoot: NSView, CanvasZoomCommands {
    override var isFlipped: Bool { true }
    var onChange: (([CanvasPlacement]) -> Void)?
    var onGeometryChanges:(([CanvasPlacement])->Void)?
    var onRemove: ((String) -> Void)?
    var onDetachChat: ((String, CanvasPlacement, NSPoint) -> Bool)?
    var onExplorer: (() -> Void)?
    var onDuplicateChat:((String)->Void)?
    var onChatTransfer:((CanvasPlacement,NSView,NSEvent)->Void)?
    var onWindowTransfer:((WindowTransferSource,NSPoint)->Bool)?
    var onRebase:((CGFloat,CGFloat)->Void)?
    var canvasTitle="Canvas"
    var canvasIssue:String?
    var canvasID=CanvasDocumentStore.primaryID
    var canvasViewID=UUID().uuidString
    private(set) var explorerPanels=[String:CanvasExplorerPanel]()
    var explorerPanel:CanvasExplorerPanel? { focusedExplorerID.flatMap{explorerPanels[$0]} ?? explorerPanels.values.first }
    private var focusedExplorerID:String?
    private var explorerPlaceholders=[String:NSView]()
    private var lastExplorerFrame: NSRect?
    private var explorerFocused = false
    var focusedExplorer: ChatRootView? { explorerFocused && explorerPanel?.isCollapsed == false ? explorerPanel?.explorer : nil }
    private var transferSource: ChatDragSource?
    private let scroll = NSScrollView(), surface = CanvasSurface()
    private let close = NSButton(), minimize = NSButton(), fullScreen = NSButton(), home = NSButton(), zoomOut = NSButton(), zoomIn = NSButton(), explorerButton = NSButton()
    private let selectionInfo = NSTextField(labelWithString: "")
    private var markedIDs = Set<String>(), boxBaseIDs = Set<String>()
    private var cards = [String: CanvasChatCard]()
    private var stored: [CanvasPlacement]
    private var snapshot: ChatSnapshot?
    private var knownChatIDs = Set<String>()
    var layoutSnapshot: [CanvasPlacement] { cards.values.map(\.placement).sorted { $0.id < $1.id } }
    private let resources:SharedCanvasResources
    private var dark = true, green = false, centered = false, normalizing = false
    private var boundsObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var suspended = false
    private var ink: NSColor { AppTheme.ink(dark:dark,green:green) }
    init(frame:NSRect,placements:[CanvasPlacement],resources:SharedCanvasResources = SharedCanvasResources()) {
        self.resources=resources;stored=placements;super.init(frame:frame)
        surface.frame = NSRect(x:0,y:0,width:max(24576,(placements.map { $0.x+$0.width }.max() ?? 0)+4096),height:max(24576,(placements.map { $0.y+$0.height }.max() ?? 0)+4096))
        surface.registerForDraggedTypes([ChatDragPayload.type,WindowTransferPayload.type])
        surface.canDropChat = { [weak self] id in self?.knownChatIDs.contains(id) == true }
        surface.onDropChat = { [weak self] source, point in
            self?.dropChat(source.chatID, at: point, placement: source.placement, replacingExisting: source.origin == .window) ?? false
        }
        surface.onWindowTransfer={ [weak self] source,point in self?.onWindowTransfer?(source,point) ?? false }
        scroll.documentView = surface; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay; scroll.allowsMagnification = true; scroll.minMagnification = 0.5; scroll.maxMagnification = 2.5
        addSubview(scroll)
        selectionInfo.font = .monospacedSystemFont(ofSize:10,weight:.regular)
        selectionInfo.setAccessibilityLabel("Canvas card selection")
        addSubview(selectionInfo)
        surface.onClearSelection = { [weak self] in self?.markedIDs.removeAll(); self?.updateCardSelection() }
        surface.onSelectAll = { [weak self] in
            guard let self else { return }; self.markedIDs = Set(self.cards.keys); self.updateCardSelection()
        }
        surface.onBeginBox = { [weak self] in self?.boxBaseIDs = self?.markedIDs ?? [] }
        surface.onBoxSelection = { [weak self] rect in
            guard let self else { return }
            self.markedIDs = self.boxBaseIDs.union(self.cards.values.filter { $0.frame.intersects(rect) }.map { $0.placement.presentationID })
            self.updateCardSelection()
        }
        for (button,title,action) in [(close,"×",#selector(closeWindow)),(minimize,"−",#selector(minimizeWindow)),(fullScreen,"",#selector(toggleFullScreen)),(home,"HOME",#selector(goHome)),(explorerButton,"EXPLORER",#selector(showExplorer)),(zoomOut,"−",#selector(smaller)),(zoomIn,"+",#selector(larger))] {
            button.title = title; button.target = self; button.action = action; button.isBordered = false; button.focusRingType = .none; addSubview(button)
        }
        close.setAccessibilityLabel("Close canvas window"); minimize.setAccessibilityLabel("Minimize canvas window")
        fullScreen.setAccessibilityLabel("Toggle canvas full screen")
        fullScreen.toolTip = "Toggle full screen (⌃⌘F)"
        explorerButton.setAccessibilityLabel("Show Explorer inside canvas"); explorerButton.toolTip = "Bring the full Explorer into this canvas"
        home.setAccessibilityLabel("Return to canvas contents"); zoomOut.setAccessibilityLabel("Zoom canvas out"); zoomIn.setAccessibilityLabel("Zoom canvas in")
        scroll.contentView.postsBoundsChangedNotifications = true
        surface.onPanEnd = { [weak self] in self?.extendPlane() }
        boundsObserver = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in
            self?.extendPlane(); self?.updateReaders()
            if let self, ExplorerDiagnostics.shared.admit("canvas.viewport") {
                var fields = ExplorerDiagnostics.rect(self.scroll.contentView.bounds, prefix: "viewport")
                fields["zoom"] = .number(self.scroll.magnification); fields["cards"] = .integer(Int64(self.cards.count))
                ExplorerDiagnostics.event("canvas.viewport", fields)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main) { [weak self] _ in self?.updateReaders() }
    }
    private func updateReaders() {
        let visible = scroll.documentVisibleRect.insetBy(dx:-180,dy:-180)
        let enabled = !suspended && window?.occlusionState.contains(.visible) == true
        // A pile of overlapping cards must not create an unbounded WebKit population.
        let active = Set(surface.subviews.reversed().compactMap { $0 as? CanvasChatCard }.filter { enabled && $0.placement.expanded && $0.frame.intersects(visible) }.map { $0.placement.presentationID })
        let priority=Dictionary(uniqueKeysWithValues:surface.subviews.reversed().compactMap{$0 as? CanvasChatCard}.enumerated().map{($0.element.placement.presentationID,10000-$0.offset)})
        resources.readers.performBatchUpdates {for (id,card) in cards {card.setReaderVisible(active.contains(id),priority:priority[id] ?? 0)}}
    }
    func update(_ snapshot:ChatSnapshot,placements:[CanvasPlacement]) {
        let metadataChanged=self.snapshot?.observedAt != snapshot.observedAt || self.snapshot?.sourceURL != snapshot.sourceURL
        self.snapshot=snapshot;if metadataChanged{knownChatIDs=Set(snapshot.chats.map(\.id))}
        let previous=Dictionary(stored.map{($0.presentationID,$0)},uniquingKeysWith:{first,_ in first})
        stored=placements;let selected=Set(placements.map(\.presentationID))
        for id in Array(cards.keys) where !selected.contains(id) {if let card=cards.removeValue(forKey:id){card.suspend();card.removeFromSuperview()}}
        for placement in placements {
            let id=placement.presentationID
            if cards[id]==nil {
                let card=CanvasChatCard(placement:placement,resources:resources)
                card.onChange={ [weak self] in self?.publish() }
                card.onRemove={ [weak self] in self?.onRemove?(id) }
                card.onDuplicate={ [weak self] in self?.onDuplicateChat?(id) }
                card.onMove={ [weak self] card,event in self?.trackCards(card,event:event) }
                card.setTheme(dark:dark,green:green);card.update(snapshot)
                cards[id]=card
                if let explorerPanel{surface.addSubview(card,positioned:.below,relativeTo:explorerPanel)}else{surface.addSubview(card)}
            } else if previous[id].map({!Self.sameGeometry($0,placement)}) ?? true {cards[id]?.applySharedGeometry(placement)}
        }
        if metadataChanged{for card in cards.values {card.update(snapshot)}}
        markedIDs.formIntersection(selected);updateCardSelection();updateReaders();needsDisplay=true
    }
    private static func sameGeometry(_ a:CanvasPlacement,_ b:CanvasPlacement)->Bool {var a=a,b=b;a.readY=nil;b.readY=nil;return a==b}
    func chatPlacement(_ instance:String)->CanvasPlacement? {cards[instance]?.transferPlacement}
    var viewportState:(NSPoint,CGFloat) {(scroll.contentView.bounds.origin,scroll.magnification)}
    func restoreViewport(_ value:(NSPoint,CGFloat)) {centered=true;scroll.setMagnification(value.1,centeredAt:value.0);scroll.contentView.scroll(to:value.0);scroll.reflectScrolledClipView(scroll.contentView)}
    func chatReadingState(_ instance:String)->CanvasReaderState? {cards[instance]?.readingState}
    func restoreChatReadingState(_ instance:String,_ state:CanvasReaderState) {cards[instance]?.restoreReadingState(state)}
    func copyReaderLocations(from other:ChatCanvasRoot) {for (id,card) in cards {if let value=other.chatReadingState(id){card.restoreReadingState(value)}}}
    @discardableResult func dropChat(_ id:String,at point:NSPoint,placement:CanvasPlacement? = nil,replacingExisting:Bool = false)->Bool {
        guard let snapshot,knownChatIDs.contains(id),point.x.isFinite,point.y.isFinite,(0...100_000_000).contains(point.x),(0...100_000_000).contains(point.y),placement.map({$0.id==id && $0.isValidTransfer}) ?? true else{return false}
        let key=placement?.instanceID != nil ? placement?.presentationID : cards.values.first(where:{$0.placement.id==id})?.placement.presentationID ?? placement?.presentationID
        var incoming=placement ?? CanvasPlacement(id:id,x:point.x,y:point.y,width:448,height:520,expanded:true)
        incoming.x=point.x;incoming.y=point.y
        if let key,let card=cards[key] {if replacingExisting {if incoming.instanceID==nil{incoming.instanceID=card.placement.instanceID};card.applyTransfer(incoming)}else{card.place(at:point,expand:placement?.expanded ?? true)};markedIDs=[key]}
        else {if placement==nil && incoming.instanceID==nil{incoming.instanceID=UUID().uuidString};update(snapshot,placements:layoutSnapshot+[incoming]);markedIDs=[incoming.presentationID];onGeometryChanges?([incoming])}
        updateCardSelection();publish();return true
    }
    private func publish() {
        let values=layoutSnapshot,prior=Dictionary(stored.map{($0.presentationID,$0)},uniquingKeysWith:{first,_ in first})
        let changed=values.filter{value in prior[value.presentationID].map{!Self.sameGeometry($0,value)} ?? true}
        stored=values;if !changed.isEmpty{onGeometryChanges?(changed)};onChange?(values);extendPlane();updateReaders()
    }
    private func updateCardSelection() {
        for (id,card) in cards { card.isCanvasSelected = markedIDs.contains(id) }
        selectionInfo.stringValue = "\(markedIDs.count) OF \(cards.count) CARDS SELECTED"
    }
    private func trackCards(_ card: CanvasChatCard, event: NSEvent) {
        guard let window else { return }
        card.setReaderVisible(true,priority:10001,focused:true)
        let id = card.placement.presentationID, previousSelection = markedIDs
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        let dragIDs = markedIDs.contains(id) ? markedIDs : (command || shift ? markedIDs.union([id]) : [id])
        window.makeFirstResponder(surface)
        let start = surface.convert(event.locationInWindow,from:nil)
        let originals = Dictionary(uniqueKeysWithValues:dragIDs.compactMap { id in cards[id].map { (id,$0.frame.origin) } })
        var moved = false
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let p = surface.convert(next.locationInWindow,from:nil)
            if !moved && hypot(p.x-start.x,p.y-start.y) < 5 { continue }
            moved = true; markedIDs = dragIDs; updateCardSelection()
            let screenPoint = window.convertPoint(toScreen: next.locationInWindow)
            let hit = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            if !window.frame.contains(screenPoint) || (hit != 0 && hit != window.windowNumber) {
                // Restore the temporary in-canvas movement before handing control
                // to AppKit; failed/cancelled transfers must leave no layout edit.
                for (key,origin) in originals {
                    cards[key]?.setFrameOrigin(origin); cards[key]?.placement.x = origin.x; cards[key]?.placement.y = origin.y
                }
                if let onChatTransfer {onChatTransfer(card.transferPlacement,card,next);updateReaders();return}
                let source = card.makeDragSource(origin: .canvas)
                transferSource = source
                source.onFinished = { [weak self] finished in
                    if self?.transferSource === finished { self?.transferSource = nil }
                }
                source.onCancelled = { [weak self] in self?.markedIDs = previousSelection; self?.updateCardSelection(); self?.updateReaders() }
                source.onAccepted = { [weak self] destination in if destination == .date { self?.onRemove?(id) } }
                let outgoing = source.placement
                source.onDesktopDrop = { [weak self] _, point in
                    guard let self, let placement = outgoing, self.onDetachChat?(card.placement.id, placement, point) == true else { return }
                    self.onRemove?(id)
                }
                updateReaders(); card.beginTransfer(source, event: next)
                return
            }
            for (key,origin) in originals {
                guard let moving = cards[key] else { continue }
                moving.setFrameOrigin(NSPoint(x:origin.x+p.x-start.x,y:origin.y+p.y-start.y))
                moving.placement.x = moving.frame.minX; moving.placement.y = moving.frame.minY
            }
        }
        if !moved {
            if command { if markedIDs.remove(id) == nil { markedIDs.insert(id) } }
            else if shift { markedIDs.insert(id) }
            else { markedIDs = [id] }
        }
        updateCardSelection()
        if moved { publish() }
        updateReaders()
    }
    func setTheme(dark: Bool, green: Bool) {
        self.dark = dark; self.green = green; surface.dark = dark; surface.green = green; surface.needsDisplay = true
        selectionInfo.textColor = AppTheme.muted(dark:dark,green:green)
        for card in cards.values { card.setTheme(dark:dark,green:green) }
        for button in [close,minimize,fullScreen,home,zoomOut,zoomIn,explorerButton] { button.attributedTitle = NSAttributedString(string:button.title,attributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.bold),.foregroundColor:ink]) }
        for panel in explorerPanels.values {panel.setTheme(dark:dark,green:green)}
        window?.backgroundColor = AppTheme.background(dark:dark); needsDisplay = true
    }
    func suspend() { suspended = true; for card in cards.values { card.suspend() }; publish() }
    func resume() { suspended = false; for card in cards.values { card.resume() }; if !centered { goHome() }; updateReaders() }
    override func layout() {
        super.layout()
        close.frame = NSRect(x:12,y:9,width:20,height:20); minimize.frame = NSRect(x:38,y:9,width:20,height:20)
        fullScreen.frame = NSRect(x:64,y:9,width:20,height:20)
        selectionInfo.frame = NSRect(x:250,y:12,width:max(1,min(280,bounds.width-540)),height:18)
        explorerButton.frame = NSRect(x:bounds.width-272,y:9,width:92,height:20)
        home.frame = NSRect(x:bounds.width-170,y:9,width:60,height:20)
        zoomOut.frame = NSRect(x:bounds.width-100,y:9,width:32,height:20); zoomIn.frame = NSRect(x:bounds.width-60,y:9,width:32,height:20)
        scroll.frame = NSRect(x:1,y:63,width:bounds.width-2,height:max(1,bounds.height-64))
        if !centered && window != nil { goHome() }
        updateReaders()
    }
    override func draw(_ dirtyRect: NSRect) {
        (AppTheme.background(dark:dark)).setFill(); bounds.fill(); AppTheme.border(dark:dark,green:green).setStroke(); NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5)).stroke()
        label(canvasTitle.uppercased(),in:NSRect(x:98,y:11,width:148,height:20),size:13,weight:.bold,color:ink)
        label(canvasIssue ?? "⌘-CLICK CHAT HEADERS TO MULTI-SELECT · SHIFT-DRAG BACKGROUND TO BOX-SELECT · DRAG BACKGROUND TO PAN · ESC CLEARS CARD SELECTION",in:NSRect(x:16,y:39,width:bounds.width-32,height:16),size:9,color:AppTheme.muted(dark:dark,green:green))
        line(from:NSPoint(x:0,y:62.5),to:NSPoint(x:bounds.width,y:62.5),color:AppTheme.border(dark:dark,green:green))
        let corners = fullScreen.frame.insetBy(dx:5,dy:5)
        for (x,y,dx,dy): (CGFloat,CGFloat,CGFloat,CGFloat) in [(corners.minX,corners.minY,3,3),(corners.maxX,corners.minY,-3,3),(corners.minX,corners.maxY,3,-3),(corners.maxX,corners.maxY,-3,-3)] {
            line(from:NSPoint(x:x,y:y),to:NSPoint(x:x+dx,y:y),color:ink)
            line(from:NSPoint(x:x,y:y),to:NSPoint(x:x,y:y+dy),color:ink)
        }
        AppTheme.border(dark:dark,green:green).setStroke()
        for button in [close,minimize,fullScreen,home,zoomOut,zoomIn,explorerButton] { NSBezierPath(rect:button.frame.insetBy(dx:0.5,dy:0.5)).stroke() }
    }
    override func mouseDown(with event: NSEvent) { if convert(event.locationInWindow,from:nil).y < 36 { window?.performDrag(with:event) } }
    @objc private func closeWindow() { window?.close() }
    @objc private func toggleFullScreen() { window?.toggleFullScreen(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func goHome() {
        centered = true
        let positions = cards.values.map(\.frame.origin) + explorerPanels.values.map(\.frame.origin)
        let x = positions.map(\.x).min() ?? stored.map({CGFloat($0.x)}).min() ?? 12312, y = positions.map(\.y).min() ?? stored.map({CGFloat($0.y)}).min() ?? 12312
        scroll.contentView.scroll(to:NSPoint(x:max(0,x-24),y:max(0,y-24))); scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func smaller() { zoom(-0.15) }
    @objc private func larger() { zoom(0.15) }
    private func zoom(_ amount: CGFloat) { scroll.setMagnification(max(0.5,min(2.5,scroll.magnification+amount)),centeredAt:scroll.contentView.bounds.origin) }
    func adjustCanvasZoom(_ delta: CGFloat) { if let focusedExplorer { focusedExplorer.adjustTextSize(by:delta > 0 ? TextSizing.step : 1/TextSizing.step) } else { zoom(delta) } }
    func resetCanvasZoom() { if let focusedExplorer { focusedExplorer.resetTextSize() } else { scroll.setMagnification(1,centeredAt:scroll.contentView.bounds.origin) } }
    @objc private func showExplorer() { if explorerPanel != nil {revealExplorer()}else{onExplorer?()} }
    func noteMouseDown(_ point:NSPoint) {
        let p=surface.convert(point,from:nil)
        focusedExplorerID=surface.subviews.reversed().compactMap{$0 as? CanvasExplorerPanel}.first{$0.frame.contains(p)}?.id
        explorerFocused=focusedExplorerID != nil
    }
    func canvasPoint(fromScreen point:NSPoint)->NSPoint? {guard let window else{return nil};return surface.convert(window.convertPoint(fromScreen:point),from:nil)}
    var visibleCanvasRect:NSRect {scroll.documentVisibleRect}
    func showExplorerPlaceholder(_ value:ExplorerPanelPlacement) {
        if let existing=explorerPlaceholders[value.id]{existing.frame=value.frame;return}
        let box=NSView(frame:value.frame);box.wantsLayer=true;box.layer?.backgroundColor=AppTheme.background(dark:dark).cgColor;box.layer?.borderColor=AppTheme.border(dark:dark,green:green).cgColor;box.layer?.borderWidth=1
        let text=NSTextField(labelWithString:"Opening Explorer…");text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.textColor=ink;text.frame=NSRect(x:16,y:16,width:220,height:24);box.addSubview(text)
        explorerPlaceholders[value.id]=box;surface.addSubview(box)
    }
    func removeExplorerPlaceholder(_ id:String) {explorerPlaceholders.removeValue(forKey:id)?.removeFromSuperview()}
    func pruneExplorerPlaceholders(_ valid:Set<String>) {for id in Array(explorerPlaceholders.keys) where !valid.contains(id){removeExplorerPlaceholder(id)}}
    func installExplorer(_ explorer:ChatRootView,id:String? = nil,frame:NSRect? = nil,reveal:Bool = true,popOut:@escaping()->Void,dismiss:@escaping()->Void) {
        let id=id ?? explorer.windowInstanceID
        removeExplorerPlaceholder(id)
        if explorerPanels[id] != nil {if reveal{revealExplorer(id)};return}
        let visible=scroll.documentVisibleRect
        let size=NSSize(width:max(CanvasExplorerPanel.explorerMinimumSize.width,explorer.bounds.width+2),height:max(CanvasExplorerPanel.explorerMinimumSize.height,explorer.bounds.height+50))
        let frame=frame ?? lastExplorerFrame ?? NSRect(origin:NSPoint(x:visible.minX+24,y:visible.minY+24),size:size)
        let panel=CanvasExplorerPanel(explorer:explorer,frame:frame,id:id)
        panel.onPopOut=popOut;panel.onDismiss=dismiss
        panel.onFocus={ [weak self] in self?.focusedExplorerID=id;self?.explorerFocused=true }
        panel.onGeometry={ [weak self,weak panel] in self?.lastExplorerFrame=panel?.expandedFrame;self?.extendPlane() }
        explorerPanels[id]=panel;if reveal{focusedExplorerID=id};surface.addSubview(panel);panel.setTheme(dark:dark,green:green)
        panel.needsLayout=true;panel.layoutSubtreeIfNeeded();extendPlane();if reveal{revealExplorer(id)}
    }
    func revealExplorer(_ id:String? = nil) {
        if let id {focusedExplorerID=id}
        guard let panel=explorerPanel else{return}
        panel.setCollapsed(false);explorerFocused=true
        surface.addSubview(panel,positioned:.above,relativeTo:nil)
        let width=scroll.contentSize.width-48,height=scroll.contentSize.height-48
        let scale=max(scroll.minMagnification,min(scroll.magnification,width/panel.frame.width,height/panel.frame.height))
        scroll.setMagnification(scale,centeredAt:panel.frame.origin)
        scroll.contentView.scroll(to:NSPoint(x:max(0,panel.frame.minX-24),y:max(0,panel.frame.minY-24)))
        scroll.reflectScrolledClipView(scroll.contentView);extendPlane()
    }
    func removeExplorer(_ requested:String? = nil) {
        guard let panel=requested.flatMap({explorerPanels[$0]}) ?? explorerPanel else{return}
        lastExplorerFrame=panel.expandedFrame;panel.explorer.isHidden=false
        panel.explorer.canvasExplorerPanel=nil;panel.explorer.removeFromSuperview();panel.removeFromSuperview()
        explorerPanels.removeValue(forKey:panel.id)
        if focusedExplorerID==panel.id{focusedExplorerID=explorerPanels.keys.first};explorerFocused=false
    }
    func homeToContents() {goHome();extendPlane()}
    func restoreRebasedViewport(_ old:(NSPoint,CGFloat),dx:CGFloat,dy:CGFloat) {
        let was=normalizing;normalizing=true;defer{normalizing=was}
        surface.setFrameSize(NSSize(width:max(surface.frame.width+dx,(cards.values.map(\.frame.maxX).max() ?? 0)+2048,(explorerPanels.values.map(\.frame.maxX).max() ?? 0)+2048),height:max(surface.frame.height+dy,(cards.values.map(\.frame.maxY).max() ?? 0)+2048,(explorerPanels.values.map(\.frame.maxY).max() ?? 0)+2048)))
        restoreViewport((NSPoint(x:old.0.x+dx,y:old.0.y+dy),old.1))
    }
    private func extendPlane() {
        guard centered, !normalizing, !surface.isPanning else { return }; normalizing = true; defer { normalizing = false }
        let visible = scroll.contentView.bounds, step: CGFloat = 12288
        let dx: CGFloat = visible.minX < 2048 ? step : 0, dy: CGFloat = visible.minY < 2048 ? step : 0
        var size = surface.frame.size
        size.width += dx + (visible.maxX > size.width-2048 ? step : 0)
        size.height += dy + (visible.maxY > size.height-2048 ? step : 0)
        size.width = max(size.width,(cards.values.map(\.frame.maxX).max() ?? 0)+2048,(explorerPanels.values.map(\.frame.maxX).max() ?? 0)+2048)
        size.height = max(size.height,(cards.values.map(\.frame.maxY).max() ?? 0)+2048,(explorerPanels.values.map(\.frame.maxY).max() ?? 0)+2048)
        if size != surface.frame.size { surface.setFrameSize(size) }
        if dx != 0 || dy != 0 {
            if let onRebase{onRebase(dx,dy);return}
            for panel in explorerPanels.values {panel.setFrameOrigin(NSPoint(x:panel.frame.minX+dx,y:panel.frame.minY+dy));panel.onGeometry?()}
            if let frame=lastExplorerFrame { lastExplorerFrame=frame.offsetBy(dx:dx,dy:dy) }
            for card in cards.values {
                card.setFrameOrigin(NSPoint(x:card.frame.minX+dx,y:card.frame.minY+dy))
                card.placement.x = card.frame.minX; card.placement.y = card.frame.minY
            }
            scroll.contentView.scroll(to:NSPoint(x:visible.minX+dx,y:visible.minY+dy)); scroll.reflectScrolledClipView(scroll.contentView)
            stored = cards.values.map(\.placement); onChange?(stored)
        }
    }
}


/// A single canvas card hosted directly in a native window, with the same reader.
final class DetachedChatController {
    let id=UUID().uuidString
    let window: ChatWindow
    private let card: CanvasChatCard
    private var observers = [NSObjectProtocol]()
    private var changingFrame = false
    private var transferring = false
    private var transferSource: ChatDragSource?
    var onClose: (() -> Void)?
    var onDuplicate:(()->Void)?
    var onTransfer:((DetachedChatController,NSView,NSEvent)->Void)?
    private var duplicateAction:DuplicateWindowAction!
    var placement:CanvasPlacement {card.transferPlacement}
    var readingState:CanvasReaderState {card.readingState}
    func restoreReadingState(_ value:CanvasReaderState) {card.restoreReadingState(value)}

    init(chatID: String, snapshot: ChatSnapshot, resources:SharedCanvasResources, dark: Bool, green: Bool, placement incoming: CanvasPlacement? = nil) {
        var placement = incoming ?? CanvasPlacement(id: chatID, x: 0, y: 0, width: 448, height: 620, expanded: true)
        placement.x = 0; placement.y = 0
        card = CanvasChatCard(placement:placement,resources:resources)
        window = ChatWindow(contentSize: NSSize(width: placement.width, height: placement.expanded ? placement.height : 54))
        window.minSize = NSSize(width: 300, height: placement.expanded ? 220 : 54)
        window.maxSize = NSSize(width:3000,height:placement.expanded ? 10000 : 54)
        window.contentView = card
        card.useStandaloneControls()
        duplicateAction=DuplicateWindowAction { [weak self] in self?.onDuplicate?() }
        window.duplicateWindowAction=duplicateAction
        card.onDuplicate={ [weak self] in self?.onDuplicate?() }
        card.onMove = { [weak self] _, event in self?.trackTransfer(event) }
        card.onWindowResize = { [weak self] event in self?.resizeWindow(event) }
        card.onRemove = { [weak self] in self?.window.close() }
        card.onChange = { [weak self] in self?.fitWindowToCard() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.card.suspend(); self?.onClose?()
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in self?.windowResized() })
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateReaderVisibility() })
        }
        setTheme(dark: dark, green: green); update(snapshot)
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        card.suspend()
    }
    func update(_ snapshot: ChatSnapshot) {
        card.update(snapshot)
        window.title = (snapshot.chats.first { $0.id == card.placement.id }?.title ?? "Chat unavailable") + " — Codex Chat Explorer"
    }
    func setTheme(dark: Bool, green: Bool) {
        card.setTheme(dark: dark, green: green)
        window.backgroundColor = AppTheme.background(dark: dark)
    }
    func show(at point:NSPoint,activate:Bool = true) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.setFrame(ChatWindowDrop.frame(at: point, size: window.frame.size, visible: screen.visibleFrame), display: true)
        if activate{window.makeKeyAndOrderFront(nil)}; card.resume(); updateReaderVisibility()
    }
    func adopt(_ value: CanvasPlacement) {
        var value = value; value.x = 0; value.y = 0
        card.applyTransfer(value); fitWindowToCard()
    }
    private func trackTransfer(_ event: NSEvent) {
        if let onTransfer {onTransfer(self,card,event);return}
        let start = window.convertPoint(toScreen: event.locationInWindow), original = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            guard hypot(point.x-start.x,point.y-start.y) >= 5 else { continue }
            let source = card.makeDragSource(origin: .window)
            transferSource = source
            source.onStarted = { [weak self] in self?.transferring = true; self?.window.orderOut(nil) }
            source.onFinished = { [weak self] finished in
                    if self?.transferSource === finished { self?.transferSource = nil }
                }
            source.onAccepted = { [weak self] _ in self?.transferring = false; self?.window.close() }
            source.onCancelled = { [weak self] in
                guard let self else { return }
                self.transferring = false
                self.window.setFrame(original, display:true); self.window.makeKeyAndOrderFront(nil); self.card.resume(); self.updateReaderVisibility()
            }
            let anchor = NSPoint(x:start.x-original.minX,y:original.maxY-start.y)
            source.onDesktopDrop = { [weak self] _, point in self?.transferring = false; self?.show(at:NSPoint(x:point.x-anchor.x,y:point.y+anchor.y)) }
            card.beginTransfer(source,event:next)
            return
        }
    }
    func updateReaderVisibility() {
        guard !transferring else { return }
        card.setReaderVisible(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }
    func setTransferring(_ value:Bool) {transferring=value;window.ignoresMouseEvents=value;window.alphaValue=value ? 0 : 1;if value{card.setReaderVisible(false)}else{window.makeKeyAndOrderFront(nil);card.resume();updateReaderVisibility()}}
    private func windowResized() {
        guard !changingFrame else { return }
        card.placement.width = card.bounds.width
        if card.placement.expanded { card.placement.height = card.bounds.height }
        card.needsLayout = true; card.layoutSubtreeIfNeeded()
    }
    private func fitWindowToCard() {
        changingFrame = true; defer { changingFrame = false }
        let top = window.frame.maxY
        window.minSize = NSSize(width: 300, height: card.placement.expanded ? 220 : 54)
        window.maxSize = NSSize(width:3000,height:card.placement.expanded ? 10000 : 54)
        window.setContentSize(card.frame.size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        card.needsLayout = true; card.layoutSubtreeIfNeeded()
        updateReaderVisibility()
    }
    private func resizeWindow(_ event: NSEvent) {
        let original = window.frame, start = window.convertPoint(toScreen: event.locationInWindow)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            let width = max(300, min(3000, original.width + point.x - start.x))
            let height = max(220, min(10000, original.height - point.y + start.y))
            window.setFrame(NSRect(x: original.minX, y: original.maxY - height, width: width, height: height), display: true)
        }
    }
}
