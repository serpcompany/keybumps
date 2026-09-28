import AppKit
import SwiftUI

/// Colors and metrics copied from Raycast's launcher window (dark), with light equivalents.
enum PaletteTheme {
    static let background = SettingsTheme.sidebarBackground
    static let border = Color.primary.opacity(0.1)
    static let selection = Color.primary.opacity(0.08)
    static let keycapFill = Color.primary.opacity(0.05)
    static let keycapBorder = Color.primary.opacity(0.16)
    static let pill = SettingsTheme.card
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

/// Raycast's outlined keycap: a dark fill, a hairline border, and a gray glyph.
struct PaletteKeycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 2)
            .background(PaletteTheme.keycapFill, in: shape)
            .overlay(shape.strokeBorder(PaletteTheme.keycapBorder, lineWidth: 1))
    }
}

/// A shortcut such as "⌘1" as a row of outlined keycaps.
struct PaletteKeycaps: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ShortcutKeycapPresentation(shortcut: shortcut).keys, id: \.self) { PaletteKeycap($0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(KeyboardShortcutRegistry.accessibilityCopy(for: shortcut))
    }
}

/// A small outlined chip for secondary actions such as Clear All.
struct PaletteChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .labelStyle(.titleOnly)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(PaletteTheme.keycapFill.opacity(configuration.isPressed ? 2 : 1), in: shape)
            .overlay(shape.strokeBorder(PaletteTheme.keycapBorder, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
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
