import AppKit
import Carbon.HIToolbox
import Foundation
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
        DictationTranslationPolicy.sourceLanguageIdentifier(for: text, recordedLanguageIdentifier: recorded)
    }

    static func targets(_ text: String) -> [String] {
        DictationTranslationPolicy.targets(from: supported, sourceIdentifier: source(text)).map(\.minimalIdentifier)
    }

    @Test("Text in another language than the setting translates from the language it's in")
    func detectsTheTextsLanguage() {
        #expect(Self.source(Self.spanish) == "es")
        #expect(Self.source(Self.japanese) == "ja")
        #expect(Self.source("我明天早上会晚一点到。") == "zh-Hans")
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
            return DictationTranslationPolicy.preferredTargetIdentifier(
                sourceIdentifier: source,
                supportedIdentifiers: DictationTranslationPolicy.targets(from: Self.supported, sourceIdentifier: source)
                    .map(\.minimalIdentifier)
            )
        }
        #expect(preferred(Self.spanish) == "en")
        #expect(preferred(Self.japanese) == "en")
        #expect(preferred(Self.english) == "ja")
        #expect(
            DictationTranslationPolicy.preferredTargetIdentifier(sourceIdentifier: "es", supportedIdentifiers: ["fr", "de"]) == "fr",
            "Without English, the first language offered"
        )
    }

    @Test("A hold keeps the palette open against outside clicks, as a confirmation does")
    func dismissalPolicy() {
        #expect(CommandPaletteDismissalPolicy.shouldDismiss())
        #expect(!CommandPaletteDismissalPolicy.shouldDismiss(isHeldOpen: true))
        #expect(!CommandPaletteDismissalPolicy.shouldDismiss(isPresentingConfirmation: true))
        #expect(!CommandPaletteDismissalPolicy.shouldDismiss(isPresentingConfirmation: true, isHeldOpen: true))
    }

    @Test("Losing key focus doesn't close a held palette; once every hold lets go, it does")
    func holdAndRelease() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        let translation = UUID()
        let other = UUID()
        let resignKey = Notification(name: NSWindow.didResignKeyNotification)

        palette.holdOpen(true, by: translation)
        palette.holdOpen(true, by: other)
        palette.windowDidResignKey(resignKey)
        #expect(palette.isHeldOpen, "Not dismissed, which would let every hold go")

        palette.holdOpen(false, by: translation)
        palette.holdOpen(false, by: translation)
        #expect(palette.isHeldOpen, "Another holder still holds it")
        palette.holdOpen(false, by: other)
        #expect(!palette.isHeldOpen)

        palette.holdOpen(true, by: translation)
        palette.dismiss()
        #expect(!palette.isHeldOpen, "Closing the palette lets every hold go")
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

        CommandPaletteHold()(translation, true)
        #expect(!fixture.palette.isHeldOpen)
        #expect(hold == CommandPaletteHold(palette: fixture.palette))
        #expect(hold != CommandPaletteHold())
    }

    @Test("Escape still closes a held palette")
    func escapeClosesAHeldPalette() {
        let fixture = PaletteFixture()
        defer { fixture.tearDown() }
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)
        )!

        fixture.palette.holdOpen(true, by: UUID())
        #expect(fixture.palette.handleKeyDown(escape) == nil)
        #expect(!fixture.palette.isHeldOpen, "Escape dismissed the palette, letting the hold go")
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
