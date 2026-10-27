import XCTest
import AppKit
import ExplorerDiagnosticsBridge
@testable import CodexChats

final class DiagnosticIntegrationTests: XCTestCase {
    func testRealDataReaderBackEvidenceAndExactBundle() throws {
        guard let path = ProcessInfo.processInfo.environment["EXPLORER_DIAGNOSTIC_SOURCE"],
              let output = ProcessInfo.processInfo.environment["EXPLORER_DIAGNOSTIC_OUTPUT"] else { throw XCTSkip("Explicit real-data source and local evidence output required") }
        XCTAssertTrue(Thread.isMainThread); _ = NSApplication.shared
        let snapshot = try ChatStore.load(from:URL(fileURLWithPath:path))
        let source = HistoryStore.source(for:snapshot)
        var selected = [Chat]()
        for chat in snapshot.chats.prefix(20) {
            if !(try HistoryStore.page(chatID:chat.id,source:source,limit:1)).messages.isEmpty { selected.append(chat) }
            if selected.count == 3 { break }
        }
        XCTAssertEqual(selected.count,3)
        let diagnostics = ExplorerDiagnostics.shared
        diagnostics.start(root:URL(fileURLWithPath:output))
        let recorder = try XCTUnwrap(diagnostics.recorder)
        let root = ChatRootView(frame:NSRect(x:0,y:0,width:940,height:650),persistTheme:false,loadOnDemand:false)
        let window = ChatWindow(contentSize:root.frame.size); window.contentView = root
        defer { diagnostics.stop(timeout:5); window.contentView = nil; window.close() }
        diagnostics.captureView = { [weak root] in root?.diagnosticState() ?? [:] }
        root.show(snapshot); root.setPresentation(.date); root.layoutSubtreeIfNeeded()
        let reader = try XCTUnwrap(root.subviews.compactMap{$0 as? HistoryPane}.first)
        let back = try XCTUnwrap(reader.subviews.compactMap{$0 as? NSButton}.first{$0.title == "‹ BACK"})
        func recorded() throws -> [DiagnosticRecord] {
            XCTAssertTrue(recorder.flush(timeout:5))
            var result = [DiagnosticRecord]()
            for file in try FileManager.default.contentsOfDirectory(at:recorder.sessionURL,includingPropertiesForKeys:nil).filter({$0.pathExtension == "jsonl"}).sorted(by:{$0.path < $1.path}) {
                try DiagnosticReader.scan(file) { result.append($0) }
            }
            return result
        }
        for (index,chat) in selected.enumerated() {
            root.scroll.contentView.scroll(to:NSPoint(x:0,y:74+CGFloat(index)*42))
            root.openChat(chat.id)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                RunLoop.current.run(until:Date().addingTimeInterval(0.05))
                if try recorded().filter({$0.event == "reader.page.end" && $0.fields["outcome"] == .text("ok")}).count == index+1 { break }
            }
            XCTAssertFalse(reader.isHidden)
            back.performClick(nil); root.layoutSubtreeIfNeeded(); root.timeline.resetCursorRects()
            XCTAssertTrue(reader.isHidden)
        }
        let records = try recorded()
        XCTAssertEqual(records.filter{$0.event == "navigation.open.begin"}.count,3)
        XCTAssertEqual(records.filter{$0.event == "navigation.back.end"}.count,3)
        XCTAssertEqual(records.filter{$0.event == "reader.page.end" && $0.fields["outcome"] == .text("ok")}.count,3)
        XCTAssertTrue(records.contains{$0.event == "cursor.reset"})
        let opens = records.filter{$0.event == "navigation.open.begin"}
        XCTAssertEqual(opens.compactMap{ if case .text(let x) = $0.fields["chat_id"] { return x }; return nil },selected.map(\.id))
        XCTAssertTrue(opens.allSatisfy{$0.fields["viewport_y"] != nil && $0.fields["zoom"] != nil})
        for record in records {
            for key in record.fields.keys { XCTAssertFalse(["text","title","transcript","source_path","query"].contains(key)) }
        }
        let bundle = URL(fileURLWithPath:output+"-export.explorerdiagnostics")
        let exported = expectation(description:"export")
        recorder.export(to:bundle) { result in
            if case .failure(let error) = result { XCTFail("Export failed: \(error)") }; exported.fulfill()
        }
        wait(for:[exported],timeout:10)
        XCTAssertTrue(FileManager.default.fileExists(atPath:bundle.appendingPathComponent("bundle.json").path))
        // Report only counts; personal IDs remain in the explicitly local diagnostic folder.
        print("DIAGNOSTIC_REAL_DATA: chats=\(snapshot.chats.count) opened=3 reader_pages=3 back=3 events=\(records.count) dropped=\(recorder.status.droppedQueue)")
    }
}
