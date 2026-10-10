import CoreGraphics
import Foundation

/// What part of a display a stream reads, and the size of the frames it delivers.
///
/// Adapted from Shotnix's `RecordingEngine.captureGeometry` (MIT, see LICENSE.shotnix): whole
/// physical pixels, even-sized (the encoders need even dimensions), and a captured region exactly
/// that size, so nothing is resampled and no edge is left unfilled.
struct ScreencastCaptureGeometry: Equatable, Sendable {
    /// In the display's points, origin at its top-left: ScreenCaptureKit's `sourceRect`.
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    /// The whole display.
    static func display(size: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry {
        area(CGRect(origin: .zero, size: size), displaySize: size, scale: scale)
    }

    /// `rect` (display points, top-left origin), clamped to the display and snapped to its pixels.
    static func area(_ rect: CGRect, displaySize: CGSize, scale: CGFloat) -> ScreencastCaptureGeometry {
        let scale = max(scale, 1)
        let bounds = CGRect(origin: .zero, size: displaySize)
        let clipped = rect.standardized.intersection(bounds)
        let region = clipped.isNull || clipped.isEmpty ? bounds : clipped
        let maxPixelWidth = max(2, Int((displaySize.width * scale).rounded(.down)) & ~1)
        let maxPixelHeight = max(2, Int((displaySize.height * scale).rounded(.down)) & ~1)
        let pixelWidth = min(evenCeil(Int(ceil(region.width * scale - 0.0001))), maxPixelWidth)
        let pixelHeight = min(evenCeil(Int(ceil(region.height * scale - 0.0001))), maxPixelHeight)
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

    /// A window, from its frame and its display's frame (both in the global top-left space
    /// `SCWindow.frame` and `SCDisplay.frame` share). The window can reach past the display's
    /// edge, so only the part on it is read.
    static func window(frame: CGRect, displayFrame: CGRect, scale: CGFloat) -> ScreencastCaptureGeometry {
        area(
            frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY),
            displaySize: displayFrame.size,
            scale: scale
        )
    }

    private static func evenCeil(_ value: Int) -> Int {
        max(2, value + (value & 1))
    }
}
