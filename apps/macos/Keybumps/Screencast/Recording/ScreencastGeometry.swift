import CoreGraphics
import CoreMedia
import Foundation

/// What part of a display a stream reads, and the size of the frames it delivers.
///
/// Adapted from Shotnix's `RecordingEngine.captureGeometry` (MIT, see LICENSE.shotnix): whole
/// physical pixels, even-sized (the encoders need even dimensions), and a captured region exactly
/// that size, so nothing is resampled and no edge is left unfilled. A region larger than the
/// writer takes (`ScreencastMovieWriter.maximumPixels` a side) is scaled down to fit, its shape
/// kept.
struct ScreencastCaptureGeometry: Equatable, Sendable {
    /// In the display's points, origin at its top-left: ScreenCaptureKit's `sourceRect`.
    let sourceRect: CGRect
    /// The frames' size, which the file is written at.
    let pixelWidth: Int
    let pixelHeight: Int

    /// The most pixels a side a display can have here; a display reporting more isn't a real one.
    static let pixelLimit = 1 << 20

    /// The whole display, or nil when its size isn't a usable one.
    static func display(size: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry? {
        area(CGRect(origin: .zero, size: size), displaySize: size, scale: scale)
    }

    /// `rect` (display points, top-left origin), clamped to the display and snapped to its pixels.
    /// Nil, rather than another part of the screen, when the display's size isn't finite, is under
    /// a point, or is more than `pixelLimit` pixels a side, or when `rect` isn't finite or doesn't
    /// meet the display.
    static func area(_ rect: CGRect, displaySize: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry? {
        let scale = scale.isFinite ? min(max(scale, 1), 8) : 1
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width >= 1, displaySize.height >= 1,
              displaySize.width * scale <= CGFloat(pixelLimit), displaySize.height * scale <= CGFloat(pixelLimit),
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        let bounds = CGRect(origin: .zero, size: displaySize)
        let region = rect.standardized.intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return nil }
        let maxPixelWidth = max(2, pixels(displaySize.width * scale) & ~1)
        let maxPixelHeight = max(2, pixels(displaySize.height * scale) & ~1)
        let sourcePixelWidth = min(evenCeil(pixels(ceil(region.width * scale - 0.0001))), maxPixelWidth)
        let sourcePixelHeight = min(evenCeil(pixels(ceil(region.height * scale - 0.0001))), maxPixelHeight)
        let width = CGFloat(sourcePixelWidth) / scale
        let height = CGFloat(sourcePixelHeight) / scale
        var x = floor(region.minX * scale + 0.0001) / scale
        var y = floor(region.minY * scale + 0.0001) / scale
        // Rounding up to even can reach past the edge: step back in.
        x = max(min(x, displaySize.width - width), 0)
        y = max(min(y, displaySize.height - height), 0)
        return ScreencastCaptureGeometry(
            sourceRect: CGRect(x: x, y: y, width: width, height: height),
            pixelWidth: fitted(sourcePixelWidth, longest: max(sourcePixelWidth, sourcePixelHeight)),
            pixelHeight: fitted(sourcePixelHeight, longest: max(sourcePixelWidth, sourcePixelHeight))
        )
    }

    /// One side of a frame larger than the writer takes, scaled with its longest side down to the
    /// writer's limit and kept even; ScreenCaptureKit scales the region into it, its shape kept.
    /// Whole numbers: both sides are at most `pixelLimit`, so the product can't overflow.
    private static func fitted(_ side: Int, longest: Int) -> Int {
        let cap = ScreencastMovieWriter.maximumPixels
        guard longest > cap else { return side }
        return max(2, (side * cap / longest) & ~1)
    }

    /// A window, from its frame and its display's frame (both in the global top-left space
    /// `SCWindow.frame` and `SCDisplay.frame` share). The window can reach past the display's
    /// edge, so only the part on it is read. Nil when no part of it is on the display, or a frame
    /// isn't a usable one.
    static func window(frame: CGRect, displayFrame: CGRect, scale: CGFloat) -> ScreencastCaptureGeometry? {
        area(
            frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY),
            displaySize: displayFrame.size,
            scale: scale
        )
    }

    private static func evenCeil(_ value: Int) -> Int {
        max(2, value + (value & 1))
    }

    /// Whole pixels, at most `pixelLimit`.
    private static func pixels(_ value: CGFloat) -> Int {
        ScreencastNumbers.int(Double(value), in: 0...pixelLimit, fallback: 2)
    }
}

/// Number conversions for values that come from the real system (ScreenCaptureKit, AVFoundation,
/// the window server) or from a caller, which unit tests can't feed every shape of: none of them
/// can trap. Swift's `Int(_:)` and its kin crash on NaN, infinity, or a value that doesn't fit.
enum ScreencastNumbers {
    /// Frames a second: 1 to 120, whatever's asked.
    static func framesPerSecond(_ value: Int) -> Int {
        min(max(value, 1), 120)
    }

    /// `value` rounded down and clamped to `range`; `fallback` when it isn't a finite number.
    /// `Double(Int.max)` rounds up to 2^63, one past `Int.max`, so a bound can clamp to a value
    /// that doesn't fit: that's the bound itself.
    static func int(_ value: Double, in range: ClosedRange<Int>, fallback: Int) -> Int {
        guard value.isFinite else { return fallback }
        let clamped = min(max(value, Double(range.lowerBound)), Double(range.upperBound)).rounded(.down)
        guard let int = Int(exactly: clamped) else { return clamped < 0 ? range.lowerBound : range.upperBound }
        return min(max(int, range.lowerBound), range.upperBound)
    }

    /// A sample rate as a whole-number `CMTimeScale`, or nil when it isn't a usable one.
    static func timescale(forSampleRate rate: Double) -> CMTimeScale? {
        guard rate.isFinite, rate >= 1, let scale = CMTimeScale(exactly: rate.rounded()) else { return nil }
        return scale
    }

    /// A position on a `timescale` clock, or nil when it isn't a finite one that fits.
    static func timeValue(_ seconds: Double, timescale: CMTimeScale) -> CMTimeValue? {
        let ticks = (seconds * Double(timescale)).rounded()
        guard ticks.isFinite, let value = CMTimeValue(exactly: ticks) else { return nil }
        return value
    }

    /// Nanoseconds to sleep for `seconds`: 0 for anything negative or not a number, at most an hour.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        return UInt64(min(seconds, 3_600) * 1_000_000_000)
    }

    /// Window numbers as `CGWindowID`s: AppKit's are `Int`, and a window with no window-server
    /// window reports 0 or -1. Those, and any that doesn't fit, are left out and counted.
    static func windowIDs(_ windowNumbers: [Int]) -> (ids: Set<CGWindowID>, dropped: Int) {
        let ids = windowNumbers.compactMap { $0 > 0 ? CGWindowID(exactly: $0) : nil }
        return (Set(ids), windowNumbers.count - ids.count)
    }
}
