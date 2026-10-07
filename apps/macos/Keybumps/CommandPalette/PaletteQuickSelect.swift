import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

/// ⇧1–9 quick select (#182): ⇧N does what Return does on the Nth row on screen, in every tab with a
/// list, the Screenshots grid, and `/`'s filters. Each of those rows shows its ⇧N keycap. Numbers
/// follow the rows on screen, so after scrolling ⇧1 is the top row showing, as in Alfred.
@MainActor @Observable
final class PaletteQuickSelect {
    /// The list or grid the rows scroll in, in window coordinates, below any header above it
    /// (`paletteQuickSelectViewport()`). Rows measure themselves in window coordinates too: a List
    /// hosts each row on its own, where the palette's own coordinate spaces don't reach.
    @ObservationIgnored private var viewport = CGRect.null
    /// The list view that reported `viewport`, so only it going away clears it.
    @ObservationIgnored private var viewportOwner: UUID?
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

    /// Where a list is, or nil once it's gone. The latest list to report is the one rows are
    /// measured against; an older one going away afterwards changes nothing.
    func setViewport(_ frame: CGRect?, of list: UUID) {
        if let frame {
            viewport = frame
            viewportOwner = list
        } else if viewportOwner == list {
            viewport = .null
            viewportOwner = nil
        }
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
        !viewport.isNull && frame.minY >= viewport.minY - 1 && frame.midY <= viewport.maxY - PaletteTheme.footerClearance
    }

    /// The number ⇧ and a number key pick. The key is matched by its position in the top row, so
    /// it's the same on every keyboard layout; Caps Lock doesn't matter, and any other modifier
    /// means it isn't quick select. The numeric keypad isn't used.
    static func number(for event: NSEvent) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift else { return nil }
        return digitKeyCodes.firstIndex(of: Int(event.keyCode)).map { $0 + 1 }
    }

    /// Whether ⇧ and the key type a digit, as on French and Belgian layouts, where digits need ⇧.
    /// Timers needs digits for durations, so there the key types instead (owner, 2026-10-07).
    static func typesDigit(_ event: NSEvent) -> Bool {
        guard let characters = event.characters, characters.count == 1, let character = characters.first else { return false }
        return character.isASCII && character.isNumber
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

    /// A row ⇧1–9 picks without a keycap: Hotkeys, whose rows show keyboard shortcuts that a ⇧N
    /// beside them would read as part of (owner, 2026-10-07).
    func paletteQuickSelectWithoutKeycap(row: Int) -> some View {
        modifier(PaletteQuickSelectRow(row: row, placement: .none))
    }

    /// A grid tile ⇧1–9 can pick, with its keycap over the top-leading corner.
    func paletteQuickSelectTile(row: Int) -> some View {
        modifier(PaletteQuickSelectRow(row: row, placement: .topLeading))
    }

    /// The List or ScrollView whose rows ⇧1–9 numbers. Rows count as on screen only inside it, so
    /// one scrolled up behind a header above the list, such as Clipboard's Clear All, doesn't.
    func paletteQuickSelectViewport() -> some View {
        modifier(PaletteQuickSelectViewport())
    }
}

private struct PaletteQuickSelectViewport: ViewModifier {
    @Environment(PaletteQuickSelect.self) private var quickSelect: PaletteQuickSelect?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                quickSelect?.setViewport(frame, of: token)
            }
            .onDisappear {
                quickSelect?.setViewport(nil, of: token)
            }
    }
}

private struct PaletteQuickSelectRow: ViewModifier {
    enum Placement { case trailing, topLeading, none }

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
                    // Every row keeps the space, so what's beside it lines up whether or not it has a
                    // number; a frame around a keycap that isn't there would take none.
                    Color.clear
                        .frame(width: 30)
                        .overlay(alignment: .trailing) { keycap }
                }
            }
        case .topLeading:
            content.overlay(alignment: .topLeading) {
                keycap
                    .padding(8)
                    // It sits on the thumbnail, which a click there should still reach.
                    .allowsHitTesting(false)
            }
        case .none:
            content
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
