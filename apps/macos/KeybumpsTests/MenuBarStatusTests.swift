import AppKit
import Testing
@testable import Keybumps

@MainActor
@Suite("The menu bar item's text and menu sections")
struct MenuBarStatusTests {
    @Test("Text and sections come from capabilities in registry order, and each change, a checkmark alone included, redraws once")
    func ordering() {
        let status = MenuBarStatus()
        var redraws = 0
        status.onChange = { redraws += 1 }
        let timer = CapabilityMenuBarStatus(status: status, capability: .timer)
        let snippets = CapabilityMenuBarStatus(status: status, capability: .snippets)

        let tea = [MenuBarItem(id: "tea", title: "Tea — 3:12", systemImage: nil, action: {})]
        timer.set(title: "3:12", spoken: "Tea, 3 minutes left", items: tea)
        timer.set(title: "3:12", spoken: "Tea, 3 minutes left", items: tea)
        #expect(redraws == 1, "Text and items together redraw once; the same again, never")
        snippets.set(title: nil, spoken: nil, items: [MenuBarItem(id: "a", title: "A", systemImage: nil, action: {})])
        #expect(status.title == "3:12")
        #expect(status.spokenTitle == "Tea, 3 minutes left")
        #expect(status.sections.map { $0.map(\.id) } == [["a"], ["tea"]], "Snippets comes before Timer")

        timer.clear()
        #expect(status.title == nil)
        #expect(status.sections.map { $0.map(\.id) } == [["a"]])
        #expect(redraws == 3)

        let keystrokes = CapabilityMenuBarStatus(status: status, capability: .keystrokes)
        keystrokes.set(title: nil, spoken: nil, items: [MenuBarItem(id: "show", title: "Show", systemImage: nil, isChecked: true, action: {})])
        keystrokes.set(title: nil, spoken: nil, items: [MenuBarItem(id: "show", title: "Show", systemImage: nil, isChecked: false, action: {})])
        #expect(redraws == 5, "Only the checkmark changed, and it redraws")
    }

    @Test("The menu starts with capabilities' sections, after Restart to Update, and their items run their actions and show their checkmarks")
    func menu() throws {
        let status = MenuBarStatus()
        var ran: [String] = []
        CapabilityMenuBarStatus(status: status, capability: .timer).set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "tea", title: "Tea — 3:12", systemImage: "timer", action: { ran.append("tea") }),
            MenuBarItem(id: "openTimers", title: "Open Timers", systemImage: "list.bullet", action: { ran.append("open") }),
        ])
        CapabilityMenuBarStatus(status: status, capability: .keystrokes).set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "show", title: "Show Keystrokes", systemImage: nil, isChecked: true, action: {}),
        ])
        let controller = NativeStatusItemController(router: MainWindowRouter())
        controller.configureStatus(status)
        controller.configureUpdater(snapshot: { UpdateReminderTests.ready }, checkNow: {}, restartWhenSafe: {})
        let menu = controller.makeMenu()

        #expect(menu.items.prefix(8).map(\.title) == [
            "Restart to Update", "", "Tea — 3:12", "Open Timers", "", "Show Keystrokes", "", "Open Keybumps",
        ])
        let tea = try #require(menu.items.first { $0.title == "Tea — 3:12" })
        let action = try #require(tea.action)
        _ = (tea.target as? NSObject)?.perform(action, with: tea)
        #expect(ran == ["tea"])
        #expect(tea.state == .off)
        #expect(try #require(menu.items.first { $0.title == "Show Keystrokes" }).state == .on, "A checked item has a checkmark")
    }

    @Test("While the menu is open, ticking items and checkmarks update in place, and items coming or going rebuild it")
    func openMenu() throws {
        let status = MenuBarStatus()
        let timer = CapabilityMenuBarStatus(status: status, capability: .timer)
        var ran: [String] = []
        timer.set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "tea", title: "Tea — 3:12", systemImage: "timer", action: { ran.append("old") }),
        ])
        let controller = NativeStatusItemController(router: MainWindowRouter())
        controller.configureStatus(status)
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let row = try #require(menu.items.first)

        timer.set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "tea", title: "Tea — finished", systemImage: "checkmark.circle", action: { ran.append("new") }),
        ])
        controller.refreshMenuBarItem()
        #expect(menu.items.first === row, "Updated in place")
        #expect(row.title == "Tea — finished")
        _ = (row.target as? NSObject)?.perform(try #require(row.action), with: row)
        #expect(ran == ["new"], "The latest action runs")

        timer.set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "eggs", title: "Eggs — 1:00", systemImage: "timer", action: {}),
        ])
        controller.refreshMenuBarItem()
        #expect(menu.items.first?.title == "Eggs — 1:00")

        let eggs = try #require(menu.items.first)
        #expect(eggs.state == .off)
        timer.set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "eggs", title: "Eggs — 1:00", systemImage: "timer", isChecked: true, action: {}),
        ])
        controller.refreshMenuBarItem()
        #expect(menu.items.first === eggs)
        #expect(eggs.state == .on, "A checkmark comes in place")
        timer.set(title: nil, spoken: nil, items: [
            MenuBarItem(id: "eggs", title: "Eggs — 1:00", systemImage: "timer", isChecked: false, action: {}),
        ])
        controller.refreshMenuBarItem()
        #expect(menu.items.first === eggs)
        #expect(eggs.state == .off, "and goes in place")

        controller.menuDidClose(menu)
        timer.set(title: nil, spoken: nil, items: [])
        controller.refreshMenuBarItem()
        #expect(menu.items.first?.title == "Eggs — 1:00", "A closed menu is rebuilt only when it opens")
    }
}
