import AppKit
import XCTest
@testable import Keybumps
import Sparkle

final class UpdaterTestEventPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

@MainActor
struct UpdaterTestPresenceController: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}

final class UpdaterTestPointerMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    func start() -> Bool { false }
    func stop() {}
}

struct UpdaterTestPermissions: DetectorPermissionProviding {
    let isAccessibilityTrusted = false
    let isInputMonitoringAuthorized = false
    func requestAccessibility() {}
    func requestInputMonitoring() {}
}

@MainActor
final class FakeUpdateController: UpdateControlling {
    private(set) var snapshot = UpdateSnapshot(status: .idle, automaticallyChecks: true, canCheck: false, canRestart: false)
    var onChange: ((UpdateSnapshot) -> Void)?
    var onShowVersionHistory: (() -> Void)?
    private(set) var startCount = 0
    private(set) var checkCount = 0
    private(set) var restartCount = 0
    private(set) var safetyChangeCount = 0

    func start() {
        startCount += 1
        emit(.idle, canCheck: true)
    }

    func checkNow() {
        checkCount += 1
        emit(.checking)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        snapshot.automaticallyChecks = enabled
        onChange?(snapshot)
    }

    func installationSafetyDidChange() { safetyChangeCount += 1 }
    func restartWhenSafe() { restartCount += 1 }

    func emit(_ status: UpdateStatus, canCheck: Bool? = nil, canRestart: Bool? = nil) {
        snapshot.setStatus(status)
        if let canCheck { snapshot.canCheck = canCheck }
        if let canRestart { snapshot.canRestart = canRestart }
        onChange?(snapshot)
    }
}

private final class UpdateTestRecorder: UpdateEventRecording {
    private(set) var events: [UpdateTelemetryEvent] = []
    func record(_ event: UpdateTelemetryEvent) { events.append(event) }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testInstallationSafetyDefersEveryActiveDictationPhase() {
        let policy = UpdateInstallationSafetyPolicy()

        for phase in [DictationPhase.recording, .transcribing, .inserting] {
            policy.update(dictationPhase: phase)
            XCTAssertFalse(policy.isSafeToInstall, "Expected \(phase) to defer installation")
        }

        policy.update(dictationPhase: .idle)
        XCTAssertTrue(policy.isSafeToInstall)
        policy.update(dictationPhase: .failed("fixture"))
        XCTAssertTrue(policy.isSafeToInstall)
        policy.updateCriticalOperation(.unsavedWork, active: true)
        XCTAssertFalse(policy.isSafeToInstall)
        policy.updateCriticalOperation(.unsavedWork, active: false)
        XCTAssertTrue(policy.isSafeToInstall)
    }

    func testQuitDuringActiveDictationAsksBeforeQuitting() {
        var asked: [[String]] = []
        let declines = AppDelegate(quickSearchRouter: QuickSearchRouter()) { asked.append($0); return false }
        let confirms = AppDelegate(quickSearchRouter: QuickSearchRouter()) { _ in true }
        defer { UpdateInstallationSafetyPolicy.shared.update(dictationPhase: .idle) }

        UpdateInstallationSafetyPolicy.shared.update(dictationPhase: .recording)
        XCTAssertEqual(declines.applicationShouldTerminate(.shared), .terminateCancel)
        XCTAssertEqual(asked, [["Dictation is still in progress."]])
        XCTAssertEqual(confirms.applicationShouldTerminate(.shared), .terminateNow)

        UpdateInstallationSafetyPolicy.shared.update(dictationPhase: .idle)
        XCTAssertEqual(declines.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertEqual(asked.count, 1)
    }

    func testDisabledUpdaterNeverContactsOrMutatesAFeed() {
        let updater = DisabledUpdateController(reason: "fixture")
        var changes = 0
        updater.onChange = { _ in changes += 1 }

        updater.start()
        updater.checkNow()
        updater.setAutomaticallyChecks(true)
        updater.restartWhenSafe()

        XCTAssertEqual(updater.snapshot.status, .unavailable("fixture"))
        XCTAssertFalse(updater.snapshot.canCheck)
        XCTAssertFalse(updater.snapshot.automaticallyChecks)
        XCTAssertEqual(changes, 0)
    }

    func testDebugConfigurationRequiresAnExplicitFixtureFeedOverride() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterFixture-\(UUID().uuidString).bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.serp.keybumps.fixture",
            "CFBundlePackageType": "BNDL",
            "SUFeedURL": "https://production.invalid/appcast.xml",
            "SUPublicEDKey": "fixture-public-key"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))

        #if DEBUG
        XCTAssertNil(SparkleUpdateConfiguration.from(bundle: bundle, environment: [:]))
        XCTAssertEqual(
            SparkleUpdateConfiguration.from(
                bundle: bundle,
                environment: ["KEYBUMPS_UPDATE_FIXTURE_FEED_URL": "http://127.0.0.1:8765/appcast.xml"]
            )?.feedURL.absoluteString,
            "http://127.0.0.1:8765/appcast.xml"
        )
        for acceptedFixture in [
            "https://localhost:8765/appcast.xml",
            "http://[::1]:8765/appcast.xml"
        ] {
            XCTAssertNotNil(
                SparkleUpdateConfiguration.from(
                    bundle: bundle,
                    environment: ["KEYBUMPS_UPDATE_FIXTURE_FEED_URL": acceptedFixture]
                )
            )
        }
        for rejectedFixture in [
            "https://production.invalid/appcast.xml",
            "http://example.com/appcast.xml",
            "http://user:password@localhost:8765/appcast.xml",
            "http://localhost:8765/appcast.xml#fragment"
        ] {
            XCTAssertNil(
                SparkleUpdateConfiguration.from(
                    bundle: bundle,
                    environment: ["KEYBUMPS_UPDATE_FIXTURE_FEED_URL": rejectedFixture]
                ),
                "Debug unexpectedly trusted \(rejectedFixture)"
            )
        }
        #endif
    }

    func testStatusMenuRoutesCheckAndSafeRestartThroughOneUpdaterSeam() {
        let controller = NativeStatusItemController(router: MainWindowRouter())
        var checkCount = 0
        var restartCount = 0
        controller.configureUpdater(
            snapshot: {
                UpdateSnapshot(
                    status: .readyToRestart(version: "0.0.2"),
                    automaticallyChecks: true,
                    canCheck: true,
                    canRestart: true
                )
            },
            checkNow: { checkCount += 1 },
            restartWhenSafe: { restartCount += 1 }
        )

        let menu = controller.makeMenu()
        let checkItem = try! XCTUnwrap(menu.item(withTitle: "Check for Updates…"))
        let restartItem = try! XCTUnwrap(menu.item(withTitle: "Restart to Update"))
        XCTAssertTrue(checkItem.isEnabled)
        checkItem.target?.perform(checkItem.action, with: checkItem)
        restartItem.target?.perform(restartItem.action, with: restartItem)

        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(restartCount, 1)
    }

    func testAppModelLaunchMenuPreferenceRetryAndInstallStatesUseInjectedUpdater() {
        let defaults = InMemoryDefaults()
        let fake = FakeUpdateController()
        let detector = ManualActionDetector(
            monitor: UpdaterTestPointerMonitor(),
            permissions: UpdaterTestPermissions()
        )
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
            inbox: InboxStore(persistence: UpdaterTestEventPersistence()),
            presenceController: UpdaterTestPresenceController(),
            detector: detector,
            updater: fake
        )

        model.start()
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertTrue(model.updateSnapshot.canCheck)

        let menuController = NativeStatusItemController(router: MainWindowRouter())
        menuController.configureUpdater(
            snapshot: { model.updateSnapshot },
            checkNow: model.checkForUpdates,
            restartWhenSafe: model.restartToUpdate
        )
        let initialMenu = menuController.makeMenu()
        let checkItem = try! XCTUnwrap(initialMenu.item(withTitle: "Check for Updates…"))
        checkItem.target?.perform(checkItem.action, with: checkItem)
        XCTAssertEqual(fake.checkCount, 1)
        XCTAssertEqual(model.updateSnapshot.status, .checking)

        fake.emit(.failed("offline"))
        model.checkForUpdates()
        XCTAssertEqual(fake.checkCount, 2, "A recoverable failure must remain retryable")
        model.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(model.updateSnapshot.automaticallyChecks)

        fake.emit(.downloading(version: "0.0.2"))
        XCTAssertNil(menuController.makeMenu().item(withTitle: "Restart to Update"))
        fake.emit(.downloaded(version: "0.0.2"))
        XCTAssertNil(menuController.makeMenu().item(withTitle: "Restart to Update"))
        fake.emit(.readyToRestart(version: "0.0.2"), canRestart: true)
        let restartItem = try! XCTUnwrap(menuController.makeMenu().item(withTitle: "Restart to Update"))
        restartItem.target?.perform(restartItem.action, with: restartItem)
        XCTAssertEqual(fake.restartCount, 1)

        fake.emit(.deferred(version: "0.0.2"))
        XCTAssertEqual(model.updateSnapshot.status, .deferred(version: "0.0.2"))
    }

    func testAvailableUpdateShowsTheDotAndVersionHistoryOpensChangelog() {
        let fake = FakeUpdateController()
        let model = AppModel(
            preferences: AppPreferences(defaults: InMemoryDefaults()),
            inbox: InboxStore(persistence: UpdaterTestEventPersistence()),
            presenceController: UpdaterTestPresenceController(),
            detector: ManualActionDetector(monitor: UpdaterTestPointerMonitor(), permissions: UpdaterTestPermissions()),
            updater: fake
        )
        var versionHistoryOpens = 0
        model.openVersionHistory = { versionHistoryOpens += 1 }
        model.start()

        fake.emit(.available(version: "0.0.2"))
        XCTAssertEqual(model.menuBarAttention.accessibilityLabel(productName: "Keybumps"), "Keybumps, update available")
        fake.emit(.readyToRestart(version: "0.0.2"), canRestart: true)
        XCTAssertEqual(model.menuBarAttention.accessibilityLabel(productName: "Keybumps"), "Keybumps, update ready")
        fake.emit(.current, canRestart: false)
        XCTAssertFalse(model.menuBarAttention.showsDot)

        fake.onShowVersionHistory?()
        XCTAssertEqual(versionHistoryOpens, 1)
    }

    func testVersionHistoryButtonIsHandledInsteadOfOpeningTheWebsite() throws {
        let controller = SparkleUpdateController(
            configuration: SparkleUpdateConfiguration(feedURL: URL(string: "https://updates.keybumps.app/appcast.xml")!, publicKey: "test"),
            safetyPolicy: UpdateInstallationSafetyPolicy()
        )
        var opens = 0
        controller.onShowVersionHistory = { opens += 1 }
        // Sparkle shows its Version History button and asks the delegate, instead of opening the
        // release notes link, only when the delegate responds to this selector.
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("standardUserDriverShowVersionHistoryForAppcastItem:")))
        controller.standardUserDriverShowVersionHistory(for: SUAppcastItem.empty())
        XCTAssertEqual(opens, 1)
    }

    func testSkippingAnUpdateClearsTheDotAndRestart() {
        let controller = SparkleUpdateController(
            configuration: SparkleUpdateConfiguration(feedURL: URL(string: "https://updates.keybumps.app/appcast.xml")!, publicKey: "test"),
            safetyPolicy: UpdateInstallationSafetyPolicy()
        )
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("updater:userDidMakeChoice:forUpdate:state:")))
        controller.installCoordinator.captureImmediateInstall(version: "0.0.2") {}
        XCTAssertTrue(controller.snapshot.canRestart)
        XCTAssertTrue(MenuBarAttention.updateIsWaiting(controller.snapshot))

        controller.userDidMake(.dismiss)
        XCTAssertTrue(controller.snapshot.canRestart, "Remind Me Later keeps the update")
        controller.userDidMake(.skip)
        XCTAssertFalse(controller.snapshot.canRestart)
        XCTAssertEqual(controller.snapshot.status, .idle)
        XCTAssertFalse(MenuBarAttention.updateIsWaiting(controller.snapshot))
        controller.installationSafetyDidChange()
        XCTAssertEqual(controller.snapshot.status, .idle, "A later safety change doesn't bring the skipped update back")
    }

    func testRestartIsNotReadyUntilAnImmediateInstallHandlerExists() {
        let safety = UpdateInstallationSafetyPolicy()
        let coordinator = SafeUpdateInstallCoordinator(safetyPolicy: safety)
        var statuses: [UpdateStatus] = []
        var installCount = 0
        coordinator.onStatusChange = { statuses.append($0) }

        coordinator.recordDownloaded(version: "0.0.2")
        XCTAssertFalse(coordinator.hasCallableRestart)
        XCTAssertFalse(coordinator.restartWhenSafe())
        XCTAssertEqual(statuses, [.downloaded(version: "0.0.2")])

        coordinator.captureImmediateInstall(version: "0.0.2") { installCount += 1 }
        XCTAssertTrue(coordinator.hasCallableRestart)
        XCTAssertEqual(statuses.last, .readyToRestart(version: "0.0.2"))
        XCTAssertTrue(coordinator.restartWhenSafe())
        XCTAssertEqual(installCount, 1)
    }

    func testSparkleRelaunchPostponementResumesWhenDictationBecomesIdle() {
        let safety = UpdateInstallationSafetyPolicy()
        let coordinator = SafeUpdateInstallCoordinator(safetyPolicy: safety)
        var resumeCount = 0
        var statuses: [UpdateStatus] = []
        coordinator.onStatusChange = { statuses.append($0) }

        safety.update(dictationPhase: .recording)
        XCTAssertTrue(
            coordinator.shouldPostponeRelaunch(version: "0.0.2") { resumeCount += 1 }
        )
        XCTAssertEqual(statuses.last, .deferred(version: "0.0.2"))
        coordinator.safetyDidChange()
        XCTAssertEqual(resumeCount, 0)

        safety.update(dictationPhase: .idle)
        coordinator.safetyDidChange()
        XCTAssertEqual(resumeCount, 1)
        coordinator.safetyDidChange()
        XCTAssertEqual(resumeCount, 1, "The postponed Sparkle continuation must be resumed once")
    }

    func testScheduledDiscoveryUsesSparklesStandardPresentation() {
        XCTAssertTrue(ScheduledUpdatePresentationPolicy.usesSparkleStandardDriver)
    }

    func testSynchronousCriticalOperationUsesSharedTerminationGate() {
        let policy = UpdateInstallationSafetyPolicy()
        var safetyChanges: [Bool] = []
        var operationRan = false

        policy.performSynchronousCriticalOperation(
            .windowAction,
            notify: { safetyChanges.append(policy.isSafeToInstall) },
            operation: {
                operationRan = true
                XCTAssertFalse(policy.isSafeToInstall)
            }
        )

        XCTAssertTrue(operationRan)
        XCTAssertEqual(safetyChanges, [false, true])
        XCTAssertTrue(policy.isSafeToInstall)
    }

    func testWindowDragLifecycleFeedsTheSharedCriticalOperationGate() {
        var tracker = WindowDragActivityTracker()
        let policy = UpdateInstallationSafetyPolicy()
        var notifications: [Bool] = []

        if tracker.setActive(true) {
            policy.updateCriticalOperation(.windowDrag, active: tracker.isActive)
            notifications.append(policy.isSafeToInstall)
        }
        XCTAssertFalse(policy.isSafeToInstall)
        XCTAssertFalse(tracker.setActive(true), "Repeated drag events must not duplicate lifecycle notifications")

        if tracker.setActive(false) {
            policy.updateCriticalOperation(.windowDrag, active: tracker.isActive)
            notifications.append(policy.isSafeToInstall)
        }
        XCTAssertTrue(policy.isSafeToInstall)
        XCTAssertEqual(notifications, [false, true])
    }

    func testUpdaterTelemetryContainsOnlyStructuralFields() {
        let recorder = UpdateTestRecorder()
        var time = 10.0
        let telemetry = UpdateTelemetry(recorder: recorder, build: "2", now: { time })
        time = 10.125

        telemetry.record(.available, version: "0.0.2")
        telemetry.record(.failed, failureCategory: "download")

        XCTAssertEqual(recorder.events, [
            UpdateTelemetryEvent(stage: .available, version: "0.0.2", build: "2", elapsedMilliseconds: 125, failureCategory: nil),
            UpdateTelemetryEvent(stage: .failed, version: nil, build: "2", elapsedMilliseconds: 125, failureCategory: "download")
        ])
    }

    func testUpdaterStatusCopyIsTruthfulAndContentFree() {
        XCTAssertEqual(UpdateStatus.checking.summary, "Checking…")
        XCTAssertEqual(UpdateStatus.current.summary, "Keybumps is up to date")
        XCTAssertEqual(
            UpdateStatus.deferred(version: "0.0.2").summary,
            "Version 0.0.2 will install when Dictation is idle"
        )
        XCTAssertEqual(
            NoUpdateStatusResolver.status(reasonCode: 3),
            .failed("This update requires a newer version of macOS")
        )
        XCTAssertEqual(NoUpdateStatusResolver.status(reasonCode: 1), .current)
        XCTAssertEqual(NoUpdateStatusResolver.status(reasonCode: 2), .current)
        XCTAssertEqual(
            NoUpdateStatusResolver.status(reasonCode: nil),
            .failed("The update check completed without a verifiable result. Try again.")
        )
        XCTAssertEqual(
            NoUpdateStatusResolver.status(reasonCode: 0),
            .failed("The update check completed without a verifiable result. Try again.")
        )
    }
}
