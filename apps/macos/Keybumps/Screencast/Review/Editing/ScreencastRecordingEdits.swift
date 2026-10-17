import CoreGraphics
import Foundation

/// A stretch of a recording, in seconds from its start.
struct ScreencastTimeRange: Equatable, Hashable, Sendable {
    var start: Double
    var end: Double

    init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    var duration: Double { end - start }

    func contains(_ time: Double) -> Bool { time >= start && time < end }

    func overlaps(_ other: ScreencastTimeRange) -> Bool { start < other.end && other.start < end }

    /// The part inside `other`, or nil when none is.
    func clamped(to other: ScreencastTimeRange) -> ScreencastTimeRange? {
        let start = max(start, other.start)
        let end = min(end, other.end)
        return end > start ? ScreencastTimeRange(start: start, end: end) : nil
    }
}

extension Array where Element == ScreencastTimeRange {
    /// Where `recordingTime` falls once these kept parts play one after another. A time outside them
    /// goes to where the next one starts, or to the end.
    func editedTime(forRecordingTime recordingTime: Double) -> Double {
        var elapsed = 0.0
        for range in self {
            if recordingTime < range.start { return elapsed }
            if recordingTime < range.end { return elapsed + recordingTime - range.start }
            elapsed += range.duration
        }
        return elapsed
    }

    /// The recording's time at `editedTime` into these kept parts played one after another; the last
    /// one's end past them, and nil when there are none.
    func recordingTime(forEditedTime editedTime: Double) -> Double? {
        var remaining = Swift.max(editedTime, 0)
        for range in self {
            if remaining < range.duration { return range.start + remaining }
            remaining -= range.duration
        }
        return last?.end
    }
}

/// What the person changed in the recording window (#517), until Save or Copy writes it into the
/// recording's files (`ScreencastEditExporter`).
///
/// Times are the recording's own, from its start, so a trim never moves a cut or a blur, and trimmed
/// and cut parts can be brought back. A trim and its cuts apply to every display, so the videos stay
/// in step; a crop and blurs belong to one display (`displays`). Times past a shorter display's end
/// (one whose stream stopped early) simply have nothing of it.
struct ScreencastRecordingEdits: Equatable, Sendable {
    /// The shortest the edited recording can be: a trim or a cut stops there.
    static let minimumLength: Double = 0.5

    /// The recording's length: its longest video's.
    let duration: Double
    /// The part kept; the ends outside it are trimmed.
    private(set) var trim: ScreencastTimeRange
    /// Parts cut out, in order, never overlapping or touching. A cut outside the trim stays, and
    /// counts again once the trim takes it back in.
    private(set) var cuts: [ScreencastTimeRange] = []
    /// Each display's crop and blurs, in display order.
    var displays: [ScreencastDisplayEdits]

    /// No edits: the whole recording, as it was recorded.
    init(duration: Double, displayCount: Int) {
        self.duration = max(duration, 0)
        trim = ScreencastTimeRange(start: 0, end: self.duration)
        displays = Array(repeating: ScreencastDisplayEdits(), count: max(displayCount, 1))
    }

    /// The whole recording.
    var whole: ScreencastTimeRange { ScreencastTimeRange(start: 0, end: duration) }

    /// Nothing to write: Save and Copy keep the files as they are.
    var isEmpty: Bool { !isTrimmed && displays.allSatisfy(\.isEmpty) }

    /// The trim or a cut changes what plays.
    var isTrimmed: Bool { trim != whole || cuts.contains { $0.overlaps(trim) } }

    /// The parts of the recording the edited one plays, in order.
    var keptRanges: [ScreencastTimeRange] {
        var kept: [ScreencastTimeRange] = []
        var start = trim.start
        for cut in cuts where cut.overlaps(trim) {
            if cut.start > start { kept.append(ScreencastTimeRange(start: start, end: cut.start)) }
            start = max(start, cut.end)
        }
        if trim.end > start { kept.append(ScreencastTimeRange(start: start, end: trim.end)) }
        return kept
    }

    /// The kept parts of a display's video `videoDuration` long.
    func keptRanges(within videoDuration: Double) -> [ScreencastTimeRange] {
        let video = ScreencastTimeRange(start: 0, end: max(videoDuration, 0))
        return keptRanges.compactMap { $0.clamped(to: video) }
    }

    /// How long the edited recording plays.
    var length: Double { keptRanges.reduce(0) { $0 + $1.duration } }

    /// Where `recordingTime` falls in the edited recording. A time trimmed or cut off goes to where
    /// the next kept part starts, or to the end.
    func editedTime(forRecordingTime recordingTime: Double) -> Double {
        keptRanges.editedTime(forRecordingTime: recordingTime)
    }

    /// The recording's time at `editedTime` into the edited recording.
    func recordingTime(forEditedTime editedTime: Double) -> Double {
        keptRanges.recordingTime(forEditedTime: editedTime) ?? trim.end
    }

    // MARK: Trim and cuts

    /// Trims to `start`...`end`, inside the recording, as long as the edited recording stays at least
    /// `minimumLength` long. Returns whether it did.
    @discardableResult
    mutating func setTrim(start: Double, end: Double) -> Bool {
        let range = ScreencastTimeRange(start: min(max(start, 0), duration), end: min(max(end, 0), duration))
        var trimmed = self
        trimmed.trim = range
        guard trimmed.length >= min(Self.minimumLength, duration) else { return false }
        trim = range
        return true
    }

    /// Cuts `range` out, joined with any cut it overlaps or touches, unless that would leave less
    /// than `minimumLength`. Returns whether it did.
    @discardableResult
    mutating func cut(_ range: ScreencastTimeRange) -> Bool {
        guard let range = range.clamped(to: whole), range.duration > 0 else { return false }
        var merged = range
        var others: [ScreencastTimeRange] = []
        for cut in cuts {
            if cut.start <= merged.end && merged.start <= cut.end {
                merged = ScreencastTimeRange(start: min(cut.start, merged.start), end: max(cut.end, merged.end))
            } else {
                others.append(cut)
            }
        }
        var cutting = self
        cutting.cuts = (others + [merged]).sorted { $0.start < $1.start }
        guard cutting.length >= min(Self.minimumLength, duration), cutting.keptRanges != keptRanges else { return false }
        cuts = cutting.cuts
        return true
    }

    /// Brings back the cut at `time`. Returns whether there was one.
    @discardableResult
    mutating func restoreCut(at time: Double) -> Bool {
        guard let index = cuts.firstIndex(where: { $0.contains(time) }) else { return false }
        cuts.remove(at: index)
        return true
    }

    /// The whole recording again: no trim and no cuts.
    mutating func resetTrim() {
        trim = whole
        cuts = []
    }
}

/// One display's crop and blurs.
struct ScreencastDisplayEdits: Equatable, Sendable {
    /// The part of the frame kept, in fractions of its width and height from its top left; nil keeps
    /// all of it.
    var crop: CGRect?
    /// In the order drawn; a later one draws over an earlier one.
    var blurs: [ScreencastBlur] = []

    var isEmpty: Bool { crop == nil && blurs.isEmpty }

    /// The crop in a `width` × `height` frame's pixels, from its top left: whole pixels, with an even
    /// width and height, as the encoder needs, inside the frame. The whole frame without a crop.
    func cropPixels(width: Int, height: Int) -> CGRect {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        guard let crop else { return frame }
        let scaled = CGRect(
            x: crop.minX * CGFloat(width), y: crop.minY * CGFloat(height),
            width: crop.width * CGFloat(width), height: crop.height * CGFloat(height)
        ).standardized
        let x = min(max(scaled.minX.rounded(), 0), CGFloat(width - 2))
        let y = min(max(scaled.minY.rounded(), 0), CGFloat(height - 2))
        let evenWidth = max(2, (min(scaled.width.rounded(), CGFloat(width) - x) / 2).rounded(.down) * 2)
        let evenHeight = max(2, (min(scaled.height.rounded(), CGFloat(height) - y) / 2).rounded(.down) * 2)
        return CGRect(x: x, y: y, width: evenWidth, height: evenHeight).intersection(frame)
    }
}

/// A blur over part of one display's video, for part of the recording: a mosaic, as the Screenshot
/// Editor's Blur draws (`ScreenshotAnnotationRenderer.mosaic`).
struct ScreencastBlur: Equatable, Sendable, Identifiable {
    let id: Int
    /// Where it covers, in fractions of the frame's width and height from its top left.
    var rect: CGRect
    var strength: ScreencastBlurStrength
    /// When it shows, in the recording's time. A new one covers the whole recording.
    var time: ScreencastTimeRange
}

/// How coarse a blur's mosaic is. Even Low hides text: its block is the Screenshot Editor's smallest.
enum ScreencastBlurStrength: String, CaseIterable, Sendable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// The mosaic's block in points: Medium is the Screenshot Editor's Blur, and Low its minimum.
    var blockPoints: CGFloat {
        switch self {
        case .low: ScreenshotAnnotationRenderer.minimumPixelateBlock
        case .medium: ScreenshotAnnotationRenderer.pixelateBlock
        case .high: 20
        }
    }

    /// The block in a recording's pixels. A video doesn't say how many pixels made a point on its
    /// display, so this takes a Retina display's two: on a 1x display, text gets bigger blocks than
    /// that, never smaller.
    var blockPixels: CGFloat { blockPoints * 2 }
}
