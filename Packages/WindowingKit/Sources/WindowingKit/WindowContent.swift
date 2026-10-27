import AppKit

/// App-owned content can use any NSView, including an NSHostingView. The
/// preservation callback must invoke its body synchronously and surrounds
/// mutations which may disturb view state.
public struct WindowContent {
    public let view: NSView
    public var preservePresentation: (@escaping () -> Void) -> Void
    public var captureRestoration: () -> (() -> Void)

    public init(view: NSView,
                preservePresentation: @escaping (@escaping () -> Void) -> Void = { $0() },
                captureRestoration: @escaping () -> (() -> Void) = { {} }) {
        self.view = view
        self.preservePresentation = preservePresentation
        self.captureRestoration = captureRestoration
    }
}
