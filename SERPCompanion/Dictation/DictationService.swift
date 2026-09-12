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
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var completion: CheckedContinuation<String, Error>?
    private var latestTranscript = ""
    private var receivedFinal = false
    private var inputTapInstalled = false
    private var destination: DictationInsertionTarget?
    private let recoveryURL: URL
    private let history: DictationHistoryService

    init(
        language: String,
        fileManager: FileManager = .default,
        history: DictationHistoryService? = nil
    ) {
        selectedLanguage = language
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
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage)), recognizer.supportsOnDeviceRecognition else {
            fail("On-device speech is unavailable for \(selectedLanguage).")
            return
        }
        lastError = nil
        destination = NSWorkspace.shared.frontmostApplication.map(DictationInsertionTarget.init)
        latestTranscript = ""
        receivedFinal = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("The microphone has no usable audio format."); return }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in request.append(buffer) }
        inputTapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in self?.receive(result: result, error: error) }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            setPhase(.recording)
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
        stopAudio()
        request?.endAudio()
        do {
            let transcript = try await waitForTranscript()
            try transcript.write(to: recoveryURL, atomically: true, encoding: .utf8)
            recoveredTranscript = transcript
            history.record(transcript, language: selectedLanguage)
            setPhase(.inserting)
            try await paste(transcript)
            cleanup()
            setPhase(.idle)
        } catch is CancellationError {
            cleanup(); setPhase(.idle)
        } catch {
            cleanup(); fail(error.localizedDescription)
        }
    }

    private func waitForTranscript() async throws -> String {
        if receivedFinal { return try validatedTranscript() }
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.finishRecognition() }
            }
        }
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            latestTranscript = result.bestTranscription.formattedString
            if result.isFinal { receivedFinal = true; finishRecognition() }
        } else if error != nil, completion != nil { finishRecognition() }
    }

    private func finishRecognition() {
        guard let completion else { return }
        self.completion = nil
        do { completion.resume(returning: try validatedTranscript()) }
        catch { completion.resume(throwing: error) }
    }

    private func validatedTranscript() throws -> String {
        let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NSError(domain: "SERPCompanion.Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech was detected."]) }
        return text
    }

    private func paste(_ text: String) async throws {
        guard let destination = destination?.runningApplication() else { throw NSError(domain: "SERPCompanion.Dictation", code: 2, userInfo: [NSLocalizedDescriptionKey: "The destination app is no longer available. Your transcript was preserved."]) }
        destination.activate(options: [])
        try await Task.sleep(for: .milliseconds(160))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            throw NSError(domain: "SERPCompanion.Dictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "The destination app could not be focused. Your transcript was preserved."])
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw NSError(domain: "SERPCompanion.Dictation", code: 3, userInfo: [NSLocalizedDescriptionKey: "The transcript was preserved but could not be pasted."])
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
    }

    private func cleanup() {
        stopAudio()
        task?.cancel(); task = nil
        request = nil
    }

    private func fail(_ message: String) { lastError = message; setPhase(.failed(message)) }
    private func setPhase(_ phase: DictationPhase) { self.phase = phase; onPhaseChange?(phase) }
}
