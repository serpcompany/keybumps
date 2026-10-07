import SwiftUI

/// What the Snippets tab's rows and buttons do; the controller supplies each one.
struct SnippetPaletteActions {
    let copy: (Snippet) -> Void
    let paste: (Snippet) -> Void
    let edit: (Snippet) -> Void
    let create: () -> Void
    /// Opens Settings on the Snippets page, where an unreadable library can be tried again.
    let openSettings: () -> Void
    /// Asks before deleting: snippets are things you wrote, not history.
    let requestDelete: (Snippet) -> Void
    let delete: (Snippet) -> Void
}

/// The Snippets tab: a Snippets header with New Snippet, then one row per snippet in the Clipboard
/// tab's row layout. Return copies, ⌘Return pastes, ⌘E edits, and ⌘N makes a new one.
struct SnippetPaletteResults: View {
    @Environment(\.paletteRevealsSelection) private var revealsSelection
    static let symbol = "text.quote"

    let content: SnippetPaletteContent
    let selection: Int
    let actions: SnippetPaletteActions
    @Binding var pendingDeletion: Snippet?
    let confirmationPresentationChanged: (Bool) -> Void

    var body: some View {
        PaletteResultsContainer {
            switch content {
            case .disabled:
                PaletteEmptyState(title: "Snippets is turned off", systemImage: Self.symbol)
            case .unreadable:
                unreadableState
            case .empty:
                emptyState
            case .noMatches:
                VStack(spacing: 0) {
                    header
                    PaletteEmptyState(title: "No matching snippets", systemImage: Self.symbol)
                }
            case .entries(let snippets):
                VStack(spacing: 0) {
                    header
                    list(snippets)
                }
            }
        }
        .alert(
            "Delete this snippet?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    pendingDeletion = nil
                    confirmationPresentationChanged(false)
                }
            ),
            presenting: pendingDeletion
        ) { snippet in
            Button("Delete", role: .destructive) { actions.delete(snippet) }
            Button("Cancel", role: .cancel) {}
        } message: { snippet in
            Text("“\(snippet.name)” will be removed from this Mac.")
        }
    }

    private var header: some View {
        HStack {
            PaletteSectionHeader("Snippets")
            Spacer()
            Button("New Snippet", systemImage: "plus", action: actions.create)
                .buttonStyle(PalettePillButtonStyle(showsIcon: true))
                .help("New Snippet (⌘N)")
                .accessibilityIdentifier("palette.snippets.new")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No snippets yet", systemImage: Self.symbol)
        } description: {
            Text("Save text you reuse, then copy or paste it from here.")
        } actions: {
            VStack(spacing: 12) {
                Button("New Snippet", systemImage: "plus", action: actions.create)
                    .buttonStyle(PalettePillButtonStyle(size: .regular, showsIcon: true))
                    .accessibilityIdentifier("palette.snippets.new")
                HStack(spacing: 6) {
                    Text("or press")
                    PaletteKeycaps(shortcut: "⌘N")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The library couldn't be read: say so rather than looking empty, and point to Settings.
    private var unreadableState: some View {
        ContentUnavailableView {
            Label("Saved snippets can’t be read", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Keybumps won’t change them until it can read them. Settings › Snippets can try again.")
        } actions: {
            Button("Open Snippets Settings", systemImage: "gearshape", action: actions.openSettings)
                .buttonStyle(PalettePillButtonStyle(size: .regular, showsIcon: true))
                .accessibilityIdentifier("palette.snippets.openSettings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ snippets: [Snippet]) -> some View {
        ScrollViewReader { proxy in
            // No per-row buttons: Delete (or ⌘⌫ while typing) asks to delete the selected row, and
            // the context menu and VoiceOver actions cover mouse and VoiceOver users.
            List(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
                Button { actions.copy(snippet) } label: {
                    SnippetRow(snippet: snippet, isSelected: index == selection)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Copy") { actions.copy(snippet) }
                    Button("Paste") { actions.paste(snippet) }
                    Button("Edit…") { actions.edit(snippet) }
                    Divider()
                    Button("Delete…", role: .destructive) { actions.requestDelete(snippet) }
                }
                .accessibilityAction(named: "Paste") { actions.paste(snippet) }
                .accessibilityAction(named: "Edit") { actions.edit(snippet) }
                .accessibilityAction(named: "Delete") { actions.requestDelete(snippet) }
                .listRowInsets(.init())
                .listRowSeparator(.hidden)
                .paletteHoverHighlights(row: index)
                .paletteRowBackground(isSelected: index == selection)
                .id(snippet.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: selection) {
                if revealsSelection, snippets.indices.contains(selection) { proxy.scrollTo(snippets[selection].id) }
            }
        }
    }
}

/// A snippet in the Clipboard tab's row layout: the `text.quote` tile, the name with the text on one
/// gray line under it (masked for a sensitive snippet), and the keyword chip right-aligned. Only the
/// selected row shows Edit ⌘E, since the footer doesn't list it. Every row is the same height.
struct SnippetRow: View {
    let snippet: Snippet
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: SnippetPaletteResults.symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 38)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.tail)
                SnippetPreviewText(snippet: snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if isSelected {
                    HStack(spacing: 6) {
                        Text("Edit").fixedSize()
                        HStack(spacing: 3) {
                            PaletteKeycap("⌘")
                            PaletteKeycap("E")
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Edit with Command-E")
                }
                if let keyword = snippet.keyword {
                    SnippetKeywordChip(keyword: keyword)
                }
            }
            .frame(maxWidth: ClipboardRow.accessoryMaxWidth, alignment: .trailing)
            .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SnippetPresentation.accessibilityLabel(for: snippet))
    }
}

/// A snippet's text on one line, or a lock and the mask for a sensitive snippet.
struct SnippetPreviewText: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: 5) {
            if snippet.isSensitive {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(SnippetPresentation.preview(of: snippet))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// A keyword, such as `;ship`, as a code-style chip: monospaced gray text on a subtle rounded fill
/// with a hairline border, in the palette keycaps' family. Used wherever a keyword shows: palette
/// rows, the Settings list, and the editor.
struct SnippetKeywordChip: View {
    let keyword: String
    var fontSize: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(keyword)
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(minHeight: fontSize + 10)
            .background(PaletteTheme.keycapFill, in: shape)
            .overlay(shape.strokeBorder(PaletteTheme.keycapBorder, lineWidth: 1))
            .help("Keyword")
            .accessibilityLabel("Keyword \(keyword)")
    }
}
