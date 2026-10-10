import AppKit
import SwiftUI

/// The drawing tools' accessibility identifiers, which the UI tests drive.
enum ScreencastDrawingToolbarID {
    static func tool(_ tool: ScreencastDrawingTool) -> String { "screencast.draw.tool.\(tool.rawValue)" }
    static func color(_ color: ScreencastDrawingColor) -> String { "screencast.draw.color.\(color.rawValue)" }
    static func lifetime(_ lifetime: ScreencastMarkLifetime) -> String { "screencast.draw.\(lifetime.rawValue)" }
    static let undo = "screencast.draw.undo"
    static let clear = "screencast.draw.clear"
    /// The value of the chosen tool, color, and Fade or Stay, besides their selected trait.
    static let selected = "Selected"
}

/// The drawing tools while drawing: the tool, the color, whether marks fade or stay, Undo, and
/// Clear, just above the control bar. Like the bar, it's never in the video and never takes the
/// keyboard.
///
/// Its panel is on screen from `show` to `hide`, empty and letting clicks through except while
/// drawing, so no new window of Keybumps's appears in a window recording mid-recording.
@MainActor
final class ScreencastDrawingToolbar {
    /// The room between the tools and the control bar.
    static let gap: CGFloat = 8
    /// With no control bar to sit above, how far above the bottom of the display the tools sit:
    /// where they'd be above a bar in its default spot.
    static let bottomInset: CGFloat = 80

    let panel = ScreencastDrawingToolbarPanel()
    /// Whose tools these are. Weak, since the overlays own the toolbar.
    weak var overlays: ScreencastOverlays?

    private let ordersPanelIn: Bool
    private var hostingView: ScreencastDrawingToolbarHostingView?
    /// Between `show` and `hide`.
    private(set) var isOnScreen = false
    /// Whether the tools show and take clicks: only while drawing.
    private(set) var isShowing = false

    /// - Parameter ordersPanelIn: False keeps the panel off screen, as under the unit-test host.
    init(ordersPanelIn: Bool = !UnitTestHost.isActive) {
        self.ordersPanelIn = ordersPanelIn
        panel.ignoresMouseEvents = true
    }

    /// Puts the empty panel on screen for the recording.
    func show() {
        isOnScreen = true
        setShowing(false)
        guard ordersPanelIn else { return }
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
    }

    func hide() {
        isOnScreen = false
        setShowing(false)
        panel.orderOut(nil)
    }

    /// Shows the tools and takes clicks, or empties the panel and lets clicks through.
    func setShowing(_ showing: Bool) {
        isShowing = showing
        if showing { _ = contentSize() }
        hostingView?.isHidden = !showing
        panel.ignoresMouseEvents = !showing
    }

    /// Moves the tools above `anchor` (the control bar's frame), or near the bottom of
    /// `visibleFrame` with none.
    func place(above anchor: CGRect?, within visibleFrame: CGRect) {
        let size = contentSize()
        let origin = Self.origin(for: size, above: anchor, within: visibleFrame)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        panel.invalidateShadow()
    }

    /// Centered just above `anchor`, or just below it when there's no room above, kept inside
    /// `visibleFrame`; with no anchor, centered near its bottom.
    static func origin(for size: CGSize, above anchor: CGRect?, within visibleFrame: CGRect) -> CGPoint {
        guard let anchor else {
            let origin = CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + bottomInset)
            return ScreencastControlBarPlacement.clamped(origin, size: size, within: visibleFrame)
        }
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        if origin.y + size.height > visibleFrame.maxY {
            origin.y = anchor.minY - gap - size.height
        }
        return ScreencastControlBarPlacement.clamped(origin, size: size, within: visibleFrame)
    }

    /// The tools' size, once their view is in the panel.
    private func contentSize() -> CGSize {
        if let hostingView {
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.fittingSize
        }
        let host = ScreencastDrawingToolbarHostingView(rootView: ScreencastDrawingToolbarView(overlays: overlays))
        host.isHidden = !isShowing
        panel.contentView = host
        hostingView = host
        return host.fittingSize
    }
}

/// The drawing tools' window: borderless and non-activating at the control bar's level, above the
/// drawing layer, so it takes clicks while drawing without becoming key. Left out of the video by
/// the recorder's filter, as the bar is.
final class ScreencastDrawingToolbarPanel: NSPanel {
    static let identifier = NSUserInterfaceItemIdentifier("screencastDrawingTools")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        canHide = false
        allowsToolTipsWhenApplicationIsInactive = true
        animationBehavior = .none
        identifier = Self.identifier
        setAccessibilityLabel("Drawing tools")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, so a tool works while another app is active.
final class ScreencastDrawingToolbarHostingView: NSHostingView<ScreencastDrawingToolbarView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The tools, styled like the control bar: the four tools, the colors, Fade or Stay, then Undo and
/// Clear, which work only while there's a mark.
struct ScreencastDrawingToolbarView: View {
    /// Weak: the overlays own the panel this view is in.
    weak var overlays: ScreencastOverlays?

    var body: some View {
        if let overlays {
            ScreencastDrawingTools(overlays: overlays)
        }
    }
}

private struct ScreencastDrawingTools: View {
    let overlays: ScreencastOverlays

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ScreencastControlBarView.cornerRadius, style: .continuous)
        HStack(spacing: 2) {
            ForEach(ScreencastDrawingTool.allCases) { tool in
                Button {
                    overlays.style.tool = tool
                } label: {
                    Image(systemName: tool.systemImage)
                }
                .buttonStyle(ScreencastDrawingIconButtonStyle(isOn: overlays.style.tool == tool))
                .help(tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(overlays.style.tool == tool ? .isSelected : [])
                .accessibilityValue(overlays.style.tool == tool ? ScreencastDrawingToolbarID.selected : "")
                .accessibilityIdentifier(ScreencastDrawingToolbarID.tool(tool))
            }

            ScreencastDrawingDivider()

            ForEach(ScreencastDrawingColor.allCases) { color in
                Button {
                    overlays.style.color = color
                } label: {
                    ScreencastDrawingSwatch(color: color, isSelected: overlays.style.color == color)
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(overlays.style.color == color ? .isSelected : [])
                .accessibilityValue(overlays.style.color == color ? ScreencastDrawingToolbarID.selected : "")
                .accessibilityIdentifier(ScreencastDrawingToolbarID.color(color))
            }

            ScreencastDrawingDivider()

            ForEach(ScreencastMarkLifetime.allCases) { lifetime in
                Button(lifetime.title) {
                    overlays.style.lifetime = lifetime
                }
                .buttonStyle(ScreencastDrawingTextButtonStyle(isOn: overlays.style.lifetime == lifetime))
                .help(lifetime == .fades ? "New marks fade a few seconds after you draw them" : "New marks stay until you clear them")
                .accessibilityAddTraits(overlays.style.lifetime == lifetime ? .isSelected : [])
                .accessibilityValue(overlays.style.lifetime == lifetime ? ScreencastDrawingToolbarID.selected : "")
                .accessibilityIdentifier(ScreencastDrawingToolbarID.lifetime(lifetime))
            }

            ScreencastDrawingDivider()

            Button(action: overlays.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(ScreencastDrawingIconButtonStyle())
            .disabled(!overlays.hasMarks)
            .help("Undo the last mark (⌘Z)")
            .accessibilityLabel("Undo")
            .accessibilityIdentifier(ScreencastDrawingToolbarID.undo)

            Button(action: overlays.clear) {
                Image(systemName: "eraser")
            }
            .buttonStyle(ScreencastDrawingIconButtonStyle())
            .disabled(!overlays.hasMarks)
            .help("Clear the drawing (⌫). Escape stops drawing.")
            .accessibilityLabel("Clear")
            .accessibilityIdentifier(ScreencastDrawingToolbarID.clear)
        }
        .padding(6)
        .fixedSize()
        .background(shape.fill(PaletteTheme.background))
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .uiTestAnimationsDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawing tools")
    }
}

/// A color to draw in, ringed while it's the one chosen.
private struct ScreencastDrawingSwatch: View {
    let color: ScreencastDrawingColor
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(nsColor: color.nsColor))
            .frame(width: 14, height: 14)
            .padding(3)
            .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5))
            .frame(width: 26, height: 30)
            .contentShape(Rectangle())
    }
}

private struct ScreencastDrawingDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

/// The control bar's square icon button: a soft fill on hover or press, and while it's chosen.
private struct ScreencastDrawingIconButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        ScreencastDrawingButton(configuration: configuration, isOn: isOn) { label in
            label
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
    }
}

/// Fade and Stay: a short word with the same fills.
private struct ScreencastDrawingTextButtonStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        ScreencastDrawingButton(configuration: configuration, isOn: isOn) { label in
            label
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 30)
        }
    }
}

private struct ScreencastDrawingButton<Label: View>: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @ViewBuilder let layout: (ButtonStyleConfiguration.Label) -> Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        layout(configuration.label)
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.9 : 0.3))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(fillOpacity))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }

    private var fillOpacity: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.22 }
        if isOn { return 0.16 }
        return isHovering ? 0.1 : 0
    }
}
