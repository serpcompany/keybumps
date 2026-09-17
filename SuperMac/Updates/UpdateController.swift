import Foundation

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
        case .current: "SuperMac is up to date"
        case .failed(let message): message
        }
    }

}

struct UpdateSnapshot: Equatable {
    var status: UpdateStatus
    var automaticallyChecks: Bool
    var canCheck: Bool
    var canRestart: Bool
}

@MainActor
protocol UpdateControlling: AnyObject {
    var snapshot: UpdateSnapshot { get }
    var onChange: ((UpdateSnapshot) -> Void)? { get set }
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
    var isSafeToInstall: Bool {
        switch dictationPhase {
        case .idle, .failed: true
        case .recording, .transcribing, .inserting: false
        }
    }

    func update(dictationPhase: DictationPhase) {
        self.dictationPhase = dictationPhase
    }
}

enum ReleaseVersionValidation {
    static func isMonotonicallyIncreasing(previousBuild: String, candidateBuild: String) -> Bool {
        guard let previous = Int(previousBuild),
              let candidate = Int(candidateBuild) else {
            return false
        }
        return candidate > previous
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
        guard let version else { return }
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
