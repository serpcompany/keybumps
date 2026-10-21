import AppKit
import SwiftUI

/// The ScreenGrabs tab's screenshots: only screen captures from Clipboard History.
enum ScreenshotPaletteContent: Equatable {
    case disabled
    case empty
    case entries([ClipboardEntry])

    static func resolve(entries: [ClipboardEntry], query: String, isEnabled: Bool) -> ScreenshotPaletteContent {
        guard isEnabled else { return .disabled }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.filter { $0.isScreenshot && (trimmed.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(trimmed)) }
        return matches.isEmpty ? .empty : .entries(matches)
    }

    var entries: [ClipboardEntry] {
        guard case .entries(let entries) = self else { return [] }
        return entries
    }
}

/// What choosing a screenshot does. Return or a double-click copies it, as in the Clipboard tab.
/// Command-Return or Command-click opens it in the Screenshot Editor.
enum ScreenshotPaletteAction: Equatable {
    case copy
    case edit

    init(withCommand: Bool) {
        self = withCommand ? .edit : .copy
    }
}

/// One tile in the ScreenGrabs tab (#494): a screenshot from Clipboard History, or a recording from
/// the recordings index (`RecordingLibrary`).
enum Screengrab: Equatable, Identifiable {
    case screenshot(ClipboardEntry)
    case recording(IndexedRecording)

    var id: UUID {
        switch self {
        case .screenshot(let entry): entry.id
        case .recording(let recording): recording.id
        }
    }

    /// When it was taken: a screenshot's capture, a recording's start.
    var date: Date {
        switch self {
        case .screenshot(let entry): entry.capturedAt
        case .recording(let recording): recording.startedAt
        }
    }

    /// The name under the tile.
    var name: String {
        switch self {
        case .screenshot(let entry): entry.displayText
        case .recording(let recording): recording.screenRecordingName
        }
    }

    var recording: IndexedRecording? {
        guard case .recording(let recording) = self else { return nil }
        return recording
    }

    /// A recording whose folder, or a display's video in it, was moved or deleted outside Keybumps.
    var isMissing: Bool { recording?.isMissing == true }

    /// What Space shows in Quick Look: a screenshot's file in ScreenGrabs' history (#605), which its
    /// item names twice (`sourcePath` and `mediaPath`); a recording's video for each display, as Copy
    /// copies them.
    var previewFiles: [URL] {
        switch self {
        case .screenshot(let entry): [entry.existingSourceURL ?? entry.imageURL].compactMap { $0 }
        case .recording(let recording): recording.sharingURLs
        }
    }

    /// Whether Space has something to show in Quick Look (`previewFiles`), looking at the disk only
    /// for a screenshot with no copy in Clipboard History, so the footer and the detail never wait
    /// on a file as they redraw.
    var hasPreviewFiles: Bool {
        switch self {
        case .screenshot(let entry): entry.imageURL != nil || entry.existingSourceURL != nil
        case .recording(let recording): !recording.sharingURLs.isEmpty
        }
    }

    /// Whether Show in Finder may have something to select (`finderFiles`), without looking at the
    /// disk: a screenshot's file, or a recording's videos.
    var mayShowInFinder: Bool {
        switch self {
        case .screenshot(let entry): entry.sourceURL != nil
        case .recording(let recording): !recording.sharingURLs.isEmpty
        }
    }

    /// What Show in Finder selects: a screenshot's file in ScreenGrabs' history, if it's still there;
    /// a recording's videos, also in the history. Never the copy where macOS saves screenshots.
    var finderFiles: [URL] {
        switch self {
        case .screenshot(let entry): [entry.existingSourceURL].compactMap { $0 }
        case .recording(let recording): recording.sharingURLs
        }
    }

    /// What VoiceOver reads for the thumbnail, before the name and the age: "Recording, 42
    /// seconds", or "Screenshot".
    var thumbnailLabel: String {
        guard let recording else { return "Screenshot" }
        if recording.isMissing { return "Recording, moved or deleted" }
        let length = IndexedRecording.spokenLength(recording.duration)
        let displays = recording.videos.count > 1 ? ", \(recording.videos.count) displays" : ""
        return "Recording, \(length)\(displays)"
    }

    /// What the tile loads its thumbnail for. A recording's changes with its poster frame, which an
    /// edit saved in the recording window makes again (`RecordingLibrary.reviewEnded`), so a tile on
    /// screen never keeps what the edit cropped, blurred, or trimmed away.
    var thumbnailKey: String {
        switch self {
        case .screenshot(let entry): entry.mediaPath ?? entry.id.uuidString
        case .recording(let recording): "\(recording.id.uuidString)-\(recording.posterFrame)-\(recording.isMissing)"
        }
    }
}

extension ClipboardEntry {
    /// The screenshot's own file, in ScreenGrabs' history (#605), while it's still there.
    var existingSourceURL: URL? {
        sourceURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
}

extension IndexedRecording {
    /// Its name in the ScreenGrabs tab, from when it started, as macOS names its own recordings and
    /// Keybumps its screenshots: "Screen Recording 2026-10-17 at 10.38.05". Never anything typed.
    var screenRecordingName: String {
        "Screen Recording \(Self.nameFormatter.string(from: startedAt))"
    }

    /// What a search in the ScreenGrabs tab matches: its name, which says "Screen Recording" and when
    /// it started, and "video". Never its review.
    var searchableText: String { "\(screenRecordingName) video" }

    /// Each display's full video and its mixdown, the files that hold it: what Delete's Move to Trash
    /// checks its folder holds, and what the detail pane's Size adds up.
    var files: [URL] {
        videos.flatMap { video in
            [folder.appendingPathComponent(video.file)] + [video.mixdown].compactMap { $0.map(folder.appendingPathComponent) }
        }
    }

    /// Its length on the tile: `0:42`, or `1:02:05` past an hour.
    static func lengthText(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Its length as VoiceOver reads it: "42 seconds".
    static func spokenLength(_ seconds: Double) -> String {
        spokenLengthFormatter.string(from: seconds.isFinite ? max(seconds.rounded(.down), 0) : 0) ?? lengthText(seconds)
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private static let spokenLengthFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
}

/// What the ScreenGrabs tab lists (#494, ADR 0010 decision 6).
enum ScreengrabsTabContent: Equatable {
    case disabled
    case empty
    case items([Screengrab])

    /// Screenshots while Clipboard History is on (`listsScreenshots`), and recordings where
    /// ScreenGrabs records (`listsRecordings`), together, newest first by when each was taken, not
    /// Clipboard History's order, which puts a screenshot copied again on top. Each is narrowed by
    /// the palette's filter, then the search: a screenshot's as in the Clipboard tab, a recording's
    /// by its name and "video" (`IndexedRecording.searchableText`).
    static func resolve(
        screenshots: [ClipboardEntry],
        recordings: [IndexedRecording],
        query: String,
        filter: PaletteFilter?,
        isEnabled: Bool,
        listsScreenshots: Bool,
        listsRecordings: Bool,
        now: Date = Date()
    ) -> ScreengrabsTabContent {
        guard isEnabled else { return .disabled }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shots = listsScreenshots
            ? ScreenshotPaletteContent.resolve(entries: filter.apply(screenshots) { $0.matches($1, now: now) }, query: query, isEnabled: true)
                .entries.sorted { $0.capturedAt > $1.capturedAt }
            : []
        let videos = listsRecordings
            ? filter.apply(recordings) { $0.matches(date: $1.startedAt, now: now) }
                .filter { trimmed.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(trimmed) }
            : []
        let merged = merge(shots, videos)
        return merged.isEmpty ? .empty : .items(merged)
    }

    /// Two lists already newest first, merged newest first, each keeping its own order.
    private static func merge(_ shots: [ClipboardEntry], _ videos: [IndexedRecording]) -> [Screengrab] {
        var merged: [Screengrab] = []
        merged.reserveCapacity(shots.count + videos.count)
        var shot = shots.startIndex, video = videos.startIndex
        while shot < shots.endIndex || video < videos.endIndex {
            if video < videos.endIndex, shot == shots.endIndex || videos[video].startedAt > shots[shot].capturedAt {
                merged.append(.recording(videos[video]))
                video += 1
            } else {
                merged.append(.screenshot(shots[shot]))
                shot += 1
            }
        }
        return merged
    }

    var items: [Screengrab] {
        guard case .items(let items) = self else { return [] }
        return items
    }

    /// The empty tab's title, with the person's own shortcuts, or none where one is unset: "Take a
    /// screenshot with ⇧⌘4 or record with ⇧⌘5, and it appears here". With Clipboard History off it
    /// names only recording, and where ScreenGrabs can't record, only screenshots.
    static func emptyTitle(
        query: String,
        listsScreenshots: Bool,
        listsRecordings: Bool,
        screenshotKeys: String?,
        recordingKeys: String?
    ) -> String {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "No matching screenshots or recordings" }
        let screenshot = screenshotKeys.map { "Take a screenshot with \($0)" } ?? "Take a screenshot"
        switch (listsScreenshots, listsRecordings) {
        case (true, true):
            return "\(screenshot) or \(recordingKeys.map { "record with \($0)" } ?? "record the screen"), and it appears here"
        case (false, true):
            return "\(recordingKeys.map { "Record the screen with \($0)" } ?? "Record the screen") and it appears here"
        default:
            return "\(screenshot) and it appears here"
        }
    }
}

/// The ScreenGrabs tab's rows (⌘3, #494), supplied by `ScreenshotToolsModule`: Clipboard History's
/// screenshots and the recordings index's recordings, newest first, as a grid
/// (`ScreengrabsTabContent`). Screenshots need Clipboard History on; recordings don't, and show only
/// where ScreenGrabs records.
///
/// - The grid is two columns, with the highlighted screengrab in full beside it, in the Dictation
///   tab's list-and-detail layout (#552): its picture, a button for each of its keys, its name, and
///   its information (`detail(of:query:)`, `ScreengrabDetail`). Until Down or a click goes into the
///   grid, the detail says how to show one there.
/// - A click highlights a screengrab, going into the grid as Down does, and the detail and the
///   footer name its actions (`PaletteClickAction.selects`, #552). The pointer only rings the tile
///   under it: the highlight, and with it the detail, follows clicks and keys alone, so the pointer
///   crossing the grid's right column to the detail's Delete never changes what it deletes.
/// - **Return** or a double-click copies: a screenshot as Clipboard History restores it, a recording
///   as its files, every display's, as the recording window's Copy does, kept out of Clipboard
///   History. **⌘V** pastes it.
/// - **⌘E** (Edit), **⌘Return**, or a ⌘-click opens a screenshot in the Screenshot Editor and a
///   recording in the recording window, where it's trimmed, cropped, and blurred, with Move to Trash
///   and Done (`ScreencastReviewMode.saved`).
/// - **Space** opens it in Quick Look (`ScreengrabsQuickLooking`).
/// - **Delete** removes a screenshot from the tab and moves its file in ScreenGrabs' history to the
///   Trash (#605). On a recording it asks, then moves its folder to the Trash (`RecordingTrash`).
///   Clear All clears screenshots only, the same way. A screengrab's copy where macOS saves
///   screenshots is the person's, and stays.
/// - The footer, the detail's buttons, and the context menu name these keys in that order, Delete's
///   last (#552), and each button does what its key does (`run(_:on:query:palette:)`), on the
///   screengrab it shows, found by its id when it runs.
/// - A recording moved or deleted outside Keybumps, its folder or a display's video, stays, dimmed,
///   marked "Moved or deleted" (`IndexedRecording.isMissing`, looked at again each time the tab
///   shows): its keys say it couldn't open, as the recording window can't, and Delete removes it
///   from the tab at once, with no question.
/// - The context menu and the detail have Show in Finder too, which no key does.
@MainActor
final class ScreengrabsPaletteContent: CapabilityPaletteContent {
    let tab = CommandPaletteTab.screenshots
    private let clipboard: ClipboardHistoryService
    private let preferences: AppPreferences
    /// The filter chosen from `/`'s list (`PaletteFilter.available(in:)`), which the palette keeps.
    private let filter: () -> PaletteFilter?
    /// The recordings index; nil in a composition without one, which lists screenshots only.
    let recordings: RecordingLibrary?
    /// Opens a saved recording in the recording window (`ScreencastReviewFlow.open(_:)`), or says it
    /// couldn't.
    private let openRecording: (IndexedRecording) -> Bool
    private let trash: RecordingTrash
    private let quickLook: any ScreengrabsQuickLooking
    /// Selects files in Finder; nothing under the unit-test host.
    private let showInFinder: @MainActor ([URL]) -> Void
    /// What the palette offered when it last showed the tab, for a Delete's question answered later.
    private var palette: PaletteContentActions?
    /// What each screengrab's files said, by `Screengrab.thumbnailKey`, for the detail's
    /// Information (#552): read off the main thread the first time one is highlighted, and again
    /// after the tab shows again, so a file moved or deleted since shows as such.
    private var fileFacts: [String: ScreengrabFileFacts] = [:]

    static let missingMessage = "Couldn’t open the recording: it was moved or deleted."
    static let trashFailedMessage = ScreencastReviewFailure.trashFailed.message
    static let openFailedMessage = "Couldn’t open the recording."
    static let screenshotTrashFailedMessage = "Couldn’t move the screenshot to the Trash."

    init(
        clipboard: ClipboardHistoryService,
        preferences: AppPreferences,
        recordings: RecordingLibrary? = nil,
        openRecording: @escaping (IndexedRecording) -> Bool = { _ in false },
        trash: RecordingTrash = .app,
        quickLook: (any ScreengrabsQuickLooking)? = nil,
        showInFinder: @escaping @MainActor ([URL]) -> Void = ScreengrabsPaletteContent.selectInFinder,
        filter: @escaping () -> PaletteFilter?
    ) {
        self.clipboard = clipboard
        self.preferences = preferences
        self.recordings = recordings
        self.openRecording = openRecording
        self.trash = trash
        self.quickLook = quickLook ?? ScreengrabsQuickLook.shared
        self.showInFinder = showInFinder
        self.filter = filter
    }

    /// The app's Show in Finder; nothing under the unit-test host.
    static func selectInFinder(_ files: [URL]) {
        guard !UnitTestHost.isActive, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// A grid with or without a search.
    func isGrid(query: String) -> Bool { true }

    /// Up and Down always move through the screengrabs, even with text in the search field, which
    /// then keeps Left and Right for its caret.
    var gridOwnsUpAndDown: Bool { true }

    /// Up and Down move a row of the grid's two columns and Left and Right one screengrab. Each stays
    /// put where there's nothing to move to, so Down above a shorter last row stays put, and Up from
    /// the top row leaves the grid.
    func selection(after move: PaletteMove, from row: Int, query: String) -> Int? {
        let target = switch move {
        case .up: row - ScreengrabGrid.columnCount
        case .down: row + ScreengrabGrid.columnCount
        case .left: row - 1
        case .right: row + 1
        }
        return (0..<rowCount(query: query)).contains(target) ? target : nil
    }

    func rowCount(query: String) -> Int {
        content(query: query).items.count
    }

    func activate(row: Int, query: String, palette: PaletteContentActions) {
        guard let item = item(at: row, query: query) else { return }
        choose(item, withCommand: false, palette: palette)
    }

    func commandActivate(row: Int, query: String, palette: PaletteContentActions) {
        guard let item = item(at: row, query: query) else { return }
        choose(item, withCommand: true, palette: palette)
    }

    func copy(row: Int, query: String, palette: PaletteContentActions) {
        guard let item = item(at: row, query: query) else { return }
        choose(item, withCommand: false, palette: palette)
    }

    func paste(row: Int, query: String, palette: PaletteContentActions) {
        guard let item = item(at: row, query: query) else { return }
        paste(item, palette: palette)
    }

    /// ⌘V and the context menu's Paste: a screenshot as Clipboard History restores it, a recording
    /// as its files.
    func paste(_ item: Screengrab, palette: PaletteContentActions) {
        switch item {
        case .screenshot(let entry): palette.pasteClipboardEntry(entry)
        case .recording(let recording):
            guard let files = sharingFiles(of: recording, palette: palette) else { return }
            palette.pasteFiles(files)
        }
    }

    /// Every screengrab takes ⌘V: a moved or deleted recording's only says so, as its other keys do,
    /// though the footer doesn't list it.
    func pastes(row: Int, query: String) -> Bool {
        item(at: row, query: query) != nil
    }

    /// Space: Quick Look, which closes the palette. A moved or deleted recording only says so, and
    /// the footer doesn't list it.
    func playback(row: Int, query: String) -> PalettePlayback? {
        item(at: row, query: query).flatMap(playback(of:))
    }

    /// Space on `item`: Quick Look, where there's a file to show (`Screengrab.hasPreviewFiles`).
    func playback(of item: Screengrab) -> PalettePlayback? {
        if item.isMissing {
            return PalettePlayback(title: "Quick Look", toggle: { [weak self] in self?.palette?.warn(Self.missingMessage) }, listsInFooter: false)
        }
        guard item.hasPreviewFiles else { return nil }
        return PalettePlayback(title: "Quick Look") { [weak self] in self?.preview(item) }
    }

    /// A screenshot leaves the tab, and its file in ScreenGrabs' history goes to the Trash; if it
    /// can't, it stays listed and the palette says so (`ClipboardHistoryService.delete`). A moved or deleted recording leaves
    /// the index at once. Any other recording asks first (`deletionConfirmation(row:query:)`), so
    /// it's never deleted here.
    func delete(row: Int, query: String) -> Bool {
        switch item(at: row, query: query) {
        case .screenshot(let entry):
            guard clipboard.delete(entry) else {
                palette?.warn(Self.screenshotTrashFailedMessage)
                return false
            }
            return true
        case .recording(let recording) where recording.isMissing:
            recordings?.remove(folder: recording.folder)
            return true
        case .recording, nil:
            return false
        }
    }

    /// A recording's Delete: "Move this recording to the Trash?", then its folder goes to the Trash.
    func deletionConfirmation(row: Int, query: String) -> PaletteDeletionConfirmation? {
        guard case .recording(let recording) = item(at: row, query: query), !recording.isMissing else { return nil }
        return Self.trashQuestion(for: recording) { [weak self] in self?.moveToTrash(recording) }
    }

    /// The question Delete asks about a recording, and what its Move to Trash does.
    static func trashQuestion(for recording: IndexedRecording, moveToTrash: @escaping @MainActor () -> Void) -> PaletteDeletionConfirmation {
        let videos = recording.videos.count > 1 ? "its \(recording.videos.count) videos" : "video"
        return PaletteDeletionConfirmation(
            title: "Move this recording to the Trash?",
            message: "Its folder and \(videos) go to the Trash. You can put them back from there.",
            delete: moveToTrash,
            confirmTitle: "Move to Trash"
        )
    }

    /// What the footer names on the highlighted screengrab: Copy ↵, Paste ⌘V, Edit ⌘E, and Delete ⌫
    /// on a screenshot; on a recording, Move to Trash ⌫ for Delete, and Copy 2 Videos for a recording
    /// of two screens; only Remove ⌫ on one moved or deleted. Space's Quick Look comes from
    /// `playback(row:query:)`, before Delete's. ⌘Return edits too, unlisted.
    func footerActions(row: Int, query: String) -> PaletteFooterActions {
        footerActions(of: item(at: row, query: query))
    }

    /// The footer's actions on `item`, or the tab's own while none is highlighted.
    func footerActions(of item: Screengrab?) -> PaletteFooterActions {
        switch item {
        case .recording(let recording) where recording.isMissing:
            PaletteFooterActions(primary: nil, secondary: [.remove])
        case .recording(let recording):
            PaletteFooterActions(primary: Self.copyTitle(for: recording), secondary: [.paste(), .edit, Self.moveToTrash])
        case .screenshot, nil:
            PaletteFooterActions(tab: tab)
        }
    }

    /// The screengrab at `row` as the detail beside the grid shows it (#552), or nil where there's
    /// none, as before Down or a click goes into the grid, when the palette highlights no row.
    func detail(row: Int, query: String) -> ScreengrabDetail? {
        item(at: row, query: query).map { detail(of: $0, query: query) }
    }

    /// `item` as the detail beside the grid shows it (#552). The grid hands over the item it drew,
    /// so a redraw works out the tab's contents once, and nothing here reads a file: what its files
    /// say comes later, off the main thread (`loadFileFacts(for:)`).
    ///
    /// Its buttons are the footer's actions, in its order, with its names and keys: Copy ↵ (⌘C
    /// too), Paste ⌘V, Edit ⌘E, and Quick Look Space; then Show in Finder, which no key does, where
    /// the context menu has it; then Delete ⌫, last, Move to Trash on a recording. One moved or
    /// deleted has only Remove. While the search field has text, Quick Look has no key, since Space
    /// types there; with text or a filter, Delete reads ⌘⌫, since ⌫ edits the search or removes the
    /// filter's chip there. Both as in the footer.
    func detail(of item: Screengrab, query: String) -> ScreengrabDetail {
        let footer = footerActions(of: item)
        var buttons: [ScreengrabDetail.ActionButton] = []
        if let copy = footer.primary {
            buttons.append(.init(action: .copy, title: copy, systemImage: "doc.on.doc", shortcuts: [["↵"], ["⌘", "C"]]))
        }
        if let paste = footer.secondary.first(where: \.isPaste) {
            buttons.append(.init(action: .paste, title: paste.title, systemImage: "doc.on.clipboard", shortcuts: [paste.keys]))
        }
        if let edit = footer.secondary.first(where: { $0 == .edit }) {
            buttons.append(.init(action: .edit, title: edit.title, systemImage: "pencil", shortcuts: [edit.keys]))
        }
        if let playback = playback(of: item), playback.listsInFooter {
            let space = PaletteKeyAction.space(playback.title)
            buttons.append(.init(action: .quickLook, title: space.title, systemImage: "eye", shortcuts: query.isEmpty ? [space.keys] : []))
        }
        // A screenshot's own file may have moved since it was saved: the detail leaves the button
        // out once its files say so (`ScreengrabDetail.buttons(files:)`), never looking here.
        if !item.isMissing, item.mayShowInFinder {
            buttons.append(.init(action: .showInFinder, title: "Show in Finder", systemImage: "folder", shortcuts: []))
        }
        if let delete = footer.secondary.last(where: \.isDelete) {
            let keys = query.isEmpty && filter() == nil ? delete.keys : delete.withCommand.keys
            buttons.append(.init(
                action: .delete, title: delete.title, systemImage: item.isMissing ? "minus.circle" : "trash", shortcuts: [keys], isDestructive: true
            ))
        }
        return ScreengrabDetail(item: item, buttons: buttons)
    }

    /// What `item`'s files said, if they've been read since the tab last showed: the detail starts
    /// with them, so one highlighted before fills in at once.
    func fileFacts(for item: Screengrab) -> ScreengrabFileFacts? {
        fileFacts[item.thumbnailKey]
    }

    /// What `item`'s files say (`ScreengrabFileFacts`), read off the main thread unless they've
    /// been read since the tab last showed.
    func loadFileFacts(for item: Screengrab) async -> ScreengrabFileFacts {
        if let known = fileFacts[item.thumbnailKey] { return known }
        let facts = await ScreengrabFileFacts.read(item)
        fileFacts[item.thumbnailKey] = facts
        return facts
    }

    /// Delete on a recording, which asks, then moves its folder to the Trash.
    static let moveToTrash = PaletteKeyAction.delete("Move to Trash")

    /// Return's name on a recording: Copy, or Copy 2 Videos for one of two screens.
    static func copyTitle(for recording: IndexedRecording) -> String {
        recording.sharingURLs.count > 1 ? "Copy \(recording.sharingURLs.count) Videos" : "Copy"
    }

    /// ⌘E edits the selected screengrab, as ⌘Return does: a screenshot in the Screenshot Editor, a
    /// recording in its window.
    var commandKeys: Set<String> { ["e"] }

    func handleCommandKey(_ characters: String, row: Int, query: String, palette: PaletteContentActions) {
        guard characters == "e", let item = item(at: row, query: query) else { return }
        choose(item, withCommand: true, palette: palette)
    }

    /// A ⌘-click edits, as ⌘Return and ⌘E do.
    var commandClicks: Bool { true }

    /// One of the detail's buttons, or a tile's context menu or trash button
    /// (`runOnTile(_:on:query:palette:)`), on the screengrab it shows: each does what its key does,
    /// and nothing of its own. Copy is Return's and ⌘C's, Paste ⌘V's, Edit ⌘E's, Quick Look Space's,
    /// and Delete the Delete key's, which asks first on a recording; Show in Finder has no key.
    /// Delete finds `item` by its id when it runs, never by a row worked out before, and does
    /// nothing once it's gone: a screenshot's Delete doesn't ask, so it must never land on another.
    func run(_ action: ScreengrabAction, on item: Screengrab, query: String, palette: PaletteContentActions) {
        switch action {
        case .copy: choose(item, withCommand: false, palette: palette)
        case .paste: paste(item, palette: palette)
        case .edit: choose(item, withCommand: true, palette: palette)
        case .quickLook: preview(item)
        case .showInFinder: reveal(item)
        case .delete:
            // The row it's at now, which the palette's Delete looks up again at once, on the main
            // thread, with the same search.
            guard let row = row(of: item, query: query) else { return }
            palette.deleteRow(row)
        }
    }

    /// A tile's context menu or trash button on the screengrab the tile shows: highlights it where
    /// it is now, then does what the detail's button does (`run(_:on:query:palette:)`). A menu
    /// stays open while a screenshot taken a moment before lands at the top and moves every tile
    /// on, so the row the tile had when the menu opened may be another's by then; the item is
    /// found by its id instead, and a menu on one that's gone since does nothing.
    func runOnTile(_ action: ScreengrabAction, on item: Screengrab, query: String, palette: PaletteContentActions) {
        guard let row = row(of: item, query: query) else { return }
        palette.selectRow(row)
        run(action, on: item, query: query, palette: palette)
    }

    /// Where `item` is in the tab now, found by its id: a screenshot's Clipboard History item, or a
    /// recording's. Nil once it's gone.
    func row(of item: Screengrab, query: String) -> Int? {
        content(query: query).items.firstIndex { $0.id == item.id }
    }

    /// Each time the tab shows, the index looks at each recording's folder again, so one moved or
    /// deleted since shows as such.
    func didShow(palette: PaletteContentActions) {
        self.palette = palette
        fileFacts = [:]
        guard listsRecordings, let recordings else { return }
        recordings.load()
        recordings.refresh()
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        palette = context.actions
        return AnyView(ScreengrabsResultsView(
            clipboard: clipboard,
            preferences: preferences,
            recordings: recordings,
            content: self,
            query: context.query,
            selection: context.selection,
            actions: context.actions,
            click: context.click,
            confirmationPresentationChanged: context.confirmationPresentationChanged
        ))
    }

    /// Return, ⌘C, and a double-click copy; ⌘Return, ⌘E, and a ⌘-click open a screenshot in the
    /// Screenshot Editor and a recording in its window. A moved or deleted recording says it
    /// couldn't open.
    func choose(_ item: Screengrab, withCommand: Bool, palette: PaletteContentActions) {
        switch item {
        case .screenshot(let entry):
            Self.choose(entry, withCommand: withCommand, palette: palette)
        case .recording(let recording):
            guard let files = sharingFiles(of: recording, palette: palette) else { return }
            if withCommand {
                palette.dismiss()
                if !openRecording(recording) { palette.warn(Self.openFailedMessage) }
            } else {
                palette.copyFiles(files)
            }
        }
    }

    /// Return and a double-click copy a screenshot; with Command held they open it in the Screenshot
    /// Editor.
    static func choose(_ entry: ClipboardEntry, withCommand: Bool, palette: PaletteContentActions) {
        switch ScreenshotPaletteAction(withCommand: withCommand) {
        case .copy: palette.copyClipboardEntry(entry)
        case .edit: palette.editClipboardImage(entry)
        }
    }

    /// Space, and the context menu's Quick Look: the palette closes first, so Quick Look has the
    /// keyboard.
    func preview(_ item: Screengrab) {
        let files: [URL]
        if let recording = item.recording {
            guard let shared = sharingFiles(of: recording, palette: palette) else { return }
            files = shared
        } else {
            files = item.previewFiles
        }
        guard !files.isEmpty else { return }
        palette?.dismiss()
        quickLook.preview(files)
    }

    /// The context menu's Show in Finder.
    func reveal(_ item: Screengrab) {
        let files = item.finderFiles
        guard !files.isEmpty else { return }
        palette?.dismiss()
        showInFinder(files)
    }

    /// Delete's Move to Trash: the recording's folder goes to the Trash, and it leaves the index.
    func moveToTrash(_ recording: IndexedRecording) {
        do {
            try trash.moveToTrash(folder: recording.folder, holding: recording.files)
        } catch {
            palette?.warn(Self.trashFailedMessage)
            return
        }
        recordings?.remove(folder: recording.folder)
    }

    /// The one check before Return, ⌘V, Space, ⌘E, and ⌘Return use a recording: it's taken as the
    /// recording window opens it (`IndexedRecording.savedCapture()`), and what's copied, pasted, or
    /// previewed is each display's mixdown, else its full video, as the window's Copy does. Nil when
    /// it can't open, and the notch says why: moved or deleted (its folder or a display's video,
    /// marked missing now if that happened since the tab showed), or else that it couldn't open.
    private func sharingFiles(of recording: IndexedRecording, palette: PaletteContentActions?) -> [URL]? {
        if !recording.isMissing, let capture = recording.savedCapture() { return capture.videos.map(\.forSharing) }
        recordings?.refresh()
        let missing = recording.isMissing || recordings?.recordings.first { $0.id == recording.id }?.isMissing == true
        palette?.warn(missing ? Self.missingMessage : Self.openFailedMessage)
        return nil
    }

    func item(at row: Int, query: String) -> Screengrab? {
        let items = content(query: query).items
        return items.indices.contains(row) ? items[row] : nil
    }

    /// Screenshots, while Clipboard History is on.
    var listsScreenshots: Bool { preferences.enabledCapabilities.contains(.clipboardHistory) }

    /// Recordings, where ScreenGrabs records and there's an index.
    var listsRecordings: Bool { recordings != nil && preferences.compatibility.supportsRecording }

    func content(query: String) -> ScreengrabsTabContent {
        ScreengrabsTabContent.resolve(
            screenshots: clipboard.entries,
            recordings: listsRecordings ? recordings?.recordings ?? [] : [],
            query: query,
            filter: filter(),
            isEnabled: preferences.enabledCapabilities.contains(.screenshotTools),
            listsScreenshots: listsScreenshots,
            listsRecordings: listsRecordings
        )
    }

    /// The empty tab's title, with the person's own screenshot and Record Screen shortcuts.
    func emptyTitle(query: String) -> String {
        ScreengrabsTabContent.emptyTitle(
            query: query,
            listsScreenshots: listsScreenshots,
            listsRecordings: preferences.compatibility.supportsRecording,
            screenshotKeys: preferences.capabilityShortcut(for: .screenshotAreaAndEdit)?.displayName,
            recordingKeys: preferences.capabilityShortcut(for: .screencast)?.displayName
        )
    }
}

private struct ScreengrabsResultsView: View {
    // Read so the view follows them: the content reads them in turn.
    @Bindable var clipboard: ClipboardHistoryService
    @Bindable var preferences: AppPreferences
    let recordings: RecordingLibrary?
    let content: ScreengrabsPaletteContent
    let query: String
    let selection: Int
    let actions: PaletteContentActions
    let click: (PaletteClick, Int) -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    var body: some View {
        switch content.content(query: query) {
        case .disabled:
            PaletteResultsContainer {
                PaletteEmptyState(title: "\(Capability.screenshotTools.title) is turned off", systemImage: "camera.viewfinder")
            }
        case .empty:
            PaletteResultsContainer {
                PaletteEmptyState(title: content.emptyTitle(query: query), systemImage: "camera.viewfinder")
            }
        case .items(let items):
            // The grid on the left and the highlighted screengrab in full on the right (#552), the
            // hint there until Down or a click goes into the grid. The detail is of the item the
            // grid draws, so the tab's contents are worked out once.
            let highlighted = items.indices.contains(selection) ? content.detail(of: items[selection], query: query) : nil
            PaletteListDetail(listWidth: ScreengrabGrid.width, highlighted: highlighted) {
                ScreengrabGrid(
                    items: items,
                    query: query,
                    selection: selection,
                    listsScreenshots: content.listsScreenshots,
                    listsRecordings: content.listsRecordings,
                    recordings: recordings,
                    content: content,
                    actions: actions,
                    click: click,
                    clear: clipboard.clearScreenshots,
                    confirmationPresentationChanged: confirmationPresentationChanged
                )
            } detail: { detail in
                ScreengrabDetailPane(
                    detail: detail,
                    recordings: recordings,
                    files: content.fileFacts(for: detail.item),
                    loadFiles: { await content.loadFileFacts(for: detail.item) }
                ) { action in
                    content.run(action, on: detail.item, query: query, palette: actions)
                }
                .id(detail.item.id)
            } placeholder: {
                ScreengrabDetailHint(text: ScreengrabDetail.hint(for: items))
            }
        }
    }
}

/// Raycast's Search Screenshots: a grid of large thumbnails with the name and age underneath, so
/// screengrabs are recognizable at a glance, in two columns beside the highlighted one in full
/// (#552). Arrow keys move through the grid.
private struct ScreengrabGrid: View {
    static let columnCount = 2
    /// About 46% of the palette's 1,040 points, so the detail beside it has the rest.
    static let width: CGFloat = 478

    let items: [Screengrab]
    /// The search the grid shows, which a tile's menu finds its screengrab in by its id.
    let query: String
    let selection: Int
    let listsScreenshots: Bool
    let listsRecordings: Bool
    let recordings: RecordingLibrary?
    let content: ScreengrabsPaletteContent
    let actions: PaletteContentActions
    /// A click on a tile, which highlights it; a double-click copies it (`PaletteClickAction.selects`).
    let click: (PaletteClick, Int) -> Void
    let clear: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    var body: some View {
        PaletteResultsContainer {
            VStack(spacing: 0) {
                PaletteListHeader(title: "Recent") {
                    if listsScreenshots {
                        ClearAllButton(
                            confirmationTitle: "Clear screenshots?",
                            confirmationMessage: listsRecordings
                                ? "This moves the screenshots in \(Capability.screenshotTools.title) to the Trash. Their copies where macOS saves screenshots stay, and recordings stay in \(Capability.screenshotTools.title)."
                                : "This moves the screenshots in \(Capability.screenshotTools.title) to the Trash. Their copies where macOS saves screenshots stay.",
                            disabled: !items.contains { $0.recording == nil },
                            confirmationPresentationChanged: confirmationPresentationChanged,
                            clear: clear
                        )
                        .buttonStyle(PalettePillButtonStyle())
                    } else {
                        // Recordings don't need Clipboard History; screenshots still do. The grid's
                        // column is too narrow for the whole sentence beside Open Settings, so it's
                        // shortened there.
                        HStack(spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                Text("Screenshots aren’t listed while Clipboard History is off")
                                Text("Screenshots need Clipboard History")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            Button("Open Settings") { actions.openSettings(.clipboard) }
                                .buttonStyle(PalettePillButtonStyle())
                                .help("Open Settings › Clipboard History")
                                .accessibilityIdentifier("palette.screengrabs.openClipboardSettings")
                        }
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: Self.columnCount),
                            spacing: 14
                        ) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ScreengrabCard(
                                    item: item,
                                    isSelected: index == selection,
                                    recordings: recordings,
                                    copyTitle: item.recording.map(ScreengrabsPaletteContent.copyTitle(for:)) ?? "Copy",
                                    clickAction: content.tab.clickAction,
                                    click: { click($0, index) },
                                    // By its id, not `index`, which may be another's by the time the
                                    // menu's chosen (`runOnTile`).
                                    run: { content.runOnTile($0, on: item, query: query, palette: actions) }
                                )
                                .paletteHoverHighlights(row: index)
                                .id(item.id)
                            }
                        }
                        // The first thumbnail sits where the list tabs' first well does (#381).
                        .padding(.horizontal, PaletteRowMetrics.wellX)
                        .padding(.vertical, PaletteRowMetrics.verticalInset)
                    }
                    .paletteScrollsToSelection(selection, proxy: proxy) { items.indices.contains($0) ? items[$0].id : nil }
                }
            }
        }
    }
}

/// What a tile's trash button and context menu, and the detail's buttons, do: each what its key
/// does (`ScreengrabsPaletteContent.run(_:on:query:palette:)`). Its raw value names the detail's button
/// (`palette.screengrabs.detail.<action>`).
enum ScreengrabAction: String, CaseIterable {
    case copy, paste, edit, quickLook, showInFinder, delete
}

/// A screengrab's tile: its picture fitted on the gray well (`ScreengrabPicture`), the name and age
/// under it, and "Moved or deleted" in its age's place for a recording moved or deleted.
private struct ScreengrabCard: View {
    let item: Screengrab
    let isSelected: Bool
    let recordings: RecordingLibrary?
    /// Return's name, for the context menu's Copy.
    let copyTitle: String
    let clickAction: PaletteClickAction
    let click: (PaletteClick) -> Void
    let run: (ScreengrabAction) -> Void
    @State private var isHovering = false
    @Environment(\.paletteHover) private var hover

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // Where the pointer doesn't move the highlight (#552), the tile under it that isn't
        // highlighted gets a ring of its own: thicker than the well's hairline, in the keycaps'
        // gray, never the highlight's accent.
        let marksHover = isHovering && !isSelected && !hover.highlights
        VStack(alignment: .leading, spacing: 6) {
            PaletteClickButton(clickAction: clickAction, click: click) {
                ScreengrabPicture(item: item, recordings: recordings, maxPixelSize: ScreengrabPicture.tilePixelSize)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(
                        isSelected ? Color.accentColor : marksHover ? PaletteTheme.keycapBorder : PaletteTheme.border,
                        lineWidth: isSelected ? 3 : marksHover ? 2 : 1
                    ))
                    .contentShape(shape)
            }
            .paletteLayoutProbe(.gridItem)
            .accessibilityLabel(item.thumbnailLabel)
            .accessibilityIdentifier(item.recording == nil ? "palette.screengrabs.screenshot" : "palette.screengrabs.recording")
            .overlay(alignment: .topTrailing) {
                if isHovering || isSelected {
                    Button(deleteTitle, systemImage: "trash", role: .destructive) { run(.delete) }
                        .buttonStyle(PalettePillButtonStyle(isCircular: true))
                        .padding(8)
                        .help("\(deleteTitle) (⌫)")
                        .accessibilityLabel("\(deleteTitle) \(item.recording == nil ? "screenshot" : "recording") \(item.name)")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isMissing {
                    Text("Moved or deleted")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                } else {
                    Text(item.date, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
        }
        .onHover { isHovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The stock context menu, with the footer's names and keys (#552): Copy ⌘C, Paste ⌘V, Edit ⌘E
    /// (a recording's opens the recording window, where it's edited), Quick Look, Show in Finder,
    /// then Delete ⌫, or Move to Trash… for a recording; only Remove for one moved or deleted.
    @ViewBuilder private var menu: some View {
        if item.isMissing {
            Button(PaletteKeyAction.remove.title) { run(.delete) }
                .paletteMenuKeys(PaletteKeyAction.remove.keys)
        } else {
            Button(copyTitle) { run(.copy) }
                .paletteMenuKeys(["⌘", "C"])
            Button("Paste") { run(.paste) }
                .paletteMenuKeys(PaletteKeyAction.paste().keys)
            Button(PaletteKeyAction.edit.title) { run(.edit) }
                .paletteMenuKeys(PaletteKeyAction.edit.keys)
            Button("Quick Look") { run(.quickLook) }
            if !item.finderFiles.isEmpty {
                Button("Show in Finder") { run(.showInFinder) }
            }
            Divider()
            Button(item.recording == nil ? "Delete" : "Move to Trash…", role: .destructive) { run(.delete) }
                .paletteMenuKeys(PaletteKeyAction.delete().keys)
        }
    }

    private var deleteTitle: String {
        switch item {
        case .screenshot: "Delete"
        case .recording(let recording): recording.isMissing ? "Remove" : "Move to Trash"
        }
    }
}

/// A screengrab's picture on the gray well, fitted: a screenshot, or a recording's poster frame with
/// a play badge, its length (Snapzy's badge), and, for a recording of more than one screen, how
/// many; one moved or deleted is dimmed, with a warning in the play badge's place. The tile draws
/// it, and the detail beside the grid draws it larger (#552). It fills what it's offered.
struct ScreengrabPicture: View {
    /// The longest side, in pixels, a tile's picture is loaded at.
    static let tilePixelSize = 640

    let item: Screengrab
    let recordings: RecordingLibrary?
    /// The longest side, in pixels, it's loaded at.
    let maxPixelSize: Int
    @State private var thumbnail: NSImage?
    /// The `Screengrab.thumbnailKey` `thumbnail` was loaded for.
    @State private var thumbnailKey: String?

    init(item: Screengrab, recordings: RecordingLibrary?, maxPixelSize: Int) {
        self.item = item
        self.recordings = recordings
        self.maxPixelSize = maxPixelSize
        // Loaded before, at this size or a tile's: it shows at once, so the detail of a tile just
        // highlighted, or a tile scrolled back to, doesn't flash the placeholder.
        let loaded = ScreengrabThumbnails.image(for: item.thumbnailKey, maxPixelSize: maxPixelSize)
        _thumbnail = State(initialValue: loaded ?? ScreengrabThumbnails.image(for: item.thumbnailKey, maxPixelSize: Self.tilePixelSize))
        _thumbnailKey = State(initialValue: loaded == nil ? nil : item.thumbnailKey)
    }

    var body: some View {
        ZStack {
            PaletteTheme.keycapFill
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: item.recording == nil ? "photo" : "film")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(item.isMissing ? 0.32 : 1)
            .grayscale(item.isMissing ? 1 : 0)
            if let recording = item.recording {
                ScreengrabPlayBadge(isMissing: recording.isMissing)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let recording = item.recording, !recording.isMissing {
                ScreengrabLengthBadge(text: IndexedRecording.lengthText(recording.duration))
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let recording = item.recording, !recording.isMissing, recording.videos.count > 1 {
                ScreengrabDisplaysBadge(count: recording.videos.count)
                    .padding(8)
            }
        }
        .task(id: item.thumbnailKey) {
            let key = item.thumbnailKey
            guard thumbnailKey != key else { return }
            // A new poster frame: the old one goes at once rather than showing while it's made.
            thumbnail = ScreengrabThumbnails.image(for: key, maxPixelSize: maxPixelSize)
                ?? ScreengrabThumbnails.image(for: key, maxPixelSize: Self.tilePixelSize)
            guard let url = await thumbnailURL() else { return }
            guard let image = await ClipboardEntryPreview.loadThumbnail(from: url, maxPixelSize: maxPixelSize),
                  !Task.isCancelled else { return }
            ScreengrabThumbnails.store(image, for: key, maxPixelSize: maxPixelSize)
            thumbnail = image
            thumbnailKey = key
        }
    }

    /// A screenshot's media copy; a recording's poster frame, made the first time, or for one moved
    /// or deleted, the one cached before.
    private func thumbnailURL() async -> URL? {
        switch item {
        case .screenshot(let entry): return entry.imageURL
        case .recording(let recording):
            guard let recordings else { return nil }
            return recording.isMissing ? recordings.cachedPosterFrame(for: recording) : await recordings.posterFrame(for: recording)
        }
    }
}

/// The pictures the ScreenGrabs tab loaded, by `Screengrab.thumbnailKey` and size, kept in memory
/// while there's room. A key stands for one file's pixels: a screenshot's media copy never changes,
/// and a recording's key changes with its poster frame, which an edit makes again, so nothing an
/// edit cropped, blurred, or trimmed away shows from here. `NSCache` is safe from any thread.
enum ScreengrabThumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    static func image(for key: String, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: "\(maxPixelSize)/\(key)" as NSString)
    }

    static func store(_ image: NSImage, for key: String, maxPixelSize: Int) {
        // Its pixels' bytes: an image made at its pixel size (`loadThumbnail`) is that many points.
        cache.setObject(image, forKey: "\(maxPixelSize)/\(key)" as NSString, cost: Int(image.size.width * image.size.height) * 4)
    }
}

/// A recording's play badge, centered on its thumbnail: white play on a translucent black circle;
/// a warning in its place for one moved or deleted. It only marks a video: a click highlights the
/// tile, and Space plays it in Quick Look.
private struct ScreengrabPlayBadge: View {
    let isMissing: Bool

    var body: some View {
        Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "play.fill")
            .font(.system(size: isMissing ? 16 : 15, weight: .semibold))
            .foregroundStyle(.white)
            .offset(x: isMissing ? 0 : 1.5)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A recording's length, in its thumbnail's bottom-right corner: Snapzy's duration badge
/// (`QuickAccessCardView.durationBadge`, BSD-3-Clause, see `LICENSE.snapzy`), white monospaced digits
/// on a 70% black capsule, at 11 points for a tile wider than Snapzy's card.
private struct ScreengrabLengthBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.7))
            )
            .accessibilityHidden(true)
    }
}

/// How many screens a recording of every screen holds, in its thumbnail's bottom-left corner, in
/// the length badge's capsule.
private struct ScreengrabDisplaysBadge: View {
    let count: Int

    var body: some View {
        Label("\(count) displays", systemImage: "display.2")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.7))
            )
            .accessibilityHidden(true)
    }
}
