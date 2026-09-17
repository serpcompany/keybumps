import AppKit
import SwiftUI
import XCTest
@testable import SuperMac

@MainActor
final class PresentationEvidenceTests: XCTestCase {
    private let visualChannels: [NotificationChannel] = [
        .topRightToast,
        .topCenterShelf
    ]

    func testEveryCustomPresentationRendersToReviewablePNG() throws {
        let requestedDirectory = ProcessInfo.processInfo.environment["PRESENTATION_EVIDENCE_DIR"]
        let outputDirectory = requestedDirectory.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ShortcutCoachPresentationEvidence")
        if requestedDirectory == nil {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let controller = PresentationWindowController()
        for channel in visualChannels {
            let size = controller.panelSize(for: channel)
            let destination = outputDirectory.appendingPathComponent("\(channel.rawValue).png")
            try render(channel: channel, size: size, to: destination)

            let data = try Data(contentsOf: destination)
            XCTAssertGreaterThan(data.count, 1_000, "\(channel.title) evidence should contain a rendered UI")
            let image = try XCTUnwrap(NSImage(data: data))
            XCTAssertEqual(image.size, size)
        }
    }

    func testPresentationGeometryAndTimingContract() {
        let controller = PresentationWindowController()

        XCTAssertEqual(controller.panelSize(for: .topRightToast), NSSize(width: 360, height: 92))
        XCTAssertEqual(controller.panelSize(for: .topCenterShelf), NSSize(width: 500, height: 112))
        XCTAssertEqual(controller.dismissalDelayNanoseconds(for: .topRightToast), 4_000_000_000)
        XCTAssertTrue(controller.panelCollectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(controller.panelCollectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testKeyboardGlyphLegendRendersToReviewablePNG() throws {
        let requestedDirectory = ProcessInfo.processInfo.environment["PRESENTATION_EVIDENCE_DIR"]
        let outputDirectory = requestedDirectory.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ShortcutCoachPresentationEvidence")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let size = NSSize(width: 420, height: 520)
        let destination = outputDirectory.appendingPathComponent("keyboard-glyph-legend.png")
        let root = VStack(spacing: 0) {
            Text("Keyboard Glyph Legend")
                .font(.title2.bold())
                .padding()
            Divider()
            KeyboardGlyphLegendContent(entries: KeyboardShortcutRegistry.legendEntries)
        }
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

    func testToastPresentationUsesTheDisplayContainingTheEvent() {
        let primary = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let secondaryVisible = NSRect(x: 1_440, y: 0, width: 1_920, height: 1_040)
        let pointer = PresentationLayout.appKitPoint(
            fromQuartzPoint: NSPoint(x: 1_800, y: 450),
            primaryScreenFrame: primary
        )

        XCTAssertTrue(secondaryVisible.contains(pointer))
        XCTAssertEqual(
            PresentationLayout.origin(
                for: .topRightToast,
                size: NSSize(width: 360, height: 92),
                visibleFrame: secondaryVisible,
                pointer: pointer
            ),
            NSPoint(x: 2_980, y: 928)
        )
    }

    private func render(channel: NotificationChannel, size: NSSize, to destination: URL) throws {
        let root = CoachingPresentationView(event: .sample, style: channel, onDismiss: {})
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: destination, options: .atomic)
    }
}
