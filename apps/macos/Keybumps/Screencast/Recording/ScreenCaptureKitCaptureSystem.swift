import AppKit
import CoreMedia
import OSLog
import ScreenCaptureKit

/// The app's capture system: `SCShareableContent` for what's on screen and an `SCStream` per
/// display, plus one display-wide stream for the sound.
///
/// The sound stream is adapted from BetterCapture's `SystemAudioStream` (MIT, see
/// LICENSE.bettercapture): a stream's sound is scoped by its video filter, so a window's stream
/// would hear only its own app. A full-display filter with a throwaway 2×2 picture hears the whole
/// Mac, and carries the microphone too, so every target and every display's file gets the same
/// sound. The video streams follow Screendrop's `ScreenRecordingCapture` (CC0-1.0, see
/// LICENSE.screendrop).
@available(macOS 15, *)
@MainActor
final class ScreenCaptureKitCaptureSystem: ScreencastCaptureSystem {
    /// The real system, except in the unit-test host, where a test that forgets to inject a fake
    /// still can't capture the screen or open the microphone.
    static var current: any ScreencastCaptureSystem {
        UnitTestHost.isActive ? InertScreencastCaptureSystem() : ScreenCaptureKitCaptureSystem()
    }

    private let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")
    /// How many of Keybumps's window numbers the last read left out, so a count is logged once.
    private var loggedDroppedWindowNumbers = 0

    func content() async throws -> ScreencastContent {
        // Every window, not just those on screen, so Keybumps is listed as an app (and can be
        // excluded whole) even before its overlays appear.
        try await content(onScreenOnly: false, includesDesktop: true)
    }

    func content(onScreenOnly: Bool, includesDesktop: Bool) async throws -> ScreencastContent {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(!includesDesktop, onScreenWindowsOnly: onScreenOnly)
            return Self.snapshot(of: content)
        } catch {
            throw Self.failure(for: error)
        }
    }

    func makeVideoStream(
        plan: ScreencastFilterPlan,
        configuration: ScreencastStreamConfiguration,
        content: ScreencastContent,
        handler: ScreencastSampleHandler
    ) throws -> any ScreencastStream {
        let filter = try Self.filter(for: plan, in: content)
        let streamConfiguration = Self.streamConfiguration(configuration)
        let output = ScreenCaptureKitStreamOutput(handler: handler, deliversVideo: true)
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.videoQueue)
        } catch {
            throw Self.failure(for: error)
        }
        return ScreenCaptureKitStream(stream: stream, output: output, configuration: streamConfiguration)
    }

    func makeAudioStream(
        audio: ScreencastAudio,
        content: ScreencastContent,
        handler: ScreencastSampleHandler
    ) throws -> any ScreencastStream {
        guard let source = content.source as? SCShareableContent,
              let display = source.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? source.displays.first else {
            throw ScreencastFailure.targetUnavailable
        }
        // Sound isn't scoped by display, so any display hears the whole Mac.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = audio.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = audio.microphone
        // The picture is unused: as small and as slow as ScreenCaptureKit accepts.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3

        let output = ScreenCaptureKitStreamOutput(handler: handler, deliversVideo: false)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            if audio.systemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.audioQueue)
            }
            if audio.microphone {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.audioQueue)
            }
            // SCStream renders a picture whatever's asked, and logs every frame it can't hand to a
            // screen output: take the frames and drop them, off the audio queue.
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.videoQueue)
        } catch {
            throw Self.failure(for: error)
        }
        return ScreenCaptureKitStream(stream: stream, output: output, configuration: configuration)
    }

    func windowFrame(_ id: CGWindowID) -> CGRect? {
        // Bounds and on-screen state only; the window's name is never read.
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return frame
    }

    func onScreenWindows(of processID: pid_t) -> Set<ScreencastWatchedWindow>? {
        // Window numbers, owners, and layers, and whether each has a name; the name itself isn't
        // kept. Every app's windows are read, to tell whether names can be read at all.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let owners = list.map { $0[kCGWindowOwnerPID as String] as? pid_t }
        let untitled = Self.untitled(
            zip(owners, list).map { (processID: $0, name: $1[kCGWindowName as String] as? String) },
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        )
        var windows = Set<ScreencastWatchedWindow>()
        for (index, info) in list.enumerated() where owners[index] == processID {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            // A layer that can't be read counts as below the windows: never attached UI.
            let layer = info[kCGWindowLayer as String] as? Int ?? Int.min
            windows.insert(ScreencastWatchedWindow(id: id, isUntitled: untitled[index], layer: layer))
        }
        return windows
    }

    func windowExists(_ id: CGWindowID) -> Bool? {
        // Listed whatever its on-screen state; a closed window isn't.
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return !list.isEmpty
    }

    func ownVisibleWindows() -> Set<CGWindowID> {
        // QA 4030.329.2 trapped converting one of these numbers: the value didn't fit a
        // `CGWindowID`, and why is unconfirmed. A number that's 0, negative, or doesn't fit is now
        // left out, and how many were is logged when that count changes (a count only), so a
        // candidate shows whether it recurs without a line every tick.
        let read = ScreencastNumbers.windowIDs(NSApplication.shared.windows.compactMap { $0.isVisible ? $0.windowNumber : nil })
        if read.dropped != loggedDroppedWindowNumbers {
            if read.dropped > 0 {
                logger.error("screencast own window numbers dropped count=\(read.dropped, privacy: .public)")
            }
            loggedDroppedWindowNumbers = read.dropped
        }
        return read.ids
    }

    // MARK: Building ScreenCaptureKit objects

    /// Whether a window's title or name is empty.
    static func isUntitled(_ title: String?) -> Bool {
        (title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether each window of one read is untitled, from its title (`SCWindow.title`) or name
    /// (`kCGWindowName`): one rule for both reads, so the watch and the filter agree. A read in
    /// which no window but Keybumps's (`ownProcessID`, whose names are always readable) has a name
    /// couldn't read names at all, as `CGWindowList` can't without Screen Recording access: every
    /// window in it then counts as titled, so none is taken for UI attached to the recorded window.
    static func untitled(_ windows: [(processID: pid_t?, name: String?)], ownProcessID: pid_t) -> [Bool] {
        let namesReadable = windows.contains { $0.processID != ownProcessID && !isUntitled($0.name) }
        return windows.map { namesReadable && isUntitled($0.name) }
    }

    static func snapshot(of content: SCShareableContent) -> ScreencastContent {
        let untitled = Self.untitled(
            content.windows.map { (processID: $0.owningApplication?.processID, name: $0.title) },
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        )
        return ScreencastContent(
            displays: content.displays.map { display in
                ScreencastContent.Display(
                    id: display.displayID,
                    frame: display.frame,
                    scale: Self.scale(SCContentFilter(display: display, excludingWindows: []).pointPixelScale)
                )
            },
            windows: zip(content.windows, untitled).compactMap { window, isUntitled in
                guard let processID = window.owningApplication?.processID else { return nil }
                return ScreencastContent.Window(
                    id: window.windowID,
                    frame: window.frame,
                    layer: window.windowLayer,
                    processID: processID,
                    isUntitled: isUntitled,
                    isOnScreen: window.isOnScreen
                )
            },
            applicationProcessIDs: Set(content.applications.map(\.processID)),
            source: content
        )
    }

    static func filter(for plan: ScreencastFilterPlan, in content: ScreencastContent) throws -> SCContentFilter {
        guard let source = content.source as? SCShareableContent,
              let display = source.displays.first(where: { $0.displayID == plan.displayID }) else {
            throw ScreencastFailure.targetUnavailable
        }
        switch plan {
        case .display(_, let excludedProcess, let exceptingWindows):
            return SCContentFilter(
                display: display,
                excludingApplications: source.applications.filter { $0.processID == excludedProcess },
                exceptingWindows: source.windows.filter { exceptingWindows.contains($0.windowID) }
            )
        case .windows(_, let windows):
            return SCContentFilter(display: display, including: source.windows.filter { windows.contains($0.windowID) })
        }
    }

    /// Pixels per point: 1 to 8, and 1 for a scale that isn't a number.
    static func scale(_ pointPixelScale: Float) -> CGFloat {
        pointPixelScale.isFinite ? CGFloat(min(max(pointPixelScale, 1), 8)) : 1
    }

    static func streamConfiguration(_ configuration: ScreencastStreamConfiguration) -> SCStreamConfiguration {
        let stream = SCStreamConfiguration()
        stream.width = configuration.pixelWidth
        stream.height = configuration.pixelHeight
        stream.sourceRect = configuration.sourceRect
        // At most 120, so it always fits a `CMTimeScale`.
        stream.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ScreencastNumbers.framesPerSecond(configuration.framesPerSecond)))
        stream.queueDepth = queueDepth(pixelWidth: configuration.pixelWidth, pixelHeight: configuration.pixelHeight)
        stream.pixelFormat = kCVPixelFormatType_32BGRA
        // Frames come in sRGB, which the writer tags its files with.
        stream.colorSpaceName = CGColorSpace.sRGB
        stream.captureResolution = .best
        stream.showsCursor = configuration.showsCursor
        stream.showMouseClicks = configuration.showsMouseClicks
        stream.scalesToFit = configuration.scalesToFit
        stream.includeChildWindows = configuration.includesChildWindows
        stream.preservesAspectRatio = true
        stream.capturesAudio = false
        return stream
    }

    /// Frames waiting for the encoder, capped by memory: eight 5K frames alone would hold almost
    /// half a gigabyte. From Shotnix's `RecordingVideoFormat.queueDepth` (MIT, see LICENSE.shotnix),
    /// with at least four: the writer keeps its last frame for the end of the file, and the
    /// recorder the newest one for a restart, so two can be held while paused.
    static func queueDepth(pixelWidth: Int, pixelHeight: Int) -> Int {
        // In floating point, so no size can overflow.
        let frameBytes = max(Double(pixelWidth) * Double(pixelHeight) * 4, 1)
        return ScreencastNumbers.int(300_000_000 / frameBytes, in: 4...6, fallback: 4)
    }

    nonisolated static func failure(for error: Error) -> ScreencastFailure {
        if let failure = error as? ScreencastFailure { return failure }
        guard let code = (error as? SCStreamError)?.code else { return .captureFailed }
        switch code {
        case .userDeclined: return .screenRecordingDenied
        case .userStopped, .systemStoppedStream: return .stoppedByMacOS
        case .noCaptureSource, .noDisplayList, .noWindowList: return .targetUnavailable
        default: return .captureFailed
        }
    }
}

/// A running `SCStream`.
@available(macOS 15, *)
@MainActor
private final class ScreenCaptureKitStream: ScreencastStream {
    private let stream: SCStream
    private let output: ScreenCaptureKitStreamOutput
    private let configuration: SCStreamConfiguration

    init(stream: SCStream, output: ScreenCaptureKitStreamOutput, configuration: SCStreamConfiguration) {
        self.stream = stream
        self.output = output
        self.configuration = configuration
    }

    func start() async throws {
        do {
            try await stream.startCapture()
        } catch {
            throw ScreenCaptureKitCaptureSystem.failure(for: error)
        }
    }

    func stop() async {
        output.markStopping()
        // A stream that already stopped on its own throws here, which is what was wanted.
        try? await stream.stopCapture()
    }

    func update(plan: ScreencastFilterPlan, content: ScreencastContent) async throws {
        let filter = try ScreenCaptureKitCaptureSystem.filter(for: plan, in: content)
        do {
            try await stream.updateContentFilter(filter)
        } catch {
            throw ScreenCaptureKitCaptureSystem.failure(for: error)
        }
    }

    func update(sourceRect: CGRect) async throws {
        configuration.sourceRect = sourceRect
        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            throw ScreenCaptureKitCaptureSystem.failure(for: error)
        }
    }
}

/// Receives a stream's samples on its queues and passes them on. Frames that carry no new picture
/// (idle, blank, suspended) are dropped.
@available(macOS 15, *)
private final class ScreenCaptureKitStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let handler: ScreencastSampleHandler
    let deliversVideo: Bool
    let videoQueue: DispatchQueue
    let audioQueue = DispatchQueue(label: "com.serp.keybumps.screencast.audio", qos: .userInteractive)
    /// Set on the main actor before `stopCapture` and read on ScreenCaptureKit's delegate queue, so
    /// the error a deliberate stop may raise isn't reported.
    private let lock = NSLock()
    private var isStopping = false

    func markStopping() {
        lock.withLock { isStopping = true }
    }

    init(handler: ScreencastSampleHandler, deliversVideo: Bool) {
        self.handler = handler
        self.deliversVideo = deliversVideo
        videoQueue = DispatchQueue(
            label: "com.serp.keybumps.screencast.video",
            qos: deliversVideo ? .userInteractive : .utility
        )
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard deliversVideo, Self.isNewFrame(sampleBuffer) else { return }
            handler.video(sampleBuffer)
        case .audio:
            handler.audio(sampleBuffer, .systemAudio)
        case .microphone:
            handler.audio(sampleBuffer, .microphone)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !lock.withLock({ isStopping }) else { return }
        handler.stopped(ScreenCaptureKitCaptureSystem.failure(for: error))
    }

    private static func isNewFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return true }
        return status == .complete
    }
}

/// A capture system that captures nothing: the unit-test host's default, so no test can start a
/// real capture.
@MainActor
final class InertScreencastCaptureSystem: ScreencastCaptureSystem {
    func content() async throws -> ScreencastContent {
        throw ScreencastFailure.captureFailed
    }

    func makeVideoStream(
        plan: ScreencastFilterPlan,
        configuration: ScreencastStreamConfiguration,
        content: ScreencastContent,
        handler: ScreencastSampleHandler
    ) throws -> any ScreencastStream {
        throw ScreencastFailure.captureFailed
    }

    func makeAudioStream(audio: ScreencastAudio, content: ScreencastContent, handler: ScreencastSampleHandler) throws -> any ScreencastStream {
        throw ScreencastFailure.captureFailed
    }

    func windowFrame(_ id: CGWindowID) -> CGRect? { nil }

    func onScreenWindows(of processID: pid_t) -> Set<ScreencastWatchedWindow>? { nil }

    func ownVisibleWindows() -> Set<CGWindowID> { [] }
}
