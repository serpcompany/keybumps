import Foundation
import Speech

@MainActor
protocol CompletedAudioTranscribing: AnyObject {
    var partialTranscript: String { get }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String

    /// Gets ready for a dictation that has started recording, such as by loading a model, so the
    /// wait after the recording stops is shorter. It must not block, and failures are left for
    /// `transcribe` to report.
    func prepare(language: String)

    func cancel()
}

extension CompletedAudioTranscribing {
    func prepare(language: String) {}
}

@MainActor
protocol UnloadableCompletedAudioTranscribing: CompletedAudioTranscribing {
    @discardableResult
    func unload() -> Task<Void, Never>
}

@MainActor
protocol DictationRuntimeIdleCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol DictationRuntimeIdleScheduling {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any DictationRuntimeIdleCancellation
}

@MainActor
private final class TaskDictationRuntimeIdleCancellation: DictationRuntimeIdleCancellation {
    private var task: Task<Void, Never>?

    init(delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
struct TaskDictationRuntimeIdleScheduler: DictationRuntimeIdleScheduling {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any DictationRuntimeIdleCancellation {
        TaskDictationRuntimeIdleCancellation(delay: delay, operation: operation)
    }
}

@MainActor
final class AppleSpeechCompletedAudioTranscriber: CompletedAudioTranscribing {
    private var task: SFSpeechRecognitionTask?
    private var completion: CheckedContinuation<String, Error>?
    private var transcriptAssembler = DictationTranscriptAssembler()
    private var timeoutTask: Task<Void, Never>?

    var partialTranscript: String { transcriptAssembler.transcript }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else {
            throw NSError(
                domain: "Keybumps.Dictation",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "On-device speech is unavailable for \(language)."]
            )
        }

        transcriptAssembler = DictationTranscriptAssembler()
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in self?.receive(result: result, error: error) }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(
                    DictationTranscriptionPlan.timeout(forRecordedDuration: recordedDuration)
                ))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.finish(error: NSError(
                        domain: "Keybumps.Dictation",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Transcription took too long. The audio recording was preserved."]
                    ))
                }
            }
        }
    }

    func cancel() {
        completion?.resume(throwing: CancellationError())
        completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        task?.cancel()
        task = nil
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let segments = result.bestTranscription.segments
            transcriptAssembler.receive(DictationTranscriptUpdate(
                text: result.bestTranscription.formattedString,
                segmentStart: segments.first?.timestamp ?? 0,
                segmentEnd: segments.last.map { $0.timestamp + $0.duration } ?? 0,
                isFinal: result.isFinal
            ))
            if result.isFinal { finish() }
        } else if let error, completion != nil {
            finish(error: error)
        }
    }

    private func finish(error: Error? = nil) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        task = nil

        if let error {
            completion.resume(throwing: error)
            return
        }

        let transcript = transcriptAssembler.transcript
        guard !transcript.isEmpty else {
            completion.resume(throwing: NSError(
                domain: "Keybumps.Dictation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No speech was detected."]
            ))
            return
        }
        completion.resume(returning: transcript)
    }
}

@MainActor
final class DictationTranscriptionCoordinator: CompletedAudioTranscribing {
    typealias WhisperFactory = @MainActor (URL) async throws -> any UnloadableCompletedAudioTranscribing

    private let selectedEngine: () -> DictationTranscriptionEngine
    private let modelManager: DictationModelManager
    private let appleTranscriber: any CompletedAudioTranscribing
    private let whisperFactory: WhisperFactory
    private let idleScheduler: any DictationRuntimeIdleScheduling
    private let idleTimeout: TimeInterval
    private var activeTranscriber: (any CompletedAudioTranscribing)?
    private var cachedWhisper: (modelFolder: URL, transcriber: any UnloadableCompletedAudioTranscribing)?
    private var pendingWhisper: (
        modelFolder: URL,
        token: UUID,
        task: Task<any UnloadableCompletedAudioTranscribing, Error>
    )?
    private var unloadingWhisper: (token: UUID, task: Task<Void, Never>)?
    private var idleCancellation: (any DictationRuntimeIdleCancellation)?

    var partialTranscript: String { activeTranscriber?.partialTranscript ?? "" }

    init(
        selectedEngine: @escaping () -> DictationTranscriptionEngine,
        modelManager: DictationModelManager,
        appleTranscriber: (any CompletedAudioTranscribing)? = nil,
        whisperFactory: WhisperFactory? = nil,
        idleScheduler: (any DictationRuntimeIdleScheduling)? = nil,
        idleTimeout: TimeInterval = 300
    ) {
        self.selectedEngine = selectedEngine
        self.modelManager = modelManager
        self.appleTranscriber = appleTranscriber ?? AppleSpeechCompletedAudioTranscriber()
        self.whisperFactory = whisperFactory ?? { try await WhisperKitCompletedAudioTranscriber.load(modelFolder: $0) }
        self.idleScheduler = idleScheduler ?? TaskDictationRuntimeIdleScheduler()
        self.idleTimeout = idleTimeout
    }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        let transcriber: any CompletedAudioTranscribing

        if let modelFolder = installedWhisperModelFolder(language: language) {
            if let cachedWhisper,
               cachedWhisper.modelFolder.standardizedFileURL == modelFolder.standardizedFileURL {
                transcriber = cachedWhisper.transcriber
            } else {
                evictWhisperRuntimeIfModelChanged(to: modelFolder)
                transcriber = try await loadWhisper(modelFolder: modelFolder)
            }
        } else {
            if cachedWhisper != nil || pendingWhisper != nil {
                evictWhisperRuntime()
            }
            transcriber = appleTranscriber
        }

        let isWhisper = transcriber is any UnloadableCompletedAudioTranscribing
        if isWhisper {
            idleCancellation?.cancel()
            idleCancellation = nil
        }
        activeTranscriber = transcriber
        defer { activeTranscriber = nil }
        do {
            let transcript = try await transcriber.transcribe(
                audioURL: audioURL,
                language: language,
                recordedDuration: recordedDuration
            )
            if isWhisper { scheduleIdleEviction() }
            return transcript
        } catch {
            if isWhisper { scheduleIdleEviction() }
            throw error
        }
    }

    /// Starts loading the selected Whisper model while the person is still talking, so the
    /// transcription that follows joins the load instead of starting it. The idle unload waits
    /// until the recording ends in a transcription or a cancel.
    func prepare(language: String) {
        guard let modelFolder = installedWhisperModelFolder(language: language) else { return }
        idleCancellation?.cancel()
        idleCancellation = nil
        let standardizedFolder = modelFolder.standardizedFileURL
        if cachedWhisper?.modelFolder.standardizedFileURL == standardizedFolder
            || pendingWhisper?.modelFolder.standardizedFileURL == standardizedFolder {
            return
        }
        evictWhisperRuntimeIfModelChanged(to: modelFolder)
        Task { [weak self] in
            // A failed load is cleared in `loadWhisper`, and `transcribe` loads again and reports it.
            _ = try? await self?.loadWhisper(modelFolder: modelFolder)
        }
    }

    func cancel() {
        if let activeTranscriber {
            activeTranscriber.cancel()
            return
        }
        // A recording that loaded a model and then ended without a transcription still unloads it
        // after the idle timeout.
        if (cachedWhisper != nil || pendingWhisper != nil), idleCancellation == nil {
            scheduleIdleEviction()
        }
    }

    func selectedModelDidChange() {
        evictWhisperRuntime()
    }

    func selectedModelWasDeleted() {
        evictWhisperRuntime()
    }

    private func evictWhisperRuntime() {
        idleCancellation?.cancel()
        idleCancellation = nil
        let previousUnload = unloadingWhisper?.task
        let pendingLoad = pendingWhisper?.task
        pendingLoad?.cancel()
        pendingWhisper = nil
        let cachedUnload = cachedWhisper?.transcriber.unload()
        cachedWhisper = nil
        guard previousUnload != nil || pendingLoad != nil || cachedUnload != nil else { return }
        let unloadTask = Task { @MainActor in
            if let previousUnload { await previousUnload.value }
            if let pendingLoad,
               let loaded = try? await pendingLoad.value {
                await loaded.unload().value
            }
            if let cachedUnload { await cachedUnload.value }
        }
        unloadingWhisper = (UUID(), unloadTask)
    }

    private func installedWhisperModelFolder(language: String) -> URL? {
        let engine = selectedEngine()
        guard engine.requiresDownload, engine.supports(language: language) else { return nil }
        return modelManager.installedModelFolder(for: engine)
    }

    private func evictWhisperRuntimeIfModelChanged(to modelFolder: URL) {
        let standardizedFolder = modelFolder.standardizedFileURL
        let cachedModelChanged = cachedWhisper.map {
            $0.modelFolder.standardizedFileURL != standardizedFolder
        } ?? false
        let pendingModelChanged = pendingWhisper.map {
            $0.modelFolder.standardizedFileURL != standardizedFolder
        } ?? false
        if cachedModelChanged || pendingModelChanged {
            evictWhisperRuntime()
        }
    }

    private func scheduleIdleEviction() {
        idleCancellation?.cancel()
        idleCancellation = idleScheduler.schedule(after: idleTimeout) { [weak self] in
            self?.evictWhisperRuntime()
        }
    }

    private func loadWhisper(modelFolder: URL) async throws -> any UnloadableCompletedAudioTranscribing {
        let standardizedFolder = modelFolder.standardizedFileURL
        if let pendingWhisper,
           pendingWhisper.modelFolder.standardizedFileURL == standardizedFolder {
            return try await pendingWhisper.task.value
        }

        if let unloadingWhisper {
            await unloadingWhisper.task.value
            if self.unloadingWhisper?.token == unloadingWhisper.token {
                self.unloadingWhisper = nil
            }
            if let cachedWhisper,
               cachedWhisper.modelFolder.standardizedFileURL == standardizedFolder {
                return cachedWhisper.transcriber
            }
            if let pendingWhisper,
               pendingWhisper.modelFolder.standardizedFileURL == standardizedFolder {
                return try await pendingWhisper.task.value
            }
        }

        let token = UUID()
        let factory = whisperFactory
        let task = Task<any UnloadableCompletedAudioTranscribing, Error> {
            try await factory(modelFolder)
        }
        pendingWhisper = (modelFolder, token, task)

        do {
            let loaded = try await task.value
            if pendingWhisper?.token == token {
                pendingWhisper = nil
                cachedWhisper = (modelFolder, loaded)
                return loaded
            }
            if let cachedWhisper,
               cachedWhisper.modelFolder.standardizedFileURL == standardizedFolder {
                return cachedWhisper.transcriber
            } else if let unloadingWhisper {
                await unloadingWhisper.task.value
                throw CancellationError()
            } else {
                await loaded.unload().value
                throw CancellationError()
            }
        } catch {
            if pendingWhisper?.token == token {
                pendingWhisper = nil
            }
            throw error
        }
    }
}
