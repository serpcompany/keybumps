import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// Setting a shortcut another Keybumps action already uses (#334): the conflict check, Replace
/// and Cancel, and the notes on the action that loses its keys.
@MainActor
@Suite("Shortcut conflicts")
struct ShortcutConflictTests {
    private static let shiftCommandE = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘E"
    )
    private static let unused = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | optionKey | shiftKey), displayName: "⌃⌥⇧Q"
    )

    private func preferencesWithEmojiPickerOnShiftCommandE() -> AppPreferences {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.setCapabilityShortcut(Self.shiftCommandE, for: .emojiPicker)
        return preferences
    }

    // MARK: Finding the conflict

    @Test("Finds the plugin or Window Manager action using the same keys, and names it")
    func findsTheConflictingAction() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        let emoji = preferences.shortcutConflict(for: Self.shiftCommandE, assigningTo: .capability(.quickSearch))
        #expect(emoji == .capability(.emojiPicker))
        #expect(emoji?.displayName == "Emoji Picker › Open Emoji Picker")

        let left = WindowAction.left.defaultShortcut!
        let window = preferences.shortcutConflict(for: left, assigningTo: .capability(.timer))
        #expect(window == .window(.left))
        #expect(window?.displayName == "Window Manager › Left")
        #expect(preferences.shortcutConflict(for: DefaultShortcut.quickSearch, assigningTo: .window(.right)) == .capability(.quickSearch))
        #expect(preferences.shortcutConflict(for: Self.unused, assigningTo: .capability(.quickSearch)) == nil)
    }

    @Test("The action being edited isn't a conflict with itself")
    func ignoresTheActionBeingEdited() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        #expect(preferences.shortcutConflict(for: Self.shiftCommandE, assigningTo: .capability(.emojiPicker)) == nil)
        #expect(preferences.shortcutConflict(for: WindowAction.left.defaultShortcut!, assigningTo: .window(.left)) == nil)
    }

    @Test("The same keys conflict however the modifiers were pressed or the name was written")
    func sameKeysConflictWhateverTheName() {
        // ⌘ Space as Quick Search's default writes it, and ⌘Space as the recorder does.
        let recorded = ShortcutBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), displayName: "⌘Space")
        let reordered = ShortcutBinding(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(shiftKey | cmdKey), displayName: "⌘⇧E")
        let found = ShortcutConflict.find(
            recorded,
            for: .capability(.timer),
            capabilityShortcuts: [CapabilityShortcut.quickSearch.rawValue: DefaultShortcut.quickSearch],
            windowShortcuts: [:]
        )
        #expect(found == .capability(.quickSearch))
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        #expect(preferences.shortcutConflict(for: reordered, assigningTo: .capability(.timer)) == .capability(.emojiPicker))
        // Other modifiers on the same key are different keys.
        let commandE = ShortcutBinding(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey), displayName: "⌘E")
        #expect(preferences.shortcutConflict(for: commandE, assigningTo: .capability(.timer)) == nil)
    }

    // MARK: Replace and Cancel

    @Test("A taken shortcut pressed while recording saves nothing until Replace, which moves it")
    func replaceMovesTheShortcut() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        let recording = Recording(preferences: preferences, owner: .capability(.quickSearch))

        recording.recorder.receive(Self.shiftCommandE)

        #expect(recording.recorder.pendingReplacement == PendingShortcutReplacement(
            identifier: "quickSearch", binding: Self.shiftCommandE, owner: .capability(.emojiPicker)
        ))
        #expect(recording.recorder.pendingReplacement?.message == "⇧⌘E is used by Emoji Picker › Open Emoji Picker.")
        #expect(recording.recorder.identifier == nil, "Recording stops while it asks")
        #expect(recording.resumed == 1, "Global shortcuts come back while it asks")
        #expect(recording.captured == 0)
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch)
        #expect(preferences.capabilityShortcut(for: .emojiPicker) == Self.shiftCommandE)

        recording.recorder.confirmReplacement()

        #expect(recording.recorder.pendingReplacement == nil)
        #expect(recording.captured == 0, "Replace saves without ending a recording, which may be another field's by now")
        #expect(recording.resumed == 1)
        #expect(preferences.capabilityShortcut(for: .quickSearch) == Self.shiftCommandE)
        #expect(preferences.capabilityShortcut(for: .emojiPicker) == nil)
        #expect(preferences.movedShortcuts[.capability(.emojiPicker)]?.note == "⇧⌘E moved to Quick Search › Open Quick Search.")
    }

    @Test("Cancel keeps both actions' shortcuts as they were")
    func cancelChangesNothing() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        let recording = Recording(preferences: preferences, owner: .capability(.quickSearch))

        recording.recorder.receive(Self.shiftCommandE)
        recording.recorder.dismissReplacement()
        recording.recorder.confirmReplacement()

        #expect(recording.recorder.pendingReplacement == nil)
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch)
        #expect(preferences.capabilityShortcut(for: .emojiPicker) == Self.shiftCommandE)
        #expect(preferences.movedShortcuts.isEmpty)
    }

    @Test("A free shortcut saves straight away, and starting again or closing the page drops a pending choice")
    func freeShortcutSavesAtOnce() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        let recording = Recording(preferences: preferences, owner: .window(.upperRight))

        recording.recorder.receive(Self.unused)
        #expect(recording.recorder.pendingReplacement == nil)
        #expect(preferences.windowShortcut(for: .upperRight) == Self.unused)

        recording.begin()
        recording.recorder.receive(Self.shiftCommandE)
        #expect(recording.recorder.pendingReplacement != nil)
        recording.begin()
        #expect(recording.recorder.pendingReplacement == nil, "Recording again starts over")
        recording.recorder.receive(Self.shiftCommandE)
        recording.recorder.cancel()
        #expect(recording.recorder.pendingReplacement == nil, "Leaving the page cancels")
        #expect(preferences.capabilityShortcut(for: .emojiPicker) == Self.shiftCommandE)
    }

    // MARK: Notes on the action that lost its shortcut

    @Test("The moved note stays until that action gets a shortcut again")
    func movedNoteClearsWhenReassigned() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        let moved = preferences.setCapabilityShortcut(Self.shiftCommandE, for: .quickSearch)
        #expect(moved == [.capability(.emojiPicker)])
        #expect(preferences.movedShortcut(for: .capability(.emojiPicker)) == ShortcutMove(binding: Self.shiftCommandE, to: .capability(.quickSearch)))

        preferences.setCapabilityShortcut(Self.unused, for: .emojiPicker)
        #expect(preferences.movedShortcuts.isEmpty)
    }

    @Test("Restore Defaults says which plugin shortcut it took a window default from")
    func restoreDefaultsNamesWhatItTook() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let left = WindowAction.left.defaultShortcut!
        preferences.setWindowShortcut(nil, for: .left)
        preferences.setCapabilityShortcut(left, for: .timer)

        let moved = preferences.restoreDefaultWindowShortcuts()

        #expect(moved == [.capability(.timer)])
        #expect(preferences.windowShortcut(for: .left) == left)
        #expect(preferences.capabilityShortcut(for: .timer) == nil)
        #expect(preferences.movedShortcuts[.capability(.timer)]?.note == "⌃⌥⌘← moved to Window Manager › Left.")
        #expect(ShortcutMove.restoreNote(for: moved, in: preferences.movedShortcuts)
            == "Restoring the defaults took ⌃⌥⌘← from Timer › Open Timers.")
        #expect(ShortcutMove.restoreNote(for: [], in: preferences.movedShortcuts) == nil)
    }

    @Test("Restore Defaults clears notes on window rows, which all have their defaults again")
    func restoreDefaultsClearsWindowNotes() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.setWindowShortcut(WindowAction.left.defaultShortcut, for: .right)
        #expect(preferences.movedShortcuts[.window(.left)] != nil)

        #expect(preferences.restoreDefaultWindowShortcuts().isEmpty)
        #expect(preferences.movedShortcuts.isEmpty)
    }

    @Test("The launch-time cleanup notes the plugin shortcut it cleared")
    func launchCleanupNotesWhatItCleared() throws {
        let defaults = InMemoryDefaults()
        defaults.set(
            try JSONEncoder().encode([WindowAction.left.rawValue: DefaultShortcut.dictation]),
            forKey: "windowShortcuts"
        )

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.capabilityShortcut(for: .dictation) == nil)
        #expect(preferences.movedShortcut(for: .capability(.dictation)) == ShortcutMove(binding: DefaultShortcut.dictation, to: .window(.left)))
        #expect(preferences.movedShortcut(for: .capability(.dictation))?.note == "⌥ Space moved to Window Manager › Left.")
        #expect(AppPreferences(defaults: defaults).movedShortcuts.isEmpty, "Once cleared, the next launch has nothing to move")
    }

    @Test("A retired window action left in stored data doesn't take a plugin's shortcut at launch")
    func retiredWindowActionsTakeNothing() throws {
        let defaults = InMemoryDefaults()
        defaults.set(try JSONEncoder().encode(["retiredAction": DefaultShortcut.dictation]), forKey: "windowShortcuts")

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.capabilityShortcut(for: .dictation) == DefaultShortcut.dictation)
        #expect(preferences.movedShortcuts.isEmpty)
    }

    @Test("A moved note goes away once the action it names no longer has those keys")
    func movedNoteFollowsTheKeys() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        preferences.setWindowShortcut(Self.shiftCommandE, for: .right)
        #expect(preferences.movedShortcut(for: .capability(.emojiPicker))?.note == "⇧⌘E moved to Window Manager › Right.")

        preferences.restoreDefaultWindowShortcuts()

        #expect(preferences.windowShortcut(for: .right) == WindowAction.right.defaultShortcut)
        #expect(preferences.movedShortcut(for: .capability(.emojiPicker)) == nil, "Right has its default again, not ⇧⌘E")
    }

    // MARK: Asking outside recording, and asking again

    @Test("Restoring a default sets it at once when free, and asks when another action has it")
    func offerAsksOnlyWhenTaken() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let recorder = ShortcutRecorderState()
        let conflict = { (binding: ShortcutBinding) in preferences.shortcutConflict(for: binding, assigningTo: .capability(.quickSearch)) }
        var restored = 0

        recorder.offer(DefaultShortcut.quickSearch, identifier: "quickSearch", conflict: conflict) { restored += 1 }
        #expect(restored == 1)
        #expect(recorder.pendingReplacement == nil)

        preferences.setCapabilityShortcut(DefaultShortcut.quickSearch, for: .timer)
        recorder.offer(DefaultShortcut.quickSearch, identifier: "quickSearch", conflict: conflict) { restored += 1 }
        #expect(restored == 1)
        #expect(recorder.pendingReplacement?.owner == .capability(.timer))
        recorder.confirmReplacement()
        #expect(restored == 2)
    }

    @Test("Replace asks again when another action took the keys after it asked")
    func replaceAsksAgainAfterAnotherReplace() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let area = DefaultShortcut.screenshotArea
        let screen = Recording(preferences: preferences, owner: .capability(.screenshotScreen))
        let edit = Recording(preferences: preferences, owner: .capability(.screenshotScreenAndEdit))
        screen.recorder.receive(area)
        edit.recorder.receive(area)
        #expect(screen.recorder.pendingReplacement?.owner == .capability(.screenshotArea))
        #expect(edit.recorder.pendingReplacement?.owner == .capability(.screenshotArea))

        screen.recorder.confirmReplacement()
        #expect(preferences.capabilityShortcut(for: .screenshotScreen) == area)

        edit.recorder.confirmReplacement()
        #expect(preferences.capabilityShortcut(for: .screenshotScreen) == area, "Nothing moves without asking about Screenshot Screen")
        #expect(edit.recorder.pendingReplacement?.owner == .capability(.screenshotScreen))
        #expect(edit.recorder.pendingReplacement?.message == "⇧⌘4 is used by Screenshot Tools › Screenshot Screen.")

        edit.recorder.confirmReplacement()
        #expect(preferences.capabilityShortcut(for: .screenshotScreenAndEdit) == area)
        #expect(preferences.capabilityShortcut(for: .screenshotScreen) == nil)
    }

    @Test("While a field asks, Escape in Settings cancels the question instead of closing")
    func escapeCancelsTheQuestion() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        let recording = Recording(preferences: preferences, owner: .capability(.quickSearch))
        #expect(!ShortcutRecorderState.isAskingAny)
        #expect(SettingsEscapePolicy.action(isRecording: false, isAsking: false, editor: nil) == .close)
        #expect(SettingsEscapePolicy.action(isRecording: true, isAsking: false, editor: nil) == nil, "A recording field takes Escape")

        recording.recorder.receive(Self.shiftCommandE)
        #expect(ShortcutRecorderState.isAskingAny)
        #expect(SettingsEscapePolicy.action(isRecording: false, isAsking: true, editor: nil) == .cancelShortcutQuestion)
        #expect(SettingsEscapePolicy.action(isRecording: true, isAsking: true, editor: nil) == nil, "Another row recording keeps Escape")

        ShortcutRecorderState.dismissAllReplacements()
        #expect(recording.recorder.pendingReplacement == nil)
        #expect(!ShortcutRecorderState.isAskingAny)
        #expect(preferences.capabilityShortcut(for: .emojiPicker) == Self.shiftCommandE, "Escape is Cancel")
    }

    @Test("A field that goes away while it asks doesn't keep Settings thinking one still asks")
    func aFieldThatGoesAwayStopsAsking() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        autoreleasepool {
            let recorder = ShortcutRecorderState()
            recorder.offer(Self.shiftCommandE, identifier: "quickSearch", conflict: {
                preferences.shortcutConflict(for: $0, assigningTo: .capability(.quickSearch))
            }, replace: {})
            #expect(ShortcutRecorderState.isAskingAny)
        }
        #expect(!ShortcutRecorderState.isAskingAny)
    }

    // MARK: VoiceOver (#345)

    @Test("VoiceOver hears the question when it appears: the keys as words, who has them, and the choice")
    func theQuestionIsAnnounced() {
        let preferences = preferencesWithEmojiPickerOnShiftCommandE()
        let recording = Recording(preferences: preferences, owner: .capability(.quickSearch))
        var heard: [String] = []
        recording.recorder.announce = { heard.append($0) }

        recording.recorder.receive(Self.shiftCommandE)
        #expect(heard == ["Shift Command E is used by Emoji Picker › Open Emoji Picker. Replace or Cancel."])

        recording.recorder.dismissReplacement()
        #expect(heard.count == 1, "Cancel says nothing more")

        // Restoring a default that another action has asks the same way.
        recording.recorder.offer(Self.shiftCommandE, identifier: "quickSearch", conflict: {
            preferences.shortcutConflict(for: $0, assigningTo: .capability(.quickSearch))
        }, replace: {})
        #expect(heard.count == 2)
    }

    @Test("When Replace finds another action has the keys by now, VoiceOver hears the new question")
    func theNewQuestionIsAnnounced() {
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        let area = DefaultShortcut.screenshotArea
        let screen = Recording(preferences: preferences, owner: .capability(.screenshotScreen))
        screen.recorder.receive(area)
        let edit = Recording(preferences: preferences, owner: .capability(.screenshotScreenAndEdit))
        var heard: [String] = []
        edit.recorder.announce = { heard.append($0) }
        edit.recorder.receive(area)
        screen.recorder.confirmReplacement()

        edit.recorder.confirmReplacement()
        #expect(heard.count == 2)
        #expect(heard.last?.contains("Screenshot Tools › Screenshot Screen.") == true)
    }
}

/// Window Manager's two-column grid at Settings' narrowest width (#345): a note under a row wraps
/// in its column rather than making the grid drop to one column, which moves the rows.
@MainActor
@Suite("Window Manager's shortcut grid")
struct WindowShortcutGridTests {
    enum Note: String, CaseIterable, CustomTestStringConvertible {
        /// A key pressed without a modifier.
        case missingModifier
        /// The Replace or Cancel question.
        case question

        var testDescription: String { rawValue }
    }

    /// The Settings window's minimum width less the widest sidebar (280pt): the narrowest the page
    /// gets.
    static let narrowestPageWidth = SettingsWindowFrame.minimumContentSize.width - 280
    /// What the Commands grid dropping to one column adds at least: its second column, seven
    /// rows of 28pt fields, moves below the first.
    static let columnDrop = CGFloat(WindowSettingsLayout.primaryTrailing.count) * 28

    @Test("A note under a row keeps the Commands grid in two columns at the narrowest width", arguments: Note.allCases)
    func aNoteKeepsTwoColumns(_ note: Note) throws {
        let model = AppModel.forShortcutTests(preferences: AppPreferences(defaults: InMemoryDefaults()))
        let plain = try Self.pageHeight(model: model, recorder: ShortcutRecorderState(), width: Self.narrowestPageWidth)
        let narrow = try Self.pageHeight(model: model, recorder: ShortcutRecorderState(), width: 480)
        #expect(narrow - plain >= Self.columnDrop, "Two columns at the narrowest width to begin with; one at 480pt")

        let recorder = ShortcutRecorderState()
        defer { recorder.cancel() }
        switch note {
        case .missingModifier:
            recorder.begin(identifier: WindowAction.left.rawValue, suspend: {}, conflict: { _ in nil }, capture: { _ in }, replace: { _ in }, cancel: {})
            let key = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)
            ))
            #expect(recorder.handle(key) == nil, "Recording takes the key")
            #expect(recorder.error != nil)
        case .question:
            recorder.offer(
                DefaultShortcut.screenshotArea, identifier: WindowAction.left.rawValue,
                conflict: { _ in .capability(.screenshotScreenAndEdit) }, replace: {}
            )
            #expect(recorder.pendingReplacement != nil)
        }
        let withNote = try Self.pageHeight(model: model, recorder: recorder, width: Self.narrowestPageWidth)
        #expect(withNote > plain, "The note shows")
        #expect(withNote - plain < Self.columnDrop, "The note wraps in its column, and the grid keeps two")
    }

    /// Lays out Window Manager's page in a window that is never shown, and returns the height of
    /// what its scroll view scrolls.
    static func pageHeight(model: AppModel, recorder: ShortcutRecorderState, width: CGFloat) throws -> CGFloat {
        let size = CGSize(width: width, height: 2000)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WindowSettingsView(recorder: recorder).environment(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let scrollView = try #require(Self.firstScrollView(in: host), "SettingsPage scrolls in an NSScrollView")
        return try #require(scrollView.documentView).frame.height
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap(firstScrollView).first
    }
}

private struct NoCoachingEvents: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

@MainActor
private struct NoPresenceChanges: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}

@MainActor
private final class QuietHotKeys: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}

@MainActor
private extension AppModel {
    /// An app model whose global shortcuts register nowhere.
    static func forShortcutTests(preferences: AppPreferences) -> AppModel {
        AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: NoCoachingEvents()),
            presenceController: NoPresenceChanges(),
            detector: ManualActionDetector(),
            shortcutCoordinator: GlobalShortcutCoordinator(backend: QuietHotKeys())
        )
    }
}

/// A recorder field for one action, saving into `preferences` as Settings does.
@MainActor
private final class Recording {
    let recorder = ShortcutRecorderState()
    private(set) var resumed = 0
    /// Recordings that ended by saving, which resumes global shortcuts in the app.
    private(set) var captured = 0
    private let preferences: AppPreferences
    private let owner: ShortcutOwner

    init(preferences: AppPreferences, owner: ShortcutOwner) {
        self.preferences = preferences
        self.owner = owner
        begin()
    }

    func begin() {
        recorder.begin(
            identifier: Self.identifier(owner),
            suspend: {},
            conflict: { [preferences, owner] in preferences.shortcutConflict(for: $0, assigningTo: owner) },
            capture: { [weak self, preferences, owner] in
                preferences.setShortcut($0, for: owner)
                self?.captured += 1
            },
            replace: { [preferences, owner] in preferences.setShortcut($0, for: owner) },
            cancel: { [weak self] in self?.resumed += 1 }
        )
    }

    private static func identifier(_ owner: ShortcutOwner) -> String {
        switch owner {
        case .capability(let shortcut): shortcut.rawValue
        case .window(let action): action.rawValue
        }
    }
}
