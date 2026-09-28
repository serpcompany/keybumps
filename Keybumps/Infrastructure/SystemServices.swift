import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
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
        case .inputMonitoring: "Lets Keyboard Shortcutter recognize supported mouse and keyboard actions outside Keybumps."
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
            "keybumps-relaunch",
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

enum PermissionSettingsPresentation {
    static let usesDisclosure = false
    static let visiblePermissions = MacPermission.allCases
}

enum PermissionSettingsRowAction: Equatable {
    case restartKeybumps
    case requestAccess
    case recoverInSystemSettings
    case openSystemSettings

    static func resolve(
        permission: MacPermission,
        state: PermissionAuthorizationState,
        requiresRelaunch: Bool
    ) -> PermissionSettingsRowAction {
        if requiresRelaunch { return .restartKeybumps }
        if state.isGranted { return .openSystemSettings }
        switch permission {
        case .microphone where state == .notDetermined, .speechRecognition where state == .notDetermined:
            return .requestAccess
        case .accessibility, .inputMonitoring, .microphone, .speechRecognition:
            return .recoverInSystemSettings
        }
    }
}

struct PermissionReadinessSnapshot: Equatable {
    let requiredPermissions: [MacPermission]
    let states: [MacPermission: PermissionAuthorizationState]
    let permissionsRequiringRelaunch: Set<MacPermission>
    let includesNativeNotifications: Bool
    let notificationAuthorization: NativeNotificationAuthorization

    var missingPermissions: [MacPermission] {
        requiredPermissions.filter {
            state(for: $0) != .granted || permissionsRequiringRelaunch.contains($0)
        }
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
            includesNativeNotifications: enabledCapabilities.contains(.keyboardShortcutter)
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
        if enabledCapabilities.contains(.keyboardShortcutter) {
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
    private let accessibilityTrusted: () -> Bool
    private let inputMonitoringAuthorized: () -> Bool
    private let microphoneAuthorizationStatus: () -> AVAuthorizationStatus
    private let speechAuthorizationStatus: () -> SFSpeechRecognizerAuthorizationStatus
    private let openSettingsAction: (MacPermission) -> Void

    var accessibilityGranted: Bool { accessibilityState.isGranted }
    var inputMonitoringGranted: Bool { inputMonitoringState.isGranted }
    var microphoneGranted: Bool { microphoneState.isGranted }
    var speechGranted: Bool { speechState.isGranted }

    init(
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        inputMonitoringAuthorized: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        microphoneAuthorizationStatus: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        speechAuthorizationStatus: @escaping () -> SFSpeechRecognizerAuthorizationStatus = {
            SFSpeechRecognizer.authorizationStatus()
        },
        openSettings: @escaping (MacPermission) -> Void = { permission in
            _ = NSWorkspace.shared.open(permission.settingsURL)
        }
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringAuthorized = inputMonitoringAuthorized
        self.microphoneAuthorizationStatus = microphoneAuthorizationStatus
        self.speechAuthorizationStatus = speechAuthorizationStatus
        self.openSettingsAction = openSettings
        refresh()
    }

    func refresh() {
        accessibilityState = accessibilityTrusted() ? .granted : .required
        inputMonitoringState = inputMonitoringAuthorized() ? .granted : .required
        microphoneState = Self.state(for: microphoneAuthorizationStatus())
        speechState = Self.state(for: speechAuthorizationStatus())
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
        openSettingsAction(permission)
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

enum SpotlightShortcutConflictStatus: Equatable {
    case noConflict
    case conflict
    case unavailable(manualRecovery: String)
}

enum SpotlightShortcutResolution: Equatable {
    case resolved
    case noLongerConflicting
    case failed(manualRecovery: String)
}

struct QuickSearchShortcutOnboardingPresentation: Equatable {
    let canContinue: Bool
    let manualRecovery: String?

    static func resolve(
        _ status: SpotlightShortcutConflictStatus
    ) -> QuickSearchShortcutOnboardingPresentation {
        switch status {
        case .noConflict:
            QuickSearchShortcutOnboardingPresentation(canContinue: true, manualRecovery: nil)
        case .conflict:
            QuickSearchShortcutOnboardingPresentation(canContinue: false, manualRecovery: nil)
        case .unavailable(let manualRecovery):
            QuickSearchShortcutOnboardingPresentation(
                canContinue: false,
                manualRecovery: manualRecovery
            )
        }
    }
}

protocol SymbolicHotKeyPreferences: AnyObject {
    func readSymbolicHotKeys() throws -> [String: Any]
    func writeSymbolicHotKeys(_ hotKeys: [String: Any]) throws
    func reloadSymbolicHotKeys() throws
}

protocol SpotlightShortcutConflictResolving: AnyObject {
    func status(for binding: ShortcutBinding) -> SpotlightShortcutConflictStatus
    func disableIfConflicting(_ binding: ShortcutBinding) -> SpotlightShortcutResolution
}

enum SymbolicHotKeyPreferencesError: Error {
    case unreadable
    case unsynchronized
    case reloadFailed
}

final class SystemSymbolicHotKeyPreferences: SymbolicHotKeyPreferences {
    private let applicationID = "com.apple.symbolichotkeys" as CFString
    private let preferenceKey = "AppleSymbolicHotKeys" as CFString
    private let settingsActivatorURL = URL(
        fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Versions/A/Resources/activateSettings"
    )

    func readSymbolicHotKeys() throws -> [String: Any] {
        guard let hotKeys = CFPreferencesCopyValue(
            preferenceKey,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] else {
            throw SymbolicHotKeyPreferencesError.unreadable
        }
        return hotKeys
    }

    func writeSymbolicHotKeys(_ hotKeys: [String: Any]) throws {
        CFPreferencesSetValue(
            preferenceKey,
            hotKeys as CFDictionary,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw SymbolicHotKeyPreferencesError.unsynchronized
        }
    }

    func reloadSymbolicHotKeys() throws {
        let process = Process()
        process.executableURL = settingsActivatorURL
        process.arguments = ["-u"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SymbolicHotKeyPreferencesError.reloadFailed
        }
    }
}

final class SpotlightShortcutConflictResolver: SpotlightShortcutConflictResolving {
    private enum Key {
        static let spotlightSearch = "64"
    }

    private let preferences: any SymbolicHotKeyPreferences

    init(preferences: any SymbolicHotKeyPreferences) {
        self.preferences = preferences
    }

    func status(for binding: ShortcutBinding) -> SpotlightShortcutConflictStatus {
        do {
            let hotKeys = try preferences.readSymbolicHotKeys()
            return spotlightStatus(in: hotKeys, binding: binding)
        } catch {
            return .unavailable(manualRecovery: Self.manualRecovery)
        }
    }

    func disableIfConflicting(_ binding: ShortcutBinding) -> SpotlightShortcutResolution {
        do {
            var hotKeys = try preferences.readSymbolicHotKeys()
            switch spotlightStatus(in: hotKeys, binding: binding) {
            case .noConflict:
                return .noLongerConflicting
            case .unavailable:
                return .failed(manualRecovery: Self.manualRecovery)
            case .conflict:
                break
            }
            guard var spotlight = hotKeys[Key.spotlightSearch] as? [String: Any] else {
                return .failed(manualRecovery: Self.manualRecovery)
            }
            spotlight["enabled"] = false
            hotKeys[Key.spotlightSearch] = spotlight
            try preferences.writeSymbolicHotKeys(hotKeys)
            try preferences.reloadSymbolicHotKeys()
            return .resolved
        } catch {
            return .failed(manualRecovery: Self.manualRecovery)
        }
    }

    private func spotlightStatus(
        in hotKeys: [String: Any],
        binding: ShortcutBinding
    ) -> SpotlightShortcutConflictStatus {
        guard let spotlight = hotKeys[Key.spotlightSearch] as? [String: Any],
              let enabled = spotlight["enabled"] as? NSNumber else {
            return .unavailable(manualRecovery: Self.manualRecovery)
        }
        guard enabled.boolValue else { return .noConflict }
        guard
            let value = spotlight["value"] as? [String: Any],
            value["type"] as? String == "standard",
            let parameters = value["parameters"] as? [NSNumber],
            parameters.count >= 3
        else { return .unavailable(manualRecovery: Self.manualRecovery) }

        let matches = parameters[1].uint32Value == binding.keyCode
            && parameters[2].intValue == cocoaModifiers(for: binding.modifiers)
        return matches ? .conflict : .noConflict
    }

    private func cocoaModifiers(for carbonModifiers: UInt32) -> Int {
        var modifiers = 0
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.command.rawValue) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.shift.rawValue) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.option.rawValue) }
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.control.rawValue) }
        return modifiers
    }

    private static let manualRecovery = "Open System Settings → Keyboard → Keyboard Shortcuts → Spotlight, turn off Show Spotlight search, then return to Keybumps."
}
