import AppKit

public struct WindowTransferKind: RawRepresentable, Codable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    public static let chat = Self(rawValue: "chat")
    public static let explorer = Self(rawValue: "explorer")
}

/// Only a presentation reference leaves the source view. The native source
/// instance and a fresh drag identity must match before a receiver can use it.
public struct WindowTransferPayload: Codable, Equatable {
    public static let type = NSPasteboard.PasteboardType("local.windowing-kit.window-reference.v1")
    private static let currentSession = UUID()
    public let version: Int
    public let kind: WindowTransferKind
    public let presentationID: String
    public let transferID: UUID
    public let processID: Int32
    public let session: UUID

    public init(kind: WindowTransferKind, presentationID: String, transferID: UUID = UUID()) {
        version = 1
        self.kind = kind
        self.presentationID = presentationID
        self.transferID = transferID
        processID = ProcessInfo.processInfo.processIdentifier
        session = Self.currentSession
    }

    private var isValid: Bool {
        version == 1 && session == Self.currentSession
            && processID == ProcessInfo.processInfo.processIdentifier
            && !presentationID.isEmpty && presentationID.utf8.count <= 512
    }
    public var data: Data? {
        guard isValid else { return nil }
        return try? JSONEncoder().encode(self)
    }

    public static func read(_ data: Data?) -> Self? {
        guard let data, data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }

    public static func read(_ info: NSDraggingInfo) -> Self? {
        guard let source = info.draggingSource as? WindowTransferSource,
              source.canAccept, info.draggingSourceOperationMask.contains(.move),
              let value = read(info.draggingPasteboard.data(forType: type)),
              value == source.payload else { return nil }
        return value
    }
}

public struct WindowTransferDestination: Equatable {
    public let destinationID: String
    /// Coordinates in the destination, supplied by its receiver.
    public let point: NSPoint
    public init(destinationID: String, point: NSPoint) { self.destinationID = destinationID; self.point = point }
    /// Compatibility for existing canvas hosts.
    public var canvasID: String { destinationID }
    public init(canvasID: String, point: NSPoint) { self.init(destinationID: canvasID, point: point) }
}

/// A one-use AppKit transport. The caller owns presentation objects and performs
/// the atomic destination installation in `accept` before source cleanup runs.
public final class WindowTransferSource: NSObject, NSDraggingSource {
    public let payload: WindowTransferPayload
    public var kind: WindowTransferKind { payload.kind }
    public var presentationID: String { payload.presentationID }
    public var preferredOperation: NSDragOperation { .move }
    public var onStarted: (() -> Void)?
    public var onAccepted: ((WindowTransferDestination) -> Void)?
    public var onCancelled: (() -> Void)?
    public var onDesktopDrop: ((NSPoint) -> Void)?
    public var onFinished: ((WindowTransferSource) -> Void)?
    /// Uses screen coordinates. The owner may allow a drop outside its canvas
    /// even when another window in this application occupies the drop point.
    public var shouldDropOnDesktop: ((NSPoint) -> Bool)?

    private var destination: WindowTransferDestination?
    private var escapeMonitor: Any?
    private var begun = false
    private var started = false
    private var accepting = false
    private var cancelled = false
    private var ending = false
    private var completed = false

    public init(kind: WindowTransferKind, presentationID: String) {
        payload = WindowTransferPayload(kind: kind, presentationID: presentationID)
        super.init()
    }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }

    public var canAccept: Bool { !cancelled && !accepting && !ending && !completed && destination == nil }

    /// Return true from `transfer` only after the destination owns the live
    /// presentation. A false result must leave ownership at the source.
    @discardableResult
    public func accept(canvasID: String, at point: NSPoint, transfer: () -> Bool) -> Bool {
        accept(destinationID: canvasID, at: point, transfer: transfer)
    }

    @discardableResult
    public func accept(destinationID: String, at point: NSPoint, transfer: () -> Bool) -> Bool {
        guard canAccept, payload.data != nil, !destinationID.isEmpty, destinationID.utf8.count <= 512,
              point.x.isFinite, point.y.isFinite else { return false }
        accepting = true
        let accepted = transfer()
        accepting = false
        if accepted { destination = WindowTransferDestination(destinationID: destinationID, point: point) }
        return accepted
    }

    /// Records cancellation without trying to synthesize input into AppKit.
    /// Once destination ownership is committed, a late Escape cannot undo it.
    public func markCancelled() {
        guard !accepting, destination == nil, !completed else { return }
        cancelled = true
    }

    @discardableResult
    public func begin(from view: NSView, event: NSEvent, title: String, subtitle: String = "",
               ink: NSColor, paper: NSColor) -> Bool {
        guard !begun, canAccept, let data = payload.data else { return false }
        begun = true
        let writer = NSPasteboardItem()
        writer.setData(data, forType: WindowTransferPayload.type)
        let width = view.bounds.width.isFinite ? min(420, max(240, view.bounds.width - 44)) : 300
        let size = NSSize(width: width, height: subtitle.isEmpty ? 36 : 54)
        let image = NSImage(size: size)
        image.lockFocus()
        paper.withAlphaComponent(0.95).setFill()
        NSRect(origin: .zero, size: size).fill()
        ink.setStroke()
        NSBezierPath(rect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)).stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (String(title.prefix(512)) as NSString).draw(
            in: NSRect(x: 12, y: size.height - 26, width: size.width - 24, height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                             .foregroundColor: ink, .paragraphStyle: paragraph])
        if !subtitle.isEmpty {
            (String(subtitle.prefix(512)) as NSString).draw(
                in: NSRect(x: 12, y: 9, width: size.width - 24, height: 15),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9),
                                 .foregroundColor: ink.withAlphaComponent(0.65), .paragraphStyle: paragraph])
        }
        image.unlockFocus()
        let item = NSDraggingItem(pasteboardWriter: writer)
        let point = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 12,
                                     width: size.width, height: size.height), contents: image)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.markCancelled() }
            return event
        }
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Other processes never receive ownership of an app-local presentation.
        context == .withinApplication ? preferredOperation : []
    }
    public func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard !started, !completed else { return }
        started = true
        onStarted?()
    }
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard !ending, !completed else { return }
        ending = true
        removeEscapeMonitor()
        let released = NSEvent.pressedMouseButtons & 1 == 0
        // AppKit must release its source-view/overlay state before reparenting
        // or closing the source window from a completion callback.
        DispatchQueue.main.async { [self] in
            complete(operation: operation, mouseReleased: released, at: screenPoint)
        }
    }

    public func complete(operation: NSDragOperation, mouseReleased: Bool, at point: NSPoint = .zero) {
        guard !completed, !accepting else { return }
        completed = true
        removeEscapeMonitor()
        let accepted = onAccepted, desktop = onDesktopDrop, cancellation = onCancelled, finished = onFinished
        let canDropOnDesktop = shouldDropOnDesktop
        onStarted = nil; onAccepted = nil; onDesktopDrop = nil; onCancelled = nil; onFinished = nil
        shouldDropOnDesktop = nil
        if let destination {
            // `accept` already committed destination ownership, independently
            // of a late native cancellation or operation-mask discrepancy.
            accepted?(destination)
        } else if operation.isEmpty, mouseReleased, !cancelled,
                  point.x.isFinite, point.y.isFinite, canDropOnDesktop?(point) == true {
            desktop?(point)
        } else {
            cancellation?()
        }
        finished?(self)
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }
}
