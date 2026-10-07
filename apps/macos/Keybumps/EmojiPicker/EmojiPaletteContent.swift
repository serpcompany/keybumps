import AppKit
import SwiftUI

/// The Emoji tab (#243). With the search empty it's a grid to browse: Recent, then Unicode's groups.
/// Typing turns it into a ranked list, as the Search tab is. Return copies the emoji and ⌘Return
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
        let actions = context.actions
        let query = context.query
        return AnyView(EmojiPaletteResults(
            content: self,
            query: query,
            selection: context.selection,
            select: actions.selectRow,
            pick: { [weak self] row in self?.activate(row: row, query: query, withCommand: false, palette: actions) }
        ))
    }
}

/// The Emoji tab's grid or list, and the highlighted emoji's name.
private struct EmojiPaletteResults: View {
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
                            PaletteSectionHeader(section.title)
                                .padding(.horizontal, 4)
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
                                    .id(index)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: selection) {
                    proxy.scrollTo(selection)
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
                        .simultaneousGesture(TapGesture(count: 2).onEnded { pick(index) })
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteRowBackground(isSelected: index == selection)
                        .accessibilityAddTraits(index == selection ? .isSelected : [])
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
