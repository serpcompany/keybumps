import SwiftUI

/// The Translate tab (#322): what's typed or pasted in the search field, translated as you type,
/// about 300 ms after the typing stops. Text in My language goes to Other language, and text in
/// any other language comes back to mine (`TranslationLanguagePair`). Return copies the translation,
/// kept out of Clipboard History; ⌘Return pastes it into the app you were using and puts the
/// clipboard back. Translations aren't kept anywhere.
///
/// For the text in the field (#362), ⌘T or the swap button swaps the two languages, and the
/// target's menu picks another; either lasts until the text changes. Picking a target for text in
/// my language also saves it as Other language. ⌘S or the speaker button reads the translation
/// aloud on this Mac (`TextSpeaking`), and stops it.
@MainActor
@Observable
final class TranslatePaletteContent: CapabilityPaletteContent {
    /// How long typing has to stop before the text is translated.
    static let debounce: Duration = .milliseconds(300)

    let tab = CommandPaletteTab.translate

    /// A translation asked for: the text, and the languages it goes between.
    struct Request: Equatable {
        let text: String
        let source: String
        let target: String
    }

    /// A translation that came back.
    struct Translation: Equatable {
        let request: Request
        let text: String
    }

    /// The text asked for last; the tab names its languages.
    private(set) var request: Request?
    /// The last translation that came back, which may be of earlier text.
    private(set) var translation: Translation?
    /// Why the last request couldn't be translated.
    private(set) var failure: String?
    /// Whether that's because a language isn't downloaded, which the tab offers to fix in System
    /// Settings.
    private(set) var needsDownload = false
    /// Whether a translation is on its way. The palette stays open meanwhile.
    private(set) var isTranslating = false
    /// Whether the translation is being read aloud.
    private(set) var isSpeaking = false

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let translator: (any TextTranslating)?
    @ObservationIgnored private let speaker: any TextSpeaking
    @ObservationIgnored private let wait: (Duration) async throws -> Void
    /// Languages picked for one text, by swapping or from the target's menu, in place of detection
    /// until the text changes.
    @ObservationIgnored private var chosen: Request?
    /// Tells a reading's end from an earlier one's.
    @ObservationIgnored private var reading = 0
    /// The debounce and translation for the latest text; tests await it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    /// Opens System Settings on Language & Region, where Translation Languages are downloaded.
    @ObservationIgnored var openLanguageSettings: @MainActor () -> Void = {}
    /// Holds the palette open against clicks in Keybumps's other windows
    /// (`holdCommandPaletteOpen`) while a translation runs. The tab's view sets it.
    @ObservationIgnored var holdPaletteOpen: @MainActor (Bool) -> Void = { _ in }

    /// `wait` sleeps out the debounce; tests pass their own. Without a speaker, it reads aloud with
    /// `TextSpeakerFactory`'s, which is silent under unit tests.
    init(
        preferences: AppPreferences,
        translator: (any TextTranslating)?,
        speaker: (any TextSpeaking)? = nil,
        wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.preferences = preferences
        self.translator = translator
        self.speaker = speaker ?? TextSpeakerFactory.makeDefault()
        self.wait = wait
    }

    /// Why the tab can't translate: Translation is off, or this Mac's macOS can't run it. Nil when
    /// it can.
    var unavailableReason: String? {
        guard preferences.compatibility.supports(.translation), translator != nil else {
            return "Translation requires macOS \(CapabilityDescriptor.translation.minimumMacOS ?? 15) or later"
        }
        guard preferences.enabledCapabilities.contains(.translation) else {
            return "Translation is turned off. Turn it on in Settings › Plugins."
        }
        return nil
    }

    var isAvailable: Bool { unavailableReason == nil }

    static func text(of query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The translation of what's in the search field, once it's back; nil while it's on its way.
    func currentTranslation(query: String) -> String? {
        guard let translation, let request, translation.request == request,
              request.text == Self.text(of: query) else { return nil }
        return translation.text
    }

    // MARK: Translating

    /// The search field changed: translates its text once typing stops for `debounce`. Anything
    /// still on its way for earlier text is dropped, so a slow translation never replaces a newer
    /// one.
    func update(query: String) {
        work?.cancel()
        work = nil
        let text = Self.text(of: query)
        guard isAvailable, !text.isEmpty else { return reset() }
        if text != request?.text { stopSpeaking() }
        if text != chosen?.text { chosen = nil }
        // Already translated, or known not to translate.
        if text == request?.text, currentTranslation(query: query) != nil || failure != nil { return setTranslating(false) }
        let wait = wait
        work = Task { [weak self] in
            do { try await wait(Self.debounce) } catch { return }
            await self?.translate(text)
        }
    }

    private func translate(_ text: String) async {
        guard !Task.isCancelled, let translator else { return }
        let request = chosen.flatMap { $0.text == text ? $0 : nil } ?? detectedRequest(for: text)
        self.request = request
        failure = nil
        needsDownload = false
        setTranslating(true)
        do {
            let translated = try await translator.translate(text, from: request.source, to: request.target)
            guard !Task.isCancelled, self.request == request else { return }
            translation = Translation(request: request, text: translated)
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            let reason = error as? TranslateFailure ?? .failed
            translation = nil
            failure = Self.message(for: reason, request: request)
            needsDownload = reason == .notDownloaded
        }
        setTranslating(false)
    }

    /// The languages for text nobody picked any for: the one it's written in, and the pair's
    /// language for it.
    private func detectedRequest(for text: String) -> Request {
        let pair = preferences.translationLanguagePair
        let source = TranslationLanguagePolicy.sourceLanguageIdentifier(for: text, fallbackLanguageIdentifier: pair.mine)
        return Request(text: text, source: source, target: pair.target(forSourceIdentifier: source))
    }

    private func setTranslating(_ translating: Bool) {
        guard translating != isTranslating else { return }
        isTranslating = translating
        holdPaletteOpen(translating)
    }

    /// Stops a translation on its way, and reading aloud, as when the palette closes, the tab
    /// changes, or Translation is turned off.
    func stop() {
        work?.cancel()
        work = nil
        setTranslating(false)
        stopSpeaking()
    }

    private func reset() {
        stop()
        chosen = nil
        request = nil
        translation = nil
        failure = nil
        needsDownload = false
    }

    static func message(for failure: TranslateFailure, request: Request) -> String {
        let source = TranslationLanguages.name(for: request.source)
        let target = TranslationLanguages.name(for: request.target)
        return switch failure {
        case .unsupportedPair: "Can’t translate \(source) into \(target) on this Mac."
        case .notDownloaded: "Download \(source) and \(target) in System Settings › General › Language & Region › Translation Languages, then try again."
        case .failed: "Translation couldn’t be completed."
        }
    }

    // MARK: Swapping and picking languages

    /// The request for the text in the field, once it's asked for; the header names its languages.
    private func currentRequest(query: String) -> Request? {
        guard isAvailable, let request, request.text == Self.text(of: query) else { return nil }
        return request
    }

    /// Whether the languages can be swapped or the target picked: the text in the field was asked
    /// for, so the header shows its languages.
    func canChangeLanguages(query: String) -> Bool {
        currentRequest(query: query) != nil
    }

    /// Translates the text in the field the other way, from its target into its source, as for a
    /// short word detected as the wrong language. Detection comes back with the next text.
    func swapLanguages(query: String) {
        guard let request = currentRequest(query: query) else { return }
        translateAgain(Request(text: request.text, source: request.target, target: request.source))
    }

    /// The languages the target's menu offers: every language Translation offers but the source.
    func targetChoices(query: String) -> [TranslationLanguages.Language] {
        guard let request = currentRequest(query: query) else { return [] }
        let source = TranslationLanguagePair.code(request.source)
        return TranslationLanguages.offered.filter { $0.code != source }
    }

    /// Translates the text in the field into `target` at once. When the text is in my language,
    /// `target` also becomes Other language, as in Settings, so my language goes there from now
    /// on. Text in another language comes back to mine, so for it the choice lasts only until the
    /// text changes, and My language stays.
    func chooseTarget(_ target: String, query: String) {
        guard let request = currentRequest(query: query), TranslationLanguages.isOffered(target) else { return }
        let target = TranslationLanguagePair.code(target)
        let source = TranslationLanguagePair.code(request.source)
        guard target != source, target != TranslationLanguagePair.code(request.target) else { return }
        if source == preferences.translationLanguagePair.mine {
            preferences.set(.choice(target), of: .translationOtherLanguage, for: .translation)
        }
        translateAgain(Request(text: request.text, source: request.source, target: target))
    }

    /// Translates the text again in the languages picked for it, without waiting out the debounce.
    private func translateAgain(_ request: Request) {
        stopSpeaking()
        chosen = request
        work?.cancel()
        work = Task { [weak self] in await self?.translate(request.text) }
    }

    // MARK: Reading aloud

    /// Reads the translation of the text in the field aloud in a voice for its language, or stops
    /// reading it.
    func toggleSpeaking(query: String) {
        if isSpeaking { return stopSpeaking() }
        guard let translated = currentTranslation(query: query), let language = request?.target else { return }
        reading += 1
        let current = reading
        isSpeaking = true
        speaker.speak(translated, language: language) { [weak self] in
            guard let self, self.reading == current else { return }
            self.isSpeaking = false
        }
    }

    func stopSpeaking() {
        guard isSpeaking else { return }
        reading += 1
        isSpeaking = false
        speaker.stop()
    }

    // MARK: CapabilityPaletteContent

    /// One row, the translation, once it's back.
    func rowCount(query: String) -> Int {
        currentTranslation(query: query) == nil ? 0 : 1
    }

    /// Return copies the translation; ⌘Return pastes it, then puts the clipboard back.
    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions) {
        guard row == 0, let translated = currentTranslation(query: query) else { return }
        if withCommand {
            palette.paste(translated, true)
        } else {
            palette.copy(translated)
        }
    }

    func footerActions(row: Int, query: String) -> PaletteFooterActions {
        currentTranslation(query: query) == nil
            ? PaletteFooterActions(primary: nil, secondary: nil)
            : PaletteFooterActions(primary: "Copy", secondary: "Paste")
    }

    /// ⌘T swaps the languages and ⌘S reads aloud; both are the tab's even when there's nothing to
    /// do, so they never reach the search field.
    func handleCommandKey(_ characters: String, query: String) -> Bool {
        switch characters {
        case "t": swapLanguages(query: query)
        case "s": toggleSpeaking(query: query)
        default: return false
        }
        return true
    }

    /// Each showing starts empty, so languages downloaded meanwhile are tried again.
    func didShow(palette: PaletteContentActions) {
        reset()
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        let view = AnyView(TranslatePaletteResults(content: self, query: context.query))
        // Apple's Translation runs its sessions in the tab's view (`hostingSessions`).
        return translator?.hostingSessions(in: view) ?? view
    }
}

/// The Translate tab: the languages, "English → Japanese", with the target a menu and a swap
/// button, then the translation with a button that reads it aloud.
private struct TranslatePaletteResults: View {
    @Environment(\.holdCommandPaletteOpen) private var holdPaletteOpen
    @State private var holdID = UUID()
    let content: TranslatePaletteContent
    let query: String

    var body: some View {
        PaletteResultsContainer {
            if let reason = content.unavailableReason {
                PaletteEmptyState(title: reason, systemImage: "translate")
            } else if TranslatePaletteContent.text(of: query).isEmpty {
                PaletteEmptyState(title: "Type or paste text to translate it", systemImage: "translate")
                    .accessibilityIdentifier("palette.translate.empty")
            } else {
                result
            }
        }
        .onChange(of: query, initial: true) { content.update(query: query) }
        // The palette keeps this view while it's hidden; a translation stops when it closes, so it
        // doesn't hold the palette open, or reopen it on the download prompt.
        .onChange(of: holdPaletteOpen.closings) { content.stop() }
        .onAppear {
            let hold = holdPaletteOpen
            let id = holdID
            content.holdPaletteOpen = { hold(id, $0) }
        }
        .onDisappear {
            content.stop()
            holdPaletteOpen(holdID, false)
        }
    }

    private var result: some View {
        let isCurrent = content.currentTranslation(query: query) != nil
        return VStack(alignment: .leading, spacing: 12) {
            if let request = content.request {
                languages(request)
            }
            if let failure = content.failure {
                Text(failure)
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("palette.translate.failure")
                if content.needsDownload {
                    Button("Open Language & Region", systemImage: "gearshape") { content.openLanguageSettings() }
                        .buttonStyle(PalettePillButtonStyle(size: .regular, showsIcon: true))
                        .accessibilityIdentifier("palette.translate.openLanguageSettings")
                }
            } else if let translation = content.translation {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        Text(translation.text)
                            .font(.system(size: 20))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    // Earlier text's translation, until the new one is back.
                    .opacity(isCurrent ? 1 : 0.45)
                    .accessibilityIdentifier("palette.translate.translation")
                    speakButton
                        .disabled(!isCurrent)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// "English → Japanese": the source as text, the target a menu of the other languages, then
    /// the swap button.
    private func languages(_ request: TranslatePaletteContent.Request) -> some View {
        let canChange = content.canChangeLanguages(query: query)
        return HStack(spacing: 6) {
            Text(TranslationLanguages.name(for: request.source))
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityLabel("to")
            Menu {
                ForEach(content.targetChoices(query: query), id: \.code) { language in
                    Button(language.name) { content.chooseTarget(language.code, query: query) }
                }
            } label: {
                Text(TranslationLanguages.name(for: request.target))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(!canChange)
            .help("Choose the language to translate into")
            .accessibilityIdentifier("palette.translate.targetMenu")
            Button("Swap languages", systemImage: "arrow.left.arrow.right") { content.swapLanguages(query: query) }
                .buttonStyle(PalettePillButtonStyle(isCircular: true))
                .disabled(!canChange)
                .help("Swap languages (⌘T)")
                .accessibilityLabel("Swap languages")
                .accessibilityIdentifier("palette.translate.swap")
            if content.isTranslating {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette.translate.languages")
    }

    /// Reads the translation aloud, or stops it.
    private var speakButton: some View {
        let title = content.isSpeaking ? "Stop reading aloud" : "Read aloud"
        return Button(title, systemImage: content.isSpeaking ? "stop.fill" : "speaker.wave.2") {
            content.toggleSpeaking(query: query)
        }
        .buttonStyle(PalettePillButtonStyle(isCircular: true))
        .help("\(title) (⌘S)")
        .accessibilityLabel(title)
        .accessibilityIdentifier("palette.translate.speak")
    }
}
