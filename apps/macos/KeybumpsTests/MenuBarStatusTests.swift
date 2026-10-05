import AppKit
import Testing
@testable import Keybumps

@MainActor
@Suite("The menu bar item's text and menu sections")
struct MenuBarStatusTests {
    @Test("Text and sections come from capabilities in registry order, and each change redraws once")
    func ordering() {
        let status = MenuBarStatus()
        var redraws = 0
        status.onChange = { redraws += 1 }
        let timer = CapabilityMenuBarStatus(status: status, capability: .timer)
        let snippets = CapabilityMenuBarStatus(status: status, capability: .snippets)

        timer.setTitle("3:12", spoken: "Tea, 3 minutes left")
        timer.setTitle("3:12", spoken: "Tea, 3 minutes left")
        #expect(redraws == 1)
        timer.setItems([MenuBarItem(id: "tea", title: "Tea — 3:12", systemImage: nil, action: {})])
        snippets.setItems([MenuBarItem(id: "a", title: "A", systemImage: nil, action: {})])
        #expect(status.title == "3:12")
        #expect(status.spokenTitle == "Tea, 3 minutes left")
        #expect(status.sections.map { $0.map(\.id) } == [["a"], ["tea"]], "Snippets comes before Timer")

        timer.clear()
        #expect(status.title == nil)
        #expect(status.sections.map { $0.map(\.id) } == [["a"]])
        #expect(redraws == 4)
    }

    @Test("The menu starts with capabilities' sections, after Restart to Update, and their items run their actions")
    func menu() throws {
        let status = MenuBarStatus()
        var ran: [String] = []
        CapabilityMenuBarStatus(status: status, capability: .timer).setItems([
            MenuBarItem(id: "tea", title: "Tea — 3:12", systemImage: "timer", action: { ran.append("tea") }),
            MenuBarItem(id: "openTimers", title: "Open Timers", systemImage: "list.bullet", action: { ran.append("open") }),
        ])
        let controller = NativeStatusItemController(router: MainWindowRouter())
        controller.configureStatus(status)
        controller.configureUpdater(snapshot: { UpdateReminderTests.ready }, checkNow: {}, restartWhenSafe: {})
        let menu = controller.makeMenu()

        #expect(menu.items.prefix(6).map(\.title) == ["Restart to Update", "", "Tea — 3:12", "Open Timers", "", "Open Keybumps"])
        let tea = try #require(menu.items.first { $0.title == "Tea — 3:12" })
        let action = try #require(tea.action)
        _ = (tea.target as? NSObject)?.perform(action, with: tea)
        #expect(ran == ["tea"])
    }
}
