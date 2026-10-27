import AppKit

/// Main-thread admission for live readers. Callers report viewport visibility
/// and apply admission changes; the budget never reads or changes source data.
public final class VisibleReaderBudget {
    public struct WindowState {
        public let id: AnyHashable
        public let isVisible: Bool
        public var isKey = false
        public init(id: AnyHashable, isVisible: Bool, isKey: Bool = false) { self.id=id; self.isVisible=isVisible; self.isKey=isKey }
    }
    public struct Candidate {
        public let id: UUID
        public let windowID: AnyHashable
        public var isVisible = true
        public var isKey = false
        public var priority = 0
        public var focusOrder: UInt64 = 0
        public var registrationOrder: UInt64 = 0
        public init(id: UUID, windowID: AnyHashable, isVisible: Bool = true, isKey: Bool = false, priority: Int = 0, focusOrder: UInt64 = 0, registrationOrder: UInt64 = 0) { self.id=id; self.windowID=windowID; self.isVisible=isVisible; self.isKey=isKey; self.priority=priority; self.focusOrder=focusOrder; self.registrationOrder=registrationOrder }
    }

    /// Stable allocation independent of AppKit, wall time and dictionary order.
    public static func allocate(_ candidates: [Candidate], limit: Int = 16, perWindowLimit: Int? = 8) -> Set<UUID> {
        guard limit > 0, perWindowLimit.map({ $0 > 0 }) ?? true else { return [] }
        let ranked = candidates.filter(\.isVisible).sorted {
            if $0.isKey != $1.isKey { return $0.isKey }
            if $0.focusOrder != $1.focusOrder { return $0.focusOrder > $1.focusOrder }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.registrationOrder != $1.registrationOrder { return $0.registrationOrder < $1.registrationOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result = Set<UUID>(), counts = [AnyHashable:Int]()
        for candidate in ranked {
            guard result.count < limit else { break }
            guard !result.contains(candidate.id), perWindowLimit.map({ counts[candidate.windowID,default:0] < $0 }) ?? true else { continue }
            result.insert(candidate.id); counts[candidate.windowID,default:0] += 1
        }
        return result
    }

    private final class Client {
        let id = UUID(), registrationOrder: UInt64
        weak var view: NSView?
        let callback: (Bool) -> Void
        var wantsVisible = false, active = false, registered = true
        public var priority = 0
        public var focusOrder: UInt64 = 0
        init(view: NSView, order: UInt64, callback: @escaping (Bool) -> Void) {
            self.view=view; registrationOrder=order; self.callback=callback
        }
    }
    public let limit: Int
    public let perWindowLimit: Int?
    private let windowState: (NSView) -> WindowState?
    private var clients = [UUID:Client]()
    private var sequence: UInt64 = 0
    private var batchDepth = 0, reconciling = false, pending = false, scheduled = false
    private var observers = [NSObjectProtocol]()
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()

    public init(limit: Int = 16, perWindowLimit: Int? = 8,
         observeWindows: Bool = true,
         windowState: @escaping (NSView) -> WindowState? = VisibleReaderBudget.liveWindowState) {
        self.limit=max(0,limit); self.perWindowLimit=perWindowLimit.map { max(0,$0) }; self.windowState=windowState
        if observeWindows {
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                    guard let self else { return }
                    if let window = notification.object as? NSWindow {
                        if name == NSWindow.willCloseNotification { self.closedWindows.add(window) }
                        if name == NSWindow.didBecomeKeyNotification || name == NSWindow.didDeminiaturizeNotification
                            || (name == NSWindow.didChangeOcclusionStateNotification && window.isVisible && window.occlusionState.contains(.visible)) {
                            self.closedWindows.remove(window)
                        }
                    }
                    self.refresh()
                }
            }
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    public static func liveWindowState(_ view: NSView) -> WindowState? {
        guard let window=view.window else { return nil }
        return WindowState(id:ObjectIdentifier(window),
            isVisible:window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
                && !view.isHiddenOrHasHiddenAncestor && view.bounds.size.width > 0 && view.bounds.size.height > 0
                && view.visibleRect.intersects(view.bounds),isKey:window.isKeyWindow)
    }

    /// Register once per view; callbacks should capture their owner weakly.
    /// Registration starts inactive, so there is no initial false callback.
    @discardableResult
    public func register(_ view: NSView, onAdmission: @escaping (Bool) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        if let existing=clients.values.first(where: { $0.registered && $0.view === view }) { return existing.id }
        sequence &+= 1
        let client=Client(view:view,order:sequence,callback:onAdmission)
        clients[client.id]=client; refresh(); return client.id
    }

    public func update(_ id: UUID, wantsVisible: Bool, priority: Int = 0, focused: Bool = false) {
        precondition(Thread.isMainThread)
        guard let client=clients[id],client.registered else { return }
        client.wantsVisible=wantsVisible; client.priority=priority
        if focused { sequence &+= 1; client.focusOrder=sequence }
        // Even an unchanged desire can follow reparenting or native occlusion.
        refresh()
    }

    public func unregister(_ id: UUID) {
        precondition(Thread.isMainThread)
        guard let client=clients[id],client.registered else { return }
        client.registered=false; refresh()
    }

    public func isAdmitted(_ id: UUID) -> Bool { clients[id]?.active == true }
    public var registeredCount: Int { clients.values.lazy.filter { $0.registered && $0.view != nil }.count }
    public var admittedCount: Int { clients.values.lazy.filter { $0.active && $0.view != nil }.count }

    /// Use when updating a canvas's entire viewport to avoid transient readers.
    public func performBatchUpdates(_ updates: () -> Void) {
        precondition(Thread.isMainThread)
        batchDepth += 1; updates(); batchDepth -= 1
        if batchDepth == 0 { refresh() }
    }

    public func refresh() {
        precondition(Thread.isMainThread)
        pending=true
        guard batchDepth == 0,!reconciling else { return }
        reconciling=true
        var passes=0
        repeat {
            pending=false; passes += 1
            clients=clients.filter { $0.value.view != nil && ($0.value.registered || $0.value.active) }
            let candidates=clients.values.compactMap { client -> Candidate? in
                guard client.registered,client.wantsVisible,let view=client.view,
                      !(view.window.map { closedWindows.contains($0) } ?? false),let state=windowState(view) else { return nil }
                return Candidate(id:client.id,windowID:state.id,isVisible:state.isVisible,isKey:state.isKey,
                    priority:client.priority,focusOrder:client.focusOrder,registrationOrder:client.registrationOrder)
            }
            let selected=Self.allocate(candidates,limit:limit,perWindowLimit:perWindowLimit)
            let ordered=clients.values.sorted { $0.registrationOrder < $1.registrationOrder }
            // Release before admitting replacements, so callbacks never exceed
            // the limit. A callback mutation invalidates the pending selection.
            for client in ordered where client.active && !selected.contains(client.id) {
                client.active=false; client.callback(false)
                if pending { break }
            }
            if !pending {
                for client in ordered where !client.active && selected.contains(client.id) {
                    client.active=true; client.callback(true)
                    if pending { break }
                }
            }
        } while pending && passes < 32
        clients=clients.filter { $0.value.registered || $0.value.active }
        reconciling=false
        // A misbehaving client cannot trap AppKit in a recursive callback loop.
        if pending && !scheduled {
            scheduled=true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled=false; self.refresh()
            }
        }
    }
}
