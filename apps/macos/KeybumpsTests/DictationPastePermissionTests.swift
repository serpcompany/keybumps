import AppKit
import AVFoundation
import Foundation
import Speech
import Testing
@testable import Keybumps

/// Dictation pastes by posting ⌘V, which macOS allows only with Accessibility (#192). These tests
/// lock that Dictation declares it, that setup asks for it once through System Settings, that
/// nothing outside the explicit request paths prompts, and that an untrusted paste never posts.
@MainActor
@Suite("Dictation paste permission")
struct DictationPastePermissionTests {
    @Test("Dictation requires Accessibility, Microphone, and Speech Recognition, in setup order")
    func dictationDeclaresAccessibility() {
        #expect(CapabilityDescriptor.dictation.requiredPermissions == [.accessibility, .microphone, .speechRecognition])
        #expect(PermissionSetupPlan.requiredPermissions(for: [.dictation]) == [.accessibility, .microphone, .speechRecognition])
    }

    @Test("The setup plan lists Accessibility once, however many capabilities need it")
    func setupPlanListsAccessibilityOnce() {
        let sharers: Set<Capability> = [.dictation, .windowManagement, .keyboardShortcutter]
        for enabled in [sharers, Set(Capability.allCases)] {
            let plan = PermissionSetupPlan.requiredPermissions(for: enabled)
            #expect(plan.filter { $0 == .accessibility }.count == 1)
            #expect(plan.first == .accessibility)
        }

        var granted: Set<MacPermission> = [.microphone, .speechRecognition]
        var progress = PermissionSetupPlan.progress(for: [.dictation]) { granted.contains($0) ? .granted : .required }
        #expect(progress.currentPermission == .accessibility)
        #expect(progress.completedCount == 2)
        #expect(progress.totalCount == 3)
        granted.insert(.accessibility)
        progress = PermissionSetupPlan.progress(for: [.dictation]) { granted.contains($0) ? .granted : .required }
        #expect(progress.isComplete)
    }

    @Test("Without Accessibility, the Dictation shortcut shows setup, which recovers through System Settings")
    func missingAccessibilityRoutesToSystemSettingsSetup() {
        var states = Dictionary(uniqueKeysWithValues: MacPermission.allCases.map { ($0, PermissionAuthorizationState.granted) })
        states[.accessibility] = .required
        let readiness = PermissionReadinessSnapshot.resolve(
            enabledCapabilities: [.dictation],
            states: states,
            permissionsRequiringRelaunch: []
        )

        #expect(readiness.missingPermissions == [.accessibility])
        #expect(readiness.missingCount == 1, "drives the Permissions page and Dock attention badges")
        #expect(DictationShortcutRouting.action(phase: .idle, missingPermissions: readiness.missingPermissions) == .showPermissionSetup)
        #expect(DictationShortcutRouting.action(phase: .recording, missingPermissions: readiness.missingPermissions) == .toggleDictation,
                "a Dictation already recording can still be stopped")
        let action = PermissionCoordinator.recoveryAction(for: .accessibility, state: .required)
        #expect(action == .openSystemSettings)
        #expect(PermissionRecoveryPresentation.resolve(permission: .accessibility, action: action) == .applicationDrag,
                "System Settings and the drag card, never a native prompt")
        #expect(PermissionSettingsRowAction.resolve(permission: .accessibility, state: .required, requiresRelaunch: false) == .recoverInSystemSettings)
    }

    @Test("Setup names every missing permission")
    func setupCopyNamesMissingPermissions() {
        #expect(MacPermission.names([]) == "")
        #expect(MacPermission.names([.accessibility]) == "Accessibility")
        #expect(MacPermission.names([.microphone, .speechRecognition]) == "Microphone and Speech Recognition")
        #expect(MacPermission.names([.accessibility, .microphone, .speechRecognition]) == "Accessibility, Microphone, and Speech Recognition")
        #expect(DictationSetupCopy.settingsNote(missing: [.accessibility])
                == "Dictation needs Accessibility access before its shortcut can record and paste.")
    }

    @Test("An insertion without Accessibility never writes the pasteboard or posts ⌘V")
    func untrustedInsertionNeverPosts() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var posts = 0
        var pasteboardWrites = 0
        var accessibilityChecks = 0
        let service = DictationService(
            language: "en-US",
            fileManager: sandbox.fileManager,
            history: sandbox.history,
            didWritePasteboard: { pasteboardWrites += 1 },
            allowsSystemAccess: true,
            accessibilityTrusted: {
                accessibilityChecks += 1
                return false
            },
            postPasteShortcut: {
                posts += 1
                return true
            }
        )

        await #expect(throws: DictationInsertionError.accessibilityRequired) {
            try await service.insert("transcript")
        }
        #expect(accessibilityChecks == 1)
        #expect(posts == 0)
        #expect(pasteboardWrites == 0)
        #expect(DictationInsertionError.accessibilityRequired.localizedDescription
                == "Dictation needs Accessibility access to paste. Your transcript was preserved.")
    }

    @Test("In the unit-test host, Dictation has no system access unless a test opts in")
    func unitTestHostDictationHasNoSystemAccess() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var accessibilityChecks = 0
        var posts = 0
        let service = DictationService(
            language: "en-US",
            fileManager: sandbox.fileManager,
            history: sandbox.history,
            accessibilityTrusted: {
                accessibilityChecks += 1
                return true
            },
            postPasteShortcut: {
                posts += 1
                return true
            }
        )

        service.start()
        #expect(service.phase == .failed("Audio capture is unavailable in this session."))
        await #expect(throws: DictationInsertionError.unavailableInSession) {
            try await service.insert("transcript")
        }
        #expect(accessibilityChecks == 0)
        #expect(posts == 0)
    }

    @Test("Dictation reads Accessibility through the permission coordinator")
    func appModelWiresAccessibilityIntoInsertion() async throws {
        let harness = try PromptHarness(allowsDictationSystemAccess: true)
        defer { harness.tearDown() }

        await #expect(throws: DictationInsertionError.accessibilityRequired) {
            try await harness.model.dictation.insert("transcript")
        }
        harness.grants.insert(.accessibility)
        // Trusted, the gate passes; with no recorded destination it stops before activating anything.
        await #expect(throws: DictationInsertionError.destinationUnavailable) {
            try await harness.model.dictation.insert("transcript")
        }
        #expect(harness.prompts.calls.isEmpty)
    }

    @Test("Refreshes, activation, and the Dictation shortcut never prompt or open System Settings")
    func nothingOutsideTheRequestPathPrompts() throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        for _ in 0..<5 {
            harness.model.refreshPermissions()
            harness.model.applicationDidBecomeActive()
        }
        #expect(harness.model.missingPermissions(for: .dictation) == [.accessibility, .microphone, .speechRecognition])
        #expect(harness.model.missingPermissionCount == 3)
        let dictation = try #require(harness.model.capabilities.module(for: .dictation) as? DictationModule)
        dictation.onShortcut?()
        dictation.onShortcut?()

        #expect(harness.prompts.calls.isEmpty)
        #expect(harness.model.dictation.phase == .idle, "the shortcut shows setup instead of recording")
    }

    @Test("Dictation setup asks for each permission once: Accessibility through System Settings, then the native prompts")
    func walkthroughAsksOnce() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.openSettings(.accessibility)] }
        // Let the drag card's delayed presentation finish before macOS reports the grant.
        try await Task.sleep(for: .milliseconds(600))
        for _ in 0..<5 { harness.model.refreshPermissions() }
        #expect(harness.prompts.calls == [.openSettings(.accessibility)], "re-reading state never asks again")

        harness.grants.insert(.accessibility)
        harness.model.refreshPermissions()
        try await harness.waitUntil { harness.prompts.calls.count == 2 }
        for _ in 0..<5 { harness.model.refreshPermissions() }
        #expect(harness.prompts.calls == [.openSettings(.accessibility), .requestMicrophone])

        harness.grants.insert(.microphone)
        harness.model.refreshPermissions()
        try await harness.waitUntil { harness.prompts.calls.count == 3 }
        harness.grants.insert(.speechRecognition)
        harness.model.refreshPermissions()

        #expect(harness.prompts.calls == [.openSettings(.accessibility), .requestMicrophone, .requestSpeechRecognition])
        #expect(!harness.model.isPermissionWalkthroughActive)
        #expect(harness.model.missingPermissions(for: .dictation).isEmpty)
    }
}

@MainActor
@Suite("Permission prompt sources")
struct PermissionPromptSourceTests {
    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Keybumps", isDirectory: true)

    @Test("The unit-test host's default prompts are inert")
    func unitTestHostPromptsAreInert() {
        #expect(UnitTestHost.isActive)
        #expect(PermissionPrompts.current.kind == .inert)
        #expect(PermissionPrompts.system.kind == .system)
    }

    @Test("Undecided Microphone and Speech Recognition prompt only through the injected requests")
    func recoveryUsesTheInjectedPrompts() async {
        var calls: [String] = []
        let coordinator = PermissionCoordinator(
            accessibilityTrusted: { false },
            inputMonitoringAuthorized: { false },
            microphoneAuthorizationStatus: { .notDetermined },
            speechAuthorizationStatus: { .notDetermined },
            screenRecordingAuthorized: { false },
            requestMicrophone: { calls.append("microphone") },
            requestSpeechRecognition: { calls.append("speech") },
            requestScreenRecording: { calls.append("screenRecording") },
            openSettings: { calls.append("settings.\($0.rawValue)") }
        )

        await coordinator.performRecovery(for: .microphone)
        await coordinator.performRecovery(for: .speechRecognition)
        await coordinator.performRecovery(for: .accessibility)
        await coordinator.performRecovery(for: .inputMonitoring)

        #expect(calls == ["microphone", "speech", "settings.accessibility", "settings.inputMonitoring"])
    }

    @Test("Only PermissionPrompts calls a prompt API, and nothing prompts for Accessibility, Input Monitoring, or event posting")
    func promptAPIsLiveOnlyInPermissionPrompts() throws {
        let allowedFile = "Permissions/PermissionPrompts.swift"
        let promptAPIs = ["AVCaptureDevice.requestAccess", "SFSpeechRecognizer.requestAuthorization", "CGRequestScreenCaptureAccess"]
        let forbiddenAPIs = [
            "AXIsProcessTrustedWithOptions", "kAXTrustedCheckOptionPrompt",
            "CGRequestListenEventAccess", "CGRequestPostEventAccess", "IOHIDRequestAccess"
        ]
        let sources = try Self.appSources()
        #expect(sources.keys.contains(allowedFile))

        for (path, text) in sources {
            for api in forbiddenAPIs {
                #expect(!text.contains(api), "\(path) asks macOS to prompt with \(api)")
            }
            guard path != allowedFile else { continue }
            for api in promptAPIs {
                #expect(!text.contains(api), "\(path) prompts with \(api); go through PermissionPrompts")
            }
        }
    }

    /// The files allowed to post keyboard events. Every caller must check Accessibility first,
    /// because macOS drops an untrusted post and shows its own alert. If the paste step moves to
    /// a shared paster, list that file here in place of Dictation's.
    private static let keyboardEventPosters = ["Dictation/DictationService.swift"]

    @Test("Only the Accessibility-gated paste step posts keyboard events")
    func eventPostingLivesOnlyInThePasteStep() throws {
        let postingAPIs = [".post(tap:", "CGEventPost", "postToPid", "CGEvent.post("]
        let sources = try Self.appSources()
        let posters = sources.filter { _, text in postingAPIs.contains(where: text.contains) }.keys.sorted()
        #expect(posters == Self.keyboardEventPosters)
    }

    @Test("No test uses the real system prompts")
    func testsNeverUseSystemPrompts() throws {
        let token = "PermissionPrompts" + ".system"
        let sources = try FileManager.default.contentsOfDirectory(at: Self.testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DictationPastePermissionTests.swift" }
        #expect(!sources.isEmpty)
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            #expect(!text.contains(token), "\(source.lastPathComponent) uses the real permission prompts")
        }
    }

    /// Every app Swift source, keyed by its path under `Keybumps/`.
    private static func appSources() throws -> [String: String] {
        let root = appDirectory.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var sources: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path.replacingOccurrences(of: root, with: "")
            sources[path] = try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }
}

// MARK: - Harness

/// A temporary folder for Dictation's history and recovery file, so no test reaches the owner's folders.
private struct Sandbox {
    let root: URL
    let fileManager: FileManager
    let history: DictationHistoryService

    @MainActor
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPastePermission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileManager = SandboxRootedFileManager(root: root)
        history = DictationHistoryService(recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Records every prompt and System Settings request a coordinator makes.
private final class PromptRecorder {
    enum Call: Equatable {
        case requestMicrophone
        case requestSpeechRecognition
        case requestScreenRecording
        case openSettings(MacPermission)
    }

    private(set) var calls: [Call] = []

    func record(_ call: Call) { calls.append(call) }
}

/// What the fake macOS reports as granted; everything else is undecided or missing.
private final class FakeGrants {
    private var granted: Set<MacPermission> = []

    func insert(_ permission: MacPermission) { granted.insert(permission) }
    func contains(_ permission: MacPermission) -> Bool { granted.contains(permission) }
}

/// A Dictation-only `AppModel` whose permissions are fakes that start undecided or missing.
@MainActor
private final class PromptHarness {
    let prompts: PromptRecorder
    let grants: FakeGrants
    let model: AppModel
    private let sandbox: Sandbox
    private let pasteboard: NSPasteboard
    private let clipboard: ClipboardHistoryService

    init(allowsDictationSystemAccess: Bool = false) throws {
        let prompts = PromptRecorder()
        let grants = FakeGrants()
        self.prompts = prompts
        self.grants = grants
        sandbox = try Sandbox()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsPastePermission-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.didCompleteOnboarding = true
        for capability in Capability.allCases where capability != .dictation {
            preferences.setCapability(capability, enabled: false)
        }
        preferences.setCapability(.dictation, enabled: true)
        clipboard = ClipboardHistoryService(
            fileManager: sandbox.fileManager,
            storageURL: sandbox.root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: sandbox.root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )

        let isGranted: (MacPermission) -> Bool = { grants.contains($0) }
        let permissions = PermissionCoordinator(
            accessibilityTrusted: { grants.contains(.accessibility) },
            inputMonitoringAuthorized: { grants.contains(.inputMonitoring) },
            microphoneAuthorizationStatus: { grants.contains(.microphone) ? .authorized : .notDetermined },
            speechAuthorizationStatus: { grants.contains(.speechRecognition) ? .authorized : .notDetermined },
            screenRecordingAuthorized: { grants.contains(.screenRecording) },
            requestMicrophone: { prompts.record(.requestMicrophone) },
            requestSpeechRecognition: { prompts.record(.requestSpeechRecognition) },
            requestScreenRecording: { prompts.record(.requestScreenRecording) },
            openSettings: { prompts.record(.openSettings($0)) }
        )
        model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: DiscardingPersistence()),
            presenceController: InertPresence(),
            detector: ManualActionDetector(monitor: IdlePointerMonitor(), permissions: FakeDetectorPermissions(isGranted: isGranted)),
            shortcutCoordinator: GlobalShortcutCoordinator(backend: IdleHotKeyBackend()),
            permissionCoordinator: permissions,
            updater: DisabledUpdateController(reason: "Dictation paste permission tests"),
            dictationModelManager: DictationModelManager(
                modelsRoot: sandbox.root.appendingPathComponent("models", isDirectory: true),
                downloader: WhisperKitModelDownloader()
            ),
            spotlightShortcutResolver: InertSpotlightShortcutResolver(),
            clipboard: clipboard,
            dictationHistory: sandbox.history,
            dictationIndicator: SilentIndicator(),
            dictationFileManager: sandbox.fileManager,
            allowsDictationSystemAccess: allowsDictationSystemAccess
        )
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for the permission walkthrough")
    }

    func tearDown() {
        clipboard.stop()
        pasteboard.releaseGlobally()
        sandbox.remove()
    }
}

private final class SandboxRootedFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}

private struct FakeDetectorPermissions: DetectorPermissionProviding {
    let isGranted: (MacPermission) -> Bool
    var isAccessibilityTrusted: Bool { isGranted(.accessibility) }
    var isInputMonitoringAuthorized: Bool { isGranted(.inputMonitoring) }
    func requestAccessibility() {}
    func requestInputMonitoring() {}
}

private final class IdlePointerMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    func start() -> Bool { true }
    func stop() {}
}

@MainActor
private final class IdleHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}

private struct InertPresence: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}

private struct DiscardingPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

private final class SilentIndicator: DictationIndicatorController {
    override func update(_ phase: DictationPhase) {}
}
