import Foundation

/// A Keybumps action that Quick Search offers beside apps, files, and folders, as Alfred offers its
/// preferences and Raycast its commands: Keybumps Settings, and one per capability that goes to it.
enum QuickSearchCommand: Hashable, Identifiable {
    /// Opens Settings, as the status menu's Settings… and Command-comma do.
    case keybumpsSettings
    /// Goes to a capability, named as its Settings page is: its Command Palette tab while it's turned
    /// on, otherwise its Settings page (`destination(enabledCapabilities:)`).
    case capability(Capability)

    /// Every command, in the order equally good matches are listed: Keybumps Settings, then the
    /// capabilities in registry order. Quick Search itself has none, since its tab lists the commands.
    static let allCases: [QuickSearchCommand] = [.keybumpsSettings]
        + CapabilityCatalog.descriptors
            .filter { $0.capability != .quickSearch }
            .map { .capability($0.capability) }

    /// A stable token for accessibility identifiers: `keybumpsSettings`, or the capability's ID.
    var id: String {
        switch self {
        case .keybumpsSettings: "keybumpsSettings"
        case .capability(let capability): capability.rawValue
        }
    }

    var title: String {
        switch self {
        case .keybumpsSettings: "\(ReleaseLane.current.productName) Settings"
        case .capability(let capability): capability.title
        }
    }

    /// Shown where other results show Application, File, or Folder.
    var kindLabel: String { "Command" }

    /// The shortcut that runs it from any Command Palette tab. Only Keybumps Settings has one of its
    /// own; a capability's row shows its tab's Command-number instead (`rowShortcut`).
    var shortcut: String? {
        switch self {
        case .keybumpsSettings: "⌘,"
        case .capability: nil
        }
    }

    /// The key that runs it with Command held, as reported by `charactersIgnoringModifiers`.
    var commandKey: String? {
        switch self {
        case .keybumpsSettings: ","
        case .capability: nil
        }
    }

    /// Other words people search for it by, such as Alfred's and older macOS's "Preferences", or a
    /// capability's tab name and what it does ("hotkeys", "dictate").
    var keywords: [String] {
        switch self {
        case .keybumpsSettings: ["preferences", "prefs"]
        case .capability(let capability): capability.descriptor.searchKeywords
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
        guard let characters else { return nil }
        return allCases.first { $0.commandKey == characters }
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

// MARK: - Where a command goes

extension QuickSearchCommand {
    /// Where running a command goes.
    enum Destination: Equatable {
        /// A Command Palette tab. The palette stays open on it.
        case paletteTab(CommandPaletteTab)
        /// Settings on this page, or where it was left when nil. The palette closes first.
        case settings(SettingsSection?)

        /// What running it does, for the row's tooltip and VoiceOver hint.
        var hint: String {
            switch self {
            case .paletteTab(let tab): "Shows the \(tab.title) tab"
            case .settings(let section?): "Opens \(section.rawValue) in Settings"
            case .settings(nil): "Opens Settings"
            }
        }
    }

    /// Keybumps Settings opens Settings. A capability's command shows its tab while the capability is
    /// on. While it's off, or when it has no tab (Window Manager), it opens its Settings page, where
    /// it can be turned on.
    func destination(enabledCapabilities: Set<Capability>) -> Destination {
        switch self {
        case .keybumpsSettings:
            return .settings(nil)
        case .capability(let capability):
            let descriptor = capability.descriptor
            if enabledCapabilities.contains(capability), let tab = descriptor.paletteTab?.tab {
                return .paletteTab(tab)
            }
            return .settings(descriptor.settingsPage?.section)
        }
    }

    /// Whether its capability is off, so its row says so before Return opens the Settings page.
    func isTurnedOff(enabledCapabilities: Set<Capability>) -> Bool {
        guard case .capability(let capability) = self else { return false }
        return !enabledCapabilities.contains(capability)
    }

    /// The keycaps its row shows: its own shortcut, or the Command-number of the tab it goes to while
    /// that tab is in the tab bar (the Hotkeys tab is usually hidden, and then Command-5 does nothing).
    func rowShortcut(enabledCapabilities: Set<Capability>, visibleTabs: [CommandPaletteTab]) -> String? {
        if let shortcut { return shortcut }
        guard case .paletteTab(let tab) = destination(enabledCapabilities: enabledCapabilities),
              visibleTabs.contains(tab) else { return nil }
        return tab.shortcutLabel
    }
}

// MARK: - Quick Search rows

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
    /// Quick Search's rows for a query. Commands the query names exactly come first, as Alfred puts
    /// its preferences first; ones the query only starts come after the applications, so a few
    /// letters still find apps first. Files and folders come last. Equally good commands keep
    /// `QuickSearchCommand.allCases` order.
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
