import AVFoundation
import Foundation
import Observation

enum DictationRecordingState: String, Codable, Equatable {
    case recording
    case transcribing
    case completed
    case interrupted
    case failed
}

struct DictationRecordingMetadata: Codable, Equatable {
    let id: String
    let datetime: Date
    let duration: TimeInterval
    let languageSelected: String
    let result: String
    let audioFile: String
    let appVersion: String
    let transcriptionError: String?
    let state: DictationRecordingState?
}

struct PendingDictationRecording: Equatable {
    let id: String
    let capturedAt: Date
    let directoryURL: URL
    let audioURL: URL
}

struct DictationHistoryEntry: Identifiable, Equatable {
    let metadata: DictationRecordingMetadata
    let directoryURL: URL
    let audioURL: URL?

    var id: String { metadata.id }
    var text: String { metadata.result }
    var displayText: String {
        if !text.isEmpty { return text }
        return state == .interrupted
            ? "Recording interrupted — transcript unavailable"
            : "Transcription unavailable"
    }
    var language: String { metadata.languageSelected }
    var capturedAt: Date { metadata.datetime }
    var duration: TimeInterval { metadata.duration }
    var metadataURL: URL { directoryURL.appendingPathComponent("meta.json") }
    var state: DictationRecordingState {
        metadata.state ?? (metadata.transcriptionError == nil ? .completed : .failed)
    }
    var canTranscribe: Bool {
        audioURL != nil && (state == .failed || state == .interrupted)
    }
    /// Why the last transcription of this recording failed, when it did.
    var failureReason: String? {
        guard state == .failed || state == .interrupted,
              let reason = metadata.transcriptionError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }
}

@MainActor
@Observable
final class DictationHistoryService {
    private(set) var entries: [DictationHistoryEntry] = []
    let recordingsDirectoryURL: URL

    private let fileManager: FileManager
    private let appVersion: String
    private var activeRecordingIDs: Set<String> = []

    init(
        fileManager: FileManager = .default,
        recordingsDirectoryURL: URL? = nil,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    ) {
        self.fileManager = fileManager
        self.appVersion = appVersion
        self.recordingsDirectoryURL = recordingsDirectoryURL
            ?? ProductPaths.keybumps(fileManager: fileManager).recordings
        try? fileManager.createDirectory(at: self.recordingsDirectoryURL, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let directories = (try? fileManager.contentsOfDirectory(
            at: recordingsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        entries = directories.compactMap(loadOrRecoverEntry).sorted { left, right in
            if left.capturedAt == right.capturedAt { return left.id > right.id }
            return left.capturedAt > right.capturedAt
        }
    }

    func prepareRecording(capturedAt: Date = .now, language: String = "en-US") throws -> PendingDictationRecording {
        let baseID = String(Int(capturedAt.timeIntervalSince1970))
        var id = baseID
        var suffix = 2
        var directory = recordingsDirectoryURL.appendingPathComponent(id, isDirectory: true)
        while fileManager.fileExists(atPath: directory.path) {
            id = "\(baseID)-\(suffix)"
            suffix += 1
            directory = recordingsDirectoryURL.appendingPathComponent(id, isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let recording = PendingDictationRecording(
            id: id,
            capturedAt: capturedAt,
            directoryURL: directory,
            audioURL: directory.appendingPathComponent("output.wav")
        )
        do {
            try persist(DictationRecordingMetadata(
                id: recording.id,
                datetime: recording.capturedAt,
                duration: 0,
                languageSelected: language,
                result: "",
                audioFile: recording.audioURL.lastPathComponent,
                appVersion: appVersion,
                transcriptionError: nil,
                state: .recording
            ), in: recording.directoryURL)
        } catch {
            try? fileManager.removeItem(at: recording.directoryURL)
            throw error
        }
        activeRecordingIDs.insert(recording.id)
        return recording
    }

    func markTranscribing(_ recording: PendingDictationRecording, language: String, duration: TimeInterval) throws {
        try persist(DictationRecordingMetadata(
            id: recording.id,
            datetime: recording.capturedAt,
            duration: max(0, duration),
            languageSelected: language,
            result: "",
            audioFile: recording.audioURL.lastPathComponent,
            appVersion: appVersion,
            transcriptionError: nil,
            state: .transcribing
        ), in: recording.directoryURL)
    }

    func markTranscribing(_ entry: DictationHistoryEntry, language: String) throws {
        let metadata = DictationRecordingMetadata(
            id: entry.id,
            datetime: entry.capturedAt,
            duration: entry.duration,
            languageSelected: language,
            result: entry.text,
            audioFile: entry.metadata.audioFile,
            appVersion: entry.metadata.appVersion,
            transcriptionError: nil,
            state: .transcribing
        )
        try persist(metadata, in: entry.directoryURL)
        activeRecordingIDs.insert(entry.id)
        replaceEntry(metadata: metadata, directoryURL: entry.directoryURL, audioURL: entry.audioURL)
    }

    @discardableResult
    func completeRecording(
        _ recording: PendingDictationRecording,
        text: String,
        language: String,
        duration: TimeInterval,
        transcriptionError: String? = nil
    ) throws -> DictationHistoryEntry {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty || transcriptionError != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        guard fileManager.fileExists(atPath: recording.audioURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let metadata = DictationRecordingMetadata(
            id: recording.id,
            datetime: recording.capturedAt,
            duration: max(0, duration),
            languageSelected: language,
            result: transcript,
            audioFile: recording.audioURL.lastPathComponent,
            appVersion: appVersion,
            transcriptionError: transcriptionError,
            state: transcriptionError == nil ? .completed : .failed
        )
        try persist(metadata, in: recording.directoryURL)
        activeRecordingIDs.remove(recording.id)

        return replaceEntry(metadata: metadata, directoryURL: recording.directoryURL, audioURL: recording.audioURL)
    }

    @discardableResult
    func completeTranscription(
        of entry: DictationHistoryEntry,
        text: String,
        language: String,
        transcriptionError: String? = nil
    ) throws -> DictationHistoryEntry {
        let recording = PendingDictationRecording(
            id: entry.id,
            capturedAt: entry.capturedAt,
            directoryURL: entry.directoryURL,
            audioURL: entry.directoryURL.appendingPathComponent(entry.metadata.audioFile)
        )
        return try completeRecording(
            recording,
            text: text,
            language: language,
            duration: entry.duration,
            transcriptionError: transcriptionError
        )
    }

    @discardableResult
    func record(
        _ text: String,
        language: String,
        capturedAt: Date = .now,
        duration: TimeInterval,
        audioSourceURL: URL
    ) throws -> DictationHistoryEntry {
        let recording = try prepareRecording(capturedAt: capturedAt)
        do {
            if audioSourceURL.standardizedFileURL != recording.audioURL.standardizedFileURL {
                try fileManager.copyItem(at: audioSourceURL, to: recording.audioURL)
            }
            return try completeRecording(
                recording,
                text: text,
                language: language,
                duration: duration
            )
        } catch {
            try? fileManager.removeItem(at: recording.directoryURL)
            throw error
        }
    }

    func discard(_ recording: PendingDictationRecording) {
        activeRecordingIDs.remove(recording.id)
        try? fileManager.removeItem(at: recording.directoryURL)
    }

    func delete(_ entry: DictationHistoryEntry) {
        guard entry.directoryURL.deletingLastPathComponent().standardizedFileURL == recordingsDirectoryURL.standardizedFileURL else {
            return
        }
        do {
            try fileManager.removeItem(at: entry.directoryURL)
            entries.removeAll { $0.id == entry.id }
        } catch {
            refresh()
        }
    }

    func clear() {
        for entry in entries {
            guard entry.directoryURL.deletingLastPathComponent().standardizedFileURL == recordingsDirectoryURL.standardizedFileURL else {
                continue
            }
            try? fileManager.removeItem(at: entry.directoryURL)
        }
        refresh()
    }

    private func loadOrRecoverEntry(from directoryURL: URL) -> DictationHistoryEntry? {
        let metadataURL = directoryURL.appendingPathComponent("meta.json")
        let audioURL = directoryURL.appendingPathComponent("output.wav")
        let audioDuration = playableAudioDuration(at: audioURL)

        if let data = try? Data(contentsOf: metadataURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var metadata = try? decoder.decode(DictationRecordingMetadata.self, from: data) else {
                return nil
            }
            if metadata.state == .recording || metadata.state == .transcribing {
                if activeRecordingIDs.contains(metadata.id) {
                    return entries.first(where: { $0.id == metadata.id })
                }
                metadata = interruptedMetadata(
                    id: metadata.id,
                    capturedAt: metadata.datetime,
                    duration: audioDuration ?? metadata.duration,
                    language: metadata.languageSelected,
                    audioFile: metadata.audioFile
                )
                try? persist(metadata, in: directoryURL)
            }
            let storedAudioURL = directoryURL.appendingPathComponent(metadata.audioFile)
            return DictationHistoryEntry(
                metadata: metadata,
                directoryURL: directoryURL,
                audioURL: fileManager.fileExists(atPath: storedAudioURL.path) ? storedAudioURL : nil
            )
        }

        guard let audioDuration else { return nil }
        let id = directoryURL.lastPathComponent
        let capturedAt = id.split(separator: "-").first
            .flatMap { TimeInterval($0) }
            .map(Date.init(timeIntervalSince1970:))
            ?? (try? audioURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? .now
        let metadata = interruptedMetadata(
            id: id,
            capturedAt: capturedAt,
            duration: audioDuration,
            language: "und",
            audioFile: audioURL.lastPathComponent
        )
        try? persist(metadata, in: directoryURL)
        return DictationHistoryEntry(metadata: metadata, directoryURL: directoryURL, audioURL: audioURL)
    }

    private func interruptedMetadata(
        id: String,
        capturedAt: Date,
        duration: TimeInterval,
        language: String,
        audioFile: String
    ) -> DictationRecordingMetadata {
        DictationRecordingMetadata(
            id: id,
            datetime: capturedAt,
            duration: max(0, duration),
            languageSelected: language,
            result: "",
            audioFile: audioFile,
            appVersion: appVersion,
            transcriptionError: "Recording was interrupted before transcription finished.",
            state: .interrupted
        )
    }

    private func playableAudioDuration(at url: URL) -> TimeInterval? {
        guard fileManager.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func persist(_ metadata: DictationRecordingMetadata, in directoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: directoryURL.appendingPathComponent("meta.json"),
            options: .atomic
        )
    }

    /// Keeps entries newest first, so a retried recording stays where it was listed.
    @discardableResult
    private func replaceEntry(metadata: DictationRecordingMetadata, directoryURL: URL, audioURL: URL?) -> DictationHistoryEntry {
        let entry = DictationHistoryEntry(metadata: metadata, directoryURL: directoryURL, audioURL: audioURL)
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { left, right in
            if left.capturedAt == right.capturedAt { return left.id > right.id }
            return left.capturedAt > right.capturedAt
        }
        return entry
    }
}
