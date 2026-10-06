import AVFoundation
import Foundation
import Testing
@testable import Keybumps

/// #293: a Dictation recording cut off by a crash or force quit has all its audio on disk but a
/// header that says it's empty. Every fixture here is a generated sine wave or silence.
@Suite struct WAVHeaderRepairTests {
    @Test func aRecordingCutOffByACrashIsRepairedAndReadsBackEveryFrame() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let url = folder.url("output.wav")
        try SyntheticWAV.sine(frames: 1_600, riffSize: 0, dataSize: 0).write(to: url)
        #expect(((try? AVAudioFile(forReading: url))?.length ?? 0) == 0)

        #expect(WAVHeaderRepair.repairFile(at: url))

        #expect(try AVAudioFile(forReading: url).length == 1_600)
        // Only the two size fields changed: the result is the header a closed file has.
        #expect(try Data(contentsOf: url) == SyntheticWAV.sine(frames: 1_600))
    }

    @Test func aPartFrameAtTheEndIsLeftOutOfTheDataSize() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let url = folder.url("output.wav")
        var crashed = SyntheticWAV.sine(frames: 1_600, riffSize: 0, dataSize: 0)
        crashed.append(0x7F)
        try crashed.write(to: url)

        #expect(WAVHeaderRepair.repairFile(at: url))

        #expect(try AVAudioFile(forReading: url).length == 1_600)
        let repaired = try Data(contentsOf: url)
        #expect(repaired.count == crashed.count)
        #expect(repaired.last == 0x7F)
    }

    /// The layout `AVAudioFile` itself leaves while it's still writing: JUNK, fmt, and FLLR
    /// chunks before `data`, a RIFF size covering only the header, and a `data` size of 0.
    @Test func aCopyOfAFileAVAudioFileIsStillWritingIsRepaired() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let open = folder.url("open.wav")
        let crashed = folder.url("output.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let writer = try AVAudioFile(forWriting: open, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        let samples = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<1_024 { samples[index] = 0.5 * sin(Float(index) * 0.05) }
        for _ in 0..<10 { try writer.write(from: buffer) }
        try FileManager.default.copyItem(at: open, to: crashed)
        withExtendedLifetime(writer) {}
        let before = try Data(contentsOf: crashed)
        #expect(try AVAudioFile(forReading: crashed).length == 0)

        #expect(WAVHeaderRepair.repairFile(at: crashed))

        #expect(try AVAudioFile(forReading: crashed).length == 10_240)
        let after = try Data(contentsOf: crashed)
        let dataChunk = try #require(before.range(of: Data("data".utf8))).lowerBound
        let dataSizeField = (dataChunk + 4)..<(dataChunk + 8)
        let changed = (0..<before.count).filter { before[$0] != after[$0] }
        #expect(after.count == before.count)
        #expect(changed.allSatisfy { (4..<8).contains($0) || dataSizeField.contains($0) })
    }

    @Test func aWAVWhoseHeaderIsAlreadyRightIsLeftUntouched() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let handWritten = folder.url("hand-written.wav")
        let valid = SyntheticWAV.sine(frames: 1_600)
        try valid.write(to: handWritten)
        let closed = folder.url("closed.wav")
        try SyntheticWAV.writeSilence(frames: 1_600, to: closed)
        let closedBytes = try Data(contentsOf: closed)

        #expect(!WAVHeaderRepair.repairFile(at: handWritten))
        #expect(!WAVHeaderRepair.repairFile(at: closed))

        #expect(try Data(contentsOf: handWritten) == valid)
        #expect(try Data(contentsOf: closed) == closedBytes)
    }

    @Test(arguments: UnrepairableWAVFixture.allCases)
    func aFileThatIsTooShortOrNotAWAVIsLeftAlone(_ file: UnrepairableWAVFixture) throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let url = folder.url("output.wav")
        try file.bytes.write(to: url)

        #expect(!WAVHeaderRepair.repairFile(at: url))

        #expect(try Data(contentsOf: url) == file.bytes)
    }

    @Test func aMissingFileIsLeftAlone() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let url = folder.url("output.wav")

        #expect(!WAVHeaderRepair.repairFile(at: url))

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func historyRepairsAnInterruptedRecordingWhenItRecoversItAtLaunch() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let pending = try DictationHistoryService(recordingsDirectoryURL: folder.root)
            .prepareRecording(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "en-US")
        try SyntheticWAV.sine(frames: 1_600, riffSize: 0, dataSize: 0).write(to: pending.audioURL)
        let orphan = folder.root.appendingPathComponent("1700000100", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try SyntheticWAV.sine(frames: 3_200, riffSize: 0, dataSize: 0)
            .write(to: orphan.appendingPathComponent("output.wav"))

        let entries = DictationHistoryService(recordingsDirectoryURL: folder.root).entries

        let recovered = try #require(entries.first { $0.id == pending.id })
        #expect(recovered.state == .interrupted)
        #expect(recovered.canTranscribe)
        #expect(recovered.duration == 0.1)
        #expect(try AVAudioFile(forReading: pending.audioURL).length == 1_600)
        let recoveredOrphan = try #require(entries.first { $0.id == "1700000100" })
        #expect(recoveredOrphan.state == .interrupted)
        #expect(recoveredOrphan.duration == 0.2)
    }

    /// A History refresh while this service is recording leaves the live file and its
    /// `recording` state alone: the writer still owns the header.
    @MainActor
    @Test func aRefreshDuringARecordingLeavesTheLiveFileAlone() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let history = DictationHistoryService(recordingsDirectoryURL: folder.root)
        let pending = try history.prepareRecording(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            language: "en-US"
        )
        let live = SyntheticWAV.sine(frames: 1_600, riffSize: 0, dataSize: 0)
        try live.write(to: pending.audioURL)
        let metadataURL = pending.directoryURL.appendingPathComponent("meta.json")
        let metadataBefore = try Data(contentsOf: metadataURL)

        history.refresh()

        #expect(try Data(contentsOf: pending.audioURL) == live)
        #expect(try Data(contentsOf: metadataURL) == metadataBefore)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(DictationRecordingMetadata.self, from: metadataBefore).state == .recording)
        #expect(history.entries.isEmpty)
    }

    /// An entry an earlier build recovered kept the empty header and a duration of 0, and if it
    /// was retried there it's now `failed`. Retrying it repairs the header and saves the real
    /// duration before the audio reaches the transcriber.
    @MainActor
    @Test(arguments: [
        (DictationRecordingState.interrupted, "Recording was interrupted before transcription finished."),
        (DictationRecordingState.failed, "No speech was detected"),
    ])
    func retryingAnEntryAnEarlierBuildRecoveredRepairsItsHeaderFirst(
        _ state: DictationRecordingState,
        _ transcriptionError: String
    ) async throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let directory = folder.root.appendingPathComponent("1700000000", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SyntheticWAV.sine(frames: 1_600, riffSize: 0, dataSize: 0)
            .write(to: directory.appendingPathComponent("output.wav"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DictationRecordingMetadata(
            id: "1700000000",
            datetime: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0,
            languageSelected: "en-US",
            result: "",
            audioFile: "output.wav",
            appVersion: "test",
            transcriptionError: transcriptionError,
            state: state
        )).write(to: directory.appendingPathComponent("meta.json"))
        let history = DictationHistoryService(recordingsDirectoryURL: folder.root)
        let entry = try #require(history.entries.first)
        #expect(entry.state == state)
        #expect(entry.canTranscribe)
        let transcriber = FrameCountingTranscriber()
        let dictation = DictationService(language: "en-US", history: history, transcriber: transcriber)

        await dictation.transcribe(entry)

        #expect(transcriber.framesRead == [1_600])
        #expect(transcriber.recordedDurations == [0.1])
        #expect(history.entries.first?.state == .completed)
        #expect(history.entries.first?.text == "1600 frames")
        #expect(history.entries.first?.duration == 0.1)
        let reloaded = DictationHistoryService(recordingsDirectoryURL: folder.root).entries.first
        #expect(reloaded?.duration == 0.1)
    }

    /// A second line of defense behind `DictationService.transcribe`'s own checks: preparing a
    /// retry for a recording this service is still writing touches neither its file nor `meta.json`.
    @MainActor
    @Test func preparingARetryLeavesALiveRecordingAlone() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let history = DictationHistoryService(recordingsDirectoryURL: folder.root)
        let pending = try history.prepareRecording(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            language: "en-US"
        )
        let live = SyntheticWAV.sine(frames: 1_600, riffSize: 0, dataSize: 0)
        try live.write(to: pending.audioURL)
        let metadataURL = pending.directoryURL.appendingPathComponent("meta.json")
        let metadataBefore = try Data(contentsOf: metadataURL)
        let entry = DictationHistoryEntry(
            metadata: DictationRecordingMetadata(
                id: pending.id,
                datetime: pending.capturedAt,
                duration: 0,
                languageSelected: "en-US",
                result: "",
                audioFile: pending.audioURL.lastPathComponent,
                appVersion: "test",
                transcriptionError: "Recording was interrupted before transcription finished.",
                state: .interrupted
            ),
            directoryURL: pending.directoryURL,
            audioURL: pending.audioURL
        )

        let prepared = history.prepareRetry(entry)

        #expect(prepared == entry)
        #expect(try Data(contentsOf: pending.audioURL) == live)
        #expect(try Data(contentsOf: metadataURL) == metadataBefore)
    }

    /// A header that's already right but a saved duration of 0: the duration is read again and
    /// saved, and the audio file isn't written.
    @MainActor
    @Test func preparingARetryReadsADurationOf0AgainWithoutRewritingAGoodHeader() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let history = DictationHistoryService(recordingsDirectoryURL: folder.root)
        let pending = try history.prepareRecording(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let closed = SyntheticWAV.sine(frames: 1_600)
        try closed.write(to: pending.audioURL)
        let entry = try history.completeRecording(
            pending,
            text: "",
            language: "en-US",
            duration: 0,
            transcriptionError: "No speech was detected"
        )

        let prepared = history.prepareRetry(entry)

        #expect(prepared.duration == 0.1)
        #expect(prepared.state == .failed)
        #expect(try Data(contentsOf: pending.audioURL) == closed)
        let reloaded = DictationHistoryService(recordingsDirectoryURL: folder.root).entries.first
        #expect(reloaded?.duration == 0.1)
        #expect(reloaded?.state == .failed)
    }

    /// A closed recording with the right duration is retried as it is.
    @MainActor
    @Test func preparingARetryLeavesAClosedRecordingAndItsDurationAlone() throws {
        let folder = try RecordingFolder()
        defer { folder.remove() }
        let history = DictationHistoryService(recordingsDirectoryURL: folder.root)
        let pending = try history.prepareRecording(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let closed = SyntheticWAV.sine(frames: 1_600)
        try closed.write(to: pending.audioURL)
        let entry = try history.completeRecording(
            pending,
            text: "",
            language: "en-US",
            duration: 0.1,
            transcriptionError: "No speech was detected"
        )
        let metadataURL = pending.directoryURL.appendingPathComponent("meta.json")
        let metadataBefore = try Data(contentsOf: metadataURL)

        let prepared = history.prepareRetry(entry)

        #expect(prepared == entry)
        #expect(try Data(contentsOf: pending.audioURL) == closed)
        #expect(try Data(contentsOf: metadataURL) == metadataBefore)
    }
}

enum UnrepairableWAVFixture: String, CaseIterable, CustomTestStringConvertible {
    case empty, shorterThanAHeader, notAWAV, headerWithoutAudio, noFormatChunk, chunkRunsPastTheEnd

    var testDescription: String { rawValue }

    var bytes: Data {
        switch self {
        case .empty: Data()
        case .shorterThanAHeader: Data("RIFF\0\0".utf8)
        case .notAWAV: Data(String(repeating: "not a recording ", count: 64).utf8)
        // A crash before the first buffer was written: there's no audio to size the data chunk to.
        case .headerWithoutAudio: SyntheticWAV.sine(frames: 0, riffSize: 0, dataSize: 0)
        case .noFormatChunk: SyntheticWAV.chunks([("data", Data(count: 0))], audio: Data(count: 64))
        case .chunkRunsPastTheEnd:
            SyntheticWAV.chunks([("LIST", Data())], sizeOverride: 1_000_000, audio: Data(count: 64))
        }
    }
}

private enum SyntheticWAV {
    /// A 16 kHz mono 16-bit WAV of a 440 Hz sine wave, with a closed file's size fields unless
    /// `riffSize` or `dataSize` say otherwise.
    static func sine(frames: Int, riffSize: UInt32? = nil, dataSize: UInt32? = nil) -> Data {
        var audio = Data()
        for index in 0..<frames {
            let sample = Int16(8_000 * sin(2 * Double.pi * 440 * Double(index) / 16_000))
            withUnsafeBytes(of: sample.littleEndian) { audio.append(contentsOf: $0) }
        }
        var format = Data()
        format.append(uint16: 1)       // PCM
        format.append(uint16: 1)       // mono
        format.append(uint32: 16_000)  // sample rate
        format.append(uint32: 32_000)  // byte rate
        format.append(uint16: 2)       // block align
        format.append(uint16: 16)      // bits per sample
        var wav = Data("RIFF".utf8)
        wav.append(uint32: riffSize ?? UInt32(36 + audio.count))
        wav.append(contentsOf: Data("WAVEfmt ".utf8))
        wav.append(uint32: UInt32(format.count))
        wav.append(format)
        wav.append(contentsOf: Data("data".utf8))
        wav.append(uint32: dataSize ?? UInt32(audio.count))
        wav.append(audio)
        return wav
    }

    /// A RIFF/WAVE file of the given chunks followed by `audio`; `sizeOverride` replaces the
    /// first chunk's size field.
    static func chunks(_ chunks: [(String, Data)], sizeOverride: UInt32? = nil, audio: Data) -> Data {
        var wav = Data("RIFF".utf8)
        wav.append(uint32: 0)
        wav.append(contentsOf: Data("WAVE".utf8))
        for (index, (id, body)) in chunks.enumerated() {
            wav.append(contentsOf: Data(id.utf8))
            wav.append(uint32: index == 0 ? sizeOverride ?? UInt32(body.count) : UInt32(body.count))
            wav.append(body)
        }
        wav.append(audio)
        return wav
    }

    static func writeSilence(frames: AVAudioFrameCount, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?.pointee.initialize(repeating: 0, count: Int(frames))
        try file.write(from: buffer)
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private struct RecordingFolder {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWAVHeaderRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Reports how many frames `AVAudioFile` reads from the audio it's given.
@MainActor
private final class FrameCountingTranscriber: CompletedAudioTranscribing {
    private(set) var framesRead: [AVAudioFramePosition] = []
    private(set) var recordedDurations: [TimeInterval] = []
    var partialTranscript: String { "" }

    func transcribe(audioURL: URL, language: String, recordedDuration: TimeInterval) async throws -> String {
        let frames = (try? AVAudioFile(forReading: audioURL))?.length ?? 0
        framesRead.append(frames)
        recordedDurations.append(recordedDuration)
        return "\(frames) frames"
    }

    func cancel() {}
}
