import AppKit
import ModelSupport

/// Restrained, shared row styling and explicit annotation actions for DATE/ACTIVE.
enum ChatRowAppearance {
    static func tagColor(_ tag: ChatTagColor) -> NSColor {
        switch tag {
        case .red: return NSColor(calibratedRed: 0.90, green: 0.38, blue: 0.34, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.88, green: 0.56, blue: 0.27, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.86, green: 0.74, blue: 0.33, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.39, green: 0.70, blue: 0.53, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.36, green: 0.56, blue: 0.84, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.65, green: 0.49, blue: 0.78, alpha: 1)
        }
    }
    static func summaryText(for chatID: String, in state: ExplorerLibraryState) -> String? {
        guard let value = state.labels[chatID]?.text else { return nil }
        return try? LabelPolicy.validatedLabel(value)
    }
    static func draw(in rect: NSRect, alternate: Bool, summarized: Bool, dark: Bool, green: Bool) {
        guard CursorGeometry.isUsable(rect) else { return }
        let isDark = AppTheme.palette(dark: dark, green: green).isDark
        let gray = NSColor(white: isDark ? 1 : 0, alpha: 1)
        if alternate || summarized {
            gray.withAlphaComponent(summarized ? 0.055 : 0.024).setFill(); rect.fill()
        }
        if summarized {
            gray.withAlphaComponent(0.16).setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
    static func drawPin(in rect: NSRect, pinned: Bool, color: NSColor) {
        guard let symbol = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: nil) else { return }
        let size = NSSize(width: 14, height: 14)
        let tinted = NSImage(size: size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            color.setFill(); bounds.fill(using: .sourceIn); return true
        }
        tinted.draw(in: NSRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    static func drawText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: max(1, rect.width), height: height), withAttributes: attributes)
    }
    static func drawSummaryButton(in rect: NSRect, summarized: Bool, dark: Bool, green: Bool) {
        let ink = AppTheme.ink(dark: dark, green: green)
        ink.withAlphaComponent(0.035).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        ink.withAlphaComponent(0.22).setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        drawText(summarized ? "Summarized ✓" : "AI summary", in: rect.insetBy(dx: 7, dy: 0), size: 9.5, weight: .medium, color: ink, alignment: .center)
    }
    static func menu(chatID: String, state: ExplorerLibraryState,
                     onPin: ((String) -> Void)?, onTag: ((String, ChatTagColor?) -> Void)?,
                     onSummary: ((String, LabelProvider) -> Void)?, existing: NSMenu? = nil) -> NSMenu {
        let menu = existing ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        add(to: menu, title: state.pinnedChatIDs.contains(chatID) ? "Unpin Chat" : "Pin Chat", enabled: onPin != nil) { onPin?(chatID) }
        let tags = NSMenuItem(title: "Colored Dot", action: nil, keyEquivalent: ""), choices = NSMenu()
        for color in ChatTagColor.allCases {
            let item = add(to: choices, title: color.rawValue.capitalized, enabled: onTag != nil) { onTag?(chatID, color) }
            item.state = state.tag(for: chatID) == color ? .on : .off
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                tagColor(color).setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill(); return true
            }
        }
        choices.addItem(.separator())
        let clear = add(to: choices, title: "No Color", enabled: onTag != nil) { onTag?(chatID, nil) }
        clear.state = state.tag(for: chatID) == nil ? .on : .off
        tags.submenu = choices; menu.addItem(tags)
        menu.addItem(.separator())
        add(to: menu, title: "AI Summary · Local Model", enabled: onSummary != nil) { onSummary?(chatID, .local) }
        add(to: menu, title: "AI Summary with Codex…", enabled: onSummary != nil) { onSummary?(chatID, .luna) }
        return menu
    }
    @discardableResult private static func add(to menu: NSMenu, title: String, enabled: Bool,
                                               action: @escaping () -> Void) -> NSMenuItem {
        let owner = ChatRowMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(ChatRowMenuAction.invokeChatRowAction(_:)), keyEquivalent: "")
        item.target = owner; item.representedObject = owner; item.isEnabled = enabled; menu.addItem(item)
        return item
    }
}
private final class ChatRowMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeChatRowAction(_ sender: Any?) { action() }
}
