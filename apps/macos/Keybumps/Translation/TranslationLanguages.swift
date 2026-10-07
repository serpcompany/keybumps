import Foundation
import NaturalLanguage

/// The languages the Translation plugin's "My language" and "Other language" offer (#322), and the
/// one place they're listed: the ones Apple's Translation offers on macOS 15, the plugin's oldest
/// macOS. Later versions add more (Danish, Finnish, Hebrew, Malay, Norwegian, and Swedish by macOS
/// 27), which the Translate tab still translates from when it detects them. Chinese is listed by
/// script.
enum TranslationLanguages {
    struct Language: Equatable {
        /// Its `TranslationLanguagePair.code`, such as `en` or `zh-Hant`.
        let code: String
        let name: String
    }

    static let offered: [Language] = [
        Language(code: "ar", name: "Arabic"),
        Language(code: "zh-Hans", name: "Chinese (Simplified)"),
        Language(code: "zh-Hant", name: "Chinese (Traditional)"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "en", name: "English"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "id", name: "Indonesian"),
        Language(code: "it", name: "Italian"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "pl", name: "Polish"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "ru", name: "Russian"),
        Language(code: "es", name: "Spanish"),
        Language(code: "th", name: "Thai"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "uk", name: "Ukrainian"),
        Language(code: "vi", name: "Vietnamese"),
    ]

    static func isOffered(_ identifier: String) -> Bool {
        let code = TranslationLanguagePair.code(identifier)
        return offered.contains { $0.code == code }
    }

    /// A language's name: its name in the list, or the Mac's name for one Translate detected that
    /// isn't in it.
    static func name(for identifier: String) -> String {
        let code = TranslationLanguagePair.code(identifier)
        return offered.first { $0.code == code }?.name
            ?? Locale.current.localizedString(forIdentifier: code)
            ?? identifier
    }
}

/// The two languages translation goes between (#322): text in mine goes to the other, and text in
/// any other language comes back to mine, as in Easydict and Pot. Languages are codes such as `en`,
/// with the script for Chinese (`zh-Hans`, `zh-Hant`), since that's which Chinese it is.
struct TranslationLanguagePair: Equatable {
    let mine: String
    let other: String

    /// The two are never the same language: when they are, the other becomes English, or Japanese
    /// when mine is English.
    init(mine: String, other: String) {
        let mine = Self.code(mine)
        let other = Self.code(other)
        self.mine = mine
        self.other = other == mine ? Self.otherDefault(forMine: mine) : other
    }

    /// What Dictation's Translate does while the Translation plugin is off: English text to
    /// Japanese, anything else to English. The plugin's setting replaces it while it's on.
    static let dictationDefault = TranslationLanguagePair(mine: "en", other: "ja")

    /// The Translation plugin's starting pair: the Mac's first preferred language, when Translation
    /// offers it (`TranslationLanguages`), or else English; with English, or with Japanese when
    /// mine is English.
    static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> TranslationLanguagePair {
        let first = preferredLanguages.first.map(code) ?? "en"
        let mine = TranslationLanguages.isOffered(first) ? first : "en"
        return TranslationLanguagePair(mine: mine, other: otherDefault(forMine: mine))
    }

    private static func otherDefault(forMine mine: String) -> String {
        mine == "en" ? "ja" : "en"
    }

    /// The language to translate text in `sourceIdentifier` into.
    func target(forSourceIdentifier sourceIdentifier: String) -> String {
        Self.code(sourceIdentifier) == mine ? other : mine
    }

    /// The language an identifier names, as the pair keeps it: its language code (`pt-BR` is `pt`),
    /// with the script for Chinese, which Taiwan and Hong Kong write in Traditional (`zh-TW` is
    /// `zh-Hant`).
    static func code(_ identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return identifier }
        if code == "zh", let script = language.script?.identifier { return "\(code)-\(script)" }
        return code
    }
}

enum TranslationLanguagePolicy {
    static func canTranslate(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How sure `NLLanguageRecognizer` must be before its guess replaces the recorded language.
    /// Short words that several languages share score below it ("OK", "Hola", "Bonjour", and "Ciao"
    /// score 0.3 to 0.7), while a sentence, or a Chinese or Japanese word of two characters, scores
    /// 0.8 or more.
    static let sourceDetectionConfidence = 0.8
    /// The fewest characters worth a guess: one says too little. It stays low because two Japanese
    /// characters are already a certain guess; the confidence screens out the rest.
    static let sourceDetectionMinimumLength = 2

    /// The language to translate from: the one the text is written in. The fallback is the language
    /// the text was expected in, such as a recording's Dictation language, which is the setting it
    /// was recorded with, not what was spoken (#321). Keeps the fallback when the text is in it (so
    /// its region stays, as in `pt-BR`), or when the guess is unsure.
    static func sourceLanguageIdentifier(for text: String, fallbackLanguageIdentifier: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= sourceDetectionMinimumLength else { return fallbackLanguageIdentifier }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let guess = recognizer.languageHypotheses(withMaximum: 1).first
        return sourceLanguageIdentifier(
            guess: guess?.key,
            confidence: guess?.value ?? 0,
            fallbackLanguageIdentifier: fallbackLanguageIdentifier
        )
    }

    /// The recognizer's top guess, unless it's missing, undetermined, below
    /// `sourceDetectionConfidence`, or the fallback language in the same script; then the fallback.
    static func sourceLanguageIdentifier(
        guess: NLLanguage?,
        confidence: Double,
        fallbackLanguageIdentifier: String
    ) -> String {
        guard let guess, guess != .undetermined,
              confidence >= sourceDetectionConfidence else { return fallbackLanguageIdentifier }
        let detected = Locale.Language(identifier: guess.rawValue)
        let recorded = Locale.Language(identifier: fallbackLanguageIdentifier)
        let sameLanguage = detected.languageCode == recorded.languageCode
            && Locale.Language(identifier: detected.maximalIdentifier).script
                == Locale.Language(identifier: recorded.maximalIdentifier).script
        return sameLanguage ? fallbackLanguageIdentifier : guess.rawValue
    }

    /// The languages Translate offers: every supported one but the source's.
    static func targets(from supported: [Locale.Language], sourceIdentifier: String) -> [Locale.Language] {
        let source = Locale.Language(identifier: sourceIdentifier)
        return supported.filter { !$0.isEquivalent(to: source) }
    }

    /// Where Translate starts, and the targets it offers from there: the text's language, or the
    /// fallback language when Translation offers nothing from the text's. Translation knows fewer
    /// languages than the recognizer (not Swedish, Danish, or Greek, for example). Nil when neither
    /// offers a target.
    @MainActor
    static func translatableSource(
        for text: String,
        fallbackLanguageIdentifier: String,
        targets: (String) async -> [Locale.Language]
    ) async -> (source: String, targets: [Locale.Language])? {
        let detected = sourceLanguageIdentifier(for: text, fallbackLanguageIdentifier: fallbackLanguageIdentifier)
        let candidates = detected == fallbackLanguageIdentifier ? [detected] : [detected, fallbackLanguageIdentifier]
        for source in candidates {
            let offered = await targets(source)
            if !offered.isEmpty { return (source, offered) }
        }
        return nil
    }

    /// The pair's other language for text in mine, and mine for text in any other language (#322);
    /// the first language offered when Translation has neither.
    static func preferredTargetIdentifier(
        sourceIdentifier: String,
        supportedIdentifiers: [String],
        pair: TranslationLanguagePair
    ) -> String? {
        let preferred = pair.target(forSourceIdentifier: sourceIdentifier)
        return supportedIdentifiers.first(where: { TranslationLanguagePair.code($0) == preferred })
            ?? supportedIdentifiers.first
    }
}
