import Foundation

/// A Keybumps action that Quick Search offers beside apps, files, and folders, as Alfred offers
/// its preferences.
enum QuickSearchCommand: String, CaseIterable, Identifiable, Hashable {
    /// Opens Settings, as the status menu's Settings… and Command-comma do.
    case keybumpsSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keybumpsSettings: "\(ReleaseLane.current.productName) Settings"
        }
    }

    /// Shown where other results show Application, File, or Folder.
    var kindLabel: String { "Command" }

    /// The shortcut that runs it from any Command Palette tab.
    var shortcut: String {
        switch self {
        case .keybumpsSettings: "⌘,"
        }
    }

    /// The key that runs it with Command held, as reported by `charactersIgnoringModifiers`.
    var commandKey: String {
        switch self {
        case .keybumpsSettings: ","
        }
    }

    /// Other words people search for it by, such as Alfred's and older macOS's "Preferences".
    var keywords: [String] {
        switch self {
        case .keybumpsSettings: ["preferences", "prefs"]
        }
    }

    /// How well a query names a command.
    enum Match: Equatable {
        /// Every query word is a whole word of the title or keywords, as in "settings" or "prefs".
        case exact
        /// Every query word starts one, as in "sett" or "keybumps pref".
        case prefix
    }

    /// How the query matches, or nil when some query word starts no word of the title or keywords.
    /// Case, accents, and punctuation between words are ignored.
    func match(_ query: String) -> Match? {
        let queryWords = Self.words(in: query)
        guard !queryWords.isEmpty else { return nil }
        let vocabulary = Set(([title] + keywords).flatMap(Self.words))
        guard queryWords.allSatisfy({ word in vocabulary.contains { $0.hasPrefix(word) } }) else { return nil }
        return queryWords.allSatisfy { vocabulary.contains($0) } ? .exact : .prefix
    }

    /// The command a Command-key press runs, if any.
    static func matchingCommandKey(_ characters: String?) -> QuickSearchCommand? {
        allCases.first { characters == $0.commandKey }
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

/// One Quick Search result row: a Keybumps command, or an app, file, or folder.
enum QuickSearchItem: Identifiable, Hashable {
    case command(QuickSearchCommand)
    case result(QuickSearchResult)

    var id: Self { self }

    var result: QuickSearchResult? {
        guard case .result(let result) = self else { return nil }
        return result
    }
}

extension QuickSearchRanking {
    /// Quick Search's rows for a query. A command the query names exactly comes first, as Alfred
    /// puts its preferences first; one the query only starts comes after the applications, so a
    /// few letters still find apps first. Files and folders come last.
    static func items(
        matching term: String,
        applications: [QuickSearchResult],
        files: [QuickSearchResult],
        commands: [QuickSearchCommand] = QuickSearchCommand.allCases
    ) -> [QuickSearchItem] {
        let exact = commands.filter { $0.match(term) == .exact }
        let prefix = commands.filter { $0.match(term) == .prefix }
        return exact.map(QuickSearchItem.command)
            + applications.map(QuickSearchItem.result)
            + prefix.map(QuickSearchItem.command)
            + files.map(QuickSearchItem.result)
    }
}
