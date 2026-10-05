import SwiftUI

/// The Emoji tab (#243). With the search empty it's a grid to browse: Recent, then Unicode's groups.
/// Typing turns it into a ranked list, as the Search tab is. Return copies the emoji and ⌘Return
/// pastes it into the app you were using, putting your clipboard back afterwards. The emoji takes
/// the skin tone set in Settings when it has one.
@MainActor
@Observable
final class EmojiPaletteContent: CapabilityPaletteContent {
    static let columns = 12

    let tab = CommandPaletteTab.emoji
    let resetsSelectionWhileTyping = true

    /// A section of the browsing grid.
    struct Section: Equatable {
        let title: String
        let emoji: [Emoji]
    }

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored let recents: EmojiRecents
    @ObservationIgnored private let loadLibrary: () -> EmojiLibrary?
    @ObservationIgnored private var cachedLibrary: EmojiLibrary??

    /// `loadLibrary` runs once, the first time the tab needs its emoji.
    init(preferences: AppPreferences, recents: EmojiRecents, loadLibrary: @escaping () -> EmojiLibrary? = EmojiPaletteContent.bundledLibrary) {
        self.preferences = preferences
        self.recents = recents
        self.loadLibrary = loadLibrary
    }

    /// The bundled catalog, without what this Mac can't draw.
    static func bundledLibrary() -> EmojiLibrary? {
        guard let catalog = try? EmojiCatalog.bundled() else { return nil }
        let check = EmojiRenderCheck()
        return EmojiLibrary(catalog: catalog, canDraw: check.canDraw)
    }

    var library: EmojiLibrary? {
        if let cachedLibrary { return cachedLibrary }
        let loaded = loadLibrary()
        cachedLibrary = .some(loaded)
        return loaded
    }

    private var remembersRecent: Bool {
        preferences.bool(.emojiRemembersRecent, for: .emojiPicker)
    }

    /// The skin tone set in Settings: 0 for none (yellow), 1 light to 5 dark.
    var skinTone: Int {
        guard case .choice(let value) = preferences.value(of: .emojiSkinTone, for: .emojiPicker) else { return 0 }
        return PluginPreference.emojiSkinToneValues.firstIndex(of: value) ?? 0
    }

    /// What an emoji pastes and shows: its form in the chosen skin tone, when it has one.
    func glyph(for emoji: Emoji) -> String {
        let tone = skinTone
        guard tone > 0, emoji.tones.count == 5 else { return emoji.glyph }
        return emoji.tones[tone - 1]
    }

    // MARK: Rows

    private static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The browsing grid's sections: Recent (when kept and not empty), then each group.
    var sections: [Section] {
        guard let library else { return [] }
        let recent = remembersRecent ? recents.glyphs.compactMap(library.emoji(withGlyph:)) : []
        var sections = recent.isEmpty ? [] : [Section(title: "Recent", emoji: recent)]
        let byGroup = Dictionary(grouping: library.emoji, by: \.group)
        for (index, title) in library.groups.enumerated() {
            if let emoji = byGroup[index], !emoji.isEmpty { sections.append(Section(title: title, emoji: emoji)) }
        }
        return sections
    }

    /// The emoji the rows stand for, in order: the grid's, or the search's.
    func rows(query: String) -> [Emoji] {
        guard let library else { return [] }
        if Self.isSearching(query) { return library.search(query, recent: remembersRecent ? recents.glyphs : []) }
        return sections.flatMap(\.emoji)
    }

    func rowCount(query: String) -> Int {
        rows(query: query).count
    }

    func isGrid(query: String) -> Bool {
        !Self.isSearching(query)
    }

    func selection(after move: PaletteMove, from row: Int, query: String) -> Int? {
        PaletteGrid.selection(after: move, from: row, sectionCounts: sections.map(\.emoji.count), columns: Self.columns)
    }

    /// Return copies; ⌘Return pastes, then puts the clipboard back. Either way the emoji becomes
    /// the most recent, unless recent emoji are turned off.
    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions) {
        let rows = rows(query: query)
        guard rows.indices.contains(row) else { return }
        let emoji = rows[row]
        if remembersRecent { recents.use(emoji.glyph) }
        let glyph = glyph(for: emoji)
        if withCommand {
            palette.paste(glyph, true)
        } else {
            palette.copy(glyph)
        }
    }

    func footerActions(row: Int, query: String) -> PaletteFooterActions {
        PaletteFooterActions(primary: "Copy", secondary: "Paste")
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        AnyView(EmojiPaletteResults(content: self, query: context.query, selection: context.selection, select: context.actions.selectRow))
    }
}

/// The Emoji tab's grid or list, and the highlighted emoji's name.
private struct EmojiPaletteResults: View {
    let content: EmojiPaletteContent
    let query: String
    let selection: Int
    let select: (Int) -> Void

    var body: some View {
        PaletteResultsContainer {
            if content.library == nil {
                PaletteEmptyState(title: "Emoji couldn’t be loaded", systemImage: "face.smiling")
            } else if content.isGrid(query: query) {
                grid
            } else {
                list
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        let sections = content.sections
        let starts = Self.starts(of: sections)
        let all = sections.flatMap(\.emoji)
        return VStack(spacing: 0) {
            selectedName(all.indices.contains(selection) ? all[selection] : nil)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(sections.enumerated()), id: \.element.title) { sectionIndex, section in
                            PaletteSectionHeader(section.title)
                                .padding(.horizontal, 4)
                                .padding(.top, sectionIndex == 0 ? 0 : 8)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: EmojiPaletteContent.columns), spacing: 4) {
                                ForEach(Array(section.emoji.enumerated()), id: \.element.glyph) { offset, emoji in
                                    let index = starts[sectionIndex] + offset
                                    EmojiCell(glyph: content.glyph(for: emoji), name: emoji.name, isSelected: index == selection) { select(index) }
                                        .id(index)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
        }
    }

    /// The row index of each section's first emoji.
    static func starts(of sections: [EmojiPaletteContent.Section]) -> [Int] {
        var starts: [Int] = []
        var total = 0
        for section in sections {
            starts.append(total)
            total += section.emoji.count
        }
        return starts
    }

    private func selectedName(_ emoji: Emoji?) -> some View {
        HStack(spacing: 8) {
            if let emoji {
                Text(content.glyph(for: emoji)).font(.system(size: 18))
                Text(emoji.name).font(.system(size: 13))
                Text(":\(emoji.aliases[0]):")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .lineLimit(1)
        .frame(height: 30)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("palette.emoji.selectedName")
    }

    // MARK: List

    private var list: some View {
        let rows = content.rows(query: query)
        return Group {
            if rows.isEmpty {
                PaletteEmptyState(title: "No emoji match", systemImage: "face.smiling")
            } else {
                ScrollViewReader { proxy in
                    List(Array(rows.enumerated()), id: \.element.glyph) { index, emoji in
                        Button { select(index) } label: {
                            EmojiRow(glyph: content.glyph(for: emoji), emoji: emoji)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteRowBackground(isSelected: index == selection)
                        .accessibilityIdentifier("palette.emoji.row")
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selection) {
                        if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].glyph) }
                    }
                }
            }
        }
    }
}

private struct EmojiCell: View {
    let glyph: String
    let name: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(glyph)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? PaletteTheme.selection : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("palette.emoji.cell")
    }
}

private struct EmojiRow: View {
    let glyph: String
    let emoji: Emoji

    var body: some View {
        HStack(spacing: 12) {
            Text(glyph)
                .font(.system(size: 24))
                .frame(width: 34)
                .accessibilityHidden(true)
            Text(emoji.name)
                .font(.system(size: 15))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(":\(emoji.aliases[0]):")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
