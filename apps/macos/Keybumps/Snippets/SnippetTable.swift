import Foundation

/// How Settings › Snippets › All Snippets sorts when a column header is clicked; clicking it again
/// reverses the order. Like search, it ignores case and accents, and numbers sort as in Finder.
/// - **Keyword:** snippets without one stay last, by name, whichever way the column sorts.
/// - **Snippet:** compares what the column shows, so a sensitive snippet sorts by its mask, beside
///   the other sensitive ones, and its text is never read.
///
/// With no column chosen, the table keeps `SnippetSearch.settingsResults`' order. The choice lasts
/// only while the page is open.
struct SnippetTableSort: SortComparator, Hashable {
    enum Column: Hashable {
        case name
        case keyword
        case snippet
    }

    var column: Column
    var order: SortOrder = .forward

    static func sorted(_ snippets: [Snippet], by sortOrder: [SnippetTableSort]) -> [Snippet] {
        sortOrder.isEmpty ? snippets : snippets.sorted(using: sortOrder)
    }

    func compare(_ lhs: Snippet, _ rhs: Snippet) -> ComparisonResult {
        let result: ComparisonResult
        switch column {
        case .name:
            result = Self.byName(lhs, rhs)
        case .keyword:
            switch (lhs.keyword, rhs.keyword) {
            case (nil, nil): return Self.byName(lhs, rhs)
            case (nil, _?): return .orderedDescending
            case (_?, nil): return .orderedAscending
            case let (left?, right?): result = Self.folded(left, right) ?? Self.byName(lhs, rhs)
            }
        case .snippet:
            result = Self.folded(SnippetPresentation.preview(of: lhs), SnippetPresentation.preview(of: rhs))
                ?? Self.byName(lhs, rhs)
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    /// Ignoring case and accents, with numbers as in Finder; nil when the two read the same.
    private static func folded(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive]
        let result = lhs.compare(rhs, options: options, locale: .current)
        return result == .orderedSame ? nil : result
    }

    /// By name, then oldest first, then by ID, so snippets with the same name keep one order.
    private static func byName(_ lhs: Snippet, _ rhs: Snippet) -> ComparisonResult {
        if let result = folded(lhs.name, rhs.name) { return result }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt ? .orderedAscending : .orderedDescending }
        return lhs.id.uuidString.compare(rhs.id.uuidString)
    }
}

/// What Settings › Snippets can do with the selected snippets: Edit… takes exactly one, while
/// Delete and Mark as Sensitive / Not Sensitive take them all. Only rows the table shows count, so
/// an action never reaches a snippet the search hides.
struct SnippetTableSelection: Equatable {
    /// The selected snippets the table shows, in its order.
    let snippets: [Snippet]

    init(_ selection: Set<Snippet.ID>, in rows: [Snippet]) {
        snippets = rows.filter { selection.contains($0.id) }
    }

    var ids: Set<Snippet.ID> { Set(snippets.map(\.id)) }
    var isEmpty: Bool { snippets.isEmpty }

    var editableID: Snippet.ID? {
        snippets.count == 1 ? snippets.first?.id : nil
    }

    var canMarkSensitive: Bool { snippets.contains { !$0.isSensitive } }
    var canMarkNotSensitive: Bool { snippets.contains(where: \.isSensitive) }

    var deletionTitle: String {
        snippets.count == 1 ? "Delete this snippet?" : "Delete \(snippets.count) snippets?"
    }

    var deletionMessage: String {
        guard snippets.count == 1, let snippet = snippets.first else { return "They’ll be removed from this Mac." }
        return "“\(snippet.name)” will be removed from this Mac."
    }

    /// The count beside the search field, which says how many are selected while more than one is.
    static func countText(total: Int, selected: Int) -> String {
        selected > 1 ? "\(selected) selected" : SnippetPresentation.count(total)
    }
}
