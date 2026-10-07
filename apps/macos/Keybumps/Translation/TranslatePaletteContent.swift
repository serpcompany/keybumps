import SwiftUI

/// The Translate tab (#322): what's typed or pasted in the search field, translated as you type,
/// about 300 ms after the typing stops. Text in My language goes to Other language, and text in
/// any other language comes back to mine (`TranslationLanguagePair`).
///
/// For the text in the field (#362), ⌘T or the swap button swaps the two languages, and the
/// target's menu picks another; either lasts until the text changes. A target picked for text
/// detected in my language also becomes Other language.
///
/// Return saves the translation to recent translations (`RecentTranslations`, the last 50, kept on
/// this Mac) and clears the field; ⌘P saves it and pastes it into the app you were using, putting
/// the clipboard back (#362, #370). With the field empty, the tab lists them, newest first: Return
/// or ⌘C copies one, kept out of Clipboard History; ⌘P pastes it; Delete asks, then deletes it. Its
/// speaker button, or Space, reads it aloud (`TranslationSpeaking`) until the palette closes, the tab
/// or the text changes, another is read, or it's deleted.
@MainActor
@Observable
final class TranslatePaletteContent: CapabilityPaletteContent {
    /// How long typing has to stop before the text is translated.
    static let debounce: Duration = .milliseconds(300)

    let tab = CommandPaletteTab.translate
    /// Typing goes back to the first row: the translation, or the newest saved one once the field
    /// is cleared.
    let resetsSelectionWhileTyping = true

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
    /// The saved translation asked to be read aloud; `isReading(_:)` says whether it still is.
    private(set) var readingID: UUID?
    /// Why a saved translation couldn't be read aloud, such as no installed voice for its language.
    private(set) var speechProblem: SpeechProblem?

    struct SpeechProblem: Equatable {
        let id: UUID
        let message: String
    }

    /// The translations Return saved, listed while the field is empty.
    let recents: RecentTranslations
    @ObservationIgnored private let speaker: any TranslationSpeaking
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let translator: (any TextTranslating)?
    @ObservationIgnored private let wait: (Duration) async throws -> Void
    /// Reading a saved translation aloud, until it starts; tests await it.
    @ObservationIgnored private(set) var reading: Task<Void, Never>?
    /// Changes whenever reading stops, so a reading that starts late is dropped.
    @ObservationIgnored private var readingGeneration = 0
    /// Languages picked for one text, by swapping or from the target's menu, in place of detection
    /// until the text changes.
    @ObservationIgnored private var chosen: Request?
    /// The debounce and translation for the latest text; tests await it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    /// Opens System Settings on Language & Region, where Translation Languages are downloaded.
    @ObservationIgnored var openLanguageSettings: @MainActor () -> Void = {}
    /// Holds the palette open against clicks in Keybumps's other windows
    /// (`holdCommandPaletteOpen`) while a translation runs. The tab's view sets it.
    @ObservationIgnored var holdPaletteOpen: @MainActor (Bool) -> Void = { _ in }

    /// `wait` sleeps out the debounce; tests pass their own.
    init(
        preferences: AppPreferences,
        translator: (any TextTranslating)?,
        recents: RecentTranslations,
        speaker: any TranslationSpeaking,
        wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.preferences = preferences
        self.translator = translator
        self.recents = recents
        self.speaker = speaker
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
    /// one. Reading aloud stops, since the list goes or is about to.
    func update(query: String) {
        stopReading()
        work?.cancel()
        work = nil
        let text = Self.text(of: query)
        guard isAvailable, !text.isEmpty else { return reset() }
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

    /// Stops a translation on its way, and reading aloud, as when the palette closes or Translation
    /// is turned off.
    func stop() {
        work?.cancel()
        work = nil
        setTranslating(false)
        stopReading()
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
    /// The current target is among them, marked in the menu.
    func targetChoices(query: String) -> [TranslationLanguages.Language] {
        guard let request = currentRequest(query: query) else { return [] }
        let source = TranslationLanguagePair.code(request.source)
        return TranslationLanguages.offered.filter { $0.code != source }
    }

    /// Translates the text in the field into `target` at once. When the text was detected in my
    /// language, and not swapped, `target` also becomes Other language, as in Settings, so my
    /// language goes there from now on. Otherwise the pick lasts only until the text changes, and
    /// the setting stays: text in another language comes back to mine, and a swapped source isn't
    /// what the text is written in.
    func chooseTarget(_ target: String, query: String) {
        guard let request = currentRequest(query: query), TranslationLanguages.isOffered(target) else { return }
        let target = TranslationLanguagePair.code(target)
        let source = TranslationLanguagePair.code(request.source)
        guard target != source, target != TranslationLanguagePair.code(request.target) else { return }
        let mine = preferences.translationLanguagePair.mine
        if source == mine, TranslationLanguagePair.code(detectedRequest(for: request.text).source) == mine {
            preferences.set(.choice(target), of: .translationOtherLanguage, for: .translation)
        }
        translateAgain(Request(text: request.text, source: request.source, target: target))
    }

    /// Translates the text again in the languages picked for it, without waiting out the debounce.
    private func translateAgain(_ request: Request) {
        chosen = request
        work?.cancel()
        work = Task { [weak self] in await self?.translate(request.text) }
    }

    // MARK: Recent translations

    /// The saved translation a row lists: the field is empty, so the tab lists them.
    func record(row: Int, query: String) -> TranslationRecord? {
        guard isAvailable, Self.text(of: query).isEmpty, recents.records.indices.contains(row) else { return nil }
        return recents.records[row]
    }

    /// "English → Japanese"
    static func languages(of record: TranslationRecord) -> String {
        "\(TranslationLanguages.name(for: record.sourceLanguage)) → \(TranslationLanguages.name(for: record.targetLanguage))"
    }

    /// Saves the translation of the text in the field, once it's back.
    private func saveCurrentTranslation(query: String) -> TranslationRecord? {
        guard let translated = currentTranslation(query: query), let request else { return nil }
        return recents.save(request.text, translated: translated, from: request.source, to: request.target)
    }

    /// Deletes a saved translation, and stops reading it aloud.
    func deleteRecord(_ id: UUID) {
        if readingID == id {
            stopReading()
        } else if speechProblem?.id == id {
            speechProblem = nil
        }
        recents.delete(id)
    }

    // MARK: Reading aloud

    /// Whether a saved translation is being read aloud, or getting ready to be.
    func isReading(_ id: UUID) -> Bool {
        readingID == id && speaker.isSpeaking
    }

    /// Reads a saved translation aloud in a voice for its target language, stopping anything
    /// being read. Asked again while it's reading, it stops. With no installed voice for the
    /// language, it says so on the row instead.
    func readAloud(_ id: UUID) {
        guard let record = recents.records.first(where: { $0.id == id }) else { return }
        let wasReading = isReading(id)
        stopReading()
        guard !wasReading else { return }
        readingID = id
        let speaker = speaker
        let generation = readingGeneration
        reading = Task { [weak self] in
            let problem = await speaker.speak(record.translatedText, language: record.targetLanguage)
            // Stopped, or another asked for, meanwhile.
            guard let self, self.readingGeneration == generation, let problem else { return }
            self.readingID = nil
            self.speechProblem = SpeechProblem(id: id, message: problem)
        }
    }

    /// Stops reading aloud, and forgets why the last one couldn't be read.
    func stopReading() {
        readingGeneration += 1
        reading = nil
        speechProblem = nil
        guard readingID != nil else { return }
        readingID = nil
        speaker.stop()
    }

    // MARK: CapabilityPaletteContent

    /// With text in the field, one row, its translation, once it's back. With the field empty, the
    /// saved translations.
    func rowCount(query: String) -> Int {
        guard isAvailable else { return 0 }
        if Self.text(of: query).isEmpty { return recents.records.count }
        return currentTranslation(query: query) == nil ? 0 : 1
    }

    /// On the translation: Return saves it and clears the field, leaving it highlighted at the top
    /// of the list. On a saved translation: Return copies it, kept out of Clipboard History.
    func activate(row: Int, query: String, palette: PaletteContentActions) {
        if record(row: row, query: query) != nil {
            copy(row: row, query: query, palette: palette)
            return
        }
        guard row == 0, saveCurrentTranslation(query: query) != nil else { return }
        palette.clearQuery()
        palette.selectRow(0)
    }

    /// ⌘C copies a saved translation, kept out of Clipboard History. The translation being typed
    /// isn't saved yet, so ⌘C there does nothing.
    func copy(row: Int, query: String, palette: PaletteContentActions) {
        guard let record = record(row: row, query: query) else { return }
        palette.copy(record.translatedText)
    }

    /// ⌘P pastes a saved translation, or saves the translation being typed and pastes it, then
    /// puts the clipboard back.
    func paste(row: Int, query: String, palette: PaletteContentActions) {
        if let record = record(row: row, query: query) {
            palette.paste(record.translatedText, true)
            return
        }
        guard row == 0, let record = saveCurrentTranslation(query: query) else { return }
        palette.paste(record.translatedText, true)
    }

    /// Space on a saved translation reads it aloud, or stops reading it.
    func playback(row: Int, query: String) -> PalettePlayback? {
        guard let id = record(row: row, query: query)?.id else { return nil }
        return PalettePlayback(title: isReading(id) ? "Stop Reading" : "Read Aloud") { [weak self] in
            self?.readAloud(id)
        }
    }

    /// A saved translation's Delete asks first, as a recording's does.
    func deletionConfirmation(row: Int, query: String) -> PaletteDeletionConfirmation? {
        guard let id = record(row: row, query: query)?.id else { return nil }
        return PaletteDeletionConfirmation(
            title: "Delete this translation?",
            message: "It will be removed from this Mac.",
            delete: { [weak self] in self?.deleteRecord(id) }
        )
    }

    func footerActions(row: Int, query: String) -> PaletteFooterActions {
        if record(row: row, query: query) != nil {
            return PaletteFooterActions(primary: "Copy", secondary: [.paste()])
        }
        return currentTranslation(query: query) == nil
            ? PaletteFooterActions(primary: nil)
            : PaletteFooterActions(primary: "Save", secondary: [.paste("Save and Paste")])
    }

    /// ⌘T swaps the languages. It's the tab's even with nothing to swap, so it never reaches the
    /// search field.
    var commandKeys: Set<String> { ["t"] }

    func handleCommandKey(_ characters: String, query: String) {
        if characters == "t" { swapLanguages(query: query) }
    }

    /// Each showing starts empty, so languages downloaded meanwhile are tried again.
    func didShow(palette: PaletteContentActions) {
        reset()
    }

    /// The palette closed or went to another tab: translating and reading aloud stop.
    func didHide() {
        stop()
    }

    func makeView(_ context: PaletteContentContext) -> AnyView {
        let view = AnyView(TranslatePaletteResults(
            content: self,
            query: context.query,
            selection: context.selection,
            actions: context.actions
        ))
        // Apple's Translation runs its sessions in the tab's view (`hostingSessions`).
        return translator?.hostingSessions(in: view) ?? view
    }
}

/// The Translate tab: with text in the field, the languages, "English → Japanese", with the target
/// a menu and a swap button, then the translation. With the field empty, recent translations.
private struct TranslatePaletteResults: View {
    @Environment(\.holdCommandPaletteOpen) private var holdPaletteOpen
    @State private var holdID = UUID()
    let content: TranslatePaletteContent
    let query: String
    let selection: Int
    let actions: PaletteContentActions

    var body: some View {
        PaletteResultsContainer {
            if let reason = content.unavailableReason {
                PaletteEmptyState(title: reason, systemImage: "translate")
            } else if TranslatePaletteContent.text(of: query).isEmpty {
                if content.recents.records.isEmpty {
                    PaletteEmptyState(title: "Type or paste text to translate it", systemImage: "translate")
                        .accessibilityIdentifier("palette.translate.empty")
                } else {
                    RecentTranslationList(content: content, selection: selection, actions: actions)
                }
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

    /// "English → Japanese": the source as text, the target a menu of the other languages with the
    /// current one checked, then the swap button.
    private func languages(_ request: TranslatePaletteContent.Request) -> some View {
        let canChange = content.canChangeLanguages(query: query)
        let target = TranslationLanguages.name(for: request.target)
        let picked = Binding(
            get: { TranslationLanguagePair.code(request.target) },
            set: { content.chooseTarget($0, query: query) }
        )
        return HStack(spacing: 6) {
            Text(TranslationLanguages.name(for: request.source))
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityLabel("to")
            Menu {
                Picker("Translate into", selection: picked) {
                    ForEach(content.targetChoices(query: query), id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(target)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(!canChange)
            .help("Choose the language to translate into")
            .accessibilityLabel("Translate into \(target)")
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
}

/// Recent translations, newest first, listed like the Dictation tab's recordings: a click
/// highlights a row and a double-click copies it. The highlighted row, and the one being read,
/// shows its speaker button.
private struct RecentTranslationList: View {
    let content: TranslatePaletteContent
    let selection: Int
    let actions: PaletteContentActions

    var body: some View {
        let records = content.recents.records
        VStack(spacing: 0) {
            HStack {
                PaletteSectionHeader("Recent Translations")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                List(Array(records.enumerated()), id: \.element.id) { index, record in
                    row(record, index: index)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .paletteHoverHighlights(row: index)
                        .paletteRowBackground(isSelected: index == selection)
                        .id(record.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .paletteScrollsToSelection(selection, proxy: proxy) { records.indices.contains($0) ? records[$0].id : nil }
            }
        }
    }

    private func row(_ record: TranslationRecord, index: Int) -> some View {
        let isReading = content.isReading(record.id)
        let showsSpeaker = index == selection || isReading
        return HStack(spacing: 0) {
            Button { actions.selectRow(index) } label: {
                RecentTranslationRow(
                    record: record,
                    problem: content.speechProblem?.id == record.id ? content.speechProblem?.message : nil
                )
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { actions.copy(record.translatedText) })

            // Its place is kept on every row, so a row's text doesn't move as the highlight does.
            Button(isReading ? "Stop Reading" : "Read Aloud", systemImage: isReading ? "stop.fill" : "speaker.wave.2") {
                content.readAloud(record.id)
            }
            .buttonStyle(PalettePillButtonStyle(isCircular: true))
            .help(isReading ? "Stop reading (Space)" : "Read aloud (Space)")
            .accessibilityIdentifier("palette.translate.readAloud")
            .opacity(showsSpeaker ? 1 : 0)
            .allowsHitTesting(showsSpeaker)
            .accessibilityHidden(!showsSpeaker)
            .padding(.trailing, 12)
        }
    }
}

/// A saved translation's row, in the Dictation tab's look: the translation, then what was typed and
/// its languages, and why it couldn't be read aloud, if it couldn't.
private struct RecentTranslationRow: View {
    let record: TranslationRecord
    let problem: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "translate")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(PaletteTheme.keycapFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.translatedText)
                    .font(.system(size: 14))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(record.sourceText)
                        .lineLimit(1)
                    Text("·")
                        .accessibilityHidden(true)
                    Text(TranslatePaletteContent.languages(of: record))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("palette.translate.recent")
    }
}
