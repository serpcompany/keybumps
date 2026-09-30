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
    /// The height of the footer's floating pill and its round Settings button.
    static let footerHeight: CGFloat = 38
}

/// A small gray group title above results, like Raycast's "Suggestions".
struct PaletteSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13))
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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 22, minHeight: 22)
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
    /// Shows the label's icon too, for action rows such as the Dictation detail's.
    var showsIcon = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if showsIcon {
                configuration.label.labelStyle(.titleAndIcon)
            } else {
                configuration.label.labelStyle(.titleOnly)
            }
        }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, showsIcon ? 10 : 8)
            .frame(minHeight: showsIcon ? 26 : 22)
            .background(PaletteTheme.keycapFill.opacity(configuration.isPressed ? 2 : 1), in: shape)
            .overlay(shape.strokeBorder(PaletteTheme.keycapBorder, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

extension View {
    /// Raycast's floating footer surface, shared by the action pill and the round Settings button.
    func paletteFloatingSurface(_ shape: some InsettableShape) -> some View {
        background(PaletteTheme.pill, in: shape)
            .overlay(shape.strokeBorder(PaletteTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    /// Raycast's selected result: a rounded neutral highlight inset from the list edges.
    func paletteRowBackground(isSelected: Bool) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: PaletteTheme.rowRadius, style: .continuous)
                .fill(isSelected ? PaletteTheme.selection : .clear)
                .padding(.horizontal, 6)
        )
    }
}

/// Shows a Shortcut Coach tip; the seam lets tests observe tips without drawing a panel.
@MainActor
protocol CoachTipPresenting: AnyObject {
    func showCoach(_ presentation: NotchCoachPresentation, duration: TimeInterval)
}

extension CoachTipPresenting {
    func showCoach(_ presentation: NotchCoachPresentation) { showCoach(presentation, duration: 4) }
}

/// A brief notice such as "Copied to Clipboard" that grows out of the notch: the message sits
/// left of the notch and an icon (or a shortcut's keycaps) right of it, on black that blends with
/// the notch. Screens without a notch show the same black tab hanging from the top of the menu bar.
@MainActor
final class PaletteHUD: CoachTipPresenting {
    /// The one notch notice every app surface shares, so a new notice replaces the current one
    /// instead of drawing over it.
    static let shared = PaletteHUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var isShowingCoach = false

    /// The surface that currently owns the notch (Dictation while its indicator shows). While set,
    /// other notices are dropped rather than drawn over it, and one already showing is hidden. It is
    /// weak, so an owner that goes away can never leave notices suppressed.
    private weak var notchOwner: AnyObject?

    var isSuppressed: Bool { notchOwner != nil }

    /// Hands the notch to `owner`, hiding any notice that is showing.
    func claimNotch(for owner: AnyObject) {
        notchOwner = owner
        dismiss()
    }

    /// Gives the notch back, if `owner` still holds it.
    func releaseNotch(from owner: AnyObject) {
        if notchOwner === owner { notchOwner = nil }
    }

    func show(
        _ message: String,
        systemImage: String = "checkmark.circle.fill",
        tint: Color = .green,
        shortcut: String? = nil,
        duration: TimeInterval? = nil
    ) {
        guard !isSuppressed, let screen = NSScreen.main else { return }
        let panel = panel ?? makePanel()
        self.panel = panel

        let notchWidth = Self.notchWidth(of: screen)
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 28)
        // Both sides of the notch are equally wide, so the notch stays centered.
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width)
        let keys = shortcut.map { ShortcutKeycapPresentation(shortcut: $0).keys } ?? []
        let trailingWidth = keys.isEmpty ? 20 : CGFloat(keys.count) * 25
        present(
            NotchNoticeView(
                message: message, systemImage: systemImage, tint: tint, keys: keys,
                notchWidth: notchWidth, wingWidth: max(textWidth, trailingWidth) + 32, height: height
            ),
            on: screen,
            announcement: message,
            duration: duration ?? (tint == .green ? 1.6 : 3)
        )
    }

    /// A Shortcut Coach tip: the notch drops down into a two-row panel with the app's icon, the
    /// action and app name, and the shortcut's keycaps, edged with an animated glow so it is hard
    /// to miss.
    func showCoach(_ presentation: NotchCoachPresentation, duration: TimeInterval) {
        guard !isSuppressed, let screen = NSScreen.main else { return }
        present(
            NotchCoachView(
                presentation: presentation,
                icon: presentation.applicationIcon(),
                notchWidth: Self.notchWidth(of: screen),
                notchHeight: max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 28)
            ),
            on: screen,
            announcement: presentation.announcement,
            duration: duration
        )
        isShowingCoach = true
    }

    /// Hides the current notice at once.
    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        isShowingCoach = false
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    /// Hides the current notice only if it is a Shortcut Coach tip.
    func dismissCoach() {
        if isShowingCoach { dismiss() }
    }

    private func present(_ view: some View, on screen: NSScreen, announcement: String, duration: TimeInterval) {
        let panel = panel ?? makePanel()
        self.panel = panel
        isShowingCoach = false
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 }) {
                // A newer show may have started during the fade.
                if panel?.alphaValue == 0 {
                    self?.isShowingCoach = false
                    panel?.orderOut(nil)
                    // Drop the view so its animations stop while nothing is shown.
                    panel?.contentView = nil
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The width of the camera housing, or zero on screens without one.
    static func notchWidth(of screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, right.minX - left.maxX)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("paletteHUD")
        return panel
    }
}

private struct NotchNoticeView: View {
    let message: String
    let systemImage: String
    let tint: Color
    let keys: [String]
    let notchWidth: CGFloat
    let wingWidth: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    var body: some View {
        HStack(spacing: 0) {
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, notchWidth > 0 ? 0 : 16)
                .padding(.trailing, notchWidth > 0 ? 14 : 8)
                .frame(width: notchWidth > 0 ? wingWidth : nil, alignment: .trailing)
            Color.clear.frame(width: notchWidth)
            trailing
                .padding(.leading, notchWidth > 0 ? 14 : 0)
                .padding(.trailing, notchWidth > 0 ? 0 : 16)
                .frame(width: notchWidth > 0 ? wingWidth : nil, alignment: .leading)
        }
        .frame(height: height)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
                .fill(.black)
        )
        .scaleEffect(x: isShown ? 1 : 0.6, y: 1, anchor: .top)
        .opacity(isShown ? 1 : 0)
        .environment(\.colorScheme, .dark)
        .onAppear {
            // With Reduce Motion, appear in place instead of springing open.
            guard !reduceMotion else { isShown = true; return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { isShown = true }
        }
    }

    @ViewBuilder private var trailing: some View {
        if keys.isEmpty {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: isShown)
        } else {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { PaletteKeycap($0) }
            }
        }
    }
}

/// What a Shortcut Coach notch tip shows and says.
struct NotchCoachPresentation: Equatable {
    let action: String
    let application: String
    let keys: [String]
    let announcement: String

    init(event: CoachingEvent) {
        action = event.actionTitle
        application = event.applicationName
        keys = ShortcutKeycapPresentation(shortcut: event.shortcut).keys
        announcement = "\(event.actionTitle), \(event.applicationName), \(KeyboardShortcutRegistry.accessibilityCopy(for: event.shortcut))"
    }

    /// The icon of the running app the tip is about, matched by its display name.
    func applicationIcon(in running: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> NSImage? {
        running.first { $0.localizedName == application }?.icon
    }
}

private struct NotchCoachView: View {
    let presentation: NotchCoachPresentation
    let icon: NSImage?
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false
    @State private var glowAngle = 0.0
    @State private var poppedKeys = 0

    static let glow: [Color] = [.purple, .blue, .cyan, .pink, .purple]

    private var appAndAction: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "keyboard").font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(presentation.action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(presentation.application)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var keycaps: some View {
        HStack(spacing: 5) {
            ForEach(Array(presentation.keys.enumerated()), id: \.offset) { index, key in
                CoachKeycap(key: key)
                    .scaleEffect(index < poppedKeys ? 1 : 0.4)
                    .opacity(index < poppedKeys ? 1 : 0)
            }
        }
    }

    /// Each side of the notch is as wide as the wider of the two contents.
    private var wingWidth: CGFloat {
        func width(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
        }
        let leading = 24 + 10 + max(width(presentation.action, 13, .semibold), width(presentation.application, 11, .regular))
        // Each key renders max(size, label) wide plus 2 pt padding per side, 5 pt apart.
        let keys = presentation.keys.map { max(CoachKeycap.size, width($0, 13, .bold)) + 4 }.reduce(0, +)
            + CGFloat(max(presentation.keys.count - 1, 0)) * 5
        return max(leading, keys) + 6
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous)
        Group {
            if notchWidth > 0 {
                // Both rows sit beside the camera housing: the app and action on the left, the
                // keys on the right, each side equally wide so the notch stays centered.
                HStack(spacing: 0) {
                    appAndAction.frame(width: wingWidth, alignment: .leading)
                    Color.clear.frame(width: notchWidth)
                    keycaps.frame(width: wingWidth, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .frame(height: max(notchHeight, 34) + 10)
            } else {
                HStack(spacing: 24) {
                    appAndAction
                    Spacer(minLength: 0)
                    keycaps
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minWidth: 340)
            }
        }
        .background(shape.fill(.black))
        .overlay(
            shape.strokeBorder(
                AngularGradient(colors: Self.glow, center: .center, angle: .degrees(glowAngle)),
                lineWidth: 2
            )
            .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
        )
        .shadow(color: .purple.opacity(0.55), radius: 14, y: 4)
        .scaleEffect(x: isShown ? 1 : 0.5, y: isShown ? 1 : 0.2, anchor: .top)
        .opacity(isShown ? 1 : 0)
        .padding([.horizontal, .bottom], 24)
        .environment(\.colorScheme, .dark)
        .onAppear {
            // With Reduce Motion, appear in place with every key showing and a still glow.
            guard !reduceMotion else {
                isShown = true
                poppedKeys = presentation.keys.count
                return
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { isShown = true }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { glowAngle = 360 }
            for index in presentation.keys.indices {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + Double(index) * 0.12) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { poppedKeys = index + 1 }
                }
            }
        }
    }
}

/// A Shortcut Coach key: bright, bold, and edged with the tip's glow colors so the shortcut is the
/// first thing noticed.
private struct CoachKeycap: View {
    static let size: CGFloat = 26
    let key: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(key)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: Self.size, minHeight: Self.size)
            .padding(.horizontal, 2)
            .background(.white.opacity(0.14), in: shape)
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.5
            ))
            .shadow(color: .cyan.opacity(0.45), radius: 4)
    }
}
