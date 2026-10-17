import Foundation
import Testing
@testable import Keybumps

/// The models that detect the language.
private let detectingEngines: [DictationTranscriptionEngine] = [
    .whisperMediumMultilingual, .whisperTurboCompressed, .whisperCppTurbo,
]

/// #530: Dictation's Automatic language. It's the default, every model takes it, the models that
/// detect the language detect it per recording, the others fall back, and everything that needs
/// one language gets a real one.
@MainActor
@Suite("Dictation: Automatic language")
struct DictationAutomaticLanguageTests {
    private static let automatic = DictationLanguage.automatic

    // MARK: The default

    @Test("A new install starts on Automatic")
    func freshInstallDefaultsToAutomatic() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        #expect(preferences.dictationLanguage == Self.automatic)
    }

    @Test("An install that never saved a language moves to Automatic")
    func storedInstallWithoutTheKeyDefaultsToAutomatic() {
        let defaults = InMemoryDefaults()
        defaults.set(true, forKey: "didCompleteOnboarding")
        defaults.set("whisperCppTurbo", forKey: "dictationTranscriptionEngine")
        #expect(AppPreferences(defaults: defaults).dictationLanguage == Self.automatic)
    }

    @Test("A language someone saved is kept", arguments: ["en-US", "ja-JP"])
    func aSavedLanguageIsKept(_ saved: String) {
        let defaults = InMemoryDefaults()
        defaults.set(saved, forKey: "dictationLanguage")
        #expect(AppPreferences(defaults: defaults).dictationLanguage == saved)
    }

    @Test("Choosing Automatic is saved")
    func choosingAutomaticIsSaved() {
        let defaults = InMemoryDefaults()
        defaults.set("ja-JP", forKey: "dictationLanguage")
        AppPreferences(defaults: defaults).dictationLanguage = Self.automatic
        #expect(AppPreferences(defaults: defaults).dictationLanguage == Self.automatic)
    }

    // MARK: Each model

    @Test("Every model takes Automatic", arguments: DictationTranscriptionEngine.allCases)
    func everyModelTakesAutomatic(_ engine: DictationTranscriptionEngine) {
        #expect(engine.supports(language: Self.automatic))
    }

    @Test("Only the multilingual Whisper models detect the language")
    func onlyMultilingualWhisperDetects() {
        let detecting = DictationTranscriptionEngine.allCases.filter(\.detectsLanguage)
        #expect(detecting == detectingEngines)
    }

    @Test("A multilingual Whisper model is asked to detect", arguments: detectingEngines)
    func multilingualModelsDetect(_ engine: DictationTranscriptionEngine) {
        let request = DictationLanguage.request(Self.automatic, engine: engine) { "fr-FR" }
        #expect(request == Self.automatic)
    }

    @Test("Apple Speech uses the Mac's language")
    func appleSpeechUsesTheMacLanguage() {
        let request = DictationLanguage.request(Self.automatic, engine: .appleSpeech) { "fr-FR" }
        #expect(request == "fr-FR")
    }

    @Test("Whisper Medium English uses English")
    func mediumEnglishUsesEnglish() {
        let request = DictationLanguage.request(Self.automatic, engine: .whisperMediumEnglish) { "fr-FR" }
        #expect(request == "en-US")
    }

    @Test("A chosen language is never detected", arguments: DictationTranscriptionEngine.allCases)
    func aChosenLanguageIsKept(_ engine: DictationTranscriptionEngine) {
        #expect(DictationLanguage.request("ja-JP", engine: engine) == "ja-JP")
    }

    @Test("An empty setting counts as Automatic, so it never reaches a model")
    func anEmptySettingIsAutomatic() {
        let resolved = DictationLanguage.resolved("", engine: .appleSpeech) { "fr-FR" }
        #expect(DictationLanguage.request("", engine: .whisperCppTurbo) == Self.automatic)
        #expect(resolved == "fr-FR")
    }

    // MARK: The Mac's language

    @Test("The Mac's language is used where on-device speech supports it")
    func theMacLanguageWhenSupported() {
        let language = DictationLanguage.macLanguage(
            preferred: "ja-JP", region: nil, supported: ["en-US", "ja-JP"]
        ) { _ in true }
        #expect(language == "ja-JP")
    }

    @Test("The Mac's own region comes first", arguments: ["en-GB", "en"])
    func theMacRegionFirst(_ preferred: String) {
        let language = DictationLanguage.macLanguage(
            preferred: preferred, region: Locale.Region("GB"), supported: ["en-AU", "en-GB", "en-US"]
        ) { _ in true }
        #expect(language == "en-GB")
    }

    @Test("English when on-device speech doesn't support the Mac's language")
    func englishWhenUnsupported() {
        let language = DictationLanguage.macLanguage(
            preferred: "th-TH", region: nil, supported: ["en-US", "th-TH"]
        ) { $0 == "en-US" }
        #expect(language == "en-US")
    }

    @Test("English when the Mac names no language")
    func englishWithoutAPreferredLanguage() {
        let language = DictationLanguage.macLanguage(preferred: nil, region: nil, supported: ["ja-JP"]) { _ in true }
        #expect(language == "en-US")
    }

    // MARK: whisper.cpp

    @Test("Automatic asks whisper.cpp for auto, and reports what it detected")
    func whisperCppDetects() async throws {
        let runtime = LanguageWhisperCppRuntime(reported: "ja")
        let result = try await Self.whisperCpp(runtime).transcription(
            audioURL: URL(fileURLWithPath: "/dev/null"), language: Self.automatic, recordedDuration: 1
        )
        #expect(runtime.lastLanguage == "auto")
        #expect(result.language == "ja")
    }

    @Test("A chosen language is sent to whisper.cpp as its code and reported as chosen")
    func whisperCppKeepsAChosenLanguage() async throws {
        let runtime = LanguageWhisperCppRuntime(reported: "ja")
        let result = try await Self.whisperCpp(runtime).transcription(
            audioURL: URL(fileURLWithPath: "/dev/null"), language: "ja-JP", recordedDuration: 1
        )
        #expect(runtime.lastLanguage == "ja")
        #expect(result.language == "ja-JP")
    }

    @Test("whisper.cpp detecting nothing reports Automatic, for the coordinator to resolve")
    func whisperCppDetectingNothing() async throws {
        let runtime = LanguageWhisperCppRuntime(reported: nil)
        let result = try await Self.whisperCpp(runtime).transcription(
            audioURL: URL(fileURLWithPath: "/dev/null"), language: Self.automatic, recordedDuration: 1
        )
        #expect(result.language == Self.automatic)
    }

    @Test("whisper.cpp's language IDs read as its codes, without a model")
    func whisperCppLanguageCodes() {
        #expect(WhisperCppRuntime.languageCode(0) == "en")
        #expect(WhisperCppRuntime.languageCode(2) == "de")
        #expect(WhisperCppRuntime.languageCode(-1) == nil)
    }

    // MARK: WhisperKit

    @Test("Automatic asks WhisperKit to detect, with no language set")
    func whisperKitDetects() {
        let options = WhisperKitCompletedAudioTranscriber.decodingOptions(language: Self.automatic)
        #expect(options.detectLanguage)
        #expect(options.language == nil)
    }

    @Test("A chosen language is set for WhisperKit, which never detects it")
    func whisperKitKeepsAChosenLanguage() {
        let options = WhisperKitCompletedAudioTranscriber.decodingOptions(language: "ja-JP")
        #expect(!options.detectLanguage)
        #expect(options.language == "ja")
    }

    @Test("WhisperKit's language is the one most of the transcript is in")
    func whisperKitDominantLanguage() {
        let parts = [(language: "en", text: "OK"), (language: "ja", text: "made-up longer words")]
        #expect(WhisperKitCompletedAudioTranscriber.dominantLanguage(of: parts) == "ja")
        #expect(WhisperKitCompletedAudioTranscriber.dominantLanguage(of: []) == nil)
        #expect(WhisperKitCompletedAudioTranscriber.dominantLanguage(of: [("", "words")]) == nil)
    }

    // MARK: The coordinator

    @Test("The coordinator asks a multilingual model to detect, and returns its language")
    func coordinatorDetects() async throws {
        let fixture = try await CoordinatorFixture(engine: .whisperTurboCompressed, detects: "ja")
        defer { fixture.remove() }
        let result = try await fixture.transcribe(Self.automatic)
        #expect(fixture.whisper.languages == [Self.automatic])
        #expect(result.language == "ja")
    }

    @Test("The coordinator gives Whisper Medium English English")
    func coordinatorMediumEnglish() async throws {
        let fixture = try await CoordinatorFixture(engine: .whisperMediumEnglish, detects: "ja")
        defer { fixture.remove() }
        let result = try await fixture.transcribe(Self.automatic)
        #expect(fixture.whisper.languages == ["en-US"])
        #expect(result.language == "en-US")
    }

    @Test("The coordinator gives Apple Speech the Mac's language")
    func coordinatorAppleSpeech() async throws {
        let fixture = try await CoordinatorFixture(engine: .appleSpeech, detects: "ja")
        defer { fixture.remove() }
        let result = try await fixture.transcribe(Self.automatic)
        #expect(fixture.apple.languages == ["fr-FR"])
        #expect(result.language == "fr-FR")
    }

    @Test("A model that detects nothing leaves the Mac's language, never Automatic")
    func coordinatorDetectingNothing() async throws {
        let fixture = try await CoordinatorFixture(engine: .whisperTurboCompressed, detects: nil)
        defer { fixture.remove() }
        #expect(try await fixture.transcribe(Self.automatic).language == "fr-FR")
    }

    // MARK: History and the other readers

    @Test("The detected language reaches the history entry")
    func detectedLanguageReachesHistory() async throws {
        let session = try ServiceFixture(transcriber: FixedLanguageTranscriber(reports: "ja"))
        defer { session.remove() }
        try session.dictateOnce()
        await session.waitForTheEnd()
        let entry = try #require(session.history.entries.first)
        #expect(entry.recordedLanguageSetting == "ja")
        #expect(session.transcriber.languages == [Self.automatic])
    }

    @Test("A transcriber that reports Automatic as given still leaves a real language")
    func historyNeverRecordsAutomatic() async throws {
        let session = try ServiceFixture(transcriber: FixedLanguageTranscriber(reports: nil))
        defer { session.remove() }
        try session.dictateOnce()
        await session.waitForTheEnd()
        let entry = try #require(session.history.entries.first)
        #expect(!DictationLanguage.isAutomatic(entry.recordedLanguageSetting))
    }

    @Test("A failed Automatic entry reads as a real language, and its retry detects again")
    func failedAutomaticEntryRetriesWithAutomatic() async throws {
        let session = try ServiceFixture(transcriber: FixedLanguageTranscriber(reports: "ja"))
        defer { session.remove() }
        let failed = try session.failedEntry(language: Self.automatic)
        #expect(!DictationLanguage.isAutomatic(failed.language))
        #expect(failed.recordedLanguageSetting == Self.automatic)

        await session.service.transcribe(failed)

        #expect(session.transcriber.languages == [Self.automatic])
        #expect(session.history.entries.first?.language == "ja")
    }

    @Test("Translation gets a real source language from an unfinished Automatic entry")
    func translationGetsARealLanguage() throws {
        let session = try ServiceFixture(transcriber: FixedLanguageTranscriber(reports: "ja"))
        defer { session.remove() }
        let failed = try session.failedEntry(language: Self.automatic)
        let source = TranslationLanguagePolicy.sourceLanguageIdentifier(
            for: "", fallbackLanguageIdentifier: failed.language
        )
        #expect(!DictationLanguage.isAutomatic(source))
    }

    @Test("The on-device speech check gets a real language", arguments: [DictationLanguage.automatic, "", "ja-JP"])
    func onDeviceCheckGetsARealLanguage(_ setting: String) {
        let service = DictationService(language: setting, allowsSystemAccess: false)
        #expect(!DictationLanguage.isAutomatic(service.onDeviceSpeechLanguage))
    }

    // MARK: Settings

    @Test("Settings lists Automatic first, then the languages")
    func settingsListsAutomaticFirst() {
        let options = DictationLanguage.menuOptions(available: ["en-US", "ja-JP"])
        #expect(options.map(\.value) == [Self.automatic, "en-US", "ja-JP"])
        #expect(options.first?.label == "Automatic")
    }

    @Test("Settings says what Automatic uses with a model that can't detect")
    func settingsExplainsTheFallbacks() {
        let apple = DictationLanguage.automaticNote(engine: .appleSpeech, preferred: "fr-FR") { "fr-FR" }
        let english = DictationLanguage.automaticNote(engine: .whisperMediumEnglish)
        #expect(apple == "With Apple Speech, Automatic uses your Mac's language.")
        #expect(english == "With Whisper Medium English, Automatic uses English.")
    }

    @Test("Settings says when Apple Speech falls back to English")
    func settingsExplainsTheEnglishFallback() {
        let note = DictationLanguage.automaticNote(engine: .appleSpeech, preferred: "th-TH") { "en-US" }
        #expect(note?.hasPrefix("With Apple Speech, Automatic uses English") == true)
    }

    @Test("Settings adds no note for a model that detects", arguments: detectingEngines)
    func noNoteForDetectingModels(_ engine: DictationTranscriptionEngine) {
        #expect(DictationLanguage.automaticNote(engine: engine) == nil)
    }

    @Test("Whisper Medium English can be used with Automatic, and keeps it")
    func mediumEnglishIsNeverGreyedOut() async throws {
        let fixture = try await CoordinatorFixture(engine: .appleSpeech, detects: nil)
        defer { fixture.remove() }
        let model = fixture.appModel()
        model.selectDictationTranscriptionEngine(.whisperMediumEnglish)
        model.setDictationLanguage(Self.automatic)
        #expect(model.preferences.dictationTranscriptionEngine == .whisperMediumEnglish)
        #expect(model.preferences.dictationLanguage == Self.automatic)
    }

    // MARK: Helpers

    private static func whisperCpp(_ runtime: LanguageWhisperCppRuntime) -> WhisperCppCompletedAudioTranscriber {
        WhisperCppCompletedAudioTranscriber(runtime: runtime) { _ in [Float](repeating: 0.1, count: 16_000) }
    }
}

/// A whisper.cpp stand-in that keeps the language it was asked for and reports `reported`.
private final class LanguageWhisperCppRuntime: WhisperCppTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: String?
    private let reported: String?

    init(reported: String?) { self.reported = reported }

    var lastLanguage: String? { lock.withLock { asked } }

    func transcribe(samples: [Float], language: String, abort: WhisperCppAbortFlag) async throws -> WhisperCppTranscript {
        lock.withLock { asked = language }
        return WhisperCppTranscript(text: "made-up words", language: reported)
    }

    func free() async {}
}

/// Keeps the languages it was asked for. For Automatic it reports `reports`, as a model that
/// detects it would, or Automatic itself when `reports` is nil; a chosen language as given.
@MainActor
private final class FixedLanguageTranscriber: UnloadableCompletedAudioTranscribing {
    private let reports: String?
    private(set) var languages: [String] = []
    var partialTranscript: String { "" }

    init(reports: String?) { self.reports = reports }

    func transcribe(audioURL: URL, language: String, recordedDuration: TimeInterval) async throws -> String {
        try await transcription(audioURL: audioURL, language: language, recordedDuration: recordedDuration).text
    }

    func transcription(audioURL: URL, language: String, recordedDuration: TimeInterval) async throws -> DictationTranscription {
        languages.append(language)
        let detected = DictationLanguage.isAutomatic(language) ? reports : nil
        return DictationTranscription(text: "made-up words", language: detected ?? language)
    }

    func cancel() {}

    func unload() -> Task<Void, Never> { Task {} }
}

/// A coordinator over a made-up installed model for `engine`, with a stand-in Whisper runtime
/// that detects `detects`, an Apple Speech stand-in, and "fr-FR" as the Mac's language.
@MainActor
private final class CoordinatorFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsAutomaticLanguage-\(UUID().uuidString)", isDirectory: true)
    let manager: DictationModelManager
    let whisper: FixedLanguageTranscriber
    let apple: FixedLanguageTranscriber
    let coordinator: DictationTranscriptionCoordinator

    init(engine: DictationTranscriptionEngine, detects: String?) async throws {
        manager = DictationModelManager(modelsRoot: root, downloader: MadeUpModelDownloader())
        for model in [engine, .whisperMediumEnglish] where model.requiresDownload {
            await manager.download(model)
        }
        let whisper = FixedLanguageTranscriber(reports: detects)
        let apple = FixedLanguageTranscriber(reports: nil)
        self.whisper = whisper
        self.apple = apple
        coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { engine },
            modelManager: manager,
            appleTranscriber: apple,
            whisperFactory: { _ in whisper },
            macLanguage: { "fr-FR" }
        )
    }

    func transcribe(_ language: String) async throws -> DictationTranscription {
        try await coordinator.transcription(
            audioURL: root.appendingPathComponent("made-up.wav"), language: language, recordedDuration: 1
        )
    }

    func appModel() -> AppModel {
        AppModel(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            inbox: InboxStore(persistence: UpdaterTestEventPersistence()),
            presenceController: UpdaterTestPresenceController(),
            detector: ManualActionDetector(),
            updater: DisabledUpdateController(reason: "Unit test"),
            dictationModelManager: manager
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A Dictation service on Automatic in its own folder, whose sessions start without the
/// microphone. It has no system access, so a finished transcript ends in a failed insert.
@MainActor
private final class ServiceFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsAutomaticDictation-\(UUID().uuidString)", isDirectory: true)
    let history: DictationHistoryService
    let transcriber: FixedLanguageTranscriber
    let service: DictationService

    init(transcriber: FixedLanguageTranscriber) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        history = DictationHistoryService(
            recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true),
            appVersion: "test"
        )
        self.transcriber = transcriber
        service = DictationService(
            language: DictationLanguage.automatic,
            durationLimit: .unlimited,
            fileManager: RootedFileManager(root: root),
            history: history,
            transcriber: transcriber,
            allowsSystemAccess: false
        )
    }

    /// Records made-up audio, then stops, as the Dictation shortcut would.
    func dictateOnce() throws {
        let recording = try history.prepareRecording(language: service.selectedLanguage)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: recording.audioURL)
        service.beginSessionWithoutMicrophone(recording: recording)
        service.toggle()
    }

    func waitForTheEnd() async {
        for _ in 0..<500 {
            if case .failed = service.phase { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The dictation never ended; it's \(service.phase).")
    }

    func failedEntry(language: String) throws -> DictationHistoryEntry {
        let recording = try history.prepareRecording(language: language)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: recording.audioURL)
        return try history.completeRecording(
            recording, text: "", language: language, duration: 1, transcriptionError: "Made-up failure"
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class RootedFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}

/// Makes a folder holding every file a model needs, for whichever model is asked for.
private struct MadeUpModelDownloader: DictationModelDownloading {
    func downloadModel(
        identifier: String,
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
        for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return folder
    }
}
