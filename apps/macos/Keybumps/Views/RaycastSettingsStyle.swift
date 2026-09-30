import AppKit
import SwiftUI

/// Colors and metrics copied from Raycast's Settings window (dark), with light equivalents.
enum SettingsTheme {
    static let pageBackground = Color(light: gray(0.96), dark: gray(0.059))
    static let sidebarBackground = Color(light: gray(0.93), dark: gray(0.075))
    static let card = Color(light: .white, dark: gray(0.09))
    static let control = Color(light: gray(0.9), dark: gray(0.15))
    static let field = Color(light: gray(0.9), dark: gray(0.1))
    static let separator = Color.primary.opacity(0.07)
    static let selection = Color.primary.opacity(0.08)

    static let rowMinHeight: CGFloat = 44
    static let rowInset: CGFloat = 11
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let titleSize: CGFloat = 13
    static let subtitleSize: CGFloat = 11
    static let sidebarTextSize: CGFloat = 14

    private static func gray(_ value: CGFloat) -> NSColor {
        NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// A Settings page: a scrolling column of groups on the page background.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsTheme.pageBackground)
        .font(.system(size: SettingsTheme.titleSize))
        .toggleStyle(SettingsSwitchToggleStyle())
        .labeledContentStyle(SettingsRowLabeledContentStyle())
        .buttonStyle(SettingsButtonStyle())
    }
}

/// The centered icon, name, and one-line summary at the top of an extension page.
struct SettingsHero: View {
    let systemImage: String
    let tint: Color
    let title: String
    let summary: String

    var body: some View {
        VStack(spacing: 6) {
            SettingsIconTile(systemImage: systemImage, tint: tint, size: 52)
                .padding(.bottom, 6)
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(summary)
                .font(.system(size: SettingsTheme.titleSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }
}

/// A heading outside a rounded card whose rows are separated by inset dividers.
struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let subtitle: String?
    private let content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let title {
                        Text(title)
                            .font(.system(size: SettingsTheme.titleSize, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.85))
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: SettingsTheme.subtitleSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, SettingsTheme.rowInset)
                .padding(.top, 8)
            }
            _VariadicView.Tree(DividedRows()) { content }
                .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
        }
    }
}

/// Uses `_VariadicView` because the macOS 14 target has no public way to visit child views;
/// replace with `ForEach(subviews:)` once the target is macOS 15.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                    .frame(maxWidth: .infinity, minHeight: SettingsTheme.rowMinHeight, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, SettingsTheme.rowInset)
                if child.id != children.last?.id {
                    SettingsTheme.separator
                        .frame(height: 1)
                        .padding(.horizontal, SettingsTheme.rowInset)
                }
            }
        }
    }
}

/// A row title with an optional gray subtitle.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: SettingsTheme.subtitleSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Gray explanatory text on its own row.
struct SettingsNote: View {
    let text: String
    let tint: Color?

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: SettingsTheme.subtitleSize))
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Label on the left, small switch on the right.
struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsCompactSwitch()
    }
}

/// Label on the left, control on the right.
struct SettingsRowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.secondary)
        }
    }
}

/// Raycast's compact rounded-rectangle buttons with a dark fill. A prominent button (a sheet's
/// default action, such as Save) is filled with the accent color instead.
struct SettingsButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: SettingsTheme.titleSize, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
            .background(
                (isProminent ? Color.accentColor : SettingsTheme.control).opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
            )
            .foregroundStyle(foreground(configuration))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }

    private func foreground(_ configuration: Configuration) -> AnyShapeStyle {
        if isProminent { return AnyShapeStyle(.white) }
        return configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary)
    }
}

/// Raycast's borderless dropdown: the selected value and a small chevron.
struct SettingsDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(options.first { $0.value == selection }?.label ?? "")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// Raycast's hotkey field: gray "Record Hotkey" when empty, a filled keycap pill when set, an
/// outlined field showing held modifiers while recording, and a clear button on hover.
struct SettingsHotkeyField: View {
    let shortcut: ShortcutBinding?
    let isRecording: Bool
    let liveModifiers: String
    let title: String
    var width: CGFloat = 160
    let record: () -> Void
    let clear: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: record) {
            Text(label)
                .font(.system(size: SettingsTheme.titleSize, weight: showsKeys ? .medium : .regular))
                .foregroundStyle(showsKeys ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.leading, 10)
                .padding(.trailing, 24)
                .frame(width: width, height: 28, alignment: .leading)
                .background(
                    shortcut != nil && !isRecording ? SettingsTheme.control : .clear,
                    in: RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if shortcut != nil, isHovering, !isRecording {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 7)
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut for \(title)")
            }
        }
        .onHover { isHovering = $0 }
        .help("Click, then press a new shortcut. Delete clears it; Escape cancels.")
        .accessibilityLabel("Record shortcut for \(title)")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isRecording { return "Waiting for shortcut" }
        guard let shortcut else { return "No shortcut assigned" }
        return KeyboardShortcutRegistry.accessibilityCopy(for: shortcut.displayName)
    }

    private var showsKeys: Bool {
        isRecording ? !liveModifiers.isEmpty : shortcut != nil
    }

    private var label: String {
        if isRecording {
            return liveModifiers.isEmpty ? "Recording…" : liveModifiers.map(String.init).joined(separator: " ")
        }
        guard let shortcut else { return "Record Hotkey" }
        return ShortcutKeycapPresentation(shortcut: shortcut.displayName).keys.joined(separator: " ")
    }

    private var borderColor: Color {
        if isRecording { return Color.primary.opacity(0.45) }
        return shortcut == nil && isHovering ? Color.primary.opacity(0.18) : .clear
    }
}

/// A square icon button beside a hotkey field, like Raycast's reset button, or a list's + and −.
struct SettingsIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(SettingsTheme.control, in: RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The white glyph on a tinted rounded square used for capabilities: sidebar rows, page heroes,
/// and command rows. Glyph size and corner radius scale with the tile.
struct SettingsIconTile: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

extension View {
    /// The small switch Raycast uses, for toggles laid out by hand (the toolbar, rows with buttons).
    func settingsCompactSwitch() -> some View {
        toggleStyle(.switch).controlSize(.small)
    }
}

/// Sidebar row chrome: a rounded highlight on the selected row.
struct SettingsSidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? SettingsTheme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
