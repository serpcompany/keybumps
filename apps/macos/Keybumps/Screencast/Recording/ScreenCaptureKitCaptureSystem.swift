import AppKit
import CoreMedia
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

    func content() async throws -> ScreencastContent {
        // Every window, not just those on screen, so Keybumps is listed as an app (and can be
        // excluded whole) even before its overlays appear.
        try await content(onScreenOnly: false)
    }

    func content(onScreenOnly: Bool) async throws -> ScreencastContent {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)
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

    func onScreenWindows(of processID: pid_t) -> Set<CGWindowID>? {
        // Window numbers and owners only; no window's name is read.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return Set(list.compactMap { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == processID ? info[kCGWindowNumber as String] as? CGWindowID : nil
        })
    }

    func onScreenPanelServiceWindows() -> Set<CGWindowID>? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return Set(list.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, isPanelService(owner) else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        })
    }

    func windowExists(_ id: CGWindowID) -> Bool? {
        // Listed whatever its on-screen state; a closed window isn't.
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return !list.isEmpty
    }

    /// Process IDs already told apart, so the 20 Hz read looks each one up once.
    private var panelServiceProcesses: [pid_t: Bool] = [:]

    private func isPanelService(_ processID: pid_t) -> Bool {
        if let known = panelServiceProcesses[processID] { return known }
        let bundleID = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        let isService = bundleID.map(ScreencastContent.panelServiceBundleIDs.contains) ?? false
        panelServiceProcesses[processID] = isService
        return isService
    }

    func ownVisibleWindows() -> Set<CGWindowID> {
        Set(NSApplication.shared.windows.filter { $0.isVisible && $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
    }

    // MARK: Building ScreenCaptureKit objects

    static func snapshot(of content: SCShareableContent) -> ScreencastContent {
        // Front to back, numbers only, for telling a sheet in front of its window.
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, info) in onScreen.enumerated() {
            if let id = info[kCGWindowNumber as String] as? CGWindowID, order[id] == nil { order[id] = index }
        }
        return ScreencastContent(
            displays: content.displays.map { display in
                ScreencastContent.Display(
                    id: display.displayID,
                    frame: display.frame,
                    scale: max(CGFloat(SCContentFilter(display: display, excludingWindows: []).pointPixelScale), 1)
                )
            },
            windows: content.windows.compactMap { window in
                guard let processID = window.owningApplication?.processID else { return nil }
                return ScreencastContent.Window(
                    id: window.windowID,
                    frame: window.frame,
                    layer: window.windowLayer,
                    processID: processID,
                    isUntitled: (window.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                    isOnScreen: window.isOnScreen,
                    order: order[window.windowID],
                    isPanelService: window.owningApplication.map { ScreencastContent.panelServiceBundleIDs.contains($0.bundleIdentifier) } ?? false
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

    static func streamConfiguration(_ configuration: ScreencastStreamConfiguration) -> SCStreamConfiguration {
        let stream = SCStreamConfiguration()
        stream.width = configuration.pixelWidth
        stream.height = configuration.pixelHeight
        stream.sourceRect = configuration.sourceRect
        stream.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(configuration.framesPerSecond, 1)))
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
        let frameBytes = max(pixelWidth * pixelHeight * 4, 1)
        return min(max(300_000_000 / frameBytes, 4), 6)
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

    func onScreenWindows(of processID: pid_t) -> Set<CGWindowID>? { nil }

    func ownVisibleWindows() -> Set<CGWindowID> { [] }
}
