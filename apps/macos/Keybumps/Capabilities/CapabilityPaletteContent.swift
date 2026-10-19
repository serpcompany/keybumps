import AppKit
import SwiftUI

/// The rows of a Command Palette tab that a capability module supplies itself, so the palette needs
/// no case of its own for the tab. The palette keeps the search field, the tab bar, the selection,
/// the arrow keys, Escape, and the footer's chrome; the content answers for its rows, for Return,
/// ⌘Return, ⌘C, ⌘V, Space, and Delete on them, and for what the footer says those keys do.
@MainActor
protocol CapabilityPaletteContent: AnyObject {
    /// The tab these rows fill; it is the owning module's `paletteTab`.
    var tab: CommandPaletteTab { get }
    /// Whether typing moves the selection back to the first row, as when the rows re-rank.
    var resetsSelectionWhileTyping: Bool { get }
    /// Whether the rows for `query` are a grid, such as emoji to browse while the search is empty:
    /// all four arrow keys go to `selection(after:from:query:)`, and the footer shows them. A list's
    /// Up and Down step one row and wrap.
    func isGrid(query: String) -> Bool
    /// Whether the grid takes Up and Down whatever else is going on, as a list's rows do: with
    /// Shift, Option, Command, or Control held, while an input method composes, and at the grid's
    /// edge, where they still count as moving within it. Left and Right then go to the grid only
    /// while the search field is empty. False, as for Emoji: the grid takes only the plain arrow
    /// keys, while no input method composes, and the others step one item and wrap, as in a list.
    var gridOwnsUpAndDown: Bool { get }
    /// Where an arrow key moves a grid's selection from `row`, or nil to stay put. `PaletteGrid`
    /// works it out for rows laid out in sections.
    func selection(after move: PaletteMove, from row: Int, query: String) -> Int?
    /// The rows Up and Down move through, for the text in the search field.
    func rowCount(query: String) -> Int
    /// Return on the selected row: the tab's main action, such as Copy. ⌘Return does the same unless
    /// the tab gives it an action of its own (`commandActivate`).
    func activate(row: Int, query: String, palette: PaletteContentActions)
    /// ⌘Return on the selected row: what Return does, unless the tab gives it an action of its own,
    /// such as the ScreenGrabs tab's Edit, which ⌘E also does. It pastes only the Translate tab's
    /// translation being typed, where ⌘V is the search field's (#370, #552).
    func commandActivate(row: Int, query: String, palette: PaletteContentActions)
    /// ⌘C on the selected row: copies it, as Return does in most tabs. A row that doesn't copy does
    /// nothing.
    func copy(row: Int, query: String, palette: PaletteContentActions)
    /// ⌘V on the selected row, where `pastes(row:query:)` says it pastes: pastes it into the app you
    /// were using (`PaletteContentActions.paste`).
    func paste(row: Int, query: String, palette: PaletteContentActions)
    /// Whether ⌘V pastes the selected row (#552). Elsewhere ⌘V is the search field's, as in any text
    /// field. By default, a row whose footer names Paste ⌘V.
    func pastes(row: Int, query: String) -> Bool
    /// What Space does on the selected row while the search field is empty: plays or pauses its
    /// audio, such as a saved translation read aloud, or opens it in Quick Look, as a screengrab's
    /// does. Nil for a row with none, where Space types.
    func playback(row: Int, query: String) -> PalettePlayback?
    /// Delete on the selected row, with Command or once the search field is empty. Returns whether
    /// it removed something; the palette then keeps the selection on a row that still exists.
    func delete(row: Int, query: String) -> Bool
    /// For a row whose Delete asks first, as a recording's does: the question, and what its Delete
    /// does. The palette shows it in place of `delete(row:query:)`. Nil deletes at once.
    func deletionConfirmation(row: Int, query: String) -> PaletteDeletionConfirmation?
    /// What the footer says Return and the other keys do on the selected row, with Delete's last
    /// (`PaletteKeyAction.delete`) on a row Delete removes. The palette adds Space's, from
    /// `playback(row:query:)`, before Delete's.
    func footerActions(row: Int, query: String) -> PaletteFooterActions
    /// The Command keys the tab keeps for itself, such as `t` for the Translate tab's ⌘T, as
    /// `charactersIgnoringModifiers` reports them, lowercased. The palette's own Command keys (the
    /// tab numbers and ⌘,) come first.
    var commandKeys: Set<String> { get }
    /// One of `commandKeys`, pressed with Command, on the selected row, such as ⌘E, which edits the
    /// selected screenshot. A held key's repeats don't come here, nor do keys pressed while `/`'s
    /// list of filters hides the rows.
    func handleCommandKey(_ characters: String, row: Int, query: String, palette: PaletteContentActions)
    /// Whether a ⌘-click on a row does what ⌘Return does (`commandActivate`), as in the ScreenGrabs
    /// tab, where both edit. Elsewhere ⌘ makes no difference to a click (`click(_:row:query:palette:)`).
    var commandClicks: Bool { get }
    /// Runs each time the palette shows the tab: when it opens on it, or switches to it.
    func didShow(palette: PaletteContentActions)
    /// Runs when the palette stops showing the tab: it closes, or switches to another tab.
    func didHide()
    /// The rows under the tab bar.
    func makeView(_ context: PaletteContentContext) -> AnyView
}

extension CapabilityPaletteContent {
    var resetsSelectionWhileTyping: Bool { false }
    func isGrid(query: String) -> Bool { false }
    var gridOwnsUpAndDown: Bool { false }
    func selection(after move: PaletteMove, from row: Int, query: String) -> Int? { nil }
    func activate(row: Int, query: String, palette: PaletteContentActions) {}
    func commandActivate(row: Int, query: String, palette: PaletteContentActions) {
        activate(row: row, query: query, palette: palette)
    }
    func copy(row: Int, query: String, palette: PaletteContentActions) {}
    func paste(row: Int, query: String, palette: PaletteContentActions) {}
    func pastes(row: Int, query: String) -> Bool {
        footerActions(row: row, query: query).secondary.contains(where: \.isPaste)
    }
    func playback(row: Int, query: String) -> PalettePlayback? { nil }
    func delete(row: Int, query: String) -> Bool { false }
    func deletionConfirmation(row: Int, query: String) -> PaletteDeletionConfirmation? { nil }
    func footerActions(row: Int, query: String) -> PaletteFooterActions { PaletteFooterActions(tab: tab) }
    var commandKeys: Set<String> { [] }
    func handleCommandKey(_ characters: String, row: Int, query: String, palette: PaletteContentActions) {}
    var commandClicks: Bool { false }
    func didShow(palette: PaletteContentActions) {}
    func didHide() {}

    /// A click on a row or tile, as its `PaletteClickButton` reports it (#552): what the tab's
    /// `clickAction` says, with `selectRow` for the highlight, `activate` for Return's action, and,
    /// where `commandClicks`, `commandActivate` for a ⌘-click.
    func click(_ click: PaletteClick, row: Int, query: String, palette: PaletteContentActions) {
        tab.clickAction.perform(
            click,
            select: { palette.selectRow(row) },
            activate: { activate(row: row, query: query, palette: palette) },
            commandActivate: commandClicks ? { self.commandActivate(row: row, query: query, palette: palette) } : nil
        )
    }
}

/// What one click on a tab's row or tile does, which the tab's registration declares
/// (`CapabilityPaletteTab.clickAction`, #552). A right-click's context menu, the pointer's highlight,
/// and the keys are the same either way.
enum PaletteClickAction: Equatable {
    /// One click does what Return does, where a row has one obvious job and no detail pane: Search
    /// opens or runs it, Clipboard, Snippets, and Emoji copy it, and Timers starts, pauses, resumes,
    /// or restarts it. The second click of a double-click does nothing, so a double-click never does
    /// it twice, as pausing a timer, then resuming it.
    case acts
    /// One click highlights the row, and a double-click does what Return does, where the tab shows
    /// the highlighted row's actions in the detail beside the list or grid (Dictation, Translate,
    /// ScreenGrabs). A click in a grid goes into it, as Down does. The Hotkeys tab's rows have no
    /// action, so they only highlight.
    case selects

    /// Does what a click does here: `select` highlights the row, `activate` does what Return does,
    /// and `commandActivate`, on a row with a ⌘-click, does what that does instead while ⌘ is held,
    /// in either kind of tab, as a screengrab's edits.
    func perform(_ click: PaletteClick, select: () -> Void, activate: () -> Void, commandActivate: (() -> Void)? = nil) {
        switch click {
        case .click(let count, let withCommand):
            if withCommand, let commandActivate {
                // Once, on a double-click's first click.
                guard count == 1 else { return }
                select()
                commandActivate()
            } else if self == .selects {
                select()
            } else if count == 1 {
                select()
                activate()
            }
        case .doubleClick(let withCommand):
            guard self == .selects, !(withCommand && commandActivate != nil) else { return }
            activate()
        }
    }
}

/// A click on a palette row or tile, as its `PaletteClickButton` reports it.
enum PaletteClick: Equatable {
    /// Each click: `count` is 1, or 2 for a double-click's second click (`NSEvent.clickCount`).
    case click(count: Int = 1, withCommand: Bool = false)
    /// A double-click, once its second click is done, after that click's own `click`. Only where a
    /// click selects (`PaletteClickAction.selects`).
    case doubleClick(withCommand: Bool = false)
}

/// A palette row's or tile's button, its label the `PaletteRow` or tile (#552). It reports each
/// click to `click`, and, where a click selects, the double-click too, which then does what the
/// tab's `clickAction` says (`CapabilityPaletteContent.click`, or `PaletteClickAction.perform`).
struct PaletteClickButton<Label: View>: View {
    let clickAction: PaletteClickAction
    let click: (PaletteClick) -> Void
    @ViewBuilder let label: Label

    var body: some View {
        let button = Button { click(.click(count: Self.clickCount, withCommand: Self.isCommandHeld)) } label: { label }
            .buttonStyle(.plain)
        switch clickAction {
        case .acts:
            button
        case .selects:
            button.simultaneousGesture(TapGesture(count: 2).onEnded { click(.doubleClick(withCommand: Self.isCommandHeld)) })
        }
    }

    /// The click count of the mouse event the button is handling. Any other press, such as
    /// VoiceOver's, is one click, even right after a double-click elsewhere: the last mouse event
    /// counts only while it's recent, within the double-click interval or a second, whichever is
    /// longer, so a busy main thread doesn't turn a double-click's second click into a first.
    @MainActor private static var clickCount: Int {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown,
              ProcessInfo.processInfo.systemUptime - event.timestamp <= max(NSEvent.doubleClickInterval, 1) else { return 1 }
        return event.clickCount
    }

    @MainActor private static var isCommandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
}

extension PaletteClickButton {
    /// A row the palette draws itself, with closures of its own: `select` highlights it,
    /// `activate` does what Return does, and `commandActivate`, if there's one, what a ⌘-click does.
    init(
        _ clickAction: PaletteClickAction,
        select: @escaping () -> Void,
        activate: @escaping () -> Void,
        commandActivate: (() -> Void)? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.init(
            clickAction: clickAction,
            click: { clickAction.perform($0, select: select, activate: activate, commandActivate: commandActivate) },
            label: label
        )
    }
}

/// Delete's question for a row that asks first, such as "Delete this translation?", and what its
/// Delete button does. The palette shows it as an alert, as it does a recording's.
struct PaletteDeletionConfirmation {
    let title: String
    let message: String
    let delete: @MainActor () -> Void
    /// The destructive button's name, such as Move to Trash for a ScreenGrabs recording.
    var confirmTitle = "Delete"
}

/// What the footer names after Select: Return's action, then each other key's, such as Paste ⌘V,
/// ending with Delete's. A nil primary leaves Return out.
struct PaletteFooterActions: Equatable {
    var primary: String?
    var secondary: [PaletteKeyAction]

    init(primary: String?, secondary: [PaletteKeyAction] = []) {
        self.primary = primary
        self.secondary = secondary
    }

    /// The actions the tab's descriptor registers.
    init(tab: CommandPaletteTab) {
        self.init(primary: tab.primaryActionTitle, secondary: tab.secondaryActions)
    }
}

/// A key the footer names after Return's, and what it does on the selected row: "Paste" with ⌘V.
/// Every tab gives a key the same name: Paste ⌘V, Edit ⌘E, and Delete ⌫, which the footer lists last
/// (#552).
struct PaletteKeyAction: Equatable, CustomStringConvertible {
    let title: String
    /// Its keycaps, in order.
    let keys: [String]
    /// Whether the key does anything only on a highlighted row, as ⌘V, Space, and Delete do; Return
    /// acts on a grid's first item before Down goes into it. The footer leaves such a key out until
    /// then.
    var needsHighlightedRow = false

    /// ⌘V, which pastes the row into the app you were using (#370, #552). On a row that doesn't
    /// paste, ⌘V is the search field's.
    static func paste(_ title: String = "Paste") -> PaletteKeyAction {
        PaletteKeyAction(title: title, keys: ["⌘", "V"], needsHighlightedRow: true)
    }

    /// ⌘E, which opens the row where it's edited: a screenshot or a Clipboard History image in the
    /// Screenshot Editor, a recording in the recording window, or a snippet in Settings. Like
    /// ⌘Return in the ScreenGrabs tab, it acts on a grid's first item before Down goes into it.
    static let edit = PaletteKeyAction(title: "Edit", keys: ["⌘", "E"])

    /// Delete, which removes the row (or Command-Delete while typing), named for what it does there,
    /// such as Move to Trash for a ScreenGrabs recording. The footer lists it last.
    static func delete(_ title: String = "Delete") -> PaletteKeyAction {
        PaletteKeyAction(title: title, keys: ["⌫"], needsHighlightedRow: true)
    }

    /// Delete on a row that only leaves the list: a Recent Item, whose app or file stays, or a
    /// ScreenGrabs recording that was moved or deleted.
    static let remove = delete("Remove")

    /// Space, which plays or pauses a row's audio while the search field is empty.
    static func space(_ title: String) -> PaletteKeyAction {
        PaletteKeyAction(title: title, keys: ["Space"], needsHighlightedRow: true)
    }

    /// Whether it's ⌘V's Paste.
    var isPaste: Bool { keys == Self.paste().keys }

    /// Whether it's Delete's, which the footer lists last, with or without Command.
    var isDelete: Bool { keys.last == Self.remove.keys.last }

    /// The same action on ⌘⌫, which the footer names while the search field has text or a filter,
    /// where ⌫ alone edits them.
    var withCommand: PaletteKeyAction {
        PaletteKeyAction(title: title, keys: ["⌘"] + keys, needsHighlightedRow: needsHighlightedRow)
    }

    /// "Paste ⌘V"
    var description: String { "\(title) \(keys.joined())" }

    /// What VoiceOver reads for a footer hint: "Paste, Command V", "Select, Up Arrow or Down Arrow".
    /// Keys after a modifier are one shortcut; keys on their own are alternatives.
    static func accessibilityLabel(title: String, keys: [String]) -> String {
        "\(title), \(spokenShortcut(keys))"
    }

    /// Keys as VoiceOver reads them: "Command V", or "Up Arrow or Down Arrow".
    static func spokenShortcut(_ keys: [String]) -> String {
        let spoken = keys.map { spokenKeys[$0] ?? $0 }
        let isShortcut = keys.first.map { spokenKeys[$0] == "Command" } ?? false
        return spoken.joined(separator: isShortcut ? " " : " or ")
    }

    private static let spokenKeys = [
        "⌘": "Command", "↵": "Return", "↑": "Up Arrow", "↓": "Down Arrow", "←": "Left Arrow", "→": "Right Arrow",
        "⌫": "Delete",
    ]

    /// The same keys beside a context menu item, as the footer names them: ⌘C beside Copy, ⌘V beside
    /// Paste, ⌘E beside Edit, and ⌫ beside Delete. Nil for keys a menu doesn't show, such as Space.
    static func menuShortcut(_ keys: [String]) -> KeyboardShortcut? {
        let command = keys.first == "⌘"
        let rest = command ? Array(keys.dropFirst()) : keys
        guard rest.count == 1, let key = rest.first else { return nil }
        let modifiers: EventModifiers = command ? .command : []
        switch key {
        case "↵": return KeyboardShortcut(.return, modifiers: modifiers)
        case "⌫": return KeyboardShortcut(.delete, modifiers: modifiers)
        default:
            guard key.count == 1, let letter = key.lowercased().first, letter.isLetter else { return nil }
            return KeyboardShortcut(KeyEquivalent(letter), modifiers: modifiers)
        }
    }
}

extension View {
    /// Shows a palette key beside a context menu item (`PaletteKeyAction.menuShortcut`), so menus
    /// teach the keys the footer names (#552): `.paletteMenuKeys(PaletteKeyAction.paste().keys)`.
    func paletteMenuKeys(_ keys: [String]) -> some View {
        keyboardShortcut(PaletteKeyAction.menuShortcut(keys))
    }
}

/// Space on a row with audio while the search field is empty: what the footer calls it, such as
/// Play or Pause, and what it does.
struct PalettePlayback {
    let title: String
    let toggle: @MainActor () -> Void
    /// False keeps it out of the footer, for a row whose Space only says why it can't, as a moved or
    /// deleted recording's does.
    var listsInFooter = true
}

/// What a tab's rows can ask of the palette.
@MainActor
struct PaletteContentActions {
    /// Closes the palette.
    let dismiss: () -> Void
    /// Moves the selection to a row, as a click on it does. In a grid, it goes into the grid's items,
    /// as Down does, so the arrow keys move on from it and the footer and the detail name its actions.
    let selectRow: (Int) -> Void
    /// Empties the search field, as after a row has used what was typed. On a tab whose rows reset
    /// the selection while typing, it also moves the selection back to the first row, so select a
    /// row after clearing, not before.
    let clearQuery: () -> Void
    /// Copies text, keeping it out of Clipboard History, then closes the palette and confirms the
    /// copy at the notch.
    var copy: (String) -> Void = { _ in }
    /// Closes the palette and pastes text into the app that was in front when it opened (⌘V), or
    /// copies it and says why when it can't (`PalettePasteRoute`). With `restoresClipboard` true, what
    /// was on the clipboard comes back once the paste has been read.
    var paste: (_ text: String, _ restoresClipboard: Bool) -> Void = { _, _ in }
    /// Deletes a row as the Delete key does, as from a detail pane's Delete button: a row whose
    /// Delete asks first (`deletionConfirmation(row:query:)`) shows its question.
    var deleteRow: (Int) -> Void = { _ in }
    /// Puts a Clipboard History item back on the clipboard, then closes the palette and confirms the
    /// copy at the notch, as the Clipboard tab's Return does.
    var copyClipboardEntry: (ClipboardEntry) -> Void = { _ in }
    /// Puts a Clipboard History item back on the clipboard, then closes the palette and pastes it into
    /// the app that was in front when it opened, as the Clipboard tab's ⌘V does. It stays on the
    /// clipboard afterwards.
    var pasteClipboardEntry: (ClipboardEntry) -> Void = { _ in }
    /// Closes the palette and opens an image item in the Screenshot Editor, as ⌘E does in the
    /// Clipboard tab. It does nothing for text, or while ScreenGrabs is off.
    var editClipboardImage: (ClipboardEntry) -> Void = { _ in }
    /// Puts files on the clipboard, as Finder copies them, kept out of Clipboard History, then
    /// closes the palette and confirms the copy at the notch, as a ScreenGrabs recording's Return does.
    var copyFiles: ([URL]) -> Void = { _ in }
    /// Copies files as `copyFiles` does, then closes the palette and pastes them into the app that
    /// was in front when it opened (⌘V). They stay on the clipboard afterwards.
    var pasteFiles: ([URL]) -> Void = { _ in }
    /// Shows a warning at the notch, such as why a recording couldn't open, leaving the palette open.
    var warn: (String) -> Void = { _ in }
    /// Closes the palette and opens Settings on a page.
    var openSettings: (SettingsSection) -> Void = { _ in }
}

/// An arrow key in a grid tab.
enum PaletteMove: Equatable {
    case up, down, left, right

    /// The move an arrow key's key code stands for.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        default: return nil
        }
    }
}

/// Arrow-key moves through a grid laid out in sections, each section starting a new row, as a
/// palette tab draws its rows: Left and Right step one item, across rows and sections; Up and
/// Down move a row, to the same column, or the last item of a shorter row. Moves stop at the edges.
enum PaletteGrid {
    static func selection(after move: PaletteMove, from index: Int, sectionCounts: [Int], columns: Int) -> Int? {
        let total = sectionCounts.reduce(0, +)
        guard columns > 0, (0..<total).contains(index) else { return nil }
        switch move {
        case .left: return index > 0 ? index - 1 : nil
        case .right: return index < total - 1 ? index + 1 : nil
        case .up, .down:
            // Each row as the index of its first item and how many it holds.
            var rows: [(start: Int, count: Int)] = []
            var start = 0
            for count in sectionCounts where count > 0 {
                for offset in stride(from: 0, to: count, by: columns) {
                    rows.append((start + offset, min(columns, count - offset)))
                }
                start += count
            }
            guard let row = rows.firstIndex(where: { (0..<$0.count).contains(index - $0.start) }) else { return nil }
            let column = index - rows[row].start
            let target = move == .up ? row - 1 : row + 1
            guard rows.indices.contains(target) else { return nil }
            return rows[target].start + min(column, rows[target].count - 1)
        }
    }
}

/// What the palette hands a tab's view each time it draws it.
@MainActor
struct PaletteContentContext {
    let query: String
    let selection: Int
    let actions: PaletteContentActions
    /// Tells the palette while a confirmation shows, so a click on it doesn't close the palette.
    let confirmationPresentationChanged: (Bool) -> Void
    /// A click on the row or tile at an index, as its `PaletteClickButton` reports it, which the
    /// palette hands to the tab's rows (`CapabilityPaletteContent.click`) with the search as it is.
    var click: (PaletteClick, Int) -> Void = { _, _ in }
}
