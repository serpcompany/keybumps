import SwiftUI

/// The rows of a Command Palette tab that a capability module supplies itself, so the palette needs
/// no case of its own for the tab. The palette keeps the search field, the tab bar, the selection,
/// the arrow keys, Escape, and the footer's chrome; the content answers for its rows, for Return,
/// ⌘Return, ⌘C, ⌘P, Space, and Delete on them, and for what the footer says those keys do.
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
    /// such as the ScreenGrabs tab's Edit (`PaletteKeyAction.edit`). It never pastes (#370).
    func commandActivate(row: Int, query: String, palette: PaletteContentActions)
    /// ⌘C on the selected row: copies it, as Return does in most tabs. A row that doesn't copy does
    /// nothing.
    func copy(row: Int, query: String, palette: PaletteContentActions)
    /// ⌘P on the selected row: pastes it into the app you were using (`PaletteContentActions.paste`).
    /// A row that doesn't paste does nothing.
    func paste(row: Int, query: String, palette: PaletteContentActions)
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
    /// What the footer says Return and the other keys do on the selected row. The palette adds
    /// Space's, from `playback(row:query:)`.
    func footerActions(row: Int, query: String) -> PaletteFooterActions
    /// The Command keys the tab keeps for itself, such as `t` for the Translate tab's ⌘T, as
    /// `charactersIgnoringModifiers` reports them, lowercased. The palette's own Command keys (the
    /// tab numbers and ⌘,) come first.
    var commandKeys: Set<String> { get }
    /// One of `commandKeys`, pressed with Command, on the selected row, such as ⌘E, which edits the
    /// selected screenshot. A held key's repeats don't come here, nor do keys pressed while `/`'s
    /// list of filters hides the rows.
    func handleCommandKey(_ characters: String, row: Int, query: String, palette: PaletteContentActions)
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
    func playback(row: Int, query: String) -> PalettePlayback? { nil }
    func delete(row: Int, query: String) -> Bool { false }
    func deletionConfirmation(row: Int, query: String) -> PaletteDeletionConfirmation? { nil }
    func footerActions(row: Int, query: String) -> PaletteFooterActions { PaletteFooterActions(tab: tab) }
    var commandKeys: Set<String> { [] }
    func handleCommandKey(_ characters: String, row: Int, query: String, palette: PaletteContentActions) {}
    func didShow(palette: PaletteContentActions) {}
    func didHide() {}
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

/// What the footer names after Select: Return's action, then each other key's, such as Paste ⌘P.
/// A nil primary leaves Return out.
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

/// A key the footer names after Return's, and what it does on the selected row: "Paste" with ⌘P.
struct PaletteKeyAction: Equatable, CustomStringConvertible {
    let title: String
    /// Its keycaps, in order.
    let keys: [String]
    /// Whether the key does anything only on a highlighted row, as ⌘P and Space do; Return acts on
    /// a grid's first item before Down goes into it. The footer leaves such a key out until then.
    var needsHighlightedRow = false

    /// ⌘P, which pastes the row into the app you were using (#370).
    static func paste(_ title: String = "Paste") -> PaletteKeyAction {
        PaletteKeyAction(title: title, keys: ["⌘", "P"], needsHighlightedRow: true)
    }

    /// ⌘Return, which in the ScreenGrabs tab opens a screenshot in the Screenshot Editor.
    static let edit = PaletteKeyAction(title: "Edit", keys: ["⌘", "↵"])

    /// ⌘Return, which in the ScreenGrabs tab opens a recording in the recording window.
    static let open = PaletteKeyAction(title: "Open", keys: ["⌘", "↵"])

    /// Delete, named in the footer where it's all a row offers, as for a ScreenGrabs recording that
    /// was moved or deleted.
    static let remove = PaletteKeyAction(title: "Remove", keys: ["⌫"], needsHighlightedRow: true)

    /// Space, which plays or pauses a row's audio while the search field is empty.
    static func space(_ title: String) -> PaletteKeyAction {
        PaletteKeyAction(title: title, keys: ["Space"], needsHighlightedRow: true)
    }

    /// "Paste ⌘P"
    var description: String { "\(title) \(keys.joined())" }

    /// What VoiceOver reads for a footer hint: "Paste, Command P", "Select, Up Arrow or Down Arrow".
    /// Keys after a modifier are one shortcut; keys on their own are alternatives.
    static func accessibilityLabel(title: String, keys: [String]) -> String {
        "\(title), \(spokenShortcut(keys))"
    }

    /// Keys as VoiceOver reads them: "Command P", or "Up Arrow or Down Arrow".
    static func spokenShortcut(_ keys: [String]) -> String {
        let spoken = keys.map { spokenKeys[$0] ?? $0 }
        let isShortcut = keys.first.map { spokenKeys[$0] == "Command" } ?? false
        return spoken.joined(separator: isShortcut ? " " : " or ")
    }

    private static let spokenKeys = [
        "⌘": "Command", "↵": "Return", "↑": "Up Arrow", "↓": "Down Arrow", "←": "Left Arrow", "→": "Right Arrow",
        "⌫": "Delete",
    ]
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
    /// Moves the selection to a row, as a click on it does.
    let selectRow: (Int) -> Void
    /// Empties the search field, as after a row has used what was typed. On a tab whose rows reset
    /// the selection while typing, it also moves the selection back to the first row, so select a
    /// row after clearing, not before.
    let clearQuery: () -> Void
    /// Copies text, keeping it out of Clipboard History, then closes the palette and confirms the
    /// copy at the notch.
    var copy: (String) -> Void = { _ in }
    /// Closes the palette and pastes text into the app that was in front when it opened (⌘P), or
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
    /// the app that was in front when it opened (⌘P), as the Clipboard tab's ⌘P does. It stays on the
    /// clipboard afterwards.
    var pasteClipboardEntry: (ClipboardEntry) -> Void = { _ in }
    /// Closes the palette and opens an image item in the Screenshot Editor, as ⌘E does in the
    /// Clipboard tab. It does nothing for text, or while ScreenGrabs is off.
    var editClipboardImage: (ClipboardEntry) -> Void = { _ in }
    /// Puts files on the clipboard, as Finder copies them, kept out of Clipboard History, then
    /// closes the palette and confirms the copy at the notch, as a ScreenGrabs recording's Return does.
    var copyFiles: ([URL]) -> Void = { _ in }
    /// Copies files as `copyFiles` does, then closes the palette and pastes them into the app that
    /// was in front when it opened (⌘P). They stay on the clipboard afterwards.
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
}
