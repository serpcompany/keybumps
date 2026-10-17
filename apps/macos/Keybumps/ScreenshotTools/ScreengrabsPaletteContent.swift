import AppKit
import SwiftUI

/// What the ScreenGrabs tab shows: only screen captures from Clipboard History.
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

/// What choosing a screenshot does. Return or a click copies it, as in the Clipboard tab.
/// Command-Return or Command-click opens it in the Screenshot Editor.
enum ScreenshotPaletteAction: Equatable {
    case copy
    case edit

    init(withCommand: Bool) {
        self = withCommand ? .edit : .copy
    }
}


/// The ScreenGrabs tab's rows (⌘3), supplied by `ScreenshotToolsModule`: the screenshots in
/// Clipboard History (`ScreenshotPaletteContent`), as a grid. Return or a click copies one, ⌘P
/// pastes it, and ⌘Return, ⌘E, or ⌘-click opens it in the Screenshot Editor. Delete removes it from
/// the tab and leaves its file; Clear All removes them all.
@MainActor
final class ScreengrabsPaletteContent: CapabilityPaletteContent {
    let tab = CommandPaletteTab.screenshots
    private let clipboard: ClipboardHistoryService
    private let preferences: AppPreferences
    /// The filter chosen from `/`'s list (`PaletteFilter.available(in:)`), which the palette keeps.
    private let filter: () -> PaletteFilter?

    init(clipboard: ClipboardHistoryService, preferences: AppPreferences, filter: @escaping () -> PaletteFilter?) {
        self.clipboard = clipboard
        self.preferences = preferences
        self.filter = filter
    }

    /// A grid with or without a search.
    func isGrid(query: String) -> Bool { true }

    /// Up and Down move a row and Left and Right one screenshot. Each stays put where there's
    /// nothing to move to, so Down above a shorter last row stays put, and Up from the top row
    /// leaves the grid.
    func selection(after move: PaletteMove, from row: Int, query: String) -> Int? {
        let target = switch move {
        case .up: row - ScreenshotGrid.columnCount
        case .down: row + ScreenshotGrid.columnCount
        case .left: row - 1
        case .right: row + 1
        }
        return (0..<rowCount(query: query)).contains(target) ? target : nil
    }

    func rowCount(query: String) -> Int {
        content(query: query).entries.count
    }

    func activate(row: Int, query: String, palette: PaletteContentActions) {
        guard let entry = entry(at: row, query: query) else { return }
        Self.choose(entry, withCommand: false, palette: palette)
    }

    func commandActivate(row: Int, query: String, palette: PaletteContentActions) {
        guard let entry = entry(at: row, query: query) else { return }
        Self.choose(entry, withCommand: true, palette: palette)
    }

    func copy(row: Int, query: String, palette: PaletteContentActions) {
        guard let entry = entry(at: row, query: query) else { return }
        palette.copyClipboardEntry(entry)
    }

    func paste(row: Int, query: String, palette: PaletteContentActions) {
        guard let entry = entry(at: row, query: query) else { return }
        palette.pasteClipboardEntry(entry)
    }

    /// Removes the screenshot from the tab; its file stays where macOS saved it.
    func delete(row: Int, query: String) -> Bool {
        guard let entry = entry(at: row, query: query) else { return false }
        clipboard.delete(entry)
        return true
    }

    /// ⌘E edits the selected screenshot, as ⌘Return does.
    var commandKeys: Set<String> { ["e"] }

    func handleCommandKey(_ characters: String, row: Int, query: String, palette: PaletteContentActions) {
        guard characters == "e", let entry = entry(at: row, query: query) else { return }
        palette.editClipboardImage(entry)
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        let actions = context.actions
        return AnyView(ScreengrabsResultsView(
            clipboard: clipboard,
            preferences: preferences,
            filter: filter(),
            query: context.query,
            selection: context.selection,
            select: actions.selectRow,
            choose: { entry in Self.choose(entry, withCommand: NSEvent.modifierFlags.contains(.command), palette: actions) },
            confirmationPresentationChanged: context.confirmationPresentationChanged
        ))
    }

    /// Return and a click copy a screenshot; with Command held they open it in the Screenshot Editor.
    static func choose(_ entry: ClipboardEntry, withCommand: Bool, palette: PaletteContentActions) {
        switch ScreenshotPaletteAction(withCommand: withCommand) {
        case .copy: palette.copyClipboardEntry(entry)
        case .edit: palette.editClipboardImage(entry)
        }
    }

    private func entry(at row: Int, query: String) -> ClipboardEntry? {
        let entries = content(query: query).entries
        return entries.indices.contains(row) ? entries[row] : nil
    }

    private func content(query: String) -> ScreenshotPaletteContent {
        ScreengrabsResultsView.content(clipboard: clipboard, preferences: preferences, filter: filter(), query: query)
    }
}

private struct ScreengrabsResultsView: View {
    @Bindable var clipboard: ClipboardHistoryService
    @Bindable var preferences: AppPreferences
    let filter: PaletteFilter?
    let query: String
    let selection: Int
    let select: (Int) -> Void
    let choose: (ClipboardEntry) -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    /// The screenshots narrowed by the filter, then by the search.
    static func content(
        clipboard: ClipboardHistoryService,
        preferences: AppPreferences,
        filter: PaletteFilter?,
        query: String
    ) -> ScreenshotPaletteContent {
        ScreenshotPaletteContent.resolve(
            entries: filter.apply(clipboard.entries) { $0.matches($1) },
            query: query,
            isEnabled: preferences.enabledCapabilities.contains(.screenshotTools)
        )
    }

    var body: some View {
        switch Self.content(clipboard: clipboard, preferences: preferences, filter: filter, query: query) {
        case .disabled:
            PaletteResultsContainer {
                PaletteEmptyState(title: "\(Capability.screenshotTools.title) is turned off", systemImage: "camera.viewfinder")
            }
        case .empty:
            PaletteResultsContainer {
                PaletteEmptyState(
                    title: query.isEmpty ? "Take a screenshot with ⇧⌘4 and it appears here" : "No matching screenshots",
                    systemImage: "camera.viewfinder"
                )
            }
        case .entries(let entries):
            ScreenshotGrid(
                entries: entries,
                selection: selection,
                select: select,
                choose: choose,
                delete: clipboard.delete,
                clear: clipboard.clearScreenshots,
                confirmationPresentationChanged: confirmationPresentationChanged
            )
        }
    }
}

/// Raycast's Search Screenshots: a grid of large thumbnails with the name and age underneath,
/// so screenshots are recognizable at a glance. Arrow keys move through the grid.
private struct ScreenshotGrid: View {
    static let columnCount = 3

    let entries: [ClipboardEntry]
    let selection: Int
    let select: (Int) -> Void
    let choose: (ClipboardEntry) -> Void
    let delete: (ClipboardEntry) -> Void
    let clear: () -> Void
    let confirmationPresentationChanged: (Bool) -> Void

    var body: some View {
        PaletteResultsContainer {
            VStack(spacing: 0) {
                PaletteListHeader(title: "Recent") {
                    ClearAllButton(
                        confirmationTitle: "Clear screenshots?",
                        confirmationMessage: "This removes screenshots from Keybumps history. The screenshot files stay where macOS saved them.",
                        disabled: entries.isEmpty,
                        confirmationPresentationChanged: confirmationPresentationChanged,
                        clear: clear
                    )
                    .buttonStyle(PalettePillButtonStyle())
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: Self.columnCount),
                            spacing: 14
                        ) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                ScreenshotCard(
                                    entry: entry,
                                    isSelected: index == selection,
                                    choose: { select(index); choose(entry) },
                                    delete: { delete(entry) }
                                )
                                .paletteHoverHighlights(row: index)
                                .id(entry.id)
                            }
                        }
                        // The first thumbnail sits where the list tabs' first well does (#381).
                        .padding(.horizontal, PaletteRowMetrics.wellX)
                        .padding(.vertical, PaletteRowMetrics.verticalInset)
                    }
                    .paletteScrollsToSelection(selection, proxy: proxy) { entries.indices.contains($0) ? entries[$0].id : nil }
                }
            }
        }
    }
}

private struct ScreenshotCard: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let choose: () -> Void
    let delete: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Button(action: choose) {
                ZStack {
                    PaletteTheme.keycapFill
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(isSelected ? Color.accentColor : PaletteTheme.border, lineWidth: isSelected ? 3 : 1))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .paletteLayoutProbe(.gridItem)
            .overlay(alignment: .topTrailing) {
                if isHovering || isSelected {
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                        .buttonStyle(PalettePillButtonStyle(isCircular: true))
                        .padding(8)
                        .help("Delete (⌫)")
                        .accessibilityLabel("Delete screenshot \(entry.displayText)")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.capturedAt, style: .relative)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: entry.mediaPath) {
            guard let imageURL = entry.imageURL else { return }
            thumbnail = await ClipboardEntryPreview.loadThumbnail(from: imageURL, maxPixelSize: 640)
        }
    }
}

