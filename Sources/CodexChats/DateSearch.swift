import AppKit

/// Replaceable metadata-only feature. No source readers, persistence or workers.
struct DateSearchIndex {
    private var rows: [(id: String, fields: [String])] = []

    static func key(_ text: String) -> String {
        // Treat spaces, hyphens and underscores alike, including project slugs.
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_–—"))).joined()
    }

    mutating func update(chats: [Chat], labels: [String: String]) {
        rows = chats.map { chat in
            (chat.id, [chat.title, chat.project.name, labels[chat.id] ?? ""].map(Self.key))
        }
    }

    func matches(_ query: String) -> Set<String>? {
        let term = Self.key(query)
        guard !term.isEmpty else { return nil }
        return Set(rows.lazy.filter { $0.fields.contains { $0.contains(term) } }.map(\.id))
    }
}

final class DateSearchBar: NSView, NSTextFieldDelegate {
    static let rowHeight: CGFloat = 30
    struct ReturnPosition {
        let offset: NSPoint
        let chatID: String?
        let deltaY: CGFloat
        let scope: String
    }

    override var isFlipped: Bool { true }
    var onChange: ((Set<String>?) -> Void)?
    var returnPosition: ReturnPosition?
    private var index = DateSearchIndex()
    private let field = NSTextField()
    private let clear = NSButton()
    private let count = NSTextField(labelWithString: "")
    private var ink = NSColor.white
    private var paper = NSColor.black
    private var frameColor = NSColor.white
    var queryKey: String { DateSearchIndex.key(field.stringValue) }
    struct PresentationState { var query: String; var returnPosition: ReturnPosition? }
    func capturePresentationState() -> PresentationState { PresentationState(query: field.stringValue, returnPosition: returnPosition) }
    func restorePresentationState(_ state: PresentationState) {
        field.stringValue = state.query; returnPosition = state.returnPosition
        clear.isHidden = field.stringValue.isEmpty
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.delegate = self
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Search DATE chats and projects")
        field.setAccessibilityHelp("Filters titles, project names and saved short labels. Existing scope filters still apply.")
        clear.title = "×"; clear.isBordered = false; clear.focusRingType = .none
        clear.target = self; clear.action = #selector(clearQuery)
        clear.setAccessibilityLabel("Clear DATE search")
        count.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        count.alignment = .right; count.lineBreakMode = .byTruncatingTail
        for view in [field, clear, count] { addSubview(view) }
        setTheme(dark: true, green: false)
        clear.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func clearIfHiding(_ chatID: String) {
        guard let matches = index.matches(field.stringValue), !matches.contains(chatID) else { return }
        field.stringValue = ""; returnPosition = nil; changed()
    }
    @discardableResult func update(chats: [Chat], labels: [String: String]) -> Set<String>? {
        index.update(chats: chats, labels: labels)
        return index.matches(field.stringValue)
    }

    func showCount(visible: Int, total: Int, archived: Int) {
        count.stringValue = "\(visible) OF \(total) CHATS · \(archived) ARCHIVED"
    }

    func setTheme(dark: Bool, green: Bool) {
        frameColor = AppTheme.border(dark:dark,green:green)
        ink = AppTheme.ink(dark: dark, green: green); paper = AppTheme.background(dark:dark)
        let muted = AppTheme.muted(dark: dark, green: green)
        field.textColor = ink; field.backgroundColor = paper
        field.placeholderAttributedString = NSAttributedString(string: "Search chats / projects…", attributes: [.foregroundColor: muted, .font: field.font!])
        clear.attributedTitle = NSAttributedString(string: "×", attributes: [.foregroundColor: ink, .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)])
        count.textColor = muted
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = min(320, max(180, bounds.width - 236))
        field.frame = NSRect(x: 8, y: 5, width: width - 36, height: 18)
        clear.frame = NSRect(x: width - 25, y: 1, width: 24, height: 22)
        count.frame = NSRect(x: width + 12, y: 5, width: max(1, bounds.width - width - 12), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); bounds.fill(); frameColor.setStroke()
        let width = min(320, max(180, bounds.width - 236))
        NSBezierPath(rect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: 23)).stroke()
    }

    func controlTextDidChange(_ obj: Notification) { changed() }
    @objc private func clearQuery() {
        field.stringValue = ""; changed(); window?.makeFirstResponder(field)
    }
    private func changed() {
        clear.isHidden = field.stringValue.isEmpty
        onChange?(index.matches(field.stringValue))
    }
}
