import SwiftUI

extension CapabilityDescriptor {
    static let screencast = CapabilityDescriptor(
        capability: .screencast,
        title: "Screencast",
        systemImage: "record.circle",
        iconTint: .red,
        requiredPermissions: [.screenRecording],
        dependencies: [],
        // ⌘1–⌘9 are taken; whether it gets a tab is open (ADR 0009).
        paletteTab: nil,
        settingsPage: CapabilitySettingsPage(
            section: .screencast,
            summary: "Record your screen with your voice and the Mac’s sound, and keep each capture on this Mac.",
            disableExplanation: "Turning this off releases its global shortcut. Captures already saved stay on this Mac.",
            content: { AnyView(PluginSettingsPage(capability: .screencast) { ScreencastCapturesSettings() }) }
        ),
        criticalOperations: [],
        searchKeywords: ["screen recording", "record", "recorder", "video", "capture"],
        category: .media,
        preferences: [
            .screencastRecordsMicrophone, .screencastRecordsSystemAudio,
            .screencastCountdown, .screencastShowsShortcuts, .screencastHighlightsClicks,
        ],
        optionalPermissions: [
            PluginOptionalPermission(
                permission: .microphone,
                reason: "Records your voice with a video. Without it, videos have only the screen and the Mac’s sound."
            ),
        ],
        isOnByDefault: false,
        minimumMacOS: 15
    )
}

/// What a composition gives Screencast in place of the screen, its windows, the countdown's clock,
/// and Finder: the UI-test composition's made-up screens and inert recorder, or unit tests' fakes.
/// Anything left nil is the app's own, which is inert under the unit-test host.
struct ScreencastSeams {
    var captureSystem: (any ScreencastCaptureSystem)?
    var pickerSystem: (any ScreencastPickerSystem)?
    var presenter: (any ScreencastOverlayPresenting)?
    var screens: (@MainActor () -> ScreencastScreenLayout)?
    var sleep: ((TimeInterval) async throws -> Void)?
    /// Shows a saved capture's files, until the review panel (#450) takes them.
    var revealCapture: (@MainActor ([URL]) -> Void)?

    init(
        captureSystem: (any ScreencastCaptureSystem)? = nil,
        pickerSystem: (any ScreencastPickerSystem)? = nil,
        presenter: (any ScreencastOverlayPresenting)? = nil,
        screens: (@MainActor () -> ScreencastScreenLayout)? = nil,
        sleep: ((TimeInterval) async throws -> Void)? = nil,
        revealCapture: (@MainActor ([URL]) -> Void)? = nil
    ) {
        self.captureSystem = captureSystem
        self.pickerSystem = pickerSystem
        self.presenter = presenter
        self.screens = screens
        self.sleep = sleep
        self.revealCapture = revealCapture
    }
}

/// Owns Screencast (ADR 0009) and its optional Start Screencast shortcut. It ships off, and needs
/// macOS 15 (`minimumMacOS`), where ScreenCaptureKit records the screen, the microphone, and the
/// Mac's sound in one stream. Its own code is under `Screencast/`, and its settings are read
/// through `AppPreferences.screencast`.
///
/// Start Screencast opens the picker (`ScreencastController`), once Keybumps has Screen Recording;
/// until then it opens Screencast's page, so the picker never makes macOS ask. Turning Screencast
/// off, or Keybumps becoming Locked, cancels a capture that hasn't started and keeps a recording
/// in the captures folder. A saved capture is shown in Finder until the review panel (#450) takes
/// its place.
@MainActor
final class ScreencastModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.screencast
    /// Opens Settings on a page; tests replace it.
    private let openSettings: @MainActor (SettingsSection) -> Void
    private let preferences: AppPreferences
    private let permissions: PermissionCoordinator
    private let seams: ScreencastSeams
    private var isOn = false
    /// The `ScreencastController`, made the first time Start Screencast opens the picker. Stored
    /// untyped because the controller needs macOS 15.
    private var controllerStorage: AnyObject?

    init(
        preferences: AppPreferences,
        permissions: PermissionCoordinator,
        openSettings: @escaping @MainActor (SettingsSection) -> Void,
        seams: ScreencastSeams = ScreencastSeams()
    ) {
        self.preferences = preferences
        self.permissions = permissions
        self.openSettings = openSettings
        self.seams = seams
    }

    func apply(_ context: CapabilityContext) {
        isOn = context.isEnabled(capability)
        context.configureShortcut(
            owner: CapabilityShortcut.screencast.ownerID,
            for: capability,
            binding: context.preferences.capabilityShortcut(for: .screencast)
        ) { [weak self] in
            self?.start()
        }
    }

    /// Turned off, or Keybumps Locked: the picker closes and a countdown is cancelled, but a
    /// recording stops and is kept, and a screenshot being saved finishes. Neither opens anything;
    /// they stay in the captures folder (`ScreencastController.shutDown`).
    func deactivate(_ context: CapabilityContext) {
        isOn = false
        guard #available(macOS 15, *), let controller else { return }
        Task { await controller.shutDown() }
    }

    /// Settings attention while it's on and Screen Recording isn't granted.
    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }

    /// Start Screencast: the picker, while Screencast is on, on macOS 15, with Screen Recording.
    /// Otherwise Screencast's page, which says what's missing; the picker never makes macOS ask.
    func start() {
        permissions.refresh()
        guard #available(macOS 15, *), isOn, permissions.screenRecordingGranted else {
            openSettings(.screencast)
            return
        }
        controllerForCapture().open()
    }

    /// The flow controller, once Start Screencast has made it.
    @available(macOS 15, *)
    var controller: ScreencastController? {
        controllerStorage as? ScreencastController
    }

    @available(macOS 15, *)
    private func controllerForCapture() -> ScreencastController {
        if let controller { return controller }
        let permissions = permissions
        let preferences = preferences
        let recorder = ScreencastRecorder(
            system: seams.captureSystem,
            // The recorder runs on the main actor, and asks only as a recording starts.
            microphoneGranted: { MainActor.assumeIsolated { permissions.microphoneGranted } }
        )
        let controller = ScreencastController(
            recorder: recorder,
            system: seams.pickerSystem,
            presenter: seams.presenter,
            areaMemory: preferences.screencastAreaMemory,
            preferences: { preferences.screencast },
            screens: seams.screens ?? { ScreencastScreenLayout.current() },
            microphoneAvailable: { permissions.microphoneGranted },
            sleep: seams.sleep ?? { try await Task.sleep(for: .seconds($0)) }
        )
        let reveal = seams.revealCapture ?? Self.revealInFinder
        controller.onCaptureFinished = { result in reveal(Self.files(of: result)) }
        controllerStorage = controller
        return controller
    }

    /// The files a saved capture shows in Finder: each video to share (its mixdown when there is
    /// one), or each screenshot.
    static func files(of result: ScreencastCaptureResult) -> [URL] {
        switch result {
        case .video(let capture): capture.videos.map(\.forSharing)
        case .screenshot(let screenshot): screenshot.images.map(\.file)
        }
    }

    /// Selects the files in Finder; never under the unit-test host.
    private static func revealInFinder(_ files: [URL]) {
        guard !UnitTestHost.isActive, !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }
}
