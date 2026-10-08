import Foundation
import OSLog

enum UpdateStatus: Equatable {
    case unavailable(String)
    case idle
    case checking
    case available(version: String)
    case downloading(version: String)
    case downloaded(version: String)
    case readyToRestart(version: String)
    case deferred(version: String)
    case current
    case failed(String)

    var summary: String {
        switch self {
        case .unavailable(let reason): reason
        case .idle: "Ready"
        case .checking: "Checking…"
        case .available(let version): "Version \(version) is available"
        case .downloading(let version): "Downloading version \(version)…"
        case .downloaded(let version): "Version \(version) is downloaded and being prepared"
        case .readyToRestart(let version): "Version \(version) is ready to install"
        case .deferred(let version): "Version \(version) will install when Dictation is idle"
        case .current: "Keybumps is up to date"
        case .failed(let message): message
        }
    }

    /// The version waiting to install, while one is.
    var pendingVersion: String? {
        switch self {
        case .downloaded(let version), .readyToRestart(let version), .deferred(let version): version
        default: nil
        }
    }

    /// The newer version this status names, from finding it until it installs (#416). A check, or a
    /// failed check or download, names none; `UpdateSnapshot.knownUpdate` keeps it through them.
    var availableVersion: String? {
        switch self {
        case .available(let version), .downloading(let version): version
        default: pendingVersion
        }
    }
}

struct UpdateSnapshot: Equatable {
    /// Set through `setStatus`, which keeps `knownUpdate` in step.
    private(set) var status: UpdateStatus
    var automaticallyChecks: Bool
    var canCheck: Bool
    var canRestart: Bool
    /// The newer version found and not yet installed or skipped. It outlives checks and failed
    /// checks or downloads, so the red dot stays until the update installs (#420).
    var knownUpdate: String? = nil

    /// The newer version to show: the one the status names, else the one found before it.
    var newerVersion: String? { status.availableVersion ?? knownUpdate }

    /// Sets the status. A check or a failure keeps the newer version found before it; Skip (idle),
    /// an up-to-date result, or updates becoming unavailable clear it, and so does Sparkle's answer
    /// that no update fits this Mac (`SparkleUpdateController.noUpdateFound`).
    mutating func setStatus(_ status: UpdateStatus) {
        self.status = status
        switch status {
        case .idle, .current, .unavailable: knownUpdate = nil
        case .checking, .failed: break
        case .available, .downloading, .downloaded, .readyToRestart, .deferred: knownUpdate = status.availableVersion
        }
    }
}

@MainActor
protocol UpdateControlling: AnyObject {
    var snapshot: UpdateSnapshot { get }
    var onChange: ((UpdateSnapshot) -> Void)? { get set }
    /// Runs when the up-to-date alert's Version History button is clicked (#416).
    var onShowVersionHistory: (() -> Void)? { get set }
    func start()
    func checkNow()
    func setAutomaticallyChecks(_ enabled: Bool)
    func installationSafetyDidChange()
    func restartWhenSafe()
}

@MainActor
final class DisabledUpdateController: UpdateControlling {
    private(set) var snapshot: UpdateSnapshot
    var onChange: ((UpdateSnapshot) -> Void)?
    var onShowVersionHistory: (() -> Void)?

    init(reason: String) {
        snapshot = UpdateSnapshot(
            status: .unavailable(reason),
            automaticallyChecks: false,
            canCheck: false,
            canRestart: false
        )
    }

    func start() {}
    func checkNow() {}
    func setAutomaticallyChecks(_ enabled: Bool) {}
    func installationSafetyDidChange() {}
    func restartWhenSafe() {}
}

@MainActor
final class UpdateInstallationSafetyPolicy {
    static let shared = UpdateInstallationSafetyPolicy()
    private(set) var dictationPhase: DictationPhase = .idle
    private(set) var activeCriticalOperations: Set<ApplicationCriticalOperation> = []
    var isSafeToInstall: Bool {
        activeCriticalOperations.isEmpty && !dictationPhase.blocksUpdateInstallation
    }

    /// What quitting now would lose, for confirming a quit the user asked for. Momentary window
    /// actions and drags matter only to automatic update relaunches, never to a user's quit.
    var quitConfirmationReasons: [String] {
        var reasons: [String] = []
        if activeCriticalOperations.contains(.unsavedWork) {
            reasons.append("The Screenshot Editor has unsaved changes.")
        }
        if dictationPhase.blocksUpdateInstallation {
            reasons.append("Dictation is still in progress.")
        }
        return reasons
    }

    func update(dictationPhase: DictationPhase) {
        self.dictationPhase = dictationPhase
    }

    func updateCriticalOperation(_ operation: ApplicationCriticalOperation, active: Bool) {
        if active { activeCriticalOperations.insert(operation) }
        else { activeCriticalOperations.remove(operation) }
    }

    func performSynchronousCriticalOperation(
        _ criticalOperation: ApplicationCriticalOperation,
        notify: () -> Void,
        operation: () -> Void
    ) {
        updateCriticalOperation(criticalOperation, active: true)
        notify()
        defer {
            updateCriticalOperation(criticalOperation, active: false)
            notify()
        }
        operation()
    }
}

enum ApplicationCriticalOperation: Hashable {
    case windowAction
    case windowDrag
    case unsavedWork
}

extension DictationPhase {
    var blocksUpdateInstallation: Bool {
        switch self {
        case .idle, .failed: false
        case .recording, .transcribing, .inserting: true
        }
    }
}

enum ScheduledUpdatePresentationPolicy {
    static let usesSparkleStandardDriver = true
}

enum UpdateTelemetryStage: String, Equatable {
    case started, checking, available, downloading, downloaded, ready, deferred, current, failed
}

struct UpdateTelemetryEvent: Equatable {
    let stage: UpdateTelemetryStage
    let version: String?
    let build: String
    let elapsedMilliseconds: Int
    let failureCategory: String?
}

protocol UpdateEventRecording {
    func record(_ event: UpdateTelemetryEvent)
}

struct OSLogUpdateEventRecorder: UpdateEventRecording {
    private let logger = Logger(subsystem: "com.serp.keybumps", category: "updates")
    func record(_ event: UpdateTelemetryEvent) {
        logger.info("stage=\(event.stage.rawValue, privacy: .public) version=\(event.version ?? "none", privacy: .public) build=\(event.build, privacy: .public) elapsed_ms=\(event.elapsedMilliseconds, privacy: .public) failure=\(event.failureCategory ?? "none", privacy: .public)")
    }
}

final class UpdateTelemetry {
    private let recorder: any UpdateEventRecording
    private let build: String
    private let now: () -> TimeInterval
    private let startedAt: TimeInterval

    init(
        recorder: any UpdateEventRecording = OSLogUpdateEventRecorder(),
        build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.recorder = recorder
        self.build = build
        self.now = now
        self.startedAt = now()
    }

    func record(_ stage: UpdateTelemetryStage, version: String? = nil, failureCategory: String? = nil) {
        recorder.record(UpdateTelemetryEvent(
            stage: stage,
            version: version,
            build: build,
            elapsedMilliseconds: max(0, Int((now() - startedAt) * 1_000)),
            failureCategory: failureCategory
        ))
    }
}

@MainActor
final class SafeUpdateInstallCoordinator {
    private let safetyPolicy: UpdateInstallationSafetyPolicy
    private var immediateInstallHandler: (() -> Void)?
    private var postponedRelaunchHandler: (() -> Void)?
    private var version: String?
    var onStatusChange: ((UpdateStatus) -> Void)?

    init(safetyPolicy: UpdateInstallationSafetyPolicy) {
        self.safetyPolicy = safetyPolicy
    }

    var hasCallableRestart: Bool { immediateInstallHandler != nil }

    func recordDownloaded(version: String) {
        self.version = version
        onStatusChange?(.downloaded(version: version))
    }

    func captureImmediateInstall(version: String, handler: @escaping () -> Void) {
        self.version = version
        immediateInstallHandler = handler
        publishReadyState()
    }

    func shouldPostponeRelaunch(version: String, handler: @escaping () -> Void) -> Bool {
        guard !safetyPolicy.isSafeToInstall else { return false }
        self.version = version
        postponedRelaunchHandler = handler
        onStatusChange?(.deferred(version: version))
        return true
    }

    func safetyDidChange() {
        guard version != nil else { return }
        if safetyPolicy.isSafeToInstall, let postponedRelaunchHandler {
            self.postponedRelaunchHandler = nil
            postponedRelaunchHandler()
            return
        }
        guard immediateInstallHandler != nil || postponedRelaunchHandler != nil else { return }
        publishReadyState()
    }

    @discardableResult
    func restartWhenSafe() -> Bool {
        guard let immediateInstallHandler else { return false }
        guard safetyPolicy.isSafeToInstall else {
            if let version { onStatusChange?(.deferred(version: version)) }
            return false
        }
        immediateInstallHandler()
        return true
    }

    func reset() {
        immediateInstallHandler = nil
        postponedRelaunchHandler = nil
        version = nil
    }

    private func publishReadyState() {
        guard let version else { return }
        onStatusChange?(
            safetyPolicy.isSafeToInstall
                ? .readyToRestart(version: version)
                : .deferred(version: version)
        )
    }
}
