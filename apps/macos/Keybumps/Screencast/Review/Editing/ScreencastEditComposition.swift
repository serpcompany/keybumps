import AVFoundation
import CoreImage

/// What a display's edits do to each of its frames: its blurs while they show, then its crop. Core
/// Image only, so the player and the export draw the same frames, and a test can check one.
struct ScreencastFrameEditor: Sendable {
    /// A blur in the frame's pixels, in Core Image's coordinates (from the bottom left).
    struct Blur: Equatable, Sendable {
        let rect: CGRect
        let block: CGFloat
        let time: ScreencastTimeRange
    }

    /// The frame's size in pixels.
    let frameSize: CGSize
    /// The part kept, in Core Image's coordinates: the whole frame without a crop.
    let crop: CGRect
    let blurs: [Blur]

    /// `display`'s crop and blurs on its `pixelWidth` × `pixelHeight` frames. `crops` false shows
    /// the whole frame, for placing the crop over it.
    init(edits: ScreencastRecordingEdits, display: Int, pixelWidth: Int, pixelHeight: Int, crops: Bool = true) {
        let size = CGSize(width: max(pixelWidth, 2), height: max(pixelHeight, 2))
        frameSize = size
        let displayEdits = edits.displays.indices.contains(display) ? edits.displays[display] : ScreencastDisplayEdits()
        let cropFromTop = crops
            ? displayEdits.cropPixels(width: Int(size.width), height: Int(size.height))
            : CGRect(origin: .zero, size: size)
        crop = Self.flipped(cropFromTop, height: size.height)
        blurs = displayEdits.blurs.compactMap { blur in
            let pixels = CGRect(
                x: blur.rect.minX * size.width, y: blur.rect.minY * size.height,
                width: blur.rect.width * size.width, height: blur.rect.height * size.height
            ).standardized.integral.intersection(CGRect(origin: .zero, size: size))
            guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
            return Blur(rect: Self.flipped(pixels, height: size.height), block: blur.strength.blockPixels, time: blur.time)
        }
    }

    /// The edited frame's size in pixels: the crop's.
    var renderSize: CGSize { crop.size }

    /// Whether a frame comes out other than it went in.
    var changesFrames: Bool { !blurs.isEmpty || crop != CGRect(origin: .zero, size: frameSize) }

    /// `frame`, recorded `recordingTime` seconds in, with the blurs showing then and the crop, moved
    /// so the crop starts at the origin.
    func render(_ frame: CIImage, atRecordingTime recordingTime: Double) -> CIImage {
        var image = frame
        for blur in blurs where blur.time.contains(recordingTime) {
            let region = blur.rect.intersection(frame.extent)
            guard !region.isNull, region.width >= 1, region.height >= 1 else { continue }
            image = ScreenshotAnnotationRenderer.mosaic(image.cropped(to: region), block: blur.block).composited(over: image)
        }
        return image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// A rect from the top left in a frame `height` tall, from the bottom left.
    static func flipped(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// One display's video with the recording's edits, as the player plays it and the export writes it:
/// the kept parts one after another (`AVMutableComposition`), with every sound track cut the same,
/// and each frame drawn through `ScreencastFrameEditor` at the recording's time it came from.
///
/// After Shotnix's `VideoCompositionBuilder` and `VideoSourceTracks` (`Video/VideoComposition.swift`,
/// MIT, see LICENSE.shotnix): a track per sound, each placed only where it has media, and the
/// picture through a reader's video composition.
struct ScreencastEditComposition {
    enum CompositionError: Error, Equatable {
        case missingVideoTrack
        case cannotAddTrack
        /// Nothing is kept of this display's video.
        case nothingKept
    }

    /// What times are kept to: about 0.1 ms, finer than any frame or sound packet's edge matters.
    static let timescale: CMTimeScale = 600_000

    let composition: AVMutableComposition
    let videoTrack: AVMutableCompositionTrack
    /// A track per recorded sound, in the file's order.
    let audioTracks: [AVMutableCompositionTrack]
    /// Each sound track's channels, in the same order.
    let audioChannels: [Int]
    let videoComposition: AVMutableVideoComposition
    let editor: ScreencastFrameEditor
    let framesPerSecond: Int

    var duration: CMTime { composition.duration }

    /// `display`'s video at `url` with `edits`. `crops` false keeps the whole frame, for placing the
    /// crop over it.
    static func make(
        source url: URL,
        edits: ScreencastRecordingEdits,
        display: Int,
        crops: Bool = true
    ) async throws -> ScreencastEditComposition {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompositionError.missingVideoTrack
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        let assetDuration = try await asset.load(.duration)
        let videoRange = try await sourceVideo.load(.timeRange)
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let nominalRate = try await sourceVideo.load(.nominalFrameRate)
        var audioRanges: [CMTimeRange] = []
        var audioChannels: [Int] = []
        for track in sourceAudio {
            audioRanges.append(try await track.load(.timeRange))
            let format = try await track.load(.formatDescriptions).first
            let channels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            audioChannels.append(Int(channels ?? 2))
        }

        let kept = edits.keptRanges(within: assetDuration.isNumeric ? assetDuration.seconds : 0)
        guard !kept.isEmpty else { throw CompositionError.nothingKept }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.cannotAddTrack
        }
        let audioTracks = try sourceAudio.map { _ in
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CompositionError.cannotAddTrack
            }
            return track
        }
        var cursor = CMTime.zero
        for range in kept {
            let start = time(range.start)
            let length = CMTimeSubtract(time(range.end), start)
            let piece = CMTimeRange(start: start, duration: length)
            try insert(piece, of: sourceVideo, within: videoRange, into: videoTrack, at: cursor)
            for (index, track) in sourceAudio.enumerated() {
                try insert(piece, of: track, within: audioRanges[index], into: audioTracks[index], at: cursor)
            }
            cursor = CMTimeAdd(cursor, length)
        }

        let framesPerSecond = ScreencastNumbers.framesPerSecond(nominalRate > 1 ? Int(nominalRate.rounded()) : 30)
        let editor = ScreencastFrameEditor(
            edits: edits, display: display,
            pixelWidth: Int(naturalSize.width.rounded()), pixelHeight: Int(naturalSize.height.rounded()),
            crops: crops
        )
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            let recordingTime = kept.recordingTime(forEditedTime: request.compositionTime.seconds) ?? 0
            request.finish(with: editor.render(request.sourceImage, atRecordingTime: recordingTime), context: nil)
        }
        videoComposition.renderSize = editor.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        // The recorder tags its files so; the edited frames keep it.
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return ScreencastEditComposition(
            composition: composition,
            videoTrack: videoTrack,
            audioTracks: audioTracks,
            audioChannels: audioChannels,
            videoComposition: videoComposition,
            editor: editor,
            framesPerSecond: framesPerSecond
        )
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// Puts the part of `piece` where `source` has media at its place after `cursor`: a sound that
    /// started late, or stopped early, leaves silence around it.
    private static func insert(
        _ piece: CMTimeRange,
        of source: AVAssetTrack,
        within media: CMTimeRange,
        into track: AVMutableCompositionTrack,
        at cursor: CMTime
    ) throws {
        let overlap = CMTimeRangeGetIntersection(piece, otherRange: media)
        guard overlap.duration.isNumeric, overlap.duration > .zero else { return }
        let offset = CMTimeSubtract(overlap.start, piece.start)
        try track.insertTimeRange(overlap, of: source, at: CMTimeAdd(cursor, offset))
    }
}
