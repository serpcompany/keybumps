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
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .screenRecording: "Screen Recording"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility: "Lets Window Manager resize other apps, Dictation return text to the original cursor, Snippets expand keywords, and ⌘P in the Command Palette paste into the app you’re using."
        case .inputMonitoring: "Lets Shortcut Coach recognize supported mouse and keyboard actions outside Keybumps, Snippets notice when you type a keyword, and Keystrokes show the shortcuts you press."
        case .microphone: "Lets Dictation record only while its recording indicator is visible."
        case .speechRecognition: "Lets Apple transcribe Dictation locally on this Mac."
        case .screenRecording: "Lets Screenshot Tools take screenshots with its hotkeys."
        }
    }

    var settingsURL: URL { SystemSettingsPage.privacy(self).url }

    var usesApplicationDragAssistant: Bool {
        self == .accessibility || self == .inputMonitoring
    }

    /// The permissions' titles as one phrase: "Accessibility", "Microphone and Speech Recognition",
    /// or "Accessibility, Microphone, and Speech Recognition".
    static func names(_ permissions: [MacPermission]) -> String {
        let titles = permissions.map(\.title)
        guard let last = titles.last else { return "" }
        switch titles.count {
        case 1: return last
        case 2: return "\(titles[0]) and \(last)"
        default: return titles.dropLast().joined(separator: ", ") + ", and " + last
        }
    }
}

/// Every System Settings page Keybumps opens. They open only through `PermissionCoordinator`,
/// whose opener is `PermissionPrompts.current` and inert in the unit-test host.
enum SystemSettingsPage: Equatable {
    case privacy(MacPermission)
    case filesAndFolders
    case keyboardShortcuts
    /// Language & Region, where Translation Languages are downloaded (#322).
    case languageAndRegion

    var url: URL {
        let address = switch self {
        case .privacy(let permission):
            "x-apple.systempreferences:com.apple.preference.security?\(Self.privacyAnchor(for: permission))"
        case .filesAndFolders:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        case .keyboardShortcuts:
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts"
        case .languageAndRegion:
            "x-apple.systempreferences:com.apple.Localization-Settings.extension"
        }
        return URL(string: address)!
    }

    private static func privacyAnchor(for permission: MacPermission) -> String {
        switch permission {
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .screenRecording: "Privacy_ScreenCapture"
        }
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
    /// Opened from a setup card, over another app. Kept out of `didBecomeActive`, so Keybumps
    /// becoming active later never turns it into a relaunch; only a grant clears it.
    private var permissionsOpenedFromCard: Set<MacPermission> = []
    private(set) var permissionsRequiringRelaunch: [MacPermission] = []

    /// Whether System Settings was opened for `permission` and it isn't usable yet. That's no
    /// evidence it was turned on, so it never counts as needing a relaunch by itself.
    func hasOpenedSystemSettings(for permission: MacPermission) -> Bool {
        permissionsOpenedFromCard.contains(permission)
            || permissionsAwaitingReturn.contains(permission)
            || permissionsRequiringRelaunch.contains(permission)
    }

    /// A setup card opened System Settings. Only `hasOpenedSystemSettings` reads this.
    mutating func didOpenSystemSettingsFromCard(for permission: MacPermission) {
        guard permission.usesApplicationDragAssistant else { return }
        permissionsOpenedFromCard.insert(permission)
    }

    /// Keybumps' own Settings window opened System Settings; Keybumps becoming active checks it.
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
        permissionsOpenedFromCard.remove(permission)
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
        case .accessibility, .inputMonitoring, .microphone, .speechRecognition, .screenRecording:
            return .recoverInSystemSettings
        }
    }
}

struct PermissionReadinessSnapshot: Equatable {
    let requiredPermissions: [MacPermission]
    let states: [MacPermission: PermissionAuthorizationState]
    let permissionsRequiringRelaunch: Set<MacPermission>

    var missingPermissions: [MacPermission] {
        requiredPermissions.filter {
            state(for: $0) != .granted || permissionsRequiringRelaunch.contains($0)
        }
    }

    var currentPermission: MacPermission? { missingPermissions.first }
    var missingCount: Int { missingPermissions.count }
    var totalCount: Int { requiredPermissions.count }
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
        permissionsRequiringRelaunch: Set<MacPermission>
    ) -> PermissionReadinessSnapshot {
        PermissionReadinessSnapshot(
            requiredPermissions: PermissionSetupPlan.requiredPermissions(for: enabledCapabilities),
            states: states,
            permissionsRequiringRelaunch: permissionsRequiringRelaunch
        )
    }
}

enum PermissionSetupPlan {
    static func requiredPermissions(for enabledCapabilities: Set<Capability>) -> [MacPermission] {
        CapabilityCatalog.requiredPermissions(for: enabledCapabilities)
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
    private(set) var screenRecordingState: PermissionAuthorizationState = .required
    private(set) var activeRequest: MacPermission?
    private let accessibilityTrusted: () -> Bool
    private let inputMonitoringAuthorized: () -> Bool
    private let microphoneAuthorizationStatus: () -> AVAuthorizationStatus
    private let speechAuthorizationStatus: () -> SFSpeechRecognizerAuthorizationStatus
    private let screenRecordingAuthorized: () -> Bool
    private let requestMicrophone: () async -> Void
    private let requestSpeechRecognition: () async -> Void
    private let requestScreenRecording: () -> Void
    private let openSettingsAction: (MacPermission) -> Void
    private let openSystemSettingsAction: (SystemSettingsPage) -> Void

    var accessibilityGranted: Bool { accessibilityState.isGranted }
    var inputMonitoringGranted: Bool { inputMonitoringState.isGranted }
    var microphoneGranted: Bool { microphoneState.isGranted }
    var speechGranted: Bool { speechState.isGranted }
    var screenRecordingGranted: Bool { screenRecordingState.isGranted }

    /// Asks macOS for Screen Recording, which can open System Settings. Only the first screenshot
    /// hotkey without access calls this directly; recovery calls it through `performRecovery`.
    func requestScreenRecordingAccess() { requestScreenRecording() }

    /// The state readers are silent preflights. The request and open closures are the only way
    /// Keybumps shows a macOS permission prompt or opens System Settings; they default to
    /// `PermissionPrompts.current`, which is inert in the unit-test host.
    init(
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        inputMonitoringAuthorized: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        microphoneAuthorizationStatus: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        speechAuthorizationStatus: @escaping () -> SFSpeechRecognizerAuthorizationStatus = {
            SFSpeechRecognizer.authorizationStatus()
        },
        screenRecordingAuthorized: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestMicrophone: @escaping () async -> Void = PermissionPrompts.current.requestMicrophone,
        requestSpeechRecognition: @escaping () async -> Void = PermissionPrompts.current.requestSpeechRecognition,
        requestScreenRecording: @escaping () -> Void = PermissionPrompts.current.requestScreenRecording,
        openSettings: @escaping (MacPermission) -> Void = { PermissionPrompts.current.openSystemSettings(.privacy($0)) },
        openSystemSettings: @escaping (SystemSettingsPage) -> Void = PermissionPrompts.current.openSystemSettings
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringAuthorized = inputMonitoringAuthorized
        self.microphoneAuthorizationStatus = microphoneAuthorizationStatus
        self.speechAuthorizationStatus = speechAuthorizationStatus
        self.screenRecordingAuthorized = screenRecordingAuthorized
        self.requestMicrophone = requestMicrophone
        self.requestSpeechRecognition = requestSpeechRecognition
        self.requestScreenRecording = requestScreenRecording
        self.openSettingsAction = openSettings
        self.openSystemSettingsAction = openSystemSettings
        refresh()
    }

    func refresh() {
        accessibilityState = accessibilityTrusted() ? .granted : .required
        inputMonitoringState = inputMonitoringAuthorized() ? .granted : .required
        microphoneState = Self.state(for: microphoneAuthorizationStatus())
        speechState = Self.state(for: speechAuthorizationStatus())
        screenRecordingState = screenRecordingAuthorized() ? .granted : .required
    }

    func state(for permission: MacPermission) -> PermissionAuthorizationState {
        switch permission {
        case .accessibility: accessibilityState
        case .inputMonitoring: inputMonitoringState
        case .microphone: microphoneState
        case .speechRecognition: speechState
        case .screenRecording: screenRecordingState
        }
    }

    func recoveryAction(for permission: MacPermission) -> PermissionRecoveryAction {
        Self.recoveryAction(for: permission, state: state(for: permission))
    }

    static func recoveryAction(for permission: MacPermission, state: PermissionAuthorizationState) -> PermissionRecoveryAction {
        guard state != .granted else { return .none }
        switch permission {
        case .accessibility, .inputMonitoring, .screenRecording:
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
            // Screen Recording lists Keybumps in System Settings only after it has asked once.
            if permission == .screenRecording { requestScreenRecording() }
            openSettings(permission)
        case .request:
            // Only an undecided Microphone or Speech Recognition gets a native prompt.
            switch permission {
            case .microphone:
                await requestMicrophone()
            case .speechRecognition:
                await requestSpeechRecognition()
            case .accessibility, .inputMonitoring, .screenRecording:
                break
            }
            refresh()
        }
    }

    func openSettings(_ permission: MacPermission) {
        openSettingsAction(permission)
    }

    /// Opens a System Settings page that isn't a permission's, such as Keyboard Shortcuts.
    func openSystemSettings(_ page: SystemSettingsPage) {
        openSystemSettingsAction(page)
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
        // Only the real product registers a login item; Debug builds (com.serp.keybumps.debug) never do.
        guard Bundle.main.bundleIdentifier == ProductIdentity.bundleIdentifier else {
            statusText = "Not available in development builds"
            return
        }
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

    /// Read by the unit-test isolation guard.
    let preferences: any SymbolicHotKeyPreferences

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
            && parameters[2].intValue == SymbolicHotKeyModifiers.cocoa(for: binding.modifiers)
        return matches ? .conflict : .noConflict
    }

    private static let manualRecovery = "Open System Settings → Keyboard → Keyboard Shortcuts → Spotlight, turn off Show Spotlight search, then return to Keybumps."
}
