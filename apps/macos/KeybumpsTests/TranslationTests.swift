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

    /// Its recent translations are kept in memory, and it reads aloud with `speaker` (a fake that
    /// never makes a sound).
    static func tab(
        _ translator: FakeTranslator,
        preferences: AppPreferences? = nil,
        recents: RecentTranslations? = nil,
        speaker: (any TranslationSpeaking)? = nil,
        wait: @escaping (Duration) async throws -> Void = { _ in }
    ) -> TranslatePaletteContent {
        TranslatePaletteContent(
            preferences: preferences ?? Self.preferences(),
            translator: translator,
            recents: recents ?? RecentTranslations(storageURL: nil),
            speaker: speaker ?? FakeTranslationSpeaker(),
            wait: wait
        )
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
        #expect(CommandPaletteTab.translate.secondaryActions == [.paste()])
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
        #expect(tab.footerActions(row: 0, query: "") == PaletteFooterActions(primary: nil))
        tab.activate(row: 0, query: "", palette: actions.actions)
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
        #expect(tab.footerActions(row: 0, query: Self.english) == PaletteFooterActions(primary: "Save", secondary: [.paste("Save and Paste")]))

        tab.update(query: "  \(Self.japanese)\n")
        await tab.work?.value
        #expect(translator.calls.last == .init(text: Self.japanese, source: "ja", target: "en"), "Trimmed, and detected")
        #expect(TranslationLanguages.name(for: tab.request?.source ?? "") == "Japanese")
        #expect(TranslationLanguages.name(for: tab.request?.target ?? "") == "English")
    }

    @Test("Return saves the translation and copies nothing; the field clears, and it's at the top of the list, highlighted")
    func returnSaves() async throws {
        let recents = RecentTranslations(storageURL: nil)
        let tab = Self.tab(FakeTranslator(), recents: recents)
        let actions = RecordingActions()
        tab.update(query: Self.english)
        await tab.work?.value

        tab.activate(row: 0, query: Self.english, palette: actions.actions)
        #expect(actions.copied.isEmpty && actions.pasted.isEmpty, "Saving does nothing else")
        #expect(actions.cleared == 1)
        #expect(actions.selected == [0])
        let record = try #require(recents.records.first)
        #expect(recents.records.count == 1)
        #expect(record.sourceText == Self.english)
        #expect(record.translatedText == "[ja] \(Self.english)")
        #expect(record.sourceLanguage == "en" && record.targetLanguage == "ja")
        #expect(tab.rowCount(query: "") == 1, "With the field empty, the tab lists it")
        #expect(tab.record(row: 0, query: "") == record)
        #expect(tab.footerActions(row: 0, query: "") == PaletteFooterActions(primary: "Copy", secondary: [.paste()]))

        // Typed on since: the translation is of older text, so Return waits for the new one.
        tab.activate(row: 0, query: Self.english + " Thanks", palette: actions.actions)
        #expect(recents.records.count == 1)
        #expect(tab.rowCount(query: Self.english + " Thanks") == 0)
    }

    @Test("⌘P saves the translation too, then pastes it and puts the clipboard back; ⌘C and Space leave it alone (#370)")
    func commandPSavesAndPastes() async {
        let recents = RecentTranslations(storageURL: nil)
        let tab = Self.tab(FakeTranslator(), recents: recents)
        let actions = RecordingActions()
        tab.update(query: Self.japanese)
        await tab.work?.value

        tab.copy(row: 0, query: Self.japanese, palette: actions.actions)
        #expect(actions.copied.isEmpty && recents.records.isEmpty, "Only saved translations copy")
        #expect(tab.playback(row: 0, query: Self.japanese) == nil, "Nothing to read aloud until it's saved")

        tab.paste(row: 0, query: Self.japanese, palette: actions.actions)
        #expect(actions.pasted.map(\.text) == ["[en] \(Self.japanese)"])
        #expect(actions.pasted.map(\.restoresClipboard) == [true])
        #expect(actions.copied.isEmpty)
        #expect(actions.cleared == 0, "Pasting leaves the field to the closing palette")
        #expect(recents.records.map(\.translatedText) == ["[en] \(Self.japanese)"])
        #expect(recents.records.first?.sourceLanguage == "ja" && recents.records.first?.targetLanguage == "en")
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
        #expect(tab.footerActions(row: 0, query: Self.english) == PaletteFooterActions(primary: nil))

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
            translator: nil,
            recents: RecentTranslations(storageURL: nil),
            speaker: FakeTranslationSpeaker()
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

    @Test("In the Translate tab, the palette's own keys still work: ⌘P pastes, ⌘2 and ⌘8 switch tabs, ⌘, opens Settings")
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

        // Without Accessibility, ⌘P's paste copies instead and offers setup for Translation.
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_P, "p")) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "[ja] \(Self.english)")
        #expect(offered == [.translation], "⌘P went to the paste")
        #expect(fixture.recents.records.map(\.translatedText) == ["[ja] \(Self.english)"], "and saved it")
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

@MainActor
@Suite("Translation: recent translations")
struct RecentTranslationTests {
    static let english = TranslateTabTests.english

    @Test("Saving the same text between the same languages again moves its record to the top, with the newer translation")
    func savingAgainMovesToTheTop() {
        var now = Date(timeIntervalSince1970: 1_000)
        let recents = RecentTranslations(storageURL: nil, now: { now })
        let hello = recents.save("Hello", translated: "こんにちは", from: "en", to: "ja")
        now += 60
        recents.save("Thanks", translated: "ありがとう", from: "en", to: "ja")
        now += 60
        let again = recents.save("Hello", translated: "こんにちは!", from: "en", to: "ja")

        #expect(recents.records.map(\.sourceText) == ["Hello", "Thanks"], "Moved, not added again")
        #expect(again.id == hello.id)
        #expect(again.translatedText == "こんにちは!")
        #expect(again.savedAt == Date(timeIntervalSince1970: 1_120))

        // Into another language, it's another record. Languages are kept by their pair code.
        recents.save("Hello", translated: "你好", from: "en-US", to: "zh-TW")
        #expect(recents.records.map(\.targetLanguage) == ["zh-Hant", "ja", "ja"])
        #expect(recents.records.first?.sourceLanguage == "en")
    }

    @Test("It keeps the last 50: the 51st drops the oldest")
    func keepsTheLastFifty() {
        let recents = RecentTranslations(storageURL: nil)
        for index in 1...51 {
            recents.save("Text \(index)", translated: "Texte \(index)", from: "en", to: "fr")
        }
        #expect(RecentTranslations.limit == 50)
        #expect(recents.records.count == 50)
        #expect(recents.records.first?.sourceText == "Text 51")
        #expect(recents.records.last?.sourceText == "Text 2")
    }

    @Test("They're kept in a file only the owner can read: read back as saved; a corrupt file is none; Clear empties it")
    func storage() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent(RecentTranslations.fileName)
        let recents = RecentTranslations(storageURL: url)
        #expect(recents.records.isEmpty, "No file yet")
        recents.save("Hello", translated: "こんにちは", from: "en", to: "ja")
        recents.save("Good night", translated: "Bonne nuit", from: "en", to: "fr")

        let reread = RecentTranslations(storageURL: url)
        #expect(reread.records == recents.records)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        reread.delete(reread.records[0].id)
        #expect(RecentTranslations(storageURL: url).records.map(\.sourceText) == ["Hello"])

        try Data("not json".utf8).write(to: url)
        let corrupt = RecentTranslations(storageURL: url)
        #expect(corrupt.records.isEmpty)
        corrupt.save("Hello", translated: "Hallo", from: "en", to: "de")
        #expect(RecentTranslations(storageURL: url).records.map(\.translatedText) == ["Hallo"], "Saving starts the file again")

        corrupt.clear()
        #expect(corrupt.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(RecentTranslations(storageURL: url).records.isEmpty)
    }

    @Test("When the file can't be removed, Clear empties it, so cleared translations don't come back")
    func clearWhenTheFileStays() {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appendingPathComponent(RecentTranslations.fileName)
        let recents = RecentTranslations(storageURL: url, fileManager: UnremovableFileManager())
        recents.save("Hello", translated: "こんにちは", from: "en", to: "ja")

        recents.clear()
        #expect(recents.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path), "Removing it failed")
        #expect(RecentTranslations(storageURL: url).records.isEmpty, "The next launch reads none")
    }

    @Test("Return saves nothing after a failure, or while a swap's translation is on its way; then it saves the languages the header shows")
    func savesAfterASwapOnlyOnceItsBack() async throws {
        let translator = FakeTranslator(waits: true)
        let recents = RecentTranslations(storageURL: nil)
        let tab = TranslateTabTests.tab(translator, recents: recents)
        let actions = RecordingActions()

        translator.failure = .unsupportedPair
        tab.update(query: Self.english)
        await tab.work?.value
        #expect(tab.failure != nil)
        tab.activate(row: 0, query: Self.english, palette: actions.actions)
        tab.paste(row: 0, query: Self.english, palette: actions.actions)
        #expect(recents.records.isEmpty)
        #expect(actions.cleared == 0 && actions.pasted.isEmpty)

        translator.failure = nil
        tab.swapLanguages(query: Self.english)
        await translator.untilCalled(2)
        #expect(tab.request == TranslatePaletteContent.Request(text: Self.english, source: "ja", target: "en"))
        tab.activate(row: 0, query: Self.english, palette: actions.actions)
        tab.paste(row: 0, query: Self.english, palette: actions.actions)
        #expect(recents.records.isEmpty, "Its translation isn't back yet")

        translator.resolve(1, with: "swapped")
        await tab.work?.value
        tab.activate(row: 0, query: Self.english, palette: actions.actions)
        let record = try #require(recents.records.first)
        #expect(record.translatedText == "swapped")
        #expect(record.sourceLanguage == "ja" && record.targetLanguage == "en", "Japanese → English, as the header showed")
    }

    @Test("Return saves nothing while a picked language's translation is on its way; then it saves that language")
    func savesAfterAPickOnlyOnceItsBack() async throws {
        let translator = FakeTranslator(waits: true)
        let recents = RecentTranslations(storageURL: nil)
        let tab = TranslateTabTests.tab(translator, recents: recents)
        let actions = RecordingActions()
        tab.update(query: Self.english)
        await translator.untilCalled(1)
        translator.resolve(0, with: "into Japanese")
        await tab.work?.value

        tab.chooseTarget("es", query: Self.english)
        await translator.untilCalled(2)
        tab.activate(row: 0, query: Self.english, palette: actions.actions)
        tab.paste(row: 0, query: Self.english, palette: actions.actions)
        #expect(recents.records.isEmpty, "Not the Japanese one, which the header no longer shows")

        translator.resolve(1, with: "into Spanish")
        await tab.work?.value
        tab.activate(row: 0, query: Self.english, palette: actions.actions)
        let record = try #require(recents.records.first)
        #expect(recents.records.count == 1)
        #expect(record.translatedText == "into Spanish")
        #expect(record.sourceLanguage == "en" && record.targetLanguage == "es", "English → Spanish, as the header showed")
    }

    @Test("While an input method is composing, Return commits its candidate in the field: nothing's saved or cleared")
    func returnWhileComposing() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        let panel = try #require(palette.layOutForTesting(.translate))
        defer { panel.orderOut(nil) }
        palette.state.historyQuery = Self.english
        fixture.tab.update(query: Self.english)
        await fixture.tab.work?.value
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        let field = try #require(Self.searchField(in: panel.contentView))
        #expect(panel.makeFirstResponder(field))
        let editor = try #require(panel.firstResponder as? NSTextView)

        editor.setMarkedText("きょう", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(fixture.tab.rowCount(query: palette.state.historyQuery) == 1, "Without the guard, Return would save it")
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) != nil, "Return goes to the input method")
        #expect(fixture.recents.records.isEmpty)

        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        palette.state.historyQuery = Self.english
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) == nil, "Once committed, Return is the palette's")
        #expect(fixture.recents.records.map(\.sourceText) == [Self.english])
    }

    @Test("Part of the translation selected with the pointer: ⌘C is Edit › Copy's, as before #370")
    func pointerSelectionInTheTranslation() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        let panel = try #require(palette.layOutForTesting(.translate))
        defer { panel.orderOut(nil) }
        palette.state.historyQuery = Self.english
        fixture.tab.update(query: Self.english)
        await fixture.tab.work?.value
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()

        // Some macOS versions (26 on CI) build SwiftUI's selectable text only on a real click;
        // `PaletteCopyPasteKeyTests.pointerSelectionInAStandIn` covers the decision there.
        guard let translation = PaletteCopyPasteKeyTests.selectableText(in: panel.contentView) else { return }
        #expect(panel.makeFirstResponder(translation))
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_C, "c")) == nil, "Nothing selected, and the translation being typed doesn't copy")
        translation.perform(#selector(NSResponder.selectAll(_:)), with: nil)
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_C, "c")) != nil, "Selected text is Edit › Copy's")
        #expect(fixture.pasteboard.string(forType: .string) == nil)
        #expect(fixture.recents.records.isEmpty)
    }

    @Test("Opening the palette again by its shortcut while \"Delete this translation?\" shows drops the question and gives the palette its keys back")
    func reopeningDropsTheQuestion() {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        fixture.recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        palette.selectOnOpening(.translate)
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_Delete, "\u{8}")) == nil)
        #expect(palette.state.contentPendingDeletion != nil)
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) != nil, "The alert has the keys")

        palette.selectOnOpening(.translate)
        #expect(palette.state.contentPendingDeletion == nil)
        #expect(fixture.recents.records.count == 2, "Nothing deleted")
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) == nil, "The palette has its keys back")
        #expect(fixture.pasteboard.string(forType: .string) == "Merci", "Return copied the first row")
    }

    /// The palette's search field, as `CommandPaletteController` finds it to focus it.
    static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    @Test("Return on the translation, in the palette: saved, the field clears, it's highlighted at the top, and nothing's copied")
    func returnInThePalette() async {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        palette.selectOnOpening(.translate)
        palette.state.historyQuery = Self.english
        fixture.tab.update(query: Self.english)
        await fixture.tab.work?.value
        #expect(palette.state.selection == 0)

        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) == nil)
        #expect(palette.state.historyQuery.isEmpty)
        #expect(palette.state.selection == 0)
        #expect(fixture.recents.records.map(\.sourceText) == [Self.english, "Good night"])
        #expect(fixture.tab.record(row: 0, query: "")?.sourceText == Self.english)
        #expect(fixture.pasteboard.string(forType: .string) == nil, "Nothing copied")
    }

    @Test("On a saved translation, Return and ⌘C copy it, kept out of Clipboard History, ⌘P pastes it, and ⌘Return only copies")
    func rowsCopyAndPaste() {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        var offered: [Capability] = []
        palette.offerPasteSetup = { offered.append($0) }
        palette.frontmostApp = { PasteTarget(processIdentifier: 4242, isKeybumps: false) }
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        fixture.recents.save("Thank you", translated: "Merci", from: "en", to: "fr")

        palette.selectOnOpening(.translate)
        palette.state.selection = 1
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "おやすみ")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty, "Kept out of Clipboard History")

        palette.selectOnOpening(.translate)
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_C, "c")) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "Merci")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty, "Kept out of Clipboard History")

        palette.selectOnOpening(.translate)
        palette.state.selection = 1
        palette.rememberPasteTarget()
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_Return, "\r")) == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "おやすみ")
        #expect(offered.isEmpty, "⌘Return copied, as Return does; it doesn't paste")

        palette.selectOnOpening(.translate)
        palette.rememberPasteTarget()
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_P, "p")) == nil)
        // Without Accessibility, the paste copies instead and offers setup.
        #expect(fixture.pasteboard.string(forType: .string) == "Merci")
        #expect(offered == [.translation])
        #expect(fixture.recents.records.map(\.sourceText) == ["Thank you", "Good night"], "Nothing saved or moved")
    }

    @Test("Space reads the highlighted saved translation aloud and stops it, only while the search field is empty")
    func spaceReadsAloud() async {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        let japanese = fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        fixture.recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        palette.selectOnOpening(.translate)
        palette.state.selection = 1
        #expect(fixture.tab.playback(row: 1, query: "")?.title == "Read Aloud")

        #expect(palette.handleKeyDown(fixture.key(kVK_Space, " ")) == nil)
        await fixture.tab.reading?.value
        #expect(fixture.speaker.readings == [.init(text: "おやすみ", language: "ja")])
        #expect(fixture.tab.isReading(japanese.id))
        #expect(fixture.tab.playback(row: 1, query: "")?.title == "Stop Reading")

        #expect(palette.handleKeyDown(fixture.key(kVK_Space, " ")) == nil)
        #expect(!fixture.tab.isReading(japanese.id), "Space again stops it")
        #expect(fixture.speaker.stops == 1)

        palette.state.historyQuery = "Good"
        #expect(palette.handleKeyDown(fixture.key(kVK_Space, " ")) != nil, "With text in the field, Space types")
        #expect(fixture.speaker.readings.count == 1)
    }

    @Test("Delete on a saved translation asks first: Cancel keeps it, and the alert's Delete deletes the one asked about")
    func deleteAsksFirst() throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        fixture.recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        palette.selectOnOpening(.translate)

        #expect(palette.handleKeyDown(fixture.commandKey(kVK_Delete, "\u{8}")) == nil)
        let asked = try #require(palette.state.contentPendingDeletion)
        #expect(asked.title == "Delete this translation?")
        #expect(asked.message == "It will be removed from this Mac.")
        #expect(fixture.recents.records.count == 2, "Nothing deleted yet")
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) != nil, "The alert has the keys")

        // Cancel.
        palette.contentDeletionDidClose()
        #expect(palette.state.contentPendingDeletion == nil)
        #expect(fixture.recents.records.count == 2)

        // Delete alone asks too, with the field empty. A hover moving the highlight meanwhile
        // doesn't change which one goes.
        palette.state.selection = 1
        #expect(palette.handleKeyDown(fixture.key(kVK_Delete, "\u{8}")) == nil)
        let confirmation = try #require(palette.state.contentPendingDeletion)
        palette.state.selection = 0
        palette.confirmContentDeletion(confirmation)
        palette.contentDeletionDidClose()
        #expect(fixture.recents.records.map(\.sourceText) == ["Thank you"])
        #expect(palette.state.selection == 0)

        // With text in the field, ⌘Delete is the field's.
        palette.state.historyQuery = "Hello"
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_Delete, "\u{8}")) != nil)
        #expect(palette.state.contentPendingDeletion == nil)
    }

    @Test("Typing goes back to the first row; the list shows only while the field is empty")
    func typingGoesToTheFirstRow() {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        for text in ["One", "Two", "Three"] {
            fixture.recents.save(text, translated: "[ja] \(text)", from: "en", to: "ja")
        }
        palette.selectOnOpening(.translate)
        #expect(fixture.tab.rowCount(query: "") == 3)
        palette.state.selection = 2
        palette.state.historyQuery = "Hel"
        #expect(palette.state.selection == 0)
        #expect(fixture.tab.rowCount(query: "Hel") == 0, "Its translation isn't back yet")
        #expect(fixture.tab.record(row: 0, query: "Hel") == nil)
        #expect(fixture.tab.deletionConfirmation(row: 0, query: "Hel") == nil)
    }
}

@MainActor
@Suite("Translation: reading saved translations aloud")
struct TranslationReadAloudTests {
    @Test("A row reads its translation in a voice for its target language; its button, again, stops it")
    func readsInTheTargetLanguage() async {
        let speaker = FakeTranslationSpeaker()
        let recents = RecentTranslations(storageURL: nil)
        let french = recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        let japanese = recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let tab = TranslateTabTests.tab(FakeTranslator(), recents: recents, speaker: speaker)

        tab.readAloud(japanese.id)
        await tab.reading?.value
        #expect(speaker.readings == [.init(text: "おやすみ", language: "ja")])
        #expect(tab.isReading(japanese.id))
        #expect(!tab.isReading(french.id))

        tab.readAloud(japanese.id)
        #expect(speaker.stops == 1)
        #expect(!tab.isReading(japanese.id))
        #expect(speaker.readings.count == 1)
    }

    @Test("Reading another row stops the first")
    func anotherRowStopsTheFirst() async {
        let speaker = FakeTranslationSpeaker()
        let recents = RecentTranslations(storageURL: nil)
        let french = recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        let japanese = recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let tab = TranslateTabTests.tab(FakeTranslator(), recents: recents, speaker: speaker)

        tab.readAloud(japanese.id)
        await tab.reading?.value
        tab.readAloud(french.id)
        await tab.reading?.value
        #expect(speaker.stops == 1)
        #expect(speaker.readings.map(\.language) == ["ja", "fr"])
        #expect(tab.isReading(french.id))
        #expect(!tab.isReading(japanese.id))
    }

    @Test("With no voice for the language, the row says so, and nothing's read in another language's voice")
    func noVoice() async {
        let speaker = FakeTranslationSpeaker()
        speaker.languagesWithoutVoice = ["ja"]
        let recents = RecentTranslations(storageURL: nil)
        let french = recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        let japanese = recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let tab = TranslateTabTests.tab(FakeTranslator(), recents: recents, speaker: speaker)

        tab.readAloud(japanese.id)
        await tab.reading?.value
        #expect(tab.speechProblem == .init(id: japanese.id, message: FakeTranslationSpeaker.noVoice))
        #expect(!tab.isReading(japanese.id))
        #expect(speaker.readings == [.init(text: "おやすみ", language: "ja")], "Asked only for Japanese")

        tab.readAloud(french.id)
        await tab.reading?.value
        #expect(tab.speechProblem == nil)
        #expect(tab.isReading(french.id))
    }

    @Test("The voice is an installed one for the language, Chinese by its script's region, or none: never another language's")
    func voiceSelection() {
        let voices = [
            TranslationSpeechVoiceDescriptor(identifier: "cantonese", language: "zh-HK"),
            TranslationSpeechVoiceDescriptor(identifier: "taiwan", language: "zh-TW"),
            TranslationSpeechVoiceDescriptor(identifier: "mainland", language: "zh-CN"),
            TranslationSpeechVoiceDescriptor(identifier: "english", language: "en-US"),
        ]
        func voice(_ language: String) -> String? {
            TranslationSpeechVoiceSelector.preferredVoiceIdentifier(targetLanguageIdentifier: language, supportedVoices: voices)
        }
        #expect(voice("zh-Hans") == "mainland")
        #expect(voice("zh-Hant") == "taiwan")
        #expect(voice("zh-HK") == "cantonese", "A region asked for stays")
        #expect(voice("en") == "english")
        #expect(voice("ja") == nil, "No Japanese voice: none, not English")
    }

    @Test("Reading stops when the palette closes, the tab changes, the text changes, or the row is deleted")
    func stops() async {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        let speaker = fixture.speaker
        let tab = fixture.tab
        let record = fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")

        func read() async {
            tab.readAloud(record.id)
            await tab.reading?.value
            #expect(tab.isReading(record.id))
        }

        palette.selectOnOpening(.translate)
        await read()
        palette.dismiss()
        #expect(speaker.stops == 1, "The palette closed")
        #expect(!tab.isReading(record.id))

        palette.selectOnOpening(.translate)
        await read()
        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_2, "2")) == nil)
        #expect(palette.state.tab == .clipboard)
        #expect(speaker.stops == 2, "The tab changed")

        #expect(palette.handleKeyDown(fixture.commandKey(kVK_ANSI_8, "8")) == nil)
        await read()
        tab.update(query: "H")
        #expect(speaker.stops == 3, "The text changed")

        tab.update(query: "")
        await read()
        tab.deleteRecord(record.id)
        #expect(speaker.stops == 4, "It was deleted")
        #expect(fixture.recents.records.isEmpty)
        #expect(speaker.readings.count == 4)
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

/// Reads nothing aloud and never makes a sound: it records what it was asked to read, in which
/// language, and each stop. With no voice for a language, it says so, as `TranslatedSpeechPlayer`
/// does. Like it, it's observable, so a view redraws when reading starts or stops.
@MainActor
@Observable
final class FakeTranslationSpeaker: TranslationSpeaking {
    struct Reading: Equatable {
        let text: String
        let language: String
    }

    static let noVoice = "No installed voice is available for this language."

    private(set) var readings: [Reading] = []
    private(set) var stops = 0
    private(set) var isSpeaking = false
    /// The languages with no installed voice.
    var languagesWithoutVoice: Set<String> = []

    func speak(_ text: String, language: String) async -> String? {
        readings.append(Reading(text: text, language: language))
        if languagesWithoutVoice.contains(language) { return Self.noVoice }
        isSpeaking = true
        return nil
    }

    func stop() {
        stops += 1
        isSpeaking = false
    }
}

/// A file manager whose `removeItem` always fails, as for a file that can't be deleted.
private final class UnremovableFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@MainActor
final class RecordingActions {
    private(set) var copied: [String] = []
    private(set) var pasted: [(text: String, restoresClipboard: Bool)] = []
    private(set) var cleared = 0
    private(set) var selected: [Int] = []

    var actions: PaletteContentActions {
        PaletteContentActions(
            dismiss: {},
            selectRow: { [weak self] in self?.selected.append($0) },
            clearQuery: { [weak self] in self?.cleared += 1 },
            copy: { [weak self] in self?.copied.append($0) },
            paste: { [weak self] text, restores in self?.pasted.append((text, restores)) }
        )
    }
}

/// A palette over a temporary folder and a named pasteboard, never shown, whose Translate tab
/// translates with `FakeTranslator`, keeps recent translations in the folder, and reads aloud with
/// `FakeTranslationSpeaker`.
@MainActor
final class TranslatePaletteFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsTranslateTab-\(UUID().uuidString)"))
    let translator = FakeTranslator()
    let speaker = FakeTranslationSpeaker()
    let recents: RecentTranslations
    let clipboard: ClipboardHistoryService
    let dictationHistory: DictationHistoryService
    let tab: TranslatePaletteContent
    let palette: CommandPaletteController

    init() {
        let root = folder.url
        dictationHistory = DictationHistoryService(
            recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)
        )
        let preferences = TranslateTabTests.preferences()
        clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        recents = RecentTranslations(storageURL: root.appendingPathComponent(RecentTranslations.fileName))
        palette = CommandPaletteController(
            clipboard: clipboard,
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
        tab = TranslatePaletteContent(
            preferences: preferences, translator: translator, recents: recents, speaker: speaker, wait: { _ in }
        )
        palette.tabContents = [.translate: tab]
    }

    /// A key with no modifiers, such as Return or Delete.
    func key(_ keyCode: Int, _ characters: String) -> NSEvent {
        commandKey(keyCode, characters, modifiers: [])
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
