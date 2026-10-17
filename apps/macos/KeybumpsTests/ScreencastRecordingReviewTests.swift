import AppKit
import AVFoundation
import AVKit
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
    private func flow(
        outcomes: ReviewOutcomeLog, notices: ReviewNotices, front: ScreencastReviewFront = .app
    ) -> ScreencastReviewFlow {
        let flow = ScreencastReviewFlow(
            services: ScreencastReviewServices(
                clipboard: fixture.clipboard,
                pasteboard: fixture.pasteboard,
                notices: notices,
                repositories: { [fixture] in fixture.repositories },
                front: front
            ),
            contextReader: .inert
        )
        flow.onFinish = { outcomes.outcomes.append($0) }
        return flow
    }

    /// What the notch says after Save: the folder the capture's folder is in, the test's captures
    /// folder, by the name Finder shows.
    private var savedNotice: String { "Recording saved to \(fixture.folder.url.lastPathComponent)" }

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
        #expect(view.model === panel.model, "its bar acts on the review's model")
        #expect(panel.isShown && !panel.window.isVisible, "never on screen under the unit-test host")

        let next = try fixture.video(name: "1791000100")
        await panel.show(next)
        #expect(outcomes.outcomes == [.saved(recording)], "the next capture closes the window, which saves")
        #expect(windowView(of: panel)?.model === panel.model && panel.model?.input == next && !panel.window.isVisible)
        await panel.close()
    }

    @Test("The window is a standard, resizable window titled Edit Recording, as the Screenshot Editor's is Edit Screenshot, with no toolbar and a minimum size, that can open over a full-screen app, never restored, and never key under the unit-test host")
    func windowShell() {
        let window = ScreencastRecordingReviewWindow()
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(!window.styleMask.contains(.nonactivatingPanel) && !window.styleMask.contains(.fullScreen))
        #expect(window.title == "Edit Recording" && window.titleVisibility == .visible)
        #expect(window.toolbar == nil, "the bar is in the window's content, as the Screenshot Editor's is")
        #expect(window.level == .normal && window.collectionBehavior.isSuperset(of: [.managed, .participatesInCycle]))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary), "it opens over a full-screen app")
        #expect(!window.isRestorable, "nothing to put back at launch")
        #expect(window.minSize == CGSize(width: 760, height: 400))
        #expect(window.identifier?.rawValue == "screencast.review.window")
        #expect(!window.canBecomeKey && !window.canBecomeMain && !window.isReleasedWhenClosed)
    }

    @Test("The bar is above the player, on the review's model: Discard, Copy, and Save, in that order; the player fills the rest")
    func barHoldsTheActions() async throws {
        defer { fixture.tearDown() }
        let panel = panel(outcomes: ReviewOutcomeLog())
        await panel.show(try fixture.video(displays: 2))
        let model = try #require(panel.model)
        let view = try #require(windowView(of: panel), "one SwiftUI root, as the Screenshot Editor's")
        #expect(view.model === model, "the bar acts on the review's model")
        #expect(panel.window.toolbar == nil)

        let actions = ScreencastRecordingReviewBar.actions(for: model)
        let identifiers = actions.map(\.identifier)
        #expect(identifiers == [ScreencastReviewID.discard, ScreencastReviewID.copy, ScreencastReviewID.save])
        let titles = actions.map(\.title)
        #expect(titles == ["Discard", "Copy", "Save"])
        let enabled = actions.filter(\.isEnabled).count
        #expect(enabled == 3, "all of them, until one is chosen")
        await panel.close()
    }

    @Test("Save is the window's prominent default button, last; Discard is red; Copy shows ⌘C and Save Return's sign as keycaps, which VoiceOver doesn't read")
    func saveIsTheDefaultButton() async throws {
        defer { fixture.tearDown() }
        let panel = panel(outcomes: ReviewOutcomeLog())
        await panel.show(try fixture.video())
        let model = try #require(panel.model)
        let actions = ScreencastRecordingReviewBar.actions(for: model)
        let save = try #require(actions.last)
        #expect(save.title == "Save")
        #expect(save.style == .prominent && save.isDefault)
        let defaults = actions.filter(\.isDefault).map(\.title)
        #expect(defaults == ["Save"], "one default button")

        let styles = actions.map(\.style)
        #expect(styles == [.destructive, .standard, .prominent])
        let keys = actions.map(\.key)
        #expect(keys == [nil, "⌘C", "↩"])
        #expect(ScreengrabsEditorAction.returnSign == "↩")
        #expect(ScreencastRecordingReviewBar.copyKey == "⌘C")
        await panel.close()
    }

    @Test("Save shows Return's sign beside its title, as a menu shows a key equivalent")
    func saveShowsReturn() async throws {
        defer { fixture.tearDown() }
        let panel = panel(outcomes: ReviewOutcomeLog())
        await panel.show(try fixture.video())
        let model = try #require(panel.model)
        let action = try #require(ScreencastRecordingReviewBar.actions(for: model).last)
        let save = NSHostingView(rootView: ScreengrabsEditorActionButton(action: action)).fittingSize.width
        let plain = NSHostingView(rootView: Button("Save") {}.buttonStyle(.borderedProminent)).fittingSize.width
        let sign = NSHostingView(rootView: Text(ScreengrabsEditorAction.returnSign)).fittingSize.width
        #expect(save >= plain + sign, "Save is \(save) points wide; a plain Save button \(plain), and the sign \(sign)")
        await panel.close()
    }

    @Test("While Discard is asked, Discard, Copy, and Save make way for the question, Keep, and Discard; Keep brings them back")
    func discardQuestionTakesTheBar() async throws {
        defer { fixture.tearDown() }
        let panel = panel(outcomes: ReviewOutcomeLog())
        await panel.show(try fixture.video())
        let model = try #require(panel.model)
        func shown() -> [String?] {
            ScreencastRecordingReviewBar.actions(for: model).map(\.identifier)
        }
        let actions = [ScreencastReviewID.discard, ScreencastReviewID.copy, ScreencastReviewID.save]
        #expect(shown() == actions)

        model.askToDiscard()
        #expect(shown() == [ScreencastReviewID.keep, ScreencastReviewID.confirmDiscard])
        let answers = ScreencastRecordingReviewBar.actions(for: model)
        let confirm = try #require(answers.last)
        #expect(confirm.title == "Discard")
        #expect(confirm.style == .prominentDestructive && !confirm.isDefault)
        #expect(answers.allSatisfy { $0.key == nil }, "no key answers it")
        #expect(ScreencastRecordingReviewBar.discardQuestion == "Discard this recording?")

        model.keep()
        #expect(shown() == actions)
        await panel.close()
    }

    @Test("The bar's buttons act on the review: Save saves and closes the window")
    func barSaves() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let panel = panel(outcomes: outcomes)
        let recording = try fixture.video()
        await panel.show(recording)
        let model = try #require(panel.model)
        let save = try #require(ScreencastRecordingReviewBar.actions(for: model).last)
        save.perform()
        try await eventually { panel.model == nil }
        #expect(outcomes.outcomes == [.saved(recording)])
    }

    @Test("The window fills the visible frame of the screen it opens on, but a margin, and not below its minimum unless the screen is")
    func windowFrame() {
        let laptop = CGRect(x: 0, y: 25, width: 1_512, height: 945)
        #expect(ScreencastRecordingReviewWindow.frame(in: laptop) == CGRect(x: 16, y: 41, width: 1_480, height: 913))
        let external = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        #expect(ScreencastRecordingReviewWindow.frame(in: external) == CGRect(x: -1_904, y: 16, width: 1_888, height: 1_048))
        let small = CGRect(x: 0, y: 0, width: 780, height: 420)
        #expect(ScreencastRecordingReviewWindow.frame(in: small) == CGRect(x: 10, y: 10, width: 760, height: 400))
        let tiny = CGRect(x: 0, y: 0, width: 720, height: 380)
        #expect(ScreencastRecordingReviewWindow.frame(in: tiny) == CGRect(x: 0, y: 0, width: 720, height: 380))
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

    @Test("Save keeps the recording in the captures folder, closes the window, and the notch says it was saved there")
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
        #expect(notices.messages == [savedNotice] && notices.warnings == [false], "where it went: the captures folder")
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
        #expect(notices.messages == [savedNotice, savedNotice, savedNotice])
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

    @Test("⌘C copies once, however long it's held, with Copy's notice; while Discard is asked it does nothing")
    func commandCCopies() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let notices = ReviewNotices()
        let flow = flow(outcomes: outcomes, notices: notices)
        let recording = try fixture.video()
        await flow.show(recording, context: .none)
        let panel = try #require(flow.panel)
        let model = try #require(panel.model)

        model.askToDiscard()
        let asking = panel.action(forKey: 8, modifiers: .command, characters: "c", in: panel.window)
        #expect(asking == .ignore, "never while Discard is asked")
        model.keep()

        let key = panel.action(forKey: 8, modifiers: .command, characters: "c", in: panel.window)
        #expect(key == .copy)
        #expect(panel.perform(.copy, isRepeat: true), "a repeat is swallowed")
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.isShown && outcomes.outcomes.isEmpty, "and doesn't copy")
        #expect(panel.perform(.copy))
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes == [.copied(recording)])
        #expect(fixture.pasteboard.pasteboardItems?.isEmpty == false, "on the test's pasteboard")
        #expect(notices.messages == ["Recording copied"])
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
        #expect(notices.messages == [savedNotice])
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
        #expect(!panel.isShown && !panel.window.isVisible, "gone before Record Screen")

        let unsaved = try fixture.video(name: "1791000100")
        await flow.show(unsaved, context: .none)
        flow.captureStarting()
        #expect(!panel.isShown, "a review not yet saved goes as the capture starts")
        try await eventually { panel.model == nil }
        #expect(outcomes.outcomes == [.saved(saved), .saved(unsaved)], "which saves it")
        #expect(ScreencastReview.read(from: unsaved.metadataURL) != nil, "with its review in meta.json")
        #expect(notices.messages == [savedNotice], "the next capture needs no notice for it")

        let next = try fixture.video(name: "1791000200")
        await flow.show(next, context: .none)
        #expect(panel.isShown && panel.model?.input == next, "the next recording opens as usual")
        await panel.close()
        #expect(notices.messages == [savedNotice, savedNotice])
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

    @Test("What the notch says: where Save put the recording, Copy, the reason as a warning when the recording couldn't be saved, and nothing for Discard")
    func notices() throws {
        defer { fixture.tearDown() }
        let recording = try fixture.video(name: "1791000000")
        // The folder named is the one the capture's own folder is in, by its name in Finder.
        var asked: [URL] = []
        let saved = ScreencastReviewFlow.notice(for: .saved(recording)) { folder in
            asked.append(folder)
            return "Movies"
        }
        #expect(saved?.message == "Recording saved to Movies" && saved?.isWarning == false)
        #expect(asked.map(\.standardizedFileURL) == [fixture.folder.url.standardizedFileURL], "the captures folder, not the capture's own")
        #expect(ScreencastReviewFlow.notice(for: .saved(recording))?.message == savedNotice, "Finder's name for it")
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
        #expect(!notices.messages.contains { $0.hasPrefix("Recording saved") })
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

    // MARK: Who gets the front

    @Test(
        "When the next capture closes a window that had the keyboard, the app in front before the window gets it back once that capture records or is cancelled, and only once",
        arguments: [ScreencastPhase.recording, .idle]
    )
    func nextCaptureGivesTheFrontBack(once phase: ScreencastPhase) async throws {
        defer { fixture.tearDown() }
        let front = FrontStandIn()
        let flow = flow(outcomes: ReviewOutcomeLog(), notices: ReviewNotices(), front: front.front)
        await flow.show(try fixture.video(), context: .none)
        let panel = try #require(flow.panel)
        front.windowTakesTheFront(panel.window)

        flow.captureStarting()
        flow.capturePhaseChanged(.picking)
        front.keyWindow = nil
        try await eventually { panel.model == nil }
        flow.capturePhaseChanged(.countingDown(remaining: 1))
        flow.capturePhaseChanged(.starting)
        #expect(front.activated.isEmpty, "nothing while the picker and the countdown have the keyboard")

        flow.capturePhaseChanged(phase)
        #expect(front.activated == [FrontStandIn.appBefore])
        flow.capturePhaseChanged(.recording)
        flow.capturePhaseChanged(.idle)
        #expect(front.activated == [FrontStandIn.appBefore], "once")
    }

    @Test("The front goes back only where the window had it: not if another app had the keyboard when the capture started, nor if another app was made active meanwhile")
    func nextCaptureLeavesTheFrontWhereItIs() async throws {
        defer { fixture.tearDown() }
        let front = FrontStandIn()
        let flow = flow(outcomes: ReviewOutcomeLog(), notices: ReviewNotices(), front: front.front)
        await flow.show(try fixture.video(name: "1791000000"), context: .none)
        let panel = try #require(flow.panel)
        front.windowTakesTheFront(panel.window)
        // The person clicks another app, then starts a capture.
        front.anotherAppTakesTheFront(201)
        flow.captureStarting()
        try await eventually { panel.model == nil }
        flow.capturePhaseChanged(.recording)
        flow.capturePhaseChanged(.idle)
        #expect(front.activated.isEmpty, "nothing, then or later")

        // The next window gives the front to the app before it, not to the one before the first.
        await flow.show(try fixture.video(name: "1791000100"), context: .none)
        front.windowTakesTheFront(panel.window)
        await panel.model?.save()
        #expect(front.activated == [201])

        // A capture closes a window with the keyboard, but the person makes another app active
        // during the picker: that app keeps the front.
        front.appInFront = 202
        await flow.show(try fixture.video(name: "1791000200"), context: .none)
        front.windowTakesTheFront(panel.window)
        flow.captureStarting()
        front.anotherAppTakesTheFront(203)
        try await eventually { panel.model == nil }
        flow.capturePhaseChanged(.recording)
        #expect(front.activated == [201], "Keybumps no longer has the front to give")
    }

    @Test("Captures taking turns: the window closing for the next one activates no app, and the next window, as it closes, gives the front to the app before the first")
    func turnKeepsTheAppBefore() async throws {
        defer { fixture.tearDown() }
        let front = FrontStandIn()
        let outcomes = ReviewOutcomeLog()
        let flow = flow(outcomes: outcomes, notices: ReviewNotices(), front: front.front)
        let first = try fixture.video(name: "1791000000")
        await flow.show(first, context: .none)
        let panel = try #require(flow.panel)
        front.windowTakesTheFront(panel.window)

        let second = try fixture.video(name: "1791000100")
        await flow.show(second, context: .none)
        #expect(outcomes.outcomes == [.saved(first)] && panel.model?.input == second)
        #expect(front.activated.isEmpty, "the next window has the front")

        await panel.model?.save()
        #expect(front.activated == [FrontStandIn.appBefore])
    }

    @Test(
        "Save, Copy, Discard, and Escape each close the window and give the front back to the app before it, once; a window without the keyboard gives none",
        arguments: ReviewChoice.allCases
    )
    func eachChoiceGivesTheFrontBack(_ choice: ReviewChoice) async throws {
        defer { fixture.tearDown() }
        let front = FrontStandIn()
        let flow = flow(outcomes: ReviewOutcomeLog(), notices: ReviewNotices(), front: front.front)
        for (name, hasKeyboard) in [("1791000000", true), ("1791000100", false)] {
            front.appInFront = FrontStandIn.appBefore
            await flow.show(try fixture.video(name: name), context: .none)
            let panel = try #require(flow.panel)
            front.windowTakesTheFront(panel.window)
            if !hasKeyboard { front.anotherAppTakesTheFront(201) }
            let model = try #require(panel.model)
            switch choice {
            case .save: await model.save()
            case .copy: await model.copy()
            case .discard:
                model.askToDiscard()
                model.confirmDiscard()
            case .escape: #expect(panel.perform(.close))
            }
            try await eventually { panel.model == nil }
        }
        #expect(front.activated == [FrontStandIn.appBefore], "for the window with the keyboard only")
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

        // ⌘C copies, as Copy's keycap says; never while Discard is asked, and not with other modifiers.
        func copyKey(
            _ modifiers: NSEvent.ModifierFlags, _ characters: String = "c", keyCode: UInt16 = 8, confirming: Bool = false
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: keyCode, modifiers: modifiers, characters: characters, isComposing: false, isConfirmingDiscard: confirming
            )
        }
        #expect(copyKey(.command) == .copy)
        #expect(copyKey([.command, .capsLock]) == .copy, "Caps Lock doesn't count")
        #expect(copyKey(.command, "C") == .copy)
        #expect(copyKey(.command, confirming: true) == .ignore, "never while Discard is asked")
        #expect(copyKey([.command, .shift]) == .pass)
        #expect(copyKey([.command, .option]) == .pass)
        #expect(copyKey([]) == .tool(.crop), "C alone picks Crop (#517), never copies")
        #expect(copyKey(.command, "v") == .pass)

        // The layout's C wherever it is, or the C key on a layout with no Latin letters, as menus do.
        #expect(copyKey(.command, "\u{441}") == .copy, "Russian's С, on the C key")
        #expect(copyKey(.command, "\u{43C}", keyCode: 9) == .pass, "Russian's М, on the V key")
        #expect(copyKey(.command, "\u{441}", confirming: true) == .ignore)
        #expect(copyKey(.command, "j") == .pass, "Dvorak's J, on the C key")
        #expect(copyKey(.command, "c", keyCode: 34) == .copy, "Dvorak's C, on the I key")

        // Tab and Shift-Tab let the bar take the keyboard, and go on to the window.
        #expect(action(48) == .tab && action(48, .shift) == .tab)
        #expect(action(48, .command) == .pass, "⌘Tab is macOS's")

        // A button in the bar with the keyboard (Full Keyboard Access) keeps Space; Return still saves.
        func focused(_ key: UInt16, confirming: Bool = false) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: key, modifiers: [], isComposing: false, isConfirmingDiscard: confirming, controlHasKeyboard: true
            )
        }
        #expect(focused(49) == .pass, "Space presses the button")
        #expect(focused(36) == .save && focused(76) == .save, "Return is the window's, never the focused button's")
        #expect(focused(36, confirming: true) == .ignore, "Return still never answers the discard question")
        #expect(focused(53) == .close && focused(53, confirming: true) == .keep, "Escape is the window's")
    }

    @Test("With Full Keyboard Access, Space goes to the bar's button that has the keyboard, and Return still saves; in the player, or with nothing focused, Space plays")
    func focusedButtonKeepsItsKeys() async throws {
        defer { fixture.tearDown() }
        let fullKeyboardAccess = KeyboardNavigation()
        let panel = panel(outcomes: ReviewOutcomeLog(), fullKeyboardAccess: { fullKeyboardAccess.isOn })
        await panel.show(try fixture.video())
        let window = panel.window
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .togglePlay, "nothing has the keyboard as it opens")
        #expect(panel.action(forKey: 36, modifiers: [], in: window) == .save)

        // A focused SwiftUI button isn't a view: the content view, the bar's host, has the keyboard.
        let content = try #require(window.contentView)
        #expect(window.barHas(content))

        // Where Tab puts the keyboard: a control in the bar, in the window's content.
        let button = FocusableStandIn()
        content.addSubview(button)
        #expect(!panel.perform(.tab), "Tab goes on to the window")
        #expect(window.makeFirstResponder(button))
        #expect(window.barHas(window.firstResponder))
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .pass, "Space presses the button")
        #expect(panel.action(forKey: 36, modifiers: [], in: window) == .save, "Return still saves")
        #expect(panel.action(forKey: 76, modifiers: [], in: window) == .save, "the keypad's Enter too")
        #expect(panel.action(forKey: 53, modifiers: [], in: window) == .close)

        fullKeyboardAccess.isOn = false
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .togglePlay, "without it, no button takes keys")

        // The keyboard in the player, such as its controls, not the bar: the review's keys again.
        fullKeyboardAccess.isOn = true
        let player = AVPlayerView()
        content.addSubview(player)
        let inPlayer = FocusableStandIn()
        player.addSubview(inPlayer)
        #expect(window.makeFirstResponder(inPlayer) && !window.barHas(window.firstResponder))
        #expect(panel.action(forKey: 49, modifiers: [], in: window) == .togglePlay)
        #expect(panel.action(forKey: 36, modifiers: [], in: window) == .save)
        #expect(!window.barHas(NSView()), "a view outside the window")
        button.removeFromSuperview()
        player.removeFromSuperview()
        await panel.close()
    }

    @Test("With Keyboard Navigation on, nothing in the bar takes the keyboard until Tab, so Space plays at open, for each recording")
    func barWaitsForTab() async throws {
        defer { fixture.tearDown() }
        let panel = panel(outcomes: ReviewOutcomeLog(), fullKeyboardAccess: { true })
        for name in ["1791000000", "1791000100"] {
            await panel.show(try fixture.video(name: name))
            let window = panel.window
            let button = FocusableStandIn()
            try #require(window.contentView).addSubview(button)
            #expect(!window.makeFirstResponder(button), "as it opens")
            #expect(!window.barHas(window.firstResponder))
            #expect(panel.action(forKey: 49, modifiers: [], in: window) == .togglePlay, "Space plays")

            #expect(panel.action(forKey: 48, modifiers: [.shift], in: window) == .tab)
            #expect(!panel.perform(.tab))
            #expect(window.makeFirstResponder(button), "after Tab")
            #expect(panel.action(forKey: 49, modifiers: [], in: window) == .pass, "Space presses it")
            button.removeFromSuperview()
            await panel.close()
        }
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

/// How a review ends, for the tests of who gets the front.
enum ReviewChoice: CaseIterable, Sendable {
    case save, copy, discard, escape
}

/// Who has the front, as macOS would say: the app in front, whether Keybumps is active, and the
/// window with the keyboard. It records the apps the review gives the front to, and activates none.
@MainActor
final class FrontStandIn {
    /// The app in front before the first review window.
    static let appBefore: pid_t = 101

    var appInFront: pid_t? = appBefore
    var keybumpsIsActive = false
    var keyWindow: NSWindow?
    private(set) var activated: [pid_t] = []

    var front: ScreencastReviewFront {
        ScreencastReviewFront(
            otherAppInFront: { self.appInFront },
            keybumpsIsActive: { self.keybumpsIsActive },
            windowHasKeyboard: { $0 === self.keyWindow },
            activate: { self.activated.append($0) }
        )
    }

    /// The review's window is up: Keybumps is in front, and the window has the keyboard.
    func windowTakesTheFront(_ window: NSWindow) {
        appInFront = nil
        keybumpsIsActive = true
        keyWindow = window
    }

    /// The person clicks another app.
    func anotherAppTakesTheFront(_ app: pid_t) {
        appInFront = app
        keybumpsIsActive = false
        keyWindow = nil
    }
}

/// A control that takes the keyboard, as a button in the bar does under Full Keyboard Access.
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
