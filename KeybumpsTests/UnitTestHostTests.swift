import AppKit
import Testing
@testable import Keybumps

@MainActor
@Suite("Unit-test host")
struct UnitTestHostTests {
    @Test("Windows created during unit tests stay invisible and click-through")
    func windowsStayOffScreen() {
        #expect(UnitTestHost.isActive)
        let presenter = PresentationWindowController()
        presenter.show(event: .sample, style: .topRightToast)
        defer { presenter.dismissAll() }

        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.hideDuringUnitTests()
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 && $0.level != .normal }.isEmpty)
    }
}
