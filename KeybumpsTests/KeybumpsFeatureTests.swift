import AVFoundation
import AppKit
import Carbon.HIToolbox
import Security
import XCTest
@testable import Keybumps

@MainActor
private final class StubGlobalHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    private(set) var activeIdentifiers: Set<UInt32> = []
    private var handler: ((UInt32) -> Void)?
    private let registrationResult: (ShortcutBinding) -> Bool

    init(registrationResult: @escaping (ShortcutBinding) -> Bool = { _ in true }) {
        self.registrationResult = registrationResult
    }

    func installHandler(_ handler: @escaping (UInt32) -> Void) {
        self.handler = handler
    }

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
        guard registrationResult(binding) else { return false }
        activeIdentifiers.insert(identifier)
        return true
    }

    func unregister(identifier: UInt32) {
        activeIdentifiers.remove(identifier)
    }

    func send(identifier: UInt32) {
        handler?(identifier)
    }
}

private final class StubSymbolicHotKeyPreferences: SymbolicHotKeyPreferences {
    enum Failure: Error { case write }

    var hotKeys: [String: Any]
    var failsWrite = false
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var reloadCount = 0

    init(hotKeys: [String: Any]) {
        self.hotKeys = hotKeys
    }

    func readSymbolicHotKeys() throws -> [String: Any] {
        readCount += 1
        return hotKeys
    }

    func writeSymbolicHotKeys(_ hotKeys: [String: Any]) throws {
        if failsWrite { throw Failure.write }
        self.hotKeys = hotKeys
        writeCount += 1
    }

    func reloadSymbolicHotKeys() throws {
        reloadCount += 1
    }
}

@MainActor
private struct StubAppPresenceController: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}

private struct InMemoryEventPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

private struct StubDictationModelDownloader: DictationModelDownloading {
    let download: @MainActor (
        _ modelIdentifier: String,
        _ downloadBase: URL,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    func downloadModel(
        identifier: String,
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await download(identifier, downloadBase, progress)
    }
}

@MainActor
private final class StubCompletedAudioTranscriber: UnloadableCompletedAudioTranscribing {
    private(set) var calls: [(URL, String, TimeInterval)] = []
    private(set) var cancelCount = 0
    private(set) var unloadCount = 0
    let result: Result<String, Error>

    init(result: Result<String, Error>) {
        self.result = result
    }

    var partialTranscript: String {
        (try? result.get()) ?? ""
    }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        calls.append((audioURL, language, recordedDuration))
        return try result.get()
    }

    func cancel() {
        cancelCount += 1
    }

    func unload() -> Task<Void, Never> {
        unloadCount += 1
        return Task {}
    }
}

@MainActor
private final class CancellationThenSuccessTranscriber: UnloadableCompletedAudioTranscribing {
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var callCount = 0
    private(set) var unloadCount = 0

    var partialTranscript: String { "" }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        callCount += 1
        if callCount > 1 { return "warm after cancellation" }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func unload() -> Task<Void, Never> {
        unloadCount += 1
        return Task {}
    }
}

@MainActor
private final class AsyncVoidGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class DelayedUnloadTranscriber: UnloadableCompletedAudioTranscribing {
    private let transcript: String
    private let unloadGate: AsyncVoidGate
    private(set) var unloadCount = 0

    init(transcript: String, unloadGate: AsyncVoidGate) {
        self.transcript = transcript
        self.unloadGate = unloadGate
    }

    var partialTranscript: String { transcript }

    func transcribe(
        audioURL: URL,
        language: String,
        recordedDuration: TimeInterval
    ) async throws -> String {
        transcript
    }

    func cancel() {}

    func unload() -> Task<Void, Never> {
        unloadCount += 1
        let unloadGate = unloadGate
        return Task { @MainActor in await unloadGate.wait() }
    }
}

@MainActor
private final class TranscriberLoadGate {
    private var waiters: [CheckedContinuation<any UnloadableCompletedAudioTranscribing, Never>] = []

    func wait() async -> any UnloadableCompletedAudioTranscribing {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(with transcriber: any UnloadableCompletedAudioTranscribing) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: transcriber)
        }
    }
}

@MainActor
private final class ManualDictationRuntimeIdleScheduler: DictationRuntimeIdleScheduling {
    private final class Cancellation: DictationRuntimeIdleCancellation {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    private var scheduled: [(TimeInterval, Cancellation, @MainActor () -> Void)] = []

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any DictationRuntimeIdleCancellation {
        let cancellation = Cancellation()
        scheduled.append((delay, cancellation, operation))
        return cancellation
    }

    var latestDelay: TimeInterval? { scheduled.last?.0 }
    var scheduledCount: Int { scheduled.count }

    func fireLatest() {
        guard let latest = scheduled.indices.last else { return }
        fire(at: latest)
    }

    func fire(at index: Int) {
        let (_, cancellation, operation) = scheduled[index]
        guard
              !cancellation.isCancelled else { return }
        operation()
    }
}

@MainActor
final class KeybumpsFeatureTests: XCTestCase {
    func testSpotlightResolverDetectsEnabledExactQuickSearchConflict() {
        let preferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": [
                "enabled": true,
                "value": [
                    "type": "standard",
                    "parameters": [32, 49, 1_048_576]
                ]
            ]
        ])
        let resolver = SpotlightShortcutConflictResolver(preferences: preferences)

        XCTAssertEqual(resolver.status(for: DefaultShortcut.quickSearch), .conflict)
    }

    func testSpotlightResolverDisablesOnlyMatchingSpotlightShortcut() throws {
        let spotlightValue: [String: Any] = [
            "type": "standard",
            "parameters": [32, 49, 1_048_576],
            "futureField": "preserve"
        ]
        let sibling: [String: Any] = ["enabled": true, "value": ["opaque": 7]]
        let preferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": ["enabled": true, "value": spotlightValue, "opaque": "keep"],
            "65": sibling
        ])
        let resolver = SpotlightShortcutConflictResolver(preferences: preferences)

        XCTAssertEqual(resolver.disableIfConflicting(DefaultShortcut.quickSearch), .resolved)

        let spotlight = try XCTUnwrap(preferences.hotKeys["64"] as? [String: Any])
        XCTAssertEqual((spotlight["enabled"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual(spotlight["opaque"] as? String, "keep")
        XCTAssertEqual(spotlight["value"] as? NSDictionary, spotlightValue as NSDictionary)
        XCTAssertEqual(preferences.hotKeys["65"] as? NSDictionary, sibling as NSDictionary)
        XCTAssertEqual(preferences.writeCount, 1)
        XCTAssertEqual(preferences.reloadCount, 1)
    }

    func testSpotlightResolverDoesNotTreatMalformedPreferencesAsReady() {
        let preferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": ["enabled": true, "value": ["type": "standard"]]
        ])
        let resolver = SpotlightShortcutConflictResolver(preferences: preferences)

        guard case .unavailable(let manualRecovery) = resolver.status(for: DefaultShortcut.quickSearch) else {
            return XCTFail("Malformed Spotlight preferences must not be reported as no conflict")
        }
        XCTAssertTrue(manualRecovery.contains("System Settings"))
    }

    func testCustomQuickSearchBindingDoesNotModifySpotlight() {
        let preferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": [
                "enabled": true,
                "value": ["type": "standard", "parameters": [32, 49, 1_048_576]]
            ]
        ])
        let resolver = SpotlightShortcutConflictResolver(preferences: preferences)
        let customBinding = ShortcutBinding(
            keyCode: 40,
            modifiers: UInt32(cmdKey),
            displayName: "⌘ K"
        )

        XCTAssertEqual(resolver.status(for: customBinding), .noConflict)
        XCTAssertEqual(resolver.disableIfConflicting(customBinding), .noLongerConflicting)
        XCTAssertEqual(preferences.writeCount, 0)
        XCTAssertEqual(preferences.reloadCount, 0)
    }

    func testSpotlightWriteFailureReturnsManualRecoveryWithoutClaimingResolution() {
        let preferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": [
                "enabled": true,
                "value": ["type": "standard", "parameters": [32, 49, 1_048_576]]
            ]
        ])
        preferences.failsWrite = true
        let resolver = SpotlightShortcutConflictResolver(preferences: preferences)

        guard case .failed(let manualRecovery) = resolver.disableIfConflicting(
            DefaultShortcut.quickSearch
        ) else {
            return XCTFail("A preferences write failure must not report resolution")
        }
        XCTAssertTrue(manualRecovery.contains("System Settings"))
        let spotlight = preferences.hotKeys["64"] as? [String: Any]
        XCTAssertEqual((spotlight?["enabled"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual(preferences.reloadCount, 0)
    }

    func testFirstRunAutomaticallyDisablesSpotlightAndRetriesQuickSearchRegistration() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setCapability(.clipboardHistory, enabled: false)
        preferences.setCapability(.dictation, enabled: false)
        preferences.setCapability(.windowManagement, enabled: false)
        preferences.setCapability(.keyboardShortcutter, enabled: false)
        let symbolicPreferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": [
                "enabled": true,
                "value": ["type": "standard", "parameters": [32, 49, 1_048_576]]
            ]
        ])
        let backend = StubGlobalHotKeyBackend { _ in
            let spotlight = symbolicPreferences.hotKeys["64"] as? [String: Any]
            return (spotlight?["enabled"] as? NSNumber)?.boolValue == false
        }
        let coordinator = GlobalShortcutCoordinator(backend: backend)
        let model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: InMemoryEventPersistence()),
            presenceController: StubAppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            shortcutCoordinator: coordinator,
            updater: DisabledUpdateController(reason: "Unit test"),
            spotlightShortcutResolver: SpotlightShortcutConflictResolver(
                preferences: symbolicPreferences
            )
        )

        model.refreshQuickSearchShortcutConflict()

        XCTAssertEqual(model.quickSearchShortcutConflictStatus, .noConflict)
        XCTAssertTrue(coordinator.activeOwners.contains(CapabilityShortcut.quickSearch.ownerID))
        let spotlight = symbolicPreferences.hotKeys["64"] as? [String: Any]
        XCTAssertEqual((spotlight?["enabled"] as? NSNumber)?.boolValue, false)
    }

    func testOnboardingCannotClaimReadyWhenSpotlightRecoveryFails() {
        let guidance = "Open System Settings and disable the Spotlight shortcut."

        let failed = QuickSearchShortcutOnboardingPresentation.resolve(
            .unavailable(manualRecovery: guidance)
        )
        let ready = QuickSearchShortcutOnboardingPresentation.resolve(.noConflict)

        XCTAssertFalse(failed.canContinue)
        XCTAssertEqual(failed.manualRecovery, guidance)
        XCTAssertTrue(ready.canContinue)
        XCTAssertNil(ready.manualRecovery)
    }

    func testCompletedOnboardingDoesNotInspectOrModifySpotlight() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.didCompleteOnboarding = true
        let symbolicPreferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": [
                "enabled": true,
                "value": ["type": "standard", "parameters": [32, 49, 1_048_576]]
            ]
        ])
        let model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: InMemoryEventPersistence()),
            presenceController: StubAppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            updater: DisabledUpdateController(reason: "Unit test"),
            spotlightShortcutResolver: SpotlightShortcutConflictResolver(
                preferences: symbolicPreferences
            )
        )

        model.refreshQuickSearchShortcutConflict()

        XCTAssertEqual(symbolicPreferences.readCount, 0)
        XCTAssertEqual(symbolicPreferences.writeCount, 0)
        XCTAssertEqual(symbolicPreferences.reloadCount, 0)
    }

    func testFailedQuickSearchRetryKeepsOnboardingBlocked() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setCapability(.clipboardHistory, enabled: false)
        preferences.setCapability(.dictation, enabled: false)
        preferences.setCapability(.windowManagement, enabled: false)
        preferences.setCapability(.keyboardShortcutter, enabled: false)
        let symbolicPreferences = StubSymbolicHotKeyPreferences(hotKeys: [
            "64": ["enabled": false]
        ])
        let coordinator = GlobalShortcutCoordinator(
            backend: StubGlobalHotKeyBackend { _ in false }
        )
        let model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: InMemoryEventPersistence()),
            presenceController: StubAppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            shortcutCoordinator: coordinator,
            updater: DisabledUpdateController(reason: "Unit test"),
            spotlightShortcutResolver: SpotlightShortcutConflictResolver(
                preferences: symbolicPreferences
            )
        )

        model.refreshQuickSearchShortcutConflict()

        XCTAssertFalse(model.quickSearchShortcutOnboardingPresentation.canContinue)
        XCTAssertFalse(coordinator.activeOwners.contains(CapabilityShortcut.quickSearch.ownerID))
    }

    func testTestHostIsTheDebugIdentityBesideTheInstalledApp() throws {
        var appURL = Bundle(for: Self.self).bundleURL
        while appURL.pathExtension != "app", appURL.path != "/" {
            appURL.deleteLastPathComponent()
        }
        XCTAssertEqual(appURL.lastPathComponent, "Keybumps.app")
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        // Debug builds use their own identity; Release and QA builds keep com.serp.keybumps
        // (checked by scripts/build-qa-candidate.sh and the release validator).
        XCTAssertEqual(bundle.bundleIdentifier, "com.serp.keybumps.debug")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "com.serp.keybumps")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Keybumps")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, "Keybumps")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "Keybumps")
        XCTAssertFalse((bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").isEmpty)
        XCTAssertFalse((bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "").isEmpty)
        XCTAssertNotNil(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool, true)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool, true)
        for resource in [
            "LICENSE.rectangle",
            "LICENSE.argmax-oss-swift",
            "NOTICES.argmax-oss-swift",
            "LICENSE.openai-whisper"
        ] {
            XCTAssertNotNil(bundle.url(forResource: resource, withExtension: nil))
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: appURL.appendingPathComponent("Contents/MacOS/Keybumps").path
        ))
    }

    func testDictationInsertionTargetCanResolveAStillRunningApplication() throws {
        let currentApplication = NSRunningApplication.current
        let target = DictationInsertionTarget(application: currentApplication)

        XCTAssertEqual(target.processIdentifier, currentApplication.processIdentifier)
        XCTAssertEqual(
            try XCTUnwrap(target.runningApplication()).processIdentifier,
            currentApplication.processIdentifier
        )
    }

    func testSignedAppHasMicrophoneCaptureEntitlement() throws {
        // CI builds the host with CODE_SIGNING_ALLOWED=NO, which leaves only a linker signature
        // without entitlements. EntitlementsSourceTests covers the declared entitlement there.
        var code: SecCode?
        var information: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           let staticCode = Self.staticCode(for: code) {
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        }
        guard (information as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] != nil else {
            throw XCTSkip("The test host carries no entitlements (built with CODE_SIGNING_ALLOWED=NO).")
        }

        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.device.audio-input" as CFString,
            nil
        ) as? Bool

        XCTAssertEqual(value, true)
    }

    private static func staticCode(for code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        return SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess ? staticCode : nil
    }

    func testDictationShortcutStartsPermissionRecoveryInsteadOfFailingSilently() {
        XCTAssertEqual(
            DictationShortcutRouting.action(
                phase: .idle,
                missingPermissions: [.microphone, .speechRecognition]
            ),
            .showPermissionSetup
        )
        XCTAssertEqual(
            DictationShortcutRouting.action(phase: .idle, missingPermissions: []),
            .toggleDictation
        )
        XCTAssertEqual(
            DictationShortcutRouting.action(phase: .recording, missingPermissions: [.microphone]),
            .toggleDictation
        )
    }

    func testDictationEscapeIsCapturedOnlyWhileCancellationCanStillPreventInsertion() {
        XCTAssertFalse(DictationEscapeRegistration.shouldRegister(for: .idle))
        XCTAssertTrue(DictationEscapeRegistration.shouldRegister(for: .recording))
        XCTAssertTrue(DictationEscapeRegistration.shouldRegister(for: .transcribing))
        XCTAssertFalse(DictationEscapeRegistration.shouldRegister(for: .inserting))
        XCTAssertFalse(DictationEscapeRegistration.shouldRegister(for: .failed("Example")))
    }

    func testDictationTranscriptionEngineCatalogPersistsACompatibleSelection() {
        let defaults = InMemoryDefaults()

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.dictationTranscriptionEngine, .appleSpeech)
        XCTAssertFalse(DictationTranscriptionEngine.appleSpeech.requiresDownload)
        XCTAssertTrue(DictationTranscriptionEngine.whisperMediumEnglish.supports(language: "en-US"))
        XCTAssertFalse(DictationTranscriptionEngine.whisperMediumEnglish.supports(language: "ja-JP"))
        XCTAssertTrue(DictationTranscriptionEngine.whisperMediumMultilingual.supports(language: "ja-JP"))
        XCTAssertTrue(DictationTranscriptionEngine.whisperTurboCompressed.supports(language: "ja-JP"))
        XCTAssertEqual(PublicModelDownloadPolicy.anonymousToken, "")

        preferences.dictationTranscriptionEngine = .whisperMediumEnglish

        XCTAssertEqual(
            AppPreferences(defaults: defaults).dictationTranscriptionEngine,
            .whisperMediumEnglish
        )
    }

    func testDictationModelManagerDownloadsTracksAndDeletesOneModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsModelManager-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = StubDictationModelDownloader { identifier, downloadBase, progress in
            XCTAssertEqual(identifier, "medium.en")
            progress(0.4)
            let folder = downloadBase.appendingPathComponent("openai_whisper-medium.en", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent(component, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            progress(1)
            return folder
        }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: downloader
        )

        XCTAssertEqual(manager.state(for: .whisperMediumEnglish), .notInstalled)
        await manager.download(.whisperMediumEnglish)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(manager.state(for: .whisperMediumEnglish), .installed)
        XCTAssertNotNil(manager.installedModelFolder(for: .whisperMediumEnglish))

        try manager.delete(.whisperMediumEnglish)

        XCTAssertEqual(manager.state(for: .whisperMediumEnglish), .notInstalled)
        XCTAssertNil(manager.installedModelFolder(for: .whisperMediumEnglish))
    }

    func testTranscriptionCoordinatorUsesInstalledSelectedWhisperModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsEngineRouting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = StubDictationModelDownloader { _, downloadBase, _ in
            let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent(component, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            return folder
        }
        let manager = DictationModelManager(modelsRoot: root, downloader: downloader)
        await manager.download(.whisperMediumMultilingual)
        let apple = StubCompletedAudioTranscriber(result: .success("apple"))
        let whisper = StubCompletedAudioTranscriber(result: .success("whisper"))
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumMultilingual },
            modelManager: manager,
            appleTranscriber: apple,
            whisperFactory: { _ in whisper }
        )
        let audioURL = root.appendingPathComponent("recording.wav")

        let transcript = try await coordinator.transcribe(
            audioURL: audioURL,
            language: "ja-JP",
            recordedDuration: 42
        )

        XCTAssertEqual(transcript, "whisper")
        XCTAssertEqual(whisper.calls.count, 1)
        XCTAssertTrue(apple.calls.isEmpty)
    }

    func testTranscriptionCoordinatorReusesSelectedWhisperRuntimeAcrossSequentialDictations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWarmWhisper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let whisper = StubCompletedAudioTranscriber(result: .success("warm"))
        var loadCount = 0
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            whisperFactory: { _ in
                loadCount += 1
                return whisper
            }
        )

        for index in 1...2 {
            let transcript = try await coordinator.transcribe(
                audioURL: root.appendingPathComponent("recording-\(index).wav"),
                language: "en-US",
                recordedDuration: 5
            )
            XCTAssertEqual(transcript, "warm")
        }

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(whisper.calls.count, 2)
    }

    func testTranscriptionCoordinatorCoalescesOverlappingLoadsForTheSameModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCoalescedWhisper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let whisper = StubCompletedAudioTranscriber(result: .success("coalesced"))
        let gate = TranscriberLoadGate()
        var loadCount = 0
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            whisperFactory: { _ in
                loadCount += 1
                return await gate.wait()
            }
        )

        let first = Task { @MainActor in
            try await coordinator.transcribe(
                audioURL: root.appendingPathComponent("one.wav"),
                language: "en-US",
                recordedDuration: 2
            )
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await coordinator.transcribe(
                audioURL: root.appendingPathComponent("two.wav"),
                language: "en-US",
                recordedDuration: 2
            )
        }
        await Task.yield()

        XCTAssertEqual(loadCount, 1)
        gate.release(with: whisper)
        let firstTranscript = try await first.value
        let secondTranscript = try await second.value
        XCTAssertEqual(firstTranscript, "coalesced")
        XCTAssertEqual(secondTranscript, "coalesced")
        XCTAssertEqual(loadCount, 1)
    }

    func testTranscriptionCoordinatorEvictsOldRuntimeWhenModelSelectionChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperSwitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { identifier, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent(identifier, isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        await manager.download(.whisperTurboCompressed)
        var selectedEngine = DictationTranscriptionEngine.whisperMediumEnglish
        let medium = StubCompletedAudioTranscriber(result: .success("medium"))
        let turbo = StubCompletedAudioTranscriber(result: .success("turbo"))
        var loaded: [StubCompletedAudioTranscriber] = []
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { selectedEngine },
            modelManager: manager,
            whisperFactory: { modelFolder in
                let transcriber = modelFolder.lastPathComponent == "medium.en" ? medium : turbo
                loaded.append(transcriber)
                return transcriber
            }
        )

        let first = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("medium.wav"),
            language: "en-US",
            recordedDuration: 2
        )
        selectedEngine = .whisperTurboCompressed
        coordinator.selectedModelDidChange()
        let second = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("turbo.wav"),
            language: "en-US",
            recordedDuration: 2
        )

        XCTAssertEqual(first, "medium")
        XCTAssertEqual(second, "turbo")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(medium.unloadCount, 1)
        XCTAssertEqual(turbo.unloadCount, 0)
    }

    func testNewWhisperModelWaitsForOldRuntimeToUnload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperExclusiveRuntime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { identifier, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent(identifier, isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        await manager.download(.whisperTurboCompressed)
        var selectedEngine = DictationTranscriptionEngine.whisperMediumEnglish
        let unloadGate = AsyncVoidGate()
        let medium = DelayedUnloadTranscriber(transcript: "medium", unloadGate: unloadGate)
        let turbo = StubCompletedAudioTranscriber(result: .success("turbo"))
        var loadCount = 0
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { selectedEngine },
            modelManager: manager,
            whisperFactory: { modelFolder in
                loadCount += 1
                return modelFolder.lastPathComponent == "medium.en" ? medium : turbo
            }
        )
        _ = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("medium.wav"),
            language: "en-US",
            recordedDuration: 2
        )
        selectedEngine = .whisperTurboCompressed
        coordinator.selectedModelDidChange()
        let next = Task { @MainActor in
            try await coordinator.transcribe(
                audioURL: root.appendingPathComponent("turbo.wav"),
                language: "en-US",
                recordedDuration: 2
            )
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(medium.unloadCount, 1)
        XCTAssertEqual(loadCount, 1)
        unloadGate.release()

        let transcript = try await next.value
        XCTAssertEqual(transcript, "turbo")
        XCTAssertEqual(loadCount, 2)
    }

    func testTranscriptionCoordinatorEvictsWarmRuntimeAfterFiveMinutesOfInactivity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperIdle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let scheduler = ManualDictationRuntimeIdleScheduler()
        let firstRuntime = StubCompletedAudioTranscriber(result: .success("first"))
        let secondRuntime = StubCompletedAudioTranscriber(result: .success("second"))
        var runtimes = [firstRuntime, secondRuntime]
        var loadCount = 0
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            whisperFactory: { _ in
                defer { loadCount += 1 }
                return runtimes.removeFirst()
            },
            idleScheduler: scheduler,
            idleTimeout: 300
        )

        _ = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("first.wav"),
            language: "en-US",
            recordedDuration: 2
        )
        XCTAssertEqual(scheduler.latestDelay, 300)
        XCTAssertEqual(firstRuntime.unloadCount, 0)

        scheduler.fireLatest()

        XCTAssertEqual(firstRuntime.unloadCount, 1)
        let transcript = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("second.wav"),
            language: "en-US",
            recordedDuration: 2
        )
        XCTAssertEqual(transcript, "second")
        XCTAssertEqual(loadCount, 2)
    }

    func testSuccessfulWarmUseResetsTheFiveMinuteIdleEviction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperIdleReset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let scheduler = ManualDictationRuntimeIdleScheduler()
        let whisper = StubCompletedAudioTranscriber(result: .success("warm"))
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            whisperFactory: { _ in whisper },
            idleScheduler: scheduler,
            idleTimeout: 300
        )

        for index in 1...2 {
            _ = try await coordinator.transcribe(
                audioURL: root.appendingPathComponent("\(index).wav"),
                language: "en-US",
                recordedDuration: 2
            )
        }
        XCTAssertEqual(scheduler.scheduledCount, 2)

        scheduler.fire(at: 0)
        XCTAssertEqual(whisper.unloadCount, 0)
        scheduler.fire(at: 1)
        XCTAssertEqual(whisper.unloadCount, 1)
    }

    func testCancellingTranscriptionKeepsTheWhisperRuntimeWarmForTheNextDictation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperCancellation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let whisper = CancellationThenSuccessTranscriber()
        var loadCount = 0
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            whisperFactory: { _ in
                loadCount += 1
                return whisper
            }
        )
        let cancelled = Task { @MainActor in
            try await coordinator.transcribe(
                audioURL: root.appendingPathComponent("cancelled.wav"),
                language: "en-US",
                recordedDuration: 2
            )
        }
        for _ in 0..<100 where whisper.callCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(whisper.callCount, 1)

        coordinator.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let transcript = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("next.wav"),
            language: "en-US",
            recordedDuration: 2
        )
        XCTAssertEqual(transcript, "warm after cancellation")
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(whisper.unloadCount, 0)
    }

    func testFailedWhisperLoadIsClearedSoRetryCanSucceed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperLoadRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let whisper = StubCompletedAudioTranscriber(result: .success("recovered"))
        var loadCount = 0
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            whisperFactory: { _ in
                loadCount += 1
                if loadCount == 1 {
                    throw NSError(domain: "KeybumpsTests", code: 42)
                }
                return whisper
            }
        )

        do {
            _ = try await coordinator.transcribe(
                audioURL: root.appendingPathComponent("first.wav"),
                language: "en-US",
                recordedDuration: 2
            )
            XCTFail("Expected first load to fail")
        } catch {}

        let transcript = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("retry.wav"),
            language: "en-US",
            recordedDuration: 2
        )
        XCTAssertEqual(transcript, "recovered")
        XCTAssertEqual(loadCount, 2)
    }

    func testDeletingSelectedWhisperModelEvictsRuntimeAndFallsBackToAppleSpeech() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWhisperDeletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        var selectedEngine = DictationTranscriptionEngine.whisperMediumEnglish
        let whisper = StubCompletedAudioTranscriber(result: .success("whisper"))
        let apple = StubCompletedAudioTranscriber(result: .success("apple"))
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { selectedEngine },
            modelManager: manager,
            appleTranscriber: apple,
            whisperFactory: { _ in whisper }
        )

        _ = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("whisper.wav"),
            language: "en-US",
            recordedDuration: 2
        )
        selectedEngine = .appleSpeech
        coordinator.selectedModelWasDeleted()
        try manager.delete(.whisperMediumEnglish)
        let transcript = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("apple.wav"),
            language: "en-US",
            recordedDuration: 2
        )

        XCTAssertEqual(whisper.unloadCount, 1)
        XCTAssertEqual(transcript, "apple")
        XCTAssertEqual(apple.calls.count, 1)
    }

    func testHistoryRetriesReuseTheWarmWhisperRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsWarmHistoryRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let manager = DictationModelManager(
            modelsRoot: modelsRoot,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try Self.createCompleteModelFolder(at: folder)
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let whisper = StubCompletedAudioTranscriber(result: .success("history transcript"))
        var loadCount = 0
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            whisperFactory: { _ in
                loadCount += 1
                return whisper
            }
        )
        let history = DictationHistoryService(recordingsDirectoryURL: recordingsRoot)
        var retryEntries: [DictationHistoryEntry] = []
        for timestamp in [1_700_000_000.0, 1_700_000_001.0] {
            let recording = try history.prepareRecording(
                capturedAt: Date(timeIntervalSince1970: timestamp),
                language: "en-US"
            )
            try Self.writeMinimalWAV(to: recording.audioURL)
            retryEntries.append(try history.completeRecording(
                recording,
                text: "",
                language: "en-US",
                duration: 2,
                transcriptionError: "Retry requested"
            ))
        }
        let service = DictationService(
            language: "en-US",
            fileManager: .default,
            history: history,
            transcriber: coordinator
        )

        for entry in retryEntries {
            await service.transcribe(entry)
        }

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(whisper.calls.count, 2)
        XCTAssertEqual(history.entries.filter { $0.state == .completed }.count, 2)
    }

    func testTranscriptionCoordinatorFallsBackToAppleWhenSelectedModelIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsEngineFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, _, _ in root }
        )
        let apple = StubCompletedAudioTranscriber(result: .success("apple"))
        let coordinator = DictationTranscriptionCoordinator(
            selectedEngine: { .whisperMediumEnglish },
            modelManager: manager,
            appleTranscriber: apple,
            whisperFactory: { _ in StubCompletedAudioTranscriber(result: .success("whisper")) }
        )

        let transcript = try await coordinator.transcribe(
            audioURL: root.appendingPathComponent("recording.wav"),
            language: "en-US",
            recordedDuration: 3
        )

        XCTAssertEqual(transcript, "apple")
        XCTAssertEqual(apple.calls.count, 1)
    }

    private static func createCompleteModelFolder(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private static func writeMinimalWAV(to url: URL) throws {
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
    }

    func testDeletingSelectedDictationModelReturnsSelectionToAppleSpeech() async throws {
        let defaults = InMemoryDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsModelSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, downloadBase, _ in
                let folder = downloadBase.appendingPathComponent("model", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
                    try FileManager.default.createDirectory(
                        at: folder.appendingPathComponent(component, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                }
                return folder
            }
        )
        await manager.download(.whisperMediumEnglish)
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            inbox: InboxStore(persistence: InMemoryEventPersistence()),
            presenceController: StubAppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            updater: DisabledUpdateController(reason: "Unit test"),
            dictationModelManager: manager
        )

        model.selectDictationTranscriptionEngine(.whisperMediumEnglish)
        XCTAssertEqual(model.preferences.dictationTranscriptionEngine, .whisperMediumEnglish)

        model.deleteDictationModel(.whisperMediumEnglish)

        XCTAssertEqual(model.preferences.dictationTranscriptionEngine, .appleSpeech)
        XCTAssertEqual(manager.state(for: .whisperMediumEnglish), .notInstalled)
    }

    func testAppLaunchRepairsAStoredSelectionWhoseModelFilesAreMissing() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.dictationTranscriptionEngine = .whisperTurboCompressed
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsMissingModelSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DictationModelManager(
            modelsRoot: root,
            downloader: StubDictationModelDownloader { _, _, _ in root }
        )

        _ = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: InMemoryEventPersistence()),
            presenceController: StubAppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            updater: DisabledUpdateController(reason: "Unit test"),
            dictationModelManager: manager
        )

        XCTAssertEqual(preferences.dictationTranscriptionEngine, .appleSpeech)
    }

    func testUnmodifiedEscapeCanBeRegisteredAsATemporaryGlobalShortcut() {
        let coordinator = GlobalShortcutCoordinator()
        let owner = "test.dictation.escape"
        defer { coordinator.unregister(owner: owner) }

        XCTAssertTrue(
            coordinator.register(owner: owner, binding: DefaultShortcut.cancelDictation) {}
        )
    }

    func testGlobalShortcutsAreRestoredAfterRecordingCancellationAndFocusLoss() {
        let backend = StubGlobalHotKeyBackend()
        let coordinator = GlobalShortcutCoordinator(backend: backend)
        var invocations: [String] = []

        coordinator.register(owner: "quickSearch", binding: DefaultShortcut.quickSearch) {
            invocations.append("quickSearch")
        }
        coordinator.register(owner: "clipboardHistory", binding: DefaultShortcut.clipboard) {
            invocations.append("clipboardHistory")
        }
        XCTAssertEqual(coordinator.activeOwners, ["clipboardHistory", "quickSearch"])

        coordinator.suspendForRecording()
        XCTAssertTrue(coordinator.activeOwners.isEmpty)

        coordinator.resumeAfterRecording()
        XCTAssertEqual(coordinator.activeOwners, ["clipboardHistory", "quickSearch"])
        XCTAssertEqual(coordinator.desiredOwners, ["clipboardHistory", "quickSearch"])

        for identifier in backend.activeIdentifiers.sorted() {
            backend.send(identifier: identifier)
        }
        XCTAssertEqual(Set(invocations), ["quickSearch", "clipboardHistory"])
    }

    func testProductionShortcutCoordinatorUsesSystemWideRegistration() {
        XCTAssertEqual(GlobalShortcutCoordinator().registrationScope, .systemWide)
    }

    func testAppShellRestoresEveryConfiguredGlobalShortcutWhenRecordingLosesFocus() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.didCompleteOnboarding = true
        preferences.setCapability(.clipboardHistory, enabled: false)
        preferences.setCapability(.windowManagement, enabled: false)
        preferences.setCapability(.keyboardShortcutter, enabled: false)
        let backend = StubGlobalHotKeyBackend()
        let coordinator = GlobalShortcutCoordinator(backend: backend)
        let model = AppModel(
            preferences: preferences,
            inbox: InboxStore(),
            presenceController: AppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            shortcutCoordinator: coordinator
        )
        model.applyCapabilities()
        let configuredOwners = coordinator.activeOwners
        XCTAssertTrue(configuredOwners.contains(CapabilityShortcut.quickSearch.ownerID))
        XCTAssertTrue(configuredOwners.contains(CapabilityShortcut.dictation.ownerID))

        model.beginShortcutRecording()
        XCTAssertTrue(coordinator.activeOwners.isEmpty)
        XCTAssertEqual(coordinator.desiredOwners, configuredOwners)

        model.applicationDidResignActive()
        XCTAssertEqual(coordinator.activeOwners, configuredOwners)
        XCTAssertEqual(coordinator.desiredOwners, configuredOwners)
    }

    func testEveryMainWindowRouteReusesOneConfiguredOpener() {
        var openCount = 0
        var activationCount = 0
        let router = MainWindowRouter { activationCount += 1 }
        router.configure { openCount += 1 }
        let statusController = NativeStatusItemController(router: router)

        let menu = statusController.makeMenu()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Settings…"))
        XCTAssertTrue(router.open()) // Command-comma uses this same route.

        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(activationCount, 2)
        NSWindow.allowsAutomaticWindowTabbing = true
        AppDelegate.configureWindowBehavior()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testCommandPaletteAndSettingsUseIndependentActivationRoutes() {
        var paletteOpenCount = 0
        var settingsOpenCount = 0
        var applicationActivationCount = 0
        let paletteRouter = QuickSearchRouter()
        let settingsRouter = MainWindowRouter { applicationActivationCount += 1 }
        paletteRouter.configure { paletteOpenCount += 1 }
        settingsRouter.configure { settingsOpenCount += 1 }

        XCTAssertTrue(paletteRouter.open())
        XCTAssertEqual(paletteOpenCount, 1)
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertEqual(applicationActivationCount, 0)

        XCTAssertTrue(settingsRouter.open())
        XCTAssertEqual(paletteOpenCount, 1)
        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(applicationActivationCount, 1)
    }

    func testStatusItemOffersAndRoutesQuickSearchSeparatelyFromSettings() throws {
        let controller = NativeStatusItemController(router: MainWindowRouter())
        var quickSearchVisible = false
        controller.configureQuickSearch(
            isVisible: { quickSearchVisible },
            setVisible: { quickSearchVisible = $0 }
        )

        let menu = controller.makeMenu()
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "Open Keybumps",
                "About Keybumps",
                "Check for Updates…",
                "Settings…",
                "Quit Keybumps"
            ]
        )
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Check for Updates…")).isEnabled)
        controller.menuWillOpen(menu)
        menu.performActionForItem(at: 0)
        XCTAssertTrue(quickSearchVisible)

        controller.menuWillOpen(menu)
        controller.toggleQuickSearch()
        XCTAssertFalse(quickSearchVisible)
    }

    func testDockReopenDefaultsToQuickSearchInsteadOfSettings() async {
        let quickSearchRouter = QuickSearchRouter()
        var quickSearchOpenCount = 0
        quickSearchRouter.configure { quickSearchOpenCount += 1 }
        let delegate = AppDelegate(quickSearchRouter: quickSearchRouter)

        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: true))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(quickSearchOpenCount, 2)
    }

    func testClosingTheSettingsWindowKeepsTheCompanionRunning() {
        let delegate = AppDelegate(quickSearchRouter: QuickSearchRouter())

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testWindowShortcutCustomizationPersistsAndMovesDuplicateBinding() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        let binding = WindowAction.left.defaultShortcut!

        preferences.setWindowShortcut(binding, for: .right)

        XCTAssertNil(preferences.windowShortcut(for: .left))
        XCTAssertEqual(preferences.windowShortcut(for: .right), binding)
        XCTAssertEqual(AppPreferences(defaults: defaults).windowShortcut(for: .right), binding)
        preferences.setWindowShortcut(nil, for: .right)
        XCTAssertNil(preferences.windowShortcut(for: .right))
    }

    func testCapabilityShortcutsCanBeRecordedClearedPersistedAndReassigned() throws {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.capabilityShortcut(for: .quickSearch), DefaultShortcut.quickSearch)
        XCTAssertEqual(preferences.capabilityShortcut(for: .clipboardHistory), DefaultShortcut.clipboard)
        XCTAssertEqual(preferences.capabilityShortcut(for: .dictation), DefaultShortcut.dictation)

        preferences.setCapabilityShortcut(nil, for: .dictation)
        XCTAssertNil(AppPreferences(defaults: defaults).capabilityShortcut(for: .dictation))

        let custom = ShortcutBinding(keyCode: 2, modifiers: UInt32(controlKey | optionKey), displayName: "⌃⌥D")
        preferences.setCapabilityShortcut(custom, for: .dictation)
        XCTAssertEqual(AppPreferences(defaults: defaults).capabilityShortcut(for: .dictation), custom)

        preferences.setCapabilityShortcut(custom, for: .quickSearch)
        XCTAssertNil(preferences.capabilityShortcut(for: .dictation))
        XCTAssertEqual(preferences.capabilityShortcut(for: .quickSearch), custom)

        preferences.setWindowShortcut(custom, for: .left)
        XCTAssertNil(preferences.capabilityShortcut(for: .quickSearch))
        XCTAssertEqual(preferences.windowShortcut(for: .left), custom)

        let migrationDefaults = InMemoryDefaults()
        migrationDefaults.set(
            try JSONEncoder().encode([WindowAction.left.rawValue: DefaultShortcut.dictation]),
            forKey: "windowShortcuts"
        )
        let migrated = AppPreferences(defaults: migrationDefaults)
        XCTAssertEqual(migrated.windowShortcut(for: .left), DefaultShortcut.dictation)
        XCTAssertNil(migrated.capabilityShortcut(for: .dictation))
    }

    func testKeyboardShortcutterIsTheCanonicalUserFacingCapabilityName() {
        XCTAssertEqual(Capability.keyboardShortcutter.title, "Shortcut Coach")
        XCTAssertEqual(SettingsSection.keyboardShortcutter.rawValue, "Shortcut Coach")
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("Setup"))
        XCTAssertEqual(SettingsNavigationHistory().selection, .permissions)
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("Home"))
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("Dictation History"))
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("About"))
        XCTAssertTrue(MacPermission.inputMonitoring.explanation.contains("Shortcut Coach"))
        XCTAssertFalse(MacPermission.inputMonitoring.explanation.contains("Shortcut Coaching"))
    }

    func testPermissionReadinessCannotBeCompleteWhileAnyRequiredItemNeedsAttention() {
        let allGranted = Dictionary(
            uniqueKeysWithValues: MacPermission.allCases.map { ($0, PermissionAuthorizationState.granted) }
        )
        let deniedNotifications = PermissionReadinessSnapshot.resolve(
            enabledCapabilities: Set(Capability.allCases),
            states: allGranted,
            permissionsRequiringRelaunch: [],
            selectedChannels: [.nativeBanner],
            notificationAuthorization: .denied
        )

        XCTAssertFalse(deniedNotifications.isReady)
        XCTAssertEqual(deniedNotifications.completedCount, deniedNotifications.totalCount - 1)
        XCTAssertEqual(deniedNotifications.missingCount, 1)
        XCTAssertTrue(deniedNotifications.nativeNotificationNeedsAttention)

        var oneDenied = allGranted
        oneDenied[.inputMonitoring] = .denied
        let deniedInputMonitoring = PermissionReadinessSnapshot.resolve(
            enabledCapabilities: Set(Capability.allCases),
            states: oneDenied,
            permissionsRequiringRelaunch: [.inputMonitoring],
            selectedChannels: [],
            notificationAuthorization: .authorized
        )
        XCTAssertFalse(deniedInputMonitoring.isReady)
        XCTAssertEqual(deniedInputMonitoring.currentPermission, .inputMonitoring)
        XCTAssertTrue(deniedInputMonitoring.requiresRelaunch(.inputMonitoring))

        let staleGrantedInputMonitoring = PermissionReadinessSnapshot.resolve(
            enabledCapabilities: [.keyboardShortcutter],
            states: allGranted,
            permissionsRequiringRelaunch: [.inputMonitoring],
            selectedChannels: [],
            notificationAuthorization: .authorized
        )
        XCTAssertFalse(staleGrantedInputMonitoring.isReady)
        XCTAssertEqual(staleGrantedInputMonitoring.missingPermissions, [.inputMonitoring])
        XCTAssertEqual(staleGrantedInputMonitoring.missingCount, 1)
        XCTAssertEqual(staleGrantedInputMonitoring.currentPermission, .inputMonitoring)
    }

    func testPermissionSettingsExposeEveryRecoveryRowWithoutADisclosure() {
        XCTAssertFalse(PermissionSettingsPresentation.usesDisclosure)
        XCTAssertEqual(PermissionSettingsPresentation.visiblePermissions, MacPermission.allCases)
    }

    func testPermissionRecoveryActionsNeverLeaveARequiredPermissionInert() {
        for permission in MacPermission.allCases {
            XCTAssertEqual(
                PermissionCoordinator.recoveryAction(for: permission, state: .granted),
                .none
            )
            XCTAssertNotEqual(
                PermissionCoordinator.recoveryAction(for: permission, state: .denied),
                .none,
                "\(permission.title) must provide a recovery action when denied"
            )
        }
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .microphone, state: .notDetermined), .request)
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .speechRecognition, state: .notDetermined), .request)
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .accessibility, state: .required), .openSystemSettings)
        XCTAssertEqual(PermissionCoordinator.recoveryAction(for: .inputMonitoring, state: .required), .openSystemSettings)
    }

    func testPermissionSettingsRowsAlwaysExposeAUsefulAction() {
        for permission in MacPermission.allCases {
            XCTAssertEqual(
                PermissionSettingsRowAction.resolve(
                    permission: permission,
                    state: .granted,
                    requiresRelaunch: false
                ),
                .openSystemSettings
            )
        }

        XCTAssertEqual(
            PermissionSettingsRowAction.resolve(
                permission: .microphone,
                state: .notDetermined,
                requiresRelaunch: false
            ),
            .requestAccess
        )
        XCTAssertEqual(
            PermissionSettingsRowAction.resolve(
                permission: .accessibility,
                state: .required,
                requiresRelaunch: false
            ),
            .recoverInSystemSettings
        )
        XCTAssertEqual(
            PermissionSettingsRowAction.resolve(
                permission: .inputMonitoring,
                state: .granted,
                requiresRelaunch: true
            ),
            .restartKeybumps
        )
    }

    func testPromptablePermissionRowsRequestAccessOnlyBeforeTheFirstDecision() {
        for permission in [MacPermission.microphone, .speechRecognition] {
            XCTAssertEqual(
                PermissionSettingsRowAction.resolve(permission: permission, state: .notDetermined, requiresRelaunch: false),
                .requestAccess,
                "\(permission.title) should use the native prompt before the first decision"
            )
            for state in [PermissionAuthorizationState.denied, .restricted] {
                XCTAssertEqual(
                    PermissionSettingsRowAction.resolve(permission: permission, state: state, requiresRelaunch: false),
                    .recoverInSystemSettings,
                    "\(permission.title) \(state.rawValue) cannot be re-prompted and must recover in System Settings"
                )
            }
        }
    }

    func testEverySystemSettingsRecoveryShowsTheMatchingVisibleAssistant() {
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .accessibility,
                action: .openSystemSettings
            ),
            .applicationDrag
        )
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .inputMonitoring,
                action: .openSystemSettings
            ),
            .applicationDrag
        )
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .microphone,
                action: .openSystemSettings
            ),
            .enableSwitch
        )
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .speechRecognition,
                action: .openSystemSettings
            ),
            .enableSwitch
        )
        XCTAssertEqual(
            PermissionRecoveryPresentation.resolve(
                permission: .microphone,
                action: .request
            ),
            .nativePrompt
        )
        XCTAssertEqual(PermissionAssistantCopy.title, "Keybumps")
        XCTAssertEqual(
            PermissionAssistantCopy.dragInstruction,
            "Drag this card into the app list above"
        )
        XCTAssertEqual(
            PermissionAssistantCopy.switchInstruction(for: .microphone),
            "Turn on the Microphone switch in the list above."
        )
        XCTAssertFalse(PermissionAssistantCopy.switchInstruction(for: .microphone).contains("Add"))
    }

    func testPermissionSettingsLinksTargetTheCorrectPrivacyPanes() {
        XCTAssertTrue(MacPermission.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
        XCTAssertTrue(MacPermission.inputMonitoring.settingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
        XCTAssertTrue(MacPermission.microphone.settingsURL.absoluteString.hasSuffix("Privacy_Microphone"))
        XCTAssertTrue(MacPermission.speechRecognition.settingsURL.absoluteString.hasSuffix("Privacy_SpeechRecognition"))
    }

    func testPermissionRelaunchAdvisorFlagsUnusableListPermissionAfterReturningFromSettings() {
        var advisor = PermissionRelaunchAdvisor()

        advisor.didOpenSystemSettings(for: .inputMonitoring)
        XCTAssertTrue(advisor.permissionsRequiringRelaunch.isEmpty)

        advisor.didBecomeActive { permission in
            permission == .inputMonitoring ? .required : .granted
        }

        XCTAssertEqual(advisor.permissionsRequiringRelaunch, [.inputMonitoring])
    }

    func testPermissionRelaunchAdvisorDoesNotPromptWhenPermissionRefreshesSuccessfully() {
        var advisor = PermissionRelaunchAdvisor()

        advisor.didOpenSystemSettings(for: .accessibility)
        advisor.didBecomeActive { _ in .granted }

        XCTAssertTrue(advisor.permissionsRequiringRelaunch.isEmpty)
    }

    func testPermissionRelaunchAdvisorIgnoresPermissionsThatDoNotNeedAnAppRelaunch() {
        var advisor = PermissionRelaunchAdvisor()

        advisor.didOpenSystemSettings(for: .microphone)
        advisor.didBecomeActive { _ in .denied }

        XCTAssertTrue(advisor.permissionsRequiringRelaunch.isEmpty)
    }

    func testPermissionRelaunchPlanWaitsForCurrentProcessThenReopensSameBundle() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Keybumps.app", isDirectory: true)

        let plan = PermissionRelaunchPlan(bundleURL: bundleURL, processIdentifier: 42)

        XCTAssertEqual(plan.executableURL.path, "/bin/sh")
        XCTAssertEqual(plan.arguments.suffix(3), ["keybumps-relaunch", "42", bundleURL.path])
        XCTAssertTrue(plan.arguments[1].contains("kill -0"))
        XCTAssertTrue(plan.arguments[1].contains("/usr/bin/open -n"))
        XCTAssertTrue(plan.arguments[1].contains("exit 1"), "The detached helper must not wait forever if termination is cancelled")
    }

    func testApplicationBundleDragPayloadRoundTripsAsAFileURL() throws {
        let applicationURL = Bundle.main.bundleURL
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsDragPayload-\(UUID().uuidString)"))

        XCTAssertTrue(ApplicationBundleDragPayload.write(applicationURL, to: pasteboard))
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]

        XCTAssertEqual(objects?.first?.filePathURL, applicationURL)
    }

    func testPermissionHelperDismissesOnlyAfterAnAcceptedDrop() {
        XCTAssertTrue(ApplicationBundleDragPayload.shouldDismiss(after: .copy))
        XCTAssertTrue(ApplicationBundleDragPayload.shouldDismiss(after: .move))
        XCTAssertFalse(ApplicationBundleDragPayload.shouldDismiss(after: []))
    }

    func testOnlyListBasedPermissionsUseTheApplicationDragAssistant() {
        XCTAssertTrue(MacPermission.accessibility.usesApplicationDragAssistant)
        XCTAssertTrue(MacPermission.inputMonitoring.usesApplicationDragAssistant)
        XCTAssertFalse(MacPermission.microphone.usesApplicationDragAssistant)
        XCTAssertFalse(MacPermission.speechRecognition.usesApplicationDragAssistant)
    }

    func testPermissionSetupPlanAdvancesInOrderAndSkipsUnneededOrGrantedPermissions() {
        let allCapabilities = Set(Capability.allCases)
        XCTAssertEqual(
            PermissionSetupPlan.requiredPermissions(for: allCapabilities),
            [.accessibility, .inputMonitoring, .microphone, .speechRecognition, .screenRecording]
        )

        var granted: Set<MacPermission> = []
        var progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertEqual(progress.currentPermission, .accessibility)
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertEqual(progress.totalCount, 5)

        granted.formUnion([.accessibility, .inputMonitoring])
        progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertEqual(progress.currentPermission, .microphone)
        XCTAssertEqual(progress.completedCount, 2)

        let windowsOnly = PermissionSetupPlan.progress(for: [.windowManagement]) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertEqual(windowsOnly.requiredPermissions, [.accessibility])
        XCTAssertTrue(windowsOnly.isComplete)
        XCTAssertEqual(
            PermissionSetupPlan.requiredPermissions(for: [.dictation]),
            [.microphone, .speechRecognition]
        )
        XCTAssertEqual(
            PermissionSetupPlan.requiredPermissions(for: [.keyboardShortcutter]),
            [.accessibility, .inputMonitoring]
        )
        XCTAssertEqual(PermissionSetupPlan.requiredPermissions(for: [.screenshotTools]), [.screenRecording])

        granted = Set(MacPermission.allCases)
        progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertTrue(progress.isComplete)
        XCTAssertNil(progress.currentPermission)
        XCTAssertEqual(progress.completedCount, 5)
    }

    func testSettingsNavigationBackReturnsThroughVisitedScreensWithoutLooping() {
        var navigation = SettingsNavigationHistory()
        XCTAssertEqual(navigation.selection, .permissions)
        XCTAssertFalse(navigation.canGoBack)

        navigation.navigate(to: .dictation)
        navigation.navigate(to: .permissions)
        navigation.navigate(to: .permissions)
        XCTAssertEqual(navigation.backStack, [.permissions, .dictation])

        navigation.goBack()
        XCTAssertEqual(navigation.selection, .dictation)
        navigation.goBack()
        XCTAssertEqual(navigation.selection, .permissions)
        XCTAssertFalse(navigation.canGoBack)

        navigation.goBack()
        XCTAssertEqual(navigation.selection, .permissions)
    }

    func testCapabilitiesDefaultEnabledAndPersist() {
        let defaults = InMemoryDefaults()
        let first = AppPreferences(defaults: defaults)
        XCTAssertEqual(first.enabledCapabilities, Set(Capability.allCases))
        first.setCapability(.dictation, enabled: false)
        XCTAssertFalse(AppPreferences(defaults: defaults).enabledCapabilities.contains(.dictation))
    }

    func testDictationDurationDefaultsToFiveMinutesAndPersistsLongerChoices() {
        let defaults = InMemoryDefaults()

        let first = AppPreferences(defaults: defaults)
        XCTAssertEqual(first.dictationDurationLimit, .fiveMinutes)
        XCTAssertEqual(first.dictationDurationLimit.seconds, 300)
        XCTAssertEqual(
            DictationDurationLimit.allCases,
            [.fiveMinutes, .tenMinutes, .fifteenMinutes, .thirtyMinutes, .sixtyMinutes, .unlimited]
        )

        first.dictationDurationLimit = .thirtyMinutes
        XCTAssertEqual(AppPreferences(defaults: defaults).dictationDurationLimit, .thirtyMinutes)
        first.dictationDurationLimit = .unlimited
        XCTAssertNil(AppPreferences(defaults: defaults).dictationDurationLimit.seconds)
    }

    func testCapabilityShortcutEditorsUseCanonicalSpaceKeycaps() {
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: DefaultShortcut.quickSearch.displayName).keys, ["⌘", "Space"])
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: DefaultShortcut.clipboard.displayName).keys, ["⇧", "⌘", "Space"])
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: DefaultShortcut.dictation.displayName).keys, ["⌥", "Space"])
    }

    func testWindowManagementSharedToggleBindingReadsAndWritesCapabilityState() {
        let defaults = InMemoryDefaults()
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            inbox: InboxStore(persistence: InMemoryEventPersistence()),
            presenceController: StubAppPresenceController(),
            detector: ManualActionDetector(),
            presenter: PresentationWindowController(),
            updater: DisabledUpdateController(reason: "Unit test")
        )
        let toggle = CapabilityToggleBinding(model: model, capability: .windowManagement).value

        toggle.wrappedValue = false
        XCTAssertFalse(model.preferences.enabledCapabilities.contains(.windowManagement))

        toggle.wrappedValue = true
        XCTAssertTrue(model.preferences.enabledCapabilities.contains(.windowManagement))
    }

    func testVersionDisplayUsesCanonicalBundleVersionAndBuild() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsVersion-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.serp.keybumps.tests.version",
            "CFBundleName": "KeybumpsVersionFixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        XCTAssertEqual(AppVersionDisplay.title(bundle: bundle), "Keybumps 1.2.3 (456)")
    }

    func testDictationTranscribesTheCompletedAudioArchiveRatherThanAnEarlyLiveResult() {
        XCTAssertEqual(DictationTranscriptionPlan.source, .completedAudioFile)
        XCTAssertEqual(DictationTranscriptionPlan.timeout(forRecordedDuration: 10), 120)
        XCTAssertEqual(DictationTranscriptionPlan.timeout(forRecordedDuration: 300), 600)
        XCTAssertEqual(DictationTranscriptionPlan.timeout(forRecordedDuration: 3_600), 7_200)
    }

    func testDictationJoinsRecognitionSpansInsteadOfKeepingOnlyTheFinalWords() {
        var assembler = DictationTranscriptAssembler()

        assembler.receive(.init(
            text: "Opening sentence.",
            segmentStart: 0.39,
            segmentEnd: 1.89,
            isFinal: false
        ))
        assembler.receive(.init(
            text: "This",
            segmentStart: 0,
            segmentEnd: 0,
            isFinal: false
        ))
        assembler.receive(.init(
            text: "This is the much longer middle portion",
            segmentStart: 0,
            segmentEnd: 0,
            isFinal: false
        ))
        assembler.receive(.init(
            text: "This is the much longer middle portion of the dictation.",
            segmentStart: 3.84,
            segmentEnd: 20.52,
            isFinal: false
        ))
        assembler.receive(.init(
            text: "These",
            segmentStart: 0,
            segmentEnd: 0,
            isFinal: false
        ))
        assembler.receive(.init(
            text: "These are the final seven words spoken.",
            segmentStart: 22.26,
            segmentEnd: 24.87,
            isFinal: true
        ))

        XCTAssertEqual(
            assembler.transcript,
            "Opening sentence. This is the much longer middle portion of the dictation. These are the final seven words spoken."
        )
    }

    func testDictationTreatsSmallPartialRevisionsAsOneSpan() {
        var assembler = DictationTranscriptAssembler()

        assembler.receive(.init(
            text: "A sentence that is still being recognized now",
            segmentStart: 0,
            segmentEnd: 0,
            isFinal: false
        ))
        assembler.receive(.init(
            text: "A sentence that is still being recognized.",
            segmentStart: 0.4,
            segmentEnd: 4.8,
            isFinal: true
        ))

        XCTAssertEqual(assembler.transcript, "A sentence that is still being recognized.")
    }

    func testClipboardKeepsFiftyAndCollapsesDuplicates() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = ClipboardHistoryService(storageURL: url)
        XCTAssertEqual(ClipboardHistoryService.capacity, 50)
        for number in 0..<52 { service.ingestForTesting("item \(number)") }
        XCTAssertEqual(service.entries.count, 50)
        XCTAssertEqual(service.entries.first?.text, "item 51")
        XCTAssertEqual(service.entries.last?.text, "item 2")
        XCTAssertFalse(service.entries.contains { $0.text == "item 0" || $0.text == "item 1" })
        service.ingestForTesting("item 51")
        XCTAssertEqual(service.entries.count, 50)
        XCTAssertEqual(ClipboardHistoryService(storageURL: url).entries.count, 50)
    }

    func testClipboardEvictsOldestImageMediaAtCapacity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-evict-\(UUID().uuidString)")
        let storageURL = root.appendingPathComponent("history.json")
        let mediaURL = root.appendingPathComponent("media", isDirectory: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsEvictClipboard-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII="))
        let service = ClipboardHistoryService(storageURL: storageURL, pasteboard: pasteboard, mediaDirectoryURL: mediaURL)

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        service.pollForTesting()
        let imageURL = try XCTUnwrap(service.entries.first?.imageURL)
        for number in 0..<(ClipboardHistoryService.capacity - 1) { service.ingestForTesting("text \(number)") }
        XCTAssertEqual(service.entries.last?.kind, .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        service.ingestForTesting("one more")
        XCTAssertEqual(service.entries.count, ClipboardHistoryService.capacity)
        XCTAssertFalse(service.entries.contains { $0.kind == .image })
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testClipboardLoadsExistingTenItemHistoryUnchanged() throws {
        let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-ten-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let existing = (0..<10).map {
            ClipboardEntry(id: UUID(), text: "saved \($0)", capturedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double($0)))
        }
        try JSONEncoder().encode(existing).write(to: storageURL)

        let loaded = ClipboardHistoryService(storageURL: storageURL)
        XCTAssertEqual(loaded.entries, existing)
        loaded.ingestForTesting("new copy")
        XCTAssertEqual(loaded.entries.count, 11)
        XCTAssertEqual(Array(loaded.entries.dropFirst()), existing)
    }

    func testClipboardPersistsPreviewsAndRestoresCopiedImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-rich-\(UUID().uuidString)")
        let storageURL = root.appendingPathComponent("history.json")
        let mediaURL = root.appendingPathComponent("media", isDirectory: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsImageClipboard-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII="))
        let service = ClipboardHistoryService(
            storageURL: storageURL,
            pasteboard: pasteboard,
            mediaDirectoryURL: mediaURL
        )

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        service.pollForTesting()

        let entry = try XCTUnwrap(service.entries.first)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.displayText, "Image")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(entry.imageURL).path))
        XCTAssertEqual(
            ClipboardHistoryService(storageURL: storageURL, pasteboard: pasteboard, mediaDirectoryURL: mediaURL).entries.first,
            entry
        )

        pasteboard.clearContents()
        service.restore(entry)
        XCTAssertEqual(pasteboard.data(forType: .png), png)

        let imageURL = try XCTUnwrap(entry.imageURL)
        service.delete(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testClipboardLoadsLegacyTextOnlyHistory() throws {
        struct LegacyClipboardEntry: Encodable {
            let id: UUID
            let text: String
            let capturedAt: Date
        }

        let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let legacy = LegacyClipboardEntry(id: UUID(), text: "Legacy text", capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try JSONEncoder().encode([legacy]).write(to: storageURL)

        let loaded = ClipboardHistoryService(storageURL: storageURL)

        XCTAssertEqual(loaded.entries.first?.id, legacy.id)
        XCTAssertEqual(loaded.entries.first?.text, "Legacy text")
        XCTAssertEqual(loaded.entries.first?.kind, .text)
    }

    func testAutomaticDictationPasteIsExcludedFromClipboardHistoryOnlyOnce() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-\(UUID().uuidString).json")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsDictationSuppression-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: url) }
        let service = ClipboardHistoryService(storageURL: url, pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("automatic dictation", forType: .string)
        service.suppressCurrentChange()
        service.pollForTesting()
        XCTAssertTrue(service.entries.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("automatic dictation", forType: .string)
        service.pollForTesting()
        XCTAssertEqual(service.entries.map(\.text), ["automatic dictation"])
    }

    func testDictationHistoryStoresOneMetadataAndAudioPairPerRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-recordings-\(UUID().uuidString)")
        let sourceAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-source-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceAudio)
        }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: sourceAudio)
        let service = DictationHistoryService(recordingsDirectoryURL: root)
        let capturedAt = Date(timeIntervalSince1970: 1_763_015_623)

        let entry = try service.record(
            "A saved dictation",
            language: "en-US",
            capturedAt: capturedAt,
            duration: 1.5,
            audioSourceURL: sourceAudio
        )

        XCTAssertEqual(entry.id, "1763015623")
        XCTAssertEqual(entry.text, "A saved dictation")
        XCTAssertEqual(entry.language, "en-US")
        XCTAssertEqual(entry.duration, 1.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(entry.audioURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dictation-history.json").path))

        let secondEntry = try service.record(
            "Another dictation from the same second",
            language: "ja-JP",
            capturedAt: capturedAt,
            duration: 2,
            audioSourceURL: sourceAudio
        )
        XCTAssertEqual(secondEntry.id, "1763015623-2")

        let reloaded = DictationHistoryService(recordingsDirectoryURL: root)
        XCTAssertEqual(reloaded.entries.map(\.id), ["1763015623-2", "1763015623"])

        reloaded.delete(try XCTUnwrap(reloaded.entries.first { $0.id == entry.id }))
        XCTAssertEqual(reloaded.entries.map(\.id), ["1763015623-2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.directoryURL.path))
        reloaded.clear()
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondEntry.directoryURL.path))
    }

    func testDictationHistoryKeepsAllRecordingDirectoriesNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-recordings-\(UUID().uuidString)")
        let sourceAudio = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-source-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceAudio)
        }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: sourceAudio)
        let service = DictationHistoryService(recordingsDirectoryURL: root)

        for number in 0..<27 {
            try service.record(
                "dictation \(number)",
                language: number.isMultiple(of: 2) ? "en-US" : "ja-JP",
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(number)),
                duration: Double(number),
                audioSourceURL: sourceAudio
            )
        }

        XCTAssertEqual(service.entries.count, 27)
        XCTAssertEqual(service.entries.first?.text, "dictation 26")
        XCTAssertEqual(service.entries.last?.text, "dictation 0")
    }

    func testDictationHistoryCopiesTranscriptWithoutUsingARealClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsDictationCopy-\(UUID().uuidString)"))

        XCTAssertTrue(DictationHistoryClipboard.copy("Copied dictation", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied dictation")
    }

    func testDictationHistoryPreservesAudioWhenTranscriptionFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("failed-dictation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DictationHistoryService(recordingsDirectoryURL: root)
        let pending = try service.prepareRecording(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: pending.audioURL)

        let entry = try service.completeRecording(
            pending,
            text: "",
            language: "en-US",
            duration: 300,
            transcriptionError: "Recognition unavailable"
        )

        XCTAssertEqual(entry.displayText, "Transcription unavailable")
        XCTAssertEqual(entry.metadata.transcriptionError, "Recognition unavailable")
        XCTAssertNotNil(entry.audioURL)
        let reloaded = try XCTUnwrap(DictationHistoryService(recordingsDirectoryURL: root).entries.first)
        XCTAssertEqual(reloaded.metadata, entry.metadata)
        XCTAssertEqual(reloaded.directoryURL.standardizedFileURL, entry.directoryURL.standardizedFileURL)
        XCTAssertEqual(reloaded.audioURL?.standardizedFileURL, entry.audioURL?.standardizedFileURL)
    }

    func testPendingDictationIsRecoveredAndCompletedInTheSameHistoryEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-dictation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DictationHistoryService(recordingsDirectoryURL: root)
        let pending = try service.prepareRecording(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            language: "ja-JP"
        )
        try writeTestWAV(to: pending.audioURL)
        service.refresh()
        XCTAssertTrue(service.entries.isEmpty, "A live recording must not be recovered before relaunch")

        let recoveredService = DictationHistoryService(recordingsDirectoryURL: root)
        let recovered = try XCTUnwrap(recoveredService.entries.first)
        XCTAssertEqual(recovered.id, pending.id)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.language, "ja-JP")
        XCTAssertTrue(recovered.text.isEmpty)
        XCTAssertTrue(recovered.canTranscribe)
        XCTAssertGreaterThan(recovered.duration, 0)

        try recoveredService.markTranscribing(recovered, language: recovered.language)
        recoveredService.refresh()
        XCTAssertEqual(recoveredService.entries.first?.state, .transcribing)

        let completed = try recoveredService.completeTranscription(
            of: recovered,
            text: "Recovered transcript",
            language: recovered.language
        )
        XCTAssertEqual(completed.id, pending.id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.text, "Recovered transcript")
        XCTAssertFalse(completed.canTranscribe)

        let reloaded = try XCTUnwrap(DictationHistoryService(recordingsDirectoryURL: root).entries.first)
        XCTAssertEqual(reloaded.id, pending.id)
        XCTAssertEqual(reloaded.state, .completed)
        XCTAssertEqual(reloaded.text, "Recovered transcript")
    }

    func testLegacyAudioOnlyRecordingIsRecoveredButIntentionalCancellationIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-dictation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let orphanDirectory = root.appendingPathComponent("1700000000", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        try writeTestWAV(to: orphanDirectory.appendingPathComponent("output.wav"))

        let service = DictationHistoryService(recordingsDirectoryURL: root)
        let recovered = try XCTUnwrap(service.entries.first)
        XCTAssertEqual(recovered.id, "1700000000")
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.language, "und")
        XCTAssertTrue(recovered.canTranscribe)

        let cancelled = try service.prepareRecording(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_001),
            language: "en-US"
        )
        try writeTestWAV(to: cancelled.audioURL)
        service.discard(cancelled)
        service.refresh()

        XCTAssertEqual(service.entries.map(\.id), ["1700000000"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.directoryURL.path))
    }

    func testDictationPlaybackRatePickerUsesOnlySupportedRates() {
        XCTAssertEqual(DictationPlaybackRate.steps, [0.5, 0.75, 1, 1.25, 1.5, 2])

        let player = DictationAudioPlayer()
        player.setPlaybackRate(1.5)
        XCTAssertEqual(player.playbackRate, 1.5)
        player.setPlaybackRate(3)
        XCTAssertEqual(player.playbackRate, 1.5)
    }

    func testDictationHistoryAccordionKeepsOnlyOneExpandedRecording() {
        var expansion = DictationHistoryExpansion()

        expansion.toggle("first")
        XCTAssertEqual(expansion.expandedEntryID, "first")
        expansion.toggle("second")
        XCTAssertEqual(expansion.expandedEntryID, "second")
        expansion.toggle("second")
        XCTAssertNil(expansion.expandedEntryID)
    }

    func testDictationTranslationRequiresRealTranscriptText() {
        XCTAssertTrue(DictationTranslationPolicy.canTranslate("Translate this"))
        XCTAssertFalse(DictationTranslationPolicy.canTranslate("  \n "))
        XCTAssertEqual(
            DictationTranslationPolicy.preferredTargetIdentifier(
                sourceIdentifier: "en-US",
                supportedIdentifiers: ["fr", "ja", "es"]
            ),
            "ja"
        )
        XCTAssertEqual(
            DictationTranslationPolicy.preferredTargetIdentifier(
                sourceIdentifier: "ja-JP",
                supportedIdentifiers: ["fr", "en-US", "es"]
            ),
            "en-US"
        )
    }

    func testTranslatedSpeechSelectsAnInstalledVoiceForTheTargetLanguage() {
        let voices = [
            TranslationSpeechVoiceDescriptor(identifier: "english-us", language: "en-US"),
            TranslationSpeechVoiceDescriptor(identifier: "japanese", language: "ja-JP"),
            TranslationSpeechVoiceDescriptor(identifier: "english-uk", language: "en-GB")
        ]

        XCTAssertEqual(
            TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
                targetLanguageIdentifier: "ja",
                supportedVoices: voices
            ),
            "japanese"
        )
        XCTAssertEqual(
            TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
                targetLanguageIdentifier: "en-GB",
                supportedVoices: voices
            ),
            "english-uk"
        )
        XCTAssertNil(
            TranslationSpeechVoiceSelector.preferredVoiceIdentifier(
                targetLanguageIdentifier: "fr",
                supportedVoices: voices
            )
        )
    }

    func testTranslatedSpeechProducesTemporaryPlayableAudioAndCleansItUp() async throws {
        let speech = TranslatedSpeechPlayer()

        await speech.prepare(text: "A short local audio fixture.", languageIdentifier: "en-US")

        let audioURL = try XCTUnwrap(speech.audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertGreaterThan(speech.duration, 0)
        XCTAssertGreaterThan(try AVAudioFile(forReading: audioURL).length, 0)
        XCTAssertFalse(speech.isPreparing)

        speech.clear()
        XCTAssertNil(speech.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testCommandPaletteHasTheFiveRequestedTabsWithSearchAsDefault() {
        let state = CommandPaletteState()
        XCTAssertEqual(state.tab, .search)
        XCTAssertEqual(CommandPaletteTab.allCases, [.search, .clipboard, .screenshots, .dictation, .keyboardShortcutter])
        XCTAssertEqual(CommandPaletteTab.allCases.map(\.shortcutLabel), ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"])
        XCTAssertEqual(
            CommandPaletteTab.allCases.map(\.labelPresentation),
            [
                CommandPaletteTabLabel(shortcut: "⌘1", name: "Search"),
                CommandPaletteTabLabel(shortcut: "⌘2", name: "Clipboard"),
                CommandPaletteTabLabel(shortcut: "⌘3", name: "Screenshots"),
                CommandPaletteTabLabel(shortcut: "⌘4", name: "Dictation"),
                CommandPaletteTabLabel(shortcut: "⌘5", name: "Hotkeys")
            ]
        )
        XCTAssertEqual(
            CommandPaletteTab.allCases.map { ShortcutKeycapPresentation(shortcut: $0.shortcutLabel).keys },
            [["⌘", "1"], ["⌘", "2"], ["⌘", "3"], ["⌘", "4"], ["⌘", "5"]]
        )
        XCTAssertEqual(CommandPaletteTab.matchingCommandKey("3"), .screenshots)
        XCTAssertEqual(CommandPaletteTab.matchingCommandKey("4"), .dictation)
        XCTAssertEqual(CommandPaletteTab.matchingCommandKey("5"), .keyboardShortcutter)

        // The Hotkeys tab is hidden by default, except while it is open.
        XCTAssertFalse(AppPreferences(defaults: InMemoryDefaults()).showsHotkeysTab)
        let hidden = CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .search)
        XCTAssertEqual(hidden, [.search, .clipboard, .screenshots, .dictation])
        XCTAssertNil(CommandPaletteTab.matchingCommandKey("5", in: hidden))
        XCTAssertEqual(CommandPaletteTab.visibleTabs(showsHotkeys: false, selected: .keyboardShortcutter).last, .keyboardShortcutter)
        XCTAssertEqual(CommandPaletteTab.visibleTabs(showsHotkeys: true, selected: .search), CommandPaletteTab.allCases)
        XCTAssertNil(CommandPaletteTab.matchingCommandKey("6"))
        XCTAssertEqual(CommandPaletteTab.screenshots.primaryActionTitle, "Edit")
        XCTAssertEqual(CommandPaletteTab.screenshots.secondaryActionTitle, "Copy")
        XCTAssertNil(CommandPaletteTab.clipboard.secondaryActionTitle)
        XCTAssertEqual(CommandPaletteTab.screenshots.prompt, "Search screenshots")
        XCTAssertNil(CommandPaletteTab.keyboardShortcutter.primaryActionTitle)
        XCTAssertEqual(CommandPaletteTab.clipboard.primaryActionTitle, "Copy")
        XCTAssertEqual(CommandPaletteTab.dictation.primaryActionTitle, "Copy")
        XCTAssertEqual(CommandPaletteTab.clipboard.prompt, "Search clipboard history")
        XCTAssertEqual(CommandPaletteTab.dictation.prompt, "Search dictation history")
        XCTAssertEqual(CommandPaletteTab.keyboardShortcutter.prompt, "Search hotkeys")
        XCTAssertEqual(ClearAllButton.title, "Clear All")

        state.historyQuery = "private filter"
        state.selection = 3
        state.select(.dictation)

        XCTAssertEqual(state.tab, .dictation)
        XCTAssertEqual(state.historyQuery, "")
        XCTAssertEqual(state.selection, 0)
    }

    func testRecentItemsPersistBoundedDeduplicatedResultsAndSupportIndividualDeletion() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-items-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        var timestamp = Date(timeIntervalSince1970: 100)
        let store = RecentItemStore(storageURL: storageURL, limit: 3, now: { timestamp })
        let finder = QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Finder.app"), kind: .application)
        let safari = QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Safari.app"), kind: .application)
        let terminal = QuickSearchResult(url: URL(fileURLWithPath: "/Applications/Terminal.app"), kind: .application)
        let document = QuickSearchResult(url: URL(fileURLWithPath: "/tmp/Notes.txt"), kind: .file)

        store.record(finder)
        timestamp.addTimeInterval(1)
        store.record(safari)
        timestamp.addTimeInterval(1)
        store.record(finder)
        timestamp.addTimeInterval(1)
        store.record(terminal)
        timestamp.addTimeInterval(1)
        store.record(document)

        XCTAssertEqual(store.items.map(\.result), [document, terminal, finder])
        XCTAssertEqual(
            RecentItemStore(storageURL: storageURL, limit: 3).items.map(\.result),
            [document, terminal, finder]
        )

        store.delete(store.items[1])
        XCTAssertEqual(store.items.map(\.result), [document, finder])
        XCTAssertEqual(
            RecentItemStore(storageURL: storageURL, limit: 3).items.map(\.result),
            [document, finder]
        )

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func testQuickSearchRecordsOpenedItemsOnlyWhenAnOpenSucceeded() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-search-items-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let store = RecentItemStore(storageURL: storageURL)
        let result = QuickSearchResult(
            url: URL(fileURLWithPath: "/Applications/Finder.app"),
            kind: .application
        )
        let model = QuickSearchModel(recentItems: store, applications: [result])

        model.query = "Finder"
        XCTAssertTrue(store.items.isEmpty, "Typing or highlighting must not record history")
        model.recordOpenResult(result, succeeded: false)
        XCTAssertTrue(store.items.isEmpty, "A failed open must not record history")
        model.recordOpenResult(result, succeeded: true)
        XCTAssertEqual(store.items.map(\.result), [result])
    }

    func testQuickSearchLearnsSuccessfulApplicationLaunchesByFrequencyAndRecency() throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("application-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let now = Date(timeIntervalSince1970: 10_000)
        let usage = ApplicationUsageStore(storageURL: storageURL, now: { now })
        let terminal = QuickSearchResult(
            url: URL(fileURLWithPath: "/Applications/Terminal.app"),
            kind: .application
        )
        let iTerm = QuickSearchResult(
            url: URL(fileURLWithPath: "/Applications/iTerm.app"),
            kind: .application
        )
        let activityMonitor = QuickSearchResult(
            url: URL(fileURLWithPath: "/Applications/Activity Monitor.app"),
            kind: .application
        )
        let model = QuickSearchModel(
            recentItems: RecentItemStore(
                storageURL: storageURL.deletingPathExtension().appendingPathExtension("items.json")
            ),
            applicationUsage: usage,
            applications: [activityMonitor, iTerm, terminal]
        )

        model.query = "t"
        XCTAssertEqual(model.results.first, terminal, "Prefix relevance wins before usage is learned")

        model.recordOpenResult(iTerm, succeeded: true)
        model.recordOpenResult(iTerm, succeeded: true)
        model.refresh()

        XCTAssertEqual(model.results.first, iTerm, "Repeated recent launches should promote iTerm")
        XCTAssertEqual(usage.record(for: iTerm.url)?.launchCount, 2)
        XCTAssertEqual(
            ApplicationUsageStore(storageURL: storageURL, now: { now }).record(for: iTerm.url)?.launchCount,
            2
        )
    }

    func testQuickSearchDoesNotLearnFromFailedOrNonApplicationOpens() {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("application-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let usage = ApplicationUsageStore(storageURL: storageURL)
        let app = QuickSearchResult(
            url: URL(fileURLWithPath: "/Applications/iTerm.app"),
            kind: .application
        )
        let file = QuickSearchResult(
            url: URL(fileURLWithPath: "/tmp/term.txt"),
            kind: .file
        )
        let model = QuickSearchModel(applicationUsage: usage, applications: [app])

        model.query = "term"
        model.recordOpenResult(app, succeeded: false)
        model.recordOpenResult(file, succeeded: true)

        XCTAssertNil(usage.record(for: app.url))
        XCTAssertNil(usage.record(for: file.url))
    }

    func testKeyboardShortcutterPaletteRowsIgnoreReadStateAndTime() {
        let id = UUID()
        let unread = CoachingEvent(
            id: id,
            occurredAt: Date(timeIntervalSince1970: 1),
            applicationName: "Fixture",
            actionTitle: "Action",
            shortcut: "⌘F",
            isRead: false
        )
        let readLater = CoachingEvent(
            id: id,
            occurredAt: Date(timeIntervalSince1970: 9_999),
            applicationName: "Fixture",
            actionTitle: "Action",
            shortcut: "⌘F",
            isRead: true
        )

        XCTAssertEqual(
            CoachingEventRowPresentation(event: unread),
            CoachingEventRowPresentation(event: readLater)
        )
    }

    func testNotificationSettingsRecoveryTargetsKeybumps() {
        XCTAssertTrue(NotificationSettingsRecovery.url.absoluteString.contains("com.serp.keybumps"))
    }

    func testKeyboardShortcutterHistoryContentCentralizesEnablementAndFiltering() {
        let events = [
            CoachingEvent(applicationName: "Finder", actionTitle: "Open New Window", shortcut: "⌘N"),
            CoachingEvent(applicationName: "Safari", actionTitle: "New Tab", shortcut: "⌘T")
        ]

        XCTAssertEqual(KeyboardShortcutterHistoryContent.resolve(events: events, query: "finder", isEnabled: true).entries.map(\.applicationName), ["Finder"])
        XCTAssertEqual(KeyboardShortcutterHistoryContent.resolve(events: events, query: "new tab", isEnabled: true).entries.map(\.applicationName), ["Safari"])
        XCTAssertEqual(KeyboardShortcutterHistoryContent.resolve(events: events, query: "⌘N", isEnabled: true).entries.map(\.applicationName), ["Finder"])
        XCTAssertEqual(KeyboardShortcutterHistoryContent.resolve(events: events, query: "  ", isEnabled: true), .entries(events))
        XCTAssertEqual(KeyboardShortcutterHistoryContent.resolve(events: events, query: "", isEnabled: false), .disabled)
        XCTAssertEqual(KeyboardShortcutterHistoryContent.resolve(events: [], query: "", isEnabled: true), .empty)
    }

    func testMainWindowDisablesAutomaticTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = true
        AppDelegate.configureWindowBehavior()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testCommandPaletteKeepsItsWindowOpenForHistoryConfirmationSheet() {
        XCTAssertFalse(
            CommandPaletteDismissalPolicy.shouldDismiss(isPresentingConfirmation: true)
        )
        XCTAssertTrue(
            CommandPaletteDismissalPolicy.shouldDismiss(isPresentingConfirmation: false)
        )
    }

    func testCommandPalettePanelIsNonactivatingAndAcceptsKeyboardFocus() {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520)
        )
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 300, height: 30))
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView?.addSubview(field)
        defer { panel.orderOut(nil) }

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)

        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(field))

        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(panel.firstResponder === field.currentEditor())
    }

    func testSelectedRectangleShortcutProfileIsExactAndUnique() {
        let assigned = WindowAction.allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } }
        XCTAssertEqual(assigned.count, 29)
        XCTAssertEqual(WindowAction.left.defaultShortcut?.displayName, "⌃⌥⌘←")
        XCTAssertEqual(WindowAction.lastFourth.defaultShortcut?.keyCode, 119)
        XCTAssertNil(WindowAction.upperRight.defaultShortcut)
        XCTAssertEqual(Set(assigned.map { "\($0.1.keyCode)-\($0.1.modifiers)" }).count, assigned.count)
    }

    func testRectangleStyleSettingsLayoutContainsEverySupportedActionExactlyOnce() {
        XCTAssertEqual(
            WindowSettingsLayout.primaryLeading,
            [.left, .right, .centerHalf, .top, .bottom, .upperLeft, .upperRight, .lowerLeft, .lowerRight]
        )
        XCTAssertEqual(
            WindowSettingsLayout.primaryTrailing,
            [.maximize, .smaller, .larger, .center, .restore, .nextDisplay, .previousDisplay]
        )
        let displayed = WindowSettingsLayout.allGroups.flatMap { $0 }
        XCTAssertEqual(displayed.count, WindowAction.allCases.count)
        XCTAssertEqual(Set(displayed), Set(WindowAction.allCases))
        XCTAssertTrue(WindowAction.allCases.allSatisfy { $0.preview != nil })
    }

    func testWindowGeometryCoversOwnerSlices() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let current = CGRect(x: 100, y: 100, width: 600, height: 500)
        XCTAssertEqual(WindowGeometry.frame(for: .left, in: screen, current: current), CGRect(x: 0, y: 0, width: 600, height: 900))
        XCTAssertEqual(WindowGeometry.frame(for: .centerThird, in: screen, current: current), CGRect(x: 400, y: 0, width: 400, height: 900))
        XCTAssertEqual(WindowGeometry.frame(for: .bottomRightSixth, in: screen, current: current), CGRect(x: 800, y: 0, width: 400, height: 450))
        XCTAssertEqual(WindowGeometry.frame(for: .lastThreeFourths, in: screen, current: current), CGRect(x: 300, y: 0, width: 900, height: 900))
    }

    private func writeTestWAV(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        if let channel = buffer.floatChannelData?.pointee {
            channel.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        try file.write(from: buffer)
    }
}
