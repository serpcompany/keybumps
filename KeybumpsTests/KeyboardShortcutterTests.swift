import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import XCTest
@testable import Keybumps

private final class MemoryPersistence: EventPersistence {
    var stored: [CoachingEvent]
    init(stored: [CoachingEvent] = []) { self.stored = stored }
    func load() throws -> [CoachingEvent] { stored }
    func save(_ events: [CoachingEvent]) throws { stored = events }
}

@MainActor
private final class SpyAdapter: ChannelDelivering {
    private(set) var events: [CoachingEvent] = []
    var error: Error?

    func deliver(_ event: CoachingEvent) async throws {
        if let error { throw error }
        events.append(event)
    }
}

private enum TestError: Error { case expected }

private final class StatusItemActionTarget: NSObject {
    @objc func activate(_ sender: NSStatusBarButton) {}
}

private final class StubDetectorPermissions: DetectorPermissionProviding {
    var isAccessibilityTrusted: Bool
    var isInputMonitoringAuthorized: Bool
    private(set) var accessibilityRequestCount = 0
    private(set) var inputMonitoringRequestCount = 0
    var grantsAccessibilityOnRequest = false
    var grantsInputMonitoringOnRequest = false

    init(accessibility: Bool, inputMonitoring: Bool) {
        isAccessibilityTrusted = accessibility
        isInputMonitoringAuthorized = inputMonitoring
    }

    func requestAccessibility() {
        accessibilityRequestCount += 1
        if grantsAccessibilityOnRequest { isAccessibilityTrusted = true }
    }

    func requestInputMonitoring() {
        inputMonitoringRequestCount += 1
        if grantsInputMonitoringOnRequest { isInputMonitoringAuthorized = true }
    }
}

private final class StubPointerMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    var shouldStart = true
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() -> Bool {
        startCount += 1
        return shouldStart
    }

    func stop() {
        stopCount += 1
    }

    func send(_ sample: PointerSample) {
        onSample?(sample)
    }
}

private final class StubAccessibilitySnapshotter: AccessibilitySnapshotting {
    private var snapshots: [AccessibilitySnapshot?]

    init(_ snapshots: [AccessibilitySnapshot?]) {
        self.snapshots = snapshots
    }

    func snapshot(at point: CGPoint, completion: @escaping (AccessibilitySnapshot?) -> Void) {
        completion(snapshots.isEmpty ? nil : snapshots.removeFirst())
    }
}

private final class StubChromeRuntimeReader: ChromeRuntimeStateReading {
    private var states: [ChromeRuntimeState]
    private(set) var requests: [(pid: Int32, requirement: ChromeRuntimeRequirement)] = []

    init(_ states: [ChromeRuntimeState]) {
        self.states = states
    }

    func read(pid: Int32, requirement: ChromeRuntimeRequirement) -> ChromeRuntimeState {
        requests.append((pid, requirement))
        return states.isEmpty ? .unavailable : states.removeFirst()
    }
}

@MainActor
private struct StubPresenceController: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}

@MainActor
final class KeyboardShortcutterTests: XCTestCase {
    func testPresentationPreviewDoesNotPersistSyntheticEvent() async {
        let inbox = InboxStore(persistence: MemoryPersistence())
        let adapter = SpyAdapter()
        let service = NotificationDeliveryService(inbox: inbox, adapters: [.notch: adapter])

        let outcome = await service.preview(.sample, through: .notch)

        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(adapter.events, [.sample])
        XCTAssertTrue(inbox.events.isEmpty)
    }

    func testSoundPreviewUsesTheConfiguredProductionAdapterWithoutPersistingHistory() async {
        let inbox = InboxStore(persistence: MemoryPersistence())
        var playedName: NSSound.Name?
        let adapter = SoundAdapter { name in
            playedName = name
            return true
        }
        let service = NotificationDeliveryService(inbox: inbox, adapters: [.sound: adapter])

        let outcome = await service.preview(.sample, through: .sound)

        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(playedName, NSSound.Name("Glass"))
        XCTAssertTrue(inbox.events.isEmpty)
    }

    func testPreviewPlanAddsSelectedSoundWithoutDoublePlayingDirectSoundPreview() async {
        XCTAssertEqual(
            PreviewChannelPlan.channels(for: .notch, selectedChannels: [.notch]),
            [.notch]
        )
        XCTAssertEqual(
            PreviewChannelPlan.channels(for: .notch, selectedChannels: [.notch, .sound]),
            [.notch, .sound]
        )
        XCTAssertEqual(
            PreviewChannelPlan.channels(for: .sound, selectedChannels: [.sound]),
            [.sound]
        )

        let inbox = InboxStore(persistence: MemoryPersistence())
        let notch = SpyAdapter()
        let sound = SpyAdapter()
        let service = NotificationDeliveryService(
            inbox: inbox,
            adapters: [.notch: notch, .sound: sound]
        )

        let combined = await service.preview(.sample, through: [.notch, .sound])
        XCTAssertEqual(combined, [.notch: .delivered, .sound: .delivered])
        XCTAssertEqual(notch.events.count, 1)
        XCTAssertEqual(sound.events.count, 1)
        XCTAssertTrue(inbox.events.isEmpty)

        _ = await service.preview(.sample, through: PreviewChannelPlan.channels(for: .sound, selectedChannels: [.sound]))
        XCTAssertEqual(sound.events.count, 2, "Direct Sound preview must play once, not once as both primary and companion")
    }

    func testAppModelPublishesPermissionAndStatusSnapshotsAfterRequestsAndRetry() async {
        let defaults = InMemoryDefaults()
        let permissions = StubDetectorPermissions(accessibility: false, inputMonitoring: false)
        permissions.grantsAccessibilityOnRequest = true
        permissions.grantsInputMonitoringOnRequest = true
        let detector = ManualActionDetector(monitor: StubPointerMonitor(), permissions: permissions)
        let preferences = AppPreferences(defaults: defaults)
        preferences.didCompleteOnboarding = true
        let model = AppModel(
            releaseLane: .full,
            preferences: preferences,
            inbox: InboxStore(persistence: MemoryPersistence()),
            presenceController: StubPresenceController(),
            detector: detector,
        )
        model.start()

        let accessibilityChanged = expectation(description: "Accessibility snapshot changed")
        withObservationTracking {
            _ = model.isAccessibilityTrusted
            _ = model.detectorStatus
        } onChange: {
            accessibilityChanged.fulfill()
        }
        model.requestAccessibilityPermission()
        await fulfillment(of: [accessibilityChanged], timeout: 1)
        XCTAssertTrue(model.isAccessibilityTrusted)
        XCTAssertFalse(model.isInputMonitoringAuthorized)
        XCTAssertEqual(model.detectorStatus, .permissionRequired([.inputMonitoring]))

        let inputMonitoringChanged = expectation(description: "Input Monitoring snapshot changed")
        withObservationTracking {
            _ = model.isInputMonitoringAuthorized
            _ = model.detectorStatus
        } onChange: {
            inputMonitoringChanged.fulfill()
        }
        model.requestInputMonitoringPermission()
        await fulfillment(of: [inputMonitoringChanged], timeout: 1)
        XCTAssertTrue(model.isInputMonitoringAuthorized)
        XCTAssertEqual(model.detectorStatus, .monitoring)
    }

    func testDetectorRequiresAccessibilityBeforeStartingPointerMonitor() {
        let permissions = StubDetectorPermissions(accessibility: false, inputMonitoring: true)
        let monitor = StubPointerMonitor()
        let detector = ManualActionDetector(monitor: monitor, permissions: permissions)

        detector.start()

        XCTAssertEqual(detector.status, .permissionRequired([.accessibility]))
        XCTAssertEqual(monitor.startCount, 0)
    }

    func testDetectorRequiresInputMonitoringBeforeStartingPointerMonitor() {
        let permissions = StubDetectorPermissions(accessibility: true, inputMonitoring: false)
        let monitor = StubPointerMonitor()
        let detector = ManualActionDetector(monitor: monitor, permissions: permissions)

        detector.start()

        XCTAssertEqual(detector.status, .permissionRequired([.inputMonitoring]))
        XCTAssertEqual(monitor.startCount, 0)
    }

    func testDetectorReportsMonitoringOnlyAfterBothPermissionsAndTapStartSucceed() {
        let permissions = StubDetectorPermissions(accessibility: true, inputMonitoring: true)
        let monitor = StubPointerMonitor()
        let detector = ManualActionDetector(monitor: monitor, permissions: permissions)

        detector.start()

        XCTAssertEqual(detector.status, .monitoring)
        XCTAssertEqual(monitor.startCount, 1)
    }

    func testDetectorStopsReportingMonitoringWhenPermissionBecomesStale() {
        let permissions = StubDetectorPermissions(accessibility: true, inputMonitoring: true)
        let detector = ManualActionDetector(monitor: StubPointerMonitor(), permissions: permissions)
        detector.start()

        permissions.isInputMonitoringAuthorized = false

        XCTAssertEqual(detector.status, .permissionRequired([.inputMonitoring]))
    }

    func testDetectorPermissionRequestsUseTheirSystemPermissionSeams() {
        let permissions = StubDetectorPermissions(accessibility: false, inputMonitoring: false)
        let detector = ManualActionDetector(monitor: StubPointerMonitor(), permissions: permissions)

        detector.requestAccessibilityPermission()
        detector.requestInputMonitoringPermission()

        XCTAssertEqual(permissions.accessibilityRequestCount, 1)
        XCTAssertEqual(permissions.inputMonitoringRequestCount, 1)
    }

    func testManualDetectorRetriesChromePostconditionAndDeliversTheFirstActionExactlyOnce() async {
        let preTabs = ChromeTabState(
            containerToken: "strip",
            tabs: (0..<2).map { chromeNode("tab-\($0)", role: kAXRadioButtonRole as String, selected: $0 == 0) }
        )
        let settledTabs = ChromeTabState(
            containerToken: "strip",
            tabs: (0..<3).map { chromeNode("tab-\($0)", role: kAXRadioButtonRole as String, selected: $0 == 0) }
        )
        let preSnapshot = AccessibilitySnapshot(
            pid: 123,
            bundleIdentifier: "com.google.Chrome",
            applicationVersion: "153.0.8010.48",
            applicationName: "Google Chrome",
            hit: chromeNode("new-tab", role: kAXButtonRole as String, description: "New Tab"),
            ancestors: []
        )

        await assertManualDetectorChromeJourney(
            preSnapshot: preSnapshot,
            preRuntime: chromeRuntime(tabs: preTabs),
            settledRuntime: chromeRuntime(tabs: settledTabs),
            expectedTitle: "New Tab",
            expectedShortcut: "⌘T"
        )
    }

    func testManualDetectorRetriesChromeCloseTabAndDeliversTheFirstActionExactlyOnce() async {
        let active = chromeNode("tab-1", role: kAXRadioButtonRole as String, selected: true)
        let other = chromeNode("tab-2", role: kAXRadioButtonRole as String, selected: false)
        let preTabs = ChromeTabState(containerToken: "strip", tabs: [active, other])
        let settledTabs = ChromeTabState(containerToken: "strip", tabs: [other])
        let preSnapshot = AccessibilitySnapshot(
            pid: 123,
            bundleIdentifier: "com.google.Chrome",
            applicationVersion: "153.0.8010.48",
            applicationName: "Google Chrome",
            hit: chromeNode("close", role: kAXButtonRole as String, description: "Close"),
            ancestors: [active]
        )

        await assertManualDetectorChromeJourney(
            preSnapshot: preSnapshot,
            preRuntime: chromeRuntime(tabs: preTabs),
            settledRuntime: chromeRuntime(tabs: settledTabs),
            expectedTitle: "Close Tab",
            expectedShortcut: "⌘W"
        )
    }

    func testDeliveryRecordsOnceAndFansOutToSelectedChannels() async {
        let persistence = MemoryPersistence()
        let inbox = InboxStore(persistence: persistence)
        let notch = SpyAdapter()
        let sound = SpyAdapter()
        let service = NotificationDeliveryService(inbox: inbox, adapters: [
            .notch: notch,
            .sound: sound
        ])
        let event = CoachingEvent.sample

        let report = await service.deliver(event, through: [.notch, .sound])

        XCTAssertTrue(report.inboxRecorded)
        XCTAssertEqual(inbox.events, [event])
        XCTAssertEqual(persistence.stored, [event])
        XCTAssertEqual(notch.events, [event])
        XCTAssertEqual(sound.events, [event])
        XCTAssertEqual(report.outcomes[.notch], .delivered)
        XCTAssertEqual(report.outcomes[.sound], .delivered)
    }

    func testDeliveryReportsOneAdapterFailureWithoutDroppingHistory() async {
        let inbox = InboxStore(persistence: MemoryPersistence())
        let failing = SpyAdapter()
        failing.error = TestError.expected
        let service = NotificationDeliveryService(inbox: inbox, adapters: [.sound: failing])

        let report = await service.deliver(.sample, through: [.sound])

        XCTAssertTrue(report.inboxRecorded)
        XCTAssertEqual(inbox.events.count, 1)
        guard case .failed = report.outcomes[.sound] else {
            return XCTFail("Expected a per-channel failure")
        }
    }

    func testPermissionRecoveryRechecksAlreadyGrantedAccessBeforeOpeningSystemSettings() async {
        var accessibilityTrusted = false
        var openedSettings: [MacPermission] = []
        let permissions = PermissionCoordinator(
            accessibilityTrusted: { accessibilityTrusted },
            openSettings: { openedSettings.append($0) }
        )
        let defaults = InMemoryDefaults()
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            inbox: InboxStore(persistence: MemoryPersistence()),
            presenceController: StubPresenceController(),
            detector: ManualActionDetector(monitor: StubPointerMonitor()),
            permissionCoordinator: permissions
        )
        XCTAssertEqual(permissions.accessibilityState, .required)

        accessibilityTrusted = true
        await model.recoverPermission(.accessibility)

        XCTAssertEqual(permissions.accessibilityState, .granted)
        XCTAssertTrue(openedSettings.isEmpty)
    }

    func testVisiblePermissionMonitoringRecognizesAccessGrantedWhileSystemSettingsIsForeground() async {
        var accessibilityTrusted = false
        let permissions = PermissionCoordinator(accessibilityTrusted: { accessibilityTrusted })
        let defaults = InMemoryDefaults()
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            inbox: InboxStore(persistence: MemoryPersistence()),
            presenceController: StubPresenceController(),
            detector: ManualActionDetector(monitor: StubPointerMonitor()),
            permissionCoordinator: permissions
        )
        XCTAssertEqual(permissions.accessibilityState, .required)

        accessibilityTrusted = true
        await model.monitorSystemPermissionChanges(interval: .zero, maximumRefreshes: 1)

        XCTAssertEqual(permissions.accessibilityState, .granted)
        XCTAssertTrue(model.permissionReadiness.state(for: .accessibility).isGranted)
    }

    func testPermissionRelaunchAlertBindingDismissesThePresentedPermission() {
        let defaults = InMemoryDefaults()
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            inbox: InboxStore(persistence: MemoryPersistence()),
            presenceController: StubPresenceController(),
            detector: ManualActionDetector(monitor: StubPointerMonitor())
        )

        model.relaunchPromptPermission = .accessibility
        XCTAssertTrue(model.isPermissionRelaunchPromptPresented)

        model.isPermissionRelaunchPromptPresented = false

        XCTAssertNil(model.relaunchPromptPermission)
        XCTAssertFalse(model.isPermissionRelaunchPromptPresented)
    }

    func testSoundInvokesGlassAndReportsUnavailablePlayback() async throws {
        var playedName: NSSound.Name?
        let successful = SoundAdapter(playSound: {
            playedName = $0
            return true
        })
        try await successful.deliver(.sample)
        XCTAssertEqual(playedName, NSSound.Name("Glass"))

        let unavailable = SoundAdapter(playSound: { _ in false })
        do {
            try await unavailable.deliver(.sample)
            XCTFail("Expected unavailable sound to fail")
        } catch {
            XCTAssertEqual(error as? DeliveryAdapterError, .soundUnavailable)
        }
    }

    func testInboxUnreadAndPersistenceLifecycle() throws {
        let persistence = MemoryPersistence()
        let inbox = InboxStore(persistence: persistence)
        let first = CoachingEvent(applicationName: "Finder", actionTitle: "New Window", shortcut: "⌘N")
        let second = CoachingEvent(applicationName: "Safari", actionTitle: "New Tab", shortcut: "⌘T")

        try inbox.append(first)
        try inbox.append(second)
        XCTAssertEqual(inbox.unreadCount, 2)

        inbox.markRead(first.id)
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertEqual(InboxStore(persistence: persistence).events.count, 2)

        inbox.markAllRead()
        XCTAssertEqual(inbox.unreadCount, 0)

        inbox.clear()
        XCTAssertTrue(persistence.stored.isEmpty)
    }

    func testPreferencesDefaultToVisiblePresenceAndPersistChannelCombinations() {
        let defaults = InMemoryDefaults()

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showInDockAndSwitcher)
        XCTAssertEqual(preferences.selectedChannels, [.notch])
        XCTAssertEqual(NotificationChannel.allCases.first, .notch, "Notch leads the Settings list")

        preferences.set(.sound, enabled: true)
        preferences.set(.notch, enabled: false)
        preferences.showInDockAndSwitcher = false

        let restored = AppPreferences(defaults: defaults)
        XCTAssertFalse(restored.showInDockAndSwitcher)
        XCTAssertEqual(restored.selectedChannels, [.sound])
    }

    func testLegacyCursorHaloSelectionIsRemovedAndRewritten() {
        let defaults = InMemoryDefaults()
        defaults.set(["cursorHalo", NotificationChannel.sound.rawValue], forKey: "selectedNotificationChannels")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedChannels, [.sound])
        XCTAssertEqual(defaults.stringArray(forKey: "selectedNotificationChannels"), ["sound"])
        XCTAssertFalse(NotificationChannel.allCases.map(\.rawValue).contains("cursorHalo"))
    }

    func testRemovedPresentationChannelsAreMigratedOutOfPersistedPreferences() {
        let defaults = InMemoryDefaults()
        defaults.set([
            "statusFeedback",
            "decisionBanner",
            "dockBadge",
            "dockBounce",
            "cursorHalo",
            "pointerCard",
            NotificationChannel.sound.rawValue
        ], forKey: "selectedNotificationChannels")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedChannels, [.sound])
        XCTAssertEqual(defaults.array(forKey: "selectedNotificationChannels") as? [String], ["sound"])
    }

    func testRetiredVisualChannelsMoveToTheNotch() {
        for retired in ["nativeBanner", "topRightToast", "topCenterShelf"] {
            let cases: [(saved: [String], expected: Set<NotificationChannel>, persisted: [String])] = [
                ([retired], [.notch], ["notch"]),
                ([retired, "sound"], [.notch, .sound], ["notch", "sound"]),
                (["notch", retired], [.notch], ["notch"])
            ]
            for (saved, expected, persisted) in cases {
                let defaults = InMemoryDefaults()
                defaults.set(saved, forKey: "selectedNotificationChannels")

                let preferences = AppPreferences(defaults: defaults)

                XCTAssertEqual(preferences.selectedChannels, expected, "\(saved)")
                XCTAssertEqual(defaults.array(forKey: "selectedNotificationChannels") as? [String], persisted, "\(saved)")
            }
        }
        XCTAssertEqual(NotificationChannel.allCases, [.notch, .sound])
    }

    func testPreferencesMigrateFromEitherPreviousBundleIdentity() {
        for sourceIndex in 0..<2 {
            let current = InMemoryDefaults()
            let oldest = InMemoryDefaults()
            let recent = InMemoryDefaults()
            let source = [recent, oldest][sourceIndex]
            source.set([NotificationChannel.sound.rawValue], forKey: "selectedNotificationChannels")
            source.set(false, forKey: "showInDockAndSwitcher")

            let migrated = AppPreferences(defaults: current, legacyDefaults: [recent, oldest])

            XCTAssertEqual(migrated.selectedChannels, [.sound])
            XCTAssertFalse(migrated.showInDockAndSwitcher)
            XCTAssertEqual(current.array(forKey: "selectedNotificationChannels") as? [String], ["sound"])
            XCTAssertEqual(current.bool(forKey: "showInDockAndSwitcher"), false)
        }
    }

    func testKeybumpsBrandingConfiguresTheActualStatusBarButtonContract() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let target = StatusItemActionTarget()

        StatusItemBranding.configure(
            button,
            target: target,
            action: #selector(StatusItemActionTarget.activate(_:))
        )

        XCTAssertEqual(ProductIdentity.statusItemImageName, "KeybumpsMascot")
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.image?.isTemplate, true)
        XCTAssertEqual(button.image?.size, NSSize(width: 22, height: 14), "the wide mascot keeps its shape")
        // NSStatusBarButton normalizes .imageOnly to .imageOverlaps. The empty
        // title is the observable contract that leaves only the image visible.
        XCTAssertEqual(button.imagePosition, .imageOverlaps)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.toolTip, "Keybumps")
        XCTAssertEqual(button.accessibilityLabel(), "Keybumps")
        XCTAssertTrue(button.target === target)
        XCTAssertEqual(button.action, #selector(StatusItemActionTarget.activate(_:)))
    }

    func testReleaseLanesHaveSeparateIdentitiesAndCapabilities() {
        XCTAssertEqual(ReleaseLane.full.productName, "Keybumps")
        XCTAssertEqual(ReleaseLane.full.bundleIdentifier, "com.serp.keybumps")
        XCTAssertTrue(ReleaseLane.full.supportsManualActionDetection)
        XCTAssertFalse(ReleaseLane.full.showsFullVersionCTA)
    }

    func testLiteShortcutCatalogIsUsefulAndSearchable() {
        XCTAssertGreaterThanOrEqual(ShortcutCatalog.tips.count, 12)
        XCTAssertTrue(ShortcutCatalog.applications.contains("Finder"))
        XCTAssertTrue(ShortcutCatalog.applications.contains("Google Chrome"))
        XCTAssertEqual(
            ShortcutCatalog.matching(searchText: "trash", application: "Finder").map(\.shortcut),
            ["⌘Delete"]
        )
        XCTAssertTrue(
            ShortcutCatalog.matching(searchText: "copy", application: "Safari")
                .contains(where: { $0.applicationName == "General" })
        )
    }

    func testEveryPresentationChannelHasStableCopyAndIdentity() {
        XCTAssertEqual(Set(NotificationChannel.allCases.map(\.id)).count, NotificationChannel.allCases.count)
        for channel in NotificationChannel.allCases {
            XCTAssertFalse(channel.title.isEmpty)
        }
    }

    func testCanonicalShortcutRegistryResolvesReportedVSCodeFailures() {
        let fixtures: [(String, AXShortcutEvidence, String)] = [
            (
                "Move Line Down",
                AXShortcutEvidence(commandCharacter: "\u{F701}", modifiers: 2 | 8, commandGlyph: 0x6A, virtualKey: 0x7D),
                "⌥↓"
            ),
            (
                "Select Previous Tab",
                AXShortcutEvidence(commandCharacter: "\t", modifiers: 1 | 4 | 8, commandGlyph: 0x02, virtualKey: 0x30),
                "⌃⇧⇥"
            ),
            (
                "Emmet: Expand Abbreviation",
                AXShortcutEvidence(commandCharacter: "\t", modifiers: 8, commandGlyph: 0x02, virtualKey: 0x30),
                "⇥"
            )
        ]

        for (action, evidence, expected) in fixtures {
            XCTAssertEqual(
                KeyboardShortcutRegistry.resolve(evidence)?.displayString,
                expected,
                action
            )
        }
    }

    func testCanonicalShortcutRegistryUppercasesMenuLettersWithoutInventingShift() {
        let shortcut = KeyboardShortcutRegistry.resolve(
            AXShortcutEvidence(commandCharacter: "a", modifiers: 0, commandGlyph: nil, virtualKey: nil)
        )

        XCTAssertEqual(shortcut?.displayString, "⌘A")
        XCTAssertEqual(shortcut?.keycapTokens, ["⌘", "A"])
        XCTAssertEqual(shortcut?.accessibilityDescription, "Command A")
    }

    func testCanonicalShortcutRegistrySuppressesUnknownAndIncompleteEvidence() {
        XCTAssertNil(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(commandCharacter: "\u{F7FF}", modifiers: 0, commandGlyph: 0xFFFF, virtualKey: 0xFFFF)
            )
        )
        XCTAssertNil(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(commandCharacter: nil, modifiers: 0, commandGlyph: nil, virtualKey: nil)
            )
        )
        XCTAssertNil(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(commandCharacter: "a", modifiers: nil, commandGlyph: nil, virtualKey: nil)
            )
        )
    }

    func testCanonicalShortcutRegistryRecoversFromUnknownCharacterUsingKnownPhysicalEvidence() {
        XCTAssertEqual(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(
                    commandCharacter: "\u{F7FF}",
                    modifiers: 2 | 8,
                    commandGlyph: 0x6A,
                    virtualKey: 0x7D
                )
            )?.displayString,
            "⌥↓"
        )
        XCTAssertEqual(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(
                    commandCharacter: "\u{F7FF}",
                    modifiers: 8,
                    commandGlyph: 0xFFFF,
                    virtualKey: 0x30
                )
            )?.displayString,
            "⇥"
        )
        XCTAssertNil(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(
                    commandCharacter: "\u{F701}",
                    modifiers: 8,
                    commandGlyph: 0x68,
                    virtualKey: 0x7D
                )
            )
        )
    }

    func testKeyboardGlyphLegendIsGeneratedFromRuntimeRegistry() throws {
        let downArrow = try XCTUnwrap(
            KeyboardShortcutRegistry.legendEntries.first(where: { $0.semanticKey == .downArrow })
        )
        let resolved = try XCTUnwrap(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(commandCharacter: "\u{F701}", modifiers: 8, commandGlyph: 0x6A, virtualKey: 0x7D)
            )
        )

        XCTAssertEqual(downArrow.symbol, resolved.primaryKey.renderedSymbol)
        XCTAssertEqual(downArrow.name, "Down Arrow")
        XCTAssertTrue(KeyboardShortcutRegistry.legendEntries.contains { $0.name == "Tab Right" && $0.symbol == "⇥" })
        XCTAssertTrue(KeyboardShortcutRegistry.legendEntries.contains { $0.name == "Escape (Esc)" && $0.symbol == "⎋" })
        XCTAssertEqual(
            Set(KeyboardShortcutRegistry.legendEntries.map(\.semanticKey)).count,
            KeyboardShortcutRegistry.legendEntries.count
        )
    }

    func testVisibleKeyboardGuideIsCuratedFromAppleMenuSymbols() {
        let expected: [KeyboardSemanticKey] = [
            .functionModifier, .control, .option, .shift, .command,
            .returnKey, .delete, .forwardDelete,
            .upArrow, .downArrow, .leftArrow, .rightArrow,
            .pageUp, .pageDown, .home, .end, .tabRight, .tabLeft, .escape
        ]

        XCTAssertEqual(KeyboardShortcutRegistry.legendEntries.map(\.semanticKey), expected)
        XCTAssertTrue(KeyboardShortcutRegistry.legendEntries.allSatisfy {
            $0.sourceURL.absoluteString == "https://support.apple.com/guide/mac-help/cpmh0011/mac"
        })
        XCTAssertFalse(KeyboardShortcutRegistry.legendEntries.contains { entry in
            switch entry.semanticKey {
            case .space, .enter, .help, .clear, .function: true
            default: false
            }
        })
    }

    func testEveryVisibleGuideKeyUsesTheSameCanonicalValueAcrossConsumers() async throws {
        let modifierKeys: Set<KeyboardSemanticKey> = [
            .functionModifier, .control, .option, .shift, .command
        ]
        let persistence = MemoryPersistence()
        let inbox = InboxStore(persistence: persistence)

        for entry in KeyboardShortcutRegistry.legendEntries {
            let displayShortcut = modifierKeys.contains(entry.semanticKey)
                ? "\(entry.symbol)A"
                : "⌘\(entry.symbol)"
            let canonical = try XCTUnwrap(KeyboardShortcutRegistry.resolve(displayString: displayShortcut))
            let event = CoachingEvent(
                applicationName: "Fixture",
                actionTitle: entry.name,
                shortcut: canonical.displayString
            )
            try inbox.append(event)

            XCTAssertTrue(canonical.keycapTokens.contains(entry.symbol), entry.name)
            XCTAssertEqual(CoachingEventRowPresentation(event: event).shortcut, canonical.displayString, entry.name)
            XCTAssertEqual(ShortcutKeycapPresentation(shortcut: event.shortcut).keys, canonical.keycapTokens, entry.name)
            XCTAssertTrue(KeyboardShortcutRegistry.accessibilityCopy(for: event.shortcut).contains(entry.name), entry.name)
            XCTAssertEqual(NotchCoachPresentation(event: event).keys, canonical.keycapTokens, entry.name)
            XCTAssertEqual(inbox.events.first?.shortcut, canonical.displayString, entry.name)
        }

        XCTAssertEqual(persistence.stored.count, KeyboardShortcutRegistry.legendEntries.count)
    }

    func testVSCodeWindowFillAndCenterChildHitsResolveThroughProductionMenuEventSeam() throws {
        let fixtures: [(title: String, character: String, expected: String)] = [
            ("Fill", "F", "🌐︎⌃F"),
            ("Center", "C", "🌐︎⌃C")
        ]

        for fixture in fixtures {
            let menuItem = AXNodeSnapshot(
                token: "menu-\(fixture.title)", role: kAXMenuItemRole as String,
                subrole: nil, title: fixture.title, elementDescription: nil, identifier: nil,
                value: nil, selected: nil, enabled: true, actions: [kAXPressAction as String], frame: nil,
                menuShortcut: nil,
                menuShortcutEvidence: AXShortcutEvidence(
                    commandCharacter: fixture.character,
                    modifiers: 16 | 8 | 4,
                    commandGlyph: nil,
                    virtualKey: nil
                )
            )
            let child = AXNodeSnapshot(
                token: "child-\(fixture.title)", role: kAXStaticTextRole as String,
                subrole: nil, title: fixture.title, elementDescription: nil, identifier: nil,
                value: nil, selected: nil, enabled: true, actions: [], frame: nil,
                menuShortcut: nil
            )
            let snapshot = AccessibilitySnapshot(
                pid: 123,
                bundleIdentifier: "com.microsoft.VSCode",
                applicationVersion: "1.138.0",
                applicationName: "Visual Studio Code",
                hit: child,
                ancestors: [menuItem]
            )

            let event = try XCTUnwrap(MenuActionEventResolver.makeEvent(from: snapshot))
            XCTAssertEqual(event.actionTitle, fixture.title)
            XCTAssertEqual(event.shortcut, fixture.expected)
            XCTAssertEqual(event.rawShortcutEvidence, menuItem.menuShortcutEvidence)
            XCTAssertEqual(event.shortcutProvenance, .liveAX)
            XCTAssertEqual(CoachingEventRowPresentation(event: event).shortcut, fixture.expected)
            XCTAssertEqual(ShortcutKeycapPresentation(shortcut: event.shortcut).keys, ["🌐︎", "⌃", fixture.character])
            XCTAssertEqual(
                KeyboardShortcutRegistry.accessibilityCopy(for: event.shortcut),
                "Shortcut Fn (Function) or Globe Control \(fixture.character)"
            )
        }
    }

    func testMenuEventResolverSuppressesAmbiguousAndIncompleteEvidence() {
        func menu(_ token: String, title: String, evidence: AXShortcutEvidence?) -> AXNodeSnapshot {
            AXNodeSnapshot(
                token: token, role: kAXMenuItemRole as String, subrole: nil, title: title,
                elementDescription: nil, identifier: nil, value: nil, selected: nil, enabled: true,
                actions: [kAXPressAction as String], frame: nil, menuShortcut: nil,
                menuShortcutEvidence: evidence
            )
        }
        let valid = AXShortcutEvidence(commandCharacter: "F", modifiers: 28, commandGlyph: nil, virtualKey: nil)
        let child = AXNodeSnapshot(
            token: "child", role: kAXStaticTextRole as String, subrole: nil, title: "Fill",
            elementDescription: nil, identifier: nil, value: nil, selected: nil, enabled: true,
            actions: [], frame: nil, menuShortcut: nil
        )
        let ambiguous = AccessibilitySnapshot(
            pid: 1, bundleIdentifier: "com.microsoft.VSCode", applicationName: "Visual Studio Code",
            hit: child, ancestors: [menu("one", title: "Fill", evidence: valid), menu("two", title: "Fill", evidence: valid)]
        )
        let incomplete = AccessibilitySnapshot(
            pid: 1, bundleIdentifier: "com.microsoft.VSCode", applicationName: "Visual Studio Code",
            hit: child, ancestors: [menu("one", title: "Fill", evidence: nil)]
        )

        XCTAssertNil(MenuActionEventResolver.makeEvent(from: ambiguous))
        XCTAssertNil(MenuActionEventResolver.makeEvent(from: incomplete))
    }

    func testEveryDeclaredSpecialKeyInputResolvesThroughTheRealRegistry() {
        typealias Expected = (
            key: KeyboardSemanticKey,
            characters: [String],
            glyphs: [Int],
            virtualKeys: [Int]
        )
        let fixed: [Expected] = [
            (.returnKey, ["\r", "\n"], [0x0B, 0x0C, 0x0D], [0x24]),
            (.enter, [], [0x04], [0x4C]),
            (.tabRight, ["\t"], [0x02], [0x30]),
            (.tabLeft, ["\u{19}"], [0x03], []),
            (.escape, ["\u{1B}"], [0x1B], [0x35]),
            (.space, [" "], [0x09], [0x31]),
            (.delete, ["\u{08}", "\u{7F}"], [0x17], [0x33]),
            (.forwardDelete, ["\u{F728}"], [0x0A], [0x75]),
            (.upArrow, ["\u{F700}"], [0x68], [0x7E]),
            (.downArrow, ["\u{F701}"], [0x6A], [0x7D]),
            (.leftArrow, ["\u{F702}"], [0x64], [0x7B]),
            (.rightArrow, ["\u{F703}"], [0x65], [0x7C]),
            (.pageUp, ["\u{F72C}"], [0x62], [0x74]),
            (.pageDown, ["\u{F72D}"], [0x6B], [0x79]),
            (.home, ["\u{F729}"], [], [0x73]),
            (.end, ["\u{F72B}"], [], [0x77]),
            (.help, ["\u{F746}"], [0x67], [0x72]),
            (.clear, ["\u{F739}"], [0x1C], [0x47])
        ]
        let functionGlyphs = Array(0x6F...0x7A) + Array(0x87...0x89) + Array(0x8F...0x92)
        let functionVirtualKeys = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A
        ]
        let functions: [Expected] = (1...20).map { number in
            (
                .function(number),
                [String(UnicodeScalar(0xF703 + number)!)],
                number <= functionGlyphs.count ? [functionGlyphs[number - 1]] : [],
                [functionVirtualKeys[number - 1]]
            )
        }

        for expected in fixed + functions {
            for character in expected.characters {
                assertRegistry(
                    resolves: AXShortcutEvidence(commandCharacter: character, modifiers: 8, commandGlyph: nil, virtualKey: nil),
                    to: expected.key
                )
            }
            for glyph in expected.glyphs {
                assertRegistry(
                    resolves: AXShortcutEvidence(commandCharacter: nil, modifiers: 8, commandGlyph: glyph, virtualKey: nil),
                    to: expected.key
                )
            }
            for virtualKey in expected.virtualKeys {
                assertRegistry(
                    resolves: AXShortcutEvidence(commandCharacter: nil, modifiers: 8, commandGlyph: nil, virtualKey: virtualKey),
                    to: expected.key
                )
            }
        }
    }

    func testAccessibilityModifierMaskUsesOneCanonicalOrderAndNoCommandSemantics() {
        XCTAssertEqual(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(commandCharacter: "k", modifiers: 0, commandGlyph: nil, virtualKey: nil)
            )?.displayString,
            "⌘K"
        )
        XCTAssertEqual(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(commandCharacter: "k", modifiers: 1 | 2 | 4, commandGlyph: nil, virtualKey: nil)
            )?.displayString,
            "⌃⌥⇧⌘K"
        )
        XCTAssertEqual(
            KeyboardShortcutRegistry.resolve(
                AXShortcutEvidence(commandCharacter: "k", modifiers: 1 | 2 | 4 | 8, commandGlyph: nil, virtualKey: nil)
            )?.displayString,
            "⌃⌥⇧K"
        )
    }

    func testCanonicalRegistryUppercasesLettersAndPreservesDigitsAndPunctuation() {
        for (input, expected) in [("z", "⌘Z"), ("7", "⌘7"), ("/", "⌘/"), ("[", "⌘["), ("?", "⌘?")] {
            XCTAssertEqual(
                KeyboardShortcutRegistry.resolve(
                    AXShortcutEvidence(commandCharacter: input, modifiers: 0, commandGlyph: nil, virtualKey: nil)
                )?.displayString,
                expected
            )
        }
    }

    @MainActor
    func testRawAXTupleFlowsThroughProductionEventAndEveryConsumer() async throws {
        let rawAttributes: [String: Any] = [
            kAXMenuItemCmdCharAttribute: "\u{F701}",
            kAXMenuItemCmdModifiersAttribute: NSNumber(value: 2 | 8),
            kAXMenuItemCmdGlyphAttribute: NSNumber(value: 0x6A),
            kAXMenuItemCmdVirtualKeyAttribute: NSNumber(value: 0x7D)
        ]
        let evidence = AXShortcutEvidenceReader.read { rawAttributes[$0] }
        let event = try XCTUnwrap(
            CoachingEventFactory.make(
                applicationName: "Visual Studio Code",
                actionTitle: "Move Line Down",
                shortcutEvidence: evidence
            )
        )
        XCTAssertEqual(event.shortcutProvenance, .liveAX)
        XCTAssertEqual(event.rawShortcutEvidence, evidence)

        let encoded = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(CoachingEvent.self, from: encoded), event)
        let persistence = MemoryPersistence()
        let inbox = InboxStore(persistence: persistence)
        try inbox.append(event)
        XCTAssertEqual(persistence.stored, [event])

        XCTAssertEqual(CoachingEventRowPresentation(event: inbox.events[0]).shortcut, "⌥↓")
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: event.shortcut).keys, ["⌥", "↓"])
        XCTAssertEqual(
            KeyboardShortcutRegistry.accessibilityCopy(for: event.shortcut),
            "Shortcut Option Down Arrow"
        )
        XCTAssertEqual(NotchCoachPresentation(event: event).keys, ["⌥", "↓"])
        XCTAssertEqual(
            KeyboardShortcutRegistry.legendEntries.first(where: { $0.semanticKey == .downArrow })?.symbol,
            "↓"
        )
    }

    func testLegacyCoachingEventDecodesWithoutShortcutMetadata() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "occurredAt": 0,
          "applicationName": "Finder",
          "actionTitle": "Open New Window",
          "shortcut": "⌘N",
          "isRead": false
        }
        """

        let event = try JSONDecoder().decode(CoachingEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.id, id)
        XCTAssertEqual(event.shortcut, "⌘N")
        XCTAssertNil(event.rawShortcutEvidence)
        XCTAssertEqual(event.shortcutProvenance, .legacyUnknown)
        XCTAssertEqual(event.canonicalShortcut?.displayString, "⌘N")
    }

    func testSavedEventWithRetiredPointerCoordinatesStillLoadsAndDropsThemOnSave() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "occurredAt": 0,
          "applicationName": "Finder",
          "actionTitle": "Open New Window",
          "shortcut": "⌘N",
          "pointerX": 120.5,
          "pointerY": 640,
          "isRead": true
        }
        """

        let event = try JSONDecoder().decode(CoachingEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.actionTitle, "Open New Window")
        XCTAssertTrue(event.isRead)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertNil(saved["pointerX"])
        XCTAssertNil(saved["pointerY"])
    }

    func testCharacterizedChromeShortcutsMustPassRegistryValidation() {
        let supported = [
            ChromeShortcutCatalog.newTab,
            ChromeShortcutCatalog.closeTab
        ] + (1...9).map(ChromeShortcutCatalog.selectTab(index:))
        XCTAssertTrue(supported.allSatisfy { KeyboardShortcutRegistry.resolve(displayString: $0) != nil })
        XCTAssertNil(
            CoachingEventFactory.makeCharacterized(
                applicationName: "Google Chrome",
                actionTitle: "Unsupported",
                displayShortcut: "⌘Not a key",
                adapterID: ChromeShortcutCatalog.adapterID,
                compatibleApplicationVersion: ChromeShortcutCatalog.characterizedChromeVersion
            )
        )
    }

    func testShortcutKeycapsUseCanonicalRegistryCapitalization() {
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: "⌘N").keys, ["⌘", "N"])
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: "⇧⌘N").keys, ["⇧", "⌘", "N"])
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: "⌃⇧⇥").keys, ["⌃", "⇧", "⇥"])
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: "🌐︎⌃F").keys, ["🌐︎", "⌃", "F"])

        let regular = ShortcutKeycapMetrics.value(compact: false)
        XCTAssertEqual(regular.height, 28)
        XCTAssertEqual(regular.minimumWidth, 28)
        XCTAssertEqual(regular.horizontalPadding, 7)
        XCTAssertEqual(regular, ShortcutKeycapMetrics.value(compact: false), "Every token length uses one layout contract")
    }

    private func chromeNode(
        _ token: String,
        role: String,
        description: String? = nil,
        selected: Bool? = nil
    ) -> AXNodeSnapshot {
        AXNodeSnapshot(
            token: token, role: role, subrole: nil, title: nil,
            elementDescription: description, identifier: nil,
            value: selected.map { $0 ? "1" : "0" }, selected: selected,
            enabled: true, actions: role == kAXButtonRole as String ? [kAXPressAction as String] : [],
            frame: AXFrameSnapshot(x: 0, y: 0, width: 30, height: 30), menuShortcut: nil
        )
    }

    private func chromeRuntime(tabs: ChromeTabState) -> ChromeRuntimeState {
        func live(_ character: String) -> LiveShortcutResolution {
            .resolved(
                LiveShortcutObservation(
                    evidence: AXShortcutEvidence(
                        commandCharacter: character,
                        modifiers: 0,
                        commandGlyph: nil,
                        virtualKey: nil
                    )
                )!
            )
        }
        return ChromeRuntimeState(
            tabs: tabs,
            tabShortcuts: ChromeTabShortcutState(
                newTab: live("T"), closeTab: live("W"), directSelection: [:]
            ),
            settingsShortcut: .unavailable,
            destination: .unavailable,
            applicationVersion: "153.0.8010.48"
        )
    }

    private func assertManualDetectorChromeJourney(
        preSnapshot: AccessibilitySnapshot,
        preRuntime: ChromeRuntimeState,
        settledRuntime: ChromeRuntimeState,
        expectedTitle: String,
        expectedShortcut: String
    ) async {
        let monitor = StubPointerMonitor()
        let runtimeReader = StubChromeRuntimeReader([preRuntime, preRuntime, settledRuntime])
        let detector = ManualActionDetector(
            monitor: monitor,
            snapshotter: StubAccessibilitySnapshotter([preSnapshot, preSnapshot]),
            permissions: StubDetectorPermissions(accessibility: true, inputMonitoring: true),
            chromeRuntimeReader: runtimeReader
        )
        let persistence = MemoryPersistence()
        let inbox = InboxStore(persistence: persistence)
        let adapter = SpyAdapter()
        let delivery = NotificationDeliveryService(inbox: inbox, adapters: [.notch: adapter])
        let delivered = expectation(description: "first Chrome action delivered")
        detector.onEvent = { event in
            Task { @MainActor in
                _ = await delivery.deliver(event, through: [.notch])
                delivered.fulfill()
            }
        }
        detector.start()
        monitor.send(PointerSample(phase: .down, location: CGPoint(x: 5, y: 5), modifiers: [], timestamp: 1))
        monitor.send(PointerSample(phase: .up, location: CGPoint(x: 5, y: 5), modifiers: [], timestamp: 1.1))

        await fulfillment(of: [delivered], timeout: 1)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(inbox.events.map(\.actionTitle), [expectedTitle])
        XCTAssertEqual(inbox.events.map(\.shortcut), [expectedShortcut])
        XCTAssertEqual(persistence.stored.count, 1)
        XCTAssertEqual(adapter.events.count, 1)
        XCTAssertEqual(runtimeReader.requests.map(\.requirement), [.tabs, .tabs, .tabs])
        detector.stop()
    }

    private func assertRegistry(
        resolves evidence: AXShortcutEvidence,
        to expected: KeyboardSemanticKey,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            KeyboardShortcutRegistry.resolve(evidence)?.primaryKey.semanticKey,
            expected,
            file: file,
            line: line
        )
    }
}
