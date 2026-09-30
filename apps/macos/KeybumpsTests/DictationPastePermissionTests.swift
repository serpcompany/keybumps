import AppKit
import AVFoundation
import Foundation
import Speech
import Testing
@testable import Keybumps

/// Dictation pastes by posting ⌘V, which macOS allows only with Accessibility (#192). These tests
/// lock that Dictation declares it, that setup asks for it once through System Settings and keeps
/// going on its own, that nothing outside the explicit request paths prompts, and that an
/// untrusted paste never posts.
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

    @Test("While setup runs, the Dictation shortcut continues it instead of showing another card")
    func runningSetupRoutesToContinue() {
        #expect(DictationShortcutRouting.action(phase: .idle, missingPermissions: [.accessibility], isPermissionSetupRunning: true)
                == .continuePermissionSetup)
        #expect(DictationShortcutRouting.action(phase: .failed("x"), missingPermissions: [.microphone], isPermissionSetupRunning: true)
                == .continuePermissionSetup)
        #expect(DictationShortcutRouting.action(phase: .idle, missingPermissions: [], isPermissionSetupRunning: true) == .toggleDictation)
        #expect(DictationShortcutRouting.action(phase: .recording, missingPermissions: [.accessibility], isPermissionSetupRunning: true)
                == .toggleDictation)
    }

    @Test("Setup names every missing permission")
    func setupCopyNamesMissingPermissions() {
        #expect(MacPermission.names([]) == "")
        #expect(MacPermission.names([.accessibility]) == "Accessibility")
        #expect(MacPermission.names([.microphone, .speechRecognition]) == "Microphone and Speech Recognition")
        #expect(MacPermission.names([.accessibility, .microphone, .speechRecognition]) == "Accessibility, Microphone, and Speech Recognition")
        #expect(DictationSetupCopy.settingsNote(missing: [.accessibility])
                == "Dictation needs Accessibility access before its shortcut can record and paste.")
        #expect(PermissionAssistantCopy.relaunchInstruction(for: .accessibility) == "Restart Keybumps to finish Accessibility setup.")
    }

    @Test("An insertion without Accessibility never runs the paste step")
    func untrustedInsertionNeverPastes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var pastes = 0
        var accessibilityChecks = 0
        let service = DictationService(
            language: "en-US",
            fileManager: sandbox.fileManager,
            history: sandbox.history,
            allowsSystemAccess: true,
            accessibilityTrusted: {
                accessibilityChecks += 1
                return false
            },
            pasteStep: DictationPasteStep { _ in
                pastes += 1
                return .pasted
            }
        )

        await #expect(throws: DictationInsertionError.accessibilityRequired) {
            try await service.insert("transcript")
        }
        #expect(accessibilityChecks == 1)
        #expect(pastes == 0)
        #expect(DictationInsertionError.accessibilityRequired.localizedDescription
                == "Dictation needs Accessibility access to paste. Your transcript was preserved.")
    }

    @Test("The ⌘V poster itself refuses to post without Accessibility")
    func pasteShortcutChecksAccessibilityItself() {
        var sent = 0
        #expect(DictationPasteShortcut.post(accessibilityTrusted: { false }, send: { _ in sent += 1 }) == .accessibilityRequired)
        #expect(sent == 0)

        var flags: [CGEventFlags] = []
        #expect(DictationPasteShortcut.post(accessibilityTrusted: { true }, send: { flags.append($0.flags) }) == .pasted)
        #expect(flags.count == 2, "⌘V down and up, sent to the fake, never to macOS")
        #expect(flags.allSatisfy { $0.contains(.maskCommand) })
    }

    @Test("In the unit-test host, Dictation has no system access and an inert paste step unless a test opts in")
    func unitTestHostDictationHasNoSystemAccess() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var accessibilityChecks = 0
        let service = DictationService(
            language: "en-US",
            fileManager: sandbox.fileManager,
            history: sandbox.history,
            accessibilityTrusted: {
                accessibilityChecks += 1
                return true
            }
        )

        #expect(service.pasteStep.kind == .inert)
        #expect(DictationPasteStep.current(didWritePasteboard: {}).kind == .inert)
        service.start()
        #expect(service.phase == .failed("Audio capture is unavailable in this session."))
        await #expect(throws: DictationInsertionError.unavailableInSession) {
            try await service.insert("transcript")
        }
        #expect(accessibilityChecks == 0)

        let harness = try PromptHarness()
        defer { harness.tearDown() }
        #expect(harness.model.dictation.pasteStep.kind == .inert, "AppModel's default paste step is inert too")
    }

    @Test("Dictation reads Accessibility through the permission coordinator")
    func appModelWiresAccessibilityIntoInsertion() async throws {
        var pastes = 0
        let harness = try PromptHarness(
            allowsDictationSystemAccess: true,
            pasteStep: DictationPasteStep { _ in
                pastes += 1
                return .pasted
            }
        )
        defer { harness.tearDown() }

        await #expect(throws: DictationInsertionError.accessibilityRequired) {
            try await harness.model.dictation.insert("transcript")
        }
        harness.grants.grant(.accessibility)
        // Trusted, the gate passes; with no recorded destination it stops before activating anything.
        await #expect(throws: DictationInsertionError.destinationUnavailable) {
            try await harness.model.dictation.insert("transcript")
        }
        #expect(pastes == 0)
        #expect(harness.prompts.calls.isEmpty)
    }

    @Test("Refreshes, activation, and the Dictation shortcut never prompt or open System Settings")
    func nothingOutsideTheRequestPathPrompts() throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        for _ in 0..<5 {
            harness.model.refreshPermissions()
            harness.model.applicationDidBecomeActive()
            harness.activations.activate("com.example.Editor")
        }
        #expect(harness.model.missingPermissions(for: .dictation) == [.accessibility, .microphone, .speechRecognition])
        #expect(harness.model.missingPermissionCount == 3)
        harness.pressDictationShortcut()
        harness.pressDictationShortcut()

        #expect(harness.prompts.calls.isEmpty)
        #expect(harness.model.permissionAssistantPresentation == .dictationSetup([.accessibility, .microphone, .speechRecognition]))
        #expect(harness.model.dictation.phase == .idle, "the shortcut shows setup instead of recording")
    }

    @Test("Setup keeps going by itself: Accessibility through System Settings, then each native prompt once")
    func walkthroughAdvancesWithoutActivation() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.openSettings(.accessibility)] }
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        for _ in 0..<5 { harness.model.refreshPermissions() }
        #expect(harness.prompts.calls == [.openSettings(.accessibility)], "re-reading state never asks again")

        // Only the fake macOS changes from here: nothing calls refreshPermissions or activates Keybumps.
        harness.grants.grant(.accessibility)
        try await harness.waitUntil { harness.prompts.calls.count == 2 }
        #expect(harness.prompts.calls == [.openSettings(.accessibility), .requestMicrophone])
        #expect(harness.model.permissionAssistantPresentation == nil, "the drag card goes once Accessibility is on")

        harness.grants.grant(.microphone)
        try await harness.waitUntil { harness.prompts.calls.count == 3 }
        harness.grants.grant(.speechRecognition)
        try await harness.waitUntil { !harness.model.isPermissionWalkthroughActive }

        #expect(harness.prompts.calls == [.openSettings(.accessibility), .requestMicrophone, .requestSpeechRecognition])
        #expect(harness.model.missingPermissions(for: .dictation).isEmpty)
    }

    @Test("The shortcut during setup brings back the System Settings step, never a second card or prompt")
    func shortcutDuringSetupContinuesIt() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .dictationSetup([.accessibility, .microphone, .speechRecognition]))
        harness.model.beginPermissionWalkthrough(for: .dictation) // what the card's Set Up Dictation… does
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }

        harness.pressDictationShortcut()
        try await harness.waitUntil { harness.prompts.calls.count == 2 }
        #expect(harness.prompts.calls == [.openSettings(.accessibility), .openSettings(.accessibility)])
        try await Task.sleep(for: .milliseconds(500)) // the step's drag card comes back after System Settings opens
        #expect(harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility))

        harness.grants.grant(.accessibility)
        try await harness.waitUntil { harness.prompts.calls.count == 3 }
        // Microphone's prompt is on screen now; the shortcut leaves it alone.
        harness.pressDictationShortcut()
        harness.pressDictationShortcut()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.prompts.calls == [.openSettings(.accessibility), .openSettings(.accessibility), .requestMicrophone])
        #expect(harness.model.permissionAssistantPresentation == nil)
    }

    @Test("Answering Don't Allow to a native prompt ends setup instead of opening System Settings unasked")
    func declinedPromptEndsSetup() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }
        harness.grants.grant(.accessibility)

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.prompts.calls == [.requestMicrophone] }
        harness.grants.deny(.microphone)
        try await harness.waitUntil { !harness.model.isPermissionWalkthroughActive }
        #expect(harness.prompts.calls == [.requestMicrophone])

        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .dictationSetup([.microphone, .speechRecognition]),
                "the next press offers setup again, which recovers a denial through System Settings")
    }

    @Test("Setup stops re-checking after its time limit")
    func walkthroughMonitorIsBounded() async throws {
        let harness = try PromptHarness(pollInterval: .zero)
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { !harness.model.isPermissionWalkthroughActive }
        #expect(harness.model.missingPermissions(for: .dictation) == [.accessibility, .microphone, .speechRecognition])
        #expect(AppModel.permissionWalkthroughMaximumChecks == 600, "10 minutes at one check a second")
    }

    @Test("Leaving System Settings for another app shows Restart when macOS needs a relaunch, without activating Keybumps")
    func relaunchCardWithoutActivation() async throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.beginPermissionWalkthrough(for: .dictation)
        try await harness.waitUntil { harness.model.permissionAssistantPresentation == .applicationDrag(.accessibility) }
        harness.activations.activate(SystemSettingsPage.applicationBundleIdentifier)
        harness.activations.activate(Bundle.main.bundleIdentifier)
        #expect(harness.model.permissionsRequiringRelaunch.isEmpty, "System Settings and Keybumps itself don't count as leaving")

        // Keybumps was switched on in System Settings, but macOS still reports it untrusted.
        harness.activations.activate("com.example.Editor")
        #expect(harness.model.permissionsRequiringRelaunch == [.accessibility])
        #expect(harness.model.permissionAssistantPresentation == .relaunch(.accessibility))

        // The shortcut offers Restart rather than sending the user back to System Settings.
        harness.pressDictationShortcut()
        #expect(harness.model.permissionAssistantPresentation == .relaunch(.accessibility))
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.prompts.calls == [.openSettings(.accessibility)])
    }

    @Test("The workspace observer reports only the activated app's bundle identifier")
    func workspaceObserverReportsBundleIdentifier() async throws {
        let center = NotificationCenter()
        let observer = WorkspaceActivationObserver(center: center)
        var reported: [String?] = []
        observer.onActivate = { reported.append($0) }

        // The test host itself, so no test reads which of the owner's apps is in front.
        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
        )
        for _ in 0..<100 where reported.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(reported == [Bundle.main.bundleIdentifier])
    }

    @Test("Other System Settings pages open through the coordinator")
    func systemSettingsPagesOpenThroughTheCoordinator() throws {
        let harness = try PromptHarness()
        defer { harness.tearDown() }

        harness.model.openKeyboardShortcutSettings()
        harness.model.permissions.openSystemSettings(.filesAndFolders)

        #expect(harness.prompts.calls == [.openSystemSettings(.keyboardShortcuts), .openSystemSettings(.filesAndFolders)])
        #expect(MacPermission.microphone.settingsURL == SystemSettingsPage.privacy(.microphone).url)
        #expect(SystemSettingsPage.filesAndFolders.url.absoluteString.hasSuffix("Privacy_FilesAndFolders"))
        #expect(SystemSettingsPage.keyboardShortcuts.url.absoluteString.hasSuffix("Keyboard-Settings.extension?Shortcuts"))
    }
}

@MainActor
@Suite("Permission prompt sources")
struct PermissionPromptSourceTests {
    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Keybumps", isDirectory: true)

    /// macOS prompt APIs, matched by method name so the receiver's spelling doesn't matter.
    /// They may appear only in `PermissionPrompts.swift`.
    private static let promptPatterns = [
        #"\bCGRequestScreenCaptureAccess\b"#,
        #"\brequestAccess\s*\("#,                    // AVCaptureDevice, CNContactStore, EKEventStore
        #"\brequest\w*Authorization\b"#,             // SFSpeechRecognizer, UNUserNotificationCenter, CLLocationManager, PHPhotoLibrary
        #"\brequestRecordPermission\b"#,             // AVAudioApplication, AVAudioSession
        #"\bAVAudioApplication\b"#,
        #"\brequest(Full|WriteOnly)Access"#          // EventKit
    ]

    /// Prompts for Accessibility, Input Monitoring, or event posting. Nothing may call these.
    private static let forbiddenPatterns = [
        #"\bAXIsProcessTrustedWithOptions\b"#,
        #"\bkAXTrustedCheckOptionPrompt\b"#,
        #"\bCGRequest(?!ScreenCaptureAccess)\w*Access\b"#, // CGRequestListenEventAccess, CGRequestPostEventAccess
        #"\bIOHIDRequestAccess\b"#
    ]

    /// The files allowed to post keyboard events. The poster must check Accessibility itself,
    /// because macOS drops an untrusted post and shows its own alert. If the paste step moves to
    /// a shared paster, list that file here in place of Dictation's.
    private static let keyboardEventPosters = ["Dictation/DictationService.swift"]

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
            openSettings: { calls.append("settings.\($0.rawValue)") },
            openSystemSettings: { _ in calls.append("settings.page") }
        )

        await coordinator.performRecovery(for: .microphone)
        await coordinator.performRecovery(for: .speechRecognition)
        await coordinator.performRecovery(for: .accessibility)
        await coordinator.performRecovery(for: .inputMonitoring)
        await coordinator.performRecovery(for: .screenRecording)

        #expect(calls == [
            "microphone", "speech", "settings.accessibility", "settings.inputMonitoring",
            "screenRecording", "settings.screenRecording"
        ])
    }

    @Test("Only PermissionPrompts calls a prompt API, and nothing prompts for Accessibility, Input Monitoring, or event posting")
    func promptAPIsLiveOnlyInPermissionPrompts() throws {
        let allowedFile = "Permissions/PermissionPrompts.swift"
        let sources = try Self.appSources()
        #expect(sources.keys.contains(allowedFile))
        #expect(Self.matches(Self.promptPatterns, in: sources[allowedFile] ?? "").count >= 3, "the patterns still find the real calls")

        for (path, text) in sources {
            #expect(Self.matches(Self.forbiddenPatterns, in: text).isEmpty, "\(path) asks macOS to prompt for Accessibility, Input Monitoring, or event posting")
            guard path != allowedFile else { continue }
            #expect(Self.matches(Self.promptPatterns, in: text).isEmpty, "\(path) prompts outside PermissionPrompts")
        }
    }

    @Test("Only the Accessibility-gated ⌘V poster posts keyboard events")
    func eventPostingLivesOnlyInThePasteStep() throws {
        let postingPatterns = [#"\.post\s*\(\s*tap:"#, #"\bCGEventPost"#, #"\bpostToPid\b"#, #"\bpostToPSN\b"#]
        let sources = try Self.appSources()
        let posters = sources.filter { _, text in !Self.matches(postingPatterns, in: text).isEmpty }.keys.sorted()
        #expect(posters == Self.keyboardEventPosters)
    }

    @Test("Only SystemSettingsPage names a System Settings address")
    func systemSettingsAddressesLiveInOnePlace() throws {
        let sources = try Self.appSources()
        let openers = sources.filter { _, text in text.contains("x-apple.systempreferences") }.keys.sorted()
        #expect(openers == ["Infrastructure/SystemServices.swift"])
    }

    @Test("No test calls a prompt API or uses the real system prompts")
    func testsNeverPrompt() throws {
        let token = "PermissionPrompts" + ".system"
        let sources = try FileManager.default.contentsOfDirectory(at: Self.testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DictationPastePermissionTests.swift" }
        #expect(!sources.isEmpty)
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            #expect(!text.contains(token), "\(source.lastPathComponent) uses the real permission prompts")
            #expect(Self.matches(Self.promptPatterns + Self.forbiddenPatterns, in: text).isEmpty,
                    "\(source.lastPathComponent) calls a macOS prompt API")
        }
    }

    private static func matches(_ patterns: [String], in text: String) -> [String] {
        patterns.filter { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
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
        case openSystemSettings(SystemSettingsPage)
    }

    private(set) var calls: [Call] = []

    func record(_ call: Call) { calls.append(call) }
}

/// What the fake macOS reports. Everything starts undecided (Microphone, Speech Recognition) or missing.
private final class FakeGrants {
    private var granted: Set<MacPermission> = []
    private var denied: Set<MacPermission> = []

    func grant(_ permission: MacPermission) { granted.insert(permission) }
    func deny(_ permission: MacPermission) { denied.insert(permission) }
    func contains(_ permission: MacPermission) -> Bool { granted.contains(permission) }

    func microphoneStatus() -> AVAuthorizationStatus {
        granted.contains(.microphone) ? .authorized : denied.contains(.microphone) ? .denied : .notDetermined
    }

    func speechStatus() -> SFSpeechRecognizerAuthorizationStatus {
        granted.contains(.speechRecognition) ? .authorized : denied.contains(.speechRecognition) ? .denied : .notDetermined
    }
}

/// Reports app activations the test chooses, in place of the workspace.
@MainActor
private final class FakeActivations: ApplicationActivationObserving {
    var onActivate: ((String?) -> Void)?
    func activate(_ bundleIdentifier: String?) { onActivate?(bundleIdentifier) }
}

/// A Dictation-only `AppModel` whose permissions, prompts, activations, and paste step are fakes.
@MainActor
private final class PromptHarness {
    let prompts: PromptRecorder
    let grants: FakeGrants
    let activations = FakeActivations()
    let model: AppModel
    private let sandbox: Sandbox
    private let pasteboard: NSPasteboard
    private let clipboard: ClipboardHistoryService

    init(
        allowsDictationSystemAccess: Bool = false,
        pasteStep: DictationPasteStep? = nil,
        pollInterval: Duration = .milliseconds(10)
    ) throws {
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

        let permissions = PermissionCoordinator(
            accessibilityTrusted: { grants.contains(.accessibility) },
            inputMonitoringAuthorized: { grants.contains(.inputMonitoring) },
            microphoneAuthorizationStatus: { grants.microphoneStatus() },
            speechAuthorizationStatus: { grants.speechStatus() },
            screenRecordingAuthorized: { grants.contains(.screenRecording) },
            requestMicrophone: { prompts.record(.requestMicrophone) },
            requestSpeechRecognition: { prompts.record(.requestSpeechRecognition) },
            requestScreenRecording: { prompts.record(.requestScreenRecording) },
            openSettings: { prompts.record(.openSettings($0)) },
            openSystemSettings: { prompts.record(.openSystemSettings($0)) }
        )
        model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: DiscardingPersistence()),
            presenceController: InertPresence(),
            detector: ManualActionDetector(
                monitor: IdlePointerMonitor(),
                permissions: FakeDetectorPermissions(isGranted: { grants.contains($0) })
            ),
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
            allowsDictationSystemAccess: allowsDictationSystemAccess,
            dictationPasteStep: pasteStep,
            permissionPollInterval: pollInterval,
            applicationActivations: activations
        )
    }

    func pressDictationShortcut() {
        (model.capabilities.module(for: .dictation) as? DictationModule)?.onShortcut?()
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for the permission walkthrough")
    }

    func tearDown() {
        model.endPermissionWalkthrough()
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
