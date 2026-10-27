import AppKit
import ModelSupport

final class LabelPane:NSView{
    override var isFlipped:Bool{true}
    var onChoose:((LabelProvider)->Void)?,onBack:(()->Void)?
    private let back=FlatActionButton(),local=FlatActionButton(),luna=FlatActionButton()
    private let title=NSTextField(labelWithString:""),info=NSTextField(wrappingLabelWithString:""),result=NSTextField(wrappingLabelWithString:"")
    private let scroll=NSScrollView(),preview=NSTextView()
    private var dark=false,green=false
    init(){
        super.init(frame:.zero)
        back.title="‹ BACK";local.title="LOCAL (DEFAULT)";luna.title="CODEX · LUNA"
        for (button,action) in [(back,#selector(goBack)),(local,#selector(chooseLocal)),(luna,#selector(chooseLuna))]{button.target=self;button.action=action;addSubview(button)}
        title.font = .monospacedSystemFont(ofSize:13,weight:.bold);title.lineBreakMode = .byTruncatingTail;addSubview(title)
        info.font = .monospacedSystemFont(ofSize:11,weight:.regular);addSubview(info)
        result.font = .monospacedSystemFont(ofSize:16,weight:.bold);result.isSelectable=true;addSubview(result)
        preview.isEditable=false;preview.isSelectable=true;preview.isRichText=false;preview.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        preview.textContainerInset=NSSize(width:12,height:12);preview.isVerticallyResizable=true;preview.autoresizingMask=[.width];preview.textContainer?.widthTracksTextView=true
        scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.documentView=preview;addSubview(scroll)
    }
    required init?(coder:NSCoder){fatalError("Not used")}
    func prepare(chat:Chat,existing:DerivedChatLabel?){
        title.stringValue=chat.title
        result.stringValue=existing.map{"Saved label: \($0.text)"} ?? ""
        info.stringValue="AI SUMMARY · Preparing bounded excerpts. The original chat title stays unchanged."
        preview.string="";local.isEnabled=false;luna.isEnabled=false;back.title="‹ BACK"
    }
    func ready(_ sample:LabelSample){
        info.stringValue="AI SUMMARY · Exactly five words · \(sample.sampledMessages) sampled excerpts from \(sample.totalMessages) indexed messages · \(sample.prompt.utf8.count)/\(LabelPolicy.maximumInputBytes) input bytes. Local uses the installed ~24 GB Qwen model and unloads it afterwards. Codex sends these excerpts to Luna at its lowest supported reasoning. One job, no tools, no retries. Leaving this panel stops the request."
        preview.string=sample.excerptPreview;local.isEnabled=true;luna.isEnabled=true
    }
    func busy(_ text:String){info.stringValue=text;local.isEnabled=false;luna.isEnabled=false;back.title="STOP"}
    func event(_ event:LabelWorkerEvent){
        if let message=event.message{info.stringValue=message}
        if let label=event.label{result.stringValue=label}
        if event.kind=="settled"{local.isEnabled=true;luna.isEnabled=true;back.title="‹ BACK"}
    }
    func failure(_ text:String){info.stringValue=text;local.isEnabled=false;luna.isEnabled=false;back.title="‹ BACK"}
    func setTheme(dark:Bool,green:Bool,scale:CGFloat=1){
        self.dark=dark;self.green=green;preview.font = .monospacedSystemFont(ofSize:11*scale,weight:.regular);let ink=AppTheme.ink(dark:dark,green:green),paper:NSColor=AppTheme.background(dark:dark)
        for button in [back,local,luna]{button.dark=dark;button.green=green}
        title.textColor=ink;info.textColor=AppTheme.muted(dark:dark,green:green);result.textColor=ink;preview.textColor=ink;preview.backgroundColor=paper;scroll.backgroundColor=paper;needsDisplay=true
    }
    override func layout(){
        super.layout();back.frame=NSRect(x:16,y:8,width:64,height:24);title.frame=NSRect(x:92,y:10,width:bounds.width-108,height:24)
        local.frame=NSRect(x:16,y:44,width:132,height:26);luna.frame=NSRect(x:154,y:44,width:132,height:26)
        info.frame=NSRect(x:16,y:78,width:bounds.width-32,height:108);result.frame=NSRect(x:16,y:190,width:bounds.width-32,height:56)
        scroll.frame=NSRect(x:1,y:254,width:bounds.width-2,height:max(1,bounds.height-255))
        preview.setFrameSize(NSSize(width:scroll.contentSize.width,height:max(preview.frame.height,scroll.contentSize.height)));preview.textContainer?.containerSize=NSSize(width:max(1,scroll.contentSize.width-24),height:.greatestFiniteMagnitude)
    }
    override func draw(_ dirtyRect:NSRect){(AppTheme.background(dark:dark)).setFill();bounds.fill()}
    @objc private func goBack(){onBack?()}
    @objc private func chooseLocal(){onChoose?(.local)}
    @objc private func chooseLuna(){onChoose?(.luna)}
}
