import Foundation

enum UpdateStatus: Equatable {
    case unavailable(String)
    case idle
    case checking
    case available(version: String)
    case downloading(version: String)
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
        case .readyToRestart(let version): "Version \(version) is ready to install"
        case .deferred(let version): "Version \(version) will install when Dictation is idle"
        case .current: "SuperMac is up to date"
        case .failed(let message): message
        }
    }

    var readyVersion: String? {
        switch self {
        case .readyToRestart(let version), .deferred(let version): version
        default: nil
        }
    }
}

struct UpdateSnapshot: Equatable {
    var status: UpdateStatus
    var automaticallyChecks: Bool
    var canCheck: Bool
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
            canCheck: false
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

@MainActor
final class ApplicationTerminationGuard {
    static let shared = ApplicationTerminationGuard()
    private(set) var isSafeToTerminate = true

    func update(dictationPhase: DictationPhase) {
        switch dictationPhase {
        case .idle, .failed: isSafeToTerminate = true
        case .recording, .transcribing, .inserting: isSafeToTerminate = false
        }
    }
}
