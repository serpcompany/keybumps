import AppKit
import Foundation
import Testing
@testable import Keybumps

@MainActor
@Suite("New screenshots on the clipboard")
struct ScreenshotClipboardTests {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n4cAAAAASUVORK5CYII=")!

    @Test("A new screenshot goes on the clipboard, and Clipboard History doesn't add that copy again")
    func copiesNewScreenshots() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })

        #expect(delivery.add(shot))
        #expect(fixture.pasteboard.data(forType: .png) == Self.png)
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.count == 1)
        #expect(fixture.clipboard.entries.first?.isScreenshot == true)
        #expect(fixture.clipboard.entries.first?.sourceURL == shot)
    }

    @Test("With the setting off, screenshots reach Clipboard History but leave the clipboard alone")
    func leavesClipboardAloneWhenOff() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { false })
        let changeCount = fixture.pasteboard.changeCount

        #expect(delivery.add(shot))
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.clipboard.entries.first?.isScreenshot == true)
    }

    @Test("A screenshot file is added and copied once, so a later copy (like an edit's Save) stays on the clipboard")
    func addsEachFileOnce() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        #expect(delivery.add(shot))

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("copied since", forType: .string)
        fixture.clipboard.pollForTesting()

        #expect(!delivery.add(shot), "the watcher seeing the Screen and Edit hotkey's file again")
        #expect(fixture.pasteboard.string(forType: .string) == "copied since")
        #expect(fixture.clipboard.entries.map(\.kind) == [.text, .image])
    }

    @Test("Copying new screenshots is on by default and remembers being turned off")
    func preferenceDefaultsOn() {
        let defaults = InMemoryDefaults()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.copiesScreenshotsToClipboard)

        preferences.copiesScreenshotsToClipboard = false
        #expect(!AppPreferences(defaults: defaults).copiesScreenshotsToClipboard)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let pasteboard: NSPasteboard
        let clipboard: ClipboardHistoryService

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsScreenshotClipboard-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsScreenshotClipboard-\(UUID().uuidString)"))
            clipboard = ClipboardHistoryService(
                storageURL: root.appendingPathComponent("history.json"),
                pasteboard: pasteboard,
                mediaDirectoryURL: root.appendingPathComponent("media", isDirectory: true)
            )
        }

        func screenshot() throws -> URL {
            let url = root.appendingPathComponent("Screenshot 2026-09-30 at 10.00.00.png")
            try ScreenshotClipboardTests.png.write(to: url)
            return url
        }

        func tearDown() {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
