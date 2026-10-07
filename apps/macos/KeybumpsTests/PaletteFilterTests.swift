import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// `/` in the Command Palette: which filters each tab lists, what they match, and the keys that
/// choose and remove one.
@MainActor
@Suite("Command Palette: / filters")
struct PaletteFilterTests {
    @Test("A query starting with / lists the tab's filters, narrowed by what follows")
    func menu() {
        #expect(PaletteFilter.menu(in: .clipboard, query: "/") == [.text, .images, .links])
        #expect(PaletteFilter.menu(in: .clipboard, query: "/im") == [.images])
        #expect(PaletteFilter.menu(in: .clipboard, query: "/IM") == [.images])
        #expect(PaletteFilter.menu(in: .clipboard, query: "/zzz") == [])
        #expect(PaletteFilter.menu(in: .search, query: "/")?.first == .applications)
        #expect(PaletteFilter.menu(in: .dictation, query: "/f") == [.unfinished])
        #expect(PaletteFilter.menu(in: .clipboard, query: "a/") == nil, "Only a leading / opens the list")
        #expect(PaletteFilter.menu(in: .clipboard, query: "") == nil)
        #expect(PaletteFilter.menu(in: .timers, query: "/") == nil, "A tab without filters types / as usual")
        #expect(PaletteFilter.menu(in: .snippets, query: "/") == nil)
    }

    @Test("A link is one http or https address and nothing else")
    func links() {
        #expect(PaletteFilter.isLink("https://example.com/a?b=c"))
        #expect(PaletteFilter.isLink("  http://example.com\n"))
        #expect(!PaletteFilter.isLink("see https://example.com"))
        #expect(!PaletteFilter.isLink("example.com"))
        #expect(!PaletteFilter.isLink("ftp://example.com"))
        #expect(!PaletteFilter.isLink("https://"))
        #expect(!PaletteFilter.isLink(""))
    }

    @Test("Clipboard filters match text, images, and links; date filters match the day and the week")
    func clipboardMatching() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_331_200) // a Wednesday, 2026-10-07 00:00 UTC
        func entry(_ text: String, kind: ClipboardEntry.Kind = .text, at date: Date? = nil) -> ClipboardEntry {
            ClipboardEntry(id: UUID(), text: text, capturedAt: date ?? now, kind: kind, mediaPath: nil)
        }
        let text = entry("made-up note")
        let link = entry("https://example.com")
        let image = entry("", kind: .image)
        #expect(PaletteFilter.text.matches(text) && !PaletteFilter.text.matches(link) && !PaletteFilter.text.matches(image))
        #expect(PaletteFilter.links.matches(link) && !PaletteFilter.links.matches(text))
        #expect(PaletteFilter.images.matches(image) && !PaletteFilter.images.matches(text))

        let yesterday = entry("x", at: now.addingTimeInterval(-3_600))
        let lastMonth = entry("x", at: now.addingTimeInterval(-30 * 86_400))
        #expect(PaletteFilter.today.matches(text, now: now, calendar: calendar))
        #expect(!PaletteFilter.today.matches(yesterday, now: now, calendar: calendar))
        #expect(PaletteFilter.thisWeek.matches(yesterday, now: now, calendar: calendar))
        #expect(!PaletteFilter.thisWeek.matches(lastMonth, now: now, calendar: calendar))
    }

    @Test("Quick Search filters match result kinds, commands, and snippets")
    func searchMatching() {
        let app = QuickSearchItem.result(QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Made Up.app"), kind: .application))
        let folder = QuickSearchItem.result(QuickSearchResult(url: URL(fileURLWithPath: "/tmp/made-up", isDirectory: true), kind: .folder))
        let command = QuickSearchItem.command(.keybumpsSettings)
        #expect(PaletteFilter.applications.matches(app) && !PaletteFilter.applications.matches(folder))
        #expect(PaletteFilter.folders.matches(folder))
        #expect(PaletteFilter.commands.matches(command) && !PaletteFilter.commands.matches(app))
    }

    @Test("Return on / chooses the highlighted filter and clears the field; Delete in an empty field removes it; Escape closes the list")
    func keys() {
        let fixture = PaletteFilterFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.clipboard)

        fixture.palette.state.historyQuery = "/"
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(fixture.palette.state.selection == 1)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_Return, "\r")) == nil)
        #expect(fixture.palette.state.filter == .images)
        #expect(fixture.palette.state.historyQuery.isEmpty)

        #expect(fixture.palette.handleKeyDown(Self.key(kVK_Delete, "\u{7f}")) == nil)
        #expect(fixture.palette.state.filter == nil, "Delete in an empty field removes the chip first")

        fixture.palette.state.historyQuery = "/li"
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_Escape, "\u{1b}")) == nil)
        #expect(fixture.palette.state.historyQuery.isEmpty, "Escape closes the list, not the palette")
        #expect(fixture.palette.state.filter == nil)

        // Switching tabs drops the filter.
        fixture.palette.chooseFilter(.links)
        fixture.palette.selectOnOpening(.dictation)
        #expect(fixture.palette.state.filter == nil)
    }

    @Test("On Screenshots, / lists filters as rows, so Down doesn't go into the grid")
    func screenshotsMenuIsAList() {
        let fixture = PaletteFilterFixture()
        defer { fixture.tearDown() }
        fixture.palette.selectOnOpening(.screenshots)
        fixture.palette.state.historyQuery = "/"
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(!fixture.palette.state.isBrowsingGrid)
        #expect(fixture.palette.state.selection == 1)
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_Return, "\r")) == nil)
        #expect(fixture.palette.state.filter == .thisWeek)
    }

    static func key(_ keyCode: Int, _ characters: String = "") -> NSEvent {
        let isArrow = [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow].contains(keyCode)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: isArrow ? [.function, .numericPad] : [],
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }
}

/// A palette over temporary folders and a named pasteboard, never the real ones.
@MainActor
private final class PaletteFilterFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsPaletteFilter-\(UUID().uuidString)"))
    let palette: CommandPaletteController

    init() {
        let root = folder.url
        let clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        let dictationHistory = DictationHistoryService(
            recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)
        )
        palette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: DictationService(
                language: "en-US",
                history: dictationHistory,
                paster: InertTextPaster(),
                allowsSystemAccess: false
            ),
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: SilentFilterNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

private final class SilentFilterNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
