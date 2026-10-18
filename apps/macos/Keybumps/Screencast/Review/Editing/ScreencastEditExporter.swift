import AVFoundation
import Foundation

/// Why the edited recording wasn't written. A category only, never a file or an edit, so it can be
/// shown and logged as it is. The original is untouched in every case.
enum ScreencastExportFailure: String, Error, Equatable {
    /// The disk is full.
    case diskFull
    /// The recording was moved or deleted.
    case recordingMissing
    /// Anything else: AVFoundation couldn't read or write it.
    case failed
    /// Cancel, or Escape.
    case cancelled

    /// What the window says: what failed, then why.
    var message: String {
        switch self {
        case .diskFull: "Couldn’t export the edited recording: the disk is full."
        case .recordingMissing: "Couldn’t export the edited recording: it was moved or deleted."
        case .failed, .cancelled: "Couldn’t export the edited recording."
        }
    }

    /// What to do about it.
    var advice: String {
        switch self {
        case .diskFull: "The original is kept as it was. Free up some space, then try again."
        case .recordingMissing: "Nothing was changed."
        case .failed, .cancelled: "The original is kept as it was. Try again, or save the original."
        }
    }

    /// The category for an error from AVFoundation or the file system.
    static func from(_ error: Error) -> ScreencastExportFailure {
        if let failure = error as? ScreencastExportFailure { return failure }
        if error is CancellationError { return .cancelled }
        let error = error as NSError
        let chain = sequence(first: error) { $0.userInfo[NSUnderlyingErrorKey] as? NSError }
        let outOfSpace = chain.contains { error in
            (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
                || (error.domain == AVFoundationErrorDomain && error.code == AVError.diskFull.rawValue)
        }
        return outOfSpace ? .diskFull : .failed
    }
}

/// A one-way flag the export checks between samples: set, it stops and deletes what it wrote. After
/// Shotnix's `CancellationFlag` (MIT, see LICENSE.shotnix).
///
/// The edited files take the originals' places (`swap`) only while it isn't set, and setting it
/// waits for a swap under way, which takes a few renames: once `cancel()` returns, the recording's
/// files are either all original or all edited, even if the app quits right after.
final class ScreencastExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let swapLock = NSLock()
    private var value = false

    var isCancelled: Bool { lock.withLock { value } }

    func cancel() {
        swapLock.withLock { lock.withLock { value = true } }
    }

    /// Runs `body` unless it's cancelled, and holds off `cancel()` until it's done.
    func swap(_ body: () throws -> Void) throws {
        try swapLock.withLock {
            guard !isCancelled else { throw ScreencastExportFailure.cancelled }
            try body()
        }
    }
}

/// Save and Copy with edits (#517): each display's edited video is written beside its original, and
/// its stereo mixdown after it, and only once every one is complete do they take the originals'
/// places, all together. A failure, or Cancel, deletes what was written and leaves the originals as
/// they were. `meta.json` then says each video's new size and length. A display with nothing in the
/// kept part (its stream stopped before it) keeps its video as it was recorded. What a quit or a
/// crash cuts short is cleaned up at the next launch (`recoverInterruptedExports(in:)`).
///
/// The writing is after Shotnix's `VideoDemoExporter.writeMovie` and `MovieJob` (`Video/VideoExporter.swift`,
/// MIT, see LICENSE.shotnix): a reader's video composition into a fresh encoder, and every sound
/// track decoded and encoded again, each on its own queue, stopping at the first failure. The picture
/// is encoded as the recorder encodes it (`ScreencastMovieWriter.videoSettings`), and each sound
/// with its own channels.
enum ScreencastEditExporter {
    /// The share of each display's progress its picture and sound take; its mixdown the rest.
    static let movieShare = 0.85

    /// Writes `edits` into `capture`'s files, reporting progress from 0 to 1, and returns the capture
    /// as it is after.
    static func export(
        _ capture: ScreencastCapture,
        edits: ScreencastRecordingEdits,
        fileManager: FileManager = .default,
        cancellation: ScreencastExportCancellation,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ScreencastCapture {
        var written: [(original: URL, edited: URL)] = []
        do {
            guard capture.videos.allSatisfy({ fileManager.fileExists(atPath: $0.file.path) }) else {
                throw ScreencastExportFailure.recordingMissing
            }
            var videos: [ScreencastVideo] = []
            let count = Double(max(capture.videos.count, 1))
            for (index, video) in capture.videos.enumerated() {
                if cancellation.isCancelled { throw ScreencastExportFailure.cancelled }
                let report: @Sendable (Double) -> Void = { fraction in progress((Double(index) + fraction) / count) }
                guard edits.keepsSomething(of: video) else {
                    // Its video stays as it was recorded, as the window says.
                    report(1)
                    videos.append(video)
                    continue
                }
                let editedFile = editingURL(for: video.file)
                written.append((video.file, editedFile))
                let facts: MovieFacts
                do {
                    facts = try await writeMovie(
                        from: video.file, to: editedFile, edits: edits, display: index, cancellation: cancellation
                    ) { report($0 * movieShare) }
                } catch ScreencastEditComposition.CompositionError.nothingKept {
                    // A backstop: the composition's own check, from the file's length, which runs a
                    // frame past the recorded one, so it can't find less than the check above.
                    written.removeLast()
                    report(1)
                    videos.append(video)
                    continue
                }
                var editedMixdown: URL?
                if let mixdown = video.mixdown {
                    if cancellation.isCancelled { throw ScreencastExportFailure.cancelled }
                    let url = editingURL(for: mixdown)
                    written.append((mixdown, url))
                    try await ScreencastAudioMixdown.write(from: editedFile, to: url) { cancellation.isCancelled }
                    editedMixdown = mixdown
                }
                if cancellation.isCancelled { throw ScreencastExportFailure.cancelled }
                report(1)
                videos.append(ScreencastVideo(
                    file: video.file, mixdown: editedMixdown, pixelWidth: facts.pixelWidth, pixelHeight: facts.pixelHeight,
                    audioTracks: video.audioTracks, duration: facts.duration
                ))
            }
            let edited = ScreencastCapture(
                folder: capture.folder, videos: videos, duration: videos.map(\.duration).max() ?? 0,
                endedEarly: capture.endedEarly, displaysEndedEarly: capture.displaysEndedEarly
            )
            try cancellation.swap {
                try replace(written, fileManager: fileManager)
                // The files are already edited: a `meta.json` that can't be updated still has the rest.
                try? updateMetadata(of: edited, fileManager: fileManager)
            }
            return edited
        } catch {
            for file in written { try? fileManager.removeItem(at: file.edited) }
            throw cancellation.isCancelled ? ScreencastExportFailure.cancelled : ScreencastExportFailure.from(error)
        }
    }

    /// Where a file's edited copy is written until it takes the file's place: beside it, hidden, with
    /// its extension, which AVFoundation reads the kind of file from.
    static func editingURL(for file: URL) -> URL {
        sibling(of: file, marked: "editing")
    }

    /// Where a file waits while the edited ones take the originals' places.
    static func backupURL(for file: URL) -> URL {
        sibling(of: file, marked: "original")
    }

    private static func sibling(of file: URL, marked mark: String) -> URL {
        let name = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent().appendingPathComponent(".\(name).\(mark).\(file.pathExtension)")
    }

    /// Deletes the edited copies an export of `capture` was writing, at once: the app may be about to
    /// quit, before the export's own clean-up runs. A writer with one open can still finish with it.
    static func removePartialFiles(of capture: ScreencastCapture, fileManager: FileManager = .default) {
        for video in capture.videos {
            for file in [video.file, video.mixdown].compactMap({ $0 }) {
                try? fileManager.removeItem(at: editingURL(for: file))
            }
        }
    }

    // MARK: One display's movie

    struct MovieFacts: Equatable, Sendable {
        let pixelWidth: Int
        let pixelHeight: Int
        let duration: TimeInterval
    }

    /// Writes `display`'s video at `source` with `edits` to `destination`, a QuickTime movie with the
    /// picture and a track per sound, as the recorder writes.
    static func writeMovie(
        from source: URL,
        to destination: URL,
        edits: ScreencastRecordingEdits,
        display: Int,
        cancellation: ScreencastExportCancellation,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MovieFacts {
        let edit = try await ScreencastEditComposition.make(source: source, edits: edits, display: display)
        let duration = edit.duration
        guard duration.isNumeric, duration > .zero else { throw ScreencastExportFailure.failed }
        try? FileManager.default.removeItem(at: destination)
        let job = try MovieJob(edit: edit, destination: destination, cancellation: cancellation, progress: progress)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            job.run { result in continuation.resume(with: result) }
        }
        let size = edit.editor.renderSize
        return MovieFacts(pixelWidth: pixels(size.width), pixelHeight: pixels(size.height), duration: duration.seconds)
    }

    /// A rendered size's whole pixels, which can't trap.
    static func pixels(_ value: CGFloat) -> Int {
        ScreencastNumbers.int(Double(value), in: 0...ScreencastCaptureGeometry.pixelLimit, fallback: 2)
    }

    /// One movie's reader and writer, confined to their queues once started.
    private final class MovieJob: @unchecked Sendable {
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)]
        private let duration: Double
        private let cancellation: ScreencastExportCancellation
        private let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var lastReported = -1.0

        init(
            edit: ScreencastEditComposition,
            destination: URL,
            cancellation: ScreencastExportCancellation,
            progress: @escaping @Sendable (Double) -> Void
        ) throws {
            reader = try AVAssetReader(asset: edit.composition)
            reader.timeRange = CMTimeRange(start: .zero, duration: edit.duration)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
            duration = edit.duration.seconds
            self.cancellation = cancellation
            self.progress = progress

            let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [edit.videoTrack], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ])
            videoOutput.videoComposition = edit.videoComposition
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else { throw ScreencastExportFailure.failed }
            reader.add(videoOutput)
            let size = edit.editor.renderSize
            let videoSettings = ScreencastMovieWriter.videoSettings(
                pixelWidth: ScreencastEditExporter.pixels(size.width), pixelHeight: ScreencastEditExporter.pixels(size.height),
                framesPerSecond: edit.framesPerSecond
            )
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw ScreencastExportFailure.failed }
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else { throw ScreencastExportFailure.failed }
            writer.add(videoInput)
            var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]

            // A sound with nothing left in the kept parts has nothing to read.
            for (track, channels) in zip(edit.audioTracks, edit.audioChannels) where !track.segments.isEmpty {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw ScreencastExportFailure.failed }
                reader.add(output)
                let settings = ScreencastMovieWriter.audioSettings(channels: channels)
                // Settings the writer can't use would raise an exception when the input is made.
                guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw ScreencastExportFailure.failed }
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw ScreencastExportFailure.failed }
                writer.add(input)
                pairs.append((output, input))
            }
            self.pairs = pairs
        }

        /// Copies every output into its input, each on its own queue (`ScreencastSampleCopier`),
        /// then finishes the file and calls `completion` once.
        func run(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
            guard writer.startWriting() else {
                return completion(.failure(writer.error ?? ScreencastExportFailure.failed))
            }
            guard reader.startReading() else {
                writer.cancelWriting()
                return completion(.failure(reader.error ?? ScreencastExportFailure.failed))
            }
            writer.startSession(atSourceTime: .zero)
            let copier = ScreencastSampleCopier(
                reader: reader, writer: writer, pairs: pairs,
                label: "com.serp.keybumps.screencast.export", qos: .userInitiated
            ) { [cancellation] in cancellation.isCancelled }
            copier.run(onSample: { [self] index, sample in
                if index == 0 { report(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
            }, completion: { [self] in
                finish(stopped: copier.didStop, completion)
            })
        }

        /// Runs once no queue is copying: the copier has cancelled both sides if it stopped.
        private func finish(stopped: Bool, _ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
            if cancellation.isCancelled {
                if writer.status == .writing { writer.cancelWriting() }
                return completion(.failure(ScreencastExportFailure.cancelled))
            }
            if stopped || reader.status == .failed {
                if writer.status == .writing { writer.cancelWriting() }
                return completion(.failure(writer.error ?? reader.error ?? ScreencastExportFailure.failed))
            }
            // A writer that failed on its own once the copy was done (a full disk) says so here.
            ScreencastSampleCopier.finishWriting(writer) { [writer] completed in
                completion(completed ? .success(()) : .failure(writer.error ?? ScreencastExportFailure.failed))
            }
        }

        private func report(_ seconds: Double) {
            guard duration > 0, seconds.isFinite else { return }
            let fraction = min(max(seconds / duration, 0), 1)
            let shouldReport = lock.withLock {
                guard fraction - lastReported >= 0.01 else { return false }
                lastReported = fraction
                return true
            }
            if shouldReport { progress(fraction) }
        }
    }

    // MARK: Taking the originals' places

    /// Moves each original aside, puts its edited copy in its place, then deletes the originals. If a
    /// move fails, every original goes back, so the recording is never half edited.
    static func replace(_ files: [(original: URL, edited: URL)], fileManager: FileManager) throws {
        var setAside: [URL] = []
        var placed: [URL] = []
        do {
            for file in files {
                try? fileManager.removeItem(at: backupURL(for: file.original))
                try fileManager.moveItem(at: file.original, to: backupURL(for: file.original))
                setAside.append(file.original)
            }
            for file in files {
                try fileManager.moveItem(at: file.edited, to: file.original)
                placed.append(file.original)
            }
        } catch {
            for original in placed { try? fileManager.removeItem(at: original) }
            for original in setAside { try? fileManager.moveItem(at: backupURL(for: original), to: original) }
            throw error
        }
        for original in setAside { try? fileManager.removeItem(at: backupURL(for: original)) }
    }

    // MARK: After a quit or a crash

    /// What `recoverInterruptedExports(in:)` did, in counts only.
    struct Recovery: Equatable, Sendable {
        /// Edited copies deleted, and originals no longer needed.
        var removed = 0
        /// Originals put back in their places.
        var restored = 0
    }

    /// At launch: what an export cut short left in each recording's folder in `capturesFolder`. Its
    /// edited copies (`.video-1.editing.mov`) are deleted. If it was swapping files, while any edited
    /// copy was still to be placed, the originals set aside (`.video-1.original.mov`) go back, over any
    /// edited one already placed; once every edited copy was placed, only the originals' deleting was
    /// left, so that's finished. An original with nothing in its place always goes back. Only
    /// recordings' folders (named as the recorder names them, `ScreencastCaptureFolder.isFolderName`,
    /// with a `meta.json`), and only the names an export makes, are touched; any other folder in
    /// `capturesFolder`, such as the person's own on the Desktop, is never opened (#504).
    @discardableResult
    static func recoverInterruptedExports(in capturesFolder: URL, fileManager: FileManager = .default) -> Recovery {
        var recovery = Recovery()
        let folders = (try? fileManager.contentsOfDirectory(
            at: capturesFolder, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        for folder in folders where ScreencastCaptureFolder.isFolderName(folder.lastPathComponent)
            && (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path),
                  names.contains(ScreencastMetadata.fileName) else { continue }
            let marked = names.compactMap(MarkedFile.init)
            let editing = marked.filter { $0.mark == "editing" }
            let placingWasCutShort = !editing.isEmpty
            for backup in marked where backup.mark == "original" {
                let backupURL = folder.appendingPathComponent(backup.name)
                let original = folder.appendingPathComponent(backup.original)
                if placingWasCutShort || !fileManager.fileExists(atPath: original.path) {
                    try? fileManager.removeItem(at: original)
                    if (try? fileManager.moveItem(at: backupURL, to: original)) != nil { recovery.restored += 1 }
                } else if (try? fileManager.removeItem(at: backupURL)) != nil {
                    recovery.removed += 1
                }
            }
            for file in editing where (try? fileManager.removeItem(at: folder.appendingPathComponent(file.name))) != nil {
                recovery.removed += 1
            }
        }
        return recovery
    }

    /// A name `sibling(of:marked:)` makes for a recording's file: `.video-1.editing.mov`, or
    /// `.video-1-mixdown.original.mp4`.
    private struct MarkedFile {
        let name: String
        let mark: String
        /// The recording's file it stands beside: `video-1.mov`.
        let original: String

        init?(_ name: String) {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0].isEmpty, ["editing", "original"].contains(parts[2]),
                  parts[1].hasPrefix("video-"), !parts[3].isEmpty else { return nil }
            self.name = name
            mark = String(parts[2])
            original = "\(parts[1]).\(parts[3])"
        }
    }

    /// Puts each video's new size and length, and the recording's, in its `meta.json`, keeping
    /// everything else in it, the review too.
    static func updateMetadata(of capture: ScreencastCapture, fileManager: FileManager) throws {
        let url = capture.metadataURL
        guard fileManager.fileExists(atPath: url.path),
              var metadata = (try JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else { return }
        metadata["duration"] = capture.duration
        if var videos = metadata["videos"] as? [[String: Any]] {
            for (index, video) in capture.videos.enumerated() where videos.indices.contains(index) {
                videos[index]["width"] = video.pixelWidth
                videos[index]["height"] = video.pixelHeight
                videos[index]["duration"] = video.duration
            }
            metadata["videos"] = videos
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try PrivateFile.write(data, to: url, fileManager: fileManager)
    }
}

/// How Save and Copy write a recording's edits: the app's writes the movies (`ScreencastEditExporter`),
/// and a test's can fail, or wait to be cancelled, without writing any.
struct ScreencastEditExport: Sendable {
    typealias Run = @Sendable (
        ScreencastCapture,
        ScreencastRecordingEdits,
        ScreencastExportCancellation,
        @escaping @Sendable (Double) -> Void
    ) async throws -> ScreencastCapture

    let run: Run

    static let movies = ScreencastEditExport { capture, edits, cancellation, progress in
        try await ScreencastEditExporter.export(capture, edits: edits, cancellation: cancellation, progress: progress)
    }
}
