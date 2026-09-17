import AppKit
import XCTest
@testable import SuperMac

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
    }

    func testApplicationTerminationGuardRejectsQuitDuringActiveDictation() {
        let delegate = AppDelegate(quickSearchRouter: QuickSearchRouter())
        defer { ApplicationTerminationGuard.shared.update(dictationPhase: .idle) }

        ApplicationTerminationGuard.shared.update(dictationPhase: .recording)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)

        ApplicationTerminationGuard.shared.update(dictationPhase: .idle)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
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
            "CFBundleIdentifier": "com.serp.supermac.fixture",
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
                environment: ["SUPERMAC_UPDATE_FIXTURE_FEED_URL": "http://127.0.0.1:8765/appcast.xml"]
            )?.feedURL.absoluteString,
            "http://127.0.0.1:8765/appcast.xml"
        )
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
                    canCheck: true
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

    func testUpdaterStatusCopyIsTruthfulAndContentFree() {
        XCTAssertEqual(UpdateStatus.checking.summary, "Checking…")
        XCTAssertEqual(UpdateStatus.current.summary, "SuperMac is up to date")
        XCTAssertEqual(
            UpdateStatus.deferred(version: "0.0.2").summary,
            "Version 0.0.2 will install when Dictation is idle"
        )
        XCTAssertEqual(
            NoUpdateStatusResolver.status(reasonCode: 3),
            .failed("This update requires a newer version of macOS")
        )
        XCTAssertEqual(NoUpdateStatusResolver.status(reasonCode: 1), .current)
    }
}
