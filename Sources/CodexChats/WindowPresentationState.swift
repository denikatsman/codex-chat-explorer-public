import AppKit

/// Value snapshots for duplication. These contain loaded records and navigation, never views,
/// workers, cancellation tokens, model requests, or ownership of shared app data.
struct WindowPresentationState {
    enum Overlay { case history, search }
    var timeline: TimelineView.PresentationState
    var textMagnification: CGFloat
    var selectedDay: Date
    var timelineFeed: Bool
    var viewOffsets: [ChatPresentation: NSPoint]
    var scrollOffset: NSPoint
    var dateSearch: DateSearchBar.PresentationState?
    var unfilteredDateOffset: NSPoint?
    var unfilteredDateAnchor: (id: String, dy: CGFloat)?
    var unfilteredDateQuery: String?
    var dateReturnPosition: (offset: NSPoint, chatID: String?, deltaY: CGFloat)?
    var overlay: Overlay?
    var readerReturnsToSearch: Bool
    var history: HistoryPane.PresentationState
    var search: SearchPane.PresentationState
    var dayFeed: SearchPane.PresentationState
    var columns: ColumnsSnapshot?
    var lanes: NativeLaneRoot.PresentationState
    var messageDay: MessageDayView.PresentationState
    var extraStatus: [ChatPresentation: String]
    var extraDirty: Set<ChatPresentation>
    var active: ActiveSnapshot?

    static func selection(_ value: NSRange, length: Int) -> NSRange {
        let location = min(max(0, value.location), length)
        return NSRange(location: location, length: min(max(0, value.length), length - location))
    }
    static func scroll(_ view: NSScrollView, to point: NSPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        view.contentView.scroll(to: point); view.reflectScrolledClipView(view.contentView)
    }
}
