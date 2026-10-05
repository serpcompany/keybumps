import Foundation
import Testing
@testable import Keybumps

/// Quick Search's Plugins command opens Settings › Plugins, and that page links to the website's
/// Plugins page (ADR 0006).
@MainActor
@Suite("Plugins in Quick Search and on the website")
struct PluginsCommandTests {
    @Test("The website's Plugins page is keybumps.app/plugins")
    func website() {
        #expect(PluginLinks.website.absoluteString == "https://keybumps.app/plugins")
    }

    @Test("Quick Search's Plugins command is found by its name or by extensions, and goes to Settings › Plugins")
    func command() {
        #expect(QuickSearchCommand.plugins.title == "Plugins")
        #expect(QuickSearchCommand.plugins.match("plugins") == .name)
        #expect(QuickSearchCommand.plugins.match("extensions") == .keyword)
        #expect(QuickSearchCommand.plugins.match("store") == nil, "It isn't called the Store")
        #expect(QuickSearchCommand.plugins.destination(enabledCapabilities: []) == .settings(.plugins))
    }

    @Test("Running it opens Settings on Plugins")
    func running() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsPluginsCommand-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let harness = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root, quickSearch: search)
        let palette = harness.model.commandPalette
        var openedSettings: [SettingsSection?] = []
        palette.openSettings = { openedSettings.append($0) }

        palette.run(.plugins)

        #expect(openedSettings == [.plugins])
    }
}
