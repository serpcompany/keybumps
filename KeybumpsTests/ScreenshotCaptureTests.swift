import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("Screenshot capture")
struct ScreenshotCaptureTests {
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Screens capture one macOS-named file per display; an area captures one, interactively")
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

    // MARK: macOS shortcut takeover

    @Test("Matching Keybumps hotkeys turn off macOS's ⇧⌘3 and ⇧⌘4, then give them back")
    func takeoverAndRestore() {
        let store = FakeSymbolicHotKeys(hotKeys: [:])
        var owned: Set<String> = []
        let takeover = SystemScreenshotShortcutTakeover(preferences: store, takenOver: { owned }, setTakenOver: { owned = $0 })
        let keybumps = [DefaultShortcut.screenshotScreen, DefaultShortcut.screenshotScreenAndEdit, DefaultShortcut.screenshotArea]

        takeover.apply(bindings: keybumps, isEnabled: true)
        #expect(store.isEnabled("28") == false)
        #expect(store.isEnabled("30") == false)
        #expect(owned == ["28", "30"])
        #expect(store.reloads == 1)

        takeover.apply(bindings: keybumps, isEnabled: true)
        #expect(store.writes == 1, "No change, no write")

        takeover.apply(bindings: keybumps, isEnabled: false)
        #expect(store.isEnabled("28") == true)
        #expect(store.isEnabled("30") == true)
        #expect(owned.isEmpty)
    }

    @Test("Moving a hotkey off macOS's keys gives only that shortcut back")
    func movingOneHotkeyRestoresOnlyIt() {
        let store = FakeSymbolicHotKeys(hotKeys: [:])
        var owned: Set<String> = []
        let takeover = SystemScreenshotShortcutTakeover(preferences: store, takenOver: { owned }, setTakenOver: { owned = $0 })
        takeover.apply(bindings: [DefaultShortcut.screenshotScreenAndEdit, DefaultShortcut.screenshotArea], isEnabled: true)

        let moved = ShortcutBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | optionKey), displayName: "⌥⌘3")
        takeover.apply(bindings: [moved, DefaultShortcut.screenshotArea], isEnabled: true)
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
        #expect(fresh.capabilityShortcut(for: .screenshotArea) == DefaultShortcut.screenshotArea)

        let existing = InMemoryDefaults()
        let original = Dictionary(uniqueKeysWithValues: CapabilityShortcut.originalShortcuts.map { ($0.rawValue, $0.defaultBinding) })
        existing.set(try JSONEncoder().encode(original), forKey: "capabilityShortcuts")
        let upgraded = AppPreferences(defaults: existing)
        #expect(upgraded.capabilityShortcut(for: .screenshotArea) == DefaultShortcut.screenshotArea)

        upgraded.setCapabilityShortcut(nil, for: .screenshotArea)
        #expect(AppPreferences(defaults: existing).capabilityShortcut(for: .screenshotArea) == nil)
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
