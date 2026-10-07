import Foundation
import SwiftUI

/// What `/` offers in a Command Palette tab: typed into an empty search field, it lists the tab's
/// filters ("Filter by …"); choosing one narrows the tab's items until it's removed.
enum PaletteFilter: String, CaseIterable, Identifiable, Equatable {
    // Quick Search
    case applications, files, folders, commands, snippets, emoji
    // Clipboard History
    case text, images, links
    // Screenshots and Dictation
    case today, thisWeek
    // Dictation
    case unfinished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applications: "Apps"
        case .files: "Files"
        case .folders: "Folders"
        case .commands: "Commands"
        case .snippets: "Snippets"
        case .emoji: "Emoji"
        case .text: "Text"
        case .images: "Images"
        case .links: "Links"
        case .today: "Today"
        case .thisWeek: "This Week"
        case .unfinished: "Failed or Interrupted"
        }
    }

    var systemImage: String {
        switch self {
        case .applications: "app"
        case .files: "doc"
        case .folders: "folder"
        case .commands: "command"
        case .snippets: "text.badge.plus"
        case .emoji: "face.smiling"
        case .text: "text.alignleft"
        case .images: "photo"
        case .links: "link"
        case .today: "sun.max"
        case .thisWeek: "calendar"
        case .unfinished: "exclamationmark.triangle"
        }
    }

    /// The filters `/` lists in `tab`, in order. Tabs with none type `/` as usual. Quick Search
    /// offers Emoji only while it finds emoji (`searchFindsEmoji`).
    static func available(in tab: CommandPaletteTab, searchFindsEmoji: Bool = false) -> [PaletteFilter] {
        switch tab {
        case .search: [.applications, .files, .folders, .commands, .snippets] + (searchFindsEmoji ? [.emoji] : [])
        case .clipboard: [.text, .images, .links]
        case .screenshots: [.today, .thisWeek]
        case .dictation: [.today, .thisWeek, .unfinished]
        default: []
        }
    }

    /// The filters a query starting with `/` lists: all of the tab's, or those whose title starts
    /// with what follows the `/`. Nil when the query doesn't open the list, or when no title matches,
    /// so a search that starts with `/`, such as a path or a `/sig` snippet keyword, still searches.
    static func menu(in tab: CommandPaletteTab, query: String, searchFindsEmoji: Bool = false) -> [PaletteFilter]? {
        guard query.hasPrefix("/") else { return nil }
        let filters = available(in: tab, searchFindsEmoji: searchFindsEmoji)
        guard !filters.isEmpty else { return nil }
        let typed = query.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return filters }
        let matches = filters.filter { $0.title.range(of: typed, options: [.caseInsensitive, .anchored]) != nil }
        return matches.isEmpty ? nil : matches
    }

    // MARK: - Matching

    func matches(_ item: QuickSearchItem) -> Bool {
        switch (self, item) {
        case (.commands, .command), (.snippets, .snippet), (.emoji, .emoji): true
        case (.applications, .result(let result)): result.kind == .application
        case (.files, .result(let result)): result.kind == .file
        case (.folders, .result(let result)): result.kind == .folder
        default: false
        }
    }

    func matches(_ entry: ClipboardEntry, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .text: entry.kind == .text && !Self.isLink(entry.text)
        case .images: entry.kind == .image
        case .links: entry.kind == .text && Self.isLink(entry.text)
        case .today, .thisWeek: matches(date: entry.capturedAt, now: now, calendar: calendar)
        default: false
        }
    }

    func matches(_ entry: DictationHistoryEntry, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .today, .thisWeek: matches(date: entry.capturedAt, now: now, calendar: calendar)
        case .unfinished: entry.state == .failed || entry.state == .interrupted
        default: false
        }
    }

    private func matches(date: Date, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .today: calendar.isDate(date, inSameDayAs: now)
        case .thisWeek: calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        default: false
        }
    }

    /// A copied web address: one http or https URL and nothing else.
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }
}

extension Optional where Wrapped == PaletteFilter {
    /// `items` narrowed by the filter, or all of them when there's none.
    func apply<T>(_ items: [T], _ matches: (PaletteFilter, T) -> Bool) -> [T] {
        guard let filter = self else { return items }
        return items.filter { matches(filter, $0) }
    }
}


/// `/`'s list: one "Filter by …" row per filter the tab offers.
struct PaletteFilterMenu: View {
    let filters: [PaletteFilter]
    let selection: Int
    let select: (Int) -> Void
    let choose: (PaletteFilter) -> Void

    var body: some View {
        PaletteResultsContainer {
            if filters.isEmpty {
                PaletteEmptyState(title: "No matching filter", systemImage: "line.3.horizontal.decrease")
            } else {
                List(Array(filters.enumerated()), id: \.element.id) { index, filter in
                    Button { choose(filter) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: filter.systemImage)
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            Text("Filter by")
                                .foregroundStyle(.secondary)
                            Text(filter.title)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(PaletteTheme.keycapFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Spacer()
                        }
                        .font(.system(size: 15))
                        .paletteQuickSelect(row: index)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { select(index) } }
                    .accessibilityLabel("Filter by \(filter.title)")
                    .accessibilityAddTraits(index == selection ? .isSelected : [])
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
                    .paletteRowBackground(isSelected: index == selection)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// The chosen filter, shown before the search text; its × or Delete in an empty field removes it.
struct PaletteFilterChip: View {
    let filter: PaletteFilter
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: filter.systemImage)
            Text(filter.title)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove filter \(filter.title)")
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(PaletteTheme.keycapFill, in: Capsule())
        .overlay(Capsule().strokeBorder(PaletteTheme.keycapBorder, lineWidth: 1))
        .fixedSize()
    }
}
