import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The key display's windows, kept per screen like the real presenter's, but made by the Window
/// Server (so they have window numbers) and never put on screen. It remembers every window it ever
/// made, so a test can check none of them reached a recording.
@MainActor
final class FakeKeyDisplayPresenter: KeyDisplayPresenting {
    var onWindowsChange: (() -> Void)?
    private(set) var last: KeyDisplayContent?
    private(set) var everWindowIDs: Set<CGWindowID> = []
    private var byDisplay: [CGDirectDisplayID: NSWindow] = [:]

    var windows: [NSWindow] { byDisplay.keys.sorted().compactMap { byDisplay[$0] } }

    func show(_ content: KeyDisplayContent, animated: Bool) {
        last = content
        // 0 stands for the pointer's screen, for a configuration that names none.
        let screens = content.configuration.displays ?? [0]
        let hasSomething = !content.entries.isEmpty || !content.clicks.isEmpty
        update(content.keepsWindowsOnScreen || hasSomething ? screens : [])
    }

    func hide() {
        update([])
    }

    private func update(_ needed: Set<CGDirectDisplayID>) {
        var changed = false
        for display in Array(byDisplay.keys) where !needed.contains(display) {
            byDisplay.removeValue(forKey: display)?.close()
            changed = true
        }
        for display in needed where byDisplay[display] == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            byDisplay[display] = window
            everWindowIDs.insert(CGWindowID(window.windowNumber))
            changed = true
        }
        if changed { onWindowsChange?() }
    }
}

/// Types the same letter whatever the key: enough for the display to show typing.
private final class LetterLayout: KeyboardLayoutTranslating {
    func character(for keyCode: UInt16, with modifiers: KeyModifiers) -> String? { "a" }
}

/// The capture flow with the recorder's and picker's fakes, the control bar's controls, a key
/// display on fakes, and the overlays wired to them as `ScreencastModule` wires them. Nothing here
/// orders a window in, listens to the keyboard, or starts a capture.
@available(macOS 15, *)
@MainActor
struct OverlaysFlow {
    let flow = ScreencastFlow()
    let presenter = FakeKeyDisplayPresenter()
    let keyDisplay: KeyDisplay
    let defaults = InMemoryDefaults()
    let controls: ScreencastRecordingControls
    let wiring: ScreencastOverlaysWiring
    /// The Keystrokes plugin's settings, while it's on.
    let plugin = PluginState()

    final class PluginState {
        var configuration: KeyDisplayConfiguration?
    }

    static let displays = ScreencastOverlaysWiring.displays(in: PickerScreens.both, connected: [])

    init() {
        keyDisplay = KeyDisplay(
            keys: InertKeyTypingMonitor(),
            pointer: InertPointerEventMonitor(),
            presenter: presenter,
            layout: LetterLayout(),
            scheduler: KeyDisplayManualScheduler(),
            secureInput: { false }
        )
        keyDisplay.pointerDisplay = { 0 }
        controls = ScreencastRecordingControls(
            menuBar: nil,
            placement: ScreencastControlBarPlacement(defaults: defaults),
            barDisplay: { _ in ScreencastBarDisplay(key: "left", visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879)) },
            ordersPanelIn: false
        )
        let plugin = plugin
        wiring = ScreencastOverlaysWiring(
            keyDisplay: keyDisplay,
            drawingMemory: ScreencastDrawingMemory(defaults: defaults),
            keystrokesConfiguration: { plugin.configuration },
            displays: { Self.displays },
            ordersWindowsIn: false,
            watchesOwnKeys: false
        )
        controls.attach(to: flow.controller)
        let controls = controls
        wiring.attach(to: flow.controller, bar: { controls.bar })
    }

    var controller: ScreencastController { flow.controller }
    var recorder: ScreencastRecorder { flow.controller.recorder }

    /// The Keystrokes plugin, on with `configuration`, holding the display as its module does.
    func turnOnKeystrokes(_ configuration: KeyDisplayConfiguration) {
        plugin.configuration = configuration
        keyDisplay.acquire(.keystrokes, configuration: configuration)
    }

    /// Start Screencast, the left screen, Record: `beforeStart` runs once the picker has closed and
    /// before the recorder starts.
    func record(showsShortcuts: Bool = true, beforeStart: () -> Void = {}) async throws {
        controller.open()
        let picker = try #require(controller.picker)
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        picker.showsShortcuts = showsShortcuts
        controller.confirm()
        beforeStart()
        #expect(await ScreencastWait.until { controller.phase == .recording })
        await wiring.recorderUpdated()
    }

    func stop() async {
        await controller.stop()
        #expect(await ScreencastWait.until { controller.phase == .idle })
        await wiring.recorderUpdated()
    }

    /// What `display` puts on screen when the key is pressed: typing, or ⌘C.
    func type(_ keyCode: Int = kVK_ANSI_A, modifiers: KeyModifiers = []) {
        keyDisplay.receive(KeyPress(keyCode: UInt16(keyCode), modifiers: modifiers))
    }

    /// The recorder's content with Keybumps's windows `ids` on the left screen, so its filter
    /// can name them.
    func showOwnWindows(_ ids: [CGWindowID]) {
        let own = ids.map {
            ScreencastContent.Window(
                id: $0, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 3,
                processID: ScreencastScreens.ownProcess, isUntitled: true, isOnScreen: true
            )
        }
        flow.captureSystem.screen = ScreencastScreens.content(windows: [ScreencastScreens.browserWindow, ScreencastScreens.controlBar] + own)
    }

    /// The windows the first video stream's filter puts back into the recording.
    var exceptedWindows: [CGWindowID]? {
        guard let stream = flow.captureSystem.videoStreams.first, case .video(let plan, _) = stream.kind,
              case .display(_, _, let excepting) = plan else { return nil }
        return excepting
    }
}

@MainActor
@Suite("Screencast: on screen while recording, in the capture flow")
struct ScreencastOverlaysWiringTests {
    // MARK: Drawing

    @available(macOS 15, *)
    @Test("A video's drawing goes up on the recorded screen when the picker closes, and is in the recording from its start")
    func drawingBeforeTheStart() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        #expect(flows.wiring.overlays == nil)

        var drawingIDs: [CGWindowID] = []
        try await flows.record(showsShortcuts: false) {
            // The countdown is off, so the recorder is starting now; the drawing is already up.
            let overlays = flows.wiring.overlays
            #expect(overlays?.isShown == true)
            drawingIDs = overlays?.overlayWindowIDs ?? []
            #expect(drawingIDs.count == 1, "the left screen only")
            #expect(overlays?.layer.window(on: PickerScreens.left.id) != nil)
            #expect(flows.wiring.includedWindowIDs == Set(drawingIDs), "asked of the recorder before it starts")
            flows.showOwnWindows(drawingIDs)
        }
        #expect(flows.exceptedWindows == drawingIDs, "the first stream's filter has the drawing")
        #expect(flows.recorder.overlayWindows == Set(drawingIDs))
        await flows.stop()
    }

    @available(macOS 15, *)
    @Test("At the end everything comes down: the drawing leaves the recorder and the bar loses its Draw button")
    func endTakesItDown() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        try await flows.record()
        let bar = try #require(flows.controls.bar)
        let overlays = try #require(flows.wiring.overlays)
        #expect(bar.model.showsDrawButton)

        bar.model.toggleDrawing()
        #expect(overlays.isDrawing && bar.isDrawing)

        await flows.stop()
        #expect(flows.wiring.overlays == nil)
        #expect(!overlays.isShown && !overlays.isDrawing)
        #expect(!bar.model.showsDrawButton && !bar.isDrawing)
        #expect(flows.recorder.overlayWindows.isEmpty, "the recorder keeps overlays otherwise")
        #expect(flows.wiring.includedWindowIDs.isEmpty)
        #expect(!flows.keyDisplay.holds(.screencast))
    }

    @available(macOS 15, *)
    @Test("The Draw shortcut toggles drawing, as the bar's button does")
    func drawShortcut() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        try await flows.record()
        let overlays = try #require(flows.wiring.overlays)
        flows.controls.perform(.screencastDraw)
        #expect(overlays.isDrawing)
        flows.controls.perform(.screencastDraw)
        #expect(!overlays.isDrawing)
        await flows.stop()
    }

    @available(macOS 15, *)
    @Test("Stopping takes the pointer back from the drawing while the files finish")
    func stoppingEndsDrawing() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        try await flows.record()
        let overlays = try #require(flows.wiring.overlays)
        overlays.startDrawing()
        flows.wiring.phaseChanged(.finishing)
        #expect(!overlays.isDrawing && overlays.isShown)
        await flows.stop()
    }

    @available(macOS 15, *)
    @Test("The drawing tools' choices carry over to the next recording")
    func toolsRemembered() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        try await flows.record()
        #expect(flows.wiring.overlays?.style == ScreencastDrawingStyle(), "a red pen that fades, the first time")
        flows.wiring.overlays?.style = ScreencastDrawingStyle(tool: .arrow, color: .blue, lifetime: .stays)
        await flows.stop()

        try await flows.record()
        #expect(flows.wiring.overlays?.style == ScreencastDrawingStyle(tool: .arrow, color: .blue, lifetime: .stays))
        await flows.stop()
    }

    @available(macOS 15, *)
    @Test("A screenshot puts nothing on screen")
    func screenshotHasNone() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        flows.controller.open()
        let picker = try #require(flows.controller.picker)
        picker.kind = .screenshot
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        flows.controller.confirm()
        #expect(flows.wiring.overlays == nil && !flows.keyDisplay.holds(.screencast))
        #expect(await ScreencastWait.until { flows.controller.phase == .idle })
        #expect(flows.wiring.overlays == nil && flows.recorder.overlayWindows.isEmpty)
    }

    @available(macOS 15, *)
    @Test("Cancelling while the recording starts takes the overlays down and lets go of the key display")
    func cancelWhileStarting() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        flows.flow.captureSystem.holdsVideoStart = true
        flows.controller.open()
        let picker = try #require(flows.controller.picker)
        picker.target = .screen
        picker.clickScreen(PickerScreens.left)
        flows.controller.confirm()
        #expect(flows.wiring.overlays != nil && flows.keyDisplay.holds(.screencast))

        flows.controller.cancel()
        #expect(flows.controller.phase == .idle)
        #expect(flows.wiring.overlays == nil && !flows.keyDisplay.holds(.screencast))
        #expect(flows.wiring.includedWindowIDs.isEmpty)
        // The cancelled start winds down once its stream lets go.
        #expect(await ScreencastWait.until {
            flows.flow.captureSystem.videoStreams.forEach { $0.releaseStart() }
            return flows.recorder.state == .idle
        })
        await flows.wiring.recorderUpdated()
        #expect(flows.recorder.overlayWindows.isEmpty)
    }

    // MARK: The shortcuts you press

    @available(macOS 15, *)
    @Test("Show shortcuts on: the key display holds the recorded screen, shortcuts only, in Keystrokes' style, and is in the recording")
    func shortcutsOn() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        let plugin = KeyDisplayConfiguration(style: .bezel, position: .bottomLeft, keys: .allKeys, namesActions: false, size: .large, linger: 3, showsClicks: true)
        flows.turnOnKeystrokes(plugin)

        var keyIDs: Set<CGWindowID> = []
        try await flows.record(showsShortcuts: true) {
            #expect(flows.keyDisplay.holds(.screencast))
            keyIDs = ScreencastOverlaysWiring.windowIDs(of: flows.keyDisplay.overlayWindows)
            #expect(keyIDs.count == 1, "a window on the recorded screen for the whole recording")
            let drawing = flows.wiring.overlays?.overlayWindowIDs ?? []
            #expect(flows.wiring.includedWindowIDs == keyIDs.union(drawing))
            flows.showOwnWindows(drawing + keyIDs.sorted())
        }
        let configuration = try #require(flows.keyDisplay.configuration)
        #expect(configuration.keys == .shortcutsOnly, "never typing, even with the plugin on All keys")
        #expect(configuration.displays == [PickerScreens.left.id])
        #expect(configuration.style == .bezel && configuration.position == .bottomLeft && configuration.size == .large)
        #expect(configuration.linger == 3 && !configuration.namesActions)
        #expect(!configuration.showsClicks, "clicks are ScreenCaptureKit's, in the video only")
        #expect(flows.presenter.last?.keepsWindowsOnScreen == true)
        #expect(flows.recorder.overlayWindows.isSuperset(of: keyIDs))
        #expect(Set(flows.exceptedWindows ?? []).isSuperset(of: keyIDs), "in the first stream's filter")

        flows.type()
        #expect(flows.presenter.last?.entries.isEmpty == true, "typing doesn't show")
        flows.type(kVK_ANSI_C, modifiers: [.command])
        #expect(flows.presenter.last?.entries.count == 1, "⌘C does")

        await flows.stop()
        #expect(!flows.keyDisplay.holds(.screencast))
        #expect(flows.keyDisplay.holds(.keystrokes), "the plugin still shows keys")
        #expect(flows.keyDisplay.configuration?.keys == .allKeys)
        #expect(flows.recorder.overlayWindows.isEmpty)
    }

    @available(macOS 15, *)
    @Test("Show shortcuts on with Keystrokes off: the display uses its defaults, and goes when the recording ends")
    func shortcutsOnPluginOff() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        try await flows.record(showsShortcuts: true)
        var expected = KeyDisplayConfiguration()
        expected.displays = [PickerScreens.left.id]
        #expect(flows.keyDisplay.configuration == expected)
        #expect(flows.keyDisplay.owners == [.screencast])
        await flows.stop()
        #expect(!flows.keyDisplay.isShowing)
        #expect(flows.keyDisplay.overlayWindows.isEmpty)
    }

    @available(macOS 15, *)
    @Test("Show shortcuts off: no key display window ever reaches the recording, even with Keystrokes on in All keys")
    func shortcutsOffNeverRecordsKeys() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        var askedFor: [CGWindowID] = []
        let recorder = flows.recorder
        // Every window the overlays ever give the recorder.
        flows.wiring.attach(
            choice: { [controller = flows.controller] in controller.choice },
            bar: { [controls = flows.controls] in controls.bar },
            include: { id in
                askedFor.append(id)
                await recorder.includeOverlayWindow(id)
            },
            remove: { id in await recorder.removeOverlayWindow(id) }
        )

        flows.turnOnKeystrokes(KeyDisplayConfiguration(keys: .allKeys))
        flows.type()
        #expect(!flows.keyDisplay.overlayWindows.isEmpty, "the plugin is showing typing")

        try await flows.record(showsShortcuts: false) {
            flows.showOwnWindows(ScreencastOverlaysWiring.windowIDs(of: flows.keyDisplay.overlayWindows).sorted())
        }
        #expect(!flows.keyDisplay.holds(.screencast))
        #expect(flows.keyDisplay.configuration?.keys == .allKeys, "the plugin's display is left as it is")
        for keyCode in [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_C] {
            flows.type(keyCode)
            flows.type(keyCode, modifiers: [.command])
        }
        flows.keyDisplay.expire()
        flows.type()
        await flows.wiring.recorderUpdated()

        let drawing = try #require(flows.wiring.overlays?.overlayWindowIDs)
        let keyWindows = flows.presenter.everWindowIDs
        #expect(!keyWindows.isEmpty)
        #expect(Set(askedFor) == Set(drawing), "only the drawing")
        #expect(Set(askedFor).isDisjoint(with: keyWindows))
        #expect(flows.recorder.overlayWindows.isDisjoint(with: keyWindows))
        #expect(Set(flows.exceptedWindows ?? []).isDisjoint(with: keyWindows), "the filter leaves them out")

        await flows.stop()
        #expect(Set(askedFor).isDisjoint(with: flows.presenter.everWindowIDs))
    }

    // MARK: Rules

    @Test("The key display's configuration while recording keeps the plugin's style and nothing else of it")
    func keyConfiguration() {
        let displays: Set<CGDirectDisplayID> = [1, 2]
        var expected = KeyDisplayConfiguration()
        expected.displays = displays
        #expect(ScreencastOverlaysWiring.keyConfiguration(plugin: nil, displays: displays) == expected)

        let plugin = KeyDisplayConfiguration(style: .bezel, position: .bottomRight, keys: .allKeys, namesActions: false, size: .small, linger: 5, showsClicks: true)
        let recording = ScreencastOverlaysWiring.keyConfiguration(plugin: plugin, displays: displays)
        #expect(recording == KeyDisplayConfiguration(
            style: .bezel, position: .bottomRight, keys: .shortcutsOnly, namesActions: false, size: .small, linger: 5,
            showsClicks: false, displays: displays
        ))
    }

    @Test("A connected screen is used as it is; a made-up one by its frame, within the visible part of the screen under it")
    func displays() {
        let laptop = ScreencastOverlayDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
        let halves = ScreencastScreenLayout(screens: [
            ScreencastScreen(id: 9_001, frame: CGRect(x: 0, y: 0, width: 756, height: 982), scale: 2),
            ScreencastScreen(id: 1, frame: laptop.frame, scale: 2),
        ])
        let displays = ScreencastOverlaysWiring.displays(in: halves, connected: [laptop])
        #expect(displays == [
            ScreencastOverlayDisplay(id: 9_001, frame: CGRect(x: 0, y: 0, width: 756, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 756, height: 879)),
            laptop,
        ])
        let alone = ScreencastOverlaysWiring.displays(in: PickerScreens.leftOnly, connected: [])
        #expect(alone == [ScreencastOverlayDisplay(id: 1, frame: PickerScreens.left.frame, visibleFrame: PickerScreens.left.frame)])
    }

    @Test("The drawing tools' memory keeps the tool, the color, and fade or stay, and falls back to the defaults")
    func drawingMemory() {
        let defaults = InMemoryDefaults()
        let memory = ScreencastDrawingMemory(defaults: defaults)
        #expect(memory.style == ScreencastDrawingStyle())
        let style = ScreencastDrawingStyle(tool: .highlighter, color: .yellow, lifetime: .stays)
        memory.save(style)
        #expect(ScreencastDrawingMemory(defaults: defaults).style == style)
        defaults.set(["tool": "laser", "color": "blue", "lifetime": 7] as [String: Any], forKey: ScreencastDrawingMemory.key)
        #expect(memory.style == ScreencastDrawingStyle(color: .blue), "what it doesn't know falls back")
        #expect(AppPreferences(defaults: defaults).screencastDrawingMemory.style == memory.style)
    }

    @available(macOS 15, *)
    @Test("Apply gives the overlays the app's shortcut coordinator, which takes the drawing keys while drawing")
    func applyGivesTheKeys() async throws {
        let flows = OverlaysFlow()
        defer { flows.flow.captures.remove() }
        let backend = DrawingHotKeyBackend()
        flows.wiring.apply(CapabilityContext(
            enabledCapabilities: [.screencast],
            preferences: AppPreferences(defaults: flows.defaults),
            shortcuts: GlobalShortcutCoordinator(backend: backend),
            permissions: PermissionCoordinator(screenRecordingAuthorized: { true }),
            permissionReadiness: { capabilities in
                PermissionReadinessSnapshot.resolve(enabledCapabilities: capabilities, states: [:], permissionsRequiringRelaunch: [])
            }
        ))
        try await flows.record()
        flows.wiring.overlays?.startDrawing()
        #expect(Set(backend.registered.values) == Set(ScreencastDrawingKey.allCases.map(\.binding)))
        await flows.stop()
        #expect(backend.registered.isEmpty)
    }
}

/// Drawing keys pressed in Keybumps's own windows.
@Suite("Screencast: the drawing keys in Keybumps's windows")
struct ScreencastDrawingKeyMatchingTests {
    @Test("A key-down is a drawing key only with exactly its modifiers")
    func matching() {
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_Escape), modifiers: []) == .end)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_Escape), modifiers: [.capsLock, .function]) == .end)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_Escape), modifiers: [.command]) == nil)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_Delete), modifiers: []) == .clear)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_Delete), modifiers: [.option]) == nil)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command]) == .undo)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift]) == nil)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_ANSI_Z), modifiers: []) == nil)
        #expect(ScreencastDrawingKey.matching(keyCode: UInt16(kVK_ANSI_A), modifiers: []) == nil)
    }
}
