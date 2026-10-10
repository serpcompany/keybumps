import AVFoundation
import CoreMedia
import Foundation
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
