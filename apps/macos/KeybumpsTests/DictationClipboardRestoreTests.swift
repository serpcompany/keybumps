import AppKit
import Foundation
import Testing
@testable import Keybumps

/// Dictation inserts through the clipboard, then puts back what was there, unless something else was
/// copied meanwhile, while its Put the clipboard back setting is on (on by default, #396).
@MainActor
@Suite("Dictation puts the clipboard back")
struct DictationClipboardRestoreTests {
    @Test("On: copy A, dictate B. B is pasted, then A is back, and Clipboard History gets no new item")
    func restoresTheEarlierCopy() async throws {
        let fixture = RestoreFixture()
        defer { fixture.tearDown() }
        // Unseen by Clipboard History, which skips a copy matching its newest item, so recording the
        // restore would show.
        fixture.pasteboard.writeText("made-up A")

        try fixture.service.pasteTranscript("made-up B")
        #expect(fixture.commandVPresses == 1)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up B", "B is on the clipboard while the app reads the paste")
        fixture.clipboard.pollForTesting()
        await fixture.restorer.pendingRestore?.value
        #expect(fixture.pasteboard.string(forType: .string) == "made-up A")
        #expect(fixture.restores == 1)
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty, "Neither the transcript nor the restore is recorded")
    }

    @Test("Something copied while the restore waits is kept")
    func newerCopyWins() async throws {
        let fixture = RestoreFixture()
        defer { fixture.tearDown() }
        fixture.copy("made-up A")

        try fixture.service.pasteTranscript("made-up B")
        fixture.copy("made-up C")
        await fixture.restorer.pendingRestore?.value
        #expect(fixture.pasteboard.string(forType: .string) == "made-up C")
        #expect(fixture.restores == 0)
        #expect(fixture.clipboard.entries.map(\.text) == ["made-up C", "made-up A"])
    }

    @Test("Off: the transcript stays on the clipboard")
    func offLeavesTheTranscript() throws {
        let fixture = RestoreFixture()
        defer { fixture.tearDown() }
        fixture.service.restoresClipboard = { false }
        fixture.copy("made-up A")

        try fixture.service.pasteTranscript("made-up B")
        #expect(fixture.commandVPresses == 1)
        #expect(fixture.restorer.pendingRestore == nil)
        #expect(fixture.pasteboard.string(forType: .string) == "made-up B")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.map(\.text) == ["made-up A"], "Still kept out of Clipboard History")
    }

    @Test("A paste whose ⌘V fails after writing still puts A back; one that never writes leaves the clipboard alone")
    func failedPastes() async throws {
        let fixture = RestoreFixture()
        defer { fixture.tearDown() }
        fixture.copy("made-up A")

        fixture.commandVFails = true
        #expect(throws: DictationInsertionError.accessibilityRequired) {
            try fixture.service.pasteTranscript("made-up B")
        }
        await fixture.restorer.pendingRestore?.value
        #expect(fixture.pasteboard.string(forType: .string) == "made-up A")

        let neverWrites = RestoreFixture(paster: InertTextPaster())
        defer { neverWrites.tearDown() }
        neverWrites.copy("made-up A")
        let changeCount = neverWrites.pasteboard.changeCount
        #expect(throws: DictationInsertionError.pasteFailed) {
            try neverWrites.service.pasteTranscript("made-up B")
        }
        #expect(neverWrites.restorer.pendingRestore == nil)
        #expect(neverWrites.pasteboard.changeCount == changeCount)
    }

    @Test("An insert that can't reach the original app never touches the clipboard")
    func unreachableDestination() async throws {
        let fixture = RestoreFixture(allowsSystemAccess: true)
        defer { fixture.tearDown() }
        fixture.copy("made-up A")
        let changeCount = fixture.pasteboard.changeCount

        await #expect(throws: DictationInsertionError.destinationUnavailable) {
            try await fixture.service.insert("made-up B")
        }
        #expect(fixture.commandVPresses == 0)
        #expect(fixture.restorer.pendingRestore == nil)
        #expect(fixture.pasteboard.changeCount == changeCount)
    }

    @Test("The setting is Dictation's, on for new and existing installs")
    func settingDefaultsOn() {
        #expect(CapabilityDescriptor.dictation.preferenceGroups.map(\.title) == ["Inserting"])
        #expect(CapabilityDescriptor.dictation.preferences.map(\.key) == ["restoresClipboard"])
        #expect(AppPreferences(defaults: InMemoryDefaults()).bool(.dictationRestoresClipboard, for: .dictation))

        let existing = InMemoryDefaults()
        existing.set(true, forKey: "didCompleteOnboarding")
        existing.set("en-US", forKey: "dictationLanguage")
        #expect(AppPreferences(defaults: existing).bool(.dictationRestoresClipboard, for: .dictation))
    }

    @Test("The app shares the palette's restorer with Dictation and reads the setting at each insert")
    func wiredInTheApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeybumpsDictationRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = WiringHarness(enabled: [.dictation], missing: nil, root: root)
        let model = harness.model

        #expect(model.dictation.clipboardRestorer === model.commandPalette.clipboardRestorer)
        #expect(model.dictation.restoresClipboard())
        model.setPluginPreference(.dictationRestoresClipboard, to: .bool(false), for: .dictation)
        #expect(!model.dictation.restoresClipboard())
    }
}

/// A Dictation service whose paste step is the app's, over a named pasteboard, with ⌘V faked and a
/// Clipboard History watching that pasteboard, wired as the shell wires them.
@MainActor
private final class RestoreFixture {
    let folder = TemporaryFolder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsDictationRestore-\(UUID().uuidString)"))
    let clipboard: ClipboardHistoryService
    let restorer: ClipboardRestorer
    let service: DictationService
    private let commandV = FakeCommandV()
    private(set) var restores = 0

    var commandVPresses: Int { commandV.presses }
    /// Makes ⌘V fail after the transcript is written, as it does without Accessibility.
    var commandVFails: Bool {
        get { commandV.fails }
        set { commandV.fails = newValue }
    }

    /// `paster` replaces the app's paste step.
    init(paster: (any TextPasting)? = nil, allowsSystemAccess: Bool = false) {
        let pasteboard = pasteboard
        let root = folder.url
        let clipboard = ClipboardHistoryService(
            storageURL: root.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: root.appendingPathComponent("clipboard-media", isDirectory: true),
            sourceApps: .inert
        )
        self.clipboard = clipboard
        let commandV = commandV
        let restorer = ClipboardRestorer(pasteboard: pasteboard)
        restorer.delay = .milliseconds(20)
        self.restorer = restorer
        service = DictationService(
            language: "en-US",
            history: DictationHistoryService(recordingsDirectoryURL: root.appendingPathComponent("recordings", isDirectory: true)),
            paster: paster ?? SystemTextPaster(
                pasteboard: { pasteboard },
                didWritePasteboard: { clipboard.suppressCurrentChange() },
                postCommandV: { try commandV.press() }
            ),
            allowsSystemAccess: allowsSystemAccess,
            accessibilityTrusted: { true }
        )
        service.clipboardRestorer = restorer
        restorer.didRestore = { [unowned self] in
            restores += 1
            clipboard.suppressCurrentChange()
        }
    }

    /// Copies text in "another app", as Clipboard History sees it.
    func copy(_ text: String) {
        pasteboard.writeText(text)
        clipboard.pollForTesting()
    }

    func tearDown() {
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

/// Counts ⌘V presses instead of posting them, or refuses as macOS does without Accessibility.
@MainActor
private final class FakeCommandV {
    private(set) var presses = 0
    var fails = false

    func press() throws {
        if fails { throw TextPasteError.accessibilityRequired }
        presses += 1
    }
}
