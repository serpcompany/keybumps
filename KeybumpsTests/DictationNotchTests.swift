import Foundation
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
        let recording = DictationNotchGeometry(notchWidth: 200, notchHeight: 37, isFailure: false)
        #expect(recording.shapeSize == CGSize(width: 200 + 2 * DictationNotchGeometry.wingWidth, height: 37))
        let failed = DictationNotchGeometry(notchWidth: 200, notchHeight: 37, isFailure: true)
        #expect(failed.shapeSize.height == 77)
        #expect(failed.shapeSize.width >= 380)
        let noNotch = DictationNotchGeometry(notchWidth: 0, notchHeight: 28, isFailure: false)
        #expect(noNotch.shapeSize.width == 120 + 2 * DictationNotchGeometry.wingWidth)
        #expect(noNotch.panelSize.width == noNotch.shapeSize.width + 2 * DictationNotchGeometry.margin)
    }
}
