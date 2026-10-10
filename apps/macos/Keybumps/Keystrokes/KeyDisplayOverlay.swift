import AppKit
import Observation
import SwiftUI

/// Draws the key display on screen: one overlay window on each display, covering it, so the keys
/// show on whichever display is being shared or recorded, and a click's ring shows on the display
/// it was on. The windows stay for as long as the display is held, even with nothing in them, and a
/// display that's still there keeps its window (and its window number) when displays change.
@MainActor
final class KeyDisplayOverlayController: KeyDisplayPresenting {
    var onWindowsChange: (() -> Void)?
    var windows: [NSWindow] { panels.map(\.window) }

    private let state = KeyDisplayOverlayState()
    private var panels: [(display: CGDirectDisplayID, geometry: KeyDisplayScreenGeometry, window: KeyDisplayOverlayWindow)] = []
    private var screenObserver: NSObjectProtocol?

    func show(_ content: KeyDisplayContent) {
        if panels.isEmpty {
            layOutWindows()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layOutWindows() }
            }
        }
        // With Reduce Motion, lines appear and go without fading.
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.2)
        withAnimation(animation) { state.content = content }
    }

    func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        state.content = nil
        guard !panels.isEmpty else { return }
        for panel in panels { close(panel.window) }
        panels = []
        onWindowsChange?()
    }

    /// One window per display: kept and moved for a display that's still there, made for a new one,
    /// and closed for one that's gone.
    private func layOutWindows() {
        var laidOut: [(display: CGDirectDisplayID, geometry: KeyDisplayScreenGeometry, window: KeyDisplayOverlayWindow)] = []
        var changed = false
        for screen in NSScreen.screens {
            guard let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let geometry = KeyDisplayScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame)
            if let existing = panels.first(where: { $0.display == display }) {
                if existing.geometry != geometry {
                    existing.window.setFrame(screen.frame, display: false)
                    existing.window.contentView = NSHostingView(rootView: KeyDisplayOverlayView(state: state, geometry: geometry))
                }
                laidOut.append((display, geometry, existing.window))
            } else {
                let window = KeyDisplayOverlayWindow(frame: screen.frame)
                window.contentView = NSHostingView(rootView: KeyDisplayOverlayView(state: state, geometry: geometry))
                window.orderFrontRegardless()
                laidOut.append((display, geometry, window))
                changed = true
            }
        }
        for panel in panels where !laidOut.contains(where: { $0.window === panel.window }) {
            close(panel.window)
            changed = true
        }
        panels = laidOut
        if changed { onWindowsChange?() }
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// A borderless, click-through panel covering one display: above everything, on every Space and
/// beside full-screen apps, and never key, main, or active. Adapted from Snapzy's
/// `KeystrokeOverlayWindow`. It ignores the mouse, so Shortcut Coach's click detection treats it as
/// Keybumps's click-through window and looks past it.
final class KeyDisplayOverlayWindow: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        identifier = NSUserInterfaceItemIdentifier("keyDisplay")
        // VoiceOver already speaks keys; the overlay only shows them.
        setAccessibilityElement(false)
        hideDuringUnitTests()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What every display's overlay draws.
@MainActor @Observable
final class KeyDisplayOverlayState {
    var content: KeyDisplayContent?
}

/// A display's frame and the part of it the menu bar and the Dock leave, in AppKit's screen
/// coordinates.
struct KeyDisplayScreenGeometry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect

    /// A screen point in the overlay's own coordinates, from its top left.
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    /// How far the visible frame is from each edge, so the keys sit above the Dock.
    var insets: EdgeInsets {
        EdgeInsets(
            top: frame.maxY - visibleFrame.maxY,
            leading: visibleFrame.minX - frame.minX,
            bottom: visibleFrame.minY - frame.minY,
            trailing: frame.maxX - visibleFrame.maxX
        )
    }
}

/// One display's overlay: the lines at the configured position, and rings where the pointer
/// clicked on this display.
struct KeyDisplayOverlayView: View {
    /// How far the keys sit from the visible frame's edges.
    static let margin: CGFloat = 32

    let state: KeyDisplayOverlayState
    let geometry: KeyDisplayScreenGeometry

    var body: some View {
        ZStack {
            Color.clear
            if let content = state.content {
                let metrics = KeystrokeMetrics(content.configuration.size)
                ForEach(content.clicks.filter { geometry.frame.contains($0.location) }) { click in
                    ClickRing(diameter: metrics.ring).position(geometry.local(click.location))
                }
                let insets = geometry.insets
                KeystrokeStack(content: content, metrics: metrics)
                    .padding(EdgeInsets(
                        top: insets.top + Self.margin,
                        leading: insets.leading + Self.margin,
                        bottom: insets.bottom + Self.margin,
                        trailing: insets.trailing + Self.margin
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: content.configuration.position.alignment)
            }
        }
        .frame(width: geometry.frame.width, height: geometry.frame.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension KeyDisplayConfiguration.Position {
    var alignment: Alignment {
        switch self {
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .bottomLeft: .leading
        case .bottomCenter: .center
        case .bottomRight: .trailing
        }
    }
}

/// The sizes of a line, for Small, Medium, or Large.
struct KeystrokeMetrics: Equatable {
    /// A keycap's height, and its narrowest width.
    let keycap: CGFloat
    let font: CGFloat
    let nameFont: CGFloat
    let bezelFont: CGFloat
    let ring: CGFloat

    init(_ size: KeyDisplayConfiguration.Size) {
        switch size {
        case .small: self.init(keycap: 36, font: 17, nameFont: 12, bezelFont: 20, ring: 28)
        case .medium: self.init(keycap: 48, font: 22, nameFont: 14, bezelFont: 28, ring: 36)
        case .large: self.init(keycap: 64, font: 30, nameFont: 17, bezelFont: 38, ring: 48)
        }
    }

    init(keycap: CGFloat, font: CGFloat, nameFont: CGFloat, bezelFont: CGFloat, ring: CGFloat) {
        self.keycap = keycap
        self.font = font
        self.nameFont = nameFont
        self.bezelFont = bezelFont
        self.ring = ring
    }

    /// The lines above the newest, which are smaller.
    var history: KeystrokeMetrics {
        KeystrokeMetrics(keycap: keycap * 0.75, font: font * 0.75, nameFont: nameFont * 0.85, bezelFont: bezelFont * 0.75, ring: ring)
    }

    /// `PaletteKeycap`'s corner: 5 points on a 22-point key.
    var cornerRadius: CGFloat { keycap * 0.23 }
    /// The darker lower edge that makes a keycap look pressed into the screen.
    var edge: CGFloat { max(2, (keycap * 0.08).rounded()) }
}

/// The lines on screen, the newest at the bottom and the last one or two above it, smaller and
/// fading (as on the Keys display canvas: full, 60%, then 35%).
struct KeystrokeStack: View {
    let content: KeyDisplayContent
    let metrics: KeystrokeMetrics

    static func opacity(age: Int) -> Double {
        [1, 0.6, 0.35][min(age, 2)]
    }

    var body: some View {
        let entries = content.entries
        VStack(alignment: content.configuration.position.horizontalAlignment, spacing: metrics.keycap * 0.25) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let age = entries.count - 1 - index
                KeystrokeLine(entry: entry, style: content.configuration.style, metrics: age == 0 ? metrics : metrics.history)
                    .opacity(Self.opacity(age: age))
                    .transition(.opacity)
            }
        }
    }
}

/// One line: keycaps with the action's name under them, or KeyCastr's bezel with the name after.
struct KeystrokeLine: View {
    /// The name's pill: the canvas's lavender.
    static let nameFill = Color(red: 0.667, green: 0.612, blue: 1)

    let entry: KeystrokeTimeline.Entry
    let style: KeyDisplayConfiguration.Style
    let metrics: KeystrokeMetrics

    var body: some View {
        switch style {
        case .keycaps: keycaps
        case .bezel: bezel
        }
    }

    private var keycaps: some View {
        VStack(spacing: metrics.keycap * 0.2) {
            HStack(spacing: metrics.keycap * 0.16) {
                ForEach(Array(entry.keycaps.enumerated()), id: \.offset) { KeystrokeKeycap(label: $0.element, metrics: metrics) }
                if entry.count > 1 {
                    Text("×\(entry.count)")
                        .font(.system(size: metrics.nameFont, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, metrics.nameFont * 0.6)
                        .padding(.vertical, metrics.nameFont * 0.25)
                        .background(.black.opacity(0.75), in: Capsule())
                }
            }
            if let name = entry.name {
                Text(name)
                    .font(.system(size: metrics.nameFont, weight: .semibold))
                    .foregroundStyle(KeystrokeKeycap.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, metrics.nameFont)
                    .padding(.vertical, metrics.nameFont * 0.4)
                    .background(Self.nameFill, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
        }
    }

    /// From KeyCastr's `KCDefaultVisualizer`: white text on 80% black, in a rounded bezel.
    private var bezel: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.bezelFont * 0.4) {
            Text(entry.text)
                .font(.system(size: metrics.bezelFont, weight: .semibold))
                .tracking(2)
            if entry.count > 1 {
                Text("×\(entry.count)").font(.system(size: metrics.bezelFont * 0.6, weight: .semibold)).opacity(0.7)
            }
            if let name = entry.name {
                Text(name).font(.system(size: metrics.bezelFont * 0.55, weight: .medium)).opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, metrics.bezelFont * 0.7)
        .padding(.vertical, metrics.bezelFont * 0.3)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: metrics.bezelFont * 0.5, style: .continuous))
    }
}

/// One key in the Keycaps style. It keeps `PaletteKeycap`'s shape (a continuous rounded square, at
/// least as wide as it's tall) and its labels (`KeyboardShortcutRegistry`'s symbols), larger and
/// solid so it reads over any screen: a light face over a darker lower edge, as on the canvas.
struct KeystrokeKeycap: View {
    static let face = Color(red: 0.98, green: 0.969, blue: 0.941)
    static let border = Color(red: 0.847, green: 0.82, blue: 0.765)
    static let lowerEdge = Color(red: 0.788, green: 0.761, blue: 0.702)
    static let ink = Color(red: 0.106, green: 0.106, blue: 0.11)

    let label: String
    let metrics: KeystrokeMetrics

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        Text(label)
            .font(.system(size: metrics.font, weight: .semibold))
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, metrics.keycap * 0.25)
            .frame(minWidth: metrics.keycap, minHeight: metrics.keycap - metrics.edge)
            .background(Self.face, in: shape)
            .padding(.bottom, metrics.edge)
            .background(Self.lowerEdge, in: shape)
            .overlay(shape.strokeBorder(Self.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: metrics.keycap * 0.2, y: metrics.keycap * 0.08)
    }
}

/// A ring where the pointer clicked, growing and fading for `KeystrokeTimeline.clickDuration`.
/// ClickLight's pulse is the model; no code is copied from it.
struct ClickRing: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDone = false

    var body: some View {
        Circle()
            .strokeBorder(KeystrokeLine.nameFill, lineWidth: 3)
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.35), radius: 3)
            .scaleEffect(isDone || reduceMotion ? 1 : 0.45)
            .opacity(isDone ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: KeystrokeTimeline.clickDuration)) { isDone = true }
            }
    }
}
