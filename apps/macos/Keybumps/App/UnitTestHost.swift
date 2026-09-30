import AppKit

/// Debug unit tests are hosted by Keybumps.app. Code under test still creates real windows, so
/// they stay invisible and click-through: layout and state are exercised without anything
/// appearing on the owner's screen. In Release builds `isActive` is always false, so none of this
/// takes effect.
enum UnitTestHost {
    /// True only in a Debug build that XCTest loaded as a unit-test host. Release builds (and so QA
    /// candidates) compile it as false. A UI-test launch isn't a unit-test host: XCUITest starts the
    /// app without XCTest's configuration, and `KeybumpsMain` would otherwise show no app at all.
    static let isActive: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }()

    /// This test run's own folder in the temporary directory. Under the unit-test host,
    /// `ProductPaths` resolves the owner's real folders to folders inside it, so a store built with
    /// its default location never reads or writes the installed app's data.
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
