import AppKit
import AVFoundation
import Foundation
import Observation
import Speech

enum DictationPhase: Equatable {
    case idle, recording, transcribing, inserting
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .inserting: "Inserting"
        case .failed: "Dictation failed"
        }
    }
}

enum DictationDurationLimit: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case sixtyMinutes = 3_600
    case unlimited = 0

    var id: Int { rawValue }
    var seconds: TimeInterval? { self == .unlimited ? nil : TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .sixtyMinutes: "60 minutes"
        case .unlimited: "No limit"
        }
    }
}

enum DictationTranscriptionSource: Equatable {
    case completedAudioFile
}

enum DictationTranscriptionPlan {
    static let source = DictationTranscriptionSource.completedAudioFile

    static func timeout(forRecordedDuration duration: TimeInterval) -> TimeInterval {
        max(120, duration * 2)
    }
}

struct DictationInsertionTarget: Equatable {
    let processIdentifier: pid_t
    private let bundleIdentifier: String?

    init(application: NSRunningApplication) {
        processIdentifier = application.processIdentifier
        bundleIdentifier = application.bundleIdentifier
    }

    func runningApplication() -> NSRunningApplication? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated,
              bundleIdentifier == nil || application.bundleIdentifier == bundleIdentifier else {
            return nil
        }
        return application
    }
}

@MainActor
@Observable
final class DictationService {
    private(set) var phase: DictationPhase = .idle
    private(set) var lastError: String?
    private(set) var recoveredTranscript: String?
    var selectedLanguage: String
    var onPhaseChange: ((DictationPhase) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var completion: CheckedContinuation<String, Error>?
    private var latestTranscript = ""
    private var inputTapInstalled = false
    private var destination: DictationInsertionTarget?
    private var audioFile: AVAudioFile?
    private var activeRecording: PendingDictationRecording?
    private var recordingStartedAt: Date?
    @ObservationIgnored private var durationTimer: Timer?
    @ObservationIgnored private var transcriptionTimeoutTask: Task<Void, Never>?
    private let recoveryURL: URL
    private let history: DictationHistoryService
    var durationLimit: DictationDurationLimit

    init(
        language: String,
        durationLimit: DictationDurationLimit = .fiveMinutes,
        fileManager: FileManager = .default,
        history: DictationHistoryService? = nil
    ) {
        selectedLanguage = language
        self.durationLimit = durationLimit
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SuperMac", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let recoveryURL = directory.appendingPathComponent("last-dictation.txt")
        self.recoveryURL = recoveryURL
        self.history = history ?? DictationHistoryService(fileManager: fileManager)
        recoveredTranscript = try? String(contentsOf: recoveryURL, encoding: .utf8)
    }

    var availableLanguages: [String] {
        SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .map(\.identifier)
            .sorted { left, right in
                let leftName = Locale.current.localizedString(forIdentifier: left) ?? left
                let rightName = Locale.current.localizedString(forIdentifier: right) ?? right
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
    }

    var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var speechGranted: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    func requestMicrophone() async { _ = await AVCaptureDevice.requestAccess(for: .audio) }
    func requestSpeech() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    func toggle() {
        switch phase {
        case .idle, .failed: start()
        case .recording: Task { await stopAndInsert() }
        case .transcribing, .inserting: break
        }
    }

    func start() {
        guard phase == .idle || isFailed else { return }
        guard microphoneGranted, speechGranted else {
            fail("Microphone and Speech Recognition permissions are required.")
            return
        }
        guard SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage))?.supportsOnDeviceRecognition == true else {
            fail("On-device speech is unavailable for \(selectedLanguage).")
            return
        }
        lastError = nil
        destination = NSWorkspace.shared.frontmostApplication.map(DictationInsertionTarget.init)
        latestTranscript = ""

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("The microphone has no usable audio format."); return }
        var preparedRecording: PendingDictationRecording?
        do {
            let recording = try history.prepareRecording()
            preparedRecording = recording
            let audioFile = try AVAudioFile(forWriting: recording.audioURL, settings: format.settings)
            activeRecording = recording
            recordingStartedAt = recording.capturedAt
            self.audioFile = audioFile
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                try? audioFile.write(from: buffer)
            }
        } catch {
            if let preparedRecording { history.discard(preparedRecording) }
            fail("The local recording file could not be created.")
            return
        }
        inputTapInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
            setPhase(.recording)
            scheduleDurationLimit()
        } catch { cleanup(); fail("The microphone could not start.") }
    }

    func cancel() {
        guard phase != .idle else { return }
        completion?.resume(throwing: CancellationError())
        completion = nil
        cleanup()
        setPhase(.idle)
    }

    func copyRecoveredTranscript() {
        guard let recoveredTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recoveredTranscript, forType: .string)
    }

    func clearRecoveredTranscript() {
        try? FileManager.default.removeItem(at: recoveryURL)
        recoveredTranscript = nil
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func stopAndInsert() async {
        setPhase(.transcribing)
        let recording = activeRecording
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        durationTimer?.invalidate()
        durationTimer = nil
        stopAudio()
        do {
            guard let recording else { throw CocoaError(.fileNoSuchFile) }
            let transcript = try await transcribeCompletedAudio(
                at: recording.audioURL,
                recordedDuration: duration
            )
            try transcript.write(to: recoveryURL, atomically: true, encoding: .utf8)
            recoveredTranscript = transcript
            try history.completeRecording(
                recording,
                text: transcript,
                language: selectedLanguage,
                duration: duration
            )
            activeRecording = nil
            recordingStartedAt = nil
            setPhase(.inserting)
            try await paste(transcript)
            cleanup()
            setPhase(.idle)
        } catch is CancellationError {
            cleanup(); setPhase(.idle)
        } catch {
            if let recording = activeRecording {
                _ = try? history.completeRecording(
                    recording,
                    text: latestTranscript,
                    language: selectedLanguage,
                    duration: duration,
                    transcriptionError: error.localizedDescription
                )
                activeRecording = nil
                recordingStartedAt = nil
                cleanup()
                fail("Transcription failed. The audio recording was preserved in Dictation History.")
            } else {
                cleanup(); fail(error.localizedDescription)
            }
        }
    }

    private func transcribeCompletedAudio(at audioURL: URL, recordedDuration: TimeInterval) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage)),
              recognizer.supportsOnDeviceRecognition else {
            throw NSError(domain: "SuperMac.Dictation", code: 5, userInfo: [NSLocalizedDescriptionKey: "On-device speech is unavailable for \(selectedLanguage)."])
        }
        latestTranscript = ""
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in self?.receive(result: result, error: error) }
            }
            transcriptionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(
                    DictationTranscriptionPlan.timeout(forRecordedDuration: recordedDuration)
                ))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.finishRecognition(error: NSError(
                        domain: "SuperMac.Dictation",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Transcription took too long. The audio recording was preserved."]
                    ))
                }
            }
        }
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            latestTranscript = result.bestTranscription.formattedString
            if result.isFinal { finishRecognition() }
        } else if let error, completion != nil {
            finishRecognition(error: error)
        }
    }

    private func finishRecognition(error: Error? = nil) {
        guard let completion else { return }
        self.completion = nil
        transcriptionTimeoutTask?.cancel()
        transcriptionTimeoutTask = nil
        if let error, latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion.resume(throwing: error)
            return
        }
        do { completion.resume(returning: try validatedTranscript()) }
        catch { completion.resume(throwing: error) }
    }

    private func validatedTranscript() throws -> String {
        let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NSError(domain: "SuperMac.Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech was detected."]) }
        return text
    }

    private func paste(_ text: String) async throws {
        guard let destination = destination?.runningApplication() else { throw NSError(domain: "SuperMac.Dictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "The destination app is no longer available. Your transcript was preserved."]) }
        destination.activate(options: [])
        try await Task.sleep(for: .milliseconds(160))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            throw NSError(domain: "SuperMac.Dictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "The destination app could not be focused. Your transcript was preserved."])
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw NSError(domain: "SuperMac.Dictation", code: 3, userInfo: [NSLocalizedDescriptionKey: "The transcript was preserved but could not be pasted."])
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    private func stopAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioFile = nil
    }

    private func cleanup() {
        durationTimer?.invalidate()
        durationTimer = nil
        transcriptionTimeoutTask?.cancel()
        transcriptionTimeoutTask = nil
        stopAudio()
        task?.cancel(); task = nil
        if let activeRecording {
            history.discard(activeRecording)
            self.activeRecording = nil
        }
        recordingStartedAt = nil
    }

    private func scheduleDurationLimit() {
        durationTimer?.invalidate()
        guard let seconds = durationLimit.seconds else { return }
        durationTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                await self.stopAndInsert()
            }
        }
    }

    private func fail(_ message: String) { lastError = message; setPhase(.failed(message)) }
    private func setPhase(_ phase: DictationPhase) { self.phase = phase; onPhaseChange?(phase) }
}
