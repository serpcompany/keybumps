import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

/// ⇧1–9 quick select (#182): ⇧N does what Return does on the Nth row on screen, in every tab with a
/// list, the Screenshots grid, and `/`'s filters. Each of those rows shows its ⇧N keycap. Numbers
/// follow the rows on screen, so after scrolling ⇧1 is the top row showing, as in Alfred.
@MainActor @Observable
final class PaletteQuickSelect {
    /// The bottom band the footer floats over. A row whose middle is in it isn't counted as on screen.
    static let footerInset: CGFloat = 56

    /// The area under the tab bar where rows show, in window coordinates. Rows measure themselves
    /// in window coordinates too: a List hosts each row on its own, where the palette's own
    /// coordinate spaces don't reach.
    @ObservationIgnored private var viewport = CGRect.null
    /// Each row view drawn, by its own token: its index in the tab's rows and where it is. Keyed by
    /// view rather than index, so the old tab's rows going away can't remove the new tab's.
    @ObservationIgnored private var rows: [UUID: (row: Int, frame: CGRect)] = [:]

    /// The rows on screen in the open tab. Changes only when a row comes on or goes off screen.
    private(set) var visibleRows: Set<Int> = []

    /// The row ⇧1 picks: the top one on screen, or the first when no row has said (no view drawn).
    var firstRow: Int { visibleRows.min() ?? 0 }

    /// The row ⇧`number` picks, or nil when that row isn't on screen.
    func row(for number: Int) -> Int? {
        let row = firstRow + number - 1
        return visibleRows.isEmpty || visibleRows.contains(row) ? row : nil
    }

    /// The number a row shows: nil when it isn't on screen, or comes after the ninth.
    func number(forRow row: Int) -> Int? {
        guard visibleRows.contains(row) else { return nil }
        let number = row - firstRow + 1
        return (1...9).contains(number) ? number : nil
    }

    func setViewport(_ frame: CGRect) {
        viewport = frame
        update()
    }

    /// Where a row view is, or nil once it's gone.
    func report(_ view: UUID, row: Int, frame: CGRect?) {
        rows[view] = frame.map { (row, $0) }
        update()
    }

    /// A row view now shows another row, as when a search narrows the list.
    func move(_ view: UUID, to row: Int) {
        guard let frame = rows[view]?.frame else { return }
        report(view, row: row, frame: frame)
    }

    private func update() {
        let visible = Set(rows.values.filter { isOnScreen($0.frame) }.map(\.row))
        if visible != visibleRows { visibleRows = visible }
    }

    private func isOnScreen(_ frame: CGRect) -> Bool {
        !viewport.isNull && frame.minY >= viewport.minY - 1 && frame.midY <= viewport.maxY - Self.footerInset
    }

    /// The number ⇧ and a number key pick. The key is matched by its position in the top row, so
    /// it's the same on every keyboard layout; Caps Lock doesn't matter, and any other modifier
    /// means it isn't quick select. The numeric keypad isn't used.
    static func number(for event: NSEvent) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift else { return nil }
        return digitKeyCodes.firstIndex(of: Int(event.keyCode)).map { $0 + 1 }
    }

    private static let digitKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]
}

extension View {
    /// A row ⇧1–9 can pick: it says whether it's on screen, and shows its ⇧N keycap at the end.
    /// Apply it to the row's content, inside its padding.
    func paletteQuickSelect(row: Int) -> some View {
        modifier(PaletteQuickSelectRow(row: row, placement: .trailing))
    }

    /// A grid tile ⇧1–9 can pick, with its keycap over the top-leading corner.
    func paletteQuickSelectTile(row: Int) -> some View {
        modifier(PaletteQuickSelectRow(row: row, placement: .topLeading))
    }
}

private struct PaletteQuickSelectRow: ViewModifier {
    enum Placement { case trailing, topLeading }

    let row: Int
    let placement: Placement
    @Environment(PaletteQuickSelect.self) private var quickSelect: PaletteQuickSelect?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        laidOut(content)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                quickSelect?.report(token, row: row, frame: frame)
            }
            .onChange(of: row) {
                quickSelect?.move(token, to: row)
            }
            .onDisappear {
                quickSelect?.report(token, row: row, frame: nil)
            }
    }

    @ViewBuilder
    private func laidOut(_ content: Content) -> some View {
        switch placement {
        case .trailing:
            HStack(spacing: 10) {
                content
                if quickSelect != nil {
                    // Every row keeps the space, so what's beside it lines up whether or not it has a number.
                    keycap.frame(width: 30, alignment: .trailing)
                }
            }
        case .topLeading:
            content.overlay(alignment: .topLeading) {
                keycap.padding(8)
            }
        }
    }

    @ViewBuilder
    private var keycap: some View {
        if let number = quickSelect?.number(forRow: row) {
            PaletteKeycap("⇧\(number)")
                .accessibilityLabel("Shift \(number)")
                .help("Shift-\(number)")
        }
    }
}
