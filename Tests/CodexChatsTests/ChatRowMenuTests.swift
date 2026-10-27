import AppKit
import XCTest
@testable import CodexChats

final class ChatRowMenuTests: XCTestCase {
    func testActualMenuDispatchRetainsTargetsAndDeliversOnlyTheSelectedAction() throws {
        _ = NSApplication.shared
        var pins = [String](), colors = [String](), summaries = [String]()
        let menu = ChatRowAppearance.menu(chatID: "fixture", state: ExplorerLibraryState(),
            onPin: { pins.append($0) }, onTag: { colors.append("\($0):\($1?.rawValue ?? "none")") },
            onSummary: { summaries.append("\($0):\($1.rawValue)") })
        let pin = try XCTUnwrap(menu.items.first { $0.title == "Pin Chat" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(pin.action), to: pin.target, from: pin))
        let green = try XCTUnwrap(menu.items.first { $0.title == "Colored Dot" }?.submenu?.items.first { $0.title == "Green" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(green.action), to: green.target, from: green))
        let local = try XCTUnwrap(menu.items.first { $0.title == "AI Summary · Local Model" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(local.action), to: local.target, from: local))
        XCTAssertEqual(pins, ["fixture"])
        XCTAssertEqual(colors, ["fixture:green"])
        XCTAssertEqual(summaries, ["fixture:local"])
    }
}
