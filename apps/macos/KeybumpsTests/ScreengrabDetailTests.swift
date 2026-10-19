import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The ScreenGrabs tab's detail beside its grid (#552): the highlighted screengrab in full, its
/// buttons named and keyed as the footer names them, each doing what its key does, and its
/// Information. Made-up screenshots and recordings in `RecordingsTabFixture`'s temporary folder, with
/// its named pasteboard, Trash, Quick Look, and Finder; the palette is laid out offscreen and read as
/// VoiceOver reads it (`PaletteAccessibility`).
@MainActor
@Suite("ScreenGrabs tab: the highlighted screengrab in full (#552)", .serialized)
struct ScreengrabDetailTests {
    /// 2026-10-17 10:38:05 in UTC.
    static let start = ScreengrabsRecordingsTabTests.start

    // MARK: What it shows

    @Test("A screenshot: Copy ↵ ⌘C, Paste ⌘V, Edit ⌘E, Quick Look Space, Show in Finder, then Delete ⌫; Dimensions, Taken, and Size")
    func screenshot() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let entry = try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start)
        let detail = try #require(fixture.content.detail(row: 0, query: ""))

        #expect(detail.item == .screenshot(entry))
        #expect(detail.buttons.map(\.action) == [.copy, .paste, .edit, .quickLook, .showInFinder, .delete])
        #expect(detail.buttons.map(\.title) == ["Copy", "Paste", "Edit", "Quick Look", "Show in Finder", "Delete"])
        #expect(detail.buttons.map(\.shortcuts) == [[["↵"], ["⌘", "C"]], [["⌘", "V"]], [["⌘", "E"]], [["Space"]], [], [["⌫"]]])
        #expect(detail.buttons.map(\.isDestructive) == [false, false, false, false, false, true], "Delete's is the one in red")
        #expect(detail.buttons.map(\.identifier) == [
            "palette.screengrabs.detail.copy",
            "palette.screengrabs.detail.paste",
            "palette.screengrabs.detail.edit",
            "palette.screengrabs.detail.quickLook",
            "palette.screengrabs.detail.showInFinder",
            "palette.screengrabs.detail.delete",
        ])
        #expect(detail.warning == nil)

        let file = try #require(entry.sourceURL)
        let files = await ScreengrabFileFacts.read(detail.item)
        #expect(files.savedFileExists == true)
        #expect(detail.buttons(files: files) == detail.buttons)
        #expect(detail.information(files: files) == [
            .init(title: "Dimensions", value: "12 × 8"),
            .init(title: "Taken", value: Self.taken(Self.start)),
            .init(title: "Size", value: Self.size(of: [file])),
        ], "No Source app: a screenshot has none")
        #expect(detail.information(files: nil) == [
            .init(title: "Dimensions", value: ""),
            .init(title: "Taken", value: Self.taken(Self.start)),
            .init(title: "Size", value: ""),
        ], "Until its files are read, its rows are there to fill in")
        #expect(Self.footerNames(fixture, row: 0) == Self.keyedNames(detail), "Named and keyed as the footer names them")
    }

    @Test("A recording: Copy, Paste, Edit (the recording window), Quick Look, Show in Finder, then Move to Trash ⌫; Length, Displays, Taken, and Size")
    func recording() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        let detail = try #require(fixture.content.detail(row: 0, query: ""))
        let files = await ScreengrabFileFacts.read(detail.item)

        #expect(detail.buttons.map(\.action) == [.copy, .paste, .edit, .quickLook, .showInFinder, .delete])
        #expect(detail.buttons.map(\.title) == ["Copy", "Paste", "Edit", "Quick Look", "Show in Finder", "Move to Trash"])
        #expect(detail.buttons.map(\.shortcuts) == [[["↵"], ["⌘", "C"]], [["⌘", "V"]], [["⌘", "E"]], [["Space"]], [], [["⌫"]]])
        #expect(detail.buttons.last?.isDestructive == true)
        #expect(detail.buttons(files: files) == detail.buttons)
        #expect(detail.information(files: files) == [
            .init(title: "Length", value: "0:42"),
            .init(title: "Displays", value: "1"),
            .init(title: "Taken", value: Self.taken(Self.start)),
            .init(title: "Size", value: Self.size(of: recording.files)),
        ])
        #expect(detail.information(files: nil).map(\.value).last == "", "Its Size fills in once its files are read")
        #expect(recording.files.map(\.lastPathComponent) == ["video-1.mov", "video-1-mixdown.mp4"], "The video and its mixdown")
        #expect(Self.footerNames(fixture, row: 0) == Self.keyedNames(detail))
    }

    @Test("A recording of two screens: Copy 2 Videos, and 2 Displays")
    func twoDisplays() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start, displays: 2)
        let detail = try #require(fixture.content.detail(row: 0, query: ""))
        let information = detail.information(files: await ScreengrabFileFacts.read(detail.item))

        #expect(detail.buttons.map(\.title) == ["Copy 2 Videos", "Paste", "Edit", "Quick Look", "Show in Finder", "Move to Trash"])
        #expect(information.map(\.title) == ["Length", "Displays", "Taken", "Size"])
        #expect(information[1].value == "2")
        #expect(information[3].value == Self.size(of: recording.files), "Both displays' videos and mixdowns")
        #expect(recording.files.count == 4)
        #expect(Self.footerNames(fixture, row: 0) == Self.keyedNames(detail))
    }

    @Test("A recording moved or deleted: only Remove ⌫, Moved or deleted, and what the index still knows")
    func missing() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        try FileManager.default.removeItem(at: recording.folder)
        fixture.content.didShow(palette: fixture.log.actions)
        let detail = try #require(fixture.content.detail(row: 0, query: ""))

        #expect(detail.item.isMissing)
        #expect(detail.buttons.map(\.action) == [.delete])
        #expect(detail.buttons.map(\.title) == ["Remove"])
        #expect(detail.buttons.map(\.shortcuts) == [[["⌫"]]])
        #expect(detail.warning == "Moved or deleted")
        let expected: [ScreengrabDetail.Fact] = [
            .init(title: "Length", value: "0:42"),
            .init(title: "Displays", value: "1"),
            .init(title: "Taken", value: Self.taken(Self.start)),
        ]
        #expect(detail.information(files: nil) == expected, "No Size, even before its files are read: they're gone")
        #expect(detail.information(files: await ScreengrabFileFacts.read(detail.item)) == expected)
        #expect(Self.footerNames(fixture, row: 0) == Self.keyedNames(detail))
    }

    @Test("Before Down or a click goes into the grid, nothing is highlighted, and the hint names what the grid holds")
    func nothingHighlighted() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addRecording(at: Self.start)
        #expect(fixture.content.detail(row: -1, query: "") == nil, "The palette passes no row until then")
        #expect(fixture.content.detail(row: 1, query: "") == nil)

        let shot = Screengrab.screenshot(ScreengrabsRecordingsTabTests.screenshot(at: 0))
        let video = Screengrab.recording(ScreengrabsRecordingsTabTests.indexed(at: 0))
        #expect(ScreengrabDetail.hint(for: [video, shot]) == "Press ↓ or click a screenshot or recording to see it here")
        #expect(ScreengrabDetail.hint(for: [shot]) == "Press ↓ or click a screenshot to see it here")
        #expect(ScreengrabDetail.hint(for: [video]) == "Press ↓ or click a recording to see it here", "With Clipboard History off")
    }

    @Test("While the search field has text, Quick Look has no key; with text or a filter, Delete reads ⌘⌫, as in the footer")
    func whileSearching() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        // Today, so the Today filter keeps it.
        try fixture.addRecording(at: Date())
        let typed = try #require(fixture.content.detail(row: 0, query: "recording"))
        #expect(typed.buttons.map(\.title) == ["Copy", "Paste", "Edit", "Quick Look", "Show in Finder", "Move to Trash"], "The buttons stay")
        #expect(typed.buttons.first { $0.action == .quickLook }?.shortcuts == [], "Space types here")
        #expect(typed.buttons.last?.shortcuts == [["⌘", "⌫"]])
        #expect(Self.footerNames(fixture, row: 0, query: "recording") == Self.keyedNames(typed))

        fixture.filter = .today
        fixture.palette.state.filter = .today
        let filtered = try #require(fixture.content.detail(row: 0, query: ""))
        #expect(filtered.buttons.first { $0.action == .quickLook }?.shortcuts == [["Space"]], "Space still opens Quick Look")
        #expect(filtered.buttons.last?.shortcuts == [["⌘", "⌫"]], "⌫ removes the filter chip here")
        #expect(Self.footerNames(fixture, row: 0) == Self.keyedNames(filtered))
    }

    @Test("A screenshot names its Source app only where Clipboard History recorded one, and leaves out what its files can't say")
    func sourceAppAndUnreadableFiles() async {
        let shot = ClipboardEntry(
            id: UUID(), text: "", capturedAt: Self.start, kind: .image, sourcePath: "/made-up/Screenshot.png", isScreenCapture: true,
            sourceApp: ClipboardSourceApp(bundleIdentifier: "com.example.capture", name: "Example Capture")
        )
        let detail = ScreengrabDetail(item: .screenshot(shot), buttons: [])
        let files = await ScreengrabFileFacts.read(.screenshot(shot))
        #expect(files == ScreengrabFileFacts(dimensions: nil, size: nil, savedFileExists: false))
        #expect(detail.information(files: files) == [
            .init(title: "Taken", value: Self.taken(Self.start)),
            .init(title: "Source app", value: "Example Capture"),
        ], "Neither its file nor a copy is there, so no Dimensions or Size")
        #expect(ScreengrabFileFacts.size(of: []) == nil)
    }

    @Test("A screenshot whose file moved: Dimensions and Size from Clipboard History's copy, and no Show in Finder once its files are read")
    func savedFileMoved() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let entry = try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start)
        try FileManager.default.removeItem(at: try #require(entry.sourceURL))
        let copy = try #require(entry.imageURL)
        let detail = try #require(fixture.content.detail(row: 0, query: ""))
        #expect(detail.buttons.map(\.action) == [.copy, .paste, .edit, .quickLook, .showInFinder, .delete], "Nothing's read yet")

        let files = await ScreengrabFileFacts.read(detail.item)
        #expect(files.savedFileExists == false)
        #expect(detail.buttons(files: files).map(\.action) == [.copy, .paste, .edit, .quickLook, .delete])
        #expect(detail.information(files: files) == [
            .init(title: "Dimensions", value: "12 × 8"),
            .init(title: "Taken", value: Self.taken(Self.start)),
            .init(title: "Size", value: Self.size(of: [copy])),
        ])
    }

    @Test("What a screengrab's files say is read once, kept by the tab while it shows, and read again after it shows again")
    func fileFactsAreKept() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let entry = try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start)
        let content = fixture.content
        let item = try #require(content.item(at: 0, query: ""))
        #expect(content.fileFacts(for: item) == nil, "Nothing read before it's highlighted")

        let read = await content.loadFileFacts(for: item)
        #expect(read.dimensions == "12 × 8")
        #expect(content.fileFacts(for: item) == read)

        // Its file goes: the tab keeps what it read until it shows again.
        try FileManager.default.removeItem(at: try #require(entry.sourceURL))
        #expect(await content.loadFileFacts(for: item) == read)
        content.didShow(palette: fixture.log.actions)
        #expect(content.fileFacts(for: item) == nil)
        #expect(await content.loadFileFacts(for: item).savedFileExists == false)
    }

    // MARK: What its buttons do

    @Test("A screenshot's buttons do what its keys do: Copy is Return's, Paste ⌘V's, Edit ⌘E's, Quick Look Space's; Show in Finder selects its file, and Delete is the Delete key's")
    func screenshotButtonsDoWhatTheKeysDo() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let entry = try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start)
        let file = try #require(entry.sourceURL)
        let content = fixture.content

        let keys = RecordingsTabLog()
        content.didShow(palette: keys.actions)
        content.activate(row: 0, query: "", palette: keys.actions)
        content.paste(row: 0, query: "", palette: keys.actions)
        content.handleCommandKey("e", row: 0, query: "", palette: keys.actions)
        try #require(content.playback(row: 0, query: "")).toggle()

        let buttons = RecordingsTabLog()
        content.didShow(palette: buttons.actions)
        let item = try #require(content.item(at: 0, query: ""))
        for action in [ScreengrabAction.copy, .paste, .edit, .quickLook] {
            content.run(action, on: item, query: "", palette: buttons.actions)
        }
        #expect(buttons.calls == keys.calls)
        #expect(keys.calls == [.copyEntry(entry.id), .pasteEntry(entry.id), .edit(entry.id), .dismiss])
        #expect(fixture.quickLook.previews == [[file], [file]])

        content.run(.showInFinder, on: item, query: "", palette: buttons.actions)
        #expect(fixture.revealed == [[file]])
        content.run(.delete, on: item, query: "", palette: buttons.actions)
        #expect(buttons.calls.suffix(2) == [.dismiss, .deleteRow(0)], "Finder closes the palette; Delete goes the Delete key's way")
    }

    @Test("A recording's buttons do what its keys do: Copy and Paste its files, Edit opens the recording window, Quick Look previews it, and Delete is the Delete key's")
    func recordingButtonsDoWhatTheKeysDo() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start, displays: 2)
        let content = fixture.content

        let keys = RecordingsTabLog()
        content.didShow(palette: keys.actions)
        content.activate(row: 0, query: "", palette: keys.actions)
        content.paste(row: 0, query: "", palette: keys.actions)
        content.handleCommandKey("e", row: 0, query: "", palette: keys.actions)
        try #require(content.playback(row: 0, query: "")).toggle()

        let buttons = RecordingsTabLog()
        content.didShow(palette: buttons.actions)
        let item = try #require(content.item(at: 0, query: ""))
        for action in [ScreengrabAction.copy, .paste, .edit, .quickLook] {
            content.run(action, on: item, query: "", palette: buttons.actions)
        }
        #expect(buttons.calls == keys.calls)
        #expect(keys.calls == [.copyFiles(recording.sharingURLs), .pasteFiles(recording.sharingURLs), .dismiss, .dismiss])
        #expect(fixture.opened == [recording.id, recording.id], "Edit opens the recording window, as ⌘E does")
        #expect(fixture.quickLook.previews == [recording.sharingURLs, recording.sharingURLs])

        content.run(.showInFinder, on: item, query: "", palette: buttons.actions)
        #expect(fixture.revealed == [recording.sharingURLs])
        content.run(.delete, on: item, query: "", palette: buttons.actions)
        #expect(buttons.calls.last == .deleteRow(0))
        #expect(fixture.trashed.isEmpty, "Never without the question")
    }

    @Test("A moved or deleted recording's Remove, pressed in the detail, is the Delete key's, which removes it at once")
    func missingRemove() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        try FileManager.default.removeItem(at: recording.folder)
        let palette = fixture.palette
        let ax = try await PaletteAccessibility.layOut(palette, tab: .screenshots)
        defer { ax.close() }
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        let detail = try #require(fixture.content.detail(row: palette.state.selection, query: ""))
        #expect(detail.buttons.map(\.action) == [.delete])

        let remove = try await ax.require("palette.screengrabs.detail.delete")
        #expect(PaletteAccessibility.label(of: remove) == "Remove")
        PaletteAccessibility.press(remove)
        #expect(fixture.recordings.recordings.isEmpty)
        #expect(palette.state.contentPendingDeletion == nil, "No question: nothing's left to trash")
        #expect(fixture.trashed.isEmpty)
    }

    // MARK: In the palette

    @Test("The grid is two columns beside the detail, which says how to show one until a click on a tile shows it with its buttons and keys")
    func layout() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start.addingTimeInterval(-60))
        try fixture.addRecording(at: Self.start)
        let ax = try await PaletteAccessibility.layOut(fixture.palette, tab: .screenshots)
        defer { ax.close() }

        let hint = try await ax.require("palette.screengrabs.detail.empty")
        #expect(PaletteAccessibility.text(of: hint) == "Press ↓ or click a screenshot or recording to see it here")
        #expect(ax.element("palette.screengrabs.detail.copy") == nil, "Nothing highlighted yet")

        // The two tiles side by side, newest first, and the hint to their right.
        let recording = try await ax.require("palette.screengrabs.recording")
        let screenshot = try await ax.require("palette.screengrabs.screenshot")
        let recordingFrame = PaletteAccessibility.frame(of: recording)
        let screenshotFrame = PaletteAccessibility.frame(of: screenshot)
        #expect(abs(recordingFrame.midY - screenshotFrame.midY) < 1, "One row")
        #expect(recordingFrame.maxX < screenshotFrame.minX)
        let panel = ax.panel.frame
        #expect(screenshotFrame.maxX < panel.minX + 478, "Both in the grid's column")
        #expect(PaletteAccessibility.frame(of: hint).minX >= panel.minX + 478)

        // One click on the recording selects it and shows it beside the grid.
        PaletteAccessibility.press(recording)
        #expect(fixture.palette.state.isBrowsingGrid)
        let copy = try await ax.require("palette.screengrabs.detail.copy")
        #expect(PaletteAccessibility.label(of: copy) == "Copy")
        #expect(PaletteAccessibility.hint(of: copy) == "Return, or Command C")
        #expect(PaletteAccessibility.frame(of: copy).minX >= panel.minX + 478, "In the detail")
        let delete = try await ax.require("palette.screengrabs.detail.delete")
        #expect(PaletteAccessibility.label(of: delete) == "Move to Trash")
        #expect(PaletteAccessibility.hint(of: delete) == "Delete")
        #expect(PaletteAccessibility.hint(of: try await ax.require("palette.screengrabs.detail.quickLook")) == "Space")
        #expect(PaletteAccessibility.hint(of: try await ax.require("palette.screengrabs.detail.edit")) == "Command E")
        #expect(PaletteAccessibility.hint(of: try await ax.require("palette.screengrabs.detail.paste")) == "Command V")
        #expect((PaletteAccessibility.hint(of: try await ax.require("palette.screengrabs.detail.showInFinder")) ?? "").isEmpty, "No key does it")
        #expect(PaletteAccessibility.label(of: try await ax.require("palette.screengrabs.detail.preview")) == "Recording, 42 seconds")
        #expect(ax.element("palette.screengrabs.detail.empty") == nil)

        let detail = try await ax.require("palette.screengrabs.detail")
        let order = PaletteAccessibility.identifiersInNavigationOrder(in: detail).filter {
            $0.hasPrefix("palette.screengrabs.detail.") && ScreengrabAction(rawValue: String($0.dropFirst("palette.screengrabs.detail.".count))) != nil
        }
        #expect(order == ScreengrabAction.allCases.map { "palette.screengrabs.detail.\($0.rawValue)" }, "In the footer's order, Delete's last")
        #expect(PaletteAccessibility.element(reading: "Information", in: detail) != nil)
        #expect(PaletteAccessibility.element(reading: "Length", in: detail) != nil)

        // Right moves on to the screenshot, which the detail then shows.
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_RightArrow)) == nil)
        #expect(await ax.waitFor { ax.label(ofElement: "palette.screengrabs.detail.delete") == "Delete" ? true : nil } == true)
        #expect(await ax.waitFor { ax.label(ofElement: "palette.screengrabs.detail.preview") == "Screenshot" ? true : nil } == true)
    }

    @Test("Its Delete asks first on a recording, as the Delete key does, and its Copy copies, closing the palette")
    func buttonsThroughThePalette() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        let palette = fixture.palette
        let ax = try await PaletteAccessibility.layOut(palette, tab: .screenshots)
        defer { ax.close() }
        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)

        PaletteAccessibility.press(try await ax.require("palette.screengrabs.detail.delete"))
        let asked = try #require(palette.state.contentPendingDeletion)
        #expect(asked.title == "Move this recording to the Trash?")
        #expect(asked.confirmTitle == "Move to Trash")
        #expect(fixture.trashed.isEmpty)
        palette.contentDeletionDidClose()

        #expect(palette.isVisible, "The question's Cancel leaves the palette open")
        PaletteAccessibility.press(try await ax.require("palette.screengrabs.detail.copy"))
        let copied = fixture.library.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(copied?.map(\.lastPathComponent) == recording.sharingURLs.map(\.lastPathComponent))
        #expect(!palette.isVisible, "Copy closes the palette")
        #expect(fixture.notices.messages == ["Copied to Clipboard"])
    }

    @Test("The pointer crossing the grid's right column on its way to the detail changes nothing: the highlight, the footer, and the detail stay on the tile clicked, and the detail's Delete deletes that one (#552)")
    func hoverChangesNothing() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let older = try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start.addingTimeInterval(-60))
        let newer = try Self.addScreenshot(to: fixture, width: 16, height: 9, at: Self.start)
        let palette = fixture.palette
        var pointer = NSPoint(x: -1000, y: -1000)
        palette.state.mouseLocation = { pointer }
        let ax = try await PaletteAccessibility.layOut(palette, tab: .screenshots)
        defer { ax.close() }
        #expect(!palette.hoverHighlights)

        // A click on the left column's tile, the newer one; then the pointer moves right, over the
        // older one, toward the detail.
        palette.clickContentRow(.click(), row: 0)
        let footer = palette.footerActions
        let detail = try #require(fixture.content.detail(row: palette.state.selection, query: ""))
        #expect(detail.item.id == newer.id)
        pointer = NSPoint(x: 300, y: 200)
        palette.hover(row: 1)
        #expect(palette.state.selection == 0)
        #expect(!palette.state.selectionFollowsPointer)
        #expect(palette.footerActions == footer)
        #expect(fixture.content.detail(row: palette.state.selection, query: "") == detail)

        // Its Delete removes the one clicked, with no question, and leaves the other.
        PaletteAccessibility.press(try await ax.require("palette.screengrabs.detail.delete"))
        #expect(fixture.library.clipboard.entries.map(\.id) == [older.id])
    }

    @Test("A tile's menu acts on its own screengrab, found by its id: one landing at the top while the menu is open moves it on, and its Delete still removes it; once it's gone, the menu does nothing (#552)")
    func menuFindsItsScreengrabByID() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let first = try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start)
        let content = fixture.content
        let palette = fixture.palette
        palette.selectOnOpening(.screenshots)
        // The menu opens on the only tile, at row 0.
        let item = try #require(content.item(at: 0, query: ""))
        #expect(item.id == first.id)

        // A screenshot taken a moment before lands at the top while the menu is open.
        let arrived = try Self.addScreenshot(to: fixture, width: 16, height: 9, at: Self.start.addingTimeInterval(60))
        #expect(content.item(at: 0, query: "")?.id == arrived.id)
        #expect(content.row(of: item, query: "") == 1)

        let log = RecordingsTabLog()
        content.runOnTile(.delete, on: item, query: "", palette: log.actions)
        #expect(log.selections == [1], "The tile is highlighted where it is now")
        #expect(log.calls == [.deleteRow(1)], "and Delete goes to its row now, not the one the menu opened at")

        // Through the palette, the menu's screenshot goes, with no question, and the new one stays.
        content.runOnTile(.delete, on: item, query: "", palette: palette.contentActions)
        #expect(fixture.library.clipboard.entries.map(\.id) == [arrived.id])
        #expect(palette.state.selection == 0)

        // Once it's gone, a menu still open on it, or the detail's button, does nothing.
        let after = RecordingsTabLog()
        content.runOnTile(.delete, on: item, query: "", palette: after.actions)
        content.run(.delete, on: item, query: "", palette: after.actions)
        content.runOnTile(.copy, on: item, query: "", palette: after.actions)
        #expect(after.calls.isEmpty)
        #expect(after.selections.isEmpty)
    }

    @Test("A recording's menu asks about its own recording after one lands at the top, with it highlighted, and Move to Trash trashes it (#552)")
    func menuAsksAboutItsOwnRecording() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        let content = fixture.content
        let palette = fixture.palette
        palette.selectOnOpening(.screenshots)
        let item = try #require(content.item(at: 0, query: ""))

        try Self.addScreenshot(to: fixture, width: 12, height: 8, at: Self.start.addingTimeInterval(60))
        content.runOnTile(.delete, on: item, query: "", palette: palette.contentActions)
        let asked = try #require(palette.state.contentPendingDeletion)
        #expect(asked.title == "Move this recording to the Trash?")
        #expect(palette.state.selection == 1, "The recording it asks about is the one highlighted, so the detail shows it")
        #expect(content.detail(row: palette.state.selection, query: "")?.item.id == recording.id)

        palette.confirmContentDeletion(asked)
        palette.contentDeletionDidClose()
        #expect(fixture.trashed.map(\.lastPathComponent) == [recording.folder.lastPathComponent])
        #expect(content.content(query: "").items.allSatisfy { $0.recording == nil }, "Only the screenshot is left")
    }

    @Test("With no screenshots or recordings, the tab keeps its empty state across the whole tab, with no detail")
    func emptyTab() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        #expect(fixture.content.content(query: "") == .empty)
        let ax = try await PaletteAccessibility.layOut(fixture.palette, tab: .screenshots)
        defer { ax.close() }

        let title = fixture.content.emptyTitle(query: "")
        #expect(await ax.waitFor { PaletteAccessibility.element(reading: title, in: ax.root) } != nil)
        #expect(ax.element("palette.screengrabs.detail") == nil)
        #expect(ax.element("palette.screengrabs.detail.empty") == nil)
    }

    @Test("With Clipboard History off, the header still says screenshots need it, beside Open Settings, in the grid's narrower column")
    func clipboardHistoryOff() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addRecording(at: Self.start)
        fixture.preferences.setCapability(.clipboardHistory, enabled: false)
        let ax = try await PaletteAccessibility.layOut(fixture.palette, tab: .screenshots)
        defer { ax.close() }

        let settings = try await ax.require("palette.screengrabs.openClipboardSettings")
        let note = try #require(await ax.waitFor {
            PaletteAccessibility.element(reading: "Screenshots aren’t listed while Clipboard History is off", in: ax.root)
                ?? PaletteAccessibility.element(reading: "Screenshots need Clipboard History", in: ax.root)
        })
        let column = ax.panel.frame.minX + 478
        #expect(PaletteAccessibility.frame(of: settings).maxX <= column, "Open Settings stays in the grid's column")
        #expect(PaletteAccessibility.frame(of: note).maxX <= PaletteAccessibility.frame(of: settings).minX, "and the note fits before it")
        #expect(try await ax.text("palette.screengrabs.detail.empty") == "Press ↓ or click a recording to see it here")
    }

    // MARK: Helpers

    /// A made-up screenshot of `width` by `height` pixels in Clipboard History, taken at `date`,
    /// with its file kept.
    @discardableResult
    static func addScreenshot(to fixture: RecordingsTabFixture, width: Int, height: Int, at date: Date) throws -> ClipboardEntry {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        // Each one's own pixels, so Clipboard History keeps every one.
        rep.setColor(NSColor(white: CGFloat(Int(date.timeIntervalSince1970) % 200) / 255, alpha: 1), atX: 0, y: 0)
        let file = fixture.library.root.url.appendingPathComponent("Screenshot \(Int(date.timeIntervalSince1970)).png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        #expect(fixture.library.clipboard.importScreenshot(at: file, capturedAt: date))
        return try #require(fixture.library.clipboard.entries.first { $0.sourcePath == file.path })
    }

    static func taken(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func size(of files: [URL]) -> String {
        let bytes = files.compactMap { try? Data(contentsOf: $0).count }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// What the palette's footer names with `row` highlighted and `query` typed, read from the
    /// palette itself (`CommandPaletteController.footerActions`), with its filter as the test set it:
    /// "Copy ↵", "Paste ⌘V", and so on.
    static func footerNames(_ fixture: RecordingsTabFixture, row: Int, query: String = "") -> [String] {
        let palette = fixture.palette
        if palette.state.tab != .screenshots {
            let filter = palette.state.filter
            palette.selectOnOpening(.screenshots)
            palette.state.filter = filter
        }
        // The search first: a new one leaves the grid.
        palette.state.historyQuery = query
        palette.state.isBrowsingGrid = true
        palette.state.selection = row
        let footer = palette.footerActions
        return (footer.primary.map { ["\($0) ↵"] } ?? []) + footer.secondary.map(\.description)
    }

    /// The detail's buttons as the footer would name them: Return's first, then each with a key,
    /// leaving out Show in Finder, which has none, and Quick Look where Space types.
    static func keyedNames(_ detail: ScreengrabDetail) -> [String] {
        detail.buttons.compactMap { button in
            guard let keys = button.shortcuts.first else { return nil }
            return "\(button.title) \(keys.joined())"
        }
    }

    static func key(_ keyCode: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        ScreengrabsPaletteContentTests.key(keyCode, characters, modifiers: modifiers)
    }
}
