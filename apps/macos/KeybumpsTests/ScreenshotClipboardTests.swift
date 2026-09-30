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
        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: shot)))
        // A newer item keeps the newest-item duplicate check from hiding a second add.
        fixture.clipboard.ingestForTesting("newer")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.map(\.kind) == [.text, .image])
        #expect(fixture.clipboard.entries.last?.isScreenshot == true)
        #expect(fixture.clipboard.entries.last?.sourceURL == shot)
    }

    @Test("Something copied since the last poll reaches Clipboard History before the screenshot replaces it")
    func recordsPendingCopyFirst() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shot = try fixture.screenshot()
        let delivery = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        fixture.clipboard.start()
        defer { fixture.clipboard.stop() }

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("copied just now", forType: .string)
        #expect(delivery.add(shot))

        #expect(fixture.pasteboard.data(forType: .png) == (try Data(contentsOf: shot)))
        #expect(fixture.clipboard.entries.map(\.kind) == [.image, .text])
        #expect(fixture.clipboard.entries.last?.text == "copied just now")
    }

    @Test("With the setting off, or for the Screen and Edit hotkey, screenshots reach Clipboard History but leave the clipboard alone")
    func leavesClipboardAloneWhenNotCopying() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let off = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { false })
        let on = ScreenshotClipboardDelivery(clipboard: fixture.clipboard, copiesToClipboard: { true })
        let changeCount = fixture.pasteboard.changeCount

        #expect(off.add(try fixture.screenshot("Screenshot 1.png")))
        #expect(on.add(try fixture.screenshot("Screenshot 2.png"), copying: false))
        #expect(fixture.pasteboard.changeCount == changeCount)
        #expect(fixture.clipboard.entries.map(\.isScreenshot) == [true, true])
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

        /// Each file gets its own pixels, so Clipboard History never treats two as the same item.
        func screenshot(_ name: String = "Screenshot 2026-09-30 at 10.00.00.png") throws -> URL {
            let url = root.appendingPathComponent(name)
            try (ScreenshotClipboardTests.png + Data(name.utf8)).write(to: url)
            return url
        }

        func tearDown() {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
