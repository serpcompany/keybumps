import AppKit
import AVFoundation
import CoreGraphics
import Speech

/// Every macOS permission prompt Keybumps asks for, plus opening System Settings.
///
/// macOS also prompts on its own, outside this type:
/// - Files & Folders, the first time Keybumps reads a protected folder: Dictation History in
///   Documents, or the screenshot folder (the Desktop by default).
/// - The "would like to control this computer" alert, if keyboard events were posted without
///   Accessibility. `SystemTextPaster.postSystemCommandV` checks first, so this never happens.
///
/// Only `PermissionCoordinator` calls these, and only from explicit request paths:
/// - Microphone and Speech Recognition, while macOS hasn't asked yet: Request Access… on the
///   Permissions page or in onboarding, and the setup walkthrough.
/// - Screen Recording: Screenshot Tools' Allow…, Open System Settings… on the Permissions page or
///   in onboarding (`performRecovery` asks once so macOS lists Keybumps), and the first screenshot
///   hotkey without access.
/// - System Settings: permission recovery, Keyboard Shortcuts, and Files & Folders.
///
/// macOS shows each native prompt at most once for an app identity.
///
/// Accessibility and Input Monitoring have no prompt here. They recover only through System
/// Settings and the drag card, and nothing in Keybumps asks macOS to prompt for them. Posting
/// keyboard events without Accessibility also makes macOS show its own alert, so the ⌘V poster
/// checks Accessibility itself. `PermissionPromptSourceTests` enforces these rules.
struct PermissionPrompts {
    enum Kind: Equatable {
        case system
        case inert
    }

    let kind: Kind
    let requestMicrophone: () async -> Void
    let requestSpeechRecognition: () async -> Void
    let requestScreenRecording: () -> Void
    let openSystemSettings: (SystemSettingsPage) -> Void

    static let system = PermissionPrompts(
        kind: .system,
        requestMicrophone: { _ = await AVCaptureDevice.requestAccess(for: .audio) },
        requestSpeechRecognition: {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        },
        requestScreenRecording: { _ = CGRequestScreenCaptureAccess() },
        openSystemSettings: { page in _ = NSWorkspace.shared.open(page.url) }
    )

    static let inert = PermissionPrompts(
        kind: .inert,
        requestMicrophone: {},
        requestSpeechRecognition: {},
        requestScreenRecording: {},
        openSystemSettings: { _ in }
    )

    /// The system prompts, except in the unit-test host, where a test that forgets to inject fakes
    /// still can't raise a real prompt or open System Settings on the owner's screen. An ad-hoc
    /// signed host is a new app to macOS after every rebuild, so it would ask again each time.
    static var current: PermissionPrompts {
        UnitTestHost.isActive ? .inert : .system
    }
}
