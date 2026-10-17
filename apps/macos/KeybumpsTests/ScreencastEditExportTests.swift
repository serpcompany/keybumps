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

    /// A recording's folder with a movie per display, three seconds each unless `seconds` says.
    private func capture(
        _ pictures: [EditTestMovie.Picture],
        sounds: Bool = true,
        mixdowns: Bool = false,
        seconds: [Double] = [],
        toneFrom: Double? = nil
    ) async throws -> ScreencastCapture {
        let captureFolder = folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
        var videos: [ScreencastVideo] = []
        for (index, picture) in pictures.enumerated() {
            let file = captureFolder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: index))
            let length = seconds.indices.contains(index) ? seconds[index] : 3
            try await EditTestMovie.write(to: file, seconds: length, picture: picture, sounds: sounds, toneFrom: toneFrom)
            var mixdown: URL?
            if mixdowns, sounds {
                let url = captureFolder.appendingPathComponent(ScreencastCaptureFolder.mixdownName(index: index))
                try await ScreencastAudioMixdown.write(from: file, to: url)
                mixdown = url
            }
            videos.append(ScreencastVideo(
                file: file, mixdown: mixdown, pixelWidth: EditTestMovie.width, pixelHeight: EditTestMovie.height,
                audioTracks: sounds ? [.microphone, .systemAudio] : [], duration: length
            ))
        }
        let duration = videos.map(\.duration).max() ?? 3
        let capture = ScreencastCapture(folder: captureFolder, videos: videos, duration: duration, endedEarly: nil)
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

    @Test("A cut with both sounds keeps them in step with the picture: a tone after the cut starts where its frame shows")
    func cutWithSound() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar], toneFrom: 2.25)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.cut(range(1, 2))
        _ = try await export(original, edits)

        let file = original.videos[0].file
        let duration = try await EditTestMovie.duration(of: file)
        #expect(abs(duration - 2) < 0.05, "\(duration) seconds")
        let sounds = try await EditTestMovie.audioDurations(of: file)
        #expect(sounds.count == 2)
        for sound in sounds {
            #expect(abs(sound - 2) < 0.1, "each sound runs as long as the picture: \(sound) seconds")
        }
        // Recorded at 2.25 s, 0.25 s after the cut: 1.25 s into the edited recording.
        let onsets = try await EditTestMovie.soundOnsets(of: file)
        #expect(onsets.count == 2)
        for onset in onsets {
            let time = try #require(onset, "the tone is there")
            #expect(abs(time - 1.25) < 0.05, "the tone starts at \(time) s")
        }
        let frame = try await EditTestMovie.barFrame(of: file, at: 1.27)
        #expect(abs(frame - 68) <= 1, "the picture there is from 2.27 s: frame \(frame)")
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

    @Test("A mostly still recording is drawn and encoded at the rate it was made at, not its average")
    func mostlyStillKeepsItsRate() async throws {
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appendingPathComponent("still.mov")
        // Ten frames at 60 a second, then one a second: the screen went still.
        let times = (0..<10).map { Double($0) / 60 } + [1, 2]
        try await EditTestMovie.write(to: file, seconds: 3, picture: .movingBar, sounds: false, framesPerSecond: 60, frameTimes: times)
        let track = try #require(try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first)
        let average = try await track.load(.nominalFrameRate)
        #expect(average < 10, "the average reads low: \(average)")

        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 0, end: 2.5)
        let edit = try await ScreencastEditComposition.make(source: file, edits: edits, display: 0)
        #expect(edit.framesPerSecond == 60)
        #expect(edit.videoComposition.frameDuration == CMTime(value: 1, timescale: 60))
    }

    @Test("The rate: the higher of the average and the shortest gap's, 1 to 120, or 30 when neither is known")
    func framesPerSecond() {
        let sixtieth = CMTime(value: 1, timescale: 60)
        #expect(ScreencastEditComposition.framesPerSecond(nominal: 5, minFrameDuration: sixtieth) == 60)
        #expect(ScreencastEditComposition.framesPerSecond(nominal: 30, minFrameDuration: .invalid) == 30)
        #expect(ScreencastEditComposition.framesPerSecond(nominal: .nan, minFrameDuration: .zero) == 30)
        let tiny = CMTime(value: 1, timescale: 1_000_000)
        #expect(ScreencastEditComposition.framesPerSecond(nominal: .infinity, minFrameDuration: tiny) == 120)
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

    @Test("A display that stopped before the kept part keeps its video as recorded; the others are trimmed")
    func shorterDisplayTrimmedPastItsEnd() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar, .halves], seconds: [3, 1])
        let second = original.videos[1]
        let before = try Data(contentsOf: second.file)
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 2)
        edits.setTrim(start: 1.5, end: 3)
        let edited = try await export(original, edits)

        let first = try await EditTestMovie.duration(of: edited.videos[0].file)
        #expect(abs(first - 1.5) < 0.05, "the first is trimmed: \(first) seconds")
        #expect(edited.videos[1] == second, "the second is as it was")
        let after = try Data(contentsOf: second.file)
        #expect(after == before, "its file untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: original.folder.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test("Less than a frame of a display is nothing of it, for the composition too")
    func slivers() async throws {
        defer { folder.remove() }
        let original = try await capture([.movingBar], sounds: false, seconds: [1])
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 0.95, end: 3)
        #expect(!edits.keepsSomething(ofVideoLasting: 1))
        #expect(edits.keepsSomething(ofVideoLasting: 3))
        await #expect(throws: ScreencastEditComposition.CompositionError.nothingKept) {
            _ = try await ScreencastEditComposition.make(source: original.videos[0].file, edits: edits, display: 0)
        }
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

    @Test("A full disk during the mixdown says so: it carries the writer's own error")
    func mixdownDiskFull() {
        let full = NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue)
        let failure = ScreencastExportFailure.from(ScreencastAudioMixdown.writerFailure(full))
        #expect(failure == .diskFull)
        let unknown = ScreencastExportFailure.from(ScreencastAudioMixdown.writerFailure(nil))
        #expect(unknown == .failed)
    }

    @Test("Cancel waits for a swap under way to finish, and none starts after it")
    func cancelWaitsForTheSwap() throws {
        let cancellation = ScreencastExportCancellation()
        let log = ProgressLog()
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? cancellation.swap {
                started.signal()
                Thread.sleep(forTimeInterval: 0.1)
                log.add(1)
            }
            done.signal()
        }
        started.wait()
        cancellation.cancel()
        #expect(log.values == [1], "the swap finished first")
        done.wait()
        #expect(throws: ScreencastExportFailure.cancelled) {
            try cancellation.swap { log.add(2) }
        }
        #expect(log.values == [1])
    }

    // MARK: After a quit or a crash

    /// Makes `files` (name: contents) in a recording's folder named `name`, with a `meta.json`.
    private func recording(_ name: String, _ files: [String: String], metadata: Bool = true) throws -> URL {
        let url = folder.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var all = files
        if metadata { all[ScreencastMetadata.fileName] = "{}" }
        for (file, contents) in all {
            try Data(contents.utf8).write(to: url.appendingPathComponent(file))
        }
        return url
    }

    /// Each file's name and contents.
    private func contents(of url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            result[name] = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
        }
        return result
    }

    @Test("At launch, an export's partial copies are deleted, only in recordings' folders")
    func recoveryDeletesPartialCopies() throws {
        defer { folder.remove() }
        let quit = try recording("1791000000", [
            "video-1.mov": "original", "video-1-mixdown.mp4": "original mix",
            ".video-1.editing.mov": "partial", ".video-1-mixdown.editing.mp4": "partial mix",
        ])
        let other = try recording("other", [".video-1.editing.mov": "not ours", ".notes.editing.txt": "x"], metadata: false)
        let recovery = ScreencastEditExporter.recoverInterruptedExports(in: folder.url)

        #expect(recovery == .init(removed: 2, restored: 0))
        let left = try contents(of: quit)
        #expect(left == ["video-1.mov": "original", "video-1-mixdown.mp4": "original mix", "meta.json": "{}"])
        #expect(try contents(of: other).count == 2, "a folder without meta.json is left alone")
    }

    @Test("At launch, a swap cut short before every edited copy was placed puts every original back")
    func recoveryRestoresAnInterruptedSwap() throws {
        defer { folder.remove() }
        // Both originals set aside; the first display's edited copy placed, the second's not yet.
        let url = try recording("1791000000", [
            ".video-1.original.mov": "original 1", "video-1.mov": "edited 1",
            ".video-2.original.mov": "original 2", ".video-2.editing.mov": "edited 2",
        ])
        let recovery = ScreencastEditExporter.recoverInterruptedExports(in: folder.url)

        #expect(recovery == .init(removed: 1, restored: 2))
        let left = try contents(of: url)
        #expect(left == ["video-1.mov": "original 1", "video-2.mov": "original 2", "meta.json": "{}"])
    }

    @Test("At launch, an original with nothing in its place goes back; once every edited copy was placed, the swap is finished")
    func recoveryFinishesACompletedSwap() throws {
        defer { folder.remove() }
        let alone = try recording("1791000000", [".video-1.original.mov": "original"])
        let placed = try recording("1791000001", [".video-1.original.mov": "original", "video-1.mov": "edited"])
        let recovery = ScreencastEditExporter.recoverInterruptedExports(in: folder.url)

        #expect(recovery == .init(removed: 1, restored: 1))
        #expect(try contents(of: alone) == ["video-1.mov": "original", "meta.json": "{}"])
        #expect(try contents(of: placed) == ["video-1.mov": "edited", "meta.json": "{}"])
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

    /// `seconds` at 30 frames a second, or a frame at each of `frameTimes`, with the microphone in
    /// mono and the Mac's sound in stereo when `sounds`: steady, or silent until `toneFrom` seconds
    /// and then a 1 kHz tone.
    static func write(
        to url: URL, seconds: Double, picture: Picture, sounds: Bool, toneFrom: Double? = nil,
        framesPerSecond: Int = 30, frameTimes: [Double]? = nil
    ) async throws {
        let writer = try ScreencastMovieWriter(
            url: url, pixelWidth: width, pixelHeight: height,
            audio: sounds ? [.microphone, .systemAudio] : [], options: ScreencastOptions(framesPerSecond: framesPerSecond),
            fragmentInterval: ScreencastMovieWriter.fragmentInterval, onFailure: {}
        )
        let tone: ((Double) -> Float)? = toneFrom.map { start in
            { host in host >= 100 + start ? Float(0.5 * sin(2 * .pi * 1_000 * host)) : 0 }
        }
        var nextAudio = 100.0
        let times = frameTimes ?? (0..<Int(seconds * 30)).map { Double($0) / 30 }
        for (frame, time) in times.enumerated() {
            let host = 100 + time
            writer.appendVideo(sample(frame: frame, picture: picture, at: host))
            while sounds, nextAudio < host + 1.0 / 30 {
                writer.appendAudio(ScreencastSamples.audio(at: nextAudio, channels: 1, value: 0.4, wave: tone), from: .microphone)
                writer.appendAudio(ScreencastSamples.audio(at: nextAudio, channels: 2, value: 0.2, wave: tone), from: .systemAudio)
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

    /// When each sound track first gets loud, in seconds: where a tone starts, or nil.
    static func soundOnsets(of url: URL) async throws -> [Double?] {
        let asset = AVURLAsset(url: url)
        var onsets: [Double?] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000,
            ])
            reader.add(output)
            reader.startReading()
            var onset: Double?
            while onset == nil, let sample = output.copyNextSampleBuffer() {
                onset = loudStart(of: sample)
            }
            reader.cancelReading()
            onsets.append(onset)
        }
        return onsets
    }

    /// Where in `sample` a sound first passes 0.2, in seconds.
    private static func loudStart(of sample: CMSampleBuffer) -> Double? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count * MemoryLayout<Float>.size, destination: &data)
        guard let index = data.firstIndex(where: { abs($0) > 0.2 }) else { return nil }
        let channels = max(data.count / frames, 1)
        return CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(index / channels) / 48_000
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
