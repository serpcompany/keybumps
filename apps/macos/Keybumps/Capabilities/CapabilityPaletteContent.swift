import SwiftUI

/// The rows of a Command Palette tab that a capability module supplies itself, so the palette needs
/// no case of its own for the tab. The palette keeps the search field, the tab bar, the selection,
/// the arrow keys, Escape, and the footer's chrome; the content answers for its rows, for Return
/// and Delete on them, and for what the footer says Return does.
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
    /// Where an arrow key moves a grid's selection from `row`, or nil to stay put. `PaletteGrid`
    /// works it out for rows laid out in sections.
    func selection(after move: PaletteMove, from row: Int, query: String) -> Int?
    /// The rows Up and Down move through, for the text in the search field.
    func rowCount(query: String) -> Int
    /// Return on the selected row; `withCommand` is Command-Return.
    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions)
    /// Delete on the selected row, with Command or once the search field is empty. Returns whether
    /// it removed something; the palette then keeps the selection on a row that still exists.
    func delete(row: Int, query: String) -> Bool
    /// What the footer says Return and Command-Return do on the selected row.
    func footerActions(row: Int, query: String) -> PaletteFooterActions
    /// The Command keys the tab keeps for itself, such as `t` for the Translate tab's ⌘T, as
    /// `charactersIgnoringModifiers` reports them, lowercased. The palette's own Command keys (the
    /// tab numbers and ⌘,) come first.
    var commandKeys: Set<String> { get }
    /// One of `commandKeys`, pressed with Command. A held key's repeats don't come here.
    func handleCommandKey(_ characters: String, query: String)
    /// Runs each time the palette shows the tab: when it opens on it, or switches to it.
    func didShow(palette: PaletteContentActions)
    /// The rows under the tab bar.
    func makeView(_ context: PaletteContentContext) -> AnyView
}

extension CapabilityPaletteContent {
    var resetsSelectionWhileTyping: Bool { false }
    func isGrid(query: String) -> Bool { false }
    func selection(after move: PaletteMove, from row: Int, query: String) -> Int? { nil }
    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions) {}
    func delete(row: Int, query: String) -> Bool { false }
    func footerActions(row: Int, query: String) -> PaletteFooterActions { PaletteFooterActions(tab: tab) }
    var commandKeys: Set<String> { [] }
    func handleCommandKey(_ characters: String, query: String) {}
    func didShow(palette: PaletteContentActions) {}
}

/// What the footer names after Select: Return's action and Command-Return's. Nil leaves one out.
struct PaletteFooterActions: Equatable {
    var primary: String?
    var secondary: String?

    init(primary: String?, secondary: String?) {
        self.primary = primary
        self.secondary = secondary
    }

    /// The titles the tab's descriptor registers.
    init(tab: CommandPaletteTab) {
        self.init(primary: tab.primaryActionTitle, secondary: tab.secondaryActionTitle)
    }
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
    /// Closes the palette and pastes text into the app that was in front when it opened, or copies
    /// it and says why when it can't (`PalettePasteRoute`). With `restoresClipboard` true, what was on
    /// the clipboard comes back once the paste has been read.
    var paste: (_ text: String, _ restoresClipboard: Bool) -> Void = { _, _ in }
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
