import AppKit
import AVFoundation

/// The part of a recording a trim keeps, in seconds from its start.
struct ScreencastTrimRange: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { end - start }

    /// Whether it cuts the start, which a passthrough cut can't do cleanly.
    var cutsStart: Bool { start > Self.tolerance }

    /// Within this of either end, a trim keeps that end.
    static let tolerance: TimeInterval = 0.05

    /// What the player's trim kept of a recording `duration` long; nil when it kept all of it, or
    /// nothing.
    init?(start: TimeInterval, end: TimeInterval, within duration: TimeInterval) {
        guard start.isFinite, end.isFinite, duration.isFinite else { return nil }
        let start = max(0, start)
        let end = min(duration, end)
        guard end - start > Self.tolerance,
              start > Self.tolerance || end < duration - Self.tolerance else { return nil }
        self.start = start
        self.end = end
    }

    /// The same range in a file `duration` long, such as another display's, which can end sooner.
    func limited(to duration: TimeInterval) -> ScreencastTrimRange {
        ScreencastTrimRange(exactStart: min(start, duration), end: min(end, duration))
    }

    private init(exactStart start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = max(start, end)
    }
}

/// Cuts a recording's files to a time range. Tests pass a fake that fails on purpose.
protocol ScreencastTrimming: Sendable {
    /// Cuts a display's full recording.
    func cut(_ recording: URL, to destination: URL, range: ScreencastTrimRange) async throws
    /// Cuts its mixdown: `cutRecording` is the recording's cut, already written.
    func cutMixdown(_ mixdown: URL, cutRecording: URL, to destination: URL, range: ScreencastTrimRange) async throws
}

/// The app's cuts. One that keeps the start copies every track as it was (passthrough), which ends
/// cleanly at any frame. One that cuts the start re-encodes the recording from the trim point
/// (`ScreencastTrimEncoder`), since a passthrough cut would keep up to a second before it hidden in
/// the file, and makes the mixdown again from that cut, as the recorder makes it
/// (`ScreencastAudioMixdown`).
struct ScreencastFileTrimmer: ScreencastTrimming {
    func cut(_ recording: URL, to destination: URL, range: ScreencastTrimRange) async throws {
        if range.cutsStart {
            try await ScreencastTrimEncoder.encode(recording, to: destination, range: range)
        } else {
            try await Self.passthrough(recording, to: destination, range: range)
        }
    }

    func cutMixdown(_ mixdown: URL, cutRecording: URL, to destination: URL, range: ScreencastTrimRange) async throws {
        if range.cutsStart {
            try await ScreencastAudioMixdown.write(from: cutRecording, to: destination)
        } else {
            try await Self.passthrough(mixdown, to: destination, range: range)
        }
    }

    private static func passthrough(_ source: URL, to destination: URL, range: ScreencastTrimRange) async throws {
        // Screencast needs macOS 15, as `export(to:as:)` does.
        guard #available(macOS 15, *),
              let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough)
        else { throw ScreencastReviewFailure.trimFailed }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600)
        )
        try await session.export(to: destination, as: destination.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
    }
}

/// The review panel's work on a capture's files: trimming a recording in place, putting a capture
/// on the clipboard, and deleting it.
enum ScreencastReviewFiles {
    /// Replaces every file of `capture`, each display's recording and its mixdown, with the part
    /// `range` keeps, and returns the capture with its new durations.
    ///
    /// The recording stays safe until the trim succeeds. Every cut is written beside its file first,
    /// and if one fails, the cuts are deleted and nothing else changes. Only then are they swapped
    /// in, each original moved aside until all are in place; if a swap fails, the originals already
    /// moved go back. So the folder ends with the whole recording trimmed, or untouched.
    static func trim(
        _ capture: ScreencastCapture,
        to range: ScreencastTrimRange,
        trimmer: any ScreencastTrimming,
        fileManager: FileManager
    ) async throws -> ScreencastCapture {
        // Each display's recording, then its mixdown, which a start cut makes from the recording's cut.
        let files = capture.videos.flatMap { video in
            [(url: video.file, duration: video.duration, cutRecording: URL?.none)]
                + [video.mixdown].compactMap { $0 }.map { (url: $0, duration: video.duration, cutRecording: Optional(sideFile(for: video.file, tag: cutTag))) }
        }
        let cuts = files.map { sideFile(for: $0.url, tag: cutTag) }
        let originals = files.map { sideFile(for: $0.url, tag: originalTag) }

        do {
            for (index, file) in files.enumerated() {
                try? fileManager.removeItem(at: cuts[index])
                let fileRange = range.limited(to: file.duration)
                if let cutRecording = file.cutRecording {
                    try await trimmer.cutMixdown(file.url, cutRecording: cutRecording, to: cuts[index], range: fileRange)
                } else {
                    try await trimmer.cut(file.url, to: cuts[index], range: fileRange)
                }
            }
        } catch {
            for cut in cuts { try? fileManager.removeItem(at: cut) }
            throw ScreencastReviewFailure.trimFailed
        }

        var swapped = 0
        do {
            for (index, file) in files.enumerated() {
                try? fileManager.removeItem(at: originals[index])
                try fileManager.moveItem(at: file.url, to: originals[index])
                do {
                    try fileManager.moveItem(at: cuts[index], to: file.url)
                } catch {
                    try? fileManager.moveItem(at: originals[index], to: file.url)
                    throw error
                }
                swapped += 1
            }
        } catch {
            // Each cut already swapped in is a copy; its original goes back in its place.
            for index in 0..<swapped {
                try? fileManager.removeItem(at: files[index].url)
                try? fileManager.moveItem(at: originals[index], to: files[index].url)
            }
            for cut in cuts { try? fileManager.removeItem(at: cut) }
            throw ScreencastReviewFailure.trimFailed
        }
        for original in originals { try? fileManager.removeItem(at: original) }

        let videos = capture.videos.map { video in
            ScreencastVideo(
                file: video.file,
                mixdown: video.mixdown,
                pixelWidth: video.pixelWidth,
                pixelHeight: video.pixelHeight,
                audioTracks: video.audioTracks,
                duration: range.limited(to: video.duration).duration
            )
        }
        return ScreencastCapture(
            folder: capture.folder,
            videos: videos,
            duration: videos.map(\.duration).max() ?? range.duration,
            endedEarly: capture.endedEarly
        )
    }

    /// A hidden file beside `url` in its folder: `.video-1.trimmed.mov`.
    static func sideFile(for url: URL, tag: String) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(".\(name).\(tag).\(url.pathExtension)")
    }

    static let cutTag = "trimmed"
    static let originalTag = "untrimmed"

    /// What a trim interrupted by a quit or a crash left in each capture's folder: a cut not swapped
    /// in is deleted, and an original moved aside goes back where it was when nothing took its place;
    /// one whose cut did take its place is deleted, as the trim would have.
    static func recoverInterruptedTrims(in capturesFolder: URL, fileManager: FileManager) {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: capturesFolder, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return }
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasPrefix(".") {
                let file = folder.appendingPathComponent(name)
                if visibleName(ofSideFile: name, tag: cutTag) != nil {
                    try? fileManager.removeItem(at: file)
                } else if let visible = visibleName(ofSideFile: name, tag: originalTag) {
                    let original = folder.appendingPathComponent(visible)
                    if fileManager.fileExists(atPath: original.path) {
                        try? fileManager.removeItem(at: file)
                    } else {
                        try? fileManager.moveItem(at: file, to: original)
                    }
                }
            }
        }
    }

    /// `video-1.mov` for `.video-1.trimmed.mov` with the tag `trimmed`; nil for any other name.
    static func visibleName(ofSideFile name: String, tag: String) -> String? {
        guard name.hasPrefix(".") else { return nil }
        let rest = name.dropFirst()
        guard let dot = rest.lastIndex(of: ".") else { return nil }
        let stem = rest[..<dot]
        let fileExtension = rest[rest.index(after: dot)...]
        let suffix = ".\(tag)"
        guard stem.hasSuffix(suffix), stem.count > suffix.count, !fileExtension.isEmpty else { return nil }
        return "\(stem.dropLast(suffix.count)).\(fileExtension)"
    }

    /// Puts the capture on `pasteboard`: a recording as its files, each display's mixdown when it
    /// has one, as Finder copies files; a screenshot as an item per display with the image and its
    /// file, so an app takes whichever it can, as Snapzy's `ClipboardHelper` does (BSD-3-Clause,
    /// see LICENSE.snapzy). `images` are a screenshot's files as they are now, a marked-up copy in
    /// place of its original. They're read before the pasteboard is cleared, so one that can't be
    /// read leaves the clipboard as it was.
    @discardableResult
    static func copy(_ input: ScreencastReviewInput, images: [URL]? = nil, to pasteboard: NSPasteboard) -> Bool {
        switch input {
        case .video(let capture):
            let files = capture.videos.map(\.forSharing)
            guard !files.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(files.map { $0 as NSURL })
        case .screenshot(let screenshot):
            let files = images ?? screenshot.images.map(\.file)
            var items: [NSPasteboardItem] = []
            for file in files {
                guard let png = pngData(of: file) else { return false }
                let item = NSPasteboardItem()
                guard item.setData(png, forType: .png), item.setString(file.absoluteString, forType: .fileURL) else { return false }
                items.append(item)
            }
            guard !items.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(items)
        }
    }

    /// Deletes the capture's folder, and only a folder holding the capture's own files.
    static func delete(_ input: ScreencastReviewInput, fileManager: FileManager) throws {
        let folder = input.folder.standardizedFileURL.path
        guard !input.mediaFiles.isEmpty,
              input.mediaFiles.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == folder }) else {
            throw ScreencastReviewFailure.deleteFailed
        }
        do {
            try fileManager.removeItem(at: input.folder)
        } catch {
            throw ScreencastReviewFailure.deleteFailed
        }
    }

    private static func pngData(of file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        if file.pathExtension.lowercased() == "png" { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}
