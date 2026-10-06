import Foundation
import Testing
@testable import Keybumps

/// #278: the Whisper model starts loading when recording starts, so the wait after the person
/// stops talking doesn't include the whole load.
@MainActor
@Suite struct DictationModelPreloadTests {
    @Test func preparingLoadsTheModelSoTheTranscriptionDoesNotLoadIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.loads.wait(for: 1)
        let transcript = try await fixture.transcribe()

        #expect(transcript == "load 1")
        #expect(fixture.loads.count == 1)
    }

    @Test func aTranscriptionJoinsALoadThatIsStillRunning() async throws {
        let fixture = try await Fixture(gatedLoads: [1])
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.loads.wait(for: 1)
        let transcription = Task { @MainActor in try await fixture.transcribe() }
        await fixture.gate.waitForWaiters(1)
        // The main actor runs jobs in order, so one yield lets the transcription join the load.
        await Task.yield()
        #expect(fixture.loads.count == 1)

        fixture.gate.release()
        #expect(try await transcription.value == "load 1")
        #expect(fixture.loads.count == 1)
    }

    @Test func preparingAgainForTheSameModelDoesNotLoadIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        fixture.coordinator.prepare(language: "en-US")
        await fixture.loads.wait(for: 1)
        fixture.coordinator.prepare(language: "en-US")
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.loads.count == 1)
    }

    @Test func aRecordingHoldsTheIdleUnloadUntilItsTranscriptionEnds() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        _ = try await fixture.transcribe()
        #expect(fixture.scheduler.scheduledCount == 1)

        // The next recording starts within five minutes, so the pending idle unload is cancelled.
        fixture.coordinator.prepare(language: "en-US")
        fixture.scheduler.fire(at: 0)
        #expect(await fixture.runtime(1).unloadCount == 0)

        _ = try await fixture.transcribe()
        #expect(fixture.scheduler.scheduledCount == 2)
        fixture.scheduler.fireLatest()
        #expect(await fixture.runtime(1).unloadCount == 1)
        #expect(fixture.loads.count == 1)
    }

    @Test func aCancelledRecordingStillUnloadsTheModelWhenIdle() async throws {
        let fixture = try await Fixture(gatedLoads: [1])
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.loads.wait(for: 1)
        fixture.coordinator.cancel()

        #expect(fixture.scheduler.scheduledCount == 1)
        #expect(fixture.scheduler.latestDelay == 300)
        fixture.scheduler.fireLatest()
        // The load was still running; it's unloaded as soon as it finishes.
        fixture.gate.release()
        await fixture.runtime(1).unloads.wait(for: 1)
    }

    @Test func anIdleUnloadBeforeThePreloadStartsSkipsTheLoad() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        fixture.coordinator.cancel()
        fixture.scheduler.fireLatest()
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.loads.count == 0)
    }

    @Test func aCancelSeesAPreloadThatIsWaitingForTheOldModelToUnload() async throws {
        let unloadGate = Gate()
        let fixture = try await Fixture(unloadGate: unloadGate)
        defer { fixture.remove() }
        _ = try await fixture.transcribe()
        fixture.coordinator.selectedModelDidChange()
        await unloadGate.waitForWaiters(1)

        // The old model is still unloading when the next recording starts and is cancelled.
        fixture.coordinator.prepare(language: "en-US")
        fixture.coordinator.cancel()
        #expect(fixture.scheduler.scheduledCount == 2)

        unloadGate.release()
        await fixture.loads.wait(for: 2)
        fixture.scheduler.fireLatest()
        await fixture.runtime(2).unloads.wait(for: 1)
        unloadGate.release()
    }

    @Test func aModelChangeDuringAJoinedLoadUsesTheNewSelectionNotTheUnloadingModel() async throws {
        let fixture = try await Fixture(gatedLoads: [1])
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.loads.wait(for: 1)
        let transcription = Task { @MainActor in try await fixture.transcribe() }
        await fixture.gate.waitForWaiters(1)
        // The main actor runs jobs in order, so one yield lets the transcription join the load.
        await Task.yield()
        fixture.coordinator.selectedModelDidChange()
        fixture.gate.release()

        #expect(try await transcription.value == "load 2")
        await fixture.runtime(1).unloads.wait(for: 1)
        #expect(await fixture.runtime(1).transcribeCount == 0)
        #expect(fixture.loads.count == 2)
    }

    @Test func aJoinedLoadThatFailsReportsItAndTheNextTranscriptionLoadsAgain() async throws {
        let fixture = try await Fixture(gatedLoads: [1], failingLoads: [1])
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "en-US")
        await fixture.loads.wait(for: 1)
        let transcription = Task { @MainActor in try await fixture.transcribe() }
        await fixture.gate.waitForWaiters(1)
        // The main actor runs jobs in order, so one yield lets the transcription join the load.
        await Task.yield()
        fixture.gate.release()

        await #expect(throws: CocoaError.self) { try await transcription.value }
        #expect(try await fixture.transcribe() == "load 2")
        #expect(fixture.loads.count == 2)
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

        #expect(fixture.loads.count == 0)
    }

    @Test func preparingDoesNothingForALanguageTheModelDoesNotSupport() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        fixture.coordinator.prepare(language: "ja-JP")
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.loads.count == 0)
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

    @Test func aHistoryRetryLeavesProcessingTimeOut() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let history = DictationHistoryService(
            recordingsDirectoryURL: fixture.root.appendingPathComponent("recordings", isDirectory: true),
            appVersion: "test"
        )
        let recording = try history.prepareRecording(language: "en-US")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: recording.audioURL)
        let failed = try history.completeRecording(
            recording,
            text: "",
            language: "en-US",
            duration: 2,
            transcriptionError: "Retry requested"
        )
        let service = DictationService(language: "en-US", history: history, transcriber: fixture.coordinator)

        await service.transcribe(failed)

        let retried = try #require(history.entries.first { $0.id == failed.id })
        #expect(retried.state == .completed)
        #expect(retried.metadata.processingTime == nil)
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

/// A coordinator over a fake installed model. Load N returns `runtime(N)`, whose transcript is
/// "load N"; loads listed in `gatedLoads` wait for `gate`, and those in `failingLoads` throw.
@MainActor
private final class Fixture {
    let root: URL
    let scheduler: PreloadIdleScheduler
    let gate: Gate
    let loads: Counter
    let coordinator: DictationTranscriptionCoordinator
    private var runtimes: [Int: PreloadRuntime] = [:]

    init(
        engine: DictationTranscriptionEngine = .whisperMediumEnglish,
        gatedLoads: Set<Int> = [],
        failingLoads: Set<Int> = [],
        unloadGate: Gate? = nil
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperPreload-\(UUID().uuidString)", isDirectory: true)
        let manager = DictationModelManager(modelsRoot: root, downloader: CompleteModelDownloader())
        await manager.download(.whisperMediumEnglish)
        let scheduler = PreloadIdleScheduler()
        let gate = Gate()
        let loads = Counter()
        self.scheduler = scheduler
        self.gate = gate
        self.loads = loads
        let registry = RuntimeRegistry()
        coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { engine },
            modelManager: manager,
            appleTranscriber: PreloadRuntime(transcript: "apple", unloadGate: nil),
            whisperFactory: { _ in
                loads.increment()
                let number = loads.count
                if gatedLoads.contains(number) { await gate.wait() }
                if failingLoads.contains(number) { throw CocoaError(.fileReadCorruptFile) }
                let runtime = PreloadRuntime(transcript: "load \(number)", unloadGate: unloadGate)
                registry.runtimes[number] = runtime
                return runtime
            },
            idleScheduler: scheduler,
            idleTimeout: 300
        )
        self.registry = registry
        #expect(manager.installedModelFolder(for: .whisperMediumEnglish) != nil)
    }

    private let registry: RuntimeRegistry

    /// Load `number`'s runtime, once that load has returned it.
    func runtime(_ number: Int) async -> PreloadRuntime {
        while registry.runtimes[number] == nil {
            await registry.registrations.wait(for: registry.registrations.count + 1)
        }
        return registry.runtimes[number]!
    }

    func transcribe() async throws -> String {
        try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("made-up.wav"),
            language: "en-US",
            recordedDuration: 2
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class RuntimeRegistry {
    let registrations = Counter()
    var runtimes: [Int: PreloadRuntime] = [:] {
        didSet { registrations.increment() }
    }
}

/// Counts events and lets a test wait for a count without polling.
@MainActor
private final class Counter {
    private(set) var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        count += 1
        let ready = waiters.filter { $0.target <= count }
        waiters.removeAll { $0.target <= count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

@MainActor
private final class Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let waiting = Counter()

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            waiting.increment()
        }
    }

    func waitForWaiters(_ count: Int) async { await waiting.wait(for: count) }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
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
    private let transcript: String
    private let unloadGate: Gate?
    let unloads = Counter()
    private(set) var transcribeCount = 0
    var unloadCount: Int { unloads.count }
    var partialTranscript: String { "" }

    init(transcript: String, unloadGate: Gate?) {
        self.transcript = transcript
        self.unloadGate = unloadGate
    }

    func transcribe(audioURL: URL, language: String, recordedDuration: TimeInterval) async throws -> String {
        transcribeCount += 1
        return transcript
    }

    func cancel() {}

    func unload() -> Task<Void, Never> {
        unloads.increment()
        let unloadGate = unloadGate
        return Task { @MainActor in await unloadGate?.wait() }
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
