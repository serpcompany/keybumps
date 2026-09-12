import CoreGraphics
import XCTest
@testable import SuperMac

final class FinderTrashDetectionTests: XCTestCase {
    private let detector = DragDropActionDetector()

    func testVerifiedFinderDragToDockTrashProducesMoveToTrashCoaching() {
        let trace = DragDropTrace(
            schemaVersion: DragDropActionDetector.currentSchemaVersion,
            itemEligibility: .supportedRegularItem,
            releasedOnDockTrash: true,
            meaningfulDrag: true,
            modifiersPresent: false,
            postcondition: .removedFromOriginalParent
        )

        let event = detector.detect(trace)
        XCTAssertEqual(event?.applicationName, "Finder")
        XCTAssertEqual(event?.actionTitle, "Move to Trash")
        XCTAssertEqual(event?.shortcut, "⌘⌫")
    }

    func testEveryUnverifiedOrUnsafeScenarioProducesNoCoaching() {
        let baseline = DragDropTrace(
            schemaVersion: DragDropActionDetector.currentSchemaVersion,
            itemEligibility: .supportedRegularItem,
            releasedOnDockTrash: true,
            meaningfulDrag: true,
            modifiersPresent: false,
            postcondition: .removedFromOriginalParent
        )
        let unsafeItems: [FinderTrashItemEligibility] = [
            .multipleSelection, .volume, .alias, .lockedOrImmutable,
            .externalOrNetwork, .readOnly, .unknown
        ]
        for item in unsafeItems {
            XCTAssertNil(detector.detect(.init(
                schemaVersion: baseline.schemaVersion,
                itemEligibility: item,
                releasedOnDockTrash: baseline.releasedOnDockTrash,
                meaningfulDrag: baseline.meaningfulDrag,
                modifiersPresent: baseline.modifiersPresent,
                postcondition: baseline.postcondition
            )), "unexpected event for \(item)")
        }

        XCTAssertNil(detector.detect(.init(
            schemaVersion: baseline.schemaVersion,
            itemEligibility: baseline.itemEligibility,
            releasedOnDockTrash: false,
            meaningfulDrag: baseline.meaningfulDrag,
            modifiersPresent: baseline.modifiersPresent,
            postcondition: baseline.postcondition
        )), "hovering over Trash before releasing elsewhere must suppress")
        XCTAssertNil(detector.detect(.init(
            schemaVersion: baseline.schemaVersion,
            itemEligibility: baseline.itemEligibility,
            releasedOnDockTrash: baseline.releasedOnDockTrash,
            meaningfulDrag: false,
            modifiersPresent: baseline.modifiersPresent,
            postcondition: baseline.postcondition
        )))
        XCTAssertNil(detector.detect(.init(
            schemaVersion: baseline.schemaVersion,
            itemEligibility: baseline.itemEligibility,
            releasedOnDockTrash: baseline.releasedOnDockTrash,
            meaningfulDrag: baseline.meaningfulDrag,
            modifiersPresent: true,
            postcondition: baseline.postcondition
        )))
        for postcondition in [FinderTrashPostcondition.stillPresent, .inaccessible] {
            XCTAssertNil(detector.detect(.init(
                schemaVersion: baseline.schemaVersion,
                itemEligibility: baseline.itemEligibility,
                releasedOnDockTrash: baseline.releasedOnDockTrash,
                meaningfulDrag: baseline.meaningfulDrag,
                modifiersPresent: baseline.modifiersPresent,
                postcondition: postcondition
            )), "unexpected event for \(postcondition)")
        }
    }

    func testCapturedSanitizedTraceReplaysThroughProductionDetector() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/finder-trash/captured-sanitized-trace.json")
        let data = try Data(contentsOf: fixtureURL)
        let trace = try JSONDecoder().decode(DragDropTrace.self, from: data)
        XCTAssertEqual(detector.detect(trace)?.actionTitle, "Move to Trash")

        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["name", "path", "url", "title", "description", "identifier", "coordinate", "pid", "token", "fileid", "contents"] {
            XCTAssertFalse(text.contains(forbidden), "sanitized trace leaked forbidden field: \(forbidden)")
        }
    }

    func testEveryModifierAndUnknownFlagSuppressesAtTheProductionCaptureBoundary() {
        for flag in [CGEventFlags.maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
                     .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn] {
            XCTAssertTrue(DragDropActionDetector.hasDisallowedModifiers(flag))
        }
        XCTAssertTrue(DragDropActionDetector.hasDisallowedModifiers(CGEventFlags(rawValue: 1 << 40)))
        XCTAssertFalse(DragDropActionDetector.hasDisallowedModifiers([]))
        XCTAssertFalse(DragDropActionDetector.hasDisallowedModifiers(.maskNonCoalesced))
    }

    func testAttachedStorageIsRejectedEvenWhenItIsLocalAndWritable() {
        let internalItem = supportedItemFacts()
        XCTAssertEqual(DragDropActionDetector.eligibility(for: internalItem), .supportedRegularItem)

        let external = supportedItemFacts(volumeIsInternal: false)
        XCTAssertEqual(DragDropActionDetector.eligibility(for: external), .externalOrNetwork)
        let removable = supportedItemFacts(volumeIsRemovable: true)
        XCTAssertEqual(DragDropActionDetector.eligibility(for: removable), .externalOrNetwork)
        let ejectable = supportedItemFacts(volumeIsEjectable: true)
        XCTAssertEqual(DragDropActionDetector.eligibility(for: ejectable), .externalOrNetwork)
        let unknownInternal = supportedItemFacts(volumeIsInternal: nil)
        XCTAssertEqual(DragDropActionDetector.eligibility(for: unknownInternal), .externalOrNetwork)
    }

    private func supportedItemFacts(
        volumeIsInternal: Bool? = true,
        volumeIsRemovable: Bool? = false,
        volumeIsEjectable: Bool? = false
    ) -> FinderItemFacts {
        FinderItemFacts(
            isFileURL: true,
            isRegularFile: true,
            isDirectory: false,
            isSymbolicLink: false,
            isAliasFile: false,
            isVolume: false,
            isWritable: true,
            volumeIsLocal: true,
            volumeIsInternal: volumeIsInternal,
            volumeIsRemovable: volumeIsRemovable,
            volumeIsEjectable: volumeIsEjectable,
            volumeIsReadOnly: false,
            isUserImmutable: false,
            isSystemImmutable: false
        )
    }
}
