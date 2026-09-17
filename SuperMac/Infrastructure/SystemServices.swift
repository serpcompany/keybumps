import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import Observation
import ServiceManagement
import Speech

enum MacPermission: String, CaseIterable, Identifiable, Hashable {
    case accessibility
    case inputMonitoring
    case microphone
    case speechRecognition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility: "Lets Window Management resize other apps and lets Dictation return text to the original cursor."
        case .inputMonitoring: "Lets Key Bumps recognize supported mouse and keyboard actions outside SuperMac."
        case .microphone: "Lets Dictation record only while its recording indicator is visible."
        case .speechRecognition: "Lets Apple transcribe Dictation locally on this Mac."
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    var usesApplicationDragAssistant: Bool {
        self == .accessibility || self == .inputMonitoring
    }
}

enum PermissionAuthorizationState: String, Equatable {
    case notDetermined = "Not Requested"
    case required = "Required"
    case denied = "Denied"
    case restricted = "Restricted"
    case granted = "Granted"

    var isGranted: Bool { self == .granted }
}

enum PermissionRecoveryAction: Equatable {
    case none
    case request
    case openSystemSettings

    var buttonTitle: String? {
        switch self {
        case .none: nil
        case .request: "Request Access…"
        case .openSystemSettings: "Open System Settings…"
        }
    }
}

enum PermissionRecoveryPresentation: Equatable {
    case none
    case nativePrompt
    case applicationDrag
    case enableSwitch

    static func resolve(
        permission: MacPermission,
        action: PermissionRecoveryAction
    ) -> PermissionRecoveryPresentation {
        switch action {
        case .none:
            .none
        case .request:
            .nativePrompt
        case .openSystemSettings:
            permission.usesApplicationDragAssistant ? .applicationDrag : .enableSwitch
        }
    }
}

struct PermissionRelaunchAdvisor {
    private var permissionsAwaitingReturn: [MacPermission] = []
    private(set) var permissionsRequiringRelaunch: [MacPermission] = []

    mutating func didOpenSystemSettings(for permission: MacPermission) {
        guard permission.usesApplicationDragAssistant else { return }
        if !permissionsAwaitingReturn.contains(where: { $0 == permission }) {
            permissionsAwaitingReturn.append(permission)
        }
        permissionsRequiringRelaunch.removeAll(where: { $0 == permission })
    }

    mutating func didBecomeActive(
        state: (MacPermission) -> PermissionAuthorizationState
    ) {
        for permission in permissionsAwaitingReturn {
            if state(permission).isGranted {
                permissionsRequiringRelaunch.removeAll(where: { $0 == permission })
            } else if !permissionsRequiringRelaunch.contains(where: { $0 == permission }) {
                permissionsRequiringRelaunch.append(permission)
            }
        }
        permissionsAwaitingReturn.removeAll()
    }

    mutating func permissionDidBecomeUsable(_ permission: MacPermission) {
        permissionsAwaitingReturn.removeAll(where: { $0 == permission })
        permissionsRequiringRelaunch.removeAll(where: { $0 == permission })
    }
}

struct PermissionRelaunchPlan {
    let executableURL = URL(fileURLWithPath: "/bin/sh")
    let arguments: [String]

    init(bundleURL: URL, processIdentifier: pid_t) {
        let script = """
        attempts=0
        while kill -0 "$1" 2>/dev/null; do
          attempts=$((attempts + 1))
          [ "$attempts" -ge 150 ] && exit 1
          sleep 0.1
        done
        exec /usr/bin/open -n "$2"
        """
        arguments = [
            "-c",
            script,
            "supermac-relaunch",
            String(processIdentifier),
            bundleURL.path
        ]
    }
}

enum PermissionRelauncher {
    static func schedule(
        bundleURL: URL = Bundle.main.bundleURL,
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let plan = PermissionRelaunchPlan(
            bundleURL: bundleURL,
            processIdentifier: processIdentifier
        )
        let helper = Process()
        helper.executableURL = plan.executableURL
        helper.arguments = plan.arguments
        try helper.run()
    }
}

struct PermissionSetupProgress: Equatable {
    let requiredPermissions: [MacPermission]
    let grantedPermissions: [MacPermission]

    var currentPermission: MacPermission? {
        requiredPermissions.first { !grantedPermissions.contains($0) }
    }

    var completedCount: Int { grantedPermissions.count }
    var totalCount: Int { requiredPermissions.count }
    var isComplete: Bool { currentPermission == nil }
}

struct PermissionReadinessSnapshot: Equatable {
    let requiredPermissions: [MacPermission]
    let states: [MacPermission: PermissionAuthorizationState]
    let permissionsRequiringRelaunch: Set<MacPermission>
    let includesNativeNotifications: Bool
    let notificationAuthorization: NativeNotificationAuthorization

    var missingPermissions: [MacPermission] {
        requiredPermissions.filter { state(for: $0) != .granted }
    }

    var currentPermission: MacPermission? { missingPermissions.first }
    var nativeNotificationNeedsAttention: Bool {
        includesNativeNotifications && !notificationAuthorization.canPresentAlerts
    }
    var missingCount: Int {
        missingPermissions.count + (nativeNotificationNeedsAttention ? 1 : 0)
    }
    var totalCount: Int { requiredPermissions.count + (includesNativeNotifications ? 1 : 0) }
    var completedCount: Int { totalCount - missingCount }
    var isReady: Bool { missingCount == 0 }

    func state(for permission: MacPermission) -> PermissionAuthorizationState {
        states[permission] ?? .required
    }

    func requiresRelaunch(_ permission: MacPermission) -> Bool {
        permissionsRequiringRelaunch.contains(permission)
    }

    static func resolve(
        enabledCapabilities: Set<Capability>,
        states: [MacPermission: PermissionAuthorizationState],
        permissionsRequiringRelaunch: Set<MacPermission>,
        selectedChannels: Set<NotificationChannel>,
        notificationAuthorization: NativeNotificationAuthorization
    ) -> PermissionReadinessSnapshot {
        PermissionReadinessSnapshot(
            requiredPermissions: PermissionSetupPlan.requiredPermissions(for: enabledCapabilities),
            states: states,
            permissionsRequiringRelaunch: permissionsRequiringRelaunch,
            includesNativeNotifications: enabledCapabilities.contains(.shortcutCoaching)
                && selectedChannels.contains(.nativeBanner),
            notificationAuthorization: notificationAuthorization
        )
    }
}

enum PermissionSetupPlan {
    static func requiredPermissions(for enabledCapabilities: Set<Capability>) -> [MacPermission] {
        var required: Set<MacPermission> = []
        if enabledCapabilities.contains(.dictation) {
            required.formUnion([.microphone, .speechRecognition])
        }
        if enabledCapabilities.contains(.windowManagement) {
            required.insert(.accessibility)
        }
        if enabledCapabilities.contains(.shortcutCoaching) {
            required.formUnion([.accessibility, .inputMonitoring])
        }
        return MacPermission.allCases.filter(required.contains)
    }

    static func progress(
        for enabledCapabilities: Set<Capability>,
        state: (MacPermission) -> PermissionAuthorizationState
    ) -> PermissionSetupProgress {
        let required = requiredPermissions(for: enabledCapabilities)
        return PermissionSetupProgress(
            requiredPermissions: required,
            grantedPermissions: required.filter { state($0).isGranted }
        )
    }
}

@MainActor @Observable
final class PermissionCoordinator {
    private(set) var accessibilityState: PermissionAuthorizationState = .required
    private(set) var inputMonitoringState: PermissionAuthorizationState = .required
    private(set) var microphoneState: PermissionAuthorizationState = .notDetermined
    private(set) var speechState: PermissionAuthorizationState = .notDetermined
    private(set) var activeRequest: MacPermission?

    var accessibilityGranted: Bool { accessibilityState.isGranted }
    var inputMonitoringGranted: Bool { inputMonitoringState.isGranted }
    var microphoneGranted: Bool { microphoneState.isGranted }
    var speechGranted: Bool { speechState.isGranted }

    init() { refresh() }

    func refresh() {
        accessibilityState = AXIsProcessTrusted() ? .granted : .required
        inputMonitoringState = CGPreflightListenEventAccess() ? .granted : .required
        microphoneState = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        speechState = Self.state(for: SFSpeechRecognizer.authorizationStatus())
    }

    func state(for permission: MacPermission) -> PermissionAuthorizationState {
        switch permission {
        case .accessibility: accessibilityState
        case .inputMonitoring: inputMonitoringState
        case .microphone: microphoneState
        case .speechRecognition: speechState
        }
    }

    func recoveryAction(for permission: MacPermission) -> PermissionRecoveryAction {
        Self.recoveryAction(for: permission, state: state(for: permission))
    }

    static func recoveryAction(for permission: MacPermission, state: PermissionAuthorizationState) -> PermissionRecoveryAction {
        guard state != .granted else { return .none }
        switch permission {
        case .accessibility, .inputMonitoring:
            return .openSystemSettings
        case .microphone, .speechRecognition:
            return state == .notDetermined ? .request : .openSystemSettings
        }
    }

    func performRecovery(for permission: MacPermission) async {
        guard activeRequest == nil else { return }
        activeRequest = permission
        defer { activeRequest = nil }

        switch recoveryAction(for: permission) {
        case .none:
            break
        case .openSystemSettings:
            openSettings(permission)
        case .request:
            switch permission {
            case .microphone:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .speechRecognition:
                await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
                }
            case .accessibility, .inputMonitoring:
                break
            }
            refresh()
        }
    }

    func openSettings(_ permission: MacPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    private static func state(for status: AVAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    private static func state(for status: SFSpeechRecognizerAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

@MainActor @Observable
final class LaunchAtLoginController {
    private(set) var statusText = "Not checked"
    func setEnabled(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refresh() }
        catch { statusText = error.localizedDescription }
    }
    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: statusText = "Enabled"
        case .requiresApproval: statusText = "Needs approval in System Settings"
        case .notRegistered: statusText = "Disabled"
        case .notFound: statusText = "Unavailable from this build location"
        @unknown default: statusText = "Unknown"
        }
    }
}

enum ReferenceApp: String, CaseIterable, Identifiable {
    case alfred = "com.runningwithcrayons.Alfred", rectangle = "com.knollsoft.Rectangle", superwhisper = "com.superduper.superwhisper"
    var id: String { rawValue }
    var name: String { switch self { case .alfred: "Alfred"; case .rectangle: "Rectangle"; case .superwhisper: "Superwhisper" } }
}

@MainActor @Observable
final class ConflictDetector {
    private(set) var runningBundleIdentifiers: Set<String> = []

    init() { refresh() }

    func refresh() {
        runningBundleIdentifiers = Set(ReferenceApp.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty }.map(\.rawValue))
    }

    func isRunning(_ reference: ReferenceApp) -> Bool { runningBundleIdentifiers.contains(reference.rawValue) }

    func quit(_ reference: ReferenceApp) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: reference.rawValue) { app.terminate() }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
        }
    }
}
