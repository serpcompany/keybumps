import AppKit
import SwiftUI

/// The highlighted screengrab as the detail beside the ScreenGrabs grid shows it (#552), as the
/// Dictation and Translate tabs show their highlighted row: its picture, a button for each of its
/// actions with the keys that do the same, its name, and its information
/// (`ScreengrabsPaletteContent.detail(of:query:)`). Nothing in it is user content the tile doesn't
/// already show: its name, and what Clipboard History, the recordings index, and its files keep.
/// Making it reads no file; what its files say comes after, off the main thread
/// (`ScreengrabFileFacts`), and fills in its Information.
struct ScreengrabDetail: Equatable {
    /// One of its buttons: its name and keys as the footer names them, and what it does, which is
    /// what those keys do (`ScreengrabsPaletteContent.run(_:on:query:palette:)`).
    struct ActionButton: Equatable {
        let action: ScreengrabAction
        let title: String
        let systemImage: String
        /// Each shortcut that does the same, as `PaletteActionButton` shows them: `[["↵"], ["⌘", "C"]]`.
        let shortcuts: [[String]]
        /// Delete's, red while the pointer is on it, as every destructive button in the palette.
        var isDestructive = false

        /// `palette.screengrabs.detail.copy`
        var identifier: String { "palette.screengrabs.detail.\(action.rawValue)" }
    }

    /// A row of its Information: "Dimensions" and "1440 × 900".
    struct Fact: Equatable {
        let title: String
        let value: String
    }

    let item: Screengrab
    /// Every button it can have, Show in Finder included wherever the screengrab may have a file to
    /// show; `buttons(files:)` leaves that out once its files say a screenshot's own has moved.
    let buttons: [ActionButton]

    /// "Moved or deleted", under the name of a recording moved or deleted outside Keybumps, as on
    /// its tile.
    var warning: String? { item.isMissing ? "Moved or deleted" : nil }

    /// Its buttons, with what its files say, nil until they've been read: Show in Finder goes once
    /// a screenshot's own file is known to be gone from where it was saved, as on its tile's menu.
    func buttons(files: ScreengrabFileFacts?) -> [ActionButton] {
        guard files?.savedFileExists == false else { return buttons }
        return buttons.filter { $0.action != .showInFinder }
    }

    /// Its Information, with what its files say (nil until they've been read): a screenshot's
    /// Dimensions, Taken, and Size, and its Source app where Clipboard History recorded one; a
    /// recording's Length, Displays, Taken, and Size. One moved or deleted keeps what the index
    /// knows, with no Size. Until its files are read, Dimensions and Size are there with no value,
    /// so nothing moves as they fill in; a value its files can't give, such as the size of a file
    /// that's gone, is then left out.
    func information(files: ScreengrabFileFacts?) -> [Fact] {
        let taken = Fact(title: "Taken", value: item.date.formatted(date: .abbreviated, time: .shortened))
        // A row its files give: blank until they've been read, and gone if they can't say.
        func fromFiles(_ title: String, _ value: (ScreengrabFileFacts) -> String?) -> Fact? {
            guard let files else { return Fact(title: title, value: "") }
            return value(files).map { Fact(title: title, value: $0) }
        }
        switch item {
        case .screenshot(let entry):
            return [
                fromFiles("Dimensions", \.dimensions),
                taken,
                fromFiles("Size", \.size),
                entry.sourceApp.map { Fact(title: "Source app", value: $0.name) },
            ].compactMap { $0 }
        case .recording(let recording):
            return [
                Fact(title: "Length", value: IndexedRecording.lengthText(recording.duration)),
                Fact(title: "Displays", value: "\(recording.videos.count)"),
                taken,
                recording.isMissing ? nil : fromFiles("Size", \.size),
            ].compactMap { $0 }
        }
    }

    /// What the detail says before Down or a click goes into the grid, naming what the grid holds:
    /// "Press ↓ or click a screenshot or recording to see it here".
    static func hint(for items: [Screengrab]) -> String {
        let shots = items.contains { $0.recording == nil }
        let videos = items.contains { $0.recording != nil }
        let kinds = shots && videos ? "a screenshot or recording" : videos ? "a recording" : "a screenshot"
        return "Press ↓ or click \(kinds) to see it here"
    }
}

/// What a screengrab's files say for the detail's Information and its Show in Finder (#552): a
/// screenshot's Dimensions, read from the file its item keeps (`imageURL`: since #605 its file in
/// ScreenGrabs' history, which is always on this Mac), and whether its own file (`sourceURL`, the
/// same one since #605) is still there; a screenshot's or a recording's Size. They're read off the main thread (`read(_:)`), since a file on a Desktop synced with iCloud
/// may have to download before its header can be read, once for each screengrab highlighted after
/// the tab shows (`ScreengrabsPaletteContent.loadFileFacts(for:)`), so neither a hover nor a key
/// waits on a file.
struct ScreengrabFileFacts: Equatable, Sendable {
    /// "1440 × 900": a screenshot's. Nil for a recording, or where no file can say.
    var dimensions: String?
    /// The files' size together, as Finder gives it: "1.2 MB". Nil where none can be read.
    var size: String?
    /// Whether a screenshot's own file is still where it was saved; nil for a recording, or a
    /// screenshot that was never saved to a file. A recording's index says whether it's moved
    /// (`IndexedRecording.isMissing`).
    var savedFileExists: Bool?

    /// Reads them, off the main thread.
    static func read(_ item: Screengrab) async -> ScreengrabFileFacts {
        switch item {
        case .screenshot(let entry):
            let copy = entry.imageURL, saved = entry.sourceURL
            return await Task.detached(priority: .utility) { Self.screenshot(copy: copy, saved: saved) }.value
        case .recording(let recording):
            let files = recording.isMissing ? [] : recording.files
            return await Task.detached(priority: .utility) { ScreengrabFileFacts(size: Self.size(of: files)) }.value
        }
    }

    /// A screenshot's, from its files: Dimensions from the file its item keeps, else its own file;
    /// Size of its own file while it's there, else of the kept one, as Quick Look shows one or the
    /// other (`Screengrab.previewFiles`). Since #605 they're one file, in ScreenGrabs' history.
    static func screenshot(copy: URL?, saved: URL?) -> ScreengrabFileFacts {
        let exists = saved.map { FileManager.default.fileExists(atPath: $0.path) }
        let own = exists == true ? saved : nil
        return ScreengrabFileFacts(
            dimensions: copy.flatMap(ClipboardRowPresentation.pixelSize(ofImageAt:)) ?? own.flatMap(ClipboardRowPresentation.pixelSize(ofImageAt:)),
            size: size(of: [own ?? copy].compactMap { $0 }),
            savedFileExists: exists
        )
    }

    /// The files' size together, as Finder gives it: "1.2 MB". Nil when none can be read.
    static func size(of files: [URL]) -> String? {
        let sizes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        guard !sizes.isEmpty else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(sizes.reduce(0, +)), countStyle: .file)
    }
}

/// The detail beside the ScreenGrabs grid (#552), in the Dictation and Translate tabs' layout: the
/// highlighted screengrab's picture, large and fitted, as its tile draws it (`ScreengrabPicture`);
/// its buttons, each with the keys that do the same (`PaletteActionButton`), going on to a second
/// line where one is too narrow, with Delete's at the end (`PaletteActionFlow`); its name, with
/// "Moved or deleted" under it for a recording moved or deleted outside Keybumps; then its
/// Information. It shows at once, and its Information's Dimensions and Size fill in once its files
/// are read, off the main thread. It scrolls where it's taller than the palette. VoiceOver reads it
/// in that order.
struct ScreengrabDetailPane: View {
    /// The picture's height: large, while the buttons and most of the Information stay in view
    /// above the footer.
    static let pictureHeight: CGFloat = 228
    /// The longest side, in pixels, the picture is loaded at: about the pane's width at 2x.
    static let picturePixelSize = 1200

    let detail: ScreengrabDetail
    let recordings: RecordingLibrary?
    /// Reads what the screengrab's files say, off the main thread, unless they've been read since
    /// the tab showed (`ScreengrabsPaletteContent.loadFileFacts(for:)`).
    let loadFiles: () async -> ScreengrabFileFacts
    /// Does a button's action, as its keys do (`ScreengrabsPaletteContent.run(_:on:query:palette:)`).
    let run: (ScreengrabAction) -> Void
    /// What its files said, nil until they've been read.
    @State private var files: ScreengrabFileFacts?

    /// - Parameter files: What its files said, if they've been read since the tab showed, so a
    ///   screengrab highlighted before shows them at once.
    init(
        detail: ScreengrabDetail,
        recordings: RecordingLibrary?,
        files: ScreengrabFileFacts?,
        loadFiles: @escaping () async -> ScreengrabFileFacts,
        run: @escaping (ScreengrabAction) -> Void
    ) {
        self.detail = detail
        self.recordings = recordings
        self.loadFiles = loadFiles
        self.run = run
        _files = State(initialValue: files)
    }

    var body: some View {
        let information = detail.information(files: files)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                picture
                PaletteActionFlow {
                    ForEach(detail.buttons(files: files), id: \.action) { button in
                        PaletteActionButton(
                            title: button.title,
                            systemImage: button.systemImage,
                            shortcuts: button.shortcuts,
                            role: button.isDestructive ? .destructive : nil
                        ) { run(button.action) }
                        .accessibilityIdentifier(button.identifier)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.item.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("palette.screengrabs.detail.name")
                    if let warning = detail.warning {
                        Text(warning)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("palette.screengrabs.detail.missing")
                    }
                }
                if !information.isEmpty {
                    PaletteInformation {
                        ForEach(information, id: \.title) { fact in
                            PaletteInformationRow(fact.title, fact.value)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("palette.screengrabs.detail.information")
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette.screengrabs.detail")
        // Again where its files change, as an edit makes a recording's poster frame again.
        .task(id: detail.item.thumbnailKey) {
            let read = await loadFiles()
            guard !Task.isCancelled else { return }
            files = read
        }
    }

    /// The tile's picture, larger: a screenshot, or a recording's poster frame with its badges,
    /// dimmed for one moved or deleted. VoiceOver reads it as the tile's: "Recording, 42 seconds".
    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ScreengrabPicture(item: detail.item, recordings: recordings, maxPixelSize: Self.picturePixelSize)
            .frame(maxWidth: .infinity)
            .frame(height: Self.pictureHeight)
            .clipShape(shape)
            .overlay(shape.strokeBorder(PaletteTheme.border, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail.item.thumbnailLabel)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("palette.screengrabs.detail.preview")
    }
}

/// The detail's quiet hint before Down or a click goes into the grid
/// (`ScreengrabDetail.hint(for:)`), centered in gray.
struct ScreengrabDetailHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("palette.screengrabs.detail.empty")
    }
}
