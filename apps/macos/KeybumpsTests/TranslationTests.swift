import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The Translation plugin (#322): the macOS 15 gate, its two languages, and the Translate tab.
/// Every translation here goes through `FakeTranslator`; none reaches Apple's Translation.
@MainActor
@Suite("Translation: the macOS gate")
struct TranslationGateTests {
    static let macOS14 = PluginCompatibility(macOSMajorVersion: 14)
    static let macOS15 = PluginCompatibility(macOSMajorVersion: 15)

    static let openTranslate = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧L"
    )

    @Test("On macOS 14 it can't be turned on, and says it requires macOS 15")
    func refusedOnMacOS14() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: Self.macOS14)
        #expect(!preferences.compatibility.supports(.translation))
        #expect(preferences.compatibility.requirement(for: .translation) == "Requires macOS 15")

        preferences.setCapability(.translation, enabled: true)
        #expect(!preferences.enabledCapabilities.contains(.translation))
        preferences.enabledCapabilities = Set(Capability.allCases)
        #expect(preferences.enabledCapabilities == Set(Capability.allCases).subtracting([.translation]))

        // Every other plugin is unaffected.
        for capability in Capability.allCases where capability != .translation {
            #expect(preferences.compatibility.supports(capability))
            #expect(preferences.compatibility.requirement(for: capability) == nil)
        }
    }

    @Test("On macOS 15 and later it turns on like any plugin", arguments: [15, 26, 27])
    func allowedOnMacOS15(_ version: Int) {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: version))
        #expect(preferences.compatibility.requirement(for: .translation) == nil)
        #expect(!preferences.enabledCapabilities.contains(.translation), "It ships off")
        preferences.setCapability(.translation, enabled: true)
        #expect(preferences.enabledCapabilities.contains(.translation))
    }

    @Test("Saved on, on macOS 14, it's still off: its module never runs and its tab never shows")
    func staleEnabledIsNeverApplied() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsTranslationGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func harness(on compatibility: PluginCompatibility) -> WiringHarness {
            let saved = InMemoryDefaults()
            saved.set(Capability.allCases.map(\.rawValue), forKey: "enabledCapabilities")
            saved.set(Capability.allCases.map(\.rawValue), forKey: "knownCapabilities")
            let harness = WiringHarness(
                enabled: Set(Capability.allCases), missing: nil, root: root, compatibility: compatibility, defaults: saved
            )
            harness.model.preferences.setCapabilityShortcut(Self.openTranslate, for: .translation)
            harness.model.start()
            return harness
        }

        let old = harness(on: Self.macOS14)
        #expect(!old.model.preferences.enabledCapabilities.contains(.translation))
        #expect(!old.model.capabilityContext.enabledCapabilities.contains(.translation))
        #expect(old.shortcuts()[CapabilityShortcut.translation.ownerID] == nil, "Open Translate isn't registered")
        let tabs = CommandPaletteTab.visibleTabs(
            showsHotkeys: true, selected: .search, enabled: old.model.preferences.enabledCapabilities
        )
        #expect(!tabs.contains(.translate))
        #expect(CommandPaletteTab.matchingCommandKey("8", in: tabs) == nil)
        #expect(QuickSearchCommand.capability(.translation).destination(
            enabledCapabilities: old.model.preferences.enabledCapabilities
        ) == .settings(.translation), "Its command opens its page, which says why")
        old.model.setCapability(.translation, enabled: true)
        #expect(old.shortcuts()[CapabilityShortcut.translation.ownerID] == nil)
        #expect(!old.model.preferences.enabledCapabilities.contains(.translation))

        let current = harness(on: Self.macOS15)
        #expect(current.model.preferences.enabledCapabilities.contains(.translation))
        #expect(current.shortcuts()[CapabilityShortcut.translation.ownerID] != nil)
    }
}

@MainActor
@Suite("Translation: languages")
struct TranslationLanguageTests {
    @Test(
        "The starting pair is the Mac's first language when Translation offers it, else English; with English, or Japanese for English",
        arguments: [
            (["en-US", "ja-JP"], "en", "ja"),
            (["ja-JP"], "ja", "en"),
            (["de-DE"], "de", "en"),
            (["zh-Hans-CN"], "zh-Hans", "en"),
            (["zh-Hant-TW"], "zh-Hant", "en"),
            (["zh-HK"], "zh-Hant", "en"),
            (["pt-BR"], "pt", "en"),
            (["sv-SE"], "en", "ja"),
            (["da-DK"], "en", "ja"),
            (["el-GR"], "en", "ja"),
            ([], "en", "ja"),
        ]
    )
    func systemDefault(preferred: [String], mine: String, other: String) {
        let pair = TranslationLanguagePair.systemDefault(preferredLanguages: preferred)
        #expect(pair.mine == mine)
        #expect(pair.other == other)
        #expect(TranslationLanguages.isOffered(pair.mine), "Always one Translation offers")
    }

    @Test("Chinese keeps its script: Taiwan and Hong Kong are Traditional, mainland China Simplified")
    func chineseKeepsItsScript() {
        #expect(TranslationLanguagePair.code("zh-TW") == "zh-Hant")
        #expect(TranslationLanguagePair.code("zh-HK") == "zh-Hant")
        #expect(TranslationLanguagePair.code("zh-Hant-TW") == "zh-Hant")
        #expect(TranslationLanguagePair.code("zh-CN") == "zh-Hans")
        #expect(TranslationLanguagePair.code("zh") == "zh-Hans")
        #expect(TranslationLanguagePair.code("pt-BR") == "pt")
        #expect(TranslationLanguagePair.code("en-GB") == "en")

        let traditional = TranslationLanguagePair(mine: "zh-TW", other: "en")
        #expect(traditional == TranslationLanguagePair(mine: "zh-Hant", other: "en"))
        #expect(traditional.target(forSourceIdentifier: "zh-Hant") == "en")
        #expect(traditional.target(forSourceIdentifier: "en-US") == "zh-Hant")
        #expect(traditional.target(forSourceIdentifier: "zh-Hans") == "zh-Hant", "Simplified text comes back in Traditional")
        #expect(TranslationLanguagePolicy.preferredTargetIdentifier(
            sourceIdentifier: "en", supportedIdentifiers: ["zh", "zh-TW", "ja"], pair: traditional
        ) == "zh-TW", "Matches on the script, not just the language")
        #expect(TranslationLanguagePolicy.preferredTargetIdentifier(
            sourceIdentifier: "en", supportedIdentifiers: ["zh-TW", "zh", "ja"], pair: TranslationLanguagePair(mine: "zh-CN", other: "en")
        ) == "zh")
    }

    @Test("My language and Other language are never the same: the pair puts English, or Japanese, in the other's place")
    func pairIsNeverOneLanguage() {
        #expect(TranslationLanguagePair(mine: "fr", other: "fr-CA") == TranslationLanguagePair(mine: "fr", other: "en"))
        #expect(TranslationLanguagePair(mine: "en-US", other: "en") == TranslationLanguagePair(mine: "en", other: "ja"))
        #expect(TranslationLanguagePair(mine: "zh-Hans", other: "zh-Hant").other == "zh-Hant", "Two scripts are two languages")
        for language in TranslationLanguages.offered {
            let pair = TranslationLanguagePair(mine: language.code, other: language.code)
            #expect(pair.mine != pair.other)
        }
    }

    @Test("The list is Translation's languages on macOS 15, each listed once, by its pair code")
    func offeredLanguages() {
        let codes = TranslationLanguages.offered.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(codes.allSatisfy { TranslationLanguagePair.code($0) == $0 })
        #expect(codes.count == 20)
        for code in ["en", "ja", "zh-Hans", "zh-Hant", "pt", "es", "de", "fr", "ko"] { #expect(codes.contains(code)) }
        for code in ["sv", "da", "el", "fi", "he"] { #expect(!codes.contains(code)) }
        #expect(TranslationLanguages.name(for: "zh-TW") == "Chinese (Traditional)")
        #expect(TranslationLanguages.name(for: "en-US") == "English")
    }

    @Test("My language and Other language are menus of that list, starting at the system pair, stored under the plugin")
    func preferences() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        let codes = TranslationLanguages.offered.map(\.code)
        for preference in [PluginPreference.translationMyLanguage, .translationOtherLanguage] {
            guard case .choice(let options, _) = preference.kind else {
                Issue.record("\(preference.key) isn't a menu")
                continue
            }
            #expect(options.map(\.value) == codes)
            #expect(CapabilityDescriptor.translation.preferences.contains(preference))
        }
        #expect(PluginPreference.translationMyLanguage.defaultValue == .choice(TranslationLanguagePair.systemDefault().mine))
        #expect(PluginPreference.translationOtherLanguage.defaultValue == .choice(TranslationLanguagePair.systemDefault().other))
        #expect(preferences.translationLanguagePair == .systemDefault())

        preferences.set(.choice("ja"), of: .translationOtherLanguage, for: .translation)
        preferences.set(.choice("en"), of: .translationMyLanguage, for: .translation)
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "ja"))
        preferences.set(.choice("de"), of: .translationOtherLanguage, for: .translation)
        #expect(defaults.string(forKey: "plugin.translation.otherLanguage") == "de")
        #expect(AppPreferences(defaults: defaults).translationLanguagePair == TranslationLanguagePair(mine: "en", other: "de"))
    }

    @Test("Choosing the other menu's language swaps the two, so the setting never holds one language twice")
    func choosingTheOtherLanguageSwaps() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.set(.choice("ja"), of: .translationOtherLanguage, for: .translation)
        preferences.set(.choice("en"), of: .translationMyLanguage, for: .translation)

        preferences.set(.choice("ja"), of: .translationMyLanguage, for: .translation)
        #expect(preferences.choice(.translationMyLanguage, for: .translation) == "ja")
        #expect(preferences.choice(.translationOtherLanguage, for: .translation) == "en")
        #expect(defaults.string(forKey: "plugin.translation.otherLanguage") == "en")

        preferences.set(.choice("ja"), of: .translationOtherLanguage, for: .translation)
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "ja"))
    }

    @Test("One language saved for both, as by `defaults write`, still gives two")
    func savedTwiceStillGivesTwo() {
        let defaults = InMemoryDefaults()
        defaults.set("fr", forKey: "plugin.translation.myLanguage")
        defaults.set("fr", forKey: "plugin.translation.otherLanguage")
        #expect(AppPreferences(defaults: defaults).translationLanguagePair == TranslationLanguagePair(mine: "fr", other: "en"))
    }

    @Test("Dictation's Translate uses the plugin's languages while it's on, else English and Japanese")
    func dictationUsesThePluginsPair() {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 26))
        preferences.set(.choice("fr"), of: .translationMyLanguage, for: .translation)
        preferences.set(.choice("de"), of: .translationOtherLanguage, for: .translation)
        #expect(preferences.dictationTranslationPair == .dictationDefault, "Off: as Dictation always did")
        #expect(TranslationLanguagePair.dictationDefault == TranslationLanguagePair(mine: "en", other: "ja"))

        preferences.setCapability(.translation, enabled: true)
        #expect(preferences.dictationTranslationPair == TranslationLanguagePair(mine: "fr", other: "de"))
        #expect(TranslationLanguagePolicy.preferredTargetIdentifier(
            sourceIdentifier: "fr-FR", supportedIdentifiers: ["en", "de", "ja"], pair: preferences.dictationTranslationPair
        ) == "de")

        preferences.setCapability(.translation, enabled: false)
        #expect(preferences.dictationTranslationPair == .dictationDefault)

        let old = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 14))
        old.set(.choice("fr"), of: .translationMyLanguage, for: .translation)
        old.setCapability(.translation, enabled: true)
        #expect(old.dictationTranslationPair == .dictationDefault, "Translation can't be on before macOS 15")
    }
}

@MainActor
@Suite("Translation: the Translate tab")
struct TranslateTabTests {
    static let english = "Please remind me to buy bread and milk this afternoon."
    static let japanese = "今日の午後にパンと牛乳を買うのを思い出させてください。"

    /// Translation on, between English and Japanese, on macOS 26.
    static func preferences(on: Bool = true) -> AppPreferences {
        let preferences = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 26))
        preferences.set(.choice("ja"), of: .translationOtherLanguage, for: .translation)
        preferences.set(.choice("en"), of: .translationMyLanguage, for: .translation)
        preferences.setCapability(.translation, enabled: on)
        return preferences
    }

    static func tab(
        _ translator: FakeTranslator,
        preferences: AppPreferences? = nil,
        wait: @escaping (Duration) async throws -> Void = { _ in }
    ) -> TranslatePaletteContent {
        TranslatePaletteContent(preferences: preferences ?? Self.preferences(), translator: translator, wait: wait)
    }

    @Test("Its manifest: Translation, the Translate tab on ⌘8 with Copy and Paste, Writing, off, macOS 15, an unassigned shortcut")
    func manifest() {
        let descriptor = CapabilityDescriptor.translation
        #expect(descriptor.title == "Translation")
        #expect(descriptor.systemImage == "translate")
        #expect(descriptor.category == .writing)
        #expect(!descriptor.isOnByDefault)
        #expect(descriptor.minimumMacOS == 15)
        #expect(descriptor.requiredPermissions.isEmpty)
        #expect(descriptor.searchKeywords?.contains("translate") == true)
        #expect(descriptor.settingsPage?.section == .translation)
        #expect(descriptor.preferences.map(\.key) == ["myLanguage", "otherLanguage"])
        #expect(descriptor.paletteTab?.tab == .translate)
        #expect(CommandPaletteTab.translate.title == "Translate")
        #expect(CommandPaletteTab.translate.shortcutLabel == "⌘8")
        #expect(CommandPaletteTab.translate.primaryActionTitle == "Copy")
        #expect(CommandPaletteTab.translate.secondaryActionTitle == "Paste")
        #expect(CommandPaletteTab.keyboardShortcutter.shortcutLabel == "⌘9", "Hotkeys moved to stay last")
        #expect(descriptor.shortcuts == [.translation])
        #expect(CapabilityShortcut.translation.title == "Open Translate")
        #expect(CapabilityShortcut.translation.defaultBinding == nil)
        #expect(TranslatePaletteContent.debounce == .milliseconds(300))
    }

    @Test("With nothing typed it says what to type, translates nothing, and Return does nothing")
    func empty() async {
        let translator = FakeTranslator()
        let tab = Self.tab(translator)
        let actions = RecordingActions()
        tab.update(query: "   ")
        await tab.work?.value
        #expect(tab.request == nil)
        #expect(tab.rowCount(query: "   ") == 0)
        #expect(tab.footerActions(row: 0, query: "") == PaletteFooterActions(primary: nil, secondary: nil))
        tab.activate(row: 0, query: "", withCommand: false, palette: actions.actions)
        #expect(actions.copied.isEmpty)
        #expect(translator.calls.isEmpty)
    }

    @Test("Text in my language goes to the other; any other language comes back to mine")
    func translatesBetweenThePair() async {
        let translator = FakeTranslator()
        let tab = Self.tab(translator)

        tab.update(query: Self.english)
        await tab.work?.value
        #expect(translator.calls == [.init(text: Self.english, source: "en", target: "ja")])
        #expect(tab.currentTranslation(query: Self.english) == "[ja] \(Self.english)")
        #expect(tab.rowCount(query: Self.english) == 1)
        #expect(tab.footerActions(row: 0, query: Self.english) == PaletteFooterActions(primary: "Copy", secondary: "Paste"))

        tab.update(query: "  \(Self.japanese)\n")
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.japanese, source: "ja", target: "en"), "Trimmed, and detected")
        #expect(TranslationLanguages.name(for: tab.request?.source ?? "") == "Japanese")
        #expect(TranslationLanguages.name(for: tab.request?.target ?? "") == "English")
    }

    @Test("Return copies the translation, kept out of Clipboard History; ⌘Return pastes it and puts the clipboard back")
    func copiesAndPastes() async {
        let tab = Self.tab(FakeTranslator())
        let actions = RecordingActions()
        tab.update(query: Self.english)
        await tab.work?.value

        tab.activate(row: 0, query: Self.english, withCommand: false, palette: actions.actions)
        #expect(actions.copied == ["[ja] \(Self.english)"])
        tab.activate(row: 0, query: Self.english, withCommand: true, palette: actions.actions)
        #expect(actions.pasted.map(\.text) == ["[ja] \(Self.english)"])
        #expect(actions.pasted.map(\.restoresClipboard) == [true])

        // Typed on since: the translation is of older text, so Return waits for the new one.
        tab.activate(row: 0, query: Self.english + " Thanks", withCommand: false, palette: actions.actions)
        #expect(actions.copied.count == 1)
        #expect(tab.rowCount(query: Self.english + " Thanks") == 0)
    }

    @Test("It waits 300 ms after the last keystroke, and translates only the latest text")
    func debounces() async {
        let translator = FakeTranslator()
        var waits: [Duration] = []
        let tab = Self.tab(translator) { duration in
            waits.append(duration)
            try await Task.sleep(for: .milliseconds(50))
        }
        tab.update(query: "Good")
        tab.update(query: "Good morning")
        tab.update(query: "Good morning, everyone")
        await tab.work?.value
        #expect(translator.calls.map(\.text) == ["Good morning, everyone"])
        #expect(waits == [TranslatePaletteContent.debounce, TranslatePaletteContent.debounce, TranslatePaletteContent.debounce])

        // The same text again keeps its translation.
        tab.update(query: "Good morning, everyone ")
        await tab.work?.value
        #expect(translator.calls.count == 1)
    }

    @Test("A translation that comes back after newer text was typed is dropped")
    func dropsStaleResults() async {
        let translator = FakeTranslator(waits: true)
        let tab = Self.tab(translator)

        tab.update(query: "First text to translate")
        let first = tab.work
        await translator.untilCalled(1)
        tab.update(query: "Second text to translate")
        let second = tab.work
        await translator.untilCalled(2)

        translator.resolve(1, with: "second")
        await second?.value
        translator.resolve(0, with: "first, late")
        await first?.value

        #expect(tab.request?.text == "Second text to translate")
        #expect(tab.currentTranslation(query: "Second text to translate") == "second")
        #expect(tab.translation?.text == "second")
        #expect(!tab.isTranslating)
    }

    @Test("It holds the palette open while a translation runs, through a download prompt, and lets go when it ends or stops")
    func holdsThePaletteOpen() async {
        let translator = FakeTranslator(waits: true)
        let tab = Self.tab(translator)
        var holds: [Bool] = []
        tab.holdPaletteOpen = { holds.append($0) }

        tab.update(query: Self.english)
        await translator.untilCalled(1)
        #expect(holds == [true])
        #expect(tab.isTranslating)
        translator.resolve(0, with: "done")
        await tab.work?.value
        #expect(holds == [true, false])

        tab.update(query: Self.japanese)
        let running = tab.work
        await translator.untilCalled(2)
        tab.stop()
        #expect(holds == [true, false, true, false], "The palette closed")
        #expect(!tab.isTranslating)
        translator.resolve(1, with: "late")
        await running?.value
        #expect(tab.currentTranslation(query: Self.japanese) == nil, "A stopped translation is dropped")
    }

    @Test("A pair Translation can't do, or one not downloaded, says so; the tab offers Language & Region and tries again when it shows again")
    func failures() async {
        let translator = FakeTranslator()
        let tab = Self.tab(translator)

        translator.failure = .unsupportedPair
        tab.update(query: Self.english)
        await tab.work?.value
        #expect(tab.failure == "Can’t translate English into Japanese on this Mac.")
        #expect(tab.rowCount(query: Self.english) == 0)
        #expect(tab.footerActions(row: 0, query: Self.english) == PaletteFooterActions(primary: nil, secondary: nil))

        #expect(!tab.needsDownload)

        translator.failure = .notDownloaded
        tab.update(query: "Another sentence in English, please.")
        await tab.work?.value
        #expect(tab.failure == "Download English and Japanese in System Settings › General › Language & Region › Translation Languages, then try again.")
        #expect(tab.needsDownload)
        var opened = 0
        tab.openLanguageSettings = { opened += 1 }
        tab.openLanguageSettings()
        #expect(opened == 1)
        tab.update(query: "And one more sentence in English.")
        await tab.work?.value
        #expect(translator.calls.count == 3, "Each new text checks again; nothing shows a download prompt")
        #expect(tab.needsDownload)

        let actions = RecordingActions()
        tab.didShow(palette: actions.actions)
        #expect(tab.request == nil && tab.failure == nil)
        translator.failure = nil
        tab.update(query: "And one more sentence in English.")
        await tab.work?.value
        #expect(translator.calls.count == 4)
        #expect(tab.currentTranslation(query: "And one more sentence in English.") != nil)
        #expect(!tab.needsDownload)

        translator.failure = .failed
        tab.update(query: Self.japanese)
        await tab.work?.value
        #expect(tab.failure == "Translation couldn’t be completed.")
    }

    @Test("Off, or on a Mac before macOS 15, it translates nothing and says why")
    func unavailable() async {
        let translator = FakeTranslator()
        let off = Self.tab(translator, preferences: Self.preferences(on: false))
        off.update(query: Self.english)
        await off.work?.value
        #expect(off.unavailableReason == "Translation is turned off. Turn it on in Settings › Plugins.")
        #expect(translator.calls.isEmpty)

        let old = TranslatePaletteContent(
            preferences: AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 14)),
            translator: nil
        )
        #expect(old.unavailableReason == "Translation requires macOS 15 or later")
        #expect(Self.tab(translator).unavailableReason == nil)
    }

    @Test("Unit tests get the inert translator, which translates nothing")
    func inertUnderTests() async {
        let translator = TextTranslatorFactory.makeDefault()
        #expect(translator is InertTextTranslator)
        await #expect(throws: TranslateFailure.failed) {
            try await InertTextTranslator().translate("Hello", from: "en", to: "ja")
        }
    }
}

@MainActor
@Suite("Translation: swapping and picking the other language")
struct TranslateTabLanguageTests {
    static let english = TranslateTabTests.english
    static let japanese = TranslateTabTests.japanese
    static let otherEnglish = "Could you send me the notes from this morning's meeting?"

    typealias Request = TranslatePaletteContent.Request

    @Test("Swapping translates the same text the other way at once, and again goes back; the next text is detected again")
    func swaps() async {
        let translator = FakeTranslator()
        var waits = 0
        let tab = TranslateTabTests.tab(translator) { _ in waits += 1 }
        tab.update(query: Self.english)
        await tab.work?.value
        #expect(translator.calls == [.init(text: Self.english, source: "en", target: "ja")])
        #expect(tab.canChangeLanguages(query: Self.english))

        tab.swapLanguages(query: Self.english)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.english, source: "ja", target: "en"))
        #expect(waits == 1, "No debounce: it translates again right away")
        #expect(tab.request == Request(text: Self.english, source: "ja", target: "en"))
        #expect(tab.currentTranslation(query: Self.english) == "[en] \(Self.english)")
        #expect(tab.rowCount(query: Self.english) == 1)

        // The same text, typed with a space after it, keeps the swap.
        tab.update(query: Self.english + " ")
        await tab.work?.value
        #expect(translator.calls.count == 2)
        #expect(tab.request?.source == "ja")

        tab.swapLanguages(query: Self.english)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.english, source: "en", target: "ja"), "Swapped back")
        tab.swapLanguages(query: Self.english)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.english, source: "ja", target: "en"))

        // Other text is detected again, and so is the first text when it comes back.
        tab.update(query: Self.otherEnglish)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.otherEnglish, source: "en", target: "ja"))
        tab.update(query: Self.english)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.english, source: "en", target: "ja"))
    }

    @Test("Swapping waits for the text in the field to be asked for, and works after a failure too")
    func swapNeedsTheCurrentText() async {
        let translator = FakeTranslator()
        let tab = TranslateTabTests.tab(translator)
        tab.swapLanguages(query: Self.english)
        #expect(tab.work == nil)
        #expect(!tab.canChangeLanguages(query: ""))

        tab.update(query: Self.english)
        await tab.work?.value
        // Typed on since; the header still names the earlier text's languages.
        #expect(!tab.canChangeLanguages(query: Self.otherEnglish))
        tab.swapLanguages(query: Self.otherEnglish)
        #expect(tab.targetChoices(query: Self.otherEnglish).isEmpty)
        #expect(translator.calls.count == 1)

        translator.failure = .unsupportedPair
        tab.update(query: Self.otherEnglish)
        await tab.work?.value
        #expect(tab.failure == "Can’t translate English into Japanese on this Mac.")
        translator.failure = nil
        tab.swapLanguages(query: Self.otherEnglish)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.otherEnglish, source: "ja", target: "en"))
        #expect(tab.failure == nil)
        #expect(tab.currentTranslation(query: Self.otherEnglish) == "[en] \(Self.otherEnglish)")
    }

    @Test("⌘T swaps in the Translate tab, even with Caps Lock; elsewhere it's not the palette's")
    func commandTSwaps() async {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette

        palette.selectOnOpening(.translate)
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_T, "t")) == nil, "Nothing to swap yet, but it's the tab's")
        #expect(fixture.translator.calls.isEmpty)

        palette.state.historyQuery = Self.english
        fixture.tab.update(query: Self.english)
        await fixture.tab.work?.value
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_T, "t")) == nil)
        await fixture.tab.work?.value
        #expect(fixture.translator.calls.last == .init(text: Self.english, source: "ja", target: "en"))
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_T, "T", modifiers: [.command, .capsLock])) == nil)
        await fixture.tab.work?.value
        #expect(fixture.translator.calls.last == .init(text: Self.english, source: "en", target: "ja"))
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_T, "t", modifiers: [.command, .shift])) != nil, "⇧⌘T isn't it")
        #expect(fixture.translator.calls.count == 3)

        for tab in [CommandPaletteTab.search, .clipboard, .snippets] {
            palette.selectOnOpening(tab)
            palette.state.historyQuery = Self.english
            #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_T, "t")) != nil, "\(tab) passes ⌘T on")
        }
        #expect(fixture.translator.calls.count == 3)
    }

    @Test("Holding ⌘T down swaps once: its repeats are still the tab's, but do nothing")
    func heldCommandTSwapsOnce() async {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        palette.selectOnOpening(.translate)
        palette.state.historyQuery = Self.english
        fixture.tab.update(query: Self.english)
        await fixture.tab.work?.value

        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_T, "t")) == nil)
        await fixture.tab.work?.value
        for _ in 0..<5 {
            #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_T, "t", isARepeat: true)) == nil)
            await fixture.tab.work?.value
        }
        #expect(fixture.translator.calls.count == 2)
        #expect(fixture.tab.request?.source == "ja", "Swapped once")
    }

    @Test("In the Translate tab, the palette's own keys still work: ⌘Return pastes, ⌘2 and ⌘8 switch tabs, ⌘, opens Settings")
    func paletteKeysStillWork() async {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        var offered: [Capability] = []
        var opened: [SettingsSection?] = []
        palette.offerPasteSetup = { offered.append($0) }
        palette.openSettings = { opened.append($0) }
        palette.frontmostApp = { PasteTarget(processIdentifier: 4242, isKeybumps: false) }
        palette.selectOnOpening(.translate)
        palette.rememberPasteTarget()
        palette.state.historyQuery = Self.english
        fixture.tab.update(query: Self.english)
        await fixture.tab.work?.value

        // Without Accessibility, ⌘Return's paste copies instead and offers setup for Translation.
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_Return, "\r")) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "[ja] \(Self.english)")
        #expect(offered == [.translation], "⌘Return went to the paste")
        #expect(fixture.translator.calls.count == 1, "Nothing swapped")

        palette.selectOnOpening(.translate)
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_2, "2")) == nil)
        #expect(palette.state.tab == .clipboard)
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_8, "8")) == nil)
        #expect(palette.state.tab == .translate)
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_Comma, ",")) == nil)
        #expect(opened == [nil])
    }

    @Test("The palette allows tooltips while Keybumps isn't the active app, so the swap button's ⌘T hint shows")
    func paletteShowsTooltips() throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let panel = try #require(fixture.palette.layOutForTesting(.translate))
        defer { panel.orderOut(nil) }
        #expect(panel.allowsToolTipsWhenApplicationIsInactive)
    }

    @Test("Picking a target for text in my language saves it as Other language and translates again at once")
    func pickingSavesOtherLanguage() async {
        let translator = FakeTranslator()
        let preferences = TranslateTabTests.preferences()
        var waits = 0
        let tab = TranslateTabTests.tab(translator, preferences: preferences) { _ in waits += 1 }
        tab.update(query: Self.english)
        await tab.work?.value

        let choices = tab.targetChoices(query: Self.english).map(\.code)
        #expect(choices == TranslationLanguages.offered.map(\.code).filter { $0 != "en" }, "Every language but the source")

        tab.chooseTarget("es", query: Self.english)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.english, source: "en", target: "es"))
        #expect(waits == 1, "No debounce")
        #expect(tab.currentTranslation(query: Self.english) == "[es] \(Self.english)")
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "es"))
        #expect(preferences.choice(.translationOtherLanguage, for: .translation) == "es", "The same setting as Settings' menu")

        // From then on, English goes to Spanish.
        tab.update(query: Self.otherEnglish)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.otherEnglish, source: "en", target: "es"))

        // The source, the current target, a language Translation doesn't offer, or earlier text: nothing.
        let count = translator.calls.count
        tab.chooseTarget("en", query: Self.otherEnglish)
        tab.chooseTarget("es", query: Self.otherEnglish)
        tab.chooseTarget("sv", query: Self.otherEnglish)
        tab.chooseTarget("fr", query: Self.english)
        #expect(translator.calls.count == count)
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "es"))
    }

    @Test("Picking a target for text in another language is for that text only; My language and Other language stay")
    func pickingForOtherTextIsOneOff() async {
        let translator = FakeTranslator()
        let preferences = TranslateTabTests.preferences()
        let tab = TranslateTabTests.tab(translator, preferences: preferences)
        tab.update(query: Self.japanese)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.japanese, source: "ja", target: "en"))
        #expect(!tab.targetChoices(query: Self.japanese).map(\.code).contains("ja"))

        tab.chooseTarget("fr", query: Self.japanese)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.japanese, source: "ja", target: "fr"))
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "ja"))

        // A swap after picking goes between the picked two.
        tab.swapLanguages(query: Self.japanese)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.japanese, source: "fr", target: "ja"))

        tab.update(query: Self.english)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.english, source: "en", target: "ja"))
    }

    @Test("After a swap, a pick is for that text only, even when the swapped source is my language")
    func pickingAfterASwapIsOneOff() async {
        let translator = FakeTranslator()
        let preferences = TranslateTabTests.preferences()
        let tab = TranslateTabTests.tab(translator, preferences: preferences)

        // Japanese text, swapped to read as English: English isn't what it's written in.
        tab.update(query: Self.japanese)
        await tab.work?.value
        tab.swapLanguages(query: Self.japanese)
        await tab.work?.value
        #expect(tab.request == Request(text: Self.japanese, source: "en", target: "ja"))
        tab.chooseTarget("es", query: Self.japanese)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.japanese, source: "en", target: "es"))
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "ja"))

        // English text swapped to read as Japanese: a pick is one-off too.
        tab.update(query: Self.english)
        await tab.work?.value
        tab.swapLanguages(query: Self.english)
        await tab.work?.value
        tab.chooseTarget("fr", query: Self.english)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.english, source: "ja", target: "fr"))
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "ja"))

        // The next English text is detected again, so a pick for it saves.
        tab.update(query: Self.otherEnglish)
        await tab.work?.value
        tab.chooseTarget("de", query: Self.otherEnglish)
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.otherEnglish, source: "en", target: "de"))
        #expect(preferences.translationLanguagePair == TranslationLanguagePair(mine: "en", other: "de"))
    }
}

// MARK: - Fakes

/// Translates by tagging the text with its target, at once, or, with `waits`, when the test resolves
/// each call. It ignores cancellation, as a slow translation might.
@MainActor
final class FakeTranslator: TextTranslating {
    struct Call: Equatable {
        let text: String
        let source: String
        let target: String
    }

    private(set) var calls: [Call] = []
    var failure: TranslateFailure?
    private let waits: Bool
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]

    init(waits: Bool = false) {
        self.waits = waits
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        calls.append(Call(text: text, source: source, target: target))
        if let failure { throw failure }
        guard waits else { return "[\(target)] \(text)" }
        let index = calls.count - 1
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func resolve(_ index: Int, with text: String) {
        pending.removeValue(forKey: index)?.resume(returning: text)
    }

    /// Lets the tab's work run until it has asked `count` times (a call is waiting as soon as it's
    /// made).
    func untilCalled(_ count: Int) async {
        var turns = 0
        while calls.count < count, turns < 10_000 {
            await Task.yield()
            turns += 1
        }
    }
}

@MainActor
private final class RecordingActions {
    private(set) var copied: [String] = []
    private(set) var pasted: [(text: String, restoresClipboard: Bool)] = []

    var actions: PaletteContentActions {
        PaletteContentActions(
            dismiss: {},
            selectRow: { _ in },
            clearQuery: {},
            copy: { [weak self] in self?.copied.append($0) },
            paste: { [weak self] text, restores in self?.pasted.append((text, restores)) }
        )
    }
}

/// A palette over a temporary folder and a named pasteboard, never shown, whose Translate tab
/// translates with `FakeTranslator`.
@MainActor
private final class TranslatePaletteFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsTranslateTab-\(UUID().uuidString)"))
    let translator = FakeTranslator()
    let tab: TranslatePaletteContent
    let palette: CommandPaletteController

    init() {
        let root = folder.url
        let dictationHistory = DictationHistoryService(
            recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)
        )
        let preferences = TranslateTabTests.preferences()
        palette = CommandPaletteController(
            clipboard: ClipboardHistoryService(
                storageURL: root.appendingPathComponent("clipboard-history.json"),
                pasteboard: pasteboard,
                mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
                sourceApps: .inert
            ),
            dictationHistory: dictationHistory,
            dictationService: DictationService(
                language: "en-US",
                history: dictationHistory,
                paster: InertTextPaster(),
                allowsSystemAccess: false
            ),
            preferences: preferences,
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: SilentTranslateNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
        tab = TranslatePaletteContent(preferences: preferences, translator: translator, wait: { _ in })
        palette.tabContents = [.translate: tab]
    }

    func commandKey(
        _ keyCode: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = .command, isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: UInt16(keyCode)
        )!
    }

    func tearDown() {
        tab.stop()
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

@MainActor
private final class SilentTranslateNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
