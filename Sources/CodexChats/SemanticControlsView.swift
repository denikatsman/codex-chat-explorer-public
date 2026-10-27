import AppKit
import CryptoKit

/// FIND's explicit model/index controls. Changing a setting never starts inference.
final class SemanticControlsView: NSView {
    override var isFlipped: Bool { true }
    let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    let tools = FlatActionButton()
    let finals = FlatActionButton()
    let warmth = NSPopUpButton(frame: .zero, pullsDown: false)
    let throttle = FlatActionButton()
    let rerank = FlatActionButton()
    let start = FlatActionButton(), pause = FlatActionButton(), cancel = FlatActionButton()
    let power = FlatActionButton()
    private var moduleEnabled = true
    private var previousMode = 0
    let status = NSTextField(labelWithString: "Local index has not started. Start indexing to enable Meaning and Combined search.")
    var onSettings: (() -> Void)?
    var onStart: (() -> Void)?
    var onPause: (() -> Void)?
    var onCancel: (() -> Void)?
    var onEnabledChanged: ((Bool) -> Void)?
    var searchMode: SemanticSearchMode { SemanticSearchMode.allCases[mode.indexOfSelectedItem] }
    var filters: SemanticFilters { SemanticFilters(includeTools: tools.state == .on, finalOnly: finals.state == .on) }
    var options: SemanticOptions { SemanticOptions(keepWarm: warmth.indexOfSelectedItem == 1, throttle: throttle.state == .on, rerank: rerank.state == .on) }
    static let preferredHeight: CGFloat = 134
    static func preferredHeight(forWidth width: CGFloat) -> CGFloat { width < 500 ? 224 : preferredHeight }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button,title) in [(tools,"Tool inputs / results"),(finals,"Final answers only"),(throttle,"Throttle indexing"),(rerank,"Rerank shortlist")] {
            button.title = title; button.setButtonType(.switch); button.setAccessibilityRole(.checkBox)
        }
        mode.addItems(withTitles: ["Combined", "Meaning", "Exact"])
        warmth.addItems(withTitles: ["Balanced", "Keep warm"])
        for control in [mode, tools, finals, warmth, throttle, rerank] as [NSControl] {
            control.target = self; control.action = #selector(settingsChanged); addSubview(control)
            control.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        }
        mode.setAccessibilityLabel("Message search mode")
        warmth.setAccessibilityLabel("Model memory policy")
        throttle.setAccessibilityLabel("Throttle indexing with paced batches")
        tools.setAccessibilityHelp("Include recorded tool inputs and results in addition to messages and replies.")
        finals.setAccessibilityHelp("Keep user inputs and recorded final answers; exclude progress updates.")
        warmth.toolTip = "Balanced unloads inactive models. Keep warm retains loaded models and uses more memory."
        throttle.toolTip = "Pace indexing with pauses to reduce sustained load. Indexing takes longer."
        rerank.toolTip = "Use the installed reranker on a bounded shortlist. Adds processing time."
        for (button, title, action) in [(start,"START / RESUME",#selector(startIndex)),(pause,"PAUSE",#selector(pauseIndex)),(cancel,"CANCEL INDEX",#selector(cancelIndex))] {
            button.title = title; button.target = self; button.action = action; addSubview(button)
        }
        pause.isEnabled = false; cancel.isEnabled = false
        power.title = "SEMANTIC ON"; power.setButtonType(.switch); power.state = .on
        power.setAccessibilityRole(.checkBox); power.setAccessibilityLabel("Semantic search enabled")
        power.toolTip = "Turn off semantic search to stop indexing and model requests and release model memory. Your saved index and Exact search remain available."
        power.target = self; power.action = #selector(powerChanged); addSubview(power)
        status.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byWordWrapping; addSubview(status)
        refreshModeState()
        setAccessibilityRole(.group); setAccessibilityLabel("Local semantic search and indexing controls")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func show(options: SemanticOptions) {
        warmth.selectItem(at: options.keepWarm ? 1 : 0)
        throttle.state = options.throttle ? .on : .off
        rerank.state = options.rerank ? .on : .off
    }
    func showStatus(_ text: String, counts: SemanticCounts, running: Bool, semanticEnabled: Bool = true, indexingState: String? = nil) {
        if moduleEnabled != semanticEnabled {
            if semanticEnabled { mode.selectItem(at: previousMode) }
            else { previousMode = mode.indexOfSelectedItem; mode.selectItem(at: 2) }
        }
        moduleEnabled = semanticEnabled
        power.state = semanticEnabled ? .on : .off; power.title = semanticEnabled ? "SEMANTIC ON" : "SEMANTIC OFF"
        mode.isEnabled = semanticEnabled; warmth.isEnabled = semanticEnabled; throttle.isEnabled = semanticEnabled
        status.stringValue = "\(indexingState.map { $0 + " · " } ?? "")\(text) · \(counts.chats) chats · \(counts.embedded)/\(counts.passages) passages indexed · \(counts.missing) unavailable · \(counts.skipped) skipped"
        status.setAccessibilityLabel(status.stringValue)
        status.toolTip = status.stringValue
        start.isEnabled = semanticEnabled && !running; pause.isEnabled = semanticEnabled && running
        cancel.isEnabled = semanticEnabled && (running || counts.pending > 0)
        refreshModeState()
    }
    func setTheme(dark: Bool, green: Bool) {
        for button in [start, pause, cancel, power, tools, finals, throttle, rerank] { button.dark = dark; button.green = green }
        status.textColor = AppTheme.muted(dark: dark, green: green)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
    func refreshModeState() {
        rerank.isEnabled = moduleEnabled && searchMode != .exact
        rerank.toolTip = rerank.isEnabled ? "Use the installed reranker on a bounded shortlist. Adds processing time." : "Exact search uses literal matches and does not invoke the reranker. Your saved preference is retained."
        rerank.needsDisplay = true
    }
    override func layout() {
        super.layout()
        if bounds.width < 500 {
            // Keep every control reachable in a narrow Explorer or embedded window.
            let remainder = max(1, bounds.width - 128)
            mode.frame = NSRect(x: 0, y: 0, width: 118, height: 24)
            tools.frame = NSRect(x: 128, y: 0, width: remainder, height: 24)
            warmth.frame = NSRect(x: 0, y: 30, width: 118, height: 24)
            throttle.frame = NSRect(x: 128, y: 30, width: remainder, height: 24)
            finals.frame = NSRect(x: 0, y: 60, width: bounds.width, height: 24)
            rerank.frame = NSRect(x: 0, y: 90, width: bounds.width, height: 24)
            start.frame = NSRect(x: 0, y: 120, width: 126, height: 24)
            pause.frame = NSRect(x: 134, y: 120, width: max(1, bounds.width - 134), height: 24)
            cancel.frame = NSRect(x: 0, y: 150, width: 116, height: 24)
            power.frame = NSRect(x: 124, y: 150, width: max(1, bounds.width - 124), height: 24)
            status.frame = NSRect(x: 0, y: 180, width: bounds.width, height: 40)
            return
        }
        mode.frame = NSRect(x: 0, y: 0, width: 118, height: 24)
        tools.frame = NSRect(x: 128, y: 0, width: 174, height: 24)
        finals.frame = NSRect(x: 310, y: 0, width: max(1, min(190, bounds.width - 310)), height: 24)
        warmth.frame = NSRect(x: 0, y: 30, width: 118, height: 24)
        throttle.frame = NSRect(x: 128, y: 30, width: 174, height: 24)
        rerank.frame = NSRect(x: 310, y: 30, width: max(1, min(190, bounds.width - 310)), height: 24)
        start.frame = NSRect(x: 0, y: 60, width: 126, height: 24)
        pause.frame = NSRect(x: 134, y: 60, width: 68, height: 24)
        cancel.frame = NSRect(x: 210, y: 60, width: 116, height: 24)
        power.frame = NSRect(x: 334, y: 60, width: 166, height: 24)
        status.frame = NSRect(x: 0, y: 90, width: bounds.width, height: 40)
    }
    @objc private func settingsChanged() { refreshModeState(); onSettings?() }
    @objc private func startIndex() { onStart?() }
    @objc private func pauseIndex() { onPause?() }
    @objc private func cancelIndex() { onCancel?() }
    @objc private func powerChanged() { onEnabledChanged?(power.state == .on) }
}

/// Preserve the ranking of each chat's first match and of passages within it.
enum SemanticResultGroups {
    static func visible(_ group: [SemanticHit], expanded: Bool) -> [SemanticHit] { expanded ? group : Array(group.prefix(1)) }
    static func groups(_ hits: [SemanticHit]) -> [[SemanticHit]] {
        var order = [String](), groups = [String: [SemanticHit]]()
        for hit in hits {
            let id = hit.passage.chatID
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(hit)
        }
        return order.compactMap { groups[$0] }
    }
}

enum SemanticSourcePresentation {
    static func header(_ passage: SemanticPassage) -> String {
        "Captured original payload\nChat: \(passage.chatID)\nItem: \(passage.itemID)\nTurn: \(passage.turnID)\nOrdinal: \(passage.ordinal)\nSource: \(passage.sourcePath ?? "Captured local history")\nPassage/context fingerprint: \(passage.sourceDigest)\n\n"
    }
    static func render(_ passage: SemanticPassage, result: Result<Data, Error>) -> String {
        switch result {
        case .success(let bytes):
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            return header(passage) + "Captured payload SHA-256: \(digest)\n\n" + (String(data: bytes, encoding: .utf8) ?? "Original payload is not UTF-8 text (\(bytes.count) bytes). Text display unavailable.")
        case .failure(let error): return header(passage) + "UNAVAILABLE · " + error.localizedDescription
        }
    }
}
