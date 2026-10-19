import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("Screenshot capture")
struct ScreenshotCaptureTests {
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Screens capture one macOS-named file per display; an area captures one, interactively, or with no selection for the smoke test")
    func planNamesAndArguments() {
        let folder = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let screens = ScreenshotCapturePlan.files(in: folder, at: Self.date, displayCount: 2, mode: .screens)
        #expect(screens.count == 2)
        #expect(screens[0].lastPathComponent.hasPrefix("Screenshot "))
        #expect(screens[0].lastPathComponent.hasSuffix(".png"))
        #expect(screens[1].lastPathComponent.hasSuffix(" (2).png"))
        #expect(ScreenshotCapturePlan.arguments(for: .screens, files: screens) == ["-t", "png"] + screens.map(\.path))

        let area = ScreenshotCapturePlan.files(in: folder, at: Self.date, displayCount: 3, mode: .area)
        #expect(area.count == 1)
        #expect(ScreenshotCapturePlan.arguments(for: .area, files: area) == ["-i", "-t", "png", area[0].path])

        // The QA smoke test's area: no selection, in whole points from the main display's top left.
        let fixed = ScreenshotCaptureMode.fixedArea(CGRect(x: 436, y: 311.4, width: 640, height: 360))
        let fixedFiles = ScreenshotCapturePlan.files(in: folder, at: Self.date, displayCount: 3, mode: fixed)
        #expect(fixedFiles == area)
        #expect(ScreenshotCapturePlan.arguments(for: fixed, files: fixedFiles) == ["-R", "436,311,640,361", "-t", "png", area[0].path])
        #expect(ScreenshotCapturePlan.rectangle(.null) == "0,0,0,0", "no trap on a rect that isn't finite")
    }

    @Test("Only written files are reported, and they are marked as screen captures")
    func capturerReportsWrittenFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = FakeCaptureRunner(writesFirstFileOnly: true)
        var clock = Self.date
        let capturer = ScreenshotCapturer(runner: runner, folder: { folder }, now: {
            defer { clock += 1 }
            return clock
        }, displayCount: { 2 })

        let written: [URL] = await withCheckedContinuation { continuation in
            capturer.capture(.screens) { continuation.resume(returning: $0) }
        }
        #expect(written.count == 1)
        #expect(runner.arguments.first == "-t")
        #expect(getxattr(written[0].path, FileSystemScreenshotDirectoryReader.screenCaptureAttribute, nil, 0, 0, 0) >= 0)

        runner.writesNothing = true
        let cancelled: [URL] = await withCheckedContinuation { continuation in
            capturer.capture(.area) { continuation.resume(returning: $0) }
        }
        #expect(cancelled.isEmpty, "Escape during an area capture writes nothing")
    }

    @Test("The Screen hotkey lists every display's screenshot in ⌘3, the main display's on top and on the clipboard")
    func screenHotkeyListsEveryDisplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreenHotkey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let capturer = ScreenshotCapturer(runner: PNGCaptureRunner(), folder: { root }, now: { Self.date }, displayCount: { 3 })
        let harness = WiringHarness(
            enabled: [.screenshotTools, .clipboardHistory], missing: nil, root: root, screenshotCapturer: capturer
        )
        harness.model.start()

        harness.pressHotKey(DefaultShortcut.screenshotScreen)
        let files = ScreenshotCapturePlan.files(in: root, at: Self.date, displayCount: 3, mode: .screens)
        let listed = ScreenshotPaletteContent.resolve(entries: harness.model.clipboard.entries, query: "", isEnabled: true)
        #expect(listed.entries.compactMap(\.sourceURL) == files)
        #expect(harness.pasteboard.data(forType: .png) == (try Data(contentsOf: files[0])), "⌘V pastes the main display's")
    }

    // MARK: macOS shortcut takeover

    @Test("Matching Keybumps hotkeys turn off macOS's ⇧⌘3 and ⇧⌘4, then give them back")
    func takeoverAndRestore() {
        let store = FakeSymbolicHotKeys(hotKeys: [:])
        var owned: Set<String> = []
        let takeover = SystemScreenshotShortcutTakeover(preferences: store, takenOver: { owned }, setTakenOver: { owned = $0 })
        var changes = 0
        takeover.didChange = { changes += 1 }
        let keybumps = [DefaultShortcut.screenshotScreen, DefaultShortcut.screenshotScreenAndEdit, DefaultShortcut.screenshotAreaAndEdit]

        takeover.apply(bindings: keybumps, isEnabled: true)
        #expect(store.isEnabled("28") == false)
        #expect(store.isEnabled("30") == false)
        #expect(owned == ["28", "30"])
        #expect(store.reloads == 1)
        #expect(changes == 1, "The key display hears that macOS's shortcuts changed")

        takeover.apply(bindings: keybumps, isEnabled: true)
        #expect(store.writes == 1, "No change, no write")
        #expect(changes == 1)

        takeover.apply(bindings: keybumps, isEnabled: false)
        #expect(store.isEnabled("28") == true)
        #expect(store.isEnabled("30") == true)
        #expect(owned.isEmpty)
        #expect(changes == 2)
    }

    @Test("Record Screen's ⇧⌘5 turns off macOS's screenshot toolbar (184), then gives it back (#490)")
    func recordScreenTakesOverTheToolbar() {
        let store = FakeSymbolicHotKeys(hotKeys: [:])
        var owned: Set<String> = []
        let takeover = SystemScreenshotShortcutTakeover(preferences: store, takenOver: { owned }, setTakenOver: { owned = $0 })

        takeover.apply(bindings: [DefaultShortcut.recordScreen], isEnabled: true)
        #expect(store.isEnabled("184") == false)
        #expect(store.isEnabled("28") == nil && store.isEnabled("30") == nil, "Untouched")
        #expect(owned == ["184"])

        takeover.apply(bindings: [], isEnabled: true)
        #expect(store.isEnabled("184") == true, "Record Screen moved off ⇧⌘5")
        #expect(owned.isEmpty)
    }

    @Test("The screenshot hotkeys: ⇧⌘2 every screen; ⇧⌘3 every screen and ⇧⌘4 an area, both marked to open the editor (#545); ⇧⌘4 still stored as Screenshot Area")
    func captureShortcutsOpenTheEditor() {
        let hotkeys = ScreenshotToolsModule.captureShortcuts.map { "\($0.shortcut.title): \($0.mode == .area ? "area" : "screens")\($0.opensEditor ? ", edit" : "")" }
        #expect(hotkeys == [
            "Screenshot Screen: screens",
            "Screenshot Screen and Edit: screens, edit",
            "Screenshot Area and Edit: area, edit",
        ])
        #expect(CapabilityShortcut.screenshotAreaAndEdit.defaultBinding == DefaultShortcut.screenshotAreaAndEdit)
        #expect(DefaultShortcut.screenshotAreaAndEdit.displayName == "⇧⌘4")
        #expect(CapabilityShortcut.screenshotAreaAndEdit.rawValue == "screenshotArea", "a key someone set or cleared carries over")
    }

    @Test("ScreenGrabs takes over ⇧⌘3, ⇧⌘4, and ⇧⌘5 with its keys on macOS 15, and leaves ⇧⌘5 to macOS 14 (#490)")
    func takeoverBindingsFollowSupportsRecording() {
        let current = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 15))
        #expect(ScreenshotToolsModule.takeoverBindings(current) == [
            DefaultShortcut.screenshotScreen, DefaultShortcut.screenshotScreenAndEdit, DefaultShortcut.screenshotAreaAndEdit, DefaultShortcut.recordScreen,
        ])
        let old = AppPreferences(defaults: InMemoryDefaults(), compatibility: PluginCompatibility(macOSMajorVersion: 14))
        #expect(ScreenshotToolsModule.takeoverBindings(old) == [
            DefaultShortcut.screenshotScreen, DefaultShortcut.screenshotScreenAndEdit, DefaultShortcut.screenshotAreaAndEdit,
        ])
        #expect(SystemScreenshotShortcutTakeover.managed.map(\.id) == ["28", "30", "184"])

        current.setCapabilityShortcut(nil, for: .screencast)
        #expect(!ScreenshotToolsModule.takeoverBindings(current).contains(DefaultShortcut.recordScreen))
    }

    @Test("Moving a hotkey off macOS's keys gives only that shortcut back")
    func movingOneHotkeyRestoresOnlyIt() {
        let store = FakeSymbolicHotKeys(hotKeys: [:])
        var owned: Set<String> = []
        let takeover = SystemScreenshotShortcutTakeover(preferences: store, takenOver: { owned }, setTakenOver: { owned = $0 })
        takeover.apply(bindings: [DefaultShortcut.screenshotScreenAndEdit, DefaultShortcut.screenshotAreaAndEdit], isEnabled: true)

        let moved = ShortcutBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | optionKey), displayName: "⌥⌘3")
        takeover.apply(bindings: [moved, DefaultShortcut.screenshotAreaAndEdit], isEnabled: true)
        #expect(store.isEnabled("28") == true)
        #expect(store.isEnabled("30") == false)
        #expect(owned == ["30"])
    }

    @Test("A macOS shortcut the owner turned off themselves is never turned back on")
    func ownerDisabledShortcutStaysOff() {
        let store = FakeSymbolicHotKeys(hotKeys: [
            "28": ["enabled": false, "value": ["parameters": [51, kVK_ANSI_3, 1_179_648], "type": "standard"]] as [String: Any]
        ])
        var owned: Set<String> = []
        let takeover = SystemScreenshotShortcutTakeover(preferences: store, takenOver: { owned }, setTakenOver: { owned = $0 })
        takeover.apply(bindings: [DefaultShortcut.screenshotScreenAndEdit], isEnabled: true)
        takeover.apply(bindings: [], isEnabled: false)
        #expect(store.isEnabled("28") == false)
        #expect(!owned.contains("28"))
    }

    // MARK: Shortcut defaults

    @Test("New installs get all three hotkeys; existing installs get them once, and a cleared one stays cleared")
    func shortcutDefaultsAndMigration() throws {
        let fresh = AppPreferences(defaults: InMemoryDefaults())
        #expect(fresh.capabilityShortcut(for: .screenshotScreen) == DefaultShortcut.screenshotScreen)
        #expect(fresh.capabilityShortcut(for: .screenshotScreenAndEdit) == DefaultShortcut.screenshotScreenAndEdit)
        #expect(fresh.capabilityShortcut(for: .screenshotAreaAndEdit) == DefaultShortcut.screenshotAreaAndEdit)

        let existing = InMemoryDefaults()
        let original = Dictionary(uniqueKeysWithValues: CapabilityShortcut.originalShortcuts.map { ($0.rawValue, $0.defaultBinding) })
        existing.set(try JSONEncoder().encode(original), forKey: "capabilityShortcuts")
        let upgraded = AppPreferences(defaults: existing)
        #expect(upgraded.capabilityShortcut(for: .screenshotAreaAndEdit) == DefaultShortcut.screenshotAreaAndEdit)

        upgraded.setCapabilityShortcut(nil, for: .screenshotAreaAndEdit)
        #expect(AppPreferences(defaults: existing).capabilityShortcut(for: .screenshotAreaAndEdit) == nil)
        #expect(AppPreferences(defaults: existing).capabilityShortcut(for: .screenshotScreen) == DefaultShortcut.screenshotScreen)
    }
}

private final class FakeCaptureRunner: ScreenshotCaptureRunning {
    let writesFirstFileOnly: Bool
    var writesNothing = false
    private(set) var arguments: [String] = []

    init(writesFirstFileOnly: Bool) { self.writesFirstFileOnly = writesFirstFileOnly }

    func run(arguments: [String], completion: @escaping @MainActor () -> Void) {
        self.arguments = arguments
        let files = arguments.filter { $0.hasSuffix(".png") }
        if !writesNothing {
            for path in writesFirstFileOnly ? Array(files.prefix(1)) : files {
                FileManager.default.createFile(atPath: path, contents: Data([0x89, 0x50]))
            }
        }
        Task { @MainActor in completion() }
    }
}

/// Writes a PNG of its own for each file and exits at once, as `screencapture` would.
private final class PNGCaptureRunner: ScreenshotCaptureRunning {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!

    func run(arguments: [String], completion: @escaping @MainActor () -> Void) {
        for file in arguments.filter({ $0.hasSuffix(".png") }) {
            FileManager.default.createFile(atPath: file, contents: Self.png + Data(file.utf8))
        }
        MainActor.assumeIsolated { completion() }
    }
}

private final class FakeSymbolicHotKeys: SymbolicHotKeyPreferences {
    private(set) var hotKeys: [String: Any]
    private(set) var writes = 0
    private(set) var reloads = 0

    init(hotKeys: [String: Any]) { self.hotKeys = hotKeys }

    func readSymbolicHotKeys() throws -> [String: Any] { hotKeys }
    func writeSymbolicHotKeys(_ hotKeys: [String: Any]) throws { self.hotKeys = hotKeys; writes += 1 }
    func reloadSymbolicHotKeys() throws { reloads += 1 }

    func isEnabled(_ id: String) -> Bool? {
        ((hotKeys[id] as? [String: Any])?["enabled"] as? NSNumber)?.boolValue
            ?? (hotKeys[id] as? [String: Any])?["enabled"] as? Bool
    }
}
