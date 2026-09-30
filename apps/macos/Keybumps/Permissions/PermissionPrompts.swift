import AppKit
import AVFoundation
import CoreGraphics
import Speech

/// Every macOS permission prompt Keybumps can show, plus opening System Settings for recovery.
///
/// Only `PermissionCoordinator`'s explicit request paths call these: Request Access… and the setup
/// walkthrough for Microphone and Speech Recognition while macOS hasn't asked yet, and Screen
/// Recording's Allow… and first screenshot hotkey. macOS shows each native prompt at most once for
/// an app identity.
///
/// Accessibility and Input Monitoring have no prompt here. They recover only through System
/// Settings and the drag card, and nothing in Keybumps asks macOS to prompt for them. Posting
/// keyboard events without Accessibility also makes macOS show its own alert, so Dictation checks
/// Accessibility before it posts ⌘V. `PermissionPromptSourceTests` enforces these rules.
struct PermissionPrompts {
    enum Kind: Equatable {
        case system
        case inert
    }

    let kind: Kind
    let requestMicrophone: () async -> Void
    let requestSpeechRecognition: () async -> Void
    let requestScreenRecording: () -> Void
    let openSettings: (MacPermission) -> Void

    static let system = PermissionPrompts(
        kind: .system,
        requestMicrophone: { _ = await AVCaptureDevice.requestAccess(for: .audio) },
        requestSpeechRecognition: {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        },
        requestScreenRecording: { _ = CGRequestScreenCaptureAccess() },
        openSettings: { permission in _ = NSWorkspace.shared.open(permission.settingsURL) }
    )

    static let inert = PermissionPrompts(
        kind: .inert,
        requestMicrophone: {},
        requestSpeechRecognition: {},
        requestScreenRecording: {},
        openSettings: { _ in }
    )

    /// The system prompts, except in the unit-test host, where a test that forgets to inject fakes
    /// still can't raise a real prompt or open System Settings on the owner's screen. An ad-hoc
    /// signed host is a new app to macOS after every rebuild, so it would ask again each time.
    static var current: PermissionPrompts {
        UnitTestHost.isActive ? .inert : .system
    }
}
