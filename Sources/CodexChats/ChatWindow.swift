import WindowingKit
import AppKit
import ExplorerDiagnosticsBridge
import ModelSupport

/// Explorer-specific commands layered over the reusable native window shell.
final class ChatWindow: WorkspaceWindow {
    var duplicateWindowAction: DuplicateWindowAction?
    convenience init(contentSize: NSSize) {
        self.init(contentSize: contentSize, title: AppBranding.displayName)
        fullscreenEvent = { event, window in
            if event == "request" {
                ExplorerDiagnostics.event("window.fullscreen.request", ["window": .integer(Int64(window.windowNumber)), "enter": .flag(!window.styleMask.contains(.fullScreen))])
            } else if event == "failed" {
                ExplorerDiagnostics.event("window.fullscreen.failed", ["window": .integer(Int64(window.windowNumber))])
            }
        }
    }
    override func sendEvent(_ event: NSEvent) {
        let canvas = contentView as? ChatCanvasRoot
        if event.type == .leftMouseDown { canvas?.noteMouseDown(event.locationInWindow) }
        let explorer = (contentView as? ChatRootView) ?? canvas?.focusedExplorer
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           explorer?.clearDateSelectionFilter() == true { return }
        super.sendEvent(event)
    }
}

func label(_ text: String, in rect: NSRect, size: CGFloat = 12,
                   weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                   alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.alignment = alignment
    (text as NSString).draw(in: rect, withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: paragraph
    ])
}

func line(from: NSPoint, to: NSPoint, color: NSColor) {
    color.setStroke()
    let path = NSBezierPath()
    path.move(to: from); path.line(to: to); path.lineWidth = 1; path.stroke()
}

private final class ProjectHeaderAccessibility: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
}

enum ChatPresentation: String, Hashable {
    case date, project, timeline, columns, lanes, active
}

final class TimelineView: NSView, NSViewToolTipOwner {
    struct PresentationState {
        var sourceURL: URL?
        var presentation: ChatPresentation
        var expandedKeys: Set<String>
        var connectionProjects: [ProjectIdentity: ProjectReference]
        var connectionOrder: [ProjectIdentity]
        var selectionFilterEnabled: Bool
        var archiveFilter: DateArchiveFilter
        var projectScope: DateProjectScope
        var visibleChatIDs: Set<String>?
        var observedTurnIDs: [String: String]
        var lastReplies: LastReplySnapshot?
    }
    func capturePresentationState() -> PresentationState {
        PresentationState(sourceURL: sourceURL, presentation: presentation, expandedKeys: expandedKeys,
                          connectionProjects: dateConnectionProjects, connectionOrder: dateConnectionOrder,
                          selectionFilterEnabled: dateSelectionFilterEnabled, archiveFilter: dateArchiveFilter,
                          projectScope: dateProjectScope, visibleChatIDs: dateVisibleChatIDs,
                          observedTurnIDs: observedTurnIDs, lastReplies: lastReplies)
    }
    func restorePresentationState(_ state: PresentationState) {
        let projects = Dictionary(groups.map { ($0.project.identity, $0.project) }, uniquingKeysWith: { first, _ in first })
        expandedKeys = state.expandedKeys.intersection(Set(projects.keys.map(\.savedKey))); initializedExpansion = true
        dateConnectionProjects = state.connectionProjects.compactMapValues { projects[$0.identity] }
        dateConnectionOrder = state.connectionOrder.filter { dateConnectionProjects[$0] != nil }
        dateArchiveFilter = state.archiveFilter; dateProjectScope = state.projectScope
        dateSelectionFilterEnabled = state.selectionFilterEnabled && !dateConnectionProjects.isEmpty && dateProjectScope != .nonProject
        dateVisibleChatIDs = state.visibleChatIDs.map { $0.intersection(knownChatIDs) }
        observedTurnIDs = state.observedTurnIDs.filter { knownChatIDs.contains($0.key) }; lastReplies = state.lastReplies
        setPresentation(state.presentation); rebuildEntries()
    }
    struct Entry {
        let y: CGFloat
        let height: CGFloat
        let group: ProjectGroup?
        let day: String?
        let chat: Chat?
    }
    override var isFlipped: Bool { true }
    var green = false { didSet { needsDisplay = true; updateWorkingIndicators() } }
    var dark = false { didSet { needsDisplay = true; updateWorkingIndicators() } }
    private var accessibleRows: [NSAccessibilityElement]?
    private var accessibleRect = NSRect.zero
    private var accessibleWindowFrame = NSRect.zero
    private(set) var entries = [Entry]()
    private(set) var groups = [ProjectGroup]()
    private(set) var presentation: ChatPresentation = .project
    private var chats = [Chat]()
    private var compactDateRows = false
    private var microDateRows = false
    private var stackedDateActions: Bool { (viewportSize?.width ?? bounds.width) < 850 }
    private var viewportSize: NSSize?
    private var expandedKeys = Set<String>()
    private var initializedExpansion = false
    private let persistExpansion: Bool
    private let persistHues: Bool
    private let hueDefaults: UserDefaults
    private static let huesChanged = Notification.Name("ExplorerProjectHuesChanged")
    private var huesObserver: NSObjectProtocol?
    var blankAreaMenu: (() -> NSMenu?)?
    private let timeFormatter = DateFormatter()
    private let dayFormatter = DateFormatter()
    private let finishDateFormatter = DateFormatter()
    private let compactDayFormatter = DateFormatter()
    private let finishYearFormatter = DateFormatter()
    private var lastReplies: LastReplySnapshot?
    private var workingChatIDs = Set<String>()
    private var waitingChatIDs = Set<String>()
    private var observedTurnIDs = [String: String]()
    private var workingIndicators = [String: DateWorkingIndicator]()
    private var workingScrollObservation: NSObjectProtocol?
    private(set) var sourceURL: URL?
    private var projectSourceURL: URL?
    private(set) var dateSelectionFilterEnabled = false
    private(set) var dateConnectionProjects = [ProjectIdentity: ProjectReference]()
    private var dateConnectionOrder = [ProjectIdentity]()
    private var dateConnectionTrackCount = 0
    private var dateConnectionCounts = [ProjectIdentity: Int]()
    private(set) var dateConnectionGeometry = DateConnectionGeometry()
    private var dateProjectColors = [ProjectIdentity: (light: NSColor, dark: NSColor)]()
    private var dateProjectHues = [String: Double]()
    private(set) var dateArchiveFilter: DateArchiveFilter = .all
    private(set) var dateProjectScope: DateProjectScope = .all
    private(set) var dateVisibleChatIDs: Set<String>?
    private(set) var dateChatCount = 0
    var canvasSelectedIDs = Set<String>() { didSet { accessibleRows = nil; needsDisplay = true } }
    var onToggleCanvasChat: ((String) -> Void)?
    var onSetCanvasChats: (([String], Bool) -> Void)?
    private var canvasSelectionAnchor: String?
    override var acceptsFirstResponder: Bool { true }
    private(set) var dateArchivedCount = 0
    var onDateSelectionChanged: (() -> Void)?
    var onOpenChat: ((String, Int64?) -> Void)?
    var onDetachChat: ((String, NSPoint) -> Void)?
    var onReturnToDate: ((String) -> Bool)?
    private var knownChatIDs = Set<String>()
    func containsChat(_ id: String) -> Bool { knownChatIDs.contains(id) }
    private var suppressFollowingControlClick = false
    private var chatDragCandidate: (chat: Chat, point: NSPoint, modifiers: NSEvent.ModifierFlags)?
    private var chatDragSource: ChatDragSource?
    var derivedLabels = [String: String]() { didSet { accessibleRows = nil; needsDisplay = true } }
    private var rowAnnotations = ExplorerLibraryState()
    private var rowStripeIndices = [String: Int]()
    var onTogglePinned: ((String) -> Void)?
    var onSetTag: ((String, ChatTagColor?) -> Void)?
    var onSummarize: ((String, LabelProvider) -> Void)?
    func setAnnotations(_ state: ExplorerLibraryState) {
        let orderingChanged = rowAnnotations.pinnedChatIDs != state.pinnedChatIDs
        rowAnnotations = state
        if orderingChanged && presentation == .date { rebuildEntries() }
        else { accessibleRows = nil; needsDisplay = true }
    }
    private func hasRowSummary(_ entry: Entry) -> Bool {
        entry.chat.flatMap { ChatRowAppearance.summaryText(for: $0.id, in: rowAnnotations) } != nil
    }
    private func rowStackOffset(_ entry: Entry) -> CGFloat {
        if compactDateRows { return hasRowSummary(entry) ? 0 : 9 }
        return stackedDateActions ? (hasRowSummary(entry) ? -1 : 6.5) : 0
    }
    private func rowTitleY(_ entry: Entry) -> CGFloat {
        if !stackedDateActions { return entry.y + (entry.height - (hasRowSummary(entry) ? 50 : 34)) / 2 }
        return entry.y + (microDateRows ? 22 : 3) + rowStackOffset(entry)
    }
    private func rowControls(for entry: Entry) -> (pin: NSRect, tag: NSRect, summary: NSRect) {
        let right = compactDateRows ? projectControls(for: entry).contentRight - 8 : projectLabelRect(for: entry).minX - 12
        let y = !stackedDateActions ? entry.y + (entry.height - 24) / 2 : entry.y + (microDateRows ? 92 : compactDateRows ? 70 : 43) + rowStackOffset(entry)
        return (NSRect(x: right - 152, y: y + 2, width: 20, height: 20),
                NSRect(x: right - 126, y: y + 2, width: 20, height: 20),
                NSRect(x: right - 100, y: y, width: 100, height: 24))
    }
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private func connectionInk(for project: ProjectReference) -> NSColor {
        guard let colors = dateProjectColors[project.identity] else { return muted }
        return dark ? colors.dark : colors.light
    }
    private var paper: NSColor { AppTheme.background(dark:dark) }
    private var border: NSColor { AppTheme.border(dark:dark,green:green) }
    private var muted: NSColor { AppTheme.muted(dark: dark, green: green) }

    init(frame: NSRect, persistExpansion: Bool = true, persistHues: Bool? = nil, hueDefaults: UserDefaults = .standard) {
        self.persistExpansion = persistExpansion
        self.persistHues = persistHues ?? persistExpansion
        self.hueDefaults = hueDefaults
        super.init(frame: frame)
        if self.persistHues {
            dateProjectHues = Self.savedProjectHues(hueDefaults)
            huesObserver = NotificationCenter.default.addObserver(forName: Self.huesChanged, object: hueDefaults, queue: .main) { [weak self] _ in self?.reloadProjectHues() }
        }
        for formatter in [timeFormatter, dayFormatter, finishDateFormatter, finishYearFormatter, compactDayFormatter] {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
        }
        timeFormatter.dateFormat = "HH:mm:ss"
        finishDateFormatter.dateFormat = "d MMM · HH:mm:ss"
        finishYearFormatter.dateFormat = "d MMM yyyy · HH:mm:ss"
        dayFormatter.dateFormat = "EEEE, d MMMM yyyy"
        compactDayFormatter.dateFormat = "EEE, d MMM yyyy"
        registerForDraggedTypes([ChatDragPayload.type])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Local Codex chats grouped by project, newest creation date first")
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func setWorkingChats(_ snapshot: ActiveSnapshot) {
        let confirmed = snapshot.connected ? snapshot.rows.filter {
            $0.host == "local" && $0.confirmedAt != nil
        } : []
        let ids = Set(confirmed.filter {
            $0.host == "local" && $0.state == "working" && $0.confirmedAt != nil
        }.map(\.id))
        let waiting = Set(confirmed.filter { $0.state == "waiting" }.map(\.id))
        var changedTurn = false
        let known = Set(chats.map(\.id))
        for row in confirmed where ["working", "waiting"].contains(row.state) && known.contains(row.id) {
            if let turnID = row.turnID, observedTurnIDs[row.id] != turnID {
                observedTurnIDs[row.id] = turnID; changedTurn = true
            }
        }
        guard ids != workingChatIDs || waiting != waitingChatIDs || changedTurn else { return }
        workingChatIDs = ids; waitingChatIDs = waiting
        accessibleRows = nil; needsDisplay = true
        updateWorkingIndicators()
    }

    private func showsWorkingIndicator(for chat: Chat) -> Bool {
        workingChatIDs.contains(chat.id)
    }

    func mergeLastTurns(_ patch: LastReplySnapshot, for ids: Set<String>) {
        var replies = lastReplies?.replies ?? [:], issues = lastReplies?.issues ?? [:]
        for id in ids {
            if patch.issue == nil { replies[id] = patch.replies[id] }
            issues[id] = patch.issue ?? patch.issues[id]
        }
        lastReplies = LastReplySnapshot(sourceURL: patch.sourceURL, replies: replies, issue: lastReplies?.issue, issues: issues)
        accessibleRows = nil; needsDisplay = true
        updateWorkingIndicators()
    }

    private func lastTurnRect(for entry: Entry) -> NSRect {
        let controls = projectControls(for: entry)
        let right = (compactDateRows ? controls.contentRight - 8 : controls.name.minX - 12) - (!stackedDateActions ? 158 : 0)
        let x: CGFloat = microDateRows ? 48 : 142
        let y = !stackedDateActions ? rowTitleY(entry) + 20 : entry.y + (microDateRows ? 43 : 24) + rowStackOffset(entry)
        return NSRect(x: x, y: y, width: max(1, right - x - 8), height: 14)
    }
    private var lastTurnPrefixWidth: CGFloat {
        ("LAST TURN · " as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: microDateRows ? 8 : 9, weight: .regular)]).width
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeWorkingViewport() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeWorkingViewport() }
    override func viewDidHide() { super.viewDidHide(); updateWorkingIndicators() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateWorkingIndicators() }

    private func observeWorkingViewport() {
        if let workingScrollObservation { NotificationCenter.default.removeObserver(workingScrollObservation) }
        workingScrollObservation = nil
        if window != nil, let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            workingScrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.updateWorkingIndicators() }
        }
        updateWorkingIndicators()
    }

    private func updateWorkingIndicators() {
        var visible = Set<String>()
        if presentation == .date, window != nil, !isHiddenOrHasHiddenAncestor, !workingChatIDs.isEmpty {
            let viewport = visibleRect
            var lo = 0, hi = entries.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if entries[mid].y + entries[mid].height < viewport.minY { lo = mid + 1 } else { hi = mid }
            }
            for entry in entries[lo...] {
                if entry.y > viewport.maxY { break }
                guard let chat = entry.chat, showsWorkingIndicator(for: chat) else { continue }
                let metadata = lastTurnRect(for: entry)
                let size: CGFloat = microDateRows ? 9 : 11
                let rect = NSRect(x: metadata.minX + lastTurnPrefixWidth, y: metadata.minY + 1, width: size, height: size)
                guard rect.maxX <= metadata.maxX, rect.intersects(viewport) else { continue }
                visible.insert(chat.id)
                let indicator = workingIndicators[chat.id] ?? DateWorkingIndicator(frame: rect)
                indicator.frame = rect; indicator.contentTintColor = muted
                if indicator.superview == nil { addSubview(indicator) }
                workingIndicators[chat.id] = indicator
            }
        }
        for id in Array(workingIndicators.keys) where !visible.contains(id) {
            workingIndicators.removeValue(forKey: id)?.removeFromSuperview()
        }
    }
    deinit {
        if let workingScrollObservation { NotificationCenter.default.removeObserver(workingScrollObservation) }
        if let huesObserver { NotificationCenter.default.removeObserver(huesObserver) }
    }

    func setSnapshot(_ snapshot: ChatSnapshot) {
        sourceURL = snapshot.sourceURL
        lastReplies = snapshot.lastReplies
        projectSourceURL = snapshot.projectSourceURL
        chats = snapshot.chats
        knownChatIDs = Set(chats.map(\.id))
        let known = Set(chats.map(\.id))
        observedTurnIDs = observedTurnIDs.filter { known.contains($0.key) }
        groups = snapshot.groups
        let currentProjects = Dictionary(uniqueKeysWithValues: groups.map { ($0.project.identity, $0.project) })
        dateConnectionProjects = dateConnectionProjects.compactMapValues { currentProjects[$0.identity] }
        dateConnectionOrder.removeAll { dateConnectionProjects[$0] == nil }
        if dateConnectionProjects.isEmpty { dateSelectionFilterEnabled = false }
        dateProjectColors = currentProjects.compactMapValues { project in
            guard canConnect(project) else { return nil }
            let hue = dateProjectHues[project.identity.savedKey].map { CGFloat($0) }
            return dateProjectColors[project.identity] ?? (DateProjectColors.color(for: project.identity, dark: false, hue: hue), DateProjectColors.color(for: project.identity, dark: true, hue: hue))
        }
        if !initializedExpansion, !groups.isEmpty {
            if persistExpansion, let saved = UserDefaults.standard.stringArray(forKey: "expandedProjects") {
                expandedKeys = Set(saved)
            } else { expandedKeys.insert(groups[0].project.identity.savedKey) }
            initializedExpansion = true
        }
        rebuildEntries()
    }

    func setPresentation(_ presentation: ChatPresentation) {
        guard self.presentation != presentation else { return }
        self.presentation = presentation
        setAccessibilityLabel(presentation == .date ? "Local Codex chats, newest creation date first" : "Local Codex chats grouped by project, newest creation date first")
        rebuildEntries()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func setDateSelectionFilterEnabled(_ enabled: Bool) {
        dateSelectionFilterEnabled = enabled && !dateConnectionProjects.isEmpty && dateProjectScope != .nonProject
        if presentation == .date { rebuildEntries() }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func setDateArchiveFilter(_ filter: DateArchiveFilter) {
        guard dateArchiveFilter != filter else { return }
        dateArchiveFilter = filter
        if presentation == .date { rebuildEntries() }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func setDateProjectScope(_ scope: DateProjectScope) {
        guard dateProjectScope != scope else { return }
        dateProjectScope = scope
        if scope == .nonProject { dateSelectionFilterEnabled = false }
        if presentation == .date { rebuildEntries() }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Optional presentation mask; the canvas has no dependency on search logic.
    func setDateVisibleChatIDs(_ ids: Set<String>?) {
        guard dateVisibleChatIDs != ids else { return }
        dateVisibleChatIDs = ids
        if presentation == .date { rebuildEntries() }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func lastTurnText(for chat: Chat) -> String {
        if workingChatIDs.contains(chat.id) { return "RUNNING" }
        if waitingChatIDs.contains(chat.id) { return "WAITING" }
        guard let lastReplies, lastReplies.issue == nil else { return "UNAVAILABLE" }
        if lastReplies.issues[chat.id] != nil { return "END UNKNOWN" }
        guard let reply = lastReplies.replies[chat.id] else { return observedTurnIDs[chat.id] == nil ? "—" : "END UNKNOWN" }
        if let observed = observedTurnIDs[chat.id], observed != reply.turnID { return "END UNKNOWN" }
        let time: String
        if let finish = reply.finishedAt {
            if let creation = chat.createdAt {
                if Calendar.current.isDate(finish, inSameDayAs: creation) { time = timeFormatter.string(from: finish) }
                else if Calendar.current.component(.year, from: finish) == Calendar.current.component(.year, from: creation) { time = finishDateFormatter.string(from: finish) }
                else { time = finishYearFormatter.string(from: finish) }
            } else { time = finishYearFormatter.string(from: finish) }
        } else { time = "END UNKNOWN" }
        return time + (reply.outcome.isEmpty ? "" : " · " + reply.outcome)
    }

    func fitViewport(_ size: NSSize) {
        let wasStacked = stackedDateActions
        viewportSize = size
        let width = max(1, size.width, presentation == .date ? DateConnectionGeometry.minimumDocumentWidth(railCount: dateConnectionTrackCount, viewportWidth: size.width) : 1)
        let compact = presentation == .date && size.width < 520
        setFrameSize(NSSize(width: width, height: max(frame.height, size.height)))
        accessibleRows = nil
        if compactDateRows != compact || microDateRows != (presentation == .date && size.width < 350) || (presentation == .date && wasStacked != stackedDateActions) { rebuildEntries() }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        updateWorkingIndicators()
    }

    private func projectControls(for entry: Entry) -> DateProjectControls {
        let offset: CGFloat = entry.chat == nil ? 0 : (!compactDateRows ? (entry.height / 2 - 21) : rowStackOffset(entry))
        return DateProjectControls(width: bounds.width, rowY: entry.y + offset, connectionTrackCount: dateConnectionTrackCount, layoutWidth: viewportSize?.width ?? enclosingScrollView?.contentView.bounds.width ?? bounds.width)
    }
    var dateConnectionsColumn: NSRect {
        DateProjectControls(width: bounds.width, rowY: 0, connectionTrackCount: dateConnectionTrackCount, layoutWidth: viewportSize?.width).connections
    }
    private func projectLabelRect(for entry: Entry) -> NSRect { projectControls(for: entry).name }
    private func canConnect(_ project: ProjectReference) -> Bool {
        if case .assigned = project.identity { return true }; return false
    }
    func toggleDateConnections(_ project: ProjectReference) {
        guard presentation == .date, canConnect(project) else { return }
        if dateConnectionProjects.removeValue(forKey: project.identity) != nil {
            dateConnectionOrder.removeAll { $0 == project.identity }
        } else {
            assignConnectionColor(project)
            dateConnectionProjects[project.identity] = project
            dateConnectionOrder.append(project.identity)
        }
        if dateConnectionProjects.isEmpty { dateSelectionFilterEnabled = false }
        rebuildEntries()
        onDateSelectionChanged?()
        accessibleRows = nil; needsDisplay = true
        window?.invalidateCursorRects(for: self)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
    private static func savedProjectHues(_ defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: "dateProjectConnectionHues") ?? [:]).compactMapValues { value in
            guard let hue = value as? Double, hue.isFinite, (0..<1).contains(hue) else { return nil }; return hue
        }
    }
    private func reloadProjectHues() {
        dateProjectHues = Self.savedProjectHues(hueDefaults)
        for project in groups.map(\.project) where canConnect(project) {
            let hue = dateProjectHues[project.identity.savedKey].map { CGFloat($0) }
            dateProjectColors[project.identity] = (DateProjectColors.color(for: project.identity, dark: false, hue: hue), DateProjectColors.color(for: project.identity, dark: true, hue: hue))
        }
        needsDisplay = true
    }
    private func assignConnectionColor(_ project: ProjectReference) {
        let key = project.identity.savedKey
        if persistHues { reloadProjectHues() }
        guard dateProjectHues[key] == nil else { return }
        let base = Double(DateProjectColors.hue(for: project.identity))
        let existing = Array(dateProjectHues.values)
        func separation(_ hue: Double) -> Double {
            existing.map { let distance = abs(hue - $0); return min(distance, 1 - distance) }.min() ?? 1
        }
        // Choose the largest available hue gap without recoloring any project
        // that already has a saved color. Writes happen only on first selection.
        var chosen = base, distance = separation(base)
        for step in 1..<48 {
            let hue = (base + Double(step) * 0.61803398875).truncatingRemainder(dividingBy: 1)
            let gap = separation(hue)
            if gap > distance { chosen = hue; distance = gap }
        }
        dateProjectHues[key] = chosen
        dateProjectColors[project.identity] = (DateProjectColors.color(for: project.identity, dark: false, hue: CGFloat(chosen)), DateProjectColors.color(for: project.identity, dark: true, hue: CGFloat(chosen)))
        if persistHues {
            hueDefaults.set(dateProjectHues, forKey: "dateProjectConnectionHues")
            NotificationCenter.default.post(name: Self.huesChanged, object: hueDefaults)
        }
    }
    private func rebuildDateConnections() {
        guard presentation == .date else { dateConnectionGeometry = DateConnectionGeometry(); return }
        var points = [ProjectIdentity: [CGFloat]]()
        for entry in entries {
            guard let chat = entry.chat, dateConnectionProjects[chat.project.identity] != nil else { continue }
            points[chat.project.identity, default: []].append(projectControls(for: entry).connections.midY)
        }
        dateConnectionGeometry = DateConnectionGeometry(dateConnectionOrder.compactMap { identity in
            points[identity].map { DateConnectionGeometry.Series(identity: identity, points: $0) }
        })
        assert(dateConnectionTrackCount == dateConnectionGeometry.rails.count)
    }
    private func drawDateConnections(_ dirtyRect: NSRect) {
        guard presentation == .date, !dateConnectionGeometry.nodes.isEmpty else { return }
        let controls = projectControls(for: Entry(y: 0, height: 0, group: nil, day: nil, chat: nil))
        dateConnectionGeometry.draw(in: dirtyRect.intersection(bounds), originX: controls.connections.maxX) { identity in
            guard let colors = dateProjectColors[identity] else { return muted }
            return dark ? colors.dark : colors.light
        }
    }

    func isExpanded(_ identity: ProjectIdentity) -> Bool { expandedKeys.contains(identity.savedKey) }

    func toggleGroup(_ identity: ProjectIdentity) {
        guard groups.contains(where: { $0.project.identity == identity }) else { return }
        let offset = enclosingScrollView?.contentView.bounds.origin ?? .zero
        if !expandedKeys.insert(identity.savedKey).inserted { expandedKeys.remove(identity.savedKey) }
        if persistExpansion { UserDefaults.standard.set(expandedKeys.sorted(), forKey: "expandedProjects") }
        rebuildEntries()
        if let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset.y, max(0, frame.height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func rebuildEntries() {
        accessibleRows = nil
        let visible = presentation == .date ? chats.filter { chat in
            dateArchiveFilter.includes(chat) && dateProjectScope.includes(chat)
                && (dateVisibleChatIDs?.contains(chat.id) ?? true)
                && (!dateSelectionFilterEnabled || dateConnectionProjects[chat.project.identity] != nil)
        } : []
        var matchingCounts = [ProjectIdentity: Int]()
        for chat in visible where dateConnectionProjects[chat.project.identity] != nil { matchingCounts[chat.project.identity, default: 0] += 1 }
        dateConnectionCounts = matchingCounts
        dateConnectionTrackCount = matchingCounts.values.filter { $0 > 1 }.count
        let viewport = viewportSize ?? enclosingScrollView?.contentView.bounds.size ?? bounds.size
        let width = max(1, viewport.width, presentation == .date ? DateConnectionGeometry.minimumDocumentWidth(railCount: dateConnectionTrackCount, viewportWidth: viewport.width) : 1)
        setFrameSize(NSSize(width: width, height: max(frame.height, viewport.height)))
        compactDateRows = presentation == .date && viewport.width < 520
        microDateRows = presentation == .date && viewport.width < 350
        entries.removeAll(keepingCapacity: true)
        var y: CGFloat = 0
        func appendChats(_ chats: [Chat]) {
            var lastDay = ""
            for chat in chats {
                let day = chat.createdAt.map { (microDateRows ? compactDayFormatter : dayFormatter).string(from: $0).uppercased() } ?? "UNKNOWN DATE"
                if day != lastDay {
                    let height: CGFloat = presentation == .date ? 44 : 34
                    entries.append(Entry(y: y, height: height, group: nil, day: day, chat: nil))
                    y += height; lastDay = day
                }
                let rowHeight: CGFloat = presentation == .date ? (microDateRows ? 134 : compactDateRows ? 112 : stackedDateActions ? 83 : 58) : 42
                entries.append(Entry(y: y, height: rowHeight, group: nil, day: nil, chat: chat))
                y += rowHeight
            }
        }
        if presentation == .date {
            dateChatCount = visible.count
            dateArchivedCount = visible.lazy.filter(\.archived).count
            let pinned = visible.filter { rowAnnotations.pinnedChatIDs.contains($0.id) }
            let ordinary = visible.filter { !rowAnnotations.pinnedChatIDs.contains($0.id) }
            if !pinned.isEmpty {
                entries.append(Entry(y: y, height: 44, group: nil, day: "PINNED", chat: nil)); y += 44
                appendChats(pinned)
            }
            if !pinned.isEmpty && !ordinary.isEmpty {
                entries.append(Entry(y: y, height: 44, group: nil, day: "CHATS", chat: nil)); y += 44
            }
            appendChats(ordinary)
        }
        else {
            for group in groups {
                entries.append(Entry(y: y, height: 44, group: group, day: nil, chat: nil))
                y += 44
                if isExpanded(group.project.identity) { appendChats(group.chats) }
            }
        }
        setFrameSize(NSSize(width: max(frame.width, 1), height: max(y + 20, enclosingScrollView?.contentSize.height ?? 1)))
        rowStripeIndices = Dictionary(entries.compactMap(\.chat).enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        rebuildDateConnections()
        removeAllToolTips()
        if presentation != .date {
            for entry in entries where entry.chat != nil || entry.group != nil {
                addToolTip(NSRect(x: 0, y: entry.y, width: 10_000, height: entry.height), owner: self, userData: nil)
            }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        updateWorkingIndicators()
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); dirtyRect.fill()
        drawDateConnections(dirtyRect)
        // Binary search skips offscreen history; no chat row owns an NSView.
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].y + entries[mid].height < dirtyRect.minY { lo = mid + 1 }
            else { hi = mid }
        }
        for entry in entries[lo...] {
            if entry.y > dirtyRect.maxY { break }
            if let group = entry.group {
                let expanded = isExpanded(group.project.identity)
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: 22, y: entry.y + 18))
                triangle.line(to: NSPoint(x: expanded ? 30 : 22, y: entry.y + (expanded ? 18 : 26)))
                triangle.line(to: NSPoint(x: expanded ? 26 : 29, y: entry.y + (expanded ? 24 : 22)))
                triangle.close(); ink.setFill(); triangle.fill()
                let name = group.project.name.components(separatedBy: .newlines).joined(separator: " ")
                label(name, in: NSRect(x: 40, y: entry.y + 14, width: max(1, bounds.width - 175), height: 20), size: 13, weight: .bold, color: ink)
                label("\(group.chats.count) \(group.chats.count == 1 ? "CHAT" : "CHATS")", in: NSRect(x: bounds.width - 122, y: entry.y + 16, width: 100, height: 17), size: 10, color: muted, alignment: .right)
                if group.chats.contains(where: { !$0.issues.isEmpty }) {
                    label("!", in: NSRect(x: bounds.width - 139, y: entry.y + 16, width: 12, height: 17), size: 10, weight: .bold, color: ink)
                }
                line(from: NSPoint(x: 22, y: entry.y + 43.5), to: NSPoint(x: bounds.width - 22, y: entry.y + 43.5), color: border)
            } else if let day = entry.day {
                let byDate = presentation == .date
                let inset: CGFloat = byDate ? 22 : 40
                label(day, in: NSRect(x: inset, y: entry.y + (byDate ? 17 : 11), width: byDate ? max(1, projectControls(for: entry).contentRight - inset - (compactDateRows ? 0 : 280)) : bounds.width - inset - 22, height: 18), size: byDate ? 11 : 10, weight: .bold, color: byDate ? ink : muted)
                if byDate && !compactDateRows {
                    label("PROJECT · LINES", in: NSRect(x: projectLabelRect(for: entry).minX, y: entry.y + 17, width: projectControls(for: entry).connections.maxX - projectLabelRect(for: entry).minX, height: 18), size: 9, color: muted, alignment: .right)
                }
                if byDate { line(from: NSPoint(x: 22, y: entry.y + 40.5), to: NSPoint(x: projectControls(for: entry).contentRight - 8, y: entry.y + 40.5), color: border.withAlphaComponent(0.6)) }
            } else if let chat = entry.chat {
                if presentation == .date {
                    ChatRowAppearance.draw(in: NSRect(x: 18, y: entry.y + 1, width: max(1, projectControls(for: entry).contentRight - 26), height: entry.height - 2), alternate: (rowStripeIndices[chat.id] ?? 0) % 2 == 1, summarized: ChatRowAppearance.summaryText(for: chat.id, in: rowAnnotations) != nil, dark: dark, green: green)
                }
                let inset: CGFloat = presentation == .date ? 48 : 40
                let titleX = microDateRows ? inset : inset + 94
                let color = chat.archived ? muted : ink
                let time = chat.createdAt.map { timeFormatter.string(from: $0) } ?? "--:--:--"
                let timeY = presentation == .date ? (!compactDateRows ? entry.y + (entry.height - 18) / 2 : entry.y + (microDateRows ? 3 : 12) + rowStackOffset(entry)) : entry.y + 12
                ChatRowAppearance.drawText(time, in: NSRect(x: inset, y: timeY, width: 76, height: 18), size: 11, color: color)
                // Normalize line breaks only for drawing; the source title bytes stay intact.
                let title = chat.title.components(separatedBy: .newlines).joined(separator: " ")
                let byDate = presentation == .date
                if byDate {
                    let rect = canvasSelectionRect(for: entry)
                    border.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 0.5,dy: 0.5)).stroke()
                    if canvasSelectedIDs.contains(chat.id) {
                        AppTheme.palette(dark:dark,green:green).selection.setFill(); rect.fill(); AppTheme.palette(dark:dark,green:green).onSelection.setStroke()
                        let tick = NSBezierPath(); tick.lineWidth = 1.5
                        tick.move(to:NSPoint(x:rect.minX+3,y:rect.midY)); tick.line(to:NSPoint(x:rect.minX+6,y:rect.maxY-4)); tick.line(to:NSPoint(x:rect.maxX-3,y:rect.minY+4)); tick.stroke()
                    }
                }
                let projectRect = projectLabelRect(for: entry)
                let controls = projectControls(for: entry)
                let rightEdge = byDate ? (compactDateRows ? controls.contentRight - 8 : projectRect.minX - 12) : bounds.width - 17
                let smallArchive = byDate && !compactDateRows && bounds.width < 760
                let rowActions = rowControls(for: entry)
                let titleRight = rightEdge - (byDate && !stackedDateActions ? 158 : 0) - (chat.archived && !compactDateRows ? (smallArchive ? 18 : 100) : 0)
                ChatRowAppearance.drawText(title, in: NSRect(x: titleX, y: byDate ? rowTitleY(entry) : entry.y + 11, width: max(1, titleRight - titleX - 8), height: byDate ? 18 : 20), size: 12, color: color)
                if byDate {
                    let metadata = lastTurnRect(for: entry)
                    let size: CGFloat = microDateRows ? 8 : 9
                    let summary = ChatRowAppearance.summaryText(for: chat.id, in: rowAnnotations)
                    let legacyLabel = summary == nil ? derivedLabels[chat.id] : nil
                    if showsWorkingIndicator(for: chat) {
                        ChatRowAppearance.drawText("LAST TURN · ", in: metadata, size: size, color: muted)
                        if let text = legacyLabel {
                            let offset = lastTurnPrefixWidth + (microDateRows ? 9 : 11) + 4
                            ChatRowAppearance.drawText("· LABEL: \(text)", in: NSRect(x: metadata.minX + offset, y: metadata.minY, width: max(1, metadata.width - offset), height: metadata.height), size: size, color: muted)
                        }
                    } else {
                        ChatRowAppearance.drawText("LAST TURN · \(lastTurnText(for: chat))" + (legacyLabel.map { " · LABEL: \($0)" } ?? ""), in: metadata, size: size, color: muted)
                    }
                    if let summary {
                        let summaryY = !stackedDateActions ? rowTitleY(entry) + 36 : entry.y + entry.height - 16 + (compactDateRows ? 0 : -1)
                        ChatRowAppearance.drawText("SUMMARY · \(summary)", in: NSRect(x: titleX, y: summaryY, width: max(1, rightEdge - titleX), height: 15), size: size, color: muted)
                    }
                }
                if byDate {
                    let pinned = rowAnnotations.pinnedChatIDs.contains(chat.id)
                    ChatRowAppearance.drawPin(in: rowActions.pin, pinned: pinned, color: pinned ? ink : muted)
                    let dot = NSRect(x: rowActions.tag.midX - 4, y: rowActions.tag.midY - 4, width: 8, height: 8)
                    if let tag = rowAnnotations.tag(for: chat.id) { ChatRowAppearance.tagColor(tag).setFill(); NSBezierPath(ovalIn: dot).fill() }
                    else { muted.setStroke(); NSBezierPath(ovalIn: dot).stroke() }
                    ChatRowAppearance.drawSummaryButton(in: rowActions.summary, summarized: hasRowSummary(entry), dark: dark, green: green)
                }
                if chat.archived {
                    drawArchive(at: NSPoint(x: microDateRows ? 116 : compactDateRows ? 22 : rightEdge - (byDate && !stackedDateActions ? 158 : 0) - (smallArchive ? 16 : 96), y: byDate && !compactDateRows ? entry.y + entry.height / 2 - 6 : entry.y + (microDateRows ? 3 : compactDateRows ? 45 : 15) + (byDate ? rowStackOffset(entry) : 0)), color: muted)
                    if !smallArchive { ChatRowAppearance.drawText("ARCHIVED", in: NSRect(x: microDateRows ? 137 : compactDateRows ? 43 : rightEdge - (byDate && !stackedDateActions ? 158 : 0) - 74, y: byDate && !compactDateRows ? entry.y + entry.height / 2 - 8 : entry.y + (microDateRows ? 3 : compactDateRows ? 45 : 13) + (byDate ? rowStackOffset(entry) : 0), width: compactDateRows ? 64 : 74, height: 16), size: compactDateRows ? 8 : 9, color: muted) }
                }
                if byDate {
                    let connected = dateConnectionProjects[chat.project.identity] != nil
                    let projectInk = connectionInk(for: chat.project)
                    DateProjectControls.draw(.connections, in: controls.connections, selected: connected, enabled: canConnect(chat.project), ink: ink, paper: paper, accent: projectInk)
                    let name = chat.project.name.components(separatedBy: .newlines).joined(separator: " ")
                    let nameInk = connected ? projectInk : canConnect(chat.project) ? ink : muted
                    ChatRowAppearance.drawText(name, in: projectRect.insetBy(dx: 7, dy: 0), size: 10, color: nameInk, alignment: .right)
                }
                if !chat.issues.isEmpty {
                    label("!", in: NSRect(x: inset - 16, y: entry.y + 12, width: 10, height: 18), size: 11, weight: .bold, color: ink)
                }
            }
        }
        if entries.isEmpty {
            let empty = presentation == .date && (dateSelectionFilterEnabled || dateArchiveFilter != .all || dateProjectScope != .all || dateVisibleChatIDs != nil) ? "No chats match the selected filters." : "No regular chats in the local index."
            label(empty, in: NSRect(x: 22, y: 28, width: bounds.width - 44, height: 24), color: muted)
        }
    }

    override func mouseDown(with event: NSEvent) {
        chatDragCandidate = nil
        if event.clickCount > 1 && suppressFollowingControlClick { return }
        if event.clickCount == 1 { suppressFollowingControlClick = false }
        let point = convert(event.locationInWindow, from: nil)
        ChatDragDiagnostics.log("down", ["point": NSStringFromPoint(point), "modifiers": String(event.modifierFlags.rawValue)])
        if presentation == .date,
           let entry = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height }), let chat = entry.chat,
           rowControls(for: entry).pin.contains(point) {
            if event.clickCount == 1 { suppressFollowingControlClick = true; onTogglePinned?(chat.id) }
        } else if presentation == .date,
           let entry = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height }), let chat = entry.chat,
           rowControls(for: entry).tag.contains(point) {
            if event.clickCount == 1 {
                suppressFollowingControlClick = true
                let menu = ChatRowAppearance.menu(chatID: chat.id, state: rowAnnotations, onPin: onTogglePinned, onTag: onSetTag, onSummary: onSummarize)
                menu.popUp(positioning: nil, at: NSPoint(x: rowControls(for: entry).tag.minX, y: rowControls(for: entry).tag.maxY), in: self)
            }
        } else if presentation == .date,
           let entry = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height }), let chat = entry.chat,
           rowControls(for: entry).summary.contains(point) {
            if event.clickCount == 1 { suppressFollowingControlClick = true; onSummarize?(chat.id, .local) }
        } else if presentation == .date,
           let entry = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height }), let chat = entry.chat,
           canvasSelectionRect(for: entry).contains(point) {
            selectCanvasChat(chat, modifiers: event.modifierFlags)
        } else if presentation == .date,
           let entry = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height }), let chat = entry.chat,
           projectControls(for: entry).connections.contains(point) {
            toggleDateConnections(chat.project)
        } else if event.clickCount >= 2, let chat = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height })?.chat {
            onOpenChat?(chat.id, nil)
        } else if let group = entries.first(where: { $0.group != nil && point.y >= $0.y && point.y < $0.y + $0.height })?.group {
            toggleGroup(group.project.identity)
        } else if presentation == .date, let chat = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height })?.chat {
            chatDragCandidate = (chat, event.locationInWindow, event.modifierFlags)
            window?.makeFirstResponder(self)
        } else { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard presentation == .date, chatDragSource == nil, let candidate = chatDragCandidate,
              hypot(event.locationInWindow.x - candidate.point.x, event.locationInWindow.y - candidate.point.y) >= 5 else { return }
        chatDragCandidate = nil
        let source = ChatDragSource(chatID: candidate.chat.id)
        source.onDesktopDrop = onDetachChat
        source.onFinished = { [weak self] finished in
            if self?.chatDragSource === finished { self?.chatDragSource = nil }
        }
        chatDragSource = source
        source.begin(from: self, event: event, title: candidate.chat.title, project: candidate.chat.project.name, ink: ink, paper: paper)
    }
    override func mouseUp(with event: NSEvent) {
        if let candidate = chatDragCandidate, !candidate.modifiers.intersection([.command,.shift]).isEmpty {
            selectCanvasChat(candidate.chat, modifiers: candidate.modifiers)
        }
        chatDragCandidate = nil
    }
    private func selectCanvasChat(_ chat: Chat, modifiers: NSEvent.ModifierFlags) {
        window?.makeFirstResponder(self)
        let visible = entries.compactMap(\.chat).map(\.id)
        if modifiers.contains(.shift), let anchor = canvasSelectionAnchor,
           let first = visible.firstIndex(of:anchor), let last = visible.firstIndex(of:chat.id) {
            onSetCanvasChats?(Array(visible[min(first,last)...max(first,last)]), canvasSelectedIDs.contains(anchor))
        } else {
            canvasSelectionAnchor = chat.id
            onToggleCanvasChat?(chat.id)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard presentation == .date, let payload = ChatDragPayload.read(sender),
              let source = sender.draggingSource as? ChatDragSource, source.origin != .date,
              knownChatIDs.contains(payload.chatID) else { return [] }
        return source.preferredOperation
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !draggingEntered(sender).isEmpty, let source = sender.draggingSource as? ChatDragSource,
              onReturnToDate?(source.chatID) == true else { return false }
        source.accept(.date); return true
    }

    private func canvasSelectionRect(for entry: Entry) -> NSRect {
        NSRect(x: 22,y: !compactDateRows ? entry.y + (entry.height - 16) / 2 : entry.y + (microDateRows ? 3 : 12) + rowStackOffset(entry),width:16,height:16)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard presentation == .date else { return }
        onSetCanvasChats?(entries.compactMap(\.chat).map(\.id), true)
    }

    override func keyDown(with event: NSEvent) {
        if presentation == .date, event.modifierFlags.contains([.command,.shift]), event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSetCanvasChats?(entries.compactMap(\.chat).map(\.id), false)
        } else { super.keyDown(with:event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let chat = entries.first(where: { $0.chat != nil && point.y >= $0.y && point.y < $0.y + $0.height })?.chat else { return blankAreaMenu?() }
        let existing = ChatContextMenu.make(chatID: chat.id)
        guard presentation == .date else { return existing }
        return ChatRowAppearance.menu(chatID: chat.id, state: rowAnnotations, onPin: onTogglePinned, onTag: onSetTag, onSummary: onSummarize, existing: existing)
    }

    func cursorRegions(in visible: NSRect) -> [CursorRegion] {
        guard CursorGeometry.isUsable(visible) else { return [] }
        var regions = [CursorRegion]()
        func add(_ rect: NSRect, _ kind: CursorRegion.Kind) {
            if let clipped = CursorGeometry.clipped(rect, to: visible) { regions.append(CursorRegion(rect: clipped, kind: kind)) }
        }
        for entry in entries where entry.group != nil || (presentation == .date && entry.chat != nil) {
            let row = NSRect(x: 0, y: entry.y, width: bounds.width, height: entry.height)
            guard CursorGeometry.clipped(row, to: visible) != nil else { continue }
            if let chat = entry.chat, presentation == .date {
                add(row, .row)
                add(canvasSelectionRect(for: entry), .control)
                let actions = rowControls(for: entry)
                add(actions.pin, .control); add(actions.tag, .control); add(actions.summary, .control)
                if canConnect(chat.project) { add(projectControls(for: entry).connections, .control) }
            } else { add(row, .control) }
        }
        return regions
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let regions = cursorRegions(in: visibleRect)
        if ExplorerDiagnostics.shared.admit("cursor.reset") {
            var fields = ExplorerDiagnostics.rect(visibleRect, prefix: "visible")
            fields["regions"] = .integer(Int64(regions.count)); fields["rows"] = .integer(Int64(entries.count)); fields["view"] = .text(presentation.rawValue)
            ExplorerDiagnostics.event("cursor.reset", fields)
        }
        for region in regions {
            addCursorRect(region.rect, cursor: region.kind == .row ? .openHand : .pointingHand)
        }
    }

    private func drawArchive(at point: NSPoint, color: NSColor) {
        color.setStroke()
        NSBezierPath(rect: NSRect(x: point.x + 1.5, y: point.y + 3.5, width: 11, height: 8)).stroke()
        NSBezierPath(rect: NSRect(x: point.x + 0.5, y: point.y + 0.5, width: 13, height: 3)).stroke()
        line(from: NSPoint(x: point.x + 5, y: point.y + 6.5), to: NSPoint(x: point.x + 9, y: point.y + 6.5), color: color)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard presentation != .date else { return "" }
        guard let entry = entries.first(where: { point.y >= $0.y && point.y < $0.y + $0.height }) else { return "" }
        if let group = entry.group {
            let identity: String
            if case let .assigned(kind, id) = group.project.identity { identity = "Project ID: \(id) (\(kind))" }
            else { identity = group.project.identity == .noProject ? "No project assignment recorded." : "Project metadata unavailable." }
            let warnings = group.chats.filter { !$0.issues.isEmpty }
            let warningText = warnings.isEmpty ? "" : "\n\(warnings.count) chats have metadata warnings.\n\(warnings.prefix(3).map { "\($0.title): \($0.issues.joined(separator: "; "))" }.joined(separator: "\n"))"
            return "\(group.project.name)\n\(group.chats.count) chats\n\(identity)\nClick to \(isExpanded(group.project.identity) ? "collapse" : "expand")\nSource: \(projectSourceURL?.path ?? "")\(warningText)"
        }
        guard let chat = entry.chat else { return "" }
        let date = chat.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unavailable"
        if presentation == .date, projectControls(for: entry).connections.contains(point) {
            guard canConnect(chat.project) else { return "No recorded shared project to connect." }
            let singleton = dateConnectionCounts[chat.project.identity] == 1 ? "\nOnly one chat matches the current filters; shown as a dot without a connecting line." : ""
            return "\(chat.project.name)\nClick to \(dateConnectionProjects[chat.project.identity] != nil ? "hide" : "show") this project's connections. Other projects stay selected.\nIndependent of filtering; lines indicate shared project membership.\(singleton)"
        }
        let finish = presentation == .date ? "\n" + (lastReplies?.explanation(for: chat.id) ?? "Last turn unavailable.") : ""
        return "\(chat.title)\nDouble-click the title to read recorded messages.\nProject: \(chat.project.name)\nCreated: \(date)\nID: \(chat.id)\n\(chat.folder)\n\(chat.archived ? "Archived" : "Active")\nSource: \(sourceURL?.path ?? "")\n\(chat.issues.joined(separator: "\n"))\(finish)"
    }

    override func accessibilityChildren() -> [Any]? {
        if let accessibleRows, accessibleRect == visibleRect, accessibleWindowFrame == (window?.frame ?? .zero) { return accessibleRows }
        let rows = entries.filter { NSRect(x: 0, y: $0.y, width: bounds.width, height: $0.height).intersects(visibleRect) }.flatMap { entry -> [NSAccessibilityElement] in
            let element: NSAccessibilityElement
            if let group = entry.group {
                let header = ProjectHeaderAccessibility()
                header.press = { [weak self] in self?.toggleGroup(group.project.identity) }
                header.setAccessibilityEnabled(true)
                header.setAccessibilityRole(.button)
                header.setAccessibilityLabel("\(group.project.name), \(group.chats.count) chats, \(isExpanded(group.project.identity) ? "expanded" : "collapsed")")
                element = header
            } else {
                if let chat = entry.chat {
                    let button = ProjectHeaderAccessibility()
                    button.press = { [weak self] in self?.onOpenChat?(chat.id, nil) }
                    element = button; element.setAccessibilityRole(.button)
                } else { element = NSAccessibilityElement(); element.setAccessibilityRole(.staticText) }
                element.setAccessibilityLabel(entry.day ?? entry.chat.map {
                    "\($0.createdAt.map { timeFormatter.string(from: $0) } ?? "Unknown time"), \($0.title)\($0.archived ? ", archived" : "")\(presentation == .date ? ", last turn: \(lastTurnText(for: $0))" : "")"
                } ?? "")
            }
            element.setAccessibilityElement(true)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(convertToScreen(NSRect(x: 0, y: entry.y, width: bounds.width, height: entry.height)))
            if presentation == .date, let chat = entry.chat {
                let select = ProjectHeaderAccessibility()
                select.press = { [weak self] in self?.canvasSelectionAnchor = chat.id; self?.onToggleCanvasChat?(chat.id) }
                select.setAccessibilityElement(true); select.setAccessibilityEnabled(true); select.setAccessibilityRole(.checkBox)
                select.setAccessibilityLabel("Select chat for canvas: \(chat.title)")
                select.setAccessibilityHelp("Shift-click applies the first checkbox's state across a range. Command-click toggles a chat. Command-A selects all shown chats; Shift-Command-A clears shown chats when the list has focus.")
                select.setAccessibilityValue(canvasSelectedIDs.contains(chat.id) ? 1 : 0)
                select.setAccessibilityParent(self); select.setAccessibilityFrame(convertToScreen(canvasSelectionRect(for:entry)))
                let connections = ProjectHeaderAccessibility()
                if canConnect(chat.project) { connections.press = { [weak self] in self?.toggleDateConnections(chat.project) } }
                connections.setAccessibilityEnabled(canConnect(chat.project))
                connections.setAccessibilityRole(.button)
                connections.setAccessibilityLabel("\(chat.project.name), \(dateConnectionProjects[chat.project.identity] != nil ? "hide" : "show") project connections")
                connections.setAccessibilityHelp(canConnect(chat.project) ? (dateConnectionCounts[chat.project.identity] == 1 ? "One chat matches the current filters: shown as a dot, without a connecting line." : "Toggle this project's colored track independently of other projects and filtering.") : "No recorded shared project to connect.")
                connections.setAccessibilityValue(dateConnectionProjects[chat.project.identity] != nil ? "on" : "off")
                connections.setAccessibilityElement(true); connections.setAccessibilityParent(self)
                connections.setAccessibilityFrame(convertToScreen(projectControls(for: entry).connections))
                let actions = rowControls(for: entry)
                let pin = ProjectHeaderAccessibility()
                pin.press = { [weak self] in self?.onTogglePinned?(chat.id) }
                pin.setAccessibilityElement(true); pin.setAccessibilityEnabled(true); pin.setAccessibilityRole(.button)
                pin.setAccessibilityLabel("\(rowAnnotations.pinnedChatIDs.contains(chat.id) ? "Unpin" : "Pin") chat: \(chat.title)")
                pin.setAccessibilityParent(self); pin.setAccessibilityFrame(convertToScreen(actions.pin))
                let tag = ProjectHeaderAccessibility()
                tag.press = { [weak self] in
                    guard let self else { return }
                    let menu = ChatRowAppearance.menu(chatID: chat.id, state: self.rowAnnotations, onPin: self.onTogglePinned, onTag: self.onSetTag, onSummary: self.onSummarize)
                    menu.popUp(positioning: nil, at: NSPoint(x: actions.tag.minX, y: actions.tag.maxY), in: self)
                }
                tag.setAccessibilityElement(true); tag.setAccessibilityEnabled(true); tag.setAccessibilityRole(.button)
                tag.setAccessibilityLabel("Color tag for \(chat.title): \(rowAnnotations.tag(for: chat.id)?.rawValue ?? "none")")
                tag.setAccessibilityParent(self); tag.setAccessibilityFrame(convertToScreen(actions.tag))
                let summary = ProjectHeaderAccessibility()
                summary.press = { [weak self] in self?.onSummarize?(chat.id, .local) }
                summary.setAccessibilityElement(true); summary.setAccessibilityEnabled(true); summary.setAccessibilityRole(.button)
                summary.setAccessibilityLabel("AI summary for \(chat.title)" + (ChatRowAppearance.summaryText(for: chat.id, in: rowAnnotations).map { ": \($0)" } ?? ", not yet saved"))
                summary.setAccessibilityParent(self); summary.setAccessibilityFrame(convertToScreen(actions.summary))
                return [element, select, connections, pin, tag, summary]
            }
            return [element]
        }
        accessibleRows = rows; accessibleRect = visibleRect; accessibleWindowFrame = window?.frame ?? .zero
        return rows
    }

    private func convertToScreen(_ rect: NSRect) -> NSRect {
        window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
}

final class ChatRootView: NSView {
    var windowInstanceID = UUID().uuidString
    var onWindowDrag: ((NSEvent) -> Void)?
    var onDuplicateWindow: (() -> Void)?
    var onLabelSettled: (() -> Void)?
    private lazy var duplicateAction = DuplicateWindowAction { [weak self] in self?.onDuplicateWindow?() }
    override var isFlipped: Bool { true }
    let timeline: TimelineView
    let scroll = NSScrollView()
    private let closeButton = NSButton()
    private let minimizeButton = NSButton()
    private let fullScreenButton = NSButton()
    private let modeButton = NSButton()
    private let findButton = NSButton()
    private var metadataToolTip: String?
    private var suppressedControlTips = [ObjectIdentifier: String]()
    private let dateButton = ChatReturnDropButton(frame: .zero)
    private let projectButton = NSButton()
    private let selectionFilterButton = NSButton()
    private let canvasButton = NSButton()
    private var ownedCanvas: ChatCanvasWorkspace?
    private weak var borrowedCanvas: ChatCanvasWorkspace?
    private weak var selectionWorkspace: ChatCanvasWorkspace?
    private var canvasSelectionObservation: UUID?
    private var chatCanvas: ChatCanvasWorkspace {
        if let borrowedCanvas { return borrowedCanvas }
        if let ownedCanvas { return ownedCanvas }
        let value=ChatCanvasWorkspace(persist:persistTheme);ownedCanvas=value;return value
    }
    weak var canvasExplorerPanel: CanvasExplorerPanel? {
        didSet {
            closeButton.setAccessibilityLabel(canvasExplorerPanel == nil ? "Close window" : "Close Explorer panel")
            minimizeButton.setAccessibilityLabel(canvasExplorerPanel == nil ? "Minimize window" : "Collapse Explorer panel")
            fullScreenButton.setAccessibilityLabel(canvasExplorerPanel == nil ? "Toggle full screen" : "Toggle canvas full screen")
        }
    }
    func transferCanvasOwnership() -> ChatCanvasWorkspace {
        let value=chatCanvas;borrowedCanvas=value;ownedCanvas=nil;return value
    }
    func bindCanvasWorkspace(_ workspace: ChatCanvasWorkspace) {
        if let canvasSelectionObservation { selectionWorkspace?.removeSelectionObserver(canvasSelectionObservation) }
        if ownedCanvas !== workspace { ownedCanvas = nil }
        borrowedCanvas = workspace; selectionWorkspace = workspace
        timeline.canvasSelectedIDs = workspace.selected
        canvasSelectionObservation = workspace.observeSelection { [weak self] ids in
            self?.timeline.canvasSelectedIDs = ids; self?.updateDateFilterControl(); self?.needsDisplay = true
        }
        if let snapshot { workspace.update(snapshot) }
        workspace.setTheme(dark: dark, green: green)
        updateDateFilterControl(); needsDisplay = true
    }
    func hostingStateRestoration() -> () -> Void {
        func scrolls(_ view:NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls) }
        let positions=scrolls(self).map { ($0,$0.contentView.bounds.origin) }
        let editor=window?.firstResponder as? NSTextView
        let selection=editor?.selectedRange()
        let focus:NSView? = editor?.isFieldEditor == true ? (editor?.delegate as? NSView) ?? (editor?.delegate as? NSCell)?.controlView : window?.firstResponder as? NSView
        return { [weak self] in
            guard let self else { return };self.needsLayout=true;self.layoutSubtreeIfNeeded()
            if let focus, focus.isDescendant(of:self), !focus.isHiddenOrHasHiddenAncestor, self.window?.makeFirstResponder(focus) == true, let selection,
               let field=self.window?.firstResponder as? NSTextView, selection.location <= field.string.utf16.count {
                field.setSelectedRange(NSRange(location:selection.location,length:min(selection.length,field.string.utf16.count-selection.location)))
            }
            for (scroll,point) in positions { scroll.contentView.scroll(to:point);scroll.reflectScrolledClipView(scroll.contentView) }
        }
    }
    func preservePresentationDuringHosting(_ change: () -> Void) {
        let restore=hostingStateRestoration();change();restore()
    }
    func capturePresentationState() -> WindowPresentationState {
        var offsets = viewOffsets; offsets[timeline.presentation] = scroll.contentView.bounds.origin
        let copiedOverlay: WindowPresentationState.Overlay?
        switch overlay { case .history, .label: copiedOverlay = .history; case .search: copiedOverlay = .search; case nil: copiedOverlay = nil }
        return WindowPresentationState(timeline: timeline.capturePresentationState(), textMagnification: textMagnification,
            selectedDay: selectedDay, timelineFeed: timelineFeed, viewOffsets: offsets, scrollOffset: scroll.contentView.bounds.origin,
            dateSearch: dateSearch?.capturePresentationState(), unfilteredDateOffset: unfilteredDateOffset,
            unfilteredDateAnchor: unfilteredDateAnchor, unfilteredDateQuery: unfilteredDateQuery, dateReturnPosition: dateReturnPosition,
            overlay: copiedOverlay, readerReturnsToSearch: readerReturnsToSearch, history: historyPane.capturePresentationState(),
            search: searchPane.capturePresentationState(), dayFeed: dayFeedPane.capturePresentationState(), columns: columnsView?.snapshot,
            lanes: lanePanel.capturePresentationState(), messageDay: messageDay.capturePresentationState(),
            extraStatus: extraStatus, extraDirty: extraDirty, active: activeChats.snapshot)
    }
    /// Restore only values already loaded by the original window; this never starts a read or model job.
    func restorePresentationState(_ state: WindowPresentationState) {
        guard state.timeline.sourceURL == timeline.sourceURL else { return }
        cancelViewReads()
        textMagnification = TextSizing.clamp(state.textMagnification.isFinite ? state.textMagnification : 1)
        selectedDay = state.selectedDay; displayedDay = nil; timelineFeed = state.timelineFeed
        viewOffsets = state.viewOffsets; unfilteredDateOffset = state.unfilteredDateOffset
        unfilteredDateAnchor = state.unfilteredDateAnchor; unfilteredDateQuery = state.unfilteredDateQuery
        dateReturnPosition = state.dateReturnPosition; readerReturnsToSearch = state.readerReturnsToSearch
        switch state.overlay { case .history: overlay = .history; case .search: overlay = .search; case nil: overlay = nil }
        timeline.restorePresentationState(state.timeline)
        if let dateState = state.dateSearch { dateSearch?.restorePresentationState(dateState) }
        timeline.setDateVisibleChatIDs(dateSearch?.update(chats: snapshot?.chats ?? [], labels: timeline.derivedLabels))
        if let columns = state.columns { showColumns(columns) }
        messageDay.restorePresentationState(state.messageDay)
        if let active = state.active { activeChats.show(active); timeline.setWorkingChats(active) }
        extraStatus = state.extraStatus; extraDirty = state.extraDirty
        installDocument(); needsLayout = true; layoutSubtreeIfNeeded(); updateViewButtons()
        lanePanel.restorePresentationState(state.lanes)
        historyPane.restorePresentationState(state.history)
        searchPane.restorePresentationState(state.search)
        dayFeedPane.restorePresentationState(state.dayFeed)
        WindowPresentationState.scroll(scroll, to: state.scrollOffset)
        needsDisplay = true
    }
    // Set to nil to detach DATE search. The canvas's nil ID mask includes all chats.
    private let dateSearch: DateSearchBar? = DateSearchBar(frame: .zero)
    private var dateHeaderScrollObservation: NSObjectProtocol?
    private let archiveAllButton = NSButton()
    private let archiveNonArchivedButton = NSButton()
    private let archiveArchivedButton = NSButton()
    private let projectScopeAllButton = NSButton()
    private let projectScopeNonProjectButton = NSButton()
    private let projectScopeProjectButton = NSButton()
    private var projectScopeButtons: [(NSButton, DateProjectScope)] {
        [(projectScopeAllButton, .all), (projectScopeNonProjectButton, .nonProject), (projectScopeProjectButton, .project)]
    }
    private var archiveButtons: [(NSButton, DateArchiveFilter)] {
        [(archiveAllButton, .all), (archiveNonArchivedButton, .nonArchived), (archiveArchivedButton, .archived)]
    }
    private var showingDateControls: Bool { overlay == nil && timeline.presentation == .date }
    private var dateControlsWrap: Bool { showingDateControls && bounds.width < 966 }
    private var dateSearchHeight: CGFloat { showingDateControls && dateSearch != nil ? DateSearchBar.rowHeight : 0 }
    private var dateMetadataTop: CGFloat { 76 + (dateControlsWrap ? 27 : 0) + dateSearchHeight }
    private var dateFunnelSide: CGFloat { 24 * textMagnification }
    private var metadataLabelY: CGFloat { showingDateControls ? dateMetadataTop + (dateFunnelSide - 17) / 2 : 81 }
    private var unfilteredDateOffset: NSPoint?
    private var unfilteredDateAnchor: (id: String, dy: CGFloat)?
    private var unfilteredDateQuery: String?
    private let timelineButton = NSButton()
    private let columnsButton = NSButton()
    private let lanesButton = NSButton()
    private let activeButton = NSButton()
    let activeChats = ActiveChatsView(frame: .zero)
    let lanePanel = NativeLaneRoot(frame: .zero)
    private(set) var columnsView: ChatColumnsView?
    private var extraRequests = [ChatPresentation: UUID]()
    private var extraCancellations = [ChatPresentation: HistoryCancellation]()
    private var extraDirty = Set<ChatPresentation>()
    private static let sharedViewQueue = DispatchQueue(label: "explorer.legacy-view-reads", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let viewQueue = ChatRootView.sharedViewQueue
    private let lastTurnQueue = DispatchQueue(label: "explorer.last-turn-reads", qos: .utility, autoreleaseFrequency: .workItem)
    private struct PendingLastTurn {
        let ticket = UUID()
        let expectedID: String?
        let needsEnding: Bool
        let deadline: TimeInterval
    }
    private var pendingLastTurns = [String: PendingLastTurn]()
    private var readingLastTurns = false
    private var lastTurnGeneration = 0
    private var messageCancellation = HistoryCancellation()
    private var extraStatus = [ChatPresentation: String]()
    private let columnsPlaceholder = NSView(frame: .zero)
    private(set) var textMagnification: CGFloat = 1
    private let previousDayButton = NSButton()
    private let nextDayButton = NSButton()
    private let todayButton = NSButton()
    private let feedButton = NSButton()
    private let chartButton = NSButton()
    private let dayInput = NSTextField()
    private var timelineFeed = true
    private var displayedDay: Date?
    let messageDay = MessageDayView(frame: .zero)
    private var selectedDay = Calendar.current.startOfDay(for: Date())
    private var messageRequest = UUID()
    private var green = false
    private var dark: Bool
    private let persistTheme: Bool
    private let persistViewDefaults: Bool
    private let sharedReconciliation: Bool
    private let loadOnDemand: Bool
    private var snapshot: ChatSnapshot?
    private var errorMessage: String?
    private var loading = true
    private var viewOffsets = [ChatPresentation: NSPoint]()
    private var dateReturnPosition: (offset: NSPoint, chatID: String?, deltaY: CGFloat)?
    let library: ExplorerLibrary
    private lazy var historyPane = HistoryPane(library: library)
    private lazy var semanticCoordinator: SemanticCoordinator = (loadOnDemand && persistTheme) ? .shared : SemanticCoordinator(allowWork: false)
    private lazy var searchPane = SearchPane(library: library, coordinator: semanticCoordinator)
    private lazy var dayFeedPane = SearchPane(library: library, coordinator: semanticCoordinator)
    private lazy var labelPane = LabelPane()
    private let labelCoordinator: LabelCoordinator
    private let labelPreparationQueue = DispatchQueue(label: "explorer.label-preparation", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var labelPreparation = HistoryCancellation()
    private var labelIntent = UUID()
    private var labelChat: Chat?
    private var labelSample: LabelSample?
    private struct LabelJob {
        let id: String
        let intent: UUID
        let chat: Chat
        let sample: LabelSample
        let provider: LabelProvider
        var cancelled = false
    }
    private var labelJob: LabelJob?
    private enum Overlay { case history, search, label }
    private var overlay: Overlay?
    private var labelReturnOverlay: Overlay?
    private var labelReturnsToListOnSuccess = false
    private var readerReturnsToSearch = false
    private var appearanceObserver: NSObjectProtocol?
    private var libraryObserver: NSObjectProtocol?
    private var ink: NSColor { AppTheme.ink(dark: dark, green: green) }
    private var paper: NSColor { AppTheme.background(dark:dark) }
    private var border: NSColor { AppTheme.border(dark:dark,green:green) }
    private var muted: NSColor { AppTheme.muted(dark: dark, green: green) }

    init(frame: NSRect, persistTheme: Bool = true, loadOnDemand: Bool = true, library: ExplorerLibrary? = nil, labelCoordinator: LabelCoordinator? = nil,
         canvasWorkspace: ChatCanvasWorkspace? = nil, sharedReconciliation: Bool = false, persistViewDefaults: Bool = true) {
        self.persistTheme = persistTheme
        self.persistViewDefaults = persistViewDefaults
        self.sharedReconciliation = sharedReconciliation
        self.ownedCanvas = canvasWorkspace
        self.labelCoordinator = labelCoordinator ?? LabelCoordinator()
        self.loadOnDemand = loadOnDemand
        self.library = library ?? ExplorerLibrary(directory: persistTheme ? ExplorerLibrary.defaultDirectory : FileManager.default.temporaryDirectory.appendingPathComponent("explorer-library-test-\(UUID())"))
        timeline = TimelineView(frame: .zero, persistExpansion: persistTheme && persistViewDefaults, persistHues: persistTheme)
        let savedTheme = persistTheme ? UserDefaults.standard.string(forKey: "colorTheme").flatMap(AppTheme.init(rawValue:)) : nil
        dark = savedTheme?.isDark ?? (persistTheme && UserDefaults.standard.bool(forKey: "darkMode"))
        green = savedTheme == .green
        super.init(frame: frame)
        if persistTheme {
            AppearanceSettings.shared.activate()
            let settings=AppearanceSettings.shared
            dark=settings.current.isDark;green = !settings.isCustom && settings.preset == .green
            appearanceObserver=NotificationCenter.default.addObserver(forName:AppearanceSettings.changed,object:nil,queue:.main) { [weak self] _ in
                guard let self else { return }
                let restore=self.hostingStateRestoration(),settings=AppearanceSettings.shared
                self.dark=settings.current.isDark;self.green = !settings.isCustom && settings.preset == .green
                self.applyTheme();restore()
            }
            if persistViewDefaults { textMagnification = TextSizing.restored(from: .standard) }
        }
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = timeline
        timeline.isHidden = true
        timeline.autoresizingMask = [.width]
        addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        dateHeaderScrollObservation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.layoutDateSelectionControl()
            if let self, ExplorerDiagnostics.shared.admit("viewport.scroll") { ExplorerDiagnostics.event("viewport.scroll", self.diagnosticState()) }
        }
        addSubview(lanePanel); lanePanel.isHidden = true
        addSubview(historyPane); historyPane.isHidden = true
        addSubview(searchPane); searchPane.isHidden = true
        addSubview(dayFeedPane); dayFeedPane.isHidden = true
        addSubview(labelPane); labelPane.isHidden = true
        historyPane.labelButton.isHidden = false
        historyPane.onGenerateLabel = { [weak self] chat, snapshot in self?.prepareLabel(chat: chat, snapshot: snapshot) }
        labelPane.onChoose = { [weak self] provider in self?.generateLabel(provider: provider) }
        labelPane.onBack = { [weak self] in self?.returnFromLabel() }
        self.labelCoordinator.onEvent = { [weak self] event in self?.labelEvent(event) }
        dayFeedPane.onSummaryChanged = { [weak self] in self?.needsDisplay = true }
        dayFeedPane.onBack = { [weak self] in self?.showTimelineChart() }
        dayFeedPane.onOpen = { [weak self] id, ordinal, excerpt in self?.openChat(id, focus: ordinal, saved: excerpt) }
        if persistTheme && persistViewDefaults, UserDefaults.standard.string(forKey: "timelineLayout") == "chart" { timelineFeed = false }
        dayInput.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        dayInput.isBezeled = false; dayInput.isBordered = true; dayInput.alignment = .center
        dayInput.focusRingType = .none; dayInput.target = self; dayInput.action = #selector(selectDay)
        dayInput.setAccessibilityLabel("Selected day, YYYY-MM-DD")
        addSubview(dayInput)
        for (button, action) in [(todayButton, #selector(showToday)), (feedButton, #selector(showTimelineFeed)), (chartButton, #selector(showTimelineChart))] {
            button.isBordered = false; button.target = self; button.action = action; button.focusRingType = .none; addSubview(button)
        }
        historyPane.onBack = { [weak self] in self?.returnFromReader() }
        libraryObserver = NotificationCenter.default.addObserver(forName: ExplorerLibrary.changed, object: self.library, queue: .main) { [weak self] _ in self?.ownedLibraryChanged() }
        timeline.blankAreaMenu = { [weak self] in self?.duplicateMenu() }
        searchPane.onBack = { [weak self] in self?.closeOverlay() }
        searchPane.onOpen = { [weak self] id, ordinal, excerpt in self?.openChat(id, focus: ordinal, saved: excerpt) }
        timeline.onOpenChat = { [weak self] id, ordinal in self?.openChat(id, focus: ordinal) }
        activeChats.onOpenChat = { [weak self] id in self?.openChat(id) }
        let togglePin: (String) -> Void = { [weak self] id in
            guard let self else { return }
            do { try self.library.togglePinned(id) } catch { self.showError(error.localizedDescription) }
        }
        let setTag: (String, ChatTagColor?) -> Void = { [weak self] id, color in
            guard let self else { return }
            do { try self.library.setTag(color, chatID: id) } catch { self.showError(error.localizedDescription) }
        }
        let summarize: (String, LabelProvider) -> Void = { [weak self] id, provider in
            guard let self else { return }
            guard let snapshot = self.snapshot, let chat = snapshot.chats.first(where: { $0.id == id }) else {
                self.showError("This chat is not present in the current local metadata; refresh before generating a summary.")
                return
            }
            self.prepareLabel(chat: chat, snapshot: snapshot, autoStart: provider)
        }
        timeline.onTogglePinned = togglePin; timeline.onSetTag = setTag; timeline.onSummarize = summarize
        activeChats.onTogglePinned = togglePin; activeChats.onSetTag = setTag; activeChats.onSummarize = summarize
        timeline.setAnnotations(self.library.state); activeChats.setAnnotations(self.library.state)
        messageDay.onOpenChat = { [weak self] id, ordinal in self?.openChat(id, focus: ordinal) }
        lanePanel.canvas.onOpenChat = { [weak self] id, ordinal in self?.openChat(id, focus: ordinal) }
        findButton.isBordered = false; findButton.target = self; findButton.action = #selector(showFind)
        findButton.toolTip = "Find chats, message text, stars and saved excerpts (⌘F)"
        findButton.setAccessibilityLabel("Find chats and saved excerpts")
        addSubview(findButton)
        closeButton.isBordered = false
        closeButton.title = ""
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.toolTip = "Close window"
        closeButton.setAccessibilityLabel("Close window")
        addSubview(closeButton)
        minimizeButton.isBordered = false
        minimizeButton.title = ""
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeWindow)
        minimizeButton.toolTip = "Minimize window (⌘M)"
        minimizeButton.setAccessibilityLabel("Minimize window")
        addSubview(minimizeButton)
        fullScreenButton.isBordered = false
        fullScreenButton.title = ""
        fullScreenButton.target = self
        fullScreenButton.action = #selector(toggleFullScreen)
        fullScreenButton.toolTip = "Toggle full screen (⌃⌘F)"
        fullScreenButton.setAccessibilityLabel("Toggle full screen")
        addSubview(fullScreenButton)
        modeButton.isBordered = false
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        modeButton.setAccessibilityLabel("Appearance: customize colors and presets")
        modeButton.toolTip = "Customize appearance"
        addSubview(modeButton)
        for button in [dateButton, projectButton, timelineButton, columnsButton, lanesButton, activeButton, previousDayButton, nextDayButton] {
            button.isBordered = false
            button.target = self
            button.focusRingType = .none
            addSubview(button)
        }
        selectionFilterButton.isBordered = false
        selectionFilterButton.title = ""
        selectionFilterButton.target = self
        selectionFilterButton.action = #selector(toggleSelectionFilterClicked)
        selectionFilterButton.focusRingType = .none
        addSubview(selectionFilterButton)
        canvasButton.isBordered = false; canvasButton.target = self; canvasButton.action = #selector(openCanvas)
        canvasButton.focusRingType = .none; canvasButton.setAccessibilityLabel("Open chat canvas")
        addSubview(canvasButton)
        timeline.onDetachChat = { [weak self] id, point in self?.chatCanvas.openDetached(id, at: point) }
        timeline.onReturnToDate = { [weak self] id in self?.revealDateChat(id) ?? false }
        dateButton.canReturn = { [weak self] id in self?.timeline.containsChat(id) == true }
        dateButton.onReturn = { [weak self] id in self?.revealDateChat(id) ?? false }
        timeline.canvasSelectedIDs = chatCanvas.selected
        timeline.onToggleCanvasChat = { [weak self] id in self?.chatCanvas.toggle(id) }
        timeline.onSetCanvasChats = { [weak self] ids, included in self?.chatCanvas.set(ids, included:included) }
        bindCanvasWorkspace(chatCanvas)
        if let dateSearch {
            addSubview(dateSearch)
            dateSearch.onChange = { [weak self] ids in self?.applyDateSearch(ids) }
        }
        for (index, button) in (archiveButtons.map { $0.0 } + projectScopeButtons.map { $0.0 }).enumerated() {
            button.isBordered = false
            button.target = self
            button.action = index < archiveButtons.count ? #selector(applyArchiveFilter(_:)) : #selector(applyProjectScope(_:))
            button.tag = index < archiveButtons.count ? index : index - archiveButtons.count
            button.focusRingType = .none
            addSubview(button)
        }
        timeline.onDateSelectionChanged = { [weak self] in
            guard let self else { return }
            if !self.timeline.dateSelectionFilterEnabled { self.restoreUnfilteredDatePosition() }
            self.updateDateFilterControl(); self.needsDisplay = true
        }
        dateButton.action = #selector(showDateView)
        dateButton.toolTip = "Show all chats by creation date"
        projectButton.action = #selector(showProjectView)
        projectButton.toolTip = "Show chats grouped by project"
        timelineButton.action = #selector(showTimelineView)
        timelineButton.toolTip = "Show messages across chats on one daily timeline"
        columnsButton.action = #selector(showColumnsView)
        columnsButton.toolTip = "Show time-aligned message columns"
        activeButton.action = #selector(showActiveView)
        activeButton.toolTip = "Show confirmed live activity in local desktop chats"
        lanesButton.action = #selector(showLanesView)
        lanesButton.toolTip = "Show recorded user messages in colored chat lanes"
        previousDayButton.action = #selector(previousDay)
        previousDayButton.toolTip = "Previous day"
        previousDayButton.setAccessibilityLabel("Previous day")
        nextDayButton.action = #selector(nextDay)
        nextDayButton.toolTip = "Next day"
        nextDayButton.setAccessibilityLabel("Next day")
        if persistTheme && persistViewDefaults, let saved = UserDefaults.standard.string(forKey: "unifiedChatPresentation"), let presentation = ChatPresentation(rawValue: saved) {
            timeline.setPresentation(presentation)
        } else if persistTheme { timeline.setPresentation(.date) }
        installDocument()
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 12, y: 10, width: 17, height: 17)
        minimizeButton.frame = NSRect(x: 37, y: 10, width: 17, height: 17)
        fullScreenButton.frame = NSRect(x: 62, y: 10, width: 17, height: 17)
        findButton.frame = NSRect(x: 91, y: 9, width: 54, height: 19)
        modeButton.frame = NSRect(x: bounds.width - 113, y: 7, width: 100, height: 23)
        let tabs: [(NSButton, CGFloat)] = [(dateButton, 60), (projectButton, 87), (timelineButton, 83), (columnsButton, 90), (lanesButton, 70), (activeButton, 108)]
        let archiveStart = bounds.width - 22 - 226
        let projectScopeStart = archiveStart - 12 - 174
        var tabX: CGFloat = 22
        for (button, width) in tabs {
            button.frame = NSRect(x: tabX, y: 43, width: width, height: 21)
            tabX += width
        }
        let filterY: CGFloat = dateControlsWrap ? 70 : 43
        var projectScopeX = projectScopeStart
        for (button, width) in [(projectScopeAllButton, CGFloat(42)), (projectScopeNonProjectButton, 78), (projectScopeProjectButton, 54)] {
            button.frame = NSRect(x: projectScopeX, y: filterY, width: width, height: 21)
            projectScopeX += width
        }
        var archiveX = archiveStart
        for (button, width) in [(archiveAllButton, CGFloat(42)), (archiveNonArchivedButton, 106), (archiveArchivedButton, 78)] {
            button.frame = NSRect(x: archiveX, y: filterY, width: width, height: 21)
            archiveX += width
        }
        previousDayButton.frame = NSRect(x: 22, y: 77, width: 20, height: 21)
        nextDayButton.frame = NSRect(x: 42, y: 77, width: 20, height: 21)
        dateSearch?.frame = NSRect(x: 22, y: dateControlsWrap ? 97 : 70, width: bounds.width - 44, height: 24)
        canvasButton.frame = NSRect(x: 116,y: dateMetadataTop + dateFunnelSide/2 - 12,width:148,height:24)
        let listTop: CGFloat = showingDateControls ? max(104 + (dateControlsWrap ? 27 : 0) + dateSearchHeight, dateMetadataTop + dateFunnelSide + 4) : 104
        scroll.frame = NSRect(x: 1, y: listTop, width: bounds.width - 2, height: max(1, bounds.height - listTop - 29))
        lanePanel.frame = scroll.frame
        historyPane.frame = scroll.frame; searchPane.frame = scroll.frame; dayFeedPane.frame = scroll.frame; labelPane.frame = scroll.frame
        dayInput.frame = NSRect(x: 72, y: 77, width: 126, height: 22)
        todayButton.frame = NSRect(x: 204, y: 77, width: 54, height: 22)
        feedButton.frame = NSRect(x: 264, y: 77, width: 54, height: 22)
        chartButton.frame = NSRect(x: 318, y: 77, width: 62, height: 22)
        if timeline.presentation == .columns { columnsView?.arrange(width: scroll.contentView.bounds.width) }
        else if timeline.presentation == .timeline { messageDay.setViewportWidth(scroll.contentView.bounds.width) }
        else if let document = scroll.documentView {
            if document === timeline { timeline.fitViewport(scroll.contentView.bounds.size) }
            else { document.setFrameSize(NSSize(width: scroll.contentView.bounds.width, height: max(document.frame.height, scroll.contentView.bounds.height))) }
        }
        layoutDateSelectionControl()
    }

    private func layoutDateSelectionControl() {
        guard timeline.presentation == .date, scroll.documentView === timeline else { return }
        let column = timeline.convert(timeline.dateConnectionsColumn, to: self)
        let side = column.width
        let alignedX = column.minX
        let x = alignedX >= 330 && alignedX + side <= bounds.width - 22 ? alignedX : bounds.width - 22 - side
        selectionFilterButton.frame = NSRect(x: x, y: dateMetadataTop, width: side, height: side)
        needsDisplay = true
    }

    func show(_ snapshot: ChatSnapshot) {
        lastTurnGeneration += 1
        let previousOffset = scroll.contentView.bounds.origin
        self.snapshot = snapshot
        chatCanvas.update(snapshot)
        searchPane.updateSnapshot(snapshot)
        timeline.derivedLabels = library.state.labels.mapValues(\.text)
        loading = false; errorMessage = nil
        timeline.isHidden = false
        let wasFiltering = timeline.dateSelectionFilterEnabled
        timeline.setSnapshot(snapshot)
        timeline.setDateVisibleChatIDs(dateSearch?.update(chats: snapshot.chats, labels: timeline.derivedLabels))
        activeChats.projects = Dictionary(snapshot.chats.map { ($0.id, $0.project.name) }, uniquingKeysWith: { first, _ in first })
        updateDateFilterControl()
        let height = scroll.documentView?.frame.height ?? 0
        scroll.contentView.scroll(to: NSPoint(x: previousOffset.x, y: min(previousOffset.y, max(0, height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        if wasFiltering && !timeline.dateSelectionFilterEnabled { restoreUnfilteredDatePosition() }
        metadataToolTip = "\(snapshot.sourceURL.path)\nProjects: \(snapshot.projectSourceURL.path)\nRead-only metadata snapshot. \(snapshot.excludedSubagents) recorded subagents excluded.\nDates in \(TimeZone.current.identifier). Refresh: ⌘R.\n\(snapshot.projectSourceIssue ?? "")"
        updateHoverToolTips()
        needsDisplay = true
        if timeline.presentation == .timeline { loadTimeline(force: true) }
        for view in [ChatPresentation.columns, .lanes] where view == timeline.presentation || (view == .columns ? columnsView != nil : lanePanel.snapshot != nil) {
            extraDirty.insert(view)
            if view == timeline.presentation && overlay == nil { loadExtra(view) }
        }
    }

    func showError(_ message: String) {
        loading = false; errorMessage = message
        metadataToolTip = message; updateHoverToolTips(); needsDisplay = true
        timeline.isHidden = snapshot == nil
        if snapshot == nil { messageDay.showError(message) }
    }

    func toggleDateSelectionFilter() {
        guard timeline.presentation == .date else { return }
        if timeline.dateSelectionFilterEnabled { _ = clearDateSelectionFilter(); return }
        guard !timeline.dateConnectionProjects.isEmpty, timeline.dateProjectScope != .nonProject else { return }
        let offset = scroll.contentView.bounds.origin
        unfilteredDateOffset = offset
        unfilteredDateQuery = dateSearch?.queryKey
        if let entry = timeline.entries.first(where: { $0.chat != nil && $0.y + $0.height > offset.y }), let chat = entry.chat {
            unfilteredDateAnchor = (chat.id, offset.y - entry.y)
        }
        timeline.setDateSelectionFilterEnabled(true)
        scrollDate(to: .zero)
        updateDateFilterControl()
        needsDisplay = true
    }

    @discardableResult func clearDateSelectionFilter() -> Bool {
        guard overlay == nil, timeline.presentation == .date, timeline.dateSelectionFilterEnabled else { return false }
        timeline.setDateSelectionFilterEnabled(false)
        restoreUnfilteredDatePosition()
        updateDateFilterControl()
        needsDisplay = true
        return true
    }

    private func restoreUnfilteredDatePosition() {
        guard var offset = unfilteredDateOffset else { return }
        if unfilteredDateQuery != dateSearch?.queryKey { offset = .zero }
        else if let anchor = unfilteredDateAnchor, let entry = timeline.entries.first(where: { $0.chat?.id == anchor.id }) {
            offset.y = entry.y + anchor.dy
        }
        scrollDate(to: offset)
        unfilteredDateOffset = nil; unfilteredDateAnchor = nil; unfilteredDateQuery = nil
    }

    private var dateSearchScope: String {
        let projects = timeline.dateSelectionFilterEnabled ? timeline.dateConnectionProjects.keys.map(\.savedKey).sorted() : []
        return String(describing: [timeline.dateArchiveFilter.rawValue, String(timeline.dateProjectScope.rawValue), String(timeline.dateSelectionFilterEnabled)] + projects)
    }

    private func applyDateSearch(_ ids: Set<String>?) {
        guard showingDateControls, let dateSearch else { return }
        if timeline.dateVisibleChatIDs == nil && ids != nil {
            let offset = scroll.contentView.bounds.origin
            let anchor = timeline.entries.first { $0.chat != nil && $0.y + $0.height > offset.y }
            dateSearch.returnPosition = DateSearchBar.ReturnPosition(offset: offset, chatID: anchor?.chat?.id, deltaY: offset.y - (anchor?.y ?? offset.y), scope: dateSearchScope)
        }
        timeline.setDateVisibleChatIDs(ids)
        var position = NSPoint.zero
        if ids == nil {
            if let saved = dateSearch.returnPosition, saved.scope == dateSearchScope {
                position = saved.offset
                if let id = saved.chatID, let entry = timeline.entries.first(where: { $0.chat?.id == id }) { position.y = entry.y + saved.deltaY }
            }
            dateSearch.returnPosition = nil
        }
        scrollDate(to: position)
        updateDateFilterControl(); needsDisplay = true
    }

    @discardableResult func revealDateChat(_ id: String) -> Bool {
        guard let chat = snapshot?.chats.first(where: { $0.id == id }) else { return false }
        setPresentation(.date)
        if !timeline.dateArchiveFilter.includes(chat) { timeline.setDateArchiveFilter(.all) }
        if !timeline.dateProjectScope.includes(chat) { timeline.setDateProjectScope(.all) }
        if timeline.dateSelectionFilterEnabled, timeline.dateConnectionProjects[chat.project.identity] == nil {
            _ = clearDateSelectionFilter()
        }
        dateSearch?.clearIfHiding(id)
        guard let row = timeline.entries.first(where: { $0.chat?.id == id }) else { return false }
        updateDateFilterControl(); needsLayout = true; layoutSubtreeIfNeeded()
        scrollDate(to: NSPoint(x: 0, y: max(0, row.y - 44)))
        window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(timeline)
        needsDisplay = true
        return true
    }

    private func scrollDate(to offset: NSPoint) {
        scroll.contentView.scroll(to: NSPoint(
            x: max(0, min(offset.x, timeline.frame.width - scroll.contentView.bounds.width)),
            y: max(0, min(offset.y, timeline.frame.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func setDateArchiveFilter(_ filter: DateArchiveFilter) {
        guard timeline.presentation == .date, timeline.dateArchiveFilter != filter else { return }
        timeline.setDateArchiveFilter(filter)
        scrollDate(to: .zero)
        updateDateFilterControl()
        needsDisplay = true
    }

    @objc private func applyArchiveFilter(_ button: NSButton) {
        guard DateArchiveFilter.allCases.indices.contains(button.tag) else { return }
        setDateArchiveFilter(DateArchiveFilter.allCases[button.tag])
    }

    func setDateProjectScope(_ scope: DateProjectScope) {
        guard timeline.presentation == .date, timeline.dateProjectScope != scope else { return }
        timeline.setDateProjectScope(scope)
        unfilteredDateOffset = timeline.dateSelectionFilterEnabled ? .zero : nil
        unfilteredDateAnchor = nil
        unfilteredDateQuery = dateSearch?.queryKey
        scrollDate(to: .zero)
        updateDateFilterControl()
        needsDisplay = true
    }

    @objc private func applyProjectScope(_ button: NSButton) {
        guard let scope = DateProjectScope(rawValue: button.tag) else { return }
        setDateProjectScope(scope)
    }

    @objc private func toggleSelectionFilterClicked() { toggleDateSelectionFilter() }

    private func updateDateFilterControl() {
        canvasButton.isHidden = !showingDateControls
        canvasButton.isEnabled = snapshot != nil
        canvasButton.attributedTitle = NSAttributedString(string:"OPEN CANVAS (\(chatCanvas.selected.count))",attributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.bold),.foregroundColor:canvasButton.isEnabled ? ink : muted])
        dateSearch?.isHidden = !showingDateControls
        dateSearch?.showCount(visible: timeline.dateChatCount, total: snapshot?.chats.count ?? 0, archived: timeline.dateArchivedCount)
        findButton.isEnabled = snapshot != nil
        findButton.attributedTitle = NSAttributedString(string: "FIND", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: overlay == .search ? AppTheme.palette(dark:dark,green:green).onSelection : ink])
        for (button, filter) in archiveButtons {
            let selected = timeline.dateArchiveFilter == filter
            button.isHidden = overlay != nil || timeline.presentation != .date
            button.attributedTitle = NSAttributedString(string: filter.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: selected ? AppTheme.palette(dark:dark,green:green).onSelection : ink
            ])
            button.state = selected ? .on : .off
            button.setAccessibilityLabel("Archive filter: \(filter.menuTitle)\(selected ? ", selected" : "")")
            button.toolTip = "\(filter.menuTitle). Combines with the project filter. Unknown archive status is included in All."
        }
        for (button, scope) in projectScopeButtons {
            let selected = timeline.dateProjectScope == scope
            button.isHidden = overlay != nil || timeline.presentation != .date
            button.attributedTitle = NSAttributedString(string: scope.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: selected ? AppTheme.palette(dark:dark,green:green).onSelection : ink
            ])
            button.state = selected ? .on : .off
            button.setAccessibilityLabel("Project scope: \(scope.description)\(selected ? ", selected" : "")")
            button.setAccessibilityHelp(scope == .nonProject ? "Show unassigned chats. Turns off the selection filter while keeping selected projects." : scope.description)
        }
        selectionFilterButton.isHidden = overlay != nil || timeline.presentation != .date
        selectionFilterButton.isEnabled = !timeline.dateConnectionProjects.isEmpty && timeline.dateProjectScope != .nonProject
        selectionFilterButton.state = timeline.dateSelectionFilterEnabled ? .on : .off
        selectionFilterButton.setAccessibilityLabel("Filter selected projects")
        selectionFilterButton.setAccessibilityValue(timeline.dateSelectionFilterEnabled ? "on" : "off")
        selectionFilterButton.toolTip = nil
        selectionFilterButton.setAccessibilityHelp(timeline.dateProjectScope == .nonProject ? "Choose ALL or PROJECT to filter selected projects." : timeline.dateConnectionProjects.isEmpty ? "Select projects using the connection buttons." : timeline.dateSelectionFilterEnabled ? "Show the full current scope (Escape), keeping selected projects and restoring your previous position." : "Show chats from all selected projects together, newest first.")
        layoutDateSelectionControl()
        updateHoverToolTips()
    }

    private func updateHoverToolTips() {
        let suppress = timeline.presentation == .date && overlay == nil
        toolTip = suppress ? nil : metadataToolTip
        for control in subviews.compactMap({ $0 as? NSControl }) {
            let key = ObjectIdentifier(control)
            if suppress {
                if let hint = control.toolTip {
                    suppressedControlTips[key] = hint
                    control.setAccessibilityHelp(hint)
                }
                control.toolTip = nil
            } else if let hint = suppressedControlTips.removeValue(forKey: key), control.toolTip == nil {
                control.toolTip = hint
            }
        }
    }

    func adjustTextSize(by factor: CGFloat) {
        textMagnification = TextSizing.clamp(textMagnification * factor)
        if persistTheme && persistViewDefaults { UserDefaults.standard.set(textMagnification, forKey: TextSizing.preferenceKey) }
        applyTextSize()
    }
    func resetTextSize() {
        textMagnification = 1
        if persistTheme && persistViewDefaults { UserDefaults.standard.set(1, forKey: TextSizing.preferenceKey) }
        applyTextSize()
    }
    private func applyTextSize() {
        let operation = ExplorerDiagnostics.begin("layout.apply_zoom", diagnosticState())
        defer { ExplorerDiagnostics.end("layout.apply_zoom", operation, diagnosticState()) }
        let position = scroll.contentView.bounds.origin
        let top = position.y
        let anchor = timeline.presentation == .date ? timeline.entries.first(where: { $0.chat != nil && $0.y + $0.height > top }) : nil
        for content in [scroll, lanePanel.scroll] {
            content.allowsMagnification = true
            content.minMagnification = TextSizing.minimum
            content.maxMagnification = TextSizing.maximum
            if abs(content.magnification - textMagnification) > 0.000001 {
                content.setMagnification(textMagnification, centeredAt: content.documentVisibleRect.origin)
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        lanePanel.needsLayout = true
        lanePanel.layoutSubtreeIfNeeded()
        if let anchor, let id = anchor.chat?.id, let current = timeline.entries.first(where: { $0.chat?.id == id }) {
            scrollDate(to: NSPoint(x: position.x, y: current.y + top - anchor.y))
        }
        historyPane.setTheme(dark: dark, green: green, scale: textMagnification)
        searchPane.setTheme(dark: dark, green: green, scale: textMagnification)
        dayFeedPane.setTheme(dark: dark, green: green, scale: textMagnification)
        labelPane.setTheme(dark: dark, green: green, scale: textMagnification)
        window?.invalidateCursorRects(for: timeline)
        needsDisplay = true
    }

    func setDark(_ value: Bool) { setTheme(value ? .dark : .light) }
    func setTheme(_ theme: AppTheme) { if persistTheme { AppearanceSettings.shared.choose(theme) } else { dark=theme.isDark;green=theme == .green;applyTheme() } }

    func setPresentation(_ presentation: ChatPresentation) {
        var fields = diagnosticState(); fields["destination"] = .text(presentation.rawValue)
        ExplorerDiagnostics.event("navigation.view", fields)
        if overlay != nil { closeOverlay() }
        guard timeline.presentation != presentation else { return }
        cancelViewReads()
        viewOffsets[timeline.presentation] = scroll.contentView.bounds.origin
        timeline.setPresentation(presentation)
        installDocument()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if persistTheme && persistViewDefaults { UserDefaults.standard.set(presentation.rawValue, forKey: "unifiedChatPresentation") }
        let offset = viewOffsets[presentation] ?? NSPoint(x: 0, y: presentation == .columns ? (columnsView?.initialOffset ?? 0) : 0)
        let height = scroll.documentView?.frame.height ?? 0
        scroll.contentView.scroll(to: NSPoint(x: min(offset.x, max(0, (scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width)), y: min(offset.y, max(0, height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateViewButtons()
        needsDisplay = true
        if presentation == .timeline { loadTimeline() }
        if presentation == .columns, columnsView == nil || extraDirty.contains(.columns) { loadExtra(.columns) }
        if presentation == .lanes, lanePanel.snapshot == nil || extraDirty.contains(.lanes) { loadExtra(.lanes) }
    }

    func diagnosticState() -> [String: DiagnosticValue] {
        var fields = ExplorerDiagnostics.rect(scroll.contentView.bounds, prefix: "viewport")
        fields.merge(ExplorerDiagnostics.rect(timeline.visibleRect, prefix: "timeline_visible"), uniquingKeysWith: { $1 })
        fields.merge(ExplorerDiagnostics.rect(historyPane.scroll.contentView.bounds, prefix: "reader_viewport"), uniquingKeysWith: { $1 })
        fields["view"] = .text(timeline.presentation.rawValue); fields["overlay"] = .text(overlay.map { String(describing: $0) } ?? "none")
        fields["zoom"] = .number(textMagnification); fields["rows"] = .integer(Int64(timeline.entries.count))
        fields["chat_id"] = overlay == .history ? historyPane.chat.map { .text($0.id) } ?? .null : .null
        fields["window"] = .integer(Int64(window?.windowNumber ?? -1)); fields["fullscreen"] = .flag(window?.styleMask.contains(.fullScreen) == true)
        return fields
    }

    var hasLabelWork: Bool { labelCoordinator.isRunning }
    var labelRequestCount: Int { labelCoordinator.startedRequests }
    func stopLabelWork(completion: (() -> Void)? = nil) {
        labelPreparation.cancel(); labelJob?.cancelled = true
        labelCoordinator.cancel(completion: completion)
    }
    private func abandonLabel() {
        if overlay == .label { labelPreparation.cancel(); labelIntent = UUID(); labelJob?.cancelled = true; labelCoordinator.cancel() }
    }
    private func prepareLabel(chat: Chat, snapshot: ChatSnapshot, autoStart: LabelProvider? = nil) {
        guard !labelCoordinator.isRunning else { return }
        if overlay != .label { labelReturnOverlay = overlay; rememberDatePosition() }
        labelReturnsToListOnSuccess = autoStart != nil && labelReturnOverlay == nil
        labelPreparation.cancel(); let token = HistoryCancellation(); labelPreparation = token
        let intent = UUID(); labelIntent = intent; labelChat = chat; labelSample = nil
        overlay = .label; installDocument(); updateViewButtons(); needsLayout = true; layoutSubtreeIfNeeded()
        labelPane.prepare(chat: chat, existing: library.state.labels[chat.id]); needsDisplay = true
        if let issue = library.issue { labelPane.failure(issue + " No model was started."); return }
        labelPreparationQueue.async { [weak self] in
            let result = Result { try LabelSampler.prepare(chat: chat, snapshot: snapshot, cancellation: token) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.labelIntent == intent, !token.cancelled, self.overlay == .label else { return }
                switch result {
                case .success(let sample):
                    self.labelSample = sample; self.labelPane.ready(sample)
                    if let autoStart { self.generateLabel(provider: autoStart) }
                case .failure(let error): self.labelPane.failure(error.localizedDescription)
                }
            }
        }
    }
    private func generateLabel(provider: LabelProvider) {
        guard overlay == .label, !labelCoordinator.isRunning, let chat = labelChat, let sample = labelSample else { return }
        do {
            let id = try labelCoordinator.start(provider: provider, sample: sample)
            labelJob = LabelJob(id: id, intent: labelIntent, chat: chat, sample: sample, provider: provider)
            labelPane.busy("Starting one bounded label request…"); needsDisplay = true
        } catch { labelPane.ready(sample); labelPane.event(LabelWorkerEvent(kind: "error", jobID: "", message: error.localizedDescription)) }
    }
    private func labelEvent(_ event: LabelWorkerEvent) {
        guard let job = labelJob, event.jobID == job.id else { return }
        if overlay == .label && labelIntent == job.intent { labelPane.event(event) }
        if event.kind == "settled" {
            var saved = false
            if !job.cancelled, let text = event.label {
                do {
                    let value = DerivedChatLabel(text: text, provider: job.provider == .local ? "Local" : "Luna", model: event.model ?? "unknown", generatedAt: Date(), sourceReferences: job.sample.references, effort: event.effort, sourceHashes: job.sample.hashes, sampledMessages: job.sample.sampledMessages, totalMessages: job.sample.totalMessages, inputBytes: job.sample.prompt.utf8.count)
                    try library.setLabel(value, chatID: job.chat.id)
                    saved = true
                } catch { if overlay == .label { labelPane.failure("Label returned, but saving failed: " + error.localizedDescription) } }
            }
            labelJob = nil
            if saved && labelReturnsToListOnSuccess && overlay == .label && labelIntent == job.intent { returnFromLabel() }
            onLabelSettled?()
        }
        needsDisplay = true
    }
    private func returnFromLabel() {
        labelPreparation.cancel()
        if labelCoordinator.isRunning {
            labelJob?.cancelled = true; labelPane.busy("Stopping the owned model request…")
            labelCoordinator.cancel { [weak self] in
                guard let self, self.overlay == .label else { return }
                self.overlay = self.labelReturnOverlay; self.installDocument(); self.updateViewButtons(); self.restoreDatePosition(); self.resumeVisibleRead(); self.needsDisplay = true
            }
        } else { overlay = labelReturnOverlay; installDocument(); updateViewButtons(); restoreDatePosition(); resumeVisibleRead(); needsDisplay = true }
    }

    @objc func showFind() {
        ExplorerDiagnostics.event("navigation.find", diagnosticState())
        guard let snapshot else { return }
        rememberDatePosition()
        if overlay == .search { searchPane.focusQuery(); return }
        cancelViewReads()
        abandonLabel(); historyPane.hideReader(); overlay = .search
        installDocument(); updateViewButtons(); needsLayout = true; layoutSubtreeIfNeeded()
        searchPane.show(snapshot: snapshot); needsDisplay = true
    }
    @objc func showSavedItems() {
        ExplorerDiagnostics.event("navigation.saved", diagnosticState())
        guard let snapshot else { return }
        rememberDatePosition()
        cancelViewReads()
        abandonLabel(); historyPane.hideReader(); overlay = .search
        installDocument(); updateViewButtons(); needsLayout = true; layoutSubtreeIfNeeded()
        searchPane.show(snapshot: snapshot, mode: .saved); needsDisplay = true
    }
    func openChat(_ id: String, focus: Int64? = nil, saved: SavedExcerpt? = nil) {
        var fields = diagnosticState(); fields["chat_id"] = .text(id); fields["focus_ordinal"] = focus.map(DiagnosticValue.integer) ?? .null
        let operation = ExplorerDiagnostics.begin("navigation.open", fields)
        defer { ExplorerDiagnostics.end("navigation.open", operation, diagnosticState()) }
        rememberDatePosition()
        cancelViewReads()
        abandonLabel()
        readerReturnsToSearch = overlay == .search
        searchPane.hideSearch(); dayFeedPane.hideSearch(); overlay = .history
        installDocument(); updateViewButtons(); needsLayout = true; layoutSubtreeIfNeeded()
        if let snapshot, let chat = snapshot.chats.first(where: { $0.id == id }) { historyPane.show(chat: chat, snapshot: snapshot, focus: focus) }
        else if let saved { historyPane.showSaved(saved) }
        else { historyPane.showUnavailable(title: id, reason: "The referenced chat is not present in the current local metadata. Refresh the index or open a saved excerpt.") }
        needsDisplay = true
    }
    private func returnFromReader() {
        let operation = ExplorerDiagnostics.begin("navigation.back", diagnosticState())
        defer { ExplorerDiagnostics.end("navigation.back", operation, diagnosticState()) }
        overlay = readerReturnsToSearch ? .search : nil; readerReturnsToSearch = false
        installDocument(); updateViewButtons(); restoreDatePosition(); resumeVisibleRead(); needsDisplay = true
    }
    private func closeOverlay() {
        ExplorerDiagnostics.event("navigation.close_overlay", diagnosticState())
        abandonLabel(); historyPane.hideReader(); searchPane.hideSearch(); overlay = nil; readerReturnsToSearch = false
        installDocument(); updateViewButtons(); restoreDatePosition(); resumeVisibleRead(); needsDisplay = true
    }
    private func rememberDatePosition() {
        guard overlay == nil, timeline.presentation == .date else { return }
        let offset = scroll.contentView.bounds.origin
        let anchor = timeline.entries.first { $0.chat != nil && $0.y + $0.height > offset.y }
        dateReturnPosition = (offset, anchor?.chat?.id, offset.y - (anchor?.y ?? offset.y))
    }
    private func restoreDatePosition() {
        guard overlay == nil, let saved = dateReturnPosition else { return }
        dateReturnPosition = nil
        guard timeline.presentation == .date else { return }
        needsLayout = true; layoutSubtreeIfNeeded()
        var offset = saved.offset
        if let id = saved.chatID, let row = timeline.entries.first(where: { $0.chat?.id == id }) { offset.y = row.y + saved.deltaY }
        scrollDate(to: offset)
    }
    private func ownedLibraryChanged() {
        let offset = scroll.contentView.bounds.origin
        let anchor = timeline.entries.first { $0.chat != nil && $0.y + $0.height > offset.y }
        let anchorID = anchor?.chat?.id, deltaY = offset.y - (anchor?.y ?? offset.y)
        historyPane.refreshOwnedData()
        let state = library.state
        timeline.derivedLabels = state.labels.mapValues(\.text)
        timeline.setAnnotations(state); activeChats.setAnnotations(state)
        timeline.setDateVisibleChatIDs(dateSearch?.update(chats: snapshot?.chats ?? [], labels: timeline.derivedLabels))
        updateDateFilterControl(); needsDisplay = true
        searchPane.refreshOwnedData()
        if overlay == nil && timeline.presentation == .date {
            var restored = offset
            if let anchorID, let row = timeline.entries.first(where: { $0.chat?.id == anchorID }) { restored.y = row.y + deltaY }
            scrollDate(to: restored)
        }
    }

    func showActive(_ snapshot: ActiveSnapshot) {
        if !sharedReconciliation {
        func current(_ value: ActiveSnapshot?) -> [String: ActiveChatRow] {
            guard let value, value.connected else { return [:] }
            return Dictionary(value.rows.filter { $0.host == "local" && $0.confirmedAt != nil && ["working", "waiting"].contains($0.state) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let old = current(activeChats.snapshot), new = current(snapshot)
        let known = Set(self.snapshot?.chats.map(\.id) ?? [])
        for id in Set(old.keys).union(new.keys).intersection(known) {
            if old[id]?.state != new[id]?.state || old[id]?.turnID != new[id]?.turnID {
                pendingLastTurns[id] = PendingLastTurn(expectedID: new[id]?.turnID ?? old[id]?.turnID,
                    needsEnding: new[id] == nil, deadline: ProcessInfo.processInfo.systemUptime + 15)
            }
        }
        }
        let previous = activeChats.snapshot?.confirmedCount
        activeChats.show(snapshot)
        timeline.setWorkingChats(snapshot)
        if previous != snapshot.confirmedCount { updateViewButtons() }
        if (timeline.presentation == .active && overlay == nil) || previous != snapshot.confirmedCount { needsDisplay = true }
        refreshLastTurnsIfNeeded()
    }

    /// Existing activity snapshots drive bounded reconciliation; no new timer.
    /// The indexed terminal row can arrive shortly after the live status change.
    private func refreshLastTurnsIfNeeded() {
        guard !sharedReconciliation, loadOnDemand, let snapshot, !readingLastTurns else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let known = Set(snapshot.chats.map(\.id))
        pendingLastTurns = pendingLastTurns.filter { known.contains($0.key) && $0.value.deadline > now }
        let batch = Dictionary(pendingLastTurns.prefix(128).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard !batch.isEmpty else { return }
        readingLastTurns = true
        let generation = lastTurnGeneration
        let source = HistoryStore.source(for: snapshot), paths = LastReplyStore.rolloutPaths(for: snapshot.chats)
        lastTurnQueue.async { [weak self] in
            let result = Result { try LastReplyStore.load(chatIDs: Array(batch.keys), from: source, rolloutPaths: paths) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingLastTurns = false
                guard self.lastTurnGeneration == generation else { return }
                let applicable = Set(batch.keys.filter { self.pendingLastTurns[$0]?.ticket == batch[$0]?.ticket })
                let patch: LastReplySnapshot
                switch result {
                case .success(let value): patch = value
                case .failure(let error): patch = LastReplySnapshot(sourceURL: source, replies: [:], issue: error.localizedDescription)
                }
                self.timeline.mergeLastTurns(patch, for: applicable)
                for id in applicable {
                    guard let pending = batch[id], patch.issue == nil, patch.issues[id] == nil else { continue }
                    let turn = patch.replies[id]
                    let matches = pending.expectedID == nil || pending.expectedID == turn?.turnID
                    if matches && (!pending.needsEnding || (turn?.isTerminal == true && turn?.finishedAt != nil)) {
                        self.pendingLastTurns.removeValue(forKey: id)
                    }
                }
            }
        }
    }
    @objc private func showActiveView() { setPresentation(.active) }
    @objc private func showDateView() { setPresentation(.date) }
    @objc private func showProjectView() { setPresentation(.project) }
    @objc private func showTimelineView() { setPresentation(.timeline) }
    @objc private func showColumnsView() { setPresentation(.columns) }
    @objc private func showLanesView() { setPresentation(.lanes) }

    private func installDocument() {
        let feedVisible = overlay == nil && timeline.presentation == .timeline && timelineFeed
        dayFeedPane.isHidden = !feedVisible
        lanePanel.isHidden = overlay != nil || timeline.presentation != .lanes
        scroll.isHidden = overlay != nil || timeline.presentation == .lanes || feedVisible
        historyPane.isHidden = overlay != .history
        searchPane.isHidden = overlay != .search
        labelPane.isHidden = overlay != .label
        let document: NSView
        switch timeline.presentation {
        case .active: document = activeChats
        case .timeline: document = messageDay
        case .columns: document = columnsView ?? columnsPlaceholder
        default: document = timeline
        }
        if scroll.documentView !== document { scroll.documentView = document }
        scroll.hasHorizontalScroller = [.date, .timeline, .columns].contains(timeline.presentation)
        scroll.scrollerStyle = [.timeline, .columns].contains(timeline.presentation) ? .legacy : .overlay
        applyTextSize()
    }

    private func loadExtra(_ presentation: ChatPresentation) {
        guard loadOnDemand else { return }
        guard let snapshot else { return }
        extraCancellations[presentation]?.cancel()
        let cancellation = HistoryCancellation()
        extraCancellations[presentation] = cancellation
        extraDirty.insert(presentation)
        let request = UUID(); extraRequests[presentation] = request
        extraStatus[presentation] = "Reading local records…"
        viewQueue.async { [weak self] in
            guard !cancellation.cancelled else { return }
            if presentation == .columns {
                let result = Result { try ColumnsStore.load(snapshot, cancellation: cancellation) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !cancellation.cancelled, self.extraRequests[presentation] == request else { return }
                    self.extraCancellations.removeValue(forKey: presentation)
                    switch result {
                    case .success(let data): self.extraDirty.remove(presentation); self.showColumns(data)
                    case .failure(let error): self.extraStatus[presentation] = "UNAVAILABLE · \(error.localizedDescription)"
                    }
                    self.needsDisplay = true
                }
            } else {
                let result = Result { try LaneStore.load(home: snapshot.sourceURL.deletingLastPathComponent(), metadata: snapshot, cancellation: cancellation) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !cancellation.cancelled, self.extraRequests[presentation] == request else { return }
                    self.extraCancellations.removeValue(forKey: presentation)
                    switch result {
                    case .success(let data): self.extraDirty.remove(presentation); self.showLanes(data)
                    case .failure(let error): self.extraStatus[presentation] = "UNAVAILABLE · \(error.localizedDescription)"; self.lanePanel.showError(error.localizedDescription)
                    }
                    self.needsDisplay = true
                }
            }
        }
    }

    private func cancelViewReads() {
        messageCancellation.cancel(); messageRequest = UUID()
        for token in extraCancellations.values { token.cancel() }
        extraCancellations.removeAll()
        dayFeedPane.hideSearch()
    }

    private func resumeVisibleRead() {
        guard overlay == nil else { return }
        if timeline.presentation == .timeline { loadTimeline() }
        else if extraDirty.contains(timeline.presentation) { loadExtra(timeline.presentation) }
    }

    deinit {
        if let canvasSelectionObservation { selectionWorkspace?.removeSelectionObserver(canvasSelectionObservation) }
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        if persistTheme { AppearanceSettings.shared.flush() }
        if let dateHeaderScrollObservation { NotificationCenter.default.removeObserver(dateHeaderScrollObservation) }
        messageCancellation.cancel(); labelPreparation.cancel()
        for token in extraCancellations.values { token.cancel() }
    }

    func showColumns(_ data: ColumnsSnapshot) {
        let first = columnsView == nil
        let offset = scroll.contentView.bounds.origin
        if let columnsView { columnsView.show(data) }
        else { columnsView = ChatColumnsView(snapshot: data); columnsView?.pinHeader(to: scroll.contentView) }
        columnsView?.onOpenChat = { [weak self] id in self?.openChat(id) }
        columnsView?.dark = dark
        columnsView?.green = green
        extraStatus[.columns] = "\(data.scope) · \(data.gaps?.count ?? 0) SOURCE GAPS"
        if timeline.presentation == .columns {
            installDocument(); needsLayout = true; layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: first ? NSPoint(x: 0, y: columnsView?.initialOffset ?? 0) : offset); scroll.reflectScrolledClipView(scroll.contentView)
        }
        needsDisplay = true
    }

    func showLanes(_ data: LaneSnapshot) {
        let first = lanePanel.snapshot == nil
        lanePanel.show(data)
        if first { lanePanel.showOverlap() }
        extraStatus[.lanes] = "\(data.chats.count) RECENT CHATS · INDEXED USER HISTORY · LARGE PAYLOADS DEFERRED · \(data.issues) SOURCE ISSUES"
        needsDisplay = true
    }
    @objc private func previousDay() { changeDay(-1) }
    @objc private func nextDay() { changeDay(1) }

    private func changeDay(_ delta: Int) {
        selectedDay = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay)!
        scroll.contentView.scroll(to: .zero)
        updateViewButtons(); loadTimeline(force: true)
        needsDisplay = true
    }

    private func loadTimeline(force: Bool = false) {
        guard overlay == nil, loadOnDemand, let snapshot else { return }
        if timelineFeed { dayFeedPane.showDay(snapshot: snapshot, day: selectedDay, force: force) }
        else if force || messageDay.data?.interval.start != Calendar.current.startOfDay(for: selectedDay) { loadMessageDay() }
    }
    @objc private func showTimelineFeed() { setTimelineFeed(true) }
    @objc private func showTimelineChart() { setTimelineFeed(false) }
    func setTimelineFeed(_ value: Bool) {
        messageCancellation.cancel(); messageRequest = UUID()
        timelineFeed = value; dayFeedPane.hideSearch()
        if persistTheme && persistViewDefaults { UserDefaults.standard.set(value ? "feed" : "chart", forKey: "timelineLayout") }
        installDocument(); updateViewButtons(); loadTimeline(); needsDisplay = true
    }
    @objc private func showToday() { selectedDay = Calendar.current.startOfDay(for: Date()); displayedDay = nil; updateViewButtons(); loadTimeline(force: true); needsDisplay = true }
    @objc private func selectDay() {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard dayInput.stringValue.count == 10, let day = formatter.date(from: dayInput.stringValue), formatter.string(from: day) == dayInput.stringValue else { dayInput.toolTip = "Enter a valid day as YYYY-MM-DD."; displayedDay = nil; updateViewButtons(); return }
        selectedDay = Calendar.current.startOfDay(for: day); updateViewButtons(); loadTimeline(force: true); needsDisplay = true
    }

    func showMessageDay(_ data: MessageDay) {
        selectedDay = data.interval.start
        messageDay.show(data)
        needsLayout = true; needsDisplay = true
    }

    private func loadMessageDay() {
        guard loadOnDemand else { return }
        guard let snapshot else { return }
        messageCancellation.cancel()
        let cancellation = HistoryCancellation(); messageCancellation = cancellation
        let oldOffset = scroll.contentView.bounds.origin
        messageDay.beginLoading()
        let day = selectedDay, request = UUID()
        messageRequest = request
        viewQueue.async { [weak self] in
            guard !cancellation.cancelled else { return }
            let result = Result { try MessageTimelineStore.load(snapshot, day: day, cancellation: cancellation) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !cancellation.cancelled, self.messageRequest == request, self.selectedDay == day else { return }
                switch result {
                case .success(let data):
                    self.showMessageDay(data)
                    if self.timeline.presentation == .timeline && !self.timelineFeed && self.overlay == nil {
                        self.layoutSubtreeIfNeeded()
                        self.scroll.contentView.scroll(to: oldOffset)
                        self.scroll.reflectScrolledClipView(self.scroll.contentView)
                    }
                case .failure(let error): self.messageDay.showError(error.localizedDescription); self.needsDisplay = true
                }
            }
        }
    }

    private func updateViewButtons() {
        updateDateFilterControl()
        previousDayButton.isHidden = overlay != nil || timeline.presentation != .timeline
        nextDayButton.isHidden = overlay != nil || timeline.presentation != .timeline
        for button in [todayButton,feedButton,chartButton] { button.isHidden = overlay != nil || timeline.presentation != .timeline }
        dayInput.isHidden = overlay != nil || timeline.presentation != .timeline
        if displayedDay != selectedDay {
            let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "yyyy-MM-dd"; dayInput.stringValue = dayFormatter.string(from: selectedDay)
            displayedDay = selectedDay
        }
        dayInput.textColor = ink; dayInput.backgroundColor = paper
        for (button, title, selected) in [(todayButton,"TODAY",false),(feedButton,"FEED",timelineFeed),(chartButton,"CHART",!timelineFeed)] {
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: selected ? AppTheme.palette(dark:dark,green:green).onSelection : ink])
            button.setAccessibilityLabel("\(title.capitalized)\(selected ? ", selected" : "")")
        }
        for (button, title) in [(previousDayButton, "‹"), (nextDayButton, "›")] {
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: ink])
        }
        for (button, presentation, title) in [(dateButton, ChatPresentation.date, "DATE"), (projectButton, ChatPresentation.project, "PROJECT"), (timelineButton, ChatPresentation.timeline, "TIMELINE"), (columnsButton, ChatPresentation.columns, "COLUMNS"), (lanesButton, ChatPresentation.lanes, "LANES"), (activeButton, ChatPresentation.active, "ACTIVE \(activeChats.snapshot?.confirmedCount ?? 0)")] {
            let selected = timeline.presentation == presentation
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: selected ? AppTheme.palette(dark:dark,green:green).onSelection : ink
            ])
            button.state = selected ? .on : .off
            button.setAccessibilityLabel("\(title.capitalized) view\(selected ? ", selected" : "")")
        }
        updateHoverToolTips()
    }

    @objc private func toggleMode() { AppearancePanel.shared.show(nil) }
    @objc private func closeWindow() { if let canvasExplorerPanel { canvasExplorerPanel.dismiss() } else { window?.close() } }
    @objc func minimizeWindow() { if let canvasExplorerPanel { canvasExplorerPanel.setCollapsed(true) } else { window?.miniaturize(nil) } }
    @objc func toggleFullScreen() { window?.toggleFullScreen(nil) }

    private func applyTheme() {
        chatCanvas.setTheme(dark:dark,green:green)
        dateSearch?.setTheme(dark: dark, green: green)
        activeChats.dark = dark; activeChats.green = green
        timeline.dark = dark
        timeline.green = green
        messageDay.green = green
        messageDay.dark = dark
        columnsView?.dark = dark
        columnsView?.green = green
        lanePanel.setTheme(green ? .green : dark ? .dark : .light)
        historyPane.setTheme(dark: dark, green: green, scale: textMagnification)
        searchPane.setTheme(dark: dark, green: green, scale: textMagnification)
        dayFeedPane.setTheme(dark: dark, green: green, scale: textMagnification)
        labelPane.setTheme(dark: dark, green: green, scale: textMagnification)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if persistTheme { NSApp.appearance=appearance }
        window?.backgroundColor = paper
        modeButton.attributedTitle = NSAttributedString(string: (AppearanceSettings.shared.isCustom && persistTheme ? "◐ CUSTOM" : (green ? AppTheme.green : dark ? .dark : .light).title), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: ink
        ])
        updateViewButtons()
        needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyTheme() }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); bounds.fill()
        border.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let title = AppBranding.displayName
        let titleWidth: CGFloat = ceil((title as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)]).width) + 8
        let x = (bounds.width - titleWidth) / 2
        for y in stride(from: CGFloat(10.5), through: CGFloat(28.5), by: 3) {
            line(from: NSPoint(x: 154, y: y), to: NSPoint(x: x - 13, y: y), color: border)
            line(from: NSPoint(x: x + titleWidth + 13, y: y), to: NSPoint(x: bounds.width - 128, y: y), color: border)
        }
        label(title, in: NSRect(x: x, y: 10, width: titleWidth, height: 20), size: 15, weight: .bold, color: ink, alignment: .center)
        NSBezierPath(rect: closeButton.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSBezierPath(rect: minimizeButton.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSBezierPath(rect: fullScreenButton.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        line(from: NSPoint(x: 17.5, y: 15.5), to: NSPoint(x: 23.5, y: 21.5), color: ink)
        line(from: NSPoint(x: 17.5, y: 21.5), to: NSPoint(x: 23.5, y: 15.5), color: ink)
        line(from: NSPoint(x: 42, y: 19.5), to: NSPoint(x: 49, y: 19.5), color: ink)
        for (x, dx) in [(CGFloat(66.5), CGFloat(3)), (CGFloat(74.5), CGFloat(-3))] {
            for (y, dy) in [(CGFloat(14.5), CGFloat(3)), (CGFloat(22.5), CGFloat(-3))] {
                line(from: NSPoint(x: x, y: y), to: NSPoint(x: x + dx, y: y), color: ink)
                line(from: NSPoint(x: x, y: y), to: NSPoint(x: x, y: y + dy), color: ink)
            }
        }
        if overlay == .search { AppTheme.palette(dark:dark,green:green).selection.setFill(); findButton.frame.fill() }
        border.setStroke(); NSBezierPath(rect: findButton.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        border.setStroke(); NSBezierPath(rect: modeButton.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        line(from: NSPoint(x: 0, y: 36.5), to: NSPoint(x: bounds.width, y: 36.5), color: border)
        AppTheme.palette(dark:dark,green:green).selection.setFill()
        for (button, view) in [(dateButton, ChatPresentation.date), (projectButton, .project), (timelineButton, .timeline), (columnsButton, .columns), (lanesButton, .lanes), (activeButton, .active)] {
            if timeline.presentation == view { button.frame.fill() }
            border.setStroke(); NSBezierPath(rect: button.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        if overlay != nil {
            label(overlay == .label ? "MANUAL SHORT LABEL · SOURCE TITLE UNCHANGED" : overlay == .history ? "RECORDED CHAT READER" : "FIND CHATS & SAVED EXCERPTS", in: NSRect(x: 22, y: 81, width: bounds.width - 44, height: 17), size: 10, weight: .bold, color: ink)
        } else if timeline.presentation == .timeline {
            for button in [previousDayButton, nextDayButton, todayButton, feedButton, chartButton] {
                if (button === feedButton && timelineFeed) || (button === chartButton && !timelineFeed) { AppTheme.palette(dark:dark,green:green).selection.setFill(); button.frame.fill() }
                NSBezierPath(rect: button.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        } else {
            let scope = timeline.presentation == .active ? "LIVE CODEX STATUS" : timeline.presentation == .columns ? "TODAY · LAST 8 / CHAT" : timeline.presentation == .lanes ? "USER MESSAGE HISTORY" : "CREATED ↓"
            label(scope, in: NSRect(x: 22, y: metadataLabelY, width: 240, height: 17), size: 10, weight: .bold, color: ink)
        }
        if overlay == nil && timeline.presentation == .date {
            border.setStroke(); NSBezierPath(rect:canvasButton.frame.insetBy(dx:0.5,dy:0.5)).stroke()
            let rect = selectionFilterButton.frame
            DateProjectControls.draw(.filter, in: rect, selected: timeline.dateSelectionFilterEnabled, enabled: selectionFilterButton.isEnabled, ink: ink, paper: paper, accent: ink)
            let count = timeline.dateConnectionProjects.count
            let selection = "\(count) PROJECT\(count == 1 ? "" : "S") SELECTED"
            label(selection, in: NSRect(x: max(140, rect.minX - 172), y: metadataLabelY, width: min(164, rect.minX - 148), height: 17), size: 10, color: muted, alignment: .right)
            AppTheme.palette(dark:dark,green:green).selection.setFill()
            let segments = archiveButtons.map { ($0.0, timeline.dateArchiveFilter == $0.1) }
                + projectScopeButtons.map { ($0.0, timeline.dateProjectScope == $0.1) }
            for (button, selected) in segments {
                if selected { button.frame.fill() }
                border.setStroke(); NSBezierPath(rect: button.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
        let counts: String
        switch timeline.presentation {
        case .date where snapshot != nil && (timeline.dateSelectionFilterEnabled || timeline.dateArchiveFilter != .all || timeline.dateProjectScope != .all || timeline.dateVisibleChatIDs != nil):
            counts = "\(timeline.dateChatCount) OF \(snapshot?.chats.count ?? 0) CHATS · \(timeline.dateArchivedCount) ARCHIVED"
        case .active: counts = "\(activeChats.snapshot?.confirmedCount ?? 0) CONFIRMED · \(activeChats.snapshot?.rows.filter { $0.state == "unknown" }.count ?? 0) UNKNOWN"
        case .timeline: counts = timelineFeed ? dayFeedPane.feedSummary : messageDay.data.map { "\($0.count) MSG · \($0.lanes.count) CHATS" } ?? messageDay.status
        case .columns: counts = columnsView.map { "\($0.snapshot.messageCount) MSG · \($0.snapshot.chats.count) CHATS" } ?? (extraStatus[.columns] ?? "READING…")
        case .lanes: counts = lanePanel.snapshot.map { "\($0.messageCount) USER MSG · \($0.chats.count) CHATS" } ?? (extraStatus[.lanes] ?? "READING…")
        default: counts = snapshot.map { "\($0.chats.count) CHATS · \($0.archivedCount) ARCHIVED" } ?? (loading ? "READING LOCAL INDEX…" : "INDEX UNAVAILABLE")
        }
        let countsX: CGFloat = timeline.presentation == .timeline ? 392 : 270
        if overlay == nil && !(timeline.presentation == .date && dateSearch != nil) { label(counts, in: NSRect(x: countsX, y: metadataLabelY, width: max(1, (timeline.presentation == .date ? selectionFilterButton.frame.minX - 184 : bounds.width - 22) - countsX), height: 17), size: 10, color: muted, alignment: .right) }
        line(from: NSPoint(x: 0, y: scroll.frame.minY - 0.5), to: NSPoint(x: bounds.width, y: scroll.frame.minY - 0.5), color: border)
        let footerY = bounds.height - 28.5
        line(from: NSPoint(x: 0, y: footerY), to: NSPoint(x: bounds.width, y: footerY), color: border)
        let status: String
        if let errorMessage { status = "\(snapshot == nil ? "INDEX UNAVAILABLE" : "STALE LIST") · \(errorMessage)" }
        else if labelCoordinator.isRunning { status = overlay == .label ? "MANUAL LABEL WORKER · ONE REQUEST · CANCELLABLE" : "STOPPING LABEL WORKER · SOURCE CHATS UNCHANGED" }
        else if overlay == .label { status = "LABEL WORKER STOPPED · APP-OWNED ANNOTATIONS ONLY" }
        else if overlay != nil { status = "LOCAL · READ ONLY · SOURCE CHATS UNCHANGED" }
        else if timeline.presentation == .active { status = "READ ONLY · " + activeChats.summary }
        else if loading { status = "READING LOCAL INDEX…" }
        else if [.columns, .lanes].contains(timeline.presentation) { status = "READ ONLY · " + (extraStatus[timeline.presentation] ?? "READING…") }
        else if timeline.presentation == .timeline {
            if timelineFeed { status = "READ ONLY · RECORDED INPUTS/REPLIES · WINDOW FOCUS UNRECORDED" }
            else {
                let unreadable = messageDay.data?.unreadableRecords ?? 0
                status = unreadable > 0 ? "READ ONLY · \(unreadable) UNREADABLE MESSAGE RECORDS" : "READ ONLY · INDEXED USER/ASSISTANT MESSAGES · DAY OVERVIEW"
            }
        }
        else if snapshot?.projectSourceIssue != nil { status = "LOCAL · READ ONLY · PROJECTS UNAVAILABLE" }
        else if let snapshot, snapshot.issueCount > 0 { status = "LOCAL · READ ONLY · \(snapshot.issueCount) METADATA WARNINGS" + (timeline.presentation == .date ? "" : " · HOVER !") }
        else { status = "LOCAL · READ ONLY" }
        label(status, in: NSRect(x: 15, y: bounds.height - 20, width: bounds.width - 160, height: 15), size: 9, color: muted)
        label("\(TimeZone.current.abbreviation() ?? "LOCAL") · REFRESH ⌘R", in: NSRect(x: bounds.width - 143, y: bounds.height - 20, width: 130, height: 15), size: 9, color: muted, alignment: .right)
        if snapshot == nil, let errorMessage {
            label("Unable to read local Codex chats.", in: NSRect(x: 22, y: 95, width: bounds.width - 44, height: 22), size: 13, color: ink)
            label(errorMessage, in: NSRect(x: 22, y: 128, width: bounds.width - 44, height: 70), size: 11, color: muted)
        }
    }

    private func duplicateMenu() -> NSMenu? {
        if onDuplicateWindow != nil { return duplicateAction.menu() }
        return (window as? ChatWindow)?.duplicateWindowAction?.menu()
    }
    override func menu(for event: NSEvent) -> NSMenu? { duplicateMenu() }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool {
        if let event,convert(event.locationInWindow,from:nil).y<36{return true}
        return super.acceptsFirstMouse(for:event)
    }
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y < 36 {
            if let canvasExplorerPanel { canvasExplorerPanel.track(event, resize: false) }
            else if let onWindowDrag { onWindowDrag(event) }
            else { window?.performDrag(with: event) }
        }
    }

    @objc func openCanvas() { chatCanvas.open() }

    func render(to url: URL) throws {
        layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { throw StoreError(message: "Cannot render window.") }
        cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw StoreError(message: "Cannot encode window.") }
        try png.write(to: url)
    }
}
