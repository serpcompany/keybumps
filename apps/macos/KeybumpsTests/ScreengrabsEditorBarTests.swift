import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// The bar the Screenshot Editor and the recording window share (#511): each window's actions, in
/// order, with their keys and the default button, recorded in a fixture, and the bar as each window
/// lays it out, drawn off screen. No window is ordered in, and the review writes to a named pasteboard.
///
/// Re-record the fixture only with `KEYBUMPS_RECORD_SNAPSHOTS=1` (through xcodebuild:
/// `TEST_RUNNER_KEYBUMPS_RECORD_SNAPSHOTS=1`), running this suite alone.
@MainActor
@Suite("Screengrabs: the editor bar")
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
        #expect(keys == ["esc", "↵"])
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

    @Test("Both windows' bars match the fixture: each action's title, key, style, default button, identifier, and help, in order")
    func barsMatchTheFixture() throws {
        defer { fixture.tearDown() }
        let actual = try Self.encode(try snapshot())
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

    @Test("Each window's bar fits the window at its narrowest, 64 points tall: the Screenshot Editor's at 840 points, the recording window's at 640, with two displays' picker or the discard question")
    func barsFitTheirWindows() throws {
        defer { fixture.tearDown() }
        let editor = NSHostingView(rootView: ScreenshotEditorToolbar(model: ScreenshotEditorModel(), cancel: {}, save: {}))
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
    private func snapshot() throws -> [EditorBarSnapshot] {
        let editor = ScreenshotEditorWindowController.barActions(cancel: {}, save: {})
        let model = fixture.model(try fixture.video())
        let recording = ScreencastRecordingReviewBar.actions(for: model)
        model.askToDiscard()
        let asking = ScreencastRecordingReviewBar.actions(for: model)
        let question = model.isConfirmingDiscard ? ScreencastRecordingReviewBar.discardQuestion : nil
        return [
            EditorBarSnapshot(window: "screenshotEditor", state: "editing", question: nil, actions: editor),
            EditorBarSnapshot(window: "recording", state: "reviewing", question: nil, actions: recording),
            EditorBarSnapshot(window: "recording", state: "askingToDiscard", question: question, actions: asking),
        ]
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

    let window: String
    let state: String
    let question: String?
    let actions: [Action]

    init(window: String, state: String, question: String?, actions: [ScreengrabsEditorAction]) {
        self.window = window
        self.state = state
        self.question = question
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
