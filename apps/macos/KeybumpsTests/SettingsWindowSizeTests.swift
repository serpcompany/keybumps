import CoreGraphics
import Testing
@testable import Keybumps

@Suite("Settings window size")
struct SettingsWindowSizeTests {
    /// A window of this content size, with its title bar and toolbar, fits inside `visible`.
    private func fits(_ content: CGSize, in visible: CGSize) -> Bool {
        content.width <= visible.width && content.height + SettingsWindowSize.chromeHeight <= visible.height
    }

    @Test("On a 1024×768 screen with a Dock, the minimum and default sizes end above the Dock (#294)")
    func smallScreenWithDock() {
        // 768 less the menu bar (25) and a bottom Dock (54).
        let visible = CGSize(width: 1024, height: 689)
        let minimum = SettingsWindowSize.minimumContentSize(fitting: visible)
        let preferred = SettingsWindowSize.defaultContentSize(fitting: visible)

        #expect(minimum == CGSize(width: 960, height: 629))
        #expect(preferred == CGSize(width: 1024, height: 629))
        #expect(fits(minimum, in: visible))
        #expect(fits(preferred, in: visible))
    }

    @Test("On a large screen, the usual minimum and default sizes are unchanged")
    func largeScreen() {
        let visible = CGSize(width: 2560, height: 1415)
        #expect(SettingsWindowSize.minimumContentSize(fitting: visible) == SettingsWindowSize.usualMinimum)
        #expect(SettingsWindowSize.defaultContentSize(fitting: visible) == SettingsWindowSize.usualDefault)
    }

    @Test("On a screen smaller than the usual minimum, both sizes shrink to the screen")
    func screenSmallerThanMinimum() {
        let visible = CGSize(width: 800, height: 551)
        let minimum = SettingsWindowSize.minimumContentSize(fitting: visible)
        let preferred = SettingsWindowSize.defaultContentSize(fitting: visible)

        #expect(minimum == CGSize(width: 800, height: 491))
        #expect(preferred == minimum)
        #expect(fits(minimum, in: visible))
    }

    @Test("Without a screen, the usual sizes")
    func noScreen() {
        #expect(SettingsWindowSize.minimumContentSize(fitting: nil) == SettingsWindowSize.usualMinimum)
        #expect(SettingsWindowSize.defaultContentSize(fitting: nil) == SettingsWindowSize.usualDefault)
    }

    @Test("The default is never smaller than the minimum")
    func defaultCoversMinimum() {
        for visible in [CGSize(width: 1024, height: 689), CGSize(width: 1440, height: 875), CGSize(width: 10, height: 10)] {
            let minimum = SettingsWindowSize.minimumContentSize(fitting: visible)
            let preferred = SettingsWindowSize.defaultContentSize(fitting: visible)
            #expect(preferred.width >= minimum.width && preferred.height >= minimum.height)
        }
    }
}
