import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The ScreenGrabs tab's recordings (#494): made-up recordings (stand-in files and the recorder's
/// `meta.json`) in a temporary folder, indexed by a `RecordingLibrary` there, beside screenshots in a
/// Clipboard History there, with a named pasteboard, a Trash, Quick Look, and Finder that record
/// what they're asked. Nothing reaches the real Trash, folders, pasteboard, or capture devices.
@MainActor
@Suite("ScreenGrabs tab recordings")
struct ScreengrabsRecordingsTabTests {
    static let macOS14 = PluginCompatibility(macOSMajorVersion: 14)
    static let macOS15 = PluginCompatibility(macOSMajorVersion: 15)
    /// 2026-10-17 10:38:05 in UTC.
    static let start = Date(timeIntervalSince1970: 1_792_233_485)

    // MARK: What it lists

    @Test("Screenshots and recordings together, newest first, each keeping its own order")
    func mergeOrder() {
        let shots = [Self.screenshot(at: 300), Self.screenshot(at: 100)]
        let videos = [Self.indexed(at: 400), Self.indexed(at: 200), Self.indexed(at: 50)]
        let content = Self.resolve(shots, videos)
        #expect(content.items.map(\.date) == [400, 300, 200, 100, 50].map(Self.at))
        #expect(content.items.map { $0.recording != nil } == [true, false, true, false, true])

        let tie = Self.resolve([Self.screenshot(at: 200)], [Self.indexed(at: 200)])
        #expect(tie.items.map { $0.recording != nil } == [false, true], "A screenshot taken as a recording started comes first")
    }

    @Test("A screenshot copied again, which Clipboard History moves to the top, is listed by when it was taken")
    func screenshotsByWhenTaken() {
        // Clipboard History's order after the older screenshot's bytes were copied again.
        let shots = [Self.screenshot(at: 100), Self.screenshot(at: 300)]
        let content = Self.resolve(shots, [Self.indexed(at: 200)])
        #expect(content.items.map(\.date) == [300, 200, 100].map(Self.at))
        #expect(Self.resolve(shots, [], listsRecordings: false).items.map(\.date) == [300, 100].map(Self.at))
    }

    @Test("With Clipboard History off only recordings list; where ScreenGrabs can't record only screenshots; off, nothing")
    func whatEachSettingLists() {
        let shots = [Self.screenshot(at: 300)]
        let videos = [Self.indexed(at: 400)]
        #expect(Self.resolve(shots, videos, listsScreenshots: false).items.map(\.id) == videos.map(\.id))
        #expect(Self.resolve(shots, videos, listsRecordings: false).items.map(\.id) == shots.map(\.id))
        #expect(Self.resolve(shots, videos, listsScreenshots: false, listsRecordings: false) == .empty)
        #expect(Self.resolve(shots, videos, isEnabled: false) == .disabled)
        #expect(Self.resolve([], []) == .empty)
    }

    @Test("A search finds recordings by recording, video, screen recording, and their date, and Today and This Week narrow them")
    func search() {
        let recording = Self.indexed(at: 0, from: Self.start)
        let shot = Self.screenshot(at: 0, named: "Screenshot 2026-10-01 at 09.00.00")
        // Its start in this Mac's time zone, as its name has it: "2026-10-17 at 10.38.05" in UTC.
        let stamp = Self.nameStamp(Self.start)
        let day = String(stamp.prefix(10)), time = String(stamp.suffix(8).prefix(5))
        for query in ["recording", "Video", "screen recording", day, time] {
            #expect(Self.resolve([shot], [recording], query: query).items.map(\.id) == [recording.id], "\(query)")
        }
        #expect(Self.resolve([shot], [recording], query: "screenshot").items.map(\.id) == [shot.id])
        #expect(Self.resolve([shot], [recording], query: "zzz") == .empty)

        let now = Self.start.addingTimeInterval(60)
        #expect(Self.resolve([], [recording], filter: .today, now: now).items.count == 1)
        #expect(Self.resolve([], [recording], filter: .today, now: now.addingTimeInterval(3 * 86_400)) == .empty)
        #expect(Self.resolve([], [recording], filter: .images, now: now) == .empty, "Only Today and This Week are dates")
    }

    @Test("A search never finds what the person wrote about a recording")
    func searchNeverReadsTheReview() async throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        try fixture.library.editMetadata(of: recording.folder) {
            $0["review"] = ["note": RecordingLibraryFixture.note, "context": ["appName": RecordingLibraryFixture.appName], "type": "bug"]
        }
        fixture.recordings.update(recording.folder)
        #expect(fixture.content.rowCount(query: "") == 1)
        #expect(fixture.content.rowCount(query: "only the person wrote") == 0)
        #expect(fixture.content.rowCount(query: RecordingLibraryFixture.appName) == 0)
        #expect(fixture.content.rowCount(query: "bug") == 0)
    }

    @Test("A recording's name, length, and what VoiceOver reads come from the index, never anything typed")
    func names() {
        let recording = Self.indexed(at: 0, from: Self.start)
        let expected = "Screen Recording " + Self.nameStamp(Self.start)
        #expect(recording.screenRecordingName == expected)
        #expect(IndexedRecording.lengthText(42.9) == "0:42")
        #expect(IndexedRecording.lengthText(3_725) == "1:02:05")
        #expect(IndexedRecording.lengthText(.nan) == "0:00")
        #expect(IndexedRecording.spokenLength(42) == "42 seconds")

        #expect(Screengrab.recording(recording).thumbnailLabel == "Recording, 42 seconds")
        var everyScreen = recording
        everyScreen.videos.append(.init(file: "video-2.mov"))
        #expect(Screengrab.recording(everyScreen).thumbnailLabel == "Recording, 42 seconds, 2 displays")
        var missing = recording
        missing.isMissing = true
        #expect(Screengrab.recording(missing).thumbnailLabel == "Recording, moved or deleted")
        #expect(Screengrab.screenshot(Self.screenshot(at: 0)).thumbnailLabel == "Screenshot")
    }

    @Test("The empty tab names the person's own shortcuts, and says less without them")
    func emptyTitles() {
        func title(_ query: String = "", shots: Bool = true, videos: Bool = true, screenshot: String? = "⇧⌘4", record: String? = "⇧⌘5") -> String {
            ScreengrabsTabContent.emptyTitle(query: query, listsScreenshots: shots, listsRecordings: videos, screenshotKeys: screenshot, recordingKeys: record)
        }
        #expect(title() == "Take a screenshot with ⇧⌘4 or record with ⇧⌘5, and it appears here")
        #expect(title(shots: false) == "Record the screen with ⇧⌘5 and it appears here")
        #expect(title(videos: false) == "Take a screenshot with ⇧⌘4 and it appears here")
        #expect(title(screenshot: nil, record: nil) == "Take a screenshot or record the screen, and it appears here")
        #expect(title(shots: false, record: nil) == "Record the screen and it appears here")
        #expect(title("made-up") == "No matching screenshots or recordings")
    }

    // MARK: When the tab shows

    @Test("The tab shows whenever ScreenGrabs is on where it records; on macOS 14 it still needs Clipboard History")
    func visibility() {
        let everything = Set(Capability.allCases)
        let noClipboard = everything.subtracting([.clipboardHistory])
        let noScreengrabs = everything.subtracting([.screenshotTools])
        func shows(_ enabled: Set<Capability>, _ compatibility: PluginCompatibility) -> Bool {
            CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .search, enabled: enabled, compatibility: compatibility).contains(.screenshots)
        }
        #expect(shows(everything, Self.macOS15))
        #expect(shows(noClipboard, Self.macOS15), "Recordings need no Clipboard History")
        #expect(shows(everything, Self.macOS14))
        #expect(!shows(noClipboard, Self.macOS14), "macOS 14 lists screenshots only")
        #expect(!shows(noScreengrabs, Self.macOS15))
        #expect(!shows(noScreengrabs, Self.macOS14))
        #expect(CommandPaletteTab.screenshots.listsRecordings)
        #expect(!CommandPaletteTab.clipboard.listsRecordings)
    }

    @Test("The content lists recordings only where ScreenGrabs records, and screenshots only with Clipboard History")
    func contentFollowsTheSettings() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addRecording(at: Self.start)
        try fixture.addScreenshot(at: Self.start.addingTimeInterval(-60))
        #expect(fixture.content.rowCount(query: "") == 2)
        fixture.preferences.setCapability(.clipboardHistory, enabled: false)
        #expect(fixture.content.content(query: "").items.map { $0.recording != nil } == [true])

        let old = RecordingsTabFixture(compatibility: Self.macOS14)
        defer { old.tearDown() }
        try old.addRecording(at: Self.start)
        try old.addScreenshot(at: Self.start.addingTimeInterval(-60))
        #expect(old.content.content(query: "").items.map { $0.recording != nil } == [false])
    }

    // MARK: Keys on a recording

    @Test("Return and ⌘C copy a recording's files, ⌘P pastes them, ⌘Return and ⌘E open it, and Space shows it in Quick Look")
    func keys() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        let content = fixture.content
        let palette = fixture.log.actions
        content.didShow(palette: palette)

        content.activate(row: 0, query: "", palette: palette)
        content.copy(row: 0, query: "", palette: palette)
        content.paste(row: 0, query: "", palette: palette)
        #expect(fixture.log.calls == [.copyFiles(recording.sharingURLs), .copyFiles(recording.sharingURLs), .pasteFiles(recording.sharingURLs)])
        #expect(recording.sharingURLs.map(\.lastPathComponent) == ["video-1-mixdown.mp4"], "Each display's mixdown, as the window's Copy")

        content.commandActivate(row: 0, query: "", palette: palette)
        content.handleCommandKey("e", row: 0, query: "", palette: palette)
        #expect(fixture.opened == [recording.id, recording.id])
        #expect(fixture.log.calls.suffix(2) == [.dismiss, .dismiss], "The palette closes for the window")

        let playback = try #require(content.playback(row: 0, query: ""))
        #expect(playback.title == "Quick Look")
        #expect(playback.listsInFooter)
        playback.toggle()
        #expect(fixture.quickLook.previews == [recording.sharingURLs])
        #expect(fixture.log.calls.last == .dismiss, "The palette closes so Quick Look has the keyboard")

        let footer = content.footerActions(row: 0, query: "")
        #expect(footer.primary == "Copy")
        #expect(footer.secondary.map(\.description) == ["Paste ⌘P", "Open ⌘↵"])
        #expect(fixture.log.warnings.isEmpty)
    }

    @Test("A recording that won't open again says so at the notch")
    func openFails() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addRecording(at: Self.start)
        fixture.openSucceeds = false
        fixture.content.commandActivate(row: 0, query: "", palette: fixture.log.actions)
        #expect(fixture.log.warnings == [ScreengrabsPaletteContent.openFailedMessage])
    }

    @Test("A recording of every screen is one tile: Return copies, ⌘P pastes, and Space previews every display's video")
    func everyScreen() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start, displays: 2)
        let content = fixture.content
        #expect(content.rowCount(query: "") == 1)
        #expect(recording.sharingURLs.count == 2)

        content.activate(row: 0, query: "", palette: fixture.log.actions)
        content.paste(row: 0, query: "", palette: fixture.log.actions)
        try #require(content.playback(row: 0, query: "")).toggle()
        #expect(fixture.log.calls.prefix(2) == [.copyFiles(recording.sharingURLs), .pasteFiles(recording.sharingURLs)])
        #expect(fixture.quickLook.previews == [recording.sharingURLs])
        #expect(content.footerActions(row: 0, query: "").primary == "Copy 2 Videos")
        let question = try #require(content.deletionConfirmation(row: 0, query: ""))
        #expect(question.message == "Its folder and its 2 videos go to the Trash. You can put them back from there.")
    }

    @Test("Return on a recording, through the palette, puts every display's video on the clipboard")
    func returnThroughThePalette() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start, displays: 2)
        let palette = fixture.palette
        palette.selectOnOpening(.screenshots)

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.handleKeyDown(Self.key(kVK_Return, "\r")) == nil)
        let copied = fixture.library.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(copied?.map(\.lastPathComponent) == recording.sharingURLs.map(\.lastPathComponent))
        #expect(copied?.count == 2)
        #expect(fixture.notices.messages == ["Copied to Clipboard"])
    }

    @Test("⌘P on a recording, through the palette, copies its files and says why it couldn't paste without Accessibility")
    func pasteThroughThePalette() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        let palette = fixture.palette
        palette.canPaste = { false }
        palette.frontmostApp = { PasteTarget(processIdentifier: 4_242, isKeybumps: false) }
        palette.rememberPasteTarget()
        palette.selectOnOpening(.screenshots)

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.handleKeyDown(Self.key(kVK_ANSI_P, "p", modifiers: .command)) == nil)
        let copied = fixture.library.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(copied?.map(\.lastPathComponent) == recording.sharingURLs.map(\.lastPathComponent))
        #expect(fixture.notices.messages == [PalettePasteRoute.Reason.needsAccessibility.notice])
    }

    @Test("A screenshot's Space shows its file in Quick Look, and the footer names Quick Look Space")
    func screenshotQuickLook() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let entry = try fixture.addScreenshot(at: Self.start)
        let playback = try #require(fixture.content.playback(row: 0, query: ""))
        playback.toggle()
        #expect(fixture.quickLook.previews == [[try #require(entry.sourceURL)]])
        let footer = PaletteFooterActions.resolve(
            tab: .screenshots, searchItem: nil, content: fixture.content.footerActions(row: 0, query: ""), playback: playback.title
        )
        #expect(footer.secondary.map(\.description) == ["Paste ⌘P", "Edit ⌘↵", "Quick Look Space"])
    }

    @Test("Show in Finder selects a recording's videos, and a screenshot's file while it's where it was saved")
    func showInFinder() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let entry = try fixture.addScreenshot(at: Self.start.addingTimeInterval(-60))
        let recording = try fixture.addRecording(at: Self.start)
        let items = fixture.content.content(query: "").items
        fixture.content.didShow(palette: fixture.log.actions)
        fixture.content.reveal(items[0])
        fixture.content.reveal(items[1])
        #expect(fixture.revealed == [recording.sharingURLs, [try #require(entry.sourceURL)]])

        try FileManager.default.removeItem(at: try #require(entry.sourceURL))
        #expect(items[1].finderFiles.isEmpty, "Nothing to show once the file's gone")
        #expect(items[1].previewFiles == [try #require(entry.imageURL)], "Quick Look shows Clipboard History's copy")
    }

    // MARK: Delete

    @Test("Delete on a recording asks, then moves its folder to the Trash and takes it out of the tab")
    func deleteMovesToTheTrash() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        let content = fixture.content
        content.didShow(palette: fixture.log.actions)

        #expect(!content.delete(row: 0, query: ""), "Never without the question")
        #expect(fixture.trashed.isEmpty)
        let question = try #require(content.deletionConfirmation(row: 0, query: ""))
        #expect(question.title == "Move this recording to the Trash?")
        #expect(question.message == "Its folder and video go to the Trash. You can put them back from there.")
        #expect(question.confirmTitle == "Move to Trash")
        question.delete()
        #expect(fixture.trashed == [recording.folder])
        #expect(fixture.recordings.recordings.isEmpty)
        #expect(content.rowCount(query: "") == 0)
    }

    @Test("A recording that can't go to the Trash stays, and the notch says so")
    func trashFails() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addRecording(at: Self.start)
        fixture.trashFails = true
        fixture.content.didShow(palette: fixture.log.actions)
        try #require(fixture.content.deletionConfirmation(row: 0, query: "")).delete()
        #expect(fixture.log.warnings == [ScreengrabsPaletteContent.trashFailedMessage])
        #expect(fixture.content.rowCount(query: "") == 1)
    }

    @Test("Delete on a recording, through the palette, shows Move to Trash, and its answer trashes it")
    func deleteThroughThePalette() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        try fixture.addScreenshot(at: Self.start.addingTimeInterval(-60))
        let recording = try fixture.addRecording(at: Self.start)
        let palette = fixture.palette
        palette.selectOnOpening(.screenshots)

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.handleKeyDown(Self.key(kVK_Delete, "\u{7f}")) == nil)
        let asked = try #require(palette.state.contentPendingDeletion)
        #expect(asked.confirmTitle == "Move to Trash")
        #expect(fixture.trashed.isEmpty)
        palette.confirmContentDeletion(asked)
        palette.contentDeletionDidClose()
        #expect(fixture.trashed == [recording.folder])
        #expect(fixture.content.content(query: "").items.map { $0.recording != nil } == [false], "The screenshot stays")
        #expect(palette.state.selection == 0)
    }

    @Test("A screenshot's Delete still removes it from the tab without a question, and Clear All leaves recordings")
    func screenshotsDeleteAsBefore() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let entry = try fixture.addScreenshot(at: Self.start.addingTimeInterval(-60))
        try fixture.addScreenshot(at: Self.start.addingTimeInterval(-120))
        try fixture.addRecording(at: Self.start)
        #expect(fixture.content.deletionConfirmation(row: 1, query: "") == nil)
        #expect(fixture.content.delete(row: 1, query: ""))
        #expect(FileManager.default.fileExists(atPath: try #require(entry.sourceURL).path), "Its file stays")
        fixture.library.clipboard.clearScreenshots()
        #expect(fixture.content.content(query: "").items.map { $0.recording != nil } == [true])
        #expect(fixture.trashed.isEmpty)
    }

    // MARK: A recording moved or deleted

    @Test("A recording whose folder is gone stays, marked missing, says it can't open, and Delete removes it at once")
    func goneFolder() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        try FileManager.default.removeItem(at: recording.folder)
        let content = fixture.content
        content.didShow(palette: fixture.log.actions)

        let item = try #require(content.item(at: 0, query: ""))
        #expect(item.isMissing)
        content.activate(row: 0, query: "", palette: fixture.log.actions)
        content.commandActivate(row: 0, query: "", palette: fixture.log.actions)
        content.copy(row: 0, query: "", palette: fixture.log.actions)
        content.paste(row: 0, query: "", palette: fixture.log.actions)
        let playback = try #require(content.playback(row: 0, query: ""))
        #expect(!playback.listsInFooter, "The footer offers only Remove")
        playback.toggle()
        #expect(fixture.log.warnings == Array(repeating: ScreengrabsPaletteContent.missingMessage, count: 5))
        #expect(fixture.log.calls.filter { $0 != .warn }.isEmpty, "Nothing copied, pasted, or opened")
        #expect(fixture.opened.isEmpty && fixture.quickLook.previews.isEmpty)

        let footer = content.footerActions(row: 0, query: "")
        #expect(footer.primary == nil)
        #expect(footer.secondary.map(\.description) == ["Remove ⌫"])
        #expect(content.deletionConfirmation(row: 0, query: "") == nil, "No question: nothing's left to trash")
        #expect(content.delete(row: 0, query: ""))
        #expect(fixture.recordings.recordings.isEmpty)
        #expect(fixture.trashed.isEmpty)
    }

    @Test("A recording deleted while the tab shows is marked missing as soon as it's used")
    func goneWhileShowing() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        fixture.content.didShow(palette: fixture.log.actions)
        try FileManager.default.removeItem(at: recording.folder)

        fixture.content.activate(row: 0, query: "", palette: fixture.log.actions)
        #expect(fixture.log.warnings == [ScreengrabsPaletteContent.missingMessage])
        #expect(fixture.content.item(at: 0, query: "")?.isMissing == true)
    }

    @Test("A recording of every screen with one display's video deleted can't be copied, pasted, previewed, or opened, as the recording window can't, and is marked missing")
    func oneDisplaysVideoGone() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start, displays: 2)
        let content = fixture.content
        content.didShow(palette: fixture.log.actions)
        try FileManager.default.removeItem(at: recording.videoURLs[1])
        #expect(recording.savedCapture() == nil, "The recording window refuses it")

        content.activate(row: 0, query: "", palette: fixture.log.actions)
        #expect(content.item(at: 0, query: "")?.isMissing == true, "Marked as soon as it's used")
        content.copy(row: 0, query: "", palette: fixture.log.actions)
        content.paste(row: 0, query: "", palette: fixture.log.actions)
        content.commandActivate(row: 0, query: "", palette: fixture.log.actions)
        try #require(content.playback(row: 0, query: "")).toggle()
        #expect(fixture.log.warnings == Array(repeating: ScreengrabsPaletteContent.missingMessage, count: 5))
        #expect(fixture.log.calls.filter { $0 != .warn }.isEmpty, "Nothing copied, pasted, or opened")
        #expect(fixture.opened.isEmpty && fixture.quickLook.previews.isEmpty)

        content.didShow(palette: fixture.log.actions)
        #expect(content.item(at: 0, query: "")?.isMissing == true, "Still marked when the tab shows again")
        #expect(content.footerActions(row: 0, query: "").secondary.map(\.description) == ["Remove ⌫"])
    }

    @Test("Return through the palette on a recording with one display's video deleted puts nothing on the pasteboard and says it can't open")
    func oneDisplaysVideoGoneThroughThePalette() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start, displays: 2)
        let palette = fixture.palette
        palette.selectOnOpening(.screenshots)
        try FileManager.default.removeItem(at: recording.videoURLs[1])
        let changeCount = fixture.library.pasteboard.changeCount

        #expect(palette.handleKeyDown(Self.key(kVK_DownArrow)) == nil)
        #expect(palette.handleKeyDown(Self.key(kVK_Return, "\r")) == nil)
        #expect(palette.handleKeyDown(Self.key(kVK_ANSI_P, "p", modifiers: .command)) == nil)
        #expect(fixture.library.pasteboard.changeCount == changeCount, "Nothing put on the pasteboard")
        let copied = fixture.library.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(copied?.isEmpty ?? true)
        #expect(fixture.notices.messages == Array(repeating: ScreengrabsPaletteContent.missingMessage, count: 2))
    }

    @Test("A display whose mixdown is deleted copies its full video instead, as the recording window's Copy does")
    func mixdownGone() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start, displays: 2)
        try FileManager.default.removeItem(at: recording.sharingURLs[1])
        fixture.content.didShow(palette: fixture.log.actions)
        #expect(fixture.content.item(at: 0, query: "")?.isMissing == false)

        fixture.content.activate(row: 0, query: "", palette: fixture.log.actions)
        #expect(fixture.log.calls == [.copyFiles([recording.sharingURLs[0], recording.videoURLs[1]])])
        #expect(fixture.log.warnings.isEmpty)
    }

    @Test("Comes back unmarked when its folder is back")
    func folderBack() throws {
        let fixture = RecordingsTabFixture()
        defer { fixture.tearDown() }
        let recording = try fixture.addRecording(at: Self.start)
        let aside = fixture.library.root.url.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.moveItem(at: recording.folder, to: aside)
        fixture.content.didShow(palette: fixture.log.actions)
        #expect(fixture.content.item(at: 0, query: "")?.isMissing == true)
        try FileManager.default.moveItem(at: aside, to: recording.folder)
        fixture.content.didShow(palette: fixture.log.actions)
        #expect(fixture.content.item(at: 0, query: "")?.isMissing == false)
    }

    // MARK: The Trash

    @Test("The Trash takes only a folder the recorder named that holds the recording's files, and the unit-test host's takes none")
    func trashChecks() throws {
        var moved: [URL] = []
        let trash = RecordingTrash { moved.append($0) }
        let folder = URL(fileURLWithPath: "/made-up/Recordings/1792233485", isDirectory: true)
        let file = folder.appendingPathComponent("video-1.mov")
        try trash.moveToTrash(folder: folder, holding: [file])
        #expect(moved == [folder])

        let recordings = URL(fileURLWithPath: "/made-up/Recordings", isDirectory: true)
        #expect(throws: RecordingTrash.Failure.notARecordingFolder) {
            try trash.moveToTrash(folder: recordings, holding: [recordings.appendingPathComponent("video-1.mov")])
        }
        #expect(throws: RecordingTrash.Failure.notARecordingFolder) {
            try trash.moveToTrash(folder: folder, holding: [recordings.appendingPathComponent("other.mov")])
        }
        #expect(throws: RecordingTrash.Failure.notARecordingFolder) { try trash.moveToTrash(folder: folder, holding: []) }
        #expect(moved == [folder])
        #expect(throws: RecordingTrash.Failure.unavailable) { try RecordingTrash.app.moveToTrash(folder: folder, holding: [file]) }
    }

    // MARK: Opening it again

    @Test("A saved recording opens again from its meta.json: each video's size and sounds, never its review")
    func savedCapture() throws {
        let review = ReviewFixture()
        defer { review.tearDown() }
        let input = try review.video(displays: 2)
        guard case .video(let capture) = input else { return }
        let structure = try #require(RecordingStructure.read(in: capture.folder))
        let recording = IndexedRecording(folder: capture.folder, metadata: structure)
        let reopened = try #require(recording.savedCapture())
        #expect(reopened.videos == capture.videos)
        #expect(reopened.duration == capture.duration)

        try FileManager.default.removeItem(at: capture.videos[1].file)
        #expect(recording.savedCapture() == nil, "A video is gone")
    }

    @Test("⌘Return's window opens on the saved recording with Move to Trash and Done")
    func flowOpensTheSavedRecording() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let library = fixture.library()
        let capture = try await fixture.recording(at: 1_000)
        library.add(capture)
        let flow = fixture.reviewFlow(recordings: library)
        let recording = try #require(library.recordings.first)

        #expect(flow.open(recording))
        let opened = await eventually { flow.panel?.model != nil }
        #expect(opened)
        let model = try #require(flow.panel?.model)
        #expect(model.mode == .saved)
        #expect(ScreencastRecordingReviewBar.actions(for: model).map(\.title) == ["Move to Trash", "Copy", "Done"])

        try FileManager.default.removeItem(at: capture.metadataURL)
        #expect(!flow.open(recording), "Its meta.json is gone")
        await flow.panel?.close()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: The window opened from ⌘3

    @Test("Opened from ⌘3, Done, Return, Escape, and quitting only close: the review in meta.json stays as it was")
    func doneOnlyCloses() async throws {
        let review = ReviewFixture()
        defer { review.tearDown() }
        let input = try review.video()
        try ScreencastReview.write(
            ScreencastReview(note: "made-up note", type: .feature, repository: "serpcompany/keybumps", context: .none, reviewedAt: ReviewFixture.reviewDate),
            to: input.metadataURL
        )
        let before = try Data(contentsOf: input.metadataURL)

        let done = SavedWindow(input, review)
        #expect(ScreencastRecordingReviewBar.actions(for: done.model).map(\.title) == ["Move to Trash", "Copy", "Done"])
        await done.model.save()
        #expect(done.outcomes == [.closed(input)])
        let escaped = SavedWindow(input, review)
        await escaped.model.close()
        #expect(escaped.outcomes == [.closed(input)])
        let quit = SavedWindow(input, review)
        quit.model.saveNow()
        #expect(quit.outcomes == [.closed(input)])
        #expect(try Data(contentsOf: input.metadataURL) == before, "Nothing written again")
        #expect(ScreencastReviewFlow.notice(for: .closed(input)) == nil, "Done says nothing at the notch")
    }

    @Test("Opened from ⌘3, Copy copies every display's video, kept out of Clipboard History, and writes nothing")
    func savedCopy() async throws {
        let review = ReviewFixture()
        defer { review.tearDown() }
        let input = try review.video(displays: 2)
        let before = try Data(contentsOf: input.metadataURL)
        let window = SavedWindow(input, review)
        await window.model.copy()
        #expect(window.outcomes == [.copied(input)])
        let copied = review.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(copied?.map(\.lastPathComponent) == ["video-1-mixdown.mp4", "video-2-mixdown.mp4"])
        #expect(window.suppressions == 1)
        #expect(try Data(contentsOf: input.metadataURL) == before)
    }

    @Test("Opened from ⌘3 with a trim, Done and Copy write it and the tile's poster frame is made again; Keep Original only closes; the review in meta.json stays")
    func savedWithAnEdit() async throws {
        let review = ReviewFixture()
        let index = RecordingLibraryFixture()
        defer {
            review.tearDown()
            index.tearDown()
        }
        let input = try review.video()
        try ScreencastReview.write(
            ScreencastReview(note: "made-up note", type: .feature, repository: "serpcompany/keybumps", context: .none, reviewedAt: ReviewFixture.reviewDate),
            to: input.metadataURL
        )
        let before = try Data(contentsOf: input.metadataURL)
        let library = index.library()
        guard case .video(let capture) = input else { return }
        library.add(capture)
        func posterFrame() throws -> String { try #require(library.recordings.first).posterFrame }
        let trim = ScreencastTimeRange(start: 1, end: 3)

        // Done with an edit writes it (the owner is deciding whether Done should), and ends saved.
        let doneExport = FakeEditExport()
        let done = SavedWindow(input, review, export: doneExport.export)
        done.model.edit { $0.setTrim(start: 1, end: 3) }
        await done.model.save()
        #expect(doneExport.runs.map(\.trim) == [trim])
        guard case .saved(.video(let saved))? = done.outcomes.first, done.outcomes.count == 1 else {
            Issue.record("saved: \(done.outcomes)")
            return
        }
        #expect(saved.duration == 2, "the edited recording")
        let first = try posterFrame()
        library.reviewEnded(try #require(done.outcomes.first))
        let afterDone = try posterFrame()
        #expect(afterDone != first, "made again: the files changed")
        #expect(try Data(contentsOf: input.metadataURL) == before, "The review isn't written again")

        // Copy with an edit writes it, copies it, and ends copied.
        let copyExport = FakeEditExport()
        let copying = SavedWindow(input, review, export: copyExport.export)
        copying.model.edit { $0.setTrim(start: 1, end: 3) }
        await copying.model.copy()
        #expect(copyExport.runs.map(\.trim) == [trim])
        guard case .copied? = copying.outcomes.first, copying.outcomes.count == 1 else {
            Issue.record("copied: \(copying.outcomes)")
            return
        }
        let copied = review.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(copied?.map(\.lastPathComponent) == ["video-1-mixdown.mp4"])
        #expect(copying.suppressions == 1)
        library.reviewEnded(try #require(copying.outcomes.first))
        let afterCopy = try posterFrame()
        #expect(afterCopy != afterDone, "made again: the files changed")
        #expect(try Data(contentsOf: input.metadataURL) == before)

        // Closing with an edit asks "Save your edits?"; Keep Original writes nothing and only closes.
        let keepExport = FakeEditExport()
        let keeping = SavedWindow(input, review, export: keepExport.export)
        keeping.model.edit { $0.setTrim(start: 1, end: 3) }
        keeping.model.askToSaveEdits()
        #expect(keeping.model.isAskingToSaveEdits)
        #expect(ScreencastRecordingReviewBar.question(for: keeping.model) == "Save your edits?")
        #expect(ScreencastRecordingReviewBar.actions(for: keeping.model).map(\.title) == ["Keep Original", "Save Edited"])
        await keeping.model.keepOriginal()
        #expect(keepExport.runs.isEmpty, "Nothing exported")
        #expect(keeping.outcomes == [.closed(input)])
        library.reviewEnded(try #require(keeping.outcomes.first))
        #expect(try posterFrame() == afterCopy, "Kept: the files didn't change")
        #expect(try Data(contentsOf: input.metadataURL) == before)
    }

    @Test("Opened from ⌘3, Move to Trash asks in the bar, then moves the folder to the Trash; after a recording, Discard is as it was")
    func savedMoveToTrash() throws {
        let review = ReviewFixture()
        defer { review.tearDown() }
        let input = try review.video()
        let window = SavedWindow(input, review)
        window.model.askToDiscard()
        #expect(ScreencastRecordingReviewBar.question(for: window.model) == "Move this recording to the Trash?")
        #expect(ScreencastRecordingReviewBar.actions(for: window.model).map(\.title) == ["Keep", "Move to Trash"])
        window.model.confirmDiscard()
        #expect(window.trashed == [input.folder])
        #expect(window.outcomes == [.movedToTrash(input)])
        #expect(FileManager.default.fileExists(atPath: input.folder.path), "Moved by the Trash, never deleted here")
        #expect(ScreencastReviewFlow.notice(for: .movedToTrash(input)) == nil)

        let failing = SavedWindow(input, review, trashFails: true)
        failing.model.askToDiscard()
        failing.model.confirmDiscard()
        #expect(failing.model.failure == .trashFailed)
        #expect(failing.outcomes.isEmpty, "It stays open to say why")

        let fresh = review.model(input)
        #expect(ScreencastRecordingReviewBar.actions(for: fresh).map(\.title) == ["Discard", "Copy", "Save"])
        fresh.askToDiscard()
        #expect(ScreencastRecordingReviewBar.question(for: fresh) == "Discard this recording?")
    }

    @Test("The index keeps a recording the window closed and drops one it moved to the Trash")
    func indexFollowsTheWindow() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let library = fixture.library()
        let capture = try await fixture.recording(at: 1_000)
        library.add(capture)
        library.reviewEnded(.closed(.video(capture)))
        #expect(library.recordings.count == 1)
        library.reviewEnded(.movedToTrash(.video(capture)))
        #expect(library.recordings.isEmpty)
    }

    @Test("A tile loads its recording's thumbnail again once Save or Copy may have edited it, and not after Done only closes")
    func tileFollowsAnEdit() async throws {
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let library = fixture.library()
        let capture = try await fixture.recording(at: 1_000)
        library.add(capture)
        func key() throws -> String { Screengrab.recording(try #require(library.recordings.first)).thumbnailKey }
        let first = try key()

        library.reviewEnded(.closed(.video(capture)))
        #expect(try key() == first, "nothing changed")
        library.reviewEnded(.saved(.video(capture)))
        let saved = try key()
        #expect(saved != first)
        library.reviewEnded(.copied(.video(capture)))
        #expect(try key() != saved)
    }

    // MARK: Helpers

    static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    static func nameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    static func screenshot(at seconds: TimeInterval, named name: String = "Screenshot") -> ClipboardEntry {
        ClipboardEntry(
            id: UUID(), text: "", capturedAt: at(seconds), kind: .image,
            sourcePath: "/made-up/\(name).png", isScreenCapture: true
        )
    }

    static func indexed(at seconds: TimeInterval, from origin: Date = start) -> IndexedRecording {
        let date = origin.addingTimeInterval(seconds)
        return IndexedRecording(
            folder: URL(fileURLWithPath: "/made-up/\(Int(date.timeIntervalSince1970))", isDirectory: true),
            metadata: RecordingStructure(startedAt: date, target: "display", duration: 42, displayCount: 1, videos: [.init(file: "video-1.mov", mixdown: nil)])
        )
    }

    static func resolve(
        _ shots: [ClipboardEntry],
        _ videos: [IndexedRecording],
        query: String = "",
        filter: PaletteFilter? = nil,
        isEnabled: Bool = true,
        listsScreenshots: Bool = true,
        listsRecordings: Bool = true,
        now: Date = Date()
    ) -> ScreengrabsTabContent {
        ScreengrabsTabContent.resolve(
            screenshots: shots, recordings: videos, query: query, filter: filter, isEnabled: isEnabled,
            listsScreenshots: listsScreenshots, listsRecordings: listsRecordings, now: now
        )
    }

    static func key(_ keyCode: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        ScreengrabsPaletteContentTests.key(keyCode, characters, modifiers: modifiers)
    }
}

/// Made-up recordings and screenshots for the tab, indexed and kept in `RecordingLibraryFixture`'s
/// temporary folder, with the Trash, Quick Look, Finder, and opening the window recorded, and a
/// palette that shows the rows on the fixture's named pasteboard.
@MainActor
private final class RecordingsTabFixture {
    let library = RecordingLibraryFixture()
    let preferences: AppPreferences
    let log = RecordingsTabLog()
    let quickLook = FakeQuickLook()
    let notices = RecordingNotices()
    let snippets = TemporaryFolder()
    private(set) var trashed: [URL] = []
    var trashFails = false
    private(set) var opened: [UUID] = []
    var openSucceeds = true
    private(set) var revealed: [[URL]] = []
    lazy var recordings = library.library()
    lazy var content: ScreengrabsPaletteContent = ScreengrabsPaletteContent(
        clipboard: library.clipboard,
        preferences: preferences,
        recordings: recordings,
        openRecording: { [weak self] recording in
            self?.opened.append(recording.id)
            return self?.openSucceeds ?? false
        },
        trash: RecordingTrash { [weak self] folder in
            guard let self, !self.trashFails else { throw CocoaError(.fileWriteNoPermission) }
            self.trashed.append(folder)
        },
        quickLook: quickLook,
        showInFinder: { [weak self] files in self?.revealed.append(files) }
    ) { nil }
    lazy var palette: CommandPaletteController = {
        let dictationHistory = DictationHistoryService(
            recordingsDirectoryURL: library.root.url.appendingPathComponent("dictation", isDirectory: true)
        )
        let palette = CommandPaletteController(
            clipboard: library.clipboard,
            dictationHistory: dictationHistory,
            dictationService: DictationService(language: "en-US", history: dictationHistory, paster: InertTextPaster(), allowsSystemAccess: false),
            preferences: preferences,
            snippets: snippets.makeStore(),
            pasteboard: library.pasteboard,
            notices: notices,
            search: QuickSearchModel.forTests(in: library.root.url)
        )
        palette.tabContents = [.screenshots: content]
        return palette
    }()

    init(compatibility: PluginCompatibility = PluginCompatibility(macOSMajorVersion: 15)) {
        preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: compatibility)
    }

    /// A recording's folder as the recorder leaves it, with stand-in files (each display's video
    /// and mixdown) and its `meta.json`, indexed as the recorder finishing adds it.
    @discardableResult
    func addRecording(at date: Date, displays: Int = 1) throws -> IndexedRecording {
        let parent = library.root.url.appendingPathComponent("Recordings", isDirectory: true)
        let folder = parent.appendingPathComponent(String(Int(date.timeIntervalSince1970)), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let videos = try (0..<displays).map { index in
            let file = folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: index))
            let mixdown = folder.appendingPathComponent(ScreencastCaptureFolder.mixdownName(index: index))
            try Data("made-up \(file.lastPathComponent)".utf8).write(to: file)
            try Data("made-up \(mixdown.lastPathComponent)".utf8).write(to: mixdown)
            return ScreencastVideo(file: file, mixdown: mixdown, pixelWidth: 64, pixelHeight: 36, audioTracks: [.microphone], duration: 42)
        }
        let capture = ScreencastCapture(folder: folder, videos: videos, duration: 42, endedEarly: nil)
        try ScreencastMetadata(capture: capture, target: displays > 1 ? .everyDisplay : .display(1), startedAt: date)
            .write(to: capture.metadataURL)
        recordings.add(capture)
        return try #require(recordings.recordings.first { $0.folder.lastPathComponent == folder.lastPathComponent })
    }

    /// A made-up screenshot in Clipboard History, taken at `date`, with its file kept.
    @discardableResult
    func addScreenshot(at date: Date) throws -> ClipboardEntry {
        let file = try library.png(seed: Int(date.timeIntervalSince1970) % 200, named: "Screenshot \(Int(date.timeIntervalSince1970)).png")
        #expect(library.clipboard.importScreenshot(at: file, capturedAt: date))
        return try #require(library.clipboard.entries.first { $0.sourcePath == file.path })
    }

    func tearDown() {
        snippets.remove()
        library.tearDown()
    }
}

/// What the rows ask of the palette.
@MainActor
private final class RecordingsTabLog {
    enum Call: Equatable {
        case copyFiles([URL]), pasteFiles([URL]), copyEntry(UUID), pasteEntry(UUID), edit(UUID), dismiss, warn
    }

    private(set) var calls: [Call] = []
    private(set) var warnings: [String] = []

    var actions: PaletteContentActions {
        PaletteContentActions(
            dismiss: { [weak self] in self?.calls.append(.dismiss) },
            selectRow: { _ in },
            clearQuery: {},
            copyClipboardEntry: { [weak self] in self?.calls.append(.copyEntry($0.id)) },
            pasteClipboardEntry: { [weak self] in self?.calls.append(.pasteEntry($0.id)) },
            editClipboardImage: { [weak self] in self?.calls.append(.edit($0.id)) },
            copyFiles: { [weak self] in self?.calls.append(.copyFiles($0)) },
            pasteFiles: { [weak self] in self?.calls.append(.pasteFiles($0)) },
            warn: { [weak self] in
                self?.calls.append(.warn)
                self?.warnings.append($0)
            }
        )
    }
}

@MainActor
private final class FakeQuickLook: ScreengrabsQuickLooking {
    private(set) var previews: [[URL]] = []
    func preview(_ files: [URL]) { previews.append(files) }
}

private final class RecordingNotices: PaletteNoticePresenting {
    private(set) var messages: [String] = []
    func showNotice(_ message: String, isWarning: Bool) { messages.append(message) }
}

/// A recording window's model opened from ⌘3 on `input` (`ScreencastReviewMode.saved`), with a Trash
/// that records what it's given, an export (a test's stand-in, `FakeEditExport`, or the movies),
/// and the outcomes and Clipboard History skips it asks for.
@MainActor
private final class SavedWindow {
    private final class Log {
        var outcomes: [ScreencastReviewOutcome] = []
        var trashed: [URL] = []
        var suppressions = 0
    }

    let model: ScreencastReviewModel
    private let log: Log
    var outcomes: [ScreencastReviewOutcome] { log.outcomes }
    var trashed: [URL] { log.trashed }
    var suppressions: Int { log.suppressions }

    init(_ input: ScreencastReviewInput, _ review: ReviewFixture, trashFails: Bool = false, export: ScreencastEditExport = .movies) {
        let log = Log()
        self.log = log
        model = ScreencastReviewModel(
            input: input,
            repositories: review.repositories,
            pasteboard: review.pasteboard,
            keepOutOfClipboardHistory: { log.suppressions += 1 },
            now: { ReviewFixture.reviewDate },
            export: export,
            mode: .saved,
            trash: RecordingTrash { folder in
                if trashFails { throw CocoaError(.fileWriteNoPermission) }
                log.trashed.append(folder)
            }
        )
        model.onFinish = { log.outcomes.append($0) }
    }
}
