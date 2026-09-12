import AppKit
import SwiftUI
import XCTest
@testable import SERPCompanion

@MainActor
final class PresentationEvidenceTests: XCTestCase {
    private let visualChannels: [NotificationChannel] = [
        .topRightToast,
        .topCenterShelf,
        .cursorHalo,
        .pointerCard,
        .statusFeedback,
        .decisionBanner
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
        XCTAssertEqual(controller.panelSize(for: .cursorHalo), NSSize(width: 120, height: 120))
        XCTAssertEqual(controller.panelSize(for: .pointerCard), NSSize(width: 320, height: 92))
        XCTAssertEqual(controller.panelSize(for: .statusFeedback), NSSize(width: 300, height: 76))
        XCTAssertEqual(controller.panelSize(for: .decisionBanner), NSSize(width: 700, height: 128))
        XCTAssertEqual(controller.dismissalDelayNanoseconds(for: .topRightToast), 4_000_000_000)
        XCTAssertEqual(controller.dismissalDelayNanoseconds(for: .decisionBanner), 8_000_000_000)
        XCTAssertTrue(controller.panelCollectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(controller.panelCollectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testPointerPresentationsFollowTheDisplayContainingTheEvent() {
        let primary = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let secondaryVisible = NSRect(x: 1_440, y: 0, width: 1_920, height: 1_040)
        let pointer = PresentationLayout.appKitPoint(
            fromQuartzPoint: NSPoint(x: 1_800, y: 450),
            primaryScreenFrame: primary
        )

        XCTAssertTrue(secondaryVisible.contains(pointer))
        XCTAssertEqual(
            PresentationLayout.origin(
                for: .cursorHalo,
                size: NSSize(width: 120, height: 120),
                visibleFrame: secondaryVisible,
                pointer: pointer
            ),
            NSPoint(x: 1_740, y: 390)
        )
        XCTAssertEqual(
            PresentationLayout.origin(
                for: .pointerCard,
                size: NSSize(width: 320, height: 92),
                visibleFrame: secondaryVisible,
                pointer: pointer
            ),
            NSPoint(x: 1_818, y: 404)
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
