import AppKit

/// A borderless native window with all-edge resizing and AppKit fullscreen transitions.
open class WorkspaceWindow: NSWindow, NSWindowDelegate {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
    /// Return true to consume an event before AppKit sees it.
    public var eventHandler: ((NSEvent) -> Bool)?
    public var fullscreenEvent: ((String, NSWindow) -> Void)?
    private var resizeEdges: WindowResizeEdges?
    private var addedTitleForFullscreen = false
    private var restoresBorderlessFrame = true
    private var hidesNativeControls = true
    public override var contentView: NSView? {
        didSet { if oldValue !== contentView { installResizeEdges() } }
    }
    private func installResizeEdges() {
        resizeEdges?.removeFromSuperview(); resizeEdges = nil
        guard let content = contentView else { return }
        let edges = WindowResizeEdges(frame: content.bounds)
        edges.autoresizingMask = [.width, .height]; edges.configure(window: self)
        content.addSubview(edges, positioned: .above, relativeTo: nil); resizeEdges = edges
    }
    public convenience init(contentSize: NSSize, title: String = "", minimumSize: NSSize = NSSize(width: 600, height: 320), maximumSize: NSSize = NSSize(width: 100000, height: 100000), style: NSWindow.StyleMask = [.borderless, .closable, .resizable, .miniaturizable, .fullSizeContentView], hideNativeControls: Bool = true) {
        self.init(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: style, backing: .buffered, defer: false)
        self.hidesNativeControls = hideNativeControls
        self.restoresBorderlessFrame = !style.contains(.titled)
        self.title = title; titleVisibility = .hidden; titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none; minSize = minimumSize; maxSize = maximumSize
        isReleasedWhenClosed = false; isExcludedFromWindowsMenu = false; hasShadow = true
        collectionBehavior.insert(.fullScreenPrimary); delegate = self
        if hidesNativeControls { hideNativeButtons() }; installResizeEdges()
    }
    open override func sendEvent(_ event: NSEvent) {
        if eventHandler?(event) == true { return }
        super.sendEvent(event)
    }
    private func hideNativeButtons() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(type)?.isHidden = true }
    }
    open override func toggleFullScreen(_ sender: Any?) {
        fullscreenEvent?("request", self)
        if !styleMask.contains(.fullScreen), !styleMask.contains(.titled) {
            addedTitleForFullscreen = true; styleMask.insert(.titled); if hidesNativeControls { hideNativeButtons() }
        }
        super.toggleFullScreen(sender)
    }
    public func windowDidExitFullScreen(_ notification: Notification) {
        if addedTitleForFullscreen || restoresBorderlessFrame { styleMask.remove(.titled); addedTitleForFullscreen = false }
        fullscreenEvent?("did_exit", self)
    }
    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        if addedTitleForFullscreen || restoresBorderlessFrame { styleMask.remove(.titled); addedTitleForFullscreen = false }
        fullscreenEvent?("failed", window)
    }
}
