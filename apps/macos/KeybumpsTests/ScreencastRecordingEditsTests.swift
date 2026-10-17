import CoreImage
import Foundation
import Testing
@testable import Keybumps

/// A recording's edits in the recording window (#517), as values: the trim and cuts every display
/// shares, the time they map between the recording and the edited one, each display's crop in whole
/// even pixels, and what a display's crop and blurs do to a made-up frame.
@Suite("ScreenGrabs: a recording's edits")
struct ScreencastRecordingEditsTests {
    private func edits(_ duration: Double = 10, displays: Int = 1) -> ScreencastRecordingEdits {
        ScreencastRecordingEdits(duration: duration, displayCount: displays)
    }

    private func range(_ start: Double, _ end: Double) -> ScreencastTimeRange {
        ScreencastTimeRange(start: start, end: end)
    }

    // MARK: Trim and cuts

    @Test("No edits keep the whole recording, for every display")
    func noEdits() {
        let edits = edits(displays: 2)
        #expect(edits.isEmpty)
        #expect(!edits.isTrimmed)
        #expect(edits.keptRanges == [range(0, 10)])
        let length = edits.length
        #expect(length == 10)
        #expect(edits.displays.count == 2)
    }

    @Test("A trim keeps the part between its handles")
    func trimKeepsTheMiddle() {
        var edits = edits()
        let trimmed = edits.setTrim(start: 2, end: 8)
        #expect(trimmed)
        #expect(edits.keptRanges == [range(2, 8)])
        #expect(edits.isTrimmed && !edits.isEmpty)
        let length = edits.length
        #expect(length == 6)
    }

    @Test("A trim stays inside the recording and never leaves less than half a second")
    func trimLimits() {
        var edits = edits()
        edits.setTrim(start: -3, end: 14)
        #expect(edits.trim == range(0, 10))
        let tooShort = edits.setTrim(start: 4, end: 4.2)
        #expect(!tooShort, "refused")
        #expect(edits.trim == range(0, 10), "unchanged")
        let justLongEnough = edits.setTrim(start: 4, end: 4.5)
        #expect(justLongEnough)
    }

    @Test("A cut takes a part out of the middle; the edited recording plays the rest in order")
    func cutTakesOutTheMiddle() {
        var edits = edits()
        let cut = edits.cut(range(4, 6))
        #expect(cut)
        #expect(edits.keptRanges == [range(0, 4), range(6, 10)])
        let length = edits.length
        #expect(length == 8)
    }

    @Test("Cuts that overlap or touch become one; a cut outside the trim, or all of it, is refused")
    func cutsJoinAndRefuse() {
        var edits = edits()
        edits.cut(range(2, 3))
        edits.cut(range(3, 4))
        edits.cut(range(3.5, 5))
        #expect(edits.cuts == [range(2, 5)])

        edits.setTrim(start: 1, end: 9)
        let outside = edits.cut(range(9.2, 9.8))
        #expect(!outside, "nothing there plays")
        let everything = edits.cut(range(0, 10))
        #expect(!everything, "it would leave nothing")
        #expect(edits.cuts == [range(2, 5)])
    }

    @Test("A trim never moves a cut: trimming over it hides it, and widening the trim brings it back")
    func trimKeepsCutsInPlace() {
        var edits = edits()
        edits.cut(range(1, 2))
        edits.setTrim(start: 3, end: 10)
        #expect(edits.keptRanges == [range(3, 10)])
        edits.setTrim(start: 0, end: 10)
        #expect(edits.keptRanges == [range(0, 1), range(2, 10)], "the cut is where it was")
    }

    @Test("Restore brings a cut back; Reset Trim brings back the whole recording")
    func restoreAndReset() {
        var edits = edits()
        edits.cut(range(4, 6))
        edits.cut(range(7, 8))
        let restored = edits.restoreCut(at: 5)
        #expect(restored)
        #expect(edits.cuts == [range(7, 8)])
        edits.setTrim(start: 1, end: 9)
        edits.resetTrim()
        #expect(edits.isEmpty)
        #expect(edits.keptRanges == [range(0, 10)])
    }

    @Test("Times map between the recording and the edited one; a trimmed or cut time goes to where it plays on")
    func timesMap() {
        var edits = edits()
        edits.setTrim(start: 1, end: 9)
        edits.cut(range(4, 6))
        let start = edits.editedTime(forRecordingTime: 1)
        #expect(start == 0)
        let beforeCut = edits.editedTime(forRecordingTime: 3)
        #expect(beforeCut == 2)
        let inCut = edits.editedTime(forRecordingTime: 5)
        #expect(inCut == 3, "the cut's start, where the edited recording goes on")
        let afterCut = edits.editedTime(forRecordingTime: 7)
        #expect(afterCut == 4)
        let trimmedOff = edits.editedTime(forRecordingTime: 9.5)
        #expect(trimmedOff == 6, "the end")

        let back = edits.recordingTime(forEditedTime: 4)
        #expect(back == 7)
        let past = edits.recordingTime(forEditedTime: 60)
        #expect(past == 9)
    }

    @Test("A shorter display keeps only what it has of the kept parts")
    func shorterDisplay() {
        var edits = edits(displays: 2)
        edits.setTrim(start: 2, end: 9)
        edits.cut(range(4, 5))
        let shorter = edits.keptRanges(within: 6)
        #expect(shorter == [range(2, 4), range(5, 6)])
    }

    // MARK: Crop

    @Test("A crop is whole, even pixels inside the frame; none is the whole frame")
    func cropPixels() {
        var display = ScreencastDisplayEdits()
        let whole = display.cropPixels(width: 3024, height: 1964)
        #expect(whole == CGRect(x: 0, y: 0, width: 3024, height: 1964))

        display.crop = CGRect(x: 0.1, y: 0.25, width: 0.333, height: 0.5)
        let crop = display.cropPixels(width: 1001, height: 601)
        #expect(crop.minX == 100 && crop.minY == 150)
        #expect(crop.width.truncatingRemainder(dividingBy: 2) == 0 && crop.height.truncatingRemainder(dividingBy: 2) == 0)
        #expect(crop.maxX <= 1001 && crop.maxY <= 601)

        display.crop = CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5)
        let corner = display.cropPixels(width: 100, height: 100)
        #expect(corner.maxX <= 100 && corner.maxY <= 100 && corner.width >= 2 && corner.height >= 2)
    }

    @Test("Blur strengths: Low is the Screenshot Editor's smallest block and Medium its Blur's, so text is hidden at every strength")
    func blurStrengths() {
        let points = ScreencastBlurStrength.allCases.map(\.blockPoints)
        #expect(points == [ScreenshotAnnotationRenderer.minimumPixelateBlock, ScreenshotAnnotationRenderer.pixelateBlock, 20])
        let titles = ScreencastBlurStrength.allCases.map(\.title)
        #expect(titles == ["Low", "Medium", "High"])
    }

    // MARK: Each frame

    @Test("A display's crop moves to the frame's origin, from the top left, in Core Image's coordinates")
    func frameEditorCrops() {
        var edits = edits(displays: 2)
        edits.displays[1].crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let first = ScreencastFrameEditor(edits: edits, display: 0, pixelWidth: 200, pixelHeight: 100)
        #expect(!first.changesFrames, "the crop is the second display's")
        let second = ScreencastFrameEditor(edits: edits, display: 1, pixelWidth: 200, pixelHeight: 100)
        #expect(second.changesFrames)
        #expect(second.crop == CGRect(x: 100, y: 50, width: 100, height: 50), "the top right, from the bottom left")
        #expect(second.renderSize == CGSize(width: 100, height: 50))
        let placing = ScreencastFrameEditor(edits: edits, display: 1, pixelWidth: 200, pixelHeight: 100, crops: false)
        #expect(placing.renderSize == CGSize(width: 200, height: 100), "the whole frame, for placing the crop")

        let frame = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let rendered = second.render(frame, atRecordingTime: 0)
        #expect(rendered.extent == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test("A blur is a mosaic over its rect, only while it shows")
    func frameEditorBlursInTime() throws {
        var edits = edits()
        edits.displays[0].blurs = [
            ScreencastBlur(id: 1, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), strength: .low, time: range(2, 4)),
        ]
        let editor = ScreencastFrameEditor(edits: edits, display: 0, pixelWidth: 160, pixelHeight: 80)
        let blur = try #require(editor.blurs.first)
        #expect(blur.rect == CGRect(x: 0, y: 0, width: 80, height: 80))
        #expect(blur.block == 20, "Low's 10 points at two pixels a point")

        let frame = Self.checkerboard(width: 160, height: 80)
        let before = Self.contrast(of: editor.render(frame, atRecordingTime: 1), in: CGRect(x: 0, y: 0, width: 80, height: 80))
        let during = Self.contrast(of: editor.render(frame, atRecordingTime: 3), in: CGRect(x: 0, y: 0, width: 80, height: 80))
        let beside = Self.contrast(of: editor.render(frame, atRecordingTime: 3), in: CGRect(x: 80, y: 0, width: 80, height: 80))
        let after = Self.contrast(of: editor.render(frame, atRecordingTime: 4), in: CGRect(x: 0, y: 0, width: 80, height: 80))
        #expect(before > 40, "sharp before it shows: \(before)")
        #expect(during < 10, "a mosaic while it shows: \(during)")
        #expect(beside > 40, "only its own rect: \(beside)")
        #expect(after > 40, "sharp once it's done: \(after)")
    }

    // MARK: The timeline

    @Test("The timeline puts the whole recording between its insets, and labels its ruler at a step that leaves room")
    func timelineGeometry() {
        let geometry = ScreencastTimelineGeometry(duration: 100, width: 1_032)
        let start = geometry.x(0)
        #expect(start == 16)
        let end = geometry.x(100)
        #expect(end == 1_016)
        let middle = geometry.time(atX: 516)
        #expect(middle == 50)
        let outside = geometry.time(atX: 2_000)
        #expect(outside == 100, "clamped to the recording")
        let step = geometry.labelStep()
        #expect(step == 10, "10 points a second: a label every 10 seconds, 100 points apart")
    }

    @Test("Times read m:ss, and h:mm:ss from an hour")
    func timeFormat() {
        let formatted = [0, 7.9, 87, 3_725].map(ScreencastEditTime.format)
        #expect(formatted == ["0:00", "0:07", "1:27", "1:02:05"])
    }

    // MARK: Helpers

    /// Black and white squares four pixels a side.
    static func checkerboard(width: Int, height: Int) -> CIImage {
        CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": 4,
            kCIInputCenterKey: CIVector(x: 0, y: 0)
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The mean difference between neighboring pixels' red, across `rect`: high for a checkerboard,
    /// near none for a mosaic.
    static func contrast(of image: CIImage, in rect: CGRect) -> Double {
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(
            image, toBitmap: &pixels, rowBytes: width * 4, bounds: rect, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        var total = 0.0
        var count = 0
        for row in 0..<height {
            for column in 1..<width {
                let here = Int(pixels[(row * width + column) * 4])
                let left = Int(pixels[(row * width + column - 1) * 4])
                total += Double(abs(here - left))
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }
}
