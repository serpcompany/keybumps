import AppKit
import SwiftUI

/// Colors and metrics copied from Raycast's Settings window (dark), with light equivalents.
enum SettingsTheme {
    static let pageBackground = Color(light: gray(0.96), dark: gray(0.078))
    static let sidebarBackground = Color(light: gray(0.93), dark: gray(0.071))
    static let card = Color(light: .white, dark: gray(0.114))
    static let control = Color(light: gray(0.9), dark: gray(0.165))
    static let separator = Color.primary.opacity(0.07)
    static let selection = Color.primary.opacity(0.09)

    static let rowMinHeight: CGFloat = 52
    static let rowInset: CGFloat = 14
    static let cardRadius: CGFloat = 12
    static let titleSize: CGFloat = 15
    static let subtitleSize: CGFloat = 13

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
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsTheme.pageBackground)
        .font(.system(size: SettingsTheme.titleSize))
        .toggleStyle(SettingsSwitchToggleStyle())
        .labeledContentStyle(SettingsRowLabeledContentStyle())
        .buttonStyle(SettingsButtonStyle())
    }
}

/// Raycast's rounded-rectangle buttons with a dark fill.
struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: SettingsTheme.titleSize - 1, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(
                SettingsTheme.control.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// A heading outside a rounded card whose rows are separated by inset dividers.
struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: SettingsTheme.titleSize, weight: .semibold))
                    .padding(.leading, SettingsTheme.rowInset)
                    .accessibilityAddTraits(.isHeader)
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
                    .padding(.vertical, 6)
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

/// A row title with an optional gray subtitle, as in Raycast's "Theme Studio" row.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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

/// Label on the left, switch on the right.
struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
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

/// A shortcut shown as one keycap pill, like Raycast's hotkey field.
struct SettingsHotkeyPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: SettingsTheme.titleSize, weight: .medium))
            .padding(.horizontal, 12)
            .frame(minWidth: 64, minHeight: 30)
            .background(SettingsTheme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(SettingsTheme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
