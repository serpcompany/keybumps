import Carbon.HIToolbox
import Foundation
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
        #expect(preferences.capabilityShortcut(for: .quickSearch) == DefaultShortcut.quickSearch)
        #expect(preferences.capabilityShortcut(for: .emojiPicker) == Self.shiftCommandE)

        recording.recorder.confirmReplacement()

        #expect(recording.recorder.pendingReplacement == nil)
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
        #expect(preferences.movedShortcuts[.capability(.emojiPicker)] == ShortcutMove(keys: "⇧⌘E", to: .capability(.quickSearch)))

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
        #expect(preferences.movedShortcuts[.capability(.dictation)] == ShortcutMove(keys: "⌥ Space", to: .window(.left)))
        #expect(AppPreferences(defaults: defaults).movedShortcuts.isEmpty, "Once cleared, the next launch has nothing to move")
    }
}

/// A recorder field for one action, saving into `preferences` as Settings does.
@MainActor
private final class Recording {
    let recorder = ShortcutRecorderState()
    private(set) var resumed = 0
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
            capture: { [preferences, owner] in preferences.setShortcut($0, for: owner) },
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
