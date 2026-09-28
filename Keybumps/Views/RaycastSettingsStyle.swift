import AppKit
import SwiftUI

/// Colors and metrics copied from Raycast's Settings window (dark), with light equivalents.
enum SettingsTheme {
    static let pageBackground = Color(light: gray(0.96), dark: gray(0.086))
    static let sidebarBackground = Color(light: gray(0.93), dark: gray(0.106))
    static let card = Color(light: .white, dark: gray(0.118))
    static let control = Color(light: gray(0.9), dark: gray(0.173))
    static let field = Color(light: gray(0.9), dark: gray(0.137))
    static let separator = Color.primary.opacity(0.07)
    static let selection = Color.primary.opacity(0.08)

    static let rowMinHeight: CGFloat = 44
    static let rowInset: CGFloat = 11
    static let cardRadius: CGFloat = 10
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
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: SettingsTheme.subtitleSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Label on the left, small switch on the right.
struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
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

/// Raycast's compact rounded-rectangle buttons with a dark fill.
struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: SettingsTheme.titleSize, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 26)
            .background(
                SettingsTheme.control.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
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
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? "")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// A shortcut shown as one keycap pill, like Raycast's hotkey field.
struct SettingsHotkeyPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: SettingsTheme.titleSize, weight: .medium))
            .padding(.horizontal, 10)
            .frame(minWidth: 56, minHeight: 26)
            .background(SettingsTheme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A square icon button beside a hotkey pill, like Raycast's reset button.
struct SettingsIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(SettingsTheme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small icon tile in front of a command name, as in Raycast's Commands tables.
struct SettingsCommandIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
