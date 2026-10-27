import Foundation
import AppKit
import WindowingKit

struct ExplorerPanelPlacement: Codable, Equatable {
    var id: String = UUID().uuidString
    var x: Double, y: Double, width: Double, height: Double
    var collapsed = false
    var frame: NSRect { NSRect(x:x,y:y,width:width,height:height) }
    var valid: Bool { !id.isEmpty && [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && x <= 100_000_000 && y <= 100_000_000 && width >= 602 && width <= 3000 && height >= 370 && height <= 3000 }
}
struct CanvasDocument: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var chats: [CanvasPlacement]
    var explorers: [ExplorerPanelPlacement] = []
}
/// App-specific canvas records and transfer rules over the reusable workspace store.
final class CanvasDocumentStore {
    static let primaryID = "primary"
    private let storage: WorkspaceStore<CanvasDocument>
    var documents: [CanvasDocument] { storage.documents }
    var issue: String? { storage.issue }
    var isReadOnly: Bool { storage.isReadOnly }
    var hasUnsavedChanges: Bool { storage.hasUnsavedChanges }
    var onIssue: ((String?) -> Void)? {
        get { storage.onIssue }
        set { storage.onIssue = newValue }
    }
    init(file: URL? = nil, legacy: Data? = nil) {
        var initial = [CanvasDocument(id: Self.primaryID, name: "Canvas", chats: [])]
        var issue: String?
        var imported = false
        if !(file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false), let legacy {
            do {
                let values = try JSONDecoder().decode([CanvasPlacement].self, from: legacy)
                guard Self.valid(CanvasDocument(id: Self.primaryID, name: "Canvas", chats: values)) else {
                    throw StoreError(message: "Invalid legacy canvas")
                }
                initial[0].chats = values; imported = true
            } catch {
                issue = "The previous canvas could not be read; its original preference is preserved. This store is read-only."
            }
        }
        storage = WorkspaceStore(file: file, initialDocuments: initial,
                                 initialHasUnsavedChanges: imported, initialIssue: issue, valid: Self.valid)
    }
    static func persistent() -> CanvasDocumentStore {
        CanvasDocumentStore(file:ExplorerLibrary.defaultDirectory.appendingPathComponent("canvas-documents-v1.json"),legacy:UserDefaults.standard.data(forKey:"chatCanvasWorkspaceV1"))
    }
    func document(_ id:String) -> CanvasDocument? { storage.document(id) }
    private static func valid(_ document:CanvasDocument)->Bool {
        !document.id.isEmpty && !document.name.isEmpty
            && document.chats.allSatisfy{$0.isValidTransfer && !$0.presentationID.isEmpty}
            && Set(document.chats.map(\.presentationID)).count==document.chats.count
            && document.explorers.allSatisfy(\.valid)
            && Set(document.explorers.map(\.id)).count==document.explorers.count
    }
    @discardableResult func observe(_ callback: @escaping (String) -> Void) -> UUID { storage.observe(callback) }
    func removeObserver(_ id: UUID) { storage.removeObserver(id) }
    @discardableResult func createCanvas() -> String? {
        let id = UUID().uuidString
        return storage.transaction { documents in
            documents.append(CanvasDocument(id: id, name: "Canvas \(documents.count + 1)", chats: [])); return true
        } ? id : nil
    }
    @discardableResult func change(_ id: String, _ body: (inout CanvasDocument) -> Void) -> Bool { storage.change(id, body) }
    @discardableResult func moveChat(_ instance:String,from source:String,to target:String,at point:NSPoint,incoming:CanvasPlacement? = nil) -> Bool {
        guard !isReadOnly,point.x.isFinite,point.y.isFinite,let from=documents.firstIndex(where:{$0.id==source}),let to=documents.firstIndex(where:{$0.id==target}),let old=documents[from].chats.first(where:{$0.presentationID==instance}) else{return false}
        if let incoming {guard incoming.isValidTransfer,incoming.id==old.id,incoming.presentationID==instance else{return false}}
        var value=old;value.x=max(0,point.x);value.y=max(0,point.y)
        if from != to,let incoming {value.readY=incoming.readY}
        guard value.isValidTransfer else{return false}
        if from==to{return change(source){ d in if let i=d.chats.firstIndex(where:{$0.presentationID==instance}){d.chats[i]=value} }}
        guard !documents[to].chats.contains(where:{$0.presentationID==instance}) else{return false}
        return storage.transaction { documents in
            documents[from].chats.removeAll{$0.presentationID==instance};documents[to].chats.append(value)
            return true
        }
    }
    @discardableResult func moveExplorer(_ instance:String,from source:String,to target:String,at point:NSPoint) -> Bool {
        guard !isReadOnly,point.x.isFinite,point.y.isFinite,let old=document(source)?.explorers.first(where:{$0.id==instance}) else{return false}
        var value=old;value.x=max(0,point.x);value.y=max(0,point.y)
        if source != target,document(target)?.explorers.contains(where:{$0.id==instance}) == true{return false}
        return commitExplorerTransfer(placement:value,fromCanvas:source,toCanvas:target)
    }
    func preflightExplorerTransfer(placement:ExplorerPanelPlacement,fromCanvas:String?,toCanvas:String)->Bool {
        explorerTransfer(placement:placement,fromCanvas:fromCanvas,toCanvas:toCanvas) != nil
    }
    /// Validate again at commit time. Every observer sees both membership edits
    /// together, and no failed transaction publishes partial model changes.
    @discardableResult func commitExplorerTransfer(placement:ExplorerPanelPlacement,fromCanvas:String?,toCanvas:String)->Bool {
        guard let next=explorerTransfer(placement:placement,fromCanvas:fromCanvas,toCanvas:toCanvas) else{return false}
        return storage.transaction { $0 = next; return true }
    }
    private func explorerTransfer(placement:ExplorerPanelPlacement,fromCanvas:String?,toCanvas:String)->[CanvasDocument]? {
        guard !isReadOnly,placement.valid,let target=documents.firstIndex(where:{$0.id==toCanvas}) else{return nil}
        var next=documents
        if let fromCanvas {
            guard let source=next.firstIndex(where:{$0.id==fromCanvas}),next[source].explorers.contains(where:{$0.id==placement.id}) else{return nil}
            if source != target {next[source].explorers.removeAll{$0.id==placement.id}}
        }
        // A desktop reference cannot implicitly take membership from a third board.
        guard !next.enumerated().contains(where:{$0.offset != target && $0.element.explorers.contains(where:{$0.id==placement.id})}) else{return nil}
        if let index=next[target].explorers.firstIndex(where:{$0.id==placement.id}) {next[target].explorers[index]=placement}
        else {next[target].explorers.append(placement)}
        return next
    }
    @discardableResult func flush() -> Bool { storage.flush() }
}
