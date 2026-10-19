import AppKit
import SwiftUI

/// The highlighted screengrab as the detail beside the ScreenGrabs grid shows it (#552), as the
/// Dictation and Translate tabs show their highlighted row: its picture, a button for each of its
/// actions with the keys that do the same, its name, and its information
/// (`ScreengrabsPaletteContent.detail(row:query:)`). Nothing in it is user content the tile doesn't
/// already show: its name, and what Clipboard History, the recordings index, and its files keep.
struct ScreengrabDetail: Equatable {
    /// One of its buttons: its name and keys as the footer names them, and what it does, which is
    /// what those keys do (`ScreengrabsPaletteContent.run(_:on:at:palette:)`).
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
    let buttons: [ActionButton]
    let information: [Fact]

    /// "Moved or deleted", under the name of a recording moved or deleted outside Keybumps, as on
    /// its tile.
    var warning: String? { item.isMissing ? "Moved or deleted" : nil }

    /// Its Information: a screenshot's Dimensions, Taken, and Size, and its Source app where
    /// Clipboard History recorded one; a recording's Length, Displays, Taken, and Size. One moved or
    /// deleted keeps what the index knows, with no Size. A value its files can't give, such as the
    /// size of a file that's gone, is left out.
    static func information(of item: Screengrab) -> [Fact] {
        let taken = Fact(title: "Taken", value: item.date.formatted(date: .abbreviated, time: .shortened))
        switch item {
        case .screenshot(let entry):
            // Its file where it was saved, else Clipboard History's copy, as Quick Look shows it.
            let files = item.previewFiles
            return [
                files.first.flatMap(ClipboardRowPresentation.pixelSize(ofImageAt:)).map { Fact(title: "Dimensions", value: $0) },
                taken,
                size(of: files).map { Fact(title: "Size", value: $0) },
                entry.sourceApp.map { Fact(title: "Source app", value: $0.name) },
            ].compactMap { $0 }
        case .recording(let recording):
            return [
                Fact(title: "Length", value: IndexedRecording.lengthText(recording.duration)),
                Fact(title: "Displays", value: "\(recording.videos.count)"),
                taken,
                recording.isMissing ? nil : size(of: recording.files).map { Fact(title: "Size", value: $0) },
            ].compactMap { $0 }
        }
    }

    /// The files' size together, as Finder gives it: "1.2 MB". Nil when none can be read.
    static func size(of files: [URL]) -> String? {
        let sizes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        guard !sizes.isEmpty else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(sizes.reduce(0, +)), countStyle: .file)
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

/// The detail beside the ScreenGrabs grid (#552), in the Dictation and Translate tabs' layout: the
/// highlighted screengrab's picture, large and fitted, as its tile draws it (`ScreengrabPicture`);
/// its buttons, each with the keys that do the same (`PaletteActionButton`), going on to a second
/// line where one is too narrow, with Delete's at the end (`PaletteActionFlow`); its name, with
/// "Moved or deleted" under it for a recording moved or deleted outside Keybumps; then its
/// Information. It scrolls where it's taller than the palette. VoiceOver reads it in that order.
struct ScreengrabDetailPane: View {
    /// The picture's height: large, while the buttons and most of the Information stay in view
    /// above the footer.
    static let pictureHeight: CGFloat = 228
    /// The longest side, in pixels, the picture is loaded at: about the pane's width at 2x.
    static let picturePixelSize = 1200

    let detail: ScreengrabDetail
    let recordings: RecordingLibrary?
    /// Does a button's action, as its keys do (`ScreengrabsPaletteContent.run(_:on:at:palette:)`).
    let run: (ScreengrabAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                picture
                PaletteActionFlow {
                    ForEach(detail.buttons, id: \.action) { button in
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
                if !detail.information.isEmpty {
                    PaletteInformation {
                        ForEach(detail.information, id: \.title) { fact in
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
