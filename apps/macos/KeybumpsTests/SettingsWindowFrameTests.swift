import CoreGraphics
import Testing
@testable import Keybumps

/// AppKit screen coordinates: the origin is the primary screen's bottom-left corner.
@Suite("Settings window frame")
struct SettingsWindowFrameTests {
    /// CI's 1024×768 screen: a 31pt menu bar on top and a 63pt Dock at the bottom.
    private let smallScreen = CGRect(x: 0, y: 63, width: 1024, height: 674)

    @Test("On a 1024×768 screen, a window reaching under the Dock is shrunk to the visible frame (#294)")
    func shrinksAWindowTallerThanTheSpaceAboveTheDock() {
        // A frame macOS kept before #294: its top under the menu bar, 772pt tall.
        let overflowing = CGRect(x: 0, y: -35, width: 1024, height: 772)
        #expect(SettingsWindowFrame.fitted(overflowing, in: smallScreen) == smallScreen)
    }

    @Test("A window filled before the Dock grew is shrunk to the new visible frame")
    func refitsAfterTheDockGrows() {
        // What CI's UI test saw: filled while the Dock was 60pt, then the Dock grew to 63pt.
        let filledEarlier = CGRect(x: 0, y: 60, width: 1024, height: 677)
        #expect(SettingsWindowFrame.fitted(filledEarlier, in: smallScreen) == smallScreen)
    }

    @Test("When even the minimum doesn't fit, the window keeps its top on the screen and then stays put")
    func stopsAtTheMinimum() {
        // A 13-inch MacBook at Larger Text (1024×640), with the same menu bar and Dock.
        let laptop = CGRect(x: 0, y: 63, width: 1024, height: 546)
        let minimum = CGSize(width: 960, height: 572)
        let fitted = SettingsWindowFrame.fitted(CGRect(x: 0, y: 0, width: 1240, height: 944), in: laptop, minimumSize: minimum)
        #expect(fitted == CGRect(x: 0, y: 37, width: 1024, height: 572))
        #expect(fitted?.maxY == laptop.maxY)
        // The next activation leaves it alone instead of shrinking it below its minimum again.
        #expect(fitted.flatMap { SettingsWindowFrame.fitted($0, in: laptop, minimumSize: minimum) } == nil)
    }

    @Test("A frame saved on a large display is shrunk and moved onto a laptop's screen")
    func fitsAFrameSavedOnALargerScreen() {
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let saved = CGRect(x: 300, y: 40, width: 1240, height: 944)
        // Its height shrinks; it moves left and down so all of it is on the screen.
        #expect(SettingsWindowFrame.fitted(saved, in: laptop) == CGRect(x: 200, y: 0, width: 1240, height: 875))
    }

    @Test("Only the side that doesn't fit shrinks")
    func shrinksOnlyTheWidth() {
        let wide = CGRect(x: 40, y: 100, width: 1240, height: 500)
        #expect(SettingsWindowFrame.fitted(wide, in: smallScreen) == CGRect(x: 0, y: 100, width: 1024, height: 500))
    }

    @Test("A secondary display with its own origin and a Dock on the left")
    func fitsOnASecondaryDisplay() {
        let secondary = CGRect(x: 1504, y: -400, width: 1856, height: 1055)
        let restored = CGRect(x: 1400, y: -500, width: 1900, height: 1200)
        #expect(SettingsWindowFrame.fitted(restored, in: secondary) == secondary)
    }

    @Test("A window that fits is left where the person put it, even partly under the Dock")
    func leavesAWindowThatFits() {
        #expect(SettingsWindowFrame.fitted(smallScreen, in: smallScreen) == nil)
        #expect(SettingsWindowFrame.fitted(CGRect(x: 100, y: 0, width: 960, height: 600), in: smallScreen) == nil)
    }
}
