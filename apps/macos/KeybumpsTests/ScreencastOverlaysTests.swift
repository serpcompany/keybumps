import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// Keys registered while drawing, kept so a test can press them.
@MainActor
final class FakeDrawingKeys: ScreencastDrawingKeyRegistering {
    private(set) var bindings: [String: ShortcutBinding] = [:]
    private var handlers: [String: () -> Void] = [:]

    func register(owner: String, binding: ShortcutBinding, handler: @escaping () -> Void) -> Bool {
        bindings[owner] = binding
        handlers[owner] = handler
        return true
    }

    func unregister(owner: String) {
        bindings[owner] = nil
        handlers[owner] = nil
    }

    func press(_ key: ScreencastDrawingKey) {
        handlers[key.owner]?()
    }
}

/// The connected displays, which a test plugs in and takes away.
@MainActor
final class FakeOverlayDisplays {
    /// A laptop with the menu bar and the Dock, a display to its right, and one to its left.
    static let laptop = ScreencastOverlayDisplay(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879)
    )
    static let right = ScreencastOverlayDisplay(
        id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055)
    )
    static let left = ScreencastOverlayDisplay(
        id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055)
    )

    var connected = [laptop, right, left]
}

/// A clock the test moves.
final class FakeDrawingClock {
    var now: TimeInterval = 100
}

/// The overlays with fake displays, keys, and clock. Nothing here orders a window in: the drawing
/// layer's windows, its borders, and the tools are made but never shown, as under the unit-test
/// host anyway.
@MainActor
@Suite("Screencast: on screen while recording")
struct ScreencastOverlaysTests {
    let displays = FakeOverlayDisplays()
    let keys = FakeDrawingKeys()
    let clock = FakeDrawingClock()

    func makeOverlays(tickInterval: TimeInterval? = nil) -> ScreencastOverlays {
        let displays = displays, clock = clock
        return ScreencastOverlays(
            keys: keys,
            displays: { displays.connected },
            clock: { clock.now },
            tickInterval: tickInterval,
            ordersWindowsIn: false
        )
    }

    /// Draws one mark on `display` through the pointer, as the drawing layer's view would.
    func drag(_ overlays: ScreencastOverlays, on display: CGDirectDisplayID = 1, from start: CGPoint = CGPoint(x: 100, y: 100), to end: CGPoint = CGPoint(x: 300, y: 200)) {
        overlays.pointerDown(at: start, on: display)
        overlays.pointerDragged(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), on: display)
        overlays.pointerUp(at: end, on: display)
    }

    // MARK: The drawing layer's windows

    @Test("One drawing window per recorded display, none on the others, and their IDs reported")
    func windowPerRecordedDisplay() throws {
        let overlays = makeOverlays()
        var changes: [[CGWindowID]] = []
        overlays.onOverlayWindowsChange = { changes.append($0) }
        overlays.show(on: [1, 3])

        let ids = overlays.overlayWindowIDs
        #expect(ids.count == 2 && Set(ids).count == 2 && ids.allSatisfy { $0 > 0 })
        #expect(changes == [ids])
        let laptop = try #require(overlays.layer.window(on: 1))
        let left = try #require(overlays.layer.window(on: 3))
        #expect(ids == [laptop.windowID, left.windowID])
        #expect(laptop.frame == FakeOverlayDisplays.laptop.frame)
        #expect(left.frame == FakeOverlayDisplays.left.frame)
        #expect(overlays.layer.window(on: 2) == nil && overlays.layer.borderWindow(on: 2) == nil)
        #expect(overlays.layer.borderWindow(on: 1)?.frame == FakeOverlayDisplays.laptop.visibleFrame)

        // Nothing is on screen under the unit-test host.
        for display: CGDirectDisplayID in [1, 3] {
            #expect(overlays.layer.window(on: display)?.isVisible == false)
            #expect(overlays.layer.borderWindow(on: display)?.isVisible == false)
        }
        #expect(!overlays.toolbar.panel.isVisible)
        overlays.hide()
    }

    @Test("Not drawing, the drawing layer lets every click through; drawing, it takes them and shows the border")
    func hitThrough() throws {
        #expect(ScreencastDrawingLayer.ignoresMouseEvents(isDrawing: false))
        #expect(!ScreencastDrawingLayer.ignoresMouseEvents(isDrawing: true))

        let overlays = makeOverlays()
        overlays.show(on: [1, 2])
        let windows = [1, 2].compactMap { overlays.layer.window(on: $0) }
        let borders = [1, 2].compactMap { overlays.layer.borderWindow(on: $0) }
        #expect(windows.count == 2 && borders.count == 2)

        #expect(windows.allSatisfy { $0.ignoresMouseEvents })
        #expect(borders.allSatisfy { $0.ignoresMouseEvents && !$0.isShowingBorder })
        #expect(overlays.toolbar.panel.ignoresMouseEvents && !overlays.toolbar.isShowing)

        overlays.toggleDrawing()
        #expect(overlays.isDrawing)
        #expect(windows.allSatisfy { !$0.ignoresMouseEvents })
        #expect(borders.allSatisfy { $0.ignoresMouseEvents && $0.isShowingBorder }, "the border never takes a click")
        #expect(!overlays.toolbar.panel.ignoresMouseEvents && overlays.toolbar.isShowing)

        overlays.toggleDrawing()
        #expect(!overlays.isDrawing)
        #expect(windows.allSatisfy { $0.ignoresMouseEvents })
        #expect(borders.allSatisfy { !$0.isShowingBorder })
        #expect(overlays.toolbar.panel.ignoresMouseEvents && !overlays.toolbar.isShowing)
        overlays.hide()
    }

    @Test("The windows keep their IDs from the start of the recording to its end")
    func stableIDs() {
        let overlays = makeOverlays()
        var changes: [[CGWindowID]] = []
        overlays.onOverlayWindowsChange = { changes.append($0) }
        overlays.show(on: [1, 2])
        let ids = overlays.overlayWindowIDs

        for _ in 0..<3 {
            overlays.toggleDrawing()
            drag(overlays)
        }
        overlays.clear()
        overlays.refreshDisplays()
        #expect(overlays.overlayWindowIDs == ids)
        #expect(changes == [ids], "nothing changed, so nothing was reported again")
        overlays.hide()
    }

    @Test("A recorded display that goes loses its window, and gets a new one when it comes back")
    func displaysComeAndGo() throws {
        let overlays = makeOverlays()
        var changes: [[CGWindowID]] = []
        overlays.onOverlayWindowsChange = { changes.append($0) }
        overlays.show(on: [1, 3])
        let laptop = try #require(overlays.layer.window(on: 1)?.windowID)
        let left = try #require(overlays.layer.window(on: 3)?.windowID)

        #expect(changes == [[laptop, left]])

        displays.connected = [FakeOverlayDisplays.laptop, FakeOverlayDisplays.right]
        overlays.refreshDisplays()
        #expect(overlays.overlayWindowIDs == [laptop])
        #expect(changes.last == [laptop])
        #expect(overlays.layer.window(on: 3) == nil && overlays.layer.borderWindow(on: 3) == nil)

        displays.connected = [FakeOverlayDisplays.laptop, FakeOverlayDisplays.right, FakeOverlayDisplays.left]
        overlays.refreshDisplays()
        let back = try #require(overlays.layer.window(on: 3)?.windowID)
        #expect(overlays.overlayWindowIDs == [laptop, back])
        #expect(changes.last == [laptop, back])
        #expect(overlays.layer.window(on: 2) == nil, "a display that isn't recorded never gets one")
        #expect(changes.count == 3)
        overlays.hide()
    }

    @Test("A recorded display that moves keeps its window, moved with it")
    func displayMoves() throws {
        let overlays = makeOverlays()
        var changes = 0
        overlays.onOverlayWindowsChange = { _ in changes += 1 }
        overlays.show(on: [2])
        let id = try #require(overlays.layer.window(on: 2)?.windowID)

        let moved = ScreencastOverlayDisplay(
            id: 2, frame: CGRect(x: 1512, y: -98, width: 2560, height: 1440), visibleFrame: CGRect(x: 1512, y: -98, width: 2560, height: 1415)
        )
        displays.connected = [FakeOverlayDisplays.laptop, moved]
        overlays.refreshDisplays()
        #expect(overlays.layer.window(on: 2)?.windowID == id)
        #expect(overlays.layer.window(on: 2)?.frame == moved.frame)
        #expect(overlays.layer.borderWindow(on: 2)?.frame == moved.visibleFrame)
        #expect(changes == 1)
        overlays.hide()
    }

    @Test("Hiding closes every window, reports none, stops drawing, and clears the marks")
    func hide() {
        let overlays = makeOverlays()
        var changes: [[CGWindowID]] = []
        var drawingChanges: [Bool] = []
        overlays.onOverlayWindowsChange = { changes.append($0) }
        overlays.onDrawingChange = { drawingChanges.append($0) }
        overlays.show(on: [1, 2])
        overlays.startDrawing()
        drag(overlays)
        #expect(overlays.hasMarks && !keys.bindings.isEmpty)

        overlays.hide()
        #expect(changes.last == [])
        #expect(overlays.overlayWindowIDs.isEmpty)
        #expect(overlays.layer.window(on: 1) == nil)
        #expect(!overlays.isShown && !overlays.isDrawing)
        #expect(!overlays.hasMarks && overlays.drawing.isEmpty)
        #expect(keys.bindings.isEmpty, "the drawing keys are given back")
        #expect(drawingChanges == [true, false])
        #expect(!overlays.toolbar.isOnScreen)
    }

    @Test("Drawing doesn't start before the overlays show, or with no recorded display connected")
    func drawingNeedsADisplay() {
        let overlays = makeOverlays()
        overlays.toggleDrawing()
        #expect(!overlays.isDrawing)

        overlays.show(on: [9])
        #expect(overlays.overlayWindowIDs.isEmpty)
        overlays.toggleDrawing()
        #expect(!overlays.isDrawing && keys.bindings.isEmpty)
        overlays.hide()
    }

    @Test("A recorded display going away while drawing on it alone stops drawing")
    func lastDisplayGoes() {
        let overlays = makeOverlays()
        overlays.show(on: [3])
        overlays.startDrawing()
        displays.connected = [FakeOverlayDisplays.laptop]
        overlays.refreshDisplays()
        #expect(!overlays.isDrawing && keys.bindings.isEmpty)
        overlays.hide()
    }

    // MARK: Where the windows sit

    @Test("The drawing layer sits above ordinary windows and below the control bar and the tools")
    func levels() throws {
        let level = ScreencastDrawingLayer.level
        #expect(level.rawValue > NSWindow.Level.normal.rawValue)
        #expect(level.rawValue < ScreencastControlBarPanel().level.rawValue)
        #expect(level.rawValue < ScreencastDrawingToolbarPanel().level.rawValue)
        #expect(ScreencastDrawingToolbarPanel().level == ScreencastControlBarPanel().level)

        let overlays = makeOverlays()
        overlays.show(on: [1])
        #expect(try #require(overlays.layer.window(on: 1)).level == level)
        #expect(try #require(overlays.layer.borderWindow(on: 1)).level == level)
        overlays.hide()
    }

    @Test("The drawing windows never take the keyboard or activate Keybumps, and can be recorded")
    func windowConfiguration() throws {
        let overlays = makeOverlays()
        overlays.show(on: [1])
        let window = try #require(overlays.layer.window(on: 1))
        let border = try #require(overlays.layer.borderWindow(on: 1))
        let tools = overlays.toolbar.panel
        for panel in [window, border, tools] as [NSPanel] {
            #expect(!panel.canBecomeKey && !panel.canBecomeMain)
            #expect(panel.styleMask.contains(.nonactivatingPanel) && !panel.styleMask.contains(.titled))
            #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(!panel.hidesOnDeactivate && !panel.canHide)
            #expect(!panel.isOpaque && panel.backgroundColor == .clear)
            // The recorder's filter decides what's in the video, never sharingType.
            #expect(panel.sharingType != .none)
        }
        #expect(window.identifier == ScreencastDrawingWindow.identifier)
        #expect(border.identifier == ScreencastDrawingBorderWindow.identifier)
        #expect(tools.identifier == ScreencastDrawingToolbarPanel.identifier)
        #expect(window.canvas.isFlipped, "marks are in points from the display's top-left corner")
        #expect(window.canvas.acceptsFirstMouse(for: nil), "the first press draws")
        overlays.hide()
    }

    // MARK: Drawing

    @Test("The pointer draws a mark with the chosen tool, color, and lifetime, on its own display")
    func drawThroughThePointer() throws {
        let overlays = makeOverlays()
        overlays.show(on: [1, 2])
        overlays.startDrawing()
        overlays.style = ScreencastDrawingStyle(tool: .arrow, color: .blue, lifetime: .stays)
        drag(overlays, on: 2, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 120))

        let mark = try #require(overlays.drawing.marks.first)
        #expect(overlays.drawing.marks.count == 1)
        #expect(mark.kind == .arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 120)))
        #expect(mark.color == .blue && mark.lifetime == .stays && mark.display == 2)
        #expect(overlays.hasMarks)
        #expect(overlays.visibleMarks(on: 2).map(\.mark.id) == [mark.id])
        #expect(overlays.visibleMarks(on: 1).isEmpty)

        overlays.style.tool = .rectangle
        drag(overlays, on: 1)
        #expect(overlays.drawing.marks.map(\.tool) == [.arrow, .rectangle])
        #expect(overlays.drawing.marks.last?.display == 1)
        overlays.hide()
    }

    @Test("While not drawing, the pointer draws nothing")
    func noDrawingWhileOff() {
        let overlays = makeOverlays()
        overlays.show(on: [1])
        drag(overlays)
        #expect(overlays.drawing.isEmpty && !overlays.hasMarks)
        overlays.hide()
    }

    @Test("Marks that fade go after a few seconds by the overlays' clock; marks that stay, stay")
    func fadingByTheClock() {
        // A timer that never fires during the test, so ticking can be seen to start and stop.
        let overlays = makeOverlays(tickInterval: 3_600)
        overlays.show(on: [1])
        overlays.startDrawing()
        drag(overlays)
        overlays.style.lifetime = .stays
        drag(overlays, from: CGPoint(x: 400, y: 400), to: CGPoint(x: 500, y: 450))
        #expect(overlays.drawing.marks.map(\.lifetime) == [.fades, .stays])
        #expect(overlays.isTicking)

        clock.now = 100 + ScreencastDrawing.life + ScreencastDrawing.fade / 2
        overlays.tick()
        #expect(overlays.visibleMarks(on: 1).map(\.opacity) == [0.5, 1])
        #expect(overlays.isTicking)

        clock.now = 100 + ScreencastDrawing.life + ScreencastDrawing.fade
        overlays.tick()
        #expect(overlays.drawing.marks.map(\.lifetime) == [.stays])
        #expect(overlays.hasMarks)
        #expect(!overlays.isTicking, "nothing fades, so nothing ticks")

        clock.now = 10_000
        overlays.tick()
        #expect(overlays.drawing.marks.count == 1)
        overlays.hide()
    }

    @Test("Undo removes the last mark and Clear removes them all; neither needs drawing to be on")
    func undoAndClear() {
        let overlays = makeOverlays()
        overlays.show(on: [1, 2])
        overlays.startDrawing()
        drag(overlays, on: 1)
        drag(overlays, on: 2)
        drag(overlays, on: 1)
        overlays.endDrawing()

        overlays.undo()
        #expect(overlays.drawing.marks.map(\.display) == [1, 2])
        overlays.clear()
        #expect(overlays.drawing.isEmpty && !overlays.hasMarks)
        overlays.undo()
        #expect(overlays.drawing.isEmpty)
        overlays.hide()
    }

    // MARK: Keys

    @Test("Escape, Delete, and ⌘Z are taken only while drawing")
    func keysWhileDrawing() {
        let overlays = makeOverlays()
        overlays.show(on: [1])
        #expect(keys.bindings.isEmpty)

        overlays.startDrawing()
        #expect(keys.bindings == [
            "screencast.draw.end": ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, displayName: "Escape"),
            "screencast.draw.clear": ShortcutBinding(keyCode: UInt32(kVK_Delete), modifiers: 0, displayName: "⌫"),
            "screencast.draw.undo": ShortcutBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey), displayName: "⌘Z"),
        ])

        drag(overlays)
        drag(overlays)
        keys.press(.undo)
        #expect(overlays.drawing.marks.count == 1)
        keys.press(.clear)
        #expect(overlays.drawing.isEmpty)

        var drawingChanges: [Bool] = []
        overlays.onDrawingChange = { drawingChanges.append($0) }
        keys.press(.end)
        #expect(!overlays.isDrawing && drawingChanges == [false])
        #expect(keys.bindings.isEmpty)
        overlays.hide()
    }

    @Test("Escape in the middle of a mark drops it")
    func escapeMidStroke() {
        let overlays = makeOverlays()
        overlays.show(on: [1])
        overlays.startDrawing()
        overlays.pointerDown(at: CGPoint(x: 10, y: 10), on: 1)
        overlays.pointerDragged(to: CGPoint(x: 80, y: 80), on: 1)
        keys.press(.end)
        #expect(overlays.drawing.isEmpty)
        // A release that arrives after drawing ended adds nothing.
        overlays.pointerUp(at: CGPoint(x: 90, y: 90), on: 1)
        #expect(overlays.drawing.isEmpty)
        overlays.hide()
    }

    @Test("The app's shortcut coordinator registers the drawing keys while drawing, and its Escape stops drawing")
    func coordinatorKeys() throws {
        let backend = DrawingHotKeyBackend()
        let coordinator = GlobalShortcutCoordinator(backend: backend)
        let displays = displays
        let overlays = ScreencastOverlays(keys: coordinator, displays: { displays.connected }, tickInterval: nil, ordersWindowsIn: false)
        overlays.show(on: [1])
        overlays.startDrawing()
        #expect(Set(backend.registered.values) == Set(ScreencastDrawingKey.allCases.map(\.binding)))

        let escape = try #require(backend.registered.first { $0.value.keyCode == UInt32(kVK_Escape) }?.key)
        backend.press(escape)
        #expect(!overlays.isDrawing)
        #expect(backend.registered.isEmpty)
        overlays.hide()
    }

    // MARK: The control bar

    @Test("The control bar's Draw button toggles drawing and follows Escape")
    func controlBar() {
        let overlays = makeOverlays()
        let recording = FakeBarRecording()
        let bar = ScreencastControlBar(recording: recording, defaults: InMemoryDefaults(), displays: { [] }, ordersPanelIn: false)
        #expect(!bar.model.showsDrawButton)
        overlays.show(on: [1])
        overlays.connect(to: bar)
        #expect(bar.model.showsDrawButton && !bar.isDrawing)

        bar.model.toggleDrawing()
        #expect(overlays.isDrawing && bar.isDrawing)
        keys.press(.end)
        #expect(!overlays.isDrawing && !bar.isDrawing)
        bar.model.toggleDrawing()
        bar.model.toggleDrawing()
        #expect(!overlays.isDrawing && !bar.isDrawing)
        #expect(recording.calls.isEmpty, "drawing never touches the recording")
        overlays.hide()
        #expect(!bar.isDrawing)
    }

    @Test("While drawing, the tools sit just above the control bar")
    func toolsAboveTheBar() {
        let overlays = makeOverlays()
        let bar = ScreencastControlBar(recording: FakeBarRecording(), defaults: InMemoryDefaults(), displays: { [] }, ordersPanelIn: false)
        overlays.show(on: [1])
        overlays.connect(to: bar)
        bar.show(on: ScreencastBarDisplay(key: "laptop", visibleFrame: FakeOverlayDisplays.laptop.visibleFrame))
        overlays.startDrawing()

        let tools = overlays.toolbar.panel.frame
        let barFrame = bar.panel.frame
        #expect(tools.width > 200 && tools.height > 20, "\(tools)")
        #expect(abs(tools.minY - (barFrame.maxY + ScreencastDrawingToolbar.gap)) < 1)
        #expect(abs(tools.midX - barFrame.midX) < 1)
        #expect(!overlays.toolbar.panel.isVisible)
        bar.hide()
        overlays.hide()
    }

    // MARK: The tools

    @Test("The tools go above the bar, below it with no room above, and stay on the display")
    func toolsPlacement() {
        let size = CGSize(width: 400, height: 42)
        let visible = FakeOverlayDisplays.laptop.visibleFrame
        let gap = ScreencastDrawingToolbar.gap

        let bar = CGRect(x: 556, y: 94, width: 400, height: 42)
        #expect(ScreencastDrawingToolbar.origin(for: size, above: bar, within: visible) == CGPoint(x: 556, y: 136 + gap))

        // A bar at the top of the display: the tools go under it.
        let high = CGRect(x: 556, y: visible.maxY - 42, width: 400, height: 42)
        #expect(ScreencastDrawingToolbar.origin(for: size, above: high, within: visible).y == high.minY - gap - 42)

        // A narrow bar at the right edge: the tools stay on the display.
        let edge = CGRect(x: visible.maxX - 200, y: 94, width: 200, height: 42)
        #expect(ScreencastDrawingToolbar.origin(for: size, above: edge, within: visible).x == visible.maxX - 400)

        // No bar: centered near the bottom.
        let alone = ScreencastDrawingToolbar.origin(for: size, above: nil, within: visible)
        #expect(alone == CGPoint(x: visible.midX - 200, y: visible.minY + ScreencastDrawingToolbar.bottomInset))
    }

    @Test("The tools' panel is on screen for the recording but empty and click-through except while drawing")
    func toolsPanel() {
        let overlays = makeOverlays()
        #expect(!overlays.toolbar.isOnScreen)
        overlays.show(on: [1])
        #expect(overlays.toolbar.isOnScreen && !overlays.toolbar.isShowing)
        #expect(overlays.toolbar.panel.ignoresMouseEvents)
        overlays.startDrawing()
        #expect(overlays.toolbar.isShowing && !overlays.toolbar.panel.ignoresMouseEvents)
        #expect(overlays.toolbar.panel.contentView?.isHidden == false)
        #expect(overlays.toolbar.panel.frame.width > 0)
        overlays.endDrawing()
        #expect(overlays.toolbar.panel.contentView?.isHidden == true)
        overlays.hide()
        #expect(!overlays.toolbar.isOnScreen)
    }

    @Test("Every symbol the tools draw is one macOS has")
    func toolSymbols() {
        let names = ScreencastDrawingTool.allCases.map(\.systemImage) + ["arrow.uturn.backward", "eraser"]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test("Each tool's accessibility identifier is its own, under screencast.draw")
    func identifiers() {
        let identifiers = ScreencastDrawingTool.allCases.map(ScreencastDrawingToolbarID.tool)
            + ScreencastDrawingColor.allCases.map(ScreencastDrawingToolbarID.color)
            + ScreencastMarkLifetime.allCases.map(ScreencastDrawingToolbarID.lifetime)
            + [ScreencastDrawingToolbarID.undo, ScreencastDrawingToolbarID.clear]
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.allSatisfy { $0.hasPrefix("screencast.draw.") })
        #expect(ScreencastDrawingToolbarID.tool(.pen) == "screencast.draw.tool.pen")
    }

    @Test("The drawing keys each have their own owner, apart from every other shortcut's")
    func keyOwners() {
        let owners = ScreencastDrawingKey.allCases.map(\.owner)
        #expect(Set(owners).count == owners.count)
        #expect(owners.allSatisfy { $0.hasPrefix("screencast.draw.") })
        #expect(Set(owners).isDisjoint(with: CapabilityShortcut.allCases.map(\.ownerID)))
        #expect(!owners.contains(DictationEscapeRegistration.ownerID))
    }
}

/// A hot-key backend that keeps what's registered and can press it.
@MainActor
private final class DrawingHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    private(set) var registered: [UInt32: ShortcutBinding] = [:]
    private var handler: ((UInt32) -> Void)?

    func installHandler(_ handler: @escaping (UInt32) -> Void) {
        self.handler = handler
    }

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
        registered[identifier] = binding
        return true
    }

    func unregister(identifier: UInt32) {
        registered[identifier] = nil
    }

    func press(_ identifier: UInt32) {
        handler?(identifier)
    }
}
