import WindowingKit
import AppKit

/// One bounded cache/read queue/render budget for all canvas and chat windows in an app session.
final class SharedCanvasResources {
    static let invalidated=Notification.Name("SharedCanvasResourcesInvalidated")
    let queue=DispatchQueue(label:"explorer.shared-canvas-reads",qos:.userInitiated,autoreleaseFrequency:.workItem)
    let cache=NSCache<NSString,CanvasMessageBox>()
    let readers=VisibleReaderBudget(limit:16,perWindowLimit:8)
    private let indices=NSCache<NSString,CanvasIndexBox>()
    func index(chat:Chat,chats:[String:Chat],source:URL,revision:Date,cancellation:HistoryCancellation) throws -> PreparedCanvasHistory {
        let key="\(source.path)|\(chat.id)|\(revision.timeIntervalSince1970)" as NSString
        if let cached=indices.object(forKey:key) {return cached.value}
        let value=try CanvasHistoryStore.index(chat:chat,chats:chats,source:source,cancellation:cancellation)
        guard !cancellation.cancelled else{throw StoreError(message:"Read cancelled.")}
        let formatter=DateFormatter();formatter.dateStyle = .medium;formatter.timeStyle = .medium
        let rows=value.messages.map { ["role":$0.role,"date":$0.createdAt.map{formatter.string(from:$0)} ?? "TIME UNKNOWN","source":$0.key] }
        let prepared=PreparedCanvasHistory(index:value,rows:rows)
        indices.setObject(CanvasIndexBox(prepared),forKey:key,cost:value.messages.count*384)
        return prepared
    }
    func invalidate(chatID:String? = nil,notify:Bool = true) {
        indices.removeAllObjects();cache.removeAllObjects()
        if notify {NotificationCenter.default.post(name:Self.invalidated,object:self,userInfo:chatID.map{["chatID":$0]})}
    }
    init() { cache.totalCostLimit=64*1024*1024;cache.countLimit=320;indices.totalCostLimit=32*1024*1024;indices.countLimit=64 }
}

struct PreparedCanvasHistory {let index:CanvasHistoryIndex;let rows:[[String:String]]}
private final class CanvasIndexBox:NSObject {let value:PreparedCanvasHistory;init(_ value:PreparedCanvasHistory){self.value=value}}
