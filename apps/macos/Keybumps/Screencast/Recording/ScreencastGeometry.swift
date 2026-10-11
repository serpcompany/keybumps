import CoreGraphics
import CoreMedia
import Foundation

/// What part of a display a stream reads, and the size of the frames it delivers.
///
/// Adapted from Shotnix's `RecordingEngine.captureGeometry` (MIT, see LICENSE.shotnix): whole
/// physical pixels, even-sized (the encoders need even dimensions), and a captured region exactly
/// that size, so nothing is resampled and no edge is left unfilled.
struct ScreencastCaptureGeometry: Equatable, Sendable {
    /// In the display's points, origin at its top-left: ScreenCaptureKit's `sourceRect`.
    let sourceRect: CGRect
    /// The frames' size: the region's own pixels, unless `fitting(longestSide:)` scaled it down.
    let pixelWidth: Int
    let pixelHeight: Int

    /// The most pixels a side a display can have here; a display reporting more isn't a real one.
    static let pixelLimit = 1 << 20

    /// The whole display.
    static func display(size: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry {
        area(CGRect(origin: .zero, size: size), displaySize: size, scale: scale)
    }

    /// `rect` (display points, top-left origin), clamped to the display and snapped to its pixels.
    /// It never traps: a `rect` that isn't finite or doesn't meet the display reads the whole
    /// display, and a display whose size isn't usable reads 2 pixels at its corner. A recording,
    /// which mustn't read another part of the screen than was chosen, asks `usableArea` instead.
    static func area(_ rect: CGRect, displaySize: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry {
        usableArea(rect, displaySize: displaySize, scale: scale)
            ?? usableArea(CGRect(origin: .zero, size: displaySize), displaySize: displaySize, scale: scale)
            ?? ScreencastCaptureGeometry(sourceRect: CGRect(x: 0, y: 0, width: 2, height: 2), pixelWidth: 2, pixelHeight: 2)
    }

    /// A window, from its frame and its display's frame (both in the global top-left space
    /// `SCWindow.frame` and `SCDisplay.frame` share). The window can reach past the display's
    /// edge, so only the part on it is read.
    static func window(frame: CGRect, displayFrame: CGRect, scale: CGFloat) -> ScreencastCaptureGeometry {
        area(frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY), displaySize: displayFrame.size, scale: scale)
    }

    /// `display(size:scale:)`, or nil when the display's size isn't a usable one.
    static func usableDisplay(size: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry? {
        usableArea(CGRect(origin: .zero, size: size), displaySize: size, scale: scale)
    }

    /// `window(frame:displayFrame:scale:)`, or nil when no part of the window is on the display, or
    /// a frame isn't a usable one.
    static func usableWindow(frame: CGRect, displayFrame: CGRect, scale: CGFloat) -> ScreencastCaptureGeometry? {
        usableArea(frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY), displaySize: displayFrame.size, scale: scale)
    }

    /// `area(_:displaySize:scale:)`, or nil, rather than another part of the screen, when the
    /// display's size isn't finite, is under a point, or is more than `pixelLimit` pixels a side,
    /// or when `rect` isn't finite or doesn't meet the display.
    static func usableArea(_ rect: CGRect, displaySize: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry? {
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
        let pixelWidth = min(evenCeil(pixels(ceil(region.width * scale - 0.0001))), maxPixelWidth)
        let pixelHeight = min(evenCeil(pixels(ceil(region.height * scale - 0.0001))), maxPixelHeight)
        let width = CGFloat(pixelWidth) / scale
        let height = CGFloat(pixelHeight) / scale
        var x = floor(region.minX * scale + 0.0001) / scale
        var y = floor(region.minY * scale + 0.0001) / scale
        // Rounding up to even can reach past the edge: step back in.
        x = max(min(x, displaySize.width - width), 0)
        y = max(min(y, displaySize.height - height), 0)
        return ScreencastCaptureGeometry(
            sourceRect: CGRect(x: x, y: y, width: width, height: height),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    /// The same region in frames whose longest side is at most `longestSide` (at least 2): a
    /// larger one is scaled down, its shape kept and both sides even, and ScreenCaptureKit scales
    /// the region into it. The video writer's limit, applied only to recordings.
    func fitting(longestSide: Int) -> ScreencastCaptureGeometry {
        let cap = max(2, longestSide)
        let longest = max(pixelWidth, pixelHeight)
        guard longest > cap else { return self }
        // In `Double`, so no size can overflow; rounded down, then even.
        func side(_ value: Int) -> Int {
            let scaled = Double(value) * Double(cap) / Double(longest)
            return max(2, ScreencastNumbers.int(scaled, in: 0...cap, fallback: 2) & ~1)
        }
        return ScreencastCaptureGeometry(sourceRect: sourceRect, pixelWidth: side(pixelWidth), pixelHeight: side(pixelHeight))
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
