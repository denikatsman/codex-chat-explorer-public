import AppKit

enum ChatContextMenu {
    static func make(chatID: String) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open in Codex", action: #selector(ChatLinkAction.openChat(_:)), keyEquivalent: "")
        item.target = ChatLinkAction.shared
        item.representedObject = chatID
        item.isEnabled = UUID(uuidString: chatID) != nil
        menu.addItem(item)
        return menu
    }
}

private final class ChatLinkAction: NSObject {
    static let shared = ChatLinkAction()
    @objc func openChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, UUID(uuidString: id) != nil,
              let url = URL(string: "codex://threads/" + id) else { return }
        // Archived chats use the same source identity; opening never unarchives them.
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "Codex could not open this chat"
            alert.informativeText = "Check that Codex is installed and try again.\n\(url.absoluteString)"
            alert.runModal()
        }
    }
}
