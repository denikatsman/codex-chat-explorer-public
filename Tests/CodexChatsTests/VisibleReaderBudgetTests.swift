import AppKit
import XCTest
@testable import CodexChats

final class VisibleReaderBudgetTests: XCTestCase {
    private func id(_ index: Int) -> UUID { UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",index))! }
    private func view() -> NSView { NSView(frame:NSRect(x:0,y:0,width:300,height:200)) }

    func testGlobalAndPerWindowCapsAreStableAcrossInputOrder() {
        let candidates=(0..<30).map { index in
            VisibleReaderBudget.Candidate(id:id(index),windowID:index/10,isKey:index<10,
                priority:30-index,registrationOrder:UInt64(index))
        }
        let selected=VisibleReaderBudget.allocate(candidates)
        XCTAssertEqual(selected.count,16)
        XCTAssertEqual(selected,Set((0..<8).map(id)+(10..<18).map(id)))
        XCTAssertEqual(selected,VisibleReaderBudget.allocate(candidates.reversed()))
        for window in 0..<3 { XCTAssertLessThanOrEqual(candidates.filter { $0.windowID == AnyHashable(window) && selected.contains($0.id) }.count,8) }
    }

    func testVisibilityFocusPriorityAndOptionalLimits() {
        let candidates=[
            VisibleReaderBudget.Candidate(id:id(0),windowID:0,isVisible:false,isKey:true,priority:100),
            VisibleReaderBudget.Candidate(id:id(1),windowID:1,priority:100),
            VisibleReaderBudget.Candidate(id:id(2),windowID:1,focusOrder:5),
            VisibleReaderBudget.Candidate(id:id(3),windowID:2,isKey:true),
            VisibleReaderBudget.Candidate(id:id(4),windowID:1,priority:200)
        ]
        XCTAssertEqual(VisibleReaderBudget.allocate(candidates,limit:2),Set([id(2),id(3)]))
        XCTAssertEqual(VisibleReaderBudget.allocate(candidates,limit:3,perWindowLimit:1),Set([id(2),id(3)]))
        XCTAssertEqual(VisibleReaderBudget.allocate(candidates,limit:20,perWindowLimit:nil).count,4)
        XCTAssertTrue(VisibleReaderBudget.allocate(candidates,limit:0).isEmpty)
        XCTAssertTrue(VisibleReaderBudget.allocate(candidates,perWindowLimit:0).isEmpty)
        XCTAssertEqual(VisibleReaderBudget.allocate(candidates + candidates,limit:20,perWindowLimit:nil).count,4)
        XCTAssertEqual(VisibleReaderBudget.allocate(Array(candidates.suffix(4)),limit:3),Set([id(2),id(3),id(4)]))
    }

    func testBatchingAndRepeatedUpdatesOnlyNotifyAdmissionChanges() {
        let views=[view(),view(),view()]
        var events=[String]()
        let budget=VisibleReaderBudget(limit:1,observeWindows:false) { _ in .init(id:1,isVisible:true) }
        let clients=views.enumerated().map { index, view in budget.register(view) { events.append("\(index):\($0)") } }
        XCTAssertTrue(events.isEmpty)
        budget.performBatchUpdates {
            budget.update(clients[0],wantsVisible:true)
            budget.performBatchUpdates { budget.update(clients[1],wantsVisible:true,priority:10) }
            budget.update(clients[2],wantsVisible:true,priority:20)
            XCTAssertTrue(events.isEmpty)
        }
        XCTAssertEqual(events,["2:true"])
        budget.update(clients[2],wantsVisible:true,priority:20);budget.refresh()
        XCTAssertEqual(events,["2:true"])
        budget.update(clients[0],wantsVisible:true,focused:true)
        XCTAssertEqual(events,["2:true","2:false","0:true"])
        XCTAssertTrue(budget.isAdmitted(clients[0]));XCTAssertFalse(budget.isAdmitted(clients[2]))
        XCTAssertEqual(budget.register(views[0]) { _ in XCTFail("Duplicate registration replaces no callback") },clients[0])
    }

    func testWindowVisibilityAndKeyChangesReallocateWithoutPolling() {
        let views=[view(),view()]
        var states=[ObjectIdentifier(views[0]):VisibleReaderBudget.WindowState(id:1,isVisible:true,isKey:true),
                    ObjectIdentifier(views[1]):VisibleReaderBudget.WindowState(id:2,isVisible:true)]
        var events=[String]()
        let budget=VisibleReaderBudget(limit:1,observeWindows:false) { states[ObjectIdentifier($0)] }
        let clients=views.enumerated().map { index, view in budget.register(view) { events.append("\(index):\($0)") } }
        budget.performBatchUpdates { clients.forEach { budget.update($0,wantsVisible:true) } }
        XCTAssertEqual(events,["0:true"])
        states[ObjectIdentifier(views[0])] = .init(id:1,isVisible:false,isKey:true)
        budget.refresh()
        XCTAssertEqual(events,["0:true","0:false","1:true"])
        states[ObjectIdentifier(views[0])] = .init(id:1,isVisible:true,isKey:true)
        budget.refresh()
        XCTAssertEqual(Array(events.suffix(2)),["1:false","0:true"])
        states.removeAll();budget.refresh()
        XCTAssertFalse(budget.isAdmitted(clients[0]));XCTAssertFalse(budget.isAdmitted(clients[1]))
    }

    func testWeakOwnershipAndUnregistrationReleaseSlots() {
        var first: NSView?=view()
        let second=view()
        var events=[String]()
        let budget=VisibleReaderBudget(limit:1,observeWindows:false) { _ in .init(id:1,isVisible:true) }
        let firstID=budget.register(first!) { events.append("first:\($0)") }
        let secondID=budget.register(second) { events.append("second:\($0)") }
        budget.performBatchUpdates {
            budget.update(firstID,wantsVisible:true);budget.update(secondID,wantsVisible:true)
        }
        XCTAssertTrue(budget.isAdmitted(firstID))
        first=nil
        budget.refresh();XCTAssertTrue(budget.isAdmitted(secondID));XCTAssertFalse(budget.isAdmitted(firstID))
        budget.unregister(secondID);budget.unregister(secondID)
        XCTAssertEqual(events,["first:true","second:true","second:false"])
        XCTAssertFalse(budget.isAdmitted(secondID))
    }

    func testReentrantCallbacksNeverNestOrExceedCapacity() {
        let views=[view(),view()]
        let budget=VisibleReaderBudget(limit:1,observeWindows:false) { _ in .init(id:1,isVisible:true) }
        var ids=[UUID](),active=Set<Int>(),events=[String](),depth=0,moved=false
        for (index,view) in views.enumerated() {
            ids.append(budget.register(view) { [weak budget] admitted in
                depth += 1;XCTAssertEqual(depth,1)
                if admitted { active.insert(index) } else { active.remove(index) }
                XCTAssertLessThanOrEqual(active.count,1)
                events.append("\(index):\(admitted)")
                if index == 0,admitted,!moved { moved=true;budget?.update(ids[1],wantsVisible:true,focused:true) }
                if index == 1,admitted { budget?.unregister(ids[1]) }
                depth -= 1
            })
        }
        budget.update(ids[0],wantsVisible:true)
        XCTAssertEqual(events,["0:true","0:false","1:true","1:false","0:true"])
        XCTAssertEqual(active,Set([0]));XCTAssertTrue(budget.isAdmitted(ids[0]))
    }

    func testCloseNotificationSuspendsBeforeWindowVisibilityChanges() {
        _ = NSApplication.shared
        let reader=view()
        let window=NSWindow(contentRect:reader.bounds,styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=reader
        defer { window.contentView=nil;window.close() }
        XCTAssertFalse(VisibleReaderBudget.liveWindowState(reader)?.isVisible ?? true)
        XCTAssertNil(VisibleReaderBudget.liveWindowState(view()))
        var events=[Bool]()
        // Explicit state keeps this lifecycle fixture entirely offscreen.
        let budget=VisibleReaderBudget { _ in .init(id:1,isVisible:true,isKey:true) }
        let client=budget.register(reader) { events.append($0) }
        budget.update(client,wantsVisible:true)
        NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:window)
        XCTAssertEqual(events,[true,false]);XCTAssertFalse(budget.isAdmitted(client))
        budget.refresh();XCTAssertEqual(events,[true,false])
        NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:window)
        XCTAssertEqual(events,[true,false,true])
        XCTAssertFalse(window.isVisible)
    }
}
