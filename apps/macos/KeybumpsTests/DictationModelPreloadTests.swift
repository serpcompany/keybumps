import Foundation
import Testing
@testable import Keybumps

/// #278: the Whisper model starts loading when recording starts, so the wait after the person
/// stops talking doesn't include the load.
@MainActor
@Suite struct DictationModelPreloadTests {
    @Test func preparingLoadsTheModelSoTheTranscriptionDoesNotLoadIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.waitUntil { fixture.loadCount == 1 }
        let transcript = try await fixture.transcribe()

        #expect(transcript == "preloaded")
        #expect(fixture.loadCount == 1)
    }

    @Test func aTranscriptionJoinsALoadThatIsStillRunning() async throws {
        let gate = LoadGate()
        let fixture = try await Fixture(gate: gate)
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.waitUntil { gate.waiting == 1 }
        let transcription = Task { @MainActor in try await fixture.transcribe() }
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.loadCount == 1)

        gate.release()
        #expect(try await transcription.value == "preloaded")
        #expect(fixture.loadCount == 1)
    }

    @Test func preparingTwiceForOneModelLoadsItOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        fixture.coordinator.prepare(language: "en-US")
        await fixture.waitUntil { fixture.loadCount == 1 }
        fixture.coordinator.prepare(language: "en-US")
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.loadCount == 1)
    }

    @Test func aRecordingHoldsTheIdleUnloadUntilItsTranscriptionEnds() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        _ = try await fixture.transcribe()
        #expect(fixture.scheduler.scheduledCount == 1)

        // The next recording starts within five minutes, so its idle unload is cancelled.
        fixture.coordinator.prepare(language: "en-US")
        fixture.scheduler.fire(at: 0)
        #expect(fixture.runtime.unloadCount == 0)

        _ = try await fixture.transcribe()
        #expect(fixture.scheduler.scheduledCount == 2)
        fixture.scheduler.fireLatest()
        #expect(fixture.runtime.unloadCount == 1)
        #expect(fixture.loadCount == 1)
    }

    @Test func aCancelledRecordingStillUnloadsTheModelWhenIdle() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.waitUntil { fixture.loadCount == 1 }
        fixture.coordinator.cancel()

        #expect(fixture.scheduler.scheduledCount == 1)
        #expect(fixture.scheduler.latestDelay == 300)
        fixture.scheduler.fireLatest()
        // A load still finishing is unloaded once it completes.
        await fixture.waitUntil { fixture.runtime.unloadCount == 1 }
    }

    @Test func cancellingWithNothingLoadedSchedulesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.cancel()

        #expect(fixture.scheduler.scheduledCount == 0)
    }

    @Test func preparingDoesNothingForAppleSpeech() async throws {
        let fixture = try await Fixture(engine: .appleSpeech)
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.loadCount == 0)
    }

    @Test func preparingDoesNothingForALanguageTheModelDoesNotSupport() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "ja-JP")
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.loadCount == 0)
    }

    @Test func aFailedPreloadLeavesTheTranscriptionToLoadAndReportIt() async throws {
        let fixture = try await Fixture(failFirstLoad: true)
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.waitUntil { fixture.loadCount == 1 }
        for _ in 0..<20 { await Task.yield() }
        let transcript = try await fixture.transcribe()

        #expect(transcript == "preloaded")
        #expect(fixture.loadCount == 2)
    }

    @Test func aCompletedRecordingSavesItsProcessingTime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsProcessingTime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = DictationHistoryService(recordingsDirectoryURL: root, appVersion: "test")
        let recording = try history.prepareRecording(language: "en-US")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: recording.audioURL)

        let entry = try history.completeRecording(
            recording,
            text: "made-up words",
            language: "en-US",
            duration: 4,
            processingTime: 0.75
        )

        #expect(entry.metadata.processingTime == 0.75)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: entry.metadataURL)) as? [String: Any]
        #expect(saved?["processingTime"] as? Double == 0.75)
    }

    @Test func historyWrittenBeforeProcessingTimeStillLoads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsProcessingTimeLegacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("1790000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: folder.appendingPathComponent("output.wav"))
        try Data("""
        {"appVersion":"0.0.3","audioFile":"output.wav","datetime":"2026-09-21T00:00:00Z","duration":2,\
        "id":"1790000000","languageSelected":"en-US","result":"made-up words","state":"completed"}
        """.utf8).write(to: folder.appendingPathComponent("meta.json"))

        let history = DictationHistoryService(recordingsDirectoryURL: root, appVersion: "test")

        #expect(history.entries.count == 1)
        #expect(history.entries.first?.metadata.processingTime == nil)
        #expect(history.entries.first?.state == .completed)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let scheduler: PreloadIdleScheduler
    let runtime: PreloadRuntime
    let coordinator: DictationTranscriptionCoordinator
    private(set) var loadCount = 0

    init(
        engine: DictationTranscriptionEngine = .whisperMediumEnglish,
        gate: LoadGate? = nil,
        failFirstLoad: Bool = false
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperPreload-\(UUID().uuidString)", isDirectory: true)
        let manager = DictationModelManager(modelsRoot: root, downloader: CompleteModelDownloader())
        await manager.download(.whisperMediumEnglish)
        let scheduler = PreloadIdleScheduler()
        let runtime = PreloadRuntime()
        self.scheduler = scheduler
        self.runtime = runtime
        var failsNext = failFirstLoad
        weak var weakSelf: Fixture?
        coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { engine },
            modelManager: manager,
            appleTranscriber: runtime,
            whisperFactory: { _ in
                weakSelf?.loadCount += 1
                if let gate { await gate.wait() }
                if failsNext {
                    failsNext = false
                    throw CocoaError(.fileReadCorruptFile)
                }
                return runtime
            },
            idleScheduler: scheduler,
            idleTimeout: 300
        )
        weakSelf = self
        #expect(manager.installedModelFolder(for: .whisperMediumEnglish) != nil)
    }

    func transcribe() async throws -> String {
        try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("made-up.wav"),
            language: "en-US",
            recordedDuration: 2
        )
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
        #expect(condition())
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private struct CompleteModelDownloader: DictationModelDownloading {
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

@MainActor
private final class PreloadRuntime: UnloadableCompletedAudioTranscribing {
    private(set) var unloadCount = 0
    var partialTranscript: String { "" }

    func transcribe(audioURL: URL, language: String, recordedDuration: TimeInterval) async throws -> String {
        "preloaded"
    }

    func cancel() {}

    func unload() -> Task<Void, Never> {
        unloadCount += 1
        return Task {}
    }
}

@MainActor
private final class LoadGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class PreloadIdleScheduler: DictationRuntimeIdleScheduling {
    private final class Cancellation: DictationRuntimeIdleCancellation {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    private var scheduled: [(delay: TimeInterval, cancellation: Cancellation, operation: @MainActor () -> Void)] = []

    var scheduledCount: Int { scheduled.count }
    var latestDelay: TimeInterval? { scheduled.last?.delay }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any DictationRuntimeIdleCancellation {
        let cancellation = Cancellation()
        scheduled.append((delay, cancellation, operation))
        return cancellation
    }

    func fire(at index: Int) {
        let entry = scheduled[index]
        guard !entry.cancellation.isCancelled else { return }
        entry.operation()
    }

    func fireLatest() {
        guard let last = scheduled.indices.last else { return }
        fire(at: last)
    }
}
