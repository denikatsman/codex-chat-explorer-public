import AppKit
import WindowingKit
import ExplorerDiagnosticsBridge

/// The adapter supplies Explorer state preservation; WindowingKit never reads chat state.
extension ChatRootView {
    var windowingContent: WindowContent {
        WindowContent(view: self, preservePresentation: { [weak self] change in
            guard let self else { change(); return }
            self.preservePresentationDuringHosting(change)
        }, captureRestoration: { [weak self] in self?.hostingStateRestoration() ?? {} })
    }
}

/// App-specific ownership and callbacks around the reusable content host.
final class CanvasExplorerHost {
    private weak var explorer: ChatRootView?
    private let contentHost: ContentHost
    let workspace: ChatCanvasWorkspace
    var onPanelGeometry: ((CanvasExplorerPanel) -> Void)?
    var onDuplicate: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDragOutside: ((CanvasExplorerPanel, NSEvent) -> Void)?
    var isEmbedded: Bool { contentHost.isEmbedded }

    init(explorer: ChatRootView, window: ChatWindow, activateWindows: Bool = true, manageWorkspace: Bool = true) {
        self.explorer = explorer
        workspace = explorer.transferCanvasOwnership()
        contentHost = ContentHost(content: explorer.windowingContent, window: window, activateWindows: activateWindows)
        contentHost.onFailure = { reason in ExplorerDiagnostics.event("explorer.embed.failed", ["reason": .text(reason)]) }
        if manageWorkspace {
            workspace.onExplorer = { [weak self] canvas in self?.embed(in: canvas) }
            workspace.onClose = { [weak self] in self?.restore(showWindow: true) }
        }
    }
    deinit { contentHost.restore(showWindow: false) }

    func embed(in canvas: ChatCanvasRoot, placement: ExplorerPanelPlacement? = nil, reveal: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard let explorer else { completion?(false); return }
        if contentHost.isEmbedded { if reveal { contentHost.reveal() }; completion?(true); return }
        contentHost.embed(isAvailable: { [weak canvas] in canvas?.window != nil }, install: { [weak self, weak canvas, weak explorer] in
            guard let self, let canvas, let explorer else { return false }
            let requestedID = placement?.id ?? explorer.windowInstanceID
            guard explorer.canvasExplorerPanel == nil, canvas.explorerPanels[requestedID] == nil else { return false }
            canvas.installExplorer(explorer, id: placement?.id, frame: placement?.frame, reveal: reveal, popOut: { [weak self] in self?.restore(showWindow: true) }, dismiss: { [weak self] in
                guard let self else { return }
                if let onDismiss = self.onDismiss { onDismiss() } else { self.restore(showWindow: false) }
            })
            guard let panel = explorer.canvasExplorerPanel else { return false }
            panel.onDuplicate = { [weak self] in self?.onDuplicate?() }
            panel.onNativeDrag = { [weak self, weak panel] event in if let panel { self?.onDragOutside?(panel, event) } }
            if let onPanelGeometry = self.onPanelGeometry {
                panel.onGeometry = { [weak panel] in if let panel { onPanelGeometry(panel) } }
            }
            if placement?.collapsed == true { panel.setCollapsed(true) }
            return true
        }, remove: { [weak canvas, weak explorer] in
            if let canvas, let panel = explorer?.canvasExplorerPanel, canvas.explorerPanels[panel.id] === panel {
                canvas.removeExplorer(panel.id)
            }
            explorer?.canvasExplorerPanel = nil
        }, reveal: { [weak canvas, weak explorer] in
            canvas?.revealExplorer(explorer?.canvasExplorerPanel?.id)
        }, destinationWindow: { [weak canvas] in canvas?.window }, completion: { [weak explorer] success in
            if success, let explorer { ExplorerDiagnostics.event("explorer.embed", explorer.diagnosticState()) }
            completion?(success)
        })
    }
    func restore(showWindow: Bool) {
        contentHost.restore(showWindow: showWindow)
        ExplorerDiagnostics.event("explorer.pop_out", ["show_window": .flag(showWindow)])
    }
    func reveal() { contentHost.reveal() }
}

/// Typed Explorer adapter; panel chrome, resizing and movement are reusable.
final class CanvasExplorerPanel: ContentPanel {
    static let explorerMinimumSize = NSSize(width: 602, height: 370)
    let explorer: ChatRootView
    var ink: NSColor { style.ink }
    init(explorer: ChatRootView, frame: NSRect, id: String? = nil) {
        self.explorer = explorer
        super.init(content: explorer.windowingContent, frame: frame, id: id ?? explorer.windowInstanceID,
                   title: "EXPLORER", minimumSize: Self.explorerMinimumSize)
        explorer.canvasExplorerPanel = self
        setAccessibilityLabel("Explorer inside canvas")
        onInteraction = { [weak self] action in
            guard let self else { return }
            if action == "collapse" { ExplorerDiagnostics.event("explorer.collapse", ["collapsed": .flag(self.isCollapsed)]) }
            else { ExplorerDiagnostics.event("explorer.\(action)", ExplorerDiagnostics.rect(self.frame, prefix: "panel")) }
        }
        setTheme(dark: true, green: false)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func setTheme(dark: Bool, green: Bool) {
        style = ContentPanelStyle(background: AppTheme.background(dark: dark), border: AppTheme.border(dark: dark, green: green), ink: AppTheme.ink(dark: dark, green: green))
    }
    func applyShared(_ value: ExplorerPanelPlacement) { applyShared(frame: value.frame, collapsed: value.collapsed) }
}
