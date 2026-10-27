import WindowingKit
import AppKit
import WebKit
import CMarkdown
import ImageIO
import UniformTypeIdentifiers
import os
import Darwin
import CryptoKit

/// Derived display only. Source strings and their provenance stay in the history reader.
enum CanvasMarkdown {
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
    }
    static func html(_ message: RecordedMessage) -> String {
        if message.recordedText == nil, message.issue != nil { return "<p class=notice>Message text is unavailable. Open the original chat to inspect it.</p>" }
        let view = message.role == "USER" ? CanvasUserMessage.project(message.text) : CanvasUserPresentation(body:message.text)
        guard case .text(let bytes)? = message.rawPayload,
              let object = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { return html(view.body) }
        let parts = object["content"] as? [[String:Any]] ?? []
        let attachments = parts.filter { !["text","input_text"].contains($0["type"] as? String ?? "") }
        let body = message.recordedText == nil && !attachments.isEmpty ? "" : html(view.body)
        var result = ""
        if let origin = view.origin { result = "<span class=message-origin hidden data-label=\"\(escape(origin))\"></span>"+result }
        for (index,quote) in view.quotes.enumerated() {
            result += "<section class=annotation data-annotation=\"\(index+1)\" data-source=\"\(escape(quote.source ?? ""))\"><div class=quote-label>\(escape(quote.label))</div><blockquote>\(html(quote.text))</blockquote>"
            if let comment = quote.comment, !comment.isEmpty {
                result += "<div class=quote-label>\(quote.label == "Question" ? "Your answer" : "Your comment")</div>\(html(comment))"
            }
            result += "</section>"
        }
        for notice in view.notices { result += "<p class=notice>\(escape(notice))</p>" }
        result += body
        var images = Set<String>(), attachmentCount = 0
        func image(_ location: String) {
            let path = location.hasPrefix("file:") ? URL(string:location)?.path ?? location : (location as NSString).expandingTildeInPath
            let identity = path.replacingOccurrences(of:"/private/var/",with:"/var/",options:.anchored)
            guard images.insert(identity).inserted else { return }
            attachmentCount += 1
            guard attachmentCount <= 16 else { return }
            if location.utf8.count < 2 * 1024 * 1024 {
                // Do not assign src until JS has prepared the permitted local/data URL.
                result += "<figure><img alt=\"Image attachment\" data-canvas-src=\"\(escape(path))\"></figure>"
            } else { result += "<p class=notice>Image not available</p>" }
        }
        for part in attachments {
            let type = part["type"] as? String ?? "Unknown attachment"
            let location = (part["path"] as? String).flatMap { type == "localImage" ? $0 : nil }
                ?? ((part["image_url"] as? [String:Any])?["url"] as? String)
                ?? (part["image_url"] as? String)
                ?? (["image","input_image"].contains(type) ? part["url"] as? String : nil)
            if let location { image(location) }
            else { result += "<p class=notice>\(escape(type)) attachment — view the original in Codex.</p>" }
        }
        for file in view.files {
            let path = (file.path as NSString).expandingTildeInPath
            if file.image { image(path) }
            else { result += "<p class=file-attachment><a href=\"\(escape(path))\">\(escape(file.name))</a></p>" }
        }
        if attachmentCount > 16 { result += "<p class=notice>Additional attachments remain available in the original chat.</p>" }
        if let memory = object["memoryCitation"] as? [String:Any], let entries = memory["entries"] as? [[String:Any]], !entries.isEmpty {
            result += "<details class=citations><summary>Memory sources (\(entries.count))</summary><ul>"
            for entry in entries.prefix(64) {
                let path = entry["path"] as? String ?? "Source unavailable"
                let lines = (entry["lineStart"] as? Int).map { ":\($0)"+((entry["lineEnd"] as? Int).map { "–\($0)" } ?? "") } ?? ""
                result += "<li><code>\(escape(path+lines))</code>"
                if let note = entry["note"] as? String { result += "<br>\(escape(note))" }
                result += "</li>"
            }
            result += "</ul></details>"
        }
        return result
    }
    static func html(_ text: String) -> String {
        guard text.utf8.count <= 2 * 1024 * 1024 else {
            return "<p class=notice>This message exceeds the rich-text viewing limit. Use Open in Codex to read the original.</p>"
        }
        let bytes = Array(normalizeMath(text).utf8)
        let buffer = NSMutableData()
        let status = bytes.withUnsafeBytes { raw in
            md_html(raw.bindMemory(to:CChar.self).baseAddress, UInt32(bytes.count), { chunk,size,context in
                guard let chunk, let context else { return }
                Unmanaged<NSMutableData>.fromOpaque(context).takeUnretainedValue().append(chunk,length:Int(size))
            }, Unmanaged.passUnretained(buffer).toOpaque(), UInt32(MD_FLAG_PERMISSIVEEMAILAUTOLINKS | MD_FLAG_PERMISSIVEURLAUTOLINKS | MD_FLAG_PERMISSIVEWWWAUTOLINKS | MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS | MD_FLAG_LATEXMATHSPANS | MD_FLAG_NOHTMLBLOCKS | MD_FLAG_NOHTMLSPANS), UInt32(MD_HTML_FLAG_SKIP_UTF8_BOM))
        }
        guard status == 0 else { return "<p class=notice>Markdown could not be rendered. Use Open in Codex to read the original.</p>" }
        return String(decoding:buffer as Data,as:UTF8.self).replacingOccurrences(of:"<img src=",with:"<img data-canvas-src=")
    }
    private static func normalizeMath(_ source: String) -> String {
        // ChatGPT also uses \(...\) and \[...\]. Protect fenced and inline code.
        guard source.contains(#"\("#) || source.contains(#"\["#) else { return source }
        let pattern = #"(?s)(`+).*?\1|\\\((.*?)\\\)|\\\[(.*?)\\\]"#
        guard let regex = try? NSRegularExpression(pattern:pattern) else { return source }
        func convert(_ value: String) -> String {
            let text = NSMutableString(string:value)
            for match in regex.matches(in:value,range:NSRange(location:0,length:text.length)).reversed() {
                for (group,delimiter) in [(2,"$"),(3,"$$")] where match.range(at:group).location != NSNotFound {
                    text.replaceCharacters(in:match.range,with:delimiter+(value as NSString).substring(with:match.range(at:group))+delimiter)
                }
            }
            return text as String
        }
        var output = "", prose = "", fence: (Character,Int)?
        func flush() { output += convert(prose); prose = "" }
        let lines = source.split(separator:"\n",omittingEmptySubsequences:false)
        for (index,line) in lines.enumerated() {
            let full = String(line)+(index+1 < lines.count ? "\n" : "")
            let leading = line.prefix { $0 == " " }.count
            let trimmed = line.dropFirst(leading)
            let marker = trimmed.first, count = marker.map { c in trimmed.prefix { $0 == c }.count } ?? 0
            if let active = fence {
                output += full
                if leading <= 3, marker == active.0, count >= active.1, trimmed.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
            } else if leading <= 3, let marker, (marker == "`" || marker == "~"), count >= 3 {
                flush(); fence = (marker,count); output += full
            } else if leading >= 4 || line.first == "\t" { flush(); output += full }
            else { prose += full }
        }
        flush(); return output
    }
}

struct CanvasReaderState {
    var y: CGFloat = 0
    var anchor = 0
    var delta: CGFloat = 0
    var hasAnchor = false
    var heights = [Int:CGFloat]()
}

private final class CanvasScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: CanvasMarkdownView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

enum CanvasImageLoader {
    struct Capture: Codable { let sourcePath: String; let sha256: String; let capturedAt: String }
    static var captureRoot: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CodexChatExplorer/CanvasImageCaptures",isDirectory:true) }
    static func key(_ path: String) -> String { SHA256.hash(data:Data(path.utf8)).map { String(format:"%02x",$0) }.joined() }
    static func thumbnail(_ raw: String) throws -> Data {
        try resolvedThumbnail(raw).data
    }
    static func resolvedThumbnail(_ raw: String, captures: URL = captureRoot) throws -> (data: Data,saved: Bool) {
        let path = raw.hasPrefix("file:") ? URL(string:raw)?.path : raw
        guard let path, path.hasPrefix("/"), !path.utf8.contains(0) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let bytes: Data, saved: Bool
        do { bytes = try read(path,limit:10*1024*1024); saved = false }
        catch {
            let identity = path.replacingOccurrences(of:"/private/var/",with:"/var/",options:.anchored)
            let manifest = captures.appendingPathComponent(key(identity)+".json")
            guard let metadata = try? read(manifest.path,limit:32*1024),
                  let record = try? JSONDecoder().decode(Capture.self,from:metadata), record.sourcePath == identity,
                  record.sha256.count == 64, record.sha256.allSatisfy({ $0.isHexDigit }),
                  let data = try? read(captures.appendingPathComponent("bytes/"+record.sha256+".image").path,limit:10*1024*1024),
                  keyBytes(data) == record.sha256 else { throw error }
            bytes = data; saved = true
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary) else { throw StoreError(message:"Image bytes could not be decoded.") }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:2048,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { throw StoreError(message:"Image thumbnail could not be decoded.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw StoreError(message:"PNG thumbnail encoder is unavailable.") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw StoreError(message:"PNG thumbnail encoding failed.") }
        return (data as Data,saved)
    }
    static func keyBytes(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func read(_ path: String, limit: Int) throws -> Data {
        let fd = Darwin.open(path,O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw StoreError(message:"Image open failed (errno \(errno)).") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StoreError(message:"Image reference is not a regular file.") }
        guard info.st_size <= limit else { throw StoreError(message:"Image exceeds the thumbnail viewing limit.") }
        var bytes = Data(), buffer = [UInt8](repeating:0,count:64*1024)
        while bytes.count <= limit {
            let count = Darwin.read(fd,&buffer,min(buffer.count,limit+1-bytes.count))
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw StoreError(message:"Image read failed (errno \(errno)).") }
            bytes.append(contentsOf:buffer.prefix(count))
        }
        guard bytes.count <= limit else { throw StoreError(message:"Image read exceeded the viewing limit.") }
        return bytes
    }
}

/// One local WebKit surface per visible expanded card; no per-message web views.
/// Raw HTML is inert, resources are bundled, and navigation requires a user click.
/// Only our private chat reference bypasses WebKit's own drop handling.
/// Text selection, copying and normal link behavior continue through WebKit.
private final class CanvasChatDropWebView: WKWebView {
    private func isChat(_ info:NSDraggingInfo)->Bool {info.draggingPasteboard.types?.contains(ChatDragPayload.type)==true || info.draggingPasteboard.types?.contains(WindowTransferPayload.type)==true}
    private func target(_ info: NSDraggingInfo) -> NSView? {
        guard ChatDragPayload.read(info) != nil || WindowTransferPayload.read(info) != nil else { return nil }
        var parent = superview
        while let view = parent {
            if view.registeredDraggedTypes.contains(WindowTransferPayload.read(info) != nil ? WindowTransferPayload.type : ChatDragPayload.type) { return view }
            parent = view.superview
        }
        return nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isChat(sender) ? target(sender)?.draggingEntered(sender) ?? [] : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isChat(sender) ? target(sender)?.draggingUpdated(sender) ?? [] : super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isChat(sender) ? target(sender)?.prepareForDragOperation(sender) ?? false : super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isChat(sender) ? target(sender)?.performDragOperation(sender) ?? false : super.performDragOperation(sender)
    }
}

final class CanvasMarkdownView: NSView, WKNavigationDelegate {
    override var isFlipped: Bool { true }
    var onNeed: (([Int]) -> Void)?
    var onState: ((CanvasReaderState) -> Void)?
    var onFailure: ((String) -> Void)?
    private static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static let imageQueue = DispatchQueue(label:"explorer.canvas.images",qos:.utility)
    private static let imageLog = Logger(subsystem:"local.ai-context-systems-management.codex-chats.canvas",category:"images")
    private var imageCancellation = HistoryCancellation()
    private var pendingImages = Set<String>()
    private let web: WKWebView
    private let bridge: CanvasScriptBridge
    private let chatID: String
    private var token = UUID().uuidString
    private var ready = false, closed = false, rowsReady = false
    private var recoveryAttempts = 0
    private var rows = [[String:Any]]()
    private var state: CanvasReaderState
    private var dark: Bool
    private var green: Bool
    private var lastColors = [String:String]()
    private var contextCopy = ""
    private var pageURL: URL?

    init(chatID: String, dark: Bool, green: Bool = false, state: CanvasReaderState) {
        self.chatID = chatID; self.dark = dark; self.green = green; self.state = state
        let bridge = CanvasScriptBridge(); self.bridge = bridge
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(bridge,name:"canvas")
        web = CanvasChatDropWebView(frame:.zero,configuration:configuration)
        super.init(frame:.zero)
        bridge.owner = self; web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.underPageBackgroundColor = AppTheme.background(dark:dark)
        web.setAccessibilityLabel("Chat messages, formatted Markdown")
        addSubview(web)
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("CanvasMarkdown/index.html")
        let development = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/CanvasMarkdown/index.html")
        pageURL = [bundled,development].compactMap { $0 }.first { FileManager.default.fileExists(atPath:$0.path) }
        if let pageURL { web.loadFileURL(pageURL,allowingReadAccessTo:pageURL.deletingLastPathComponent()) }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit { web.configuration.userContentController.removeScriptMessageHandler(forName:"canvas"); web.stopLoading() }
    override func layout() { super.layout(); web.frame = bounds }

    func setRows(_ rows: [[String:Any]]) { self.rows = rows; rowsReady = true; if ready { configure() } }
    func setTheme(dark: Bool, green: Bool) {
        let colors=AppTheme.palette(dark:dark,green:green).web
        guard self.dark != dark || self.green != green || lastColors != colors else { return }
        self.dark=dark;self.green=green;lastColors=colors
        web.underPageBackgroundColor=AppTheme.background(dark:dark)
        run("window.canvas.theme(dark,colors)",arguments:["dark":dark,"colors":colors])
    }
    func setMessage(_ index: Int, html: String) {
        run("window.canvas.message(index,html)",arguments:["index":index,"html":html])
    }
    func close() {
        guard !closed else { return }; closed = true
        imageCancellation.cancel(); pendingImages.removeAll()
        onNeed = nil; onState = nil; onFailure = nil; bridge.owner = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName:"canvas")
        web.navigationDelegate = nil; web.stopLoading(); web.removeFromSuperview()
    }
    private func run(_ code: String, arguments: [String:Any]) {
        guard ready, !closed else { return }
        web.callAsyncJavaScript(code,arguments:arguments,in:nil,in:.page,completionHandler:nil)
    }
    private func configure() {
        lastColors=AppTheme.palette(dark:dark,green:green).web
        run("window.canvas.configure(config)",arguments:["config":["token":token,"rows":rows,"dark":dark,"colors":AppTheme.palette(dark:dark,green:green).web,"y":state.y,"anchor":state.anchor,"delta":state.delta,"hasAnchor":state.hasAnchor,"heights":state.heights.map { ["index":$0.key,"height":$0.value] }]])
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == pageURL?.standardizedFileURL,
              let payload = message.body as? [String:Any], let kind = payload["type"] as? String else { return }
        if kind == "ready" { ready = true; if rowsReady { configure() }; return }
        guard payload["token"] as? String == token else { return }
        switch kind {
        case "need":
            let indices = (payload["indices"] as? [Int] ?? []).prefix(4).filter { rows.indices.contains($0) }
            onNeed?(Array(indices))
        case "state":
            if let y = payload["y"] as? Double, y.isFinite { state.y = max(0,y) }
            if let anchor = payload["anchor"] as? Int, rows.indices.contains(anchor), let delta = payload["delta"] as? Double, delta.isFinite {
                state.anchor = anchor; state.delta = delta; state.hasAnchor = true
            }
            for value in (payload["heights"] as? [[String:Double]] ?? []).prefix(128) {
                if let index = value["index"], let height = value["height"], index.isFinite, height.isFinite,
                   index >= 0, index < Double(rows.count), height >= 0, height <= 10_000_000 { state.heights[Int(index)] = CGFloat(height) }
            }
            onState?(state)
        case "image":
            if let id = payload["id"] as? String, id.range(of:#"^image-[0-9]+$"#,options:.regularExpression) != nil,
               let path = payload["path"] as? String, path.utf8.count < 32_768 { loadImage(id:id,path:path) }
        case "image-failure":
            Self.imageLog.error("Image display failure: \(payload["phase"] as? String ?? "unknown",privacy:.public)")
        case "link": if let target = payload["href"] as? String { open(target) }
        case "copy":
            if let text = payload["text"] as? String, text.utf8.count <= 4 * 1024 * 1024 { copy(text) }
        case "context":
            let selected = payload["selection"] as? String ?? ""
            contextCopy = selected.utf8.count <= 4 * 1024 * 1024 ? selected : ""
            let menu = ChatContextMenu.make(chatID:chatID)
            if !contextCopy.isEmpty {
                let item = NSMenuItem(title:"Copy",action:#selector(copySelection),keyEquivalent:""); item.target = self
                menu.insertItem(item,at:0); menu.insertItem(.separator(),at:1)
            }
            let x = payload["x"] as? Double ?? 0, y = payload["y"] as? Double ?? 0
            menu.popUp(positioning:nil,at:NSPoint(x:x,y:y),in:self)
        default: break
        }
    }
    private func loadImage(id: String, path: String) {
        guard pendingImages.count < 4, pendingImages.insert(id).inserted else { return }
        let cancel = imageCancellation
        Self.imageQueue.async { [weak self] in
            guard !cancel.cancelled else { return }
            let result: (data: Data,saved: Bool)?
            do { result = try CanvasImageLoader.resolvedThumbnail(path) }
            catch {
                let stage = (error as? StoreError)?.message ?? "File access failed."
                let error = error as NSError; Self.imageLog.error("Native thumbnail failed: \(stage,privacy:.public) \(error.domain,privacy:.public) code \(error.code)"); result = nil
            }
            guard !cancel.cancelled else { return }
            let data = result.map { "data:image/png;base64,"+$0.data.base64EncodedString() } ?? ""
            let saved = result?.saved ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, !cancel.cancelled, !self.closed else { return }
                self.pendingImages.remove(id)
                self.run("window.canvas.image(id,data,saved)",arguments:["id":id,"data":data,"saved":saved])
            }
        }
    }
    @objc private func copySelection() { copy(contextCopy) }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
    private func open(_ target: String) {
        guard target.count < 32_768 else { return }
        if target.hasPrefix("/") || target.hasPrefix("file:") {
            let value = target.hasPrefix("file:") ? URL(string:target)?.path : target
            guard var path = value else { return }
            // A file reference's :line suffix is navigation metadata, not part of its filename.
            if let range = path.range(of:#":\d+(?::\d+)?$"#,options:.regularExpression) { path.removeSubrange(range) }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]); return
        }
        guard let url = URL(string:target), let scheme = url.scheme?.lowercased() else { return }
        if scheme == "https" || scheme == "http" || scheme == "mailto" { NSWorkspace.shared.open(url) }
        else if scheme == "codex", url.host == "threads", UUID(uuidString:url.lastPathComponent) != nil { NSWorkspace.shared.open(url) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let target = navigationAction.request.url?.absoluteString { open(target); decisionHandler(.cancel); return }
        decisionHandler(navigationAction.request.url?.standardizedFileURL == pageURL?.standardizedFileURL ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed, let pageURL else { return }; ready = false
        token = UUID().uuidString
        imageCancellation.cancel(); imageCancellation = HistoryCancellation(); pendingImages.removeAll()
        guard recoveryAttempts < 1 else { onFailure?("Reader stopped. Press RELOAD to reopen it."); return }
        recoveryAttempts += 1
        web.loadFileURL(pageURL,allowingReadAccessTo:pageURL.deletingLastPathComponent())
    }
}
