import SwiftUI

extension CapabilityDescriptor {
    static let emojiPicker = CapabilityDescriptor(
        capability: .emojiPicker,
        title: "Emoji Picker",
        systemImage: "face.smiling",
        iconTint: .yellow,
        requiredPermissions: [],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .emoji,
            name: "Emoji",
            commandKey: 7,
            systemImage: "face.smiling",
            prompt: "Search emoji by name, keyword, or :shortcode:",
            primaryActionTitle: "Copy",
            secondaryActionTitle: "Paste",
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .emojiPicker,
            summary: "Find any emoji by name and paste it where you’re typing.",
            disableExplanation: "Turning this off closes the Emoji tab and releases its global shortcut. Your recent emoji stay saved on this Mac.",
            content: { AnyView(PluginSettingsPage(capability: .emojiPicker)) }
        ),
        criticalOperations: [],
        searchKeywords: ["emoji", "emojis", "smiley"],
        category: .writing,
        preferences: [.emojiSkinTone, .emojiRemembersRecent, .emojiInQuickSearch],
        optionalPermissions: [
            PluginOptionalPermission(
                permission: .accessibility,
                reason: "Lets ⌘Return paste the emoji into the app you’re using. Without it, ⌘Return copies the emoji instead."
            ),
        ],
        isOnByDefault: false
    )
}

extension PluginPreference {
    /// The tones, in the order `Emoji.tones` lists them after "none".
    static let emojiSkinToneValues = ["none", "light", "mediumLight", "medium", "mediumDark", "dark"]

    static let emojiSkinTone = PluginPreference(
        key: "skinTone",
        title: "Skin tone",
        subtitle: "Used for every emoji that has skin tones, including two-person ones.",
        group: "Picking",
        kind: .choice(
            options: zip(emojiSkinToneValues, ["Default", "Light", "Medium-Light", "Medium", "Medium-Dark", "Dark"])
                .map { PluginPreference.Choice(value: $0, title: $1) },
            default: "none"
        )
    )
    static let emojiRemembersRecent = PluginPreference(
        key: "remembersRecent",
        title: "Remember recently used emoji",
        subtitle: "Shown first while the search is empty. Kept only on this Mac; turning this off clears them.",
        group: "Picking",
        kind: .toggle(default: true)
    )
    static let emojiInQuickSearch = PluginPreference(
        key: "showsInQuickSearch",
        title: "Show emoji in Quick Search",
        subtitle: "Matching emoji appear in Quick Search's results, after apps, commands, and snippets.",
        group: "Picking",
        kind: .toggle(default: true)
    )
}

extension AppPreferences {
    /// Whether Quick Search finds emoji (#333): Emoji Picker is on, and so is its setting.
    var quickSearchFindsEmoji: Bool {
        enabledCapabilities.contains(.emojiPicker) && bool(.emojiInQuickSearch, for: .emojiPicker)
    }
}

/// Owns the Emoji tab (`EmojiPaletteContent`) and its optional Open Emoji Picker shortcut. It ships
/// off (#243): it's turned on in Settings › Plugins. Turning off Remember recently used emoji
/// clears them.
@MainActor
final class EmojiPickerModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.emojiPicker
    var paletteContent: (any CapabilityPaletteContent)? { emojiTab }
    private let emojiTab: EmojiPaletteContent
    private let palette: CommandPaletteController
    private let preferences: AppPreferences
    private let recents: EmojiRecents

    init(palette: CommandPaletteController, preferences: AppPreferences, recents: EmojiRecents, emojiTab: EmojiPaletteContent? = nil) {
        self.palette = palette
        self.preferences = preferences
        self.recents = recents
        self.emojiTab = emojiTab ?? EmojiPaletteContent(preferences: preferences, recents: recents)
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.emojiPicker.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .emojiPicker)
        ) { [weak palette] in
            palette?.toggle(.emoji)
        }
        if !preferences.bool(.emojiRemembersRecent, for: .emojiPicker) { recents.clear() }
        palette.setQuickSearchEmoji(
            matches: { [weak emojiTab] query in emojiTab?.quickSearchMatches(query) ?? [] },
            use: { [weak emojiTab] emoji in emojiTab?.useFromQuickSearch(emoji) }
        )
        if preferences.quickSearchFindsEmoji { emojiTab.prepareForQuickSearch() }
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .emoji)
    }
}
