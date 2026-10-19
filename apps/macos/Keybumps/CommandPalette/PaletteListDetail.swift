import SwiftUI

/// Raycast's list-and-detail layout, shared by the Dictation, Translate, and ScreenGrabs tabs: the
/// list on the left at a fixed width, a hairline, and the highlighted item in full on the right, or
/// the placeholder while no item is highlighted: nothing, or a hint, as beside the ScreenGrabs grid.
struct PaletteListDetail<Item, ListView: View, Detail: View, Placeholder: View>: View {
    /// The Dictation and Translate lists' width.
    static var defaultListWidth: CGFloat { 330 }

    /// The list's width: a list's, or a grid's wider column, as ScreenGrabs' (#552).
    var listWidth: CGFloat = Self.defaultListWidth
    /// The highlighted item, which the detail shows.
    let highlighted: Item?
    @ViewBuilder let list: ListView
    @ViewBuilder let detail: (Item) -> Detail
    /// What the detail's side shows while no item is highlighted.
    @ViewBuilder let placeholder: Placeholder

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: listWidth)
            Rectangle()
                .fill(PaletteTheme.border)
                .frame(width: 1)
            if let highlighted {
                detail(highlighted)
            } else {
                placeholder
            }
        }
    }
}

extension PaletteListDetail where Placeholder == Spacer {
    /// Nothing on the detail's side while no item is highlighted.
    init(
        listWidth: CGFloat = Self.defaultListWidth,
        highlighted: Item?,
        @ViewBuilder list: () -> ListView,
        @ViewBuilder detail: @escaping (Item) -> Detail
    ) {
        self.init(listWidth: listWidth, highlighted: highlighted, list: list, detail: detail, placeholder: { Spacer() })
    }
}

/// The list half of `PaletteListDetail`: a section header, with an accessory such as Clear All,
/// over rows, each a `PaletteRow` as in every other tab (#381). A click does what the tab's
/// `clickAction` says: in the Dictation and Translate tabs it highlights a row, whose actions the
/// detail shows, and a double-click chooses it (#552). The pointer highlights the row under it
/// (#351), and the highlighted row stays on screen as the keys move it (#353).
struct PaletteDetailList<Item: Identifiable, Accessory: View, Row: View>: View {
    let title: String
    let items: [Item]
    let selection: Int
    /// The tab's `CapabilityPaletteTab.clickAction`.
    let clickAction: PaletteClickAction
    let select: (Int) -> Void
    /// What Return does on a row, such as Copy, which a double-click does here.
    let choose: (Item) -> Void
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            PaletteListHeader(title: title) { accessory }

            ScrollViewReader { proxy in
                List(Array(items.enumerated()), id: \.element.id) { index, item in
                    PaletteClickButton(clickAction, select: { select(index) }, activate: { choose(item) }) {
                        row(item)
                    }
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
        clickAction: PaletteClickAction,
        select: @escaping (Int) -> Void,
        choose: @escaping (Item) -> Void,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.init(
            title: title, items: items, selection: selection, clickAction: clickAction, select: select, choose: choose,
            accessory: { EmptyView() }, row: row
        )
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

/// A detail pane's hairline, between Information's rows or between its sections, such as a saved
/// translation and the text it was translated from.
struct PaletteDivider: View {
    var body: some View {
        Rectangle().fill(PaletteTheme.border).frame(height: 1)
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
            PaletteDivider()
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
/// same, such as Copy ↵ ⌘C, so the buttons teach the keys. It calls what the keys do; one no key does,
/// such as Show in Finder, has no keycap. VoiceOver reads the title, with the keys as its hint:
/// "Copy", "Return, or Command C".
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
        .help(shortcuts.isEmpty ? title : "\(title) (\(shortcuts.map { $0.joined() }.joined(separator: " or ")))")
        .accessibilityLabel(title)
        .accessibilityHint(shortcuts.map(PaletteKeyAction.spokenShortcut).joined(separator: ", or "))
    }
}

/// A detail pane's action buttons where one line is too narrow for them, as beside the ScreenGrabs
/// grid (#552): they keep their order and go on to the next line where the next wouldn't fit, and
/// the last, Delete's, keeps the trailing end of its line, as a `Spacer` before it does in one line.
/// Each button is its ideal width, never shortened. VoiceOver reads them in order.
struct PaletteActionFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(of: subviews, width: proposal.width ?? .infinity)
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        let widest = lines.map(\.width).max() ?? 0
        // As wide as it's offered, as a line with a `Spacer` is; its widest line where it's offered any.
        return CGSize(width: proposal.width.map { $0.isFinite ? $0 : widest } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                if index == subviews.indices.last { x = max(x, bounds.maxX - size.width) }
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    /// The buttons on each line, left to right, and how wide and tall each line is.
    private func lines(of subviews: Subviews, width: CGFloat) -> [(indices: Range<Int>, width: CGFloat, height: CGFloat)] {
        var lines: [(indices: Range<Int>, width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let line = lines.last, line.width + spacing + size.width <= width {
                lines[lines.count - 1] = (line.indices.lowerBound..<index + 1, line.width + spacing + size.width, max(line.height, size.height))
            } else {
                lines.append((index..<index + 1, size.width, size.height))
            }
        }
        return lines
    }
}
