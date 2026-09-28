import AVFoundation
import Speech
import XCTest
@testable import Keybumps

/// Locks the Microphone revoke → recover → re-grant flow verified by the owner (#56).
/// macOS may keep reporting `.authorized` to a running process after access is revoked;
/// the coordinator must never cache on its own, so the first refresh that sees the new
/// status (after relaunch, or whenever macOS reports it) drives every surface below.
@MainActor
final class MicrophonePermissionFlowTests: XCTestCase {
    private var microphone: AVAuthorizationStatus = .authorized
    private var opened: [MacPermission] = []

    private func makeCoordinator() -> PermissionCoordinator {
        PermissionCoordinator(
            accessibilityTrusted: { true },
            inputMonitoringAuthorized: { true },
            microphoneAuthorizationStatus: { [unowned self] in microphone },
            speechAuthorizationStatus: { .authorized },
            openSettings: { [unowned self] in opened.append($0) }
        )
    }

    private func readiness(_ coordinator: PermissionCoordinator) -> PermissionReadinessSnapshot {
        PermissionReadinessSnapshot.resolve(
            enabledCapabilities: [.dictation],
            states: Dictionary(uniqueKeysWithValues: MacPermission.allCases.map { ($0, coordinator.state(for: $0)) }),
            permissionsRequiringRelaunch: [],
            selectedChannels: [],
            notificationAuthorization: .authorized
        )
    }

    func testEveryMicrophoneStatusMapsToATruthfulState() {
        let expectations: [(AVAuthorizationStatus, PermissionAuthorizationState)] = [
            (.authorized, .granted), (.notDetermined, .notDetermined), (.denied, .denied), (.restricted, .restricted)
        ]
        let coordinator = makeCoordinator()
        for (status, state) in expectations {
            microphone = status
            coordinator.refresh()
            XCTAssertEqual(coordinator.state(for: .microphone), state, "\(status.rawValue)")
            XCTAssertEqual(coordinator.microphoneGranted, state == .granted)
        }
    }

    func testRevokedMicrophoneIsReportedOnTheNextRefreshWithoutCaching() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.state(for: .microphone), .granted)

        microphone = .denied
        XCTAssertEqual(coordinator.state(for: .microphone), .granted, "state changes only on refresh")
        coordinator.refresh()
        XCTAssertEqual(coordinator.state(for: .microphone), .denied)
    }

    func testDeniedMicrophoneShowsDeniedAndRecoversInSystemSettings() async {
        microphone = .denied
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.state(for: .microphone).rawValue, "Denied")
        XCTAssertEqual(coordinator.recoveryAction(for: .microphone), .openSystemSettings)
        XCTAssertEqual(
            PermissionSettingsRowAction.resolve(permission: .microphone, state: coordinator.state(for: .microphone), requiresRelaunch: false),
            .recoverInSystemSettings,
            "Request Access would do nothing: macOS will not prompt again"
        )

        await coordinator.performRecovery(for: .microphone)
        XCTAssertEqual(opened, [.microphone])
        XCTAssertTrue(MacPermission.microphone.settingsURL.absoluteString.hasSuffix("Privacy_Microphone"))
    }

    func testRestrictedMicrophoneAlsoRecoversInSystemSettings() {
        microphone = .restricted
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.recoveryAction(for: .microphone), .openSystemSettings)
        XCTAssertEqual(
            PermissionSettingsRowAction.resolve(permission: .microphone, state: .restricted, requiresRelaunch: false),
            .recoverInSystemSettings
        )
    }

    func testUndecidedMicrophoneStillUsesTheNativePrompt() {
        microphone = .notDetermined
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.recoveryAction(for: .microphone), .request)
        XCTAssertEqual(
            PermissionSettingsRowAction.resolve(permission: .microphone, state: .notDetermined, requiresRelaunch: false),
            .requestAccess
        )
    }

    func testDeniedMicrophoneBlocksDictationAndFlagsAttentionUntilRegranted() {
        microphone = .denied
        let coordinator = makeCoordinator()
        var snapshot = readiness(coordinator)
        XCTAssertEqual(snapshot.missingPermissions, [.microphone])
        XCTAssertEqual(snapshot.missingCount, 1, "drives the Settings and Dock attention badges")
        XCTAssertEqual(DictationShortcutRouting.action(phase: .idle, missingPermissions: snapshot.missingPermissions), .showPermissionSetup)
        XCTAssertEqual(DictationShortcutRouting.action(phase: .failed("Microphone unavailable"), missingPermissions: snapshot.missingPermissions), .showPermissionSetup)

        microphone = .authorized
        coordinator.refresh()
        snapshot = readiness(coordinator)
        XCTAssertTrue(snapshot.isReady)
        XCTAssertEqual(DictationShortcutRouting.action(phase: .idle, missingPermissions: snapshot.missingPermissions), .toggleDictation)
        XCTAssertEqual(coordinator.recoveryAction(for: .microphone), .none)
        XCTAssertEqual(
            PermissionSettingsRowAction.resolve(permission: .microphone, state: coordinator.state(for: .microphone), requiresRelaunch: false),
            .openSystemSettings
        )
    }

    func testAnActiveDictationCanAlwaysBeStopped() {
        for phase in [DictationPhase.recording, .transcribing, .inserting] {
            XCTAssertEqual(DictationShortcutRouting.action(phase: phase, missingPermissions: [.microphone]), .toggleDictation)
        }
    }
}
