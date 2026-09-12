import CoreGraphics
import XCTest
@testable import SuperMac

final class StandardWindowControlTests: XCTestCase {
    private let detector = WindowControlActionDetector()

    func testMinimizeEmitsOnlyAfterTheSameWindowBecomesMinimized() {
        XCTAssertNil(detector.detect(trace(kind: .minimize), applicationName: "Finder", pointer: .zero))
        let minimized = trace(kind: .minimize, postMinimized: true)
        XCTAssertEqual(detector.detect(minimized, applicationName: "Finder", pointer: .zero)?.shortcut, "⌘M")
    }

    func testCloseWindowRequiresTheCapturedWindowToDisappear() {
        XCTAssertNil(detector.detect(trace(kind: .close), applicationName: "Google Chrome", pointer: .zero))
        let closed = trace(kind: .close, postPresent: false, shortcut: "⇧⌘W")
        let event = detector.detect(closed, applicationName: "Google Chrome", pointer: .zero)
        XCTAssertEqual(event?.actionTitle, "Close Window")
        XCTAssertEqual(event?.shortcut, "⇧⌘W")
    }

    func testChromeFullScreenRequiresStateToggleAndFrameTransition() {
        XCTAssertNil(detector.detect(trace(kind: .fullScreen), applicationName: "Google Chrome", pointer: .zero))
        let resizedOnly = trace(kind: .fullScreen, frameChanged: true)
        XCTAssertNil(detector.detect(resizedOnly, applicationName: "Google Chrome", pointer: .zero))

        let entered = trace(kind: .fullScreen, shortcut: "⌃⌘F", postFullScreen: true, frameChanged: true)
        XCTAssertEqual(detector.detect(entered, applicationName: "Google Chrome", pointer: .zero)?.actionTitle, "Enter Full Screen")
    }

    func testExitFullScreenRequiresTheInverseStateAndFrameTransition() {
        let exited = trace(kind: .fullScreen, shortcut: "⌃⌘F", preFullScreen: true, postFullScreen: false, frameChanged: true)
        XCTAssertEqual(detector.detect(exited, applicationName: "Google Chrome", pointer: .zero)?.actionTitle, "Exit Full Screen")
    }

    func testGenericAXFullScreenTransitionsStaySuppressedWithoutAnAppAdapter() {
        for profile in [WindowControlApplicationProfile.finder, .safari, .other] {
            let generic = trace(kind: .fullScreen, profile: profile, shortcut: "⌃⌘F", postFullScreen: true, frameChanged: true)
            XCTAssertNil(detector.detect(generic, applicationName: "Other app", pointer: .zero))
        }
    }

    func testMissingAmbiguousOrStaleLiveShortcutSuppresses() {
        XCTAssertNil(WindowControlActionDetector.uniqueShortcut(from: []))
        XCTAssertNil(WindowControlActionDetector.uniqueShortcut(from: ["⌘M", "⌘M"]))
        XCTAssertEqual(WindowControlActionDetector.uniqueShortcut(from: ["⌘M"]), "⌘M")
        XCTAssertTrue(WindowControlActionDetector.shortcutIsCurrent("⌘M", reread: "⌘M"))
        XCTAssertFalse(WindowControlActionDetector.shortcutIsCurrent("⌘M", reread: nil))
        XCTAssertFalse(WindowControlActionDetector.shortcutIsCurrent("⌘M", reread: "⌘W"))
    }

    func testModifiedAndUnknownFlagGesturesSuppressButBookkeepingBitDoesNot() {
        for flag in [CGEventFlags.maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
                     .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn] {
            XCTAssertTrue(WindowControlActionDetector.hasDisallowedModifiers(flag))
        }
        XCTAssertTrue(WindowControlActionDetector.hasDisallowedModifiers(CGEventFlags(rawValue: 1 << 40)))
        XCTAssertFalse(WindowControlActionDetector.hasDisallowedModifiers([]))
        XCTAssertFalse(WindowControlActionDetector.hasDisallowedModifiers(.maskNonCoalesced))
    }

    func testOnlyKnownNonModalStandardWindowsAreAccepted() {
        XCTAssertTrue(WindowControlActionDetector.acceptsWindow(isStandard: true, isModal: false))
        XCTAssertFalse(WindowControlActionDetector.acceptsWindow(isStandard: false, isModal: false))
        XCTAssertFalse(WindowControlActionDetector.acceptsWindow(isStandard: true, isModal: true))
        XCTAssertFalse(WindowControlActionDetector.acceptsWindow(isStandard: nil, isModal: false))
        XCTAssertFalse(WindowControlActionDetector.acceptsWindow(isStandard: true, isModal: nil))
    }

    func testCapturedSanitizedTraceReplaysThroughProductionDetector() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/window-controls/chrome-green-captured-sanitized-trace.json")
        let data = try Data(contentsOf: fixtureURL)
        let trace = try JSONDecoder().decode(WindowControlTrace.self, from: data)
        XCTAssertEqual(detector.detect(trace, applicationName: "Google Chrome", pointer: .zero)?.actionTitle, "Enter Full Screen")

        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["windowtitle", "documenttitle", "contents", "pointerx", "pointery", "pid", "token"] {
            XCTAssertFalse(text.contains(forbidden), "sanitized trace leaked forbidden field: \(forbidden)")
        }
    }

    private func trace(
        kind: StandardWindowControlKind,
        profile: WindowControlApplicationProfile = .googleChrome,
        postPresent: Bool = true,
        shortcut: String = "⌘M",
        preMinimized: Bool? = false,
        postMinimized: Bool? = false,
        preFullScreen: Bool? = false,
        postFullScreen: Bool? = false,
        frameChanged: Bool = false
    ) -> WindowControlTrace {
        WindowControlTrace(
            schemaVersion: WindowControlActionDetector.currentSchemaVersion,
            kind: kind,
            applicationProfile: profile,
            shortcut: shortcut,
            prePresent: true,
            postPresent: postPresent,
            preMinimized: preMinimized,
            postMinimized: postMinimized,
            preFullScreen: preFullScreen,
            postFullScreen: postFullScreen,
            frameChanged: frameChanged
        )
    }
}
