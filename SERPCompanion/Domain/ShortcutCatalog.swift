import Foundation

struct ShortcutTip: Identifiable, Equatable {
    let applicationName: String
    let actionTitle: String
    let shortcut: String

    var id: String { "\(applicationName)|\(actionTitle)|\(shortcut)" }
}

enum ShortcutCatalog {
    static let tips: [ShortcutTip] = [
        .init(applicationName: "General", actionTitle: "Copy", shortcut: "⌘C"),
        .init(applicationName: "General", actionTitle: "Paste", shortcut: "⌘V"),
        .init(applicationName: "General", actionTitle: "Undo", shortcut: "⌘Z"),
        .init(applicationName: "General", actionTitle: "Find", shortcut: "⌘F"),
        .init(applicationName: "Finder", actionTitle: "New Finder Window", shortcut: "⌘N"),
        .init(applicationName: "Finder", actionTitle: "Move to Trash", shortcut: "⌘Delete"),
        .init(applicationName: "Finder", actionTitle: "Quick Look", shortcut: "Space"),
        .init(applicationName: "Google Chrome", actionTitle: "New Tab", shortcut: "⌘T"),
        .init(applicationName: "Google Chrome", actionTitle: "Close Tab", shortcut: "⌘W"),
        .init(applicationName: "Google Chrome", actionTitle: "Next Tab", shortcut: "⌃Tab"),
        .init(applicationName: "Safari", actionTitle: "New Tab", shortcut: "⌘T"),
        .init(applicationName: "Safari", actionTitle: "Close Tab", shortcut: "⌘W"),
        .init(applicationName: "Safari", actionTitle: "Show Start Page", shortcut: "⇧⌘\\")
    ]

    static var applications: [String] {
        Array(Set(tips.map(\.applicationName))).sorted()
    }

    static func matching(searchText: String, application: String?) -> [ShortcutTip] {
        tips.filter { tip in
            let matchesApplication = application == nil || tip.applicationName == application || tip.applicationName == "General"
            let matchesSearch = searchText.isEmpty ||
                tip.applicationName.localizedCaseInsensitiveContains(searchText) ||
                tip.actionTitle.localizedCaseInsensitiveContains(searchText) ||
                tip.shortcut.localizedCaseInsensitiveContains(searchText)
            return matchesApplication && matchesSearch
        }
    }
}
