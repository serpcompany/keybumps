import Foundation
import Speech

/// Dictation's recognition language (`AppPreferences.dictationLanguage`, #530): Automatic, the
/// default, or a language someone chose in Settings › Dictation, as a locale identifier such as
/// `en-US`. A model that detects the language detects Automatic per recording; the others fall
/// back to one language. Whatever needs one language gets a real one, never Automatic or "".
enum DictationLanguage {
    /// What the setting holds for Automatic.
    static let automatic = "auto"
    /// What Automatic falls back to when nothing better is known, and the default before #530.
    static let english = "en-US"

    /// An empty setting counts as Automatic, so it never reaches a model or the history.
    static func isAutomatic(_ setting: String) -> Bool {
        setting == automatic || setting.isEmpty
    }

    /// The one language `engine` uses for `setting` where one is needed before or without a
    /// detection: the setting itself, unless it's Automatic. Then Whisper Medium English uses
    /// English, and every other model the Mac's language (`macLanguage()`).
    static func resolved(
        _ setting: String,
        engine: DictationTranscriptionEngine = .appleSpeech,
        macLanguage: () -> String = { DictationLanguage.macLanguage() }
    ) -> String {
        guard isAutomatic(setting) else { return setting }
        return engine == .whisperMediumEnglish ? english : macLanguage()
    }

    /// What `engine`'s model is asked to transcribe in: Automatic for a model that detects the
    /// language, otherwise `resolved`.
    static func request(
        _ setting: String,
        engine: DictationTranscriptionEngine,
        macLanguage: () -> String = { DictationLanguage.macLanguage() }
    ) -> String {
        if isAutomatic(setting), engine.detectsLanguage { return automatic }
        return resolved(setting, engine: engine, macLanguage: macLanguage)
    }

    /// The Mac's language where Apple's on-device speech supports it, otherwise English: what
    /// Automatic uses with Apple Speech, which needs one language. The Mac's script comes first,
    /// so a Simplified Chinese Mac in Hong Kong gets `zh-CN` rather than Cantonese `zh-HK`; then
    /// the Mac's own region, so a British Mac gets `en-GB` rather than `en-US`; then the
    /// language's likely region, so English on a German Mac gets `en-US` rather than `en-ID`.
    static func macLanguage(
        preferred: String? = Locale.preferredLanguages.first,
        region: Locale.Region? = Locale.current.region,
        supported: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier),
        supportsOnDevice: (String) -> Bool = {
            SFSpeechRecognizer(locale: Locale(identifier: $0))?.supportsOnDeviceRecognition == true
        }
    ) -> String {
        guard let preferred else { return english }
        let mac = Locale.Language(identifier: preferred)
        let macRegion = mac.region ?? region
        // Likely subtags: en → en-Latn-US, es → es-Latn-ES, zh-Hant → zh-Hant-TW.
        let likelyRegion = Locale.Language(
            identifier: Locale.Language(languageCode: mac.languageCode, script: mac.script).maximalIdentifier
        ).region
        // Script, then region (the Mac's, the likely one, the rest), then the identifier.
        let order = { (identifier: String) -> (Int, Int, String) in
            let language = Locale.Language(identifier: identifier)
            let region = language.region == macRegion ? 0 : language.region == likelyRegion ? 1 : 2
            return (language.script == mac.script ? 0 : 1, region, identifier)
        }
        return supported
            .filter { Locale.Language(identifier: $0).languageCode == mac.languageCode }
            .sorted { order($0) < order($1) }
            .first(where: supportsOnDevice) ?? english
    }

    /// What Settings › Dictation says under its menu while Automatic is chosen with a model that
    /// can't detect the language; nil for a model that detects it.
    static func automaticNote(
        engine: DictationTranscriptionEngine,
        preferred: String? = Locale.preferredLanguages.first,
        macLanguage: () -> String = { DictationLanguage.macLanguage() }
    ) -> String? {
        switch engine {
        case .whisperMediumEnglish:
            return "With \(engine.title), Automatic uses English."
        case .appleSpeech:
            let used = Locale.Language(identifier: macLanguage()).languageCode
            guard let preferred, Locale.Language(identifier: preferred).languageCode != used else {
                return "With \(engine.title), Automatic uses your Mac's language."
            }
            return "With \(engine.title), Automatic uses English: on-device speech doesn't support your Mac's language."
        case .whisperMediumMultilingual, .whisperTurboCompressed, .whisperCppTurbo:
            return nil
        }
    }

    /// Settings › Dictation's language menu: Automatic first, then every language Apple's
    /// on-device speech offers, by name.
    static func menuOptions(available: [String]) -> [(value: String, label: String)] {
        [(automatic, "Automatic")]
            + available.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
    }
}

/// A finished transcription and the language it's in (#530).
struct DictationTranscription: Equatable, Sendable {
    let text: String
    /// The language detected for Automatic, otherwise the one asked for.
    let language: String
}
