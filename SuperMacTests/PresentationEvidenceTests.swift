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

    private let fixtures: [(name: String, event: CoachingEvent, expectsFallback: Bool)] = [
        (
            "source-control",
            CoachingEvent(applicationName: "Code", actionTitle: "Source Control", shortcut: "⇧⌘G"),
            false
        ),
        (
            "command-palette",
            CoachingEvent(applicationName: "Code", actionTitle: "Command Palette…", shortcut: "⇧⌘P"),
            false
        ),
        (
            "line-ends",
            CoachingEvent(
                applicationName: "Code",
                actionTitle: "Add Cursors to Line Ends",
                shortcut: "⇧⌥I"
            ),
            false
        ),
        (
            "run-active-file",
            CoachingEvent(
                applicationName: "Code",
                actionTitle: "Run Active File",
                shortcut: "⌃⌥⌘R"
            ),
            false
        ),
        (
            "extreme-fallback",
            CoachingEvent(
                applicationName: "Code",
                actionTitle: "A deliberately extreme synthetic command title that cannot fit on one line even at the maximum safe presentation width and continues with enough source-exact detail to require the bounded multiline fallback without hiding any information",
                shortcut: "⇧⌃⌥⌘R"
            ),
            true
        )
    ]

    func testEveryRequiredFixtureRendersInBothCustomChannels() throws {
        let requestedDirectory = ProcessInfo.processInfo.environment["PRESENTATION_EVIDENCE_DIR"]
        let outputDirectory = requestedDirectory.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("SuperMacPresentationEvidence")
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
                XCTAssertGreaterThan(data.count, 1_000, "\(channel.title) evidence should contain rendered UI")
                let image = try XCTUnwrap(NSImage(data: data))
                XCTAssertEqual(image.size, size)
            }
        }
    }

    func testRequiredRealisticFixturesRemainExactSingleRowAndCompact() {
        for fixture in fixtures where !fixture.expectsFallback {
            for channel in visualChannels {
                let contract = CoachingPresentationContract(event: fixture.event, style: channel)

                XCTAssertEqual(contract.title, fixture.event.actionTitle)
                XCTAssertEqual(contract.applicationName, fixture.event.applicationName)
                XCTAssertEqual(contract.shortcut, fixture.event.shortcut)
                XCTAssertFalse(contract.usesWrappedCopy, fixture.name)
                XCTAssertTrue(contract.keepsShortcutInPrimaryRow, fixture.name)
                XCTAssertEqual(
                    contract.panelSize.height,
                    CoachingPresentationContract.compactPanelSize(for: channel).height,
                    fixture.name
                )
                XCTAssertGreaterThanOrEqual(
                    contract.panelSize.width,
                    CoachingPresentationContract.compactPanelSize(for: channel).width
                )
                XCTAssertLessThanOrEqual(contract.panelSize.width, CoachingPresentationContract.maximumWidth)
                XCTAssertGreaterThanOrEqual(
                    contract.copyWidth,
                    max(contract.measurements.titleWidth, contract.measurements.applicationWidth)
                )
            }
        }
    }

    func testWidthDecisionUsesMeasuredContentRatherThanCharacterCount() {
        let event = CoachingEvent(applicationName: "Code", actionTitle: String(repeating: "W", count: 40), shortcut: "⌘W")
        let compactMeasurements = CoachingPresentationMeasurements(
            titleWidth: 80,
            applicationWidth: 32,
            shortcutWidth: 60,
            titleLineHeight: 16,
            applicationLineHeight: 14
        )
        let wideMeasurements = CoachingPresentationMeasurements(
            titleWidth: 500,
            applicationWidth: 32,
            shortcutWidth: 60,
            titleLineHeight: 16,
            applicationLineHeight: 14
        )

        let compact = CoachingPresentationContract(
            event: event,
            style: .topRightToast,
            measurements: compactMeasurements
        )
        let wide = CoachingPresentationContract(
            event: event,
            style: .topRightToast,
            measurements: wideMeasurements
        )

        XCTAssertFalse(compact.usesWrappedCopy)
        XCTAssertEqual(compact.panelSize.width, 360)
        XCTAssertFalse(wide.usesWrappedCopy, "measured content should consume available width before wrapping")
        XCTAssertGreaterThan(wide.panelSize.width, compact.panelSize.width)
        XCTAssertEqual(wide.panelSize.height, compact.panelSize.height)
    }

    func testExtremeFixtureUsesBoundedMeasuredFallbackWithoutDroppingContent() {
        let fixture = fixtures.first { $0.expectsFallback }!

        for channel in visualChannels {
            let contract = CoachingPresentationContract(event: fixture.event, style: channel)

            XCTAssertEqual(contract.title, fixture.event.actionTitle)
            XCTAssertTrue(contract.usesWrappedCopy)
            XCTAssertTrue(contract.keepsShortcutInPrimaryRow)
            XCTAssertEqual(contract.panelSize.width, CoachingPresentationContract.maximumWidth)
            XCTAssertGreaterThan(
                contract.panelSize.height,
                CoachingPresentationContract.compactPanelSize(for: channel).height
            )
            XCTAssertLessThanOrEqual(contract.panelSize.height, CoachingPresentationContract.maximumHeight)
        }
    }

    func testPresentationAccessibilityUsesSourceValuesExactlyOnce() {
        let event = fixtures[1].event
        let contract = CoachingPresentationContract(event: event, style: .topRightToast)

        XCTAssertEqual(contract.accessibilityLabel.components(separatedBy: event.actionTitle).count - 1, 1)
        XCTAssertEqual(contract.accessibilityLabel.components(separatedBy: event.applicationName).count - 1, 1)
        XCTAssertEqual(contract.accessibilityLabel.components(separatedBy: event.shortcut).count - 1, 1)
        XCTAssertFalse(contract.accessibilityLabel.contains(event.coachingTitle))
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
