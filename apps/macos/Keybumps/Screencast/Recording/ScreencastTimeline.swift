import Foundation

// Adapted from Shotnix's `RecordingTimeline` and `RecordingAudioPlacement`
// (`Sources/ShotnixCore/Capture/RecordingWriterCore.swift`, MIT, see LICENSE.shotnix and the donor
// ledger): host-clock samples mapped to recording time with pauses cut out, and audio placed on a
// gap-free track.

/// Stretches of host time, in seconds: the closed ones, plus one still open. Pauses are kept this
/// way, and so are the times a sound was switched off, so a sample is judged by when it was
/// captured rather than when it reached the writer.
struct ScreencastHostIntervals: Equatable, Sendable {
    private(set) var closed: [Range<Double>] = []
    private(set) var openSince: Double?

    var isOpen: Bool { openSince != nil }

    /// Starts a stretch at `host`; does nothing while one is open.
    mutating func open(at host: Double) {
        if openSince == nil { openSince = host }
    }

    /// Ends the open stretch at `host`. An empty one leaves nothing behind.
    mutating func close(at host: Double) {
        guard let start = openSince else { return }
        openSince = nil
        if host > start { closed.append(start..<host) }
    }

    func contains(_ host: Double) -> Bool {
        if let openSince, host >= openSince { return true }
        return closed.contains { $0.contains(host) }
    }

    /// Seconds of every stretch, the open one included, between `start` and `end`.
    func total(from start: Double, to end: Double) -> Double {
        let closedTotal = closed.reduce(0) { sum, range in
            sum + max(0, min(range.upperBound, end) - max(range.lowerBound, start))
        }
        guard let openSince else { return closedTotal }
        return closedTotal + max(0, end - max(openSince, start))
    }
}

/// Maps host-clock times (ScreenCaptureKit stamps every video and audio sample with the host
/// clock) to recording time: 0 at the first video frame, with paused stretches cut out.
struct ScreencastTimeline: Equatable, Sendable {
    private(set) var origin: Double?
    private(set) var pauses = ScreencastHostIntervals()

    var hasStarted: Bool { origin != nil }
    var isPaused: Bool { pauses.isOpen }

    /// Sets t=0, once.
    mutating func start(at host: Double) {
        if origin == nil { origin = host }
    }

    mutating func pause(at host: Double) {
        pauses.open(at: host)
    }

    mutating func resume(at host: Double) {
        pauses.close(at: host)
    }

    func isPaused(at host: Double) -> Bool {
        pauses.contains(host)
    }

    /// Where a sample taken at `host` lands in the recording: nil while paused or before t=0 is
    /// known, negative before t=0.
    func time(at host: Double) -> Double? {
        guard let origin, !isPaused(at: host) else { return nil }
        return host - origin - pauses.total(from: origin, to: host)
    }

    /// Recorded seconds by `host`, frozen while paused.
    func duration(at host: Double) -> Double {
        guard let origin else { return 0 }
        return max(0, host - origin - pauses.total(from: origin, to: host))
    }
}

/// Where one audio buffer goes on a gap-free track. AVAssetWriter plays audio buffers back to back
/// and ignores gaps in their timestamps, so a sound that starts late, drops out, or was captured
/// before the first frame would slide everything after it out of sync with the picture.
struct ScreencastAudioPlacement: Equatable, Sendable {
    /// Seconds of silence to write before the buffer.
    var silence: Double
    /// Seconds to cut from the buffer's start, where it overlaps what's already written.
    var trim: Double

    /// Drift under this is left alone (lip sync tolerates far more); anything bigger is filled
    /// with silence or trimmed.
    static let tolerance = 0.03

    /// Nil when the buffer lies entirely before what's written, or before t=0.
    static func place(start: Double, duration: Double, written: Double) -> ScreencastAudioPlacement? {
        guard start + duration > written + 0.0005 else { return nil }
        // The first buffer lands exactly on t=0: a late start is padded with silence and an early
        // one trimmed, so every track starts with the picture.
        let tolerance = written > 0 ? Self.tolerance : 0.0005
        let gap = start - written
        if gap > tolerance { return ScreencastAudioPlacement(silence: gap, trim: 0) }
        if gap < -tolerance { return ScreencastAudioPlacement(silence: 0, trim: -gap) }
        return ScreencastAudioPlacement(silence: 0, trim: 0)
    }
}
