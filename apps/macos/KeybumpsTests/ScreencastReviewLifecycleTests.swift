import AppKit
import Foundation
import Testing
@testable import Keybumps

/// The review panel around the person's choices (#464's review): the editor opened from it, a quit
/// or relaunch, a trim a quit interrupted, Screencast turned off while a capture waits, captures
/// that arrive one after another, and a context read that comes late. Made-up captures in a
/// temporary folder, a named pasteboard, and no window ordered in.
@MainActor
@Suite("Screencast: the review panel's lifecycle")
struct ScreencastReviewLifecycleTests {
    let fixture = ReviewFixture()
    static let safari = ScreencastCaptureContext(appBundleIdentifier: "com.apple.Safari", appName: "Safari", domain: "keybumps.app")

    private func repository(_ text: String) throws -> ScreencastRepository {
        try #require(ScreencastRepository(text))
    }

    private func panel(
        trimmer: any ScreencastTrimming = FakeTrimmer(),
        editor: (any ScreencastScreenshotEditing)? = nil,
        screenshots: (any ScreencastScreenshotsLibrary)? = nil,
        outcomes: ReviewOutcomeLog
    ) -> ScreencastReviewPanel {
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            editor: { editor },
            trimmer: trimmer,
            screenshots: { screenshots },
            settings: ScreencastReviewSettings(defaults: fixture.defaults),
            screen: { nil }
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

    // MARK: The Screenshot Editor opened from the panel

    @Test("Edit, then Save with ⌘3 on: the editor doesn't copy, and ⌘3 gets exactly one item, the marked-up one")
    func editThenSaveAddsTheMarkedUpImage() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        let editor = FakeScreenshotEditor()
        let changeCount = fixture.pasteboard.changeCount
        let model = fixture.model(input, editor: editor, screenshots: fixture.clipboard)
        model.edit()
        #expect(editor.copyRequests == [false], "the panel's Copy is the copy")
        let edited = input.folder.appendingPathComponent("screenshot-1 (edited).png")
        try ReviewFixture.png(seed: "marked up").write(to: edited)
        editor.finishEditing(savedAt: edited)

        await model.save()
        fixture.clipboard.pollForTesting()
        let entries = fixture.clipboard.entries
        #expect(entries.count == 1)
        #expect(entries.first?.isScreenshot == true && entries.first?.sourcePath == edited.path)
        #expect(fixture.pasteboard.changeCount == changeCount)
    }

    @Test("Edit, then Discard: nothing is left in Clipboard History")
    func editThenDiscardLeavesNothing() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.screenshot()
        let editor = FakeScreenshotEditor()
        let model = fixture.model(input, editor: editor, screenshots: fixture.clipboard)
        model.edit()
        let edited = input.folder.appendingPathComponent("screenshot-1 (edited).png")
        try ReviewFixture.png(seed: "marked up").write(to: edited)
        editor.finishEditing(savedAt: edited)
        model.askToDiscard()
        model.confirmDiscard()

        fixture.clipboard.pollForTesting()
        #expect(model.isFinished && fixture.clipboard.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: input.folder.path))
    }

    @Test("The Screenshot Editor opened from the panel saves its copy without the clipboard; Screenshot Tools' own still copies")
    func editorSaveWithoutCopy() throws {
        defer { fixture.tearDown() }
        guard case .screenshot(let screenshot) = try fixture.screenshot() else { return }
        let file = screenshot.images[0].file
        let source = try #require(ScreenshotRenderSource(imageData: Data(contentsOf: file)))
        let before = fixture.pasteboard.changeCount

        var quietResult: ScreenshotEditorWindowController.Result?
        let quiet = ScreenshotEditorWindowController(
            source: source, sourceURL: file, fallbackFolder: screenshot.folder, pasteboard: fixture.pasteboard, copiesToClipboard: false
        )
        quiet.onFinish = { quietResult = $0 }
        quiet.save()
        #expect(fixture.pasteboard.changeCount == before)
        #expect(quietResult?.copied == false)
        #expect(quietResult?.savedURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        var copyingResult: ScreenshotEditorWindowController.Result?
        let copying = ScreenshotEditorWindowController(source: source, sourceURL: file, fallbackFolder: screenshot.folder, pasteboard: fixture.pasteboard)
        copying.onFinish = { copyingResult = $0 }
        copying.save()
        #expect(copyingResult?.copied == true && fixture.pasteboard.data(forType: .png) != nil)
    }

    // MARK: Quitting

    @Test("Quitting saves the review at once, without a trim not yet applied, which keeps the originals")
    func quitSavesAtOnce() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video(mixdown: true)
        let trimmer = FakeTrimmer()
        let model = fixture.model(input, trimmer: trimmer)
        model.note = "typed before quitting"
        model.repositoryText = "serpcompany/keybumps"
        model.setTrim(ScreencastTrimRange(start: 1, end: 3, within: 4))

        model.saveNow()
        #expect(model.isFinished && fixture.outcomes == [.saved(input)])
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "typed before quitting")
        #expect(ScreencastReview.read(from: input.metadataURL)?.repository == "serpcompany/keybumps")
        #expect(trimmer.cutCount == 0)
        #expect(try fixture.originalContents(of: input) == ["original video-1.mov", "original video-1-mixdown.mp4"])
    }

    @Test("A quit during a trim's cut saves the review; a cut that finishes anyway still records its durations")
    func quitDuringATrim() async throws {
        defer { fixture.tearDown() }
        let input = try fixture.video(mixdown: false)
        let trimmer = FakeTrimmer(holds: true)
        let model = fixture.model(input, trimmer: trimmer)
        model.note = "mid-trim"
        model.setTrim(ScreencastTrimRange(start: 1, end: 3, within: 4))
        let saving = Task { await model.save() }
        try await eventually { trimmer.isHolding }

        model.saveNow()
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "mid-trim")
        #expect(try ScreencastMetadata.read(from: input.metadataURL).duration == 4)
        trimmer.release()
        await saving.value
        #expect(try ScreencastMetadata.read(from: input.metadataURL).duration == 2, "the cut swapped in, so its length is recorded")
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "mid-trim")
    }

    @Test("At launch, what an interrupted trim left aside is put back or removed, and nothing else is touched")
    func recoversInterruptedTrims() throws {
        defer { fixture.tearDown() }
        let folder = fixture.folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        try write("video-1.mov", "cut 1")
        try write(".video-1.untrimmed.mov", "original 1")
        try write(".video-2.untrimmed.mov", "original 2")
        try write(".video-1-mixdown.trimmed.mp4", "cut mixdown")
        try write(".DS_Store", "finder")
        try write("meta.json", "{}")
        try Data("loose".utf8).write(to: fixture.folder.url.appendingPathComponent(".video-9.trimmed.mov"))

        ScreencastReviewFiles.recoverInterruptedTrims(in: fixture.folder.url, fileManager: .default)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == [".DS_Store", "meta.json", "video-1.mov", "video-2.mov"])
        #expect(try String(contentsOf: folder.appendingPathComponent("video-1.mov"), encoding: .utf8) == "cut 1",
                "a cut already swapped in stays, as the trim would have left it")
        #expect(try String(contentsOf: folder.appendingPathComponent("video-2.mov"), encoding: .utf8) == "original 2",
                "an original with nothing in its place goes back")
        #expect(FileManager.default.fileExists(atPath: fixture.folder.url.appendingPathComponent(".video-9.trimmed.mov").path),
                "only capture folders are looked in")
        #expect(ScreencastReviewFiles.visibleName(ofSideFile: ".video-1.trimmed.mov", tag: "trimmed") == "video-1.mov")
        #expect(ScreencastReviewFiles.visibleName(ofSideFile: ".trimmed.mov", tag: "trimmed") == nil)
        #expect(ScreencastReviewFiles.visibleName(ofSideFile: "video-1.trimmed.mov", tag: "trimmed") == nil)
    }

    // MARK: Turning Screencast off, and captures taking turns

    @Test("A capture finishing as Screencast turns off is saved, with its context once read, and never shown")
    func turnedOffBeforeThePanelOpens() async throws {
        defer { fixture.tearDown() }
        let gate = ContextGate()
        let flow = ScreencastReviewFlow(
            services: ScreencastReviewServices(
                clipboard: fixture.clipboard,
                isClipboardHistoryOn: { false },
                editor: { nil },
                settings: ScreencastReviewSettings(defaults: fixture.defaults),
                notices: nil,
                repositories: { [fixture] in fixture.repositories }
            ),
            contextReader: ScreencastCaptureContextReader {
                await gate.wait()
                return Self.safari
            }
        )
        guard case .screenshot(let screenshot) = try fixture.screenshot() else { return }
        flow.captureStarting()
        flow.captureFinished(.screenshot(screenshot))
        flow.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(flow.panel?.isShown != true)

        gate.open()
        try await eventually { ScreencastReview.read(from: screenshot.metadataURL) != nil }
        #expect(flow.panel?.isShown != true, "never shown")
        #expect(ScreencastReview.read(from: screenshot.metadataURL)?.context == Self.safari)
    }

    @Test("Captures take turns: one arriving during a slow Save waits, and none is skipped or left unsaved")
    func capturesTakeTurns() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let trimmer = FakeTrimmer(holds: true)
        let panel = panel(trimmer: trimmer, outcomes: outcomes)
        let first = try fixture.video(name: "1791000000", mixdown: false)
        let second = try fixture.screenshot(name: "1791000100")
        let third = try fixture.screenshot(name: "1791000200", seed: "c")

        await panel.show(first)
        panel.model?.note = "first"
        panel.model?.setTrim(ScreencastTrimRange(start: 1, end: 3, within: 4))
        let showingSecond = Task { await panel.show(second) }
        try await eventually { trimmer.isHolding }
        let showingThird = Task { await panel.show(third) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.model?.input == first, "the first is still saving")

        trimmer.release()
        await showingSecond.value
        await showingThird.value
        #expect(outcomes.outcomes.map(\.folder) == [first.folder, second.folder])
        #expect(panel.model?.input == third)
        #expect(ScreencastReview.read(from: first.metadataURL)?.note == "first")
        #expect(ScreencastReview.read(from: second.metadataURL) != nil, "the second was shown, then saved")
        await panel.close()
    }

    @Test("While the editor is open, a new capture waits until the editor and then the panel close")
    func newCaptureWaitsForTheEditor() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let editor = FakeScreenshotEditor()
        let panel = panel(editor: editor, outcomes: outcomes)
        let first = try fixture.screenshot(name: "1791000000")
        let second = try fixture.screenshot(name: "1791000100", seed: "b")
        await panel.show(first)
        panel.model?.edit()
        #expect(panel.model?.isEditing == true)

        let showingSecond = Task { await panel.show(second) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.model?.input == first && outcomes.outcomes.isEmpty, "nothing closes the panel under the editor")
        editor.finishEditing(savedAt: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.model?.input == first, "it waits for the person to close the panel too")

        await panel.model?.save()
        await showingSecond.value
        #expect(outcomes.outcomes == [.saved(first)])
        #expect(panel.model?.input == second)
        await panel.close()
    }

    @Test("Turning Screencast off with the editor open saves the review and leaves the editor; its later Save is recorded")
    func turnedOffWhileEditing() async throws {
        defer { fixture.tearDown() }
        let outcomes = ReviewOutcomeLog()
        let editor = FakeScreenshotEditor()
        let panel = panel(editor: editor, outcomes: outcomes)
        let input = try fixture.screenshot()
        await panel.show(input)
        panel.model?.note = "while editing"
        panel.model?.edit()

        panel.shutDown()
        try await eventually { !panel.isShown }
        #expect(outcomes.outcomes == [.saved(input)] && editor.isOpen)
        #expect(ScreencastReview.read(from: input.metadataURL)?.note == "while editing")

        let edited = input.folder.appendingPathComponent("screenshot-1 (edited).png")
        try ReviewFixture.png(seed: "late").write(to: edited)
        editor.finishEditing(savedAt: edited)
        #expect(ScreencastReview.read(from: input.metadataURL)?.editedImages == ["screenshot-1.png": "screenshot-1 (edited).png"])
    }

    // MARK: A context that comes late

    @Test("The panel shows at once; the guess fills the repository when the context comes, unless the person typed there")
    func lateContextFillsTheGuess() async throws {
        defer { fixture.tearDown() }
        fixture.repositories.remember(try repository("serpcompany/keybumps"), for: Self.safari)

        let gate = ContextGate()
        let untouched = fixture.model(try fixture.screenshot(name: "1791000000"), contextRead: Task { @MainActor in
            await gate.wait()
            return Self.safari
        })
        #expect(untouched.repositoryText.isEmpty && untouched.context == .none)
        let typed = fixture.model(try fixture.screenshot(name: "1791000100", seed: "b"), contextRead: Task { @MainActor in
            await gate.wait()
            return Self.safari
        })
        typed.repositoryText = "serpcompany/other"

        gate.open()
        try await eventually { untouched.context == Self.safari && typed.context == Self.safari }
        #expect(untouched.repositoryText == "serpcompany/keybumps")
        #expect(untouched.repositoryHint == "Remembered for keybumps.app")
        #expect(typed.repositoryText == "serpcompany/other", "what the person typed stays")
    }

    @Test("Save waits for a context still on its way, and records it")
    func saveWaitsForTheContext() async throws {
        defer { fixture.tearDown() }
        let gate = ContextGate()
        let input = try fixture.screenshot()
        let model = fixture.model(input, contextRead: Task { @MainActor in
            await gate.wait()
            return Self.safari
        })
        let saving = Task { await model.save() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.isFinished)
        gate.open()
        await saving.value
        #expect(model.isFinished)
        #expect(ScreencastReview.read(from: input.metadataURL)?.context == Self.safari)
    }
}

/// The outcomes a panel reports.
@MainActor
final class ReviewOutcomeLog {
    var outcomes: [ScreencastReviewOutcome] = []
}

/// Holds whoever waits until `open()`.
@MainActor
private final class ContextGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiting
        self.waiting = []
        waiting.forEach { $0.resume() }
    }
}

extension ScreencastReviewOutcome {
    var folder: URL? {
        switch self {
        case .saved(let input), .copied(let input): input.folder
        case .discarded: nil
        }
    }
}
