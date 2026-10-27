import AppKit
import QuartzCore

/// A tiny, independently backed image; the history canvas stays unlayered.
final class DateWorkingIndicator: NSView {
    private let glyph = CALayer()
    private var windowObservation: NSObjectProtocol?
    private var motionObservation: NSObjectProtocol?
    var contentTintColor: NSColor? {
        didSet { if contentTintColor != oldValue { updateGlyph() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.contentsGravity = .resizeAspect
        layer?.addSublayer(glyph)
        positionGlyph()
        updateGlyph()
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() { super.layout(); positionGlyph() }
    private func positionGlyph() {
        // AppKit owns the backing layer's origin. Only this child rotates.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.bounds = CGRect(origin: .zero, size: bounds.size)
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    private func updateGlyph() {
        let color = contentTintColor ?? .secondaryLabelColor
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        let image = NSImage(size: NSSize(width: 66, height: 66), flipped: false) { rect in
            symbol?.draw(in: rect)
            color.setFill(); rect.fill(using: .sourceIn)
            return true
        }
        glyph.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservations()
        if let window {
            windowObservation = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.updateAnimation() }
            motionObservation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateAnimation() }
        }
        updateAnimation()
    }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }

    private func updateAnimation() {
        let animate = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else { glyph.removeAnimation(forKey: "workingRotation"); return }
        guard glyph.animation(forKey: "workingRotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2
        rotation.duration = 1.3
        rotation.repeatCount = .infinity
        glyph.add(rotation, forKey: "workingRotation")
    }
    private func removeObservations() {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
        if let motionObservation { NSWorkspace.shared.notificationCenter.removeObserver(motionObservation) }
        windowObservation = nil; motionObservation = nil
    }
    deinit { removeObservations() }
}
