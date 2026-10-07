import SwiftUI

extension CapabilityDescriptor {
    static let translation = CapabilityDescriptor(
        capability: .translation,
        title: "Translation",
        systemImage: "translate",
        iconTint: .indigo,
        requiredPermissions: [],
        dependencies: [],
        paletteTab: CapabilityPaletteTab(
            tab: .translate,
            name: "Translate",
            commandKey: 8,
            systemImage: "translate",
            prompt: "Type or paste text to translate",
            primaryActionTitle: "Copy",
            secondaryActionTitle: "Paste",
            dataSource: nil
        ),
        settingsPage: CapabilitySettingsPage(
            section: .translation,
            summary: "Translate what you type, then copy it or paste it where you’re typing.",
            disableExplanation: "Turning this off closes the Translate tab and releases its global shortcut. Dictation’s Translate goes back to English and Japanese.",
            content: { AnyView(PluginSettingsPage(capability: .translation) { RecentTranslationsSettings() }) }
        ),
        criticalOperations: [],
        searchKeywords: ["translate", "translator", "languages"],
        category: .writing,
        preferences: [.translationMyLanguage, .translationOtherLanguage],
        optionalPermissions: [
            PluginOptionalPermission(
                permission: .accessibility,
                reason: "Lets ⌘Return paste the translation into the app you’re using. Without it, ⌘Return copies the translation instead."
            ),
        ],
        isOnByDefault: false,
        minimumMacOS: 15
    )
}

extension PluginPreference {
    /// The languages to choose from (`TranslationLanguages`), by code.
    private static let translationLanguageChoices = TranslationLanguages.offered.map {
        PluginPreference.Choice(value: $0.code, title: $0.name)
    }

    /// The starting pair, from this Mac's languages (`TranslationLanguagePair.systemDefault`).
    private static let translationDefaultPair = TranslationLanguagePair.systemDefault()

    static let translationMyLanguage = PluginPreference(
        key: "myLanguage",
        title: "My language",
        subtitle: "Text in any other language is translated into it.",
        group: "Languages",
        kind: .choice(options: translationLanguageChoices, default: translationDefaultPair.mine),
        differsFrom: "otherLanguage"
    )
    static let translationOtherLanguage = PluginPreference(
        key: "otherLanguage",
        title: "Other language",
        subtitle: "Text in your language is translated into it. Choosing your language here swaps the two.",
        group: "Languages",
        kind: .choice(options: translationLanguageChoices, default: translationDefaultPair.other),
        differsFrom: "myLanguage"
    )
}

extension AppPreferences {
    /// The Translation plugin's languages: its My language and Other language.
    var translationLanguagePair: TranslationLanguagePair {
        TranslationLanguagePair(
            mine: choice(.translationMyLanguage, for: .translation),
            other: choice(.translationOtherLanguage, for: .translation)
        )
    }

    /// The languages Dictation's Translate goes between: the Translation plugin's while it's on,
    /// otherwise English and Japanese, as it always did.
    var dictationTranslationPair: TranslationLanguagePair {
        enabledCapabilities.contains(.translation) ? translationLanguagePair : .dictationDefault
    }
}

/// Owns the Translate tab (`TranslatePaletteContent`) and its optional Open Translate shortcut. It
/// ships off, and needs macOS 15 (`minimumMacOS`), where Apple's Translation translates on this Mac.
/// Turning it off keeps recent translations; only their Clear button removes them.
@MainActor
final class TranslationModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.translation
    var paletteContent: (any CapabilityPaletteContent)? { translateTab }
    private let translateTab: TranslatePaletteContent
    private let palette: CommandPaletteController

    init(
        palette: CommandPaletteController,
        preferences: AppPreferences,
        translator: (any TextTranslating)?,
        recents: RecentTranslations,
        speaker: any TranslationSpeaking,
        openSystemSettings: @escaping @MainActor (SystemSettingsPage) -> Void = { _ in }
    ) {
        self.palette = palette
        translateTab = TranslatePaletteContent(preferences: preferences, translator: translator, recents: recents, speaker: speaker)
        // The palette closes first, so System Settings comes forward over it.
        translateTab.openLanguageSettings = { [weak palette] in
            palette?.dismiss()
            openSystemSettings(.languageAndRegion)
        }
    }

    func apply(_ context: CapabilityContext) {
        context.configureShortcut(
            owner: CapabilityShortcut.translation.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .translation)
        ) { [weak palette] in
            palette?.toggle(.translate)
        }
    }

    func deactivate(_ context: CapabilityContext) {
        palette.dismiss(ifDisplaying: .translate)
        translateTab.stop()
    }
}

/// The Translation page's own part, below its languages: clearing recent translations, which asks
/// first. It works whether Translation is on or off.
private struct RecentTranslationsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsClear = false

    var body: some View {
        let recents = model.recentTranslations
        SettingsGroup {
            LabeledContent {
                Button("Clear Recent Translations") { confirmsClear = true }
                    .disabled(recents.records.isEmpty)
                    .accessibilityIdentifier("plugin.translation.clearRecent")
            } label: {
                SettingsRowLabel(
                    title: "Recent translations",
                    subtitle: "Return in the Translate tab saves a translation. The last \(RecentTranslations.limit) are kept on this Mac."
                )
            }
        }
        .alert("Clear recent translations?", isPresented: $confirmsClear) {
            Button("Clear", role: .destructive) { recents.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved translation will be removed from this Mac.")
        }
    }
}
