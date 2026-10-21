import Testing
@testable import Keybumps

/// What a permission row in Settings shows, on the Permissions page and on plugin pages (#559):
/// a short button while something needs doing, none once granted, and the full name for VoiceOver.
@MainActor
@Suite("Permission rows")
struct PermissionRowTests {
    private static func button(
        _ permission: MacPermission,
        _ state: PermissionAuthorizationState,
        requiresRelaunch: Bool = false
    ) -> PermissionRowButton? {
        PermissionSettingsRowAction.resolve(permission: permission, state: state, requiresRelaunch: requiresRelaunch)
            .button(for: permission)
    }

    @Test("A granted row shows only Granted, with no button")
    func grantedHasNoButton() {
        for permission in MacPermission.allCases {
            #expect(PermissionSettingsRowAction.resolve(permission: permission, state: .granted, requiresRelaunch: false) == .granted)
            #expect(Self.button(permission, .granted) == nil, "\(permission.title)")
            #expect(PermissionRow.status(.granted, requiresRelaunch: false, isOptional: false) == "Granted")
            #expect(PermissionRow.status(.granted, requiresRelaunch: false, isOptional: true) == "Granted")
        }
    }

    @Test("A missing permission shows Allow…, and VoiceOver hears Allow and the permission's name")
    func missingShowsAllow() {
        for permission in MacPermission.allCases {
            for state in [PermissionAuthorizationState.notDetermined, .required, .denied, .restricted] {
                let button = Self.button(permission, state)
                #expect(button?.title == "Allow…", "\(permission.title) \(state.rawValue)")
                #expect(button?.accessibilityLabel == "Allow \(permission.title)", "\(permission.title) \(state.rawValue)")
            }
        }
    }

    @Test("Allow… keeps what it did: a native prompt before the first answer, else System Settings, which VoiceOver names")
    func allowKeepsItsAction() {
        #expect(PermissionSettingsRowAction.resolve(permission: .microphone, state: .notDetermined, requiresRelaunch: false) == .requestAccess)
        #expect(Self.button(.microphone, .notDetermined)
            == PermissionRowButton(title: "Allow…", accessibilityLabel: "Allow Microphone"), "the prompt asks in place")
        #expect(Self.button(.speechRecognition, .notDetermined)?.accessibilityHint == nil)

        #expect(PermissionSettingsRowAction.resolve(permission: .accessibility, state: .required, requiresRelaunch: false) == .recoverInSystemSettings)
        #expect(Self.button(.accessibility, .required) == PermissionRowButton(
            title: "Allow…",
            accessibilityLabel: "Allow Accessibility",
            accessibilityHint: "Open System Settings for Accessibility"
        ))
        #expect(Self.button(.microphone, .denied)?.accessibilityHint == "Open System Settings for Microphone")
        #expect(Self.button(.screenRecording, .required)?.accessibilityHint == "Open System Settings for Screen Recording")
    }

    @Test("While macOS needs a restart to apply a permission, the row shows Restart, which VoiceOver reads as Restart Keybumps")
    func restart() {
        for state in [PermissionAuthorizationState.granted, .required] {
            #expect(PermissionSettingsRowAction.resolve(permission: .inputMonitoring, state: state, requiresRelaunch: true) == .restartKeybumps)
            #expect(Self.button(.inputMonitoring, state, requiresRelaunch: true)
                == PermissionRowButton(title: "Restart", accessibilityLabel: "Restart Keybumps"))
        }
        #expect(PermissionRow.status(.granted, requiresRelaunch: true, isOptional: false) == "Restart Required")
    }

    @Test("A missing permission's status says what's wrong; an optional one reads Not Granted")
    func missingStatus() {
        #expect(PermissionRow.status(.required, requiresRelaunch: false, isOptional: false) == "Required")
        #expect(PermissionRow.status(.denied, requiresRelaunch: false, isOptional: false) == "Denied")
        #expect(PermissionRow.status(.notDetermined, requiresRelaunch: false, isOptional: false) == "Not Requested")
        #expect(PermissionRow.status(.required, requiresRelaunch: false, isOptional: true) == "Not Granted")
    }
}
