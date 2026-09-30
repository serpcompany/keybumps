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

    /// This test run's own folder in the temporary directory. Stores whose default location is the
    /// installed app's (Quick Search's Recent Items and learned usage) use it under the unit-test
    /// host, so a test that forgets its own store never reads or writes the owner's data.
    static let dataDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsUnitTestHost-\(UUID().uuidString)", isDirectory: true)
}

extension NSWindow {
    /// Keeps the window off the owner's screen while unit tests run; a no-op otherwise.
    func hideDuringUnitTests() {
        guard UnitTestHost.isActive else { return }
        alphaValue = 0
        ignoresMouseEvents = true
    }
}
