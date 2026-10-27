import AppKit

/// Transfers one live view between its native window and an app-owned container.
/// Call on the main thread. Destination callbacks should capture their owner weakly.
public final class ContentHost {
    private let content: WindowContent
    private weak var window: NSWindow?
    private let activateWindows: Bool
    private var originalAutoresizing: NSView.AutoresizingMask = []
    private var originalMenuExclusion = false
    private var removeDestination: (() -> Void)?
    private var revealDestination: (() -> Void)?
    private var destinationWindow: (() -> NSWindow?)?
    private var exitObservation: NSObjectProtocol?
    private var pendingTicket: UUID?
    private var pendingRestoration: (() -> Void)?
    private var pendingCompletion: ((Bool) -> Void)?
    private var restoring = false
    private var activeEmbed: UUID?
    private var activeEmbedCancelled = false
    public private(set) var isEmbedded = false
    public var onFailure: ((String) -> Void)?
    public var fullscreenExitTimeout: TimeInterval = 5

    public init(content: WindowContent, window: NSWindow, activateWindows: Bool = true) {
        self.content = content; self.window = window; self.activateWindows = activateWindows
    }
    deinit { restore(showWindow: false) }

    public func embed(isAvailable: @escaping () -> Bool, install: @escaping () -> Bool,
                      remove: @escaping () -> Void, reveal: @escaping () -> Void,
                      destinationWindow: @escaping () -> NSWindow?, completion: ((Bool) -> Void)? = nil) {
        // Reserve the operation before calling any app-provided closure. A
        // synchronous callback may attempt another transfer or cancel this one.
        guard !restoring, activeEmbed == nil, pendingTicket == nil else { completion?(false); return }
        let operation = UUID(); activeEmbed = operation; activeEmbedCancelled = false
        defer { if activeEmbed == operation { activeEmbed = nil; activeEmbedCancelled = false } }
        func finish(_ result: Bool) {
            if activeEmbed == operation { activeEmbed = nil; activeEmbedCancelled = false }
            completion?(result)
        }
        guard let window, isAvailable(), !activeEmbedCancelled else { finish(false); return }
        if isEmbedded { reveal(); finish(!activeEmbedCancelled && isEmbedded); return }
        guard window.contentView === content.view else { finish(false); return }
        if window.styleMask.contains(.fullScreen) {
            let ticket = UUID(); pendingTicket = ticket; pendingCompletion = completion
            let restoration = content.captureRestoration()
            // captureRestoration itself is app code and may cancel synchronously.
            guard pendingTicket == ticket, !activeEmbedCancelled else { restoration(); return }
            pendingRestoration = restoration
            exitObservation = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pendingTicket == ticket else { return }
                    let restoration = self.pendingRestoration; let completion = self.pendingCompletion
                    self.clearPending()
                    self.embed(isAvailable: isAvailable, install: install, remove: remove, reveal: reveal, destinationWindow: destinationWindow) { result in
                        restoration?(); completion?(result)
                    }
                }
            }
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fullscreenExitTimeout)) { [weak self] in
                guard let self, self.pendingTicket == ticket else { return }
                self.onFailure?("fullscreen_exit_timeout"); self.cancelPending()
            }
            return
        }
        originalAutoresizing = content.view.autoresizingMask
        originalMenuExclusion = window.isExcludedFromWindowsMenu
        var detached = false, attemptedInstall = false, installed = false
        content.preservePresentation {
            guard !self.activeEmbedCancelled else { return }
            window.makeFirstResponder(nil)
            guard !self.activeEmbedCancelled else { return }
            window.isExcludedFromWindowsMenu = true
            detached = true; window.contentView = nil
            guard !self.activeEmbedCancelled else { return }
            attemptedInstall = true; installed = install()
        }
        if !installed || activeEmbedCancelled {
            if detached {
                content.preservePresentation {
                    if attemptedInstall { remove() }
                    self.content.view.removeFromSuperview(); self.content.view.autoresizingMask = self.originalAutoresizing
                    window.isExcludedFromWindowsMenu = self.originalMenuExclusion; window.contentView = self.content.view
                }
            }
            finish(false); return
        }
        removeDestination = remove; revealDestination = reveal; self.destinationWindow = destinationWindow; isEmbedded = true
        let wasVisible = window.isVisible
        window.orderOut(nil)
        if activeEmbedCancelled || !isEmbedded {
            if wasVisible { window.orderFront(nil) }
            finish(false); return
        }
        if activateWindows { destinationWindow()?.makeKeyAndOrderFront(nil) }
        if activeEmbedCancelled || !isEmbedded {
            if wasVisible { window.orderFront(nil) }
            finish(false); return
        }
        finish(true)
    }
    private func clearPending() {
        if let exitObservation { NotificationCenter.default.removeObserver(exitObservation) }
        exitObservation = nil; pendingTicket = nil; pendingRestoration = nil; pendingCompletion = nil
    }
    private func cancelPending() {
        let restoration = pendingRestoration, completion = pendingCompletion
        clearPending(); restoration?(); completion?(false)
    }
    /// Cancels a pending fullscreen transfer or moves the embedded view back.
    public func restore(showWindow: Bool) {
        guard !restoring else { return }; restoring = true; defer { restoring = false }
        if activeEmbed != nil { activeEmbedCancelled = true }
        if pendingTicket != nil { cancelPending() }
        if isEmbedded {
            content.preservePresentation {
                self.removeDestination?(); self.content.view.removeFromSuperview()
                self.content.view.autoresizingMask = self.originalAutoresizing
                self.window?.isExcludedFromWindowsMenu = self.originalMenuExclusion
                self.window?.contentView = self.content.view
            }
            removeDestination = nil; revealDestination = nil; destinationWindow = nil; isEmbedded = false
            // Restoring focus/content can make AppKit expose the source window.
            // Preserve the hosting visibility policy after those callbacks finish.
            if !showWindow || !activateWindows { window?.orderOut(nil) }
        }
        if showWindow && activateWindows { window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil) }
    }
    public func reveal() {
        if isEmbedded { revealDestination?(); destinationWindow?()?.deminiaturize(nil); destinationWindow?()?.makeKeyAndOrderFront(nil) }
        else { window?.deminiaturize(nil); window?.makeKeyAndOrderFront(nil) }
    }
}
