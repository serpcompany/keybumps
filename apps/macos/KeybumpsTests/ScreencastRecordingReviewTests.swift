import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// A recording's review in its window (#475): the player and Discard, Copy, and Save, closing on
/// Save or Copy with a notice in the notch, and playing and pausing on Space. Made-up captures in a
/// temporary folder, a named pasteboard, and no window ordered in or made key.
@MainActor
@Suite("Screencast: the review window")
struct ScreencastRecordingReviewTests {
    let fixture = ReviewFixture()

    private func panel(
        outcomes: ReviewOutcomeLog,
        makePlayback: @escaping @MainActor () -> ScreencastReviewPlayback? = { nil },
        fullKeyboardAccess: @escaping @MainActor () -> Bool = { false }
    ) -> ScreencastReviewPanel {
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            screen: { nil },
            makePlayback: makePlayback,
            fullKeyboardAccess: fullKeyboardAccess
        )
        panel.onFinish = { outcomes.outcomes.append($0) }
        return panel
    }

    /// The flow the app hangs the review on, with its notch notices recorded.
    private func flow(outcomes: ReviewOutcomeLog, notices: ReviewNotices) -> ScreencastReviewFlow {
        let flow = ScreencastReviewFlow(
            services: ScreencastReviewServices(
                clipboard: fixture.clipboard,
                pasteboard: fixture.pasteboard,
                notices: notices,
                repositories: { [fixture] in fixture.repositories }
            ),
            contextReader: .inert
        )
        flow.onFinish = { outcomes.outcomes.append($0) }
        return flow
    }

    /// The window's SwiftUI view.
    private func windowView(of panel: ScreencastReviewPanel) -> ScreencastRecordingReviewView? {
        (panel.window.contentView as? NSHostingView<ScreencastRecordingReviewView>)?.rootView
    }

    /// A recording the player can play: one second of real media.
    private func playableRecording() async throws -> ScreencastReviewInput {
        let folder = fixture.folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 0))
        try await ReviewFixture.writeMovie(to: file, seconds: 1)
        let video = ScreencastVideo(file: file, mixdown: nil, pixelWidth: 64, pixelHeight: 36, audioTracks: [], duration: 1)
        return .video(ScreencastCapture(folder: folder, videos: [video], duration: 1, endedEarly: nil))
    }

    /// Lets the main actor run until `condition` holds, for two seconds at most.
    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    // MARK: Which review opens

    @Test("Each recording opens in the window, on the review's model; the next one closes it, which saves")
    func recordingOpensTheWindow() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes)
        let recording = try fixture.video()
        await panel.show(recording)
        let view = try #require(windowView(of: panel), "the window shows the recording")
        #expect(view.model === panel.model, "its toolbar acts on the review's model")
        #expect(panel.isShown && !panel.window.isVisible, "never on screen under the unit-test host")

        let next = try fixture.video(name: "1791000100")
        await panel.show(next)
        #expect(outcomes.outcomes == [.saved(recording)], "the next capture closes the window, which saves")
        #expect(windowView(of: panel)?.model === panel.model && panel.model?.input == next && !panel.window.isVisible)
        await panel.close()
    }

    @Test("The window is a standard, resizable window titled Recording, with a compact toolbar and a minimum size, that can open over a full-screen app, never restored, and never key under the unit-test host")
    func windowShell() {
        let window = ScreencastRecordingReviewWindow()
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(!window.styleMask.contains(.nonactivatingPanel) && !window.styleMask.contains(.fullScreen))
        #expect(window.title == "Recording" && window.titleVisibility == .hidden, "the toolbar shows it, in its middle")
        #expect(window.toolbar != nil && window.toolbarStyle == .unifiedCompact)
        #expect(window.level == .normal && window.collectionBehavior.isSuperset(of: [.managed, .participatesInCycle]))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary), "it opens over a full-screen app")
        #expect(!window.isRestorable, "nothing to put back at launch")
        // AppKit adds a few points to the height for the toolbar.
        #expect(window.minSize.width == 640 && (400...420).contains(window.minSize.height))
        #expect(window.identifier?.rawValue == "screencast.review.window")
        #expect(!window.canBecomeKey && !window.canBecomeMain && !window.isReleasedWhenClosed)
    }

    @Test("Discard is on the toolbar's left, the title and display picker in its middle, and Copy and Save on its right; nothing else is around the player")
    func toolbarHoldsTheActions() async throws {
        defer { fixture.tearDown() }
        let panel = panel(outcomes: ReviewOutcomeLog())
        await panel.show(try fixture.video(displays: 2))
        let window = panel.window
        let toolbar = try #require(window.toolbar)
        #expect(toolbar.items.map(\.itemIdentifier.rawValue) == [
            "screencast.review.toolbar.leading", "NSToolbarFlexibleSpaceItem",
            "screencast.review.toolbar.middle", "NSToolbarFlexibleSpaceItem",
            "screencast.review.toolbar.trailing",
        ])
        let parts = toolbar.items.compactMap { $0.view as? NSHostingView<ScreencastRecordingReviewToolbar> }.map(\.rootView)
        #expect(parts.map(\.part) == [.leading, .middle, .trailing])
        #expect(parts.allSatisfy { $0.model === panel.model }, "they act on the review's model")
        #expect(window.contentView is NSHostingView<ScreencastRecordingReviewView>, "the content is the player alone")

        // Laid out off screen at a CI screen's size: the parts sit where the owner put them, not
        // pushed together by a shown title.
        window.setFrame(CGRect(x: 16, y: 16, width: 992, height: 700), display: false)
        for _ in 0..<3 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let frames = toolbar.items.filter { $0.view is NSHostingView<ScreencastRecordingReviewToolbar> }
            .compactMap { item in item.view.map { $0.convert($0.bounds, to: nil) } }
        try #require(frames.count == 3)
        let middle = window.frame.width / 2
        #expect(frames[0].width > 0 && frames[0].maxX < middle / 2, "Discard on the left")
        #expect(frames[1].minX < middle && frames[1].maxX > middle, "the title and picker in the middle")
        #expect(frames[2].width > 0 && frames[2].minX > middle * 1.5, "Copy and Save on the right")
        await panel.close()
    }

    @Test("The window fills the visible frame of the screen it opens on, but a margin, and not below its minimum unless the screen is")
    func windowFrame() {
        let laptop = CGRect(x: 0, y: 25, width: 1_512, height: 945)
        #expect(ScreencastRecordingReviewWindow.frame(in: laptop) == CGRect(x: 16, y: 41, width: 1_480, height: 913))
        let external = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        #expect(ScreencastRecordingReviewWindow.frame(in: external) == CGRect(x: -1_904, y: 16, width: 1_888, height: 1_048))
        let small = CGRect(x: 0, y: 0, width: 660, height: 420)
        #expect(ScreencastRecordingReviewWindow.frame(in: small) == CGRect(x: 10, y: 10, width: 640, height: 400))
        let tiny = CGRect(x: 0, y: 0, width: 600, height: 380)
        #expect(ScreencastRecordingReviewWindow.frame(in: tiny) == CGRect(x: 0, y: 0, width: 600, height: 380))
    }

    @Test("The window opens filling the screen with the pointer")
    func windowFillsItsScreen() async throws {
        defer { fixture.tearDown() }
        let screen = try #require(NSScreen.screens.last)
        let review = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            screen: { screen },
            makePlayback: { nil }
        )
        await review.show(try fixture.video())
        #expect(review.window.frame == ScreencastRecordingReviewWindow.frame(in: screen.visibleFrame))
        await review.close()
    }

    // MARK: Save, Copy, and Discard

    @Test("Save keeps the recording in the captures folder, closes the window, and the notch says \"Recording saved\"")
    func saveClosesWithANotice() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        let flow = flow(outcomes: outcomes, notices: notices)
        let recording = try fixture.video()
        await flow.show(recording, context: .none)
        let panel = try #require(flow.panel)
        #expect(panel.isShown && notices.messages.isEmpty)

        await panel.model?.save()
        #expect(outcomes.outcomes == [.saved(recording)])
        #expect(!panel.isShown && !panel.window.isVisible && panel.playback == nil, "the window closes")
        #expect(notices.messages == ["Recording saved"] && notices.warnings == [false])
        #expect(FileManager.default.fileExists(atPath: recording.folder.path), "kept in the captures folder it was recorded into")
        #expect(try ScreencastMetadata.read(from: recording.metadataURL).duration == 4, "the recording as it was")
        #expect(ScreencastReview.read(from: recording.metadataURL) != nil, "with its review in meta.json")
    }

    @Test("Return saves once, however long it's held; Escape and the close button save too, each with the notice")
    func returnAndEscapeSave() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        let flow = flow(outcomes: outcomes, notices: notices)

        let returned = try fixture.video(name: "1791000000")
        await flow.show(returned, context: .none)
        let panel = try #require(flow.panel)
        #expect(panel.action(forKey: 36, modifiers: [], in: panel.window) == .save)
        #expect(panel.perform(.save, isRepeat: true), "a repeat is swallowed")
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.isShown && outcomes.outcomes.isEmpty, "and doesn't save")
        #expect(panel.perform(.save))
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes == [.saved(returned)])

        let escaped = try fixture.video(name: "1791000100")
        await flow.show(escaped, context: .none)
        #expect(panel.action(forKey: 53, modifiers: [], in: panel.window) == .close)
        #expect(panel.perform(.close, isRepeat: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.isShown, "a held Escape acts once, on its first press")
        #expect(panel.perform(.close))
        try await eventually { !panel.isShown }

        let closed = try fixture.video(name: "1791000200")
        await flow.show(closed, context: .none)
        panel.window.performClose(nil)
        try await eventually { !panel.isShown }

        #expect(outcomes.outcomes == [.saved(returned), .saved(escaped), .saved(closed)])
        #expect(notices.messages == ["Recording saved", "Recording saved", "Recording saved"])
    }

    @Test("Copy puts the recording on the services' pasteboard and closes the window; the notch then says \"Recording copied\"")
    func copyCloses() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        // The flow, as the app hangs it: Copy writes to the pasteboard its services name, here the
        // test's own.
        let flow = flow(outcomes: outcomes, notices: notices)
        let recording = try fixture.video()
        await flow.show(recording, context: .none)
        let panel = try #require(flow.panel)
        await panel.model?.copy()
        #expect(outcomes.outcomes == [.copied(recording)] && !panel.isShown && !panel.window.isVisible)
        #expect(fixture.pasteboard.pasteboardItems?.isEmpty == false, "on the test's pasteboard")
        #expect(notices.messages == ["Recording copied"] && notices.warnings == [false])
    }

    @Test("Discard asks first, then deletes and closes, with no notice; turning Screencast off saves")
    func discardAndTurningOff() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        let flow = flow(outcomes: outcomes, notices: notices)

        let discarded = try fixture.video(name: "1791000000")
        await flow.show(discarded, context: .none)
        let panel = try #require(flow.panel)
        panel.model?.confirmDiscard()
        #expect(panel.isShown && FileManager.default.fileExists(atPath: discarded.folder.path), "nothing goes without the question")
        panel.model?.askToDiscard()
        #expect(panel.action(forKey: 36, modifiers: [], in: panel.window) == .ignore, "Return doesn't answer it")
        #expect(panel.action(forKey: 53, modifiers: [], in: panel.window) == .keep, "Escape keeps it")
        panel.model?.confirmDiscard()
        #expect(!panel.isShown && outcomes.outcomes == [.discarded])
        #expect(!FileManager.default.fileExists(atPath: discarded.folder.path))
        #expect(notices.messages.isEmpty)

        let kept = try fixture.video(name: "1791000100")
        await flow.show(kept, context: .none)
        flow.close()
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes == [.discarded, .saved(kept)])
        #expect(notices.messages == ["Recording saved"])
    }

    @Test("Nothing is left on screen for the next capture: a saved recording's window is already gone; one not yet saved closes as the capture starts, which saves it, with no notice")
    func nextCaptureAfterAReview() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        let flow = flow(outcomes: outcomes, notices: notices)

        let saved = try fixture.video(name: "1791000000")
        await flow.show(saved, context: .none)
        let panel = try #require(flow.panel)
        await panel.model?.save()
        #expect(!panel.isShown && !panel.window.isVisible, "gone before Start Screencast")

        let unsaved = try fixture.video(name: "1791000100")
        await flow.show(unsaved, context: .none)
        flow.captureStarting()
        #expect(!panel.isShown, "a review not yet saved goes as the capture starts")
        try await eventually { panel.model == nil }
        #expect(outcomes.outcomes == [.saved(saved), .saved(unsaved)], "which saves it")
        #expect(ScreencastReview.read(from: unsaved.metadataURL) != nil, "with its review in meta.json")
        #expect(notices.messages == ["Recording saved"], "the next capture needs no notice for it")

        let next = try fixture.video(name: "1791000200")
        await flow.show(next, context: .none)
        #expect(panel.isShown && panel.model?.input == next, "the next recording opens as usual")
        await panel.close()
        #expect(notices.messages == ["Recording saved", "Recording saved"])
    }

    @Test("From the moment a capture starts, the window before is off screen, never key, deaf to its keys, and its player stopped, while its save is still to come")
    func nextCaptureNeverHasTheWindow() async throws {
        defer { fixture.tearDown() }
        let recording = try await playableRecording()
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes, makePlayback: { ScreencastReviewPlayback() })
        await panel.show(recording)
        let playback = try #require(panel.playback)
        let window = panel.window
        #expect(panel.perform(.togglePlay) && playback.isPlaying)

        panel.makeWayForNextCapture()
        #expect(panel.model?.isFinished == false, "its save still to come")
        #expect(!panel.isShown && !window.isVisible && !window.isKeyWindow, "gone at once, before the picker opens")
        #expect(panel.playback == nil && playback.view.player?.currentItem == nil, "the player stopped")
        for key: UInt16 in [49, 36, 76, 53] {
            #expect(panel.action(forKey: key, modifiers: [], in: window) == .pass, "key \(key) does nothing to it")
        }
        #expect(!panel.perform(.togglePlay) && !panel.perform(.save) && !panel.perform(.close))
        // The close button can't reach it either; if it could, it would only save the same capture.
        panel.window.performClose(nil)

        try await eventually { panel.model == nil }
        #expect(outcomes.outcomes == [.saved(recording)], "saved once")
        #expect(!panel.isShown && !window.isVisible && !window.isKeyWindow, "and it never comes back")
    }

    @Test("What the notch says: Save and Copy, the reason as a warning when the recording couldn't be saved, and nothing for Discard")
    func notices() throws {
        defer { fixture.tearDown() }
        let recording = try fixture.video(name: "1791000000")
        #expect(ScreencastReviewFlow.notice(for: .saved(recording))?.message == "Recording saved")
        #expect(ScreencastReviewFlow.notice(for: .saved(recording))?.isWarning == false)
        #expect(ScreencastReviewFlow.notice(for: .copied(recording))?.message == "Recording copied")
        let failed = ScreencastReviewFlow.notice(for: .saveFailed(recording, .diskFull))
        #expect(failed?.message == "Couldn’t save the recording: the disk is full." && failed?.isWarning == true)
        #expect(ScreencastReviewFlow.notice(for: .discarded) == nil)
    }

    // MARK: A save that fails

    @Test("A Save that fails says it couldn't save the recording and why, and stays; closing then warns, never says saved")
    func failedSaveSaysWhy() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        let flow = flow(outcomes: outcomes, notices: notices)
        let recording = try fixture.video()
        // A folder where meta.json goes: writing it fails.
        try FileManager.default.removeItem(at: recording.metadataURL)
        try FileManager.default.createDirectory(at: recording.metadataURL, withIntermediateDirectories: true)
        await flow.show(recording, context: .none)
        let panel = try #require(flow.panel)
        let model = try #require(panel.model)

        await model.save()
        #expect(model.failure == .metadataFailed && panel.isShown, "the window stays to say why")
        let message = try #require(model.failure?.message)
        #expect(message == "Couldn’t save the recording: its folder can’t be written to.")
        #expect(!message.contains("note") && !message.localizedCaseInsensitiveContains("saved"))
        #expect(notices.messages.isEmpty)

        await panel.close()
        #expect(outcomes.outcomes == [.saveFailed(recording, .metadataFailed)], "never saved")
        #expect(notices.messages == [message] && notices.warnings == [true], "the notch warns, with the reason")
        #expect(!notices.messages.contains("Recording saved"))
    }

    @Test("A recording moved or deleted during its review: Save says so, nothing makes its folder again, and the next capture closing it warns")
    func recordingGoneSaysSo() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        let flow = flow(outcomes: outcomes, notices: notices)
        let recording = try fixture.video()
        await flow.show(recording, context: .none)
        let panel = try #require(flow.panel)
        let model = try #require(panel.model)
        try FileManager.default.removeItem(at: recording.folder)

        await model.save()
        #expect(model.failure == .recordingMissing)
        #expect(model.failure?.message == "Couldn’t save the recording: it was moved or deleted.")
        #expect(!FileManager.default.fileExists(atPath: recording.folder.path), "no folder made around the review alone")

        flow.captureStarting()
        try await eventually { panel.model == nil }
        #expect(outcomes.outcomes == [.saveFailed(recording, .recordingMissing)])
        #expect(notices.messages == ["Couldn’t save the recording: it was moved or deleted."] && notices.warnings == [true],
                "a failure is told even as the next capture starts")
        #expect(!FileManager.default.fileExists(atPath: recording.folder.path))
    }

    @Test("Why a review couldn't be written: the recording gone, a full disk, or anything else")
    func saveFailureReasons() {
        let outOfSpace = CocoaError(.fileWriteOutOfSpace)
        #expect(ScreencastReviewFailure.saving(outOfSpace, recordingExists: true) == .diskFull)
        let noSpace = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        #expect(ScreencastReviewFailure.saving(noSpace, recordingExists: true) == .diskFull, "or ENOSPC under it")
        #expect(ScreencastReviewFailure.saving(CocoaError(.fileWriteNoPermission), recordingExists: true) == .metadataFailed)
        #expect(ScreencastReviewFailure.saving(outOfSpace, recordingExists: false) == .recordingMissing)
        for failure in [ScreencastReviewFailure.recordingMissing, .diskFull, .metadataFailed] {
            #expect(failure.message.hasPrefix("Couldn’t save the recording: "), "what failed, then why")
        }
    }

    // MARK: Space

    @Test("Space plays and pauses the recording; Return saves and Escape closes")
    func keys() {
        func action(
            _ key: UInt16, _ modifiers: NSEvent.ModifierFlags = [], composing: Bool = false, confirming: Bool = false
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: key, modifiers: modifiers, isComposing: composing, isConfirmingDiscard: confirming
            )
        }
        #expect(action(49) == .togglePlay)
        #expect(action(49, .shift) == .pass && action(49, .command) == .pass && action(49, .option) == .pass)
        #expect(action(49, composing: true) == .pass)
        #expect(action(49, confirming: true) == .togglePlay)

        #expect(action(36) == .save && action(76) == .save && action(53) == .close)
        #expect(action(53, confirming: true) == .keep && action(36, confirming: true) == .ignore)

        // A toolbar button with the keyboard (Full Keyboard Access) keeps Space and Return.
        func focused(_ key: UInt16, confirming: Bool = false) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: key, modifiers: [], isComposing: false, isConfirmingDiscard: confirming, controlHasKeyboard: true
            )
        }
        #expect(focused(49) == .pass && focused(36) == .pass && focused(76) == .pass)
        #expect(focused(36, confirming: true) == .ignore, "Return still never answers the discard question")
        #expect(focused(53) == .close && focused(53, confirming: true) == .keep, "Escape is the window's")
    }

    @Test("With Full Keyboard Access, Space and Return go to the toolbar button that has the keyboard; with nothing focused, Space plays and Return saves")
    func focusedButtonKeepsItsKeys() async throws {
        defer { fixture.tearDown() }
        let fullKeyboardAccess = KeyboardNavigation()
        let panel = panel(outcomes: ReviewOutcomeLog(), fullKeyboardAccess: { fullKeyboardAccess.isOn })
        await panel.show(try fixture.video())
        let window = panel.window
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .togglePlay, "nothing has the keyboard as it opens")
        #expect(panel.action(forKey: 36, modifiers: [], in: window) == .save)

        // Where Tab puts the keyboard: a control in the toolbar's Discard part.
        let part = try #require(window.toolbar?.items.first?.view)
        let button = FocusableStandIn()
        part.addSubview(button)
        #expect(window.makeFirstResponder(button))
        #expect(window.toolbarHas(window.firstResponder))
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .pass, "Space presses the button")
        #expect(panel.action(forKey: 36, modifiers: [], in: window) == .pass, "and Return is the button's too")
        #expect(panel.action(forKey: 53, modifiers: [], in: window) == .close)

        fullKeyboardAccess.isOn = false
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .togglePlay, "without it, no button takes keys")

        // The keyboard in the player's area, not the toolbar: the review's keys again.
        fullKeyboardAccess.isOn = true
        let inPlayer = FocusableStandIn()
        window.contentView?.addSubview(inPlayer)
        #expect(window.makeFirstResponder(inPlayer) && !window.toolbarHas(window.firstResponder))
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .togglePlay)
        #expect(panel.action(forKey: 36, modifiers: [], in: window) == .save)
        button.removeFromSuperview()
        inPlayer.removeFromSuperview()
        await panel.close()
    }

    @Test("The window opens with nothing taking the keyboard, so Space plays at once; Return still saves and Escape still closes")
    func spacePlaysOnOpening() async throws {
        defer { fixture.tearDown() }
        let recording = try await playableRecording()
        let panel = panel(outcomes: ReviewOutcomeLog(), makePlayback: { ScreencastReviewPlayback() })
        await panel.show(recording)
        let window = panel.window
        // Lays the window out, as on screen, so whatever takes the keyboard as it appears has run.
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let responder = window.firstResponder
        #expect(!(responder is NSText) && !(responder is NSTextField), "no text field takes the keyboard")

        #expect(panel.action(forKey: 36, modifiers: [], in: window) == .save)
        #expect(panel.action(forKey: 53, modifiers: [], in: window) == .close)
        #expect(panel.action(forKey: 49, modifiers: [], in: NSWindow()) == .pass, "keys count only in the review's own window")
        let space = panel.action(forKey: 49, modifiers: [], in: window)
        #expect(space == .togglePlay)
        let playback = try #require(panel.playback)
        #expect(panel.perform(space))
        #expect(playback.isPlaying, "the first Space plays")
        playback.pause()
        await panel.close()
    }

    @Test("Space reaches the recording's player through the window's keys; a held Space toggles once")
    func spaceTogglesThePlayer() async throws {
        defer { fixture.tearDown() }
        let recording = try await playableRecording()

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

/// A control that takes the keyboard, as a toolbar button does under Full Keyboard Access.
private final class FocusableStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// System Settings' Keyboard Navigation, as a test sets it.
@MainActor
private final class KeyboardNavigation {
    var isOn = true
}

/// The notch's notices.
private final class ReviewNotices: PaletteNoticePresenting {
    private(set) var messages: [String] = []
    private(set) var warnings: [Bool] = []

    func showNotice(_ message: String, isWarning: Bool) {
        messages.append(message)
        warnings.append(isWarning)
    }
}
