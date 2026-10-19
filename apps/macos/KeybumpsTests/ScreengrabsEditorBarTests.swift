import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// The bar the Screenshot Editor and the recording window share (#511): each window's actions, in
/// order, with their keys and the default button, and whether it has undo and redo, recorded in a
/// fixture; the editor's tools, colors, and undo and redo through its bar; and the bar as each window
/// lays it out, drawn off screen. No window is ordered in, and the review writes to a named pasteboard.
///
/// Re-record the fixture only with `KEYBUMPS_RECORD_SNAPSHOTS=1` (through xcodebuild:
/// `TEST_RUNNER_KEYBUMPS_RECORD_SNAPSHOTS=1`), running this suite alone.
@MainActor
@Suite("ScreenGrabs: the editor bar")
struct ScreengrabsEditorBarTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/screengrabs-editor-bar.json")

    let fixture = ReviewFixture()

    // MARK: Each window's actions

    @Test("The Screenshot Editor's actions: Cancel with esc, then Save with Return's sign, filled with the accent color; Return is its key monitor's, so Save isn't the default button")
    func screenshotEditorActions() {
        let actions = ScreenshotEditorWindowController.barActions(cancel: {}, save: {})
        let titles = actions.map(\.title)
        #expect(titles == ["Cancel", "Save"])
        let keys = actions.map(\.key)
        #expect(keys == ["esc", "↩"])
        let styles = actions.map(\.style)
        #expect(styles == [.standard, .prominent])
        let defaults = actions.filter(\.isDefault)
        #expect(defaults.isEmpty, "Return in its text box ends the text")
        #expect(ScreenshotEditorWindowController.isSaveKey("\r", modifiers: []), "Return saves")
    }

    @Test("The Screenshot Editor's actions cancel and save")
    func screenshotEditorActionsAct() {
        let log = ActionLog()
        let actions = ScreenshotEditorWindowController.barActions(cancel: { log.add("cancel") }, save: { log.add("save") })
        for action in actions { action.perform() }
        #expect(log.calls == ["cancel", "save"])
    }

    @Test("The recording window's actions: Discard, Copy with ⌘C, and Save with Return's sign, the prominent default button; the discard question's Keep and Discard answer to no key")
    func recordingActions() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        let actions = ScreencastRecordingReviewBar.actions(for: model)
        let titles = actions.map(\.title)
        #expect(titles == ["Discard", "Copy", "Save"])
        let keys = actions.map(\.key)
        #expect(keys == [nil, "⌘C", "↩"])
        let defaults = actions.filter(\.isDefault).map(\.title)
        #expect(defaults == ["Save"])
        #expect(actions.last?.style == .prominent, "Save last, filled with the accent color")

        model.askToDiscard()
        let answers = ScreencastRecordingReviewBar.actions(for: model)
        let answerTitles = answers.map(\.title)
        #expect(answerTitles == ["Keep", "Discard"])
        #expect(answers.allSatisfy { $0.key == nil && !$0.isDefault }, "no key deletes")
    }

    // MARK: What moved into the bar

    @Test("The Screenshot Editor's bar picks its tools, Arrow first and picked when it opens (#544), and colors, and dims the colors for a tool drawn in none")
    func screenshotEditorToolsAndColors() throws {
        let model = ScreenshotEditorModel()
        let bar = ScreenshotEditorBar(model: model, cancel: {}, save: {})
        let titles = bar.tools.map(\.title)
        #expect(titles == ["Arrow", "Text", "Draw", "Blur", "Redact"])
        #expect(bar.tools.map(\.number) == ["1", "2", "3", "4", "5"])
        #expect(bar.tools.filter(\.isSelected).map(\.title) == ["Arrow"])
        #expect(bar.swatchesAreEnabled)

        try #require(bar.tools.last).select()
        #expect(model.tool == .redact)
        #expect(bar.tools.filter(\.isSelected).map(\.title) == ["Redact"])
        #expect(!bar.swatchesAreEnabled, "Redact has no color")

        let colors = bar.swatches.map(\.color)
        #expect(colors == ScreenshotAnnotationColor.allCases)
        try #require(bar.swatches.first { $0.color == .blue }).pick()
        #expect(model.color == .blue)
        #expect(bar.swatches.filter(\.isSelected).map(\.color) == [.blue])
    }

    @Test("The Screenshot Editor's bar undoes and redoes the model's marks, each only when there's one to take back or put back")
    func screenshotEditorUndoAndRedo() throws {
        let model = ScreenshotEditorModel()
        let bar = ScreenshotEditorBar(model: model, cancel: {}, save: {})
        let fresh = try #require(bar.history)
        #expect(!fresh.canUndo && !fresh.canRedo)

        model.add(ScreenshotAnnotation(kind: .arrow(start: .zero, end: CGPoint(x: 40, y: 0))))
        let marked = try #require(bar.history)
        #expect(marked.canUndo && !marked.canRedo)
        marked.undo()
        #expect(model.history.isEmpty)

        let undone = try #require(bar.history)
        #expect(!undone.canUndo && undone.canRedo)
        undone.redo()
        #expect(model.history.annotations.count == 1)
    }

    @Test("The recording window's bar has undo and redo, each on only once there's an edit to take back or put back (#517)")
    func recordingBarHistory() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        let history = try #require(ScreencastRecordingReviewBar(model: model).history)
        #expect(!history.canUndo && !history.canRedo)
        model.edit { $0.setTrim(start: 1, end: 3) }
        let edited = try #require(ScreencastRecordingReviewBar(model: model).history)
        #expect(edited.canUndo && !edited.canRedo)
        edited.undo()
        let undone = try #require(ScreencastRecordingReviewBar(model: model).history)
        #expect(!undone.canUndo && undone.canRedo)
    }

    @Test("Both windows' bars match the fixture: whether each has undo and redo, and each action's title, key, style, default button, identifier, and help, in order; the recording window's tools, and Crop's and Blur's options")
    func barsMatchTheFixture() async throws {
        defer { fixture.tearDown() }
        let actual = try Self.encode(try await snapshot())
        if ProcessInfo.processInfo.environment["KEYBUMPS_RECORD_SNAPSHOTS"] == "1" {
            try actual.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        if actual != expected {
            Attachment.record(actual, named: "screengrabs-editor-bar.actual.json")
            Issue.record("The editor bar changed. Re-record \(Self.fixtureURL.lastPathComponent) if that's intended, and review its diff.")
        }
    }

    // MARK: As laid out

    @Test("Each window's bar fits the window at its narrowest, 64 points tall: the Screenshot Editor's at 840 points, the recording window's at 760, with two displays' picker or the discard question; with Trim's, Crop's, or Blur's options in full, the narrowest Mac screen")
    func barsFitTheirWindows() throws {
        defer { fixture.tearDown() }
        let editor = NSHostingView(rootView: ScreenshotEditorBar(model: ScreenshotEditorModel(), cancel: {}, save: {}))
        let editorSize = editor.fittingSize
        #expect(editorSize.width <= ScreenshotEditorWindowController.minimumWidth, "\(editorSize.width) points wide")
        #expect(editorSize.height == ScreengrabsEditorBarMetrics.height)

        let model = fixture.model(try fixture.video(displays: 2))
        let recording = NSHostingView(rootView: ScreencastRecordingReviewBar(model: model))
        let recordingSize = recording.fittingSize
        let narrowest = ScreencastRecordingReviewWindow.minimumSize.width
        #expect(recordingSize.width <= narrowest, "\(recordingSize.width) points wide")
        #expect(recordingSize.height == ScreengrabsEditorBarMetrics.height)

        model.askToDiscard()
        let asking = NSHostingView(rootView: ScreencastRecordingReviewBar(model: model)).fittingSize
        #expect(asking.width <= narrowest, "asking, \(asking.width) points wide")

        // With Trim's options in full, it fits the window on the narrowest Mac screen, 1280 points
        // wide; a narrower window shows them without their titles.
        model.keep()
        model.pick(.trim)
        let trimming = NSHostingView(rootView: ScreencastRecordingReviewBar(model: model)).fittingSize
        #expect(trimming.width <= 1_280 - 2 * ScreencastRecordingReviewWindow.screenMargin, "trimming, \(trimming.width) points wide")
        model.pick(.crop)
        model.setCropAspect(.square)
        let cropping = NSHostingView(rootView: ScreencastRecordingReviewBar(model: model)).fittingSize
        #expect(cropping.width <= 1_280 - 2 * ScreencastRecordingReviewWindow.screenMargin, "cropping, \(cropping.width) points wide")
        model.pick(.blur)
        model.addBlur(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2))
        let blurring = NSHostingView(rootView: ScreencastRecordingReviewBar(model: model)).fittingSize
        #expect(blurring.width <= 1_280 - 2 * ScreencastRecordingReviewWindow.screenMargin, "blurring, \(blurring.width) points wide")
        #expect(blurring.height == ScreengrabsEditorBarMetrics.height)
    }

    @Test("An action's keycap follows its title, in full")
    func keycapFollowsTheTitle() {
        let label = NSHostingView(rootView: ScreengrabsEditorActionLabel(title: "Copy", key: "⌘C")).fittingSize.width
        let title = NSHostingView(rootView: Text("Copy")).fittingSize.width
        let key = NSHostingView(rootView: Text("⌘C").font(.system(size: 11, weight: .medium))).fittingSize.width
        #expect(label >= title + 6 + key, "the label is \(label) points wide; its title \(title), and its key \(key)")
    }

    @Test("The recording window draws the bar along its top, over the window's background, and the black player under it to the bottom")
    func recordingWindowDrawsTheBar() async throws {
        defer { fixture.tearDown() }
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories,
            pasteboard: fixture.pasteboard,
            keepOutOfClipboardHistory: {},
            screen: { nil }
        )
        await panel.show(try fixture.video())
        let window = panel.window
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 992, height: 600))
        let image = try Self.render(try #require(window.contentView))
        let barColors = image.colors(rows: 4..<60)
        #expect(barColors.count > 20, "the bar's band has drawn controls, \(barColors.count) colors")
        let below = image.colors(rows: 80..<590)
        #expect(below == [0], "under it, only the player's black")
        #expect(!panel.window.isVisible)
        await panel.close()
    }

    // MARK: Helpers

    /// What the fixture records: each window's bar, in each of its states.
    private func snapshot() async throws -> [EditorBarSnapshot] {
        let editor = ScreenshotEditorBar(model: ScreenshotEditorModel(), cancel: {}, save: {})
        let editorActions = ScreenshotEditorWindowController.barActions(cancel: {}, save: {})
        let export = FakeEditExport(.waitForCancel)
        let model = fixture.model(try fixture.video(), export: export.export)
        let recording = ScreencastRecordingReviewBar(model: model)
        let reviewing = ScreencastRecordingReviewBar.actions(for: model)
        model.askToDiscard()
        let asking = ScreencastRecordingReviewBar.actions(for: model)
        let question = ScreencastRecordingReviewBar.question(for: model)
        model.keep()

        model.pick(.trim)
        model.edit { $0.setTrim(start: 1, end: 3) }
        let trimming = ScreencastRecordingReviewBar.actions(for: model)
        let trimTools = Self.tools(of: model)
        model.pick(.crop)
        model.setCropAspect(.square)
        let cropTools = Self.tools(of: model)
        let cropOptions = Self.options(of: model)
        model.pick(.blur)
        let blurTools = Self.tools(of: model)
        let blurOptions = Self.options(of: model)
        model.addBlur(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2))
        let blurPickedOptions = Self.options(of: model)
        model.askToSaveEdits()
        let askingToSave = ScreencastRecordingReviewBar.actions(for: model)
        let saveQuestion = ScreencastRecordingReviewBar.question(for: model)
        model.dismissSaveQuestion()
        let saving = Task { await model.save() }
        for _ in 0..<200 where !model.isExporting { try await Task.sleep(for: .milliseconds(10)) }
        let exporting = ScreencastRecordingReviewBar.actions(for: model)
        model.cancelExport()
        await saving.value
        return [
            EditorBarSnapshot(
                window: "screenshotEditor", state: "editing", hasHistory: editor.history != nil, question: nil,
                actions: editorActions
            ),
            EditorBarSnapshot(
                window: "recording", state: "reviewing", hasHistory: recording.history != nil, question: nil,
                actions: reviewing
            ),
            EditorBarSnapshot(
                window: "recording", state: "askingToDiscard", hasHistory: recording.history != nil, question: question,
                actions: asking
            ),
            EditorBarSnapshot(
                window: "recording", state: "trimming", hasHistory: true, question: nil, actions: trimming, tools: trimTools
            ),
            EditorBarSnapshot(
                window: "recording", state: "cropping", hasHistory: true, question: nil, actions: trimming, tools: cropTools,
                options: cropOptions
            ),
            EditorBarSnapshot(
                window: "recording", state: "blurring", hasHistory: true, question: nil, actions: trimming, tools: blurTools,
                options: blurOptions
            ),
            EditorBarSnapshot(
                window: "recording", state: "blurPicked", hasHistory: true, question: nil, actions: trimming, tools: blurTools,
                options: blurPickedOptions
            ),
            EditorBarSnapshot(
                window: "recording", state: "askingToSaveEdits", hasHistory: true, question: saveQuestion, actions: askingToSave
            ),
            EditorBarSnapshot(
                window: "recording", state: "exporting", hasHistory: true, question: nil, actions: exporting
            ),
        ]
    }

    /// The recording window's tools as the bar shows them.
    private static func tools(of model: ScreencastReviewModel) -> [EditorBarSnapshot.Tool] {
        ScreencastEditTool.allCases.map { tool in
            EditorBarSnapshot.Tool(
                title: tool.title, number: tool.number, key: tool.key, isSelected: model.tool == tool,
                identifier: ScreencastReviewID.tool(tool)
            )
        }
    }

    /// Crop's or Blur's options as the bar shows them (`ScreencastCropOptions`, `ScreencastBlurOptions`).
    private static func options(of model: ScreencastReviewModel) -> EditorBarSnapshot.Options? {
        switch model.tool {
        case .crop:
            EditorBarSnapshot.Options(
                label: "Aspect", segments: ScreencastCropAspect.allCases.map(\.title), picked: model.cropAspect.title,
                buttons: ["Reset Crop" + (model.hasCrop ? "" : " (off)")],
                identifiers: [ScreencastReviewID.cropAspect, ScreencastReviewID.resetCrop]
            )
        case .blur:
            EditorBarSnapshot.Options(
                label: "Strength", segments: ScreencastBlurStrength.allCases.map(\.title), picked: model.blurStrength.title,
                buttons: model.selectedBlur == nil ? [] : ["Delete \(ScreencastBlurOptions.deleteKey)"],
                identifiers: [ScreencastReviewID.blurStrength] + (model.selectedBlur == nil ? [] : [ScreencastReviewID.deleteBlur])
            )
        case .trim, nil:
            nil
        }
    }

    private static func encode(_ snapshot: [EditorBarSnapshot]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// `view` drawn as the app draws it, at 2x, through AppKit and Core Animation.
    private static func render(_ view: NSView) throws -> RenderedBar {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return RenderedBar(rep: rep)
    }
}

/// One bar, as the fixture records it.
private struct EditorBarSnapshot: Encodable {
    struct Action: Encodable {
        let title: String
        let key: String?
        let style: String
        let isDefault: Bool
        let identifier: String?
        let help: String
    }

    struct Tool: Encodable {
        let title: String
        let number: String
        let key: String
        let isSelected: Bool
        let identifier: String
    }

    /// Crop's or Blur's options: a label, a segmented control, and buttons.
    struct Options: Encodable {
        let label: String
        let segments: [String]
        let picked: String
        let buttons: [String]
        let identifiers: [String]
    }

    let window: String
    let state: String
    /// Undo and redo show.
    let hasHistory: Bool
    let question: String?
    let actions: [Action]
    /// The recording window's tools, where recorded.
    let tools: [Tool]?
    /// The picked tool's options, where recorded.
    let options: Options?

    init(
        window: String, state: String, hasHistory: Bool, question: String?, actions: [ScreengrabsEditorAction],
        tools: [Tool]? = nil, options: Options? = nil
    ) {
        self.window = window
        self.state = state
        self.hasHistory = hasHistory
        self.question = question
        self.tools = tools
        self.options = options
        self.actions = actions.map { action in
            Action(
                title: action.title, key: action.key, style: action.style.rawValue,
                isDefault: action.isDefault, identifier: action.identifier, help: action.help
            )
        }
    }
}

/// A view drawn at 2x, read in points from its top.
private struct RenderedBar {
    let rep: NSBitmapImageRep

    /// The colors across the rows from `rows` (points from the top), sampled every other point,
    /// each as 0xRRGGBB.
    func colors(rows: Range<Int>) -> Set<UInt32> {
        var colors: Set<UInt32> = []
        for y in stride(from: rows.lowerBound * 2, to: rows.upperBound * 2, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                colors.insert(red << 16 | green << 8 | blue)
            }
        }
        return colors
    }
}

/// What the bar's actions did, in order.
@MainActor
private final class ActionLog {
    private(set) var calls: [String] = []
    func add(_ call: String) { calls.append(call) }
}
