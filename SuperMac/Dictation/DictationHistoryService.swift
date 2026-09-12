import Foundation
import Observation

struct DictationRecordingMetadata: Codable, Equatable {
    let id: String
    let datetime: Date
    let duration: TimeInterval
    let languageSelected: String
    let result: String
    let audioFile: String
    let appVersion: String
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
    var language: String { metadata.languageSelected }
    var capturedAt: Date { metadata.datetime }
    var duration: TimeInterval { metadata.duration }
    var metadataURL: URL { directoryURL.appendingPathComponent("meta.json") }
}

@MainActor
@Observable
final class DictationHistoryService {
    private(set) var entries: [DictationHistoryEntry] = []
    let recordingsDirectoryURL: URL

    private let fileManager: FileManager
    private let appVersion: String

    init(
        fileManager: FileManager = .default,
        recordingsDirectoryURL: URL? = nil,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    ) {
        self.fileManager = fileManager
        self.appVersion = appVersion
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.recordingsDirectoryURL = recordingsDirectoryURL
            ?? documents.appendingPathComponent("SuperMac/recordings", isDirectory: true)
        try? fileManager.createDirectory(at: self.recordingsDirectoryURL, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let directories = (try? fileManager.contentsOfDirectory(
            at: recordingsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        entries = directories.compactMap(loadEntry).sorted { left, right in
            if left.capturedAt == right.capturedAt { return left.id > right.id }
            return left.capturedAt > right.capturedAt
        }
    }

    func prepareRecording(capturedAt: Date = .now) throws -> PendingDictationRecording {
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
        return PendingDictationRecording(
            id: id,
            capturedAt: capturedAt,
            directoryURL: directory,
            audioURL: directory.appendingPathComponent("output.wav")
        )
    }

    @discardableResult
    func completeRecording(
        _ recording: PendingDictationRecording,
        text: String,
        language: String,
        duration: TimeInterval
    ) throws -> DictationHistoryEntry {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
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
            appVersion: appVersion
        )
        let metadataURL = recording.directoryURL.appendingPathComponent("meta.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

        let entry = DictationHistoryEntry(
            metadata: metadata,
            directoryURL: recording.directoryURL,
            audioURL: recording.audioURL
        )
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        return entry
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

    private func loadEntry(from directoryURL: URL) -> DictationHistoryEntry? {
        let metadataURL = directoryURL.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(DictationRecordingMetadata.self, from: data) else {
            return nil
        }
        let audioURL = directoryURL.appendingPathComponent(metadata.audioFile)
        return DictationHistoryEntry(
            metadata: metadata,
            directoryURL: directoryURL,
            audioURL: fileManager.fileExists(atPath: audioURL.path) ? audioURL : nil
        )
    }
}
