import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import Keybumps

// MARK: - Pausing

@Suite("Screencast: the pause timeline")
struct ScreencastTimelineTests {
    @Test("Recording time starts at the first frame and is unknown before it")
    func startsAtTheFirstFrame() {
        var timeline = ScreencastTimeline()
        #expect(timeline.time(at: 100) == nil)
        #expect(timeline.duration(at: 100) == 0)
        timeline.start(at: 100)
        timeline.start(at: 200)
        #expect(timeline.origin == 100, "t=0 is set once")
        #expect(timeline.time(at: 99.5) == -0.5)
        #expect(timeline.time(at: 103) == 3)
    }

    @Test("A pause drops what's captured during it and cuts its length from everything after")
    func pausesAreCutOut() {
        var timeline = ScreencastTimeline()
        timeline.start(at: 100)
        timeline.pause(at: 110)
        #expect(timeline.isPaused)
        #expect(timeline.time(at: 109.5) == 9.5, "a sample captured before the pause still lands")
        #expect(timeline.time(at: 112) == nil)
        #expect(timeline.duration(at: 120) == 10, "frozen while paused")
        timeline.resume(at: 130)
        #expect(!timeline.isPaused)
        #expect(timeline.time(at: 125) == nil, "captured during the pause, delivered after it")
        #expect(timeline.time(at: 131) == 11)
        #expect(timeline.duration(at: 135) == 15)
    }

    @Test("Several pauses add up, and pausing twice or resuming unpaused changes nothing")
    func severalPauses() {
        var timeline = ScreencastTimeline()
        timeline.start(at: 0)
        timeline.resume(at: 1)
        timeline.pause(at: 10)
        timeline.pause(at: 12)
        timeline.resume(at: 15)
        timeline.pause(at: 20)
        timeline.resume(at: 22)
        #expect(timeline.pauses.closed == [10..<15, 20..<22])
        #expect(timeline.time(at: 30) == 23)
        #expect(timeline.duration(at: 30) == 23)
    }

    @Test("Paused before the first frame: the pause before t=0 costs the recording nothing")
    func pausedBeforeTheFirstFrame() {
        var timeline = ScreencastTimeline()
        timeline.pause(at: 5)
        timeline.resume(at: 8)
        timeline.start(at: 9)
        #expect(timeline.time(at: 12) == 3)
    }

    @Test("Switched-off stretches are kept by when they began and ended")
    func hostIntervals() {
        var off = ScreencastHostIntervals()
        off.open(at: 3)
        #expect(off.contains(3) && off.contains(1_000))
        #expect(off.total(from: 0, to: 5) == 2)
        off.close(at: 6)
        #expect(!off.contains(6) && off.contains(5.9) && !off.contains(2.9))
        off.open(at: 9)
        off.close(at: 9)
        #expect(off.closed == [3..<6], "an empty stretch leaves nothing")
        #expect(off.total(from: 4, to: 100) == 2)
    }
}

// MARK: - Audio placement

@Suite("Screencast: where audio lands on its track")
struct ScreencastAudioPlacementTests {
    @Test("The first buffer lands on t=0: a late one is padded with silence, an early one trimmed")
    func firstBuffer() {
        #expect(ScreencastAudioPlacement.place(start: 0, duration: 0.02, written: 0) == .init(silence: 0, trim: 0))
        #expect(ScreencastAudioPlacement.place(start: 0.4, duration: 0.02, written: 0) == .init(silence: 0.4, trim: 0))
        let early = ScreencastAudioPlacement.place(start: -0.005, duration: 0.02, written: 0)
        #expect(early?.silence == 0)
        #expect(abs((early?.trim ?? 0) - 0.005) < 1e-9)
    }

    @Test("Drift within the tolerance is left alone; more is filled or trimmed")
    func drift() {
        #expect(ScreencastAudioPlacement.place(start: 1.02, duration: 0.02, written: 1) == .init(silence: 0, trim: 0))
        #expect(ScreencastAudioPlacement.place(start: 0.98, duration: 0.02, written: 1) == nil, "ends before what's written")
        #expect(ScreencastAudioPlacement.place(start: 0.975, duration: 0.1, written: 1) == .init(silence: 0, trim: 0))
        let gap = ScreencastAudioPlacement.place(start: 1.5, duration: 0.02, written: 1)
        #expect(gap.map { abs($0.silence - 0.5) < 1e-9 } == true)
        let overlap = ScreencastAudioPlacement.place(start: 0.9, duration: 0.2, written: 1)
        #expect(overlap.map { abs($0.trim - 0.1) < 1e-9 && $0.silence == 0 } == true)
    }

    @Test("A buffer entirely before t=0 is dropped")
    func beforeTheStart() {
        #expect(ScreencastAudioPlacement.place(start: -1, duration: 0.02, written: 0) == nil)
    }
}

// MARK: - Geometry

@Suite("Screencast: what a stream reads")
struct ScreencastGeometryTests {
    @Test("A whole display at its pixel size")
    func display() {
        let geometry = ScreencastCaptureGeometry.display(size: CGSize(width: 1512, height: 982), scale: 2)
        #expect(geometry.sourceRect == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(geometry.pixelWidth == 3024 && geometry.pixelHeight == 1964)
    }

    @Test("An area snaps to whole, even pixels and stays on the display")
    func area() {
        let geometry = ScreencastCaptureGeometry.area(CGRect(x: 10.3, y: 20.7, width: 100.5, height: 50.25), displaySize: CGSize(width: 1512, height: 982), scale: 2)
        #expect(geometry.pixelWidth % 2 == 0 && geometry.pixelHeight % 2 == 0)
        #expect(geometry.pixelWidth == 202 && geometry.pixelHeight == 102)
        #expect(geometry.sourceRect.width * 2 == CGFloat(geometry.pixelWidth))

        let edge = ScreencastCaptureGeometry.area(CGRect(x: 1400, y: 900, width: 300, height: 300), displaySize: CGSize(width: 1512, height: 982), scale: 1)
        #expect(edge.sourceRect.maxX <= 1512 && edge.sourceRect.maxY <= 982, "clamped to the display")
        #expect(edge.pixelWidth == 112 && edge.pixelHeight == 82)

        let odd = ScreencastCaptureGeometry.area(CGRect(x: 1511, y: 0, width: 1, height: 1), displaySize: CGSize(width: 1512, height: 982), scale: 1)
        #expect(odd.pixelWidth == 2 && odd.sourceRect.maxX <= 1512, "rounding up to even steps back in")
    }

    @Test("A window reads its frame on its display; the part past the edge is left out")
    func window() {
        let display = ScreencastScreens.rightDisplay
        let geometry = ScreencastCaptureGeometry.window(frame: CGRect(x: 1600, y: 100, width: 800, height: 600), displayFrame: display.frame, scale: 1)
        #expect(geometry.sourceRect == CGRect(x: 88, y: 100, width: 800, height: 600))
        let past = ScreencastCaptureGeometry.window(frame: CGRect(x: 3200, y: 100, width: 800, height: 600), displayFrame: display.frame, scale: 1)
        #expect(past.sourceRect.maxX <= 1920 && past.pixelWidth == 232)
    }

    @Test("An area drawn in AppKit's space becomes the display's own, top-left")
    func appKitArea() {
        let screen = CGRect(x: 1512, y: -98, width: 1920, height: 1080)
        let rect = ScreencastTarget.displayLocalRect(fromAppKit: CGRect(x: 1612, y: 682, width: 400, height: 200), screenFrame: screen)
        #expect(rect == CGRect(x: 100, y: 100, width: 400, height: 200))
    }
}

// MARK: - Which windows are in the video

@Suite("Screencast: which windows a recording shows")
struct ScreencastCaptureFilterTests {
    typealias Screens = ScreencastScreens

    @Test("A display leaves out all of Keybumps but its overlays, and only overlays still on screen")
    func display() {
        let content = Screens.content()
        let plan = ScreencastCaptureFilter.displayPlan(display: 1, ownProcessID: Screens.ownProcess, overlays: [31, 99], content: content)
        #expect(plan == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: [31]))
        #expect(!plan.dependsOnWindows(of: Screens.ownProcess), "excluding the app keeps windows it opens later out too")

        let noOverlays = ScreencastCaptureFilter.displayPlan(display: 1, ownProcessID: Screens.ownProcess, overlays: [], content: content)
        #expect(noOverlays == .display(1, excludingProcess: Screens.ownProcess, exceptingWindows: []))
    }

    @Test("When ScreenCaptureKit doesn't list Keybumps, there's nothing to leave out yet, and the filter is rebuilt when it opens windows")
    func ownAppNotListed() {
        let plan = ScreencastCaptureFilter.displayPlan(display: 2, ownProcessID: Screens.ownProcess, overlays: [31], content: Screens.content(includesOwnApp: false))
        #expect(plan == .display(2, excludingProcess: nil, exceptingWindows: []))
        #expect(plan.dependsOnWindows(of: Screens.ownProcess))
    }

    @Test("A window recording names its windows: the window, its sheet and menu, and Keybumps's overlays, never Keybumps's others")
    func window() throws {
        let plan = try #require(ScreencastCaptureFilter.windowPlan(window: 10, ownProcessID: Screens.ownProcess, overlays: [31], content: Screens.content()))
        #expect(plan == .windows(1, includingWindows: [10, 11, 13, 31]), "the app's other window (12) and the control bar (30) stay out")
        #expect(!plan.dependsOnWindows(of: Screens.ownProcess), "a window Keybumps opens can't show, not even for a frame")
    }

    @Test("Without an overlay on screen, nothing of Keybumps is in a window recording's filter")
    func windowWithoutOverlays() throws {
        for overlays: Set<CGWindowID> in [[], [99]] {
            let plan = try #require(ScreencastCaptureFilter.windowPlan(window: 10, ownProcessID: Screens.ownProcess, overlays: overlays, content: Screens.content()))
            #expect(plan == .windows(1, includingWindows: [10, 11, 13]))
        }
    }

    @Test("The app's windows off screen or on another display aren't named")
    func windowOffScreen() throws {
        let hidden = ScreencastContent.Window(id: 14, frame: CGRect(x: 150, y: 150, width: 200, height: 100), layer: 101, processID: Screens.browser, isUntitled: true, isOnScreen: false)
        let elsewhere = ScreencastContent.Window(id: 15, frame: CGRect(x: 1800, y: 150, width: 200, height: 100), layer: 101, processID: Screens.browser, isUntitled: true, isOnScreen: true)
        let content = Screens.content(windows: Screens.content().windows + [hidden, elsewhere])
        let plan = try #require(ScreencastCaptureFilter.windowPlan(window: 10, ownProcessID: Screens.ownProcess, overlays: [], content: content))
        #expect(plan == .windows(1, includingWindows: [10, 11, 13]))
    }

    @Test("A window on the right display records there; a closed one can't be recorded")
    func windowDisplay() {
        let plan = ScreencastCaptureFilter.windowPlan(window: 20, ownProcessID: Screens.ownProcess, overlays: [], content: Screens.content())
        #expect(plan?.displayID == 2)
        #expect(ScreencastCaptureFilter.windowPlan(window: 77, ownProcessID: Screens.ownProcess, overlays: [], content: Screens.content()) == nil)
    }

    @Test("Recording one of Keybumps's own windows leaves its other windows out, overlays apart")
    func ownWindow() {
        let plan = ScreencastCaptureFilter.windowPlan(window: 30, ownProcessID: Screens.ownProcess, overlays: [], content: Screens.content())
        #expect(plan == .windows(1, includingWindows: [30]))
        let withOverlay = ScreencastCaptureFilter.windowPlan(window: 30, ownProcessID: Screens.ownProcess, overlays: [31], content: Screens.content())
        #expect(withOverlay == .windows(1, includingWindows: [30, 31]))
    }

    @Test("Of the app's other windows, only ordinary ones are hidden, and an untitled one over the window stays")
    func windowsToHide() {
        let hidden = ScreencastCaptureFilter.windowsToHide(
            recording: Screens.browserWindow,
            others: [Screens.browserSheet, Screens.browserOtherWindow, Screens.browserMenu]
        )
        #expect(hidden == [12])
    }

    @Test("The display showing most of a window is the one it's recorded on")
    func mostOverlapping() {
        let content = Screens.content()
        #expect(content.display(mostOverlapping: CGRect(x: 1400, y: 100, width: 300, height: 100))?.id == 2)
        #expect(content.display(mostOverlapping: CGRect(x: 1300, y: 100, width: 300, height: 100))?.id == 1)
        #expect(content.display(mostOverlapping: CGRect(x: -900, y: 100, width: 300, height: 100)) == nil)
    }
}

// MARK: - Sample buffers the writer makes

@Suite("Screencast: silence, trimming, and the microphone meter")
struct ScreencastAudioBufferTests {
    @Test("Silence matches the format it pads, starting where asked")
    func silence() throws {
        let format = try #require(ScreencastAudioBuffers.defaultFormat(channels: 2))
        let silence = try #require(ScreencastAudioBuffers.silence(frames: 480, format: format, at: CMTime(value: 4_800, timescale: 48_000)))
        #expect(CMSampleBufferGetNumSamples(silence) == 480)
        #expect(silence.presentationTimeStamp.seconds == 0.1)
        #expect(ScreencastSamples.peak(of: silence) == 0)
        #expect(CMSampleBufferGetFormatDescription(silence) == format)
    }

    @Test("Trimming drops a buffer's first frames and keeps the rest")
    func trim() throws {
        let buffer = ScreencastSamples.audio(at: 0, frames: 1_024, channels: 2, value: 0.25)
        let trimmed = try #require(ScreencastAudioBuffers.dropping(frames: 24, from: buffer, at: .zero))
        #expect(CMSampleBufferGetNumSamples(trimmed) == 1_000)
        #expect(ScreencastSamples.peak(of: trimmed) == 0.25)
        #expect(ScreencastAudioBuffers.dropping(frames: 1_024, from: buffer, at: .zero) == nil)
    }

    @Test("Converting stereo to mono mixes both channels, so a microphone on the second input is kept")
    func downmix() throws {
        let mono = try #require(ScreencastAudioBuffers.defaultFormat(channels: 1))
        let rightOnly = ScreencastSamples.audio(at: 0, channelValues: [0, 0.5])
        let converted = try #require(ScreencastAudioConformer().conform(rightOnly, to: mono))
        #expect(ScreencastSamples.peak(of: converted) > 0.2)
        let leftOnly = ScreencastSamples.audio(at: 0, channelValues: [0.5, 0])
        #expect(ScreencastSamples.peak(of: try #require(ScreencastAudioConformer().conform(leftOnly, to: mono))) > 0.2)
    }

    @Test("More than two channels with no layout can't be converted, and nothing crashes; with a layout they can")
    func multichannel() throws {
        let mono = try #require(ScreencastAudioBuffers.defaultFormat(channels: 1))
        let noLayout = ScreencastSamples.audio(at: 0, channelValues: [0.5, 0.5, 0.5, 0.5])
        let noLayoutFormat = try #require(CMSampleBufferGetFormatDescription(noLayout))
        #expect(!ScreencastAudioBuffers.canConvert(noLayoutFormat))
        #expect(ScreencastAudioConformer().conform(noLayout, to: mono) == nil)
        #expect(ScreencastAudioBuffers.silence(frames: 10, format: noLayoutFormat, at: .zero) == nil)

        let withLayout = ScreencastSamples.audio(at: 0, channelValues: [0.5, 0.5, 0.5, 0.5], discreteLayout: true)
        #expect(ScreencastAudioBuffers.canConvert(try #require(CMSampleBufferGetFormatDescription(withLayout))))
        let converted = try #require(ScreencastAudioConformer().conform(withLayout, to: mono))
        #expect(CMSampleBufferGetNumSamples(converted) == ScreencastSamples.audioFrames)
    }

    @Test("The meter reads silence as 0, loud speech as 1, and quiet speech in between")
    func level() {
        #expect(ScreencastAudioBuffers.level(of: ScreencastSamples.audio(at: 0, value: 0)) == 0)
        #expect(ScreencastAudioBuffers.level(of: ScreencastSamples.audio(at: 0, value: 0.9)) == 1)
        let quiet = ScreencastAudioBuffers.level(of: ScreencastSamples.audio(at: 0, channels: 1, value: 0.01))
        #expect(quiet > 0.2 && quiet < 0.4, "-40 dB")
        #expect(ScreencastAudioBuffers.normalizedLevel(rms: 0.001) == 0, "-60 dB is room hiss")
    }
}

// MARK: - Encoding

@Suite("Screencast: how files are encoded")
struct ScreencastVideoFormatTests {
    @Test("H.264 up to what level 5.2 takes, HEVC above it")
    func codec() {
        #expect(ScreencastVideoFormat.plan(pixelWidth: 3024, pixelHeight: 1964, framesPerSecond: 30).codec == .h264)
        #expect(ScreencastVideoFormat.plan(pixelWidth: 3456, pixelHeight: 2234, framesPerSecond: 60).codec == .h264)
        #expect(ScreencastVideoFormat.plan(pixelWidth: 5120, pixelHeight: 2880, framesPerSecond: 30).codec == .hevc)
        #expect(ScreencastVideoFormat.plan(pixelWidth: 4096, pixelHeight: 2304, framesPerSecond: 60).codec == .hevc, "too many macroblocks a second")
    }

    @Test("The mixdown plays each sound at 1/N, so two at full scale can't clip")
    func mixdownVolume() {
        #expect(ScreencastAudioMixdown.inputVolume(audioTrackCount: 1) == 1)
        #expect(ScreencastAudioMixdown.inputVolume(audioTrackCount: 2) == 0.5)
        #expect(abs(ScreencastAudioMixdown.inputVolume(audioTrackCount: 3) - 1.0 / 3) < 1e-6)
    }

    @Test("The bit rate grows with the picture and stays between 2 and 40 Mbit/s")
    func bitRate() {
        #expect(ScreencastVideoFormat.bitRate(pixelWidth: 64, pixelHeight: 36, framesPerSecond: 30, hevc: false) == 2_000_000)
        #expect(ScreencastVideoFormat.bitRate(pixelWidth: 3024, pixelHeight: 1964, framesPerSecond: 30, hevc: false) == 14_253_926)
        #expect(ScreencastVideoFormat.bitRate(pixelWidth: 6016, pixelHeight: 3384, framesPerSecond: 60, hevc: true) == 40_000_000)
    }
}

// MARK: - meta.json

@Suite("Screencast: a capture's meta.json")
struct ScreencastMetadataTests {
    @Test("Structure only: the target's kind, durations, tracks, and file names Keybumps chose")
    func structureOnly() throws {
        let folder = TemporaryCapturesFolder()
        defer { folder.remove() }
        let capture = ScreencastCapture(
            folder: folder.url,
            videos: [
                ScreencastVideo(
                    file: folder.url.appendingPathComponent("video-1.mov"),
                    mixdown: folder.url.appendingPathComponent("video-1-mixdown.mp4"),
                    pixelWidth: 1600, pixelHeight: 1200,
                    audioTracks: [.microphone, .systemAudio],
                    duration: 30.5
                )
            ],
            duration: 30.5,
            endedEarly: nil
        )
        let metadata = ScreencastMetadata(capture: capture, target: .window(4_242), startedAt: Date(timeIntervalSince1970: 1_791_000_000))
        try metadata.write(to: capture.metadataURL)

        let text = try String(contentsOf: capture.metadataURL, encoding: .utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "startedAt", "target", "duration", "displayCount", "videos"])
        #expect(object["target"] as? String == "window")
        #expect(!text.contains("4242"), "no window ID")
        let video = try #require((object["videos"] as? [[String: Any]])?.first)
        #expect(video["tracks"] as? [String] == ["video", "microphone", "systemAudio"])
        #expect(video["file"] as? String == "video-1.mov")
        #expect(try ScreencastMetadata.read(from: capture.metadataURL) == metadata)
    }

    @Test("Folders are named by the start time, with a suffix for a second one in the same second")
    func folderNames() throws {
        let folder = TemporaryCapturesFolder()
        defer { folder.remove() }
        let date = Date(timeIntervalSince1970: 1_791_000_000.6)
        let first = try ScreencastCaptureFolder.create(in: folder.url, startedAt: date, fileManager: .default)
        let second = try ScreencastCaptureFolder.create(in: folder.url, startedAt: date, fileManager: .default)
        #expect(first.lastPathComponent == "1791000000")
        #expect(second.lastPathComponent == "1791000000-2")
        #expect(ScreencastCaptureFolder.videoName(index: 1) == "video-2.mov")
        #expect(ScreencastCaptureFolder.mixdownName(index: 0) == "video-1-mixdown.mp4")
    }
}
