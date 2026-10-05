import Foundation
import Testing
@testable import Keybumps

/// The Store is the plugin directory on keybumps.app (ADR 0006). The app links to it; turning a
/// plugin on or off stays in Settings › Plugins.
@MainActor
@Suite("The Store")
struct StoreTests {
    @Test("It lives at keybumps.app/plugins")
    func url() {
        #expect(PluginStore.url.absoluteString == "https://keybumps.app/plugins")
    }

    @Test("Quick Search's Store command is found by its name or by plugins, and goes to the website")
    func command() {
        #expect(QuickSearchCommand.store.title == "Store")
        #expect(QuickSearchCommand.store.match("store") == .name)
        #expect(QuickSearchCommand.store.match("plugins") == .keyword)
        #expect(QuickSearchCommand.store.match("marketplace") == .keyword)
        #expect(QuickSearchCommand.store.destination(enabledCapabilities: []) == .website(PluginStore.url))
        #expect(QuickSearchCommand.store.destination(enabledCapabilities: []).hint == "Opens keybumps.app in your browser")
    }

    @Test("Running it closes the palette and opens the Store in the browser, not Settings")
    func running() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = QuickSearchModel.forTests(in: root)
        let harness = WiringHarness(enabled: Set(Capability.allCases), missing: nil, root: root, quickSearch: search)
        let palette = harness.model.commandPalette
        var openedURLs: [URL] = []
        palette.openURL = { openedURLs.append($0); return true }
        var openedSettings: [SettingsSection?] = []
        palette.openSettings = { openedSettings.append($0) }

        palette.run(.store)

        #expect(openedURLs == [PluginStore.url])
        #expect(openedSettings.isEmpty)
        #expect(!palette.isVisible)
    }
}
