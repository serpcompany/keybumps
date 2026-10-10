import CoreMedia
import Foundation
import Testing
@testable import Keybumps

/// Made-up capture: frames at 30 a second and audio buffers at their natural cadence, each source
/// running over its own stretch of host time, handed to a writer core in the order they were
/// captured.
private struct CaptureFeed {
    var video: ClosedRange<Double>?
    var audio: [ScreencastAudioSource: ClosedRange<Double>] = [:]

    enum Event {
        case video(Double)
        case audio(ScreencastAudioSource, Double)

        var host: Double {
            switch self {
            case .video(let host), .audio(_, let host): host
            }
        }
    }

    func events(from start: Double, to end: Double) -> [Event] {
        var events: [Event] = []
        func stamps(_ range: ClosedRange<Double>, every step: Double) -> [Double] {
            Array((0...).lazy.map { range.lowerBound + Double($0) * step }
                .prefix { $0 <= range.upperBound }
                .filter { $0 >= start && $0 < end })
        }
        if let video {
            events += stamps(video, every: 1.0 / 30).map(Event.video)
        }
        for (source, range) in audio {
            events += stamps(range, every: ScreencastSamples.audioBufferSeconds).map { .audio(source, $0) }
        }
        return events.sorted { $0.host < $1.host }
    }

    /// Hands the core everything captured in [start, end).
    func run(_ core: ScreencastWriterCore, from start: Double, to end: Double) {
        for event in events(from: start, to: end) {
            switch event {
            case .video(let host):
                core.appendVideo(ScreencastSamples.video(at: host))
            case .audio(let source, let host):
                core.appendAudio(ScreencastSamples.audio(at: host, channels: source == .systemAudio ? 2 : 1), from: source)
            }
        }
    }
}

@Suite("Screencast: writing a file's samples")
struct ScreencastWriterCoreTests {
    private func makeCore(audio: [ScreencastAudioSource] = [.microphone, .systemAudio], onFailure: @escaping () -> Void = {}) -> (ScreencastWriterCore, RecordingSink) {
        let sink = RecordingSink(audio: audio)
        return (ScreencastWriterCore(sink: sink, framesPerSecond: 30, onFailure: onFailure), sink)
    }

    private func near(_ value: Double, _ expected: Double, within tolerance: Double = 0.03) -> Bool {
        abs(value - expected) <= tolerance
    }

    @Test("Every track starts with the picture: a late microphone is padded with silence, early system audio is trimmed")
    func tracksStartWithThePicture() throws {
        let (core, sink) = makeCore()
        let feed = CaptureFeed(video: 100...102, audio: [.microphone: 100.3...102, .systemAudio: 99.9...102])
        feed.run(core, from: 99, to: 102)
        let end = core.finish(at: 102)

        #expect(sink.sessionStarted)
        #expect(sink.video.first?.start == 0)
        #expect(near(end, 2))
        let mic = sink.audio(.microphone)
        let lead = try #require(mic.first)
        #expect(lead.start == 0 && lead.isSilent && near(lead.duration, 0.3, within: 0.001))
        #expect(near(sink.sound(.microphone, from: 0.3, to: 2), 1.7))
        let system = sink.audio(.systemAudio)
        #expect(system.first?.start == 0 && system.first?.isSilent == false, "trimmed to start on the first frame")
        #expect(near(core.writtenAudio(for: .systemAudio), 2) && near(core.writtenAudio(for: .microphone), 2))
    }

    @Test("A pause drops what's captured during it, and the sound stays in step with the picture after it")
    func pause() {
        let (core, sink) = makeCore()
        // Offset from the pause's edges, so no frame lands exactly on one.
        let feed = CaptureFeed(video: 100.01...106, audio: [.microphone: 100.005...106, .systemAudio: 100.005...106])
        feed.run(core, from: 100, to: 102)
        core.pause(at: 102)
        feed.run(core, from: 102, to: 104)
        core.resume(at: 104)
        feed.run(core, from: 104, to: 106)
        let end = core.finish(at: 106.01)

        #expect(near(end, 4), "two of the six seconds were paused")
        let times = sink.video.map(\.start)
        #expect(times == times.sorted() && Set(times).count == times.count)
        #expect(times.filter { $0 < 3.98 }.count == 120, "the 60 frames captured while paused are dropped")
        #expect(near(times[60], 2, within: 0.001), "the first frame after resuming follows the last before pausing")
        #expect(near(sink.sound(.microphone, from: 0, to: 4), 4, within: 0.05), "no silence where the pause was cut out")
        #expect(near(core.writtenAudio(for: .systemAudio), 4))
    }

    @Test("Paused before the first frame: the recording starts at the first frame after resuming")
    func pausedBeforeTheFirstFrame() {
        let (core, sink) = makeCore(audio: [])
        core.pause(at: 99)
        CaptureFeed(video: 100...101).run(core, from: 100, to: 101)
        #expect(sink.video.isEmpty && !sink.sessionStarted)
        core.resume(at: 101)
        CaptureFeed(video: 101.5...102).run(core, from: 101, to: 102)
        #expect(sink.video.first?.start == 0)
        #expect(near(core.videoDuration, 0.5, within: 0.05))
    }

    @Test("A sound switched off mid-recording keeps running and is written as silence until it's back on")
    func switchingASoundOff() {
        let (core, sink) = makeCore()
        let feed = CaptureFeed(video: 100...104, audio: [.microphone: 100...104, .systemAudio: 100...104])
        feed.run(core, from: 100, to: 101)
        core.setAudio(.microphone, on: false, at: 101)
        feed.run(core, from: 101, to: 102.5)
        core.setAudio(.microphone, on: true, at: 102.5)
        feed.run(core, from: 102.5, to: 104)
        core.finish(at: 104)

        #expect(sink.sound(.microphone, from: 1.03, to: 2.47) == 0)
        #expect(near(sink.sound(.microphone, from: 0, to: 1), 1))
        #expect(near(sink.sound(.microphone, from: 2.5, to: 4), 1.5))
        #expect(near(core.writtenAudio(for: .microphone), 4), "the track never falls behind the picture")
        #expect(near(sink.sound(.systemAudio, from: 0, to: 4), 4, within: 0.05), "the other sound is untouched")
    }

    @Test("A sound that goes quiet is padded as the picture moves on, then to the end")
    func quietSourceIsPadded() {
        let (core, sink) = makeCore(audio: [.systemAudio])
        CaptureFeed(video: 100...104, audio: [.systemAudio: 100...101]).run(core, from: 100, to: 104)
        #expect(core.writtenAudio(for: .systemAudio) > 2.4, "kept within about a second of the picture")
        core.finish(at: 104)
        #expect(near(core.writtenAudio(for: .systemAudio), 4))
        #expect(near(sink.sound(.systemAudio, from: 0, to: 4), 1, within: 0.05))
    }

    @Test("A track that never heard anything is silence for the whole recording")
    func silentTrack() {
        let (core, sink) = makeCore(audio: [.microphone])
        CaptureFeed(video: 100...103).run(core, from: 100, to: 103)
        core.finish(at: 103)
        #expect(near(core.writtenAudio(for: .microphone), 3))
        #expect(sink.audio(.microphone).allSatisfy { $0.isSilent })
    }

    @Test("Stopping repeats the last frame, so a still screen's video runs to the stop")
    func lastFrameRunsToTheStop() {
        let (core, sink) = makeCore(audio: [])
        CaptureFeed(video: 100...100.5).run(core, from: 100, to: 101)
        let end = core.finish(at: 103)
        #expect(near(end, 3, within: 0.001))
        #expect(sink.video.last.map { near($0.start, 3, within: 0.001) } == true)
    }

    @Test("Stopping while paused ends the file where the pause began")
    func stoppedWhilePaused() {
        let (core, _) = makeCore(audio: [])
        CaptureFeed(video: 100...101.5).run(core, from: 100, to: 102)
        core.pause(at: 102)
        #expect(near(core.finish(at: 110), 2, within: 0.001))
    }

    @Test("A failed writer is noticed once and takes nothing more")
    func failedWriter() {
        var failures = 0
        let (core, sink) = makeCore { failures += 1 }
        let feed = CaptureFeed(video: 100...103, audio: [.microphone: 100...103])
        feed.run(core, from: 100, to: 101)
        let appended = sink.appends.count
        sink.hasFailed = true
        feed.run(core, from: 101, to: 103)
        core.finish(at: 103)
        #expect(failures == 1)
        #expect(core.hasFailed)
        #expect(sink.appends.count == appended)
    }

    @Test("An encoder that can't keep up drops frames instead of holding them")
    func backpressure() {
        let (core, sink) = makeCore(audio: [])
        CaptureFeed(video: 100.01...100.2).run(core, from: 100, to: 100.09)
        sink.isReady = false
        CaptureFeed(video: 100.21...100.5).run(core, from: 100.2, to: 100.49)
        #expect(core.droppedFrameCount == 9)
        #expect(sink.video.count == 3)
    }

    @Test("A deactivated core takes no more samples")
    func deactivated() {
        let (core, sink) = makeCore()
        CaptureFeed(video: 100...101).run(core, from: 100, to: 100.5)
        let appended = sink.appends.count
        core.deactivate()
        CaptureFeed(video: 100...101, audio: [.microphone: 100.5...101]).run(core, from: 100.5, to: 101)
        #expect(sink.appends.count == appended)
    }
}
