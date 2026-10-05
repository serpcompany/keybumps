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
    /// The rows Up and Down move through, for the text in the search field.
    func rowCount(query: String) -> Int
    /// Return on the selected row; `withCommand` is Command-Return.
    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions)
    /// Delete on the selected row, with Command or once the search field is empty. Returns whether
    /// it removed something; the palette then keeps the selection on a row that still exists.
    func delete(row: Int, query: String) -> Bool
    /// What the footer says Return and Command-Return do on the selected row.
    func footerActions(row: Int, query: String) -> PaletteFooterActions
    /// Runs each time the palette shows the tab: when it opens on it, or switches to it.
    func didShow(palette: PaletteContentActions)
    /// The rows under the tab bar.
    func makeView(_ context: PaletteContentContext) -> AnyView
}

extension CapabilityPaletteContent {
    var resetsSelectionWhileTyping: Bool { false }
    func activate(row: Int, query: String, withCommand: Bool, palette: PaletteContentActions) {}
    func delete(row: Int, query: String) -> Bool { false }
    func footerActions(row: Int, query: String) -> PaletteFooterActions { PaletteFooterActions(tab: tab) }
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
    /// Empties the search field, as after a row has used what was typed.
    let clearQuery: () -> Void
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
