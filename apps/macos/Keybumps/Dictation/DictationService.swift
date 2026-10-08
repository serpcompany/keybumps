import AppKit
import ApplicationServices
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

struct DictationTranscriptUpdate: Equatable {
    let text: String
    let segmentStart: TimeInterval
    let segmentEnd: TimeInterval
    let isFinal: Bool

    fileprivate var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var hasStableTiming: Bool {
        segmentEnd > segmentStart && segmentEnd > 0
    }
}

struct DictationTranscriptAssembler {
    private var completedSpans: [String] = []
    private var activeUpdate: DictationTranscriptUpdate?

    var transcript: String {
        (completedSpans + [activeUpdate?.normalizedText].compactMap { $0 })
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func receive(_ update: DictationTranscriptUpdate) {
        guard !update.normalizedText.isEmpty else { return }

        if let activeUpdate, beginsNewSpan(after: activeUpdate, with: update) {
            commit(activeUpdate)
        }
        activeUpdate = update

        if update.isFinal {
            commit(update)
            activeUpdate = nil
        }
    }

    private func beginsNewSpan(
        after previous: DictationTranscriptUpdate,
        with incoming: DictationTranscriptUpdate
    ) -> Bool {
        if previous.hasStableTiming,
           incoming.hasStableTiming,
           incoming.segmentStart > previous.segmentEnd {
            return true
        }

        let previousCount = previous.normalizedText.count
        let incomingCount = incoming.normalizedText.count
        return previous.hasStableTiming && incomingCount * 2 < previousCount
    }

    private mutating func commit(_ update: DictationTranscriptUpdate) {
        let text = update.normalizedText
        guard !text.isEmpty, completedSpans.last != text else { return }
        completedSpans.append(text)
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

/// Why Dictation couldn't put a finished transcript at the original cursor. Each one happens after
/// the transcript is saved to Dictation History and the recovery file, so none of them loses it.
enum DictationInsertionError: Error, Equatable, LocalizedError {
    case unavailableInSession
    case accessibilityRequired
    case destinationUnavailable
    case destinationNotFocused
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .unavailableInSession: "Insertion is unavailable in this session. Your transcript was preserved."
        case .accessibilityRequired: "Dictation needs Accessibility access to paste. Your transcript was preserved."
        case .destinationUnavailable: "The destination app is no longer available. Your transcript was preserved."
        case .destinationNotFocused: "The destination app could not be focused. Your transcript was preserved."
        case .pasteFailed: "The transcript was preserved but could not be pasted."
        }
    }
}

@MainActor
@Observable
final class DictationService {
    private(set) var phase: DictationPhase = .idle
    private(set) var lastError: String?
    private(set) var recoveredTranscript: String?
    private(set) var retryingEntryID: String?
    var selectedLanguage: String
    var onPhaseChange: ((DictationPhase) -> Void)?
    /// The microphone's loudness while recording, 0 (silence) to 1, on the main actor.
    var onInputLevel: ((Float) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var inputTapInstalled = false
    private var destination: DictationInsertionTarget?
    private var audioFile: AVAudioFile?
    private var activeRecording: PendingDictationRecording?
    private var recordingStartedAt: Date?
    /// Changes when a dictation session starts or is cancelled, so a stop still waiting on its
    /// transcription can tell that the state now belongs to another session (#281).
    private var session = 0
    @ObservationIgnored private var durationTimer: Timer?
    /// The last transcript kept for recovery; read by the unit-test isolation guard.
    let recoveryURL: URL
    private let history: DictationHistoryService
    private let transcriber: any CompletedAudioTranscribing
    /// The paste step Dictation shares with Snippets; read by the unit-test isolation guard.
    let paster: any TextPasting
    private let allowsSystemAccess: Bool
    private let accessibilityTrusted: () -> Bool
    var durationLimit: DictationDurationLimit
    /// Puts the clipboard back after an insert while `restoresClipboard` says so. The shell shares
    /// the Command Palette's, which keyword expansion also uses; without one, the transcript stays.
    @ObservationIgnored var clipboardRestorer: ClipboardRestorer?
    /// Dictation's Put the clipboard back setting, read at each insert. On by default.
    @ObservationIgnored var restoresClipboard: () -> Bool = { true }

    /// `allowsSystemAccess` gates the microphone, activating the destination app, and pasting.
    /// It's off in UI-test compositions and, unless a test opts in, in the unit-test host.
    /// `accessibilityTrusted` is a silent check; it never prompts. `paster` defaults to
    /// `InertTextPaster`: only the app shell's paste step keeps the write out of Clipboard History,
    /// so a service built without one never pastes.
    init(
        language: String,
        durationLimit: DictationDurationLimit = .fiveMinutes,
        fileManager: FileManager = .default,
        history: DictationHistoryService? = nil,
        transcriber: (any CompletedAudioTranscribing)? = nil,
        paster: any TextPasting = InertTextPaster(),
        allowsSystemAccess: Bool = !UnitTestHost.isActive,
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.allowsSystemAccess = allowsSystemAccess
        self.accessibilityTrusted = accessibilityTrusted
        selectedLanguage = language
        self.durationLimit = durationLimit
        let directory = ProductPaths.keybumps(fileManager: fileManager).applicationSupport
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let recoveryURL = directory.appendingPathComponent("last-dictation.txt")
        self.recoveryURL = recoveryURL
        self.history = history ?? DictationHistoryService(fileManager: fileManager)
        self.transcriber = transcriber ?? AppleSpeechCompletedAudioTranscriber()
        self.paster = paster
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

    func toggle() {
        switch phase {
        case .idle, .failed: start()
        case .recording: Task { await stopAndInsert() }
        case .transcribing, .inserting: break
        }
    }

    func start() {
        guard phase == .idle || isFailed else { return }
        guard retryingEntryID == nil else { return }
        // UI test compositions never open the microphone, whatever the faked permission state.
        guard allowsSystemAccess else {
            fail("Audio capture is unavailable in this session.")
            return
        }
        guard microphoneGranted, speechGranted else {
            fail("Microphone and Speech Recognition permissions are required.")
            return
        }
        guard SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage))?.supportsOnDeviceRecognition == true else {
            fail("On-device speech is unavailable for \(selectedLanguage).")
            return
        }
        destination = NSWorkspace.shared.frontmostApplication.map(DictationInsertionTarget.init)
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("The microphone has no usable audio format."); return }
        var preparedRecording: PendingDictationRecording?
        do {
            let recording = try history.prepareRecording(language: selectedLanguage)
            preparedRecording = recording
            let audioFile = try AVAudioFile(forWriting: recording.audioURL, settings: format.settings)
            activeRecording = recording
            recordingStartedAt = recording.capturedAt
            self.audioFile = audioFile
            let reportLevel = onInputLevel
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                try? audioFile.write(from: buffer)
                guard let reportLevel else { return }
                let level = DictationInputLevel.normalized(buffer)
                DispatchQueue.main.async { reportLevel(level) }
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
            beginSession()
        } catch { cleanup(); fail("The microphone could not start.") }
    }

    /// Starts a session for `recording` as `start()` does once the microphone is writing to it,
    /// but without the microphone. Internal so tests can follow a session through a cancel and
    /// the next session (#281); it does nothing outside the unit-test host.
    func beginSessionWithoutMicrophone(recording: PendingDictationRecording) {
        guard UnitTestHost.isActive, phase == .idle || isFailed, retryingEntryID == nil else { return }
        activeRecording = recording
        recordingStartedAt = recording.capturedAt
        beginSession()
    }

    private func beginSession() {
        session += 1
        lastError = nil
        setPhase(.recording)
        scheduleDurationLimit()
        transcriber.prepare(language: selectedLanguage)
    }

    func cancel() {
        guard phase != .idle || retryingEntryID != nil else { return }
        session += 1
        transcriber.cancel()
        cleanup()
        setPhase(.idle)
    }

    func copyRecoveredTranscript() {
        guard let recoveredTranscript else { return }
        NSPasteboard.keybumps.clearContents()
        NSPasteboard.keybumps.setString(recoveredTranscript, forType: .string)
    }

    func clearRecoveredTranscript() {
        try? FileManager.default.removeItem(at: recoveryURL)
        recoveredTranscript = nil
    }

    func transcribe(_ entry: DictationHistoryEntry) async {
        guard retryingEntryID == nil,
              phase == .idle || isFailed,
              entry.canTranscribe,
              let audioURL = entry.audioURL else { return }

        let entry = history.prepareRetry(entry)
        let language = entry.language == "und" ? selectedLanguage : entry.language
        retryingEntryID = entry.id
        lastError = nil
        do {
            try history.markTranscribing(entry, language: language)
            let transcript = try await transcribeCompletedAudio(
                at: audioURL,
                language: language,
                recordedDuration: entry.duration
            )
            _ = try history.completeTranscription(
                of: entry,
                text: transcript,
                language: language
            )
        } catch is CancellationError {
            _ = try? history.completeTranscription(
                of: entry,
                text: transcriber.partialTranscript,
                language: language,
                transcriptionError: "Transcription was cancelled."
            )
        } catch {
            _ = try? history.completeTranscription(
                of: entry,
                text: transcriber.partialTranscript,
                language: language,
                transcriptionError: error.localizedDescription
            )
            lastError = "Transcription failed. The audio recording was preserved."
        }
        transcriber.cancel()
        retryingEntryID = nil
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func stopAndInsert() async {
        // The shortcut and the duration limit can both stop the same recording.
        guard phase == .recording else { return }
        let session = self.session
        setPhase(.transcribing)
        let recording = activeRecording
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        durationTimer?.invalidate()
        durationTimer = nil
        stopAudio()
        let stoppedAt = Date()
        do {
            guard let recording else { throw CocoaError(.fileNoSuchFile) }
            try history.markTranscribing(
                recording,
                language: selectedLanguage,
                duration: duration
            )
            let transcript = try await transcribeCompletedAudio(
                at: recording.audioURL,
                language: selectedLanguage,
                recordedDuration: duration
            )
            guard session == self.session else { return }
            try transcript.write(to: recoveryURL, atomically: true, encoding: .utf8)
            recoveredTranscript = transcript
            try history.completeRecording(
                recording,
                text: transcript,
                language: selectedLanguage,
                duration: duration,
                processingTime: Date().timeIntervalSince(stoppedAt)
            )
            activeRecording = nil
            recordingStartedAt = nil
            setPhase(.inserting)
            try await insert(transcript)
            guard session == self.session else { return }
            cleanup()
            setPhase(.idle)
        } catch {
            // Cancelled or replaced while it waited: the cancel discarded this recording, and
            // what's active now belongs to another session.
            guard session == self.session else { return }
            if error is CancellationError { cleanup(); setPhase(.idle); return }
            if let recording = activeRecording {
                _ = try? history.completeRecording(
                    recording,
                    text: transcriber.partialTranscript,
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

    private func transcribeCompletedAudio(
        at audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        try await transcriber.transcribe(
            audioURL: audioURL,
            language: language,
            recordedDuration: recordedDuration
        )
    }

    /// Pastes a saved transcript at the original cursor through `paster`. Without Accessibility
    /// it stops before touching the destination, the pasteboard, or events; the ⌘V poster checks
    /// again right before posting.
    func insert(_ text: String) async throws {
        // UI test compositions never activate another app or synthesize Command-V.
        guard allowsSystemAccess else { throw DictationInsertionError.unavailableInSession }
        // Checked silently first: macOS drops ⌘V posted without Accessibility and shows its own alert.
        guard accessibilityTrusted() else { throw DictationInsertionError.accessibilityRequired }
        guard let destination = destination?.runningApplication() else { throw DictationInsertionError.destinationUnavailable }
        destination.activate(options: [])
        try await Task.sleep(for: .milliseconds(160))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            throw DictationInsertionError.destinationNotFocused
        }
        try pasteTranscript(text)
    }

    /// `insert`'s paste, once the original app is in front again: writes the transcript, kept out of
    /// Clipboard History, and presses ⌘V. With Put the clipboard back on, what was on the clipboard
    /// comes back once the app has read the paste, unless something else was copied by then
    /// (`ClipboardRestorer`); a paste that fails after writing puts it back too. Only `insert` calls
    /// it, after its checks; tests call it directly, with a paste step that never posts ⌘V.
    func pasteTranscript(_ text: String) throws {
        let paster = paster
        let paste = { try paster.paste(text, concealed: false) }
        do {
            if restoresClipboard(), let clipboardRestorer {
                try clipboardRestorer.restoreAfter(paste)
            } else {
                try paste()
            }
        } catch TextPasteError.accessibilityRequired {
            throw DictationInsertionError.accessibilityRequired
        } catch {
            throw DictationInsertionError.pasteFailed
        }
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
        stopAudio()
        transcriber.cancel()
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

/// Converts a microphone buffer to a 0–1 loudness for the recording indicator. Only a single
/// number leaves the audio thread; no audio content is kept or logged.
enum DictationInputLevel {
    static func normalized(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        return normalized(rms: (sum / Float(count)).squareRoot())
    }

    /// Maps -50 dBFS (quiet room) … 0 dBFS (loud) onto 0 … 1.
    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
