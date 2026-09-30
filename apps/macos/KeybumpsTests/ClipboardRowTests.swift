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
