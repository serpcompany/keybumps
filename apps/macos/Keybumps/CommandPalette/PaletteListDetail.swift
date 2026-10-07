import SwiftUI

/// Raycast's list-and-detail layout, shared by the Dictation and Translate tabs: the list on the
/// left at a fixed width, a hairline, and the highlighted item in full on the right, or nothing
/// while no item is highlighted.
struct PaletteListDetail<Item, ListView: View, Detail: View>: View {
    static var listWidth: CGFloat { 330 }

    /// The highlighted item, which the detail shows.
    let highlighted: Item?
    @ViewBuilder let list: ListView
    @ViewBuilder let detail: (Item) -> Detail

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: Self.listWidth)
            Rectangle()
                .fill(PaletteTheme.border)
                .frame(width: 1)
            if let highlighted {
                detail(highlighted)
            } else {
                Spacer()
            }
        }
    }
}

/// The list half of `PaletteListDetail`: a section header, with an accessory such as Clear All,
/// over rows, each a `PaletteRow` as in every other tab (#381). A click highlights a row and a
/// double-click chooses it. The pointer highlights
/// the row under it (#351), and the highlighted row stays on screen as the keys move it (#353).
struct PaletteDetailList<Item: Identifiable, Accessory: View, Row: View>: View {
    let title: String
    let items: [Item]
    let selection: Int
    let select: (Int) -> Void
    /// A double-click on a row, such as Copy.
    let choose: (Item) -> Void
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            PaletteListHeader(title: title) { accessory }

            ScrollViewReader { proxy in
                List(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { select(index) } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { choose(item) })
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
                    .paletteHoverHighlights(row: index)
                    .paletteRowBackground(isSelected: index == selection)
                    .id(item.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .paletteScrollsToSelection(selection, proxy: proxy) { items.indices.contains($0) ? items[$0].id : nil }
            }
        }
    }
}

extension PaletteDetailList where Accessory == EmptyView {
    init(
        title: String,
        items: [Item],
        selection: Int,
        select: @escaping (Int) -> Void,
        choose: @escaping (Item) -> Void,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.init(title: title, items: items, selection: selection, select: select, choose: choose, accessory: { EmptyView() }, row: row)
    }
}

/// A detail pane's Information section: its header, then a title and value on each row, between
/// hairlines, such as when a recording was made.
struct PaletteInformation<Rows: View>: View {
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaletteSectionHeader("Information")
                .padding(.bottom, 6)
            rows
        }
    }
}

/// One row of `PaletteInformation`.
struct PaletteInformationRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(PaletteTheme.border).frame(height: 1)
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text(value).foregroundStyle(.primary)
            }
            .font(.system(size: 13))
            .padding(.vertical, 8)
        }
    }
}

/// A detail pane's action button: its icon and title, then a keycap for each shortcut that does the
/// same, such as Copy ↵ ⌘C, so the buttons teach the keys. It calls what the keys do. VoiceOver reads
/// the title, with the keys as its hint: "Copy", "Return, or Command C".
struct PaletteActionButton: View {
    let title: String
    let systemImage: String
    /// Each shortcut that does the same, in order: `[["↵"], ["⌘", "C"]]`. A shortcut's keys share one
    /// keycap, so a row of buttons fits beside a list.
    let shortcuts: [[String]]
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                ForEach(shortcuts, id: \.self) { PaletteKeycap($0.joined()) }
            }
            // Never shortened: the row leaves room for every button.
            .fixedSize()
        }
        .buttonStyle(PalettePillButtonStyle())
        .help("\(title) (\(shortcuts.map { $0.joined() }.joined(separator: " or ")))")
        .accessibilityLabel(title)
        .accessibilityHint(shortcuts.map(PaletteKeyAction.spokenShortcut).joined(separator: ", or "))
    }
}
