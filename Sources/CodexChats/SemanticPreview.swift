import AppKit

/// Real saved results, rendered inside the app's initialized AppKit process.
/// The window remains offscreen; no model inference, source imports or production preferences.
func renderSemanticPreview(to destination: URL) throws {
    dispatchPrecondition(condition: .onQueue(.main))
    let index = ExplorerLibrary.defaultDirectory.appendingPathComponent("SemanticSearch/index-v1.sqlite")
    guard FileManager.default.fileExists(atPath:index.path) else { throw SemanticFailure("Saved semantic index is unavailable for preview.") }
    let snapshot = try ChatStore.load()
    let store = try SemanticIndexStore(url:index)
    let hits = try store.search(query:"model",vector:nil,mode:.exact,filters:SemanticFilters(),modelDigest:"",limit:80,cancellation:HistoryCancellation())
    let counts = try store.counts(modelDigest:SemanticModelRuntime.expectedDigest)
    guard !hits.isEmpty else { throw SemanticFailure("The saved index contains no matches for the preview question.") }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-native-preview-\(UUID())")
    try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:temporary) }
    let suite = "semantic-native-preview-\(UUID())"
    guard let defaults = UserDefaults(suiteName:suite) else { throw SemanticFailure("Cannot create isolated preview preferences.") }
    let coordinator = SemanticCoordinator(databaseURL:temporary.appendingPathComponent("unused-index.sqlite"),defaults:defaults,allowWork:false)
    let pane = SearchPane(library:ExplorerLibrary(directory:temporary),coordinator:coordinator)
    pane.frame = NSRect(x:0,y:0,width:940,height:900)
    pane.setTheme(dark:true,green:false,scale:1)
    pane.showSemanticPreview(snapshot:snapshot,hits:hits,counts:counts)
    let window = NSWindow(contentRect:pane.bounds,styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = pane
    defer { window.contentView = nil; window.close() }
    pane.layoutSubtreeIfNeeded()
    guard let bitmap = pane.bitmapImageRepForCachingDisplay(in:pane.bounds) else { throw SemanticFailure("Cannot allocate native FIND preview bitmap.") }
    pane.cacheDisplay(in:pane.bounds,to:bitmap)
    guard let png = bitmap.representation(using:.png,properties:[:]) else { throw SemanticFailure("Cannot encode native FIND preview.") }
    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
    try png.write(to:destination,options:.atomic)
    guard !window.isVisible, !window.isKeyWindow else { throw SemanticFailure("Preview unexpectedly became visible.") }
}
