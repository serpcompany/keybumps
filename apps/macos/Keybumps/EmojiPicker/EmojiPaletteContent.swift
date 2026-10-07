import AppKit
import SwiftUI

/// The Emoji tab (#243). With the search empty it's a grid to browse: Recent, then Unicode's groups.
/// Typing turns it into a ranked list, as the Search tab is. Return or ⌘C copies the emoji and ⌘P
/// pastes it into the app you were using, putting your clipboard back afterwards; a double-click
/// copies too. The emoji takes the skin tone set in Settings when it has one.
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

    /// The list, once loaded; nil while it loads, or when it couldn't be.
    private(set) var library: EmojiLibrary?
    private(set) var loadFailed = false
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored let recents: EmojiRecents
    @ObservationIgnored private let loadLibrary: @Sendable () -> EmojiLibrary?
    @ObservationIgnored private let loadsInBackground: Bool
    /// The grid's sections, kept until Recent or the setting changes.
    @ObservationIgnored private var cachedSections: (key: [String], sections: [Section])?
    /// The last search's results, kept until the query or Recent changes.
    @ObservationIgnored private var cachedSearch: (query: String, recent: [String], results: [Emoji])?

    /// `loadLibrary` runs once, the first time the tab shows: off the main thread in the app, or at
    /// once when `loadsInBackground` is false, as tests ask.
    init(
        preferences: AppPreferences,
        recents: EmojiRecents,
        loadLibrary: @escaping @Sendable () -> EmojiLibrary? = EmojiPaletteContent.bundledLibrary,
        loadsInBackground: Bool = true
    ) {
        self.preferences = preferences
        self.recents = recents
        self.loadLibrary = loadLibrary
        self.loadsInBackground = loadsInBackground
        if !loadsInBackground { finishLoading(loadLibrary()) }
    }

    /// The bundled catalog, without what this Mac can't draw; nil when either is missing.
    nonisolated static func bundledLibrary() -> EmojiLibrary? {
        guard let catalog = try? EmojiCatalog.bundled(), let check = EmojiRenderCheck() else { return nil }
        return EmojiLibrary(catalog: catalog, canDraw: check.canDraw)
    }

    func didShow(palette: PaletteContentActions) {
        loadIfNeeded()
    }

    // MARK: Quick Search (#333)

    /// Loads the list ahead of Quick Search's first query.
    func prepareForQuickSearch() {
        loadIfNeeded()
    }

    /// Quick Search's emoji for a query: every match of the Emoji tab's search, while Emoji Picker
    /// and Show emoji in Quick Search are on. None until the list has loaded.
    func quickSearchMatches(_ query: String) -> [QuickSearchEmoji] {
        guard preferences.quickSearchFindsEmoji, Self.isSearching(query) else { return [] }
        loadIfNeeded()
        return rows(query: query).map {
            QuickSearchEmoji(glyph: glyph(for: $0), baseGlyph: $0.glyph, name: $0.name)
        }
    }

    /// An emoji used from Quick Search becomes the most recent, as in the tab.
    func useFromQuickSearch(_ emoji: QuickSearchEmoji) {
        if remembersRecent { recents.use(emoji.baseGlyph) }
    }

    private func loadIfNeeded() {
        guard library == nil, !loadFailed, !isLoading else { return }
        isLoading = true
        let load = loadLibrary
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { load() }.value
            self?.finishLoading(loaded)
        }
    }

    private func finishLoading(_ loaded: EmojiLibrary?) {
        isLoading = false
        library = loaded
        loadFailed = loaded == nil
    }

    var isEnabled: Bool {
        preferences.enabledCapabilities.contains(.emojiPicker)
    }

    private var remembersRecent: Bool {
        preferences.bool(.emojiRemembersRecent, for: .emojiPicker)
    }

    private var recentGlyphs: [String] {
        remembersRecent ? recents.glyphs : []
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
        guard isEnabled, let library else { return [] }
        let recent = recentGlyphs
        if let cachedSections, cachedSections.key == recent { return cachedSections.sections }
        let recentEmoji = recent.compactMap(library.emoji(withGlyph:))
        var sections = recentEmoji.isEmpty ? [] : [Section(title: "Recent", emoji: recentEmoji)]
        let byGroup = Dictionary(grouping: library.emoji, by: \.group)
        for (index, title) in library.groups.enumerated() {
            if let emoji = byGroup[index], !emoji.isEmpty { sections.append(Section(title: title, emoji: emoji)) }
        }
        cachedSections = (recent, sections)
        return sections
    }

    /// The row index of each section's first emoji.
    static func starts(of sections: [Section]) -> [Int] {
        var starts: [Int] = []
        var total = 0
        for section in sections {
            starts.append(total)
            total += section.emoji.count
        }
        return starts
    }

    /// The emoji the rows stand for, in order: the grid's, or the search's.
    func rows(query: String) -> [Emoji] {
        guard isEnabled, let library else { return [] }
        guard Self.isSearching(query) else { return sections.flatMap(\.emoji) }
        let recent = recentGlyphs
        if let cachedSearch, cachedSearch.query == query, cachedSearch.recent == recent { return cachedSearch.results }
        let results = library.search(query, recent: recent)
        cachedSearch = (query, recent, results)
        return results
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

    /// Return and ⌘C copy; ⌘P pastes, then puts the clipboard back. Either way the emoji becomes
    /// the most recent, unless recent emoji are turned off.
    func activate(row: Int, query: String, palette: PaletteContentActions) {
        copy(row: row, query: query, palette: palette)
    }

    func copy(row: Int, query: String, palette: PaletteContentActions) {
        guard let glyph = use(row: row, query: query) else { return }
        palette.copy(glyph)
    }

    func paste(row: Int, query: String, palette: PaletteContentActions) {
        guard let glyph = use(row: row, query: query) else { return }
        palette.paste(glyph, true)
    }

    /// The glyph a row copies or pastes, making it the most recent emoji.
    private func use(row: Int, query: String) -> String? {
        let rows = rows(query: query)
        guard rows.indices.contains(row) else { return nil }
        let emoji = rows[row]
        if remembersRecent { recents.use(emoji.glyph) }
        return glyph(for: emoji)
    }

    func footerActions(row: Int, query: String) -> PaletteFooterActions {
        PaletteFooterActions(primary: "Copy", secondary: [.paste()])
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        let actions = context.actions
        let query = context.query
        return AnyView(EmojiPaletteResults(
            content: self,
            query: query,
            selection: context.selection,
            select: actions.selectRow,
            pick: { [weak self] row in self?.activate(row: row, query: query, palette: actions) }
        ))
    }
}

/// The Emoji tab's grid or list, and the highlighted emoji's name.
private struct EmojiPaletteResults: View {
    @Environment(\.paletteRevealsSelection) private var revealsSelection
    let content: EmojiPaletteContent
    let query: String
    let selection: Int
    let select: (Int) -> Void
    /// A double-click: what Return does.
    let pick: (Int) -> Void

    var body: some View {
        PaletteResultsContainer {
            if !content.isEnabled {
                PaletteEmptyState(title: "Emoji Picker is turned off. Turn it on in Settings › Plugins.", systemImage: "face.smiling")
            } else if content.loadFailed {
                PaletteEmptyState(title: "Emoji couldn’t be loaded", systemImage: "face.smiling")
            } else if content.library == nil {
                ProgressView().controlSize(.small)
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
        let starts = EmojiPaletteContent.starts(of: sections)
        let all = sections.flatMap(\.emoji)
        let selected = all.indices.contains(selection) ? all[selection] : nil
        return VStack(spacing: 0) {
            selectedName(selected)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(sections.enumerated()), id: \.element.title) { sectionIndex, section in
                            // A group's title starts where the other tabs' headers do, and its tiles
                            // where their rows' wells do (#381).
                            PaletteSectionHeader(section.title)
                                .paletteLayoutProbe(.gridHeader)
                                .padding(.horizontal, PaletteRowMetrics.headerInset)
                                .padding(.top, sectionIndex == 0 ? 0 : 8)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: EmojiPaletteContent.columns), spacing: 4) {
                                ForEach(Array(section.emoji.enumerated()), id: \.element.glyph) { offset, emoji in
                                    let index = starts[sectionIndex] + offset
                                    EmojiCell(
                                        glyph: content.glyph(for: emoji),
                                        name: emoji.name,
                                        isSelected: index == selection,
                                        select: { select(index) },
                                        pick: { pick(index) }
                                    )
                                    .paletteHoverHighlights(row: index)
                                    .id(index)
                                }
                            }
                            .padding(.horizontal, PaletteRowMetrics.wellX)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .paletteScrollsToSelection(selection, proxy: proxy) { all.indices.contains($0) ? $0 : nil }
                .onChange(of: selection) {
                    // The pointer moved the highlight: the tile is already under it, and the name
                    // above the grid shows which emoji it is.
                    guard revealsSelection else { return }
                    // Arrowing through the grid moves no VoiceOver cursor, so say where it went.
                    if let selected { Self.announce(selected.name) }
                }
            }
        }
    }

    private static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
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
        // Where the other tabs' section header is, so the grid starts where their rows do (#381).
        .paletteHeaderBand()
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
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { pick(index) })
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteHoverHighlights(row: index)
                        .paletteRowBackground(isSelected: index == selection)
                        .accessibilityAddTraits(index == selection ? .isSelected : [])
                        .accessibilityIdentifier("palette.emoji.row")
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .paletteScrollsToSelection(selection, proxy: proxy) { rows.indices.contains($0) ? rows[$0].glyph : nil }
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
    let pick: () -> Void

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
        .paletteLayoutProbe(.gridItem)
        .simultaneousGesture(TapGesture(count: 2).onEnded(pick))
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("palette.emoji.cell")
    }
}

private struct EmojiRow: View {
    let glyph: String
    let emoji: Emoji

    var body: some View {
        PaletteRow {
            PaletteRowEmoji(glyph: glyph)
        } content: {
            HStack(spacing: 12) {
                Text(emoji.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(":\(emoji.aliases[0]):")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
