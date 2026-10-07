import AppKit
import SwiftUI

/// The one set of metrics every Command Palette list shares (#381), so switching tabs with ← → never
/// moves the rows: the section header above them, each row's leading well, where its title starts,
/// and its height. They're the Clipboard and Snippets rows'. Lists draw their header with
/// `PaletteListHeader` and their rows with `PaletteRow`, and the Screenshots and Emoji grids start
/// where the rows' wells do.
enum PaletteRowMetrics {
    /// SwiftUI's List on macOS lays each row's content out this far in from the list's edge (half
    /// its table's spacing between cells), though the row's highlight still starts at the edge. What
    /// lines up with the rows from outside a row, such as a grid, adds it; a section header inside a
    /// list, as Timers' are, takes it off.
    static let listCellInset: CGFloat = 8
    /// How far a row's content sits in from its cell's edges.
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 8

    /// Every row's leading well. A thumbnail fills it, a symbol sits on its tile (`PaletteRowIcon`),
    /// and an image with a shape of its own (an app icon, a Settings tile, an emoji, a timer's ring)
    /// is centered in it.
    static let wellSize = CGSize(width: 52, height: 38)
    static let wellCornerRadius: CGFloat = 6
    /// The space between the well and the title.
    static let wellSpacing: CGFloat = 14
    /// An app icon in the well.
    static let iconSize: CGFloat = 32
    /// A Settings tile in the well: an app icon's artwork without its transparent margin.
    static let iconTileSize: CGFloat = 26
    /// An emoji in the well.
    static let emojiSize: CGFloat = 24

    /// Where every row's well starts, from the list's leading edge. The grids start there too.
    static var wellX: CGFloat { listCellInset + horizontalInset }
    /// Where every row's title starts, from the list's leading edge.
    static var titleX: CGFloat { wellX + wellSize.width + wellSpacing }
    /// Every row's height, with one line of text or two: the well's, inset.
    static var rowHeight: CGFloat { wellSize.height + 2 * verticalInset }

    /// Where the section header's title starts, from the list's leading edge.
    static let headerInset: CGFloat = 18
    /// The band the section header sits in: a compact pill's height, so a header with Clear All or
    /// New Snippet beside it is as tall as one without.
    static var headerHeight: CGFloat { PalettePillButtonStyle.Size.compact.height }
    static let headerTop: CGFloat = 10
    static let headerBottom: CGFloat = 6
    /// From the top of the list's area to its first row: the header band and the space around it.
    static var headerBlockHeight: CGFloat { headerTop + headerHeight + headerBottom }
}

/// A Command Palette list row: its well, then its content, whose leading edge is where the title
/// starts, always `PaletteRowMetrics.rowHeight` tall. A row button's label is one of these, so the
/// row's padding takes clicks and the pointer too.
struct PaletteRow<Well: View, Content: View>: View {
    @ViewBuilder let well: Well
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: PaletteRowMetrics.wellSpacing) {
            well
                .frame(width: PaletteRowMetrics.wellSize.width, height: PaletteRowMetrics.wellSize.height)
                .paletteLayoutProbe(.well)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .paletteLayoutProbe(.title)
        }
        .frame(height: PaletteRowMetrics.wellSize.height)
        .padding(.horizontal, PaletteRowMetrics.horizontalInset)
        .padding(.vertical, PaletteRowMetrics.verticalInset)
        .contentShape(Rectangle())
        .paletteLayoutProbe(.row)
    }
}

/// A symbol on the well's tile, as a text item's preview, a snippet, or a recording shows it.
struct PaletteRowIcon: View {
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18))
            .foregroundStyle(tint)
            .paletteWellTile()
    }
}

/// An app's icon centered in the well.
struct PaletteRowAppIcon: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: PaletteRowMetrics.iconSize, height: PaletteRowMetrics.iconSize)
    }
}

/// An emoji centered in the well.
struct PaletteRowEmoji: View {
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: PaletteRowMetrics.emojiSize))
            .accessibilityHidden(true)
    }
}

/// The section header above a palette list's rows, with an accessory such as Clear All on the right.
/// It's as tall with an accessory as without, so every tab's first row starts at the same height.
struct PaletteListHeader<Accessory: View>: View {
    let title: String
    /// It's one of the list's rows, as Timers' section headers are.
    var isInList = false
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack {
            PaletteSectionHeader(title)
            Spacer()
            accessory
        }
        .paletteHeaderBand(isInList: isInList)
    }
}

extension PaletteListHeader where Accessory == EmptyView {
    init(_ title: String, isInList: Bool = false) {
        self.init(title: title, isInList: isInList) { EmptyView() }
    }
}

extension View {
    /// The well's gray tile behind a symbol or a thumbnail, the well's size.
    func paletteWellTile() -> some View {
        let shape = RoundedRectangle(cornerRadius: PaletteRowMetrics.wellCornerRadius)
        return frame(width: PaletteRowMetrics.wellSize.width, height: PaletteRowMetrics.wellSize.height)
            .background(Color.primary.opacity(0.08), in: shape)
            .clipShape(shape)
    }

    /// The section header's band and the space around it, for what sits where a list's header
    /// does, such as the Emoji grid's highlighted emoji. Inside a list's row, the list's own inset
    /// is taken off, so it starts where the other headers do.
    func paletteHeaderBand(isInList: Bool = false) -> some View {
        let inset = PaletteRowMetrics.headerInset - (isInList ? PaletteRowMetrics.listCellInset : 0)
        return frame(height: PaletteRowMetrics.headerHeight)
            .paletteLayoutProbe(.header)
            .padding(.horizontal, inset)
            .padding(.top, PaletteRowMetrics.headerTop)
            .padding(.bottom, PaletteRowMetrics.headerBottom)
    }

    /// Unit tests only: reports this view's frame to the palette's `PaletteLayoutProbe`, if a test
    /// gave it one. Otherwise it does nothing.
    func paletteLayoutProbe(_ part: PaletteLayoutProbe.Part) -> some View {
        modifier(PaletteLayoutProbing(part: part))
    }
}

/// Unit tests only (#381): where a palette laid out the parts every tab shares, in its window's
/// coordinates from the top left, so a test can check every tab puts them in the same place. For
/// each part it reports the topmost of the views on screen, which is the first row's. A test sets it
/// on the palette (`CommandPaletteController.layoutProbe`) before the palette first lays out; the
/// app never does, so nothing is measured there.
@MainActor
final class PaletteLayoutProbe {
    enum Part: Hashable {
        /// The section header's band (`paletteHeaderBand`), padding excluded.
        case header
        /// A row, padding included.
        case row
        case well
        /// What follows the well, which starts where the title does.
        case title
        /// A grid's item: a screenshot's thumbnail, or an emoji's tile.
        case gridItem
        /// A section title inside a grid, such as an emoji group's.
        case gridHeader
    }

    /// Each view's latest frame, until it goes.
    private var views: [UUID: (part: Part, frame: CGRect)] = [:]

    /// The topmost frame of each part, leftmost first among equals.
    var frames: [Part: CGRect] {
        views.values.reduce(into: [:]) { topmost, view in
            if let kept = topmost[view.part], (kept.minY, kept.minX) <= (view.frame.minY, view.frame.minX) { return }
            topmost[view.part] = view.frame
        }
    }

    /// Forgets every view, so only what lays out from now on is reported.
    func reset() {
        views = [:]
    }

    fileprivate func record(_ part: Part, _ frame: CGRect, for view: UUID) {
        views[view] = (part, frame)
    }

    fileprivate func remove(_ view: UUID) {
        views[view] = nil
    }
}

extension EnvironmentValues {
    @Entry var paletteLayoutProbe: PaletteLayoutProbe?
}

private struct PaletteLayoutProbing: ViewModifier {
    let part: PaletteLayoutProbe.Part
    @Environment(\.paletteLayoutProbe) private var probe

    func body(content: Content) -> some View {
        if let probe {
            content.modifier(PaletteLayoutRecording(part: part, probe: probe))
        } else {
            content
        }
    }
}

/// Reports one view's frame each time it changes, and its going.
private struct PaletteLayoutRecording: ViewModifier {
    let part: PaletteLayoutProbe.Part
    let probe: PaletteLayoutProbe
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                probe.record(part, frame, for: id)
            }
            .onDisappear { probe.remove(id) }
    }
}
