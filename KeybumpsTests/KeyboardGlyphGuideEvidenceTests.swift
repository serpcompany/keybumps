import AppKit
import SwiftUI
import XCTest
@testable import Keybumps

@MainActor
final class KeyboardGlyphGuideEvidenceTests: XCTestCase {
    func testInlineKeyboardGlyphGuideRendersToReviewablePNG() throws {
        let requestedDirectory = ProcessInfo.processInfo.environment["PRESENTATION_EVIDENCE_DIR"]
        let outputDirectory = requestedDirectory.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("KeyboardGlyphGuideEvidence")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let size = NSSize(width: 720, height: 420)
        let destination = outputDirectory.appendingPathComponent("inline-keyboard-symbols.png")
        let root = VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard symbols")
                .font(.headline)
            KeyboardGlyphLegendContent(entries: KeyboardShortcutRegistry.legendEntries)
        }
        .padding(20)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: destination, options: .atomic)

        XCTAssertGreaterThan(png.count, 1_000)
        XCTAssertEqual(try XCTUnwrap(NSImage(data: png)).size, size)
    }
}
