import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import Testing
@testable import Keybumps

/// The real `AVAssetWriter` path, fed made-up frames and sound into a temporary folder: no screen,
/// microphone, or permission involved. It proves the files are written and readable, not that
/// ScreenCaptureKit delivers what's fed here; that needs a signed build.
@Suite("Screencast: writing real files", .serialized)
struct ScreencastMovieWriterTests {
    let folder = TemporaryCapturesFolder()

    /// Three seconds from host 100: frames at 30 a second, the microphone in mono and the Mac's
    /// sound in stereo, delivered about as fast as an encoder takes them.
    private func feed(_ writer: ScreencastMovieWriter, seconds: Double = 3) {
        let frames = Int(seconds * 30)
        var nextAudio: [ScreencastAudioSource: Double] = [.microphone: 100, .systemAudio: 100]
        for frame in 0..<frames {
            let host = 100 + Double(frame) / 30
            writer.appendVideo(ScreencastSamples.video(at: host, width: 320, height: 180, shade: UInt8(frame % 255)))
            for source in ScreencastAudioSource.allCases {
                while let next = nextAudio[source], next < host + 1.0 / 30 {
                    writer.appendAudio(
                        ScreencastSamples.audio(at: next, channels: source == .systemAudio ? 2 : 1, value: source == .systemAudio ? 0.2 : 0.4),
                        from: source
                    )
                    nextAudio[source] = next + ScreencastSamples.audioBufferSeconds
                }
            }
            usleep(2_000)
        }
    }

    private func makeWriter(_ name: String, fragmentInterval: CMTime = ScreencastMovieWriter.fragmentInterval) throws -> ScreencastMovieWriter {
        try ScreencastMovieWriter(
            url: folder.url.appendingPathComponent(name),
            pixelWidth: 320,
            pixelHeight: 180,
            audio: [.microphone, .systemAudio],
            options: ScreencastOptions(),
            fragmentInterval: fragmentInterval,
            onFailure: {}
        )
    }

    private func channelCount(of track: AVAssetTrack) async throws -> UInt32? {
        let format = try await track.load(.formatDescriptions).first
        return format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
    }

    @Test("A file has the picture and a track per sound, and its mixdown one stereo track, both as long as the recording")
    func fileAndMixdown() async throws {
        defer { folder.remove() }
        let writer = try makeWriter("video-1.mov")
        feed(writer)
        let result = await writer.finish(at: 103)
        #expect(!result.failed && result.hasFootage)
        #expect(abs(result.duration - 3) < 0.05)

        let asset = AVURLAsset(url: result.fileURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1 && audioTracks.count == 2)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.1)
        #expect(try await videoTracks[0].load(.naturalSize) == CGSize(width: 320, height: 180))
        var channels: [UInt32] = []
        for track in audioTracks { channels.append(try await channelCount(of: track) ?? 0) }
        #expect(channels.sorted() == [1, 2], "the microphone in mono, the Mac's sound in stereo")

        let mixdownURL = folder.url.appendingPathComponent("video-1-mixdown.mp4")
        try await ScreencastAudioMixdown.write(from: result.fileURL, to: mixdownURL)
        let mixdown = AVURLAsset(url: mixdownURL)
        let mixedAudio = try await mixdown.loadTracks(withMediaType: .audio)
        #expect(try await mixdown.loadTracks(withMediaType: .video).count == 1)
        #expect(mixedAudio.count == 1)
        #expect(try await channelCount(of: mixedAudio[0]) == 2)
        #expect(abs(try await mixdown.load(.duration).seconds - 3) < 0.1)
    }

    @Test("Tracks that never heard a sound still run the whole recording", arguments: [30.0, 120.0])
    func silentTracksRunToTheEnd(seconds: Double) async throws {
        defer { folder.remove() }
        let writer = try makeWriter("silent-\(Int(seconds)).mov")
        // A frame a second is enough picture; the sound never comes.
        for second in 0...Int(seconds) {
            writer.appendVideo(ScreencastSamples.video(at: 100 + Double(second), width: 320, height: 180))
        }
        let result = await writer.finish(at: 100 + seconds)
        #expect(!result.failed && abs(result.duration - seconds) < 0.05)
        let audioTracks = try await AVURLAsset(url: result.fileURL).loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 2)
        for track in audioTracks {
            let length = try await track.load(.timeRange).duration.seconds
            #expect(abs(length - seconds) < 0.1, "a silent track \(length) s long in a \(seconds) s recording")
        }
    }

    @Test("A recording the clock kept up stops at once: its silent tracks are already written")
    func keptUpRecordingStopsAtOnce() async throws {
        defer { folder.remove() }
        let writer = try makeWriter("kept-up.mov")
        let seconds = 120.0
        // The recorder's tick, at about 125 times real time; a frame every 5 s, nothing heard.
        for quarter in stride(from: 0.0, through: seconds, by: 0.25) {
            if quarter.truncatingRemainder(dividingBy: 5) == 0 {
                writer.appendVideo(ScreencastSamples.video(at: 100 + quarter, width: 320, height: 180))
            }
            writer.keepUp(at: 100 + quarter)
            usleep(2_000)
        }
        let started = CACurrentMediaTime()
        let result = await writer.finish(at: 100 + seconds)
        let took = CACurrentMediaTime() - started
        #expect(took < 1, "finishing took \(took) s")
        #expect(!result.failed && abs(result.duration - seconds) < 0.05)
        for track in try await AVURLAsset(url: result.fileURL).loadTracks(withMediaType: .audio) {
            #expect(abs(try await track.load(.timeRange).duration.seconds - seconds) < 0.1)
        }
    }

    @Test("A microphone heard only after padding, in another layout, is converted and the file stays whole")
    func convertedMicrophone() async throws {
        defer { folder.remove() }
        let writer = try makeWriter("converted.mov")
        for frame in 0..<120 {
            let host = 100 + Double(frame) / 30
            writer.appendVideo(ScreencastSamples.video(at: host, width: 320, height: 180))
            if frame == 60 { writer.keepUp(at: host) }
            usleep(1_000)
        }
        // From 4 s, a 44.1 kHz stereo interleaved microphone.
        var host = 104.0
        while host < 106 {
            writer.appendAudio(ScreencastSamples.audio(at: host, frames: 941, channels: 2, value: 0.3, sampleRate: 44_100, interleaved: true), from: .microphone)
            writer.appendVideo(ScreencastSamples.video(at: host, width: 320, height: 180))
            host += 941.0 / 44_100
            usleep(500)
        }
        let result = await writer.finish(at: 106)
        #expect(!result.failed)
        let tracks = try await AVURLAsset(url: result.fileURL).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 2)
        for track in tracks {
            #expect(abs(try await track.load(.timeRange).duration.seconds - 6) < 0.1)
        }
    }

    @Test("The mixdown plays two sounds at full scale without clipping")
    func mixdownDoesNotClip() async throws {
        defer { folder.remove() }
        let writer = try makeWriter("loud.mov")
        var next = 100.0
        for frame in 0..<60 {
            let host = 100 + Double(frame) / 30
            writer.appendVideo(ScreencastSamples.video(at: host, width: 320, height: 180))
            while next < host + 1.0 / 30 {
                writer.appendAudio(ScreencastSamples.tone(at: next, channels: 1, amplitude: 0.8), from: .microphone)
                writer.appendAudio(ScreencastSamples.tone(at: next, channels: 2, amplitude: 0.8), from: .systemAudio)
                next += ScreencastSamples.audioBufferSeconds
            }
            usleep(2_000)
        }
        let result = await writer.finish(at: 102)
        let mixdownURL = folder.url.appendingPathComponent("loud-mixdown.mp4")
        try await ScreencastAudioMixdown.write(from: result.fileURL, to: mixdownURL)

        let peak = try await Self.peak(ofAudioIn: mixdownURL)
        #expect(peak > 0.5 && peak < 0.95, "two sounds at 0.8 mix to about 0.8, not 1.6")
    }

    /// The loudest decoded sample in a file's audio.
    private static func peak(ofAudioIn url: URL) async throws -> Float {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        reader.startReading()
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            peak = max(peak, ScreencastSamples.peak(of: sample))
        }
        return peak
    }

    @Test("A writer that never finishes, as when Keybumps is killed, leaves a file that plays up to its last fragment")
    func unfinishedFilePlays() async throws {
        defer { folder.remove() }
        let url: URL
        do {
            let writer = try makeWriter("killed.mov", fragmentInterval: CMTime(seconds: 0.5, preferredTimescale: 600))
            url = writer.fileURL
            feed(writer)
            // Gone without finishing or cancelling.
        }
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.load(.duration).seconds > 1.5)
    }

    @Test("Cancelling deletes the file")
    func cancel() async throws {
        defer { folder.remove() }
        let writer = try makeWriter("discarded.mov")
        feed(writer, seconds: 0.5)
        await writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: writer.fileURL.path))
    }

    @Test("A file stopped before its first frame is no footage")
    func noFrames() async throws {
        defer { folder.remove() }
        let writer = try makeWriter("empty.mov")
        let result = await writer.finish(at: 103)
        #expect(!result.hasFootage && !result.failed)
    }
}
