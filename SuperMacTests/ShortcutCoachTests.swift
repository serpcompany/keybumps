import AppKit
import Carbon.HIToolbox
import Observation
import XCTest
@testable import SuperMac

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

@MainActor
private final class StubNativeNotificationCenter: NativeNotificationCenterClient {
    var status: NativeNotificationAuthorization
    var requestedStatus: NativeNotificationAuthorization?
    var requestResult = true
    private(set) var requestCount = 0
    var addError: Error?
    private(set) var added: [(identifier: String, payload: NativeNotificationPayload)] = []

    init(status: NativeNotificationAuthorization) {
        self.status = status
    }

    func authorizationStatus() async -> NativeNotificationAuthorization {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if let requestedStatus { status = requestedStatus }
        return requestResult
    }

    func add(identifier: String, payload: NativeNotificationPayload) async throws {
        if let addError { throw addError }
        added.append((identifier, payload))
    }
}

@MainActor
private final class StubKeyboardEventMonitor: KeyboardEventMonitoring {
    private var handler: (() -> Bool)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startDismissalHandler(_ handler: @escaping () -> Bool) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func sendDismissalCommand() -> Bool {
        handler?() ?? false
    }
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
}

@MainActor
private struct StubPresenceController: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}

@MainActor
final class ShortcutCoachTests: XCTestCase {
    func testPresentationPreviewDoesNotPersistSyntheticEvent() async {
        let inbox = InboxStore(persistence: MemoryPersistence())
        let adapter = SpyAdapter()
        let service = NotificationDeliveryService(inbox: inbox, adapters: [.topRightToast: adapter])

        let outcome = await service.preview(.sample, through: .topRightToast)

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
            PreviewChannelPlan.channels(for: .topRightToast, selectedChannels: [.topRightToast]),
            [.topRightToast]
        )
        XCTAssertEqual(
            PreviewChannelPlan.channels(for: .topRightToast, selectedChannels: [.topRightToast, .sound]),
            [.topRightToast, .sound]
        )
        XCTAssertEqual(
            PreviewChannelPlan.channels(for: .sound, selectedChannels: [.sound]),
            [.sound]
        )

        let inbox = InboxStore(persistence: MemoryPersistence())
        let toast = SpyAdapter()
        let sound = SpyAdapter()
        let service = NotificationDeliveryService(
            inbox: inbox,
            adapters: [.topRightToast: toast, .sound: sound]
        )

        let combined = await service.preview(.sample, through: [.topRightToast, .sound])
        XCTAssertEqual(combined, [.topRightToast: .delivered, .sound: .delivered])
        XCTAssertEqual(toast.events.count, 1)
        XCTAssertEqual(sound.events.count, 1)
        XCTAssertTrue(inbox.events.isEmpty)

        _ = await service.preview(.sample, through: PreviewChannelPlan.channels(for: .sound, selectedChannels: [.sound]))
        XCTAssertEqual(sound.events.count, 2, "Direct Sound preview must play once, not once as both primary and companion")
    }

    func testAppModelPublishesPermissionAndStatusSnapshotsAfterRequestsAndRetry() async {
        let suite = "ShortcutCoachTests-permissions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
            presenter: PresentationWindowController()
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

    func testDeliveryRecordsOnceAndFansOutToSelectedChannels() async {
        let persistence = MemoryPersistence()
        let inbox = InboxStore(persistence: persistence)
        let toast = SpyAdapter()
        let sound = SpyAdapter()
        let service = NotificationDeliveryService(inbox: inbox, adapters: [
            .topRightToast: toast,
            .sound: sound
        ])
        let event = CoachingEvent.sample

        let report = await service.deliver(event, through: [.topRightToast, .sound])

        XCTAssertTrue(report.inboxRecorded)
        XCTAssertEqual(inbox.events, [event])
        XCTAssertEqual(persistence.stored, [event])
        XCTAssertEqual(toast.events, [event])
        XCTAssertEqual(sound.events, [event])
        XCTAssertEqual(report.outcomes[.topRightToast], .delivered)
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

    func testNativeNotificationDeliversExactEventCopyWithFreshIdentifierWhenAuthorized() async throws {
        let center = StubNativeNotificationCenter(status: .authorized)
        let adapter = NativeNotificationAdapter(center: center, identifierFactory: { "fresh-preview" })
        let event = CoachingEvent.sample

        try await adapter.deliver(event)

        XCTAssertEqual(center.requestCount, 0)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added.first?.identifier, "fresh-preview")
        XCTAssertEqual(center.added.first?.payload.title, event.coachingTitle)
        XCTAssertEqual(center.added.first?.payload.body, event.coachingBody)
        XCTAssertEqual(center.added.first?.payload.destination, .keyBumpsHistory)
    }

    func testNativeBannerContentDoesNotForceTheSeparateSoundChannel() {
        let payload = NativeNotificationPayload(
            title: "Open new window",
            body: "Finder · ⌘N",
            destination: .keyBumpsHistory
        )

        let content = SystemNotificationContentFactory.makeContent(for: payload)

        XCTAssertNil(content.sound)
        XCTAssertEqual(
            content.userInfo[NativeNotificationPayload.destinationKey] as? String,
            AppShellDestination.keyBumpsHistory.rawValue
        )
    }

    func testNativeNotificationPreviewReportsDeliveryErrorWithoutPersistingHistory() async {
        let center = StubNativeNotificationCenter(status: .authorized)
        center.addError = TestError.expected
        let inbox = InboxStore(persistence: MemoryPersistence())
        let service = NotificationDeliveryService(
            inbox: inbox,
            adapters: [.nativeBanner: NativeNotificationAdapter(center: center)]
        )

        let outcome = await service.preview(.sample, through: .nativeBanner)

        guard case .failed = outcome else { return XCTFail("Expected notification-center rejection to fail") }
        XCTAssertTrue(inbox.events.isEmpty)
    }

    func testNotificationResponseRoutesThroughAppShellToKeyBumpsHistory() {
        let router = AppShellRouter()
        var destinations: [AppShellDestination] = []
        let delegate = AppDelegate(
            quickSearchRouter: QuickSearchRouter(),
            appShellRouter: router
        )

        XCTAssertTrue(delegate.handleNotificationResponse(userInfo: NativeNotificationPayload.keyBumpsUserInfo))
        XCTAssertTrue(destinations.isEmpty, "A cold-launch notification response should wait for app-shell configuration")
        router.configure { destinations.append($0) }
        XCTAssertEqual(destinations, [.keyBumpsHistory])
        XCTAssertFalse(delegate.handleNotificationResponse(userInfo: [:]))
        XCTAssertEqual(destinations, [.keyBumpsHistory])
    }

    func testNotificationResponseWinsOverQueuedGenericReopen() async {
        let quickSearchRouter = QuickSearchRouter()
        let appShellRouter = AppShellRouter()
        var quickSearchOpenCount = 0
        var destinations: [AppShellDestination] = []
        quickSearchRouter.configure { quickSearchOpenCount += 1 }
        appShellRouter.configure { destinations.append($0) }
        let delegate = AppDelegate(
            quickSearchRouter: quickSearchRouter,
            appShellRouter: appShellRouter
        )

        XCTAssertFalse(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false))
        XCTAssertTrue(delegate.handleNotificationResponse(userInfo: NativeNotificationPayload.keyBumpsUserInfo))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertEqual(destinations, [.keyBumpsHistory])
        XCTAssertEqual(quickSearchOpenCount, 0, "Notification routing must suppress the queued generic Search reopen")
    }

    func testOnlyReliablyPreviewableChannelsOfferPreviewControls() {
        XCTAssertFalse(NotificationChannel.nativeBanner.supportsPreview)
        XCTAssertTrue(NotificationChannel.topRightToast.supportsPreview)
        XCTAssertTrue(NotificationChannel.topCenterShelf.supportsPreview)
        XCTAssertTrue(NotificationChannel.sound.supportsPreview)
    }

    func testNativeNotificationRequestsUndeterminedAuthorizationBeforeDelivery() async throws {
        let center = StubNativeNotificationCenter(status: .notDetermined)
        center.requestedStatus = .provisional
        let adapter = NativeNotificationAdapter(center: center)

        try await adapter.deliver(.sample)

        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(center.added.count, 1)
    }

    func testNativeNotificationDoesNotSubmitWhenAuthorizationIsDenied() async {
        for status in [NativeNotificationAuthorization.denied, .unknown] {
            let center = StubNativeNotificationCenter(status: status)
            let adapter = NativeNotificationAdapter(center: center)

            do {
                try await adapter.deliver(.sample)
                XCTFail("Expected denied authorization to fail")
            } catch {
                XCTAssertEqual(error as? DeliveryAdapterError, .notificationsDenied)
            }
            XCTAssertEqual(center.requestCount, 0)
            XCTAssertTrue(center.added.isEmpty)
        }
    }

    func testNativeNotificationReportsAuthorizedButDisabledBanners() async {
        let center = StubNativeNotificationCenter(status: .authorizedWithoutAlerts)
        let adapter = NativeNotificationAdapter(center: center)

        do {
            try await adapter.deliver(.sample)
            XCTFail("Expected disabled banner alerts to fail")
        } catch {
            XCTAssertEqual(error as? DeliveryAdapterError, .notificationAlertsDisabled)
        }
        XCTAssertTrue(center.added.isEmpty)
    }

    func testNativeNotificationHonorsARejectedAuthorizationRequest() async {
        let center = StubNativeNotificationCenter(status: .notDetermined)
        center.requestResult = false
        let adapter = NativeNotificationAdapter(center: center)

        do {
            try await adapter.deliver(.sample)
            XCTFail("Expected rejected authorization to fail")
        } catch {
            XCTAssertEqual(error as? DeliveryAdapterError, .notificationsDenied)
        }
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testEnabledNativeBannerSurfacesMissingNotificationAuthorization() async {
        let suite = "ShortcutCoachTests-notification-attention-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([NotificationChannel.nativeBanner.rawValue], forKey: "selectedNotificationChannels")
        let center = StubNativeNotificationCenter(status: .denied)
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            inbox: InboxStore(persistence: MemoryPersistence()),
            presenceController: StubPresenceController(),
            detector: ManualActionDetector(monitor: StubPointerMonitor()),
            presenter: PresentationWindowController(keyboardMonitor: StubKeyboardEventMonitor()),
            nativeNotificationCenter: center
        )

        await model.refreshNotificationPermission()
        XCTAssertTrue(model.nativeNotificationNeedsAttention)

        center.status = .authorized
        await model.refreshNotificationPermission()
        XCTAssertFalse(model.nativeNotificationNeedsAttention)
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

    func testEscapeDismissesCustomPanelsAndStopsBeingConsumedAfterCleanup() {
        let keyboard = StubKeyboardEventMonitor()
        let controller = PresentationWindowController(keyboardMonitor: keyboard)

        XCTAssertEqual(keyboard.startCount, 0)

        controller.show(event: .sample, style: .topRightToast)
        controller.show(event: .sample, style: .topCenterShelf)
        XCTAssertEqual(keyboard.startCount, 1, "All active presentations share one Escape monitor")
        XCTAssertEqual(controller.activeChannels, [.topRightToast, .topCenterShelf])
        XCTAssertTrue(keyboard.sendDismissalCommand())
        XCTAssertTrue(controller.activeChannels.isEmpty)
        XCTAssertTrue(controller.scheduledDismissalChannels.isEmpty)
        XCTAssertEqual(keyboard.stopCount, 1, "The monitor must stop when the final panel closes")
        XCTAssertFalse(keyboard.sendDismissalCommand())
    }

    func testDismissingOneOfSeveralPanelsKeepsInteractionMonitorUntilTheLastCloses() {
        let keyboard = StubKeyboardEventMonitor()
        let controller = PresentationWindowController(keyboardMonitor: keyboard)
        controller.show(event: .sample, style: .topRightToast)
        controller.show(event: .sample, style: .topCenterShelf)

        controller.dismiss(.topRightToast)
        XCTAssertEqual(keyboard.stopCount, 0)
        controller.dismiss(.topCenterShelf)
        XCTAssertEqual(keyboard.stopCount, 1)
    }

    func testDisablingKeyBumpsDismissesPresentationsAndStopsInteractionMonitors() {
        let suite = "ShortcutCoachTests-disable-presentations-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.didCompleteOnboarding = true
        let keyboard = StubKeyboardEventMonitor()
        let presenter = PresentationWindowController(keyboardMonitor: keyboard)
        let model = AppModel(
            releaseLane: .full,
            preferences: preferences,
            inbox: InboxStore(persistence: MemoryPersistence()),
            presenceController: StubPresenceController(),
            detector: ManualActionDetector(monitor: StubPointerMonitor()),
            presenter: presenter
        )
        presenter.show(event: .sample, style: .topRightToast)

        model.setCapability(.shortcutCoaching, enabled: false)

        XCTAssertTrue(presenter.activeChannels.isEmpty)
        XCTAssertEqual(keyboard.stopCount, 1)
    }

    func testLocalKeyboardMonitorRecognizesEscapeButPassesThroughOtherKeys() throws {
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        ))
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: UInt16(kVK_Return)
        ))

        XCTAssertTrue(LocalKeyboardEventMonitor.isDismissalEvent(escape))
        XCTAssertFalse(LocalKeyboardEventMonitor.isDismissalEvent(returnKey))
    }

    func testRetainedPresentationsCanAppearTogether() {
        let controller = PresentationWindowController(keyboardMonitor: StubKeyboardEventMonitor())

        controller.show(event: .sample, style: .topRightToast)
        controller.show(event: .sample, style: .topCenterShelf)

        XCTAssertEqual(controller.activeChannels, [.topRightToast, .topCenterShelf])
        XCTAssertEqual(controller.scheduledDismissalChannels, [.topRightToast, .topCenterShelf])
    }

    func testButtonDismissalUsesCanonicalPanelAndTaskCleanup() {
        let controller = PresentationWindowController(keyboardMonitor: StubKeyboardEventMonitor())
        controller.show(event: .sample, style: .topCenterShelf)

        let buttonAction = controller.dismissalAction(for: .topCenterShelf)
        buttonAction()

        XCTAssertTrue(controller.activeChannels.isEmpty)
        XCTAssertTrue(controller.scheduledDismissalChannels.isEmpty)
    }

    func testHoverPausesAndResumesTheExistingDismissalCountdown() {
        let controller = PresentationWindowController(keyboardMonitor: StubKeyboardEventMonitor())
        controller.show(event: .sample, style: .topRightToast)
        XCTAssertEqual(controller.scheduledDismissalChannels, [.topRightToast])

        controller.setHovering(true, style: .topRightToast)
        XCTAssertEqual(controller.pausedDismissalChannels, [.topRightToast])
        XCTAssertTrue(controller.scheduledDismissalChannels.isEmpty)

        controller.setHovering(false, style: .topRightToast)
        XCTAssertTrue(controller.pausedDismissalChannels.isEmpty)
        XCTAssertEqual(controller.scheduledDismissalChannels, [.topRightToast])
    }

    func testHoverTimingPreservesRemainingDurationInsteadOfResetting() {
        XCTAssertEqual(
            ToastDismissalPolicy.remainingDuration(initial: 4, elapsed: 1.25),
            2.75,
            accuracy: 0.001
        )
        XCTAssertEqual(ToastDismissalPolicy.remainingDuration(initial: 2, elapsed: 7), 0)
        XCTAssertEqual(ToastDismissalPolicy.remainingDuration(initial: 2, elapsed: -1), 2)
    }

    func testOnlyIntentionalHorizontalSwipesDismissToasts() {
        XCTAssertTrue(ToastDismissalPolicy.shouldDismiss(for: NSSize(width: 70, height: 8)))
        XCTAssertTrue(ToastDismissalPolicy.shouldDismiss(for: NSSize(width: -70, height: 8)))
        XCTAssertFalse(ToastDismissalPolicy.shouldDismiss(for: NSSize(width: 40, height: 2)))
        XCTAssertFalse(ToastDismissalPolicy.shouldDismiss(for: NSSize(width: 70, height: 90)))
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
        let suite = "ShortcutCoachTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showInDockAndSwitcher)
        XCTAssertEqual(preferences.selectedChannels, [.topRightToast])

        preferences.set(.sound, enabled: true)
        preferences.set(.topRightToast, enabled: false)
        preferences.showInDockAndSwitcher = false

        let restored = AppPreferences(defaults: defaults)
        XCTAssertFalse(restored.showInDockAndSwitcher)
        XCTAssertEqual(restored.selectedChannels, [.sound])
    }

    func testLegacyCursorHaloSelectionIsRemovedAndRewritten() {
        let suite = "ShortcutCoachTests-remove-cursor-halo-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["cursorHalo", NotificationChannel.sound.rawValue], forKey: "selectedNotificationChannels")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedChannels, [.sound])
        XCTAssertEqual(defaults.stringArray(forKey: "selectedNotificationChannels"), ["sound"])
        XCTAssertFalse(NotificationChannel.allCases.map(\.rawValue).contains("cursorHalo"))
    }

    func testRetainedPresentationChannelsCanBeCombined() {
        let suite = "ShortcutCoachTests-overlap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)

        preferences.set(.topCenterShelf, enabled: true)
        XCTAssertEqual(preferences.selectedChannels, [.topRightToast, .topCenterShelf])
    }

    func testRemovedPresentationChannelsAreMigratedOutOfPersistedPreferences() {
        let suite = "ShortcutCoachTests-normalized-overlap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "statusFeedback",
            NotificationChannel.topCenterShelf.rawValue,
            "decisionBanner",
            "dockBadge",
            "dockBounce",
            "cursorHalo",
            "pointerCard",
            NotificationChannel.sound.rawValue
        ], forKey: "selectedNotificationChannels")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedChannels, [.topCenterShelf, .sound])
        XCTAssertEqual(
            defaults.array(forKey: "selectedNotificationChannels") as? [String],
            ["sound", "topCenterShelf"]
        )
    }

    func testPreferencesMigrateFromEitherPreviousBundleIdentity() {
        for sourceIndex in 0..<2 {
            let currentSuite = "ShortcutCoachTests-current-\(UUID().uuidString)"
            let oldestSuite = "ShortcutCoachTests-oldest-\(UUID().uuidString)"
            let recentSuite = "ShortcutCoachTests-recent-\(UUID().uuidString)"
            let current = UserDefaults(suiteName: currentSuite)!
            let oldest = UserDefaults(suiteName: oldestSuite)!
            let recent = UserDefaults(suiteName: recentSuite)!
            defer {
                current.removePersistentDomain(forName: currentSuite)
                oldest.removePersistentDomain(forName: oldestSuite)
                recent.removePersistentDomain(forName: recentSuite)
            }
            let source = [recent, oldest][sourceIndex]
            source.set([NotificationChannel.topCenterShelf.rawValue, NotificationChannel.sound.rawValue], forKey: "selectedNotificationChannels")
            source.set(false, forKey: "showInDockAndSwitcher")

            let migrated = AppPreferences(defaults: current, legacyDefaults: [recent, oldest])

            XCTAssertEqual(migrated.selectedChannels, [.topCenterShelf, .sound])
            XCTAssertFalse(migrated.showInDockAndSwitcher)
            XCTAssertEqual(current.array(forKey: "selectedNotificationChannels") as? [String], ["sound", "topCenterShelf"])
            XCTAssertEqual(current.bool(forKey: "showInDockAndSwitcher"), false)
        }
    }

    func testSuperMacBrandingConfiguresTheActualStatusBarButtonContract() {
        XCTAssertTrue(ProductIdentity.legacyBundleIdentifiers.isEmpty)
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let target = StatusItemActionTarget()

        StatusItemBranding.configure(
            button,
            target: target,
            action: #selector(StatusItemActionTarget.activate(_:))
        )

        XCTAssertEqual(ProductIdentity.statusItemImageName, "SuperMacMenuBarMark")
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.image?.isTemplate, true)
        XCTAssertEqual(button.image?.size, NSSize(width: 17, height: 17))
        // NSStatusBarButton normalizes .imageOnly to .imageOverlaps. The empty
        // title is the observable contract that leaves only the image visible.
        XCTAssertEqual(button.imagePosition, .imageOverlaps)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.toolTip, "SuperMac")
        XCTAssertEqual(button.accessibilityLabel(), "SuperMac")
        XCTAssertTrue(button.target === target)
        XCTAssertEqual(button.action, #selector(StatusItemActionTarget.activate(_:)))
    }

    func testReleaseLanesHaveSeparateIdentitiesAndCapabilities() {
        XCTAssertEqual(ReleaseLane.full.productName, "SuperMac")
        XCTAssertEqual(ReleaseLane.full.bundleIdentifier, "com.serp.supermac")
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
            XCTAssertFalse(channel.summary.isEmpty)
            XCTAssertFalse(channel.systemImage.isEmpty)
        }
    }

    func testShortcutFormatterUsesAccessibilityModifierBits() {
        XCTAssertEqual(ShortcutFormatter.format(command: "n", modifiers: 0), "⌘N")
        XCTAssertEqual(ShortcutFormatter.format(command: "t", modifiers: 1), "⇧⌘T")
        XCTAssertEqual(ShortcutFormatter.format(command: "f", modifiers: 2 | 4), "⌃⌥⌘F")
        XCTAssertEqual(ShortcutFormatter.format(command: "a", modifiers: 8), "A")
    }

    func testCoachingCopyUsesTheDetectedEvent() {
        let event = CoachingEvent(applicationName: "Safari", actionTitle: "New Tab", shortcut: "⌘T")
        XCTAssertEqual(event.coachingTitle, "New tab")
        XCTAssertEqual(event.coachingBody, "Safari · ⌘T")
    }

    func testShortcutKeycapsUseLowercaseLettersUnlessShiftIsPresent() {
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: "⌘N").keys, ["⌘", "n"])
        XCTAssertEqual(ShortcutKeycapPresentation(shortcut: "⇧⌘N").keys, ["⇧", "⌘", "N"])
    }
}
