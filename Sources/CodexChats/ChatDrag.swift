import AppKit
import CoreGraphics

/// An app-local reference, never an exported transcript or Finder file promise.
struct ChatDragPayload: Codable {
    static let type = NSPasteboard.PasteboardType("local.codex-chat-explorer.chat-reference.v1")
    private static let currentSession = UUID().uuidString
    let version: Int
    let chatID: String
    let session: String

    init(chatID: String) { version = 1; self.chatID = chatID; session = Self.currentSession }
    var data: Data? { try? JSONEncoder().encode(self) }
    static func read(_ data: Data?) -> ChatDragPayload? {
        guard let data, data.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.session == currentSession,
              !value.chatID.isEmpty, value.chatID.utf8.count <= 512 else { return nil }
        return value
    }
    static func read(_ info: NSDraggingInfo) -> ChatDragPayload? {
        guard let source = info.draggingSource as? ChatDragSource,
              let value = read(info.draggingPasteboard.data(forType: type)), value.chatID == source.chatID else { return nil }
        return value
    }
}

enum ChatWindowDrop {
    struct Window {
        let bounds: CGRect
        let layer: Int
        let owner: Int32
        let alpha: Double
    }
    static func isOutsideExplorer(point: CGPoint, windows: [Window], ownPID: Int32) -> Bool {
        // CGWindowList is front to back. An obscured Explorer window must not
        // veto a drop onto another application in front of it.
        let target = windows.first { window in
            window.layer >= 0 && window.alpha > 0 && window.bounds.contains(point)
                && !(window.owner == ownPID && window.layer > NSWindow.Level.popUpMenu.rawValue)
        }
        return target?.owner != ownPID
    }
    static func isOutsideExplorer(at point: NSPoint) -> Bool {
        guard NSScreen.screens.contains(where: { $0.frame.contains(point) }),
              let top = NSScreen.screens.first?.frame.maxY,
              let values = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let windows = values.compactMap { value -> Window? in
            guard let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let layer = value[kCGWindowLayer as String] as? Int,
                  let pid = value[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            return Window(bounds: rect, layer: layer, owner: pid, alpha: value[kCGWindowAlpha as String] as? Double ?? 1)
        }
        let converted = CGPoint(x: point.x, y: top - point.y)
        let result = isOutsideExplorer(point: converted, windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
        ChatDragDiagnostics.log("outside-target", ["point": NSStringFromPoint(point), "outsideExplorer": String(result), "windows": windows.filter { $0.bounds.contains(converted) }.prefix(8).map { "\($0.owner):\($0.layer):\($0.bounds)" }.joined(separator: ";")])
        return result
    }
    static func shouldOpen(operation: NSDragOperation, cancelled: Bool, mouseReleased: Bool) -> Bool {
        operation.isEmpty && !cancelled && mouseReleased
    }
    static func frame(at point: NSPoint, size: NSSize, visible: NSRect) -> NSRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        return NSRect(x: min(max(point.x, visible.minX), visible.maxX - width),
                      y: min(max(point.y - height, visible.minY), visible.maxY - height), width: width, height: height)
    }
}

enum ChatDragOrigin { case date, canvas, window }
enum ChatDropDestination: Equatable { case canvas, date }
enum ChatDragResolution: Equatable {
    case accepted(ChatDropDestination), outside, cancelled
    static func resolve(operation: NSDragOperation, destination: ChatDropDestination?, cancelled: Bool, mouseReleased: Bool, outside: Bool) -> Self {
        if cancelled { return .cancelled }
        if let destination { return operation.isEmpty ? .cancelled : .accepted(destination) }
        return operation.isEmpty && mouseReleased && outside ? .outside : .cancelled
    }
}

final class ChatDragSource: NSObject, NSDraggingSource {
    let chatID: String
    let origin: ChatDragOrigin
    var preferredOperation: NSDragOperation { origin == .date ? .copy : .move }
    var placement: CanvasPlacement?
    var onStarted: (() -> Void)?
    var onAccepted: ((ChatDropDestination) -> Void)?
    var onCancelled: (() -> Void)?
    private var destination: ChatDropDestination?
    var onDesktopDrop: ((String, NSPoint) -> Void)?
    var onFinished: ((ChatDragSource) -> Void)?
    private var escapeMonitor: Any?
    private var cancelled = false
    private var completed = false

    init(chatID: String, origin: ChatDragOrigin = .date) { self.chatID = chatID; self.origin = origin }
    func accept(_ destination: ChatDropDestination) { self.destination = destination }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }

    func begin(from view: NSView, event: NSEvent, title: String, project: String, ink: NSColor, paper: NSColor) {
        ChatDragDiagnostics.log("begin", ["origin": String(describing:origin), "modifiers": String(event.modifierFlags.rawValue)])
        let writer = NSPasteboardItem()
        guard let data = ChatDragPayload(chatID: chatID).data else { return }
        writer.setData(data, forType: ChatDragPayload.type)
        let size = NSSize(width: min(420, max(240, view.bounds.width - 44)), height: 54)
        let image = NSImage(size: size)
        image.lockFocus()
        paper.withAlphaComponent(0.95).setFill(); NSRect(origin: .zero, size: size).fill()
        ink.setStroke(); NSBezierPath(rect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)).stroke()
        label(title, in: NSRect(x: 12, y: 28, width: size.width - 24, height: 18), size: 12, weight: .bold, color: ink)
        label(project, in: NSRect(x: 12, y: 9, width: size.width - 24, height: 15), size: 9, color: ink.withAlphaComponent(0.65))
        image.unlockFocus()
        let item = NSDraggingItem(pasteboardWriter: writer)
        let point = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - 12, width: size.width, height: size.height), contents: image)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelled = true }; return event
        }
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { preferredOperation }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onStarted?() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        ChatDragDiagnostics.log("end", ["origin": String(describing:origin), "destination": String(describing:destination), "operation": String(operation.rawValue), "pressedButtons": String(NSEvent.pressedMouseButtons), "cancelled": String(cancelled), "point": NSStringFromPoint(screenPoint)])
        let released = NSEvent.pressedMouseButtons & 1 == 0
        // Finish after AppKit releases the source view and removes its overlay.
        DispatchQueue.main.async { [self] in
            let outside = operation.isEmpty && released && !cancelled && (origin == .window || ChatWindowDrop.isOutsideExplorer(at: screenPoint))
            complete(operation: operation, mouseReleased: released, outside: outside, at: screenPoint)
        }
    }
    func complete(operation: NSDragOperation, mouseReleased: Bool, outside: Bool, at point: NSPoint = .zero) {
        guard !completed else { return }; completed = true
        onFinished?(self)
        switch ChatDragResolution.resolve(operation: operation, destination: destination, cancelled: cancelled, mouseReleased: mouseReleased, outside: outside) {
        case .accepted(let destination): onAccepted?(destination)
        case .outside: onDesktopDrop?(chatID, point)
        case .cancelled: onCancelled?()
        }
    }
}


// Explicit, local-only diagnostics for native gesture verification. Normal launches
// do not create a log or monitor global input.
enum ChatDragDiagnostics {
    static func log(_ event: String, _ fields: [String: String] = [:]) {
        guard let index = CommandLine.arguments.firstIndex(of: "--drag-debug"), index + 1 < CommandLine.arguments.count else { return }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        var value = fields; value["event"] = event
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        do { try file.seekToEnd(); try file.write(contentsOf: data) } catch { }
    }
}


final class ChatReturnDropButton: NSButton {
    var canReturn: ((String) -> Bool)?
    var onReturn: ((String) -> Bool)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([ChatDragPayload.type]) }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = ChatDragPayload.read(sender), let source = sender.draggingSource as? ChatDragSource,
              source.origin != .date, canReturn?(payload.chatID) == true else { return [] }
        return source.preferredOperation
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !draggingEntered(sender).isEmpty, let source = sender.draggingSource as? ChatDragSource,
              onReturn?(source.chatID) == true else { return false }
        source.accept(.date); return true
    }
}
