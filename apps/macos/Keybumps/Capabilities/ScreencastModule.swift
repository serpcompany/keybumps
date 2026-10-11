import AVFoundation
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
        actions: [.startScreencast],
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

extension PluginAction {
    /// Quick Search's Start Screencast, which does what the shortcut does (`ScreencastModule.start`).
    static let startScreencast = PluginAction(
        id: "startScreencast",
        title: "Start Screencast",
        keywords: ["record", "recording", "screen recording", "capture", "video"],
        systemImage: "record.circle",
        shortcut: .screencast
    )
}

/// What a composition gives Screencast in place of the screen, its windows, the files a recording
/// writes, the countdown's clock, and the app in front: the UI-test composition's made-up screens
/// and inert recorder, or unit tests' fakes. Anything left nil is the app's own, which is inert
/// under the unit-test host.
struct ScreencastSeams {
    var captureSystem: (any ScreencastCaptureSystem)?
    /// Writes each recording's movie files and its mixdown.
    var writers: (any ScreencastWriterFactory)?
    var pickerSystem: (any ScreencastPickerSystem)?
    var presenter: (any ScreencastOverlayPresenting)?
    var screens: (@MainActor () -> ScreencastScreenLayout)?
    var sleep: ((TimeInterval) async throws -> Void)?
    /// How long the control bar's Restart? and Discard? wait for an answer before going back as
    /// Keep; the UI-test composition makes it long, so a slow runner never sees one give up.
    var barConfirmationTimeout: Duration?
    /// Reads the app in front as a capture starts, for the review panel's repository guess.
    var contextReader: ScreencastCaptureContextReader?

    init(
        captureSystem: (any ScreencastCaptureSystem)? = nil,
        writers: (any ScreencastWriterFactory)? = nil,
        pickerSystem: (any ScreencastPickerSystem)? = nil,
        presenter: (any ScreencastOverlayPresenting)? = nil,
        screens: (@MainActor () -> ScreencastScreenLayout)? = nil,
        sleep: ((TimeInterval) async throws -> Void)? = nil,
        barConfirmationTimeout: Duration? = nil,
        contextReader: ScreencastCaptureContextReader? = nil
    ) {
        self.captureSystem = captureSystem
        self.writers = writers
        self.pickerSystem = pickerSystem
        self.presenter = presenter
        self.screens = screens
        self.sleep = sleep
        self.barConfirmationTimeout = barConfirmationTimeout
        self.contextReader = contextReader
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
/// in the captures folder. While it records, `ScreencastRecordingControls` shows the control bar
/// and the time in the menu bar, and registers the recording shortcuts, and
/// `ScreencastOverlaysWiring` puts the drawing and, with Show shortcuts on, the key display on the
/// recorded screens and into the video. Each saved capture opens the review panel (`review`, in
/// `ScreencastModule+Review.swift`).
@MainActor
final class ScreencastModule: CapabilityModule {
    let descriptor = CapabilityDescriptor.screencast
    /// Opens Settings on a page; tests replace it.
    private let openSettings: @MainActor (SettingsSection) -> Void
    private let preferences: AppPreferences
    private let permissions: PermissionCoordinator
    private let seams: ScreencastSeams
    /// The control bar, the menu bar's time, and the recording shortcuts.
    let recordingControls: ScreencastRecordingControls
    /// The drawing and the shortcuts on screen while recording.
    let overlays: ScreencastOverlaysWiring
    private var isOn = false
    /// The review panel after each capture (#450).
    let review: ScreencastReviewFlow
    /// The `ScreencastController`, made the first time Start Screencast opens the picker. Stored
    /// untyped because the controller needs macOS 15.
    private var controllerStorage: AnyObject?

    init(
        preferences: AppPreferences,
        permissions: PermissionCoordinator,
        openSettings: @escaping @MainActor (SettingsSection) -> Void,
        menuBar: CapabilityMenuBarStatus? = nil,
        keyDisplay: KeyDisplay? = nil,
        seams: ScreencastSeams = ScreencastSeams(),
        review services: ScreencastReviewServices? = nil
    ) {
        self.preferences = preferences
        self.permissions = permissions
        self.openSettings = openSettings
        self.seams = seams
        recordingControls = ScreencastRecordingControls(
            menuBar: menuBar,
            placement: preferences.screencastBarPlacement,
            confirmationTimeout: seams.barConfirmationTimeout ?? ScreencastControlBarModel.confirmationTimeout
        )
        let screens = seams.screens ?? { ScreencastScreenLayout.current() }
        overlays = ScreencastOverlaysWiring(
            keyDisplay: keyDisplay,
            drawingMemory: preferences.screencastDrawingMemory,
            keystrokesConfiguration: { [preferences] in
                preferences.enabledCapabilities.contains(.keystrokes) ? preferences.keystrokesConfiguration : nil
            },
            displays: { ScreencastOverlaysWiring.displays(in: screens(), connected: ScreencastOverlayDisplay.connected) }
        )
        review = ScreencastReviewFlow(services: services, contextReader: seams.contextReader ?? .current)
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
        recordingControls.apply(context)
        overlays.apply(context)
    }

    /// Turned off, or Keybumps Locked: the picker closes and a countdown is cancelled, but a
    /// recording stops and is kept. It opens nothing; it stays in the captures folder
    /// (`ScreencastController.shutDown`).
    func deactivate(_ context: CapabilityContext) {
        isOn = false
        recordingControls.deactivate()
        // The capture under review is saved.
        review.close()
        guard #available(macOS 15, *), let controller else { return }
        Task { await controller.shutDown() }
    }

    /// Settings attention while it's on and Screen Recording isn't granted.
    func attentionCount(_ context: CapabilityContext) -> Int {
        guard context.isEnabled(capability) else { return 0 }
        return context.permissionReadiness([capability]).missingCount
    }

    /// Quick Search's Start Screencast takes the shortcut's path.
    func perform(_ action: PluginAction, _ context: CapabilityContext) {
        if action == .startScreencast { start() }
    }

    /// Start Screencast isn't listed while a capture is under way, when it would do nothing.
    func offers(_ action: PluginAction, _ context: CapabilityContext) -> Bool {
        action != .startScreencast || !isCapturing
    }

    /// Whether a capture is under way: the picker open, counting down, recording, or saving.
    var isCapturing: Bool {
        guard #available(macOS 15, *), let controller else { return false }
        return controller.phase != .idle
    }

    /// Start Screencast: the picker, while Screencast is on, on macOS 15, with Screen Recording.
    /// Otherwise Screencast's page, which says what's missing; the picker never makes macOS ask.
    func start() {
        permissions.refresh()
        guard #available(macOS 15, *), isOn, permissions.screenRecordingGranted else {
            openSettings(.screencast)
            return
        }
        let controller = controllerForCapture()
        if controller.phase == .idle { review.captureStarting() }
        controller.open()
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
            writers: seams.writers ?? AVAssetScreencastWriterFactory(),
            // The recorder asks on the main actor, as a recording starts. Asked anywhere else, it
            // reads macOS's answer directly rather than trapping.
            microphoneGranted: {
                guard Thread.isMainThread else { return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
                return MainActor.assumeIsolated { permissions.microphoneGranted }
            }
        )
        let controller = Self.wiredController(
            recorder: recorder,
            captureSystem: seams.captureSystem ?? ScreenCaptureKitCaptureSystem.current,
            pickerSystem: seams.pickerSystem,
            presenter: seams.presenter,
            areaMemory: preferences.screencastAreaMemory,
            preferences: { preferences.screencast },
            screens: seams.screens ?? { ScreencastScreenLayout.current() },
            microphoneAvailable: { permissions.microphoneGranted },
            sleep: seams.sleep ?? { try await Task.sleep(for: .seconds($0)) },
            recordingControls: recordingControls,
            overlays: overlays
        )
        controller.onCaptureFinished = { [review] result in review.captureFinished(result) }
        controllerStorage = controller
        return controller
    }
}

extension ScreencastModule {
    /// Start Screencast's controller for `recorder`, with the control bar and the overlays attached.
    /// The QA smoke test (`ScreencastSmokeRig`) makes its controller here too, so it runs this
    /// wiring rather than a copy of it.
    @available(macOS 15, *)
    static func wiredController(
        recorder: ScreencastRecorder,
        captureSystem: any ScreencastCaptureSystem,
        pickerSystem: (any ScreencastPickerSystem)?,
        presenter: (any ScreencastOverlayPresenting)?,
        areaMemory: ScreencastAreaMemory,
        preferences: @escaping @MainActor () -> ScreencastPreferences,
        screens: @escaping @MainActor () -> ScreencastScreenLayout,
        microphoneAvailable: @escaping @MainActor () -> Bool,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        recordingControls: ScreencastRecordingControls,
        overlays: ScreencastOverlaysWiring
    ) -> ScreencastController {
        let controller = ScreencastController(
            recorder: recorder,
            system: pickerSystem,
            presenter: presenter,
            areaMemory: areaMemory,
            preferences: preferences,
            screens: screens,
            microphoneAvailable: microphoneAvailable,
            sleep: sleep,
            ownProcessID: ownProcessID
        )
        recordingControls.attach(to: controller)
        // The engine's own reader, in the screens' AppKit space, so the keys follow a recorded window.
        overlays.attach(
            to: controller,
            bar: { [recordingControls] in recordingControls.bar },
            windowFrame: { id in captureSystem.windowFrame(id).map { screens().appKitRect(fromTopLeft: $0) } }
        )
        return controller
    }
}
