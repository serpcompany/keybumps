import AppKit

/// Debug unit tests are hosted by Keybumps.app. Code under test still creates real windows, so
/// they stay invisible and click-through: layout and state are exercised without anything
/// appearing on the owner's screen. Release builds compile none of this.
enum UnitTestHost {
    static let isActive: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }()
}

extension NSWindow {
    /// Keeps the window off the owner's screen while unit tests run; a no-op otherwise.
    func hideDuringUnitTests() {
        guard UnitTestHost.isActive else { return }
        alphaValue = 0
        ignoresMouseEvents = true
    }
}
