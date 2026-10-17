import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// Writing a recording's edits into its files (#517), on short movies made here through the
/// recorder's own writer (AVAssetWriter) in a temporary folder, never a real recording: what plays
/// after a trim, a cut, a crop, and blurs, each display's own, every sound cut with the picture, the
/// originals replaced only once everything is written, and kept as they were when it fails.
@Suite("ScreenGrabs: exporting a recording's edits", .serialized)
struct ScreencastEditExportTests {
    let folder = TemporaryCapturesFolder()

    private func range(_ start: Double, _ end: Double) -> ScreencastTimeRange {
        ScreencastTimeRange(start: start, end: end)
    }

    /// A recording's folder with a movie per display, three seconds each.
    private func capture(
        _ pictures: [EditTestMovie.Picture],
        sounds: Bool = true,
        mixdowns: Bool = false
    ) async throws -> ScreencastCapture {
        let captureFolder = folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
        var videos: [ScreencastVideo] = []
        for (index, picture) in pictures.enumerated() {
            let file = captureFolder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: index))
            try await EditTestMovie.write(to: file, seconds: 3, picture: picture, sounds: sounds)
            var mixdown: URL?
            if mixdowns, sounds {
                let url = captureFolder.appendingPathComponent(ScreencastCaptureFolder.mixdownName(index: index))
                try await ScreencastAudioMixdown.write(from: file, to: url)
                mixdown = url
            }
            videos.append(ScreencastVideo(
                file: file, mixdown: mixdown, pixelWidth: EditTestMovie.width, pixelHeight: EditTestMovie.height,
                audioTracks: sounds ? [.microphone, .systemAudio] : [], duration: 3
            ))
        }
        let capture = ScreencastCapture(folder: captureFolder, videos: videos, duration: 3, endedEarly: nil)
        try ScreencastMetadata(capture: capture, target: .display(1), startedAt: Date(timeIntervalSince1970: 1_791_000_000))
            .write(to: capture.metadataURL)
        return capture
    }

    private func export(_ capture: ScreencastCapture, _ edits: ScreencastRecordingEdits) async throws -> ScreencastCapture {
        try await ScreencastEditExporter.export(capture, edits: edits, cancellation: ScreencastExportCancellation())
    }

    // MARK: Trim and cut

    @Test("A trim plays the kept part, picture and both sounds, in the original's place")
    func trim() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar])
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 1, end: 2.5)
        let edited = try await export(original, edits)

        let file = original.videos[0].file
        #expect(edited.videos[0].file == file, "in the original's place")
        let duration = try await EditTestMovie.duration(of: file)
        #expect(abs(duration - 1.5) < 0.05, "\(duration) seconds")
        let first = try await EditTestMovie.barFrame(of: file, at: 0)
        #expect(abs(first - 30) <= 1, "it starts at the trim's start, frame \(first)")
        let sounds = try await EditTestMovie.audioDurations(of: file)
        #expect(sounds.count == 2, "a track per sound, as recorded")
        for sound in sounds {
            #expect(abs(sound - 1.5) < 0.1, "each sound trimmed with the picture: \(sound) seconds")
        }
        #expect(abs(edited.duration - 1.5) < 0.05)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: original.folder.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, "nothing left beside it: \(leftovers)")
    }

    @Test("A cut part is skipped: what came after it plays right after what came before")
    func cut() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar], sounds: false)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.cut(range(1, 2))
        _ = try await export(original, edits)

        let file = original.videos[0].file
        let duration = try await EditTestMovie.duration(of: file)
        #expect(abs(duration - 2) < 0.05, "\(duration) seconds")
        let before = try await EditTestMovie.barFrame(of: file, at: 0.5)
        #expect(abs(before - 15) <= 1, "before the cut: frame \(before)")
        let after = try await EditTestMovie.barFrame(of: file, at: 1.2)
        #expect(abs(after - 66) <= 1, "0.2 s after the cut's end: frame \(after)")
    }

    // MARK: Crop and blur

    @Test("A crop makes the video the crop's size, showing only what's in it")
    func crop() async throws {
        defer { folder.remove() }
        let original = try await capture([.halves], sounds: false)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.displays[0].crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let edited = try await export(original, edits)

        let video = edited.videos[0]
        #expect(video.pixelWidth == 96 && video.pixelHeight == 108)
        let size = try await EditTestMovie.size(of: video.file)
        #expect(size == CGSize(width: 96, height: 108))
        let image = try await EditTestMovie.image(of: video.file, at: 1)
        let left = EditTestMovie.color(in: image, x: 4, y: 54)
        let right = EditTestMovie.color(in: image, x: 92, y: 54)
        #expect(left.blue > 180 && left.red < 80, "only the right half, which is blue: \(left)")
        #expect(right.blue > 180 && right.red < 80, "\(right)")
    }

    @Test("A blur is a mosaic over its rect for the whole recording, and the rest stays sharp")
    func blur() async throws {
        defer { folder.remove() }
        let original = try await capture([.checkerboard], sounds: false)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.displays[0].blurs = [
            ScreencastBlur(id: 1, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), strength: .high, time: range(0, 3)),
        ]
        _ = try await export(original, edits)

        let image = try await EditTestMovie.image(of: original.videos[0].file, at: 1.5)
        let blurred = EditTestMovie.contrast(in: image, columns: 4..<88)
        let sharp = EditTestMovie.contrast(in: image, columns: 100..<188)
        #expect(blurred < 12, "a mosaic: \(blurred)")
        #expect(sharp > 30, "sharp beside it: \(sharp)")
    }

    @Test("A blur limited in time shows only then")
    func blurLimitedInTime() async throws {
        defer { folder.remove() }
        let original = try await capture([.checkerboard], sounds: false)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.displays[0].blurs = [
            ScreencastBlur(id: 1, rect: CGRect(x: 0, y: 0, width: 1, height: 1), strength: .medium, time: range(1, 2)),
        ]
        _ = try await export(original, edits)

        let file = original.videos[0].file
        let before = EditTestMovie.contrast(in: try await EditTestMovie.image(of: file, at: 0.5), columns: 4..<188)
        let during = EditTestMovie.contrast(in: try await EditTestMovie.image(of: file, at: 1.5), columns: 4..<188)
        let after = EditTestMovie.contrast(in: try await EditTestMovie.image(of: file, at: 2.5), columns: 4..<188)
        #expect(before > 30, "sharp before: \(before)")
        #expect(during < 12, "blurred from 1 s to 2 s: \(during)")
        #expect(after > 30, "sharp after: \(after)")
    }

    // MARK: What the player plays

    @Test("The player's composition plays the kept parts with every sound, at the crop's size, or the whole frame for placing the crop")
    func composition() async throws {
        defer { folder.remove() }
        let original = try await capture([.halves])
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 0.5, end: 2.5)
        edits.cut(range(1, 1.5))
        edits.displays[0].crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let file = original.videos[0].file

        let edit = try await ScreencastEditComposition.make(source: file, edits: edits, display: 0)
        let length = edit.duration.seconds
        #expect(abs(length - 1.5) < 0.01, "\(length) seconds")
        #expect(edit.videoComposition.renderSize == CGSize(width: 96, height: 108))
        #expect(edit.audioTracks.count == 2 && edit.audioChannels == [1, 2])
        #expect(edit.framesPerSecond == 30)

        let placing = try await ScreencastEditComposition.make(source: file, edits: edits, display: 0, crops: false)
        #expect(placing.videoComposition.renderSize == CGSize(width: 192, height: 108))
    }

    // MARK: Several displays

    @Test("Several displays: the trim cuts every display's video and mixdown, a crop only its own display's, and meta.json says their new sizes")
    func severalDisplays() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar, .halves], mixdowns: true)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 2)
        edits.setTrim(start: 0.5, end: 2.5)
        edits.displays[1].crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let edited = try await export(original, edits)

        for video in edited.videos {
            let duration = try await EditTestMovie.duration(of: video.file)
            #expect(abs(duration - 2) < 0.05, "\(video.file.lastPathComponent): \(duration) seconds")
            let mixdown = try #require(video.mixdown, "each keeps its mixdown")
            let mixed = try await EditTestMovie.duration(of: mixdown)
            #expect(abs(mixed - 2) < 0.1, "\(mixdown.lastPathComponent), made again: \(mixed) seconds")
            let tracks = try await EditTestMovie.audioDurations(of: mixdown)
            #expect(tracks.count == 1, "one stereo track")
        }
        let first = try await EditTestMovie.size(of: edited.videos[0].file)
        #expect(first == CGSize(width: 192, height: 108), "the first display isn't cropped")
        let second = try await EditTestMovie.size(of: edited.videos[1].file)
        #expect(second == CGSize(width: 96, height: 108), "the second is")

        let metadata = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: original.metadataURL)) as? [String: Any])
        let videos = try #require(metadata["videos"] as? [[String: Any]])
        let widths = videos.compactMap { $0["width"] as? Int }
        #expect(widths == [192, 96])
        let durations = videos.compactMap { $0["duration"] as? Double }
        let allTrimmed = durations.allSatisfy { abs($0 - 2) < 0.05 }
        #expect(durations.count == 2)
        #expect(allTrimmed, "\(durations)")
        let duration = try #require(metadata["duration"] as? Double)
        #expect(abs(duration - 2) < 0.05)
        #expect(metadata["startedAt"] != nil && metadata["target"] != nil, "everything else is kept")
    }

    // MARK: When it doesn't finish

    @Test("A failed export keeps the original as it was, and leaves nothing beside it")
    func failureKeepsTheOriginal() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar], sounds: false)
        let file = original.videos[0].file
        let before = try Data(contentsOf: file)
        // A folder nothing can be written in: the edited copy can't be made.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: original.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: original.folder.path) }
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 1, end: 2)

        await #expect(throws: ScreencastExportFailure.failed) {
            _ = try await export(original, edits)
        }
        let after = try Data(contentsOf: file)
        #expect(after == before, "the original is untouched")
        let names = try FileManager.default.contentsOfDirectory(atPath: original.folder.path).sorted()
        #expect(names == ["meta.json", "video-1.mov"])
    }

    @Test("A moved recording, or Cancel, changes nothing")
    func missingOrCancelled() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar], sounds: false)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 1, end: 2)
        let cancellation = ScreencastExportCancellation()
        cancellation.cancel()
        await #expect(throws: ScreencastExportFailure.cancelled) {
            _ = try await ScreencastEditExporter.export(original, edits: edits, cancellation: cancellation)
        }
        let duration = try await EditTestMovie.duration(of: original.videos[0].file)
        #expect(abs(duration - 3) < 0.05)

        try FileManager.default.removeItem(at: original.videos[0].file)
        await #expect(throws: ScreencastExportFailure.recordingMissing) {
            _ = try await export(original, edits)
        }
    }

    @Test("A full disk, or an AVFoundation error, says which")
    func failureCategories() {
        let full = ScreencastExportFailure.from(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        #expect(full == .diskFull)
        let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let wrapped = ScreencastExportFailure.from(NSError(domain: AVFoundationErrorDomain, code: -11_800, userInfo: [NSUnderlyingErrorKey: underlying]))
        #expect(wrapped == .diskFull)
        let avFull = ScreencastExportFailure.from(NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue))
        #expect(avFull == .diskFull)
        let other = ScreencastExportFailure.from(NSError(domain: AVFoundationErrorDomain, code: -11_800))
        #expect(other == .failed)
        #expect(ScreencastExportFailure.diskFull.message == "Couldn’t export the edited recording: the disk is full.")
    }

    @Test("Progress rises to the end")
    func progress() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar], sounds: false)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 0.5, end: 3)
        let log = ProgressLog()
        _ = try await ScreencastEditExporter.export(original, edits: edits, cancellation: ScreencastExportCancellation()) { log.add($0) }
        let values = log.values
        #expect(values.count >= 3, "\(values.count) reports")
        #expect(values.last == 1)
    }
}

/// Progress reports, from any queue.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
}

/// Short movies made for a test through the recorder's writer, and what's read back from them.
enum EditTestMovie {
    static let width = 192
    static let height = 108

    enum Picture {
        /// Black, with a white bar two pixels wide at `4 + 2 × frame`, so a frame says which it is.
        case movingBar
        /// Red on the left, blue on the right.
        case halves
        /// Black and white squares four pixels a side.
        case checkerboard
    }

    /// `seconds` at 30 frames a second, with the microphone in mono and the Mac's sound in stereo
    /// when `sounds`.
    static func write(to url: URL, seconds: Double, picture: Picture, sounds: Bool) async throws {
        let writer = try ScreencastMovieWriter(
            url: url, pixelWidth: width, pixelHeight: height,
            audio: sounds ? [.microphone, .systemAudio] : [], options: ScreencastOptions(),
            fragmentInterval: ScreencastMovieWriter.fragmentInterval, onFailure: {}
        )
        var nextAudio = 100.0
        for frame in 0..<Int(seconds * 30) {
            let host = 100 + Double(frame) / 30
            writer.appendVideo(sample(frame: frame, picture: picture, at: host))
            while sounds, nextAudio < host + 1.0 / 30 {
                writer.appendAudio(ScreencastSamples.audio(at: nextAudio, channels: 1, value: 0.4), from: .microphone)
                writer.appendAudio(ScreencastSamples.audio(at: nextAudio, channels: 2, value: 0.2), from: .systemAudio)
                nextAudio += ScreencastSamples.audioBufferSeconds
            }
        }
        let result = await writer.finish(at: 100 + seconds)
        guard !result.failed, result.hasFootage else { throw ScreencastExportFailure.failed }
    }

    private static func sample(frame: Int, picture: Picture, at host: Double) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pixelBuffer)
        let pixels = pixelBuffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let bar = 4 + frame * 2
        for y in 0..<height {
            for x in 0..<width {
                let (blue, green, red): (UInt8, UInt8, UInt8)
                switch picture {
                case .movingBar:
                    let lit: UInt8 = (x == bar || x == bar + 1) ? 255 : 0
                    (blue, green, red) = (lit, lit, lit)
                case .halves:
                    (blue, green, red) = x < width / 2 ? (0, 0, 255) : (255, 0, 0)
                case .checkerboard:
                    let lit: UInt8 = (x / 4 + y / 4) % 2 == 0 ? 255 : 0
                    (blue, green, red) = (lit, lit, lit)
                }
                let offset = y * rowBytes + x * 4
                base[offset] = blue
                base[offset + 1] = green
                base[offset + 2] = red
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: host, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample!
    }

    static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return try await asset.load(.duration).seconds
    }

    static func size(of url: URL) async throws -> CGSize? {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        return try await track?.load(.naturalSize)
    }

    static func audioDurations(of url: URL) async throws -> [Double] {
        var durations: [Double] = []
        for track in try await AVURLAsset(url: url).loadTracks(withMediaType: .audio) {
            durations.append(try await track.load(.timeRange).duration.seconds)
        }
        return durations
    }

    /// The frame at `seconds`, exactly.
    static func image(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Which recorded frame shows at `seconds` of a moving-bar movie: where its bar is.
    static func barFrame(of url: URL, at seconds: Double) async throws -> Int {
        let image = try await image(of: url, at: seconds)
        let row = rgba(image)
        let y = image.height / 2
        let brightest = (0..<image.width).max { left, right in
            brightness(row, image: image, x: left, y: y) < brightness(row, image: image, x: right, y: y)
        } ?? 0
        return (brightest - 4) / 2
    }

    struct Color: CustomStringConvertible {
        let red: Int, green: Int, blue: Int
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }

    static func color(in image: CGImage, x: Int, y: Int) -> Color {
        let pixels = rgba(image)
        let offset = (y * image.width + x) * 4
        return Color(red: Int(pixels[offset]), green: Int(pixels[offset + 1]), blue: Int(pixels[offset + 2]))
    }

    /// The mean difference between neighboring pixels' red across `columns`, every row: high for
    /// the checkerboard, low for a mosaic.
    static func contrast(in image: CGImage, columns: Range<Int>) -> Double {
        let pixels = rgba(image)
        var total = 0.0
        var count = 0
        for y in 0..<image.height {
            for x in columns.dropFirst() {
                let here = Int(pixels[(y * image.width + x) * 4])
                let left = Int(pixels[(y * image.width + x - 1) * 4])
                total += Double(abs(here - left))
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    private static func brightness(_ pixels: [UInt8], image: CGImage, x: Int, y: Int) -> Int {
        let offset = (y * image.width + x) * 4
        return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
    }

    /// The image's pixels, RGBA from its top left, in sRGB.
    private static func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}
