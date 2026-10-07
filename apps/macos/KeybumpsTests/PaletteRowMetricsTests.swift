import AppKit
import Foundation
import Testing
@testable import Keybumps

/// Switching tabs with ← → moved the layout a little (#381): each tab's rows had their own well,
/// title position, height, and space under the header. Every tab is laid out offscreen at the
/// palette's size (`layOutForTesting`) with made-up content, and `PaletteLayoutProbe` reports where
/// it put the section header, the first row, its well and title, and a grid's first item. SwiftUI
/// builds no accessibility elements inside a list row's button, so they can't be read as
/// `TranslateDetailTests` reads the detail pane.
@MainActor
@Suite("Command Palette: every tab's rows use the same metrics (#381)", .serialized)
struct PaletteRowMetricsTests {
    /// The tabs that list rows under a section header while the search field is empty, as ← → shows
    /// them; Dictation and Translate in the list column beside their detail.
    static let listTabs: [CommandPaletteTab] = [.search, .clipboard, .dictation, .snippets, .timers, .translate, .keyboardShortcutter]
    /// The tabs that browse a grid while the search field is empty.
    static let gridTabs: [CommandPaletteTab] = [.screenshots, .emoji]

    @Test("Every palette tab is measured, so a new plugin's tab can't be skipped")
    func everyTabIsMeasured() {
        #expect(Set(Self.listTabs + Self.gridTabs) == Set(CommandPaletteTab.allCases))
        #expect(Self.listTabs.count + Self.gridTabs.count == CommandPaletteTab.allCases.count)
    }

    @Test("Every list tab puts its header, its first row, the row's well, and its title in the same place")
    func listTabsLineUp() async throws {
        var measured: [CommandPaletteTab: PaletteLayoutMeasurement] = [:]
        for tab in Self.listTabs {
            measured[tab] = try await PaletteMetricsFixture.measure(tab)
        }
        let clipboard = try #require(measured[.clipboard])

        for tab in Self.listTabs {
            let tabMeasured = try #require(measured[tab])
            let header = try tabMeasured.require(.header)
            let row = try tabMeasured.require(.row)
            let well = try tabMeasured.require(.well)
            let title = try tabMeasured.require(.title)
            #expect(header.minY == clipboard.frames[.header]?.minY, "\(tab.rawValue): the header's y")
            #expect(header.minX == clipboard.frames[.header]?.minX, "\(tab.rawValue): the header's x")
            #expect(header.height == PaletteRowMetrics.headerHeight, "\(tab.rawValue): the header's band")
            #expect(row.minY == clipboard.frames[.row]?.minY, "\(tab.rawValue): the first row's y")
            #expect(row.minY - header.maxY == PaletteRowMetrics.headerBottom, "\(tab.rawValue): header to first row")
            #expect(row.height == PaletteRowMetrics.rowHeight, "\(tab.rawValue): the row's height")
            #expect(row.minX == PaletteRowMetrics.listCellInset, "\(tab.rawValue): the row's x in its list")
            #expect(well == clipboard.frames[.well], "\(tab.rawValue): the well")
            #expect(title.minX == clipboard.frames[.title]?.minX, "\(tab.rawValue): the title's x")
        }

        // And they're the metrics, from the list's leading edge and the row's top.
        let header = try clipboard.require(.header)
        let row = try clipboard.require(.row)
        let well = try clipboard.require(.well)
        let title = try clipboard.require(.title)
        #expect(header.minX == PaletteRowMetrics.headerInset)
        #expect(well.size == PaletteRowMetrics.wellSize)
        #expect(well.minX == PaletteRowMetrics.wellX)
        #expect(well.minY - row.minY == PaletteRowMetrics.verticalInset)
        #expect(title.minX == PaletteRowMetrics.titleX)
        #expect(row.minY - header.minY + PaletteRowMetrics.headerTop == PaletteRowMetrics.headerBlockHeight)
    }

    @Test("The Screenshots and Emoji grids start where the list rows' wells do, under the same header band")
    func gridsLineUpWithTheRows() async throws {
        let clipboard = try await PaletteMetricsFixture.measure(.clipboard)
        let screenshots = try await PaletteMetricsFixture.measure(.screenshots)
        let emoji = try await PaletteMetricsFixture.measure(.emoji)
        let header = try clipboard.require(.header)
        let row = try clipboard.require(.row)
        let well = try clipboard.require(.well)

        #expect(try screenshots.require(.header) == header)
        // A flexible grid's columns are fractions of a point off.
        let thumbnail = try screenshots.require(.gridItem)
        #expect(abs(thumbnail.minX - well.minX) < 0.5, "The first thumbnail starts where the wells do")
        #expect(abs(thumbnail.minY - well.minY) < 0.5, "and at the first well's height")

        // Emoji's highlighted-emoji line sits in the header's band, so the grid starts where rows do.
        let band = try emoji.require(.header)
        #expect(band.minX == header.minX)
        #expect(band.minY == header.minY)
        #expect(band.height == header.height)
        let groupTitle = try emoji.require(.gridHeader)
        #expect(groupTitle.minX == header.minX, "A group's title starts where the headers do")
        #expect(groupTitle.minY == row.minY, "The first group starts where the first row does")
        #expect(abs(try emoji.require(.gridItem).minX - well.minX) < 0.5, "The first tile starts where the wells do")
    }

    /// Typed Quick Search results and `/`'s filters have no section header, so their first row sits
    /// a header block higher than the tabs' by design; only their x and height are compared.
    @Test("Rows while typing and `/`'s filters use the same well, title, and height as the tabs' rows")
    func typedRowsLineUp() async throws {
        let clipboard = try await PaletteMetricsFixture.measure(.clipboard)
        let well = try clipboard.require(.well)
        let title = try clipboard.require(.title)

        let typed: [(String, PaletteLayoutMeasurement)] = [
            ("Quick Search's results", try await PaletteMetricsFixture.measure(.search) { $0.search.query = "c" }),
            ("Emoji's results", try await PaletteMetricsFixture.measure(.emoji) { $0.palette.state.historyQuery = "smile" }),
            ("The filters", try await PaletteMetricsFixture.measure(.clipboard) { $0.palette.state.historyQuery = "/" }),
        ]
        for (name, measured) in typed {
            let row = try measured.require(.row)
            let rowWell = try measured.require(.well)
            #expect(row.height == PaletteRowMetrics.rowHeight, "\(name): the row's height")
            #expect(rowWell.minX == well.minX, "\(name): the well's x")
            #expect(rowWell.minY - row.minY == PaletteRowMetrics.verticalInset, "\(name): the well's y in its row")
            #expect(rowWell.size == well.size, "\(name): the well's size")
            #expect(try measured.require(.title).minX == title.minX, "\(name): the title's x")
        }
    }
}

/// Where one tab laid out the parts every tab shares, in the palette window's points from its top
/// left.
struct PaletteLayoutMeasurement {
    let tab: CommandPaletteTab
    let frames: [PaletteLayoutProbe.Part: CGRect]

    func require(_ part: PaletteLayoutProbe.Part) throws -> CGRect {
        try #require(frames[part], "\(tab.rawValue) laid out no \(part)")
    }
}

/// A palette over temporary folders and a named pasteboard, with a little made-up content in every
/// tab and every plugin with a tab turned on, whose layout `layoutProbe` measures.
@MainActor
final class PaletteMetricsFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsRowMetrics-\(UUID().uuidString)"))
    let layoutProbe = PaletteLayoutProbe()
    let search: QuickSearchModel
    let timers: TimerStore
    let translate: TranslatePaletteContent
    let palette: CommandPaletteController

    /// Lays out a new palette on `tab`, after `prepare` (such as typing), and measures it once its
    /// layout settles.
    static func measure(
        _ tab: CommandPaletteTab,
        prepare: ((PaletteMetricsFixture) -> Void)? = nil
    ) async throws -> PaletteLayoutMeasurement {
        let fixture = try PaletteMetricsFixture()
        defer { fixture.tearDown() }
        let panel = try #require(fixture.palette.layOutForTesting(tab))
        defer { panel.orderOut(nil) }
        try await fixture.settle(panel)
        if let prepare {
            // Only what the typing shows is measured.
            prepare(fixture)
            fixture.layoutProbe.reset()
            try await fixture.settle(panel)
        }
        return PaletteLayoutMeasurement(tab: tab, frames: fixture.layoutProbe.frames)
    }

    /// Waits until the palette reports the same frames twice in a row, once it reports any.
    private func settle(_ panel: NSWindow) async throws {
        var last: [PaletteLayoutProbe.Part: CGRect] = [:]
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            panel.contentView?.layoutSubtreeIfNeeded()
            let frames = layoutProbe.frames
            if !frames.isEmpty, frames == last { return }
            last = frames
        }
    }

    init() throws {
        let root = folder.url
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 26))
        for capability in [Capability.screenshotTools, .snippets, .timer, .emojiPicker, .translation, .keyboardShortcutter] {
            preferences.setCapability(capability, enabled: true)
        }
        let clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        let dictationHistory = DictationHistoryService(recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true))
        let calculator = QuickSearchResult(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), kind: .application)
        let chess = QuickSearchResult(url: URL(fileURLWithPath: "/System/Applications/Chess.app"), kind: .application)
        search = QuickSearchModel.forTests(in: root, applications: [calculator, chess])
        let snippets = folder.makeStore()
        timers = TimerStore(storageURL: root.appendingPathComponent(TimerStore.fileName), notifications: NotificationCenter())
        let inbox = InboxStore(persistence: MetricsCoachingPersistence())
        let recents = RecentTranslations(storageURL: root.appendingPathComponent(RecentTranslations.fileName))
        translate = TranslatePaletteContent(
            preferences: preferences, translator: FakeTranslator(), recents: recents, speaker: FakeTranslationSpeaker(), wait: { _ in }
        )
        palette = CommandPaletteController(
            clipboard: clipboard,
            dictationHistory: dictationHistory,
            dictationService: DictationService(language: "en-US", history: dictationHistory, paster: InertTextPaster(), allowsSystemAccess: false),
            preferences: preferences,
            snippets: snippets,
            pasteboard: pasteboard,
            notices: MetricsNotices(),
            search: search
        )
        let emojiLibrary = EmojiLibrary(catalog: try EmojiCatalog.bundled(), canDraw: { _ in true })
        palette.tabContents = [
            .timers: TimerPaletteContent(store: timers, preferences: preferences, notices: MetricsNotices()),
            .emoji: EmojiPaletteContent(
                preferences: preferences,
                recents: EmojiRecents(storageURL: root.appendingPathComponent("emoji-recent.json")),
                loadLibrary: { emojiLibrary },
                loadsInBackground: false
            ),
            .translate: translate,
            .keyboardShortcutter: KeyboardShortcutterPaletteContent(inbox: inbox, preferences: preferences),
        ]
        palette.layoutProbe = layoutProbe

        // Two of everything, made up.
        search.recentItems.record(calculator)
        search.recentItems.record(chess)
        clipboard.ingestForTesting("Made-up copied text")
        clipboard.ingestForTesting("More made-up copied text")
        for name in ["Made-up screenshot 1.png", "Made-up screenshot 2.png"] {
            let url = root.appendingPathComponent(name)
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!
            try (png + Data(name.utf8)).write(to: url)
            #expect(clipboard.ingestImageFile(at: url))
        }
        for transcript in ["Made-up dictated words", "More made-up dictated words"] {
            let audio = root.appendingPathComponent("made-up-\(UUID().uuidString).wav")
            try Data("made-up audio".utf8).write(to: audio)
            try dictationHistory.record(transcript, language: "en-US", duration: 3, audioSourceURL: audio)
        }
        _ = try snippets.add(SnippetDraft(name: "Made-up snippet", keyword: ";mu", text: "Made-up snippet text"))
        _ = try snippets.add(SnippetDraft(name: "Another made-up snippet", text: "More made-up text"))
        timers.activate()
        _ = timers.start(duration: 300, name: "Tea")
        _ = timers.start(duration: 600, name: nil)
        try inbox.append(CoachingEvent(applicationName: "Finder", actionTitle: "New Folder", shortcut: "⇧⌘N"))
        try inbox.append(CoachingEvent(applicationName: "Finder", actionTitle: "Get Info", shortcut: "⌘I"))
        recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
    }

    func tearDown() {
        translate.stop()
        timers.deactivate()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder.url)
    }
}

private final class MetricsCoachingPersistence: EventPersistence {
    private var events: [CoachingEvent] = []
    func load() throws -> [CoachingEvent] { events }
    func save(_ events: [CoachingEvent]) throws { self.events = events }
}

@MainActor
private final class MetricsNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
