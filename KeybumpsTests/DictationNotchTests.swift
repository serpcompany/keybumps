import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

@Suite("Dictation notch indicator")
struct DictationNotchTests {
    @Test("Loudness maps -50 dBFS … 0 dBFS onto 0 … 1 and clamps outside it")
    func inputLevel() {
        #expect(DictationInputLevel.normalized(rms: 0) == 0)
        #expect(DictationInputLevel.normalized(rms: 1) == 1)
        #expect(DictationInputLevel.normalized(rms: 2) == 1)
        #expect(DictationInputLevel.normalized(rms: 0.000_01) == 0)
        #expect(abs(DictationInputLevel.normalized(rms: pow(10, -25.0 / 20)) - 0.5) < 0.001)
    }

    @Test("Recording stays notch height; a failure drops down and widens")
    func geometry() {
        let recording = DictationNotchGeometry(notchWidth: 200, notchHeight: 37, isFailure: false, finishKeysWidth: DictationNotchGeometry.keysWidth("⌥ Space"))
        let side = recording.wingWidth + DictationNotchGeometry.inset
        #expect(recording.shapeSize == CGSize(width: 200 + 2 * side, height: 37))
        let failed = DictationNotchGeometry(notchWidth: 200, notchHeight: 37, isFailure: true, finishKeysWidth: DictationNotchGeometry.keysWidth("⌥ Space"))
        #expect(failed.shapeSize.height == 77)
        #expect(failed.shapeSize.width >= 380)
        // The panel is always the failure size, so switching states never clips the shape.
        #expect(recording.panelSize == failed.panelSize)
        #expect(recording.panelSize.height >= failed.shapeSize.height + DictationNotchGeometry.margin)
        let noNotch = DictationNotchGeometry(notchWidth: 0, notchHeight: 28, isFailure: false, finishKeysWidth: 0)
        #expect(noNotch.shapeSize.width == 120 + 2 * (noNotch.wingWidth + DictationNotchGeometry.inset))
    }

    @Test("A long finish shortcut widens both sides instead of reaching under the camera")
    func longShortcutWidensSides() {
        let longKeys = DictationNotchGeometry.keysWidth("⌃⌥⇧⌘ Space")
        let long = DictationNotchGeometry(notchWidth: 200, notchHeight: 37, isFailure: false, finishKeysWidth: longKeys)
        // "Space" renders as a word, wider than a symbol key.
        #expect(DictationNotchGeometry.keysWidth("⌥ Space") > 2 * 16 + 2)
        #expect(long.wingWidth == 25 + 8 + longKeys)
        #expect(long.wingWidth > DictationNotchGeometry.minimumWingWidth)
        #expect(DictationNotchGeometry.keysWidth(nil) == 0)
    }
}

@MainActor
@Suite("Dictation notch panel")
struct DictationNotchPanelTests {
    @Test("Recording shows the notch view in a visible panel at the top of the screen, and idle hides it")
    func showsNotchView() throws {
        let indicator = DictationIndicatorController()
        defer { indicator.update(.idle) }
        indicator.update(.recording)
        let panel = try #require(indicator.panel)
        #expect(panel.contentView is NSHostingView<DictationNotchView>)
        #expect(panel.isVisible)
        if let screen = NSScreen.main {
            #expect(panel.frame.maxY == screen.frame.maxY)
        }
        indicator.update(.idle)
        #expect(!panel.isVisible)
    }
}

@MainActor
@Suite("Dictation keeps the notch to itself", .serialized)
struct DictationNotchSuppressionTests {
    @Test("While Dictation shows its state, other notch notices are dropped; idle lets them through")
    func dictationSuppressesNotices() {
        defer { PaletteHUD.shared.isSuppressed = false }
        let indicator = DictationIndicatorController()
        for phase: DictationPhase in [.recording, .transcribing, .inserting, .failed("Example")] {
            indicator.update(phase)
            #expect(PaletteHUD.shared.isSuppressed, "\(phase)")
        }
        indicator.update(.idle)
        #expect(!PaletteHUD.shared.isSuppressed)
    }

    @Test("A suppressed notice never appears, and suppression hides one already showing")
    func suppressedNoticeNeverAppears() {
        let notice = PaletteHUD()
        defer { notice.dismiss() }
        notice.show("Copied to Clipboard")
        #expect(visibleNotices() == 1)

        notice.isSuppressed = true
        #expect(visibleNotices() == 0)
        notice.show("Copied to Clipboard")
        notice.showCoach(NotchCoachPresentation(event: .sample))
        #expect(visibleNotices() == 0)
    }

    private func visibleNotices() -> Int {
        NSApp.windows.filter { $0.identifier?.rawValue == "paletteHUD" && $0.isVisible }.count
    }
}
