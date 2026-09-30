import AppKit
import Carbon.HIToolbox
import Foundation

/// What a Screenshot Tools hotkey captures.
enum ScreenshotCaptureMode: Equatable {
    /// Every display, one file each.
    case screens
    /// An area the user selects; Escape cancels.
    case area
}

/// How `/usr/sbin/screencapture` is called and where the files go, named like macOS's own
/// screenshots so Finder and Clipboard History treat them the same.
enum ScreenshotCapturePlan {
    static func files(in folder: URL, at date: Date, displayCount: Int, mode: ScreenshotCaptureMode) -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screenshot \(formatter.string(from: date))"
        let count = mode == .area ? 1 : max(displayCount, 1)
        return (1...count).map { index in
            folder.appendingPathComponent(index == 1 ? "\(base).png" : "\(base) (\(index)).png")
        }
    }

    static func arguments(for mode: ScreenshotCaptureMode, files: [URL]) -> [String] {
        let modeArguments = mode == .area ? ["-i"] : []
        return modeArguments + ["-t", "png"] + files.map(\.path)
    }
}

/// Runs the capture tool. Injected so tests never capture the screen.
protocol ScreenshotCaptureRunning {
    func run(arguments: [String], completion: @escaping @MainActor () -> Void)
}

struct ProcessScreenshotCaptureRunner: ScreenshotCaptureRunning {
    func run(arguments: [String], completion: @escaping @MainActor () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { _ in Task { @MainActor in completion() } }
        do {
            try process.run()
        } catch {
            Task { @MainActor in completion() }
        }
    }
}

/// Takes screenshots into the macOS screenshot folder and marks them as screen captures, so the
/// Screenshot Tools watcher adds them to Clipboard History like screenshots macOS takes.
@MainActor
final class ScreenshotCapturer {
    private let runner: any ScreenshotCaptureRunning
    private let folder: () -> URL
    private let now: () -> Date
    private let displayCount: () -> Int
    private let fileManager: FileManager

    init(
        runner: any ScreenshotCaptureRunning = ProcessScreenshotCaptureRunner(),
        folder: @escaping () -> URL = { ScreenshotLocationResolver.system.resolve() },
        now: @escaping () -> Date = Date.init,
        displayCount: @escaping () -> Int = { NSScreen.screens.count },
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.folder = folder
        self.now = now
        self.displayCount = displayCount
        self.fileManager = fileManager
    }

    /// Calls `completion` with the files actually written (none when an area capture is cancelled).
    func capture(_ mode: ScreenshotCaptureMode, completion: @escaping @MainActor ([URL]) -> Void) {
        let files = ScreenshotCapturePlan.files(in: folder(), at: now(), displayCount: displayCount(), mode: mode)
        runner.run(arguments: ScreenshotCapturePlan.arguments(for: mode, files: files)) { [fileManager] in
            let written = files.filter { fileManager.fileExists(atPath: $0.path) }
            written.forEach(Self.markAsScreenCapture)
            completion(written)
        }
    }

    private static func markAsScreenCapture(_ url: URL) {
        guard getxattr(url.path, FileSystemScreenshotDirectoryReader.screenCaptureAttribute, nil, 0, 0, 0) < 0,
              let value = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        else { return }
        _ = value.withUnsafeBytes {
            setxattr(url.path, FileSystemScreenshotDirectoryReader.screenCaptureAttribute, $0.baseAddress, value.count, 0, 0)
        }
    }
}

/// Turns off macOS's own "save picture of screen" (⇧⌘3) and "save picture of selected area"
/// (⇧⌘4) shortcuts while a Keybumps screenshot hotkey uses the same keys, and turns them back on
/// when Screenshot Tools is off or the hotkey moves. Only shortcuts Keybumps turned off are
/// restored.
@MainActor
final class SystemScreenshotShortcutTakeover {
    /// macOS symbolic hotkey IDs and their defaults: (ascii, keyCode, Cocoa modifiers).
    static let managed: [(id: String, defaults: [Int])] = [
        ("28", [51, kVK_ANSI_3, 1_179_648]),
        ("30", [52, kVK_ANSI_4, 1_179_648])
    ]

    private let preferences: any SymbolicHotKeyPreferences
    private let takenOver: () -> Set<String>
    private let setTakenOver: (Set<String>) -> Void

    init(
        preferences: any SymbolicHotKeyPreferences,
        takenOver: @escaping () -> Set<String>,
        setTakenOver: @escaping (Set<String>) -> Void
    ) {
        self.preferences = preferences
        self.takenOver = takenOver
        self.setTakenOver = setTakenOver
    }

    func apply(bindings: [ShortcutBinding], isEnabled: Bool) {
        guard var hotKeys = try? preferences.readSymbolicHotKeys() else { return }
        var owned = takenOver()
        var changed = false
        for (id, defaults) in Self.managed {
            var entry = hotKeys[id] as? [String: Any] ?? [
                "enabled": true,
                "value": ["parameters": defaults, "type": "standard"] as [String: Any]
            ]
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int] ?? defaults
            let conflicts = isEnabled && parameters.count >= 3 && bindings.contains {
                Int($0.keyCode) == parameters[1] && SymbolicHotKeyModifiers.cocoa(for: $0.modifiers) == parameters[2]
            }
            let isOn = (entry["enabled"] as? NSNumber)?.boolValue ?? true
            if conflicts, isOn {
                entry["enabled"] = false
                owned.insert(id)
            } else if !conflicts, owned.contains(id) {
                entry["enabled"] = true
                owned.remove(id)
            } else {
                continue
            }
            hotKeys[id] = entry
            changed = true
        }
        guard changed else { return }
        do {
            try preferences.writeSymbolicHotKeys(hotKeys)
            try preferences.reloadSymbolicHotKeys()
            setTakenOver(owned)
        } catch {
            // Leave the record unchanged so the next apply retries.
        }
    }
}

/// Converts Carbon modifier masks to the Cocoa masks stored in symbolic hotkeys.
enum SymbolicHotKeyModifiers {
    static func cocoa(for carbonModifiers: UInt32) -> Int {
        var modifiers = 0
        if carbonModifiers & UInt32(cmdKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.command.rawValue) }
        if carbonModifiers & UInt32(shiftKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.shift.rawValue) }
        if carbonModifiers & UInt32(optionKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.option.rawValue) }
        if carbonModifiers & UInt32(controlKey) != 0 { modifiers |= Int(NSEvent.ModifierFlags.control.rawValue) }
        return modifiers
    }
}

/// Used in tests and UI-test mode so nothing reads or writes the real symbolic hotkeys.
final class InertSymbolicHotKeyPreferences: SymbolicHotKeyPreferences {
    func readSymbolicHotKeys() throws -> [String: Any] { throw SymbolicHotKeyPreferencesError.unreadable }
    func writeSymbolicHotKeys(_ hotKeys: [String: Any]) throws {}
    func reloadSymbolicHotKeys() throws {}
}
