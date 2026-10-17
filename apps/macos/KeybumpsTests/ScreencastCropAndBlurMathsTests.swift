import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// Crop's and Blur's maths (#517): the crop's rectangle with each shape, dragged by each handle and
/// moved, always inside the frame; blurs added, moved, timed, given a strength, and deleted, each on
/// its own display; and the way between the player's points and the frame's fractions. Pure values:
/// no window, player, or file.
@Suite("ScreenGrabs: crop and blur maths")
struct ScreencastCropAndBlurMathsTests {
    /// A 14-inch MacBook Pro's screen, in pixels.
    let screen = CGSize(width: 3024, height: 1964)

    private func pixelRatio(_ rect: CGRect) -> CGFloat {
        ScreencastFrameRect.ratio(of: rect, pixelSize: screen) ?? 0
    }

    private func isInside(_ rect: CGRect) -> Bool {
        rect.minX >= -1e-9 && rect.minY >= -1e-9 && rect.maxX <= 1 + 1e-9 && rect.maxY <= 1 + 1e-9
    }

    // MARK: Crop

    @Test("Each shape's crop is the largest of that shape, centered where the crop was; Free keeps it")
    func cropShapes() {
        let whole = ScreencastFrameRect.whole
        let wide = ScreencastFrameRect.crop(.widescreen, around: whole, pixelSize: screen)
        #expect(abs(pixelRatio(wide) - 16.0 / 9.0) < 0.001)
        #expect(wide.width == 1, "16:9 is wider than the screen's 3:2 only in height")
        #expect(abs(wide.midY - 0.5) < 1e-9)

        let square = ScreencastFrameRect.crop(.square, around: whole, pixelSize: screen)
        #expect(abs(pixelRatio(square) - 1) < 0.001)
        #expect(square.height == 1)
        #expect(abs(square.midX - 0.5) < 1e-9)

        let corner = CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)
        let free = ScreencastFrameRect.crop(.free, around: corner, pixelSize: screen)
        #expect(free == corner)
        let moved = ScreencastFrameRect.crop(.square, around: corner, pixelSize: screen)
        #expect(isInside(moved), "moved inside the frame: \(moved)")
    }

    @Test("A shape's crop keeps its shape whichever handle is dragged, inside the frame, anchored opposite")
    func lockedResize() {
        for aspect in [ScreencastCropAspect.widescreen, .square] {
            let ratio = aspect.ratio ?? 1
            let start = ScreencastFrameRect.crop(aspect, around: ScreencastFrameRect.whole, pixelSize: screen)
            for handle in ScreencastRectHandle.allCases {
                for delta in [CGSize(width: -0.2, height: -0.15), CGSize(width: 0.3, height: 0.4)] {
                    let rect = ScreencastFrameRect.resized(
                        start, handle: handle, by: delta, minimumSide: ScreencastFrameRect.minimumCropSide,
                        ratio: ratio, pixelSize: screen
                    )
                    let shape = pixelRatio(rect)
                    #expect(abs(shape - ratio) < 0.001, "\(aspect) \(handle) \(delta): \(shape)")
                    #expect(isInside(rect), "\(aspect) \(handle) \(delta): \(rect)")
                }
            }
        }

        // Dragging the top-left corner in keeps the bottom-right corner where it was.
        let start = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5 * 3024 / 1964)
        let shrunk = ScreencastFrameRect.resized(
            start, handle: .topLeft, by: CGSize(width: 0.2, height: 0.2), minimumSide: 0.05, ratio: 1, pixelSize: screen
        )
        #expect(abs(shrunk.maxX - start.maxX) < 1e-9)
        #expect(abs(shrunk.maxY - start.maxY) < 1e-9)
    }

    @Test("Free resizes each side on its own, stops at the frame's edges, and never below the shortest side")
    func freeResize() {
        let start = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let wider = ScreencastFrameRect.resized(start, handle: .right, by: CGSize(width: 0.125, height: 0.3), minimumSide: 0.05)
        #expect(wider == CGRect(x: 0.25, y: 0.25, width: 0.625, height: 0.5))

        let past = ScreencastFrameRect.resized(start, handle: .bottomRight, by: CGSize(width: 2, height: 2), minimumSide: 0.05)
        #expect(past.maxX == 1 && past.maxY == 1)

        let crushed = ScreencastFrameRect.resized(start, handle: .topLeft, by: CGSize(width: 2, height: 2), minimumSide: 0.05)
        #expect(abs(crushed.width - 0.05) < 1e-9)
        #expect(abs(crushed.height - 0.05) < 1e-9)
    }

    @Test("A moved crop or blur stays inside the frame, its size kept; a drawn one is the rectangle between two points")
    func moveAndSpan() {
        let rect = CGRect(x: 0.5, y: 0.125, width: 0.25, height: 0.25)
        let moved = ScreencastFrameRect.moved(rect, by: CGSize(width: 0.5, height: -0.5))
        #expect(moved == CGRect(x: 0.75, y: 0, width: 0.25, height: 0.25))

        let span = ScreencastFrameRect.spanning(CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.25, y: 0.125))
        #expect(span == CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.375))
    }

    @Test("A crop of the whole frame is no crop; a crop is the display's own")
    func setCrop() {
        var edits = ScreencastRecordingEdits(duration: 10, displayCount: 2)
        edits.setCrop(CGRect(x: 0.25, y: 0, width: 0.5, height: 1), display: 1)
        #expect(edits.displays[0].crop == nil)
        #expect(edits.displays[1].crop == CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        edits.setCrop(ScreencastFrameRect.whole, display: 1)
        #expect(edits.isEmpty)
        let missing = edits.setCrop(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), display: 2)
        #expect(!missing)
    }

    @Test("The crop's size in pixels is the size Save writes: whole and even")
    func cropPixels() {
        var edits = ScreencastRecordingEdits(duration: 10, displayCount: 1)
        let square = ScreencastFrameRect.crop(.square, around: ScreencastFrameRect.whole, pixelSize: screen)
        edits.setCrop(square, display: 0)
        let pixels = edits.displays[0].cropPixels(width: 3024, height: 1964)
        #expect(pixels.size == CGSize(width: 1964, height: 1964))
        #expect(pixels.minX == 530)
    }

    // MARK: Blur

    @Test("A new blur covers the whole recording, on its display, with an id no other blur has")
    func addBlur() throws {
        var edits = ScreencastRecordingEdits(duration: 10, displayCount: 2)
        let addedFirst = edits.addBlur(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), strength: .high, display: 0)
        let first = try #require(addedFirst)
        let addedSecond = edits.addBlur(CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1), strength: .low, display: 1)
        let second = try #require(addedSecond)
        #expect(first != second)
        let blur = try #require(edits.blur(second, display: 1))
        #expect(blur.time == edits.whole)
        #expect(blur.strength == .low)
        #expect(edits.blur(second, display: 0) == nil, "each display has its own")

        let addedClipped = edits.addBlur(CGRect(x: 0.9, y: -0.1, width: 0.3, height: 0.2), strength: .high, display: 0)
        let clipped = try #require(addedClipped)
        let inside = try #require(edits.blur(clipped, display: 0)).rect
        #expect(abs(inside.maxX - 1) < 1e-9 && inside.minY == 0, "inside the frame: \(inside)")
        let outside = edits.addBlur(CGRect(x: 1.2, y: 0, width: 0.1, height: 0.1), strength: .high, display: 0)
        #expect(outside == nil)
    }

    @Test("A blur moves, resizes, takes a strength, and is deleted; its time stays inside the recording and at least a tenth of a second")
    func editBlur() throws {
        var edits = ScreencastRecordingEdits(duration: 10, displayCount: 1)
        let addedId = edits.addBlur(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), strength: .high, display: 0)
        let id = try #require(addedId)
        edits.setBlurRect(id, display: 0, to: CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3))
        edits.setBlurStrength(id, display: 0, to: .medium)
        edits.setBlurTime(id, display: 0, edge: .start, to: 2)
        edits.setBlurTime(id, display: 0, edge: .end, to: 6.5)
        var blur = try #require(edits.blur(id, display: 0))
        #expect(blur.rect == CGRect(x: 0.4, y: 0.4, width: 0.3, height: 0.3))
        #expect(blur.strength == .medium)
        #expect(blur.time == ScreencastTimeRange(start: 2, end: 6.5))

        edits.setBlurTime(id, display: 0, edge: .start, to: 9)
        edits.setBlurTime(id, display: 0, edge: .end, to: 20)
        blur = try #require(edits.blur(id, display: 0))
        #expect(abs(blur.time.start - 6.4) < 1e-9, "stops short of its end: \(blur.time)")
        #expect(blur.time.end == 10, "and at the recording's end")

        let removed = edits.removeBlur(id, display: 0)
        #expect(removed && edits.isEmpty)
        let again = edits.removeBlur(id, display: 0)
        #expect(!again)
    }

    // MARK: Over the player

    @Test("The video sits fitted in the player, and points go to the frame's fractions and back, with the crop shown or the whole frame")
    func overlayGeometry() {
        let whole = ScreencastVideoOverlayGeometry(area: CGSize(width: 1000, height: 500), shown: ScreencastFrameRect.whole, pixelSize: CGSize(width: 1600, height: 1000))
        #expect(whole.videoRect == CGRect(x: 100, y: 0, width: 800, height: 500), "pillarboxed")
        let middle = whole.framePoint(CGPoint(x: 500, y: 250))
        #expect(middle == CGPoint(x: 0.5, y: 0.5))
        let outside = whole.framePoint(CGPoint(x: 0, y: 600))
        #expect(outside == CGPoint(x: 0, y: 1), "inside the frame")

        let crop = CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let cropped = ScreencastVideoOverlayGeometry(area: CGSize(width: 1000, height: 500), shown: crop, pixelSize: CGSize(width: 1600, height: 1000))
        let topLeft = cropped.framePoint(CGPoint(x: 100, y: 0))
        #expect(topLeft == CGPoint(x: 0.5, y: 0.5), "the crop's corner is the video's")
        let back = cropped.viewRect(crop)
        #expect(back == cropped.videoRect)
        let delta = cropped.frameDelta(CGSize(width: 80, height: 50))
        #expect(delta == CGSize(width: 0.05, height: 0.05))
    }
}
