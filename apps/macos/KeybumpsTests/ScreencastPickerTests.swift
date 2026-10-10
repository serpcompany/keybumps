import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// The picker's geometry and state, with no window: the two global spaces, drawing an area, the
/// remembered area, which windows can be picked, and switching modes.
@MainActor
@Suite("Screencast: the picker")
struct ScreencastPickerTests {
    typealias Screens = ScreencastScreens
    let left = PickerScreens.left
    let right = PickerScreens.right
    let layout = PickerScreens.both

    // MARK: The two global spaces

    @Test("AppKit's bottom-left space and ScreenCaptureKit's top-left one convert both ways")
    func spaces() {
        #expect(layout.primaryHeight == 982)
        // The right display's top lines up with the main one's, so its AppKit frame starts below 0.
        #expect(layout.topLeftRect(fromAppKit: right.frame) == Screens.rightDisplay.frame)
        #expect(layout.appKitRect(fromTopLeft: Screens.browserWindow.frame) == CGRect(x: 100, y: 282, width: 800, height: 600))
        #expect(layout.appKitRect(fromTopLeft: layout.topLeftRect(fromAppKit: CGRect(x: 1600, y: -50, width: 10, height: 20)))
            == CGRect(x: 1600, y: -50, width: 10, height: 20))
        #expect(layout.topLeftPoint(fromAppKit: CGPoint(x: 150, y: 832)) == CGPoint(x: 150, y: 150))
    }

    @Test("An area drawn in AppKit's space becomes the display's top-left rect the recorder takes")
    func areaToDisplayRect() {
        let onRight = CGRect(x: 1612, y: 0, width: 400, height: 300)
        #expect(ScreencastTarget.displayLocalRect(fromAppKit: onRight, screenFrame: right.frame) == CGRect(x: 100, y: 682, width: 400, height: 300))
        let onLeft = CGRect(x: 100, y: 282, width: 800, height: 600)
        #expect(ScreencastTarget.displayLocalRect(fromAppKit: onLeft, screenFrame: left.frame) == CGRect(x: 100, y: 100, width: 800, height: 600))
    }

    @Test("A point on an edge two screens share is on one of them; a point in a gap is on none")
    func screenUnderPoint() {
        #expect(layout.screen(containing: CGPoint(x: 1512, y: 500))?.id == 2)
        #expect(layout.screen(containing: CGPoint(x: 1511.5, y: 500))?.id == 1)
        // The pointer at the very top of a screen is on it.
        #expect(layout.screen(containing: CGPoint(x: 100, y: 982))?.id == 1)
        #expect(layout.screen(containing: CGPoint(x: 100, y: 0)) == nil)
        #expect(layout.screen(containing: CGPoint(x: 100, y: -50)) == nil)
        #expect(layout.screen(mostOverlapping: CGRect(x: 1400, y: 100, width: 300, height: 100))?.id == 2)
        #expect(layout.screen(mostOverlapping: CGRect(x: -500, y: -500, width: 100, height: 100)) == nil)
    }

    // MARK: Drawing an area

    @Test("Dragging either way draws the same area, kept on its screen")
    func drawing() {
        var editor = ScreencastAreaEditor(bounds: left.frame)
        editor.press(at: CGPoint(x: 500, y: 400), on: left.frame)
        editor.drag(to: CGPoint(x: 200, y: 100))
        #expect(editor.isDrawing)
        editor.release()
        #expect(editor.rect == CGRect(x: 200, y: 100, width: 300, height: 300))
        #expect(editor.gesture == nil)

        // Past the screen's edge, it stops at the edge.
        editor.press(at: CGPoint(x: 1400, y: 900), on: left.frame)
        editor.drag(to: CGPoint(x: 1700, y: 1200))
        editor.release()
        #expect(editor.rect == CGRect(x: 1400, y: 900, width: 112, height: 82))
    }

    @Test("A press without a drag, or an area under the minimum, leaves no area")
    func tooSmall() {
        var editor = ScreencastAreaEditor(bounds: left.frame)
        editor.press(at: CGPoint(x: 500, y: 400), on: left.frame)
        editor.release()
        #expect(editor.rect == nil)
        editor.press(at: CGPoint(x: 500, y: 400), on: left.frame)
        editor.drag(to: CGPoint(x: 600, y: 410))
        editor.release()
        #expect(editor.rect == nil)
    }

    @Test("Dragging inside the area moves it, never past its screen's edges")
    func moving() {
        var editor = ScreencastAreaEditor(rect: CGRect(x: 100, y: 100, width: 200, height: 100), bounds: left.frame)
        editor.press(at: CGPoint(x: 150, y: 150), on: left.frame)
        #expect(editor.gesture == .moving(offset: CGVector(dx: 50, dy: 50)))
        editor.drag(to: CGPoint(x: 250, y: 350))
        #expect(editor.rect == CGRect(x: 200, y: 300, width: 200, height: 100))
        editor.drag(to: CGPoint(x: 5000, y: 5000))
        editor.release()
        #expect(editor.rect == CGRect(x: 1312, y: 882, width: 200, height: 100))
    }

    @Test("A corner resizes from the opposite corner; an edge moves only itself, never below the minimum")
    func resizing() {
        var editor = ScreencastAreaEditor(rect: CGRect(x: 100, y: 100, width: 200, height: 100), bounds: left.frame)
        // Top-right is at maxX, maxY in AppKit's unflipped space.
        editor.press(at: CGPoint(x: 300, y: 200), on: left.frame)
        #expect(editor.gesture == .resizing(.topRight))
        editor.drag(to: CGPoint(x: 400, y: 260))
        editor.release()
        #expect(editor.rect == CGRect(x: 100, y: 100, width: 300, height: 160))

        editor.press(at: CGPoint(x: 100, y: 180), on: left.frame)
        #expect(editor.gesture == .resizing(.left))
        editor.drag(to: CGPoint(x: 900, y: 0))
        editor.release()
        #expect(editor.rect == CGRect(x: 400 - ScreencastAreaEditor.minimumSize, y: 100, width: ScreencastAreaEditor.minimumSize, height: 160))
    }

    @Test("Where a corner's handle and an edge's overlap, the corner wins")
    func cornersFirst() {
        // The top edge's handle, at (112, 124), reaches both top corners' handles.
        let editor = ScreencastAreaEditor(rect: CGRect(x: 100, y: 100, width: 24, height: 24), bounds: left.frame)
        #expect(editor.handle(at: CGPoint(x: 106, y: 124)) == .topLeft)
        #expect(editor.handle(at: CGPoint(x: 118, y: 124)) == .topRight)
        #expect(ScreencastAreaEditor(rect: CGRect(x: 100, y: 100, width: 300, height: 300), bounds: left.frame)
            .handle(at: CGPoint(x: 250, y: 402)) == .top)
    }

    @Test("Pressing on another screen starts a new area there")
    func otherScreen() {
        var editor = ScreencastAreaEditor(rect: CGRect(x: 100, y: 100, width: 200, height: 100), bounds: left.frame)
        editor.press(at: CGPoint(x: 1600, y: 0), on: right.frame)
        editor.drag(to: CGPoint(x: 1700, y: 200))
        editor.release()
        #expect(editor.bounds == right.frame)
        #expect(editor.rect == CGRect(x: 1600, y: 0, width: 100, height: 200))
    }

    // MARK: The remembered area

    @Test("The last area comes back on its screen, and only in memory")
    func rememberedArea() throws {
        let defaults = InMemoryDefaults()
        let memory = ScreencastAreaMemory(defaults: defaults)
        #expect(memory.area(in: layout) == nil)
        memory.save(CGRect(x: 1612, y: 0, width: 400, height: 300))
        #expect(memory.area(in: layout) == ScreencastPickedArea(display: 2, rect: CGRect(x: 1612, y: 0, width: 400, height: 300)))
        #expect(defaults.leakedDomain == nil)
    }

    @Test("A remembered area on a display that's gone is dropped; one half off its screen is cut to fit")
    func rememberedAreaOffScreen() {
        let memory = ScreencastAreaMemory(defaults: InMemoryDefaults())
        memory.save(CGRect(x: 1612, y: 0, width: 400, height: 300))
        #expect(memory.area(in: PickerScreens.leftOnly) == nil)
        memory.save(CGRect(x: 1400, y: 800, width: 300, height: 300))
        #expect(memory.area(in: PickerScreens.leftOnly) == ScreencastPickedArea(display: 1, rect: CGRect(x: 1400, y: 800, width: 112, height: 182)))
        memory.save(CGRect(x: 1500, y: 0, width: 300, height: 300))
        // Only 12 points of it are left on the main screen.
        #expect(memory.area(in: PickerScreens.leftOnly) == nil)
    }

    @Test("A remembered area that isn't four numbers is ignored")
    func rememberedAreaMalformed() {
        let defaults = InMemoryDefaults()
        defaults.set(["x": "left", "y": 0, "width": 100, "height": 100], forKey: ScreencastAreaMemory.key)
        #expect(ScreencastAreaMemory(defaults: defaults).area(in: layout) == nil)
        defaults.set("an area", forKey: ScreencastAreaMemory.key)
        #expect(ScreencastAreaMemory(defaults: defaults).area(in: layout) == nil)
    }

    // MARK: Picking a window

    @Test("Only other apps' ordinary windows on a display can be picked; never Keybumps's own")
    func pickableWindows() {
        let tiny = ScreencastContent.Window(id: 40, frame: CGRect(x: 10, y: 10, width: 30, height: 300), layer: 0, processID: Screens.browser, isUntitled: false, isOnScreen: true)
        let hidden = ScreencastContent.Window(id: 41, frame: CGRect(x: 10, y: 10, width: 300, height: 300), layer: 0, processID: Screens.browser, isUntitled: false, isOnScreen: false)
        let offDisplay = ScreencastContent.Window(id: 42, frame: CGRect(x: -900, y: 10, width: 300, height: 300), layer: 0, processID: Screens.browser, isUntitled: false, isOnScreen: true)
        let ownOrdinary = ScreencastContent.Window(id: 32, frame: CGRect(x: 200, y: 200, width: 600, height: 400), layer: 0, processID: Screens.ownProcess, isUntitled: false, isOnScreen: true)
        let content = Screens.content(windows: [ownOrdinary, Screens.controlBar, Screens.browserWindow, Screens.browserMenu, tiny, hidden, offDisplay, Screens.otherAppWindow])
        let pickable = ScreencastWindowPicking.pickableWindows(in: content, ownProcessID: Screens.ownProcess)
        #expect(pickable.map(\.id) == [10, 20])
    }

    @Test("A window drawn with alpha 0 can't be picked, so the window under it takes the click")
    func transparentWindows() {
        let invisible = ScreencastContent.Window(id: 50, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 0, processID: Screens.otherApp, isUntitled: true, isOnScreen: true)
        let content = Screens.content(windows: [invisible, Screens.browserWindow])
        #expect(ScreencastWindowPicking.pickableWindows(in: content, ownProcessID: Screens.ownProcess).map(\.id) == [50, 10])
        let pickable = ScreencastWindowPicking.pickableWindows(in: content, ownProcessID: Screens.ownProcess, transparent: [50])
        #expect(pickable.map(\.id) == [10])
        #expect(ScreencastWindowPicking.window(at: CGPoint(x: 150, y: 150), in: pickable)?.id == 10)
    }

    @Test("The window under the pointer is the frontmost one there")
    func windowUnderPointer() {
        let windows = [Screens.browserOtherWindow, Screens.browserWindow]
        #expect(ScreencastWindowPicking.window(at: CGPoint(x: 250, y: 250), in: windows)?.id == 12)
        #expect(ScreencastWindowPicking.window(at: CGPoint(x: 150, y: 150), in: windows)?.id == 10)
        #expect(ScreencastWindowPicking.window(at: CGPoint(x: 1300, y: 900), in: windows) == nil)
    }

    @Test("Hovering and clicking take AppKit points, and a click on nothing keeps the window picked")
    func pickingInTheModel() {
        let model = PickerScreens.model()
        model.target = .window
        model.windows = ScreencastWindowPicking.pickableWindows(in: Screens.content(), ownProcessID: Screens.ownProcess)
        #expect(!model.canConfirm)
        // (150, 150) in the top-left space.
        model.hoverWindow(at: CGPoint(x: 150, y: 832))
        #expect(model.hoveredWindow == 10)
        model.clickWindow(at: CGPoint(x: 150, y: 832))
        #expect(model.selectedWindow == 10)
        model.clickWindow(at: CGPoint(x: 1400, y: 20))
        #expect(model.selectedWindow == 10)
        let choice = model.choice()
        #expect(choice?.target == .window(10))
        #expect(choice?.regions == [ScreencastChoice.Region(display: 1, frame: CGRect(x: 100, y: 282, width: 800, height: 600))])
    }

    @Test("A picked window that closes is no longer picked")
    func pickedWindowCloses() {
        let model = PickerScreens.model()
        model.target = .window
        model.windows = [Screens.browserWindow]
        model.clickWindow(at: CGPoint(x: 150, y: 832))
        model.windows = [Screens.otherAppWindow]
        #expect(model.selectedWindow == nil)
        #expect(model.choice() == nil)
    }

    // MARK: Modes and switches

    @Test("The switches start from the settings, and the microphone stays off without access")
    func switchesFromSettings() {
        let preferences = PickerScreens.preferences(microphone: true, systemAudio: false, shortcuts: false, clicks: true)
        let model = ScreencastPickerModel(layout: layout, preferences: preferences, microphoneAvailable: true)
        #expect(model.recordsMicrophone && !model.recordsSystemAudio && !model.showsShortcuts && model.highlightsClicks)
        let withoutAccess = ScreencastPickerModel(layout: layout, preferences: preferences, microphoneAvailable: false)
        #expect(!withoutAccess.recordsMicrophone)
        withoutAccess.recordsMicrophone = true
        withoutAccess.target = .screen
        #expect(withoutAccess.choice()?.audio == ScreencastAudio(microphone: false, systemAudio: false))
    }

    @Test("A screenshot captures with no sound, shortcuts, or clicks, and its button says Capture")
    func screenshotMode() {
        let model = PickerScreens.model(rememberedArea: ScreencastPickedArea(display: 1, rect: CGRect(x: 100, y: 282, width: 800, height: 600)))
        #expect(model.kind == .video && model.confirmTitle == "Record")
        #expect(model.choice()?.audio == ScreencastAudio(microphone: true, systemAudio: true))
        #expect(model.choice()?.showsShortcuts == true)
        model.kind = .screenshot
        #expect(model.confirmTitle == "Capture")
        let choice = model.choice()
        #expect(choice?.kind == .screenshot)
        #expect(choice?.audio == ScreencastAudio.none)
        #expect(choice?.showsShortcuts == false && choice?.highlightsClicks == false)
    }

    @Test("Switching between area, window, and screen keeps the area drawn and the window picked")
    func switchingTargets() {
        let area = ScreencastPickedArea(display: 2, rect: CGRect(x: 1612, y: 0, width: 400, height: 300))
        let model = PickerScreens.model(rememberedArea: area)
        #expect(model.target == .area && model.area == area)
        #expect(model.choice()?.target == .area(display: 2, rect: CGRect(x: 100, y: 682, width: 400, height: 300)))
        #expect(model.choice()?.area == area)
        model.target = .window
        #expect(!model.canConfirm)
        model.windows = [Screens.browserWindow]
        model.clickWindow(at: CGPoint(x: 150, y: 832))
        model.target = .screen
        #expect(model.choice()?.target == .everyDisplay)
        #expect(model.choice()?.regions.map(\.display) == [1, 2])
        model.target = .area
        #expect(model.area == area)
        model.target = .window
        #expect(model.choice()?.target == .window(10))
    }

    @Test("Screen mode records the screen clicked, or every screen again")
    func oneScreenOfTwo() {
        let model = PickerScreens.model()
        model.target = .screen
        #expect(model.offersEveryScreen)
        #expect(model.isChosen(left) && model.isChosen(right))
        #expect(model.choice()?.target == .everyDisplay)
        model.clickScreen(right)
        #expect(model.choice()?.target == .display(2))
        #expect(model.choice()?.regions == [ScreencastChoice.Region(display: 2, frame: right.frame)])
        #expect(model.isChosen(right) && !model.isChosen(left))
        #expect(model.hint == "This screen only. Choose Every Screen for all of them.")
        model.chooseEveryScreen()
        #expect(model.choice()?.target == .everyDisplay)
        #expect(model.hint == "Every screen, one file each. Click a screen for just that one.")

        // A click picks a screen only in Screen mode.
        model.target = .area
        model.clickScreen(left)
        #expect(model.selectedScreen == nil)
        #expect(!PickerScreens.model(layout: PickerScreens.leftOnly).offersEveryScreen)
    }

    @Test("Every screen of one screen is that display")
    func oneScreen() {
        let model = PickerScreens.model(layout: PickerScreens.leftOnly)
        model.target = .screen
        #expect(model.choice()?.target == .display(1))
        #expect(model.choice()?.regions == [ScreencastChoice.Region(display: 1, frame: left.frame)])
    }

    @Test("Drawing an area in the model needs Area, and Record waits until it's drawn")
    func drawingInTheModel() {
        let model = PickerScreens.model()
        var changes = 0
        model.onChange = { changes += 1 }
        #expect(!model.canConfirm)
        #expect(model.hint == "Drag to choose an area.")
        model.pressArea(at: CGPoint(x: 1612, y: 300), on: right)
        model.dragArea(to: CGPoint(x: 2012, y: 0))
        // Not while it's being drawn.
        #expect(model.area == nil)
        model.releaseArea()
        #expect(model.area == ScreencastPickedArea(display: 2, rect: CGRect(x: 1612, y: 0, width: 400, height: 300)))
        #expect(model.canConfirm)
        #expect(changes == 3)

        model.target = .window
        model.pressArea(at: CGPoint(x: 10, y: 10), on: left)
        #expect(model.areaEditor?.bounds == right.frame)
    }
}
