import AppKit
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

    /// In AppKit's space, on the left screen unless said: on the browser window (10) only; on the
    /// browser's other window (12) only, clear of the bar; on the other app's window (20), on the
    /// right screen; on no window; and on the bar, over window 12.
    private let onBrowserWindow = CGPoint(x: 150, y: 832)
    private let onOtherWindow = CGPoint(x: 975, y: 232)
    private let onRightWindow = CGPoint(x: 2000, y: 582)
    private let onDesktop = CGPoint(x: 1400, y: 20)
    private let onBar = CGPoint(x: 920, y: 240)

    /// Window mode over the made-up windows, with the bar laid out over the lower part of the
    /// browser's other window (12), as it is over whatever window is under it.
    private func windowModel() -> ScreencastPickerModel {
        let model = PickerScreens.model()
        model.target = .window
        model.windows = ScreencastWindowPicking.pickableWindows(in: Screens.content(), ownProcessID: Screens.ownProcess)
        model.barFrame = CGRect(x: 250, y: 190, width: 700, height: 100)
        #expect(ScreencastWindowPicking.window(at: layout.topLeftPoint(fromAppKit: onBar), in: model.windows)?.id == 12)
        return model
    }

    @Test("A window chosen stays chosen while the pointer crosses other windows, the desktop, and the bar")
    func windowStaysChosenWhileThePointerMoves() {
        let model = windowModel()
        #expect(model.clickWindow(at: onBrowserWindow))
        #expect(model.selectedWindow == 10)

        model.hoverWindow(at: onOtherWindow)
        #expect(model.hoveredWindow == 12, "Another window under the pointer is only previewed")
        #expect(model.selectedWindow == 10)
        model.hoverWindow(at: onRightWindow)
        #expect(model.hoveredWindow == 20 && model.selectedWindow == 10)
        model.hoverWindow(at: onDesktop)
        #expect(model.hoveredWindow == nil && model.selectedWindow == 10)
        model.hoverWindow(at: onBar)
        #expect(model.hoveredWindow == nil, "The pointer on the bar is on no window under it")
        #expect(model.selectedWindow == 10)
        #expect(model.hint == "Click another window to change it.")
        #expect(model.choice()?.target == .window(10))
    }

    @Test("A click or a double click on the bar, or on its buttons and switches, never changes the window chosen")
    func barNeverChoosesAWindow() {
        let model = windowModel()
        #expect(!model.press(at: onBar, on: left, clickCount: 1), "Before one is chosen, a click on the bar chooses none")
        #expect(!model.press(at: onBar, on: left, clickCount: 2))
        #expect(model.selectedWindow == nil && !model.canConfirm)

        model.clickWindow(at: onBrowserWindow)
        model.hoverWindow(at: onBar)
        #expect(!model.press(at: onBar, on: left, clickCount: 1))
        #expect(!model.press(at: onBar, on: left, clickCount: 2), "A double click on the bar records nothing")
        #expect(model.selectedWindow == 10)
        // What the bar's buttons and switches set.
        model.kind = .screenshot
        model.kind = .video
        model.recordsMicrophone.toggle()
        model.recordsSystemAudio.toggle()
        model.showsShortcuts.toggle()
        model.highlightsClicks.toggle()
        model.target = .area
        model.target = .screen
        model.target = .window
        #expect(model.selectedWindow == 10)
        let choice = model.choice()
        #expect(choice?.target == .window(10))
        #expect(choice?.regions == [ScreencastChoice.Region(display: 1, frame: CGRect(x: 100, y: 282, width: 800, height: 600))])
    }

    @Test("Only a click on another window changes the window chosen, and Record records that one")
    func clickOnAnotherWindowChangesIt() {
        let model = windowModel()
        model.clickWindow(at: onBrowserWindow)
        #expect(model.clickWindow(at: onOtherWindow))
        #expect(model.selectedWindow == 12)
        #expect(model.choice()?.target == .window(12))
        #expect(model.choice()?.regions == [ScreencastChoice.Region(display: 1, frame: CGRect(x: 200, y: 182, width: 800, height: 600))])
        #expect(model.clickWindow(at: onRightWindow))
        #expect(model.choice()?.target == .window(20))
        #expect(model.choice()?.regions.map(\.display) == [2])
        // A double click on a window chooses it and records it; one on no window records nothing.
        #expect(model.press(at: onBrowserWindow, on: left, clickCount: 2))
        #expect(model.selectedWindow == 10)
        #expect(!model.press(at: onDesktop, on: left, clickCount: 2))
        // Without a bar laid out, as on a screen without it, a press reaches every window.
        model.barFrame = nil
        #expect(!model.press(at: onBar, on: left, clickCount: 1))
        #expect(model.selectedWindow == 12)
    }

    @Test("A click or a double click on the bar keeps the area drawn, and a drag from elsewhere can end on it")
    func barKeepsTheArea() {
        let model = PickerScreens.model()
        model.barFrame = CGRect(x: 250, y: 190, width: 700, height: 100)
        // Drawn from above the bar down onto it.
        #expect(!model.press(at: CGPoint(x: 400, y: 600), on: left, clickCount: 1))
        model.dragArea(to: CGPoint(x: 600, y: 240))
        model.releaseArea()
        let area = ScreencastPickedArea(display: 1, rect: CGRect(x: 400, y: 240, width: 200, height: 360))
        #expect(model.area == area)

        // The bar's empty part, beside the area, and the bar where it covers the area: a click, a
        // drag that starts there, and a double click change nothing and record nothing.
        for onBar in [CGPoint(x: 900, y: 200), CGPoint(x: 450, y: 270)] {
            #expect(!model.press(at: onBar, on: left, clickCount: 1))
            model.dragArea(to: CGPoint(x: onBar.x + 40, y: onBar.y + 40))
            model.releaseArea()
            #expect(!model.press(at: onBar, on: left, clickCount: 2), "A double click on the bar records nothing")
            model.releaseArea()
        }
        #expect(model.area == area)
        #expect(model.canConfirm)
        #expect(model.hint == "Drag inside it to move it, or its edges to resize it, or drag elsewhere for a new one.")
        // Off the bar, a double click in the area records it.
        #expect(model.press(at: CGPoint(x: 500, y: 500), on: left, clickCount: 2))
    }

    @Test("A click or a double click on the bar keeps the screen chosen, or All Screens, and records nothing")
    func barKeepsTheScreen() {
        let model = PickerScreens.model()
        model.target = .screen
        model.barFrame = CGRect(x: 250, y: 190, width: 700, height: 100)
        model.chooseEveryScreen()
        #expect(!model.press(at: onBar, on: left, clickCount: 1))
        #expect(!model.press(at: onBar, on: left, clickCount: 2), "A double click on the bar records nothing")
        #expect(model.selectedScreen == nil && model.choice()?.target == .everyDisplay)

        model.chooseScreen(right.id)
        #expect(!model.press(at: onBar, on: left, clickCount: 1))
        #expect(!model.press(at: onBar, on: left, clickCount: 2))
        #expect(model.choice()?.target == .display(2))

        // Off the bar, a click chooses that screen, and a double click records it.
        #expect(!model.press(at: onDesktop, on: left, clickCount: 1))
        #expect(model.selectedScreen == 1)
        #expect(model.press(at: onDesktop, on: left, clickCount: 2))
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
        #expect(model.choice()?.target == .display(1), "It starts on a screen, not all of them")
        model.chooseEveryScreen()
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
        // No pointer screen given: the first screen in recording order.
        #expect(model.selectedScreen == 1 && model.choice()?.target == .display(1))
        #expect(model.hint == "Records all of Screen 1.")
        model.clickScreen(right)
        #expect(model.choice()?.target == .display(2))
        #expect(model.choice()?.regions == [ScreencastChoice.Region(display: 2, frame: right.frame)])
        #expect(model.isChosen(right) && !model.isChosen(left))
        #expect(model.hint == "Records all of Screen 2.")
        model.chooseEveryScreen()
        #expect(model.choice()?.target == .everyDisplay)
        #expect(model.isChosen(left) && model.isChosen(right))
        #expect(model.hint == "Records all screens, one file each.")
        model.kind = .screenshot
        #expect(model.hint == "Captures all screens, one image each.")
        model.chooseScreen(1)
        #expect(model.hint == "Captures all of Screen 1.")

        // A click picks a screen only in Screen mode.
        model.target = .area
        model.clickScreen(right)
        #expect(model.selectedScreen == 1)
    }

    @Test("Screen mode starts on the screen with the pointer, and one screen has no All Screens")
    func screenWithThePointer() {
        #expect(PickerScreens.model(pointerScreen: 2).selectedScreen == 2)
        #expect(PickerScreens.model(pointerScreen: 77).selectedScreen == 1, "A screen that isn't there: the first")
        // The bar's screen is the same one.
        #expect(PickerScreens.model(pointerScreen: 2).pointerScreen == PickerScreens.right)
        #expect(PickerScreens.model(pointerScreen: 77).pointerScreen == PickerScreens.left)
        // Without the pointer on a screen, both start on the main one, which `NSScreen` lists
        // first, even when it isn't leftmost.
        let mainOnRight = PickerScreens.model(layout: ScreencastScreenLayout(screens: [PickerScreens.right, PickerScreens.left]))
        #expect(mainOnRight.pointerScreen == PickerScreens.right && mainOnRight.selectedScreen == 2)
        let single = PickerScreens.model(layout: PickerScreens.leftOnly)
        single.target = .screen
        #expect(!single.offersEveryScreen && single.selectedScreen == 1)
        single.chooseEveryScreen()
        #expect(single.selectedScreen == 1 && single.choice()?.target == .display(1))
    }

    @Test("Screens are named as macOS names them, or numbered in recording order")
    func screenNames() {
        let named = ScreencastScreen(id: 7, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), scale: 1, name: "Studio Display")
        let layout = ScreencastScreenLayout(screens: [left, right, named])
        #expect(layout.orderedScreens.map(\.id) == [7, 1, 2])
        #expect(layout.number(of: left) == 2)
        #expect(layout.title(of: named) == "Studio Display")
        #expect(layout.title(of: right) == "Screen 3")
        // Stacked screens: the top one first.
        let top = ScreencastScreen(id: 8, frame: CGRect(x: 0, y: 982, width: 1512, height: 982), scale: 2)
        #expect(ScreencastScreenLayout(screens: [left, top]).orderedScreens.map(\.id) == [8, 1])
    }

    @Test("The pointer over a screen choice shows it on the screens until it leaves")
    func screenPreview() {
        let model = PickerScreens.model()
        model.target = .screen
        #expect(model.isLit(left) && !model.isLit(right))
        model.previewScreens(.screen(2))
        #expect(!model.isLit(left) && model.isLit(right))
        model.previewScreens(.all)
        #expect(model.isLit(left) && model.isLit(right))
        model.previewScreens(nil)
        #expect(model.isLit(left) && !model.isLit(right))
        #expect(model.choice()?.target == .display(1), "A preview chooses nothing")
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

/// One screen's picker view with the bar laid out on it, as Start Screencast lays it out, in a panel
/// that's never shown, and mouse events sent to it as AppKit sends them.
@MainActor
@Suite("Screencast: the picker on a screen")
struct ScreencastPickerViewTests {
    /// Below and right of AppKit's origin, so a wrong offset or a flipped y shows.
    let right = PickerScreens.right

    /// A window over most of the right screen, down to its bottom, so the bar is over it.
    private let underTheBar = ScreencastContent.Window(
        id: 30, frame: CGRect(x: 1612, y: 80, width: 1720, height: 1000), layer: 0,
        processID: ScreencastScreens.otherApp, isUntitled: false, isOnScreen: true
    )

    @available(macOS 15, *)
    @Test("The bar's frame is in AppKit's global space, and a double click on it records nothing in any mode")
    func barOnAScreenAwayFromTheOrigin() throws {
        let model = PickerScreens.model(pointerScreen: right.id)
        model.windows = [underTheBar]
        var recorded = 0
        let view = ScreencastPickerView(model: model, screen: right, confirm: { recorded += 1 })
        let panel = ScreencastKeyPanel(frame: right.frame, level: .screenSaver, identifier: "screencastPicker")
        defer { panel.contentView = nil }
        panel.contentView = view
        view.showBar(ScreencastPickerBar(model: model, confirm: {}, cancel: {}), bottomInset: 28)
        view.layoutSubtreeIfNeeded()

        let bar = try #require(model.barFrame)
        #expect(right.frame.contains(bar))
        #expect(abs(bar.midX - right.frame.midX) <= 1)
        #expect(bar.minY == right.frame.minY + 28)

        /// A mouse event at `point`, in AppKit's global space.
        func event(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: CGPoint(x: point.x - right.frame.minX, y: point.y - right.frame.minY),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            ))
        }
        func doubleClick(at point: CGPoint) throws {
            for count in [1, 2] {
                try view.mouseDown(with: event(.leftMouseDown, at: point, clickCount: count))
                try view.mouseUp(with: event(.leftMouseUp, at: point, clickCount: count))
            }
        }
        // On the bar's lower row, there in every mode, and over the window.
        let onBar = CGPoint(x: bar.midX, y: bar.minY + 20)
        let offBar = CGPoint(x: 1700, y: 500)
        #expect(ScreencastWindowPicking.window(at: model.layout.topLeftPoint(fromAppKit: onBar), in: model.windows)?.id == 30)

        model.target = .window
        try doubleClick(at: onBar)
        #expect(model.selectedWindow == nil && recorded == 0, "On the bar: no window chosen, nothing recorded")
        try doubleClick(at: offBar)
        #expect(model.selectedWindow == 30 && recorded == 1, "On the window: chosen and recorded")

        model.target = .screen
        model.chooseEveryScreen()
        try doubleClick(at: onBar)
        #expect(model.selectedScreen == nil && recorded == 1, "On the bar: All Screens kept, nothing recorded")
        try doubleClick(at: offBar)
        #expect(model.selectedScreen == right.id && recorded == 2)

        // An area drawn from above the bar down past the point on it.
        model.target = .area
        try view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: bar.midX - 200, y: 500)))
        try view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: bar.midX + 100, y: bar.minY + 10)))
        try view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: bar.midX + 100, y: bar.minY + 10)))
        let area = try #require(model.area)
        #expect(area.rect.contains(onBar))
        try doubleClick(at: onBar)
        #expect(model.area == area && recorded == 2, "On the bar over the area: kept, nothing recorded")
        try doubleClick(at: CGPoint(x: area.rect.midX, y: 400))
        #expect(recorded == 3, "In the area, off the bar: recorded")
    }
}

/// "Getting ready…" in the notch, through Screencast's own overlays and a notch notice of the
/// test's own.
@MainActor
@Suite("Screencast: Getting ready…")
struct ScreencastGettingReadyNoticeTests {
    @available(macOS 15, *)
    @Test("Hiding Getting ready… hides it, and never a notice that replaced it, such as a Shortcut Coach tip")
    func hidesOnlyItself() throws {
        let notices = PaletteHUD()
        defer { notices.dismiss() }
        let overlays = ScreencastOverlayWindows(notices: notices)

        overlays.showGettingReady()
        #expect(notices.shownNotice != nil)
        overlays.hideGettingReady()
        #expect(notices.shownNotice == nil)

        overlays.showGettingReady()
        notices.showCoach(NotchCoachPresentation(event: .sample))
        let tip = try #require(notices.shownNotice)
        overlays.hideGettingReady()
        #expect(notices.shownNotice == tip, "the tip stays")

        // Nor a notice that came after one that hid on its own.
        overlays.showGettingReady()
        notices.dismiss()
        let later = notices.show("Copied to Clipboard")
        overlays.hideGettingReady()
        #expect(later != nil && notices.shownNotice == later)
    }
}
