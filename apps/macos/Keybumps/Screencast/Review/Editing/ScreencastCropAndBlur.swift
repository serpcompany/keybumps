import CoreGraphics
import Foundation

/// Crop's shapes in the bar (#517, decision 3), after Shotnix's `VideoCropAspect` (MIT, see
/// LICENSE.shotnix): free, or a width-to-height ratio in the video's pixels.
enum ScreencastCropAspect: String, CaseIterable, Identifiable, Sendable {
    case free
    case widescreen
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .widescreen: "16:9"
        case .square: "1:1"
        }
    }

    /// Width over height, in pixels; nil for Free.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .widescreen: 16.0 / 9.0
        case .square: 1
        }
    }
}

/// A handle on a rectangle over the video, a corner or the middle of a side, after Shotnix's
/// `VideoCropOverlay.Handle`.
enum ScreencastRectHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Where it sits on `rect`, from its top left.
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX,
            y: movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        )
    }
}

/// Rectangles over a video's frame, in fractions of its width and height from its top left, as
/// `ScreencastDisplayEdits` keeps them: a crop or a blur dragged, resized, or drawn, always inside
/// the frame. After Shotnix's `VideoCropOverlay` and `applyCropAspect`.
enum ScreencastFrameRect {
    /// The whole frame.
    static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// A crop's shortest side, so it can still be grabbed.
    static let minimumCropSide: CGFloat = 0.05
    /// A blur's shortest side once drawn.
    static let minimumBlurSide: CGFloat = 0.01

    /// The largest crop of `aspect` inside a `pixelSize` frame, centered where `current` is and
    /// moved inside the frame; `current` for Free.
    static func crop(_ aspect: ScreencastCropAspect, around current: CGRect, pixelSize: CGSize) -> CGRect {
        guard let ratio = aspect.ratio, pixelSize.width > 0, pixelSize.height > 0 else { return current }
        let frameRatio = pixelSize.width / pixelSize.height
        let size = ratio < frameRatio
            ? CGSize(width: ratio / frameRatio, height: 1)
            : CGSize(width: 1, height: frameRatio / ratio)
        let centered = CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2, width: size.width, height: size.height)
        return moved(centered, by: .zero)
    }

    /// `rect` moved by `delta`, kept inside the frame.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        let width = min(rect.width, 1)
        let height = min(rect.height, 1)
        return CGRect(
            x: min(max(rect.minX + delta.width, 0), 1 - width),
            y: min(max(rect.minY + delta.height, 0), 1 - height),
            width: width, height: height
        )
    }

    /// The part of `rect` inside the frame, `rect` itself when it's all inside; nil when none is.
    static func inside(_ rect: CGRect) -> CGRect? {
        let rect = rect.standardized
        if whole.contains(rect), rect.width > 0, rect.height > 0 { return rect }
        let inside = rect.intersection(whole)
        return inside.isNull || inside.width <= 0 || inside.height <= 0 ? nil : inside
    }

    /// The rectangle from `start` to `end`, inside the frame.
    static func spanning(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(whole)
    }

    /// `rect` with `handle` dragged by `delta`, inside the frame and no side shorter than
    /// `minimumSide`. With a `ratio` (width over height in a `pixelSize` frame's pixels), it keeps
    /// that shape, anchored at the opposite corner, or, for a side's handle, the opposite side's
    /// middle.
    static func resized(
        _ rect: CGRect,
        handle: ScreencastRectHandle,
        by delta: CGSize,
        minimumSide: CGFloat,
        ratio: CGFloat? = nil,
        pixelSize: CGSize = CGSize(width: 1, height: 1)
    ) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if handle.movesLeft { minX = min(max(minX + delta.width, 0), maxX - minimumSide) }
        if handle.movesRight { maxX = max(min(maxX + delta.width, 1), minX + minimumSide) }
        if handle.movesTop { minY = min(max(minY + delta.height, 0), maxY - minimumSide) }
        if handle.movesBottom { maxY = max(min(maxY + delta.height, 1), minY + minimumSide) }
        let free = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio, ratio > 0, pixelSize.width > 0, pixelSize.height > 0 else { return free }
        return locked(free, from: rect, ratio: ratio, handle: handle, minimumSide: minimumSide, pixelSize: pixelSize)
    }

    /// `rect` reshaped to `ratio` around `handle`'s anchor in `original`, as large as the drag asks
    /// and the frame allows.
    private static func locked(
        _ rect: CGRect, from original: CGRect, ratio: CGFloat, handle: ScreencastRectHandle, minimumSide: CGFloat,
        pixelSize: CGSize
    ) -> CGRect {
        // The height, in fractions of the frame's, of a crop one frame-width wide in this shape.
        let factor = pixelSize.width / pixelSize.height / ratio
        let horizontal = handle.movesLeft || handle.movesRight
        let vertical = handle.movesTop || handle.movesBottom
        // The anchor, and the room from it to the frame's edges the drag can grow into.
        let anchorX = handle.movesLeft ? original.maxX : handle.movesRight ? original.minX : original.midX
        let anchorY = handle.movesTop ? original.maxY : handle.movesBottom ? original.minY : original.midY
        let roomX = handle.movesLeft ? anchorX : handle.movesRight ? 1 - anchorX : 2 * min(anchorX, 1 - anchorX)
        let roomY = handle.movesTop ? anchorY : handle.movesBottom ? 1 - anchorY : 2 * min(anchorY, 1 - anchorY)
        var width = horizontal ? rect.width : rect.height / factor
        var height = width * factor
        if vertical && horizontal {
            // A corner follows whichever side the drag pulled further.
            let byHeight = rect.height / factor
            if byHeight > width {
                width = byHeight
                height = rect.height
            }
        }
        let smallest = max(minimumSide, minimumSide / factor)
        if width < smallest {
            width = smallest
            height = width * factor
        }
        if width > roomX {
            width = roomX
            height = width * factor
        }
        if height > roomY {
            height = roomY
            width = height / factor
        }
        let x = handle.movesLeft ? anchorX - width : handle.movesRight ? anchorX : anchorX - width / 2
        let y = handle.movesTop ? anchorY - height : handle.movesBottom ? anchorY : anchorY - height / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `rect`'s shape, width over height, in a `pixelSize` frame's pixels.
    static func ratio(of rect: CGRect, pixelSize: CGSize) -> CGFloat? {
        let height = rect.height * pixelSize.height
        return height > 0 ? rect.width * pixelSize.width / height : nil
    }
}

/// Which end of a time range a drag moves.
enum ScreencastTimeEdge {
    case start
    case end
}

/// Crop and Blur's edits (#517), each on one display's crop or blurs.
extension ScreencastRecordingEdits {
    /// The shortest a blur can show.
    static let minimumBlurLength: Double = 0.1

    /// An id no blur on any display has.
    var nextBlurID: Int { (displays.flatMap(\.blurs).map(\.id).max() ?? 0) + 1 }

    /// `display`'s crop: nil, or the whole frame, keeps all of it. Its shape stays as it was unless
    /// `aspect` is given, and is Free again once the crop is reset (nil). Returns whether it's a
    /// display's.
    @discardableResult
    mutating func setCrop(_ rect: CGRect?, aspect: ScreencastCropAspect? = nil, display: Int) -> Bool {
        guard displays.indices.contains(display) else { return false }
        let inside = rect.flatMap(ScreencastFrameRect.inside)
        let isWhole = inside.map { $0.insetBy(dx: -0.0001, dy: -0.0001).contains(ScreencastFrameRect.whole) } ?? true
        displays[display].crop = isWhole ? nil : inside
        if let aspect = aspect ?? (rect == nil ? .free : nil) { displays[display].cropAspect = aspect }
        return true
    }

    /// The blur `id` on `display`, if it's there.
    func blur(_ id: Int, display: Int) -> ScreencastBlur? {
        guard displays.indices.contains(display) else { return nil }
        return displays[display].blurs.first { $0.id == id }
    }

    /// Adds a blur over `rect` on `display`, showing for the whole recording, the safe choice.
    /// Returns its id, or nil when `rect` has nothing of the frame.
    @discardableResult
    mutating func addBlur(_ rect: CGRect, strength: ScreencastBlurStrength, display: Int) -> Int? {
        guard displays.indices.contains(display), let inside = ScreencastFrameRect.inside(rect) else { return nil }
        let id = nextBlurID
        displays[display].blurs.append(ScreencastBlur(id: id, rect: inside, strength: strength, time: whole))
        return id
    }

    /// Moves or resizes the blur `id` on `display` to `rect`, inside the frame.
    @discardableResult
    mutating func setBlurRect(_ id: Int, display: Int, to rect: CGRect) -> Bool {
        guard let inside = ScreencastFrameRect.inside(rect) else { return false }
        return changeBlur(id, display: display) { $0.rect = inside }
    }

    /// Moves `edge` of when the blur `id` on `display` shows to `time`, inside the recording and
    /// at least `minimumBlurLength` from its other end.
    @discardableResult
    mutating func setBlurTime(_ id: Int, display: Int, edge: ScreencastTimeEdge, to time: Double) -> Bool {
        let duration = duration
        let length = min(Self.minimumBlurLength, duration)
        return changeBlur(id, display: display) { blur in
            switch edge {
            case .start: blur.time = ScreencastTimeRange(start: min(max(time, 0), blur.time.end - length), end: blur.time.end)
            case .end: blur.time = ScreencastTimeRange(start: blur.time.start, end: max(min(time, duration), blur.time.start + length))
            }
        }
    }

    @discardableResult
    mutating func setBlurStrength(_ id: Int, display: Int, to strength: ScreencastBlurStrength) -> Bool {
        changeBlur(id, display: display) { $0.strength = strength }
    }

    /// Takes the blur `id` off `display`. Returns whether it was there.
    @discardableResult
    mutating func removeBlur(_ id: Int, display: Int) -> Bool {
        guard displays.indices.contains(display), let index = displays[display].blurs.firstIndex(where: { $0.id == id }) else { return false }
        displays[display].blurs.remove(at: index)
        return true
    }

    private mutating func changeBlur(_ id: Int, display: Int, _ change: (inout ScreencastBlur) -> Void) -> Bool {
        guard displays.indices.contains(display), let index = displays[display].blurs.firstIndex(where: { $0.id == id }) else { return false }
        change(&displays[display].blurs[index])
        return true
    }
}

/// Where the shown part of a display's frame sits in the player (#517): fitted to the player's
/// area as `AVPlayerView` fits it (`resizeAspect`), and the way between the player's points and
/// the frame's fractions, for drawing a crop or blurs over the video.
struct ScreencastVideoOverlayGeometry: Equatable {
    /// The player's area, in points from its top left.
    let area: CGSize
    /// The part of the frame the player shows, in fractions: all of it, or the crop.
    let shown: CGRect
    /// The frame's size in pixels.
    let pixelSize: CGSize

    /// Where the video is drawn in the player.
    var videoRect: CGRect {
        let width = shown.width * pixelSize.width
        let height = shown.height * pixelSize.height
        guard width > 0, height > 0, area.width > 0, area.height > 0 else { return CGRect(origin: .zero, size: area) }
        let scale = min(area.width / width, area.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
    }

    func viewPoint(_ point: CGPoint) -> CGPoint {
        let video = videoRect
        return CGPoint(
            x: video.minX + (point.x - shown.minX) / max(shown.width, .ulpOfOne) * video.width,
            y: video.minY + (point.y - shown.minY) / max(shown.height, .ulpOfOne) * video.height
        )
    }

    /// The frame's point under `point` in the player, inside the frame.
    func framePoint(_ point: CGPoint) -> CGPoint {
        let video = videoRect
        let x = shown.minX + (point.x - video.minX) / max(video.width, 1) * shown.width
        let y = shown.minY + (point.y - video.minY) / max(video.height, 1) * shown.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    func viewRect(_ rect: CGRect) -> CGRect {
        let origin = viewPoint(rect.origin)
        let end = viewPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
    }

    /// A drag of `translation` points, in fractions of the frame.
    func frameDelta(_ translation: CGSize) -> CGSize {
        let video = videoRect
        return CGSize(
            width: translation.width / max(video.width, 1) * shown.width,
            height: translation.height / max(video.height, 1) * shown.height
        )
    }
}
