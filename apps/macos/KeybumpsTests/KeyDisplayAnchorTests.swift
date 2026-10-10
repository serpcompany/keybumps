import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The key display's anchor, a rect the keys sit in such as a recorded window (#449), and which
/// holder's screens, anchor, and clicks apply while a recording holds the display.
@MainActor
@Suite("Keystrokes: the keys inside what's recorded")
struct KeyDisplayAnchorTests {
    /// A laptop with the menu bar and the Dock.
    static let laptop = KeyDisplayScreen(
        display: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879)
    )

    // MARK: Where the keys go

    @Test("Without an anchor the keys sit inside the visible frame, as before")
    func noAnchor() {
        let margin = KeyDisplayOverlayView.margin
        #expect(Self.laptop.keyArea(anchor: nil) == Self.laptop.visibleFrame.insetBy(dx: margin, dy: margin))
        // The padding the view lays the keys out with: the visible frame's insets plus the margin.
        let insets = Self.laptop.insets(to: Self.laptop.keyArea(anchor: nil))
        #expect(insets.bottom == 70 + margin && insets.leading == margin && insets.top == 982 - 949 + margin && insets.trailing == margin)
    }

    @Test("With an anchor on the screen, the keys sit inside it, inset, so along its bottom edge")
    func insideTheAnchor() {
        let window = CGRect(x: 300, y: 400, width: 600, height: 400)
        let margin = KeyDisplayOverlayView.anchorMargin
        let area = Self.laptop.keyArea(anchor: window)
        #expect(area == window.insetBy(dx: margin, dy: margin))
        let insets = Self.laptop.insets(to: area)
        #expect(insets.bottom == 400 + margin, "the keys' bottom is just above the window's")
        #expect(insets.leading == 300 + margin && insets.trailing == 1512 - 900 + margin)
    }

    @Test("An anchor partly off the screen, or under the Dock, is cut to what's visible")
    func cutToTheVisibleFrame() {
        let window = CGRect(x: 1200, y: 20, width: 800, height: 500)
        let margin = KeyDisplayOverlayView.anchorMargin
        #expect(Self.laptop.keyArea(anchor: window) == CGRect(x: 1200, y: 70, width: 312, height: 450).insetBy(dx: margin, dy: margin))
    }

    @Test("An anchor on another screen, or too small to hold keys, leaves them where they'd be without one")
    func unusableAnchor() {
        let plain = Self.laptop.keyArea(anchor: nil)
        #expect(Self.laptop.keyArea(anchor: CGRect(x: 2000, y: 100, width: 600, height: 400)) == plain)
        #expect(Self.laptop.keyArea(anchor: CGRect(x: 100, y: 100, width: 40, height: 400)) == plain)
        #expect(Self.laptop.keyArea(anchor: .null) == plain)
    }

    // MARK: Whose settings apply

    static let window = CGRect(x: 300, y: 400, width: 600, height: 400)

    static var recording: KeyDisplayConfiguration {
        KeyDisplayConfiguration(keys: .shortcutsOnly, showsClicks: false, displays: [1], anchor: window)
    }

    @Test("While a recording holds the display, its screens, anchor, and clicks win over a holder that comes later")
    func recordingWins() throws {
        var holds = KeyDisplayHolds()
        holds.acquire(.screencast, configuration: Self.recording, keepsWindowsOnScreen: true)
        // Keystrokes turned on mid-recording, in All keys, with rings, on the pointer's screen.
        let plugin = KeyDisplayConfiguration(style: .bezel, position: .bottomRight, keys: .allKeys, size: .large, showsClicks: true)
        holds.acquire(.keystrokes, configuration: plugin)

        let configuration = try #require(holds.configuration)
        #expect(configuration.keys == .shortcutsOnly, "Shortcuts only stays")
        #expect(!configuration.showsClicks, "no rings in the video")
        #expect(configuration.displays == [1] && configuration.anchor == Self.window)
        #expect(configuration.style == .bezel && configuration.position == .bottomRight && configuration.size == .large, "the look is the newest holder's")

        // A later holder naming other screens and an anchor doesn't move a recording's keys either.
        holds.acquire(KeyDisplayOwner("other"), configuration: KeyDisplayConfiguration(showsClicks: true, displays: [2], anchor: CGRect(x: 0, y: 0, width: 500, height: 500)))
        #expect(holds.configuration?.displays == [1] && holds.configuration?.anchor == Self.window)
        #expect(holds.configuration?.showsClicks == false)

        holds.release(.screencast)
        #expect(holds.configuration?.showsClicks == true, "the plugin's own settings once the recording lets go")
        #expect(holds.configuration?.displays == [2], "the newest holder naming screens, as before")
        #expect(holds.configuration?.anchor == CGRect(x: 0, y: 0, width: 500, height: 500))
        holds.release(KeyDisplayOwner("other"))
        #expect(holds.configuration == plugin)
    }

    @Test("A recording that shows rings keeps them, and without a recording nobody's anchor is forced")
    func recordingWithClicks() {
        var holds = KeyDisplayHolds()
        var withClicks = Self.recording
        withClicks.showsClicks = true
        holds.acquire(.screencast, configuration: withClicks, keepsWindowsOnScreen: true)
        holds.acquire(.keystrokes, configuration: KeyDisplayConfiguration(showsClicks: false))
        #expect(holds.configuration?.showsClicks == true)

        var plain = KeyDisplayHolds()
        plain.acquire(.keystrokes, configuration: KeyDisplayConfiguration())
        #expect(plain.configuration?.anchor == nil && plain.configuration?.displays == nil)
    }

    @Test("The display a recording holds draws no rings when Keystrokes, with rings, is turned on after it")
    func displayKeepsTheRecordingsClicks() throws {
        let presenter = FakeKeyDisplayPresenter()
        let display = KeyDisplay(
            keys: InertKeyTypingMonitor(),
            pointer: InertPointerEventMonitor(),
            presenter: presenter,
            scheduler: KeyDisplayManualScheduler(),
            secureInput: { false }
        )
        display.acquire(.screencast, configuration: Self.recording, keepsWindowsOnScreen: true)
        display.acquire(.keystrokes, configuration: KeyDisplayConfiguration(keys: .allKeys, showsClicks: true))
        let shown = try #require(presenter.last)
        #expect(!shown.configuration.showsClicks)
        #expect(shown.configuration.anchor == Self.window && shown.configuration.displays == [1])
        #expect(shown.keepsWindowsOnScreen)
        display.release(.keystrokes)
        display.release(.screencast)
    }
}
