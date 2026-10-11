import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// A recording's review in its bigger window (#475): it opens for a recording and not for a
/// screenshot, stays after Save or Copy to say where the recording is, reveals the capture's folder,
/// and plays and pauses on Space. Made-up captures in a temporary folder, a named pasteboard, and no
/// window ordered in or made key.
@MainActor
@Suite("Screencast: a recording's review window")
struct ScreencastRecordingReviewTests {
    let fixture = ReviewFixture()

    private func panel(
        trimmer: any ScreencastTrimming = FakeTrimmer(),
        outcomes: ReviewOutcomeLog,
        revealed: RevealLog = RevealLog(),
        makePlayback: @escaping @MainActor () -> ScreencastReviewPlayback? = { nil }
    ) -> ScreencastReviewPanel {
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            trimmer: trimmer,
            screenshots: { nil },
            settings: ScreencastReviewSettings(defaults: fixture.defaults),
            screen: { nil },
            makePlayback: makePlayback,
            revealInFinder: { revealed.selections.append($0) }
        )
        panel.onFinish = { outcomes.outcomes.append($0) }
        return panel
    }

    /// The window's SwiftUI view, while it shows a recording.
    private func windowView(of panel: ScreencastReviewPanel) -> ScreencastRecordingReviewView? {
        (panel.recordingWindow.contentView as? NSHostingView<ScreencastRecordingReviewView>)?.rootView
    }

    /// Lets the main actor run until `condition` holds, for two seconds at most.
    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    // MARK: Which review opens

    @Test("A recording opens in the bigger window, on the panel's model; a screenshot keeps the panel")
    func recordingOpensTheWindow() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes)
        let recording = try fixture.video()
        await panel.show(recording)
        let view = try #require(windowView(of: panel), "the window shows the recording")
        #expect(view.model === panel.model, "its sidebar and bottom bar act on the review's model")
        #expect(!(panel.panel.contentView is NSHostingView<ScreencastReviewView>), "not in the panel")
        #expect(panel.isShown && !panel.recordingWindow.isVisible, "never on screen under the unit-test host")

        let screenshot = try fixture.screenshot(name: "1791000100")
        await panel.show(screenshot)
        #expect(outcomes.outcomes == [.saved(recording)], "the next capture closes the window, which saves")
        #expect(panel.panel.contentView is NSHostingView<ScreencastReviewView>, "a screenshot keeps the panel")
        #expect(panel.model?.input == screenshot && !panel.recordingWindow.isVisible)
        await panel.close()
    }

    @Test("The window is a standard, resizable window with a minimum size, never key under the unit-test host")
    func windowShell() {
        let window = ScreencastRecordingReviewWindow()
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(!window.styleMask.contains(.nonactivatingPanel))
        #expect(window.level == .normal && window.collectionBehavior.contains(.managed))
        #expect(window.minSize == CGSize(width: 760, height: 500))
        #expect(window.identifier?.rawValue == "screencast.review.window")
        #expect(!window.canBecomeKey && !window.canBecomeMain && !window.isReleasedWhenClosed)
    }

    @Test("The window opens at 1100 × 700, centered, or fitted to a smaller screen, and not below its minimum unless the screen is")
    func windowFrame() {
        let laptop = CGRect(x: 0, y: 25, width: 1_512, height: 945)
        #expect(ScreencastRecordingReviewWindow.frame(in: laptop) == CGRect(x: 206, y: 148, width: 1_100, height: 700))
        let external = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        #expect(ScreencastRecordingReviewWindow.frame(in: external) == CGRect(x: -1_510, y: 190, width: 1_100, height: 700))
        let small = CGRect(x: 0, y: 28, width: 1_024, height: 740)
        #expect(ScreencastRecordingReviewWindow.frame(in: small) == CGRect(x: 20, y: 48, width: 984, height: 700))
        let tiny = CGRect(x: 0, y: 0, width: 700, height: 400)
        #expect(ScreencastRecordingReviewWindow.frame(in: tiny) == CGRect(x: 0, y: 0, width: 700, height: 400))
        let short = CGRect(x: 0, y: 0, width: 1_400, height: 520)
        #expect(ScreencastRecordingReviewWindow.frame(in: short) == CGRect(x: 150, y: 10, width: 1_100, height: 500))
    }

    // MARK: After Save, Copy, and Discard

    @Test("Save keeps the window open, saying where; Show in Finder selects the capture's folder; Done closes it")
    func saveConfirms() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let revealed = RevealLog()
        let panel = panel(outcomes: outcomes, revealed: revealed)
        let recording = try fixture.video()
        await panel.show(recording)
        let model = try #require(panel.model)
        panel.showInFinder()
        #expect(revealed.selections.isEmpty, "nothing to show before it's saved")

        model.note = "Checkout fails"
        await model.save()
        #expect(outcomes.outcomes == [.saved(recording)])
        #expect(ScreencastReview.read(from: recording.metadataURL)?.note == "Checkout fails")
        #expect(panel.isShown && panel.model === model, "the window stays")
        let confirmation = try #require(ScreencastReviewConfirmation(model.outcome))
        #expect(confirmation.title == "Saved" && confirmation.folder == recording.folder)

        panel.showInFinder()
        #expect(revealed.selections == [[recording.folder]])

        #expect(panel.perform(.close))
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes == [.saved(recording)], "closing after Save saves nothing more")
        #expect(FileManager.default.fileExists(atPath: recording.folder.path))
    }

    @Test("Copy keeps the window open too, saying it's on the clipboard and where it's kept")
    func copyConfirms() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes)
        let recording = try fixture.video()
        await panel.show(recording)
        await panel.model?.copy()
        #expect(outcomes.outcomes == [.copied(recording)] && panel.isShown)
        #expect(ScreencastReviewConfirmation(panel.model?.outcome)?.title == "Copied to Clipboard")
        #expect(fixture.pasteboard.pasteboardItems?.isEmpty == false)
        await panel.close()
        #expect(!panel.isShown && outcomes.outcomes.count == 1)
    }

    @Test("Discard, Escape, the close button, and turning Screencast off each close the window as before")
    func closingRules() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes)

        let discarded = try fixture.video(name: "1791000000")
        await panel.show(discarded)
        panel.model?.askToDiscard()
        panel.model?.confirmDiscard()
        #expect(!panel.isShown && outcomes.outcomes == [.discarded], "Discard closes at once")
        #expect(!FileManager.default.fileExists(atPath: discarded.folder.path))

        let escaped = try fixture.video(name: "1791000100")
        await panel.show(escaped)
        panel.model?.note = "by Escape"
        #expect(panel.perform(.close))
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes.last == .saved(escaped))
        #expect(ScreencastReview.read(from: escaped.metadataURL)?.note == "by Escape", "closing saves")

        let closed = try fixture.video(name: "1791000200")
        await panel.show(closed)
        panel.recordingWindow.performClose(nil)
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes.last == .saved(closed), "the close button saves")

        let saved = try fixture.video(name: "1791000300")
        await panel.show(saved)
        await panel.model?.save()
        #expect(panel.isShown)
        panel.shutDown()
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes.last == .saved(saved) && outcomes.outcomes.count == 4)
    }

    @Test("In the window, Trim and Save still cut the recording, and the window then shows the cut")
    func trimInTheWindow() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes)
        let recording = try fixture.video(mixdown: false)
        await panel.show(recording)
        let model = try #require(panel.model)
        let player = FakeTrimPresenter()
        model.trim(with: player)
        player.complete(1...3)
        await model.save()
        guard case .video(let cut) = model.input else {
            Issue.record("still a recording")
            return
        }
        #expect(cut.duration == 2 && model.durationText == "00:02")
        #expect(windowView(of: panel)?.model.input == model.input)
        #expect(outcomes.outcomes == [.saved(model.input)])
        await panel.close()
    }

    // MARK: What the window says

    @Test("The confirmation names the captures folder from the home folder, and Show in Finder the capture's own folder")
    func confirmationText() throws {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let folder = URL(fileURLWithPath: "/Users/someone/Documents/Keybumps/captures/1791000000", isDirectory: true)
        let input = ScreencastReviewInput.video(ScreencastCapture(folder: folder, videos: [], duration: 1, endedEarly: nil))

        let saved = try #require(ScreencastReviewConfirmation(.saved(input), home: home))
        #expect(saved.text == "Saved · Documents › Keybumps › captures")
        #expect(saved.folder == folder)
        let copied = try #require(ScreencastReviewConfirmation(.copied(input), home: home))
        #expect(copied.text == "Copied to Clipboard · Documents › Keybumps › captures")
        #expect(ScreencastReviewConfirmation(.discarded, home: home) == nil)
        #expect(ScreencastReviewConfirmation(nil, home: home) == nil)

        #expect(ScreencastReviewConfirmation.place(of: folder.deletingLastPathComponent(), home: URL(fileURLWithPath: "/Users/someone/")) ==
                "Documents › Keybumps › captures")
        #expect(ScreencastReviewConfirmation.place(of: URL(fileURLWithPath: "/private/tmp/sandbox/captures"), home: home) ==
                "private › tmp › sandbox › captures", "outside the home folder, the whole path")
        #expect(ScreencastReviewConfirmation.place(of: URL(fileURLWithPath: "/Users/someoneelse/captures"), home: home) ==
                "Users › someoneelse › captures", "a folder whose name only starts like the home folder's isn't in it")
    }

    // MARK: Space

    @Test("Space plays and pauses a recording, unless a text field has the keyboard; Return and Escape close it once saved")
    func keys() {
        func action(
            _ key: UInt16, _ modifiers: NSEvent.ModifierFlags = [], typing: Bool = false, recording: Bool = true,
            finished: Bool = false, trimming: Bool = false, composing: Bool = false, confirming: Bool = false
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: key, modifiers: modifiers, isTrimming: trimming, isComposing: composing,
                isConfirmingDiscard: confirming, isFinished: finished, isTyping: typing, playsRecording: recording
            )
        }
        #expect(action(49) == .togglePlay)
        #expect(action(49, typing: true) == .pass, "a space in the note")
        #expect(action(49, recording: false) == .pass, "a screenshot's panel has no player")
        #expect(action(49, .shift) == .pass && action(49, .command) == .pass && action(49, .option) == .pass)
        #expect(action(49, trimming: true) == .pass, "the trim controls keep their keys")
        #expect(action(49, composing: true) == .pass)
        #expect(action(49, confirming: true) == .togglePlay && action(49, finished: true) == .togglePlay)

        #expect(action(36, finished: true) == .close && action(76, finished: true) == .close && action(53, finished: true) == .close)
        #expect(action(36) == .save && action(53) == .close, "before Save, as in the panel")
        #expect(action(53, confirming: true) == .keep && action(36, confirming: true) == .ignore)
    }

    @Test("Space reaches the recording's player through the window's keys; a held Space toggles once")
    func spaceTogglesThePlayer() async throws {
        defer { fixture.tearDown() }
        let folder = fixture.folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 0))
        try await ReviewFixture.writeMovie(to: file, seconds: 1)
        let video = ScreencastVideo(file: file, mixdown: nil, pixelWidth: 64, pixelHeight: 36, audioTracks: [], duration: 1)
        let recording = ScreencastReviewInput.video(ScreencastCapture(folder: folder, videos: [video], duration: 1, endedEarly: nil))

        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes, makePlayback: { ScreencastReviewPlayback() })
        await panel.show(recording)
        let playback = try #require(panel.playback)
        #expect(!playback.isPlaying)

        #expect(panel.perform(.togglePlay))
        #expect(playback.isPlaying)
        panel.perform(.togglePlay, isRepeat: true)
        #expect(playback.isPlaying, "a held Space doesn't toggle again")
        panel.perform(.togglePlay)
        #expect(!playback.isPlaying)

        // At the end, Space plays from the start again.
        let player = try #require(playback.view.player)
        let end = try await #require(player.currentItem).asset.load(.duration)
        _ = await player.seek(to: end)
        panel.perform(.togglePlay)
        #expect(playback.isPlaying)
        player.pause()
        try await eventually { player.currentTime().seconds < 0.5 }

        await panel.close()
        #expect(panel.playback == nil && playback.view.player?.currentItem == nil, "closing stops the player")
    }
}

/// What Show in Finder would have selected.
final class RevealLog {
    var selections: [[URL]] = []
}
