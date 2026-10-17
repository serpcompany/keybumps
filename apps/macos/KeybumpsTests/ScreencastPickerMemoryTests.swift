import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// The picker opens as Record last left it (#483): Area, Window, or Screen, the screen or All
/// Screens, and the switches, which are Settings › Screengrabs'. Each launch is a new
/// `ScreencastModule` and `AppPreferences` on the same in-memory defaults, with made-up screens and
/// windows, so nothing reads the screen, asks for a permission, or records.
@MainActor
@Suite("Screencast: the picker remembers your last choices")
struct ScreencastPickerMemoryTests {
    let defaults = InMemoryDefaults()
    /// (150, 150) in the top-left space: on the browser window, on the left screen.
    let onBrowserWindow = CGPoint(x: 150, y: 832)
    /// The switches before any is changed: Settings › Screengrabs' defaults.
    let firstUseSwitches = ScreencastSwitches(
        recordsMicrophone: true, recordsSystemAudio: true, showsShortcuts: true, highlightsClicks: false
    )
    /// Where Settings › Screengrabs stores the switches.
    let switchKeys = [
        PluginPreference.screencastRecordsMicrophone, .screencastRecordsSystemAudio,
        .screencastShowsShortcuts, .screencastHighlightsClicks,
    ].map { $0.storageKey(for: .screenshotTools) }

    struct Launch {
        let preferences: AppPreferences
        let module: ScreencastModule
        let overlays: FakeOverlays
    }

    /// Keybumps launched on `defaults`, with Screencast on, Screen Recording, and `microphone` as
    /// Microphone access. Asking for the microphone calls `onMicrophoneRequest`.
    private func launch(
        microphone: AVAuthorizationStatus = .authorized,
        onMicrophoneRequest: @escaping () -> Void = {}
    ) -> Launch {
        let preferences = AppPreferences(defaults: defaults)
        let permissions = PermissionCoordinator(
            microphoneAuthorizationStatus: { microphone },
            screenRecordingAuthorized: { true },
            requestMicrophone: { onMicrophoneRequest() }
        )
        let overlays = FakeOverlays()
        let module = ScreencastModule(
            preferences: preferences,
            permissions: permissions,
            openSettings: { _ in },
            seams: ScreencastSeams(
                captureSystem: FakeCaptureSystem(content: ScreencastScreens.content()),
                pickerSystem: FakePickerSystem(content: ScreencastScreens.content()),
                presenter: overlays,
                screens: { PickerScreens.both },
                sleep: { _ in },
                contextReader: .inert
            )
        )
        module.apply(CapabilityContext(
            enabledCapabilities: [.screenshotTools],
            preferences: preferences,
            shortcuts: GlobalShortcutCoordinator(backend: DrawingHotKeyBackend()),
            permissions: permissions,
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))
        return Launch(preferences: preferences, module: module, overlays: overlays)
    }

    /// Record Screen: the picker, once it has read the windows.
    @available(macOS 15, *)
    private func open(_ launch: Launch) async throws -> ScreencastPickerModel {
        launch.module.start()
        let picker = try #require(launch.module.controller?.picker)
        #expect(await ScreencastWait.until { launch.overlays.picker === picker })
        return picker
    }

    /// Record, then Escape during the countdown, so nothing records. What Record saved stays: that
    /// Escape cancels the recording, not the choices Record took (`escapeSavesNothing` covers
    /// Escape in the picker).
    @available(macOS 15, *)
    private func record(_ launch: Launch) throws {
        let controller = try #require(launch.module.controller)
        controller.confirm()
        #expect(controller.phase == .countingDown(remaining: 3))
        controller.cancel()
        #expect(controller.phase == .idle)
    }

    private func switches(_ picker: ScreencastPickerModel) -> ScreencastSwitches {
        ScreencastSwitches(
            recordsMicrophone: picker.recordsMicrophone,
            recordsSystemAudio: picker.recordsSystemAudio,
            showsShortcuts: picker.showsShortcuts,
            highlightsClicks: picker.highlightsClicks
        )
    }

    // MARK: Round trips

    @available(macOS 15, *)
    @Test("Screen mode, its screen, and every switch come back after a relaunch, and Settings shows the same switches")
    func screenAndSwitchesComeBack() async throws {
        let first = launch()
        let picker = try await open(first)
        picker.target = .screen
        picker.chooseScreen(PickerScreens.right.id)
        picker.recordsMicrophone = false
        picker.recordsSystemAudio = false
        picker.showsShortcuts = false
        picker.highlightsClicks = true
        let chosen = switches(picker)
        try record(first)
        #expect(first.preferences.screencast.switches == chosen, "Settings › Screengrabs shows what the picker took")
        // Stored by its UUID, whichever screen the pointer is on.
        let stored = try #require(defaults.dictionary(forKey: ScreencastPickerMemory.key))
        #expect(stored["target"] as? String == "screen")
        #expect(stored["display"] as? String == "MADE-UP-RIGHT-DISPLAY")
        #expect(stored["allScreens"] == nil)

        let again = try await open(launch())
        #expect(again.target == .screen)
        #expect(again.selectedScreen == PickerScreens.right.id)
        #expect(again.choice()?.target == .display(PickerScreens.right.id))
        #expect(switches(again) == chosen)
        #expect(defaults.leakedDomain == nil)
    }

    @available(macOS 15, *)
    @Test("All Screens comes back, an area comes back with its own memory, and a capture in another mode keeps the screen choice")
    func allScreensAndAreaComeBack() async throws {
        let first = launch()
        let picker = try await open(first)
        picker.target = .screen
        picker.chooseEveryScreen()
        try record(first)

        let second = launch()
        let screens = try await open(second)
        #expect(screens.target == .screen && screens.selectedScreen == nil)
        #expect(screens.choice()?.target == .everyDisplay)
        // An area on the left screen.
        screens.target = .area
        screens.pressArea(at: CGPoint(x: 100, y: 100), on: PickerScreens.left)
        screens.dragArea(to: CGPoint(x: 500, y: 400))
        screens.releaseArea()
        let area = try #require(screens.area)
        try record(second)

        let third = try await open(launch())
        #expect(third.target == .area)
        #expect(third.area == area)
        third.target = .screen
        #expect(third.selectedScreen == nil, "Still All Screens")
    }

    @available(macOS 15, *)
    @Test("Window mode comes back with no window chosen, and what's remembered is only the mode")
    func windowModeStartsEmpty() async throws {
        let first = launch()
        let picker = try await open(first)
        picker.target = .window
        #expect(picker.clickWindow(at: onBrowserWindow))
        #expect(picker.choice()?.target == .window(ScreencastScreens.browserWindow.id))
        try record(first)
        let stored = try #require(defaults.dictionary(forKey: ScreencastPickerMemory.key))
        #expect(Set(stored.keys) == ["target"])
        #expect(stored["target"] as? String == "window")

        let again = try await open(launch())
        #expect(again.target == .window)
        #expect(again.selectedWindow == nil)
        #expect(again.choice() == nil && !again.canConfirm)
        #expect(again.hint == "Click a window to choose it.")
    }

    // MARK: Escape

    @available(macOS 15, *)
    @Test("Escape in the picker saves nothing, nor does Record with nothing chosen: the next picker opens as on first use")
    func escapeSavesNothing() async throws {
        let first = launch()
        let before = NSDictionary(dictionary: defaults.dictionaryRepresentation())
        let picker = try await open(first)
        let controller = try #require(first.module.controller)
        picker.target = .screen
        picker.chooseScreen(PickerScreens.right.id)
        picker.recordsSystemAudio = false
        picker.highlightsClicks = true
        // Window mode with no window chosen: Record does nothing, and the picker stays open.
        picker.target = .window
        #expect(!picker.canConfirm)
        controller.confirm()
        #expect(controller.phase == .picking)
        picker.target = .screen
        controller.cancel()
        #expect(controller.phase == .idle && controller.picker == nil)

        #expect(defaults.object(forKey: ScreencastPickerMemory.key) == nil)
        #expect(switchKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(first.preferences.screencast.switches == firstUseSwitches, "Settings › Screengrabs is as it was")
        #expect(before.isEqual(to: defaults.dictionaryRepresentation()), "Nothing at all was stored")

        let again = try await open(launch())
        #expect(again.target == .screen && again.area == nil)
        #expect(again.selectedScreen == again.pointerScreen?.id, "Screen mode starts on the pointer's screen")
        #expect(switches(again) == firstUseSwitches)
    }

    // MARK: Falling back

    @Test("A remembered screen that isn't connected falls back to the pointer's screen, and so does All Screens on one screen")
    func missingScreenFallsBack() {
        let preferences = PickerScreens.preferences()
        func model(
            _ layout: ScreencastScreenLayout,
            _ screen: ScreencastPickerChoices.Screen,
            pointer: CGDirectDisplayID
        ) -> ScreencastPickerModel {
            ScreencastPickerModel(
                layout: layout, preferences: preferences, microphoneAvailable: true,
                remembered: ScreencastPickerChoices(target: .screen, screen: screen), pointerScreen: pointer
            )
        }
        let right = ScreencastPickerChoices.Screen.display(uuid: "MADE-UP-RIGHT-DISPLAY")

        // Connected: it comes back, while the bar stays on the pointer's screen.
        let connected = model(PickerScreens.both, right, pointer: 1)
        #expect(connected.target == .screen)
        #expect(connected.selectedScreen == 2 && connected.pointerScreen == PickerScreens.left)

        let unplugged = model(PickerScreens.leftOnly, right, pointer: 1)
        #expect(unplugged.target == .screen && unplugged.selectedScreen == 1)
        #expect(unplugged.choice()?.target == .display(1))
        #expect(model(PickerScreens.both, .display(uuid: "A-DISPLAY-THAT-IS-GONE"), pointer: 2).selectedScreen == 2)

        let oneScreen = model(PickerScreens.leftOnly, .all, pointer: 1)
        #expect(oneScreen.selectedScreen == 1 && oneScreen.choice()?.target == .display(1))
        #expect(model(PickerScreens.both, .all, pointer: 1).selectedScreen == nil)

        // Taken in Screen mode on the one screen left, that screen is what's remembered next.
        #expect(unplugged.choicesToRemember == ScreencastPickerChoices(target: .screen, screen: .display(uuid: "MADE-UP-LEFT-DISPLAY")))
        // Taken in another mode, the screen remembered stays.
        unplugged.target = .window
        #expect(unplugged.choicesToRemember == ScreencastPickerChoices(target: .window, screen: right))
    }

    @Test("A screen chosen that macOS gives no UUID is remembered as none, so the next picker starts on the pointer's screen")
    func screenWithoutUUID() {
        var unnamed = PickerScreens.right
        unnamed.uuid = nil
        let layout = ScreencastScreenLayout(screens: [PickerScreens.left, unnamed])
        let memory = ScreencastPickerMemory(defaults: InMemoryDefaults())
        func model() -> ScreencastPickerModel {
            ScreencastPickerModel(
                layout: layout, preferences: PickerScreens.preferences(), microphoneAvailable: true,
                remembered: memory.choices, pointerScreen: PickerScreens.left.id
            )
        }
        // All Screens was last chosen.
        memory.save(ScreencastPickerChoices(target: .screen, screen: .all))
        let picker = model()
        #expect(picker.selectedScreen == nil)
        picker.chooseScreen(unnamed.id)
        #expect(picker.choicesToRemember == ScreencastPickerChoices(target: .screen, screen: nil))
        memory.save(picker.choicesToRemember)

        let again = model()
        #expect(again.target == .screen)
        #expect(again.selectedScreen == PickerScreens.left.id, "Not All Screens")
    }

    @Test("A remembered Area whose area no screen shows still opens on Area, with none drawn: what's remembered wins over Screen")
    func areaThatNoLongerFits() {
        let defaults = InMemoryDefaults()
        ScreencastPickerMemory(defaults: defaults).save(ScreencastPickerChoices(target: .area))
        // On the right screen, which is unplugged.
        let areaMemory = ScreencastAreaMemory(defaults: defaults)
        areaMemory.save(CGRect(x: 1612, y: 0, width: 400, height: 300))
        let picker = ScreencastPickerModel(
            layout: PickerScreens.leftOnly, preferences: PickerScreens.preferences(), microphoneAvailable: true,
            remembered: ScreencastPickerMemory(defaults: defaults).choices,
            rememberedArea: areaMemory.area(in: PickerScreens.leftOnly), pointerScreen: 1
        )
        #expect(picker.target == .area && picker.area == nil)
        #expect(picker.hint == "Drag to choose an area.")
    }

    @Test("Remembered choices that aren't understood are ignored")
    func malformedMemory() {
        let defaults = InMemoryDefaults()
        let memory = ScreencastPickerMemory(defaults: defaults)
        defaults.set(["target": "everything", "display": 7, "allScreens": "yes"], forKey: ScreencastPickerMemory.key)
        #expect(memory.choices == ScreencastPickerChoices())
        defaults.set("a screen", forKey: ScreencastPickerMemory.key)
        #expect(memory.choices == ScreencastPickerChoices())
        memory.save(ScreencastPickerChoices(target: .screen, screen: .all))
        #expect(memory.choices == ScreencastPickerChoices(target: .screen, screen: .all))
    }

    // MARK: The microphone

    @available(macOS 15, *)
    @Test("Without Microphone access the microphone stays off and nothing asks for it, and its setting is kept for when there's access")
    func microphoneWithoutAccess() async throws {
        var requests = 0
        let denied = launch(microphone: .notDetermined, onMicrophoneRequest: { requests += 1 })
        let picker = try await open(denied)
        #expect(!picker.recordsMicrophone)
        picker.target = .screen
        picker.recordsSystemAudio = false
        #expect(picker.choice()?.audio == ScreencastAudio(microphone: false, systemAudio: false))
        try record(denied)
        #expect(denied.preferences.screencast.recordsMicrophone, "Its setting stays on")
        #expect(!denied.preferences.screencast.recordsSystemAudio)

        let stillDenied = try await open(launch(microphone: .denied, onMicrophoneRequest: { requests += 1 }))
        #expect(!stillDenied.recordsMicrophone && !stillDenied.recordsSystemAudio)
        #expect(requests == 0)

        let granted = try await open(launch())
        #expect(granted.recordsMicrophone && !granted.recordsSystemAudio)
    }

    // MARK: First use

    @available(macOS 15, *)
    @Test("On first use the picker opens on Screen, on the pointer's screen, and Settings keeps following its defaults until a switch changes")
    func firstUse() async throws {
        #expect(ScreencastPickerMemory(defaults: defaults).choices == ScreencastPickerChoices())
        let first = launch()
        let picker = try await open(first)
        // Screen, not Area (#501), so Record records at once.
        #expect(picker.target == .screen && picker.area == nil)
        #expect(picker.selectedScreen == picker.pointerScreen?.id && picker.canConfirm)
        #expect(switches(picker) == firstUseSwitches)
        // The pointer's screen, as before.
        let model = ScreencastPickerModel(
            layout: PickerScreens.both, preferences: PickerScreens.preferences(), microphoneAvailable: true,
            remembered: ScreencastPickerMemory(defaults: defaults).choices, pointerScreen: 2
        )
        #expect(model.target == .screen && model.selectedScreen == 2)
        #expect(model.choice()?.target == .display(2))
        #expect(model.hint == "Records all of Screen 2.")

        // Recording with the switches as they were stores none of them, and Screen is remembered.
        try record(first)
        #expect(switchKeys.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(defaults.dictionary(forKey: ScreencastPickerMemory.key)?["target"] as? String == "screen")
    }
}
