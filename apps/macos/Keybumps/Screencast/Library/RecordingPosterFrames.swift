import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A still for each indexed recording, for the ⌘3 tab (#494): its first video's opening frame,
/// made by `AVAssetImageGenerator` off the main actor (#325's lesson: decoding video on the main
/// thread froze the palette), cached as a JPEG in Keybumps's Caches folder, and made again when the
/// cached file is gone. It's a picture of the screen, so it's written readable only by the person
/// (`PrivateFile`), and removed with its entry. A frame no entry names is swept when the index loads.
struct RecordingPosterFrames: Sendable {
    /// `~/Library/Caches/Keybumps/RecordingPosters`, through `ProductPaths` so tests keep theirs in
    /// their own folder.
    let folder: URL
    /// The longest side, in pixels: big enough for a tile at 2x.
    static let maximumPixels = 640

    static var defaultFolder: URL {
        ProductPaths.keybumps().caches.appendingPathComponent("RecordingPosters", isDirectory: true)
    }

    /// Where the recording's poster frame is cached; nil when its name isn't one in the cache
    /// (`IndexedRecording.isFileName`).
    func url(for recording: IndexedRecording) -> URL? {
        IndexedRecording.isFileName(recording.posterFrame) ? folder.appendingPathComponent(recording.posterFrame) : nil
    }

    /// The cached poster frame, made first when it's missing; nil when the video can't be read.
    func make(for recording: IndexedRecording) async -> URL? {
        guard let destination = url(for: recording) else { return nil }
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let video = recording.videoURLs.first else { return nil }
        return await Task.detached(priority: .utility) {
            await Self.render(video, to: destination) ? destination : nil
        }.value
    }

    func remove(for recording: IndexedRecording) {
        guard let url = url(for: recording) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes each file in the cache that `kept` doesn't name and that was last written before
    /// `cutoff`, so a frame made while this runs is never taken. It reads the folder, so it runs off
    /// the main actor. Returns how many it deleted.
    func removeAll(except kept: Set<String>, writtenBefore cutoff: Date) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        var removed = 0
        for file in files where !kept.contains(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let written = values.contentModificationDate, written < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    private static func render(_ video: URL, to destination: URL) async -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixels, height: maximumPixels)
        guard let (image, _) = try? await generator.image(at: .zero),
              let data = jpeg(image) else { return false }
        return (try? PrivateFile.write(data, to: destination)) != nil
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(target) ? data as Data : nil
    }
}
