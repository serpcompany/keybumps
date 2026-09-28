import AppKit
import SwiftUI

/// Colors and metrics copied from Raycast's launcher window (dark), with light equivalents.
enum PaletteTheme {
    static let background = Color(light: .white, dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.11, alpha: 1))
    static let border = Color.primary.opacity(0.1)
    static let selection = Color.primary.opacity(0.1)
    static let keycap = Color.primary.opacity(0.1)
    static let cornerRadius: CGFloat = 16
    static let rowRadius: CGFloat = 8
}

/// A small gray group title above results, like Raycast's "Suggestions".
struct PaletteSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One key in the footer's action hints.
struct PaletteKeycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 3)
            .background(PaletteTheme.keycap, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

extension View {
    /// Raycast's selected result: a rounded neutral highlight inset from the list edges.
    func paletteRowBackground(isSelected: Bool) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: PaletteTheme.rowRadius, style: .continuous)
                .fill(isSelected ? PaletteTheme.selection : .clear)
                .padding(.horizontal, 6)
        )
    }
}
