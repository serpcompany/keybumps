import Testing
@testable import Keybumps

/// What one click on a palette row or tile does depends on its tab (#552): where a row has one
/// obvious job, a click does what Return does; where the tab shows the highlighted row's actions,
/// a click highlights it and a double-click does Return's. `EmojiPaletteContentTests`,
/// `TimerModuleTests`, and `ScreengrabsPaletteContentTests` click each of those tabs' rows.
@MainActor
@Suite("Command Palette: what a click does")
struct PaletteClickTests {
    @Test("Each tab declares what one click does: Return's action, or the highlight where the tab shows the row's actions")
    func eachTabsClick() {
        let expected: [CommandPaletteTab: PaletteClickAction] = [
            .search: .acts,
            .clipboard: .acts,
            .screenshots: .selects,
            .dictation: .selects,
            .snippets: .acts,
            .timers: .acts,
            .emoji: .acts,
            .translate: .selects,
            .keyboardShortcutter: .selects,
        ]
        #expect(Set(expected.keys) == Set(CommandPaletteTab.allCases), "A new tab declares its click here too")
        for tab in CommandPaletteTab.allCases {
            #expect(tab.clickAction == expected[tab], "\(tab.rawValue)")
        }
    }

    @Test("Where a click acts, it highlights the row and does Return's; a double-click's second click does nothing, so it never happens twice")
    func clickActs() {
        #expect(Self.steps(.acts, .click()) == [.select, .activate])
        #expect(Self.steps(.acts, .click(count: 2)) == [], "A double-click's second click")
        #expect(Self.steps(.acts, .doubleClick()) == [])
    }

    @Test("Where a click selects, it only highlights the row, and a double-click does Return's")
    func clickSelects() {
        #expect(Self.steps(.selects, .click()) == [.select])
        #expect(Self.steps(.selects, .click(count: 2)) == [.select], "A double-click's second click still only highlights")
        #expect(Self.steps(.selects, .doubleClick()) == [.activate])
    }

    @Test("A ⌘-click does the row's own ⌘-click, once, in either kind of tab; on a row without one, ⌘ makes no difference")
    func commandClick() {
        for action in [PaletteClickAction.acts, .selects] {
            #expect(Self.steps(action, .click(withCommand: true), commandClicks: true) == [.select, .commandActivate])
            #expect(Self.steps(action, .click(count: 2, withCommand: true), commandClicks: true) == [])
            #expect(Self.steps(action, .doubleClick(withCommand: true), commandClicks: true) == [], "\(action): the double-click doesn't copy too")
        }
        #expect(Self.steps(.acts, .click(withCommand: true)) == [.select, .activate])
        #expect(Self.steps(.selects, .click(withCommand: true)) == [.select])
        #expect(Self.steps(.selects, .doubleClick(withCommand: true)) == [.activate])
        #expect(Self.steps(.selects, .click(), commandClicks: true) == [.select], "Without ⌘, a click is a click")
    }

    private enum Step: Equatable {
        case select, activate, commandActivate
    }

    /// What a click did, in order.
    private static func steps(_ action: PaletteClickAction, _ click: PaletteClick, commandClicks: Bool = false) -> [Step] {
        var steps: [Step] = []
        action.perform(
            click,
            select: { steps.append(.select) },
            activate: { steps.append(.activate) },
            commandActivate: commandClicks ? { steps.append(.commandActivate) } : nil
        )
        return steps
    }
}
