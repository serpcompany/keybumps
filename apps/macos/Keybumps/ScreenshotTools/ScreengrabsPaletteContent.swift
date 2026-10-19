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

    /// What Space shows in Quick Look: a screenshot's file where it was saved, else Clipboard
    /// History's copy of it; a recording's video for each display, as Copy copies them.
    var previewFiles: [URL] {
        switch self {
        case .screenshot(let entry): [entry.existingSourceURL ?? entry.imageURL].compactMap { $0 }
        case .recording(let recording): recording.sharingURLs
        }
    }

    /// What Show in Finder selects: a screenshot's file where it was saved, if it's still there;
    /// a recording's videos.
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
    /// The screenshot's own file, while it's still where it was saved.
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
/// - A click highlights a screengrab, going into the grid as Down does, and the footer names its
///   actions (`PaletteClickAction.selects`, #552).
/// - **Return** or a double-click copies: a screenshot as Clipboard History restores it, a recording
///   as its files, every display's, as the recording window's Copy does, kept out of Clipboard
///   History. **⌘V** pastes it.
/// - **⌘E** (Edit), **⌘Return**, or a ⌘-click opens a screenshot in the Screenshot Editor and a
///   recording in the recording window, where it's trimmed, cropped, and blurred, with Move to Trash
///   and Done (`ScreencastReviewMode.saved`).
/// - **Space** opens it in Quick Look (`ScreengrabsQuickLooking`).
/// - **Delete** removes a screenshot from the tab and leaves its file. On a recording it asks, then
///   moves its folder to the Trash (`RecordingTrash`). Clear All clears screenshots only.
/// - The footer and the context menu name these keys in that order, Delete's last (#552).
/// - A recording moved or deleted outside Keybumps, its folder or a display's video, stays, dimmed,
///   marked "Moved or deleted" (`IndexedRecording.isMissing`, looked at again each time the tab
///   shows): its keys say it couldn't open, as the recording window can't, and Delete removes it
///   from the tab at once, with no question.
/// - The context menu has Show in Finder too.
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

    static let missingMessage = "Couldn’t open the recording: it was moved or deleted."
    static let trashFailedMessage = ScreencastReviewFailure.trashFailed.message
    static let openFailedMessage = "Couldn’t open the recording."

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

    /// Up and Down move a row and Left and Right one screengrab. Each stays put where there's
    /// nothing to move to, so Down above a shorter last row stays put, and Up from the top row
    /// leaves the grid.
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
        guard let item = item(at: row, query: query) else { return nil }
        if item.isMissing {
            return PalettePlayback(title: "Quick Look", toggle: { [weak self] in self?.palette?.warn(Self.missingMessage) }, listsInFooter: false)
        }
        let files = item.previewFiles
        guard !files.isEmpty else { return nil }
        return PalettePlayback(title: "Quick Look") { [weak self] in self?.preview(item) }
    }

    /// A screenshot leaves the tab, and its file stays where it was saved. A moved or deleted
    /// recording leaves the index at once. Any other recording asks first
    /// (`deletionConfirmation(row:query:)`), so it's never deleted here.
    func delete(row: Int, query: String) -> Bool {
        switch item(at: row, query: query) {
        case .screenshot(let entry):
            clipboard.delete(entry)
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
        switch item(at: row, query: query) {
        case .recording(let recording) where recording.isMissing:
            PaletteFooterActions(primary: nil, secondary: [.remove])
        case .recording(let recording):
            PaletteFooterActions(primary: Self.copyTitle(for: recording), secondary: [.paste(), .edit, Self.moveToTrash])
        case .screenshot, nil:
            PaletteFooterActions(tab: tab)
        }
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

    /// Each time the tab shows, the index looks at each recording's folder again, so one moved or
    /// deleted since shows as such.
    func didShow(palette: PaletteContentActions) {
        self.palette = palette
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
        let files = recording.videos.flatMap { video in
            [recording.folder.appendingPathComponent(video.file)] + [video.mixdown].compactMap { $0.map(recording.folder.appendingPathComponent) }
        }
        do {
            try trash.moveToTrash(folder: recording.folder, holding: files)
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
            ScreengrabGrid(
                items: items,
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
        }
    }
}

/// Raycast's Search Screenshots: a grid of large thumbnails with the name and age underneath, so
/// screengrabs are recognizable at a glance. Arrow keys move through the grid.
private struct ScreengrabGrid: View {
    static let columnCount = 3

    let items: [Screengrab]
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
                                ? "This removes screenshots from Keybumps history. Their files stay where they were saved, and recordings stay in \(Capability.screenshotTools.title)."
                                : "This removes screenshots from Keybumps history. Their files stay where they were saved.",
                            disabled: !items.contains { $0.recording == nil },
                            confirmationPresentationChanged: confirmationPresentationChanged,
                            clear: clear
                        )
                        .buttonStyle(PalettePillButtonStyle())
                    } else {
                        // Recordings don't need Clipboard History; screenshots still do.
                        HStack(spacing: 12) {
                            Text("Screenshots aren’t listed while Clipboard History is off")
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
                                    run: { action in
                                        actions.selectRow(index)
                                        switch action {
                                        case .copy: content.choose(item, withCommand: false, palette: actions)
                                        case .paste: content.paste(item, palette: actions)
                                        case .edit: content.choose(item, withCommand: true, palette: actions)
                                        case .quickLook: content.preview(item)
                                        case .showInFinder: content.reveal(item)
                                        case .delete: actions.deleteRow(index)
                                        }
                                    }
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

/// What a tile's trash button and context menu do.
private enum ScreengrabCardAction {
    case copy, paste, edit, quickLook, showInFinder, delete
}

/// A screengrab's tile: its thumbnail fitted on the gray well, the name and age under it. A
/// recording's has its poster frame, a play badge, and its length (Snapzy's badge), and a recording
/// of more than one screen says how many; one moved or deleted is dimmed, with a warning in the
/// play badge's place and "Moved or deleted" in its age's.
private struct ScreengrabCard: View {
    let item: Screengrab
    let isSelected: Bool
    let recordings: RecordingLibrary?
    /// Return's name, for the context menu's Copy.
    let copyTitle: String
    let clickAction: PaletteClickAction
    let click: (PaletteClick) -> Void
    let run: (ScreengrabCardAction) -> Void
    @State private var thumbnail: NSImage?
    /// The `Screengrab.thumbnailKey` `thumbnail` was loaded for.
    @State private var thumbnailKey: String?
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            PaletteClickButton(clickAction: clickAction, click: click) {
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
                .aspectRatio(16 / 10, contentMode: .fit)
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
                .clipShape(shape)
                .overlay(shape.strokeBorder(isSelected ? Color.accentColor : PaletteTheme.border, lineWidth: isSelected ? 3 : 1))
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
        .task(id: item.thumbnailKey) {
            let key = item.thumbnailKey
            // A new poster frame: the old one goes at once rather than showing while it's made.
            if thumbnailKey != key { thumbnail = nil }
            guard let url = await thumbnailURL() else { return }
            let image = await ClipboardEntryPreview.loadThumbnail(from: url, maxPixelSize: 640)
            guard !Task.isCancelled else { return }
            thumbnail = image
            thumbnailKey = key
        }
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
