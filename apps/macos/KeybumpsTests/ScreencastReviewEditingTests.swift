import AppKit
import Foundation
import Testing
@testable import Keybumps

/// Editing in the recording window (#517): the tools, undo and redo, and what Save, Copy, and
/// closing do with edits: export first with progress, keep the original until that's complete, say
/// why when it fails, and ask before closing with edits. An export stand-in (`FakeEditExport`)
/// writes nothing; the real export has its own tests. Made-up captures in a temporary folder, a
/// named pasteboard, and no window ordered in.
@MainActor
@Suite("ScreenGrabs: editing in the recording window")
struct ScreencastReviewEditingTests {
    let fixture = ReviewFixture()

    private func panel(outcomes: ReviewOutcomeLog, export: FakeEditExport) -> ScreencastReviewPanel {
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            screen: { nil },
            makePlayback: { nil },
            export: export.export
        )
        panel.onFinish = { outcomes.outcomes.append($0) }
        return panel
    }

    /// Lets the main actor run until `condition` holds, for two seconds at most.
    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func trimmed(_ model: ScreencastReviewModel) {
        model.edit { $0.setTrim(start: 1, end: 3) }
    }

    // MARK: Tools and history

    @Test("The bar's one tool so far is Trim, number 1 and T; picking it shows the timeline, and picking it again or Escape puts it down")
    func trimTool() throws {
        defer { fixture.tearDown() }
        let tools = ScreencastEditTool.allCases.map(\.title)
        #expect(tools == ["Trim"])
        let byNumber = ScreencastEditTool.matching(key: "1")
        #expect(byNumber == .trim)
        let byLetter = ScreencastEditTool.matching(key: "T")
        #expect(byLetter == .trim)

        let model = fixture.model(try fixture.video())
        #expect(model.tool == nil && !model.showsTimeline, "a plain player until a tool is picked")
        model.pick(.trim)
        #expect(model.tool == .trim && model.showsTimeline)
        model.pick(.trim)
        #expect(model.tool == nil)
        model.pick(.trim)
        model.putToolDown()
        #expect(model.tool == nil && !model.showsTimeline)
    }

    @Test("Edits undo and redo one at a time; a drag is one edit; Cut Section cuts the selection")
    func undoAndRedo() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        #expect(!model.canUndo && !model.canRedo)

        model.beginDrag()
        model.dragEdit { $0.setTrim(start: 0.5, end: 4) }
        model.dragEdit { $0.setTrim(start: 1, end: 4) }
        model.endDrag()
        #expect(model.edits.trim == ScreencastTimeRange(start: 1, end: 4))
        #expect(model.canUndo)

        model.selectForCut(ScreencastTimeRange(start: 2, end: 3))
        model.cutSelection()
        #expect(model.edits.cuts == [ScreencastTimeRange(start: 2, end: 3)])
        #expect(model.trimSelection == nil, "the selection goes with the cut")

        model.undo()
        #expect(model.edits.cuts.isEmpty && model.edits.trim.start == 1, "the cut comes back")
        model.undo()
        #expect(model.edits.isEmpty, "the drag was one edit")
        #expect(!model.canUndo && model.canRedo)
        model.redo()
        model.redo()
        #expect(model.edits.cuts.count == 1 && model.edits.trim.start == 1)

        model.resetTrim()
        #expect(model.edits.isEmpty)
        model.undo()
        #expect(!model.edits.isEmpty)
    }

    @Test("A drag cut short by Escape, a tool, or undo is one edit then, and the next drag is its own")
    func dragCutShort() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.trim)
        model.beginDrag()
        model.dragEdit { $0.setTrim(start: 1, end: 4) }
        model.putToolDown()
        #expect(model.editRevision == 1, "the player plays it")
        #expect(model.canUndo)

        model.pick(.trim)
        model.beginDrag()
        model.dragEdit { $0.setTrim(start: 2, end: 4) }
        model.pick(.trim)
        model.undo()
        #expect(model.edits.trim.start == 1, "the second drag was its own edit")
        model.undo()
        #expect(model.edits.isEmpty && !model.canUndo)

        // ⌘Z mid-drag takes the drag back; the drag going on is a new one.
        model.redo()
        model.beginDrag()
        model.dragEdit { $0.setTrim(start: 3, end: 4) }
        model.undo()
        #expect(model.edits.trim.start == 1, "the drag is undone")
        model.dragEdit { $0.setTrim(start: 2.5, end: 4) }
        #expect(model.edits.trim.start == 1, "until it begins again")
        model.beginDrag()
        model.dragEdit { $0.setTrim(start: 2.5, end: 4) }
        model.endDrag()
        model.undo()
        #expect(model.edits.trim.start == 1, "one edit")
    }

    @Test("I and O start and end the selection at the playhead")
    func markInAndOut() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.markSelectionStart(at: 1)
        #expect(model.trimSelection == ScreencastTimeRange(start: 1, end: 4), "to the trim's end")
        model.markSelectionEnd(at: 2.5)
        #expect(model.trimSelection == ScreencastTimeRange(start: 1, end: 2.5))
    }

    @Test("A recording of several displays has one set of edits: the trim applies to all, and each display has its own crop and blurs")
    func severalDisplays() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video(displays: 2))
        #expect(model.edits.displays.count == 2)
        trimmed(model)
        model.selectedDisplay = 1
        #expect(model.edits.trim == ScreencastTimeRange(start: 1, end: 3), "the same trim on the second display")
    }

    @Test("A display whose stream stopped before the kept part: the window says Save keeps it as recorded")
    func displayWithNothingKept() throws {
        defer { fixture.tearDown() }
        guard case .video(let recorded) = try fixture.video(displays: 3) else { return }
        let videos = recorded.videos.enumerated().map { index, video in
            ScreencastVideo(
                file: video.file, mixdown: video.mixdown, pixelWidth: 64, pixelHeight: 36,
                audioTracks: video.audioTracks, duration: index == 0 ? 4 : 1
            )
        }
        let capture = ScreencastCapture(folder: recorded.folder, videos: videos, duration: 4, endedEarly: nil)
        let model = fixture.model(.video(capture))
        #expect(model.nothingKeptNotice == nil)
        model.edit { $0.setTrim(start: 0.5, end: 4) }
        #expect(model.displaysWithNothingKept.isEmpty)
        model.edit { $0.setTrim(start: 2, end: 4) }
        #expect(model.displaysWithNothingKept == [1, 2])
        let notice = model.nothingKeptNotice
        #expect(notice == "Displays 2 and 3 have nothing in the kept part. Save keeps them as they were recorded.")
    }

    @Test("The player shows a display with nothing in the kept part as such, not the picture it had")
    func playerShowsNothingKept() async throws {
        defer { fixture.tearDown() }
        let file = fixture.folder.url.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 1))
        try await EditTestMovie.write(to: file, seconds: 1, picture: .movingBar, sounds: false)
        let video = ScreencastVideo(
            file: file, mixdown: nil, pixelWidth: EditTestMovie.width, pixelHeight: EditTestMovie.height, audioTracks: [], duration: 1
        )
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 2)
        edits.setTrim(start: 0.5, end: 3)
        let playback = ScreencastReviewPlayback()
        defer { playback.stop() }
        playback.show(video, display: 1, edits: edits)
        try await eventually { abs((playback.playingLength ?? 0) - 0.5) < 0.05 }
        #expect(playback.blank == nil)

        edits.setTrim(start: 1.5, end: 3)
        playback.show(video, display: 1, edits: edits)
        #expect(playback.blank == .nothingKept)
        #expect(playback.playingLength == nil, "the picture it had is gone")
        playback.seek(toRecordingTime: 2)
        #expect(playback.recordingTime == 2, "the place is kept")
    }

    @Test("The player plays the edits and says where it is in the recording's own time; a trimmed-off time goes to where it plays on")
    func playerPlaysTheEdits() async throws {
        defer { fixture.tearDown() }
        let file = fixture.folder.url.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 0))
        try await EditTestMovie.write(to: file, seconds: 3, picture: .movingBar, sounds: false)
        let video = ScreencastVideo(
            file: file, mixdown: nil, pixelWidth: EditTestMovie.width, pixelHeight: EditTestMovie.height, audioTracks: [], duration: 3
        )
        var edits = ScreencastRecordingEdits(duration: 3, displayCount: 1)
        edits.setTrim(start: 1, end: 2.5)
        let playback = ScreencastReviewPlayback()
        defer { playback.stop() }
        playback.show(video, display: 0, edits: edits)
        try await eventually { (playback.playingLength ?? 0) > 0 && abs((playback.playingLength ?? 0) - 1.5) < 0.05 }

        playback.seek(toRecordingTime: 0.2)
        #expect(playback.recordingTime == 1, "trimmed off: the trim's start")
        playback.seek(toRecordingTime: 2)
        #expect(playback.recordingTime == 2)

        playback.show(video, display: 0, edits: ScreencastRecordingEdits(duration: 3, displayCount: 1))
        try await eventually { abs((playback.playingLength ?? 0) - 3) < 0.05 }
        #expect(playback.recordingTime == 2, "no edits: the recording, at the same place")
    }

    // MARK: Saving with edits

    @Test("With no edits, Save and Copy work as before: nothing is exported")
    func noEditsNoExport() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport()
        let recording = try fixture.video()
        let model = fixture.model(recording, export: export.export)
        await model.save()
        #expect(fixture.outcomes == [.saved(recording)])
        #expect(export.runs.isEmpty)
    }

    @Test("Save with edits exports first, with its progress and Cancel in the bar, then saves the edited recording")
    func saveExportsFirst() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport(.waitForRelease)
        let recording = try fixture.video()
        let model = fixture.model(recording, export: export.export)
        trimmed(model)
        let saving = Task { await model.save() }
        try await eventually { model.exportProgress == 0.5 }
        #expect(model.isExporting && !model.acceptsEdits && !model.canUndo)
        let actions = ScreencastRecordingReviewBar.actions(for: model).map(\.identifier)
        #expect(actions == [ScreencastReviewID.cancelExport], "Cancel is the only action")
        #expect(fixture.outcomes.isEmpty, "the original is kept until it's done")

        export.release()
        await saving.value
        #expect(export.runs.map(\.trim) == [ScreencastTimeRange(start: 1, end: 3)])
        guard case .saved(let saved)? = fixture.outcomes.first, case .video(let capture) = saved else {
            Issue.record("saved: \(fixture.outcomes)")
            return
        }
        #expect(capture.duration == 2, "the edited recording")
        #expect(!model.isExporting)
    }

    @Test("Copy with edits exports, then copies the recording")
    func copyExports() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport()
        let model = fixture.model(try fixture.video(), export: export.export)
        trimmed(model)
        await model.copy()
        #expect(export.runs.count == 1)
        guard case .copied? = fixture.outcomes.first else {
            Issue.record("copied: \(fixture.outcomes)")
            return
        }
        let files = fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        #expect(files.count == 1)
    }

    @Test("A failed export stays open with the edits and says why; Try Again exports again")
    func failureThenTryAgain() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport(.fail(.diskFull), .succeed)
        let model = fixture.model(try fixture.video(), export: export.export)
        trimmed(model)
        await model.save()
        #expect(model.exportFailure == .diskFull)
        #expect(fixture.outcomes.isEmpty && !model.isFinished, "the window stays open")
        #expect(!model.edits.isEmpty, "with the edits")
        let key = ScreencastReviewKey.action(
            keyCode: 36, modifiers: [], isComposing: false, isConfirmingDiscard: false,
            editing: .init(hasExportFailure: true)
        )
        #expect(key == .tryAgain, "Return tries again")

        await model.tryAgain()
        #expect(export.runs.count == 2)
        #expect(fixture.outcomes.count == 1 && model.exportFailure == nil)
    }

    @Test("After a failed export, Save Original saves the recording as it was recorded")
    func failureThenSaveOriginal() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport(.fail(.failed))
        let recording = try fixture.video()
        let model = fixture.model(recording, export: export.export)
        trimmed(model)
        await model.copy()
        #expect(model.exportFailure == .failed)
        await model.saveOriginal()
        #expect(fixture.outcomes == [.saved(recording)])
        #expect(export.runs.count == 1, "not exported again")
    }

    @Test("Cancel stops the export: no failure, and the window stays with the edits")
    func cancel() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport(.waitForCancel)
        let model = fixture.model(try fixture.video(), export: export.export)
        trimmed(model)
        let saving = Task { await model.save() }
        try await eventually { model.isExporting }
        model.cancelExport()
        await saving.value
        #expect(!model.isExporting && model.exportFailure == nil)
        #expect(fixture.outcomes.isEmpty && !model.edits.isEmpty)
    }

    /// The stand-in edited copies `FakeEditExport` leaves beside `capture`'s files.
    private func partialFiles(of input: ScreencastReviewInput) -> [String] {
        guard case .video(let capture) = input else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: capture.folder.path)) ?? []
        return names.filter { $0.contains(".editing.") }
    }

    /// The fixture's stand-in originals, as written.
    private func originalsUntouched(_ input: ScreencastReviewInput) -> Bool {
        guard case .video(let capture) = input else { return false }
        return capture.videos.allSatisfy { video in
            (try? Data(contentsOf: video.file)) == Data("original \(video.file.lastPathComponent)".utf8)
        }
    }

    @Test("Closing while the edits are exported cancels it, keeps the original, and deletes the edited copies")
    func closeCancelsAnExport() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport(.waitForCancel)
        export.writesPartialFiles = true
        let recording = try fixture.video()
        let model = fixture.model(recording, export: export.export)
        trimmed(model)
        let saving = Task { await model.save() }
        try await eventually { model.isExporting }
        #expect(partialFiles(of: recording).count == 2, "the stand-in's copies are there")

        await model.close()
        await saving.value
        #expect(export.sawCancel)
        #expect(fixture.outcomes == [.saved(recording)], "saved as recorded")
        #expect(partialFiles(of: recording).isEmpty)
        #expect(originalsUntouched(recording))
        #expect(export.runs.count == 1, "not exported again")
    }

    @Test("Quitting while the edits are exported saves the original at once, and the edited copies go before it returns")
    func saveNowCancelsAnExport() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport(.waitForCancel)
        export.writesPartialFiles = true
        let recording = try fixture.video()
        let model = fixture.model(recording, export: export.export)
        trimmed(model)
        let saving = Task { await model.save() }
        try await eventually { model.isExporting }

        model.saveNow()
        #expect(fixture.outcomes == [.saved(recording)], "at once")
        #expect(partialFiles(of: recording).isEmpty, "already")
        await saving.value
        #expect(export.sawCancel)
        #expect(fixture.outcomes.count == 1)
        #expect(originalsUntouched(recording))
    }

    @Test("The next capture, while the edits are exported, cancels it and keeps the original")
    func nextCaptureCancelsAnExport() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let export = FakeEditExport(.waitForCancel)
        export.writesPartialFiles = true
        let panel = panel(outcomes: outcomes, export: export)
        let recording = try fixture.video()
        await panel.show(recording)
        let model = try #require(panel.model)
        trimmed(model)
        let saving = Task { await model.save() }
        try await eventually { model.isExporting }

        panel.makeWayForNextCapture()
        try await eventually { !outcomes.outcomes.isEmpty }
        await saving.value
        #expect(export.sawCancel)
        #expect(outcomes.outcomes == [.saved(recording)])
        #expect(partialFiles(of: recording).isEmpty)
        #expect(originalsUntouched(recording))
    }

    // MARK: Closing with edits

    @Test("Closing with edits asks \"Save your edits?\": Keep Original saves it as recorded, without exporting")
    func closeAsksKeepOriginal() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let export = FakeEditExport()
        let panel = panel(outcomes: outcomes, export: export)
        let recording = try fixture.video()
        await panel.show(recording)
        let model = try #require(panel.model)
        trimmed(model)

        await panel.requestClose()
        #expect(model.isAskingToSaveEdits && outcomes.outcomes.isEmpty, "asked, not closed")
        #expect(ScreencastRecordingReviewBar.question(for: model) == "Save your edits?")
        let actions = ScreencastRecordingReviewBar.actions(for: model)
        let titles = actions.map(\.title)
        #expect(titles == ["Keep Original", "Save Edited"])
        let defaults = actions.filter(\.isDefault).map(\.title)
        #expect(defaults == ["Save Edited"])

        await model.keepOriginal()
        #expect(outcomes.outcomes == [.saved(recording)])
        #expect(export.runs.isEmpty)
    }

    @Test("Asked, Save Edited exports, and Escape goes back to editing")
    func closeAsksSaveEdited() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let export = FakeEditExport()
        let panel = panel(outcomes: outcomes, export: export)
        await panel.show(try fixture.video())
        let model = try #require(panel.model)
        trimmed(model)
        await panel.requestClose()
        let escape = ScreencastReviewKey.action(
            keyCode: 53, modifiers: [], isComposing: false, isConfirmingDiscard: false, editing: .init(isAskingToSaveEdits: true)
        )
        #expect(escape == .dismissQuestion)
        panel.perform(escape)
        #expect(!model.isAskingToSaveEdits && outcomes.outcomes.isEmpty)

        await panel.requestClose()
        await model.saveEdited()
        #expect(export.runs.count == 1 && outcomes.outcomes.count == 1)
    }

    @Test("The ways out that can't ask keep the original: the next capture closes the window without exporting")
    func nextCaptureKeepsTheOriginal() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let export = FakeEditExport()
        let panel = panel(outcomes: outcomes, export: export)
        let recording = try fixture.video()
        await panel.show(recording)
        trimmed(try #require(panel.model))
        panel.makeWayForNextCapture()
        try await eventually { !outcomes.outcomes.isEmpty }
        #expect(outcomes.outcomes == [.saved(recording)])
        #expect(export.runs.isEmpty)
    }

    // MARK: Keys

    @Test("Keys: a tool's number or letter, undo and redo, ⌫ and I and O with Trim, and Escape putting the tool down first")
    func keys() {
        func key(
            _ code: UInt16, _ characters: String?, _ modifiers: NSEvent.ModifierFlags = [],
            _ editing: ScreencastReviewKey.Editing = .none
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: code, modifiers: modifiers, characters: characters, isComposing: false,
                isConfirmingDiscard: false, editing: editing
            )
        }
        let trim = ScreencastReviewKey.Editing(tool: .trim)
        #expect(key(18, "1") == .tool(.trim))
        #expect(key(17, "t") == .tool(.trim))
        #expect(key(6, "z", .command) == .undo)
        #expect(key(6, "z", [.command, .shift]) == .redo)
        #expect(key(51, nil) == .pass, "⌫ does nothing without Trim")
        #expect(key(51, nil, [], trim) == .cutSelection)
        #expect(key(34, "i", [], trim) == .markIn)
        #expect(key(31, "o", [], trim) == .markOut)
        #expect(key(53, nil, [], trim) == .putToolDown)
        #expect(key(53, nil) == .close)
        #expect(key(36, nil) == .save)

        let exporting = ScreencastReviewKey.Editing(isExporting: true)
        #expect(key(53, nil, [], exporting) == .cancelExport)
        #expect(key(36, nil, [], exporting) == .ignore, "nothing else while it's written")
        #expect(key(8, "c", .command, exporting) == .ignore)
        #expect(key(49, " ", [], exporting) == .togglePlay, "Space still plays")

        let asking = ScreencastReviewKey.Editing(isAskingToSaveEdits: true)
        #expect(key(36, nil, [], asking) == .saveEdited)
        #expect(key(8, "c", .command, asking) == .ignore)
        #expect(key(6, "z", .command, asking) == .ignore)
    }
}

/// An export that writes nothing, unless `writesPartialFiles` says to leave stand-in edited copies
/// where the real one writes them, as a quit would: it records the edits it was given, reports half
/// its progress, then does what the test says, in turn, the last again.
final class FakeEditExport: @unchecked Sendable {
    enum Behavior {
        case succeed
        case fail(ScreencastExportFailure)
        /// Waits until `release()`, then succeeds.
        case waitForRelease
        /// Waits until it's cancelled.
        case waitForCancel
    }

    private let lock = NSLock()
    private var behaviors: [Behavior]
    private var storedRuns: [ScreencastRecordingEdits] = []
    private var released = false
    private var storedSawCancel = false
    /// Leaves an edited copy beside each file, and doesn't delete it.
    var writesPartialFiles = false

    init(_ behaviors: Behavior...) {
        self.behaviors = behaviors.isEmpty ? [.succeed] : behaviors
    }

    var runs: [ScreencastRecordingEdits] { lock.withLock { storedRuns } }

    func release() { lock.withLock { released = true } }

    /// Whether a run waiting to be cancelled was.
    var sawCancel: Bool { lock.withLock { storedSawCancel } }

    var export: ScreencastEditExport {
        ScreencastEditExport { [self] capture, edits, cancellation, progress in
            let behavior = lock.withLock {
                storedRuns.append(edits)
                return behaviors.count > 1 ? behaviors.removeFirst() : behaviors[0]
            }
            if writesPartialFiles {
                for file in capture.videos.flatMap({ [$0.file, $0.mixdown].compactMap { $0 } }) {
                    FileManager.default.createFile(atPath: ScreencastEditExporter.editingURL(for: file).path, contents: Data("partial".utf8))
                }
            }
            progress(0.5)
            switch behavior {
            case .succeed:
                break
            case .fail(let failure):
                throw failure
            case .waitForRelease:
                while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
            case .waitForCancel:
                while !cancellation.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
                lock.withLock { storedSawCancel = true }
                throw ScreencastExportFailure.cancelled
            }
            return ScreencastCapture(
                folder: capture.folder,
                videos: capture.videos.map { video in
                    ScreencastVideo(
                        file: video.file, mixdown: video.mixdown, pixelWidth: video.pixelWidth, pixelHeight: video.pixelHeight,
                        audioTracks: video.audioTracks, duration: edits.length
                    )
                },
                duration: edits.length,
                endedEarly: capture.endedEarly
            )
        }
    }
}
