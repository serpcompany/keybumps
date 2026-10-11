#if DEBUG
import AppKit
import AVFoundation
import SwiftUI

// UI test mode's `-KBUITestScreencastReview video|screenshot`: Screencast's review panel on a
// capture made up in the sandbox's captures folder, as the flow controller would save one, since
// UI tests can't record the screen. Debug builds only, like the rest of UI test mode.

extension AppModel {
    /// Opens the review panel on a made-up capture, through the same flow a saved capture takes
    /// (with the UI-test composition's inert context reader). When the panel is done, a small
    /// window says what happened to the capture (`ScreencastReviewUITestOutcome`).
    func showScreencastReviewForUITesting(_ kind: UITestLaunchConfiguration.ScreencastReviewCapture) {
        guard isLicensed, preferences.enabledCapabilities.contains(.screencast),
              let module = capabilities.module(for: .screencast) as? ScreencastModule else { return }
        let capturesFolder = preferences.screencast.capturesFolder
        Task { @MainActor in
            guard let result = await ScreencastReviewUITestCapture.make(kind, in: capturesFolder) else { return }
            // So the outcome counts only what Copy put there.
            NSPasteboard.keybumps.clearContents()
            module.review.onFinish = { outcome in ScreencastReviewUITestOutcome.show(outcome, of: result) }
            module.review.captureStarting()
            module.review.captureFinished(result)
        }
    }
}

/// A made-up capture in its own `<timestamp>` folder: a one-second silent video of a changing
/// gray, or a PNG, each with its `meta.json`.
@MainActor
enum ScreencastReviewUITestCapture {
    static let videoSize = (width: 64, height: 36)

    static func make(_ kind: UITestLaunchConfiguration.ScreencastReviewCapture, in capturesFolder: URL) async -> ScreencastCaptureResult? {
        let fileManager = FileManager.default
        let now = Date()
        guard (try? fileManager.createDirectory(at: capturesFolder, withIntermediateDirectories: true)) != nil,
              let folder = try? ScreencastCaptureFolder.create(in: capturesFolder, startedAt: now, fileManager: fileManager) else { return nil }
        switch kind {
        case .screenshot:
            let file = folder.appendingPathComponent(ScreencastCaptureFolder.screenshotName(index: 0))
            guard let sample = UITestSandbox.writeSampleImage(in: folder),
                  (try? fileManager.moveItem(at: sample, to: file)) != nil else { return nil }
            let screenshot = ScreencastScreenshot(folder: folder, images: [.init(file: file, pixelWidth: 320, pixelHeight: 200)])
            try? ScreencastScreenshotMetadata(screenshot: screenshot, target: .display(9_001), startedAt: now).write(to: screenshot.metadataURL)
            return .screenshot(screenshot)
        case .video:
            let file = folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 0))
            guard await writeVideo(to: file) else { return nil }
            let video = ScreencastVideo(
                file: file, mixdown: nil, pixelWidth: videoSize.width, pixelHeight: videoSize.height, audioTracks: [], duration: 1
            )
            let capture = ScreencastCapture(folder: folder, videos: [video], duration: 1, endedEarly: nil)
            try? ScreencastMetadata(capture: capture, target: .display(9_001), startedAt: now).write(to: capture.metadataURL)
            return .video(capture)
        }
    }

    /// One second at 30 frames a second, H.264, no sound.
    private static func writeVideo(to url: URL) async -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoSize.width,
            kCVPixelBufferHeightKey as String: videoSize.height,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                writer.cancelWriting()
                return false
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 + frame * 6), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                writer.cancelWriting()
                return false
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        return writer.status == .completed
    }
}

/// What the review panel did with the capture, in a small window of its own, since a UI test can't
/// read the sandbox or the pasteboard: `saved; folder kept; note <the note>; clipboard <items>`.
@MainActor
enum ScreencastReviewUITestOutcome {
    static let identifier = "screencast.review.uitest.outcome"
    private static var window: NSPanel?

    static func show(_ outcome: ScreencastReviewOutcome, of result: ScreencastCaptureResult) {
        let text = describe(outcome, of: result)
        let panel = window ?? NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 480, height: 44),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Review outcome"
        panel.identifier = NSUserInterfaceItemIdentifier("\(identifier)Window")
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: Text(text).padding(8).accessibilityIdentifier(identifier))
        panel.orderFrontRegardless()
        window = panel
    }

    static func describe(_ outcome: ScreencastReviewOutcome, of result: ScreencastCaptureResult) -> String {
        let name = switch outcome {
        case .saved: "saved"
        case .copied: "copied"
        case .discarded: "discarded"
        }
        let folder = FileManager.default.fileExists(atPath: result.folder.path) ? "kept" : "deleted"
        let note = ScreencastReview.read(from: result.folder.appendingPathComponent(ScreencastMetadata.fileName))?.note
        let items = NSPasteboard.keybumps.pasteboardItems?.count ?? 0
        return "\(name); folder \(folder); note \(note.map { $0.isEmpty ? "empty" : $0 } ?? "none"); clipboard \(items)"
    }
}
#endif
