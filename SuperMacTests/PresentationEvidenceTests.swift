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

    private let fixtures: [(name: String, event: CoachingEvent)] = [
        ("short", .sample),
        (
            "line-ends",
            CoachingEvent(
                applicationName: "Visual Studio Code",
                actionTitle: "Add Cursors to Line Ends",
                shortcut: "⇧⌥I"
            )
        ),
        (
            "long-shortcut",
            CoachingEvent(
                applicationName: "Cursor",
                actionTitle: "Add Cursors to Every Selected Line End",
                shortcut: "⌃⌥⌘-"
            )
        ),
        (
            "long-application",
            CoachingEvent(
                applicationName: "Visual Studio Code - Insiders",
                actionTitle: "Add Cursors to Every Selected Line End",
                shortcut: "⌃⌥⌘-"
            )
        )
    ]

    func testEveryCustomPresentationFixtureRendersToReviewablePNG() throws {
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
            for fixture in fixtures {
                let size = controller.panelSize(for: channel, event: fixture.event)
                let destination = outputDirectory
                    .appendingPathComponent("\(channel.rawValue)-\(fixture.name).png")
                try render(event: fixture.event, channel: channel, size: size, to: destination)

                let data = try Data(contentsOf: destination)
                XCTAssertGreaterThan(data.count, 1_000, "\(channel.title) evidence should contain a rendered UI")
                let image = try XCTUnwrap(NSImage(data: data))
                XCTAssertEqual(image.size, size)
            }
        }
    }

    func testPresentationContractKeepsShortContentCompactAndLongContentBounded() {
        let shortToast = CoachingPresentationContract(event: .sample, style: .topRightToast)
        XCTAssertEqual(shortToast.layout, .compact)
        XCTAssertEqual(shortToast.panelSize, NSSize(width: 360, height: 92))

        for fixture in fixtures.dropFirst() {
            for channel in visualChannels {
                let contract = CoachingPresentationContract(event: fixture.event, style: channel)
                XCTAssertEqual(contract.layout, .expanded)
                XCTAssertLessThanOrEqual(contract.panelSize.width, channel == .topRightToast ? 420 : 500)
                XCTAssertLessThanOrEqual(contract.panelSize.height, 148)
                XCTAssertEqual(contract.secondaryText, fixture.event.applicationName)
                XCTAssertEqual(contract.shortcutDisplayCount, 1)
                XCTAssertFalse(contract.showsDecorativeIcon)
                XCTAssertEqual(contract.closePlacement, .topTrailingOverlay)
            }
        }
    }

    func testPresentationAccessibilityAnnouncesEventValuesExactlyOnce() {
        let event = fixtures[2].event
        let contract = CoachingPresentationContract(event: event, style: .topRightToast)

        XCTAssertEqual(contract.accessibilityLabel.components(separatedBy: event.coachingTitle).count - 1, 1)
        XCTAssertEqual(contract.accessibilityLabel.components(separatedBy: event.applicationName).count - 1, 1)
        XCTAssertEqual(contract.accessibilityLabel.components(separatedBy: event.shortcut).count - 1, 1)
    }

    func testPresentationGeometryAndTimingContract() {
        let controller = PresentationWindowController()

        XCTAssertEqual(controller.panelSize(for: .topRightToast), NSSize(width: 360, height: 92))
        XCTAssertEqual(controller.panelSize(for: .topCenterShelf), NSSize(width: 500, height: 112))
        XCTAssertEqual(controller.dismissalDelayNanoseconds(for: .topRightToast), 4_000_000_000)
        XCTAssertTrue(controller.panelCollectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(controller.panelCollectionBehavior.contains(.fullScreenAuxiliary))
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

    private func render(
        event: CoachingEvent,
        channel: NotificationChannel,
        size: NSSize,
        to destination: URL
    ) throws {
        let root = CoachingPresentationView(event: event, style: channel, onDismiss: {})
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
