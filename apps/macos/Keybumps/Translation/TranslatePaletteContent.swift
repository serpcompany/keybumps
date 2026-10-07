import SwiftUI

/// The Translate tab (#322): what's typed or pasted in the search field, translated as you type,
/// about 300 ms after the typing stops. Text in My language goes to Other language, and text in
/// any other language comes back to mine (`TranslationLanguagePair`). Return copies the translation,
/// kept out of Clipboard History; ⌘Return pastes it into the app you were using and puts the
/// clipboard back. Translations aren't kept anywhere.
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
    /// Whether a translation is on its way. The palette stays open meanwhile, through a language's
    /// download prompt.
    private(set) var isTranslating = false

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let translator: (any TextTranslating)?
    @ObservationIgnored private let wait: (Duration) async throws -> Void
    /// The debounce and translation for the latest text; tests await it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    /// The language pairs whose download was declined since the tab showed, so typing on doesn't
    /// show the download prompt again and again.
    @ObservationIgnored private var declined: Set<[String]> = []
    /// Holds the palette open against clicks in Keybumps's other windows, such as the download
    /// prompt (`holdCommandPaletteOpen`), while a translation runs. The tab's view sets it.
    @ObservationIgnored var holdPaletteOpen: @MainActor (Bool) -> Void = { _ in }

    /// `wait` sleeps out the debounce; tests pass their own.
    init(
        preferences: AppPreferences,
        translator: (any TextTranslating)?,
        wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.preferences = preferences
        self.translator = translator
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
        let pair = preferences.translationLanguagePair
        let source = TranslationLanguagePolicy.sourceLanguageIdentifier(for: text, fallbackLanguageIdentifier: pair.mine)
        let request = Request(text: text, source: source, target: pair.target(forSourceIdentifier: source))
        self.request = request
        failure = nil
        let languages = [TranslationLanguagePair.code(request.source), request.target]
        guard !declined.contains(languages) else {
            failure = Self.message(for: .notDownloaded, request: request)
            return setTranslating(false)
        }
        setTranslating(true)
        do {
            let translated = try await translator.translate(text, from: request.source, to: request.target)
            guard !Task.isCancelled, self.request == request else { return }
            translation = Translation(request: request, text: translated)
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            let reason = error as? TranslateFailure ?? .failed
            if reason == .notDownloaded { declined.insert(languages) }
            translation = nil
            failure = Self.message(for: reason, request: request)
        }
        setTranslating(false)
    }

    private func setTranslating(_ translating: Bool) {
        guard translating != isTranslating else { return }
        isTranslating = translating
        holdPaletteOpen(translating)
    }

    /// Stops a translation on its way, as when the palette closes or Translation is turned off.
    func stop() {
        work?.cancel()
        work = nil
        setTranslating(false)
    }

    private func reset() {
        stop()
        request = nil
        translation = nil
        failure = nil
    }

    static func message(for failure: TranslateFailure, request: Request) -> String {
        let source = TranslationLanguages.name(for: request.source)
        let target = TranslationLanguages.name(for: request.target)
        return switch failure {
        case .unsupportedPair: "Can’t translate \(source) into \(target) on this Mac."
        case .notDownloaded: "\(source) and \(target) weren’t downloaded. Open Translate again to download them."
        case .failed: "Translation couldn’t be completed."
        }
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

    /// Each showing starts empty, and may ask again for a download declined before.
    func didShow(palette: PaletteContentActions) {
        reset()
        declined = []
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        let view = AnyView(TranslatePaletteResults(content: self, query: context.query))
        // Apple's Translation runs its sessions in the tab's view (`hostingSessions`).
        return translator?.hostingSessions(in: view) ?? view
    }
}

/// The Translate tab: the languages, "English → Japanese", then the translation.
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
                HStack(spacing: 6) {
                    Text(TranslationLanguages.name(for: request.source))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityLabel("to")
                    Text(TranslationLanguages.name(for: request.target))
                    if content.isTranslating {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("palette.translate.languages")
            }
            if let failure = content.failure {
                Text(failure)
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("palette.translate.failure")
            } else if let translation = content.translation {
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
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }
}
