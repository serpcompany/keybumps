import AVFoundation
import SwiftUI

extension PluginAction {
    /// Record Screen's name, for Quick Search's action and the shortcut's row alike, so a new name
    /// is one change.
    static let recordScreenTitle = "Record Screen"

    /// Quick Search's Record Screen, which does what the shortcut does (`ScreencastModule.start`).
    /// Its ID keeps Screencast's name, since it keys the action's learned usage.
    static let startScreencast = PluginAction(
        id: "startScreencast",
        title: recordScreenTitle,
        keywords: ["record", "recording", "screen recording", "screencast", "capture", "video"],
        systemImage: "record.circle",
        shortcut: .screencast
    )
}

extension CapabilityContext {
    /// Whether ScreenGrabs records now: it's on, and this Mac's macOS can record
    /// (`PluginCompatibility.supportsRecording`).
    var recordsScreen: Bool {
        isEnabled(.screenshotTools) && preferences.compatibility.supportsRecording
    }
}

/// What a composition gives ScreenGrabs' recording in place of the screen, its windows, the files a recording
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

/// ScreenGrabs' recording (ADR 0009, ADR 0010): a part `ScreenshotToolsModule` owns, which keeps
/// Screencast's name from when it was a plugin of its own, and Record Screen (the `screencast`
/// shortcut, ⇧⌘5 by default, and Quick Search's action). It records only where
/// `PluginCompatibility.supportsRecording` (macOS 15), where ScreenCaptureKit records the screen,
/// the microphone, and the Mac's sound in one stream; `#available` wraps only those calls. Its own
/// code is under `Screencast/`, and its settings are read through `AppPreferences.screencast`.
///
/// Record Screen opens the picker (`ScreencastController`), once Keybumps has Screen Recording;
/// until then it opens ScreenGrabs' page, so the picker never makes macOS ask. Turning ScreenGrabs
/// off, or Keybumps becoming Locked, cancels a recording that hasn't started and keeps one under
/// way in the recordings folder. While it records, `ScreencastRecordingControls` shows the control
/// bar and the time in the menu bar, and registers the recording shortcuts, and
/// `ScreencastOverlaysWiring` puts the drawing and, with Show shortcuts on, the key display on the
/// recorded screens and into the video. Each saved recording opens the recording window (`review`,
/// in `ScreencastModule+Review.swift`).
@MainActor
final class ScreencastModule {
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
    /// The recording window after each recording (#450, #479).
    let review: ScreencastReviewFlow
    /// The `ScreencastController`, made the first time Record Screen opens the picker. Stored
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

    /// Run from `ScreenshotToolsModule.apply`. Record Screen's shortcut is registered while
    /// ScreenGrabs is on, and only where it can record, so macOS 14 keeps ⇧⌘5.
    func apply(_ context: CapabilityContext) {
        isOn = context.recordsScreen
        context.configureShortcut(
            owner: CapabilityShortcut.screencast.ownerID,
            for: .screenshotTools,
            binding: context.preferences.compatibility.supportsRecording
                ? context.preferences.capabilityShortcut(for: .screencast)
                : nil
        ) { [weak self] in
            self?.start()
        }
        recordingControls.apply(context)
        overlays.apply(context)
        if isOn { review.recoverInterruptedExports(in: context.preferences.screencast.capturesFolder) }
    }

    /// ScreenGrabs turned off, or Keybumps Locked: the picker closes and a countdown is cancelled,
    /// but a recording stops and is kept. It opens nothing; it stays in the recordings folder
    /// (`ScreencastController.shutDown`).
    func deactivate(_ context: CapabilityContext) {
        isOn = false
        recordingControls.deactivate()
        // The recording in the recording window is saved.
        review.close()
        guard #available(macOS 15, *), let controller else { return }
        Task { await controller.shutDown() }
    }

    /// Quick Search's Record Screen takes the shortcut's path.
    func perform(_ action: PluginAction, _ context: CapabilityContext) {
        if action == .startScreencast { start() }
    }

    /// Record Screen isn't listed where ScreenGrabs can't record, or while a recording is under
    /// way, when it would do nothing.
    func offers(_ action: PluginAction, _ context: CapabilityContext) -> Bool {
        action != .startScreencast || (context.preferences.compatibility.supportsRecording && !isCapturing)
    }

    /// Whether a recording is under way: the picker open, counting down, recording, or saving.
    var isCapturing: Bool {
        guard #available(macOS 15, *), let controller else { return false }
        return controller.phase != .idle
    }

    /// Record Screen: the picker, while ScreenGrabs is on, where it can record, with Screen
    /// Recording. Otherwise ScreenGrabs' page, which says what's missing; the picker never makes
    /// macOS ask.
    func start() {
        permissions.refresh()
        guard #available(macOS 15, *), isOn, permissions.screenRecordingGranted else {
            openSettings(.screenshotTools)
            return
        }
        let controller = controllerForCapture()
        if controller.phase == .idle { review.captureStarting() }
        controller.open()
    }

    /// The flow controller, once Record Screen has made it.
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
            pickerMemory: preferences.screencastPickerMemory,
            preferences: { preferences.screencast },
            saveSwitches: { preferences.setScreencastSwitches($0) },
            screens: seams.screens ?? { ScreencastScreenLayout.current() },
            microphoneAvailable: { permissions.microphoneGranted },
            sleep: seams.sleep ?? { try await Task.sleep(for: .seconds($0)) },
            recordingControls: recordingControls,
            overlays: overlays
        )
        controller.onCaptureFinished = { [review] result in review.captureFinished(result) }
        controller.addPhaseObserver { [review] phase in review.capturePhaseChanged(phase) }
        controllerStorage = controller
        return controller
    }
}

extension ScreencastModule {
    /// Record Screen's controller for `recorder`, with the control bar and the overlays attached.
    /// The QA smoke test (`ScreencastSmokeRig`) makes its controller here too, so it runs this
    /// wiring rather than a copy of it.
    @available(macOS 15, *)
    static func wiredController(
        recorder: ScreencastRecorder,
        captureSystem: any ScreencastCaptureSystem,
        pickerSystem: (any ScreencastPickerSystem)?,
        presenter: (any ScreencastOverlayPresenting)?,
        areaMemory: ScreencastAreaMemory,
        pickerMemory: ScreencastPickerMemory,
        preferences: @escaping @MainActor () -> ScreencastPreferences,
        saveSwitches: @escaping @MainActor (ScreencastSwitches) -> Void,
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
            pickerMemory: pickerMemory,
            preferences: preferences,
            saveSwitches: saveSwitches,
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
