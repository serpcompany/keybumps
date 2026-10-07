import AppKit
import Carbon.HIToolbox
import Foundation
import NaturalLanguage
import Testing
@testable import Keybumps

/// Dictation's Translate starts from the language the text is in, not the Dictation language
/// setting it was recorded with, and holds the Command Palette open while it translates (#321).
@MainActor
@Suite("Dictation: Translate")
struct DictationTranslationTests {
    static let spanish = "¿Puedes recordarme comprar pan y leche esta tarde?"
    static let japanese = "今日の午後にパンと牛乳を買うのを思い出させてください。"
    static let english = "Please remind me to buy bread and milk this afternoon."
    static let supported = ["en-US", "es-ES", "ja-JP", "fr-FR"].map(Locale.Language.init(identifier:))

    static func source(_ text: String, recordedWith recorded: String = "en-US") -> String {
        TranslationLanguagePolicy.sourceLanguageIdentifier(for: text, fallbackLanguageIdentifier: recorded)
    }

    static func targets(_ text: String) -> [String] {
        TranslationLanguagePolicy.targets(from: supported, sourceIdentifier: source(text)).map(\.minimalIdentifier)
    }

    @Test("Text in another language than the setting translates from the language it's in")
    func detectsTheTextsLanguage() {
        #expect(Self.source(Self.spanish) == "es")
        #expect(Self.source(Self.japanese) == "ja")
        #expect(Self.source("我明天早上会晚一点到。") == "zh-Hans")
        #expect(Self.source("我明天早上會晚一點到。") == "zh-Hant")
        #expect(Self.source("我明天早上會晚一點到。", recordedWith: "zh-TW") == "zh-TW")
    }

    @Test("Text in the setting's language keeps the setting, region and all")
    func keepsTheRecordedLanguage() {
        #expect(Self.source(Self.english) == "en-US")
        #expect(Self.source("Eu chego atrasado amanhã de manhã.", recordedWith: "pt-BR") == "pt-BR")
    }

    @Test("Text too short or unclear to tell keeps the setting")
    func fallsBackWhenUnsure() {
        #expect(Self.source("a", recordedWith: "es-ES") == "es-ES")
        #expect(Self.source("2026") == "en-US")
        #expect(Self.source("OK", recordedWith: "fr-FR") == "fr-FR")
    }

    @Test("A guess replaces the setting from 0.8 confidence; undetermined or missing guesses never do")
    func confidenceThreshold() {
        func source(_ guess: NLLanguage?, _ confidence: Double, recordedWith recorded: String = "en-US") -> String {
            TranslationLanguagePolicy.sourceLanguageIdentifier(
                guess: guess, confidence: confidence, fallbackLanguageIdentifier: recorded
            )
        }
        #expect(TranslationLanguagePolicy.sourceDetectionConfidence == 0.8)
        #expect(source(.spanish, 0.79) == "en-US")
        #expect(source(.spanish, 0.8) == "es")
        #expect(source(.spanish, 1) == "es")
        #expect(source(.undetermined, 1) == "en-US")
        #expect(source(nil, 0) == "en-US")
        #expect(source(.english, 1) == "en-US", "The setting's own language keeps its region")
        #expect(source(.simplifiedChinese, 1, recordedWith: "zh-CN") == "zh-CN", "Same script")
        #expect(source(.simplifiedChinese, 1, recordedWith: "zh-TW") == "zh-Hans", "Simplified text, another script")
        #expect(source(.traditionalChinese, 1, recordedWith: "zh-TW") == "zh-TW", "Traditional text keeps Taiwan")
        #expect(source(.traditionalChinese, 1, recordedWith: "zh-HK") == "zh-HK", "Traditional text keeps Hong Kong")
        #expect(source(.traditionalChinese, 1) == "zh-Hant")
    }

    @Test("A language Translation can't start from falls back to the setting; with neither, nothing is offered")
    func untranslatableLanguageFallsBack() async {
        let swedish = "Kan du påminna mig om att köpa bröd och mjölk i eftermiddag?"
        #expect(Self.source(swedish) == "sv")
        var asked: [String] = []
        let offeredFromEnglish = await TranslationLanguagePolicy.translatableSource(
            for: swedish, fallbackLanguageIdentifier: "en-US"
        ) { source in
            asked.append(source)
            return source == "en-US" ? Self.supported : []
        }
        #expect(asked == ["sv", "en-US"])
        #expect(offeredFromEnglish?.source == "en-US")
        #expect(offeredFromEnglish?.targets == Self.supported)

        asked = []
        let nothing = await TranslationLanguagePolicy.translatableSource(
            for: swedish, fallbackLanguageIdentifier: "en-US"
        ) { source in
            asked.append(source)
            return []
        }
        #expect(nothing == nil)
        #expect(asked == ["sv", "en-US"])

        asked = []
        let fromSpanish = await TranslationLanguagePolicy.translatableSource(
            for: Self.spanish, fallbackLanguageIdentifier: "en-US"
        ) { source in
            asked.append(source)
            return Self.supported
        }
        #expect(fromSpanish?.source == "es")
        #expect(asked == ["es"], "A translatable language isn't second-guessed")

        asked = []
        _ = await TranslationLanguagePolicy.translatableSource(
            for: Self.english, fallbackLanguageIdentifier: "en-US"
        ) { source in
            asked.append(source)
            return []
        }
        #expect(asked == ["en-US"], "The setting is asked once")
    }

    @Test("Spanish or Japanese text recorded with the setting on English offers English; English text doesn't")
    func offersEnglishForOtherLanguages() {
        #expect(Self.targets(Self.spanish).contains("en"))
        #expect(!Self.targets(Self.spanish).contains("es"))
        #expect(Self.targets(Self.japanese).contains("en"))
        #expect(!Self.targets(Self.japanese).contains("ja"))
        #expect(!Self.targets(Self.english).contains("en"))
        #expect(Self.targets(Self.english).contains("es"))
    }

    @Test("Translate picks English first, or Japanese for English text")
    func preferredTarget() {
        func preferred(_ text: String) -> String? {
            let source = Self.source(text)
            return TranslationLanguagePolicy.preferredTargetIdentifier(
                sourceIdentifier: source,
                supportedIdentifiers: TranslationLanguagePolicy.targets(from: Self.supported, sourceIdentifier: source)
                    .map(\.minimalIdentifier),
                pair: TranslationLanguagePair(mine: "en", other: "ja")
            )
        }
        #expect(preferred(Self.spanish) == "en")
        #expect(preferred(Self.japanese) == "en")
        #expect(preferred(Self.english) == "ja")
        #expect(
            TranslationLanguagePolicy.preferredTargetIdentifier(
                sourceIdentifier: "es", supportedIdentifiers: ["fr", "de"], pair: TranslationLanguagePair(mine: "en", other: "ja")
            ) == "fr",
            "Without English, the first language offered"
        )
    }

    @Test("The language pair: text in mine goes to the other, anything else comes back to mine (#322)")
    func languagePair() {
        let englishJapanese = TranslationLanguagePair(mine: "en-US", other: "ja-JP")
        #expect(englishJapanese == TranslationLanguagePair(mine: "en", other: "ja"), "Regions don't matter")
        #expect(englishJapanese.target(forSourceIdentifier: "en-GB") == "ja")
        #expect(englishJapanese.target(forSourceIdentifier: "ja") == "en")
        #expect(englishJapanese.target(forSourceIdentifier: "fr-FR") == "en")

        #expect(TranslationLanguagePair.systemDefault(preferredLanguages: ["en-US", "ja-JP"]) == englishJapanese,
                "An English Mac keeps Dictation's English ↔ Japanese")
        #expect(TranslationLanguagePair.systemDefault(preferredLanguages: ["de-DE"]) == TranslationLanguagePair(mine: "de", other: "en"))
        #expect(TranslationLanguagePair.systemDefault(preferredLanguages: []) == englishJapanese)

        let germanEnglish = TranslationLanguagePair(mine: "de", other: "en")
        #expect(TranslationLanguagePolicy.preferredTargetIdentifier(
            sourceIdentifier: "de-DE", supportedIdentifiers: ["fr", "en-US"], pair: germanEnglish
        ) == "en-US")
        #expect(TranslationLanguagePolicy.preferredTargetIdentifier(
            sourceIdentifier: "ja", supportedIdentifiers: ["de", "en"], pair: germanEnglish
        ) == "de")
    }

    @Test("A hold keeps the palette open against Keybumps's other windows, as a confirmation does")
    func dismissalPolicy() {
        #expect(CommandPaletteDismissalPolicy.shouldDismiss())
        #expect(!CommandPaletteDismissalPolicy.shouldDismiss(isHeldOpen: true))
        #expect(!CommandPaletteDismissalPolicy.shouldDismiss(isPresentingConfirmation: true))
        #expect(!CommandPaletteDismissalPolicy.shouldDismiss(isPresentingConfirmation: true, isHeldOpen: true))

        #expect(!CommandPaletteDismissalPolicy.shouldDismissOnResignKey(
            isPresentingConfirmation: false, isHeldOpen: true, keyWentToOwnWindow: true
        ))
        #expect(CommandPaletteDismissalPolicy.shouldDismissOnResignKey(
            isPresentingConfirmation: false, isHeldOpen: true, keyWentToOwnWindow: false
        ), "A hold never keeps it over another app")
        #expect(CommandPaletteDismissalPolicy.shouldDismissOnResignKey(
            isPresentingConfirmation: false, isHeldOpen: false, keyWentToOwnWindow: true
        ))
        #expect(!CommandPaletteDismissalPolicy.shouldDismissOnResignKey(
            isPresentingConfirmation: true, isHeldOpen: false, keyWentToOwnWindow: false
        ))
    }

    @Test("The palette's keys handle keys sent to the panel or to no window, never another window's")
    func keyRouting() {
        let panel = Self.window()
        let prompt = Self.window()
        #expect(CommandPaletteDismissalPolicy.palettesKey(eventWindow: panel, panel: panel))
        #expect(CommandPaletteDismissalPolicy.palettesKey(eventWindow: nil, panel: panel))
        #expect(!CommandPaletteDismissalPolicy.palettesKey(eventWindow: prompt, panel: panel))
        #expect(!CommandPaletteDismissalPolicy.palettesKey(eventWindow: prompt, panel: nil))
    }

    @Test("As the last hold lets go, a showing palette that lost key focus to a closed prompt takes it back")
    func takesKeyBack() {
        func takesKey(held: Bool = false, visible: Bool = true, key: Bool = false, otherKey: Bool = false) -> Bool {
            CommandPaletteDismissalPolicy.shouldTakeKeyBack(
                isHeldOpen: held, isVisible: visible, isKey: key, keybumpsHasKeyWindow: otherKey
            )
        }
        #expect(takesKey())
        #expect(!takesKey(held: true), "Another holder still holds it")
        #expect(!takesKey(visible: false), "A closed palette stays closed")
        #expect(!takesKey(key: true), "Already key")
        #expect(!takesKey(otherKey: true), "The prompt or another Keybumps window still has the keys")
    }

    @Test("Keys typed into another Keybumps window pass through untouched")
    func keysForAnotherWindowPassThrough() throws {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let prompt = Self.window()
        try #require(prompt.windowNumber > 0)
        fixture.palette.holdOpen(true, by: UUID())

        for keyCode in [kVK_Return, kVK_Escape, kVK_DownArrow, kVK_Delete] {
            let event = Self.key(keyCode, windowNumber: prompt.windowNumber)
            try #require(event.window === prompt)
            #expect(fixture.palette.handleKeyDown(event) === event)
        }
        #expect(fixture.palette.isHeldOpen, "Escape and Return for the prompt didn't close the palette")
        #expect(fixture.palette.state.closings == 0)
    }

    @Test("Losing key focus to a Keybumps window doesn't close a held palette; to another app it does")
    func resignKey() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        let prompt = Self.window()

        palette.holdOpen(true, by: UUID())
        palette.resignedKey(to: prompt)
        #expect(palette.isHeldOpen, "Not dismissed, which would let every hold go")
        #expect(palette.state.closings == 0)

        palette.resignedKey(to: nil)
        #expect(!palette.isHeldOpen)
        #expect(palette.state.closings == 1)

        palette.resignedKey(to: prompt)
        #expect(palette.state.closings == 2, "Unheld, any loss of key focus closes it")
    }

    @Test("Switching to another app closes a held palette; Keybumps coming forward doesn't")
    func appSwitch() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette

        palette.holdOpen(true, by: UUID())
        palette.didActivateApp(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        #expect(palette.isHeldOpen)
        palette.didActivateApp(processIdentifier: 1)
        #expect(!palette.isHeldOpen)
        #expect(palette.state.closings == 1)
    }

    @Test("Every holder must let go; closing the palette lets them all go and counts the closing")
    func holdAndRelease() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        let translation = UUID()
        let other = UUID()

        palette.holdOpen(true, by: translation)
        palette.holdOpen(true, by: other)
        palette.holdOpen(false, by: translation)
        palette.holdOpen(false, by: translation)
        #expect(palette.isHeldOpen, "Another holder still holds it")
        palette.holdOpen(false, by: other)
        #expect(!palette.isHeldOpen)

        palette.holdOpen(true, by: translation)
        palette.dismiss()
        #expect(!palette.isHeldOpen, "Closing the palette lets every hold go")
        #expect(palette.state.closings == 1, "So a translation still waiting stops")
        palette.holdOpen(false, by: translation)
        #expect(!palette.isHeldOpen, "A late release after closing is harmless")
    }

    @Test("The environment's hold reaches the palette it came from, and outside the palette does nothing")
    func environmentHold() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let translation = UUID()
        let hold = CommandPaletteHold(palette: fixture.palette)

        hold(translation, true)
        #expect(fixture.palette.isHeldOpen)
        hold(translation, false)
        #expect(!fixture.palette.isHeldOpen)
        fixture.palette.dismiss()
        #expect(hold.closings == 1)

        CommandPaletteHold()(translation, true)
        #expect(!fixture.palette.isHeldOpen)
        #expect(CommandPaletteHold().closings == 0)
        #expect(hold == CommandPaletteHold(palette: fixture.palette))
        #expect(hold != CommandPaletteHold())
    }

    @Test("Escape still closes a held palette")
    func escapeClosesAHeldPalette() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }

        fixture.palette.holdOpen(true, by: UUID())
        #expect(fixture.palette.handleKeyDown(Self.key(kVK_Escape)) == nil)
        #expect(!fixture.palette.isHeldOpen, "Escape dismissed the palette, letting the hold go")
    }

    /// A window that is never shown.
    static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    static func key(_ keyCode: Int, windowNumber: Int = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }
}

/// A palette over a temporary folder and a named pasteboard, never shown.
@MainActor
private final class PaletteFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsTranslation-\(UUID().uuidString)"))
    let palette: CommandPaletteController

    init() {
        let root = folder.url
        let dictationHistory = DictationHistoryService(
            recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)
        )
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
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            snippets: folder.makeStore(),
            pasteboard: pasteboard,
            notices: QuietNotices(),
            search: QuickSearchModel.forTests(in: root)
        )
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

@MainActor
private final class QuietNotices: PaletteNoticePresenting {
    func showNotice(_ message: String, isWarning: Bool) {}
}
