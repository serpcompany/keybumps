import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("Shortcut Coach notch tip")
struct NotchCoachPresentationTests {
    @Test("Shows the action, app, and keys, and announces all three")
    func presentation() {
        let event = CoachingEvent(applicationName: "Code", actionTitle: "Close Window", shortcut: "⇧⌘W")
        let tip = NotchCoachPresentation(event: event)
        #expect(tip.action == "Close Window")
        #expect(tip.application == "Code")
        #expect(tip.keys == ShortcutKeycapPresentation(shortcut: "⇧⌘W").keys)
        #expect(tip.announcement.hasPrefix("Close Window, Code, "))
        #expect(tip.announcement.hasSuffix(KeyboardShortcutRegistry.accessibilityCopy(for: "⇧⌘W")))
    }

    @Test("Finds no icon when the app is not running")
    func missingIcon() {
        let event = CoachingEvent(applicationName: "Not Running \(UUID())", actionTitle: "Close Window", shortcut: "⌘W")
        #expect(NotchCoachPresentation(event: event).applicationIcon(in: []) == nil)
        #expect(NotchCoachPresentation(event: event).applicationIcon() == nil)
    }
}
