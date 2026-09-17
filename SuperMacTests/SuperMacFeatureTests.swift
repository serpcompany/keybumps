import AVFoundation
import Carbon.HIToolbox
import Security
import XCTest
@testable import SuperMac

@MainActor
private final class StubGlobalHotKeyBackend: GlobalHotKeyRegistering {
    private(set) var activeIdentifiers: Set<UInt32> = []
    private var handler: ((UInt32) -> Void)?

    func installHandler(_ handler: @escaping (UInt32) -> Void) {
        self.handler = handler
    }

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
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

@MainActor
final class SuperMacFeatureTests: XCTestCase {
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
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.device.audio-input" as CFString,
            nil
        ) as? Bool

        XCTAssertEqual(value, true)
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

    func testAppShellRestoresEveryConfiguredGlobalShortcutWhenRecordingLosesFocus() {
        let suite = "SuperMacHotKeyFocus-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.didCompleteOnboarding = true
        preferences.setCapability(.clipboardHistory, enabled: false)
        preferences.setCapability(.windowManagement, enabled: false)
        preferences.setCapability(.shortcutCoaching, enabled: false)
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

        statusController.makeMenu().performActionForItem(at: 5)
        XCTAssertTrue(router.open()) // Command-comma uses this same route.

        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(activationCount, 2)
        NSWindow.allowsAutomaticWindowTabbing = true
        AppDelegate.configureWindowBehavior()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testStatusItemOffersAndRoutesQuickSearchSeparatelyFromSettings() {
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
                "Toggle SuperMac",
                AppVersionDisplay.title(),
                "Check for Updates…",
                "Settings…",
                "Quit SuperMac"
            ]
        )
        XCTAssertFalse(menu.items[2].isEnabled)
        XCTAssertFalse(menu.items[3].isEnabled)
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
        let suite = "SuperMacWindowShortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let binding = SuperMacWindowAction.left.defaultShortcut!

        preferences.setWindowShortcut(binding, for: .right)

        XCTAssertNil(preferences.windowShortcut(for: .left))
        XCTAssertEqual(preferences.windowShortcut(for: .right), binding)
        XCTAssertEqual(AppPreferences(defaults: defaults).windowShortcut(for: .right), binding)
        preferences.setWindowShortcut(nil, for: .right)
        XCTAssertNil(preferences.windowShortcut(for: .right))
    }

    func testCapabilityShortcutsCanBeRecordedClearedPersistedAndReassigned() throws {
        let suite = "SuperMacCapabilityShortcuts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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

        let migrationSuite = "SuperMacCapabilityShortcutMigration-\(UUID().uuidString)"
        let migrationDefaults = UserDefaults(suiteName: migrationSuite)!
        defer { migrationDefaults.removePersistentDomain(forName: migrationSuite) }
        migrationDefaults.set(
            try JSONEncoder().encode([SuperMacWindowAction.left.rawValue: DefaultShortcut.dictation]),
            forKey: "windowShortcuts"
        )
        let migrated = AppPreferences(defaults: migrationDefaults)
        XCTAssertEqual(migrated.windowShortcut(for: .left), DefaultShortcut.dictation)
        XCTAssertNil(migrated.capabilityShortcut(for: .dictation))
    }

    func testKeyBumpsIsTheCanonicalUserFacingCapabilityName() {
        XCTAssertEqual(Capability.shortcutCoaching.title, "Key Bumps")
        XCTAssertEqual(SettingsSection.coaching.rawValue, "Key Bumps")
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("Setup"))
        XCTAssertEqual(SettingsNavigationHistory().selection, .permissions)
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("Home"))
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("Dictation History"))
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("About"))
        XCTAssertTrue(MacPermission.inputMonitoring.explanation.contains("Key Bumps"))
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
            enabledCapabilities: [.shortcutCoaching],
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
        XCTAssertEqual(PermissionAssistantCopy.title, "SuperMac")
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
        let bundleURL = URL(fileURLWithPath: "/Applications/SuperMac.app", isDirectory: true)

        let plan = PermissionRelaunchPlan(bundleURL: bundleURL, processIdentifier: 42)

        XCTAssertEqual(plan.executableURL.path, "/bin/sh")
        XCTAssertEqual(plan.arguments.suffix(3), ["supermac-relaunch", "42", bundleURL.path])
        XCTAssertTrue(plan.arguments[1].contains("kill -0"))
        XCTAssertTrue(plan.arguments[1].contains("/usr/bin/open -n"))
        XCTAssertTrue(plan.arguments[1].contains("exit 1"), "The detached helper must not wait forever if termination is cancelled")
    }

    func testApplicationBundleDragPayloadRoundTripsAsAFileURL() throws {
        let applicationURL = Bundle.main.bundleURL
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SuperMacDragPayload-\(UUID().uuidString)"))

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
            [.accessibility, .inputMonitoring, .microphone, .speechRecognition]
        )

        var granted: Set<MacPermission> = []
        var progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertEqual(progress.currentPermission, .accessibility)
        XCTAssertEqual(progress.completedCount, 0)
        XCTAssertEqual(progress.totalCount, 4)

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
            PermissionSetupPlan.requiredPermissions(for: [.shortcutCoaching]),
            [.accessibility, .inputMonitoring]
        )

        granted = Set(MacPermission.allCases)
        progress = PermissionSetupPlan.progress(for: allCapabilities) {
            granted.contains($0) ? .granted : .required
        }
        XCTAssertTrue(progress.isComplete)
        XCTAssertNil(progress.currentPermission)
        XCTAssertEqual(progress.completedCount, 4)
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
        let suite = "SuperMacCapabilities-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppPreferences(defaults: defaults)
        XCTAssertEqual(first.enabledCapabilities, Set(Capability.allCases))
        first.setCapability(.dictation, enabled: false)
        XCTAssertFalse(AppPreferences(defaults: defaults).enabledCapabilities.contains(.dictation))
    }

    func testDictationDurationDefaultsToFiveMinutesAndPersistsLongerChoices() {
        let suite = "SuperMacDictationDuration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

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

    func testClipboardKeepsTenAndCollapsesDuplicates() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let service = ClipboardHistoryService(storageURL: url)
        for number in 0..<12 { service.ingestForTesting("item \(number)") }
        XCTAssertEqual(service.entries.count, 10)
        XCTAssertEqual(service.entries.first?.text, "item 11")
        XCTAssertFalse(service.entries.contains { $0.text == "item 0" })
        service.ingestForTesting("item 11")
        XCTAssertEqual(service.entries.count, 10)
        XCTAssertEqual(ClipboardHistoryService(storageURL: url).entries.count, 10)
    }

    func testClipboardPersistsPreviewsAndRestoresCopiedImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-rich-\(UUID().uuidString)")
        let storageURL = root.appendingPathComponent("history.json")
        let mediaURL = root.appendingPathComponent("media", isDirectory: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SuperMacImageClipboard-\(UUID().uuidString)"))
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SuperMacDictationSuppression-\(UUID().uuidString)"))
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SuperMacDictationCopy-\(UUID().uuidString)"))

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

    func testCommandPaletteHasTheFourRequestedTabsWithSearchAsDefault() {
        let state = CommandPaletteState()
        XCTAssertEqual(state.tab, .search)
        XCTAssertEqual(CommandPaletteTab.allCases, [.search, .clipboard, .dictation, .keyBumps])
        XCTAssertEqual(CommandPaletteTab.allCases.map(\.shortcutLabel), ["⌘1", "⌘2", "⌘3", "⌘4"])
        XCTAssertEqual(
            CommandPaletteTab.allCases.map(\.labelPresentation),
            [
                CommandPaletteTabLabel(shortcut: "⌘1", name: "Search"),
                CommandPaletteTabLabel(shortcut: "⌘2", name: "Clipboard"),
                CommandPaletteTabLabel(shortcut: "⌘3", name: "Dictation"),
                CommandPaletteTabLabel(shortcut: "⌘4", name: "Key Bumps")
            ]
        )
        XCTAssertEqual(
            CommandPaletteTab.allCases.map { ShortcutKeycapPresentation(shortcut: $0.shortcutLabel).keys },
            [["⌘", "1"], ["⌘", "2"], ["⌘", "3"], ["⌘", "4"]]
        )
        XCTAssertEqual(CommandPaletteTab.matchingCommandKey("4"), .keyBumps)
        XCTAssertNil(CommandPaletteTab.matchingCommandKey("5"))
        XCTAssertNil(CommandPaletteTab.keyBumps.primaryActionTitle)
        XCTAssertEqual(CommandPaletteTab.clipboard.primaryActionTitle, "Copy")
        XCTAssertEqual(CommandPaletteTab.dictation.primaryActionTitle, "Copy")
        XCTAssertEqual(CommandPaletteTab.clipboard.prompt, "Search clipboard history")
        XCTAssertEqual(CommandPaletteTab.dictation.prompt, "Search dictation history")
        XCTAssertEqual(CommandPaletteTab.keyBumps.prompt, "Search Key Bumps history")
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

    func testKeyBumpsPaletteRowsIgnoreReadStateAndTime() {
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

    func testNotificationSettingsRecoveryTargetsSuperMac() {
        XCTAssertTrue(NotificationSettingsRecovery.url.absoluteString.contains("com.serp.supermac"))
    }

    func testKeyBumpsHistoryContentCentralizesEnablementAndFiltering() {
        let events = [
            CoachingEvent(applicationName: "Finder", actionTitle: "Open New Window", shortcut: "⌘N"),
            CoachingEvent(applicationName: "Safari", actionTitle: "New Tab", shortcut: "⌘T")
        ]

        XCTAssertEqual(KeyBumpsHistoryContent.resolve(events: events, query: "finder", isEnabled: true).entries.map(\.applicationName), ["Finder"])
        XCTAssertEqual(KeyBumpsHistoryContent.resolve(events: events, query: "new tab", isEnabled: true).entries.map(\.applicationName), ["Safari"])
        XCTAssertEqual(KeyBumpsHistoryContent.resolve(events: events, query: "⌘N", isEnabled: true).entries.map(\.applicationName), ["Finder"])
        XCTAssertEqual(KeyBumpsHistoryContent.resolve(events: events, query: "  ", isEnabled: true), .entries(events))
        XCTAssertEqual(KeyBumpsHistoryContent.resolve(events: events, query: "", isEnabled: false), .disabled)
        XCTAssertEqual(KeyBumpsHistoryContent.resolve(events: [], query: "", isEnabled: true), .empty)
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

    func testSelectedRectangleShortcutProfileIsExactAndUnique() {
        let assigned = SuperMacWindowAction.allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } }
        XCTAssertEqual(assigned.count, 29)
        XCTAssertEqual(SuperMacWindowAction.left.defaultShortcut?.displayName, "⌃⌥⌘←")
        XCTAssertEqual(SuperMacWindowAction.lastFourth.defaultShortcut?.keyCode, 119)
        XCTAssertNil(SuperMacWindowAction.upperRight.defaultShortcut)
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
        XCTAssertEqual(displayed.count, SuperMacWindowAction.allCases.count)
        XCTAssertEqual(Set(displayed), Set(SuperMacWindowAction.allCases))
        XCTAssertTrue(SuperMacWindowAction.allCases.allSatisfy { $0.preview != nil })
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
