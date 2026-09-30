import AppKit
import Foundation
import Testing
@testable import Keybumps

/// The Command Palette's Clipboard tab rows show no kind word; the preview is the kind. These check
/// what each row still says to VoiceOver and search, and the title of an image with no name.
/// Every item is made up.
@MainActor
@Suite("Clipboard tab rows")
struct ClipboardRowTests {
    static let text = ClipboardEntry(id: UUID(), text: "made-up text", capturedAt: Date())
    static let copiedImage = ClipboardEntry(
        id: UUID(), text: "", capturedAt: Date(), kind: .image,
        mediaPath: "/tmp/made-up.png", mediaPasteboardType: "public.png", fingerprint: "image:made-up"
    )
    static let screenshot = ClipboardEntry(
        id: UUID(), text: "", capturedAt: Date(), kind: .image,
        mediaPath: "/tmp/made-up-shot.png", mediaPasteboardType: "public.png", fingerprint: "image:made-up-shot",
        sourcePath: "/tmp/Screenshot made-up.png", isScreenCapture: true
    )
    static let imageFile = ClipboardEntry(
        id: UUID(), text: "", capturedAt: Date(), kind: .image,
        mediaPath: "/tmp/made-up-file.png", mediaPasteboardType: "public.png", fingerprint: "image:made-up-file",
        sourcePath: "/tmp/made-up diagram.png", isScreenCapture: false
    )

    @Test("Each row still tells VoiceOver its kind")
    func accessibilityKind() {
        #expect(ClipboardRowPresentation.accessibilityKind(of: Self.text) == "Copied text")
        #expect(ClipboardRowPresentation.accessibilityKind(of: Self.copiedImage) == "Copied image")
        #expect(ClipboardRowPresentation.accessibilityKind(of: Self.imageFile) == "Copied image")
        #expect(ClipboardRowPresentation.accessibilityKind(of: Self.screenshot) == "Screenshot")
    }

    @Test("Searching a kind word still finds images and screenshots")
    func searchStillMatchesKinds() {
        #expect(Self.copiedImage.matches("image"))
        #expect(Self.imageFile.matches("image"))
        #expect(Self.screenshot.matches("screenshot"))
        #expect(!Self.text.matches("image"))
    }

    @Test("A row's title is the text, a file's name, or an unnamed image's pixel size")
    func titles() {
        #expect(ClipboardRowPresentation.title(for: Self.text, pixelSize: nil) == "made-up text")
        #expect(ClipboardRowPresentation.title(for: Self.screenshot, pixelSize: "8 × 6") == "Screenshot made-up")
        #expect(ClipboardRowPresentation.title(for: Self.imageFile, pixelSize: "8 × 6") == "made-up diagram")
        #expect(ClipboardRowPresentation.title(for: Self.copiedImage, pixelSize: "8 × 6") == "8 × 6")
        #expect(ClipboardRowPresentation.title(for: Self.copiedImage, pixelSize: nil) == "Image", "Until the size is read")
    }

    @Test("Text rows show one line: runs of spaces, tabs, and newlines become single spaces")
    func singleLineText() {
        let multiLine = ClipboardEntry(id: UUID(), text: "\n  First made-up line\n\n\tsecond line  \r\nthird\n", capturedAt: Date())
        #expect(ClipboardRowPresentation.title(for: multiLine, pixelSize: nil) == "First made-up line second line third")
        #expect(ClipboardRowPresentation.singleLine("made-up") == "made-up")

        let long = String(repeating: "made-up words ", count: 1_000)
        let title = ClipboardRowPresentation.singleLine(long)
        #expect(title.count <= 500, "Only the start of a long copy is read")
        #expect(title.hasPrefix("made-up words made-up words"))
    }

    @Test("Timestamps are always the same width, on a 24-hour or a 12-hour clock")
    func timestamps() throws {
        let timeZone = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 3, minute: 37)))
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 25, hour: 15, minute: 5)))

        let twentyFour = ClipboardRowPresentation.makeTimestampFormatter(usesTwentyFourHourClock: true, timeZone: timeZone)
        #expect(twentyFour.string(from: early) == "09/03/2026 @ 03:37")
        #expect(twentyFour.string(from: late) == "12/25/2026 @ 15:05")
        #expect(twentyFour.string(from: early).count == twentyFour.string(from: late).count)

        let twelve = ClipboardRowPresentation.makeTimestampFormatter(usesTwentyFourHourClock: false, timeZone: timeZone)
        #expect(twelve.string(from: early) == "09/03/2026 @ 03:37 AM")
        #expect(twelve.string(from: late) == "12/25/2026 @ 03:05 PM")
        #expect(twelve.string(from: early).count == twelve.string(from: late).count)

        #expect(!ClipboardRowPresentation.usesTwentyFourHourClock(locale: Locale(identifier: "en_US")))
        #expect(ClipboardRowPresentation.usesTwentyFourHourClock(locale: Locale(identifier: "en_GB")))
        #expect(ClipboardRowPresentation.usesTwentyFourHourClock(locale: Locale(identifier: "de_DE")))
    }

    @Test("An image's pixel size is read from its file")
    func pixelSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsClipboardRow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let file = folder.appendingPathComponent("made-up.png")
        try png.write(to: file)

        #expect(ClipboardRowPresentation.pixelSize(ofImageAt: file) == "8 × 6")
        #expect(ClipboardRowPresentation.pixelSize(ofImageAt: folder.appendingPathComponent("missing.png")) == nil)
    }
}
