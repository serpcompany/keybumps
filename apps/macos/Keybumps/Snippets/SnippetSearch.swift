import Foundation

/// How the Snippets tab and the Settings list find and order snippets.
enum SnippetSearch {
    /// How well a query matches a snippet, best first.
    enum Match: Int, Comparable {
        /// The keyword is the query, with or without its leading punctuation (`;ship` or `ship`).
        case keyword
        /// The keyword starts with the query.
        case keywordPrefix
        /// Every query word starts a word of the name.
        case nameWords
        /// The name contains the query.
        case name
        /// The text contains the query. A sensitive snippet's text is never searched.
        case text

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The snippets for a query, best first. An empty query lists every snippet, recently used
    /// first and then by name. Otherwise snippets are grouped by `Match`, and each group keeps
    /// that same order. Case and accents are ignored.
    static func results(_ snippets: [Snippet], query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets.sorted(by: listOrder) }
        return ranked(snippets, query: trimmed).map(\.snippet)
    }

    /// How many snippets Quick Search lists at most, so they never bury apps and files.
    static let quickSearchLimit = 8

    /// Quick Search's snippets for a query, ranked as in the Snippets tab but matched only by keyword
    /// and name: text is never searched there, so snippet text doesn't flood app and file results.
    static func quickSearchMatches(_ snippets: [Snippet], query: String) -> [(snippet: Snippet, match: Match)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return Array(ranked(snippets, query: trimmed).filter { $0.match != .text }.prefix(quickSearchLimit))
    }

    /// The snippets `query` (trimmed, not empty) matches, grouped by `Match` best first, each group
    /// in `listOrder`.
    private static func ranked(_ snippets: [Snippet], query: String) -> [(snippet: Snippet, match: Match)] {
        let matches = snippets.sorted(by: listOrder).compactMap { snippet in
            match(snippet, query: query).map { (snippet: snippet, match: $0) }
        }
        // A stable sort by match keeps the list order inside each group.
        return matches.enumerated()
            .sorted { ($0.element.match, $0.offset) < ($1.element.match, $1.offset) }
            .map(\.element)
    }

    /// The Settings list: by name with an empty search, where you manage snippets rather than use
    /// them, otherwise the same results as the palette.
    static func settingsResults(_ snippets: [Snippet], query: String) -> [Snippet] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return results(snippets, query: query)
        }
        return snippets.sorted(by: nameOrder)
    }

    /// Recently used first (most recent on top), then the rest by name.
    static func listOrder(_ lhs: Snippet, _ rhs: Snippet) -> Bool {
        switch (lhs.lastUsedAt, rhs.lastUsedAt) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return nameOrder(lhs, rhs)
        }
    }

    /// By name as Finder sorts, then oldest first.
    static func nameOrder(_ lhs: Snippet, _ rhs: Snippet) -> Bool {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        return byName == .orderedSame ? lhs.createdAt < rhs.createdAt : byName == .orderedAscending
    }

    /// The best way `query` (already trimmed) matches `snippet`, or nil.
    static func match(_ snippet: Snippet, query: String) -> Match? {
        let folded = fold(query)
        if let keyword = snippet.keyword.map(fold) {
            let bare = String(keyword.drop { !$0.isLetter && !$0.isNumber })
            if keyword == folded || bare == folded { return .keyword }
            if keyword.hasPrefix(folded) || (!bare.isEmpty && bare.hasPrefix(folded)) { return .keywordPrefix }
        }
        let name = fold(snippet.name)
        let queryWords = words(in: folded)
        let nameWords = words(in: name)
        if !queryWords.isEmpty, queryWords.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) {
            return .nameWords
        }
        if name.contains(folded) { return .name }
        if !snippet.isSensitive, fold(snippet.text).contains(folded) { return .text }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func words(in text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }
}

/// What a snippet shows in the palette's rows and the Settings list.
enum SnippetPresentation {
    /// Stands in for a sensitive snippet's text everywhere it would show.
    static let maskedText = "••••••"

    /// The text on one line (runs of whitespace become single spaces), or the mask.
    static func preview(of snippet: Snippet) -> String {
        snippet.isSensitive ? maskedText : ClipboardRowPresentation.singleLine(snippet.text)
    }

    /// What VoiceOver reads for a row. A sensitive snippet's text is never read out.
    static func accessibilityLabel(for snippet: Snippet) -> String {
        var parts = [snippet.name]
        if let keyword = snippet.keyword { parts.append("keyword \(keyword)") }
        parts.append(snippet.isSensitive ? "sensitive, text hidden" : preview(of: snippet))
        return parts.joined(separator: ", ")
    }

    static func count(_ count: Int) -> String {
        count == 1 ? "1 snippet" : "\(count) snippets"
    }
}

/// What the Snippets tab shows.
enum SnippetPaletteContent: Equatable {
    case disabled
    /// The saved snippets can't be read (`SnippetLibraryState.readOnly`), so the tab mustn't look empty.
    case unreadable
    /// There are no snippets yet.
    case empty
    /// There are snippets, but none match the search.
    case noMatches
    case entries([Snippet])

    static func resolve(
        snippets: [Snippet],
        query: String,
        isEnabled: Bool,
        libraryState: SnippetLibraryState = .ready
    ) -> SnippetPaletteContent {
        guard isEnabled else { return .disabled }
        guard libraryState != .readOnly else { return .unreadable }
        guard !snippets.isEmpty else { return .empty }
        let results = SnippetSearch.results(snippets, query: query)
        return results.isEmpty ? .noMatches : .entries(results)
    }

    var entries: [Snippet] {
        guard case .entries(let entries) = self else { return [] }
        return entries
    }
}
