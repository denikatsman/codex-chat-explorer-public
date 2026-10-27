import AppKit

public final class DuplicateWindowAction: NSObject {
    public var perform: (() -> Void)?
    public init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc public func duplicate(_ sender: Any?) { perform?() }
    public func menu(appending existing: NSMenu? = nil) -> NSMenu {
        let menu = (existing?.copy() as? NSMenu) ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: "Duplicate Window", action: #selector(duplicate(_:)), keyEquivalent: "")
        item.target = self; menu.addItem(item); return menu
    }
}
