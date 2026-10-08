import Foundation
import Sparkle

struct SparkleUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicKey: String

    static func from(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SparkleUpdateConfiguration? {
        #if DEBUG
        let fixtureFeed = environment["KEYBUMPS_UPDATE_FIXTURE_FEED_URL"]
        let rawFeed = fixtureFeed
        #else
        let fixtureFeed: String? = nil
        let rawFeed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        #endif
        guard let rawFeed,
              let feedURL = validatedFeedURL(rawFeed, isFixture: fixtureFeed != nil),
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SparkleUpdateConfiguration(feedURL: feedURL, publicKey: publicKey)
    }

    private static func validatedFeedURL(_ rawValue: String, isFixture: Bool) -> URL? {
        guard let components = URLComponents(string: rawValue),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        if isFixture {
            guard (scheme == "http" || scheme == "https"),
                  ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else {
                return nil
            }
        } else {
            guard scheme == "https" else { return nil }
        }
        return components.url
    }
}

enum NoUpdateStatusResolver {
    /// Whether Sparkle answered (up to date, or no update fits this Mac) rather than failing to
    /// verify the feed.
    static func isAnswer(reasonCode: Int?) -> Bool {
        (1...5).contains(reasonCode ?? 0)
    }

    static func status(reasonCode: Int?) -> UpdateStatus {
        switch reasonCode {
        case 1, 2: .current
        case 3: .failed("This update requires a newer version of macOS")
        case 4: .failed("This update does not support this version of macOS")
        case 5: .failed("This update requires an Apple silicon Mac")
        default: .failed("The update check completed without a verifiable result. Try again.")
        }
    }
}

@MainActor
enum UpdateControllerFactory {
    static func makeDefault(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        safetyPolicy: UpdateInstallationSafetyPolicy
    ) -> any UpdateControlling {
        guard let configuration = SparkleUpdateConfiguration.from(
            bundle: bundle,
            environment: environment
        ) else {
            #if DEBUG
            return DisabledUpdateController(reason: "Updates are disabled in this development build")
            #else
            return DisabledUpdateController(reason: "Update service is not configured")
            #endif
        }
        return SparkleUpdateController(configuration: configuration, safetyPolicy: safetyPolicy)
    }
}

@MainActor
final class SparkleUpdateController: NSObject, UpdateControlling, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private(set) var snapshot = UpdateSnapshot(
        status: .idle,
        automaticallyChecks: true,
        canCheck: false,
        canRestart: false
    )
    var onChange: ((UpdateSnapshot) -> Void)?
    var onShowVersionHistory: (() -> Void)?

    private let configuration: SparkleUpdateConfiguration
    let installCoordinator: SafeUpdateInstallCoordinator
    private let telemetry: UpdateTelemetry
    private var updaterController: SPUStandardUpdaterController?
    private var started = false

    init(
        configuration: SparkleUpdateConfiguration,
        safetyPolicy: UpdateInstallationSafetyPolicy,
        telemetry: UpdateTelemetry = UpdateTelemetry()
    ) {
        self.configuration = configuration
        self.installCoordinator = SafeUpdateInstallCoordinator(safetyPolicy: safetyPolicy)
        self.telemetry = telemetry
        super.init()
        installCoordinator.onStatusChange = { [weak self] status in self?.apply(status) }
    }

    func start() {
        guard !started else { return }
        started = true
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller
        controller.startUpdater()
        controller.updater.automaticallyDownloadsUpdates = true
        refresh(status: .idle)
        telemetry.record(.started)
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
            refresh(status: .checking)
            telemetry.record(.checking)
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration.feedURL.absoluteString
    }

    func checkNow() {
        guard let updater = updaterController?.updater, updater.canCheckForUpdates else { return }
        refresh(status: .checking)
        telemetry.record(.checking)
        updater.checkForUpdates()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func installationSafetyDidChange() {
        installCoordinator.safetyDidChange()
    }

    func restartWhenSafe() {
        guard installCoordinator.hasCallableRestart else {
            refresh(status: .failed("The update is not ready to restart yet"))
            return
        }
        _ = installCoordinator.restartWhenSafe()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        apply(.available(version: item.displayVersionString))
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        ScheduledUpdatePresentationPolicy.usesSparkleStandardDriver
    }

    /// The up-to-date alert's Version History button opens Settings › Changelog instead of the
    /// release notes website (#416).
    func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        onShowVersionHistory?()
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        userDidMake(choice)
    }

    func userDidMake(_ choice: SPUUserUpdateChoice) {
        if choice == .skip { userDidSkipUpdate() }
    }

    /// A skipped version no longer counts as available, so its red dot goes (#416). The install
    /// coordinator resets too, so no Restart to Update outlives a skipped version.
    func userDidSkipUpdate() {
        installCoordinator.reset()
        refresh(status: .idle)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let nsError = error as NSError
        let reasonCode = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        noUpdateFound(reasonCode: reasonCode)
    }

    /// Sparkle found no update. An answer (up to date, or nothing fits this Mac) means no newer
    /// version is installable, so the dot goes even when the status reads as a failure (#420).
    func noUpdateFound(reasonCode: Int?) {
        if NoUpdateStatusResolver.isAnswer(reasonCode: reasonCode) { snapshot.knownUpdate = nil }
        apply(NoUpdateStatusResolver.status(reasonCode: reasonCode))
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        apply(.downloading(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        installCoordinator.recordDownloaded(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        telemetry.record(.failed, version: item.displayVersionString, failureCategory: "download")
        refresh(status: .failed("The update could not be downloaded. Try again."))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        installCoordinator.reset()
        let nsError = error as NSError
        guard nsError.code != 1001 else { // Sparkle's documented SUNoUpdateError value.
            let reasonCode = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
            noUpdateFound(reasonCode: reasonCode)
            return
        }
        telemetry.record(.failed, failureCategory: "update-cycle")
        refresh(status: .failed("The update check failed. Try again."))
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installCoordinator.captureImmediateInstall(
            version: item.displayVersionString,
            handler: immediateInstallHandler
        )
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        installCoordinator.shouldPostponeRelaunch(
            version: item.displayVersionString,
            handler: installHandler
        )
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        refresh()
    }

    private func refresh(status: UpdateStatus? = nil) {
        if let status { snapshot.setStatus(status) }
        if let updater = updaterController?.updater {
            snapshot.automaticallyChecks = updater.automaticallyChecksForUpdates
            snapshot.canCheck = updater.canCheckForUpdates
        }
        snapshot.canRestart = installCoordinator.hasCallableRestart
        onChange?(snapshot)
    }

    private func apply(_ status: UpdateStatus) {
        switch status {
        case .available(let version): telemetry.record(.available, version: version)
        case .downloading(let version): telemetry.record(.downloading, version: version)
        case .downloaded(let version): telemetry.record(.downloaded, version: version)
        case .readyToRestart(let version): telemetry.record(.ready, version: version)
        case .deferred(let version): telemetry.record(.deferred, version: version)
        case .current: telemetry.record(.current)
        case .failed: telemetry.record(.failed, failureCategory: "status")
        case .checking: telemetry.record(.checking)
        case .idle, .unavailable: break
        }
        refresh(status: status)
    }
}
