import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import Keybumps

/// ADR 0008: the whisper.cpp Turbo engine, its pinned download, and its audio input.
@MainActor
@Suite struct WhisperCppEngineTests {
    @Test func theTurboEngineNeedsItsGgmlFileAndSupportsJapanese() {
        let engine = DictationTranscriptionEngine.whisperCppTurbo

        #expect(engine.requiresDownload)
        #expect(engine.modelIdentifier == "ggml-large-v3-turbo-q5_0")
        #expect(engine.requiredModelFiles == ["ggml-large-v3-turbo-q5_0.bin"])
        #expect(engine.supports(language: "ja-JP"))
        #expect(WhisperCppModel.turbo.byteCount == 574_041_195)
        #expect(WhisperCppModel.turbo.source.absoluteString.contains("5359861c739e955e79d9a303bcbc70fb988958b1"))
    }

    @Test func onlyTheFastTurboIsMarkedRecommended() {
        #expect(DictationTranscriptionEngine.allCases.filter(\.isRecommended) == [.whisperCppTurbo])
        #expect(DictationTranscriptionEngine.whisperCppTurbo.detail == "English and Japanese · About 574 MB")
    }

    @Test func theModelManagerInstallsAFolderHoldingTheGgmlFile() async throws {
        let root = temporaryFolder("KeybumpsWhisperCppInstall")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(modelsRoot: root, downloader: FakeDownloader { _, base in
            let folder = base.appendingPathComponent("ggml-large-v3-turbo-q5_0", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin"))
            return folder
        })

        await manager.download(.whisperCppTurbo)

        #expect(manager.state(for: .whisperCppTurbo) == .installed)
        let folder = try #require(manager.installedModelFolder(for: .whisperCppTurbo))
        #expect(WhisperCppModel.installedFile(in: folder)?.lastPathComponent == "ggml-large-v3-turbo-q5_0.bin")
    }

    @Test func aWhisperKitModelFolderIsNotMistakenForAWhisperCppOne() throws {
        let folder = temporaryFolder("KeybumpsWhisperKitShaped")
        defer { try? FileManager.default.removeItem(at: folder) }
        for component in DictationTranscriptionEngine.whisperTurboCompressed.requiredModelFiles {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        #expect(WhisperCppModel.installedFile(in: folder) == nil)
    }

    @Test func aDamagedGgmlFileFailsToLoadThroughTheWhisperCppRuntime() async throws {
        let folder = temporaryFolder("KeybumpsWhisperCppDamaged")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not a ggml model".utf8).write(to: folder.appendingPathComponent(WhisperCppModel.turbo.fileName))

        do {
            _ = try await DictationTranscriptionCoordinator.loadInstalledWhisperRuntime(modelFolder: folder)
            Issue.record("A damaged model shouldn't load.")
        } catch {
            // Code 7 comes from `WhisperCppRuntime.load`, so the folder was routed to whisper.cpp.
            #expect((error as NSError).domain == "Keybumps.Dictation")
            #expect((error as NSError).code == 7)
        }
    }

    @Test func anEmptyRecordingNeverReachesWhisperCpp() async throws {
        let root = temporaryFolder("KeybumpsWhisperCppEmpty")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("empty.wav")
        try writeTone(to: url, sampleRate: 48_000, channels: 1, seconds: 0)
        let runtime = FakeWhisperCppRuntime()
        let transcriber = WhisperCppCompletedAudioTranscriber(runtime: runtime)

        do {
            _ = try await transcriber.transcribe(audioURL: url, language: "en-US", recordedDuration: 0)
            Issue.record("An empty recording should fail.")
        } catch {
            #expect((error as NSError).code == 1)
        }
        #expect(runtime.calls == 0)
    }

    @Test func aCancelDuringAudioConversionStopsBeforeWhisperCpp() async throws {
        let runtime = FakeWhisperCppRuntime()
        let gate = LoaderGate()
        let transcriber = WhisperCppCompletedAudioTranscriber(runtime: runtime) { _ in
            await gate.wait()
            return [Float](repeating: 0.1, count: 16_000)
        }
        let transcription = Task { @MainActor in
            try await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/dev/null"), language: "en-US", recordedDuration: 1)
        }
        await gate.waitUntilWaiting()

        transcriber.cancel()
        gate.release()

        await #expect(throws: CancellationError.self) { try await transcription.value }
        #expect(runtime.calls == 0)
    }

    @Test func aCancelWhileIdleDoesNotAbortTheNextTranscription() async throws {
        let runtime = FakeWhisperCppRuntime()
        let transcriber = WhisperCppCompletedAudioTranscriber(runtime: runtime) { _ in
            [Float](repeating: 0.1, count: 16_000)
        }

        transcriber.cancel()
        let transcript = try await transcriber.transcribe(
            audioURL: URL(fileURLWithPath: "/dev/null"),
            language: "ja-JP",
            recordedDuration: 1
        )

        #expect(transcript == "fake transcript")
        #expect(runtime.calls == 1)
        #expect(runtime.lastLanguage == "ja")
        #expect(runtime.lastAbortWasSet == false)
    }

    @Test func aFolderWithoutTheGgmlFileIsNotInstalled() async throws {
        let root = temporaryFolder("KeybumpsWhisperCppMissing")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(modelsRoot: root, downloader: FakeDownloader { _, base in
            let folder = base.appendingPathComponent("empty", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        })

        await manager.download(.whisperCppTurbo)
        manager.refresh()

        #expect(manager.installedModelFolder(for: .whisperCppTurbo) == nil)
        #expect(manager.state(for: .whisperCppTurbo) == .notInstalled)
    }

    @Test func theRouterSendsGgmlModelsToWhisperCppAndTheRestToWhisperKit() async throws {
        let base = temporaryFolder("KeybumpsDownloadRouter")
        defer { try? FileManager.default.removeItem(at: base) }
        var calls: [String] = []
        let router = DictationModelDownloadRouter(
            whisperKit: FakeDownloader { identifier, base in calls.append("kit \(identifier)"); return base },
            whisperCpp: FakeDownloader { identifier, base in calls.append("cpp \(identifier)"); return base }
        )

        _ = try await router.downloadModel(identifier: "ggml-large-v3-turbo-q5_0", to: base, progress: { _ in })
        _ = try await router.downloadModel(identifier: "large-v3-v20240930_626MB", to: base, progress: { _ in })

        #expect(calls == ["cpp ggml-large-v3-turbo-q5_0", "kit large-v3-v20240930_626MB"])
    }

    @Test func aDownloadThatMatchesItsChecksumIsInstalled() async throws {
        let root = temporaryFolder("KeybumpsWhisperCppDownload")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _) = try localModel(in: root, contents: Data("made-up model bytes".utf8))
        let downloader = WhisperCppModelDownloader(models: [model])
        let progress = ProgressLog()

        let folder = try await downloader.downloadModel(
            identifier: model.identifier,
            to: root.appendingPathComponent("install", isDirectory: true),
            progress: { value in Task { @MainActor in progress.values.append(value) } }
        )

        let installed = folder.appendingPathComponent(model.fileName)
        #expect(try Data(contentsOf: installed) == Data("made-up model bytes".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("install/\(model.fileName).partial").path
        ))
    }

    @Test func aDownloadWithTheWrongChecksumIsNotInstalled() async throws {
        let root = temporaryFolder("KeybumpsWhisperCppChecksum")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, source) = try localModel(in: root, contents: Data("expected bytes".utf8))
        try Data("damaged bytes!".utf8).write(to: source)
        let downloader = WhisperCppModelDownloader(models: [model])
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)

        await #expect(throws: WhisperCppModelDownloadError.checksumMismatch) {
            _ = try await downloader.downloadModel(identifier: model.identifier, to: installRoot, progress: { _ in })
        }
        #expect(WhisperCppModel.installedFile(in: installRoot.appendingPathComponent(model.identifier)) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: installRoot.path).isEmpty)
    }

    @Test func aDownloadOfTheWrongSizeIsNotInstalled() async throws {
        let root = temporaryFolder("KeybumpsWhisperCppSize")
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, source) = try localModel(in: root, contents: Data("expected bytes".utf8))
        try Data("short".utf8).write(to: source)
        let downloader = WhisperCppModelDownloader(models: [model])
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)

        await #expect(throws: WhisperCppModelDownloadError.wrongSize) {
            _ = try await downloader.downloadModel(identifier: model.identifier, to: installRoot, progress: { _ in })
        }
    }

    @Test func anUnknownModelIsRefused() async throws {
        await #expect(throws: WhisperCppModelDownloadError.unknownModel) {
            _ = try await WhisperCppModelDownloader().downloadModel(
                identifier: "not-a-model",
                to: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
        }
    }

    @Test(arguments: [(48_000.0, 2 as AVAudioChannelCount), (44_100.0, 1), (16_000.0, 1)])
    func recordingsBecomeSixteenKilohertzMono(sampleRate: Double, channels: AVAudioChannelCount) throws {
        let root = temporaryFolder("KeybumpsWhisperCppAudio")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.wav")
        try writeTone(to: url, sampleRate: sampleRate, channels: channels, seconds: 1.5)

        let samples = try WhisperCppAudio.samples(from: url)

        #expect(abs(samples.count - 24_000) <= 240)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.2 && peak <= 1.0)
    }

    @Test func soundOnlyOnTheSecondChannelIsStillHeard() throws {
        let root = temporaryFolder("KeybumpsWhisperCppChannel")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("second-channel.wav")
        try writeTone(to: url, sampleRate: 48_000, channels: 2, seconds: 1, silentChannels: [0])

        let samples = try WhisperCppAudio.samples(from: url)

        #expect((samples.map(abs).max() ?? 0) > 0.1, "A microphone on input 2 must not become silence")
    }

    @Test func soundOnOneChannelOfAFourChannelInterfaceIsStillHeard() throws {
        let root = temporaryFolder("KeybumpsWhisperCppFourChannels")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("four-channels.wav")
        try writeTone(to: url, sampleRate: 48_000, channels: 4, seconds: 1, silentChannels: [0, 1, 3])

        let samples = try WhisperCppAudio.samples(from: url)

        #expect(abs(samples.count - 16_000) <= 160)
        #expect((samples.map(abs).max() ?? 0) > 0.2, "Apple's converter alone makes 3+ channels silent")
    }

    @Test func identicalChannelsAreSummedWithoutClipping() throws {
        let root = temporaryFolder("KeybumpsWhisperCppLoud")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("loud-stereo.wav")
        try writeTone(to: url, sampleRate: 16_000, channels: 2, seconds: 1, amplitude: 0.9)

        let samples = try WhisperCppAudio.samples(from: url)

        #expect((samples.map(abs).max() ?? 0) <= 1.0)
    }

    @Test func onlyAFileWithTheGgmlHeaderIsTreatedAsAModel() throws {
        let root = temporaryFolder("KeybumpsWhisperCppHeader")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.bin")
        try Data([0x6c, 0x6d, 0x67, 0x67, 0, 0]).write(to: model)
        let junk = root.appendingPathComponent("junk.bin")
        try Data("not a model".utf8).write(to: junk)

        #expect(WhisperCppModel.hasModelHeader(model))
        #expect(!WhisperCppModel.hasModelHeader(junk))
        #expect(!WhisperCppModel.hasModelHeader(root.appendingPathComponent("missing.bin")))
    }

    @Test func aRealModelTranscribesWhenOneIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["KEYBUMPS_WHISPER_CPP_MODEL"],
              let audioPath = environment["KEYBUMPS_WHISPER_CPP_AUDIO"],
              FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: audioPath) else {
            // Pass TEST_RUNNER_KEYBUMPS_WHISPER_CPP_MODEL=<ggml file> and
            // TEST_RUNNER_KEYBUMPS_WHISPER_CPP_AUDIO=<non-private WAV> to xcodebuild to run it.
            return
        }
        let loadStarted = ContinuousClock.now
        let transcriber = try await WhisperCppCompletedAudioTranscriber.load(
            modelFile: URL(fileURLWithPath: modelPath)
        )
        let load = loadStarted.duration(to: .now)
        var runs: [Duration] = []
        var transcript = ""
        for _ in 0..<3 {
            let started = ContinuousClock.now
            transcript = try await transcriber.transcribe(
                audioURL: URL(fileURLWithPath: audioPath),
                language: "en-US",
                recordedDuration: 7
            )
            runs.append(started.duration(to: .now))
        }
        await transcriber.unload().value

        print("KEYBUMPS_WHISPER_CPP_TIMING load=\(load) transcribe=\(runs)")
        #expect(!transcript.isEmpty)
    }

    // MARK: Helpers

    private func temporaryFolder(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A model descriptor whose source is a local file, so downloads run without the network.
    private func localModel(in root: URL, contents: Data) throws -> (WhisperCppModel, URL) {
        let source = root.appendingPathComponent("source.bin")
        try contents.write(to: source)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let model = WhisperCppModel(
            identifier: "test-model",
            fileName: "test-model.bin",
            source: source,
            byteCount: Int64(contents.count),
            sha256: digest
        )
        return (model, source)
    }

    private func writeTone(
        to url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double,
        silentChannels: Set<Int> = [],
        amplitude: Float = 0.5
    ) throws {
        // More than two channels needs an explicit layout, as an audio interface would report.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        let candidate: AVAudioFormat?
        if channels > 2, let layout {
            candidate = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        } else {
            candidate = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        }
        let format = try #require(candidate)
        guard seconds > 0 else {
            // A recording stopped before any audio arrived: a WAV with a header and no frames.
            _ = try AVAudioFile(forWriting: url, settings: format.settings)
            return
        }
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try #require(buffer.floatChannelData?[channel])
            let level: Float = silentChannels.contains(channel) ? 0 : amplitude
            for frame in 0..<Int(frames) {
                data[frame] = level * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

@MainActor
private final class ProgressLog {
    var values: [Double] = []
}

private struct FakeDownloader: DictationModelDownloading {
    let body: @MainActor (String, URL) throws -> URL

    func downloadModel(
        identifier: String,
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try body(identifier, downloadBase)
    }
}

private final class FakeWhisperCppRuntime: WhisperCppTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _lastLanguage: String?
    private var _lastAbortWasSet: Bool?

    var calls: Int { lock.withLock { _calls } }
    var lastLanguage: String? { lock.withLock { _lastLanguage } }
    var lastAbortWasSet: Bool? { lock.withLock { _lastAbortWasSet } }

    func transcribe(samples: [Float], language: String, abort: WhisperCppAbortFlag) async throws -> String {
        lock.withLock {
            _calls += 1
            _lastLanguage = language
            _lastAbortWasSet = abort.isSet
        }
        return "fake transcript"
    }

    func free() async {}
}

/// Holds a sample loader until released, and says when it's waiting.
@MainActor
private final class LoaderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waitingContinuation?.resume()
            waitingContinuation = nil
        }
    }

    func waitUntilWaiting() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waitingContinuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
