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
final class ScreencastExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool { lock.withLock { value } }

    func cancel() { lock.withLock { value = true } }
}

/// Save and Copy with edits (#517): each display's edited video is written beside its original, and
/// its stereo mixdown after it, and only once every one is complete do they take the originals'
/// places, all together. A failure, or Cancel, deletes what was written and leaves the originals as
/// they were. `meta.json` then says each video's new size and length.
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
                let report: @Sendable (Double) -> Void = { fraction in progress((Double(index) + fraction) / count) }
                let editedFile = editingURL(for: video.file)
                written.append((video.file, editedFile))
                let facts = try await writeMovie(
                    from: video.file, to: editedFile, edits: edits, display: index, cancellation: cancellation
                ) { report($0 * movieShare) }
                var editedMixdown: URL?
                if let mixdown = video.mixdown {
                    let url = editingURL(for: mixdown)
                    written.append((mixdown, url))
                    try await ScreencastAudioMixdown.write(from: editedFile, to: url)
                    editedMixdown = mixdown
                }
                if cancellation.isCancelled { throw ScreencastExportFailure.cancelled }
                report(1)
                videos.append(ScreencastVideo(
                    file: video.file, mixdown: editedMixdown, pixelWidth: facts.pixelWidth, pixelHeight: facts.pixelHeight,
                    audioTracks: video.audioTracks, duration: facts.duration
                ))
            }
            try replace(written, fileManager: fileManager)
            let edited = ScreencastCapture(
                folder: capture.folder, videos: videos, duration: videos.map(\.duration).max() ?? 0,
                endedEarly: capture.endedEarly, displaysEndedEarly: capture.displaysEndedEarly
            )
            // The files are already edited: a `meta.json` that can't be updated still has the rest.
            try? updateMetadata(of: edited, fileManager: fileManager)
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
        return MovieFacts(pixelWidth: Int(size.width), pixelHeight: Int(size.height), duration: duration.seconds)
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
        private var finished: [Bool]
        private var failed = false
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
                pixelWidth: Int(size.width), pixelHeight: Int(size.height), framesPerSecond: edit.framesPerSecond
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
            finished = Array(repeating: false, count: pairs.count)
        }

        /// Copies every output into its input, each on its own queue, then finishes the file and
        /// calls `completion` once.
        func run(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
            guard writer.startWriting() else {
                return completion(.failure(writer.error ?? ScreencastExportFailure.failed))
            }
            guard reader.startReading() else {
                writer.cancelWriting()
                return completion(.failure(reader.error ?? ScreencastExportFailure.failed))
            }
            writer.startSession(atSourceTime: .zero)
            let group = DispatchGroup()
            for (index, pair) in pairs.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "com.serp.keybumps.screencast.export.\(index)", qos: .userInitiated)
                pair.input.requestMediaDataWhenReady(on: queue) { [self] in
                    pump(index, group: group)
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) { [self] in
                finish(completion)
            }
        }

        /// Appends what the input will take, in an autorelease pool per sample, as Shotnix's
        /// `MovieJob` does: without one, every decoded frame stays alive until the queue pauses.
        private func pump(_ index: Int, group: DispatchGroup) {
            let (output, input) = pairs[index]
            while input.isReadyForMoreMediaData {
                guard !lock.withLock({ failed || finished[index] }) else { return }
                if cancellation.isCancelled { return fail(group: group) }
                let appended = autoreleasepool { () -> Bool? in
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    if index == 0 { report(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
                    return input.append(sample)
                }
                switch appended {
                case nil:
                    if writer.status == .writing { input.markAsFinished() }
                    return markFinished(index, group: group)
                case false?:
                    return fail(group: group)
                case true?:
                    continue
                }
            }
        }

        private func markFinished(_ index: Int, group: DispatchGroup) {
            lock.withLock {
                guard !finished[index] else { return }
                finished[index] = true
                group.leave()
            }
        }

        /// Stops both sides once, and leaves the group for every input still copying: a cancelled
        /// writer never asks them for more.
        private func fail(group: DispatchGroup) {
            let isFirst = lock.withLock {
                defer { failed = true }
                return !failed
            }
            guard isFirst else { return }
            reader.cancelReading()
            writer.cancelWriting()
            pairs.indices.forEach { markFinished($0, group: group) }
        }

        private func finish(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
            if cancellation.isCancelled {
                if writer.status == .writing { writer.cancelWriting() }
                return completion(.failure(ScreencastExportFailure.cancelled))
            }
            if lock.withLock({ failed }) || reader.status == .failed {
                if writer.status == .writing { writer.cancelWriting() }
                return completion(.failure(writer.error ?? reader.error ?? ScreencastExportFailure.failed))
            }
            writer.finishWriting { [writer] in
                completion(writer.status == .completed ? .success(()) : .failure(writer.error ?? ScreencastExportFailure.failed))
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
