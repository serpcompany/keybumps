import AppKit
import Observation
import SwiftUI

/// Draws the key display on screen: an overlay window covering each screen that has something to
/// show (`KeyDisplayContent.displaysNeedingWindows`), put up when there is and taken down once it
/// has faded, or, while a holder keeps them up, one on each of its screens for the whole hold. A
/// screen that stays connected keeps its window, and its window number, when screens change. It
/// watches for screen changes only between the first `show` and `hide`.
@MainActor
final class KeyDisplayOverlayController: KeyDisplayPresenting {
    /// How long lines take to fade, before an unneeded window is taken down.
    static let fadeDuration: TimeInterval = 0.2

    var onWindowsChange: (() -> Void)?
    var windows: [NSWindow] { onScreen.compactMap { panels[$0]?.window } }

    private let state = KeyDisplayOverlayState()
    private let screens: () -> [KeyDisplayScreen]
    private let scheduler: any TimerScheduling
    private let notificationCenter: NotificationCenter
    private let reduceMotion: () -> Bool
    /// A window for each screen that has needed one, kept until the screen goes or `hide`.
    private var panels: [CGDirectDisplayID: (screen: KeyDisplayScreen, window: KeyDisplayOverlayWindow)] = [:]
    /// The screens whose windows are on screen, in screen order.
    private var onScreen: [CGDirectDisplayID] = []
    private var screenObserver: NSObjectProtocol?
    private var pendingTakeDown: (any TimerScheduledAction)?

    init(
        screens: (() -> [KeyDisplayScreen])? = nil,
        scheduler: (any TimerScheduling)? = nil,
        notificationCenter: NotificationCenter = .default,
        reduceMotion: (() -> Bool)? = nil
    ) {
        self.screens = screens ?? { KeyDisplayScreen.current() }
        self.scheduler = scheduler ?? MonotonicTickScheduler()
        self.notificationCenter = notificationCenter
        self.reduceMotion = reduceMotion ?? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    /// Whether it's watching for screen changes: between the first `show` and `hide`.
    var isWatchingScreens: Bool { screenObserver != nil }

    func show(_ content: KeyDisplayContent, animated: Bool) {
        if screenObserver == nil {
            screenObserver = notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensDidChange() }
            }
        }
        let animates = animated && !reduceMotion()
        if animates {
            withAnimation(.easeOut(duration: Self.fadeDuration)) { state.content = content }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.content = content }
        }
        arrange(animated: animates)
        if !animates {
            // Draw the change now, not at the next display cycle.
            for window in windows {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
    }

    func hide() {
        if let screenObserver { notificationCenter.removeObserver(screenObserver) }
        screenObserver = nil
        pendingTakeDown?.cancel()
        pendingTakeDown = nil
        state.content = nil
        let hadWindows = !onScreen.isEmpty
        for panel in panels.values { close(panel.window) }
        panels = [:]
        onScreen = []
        if hadWindows { onWindowsChange?() }
    }

    /// Screens came, went, or changed: windows follow, while the display shows.
    func screensDidChange() {
        guard state.content != nil else { return }
        arrange(animated: false)
    }

    /// Puts up a window on each screen that needs one, and takes the rest down: after the fade, or
    /// at once.
    private func arrange(animated: Bool) {
        guard let content = state.content else { return }
        let before = windows.map(ObjectIdentifier.init)
        let screens = screens()
        for display in Array(panels.keys) where !screens.contains(where: { $0.display == display }) {
            if let window = panels[display]?.window { close(window) }
            panels[display] = nil
        }
        let needed = content.displaysNeedingWindows(on: screens)
        var shown: [CGDirectDisplayID] = []
        for screen in screens {
            let isUp = onScreen.contains(screen.display)
            guard needed.contains(screen.display) || (isUp && animated) else {
                if isUp, let window = panels[screen.display]?.window { window.orderOut(nil) }
                continue
            }
            let window = panel(for: screen)
            if !isUp { window.orderFrontRegardless() }
            shown.append(screen.display)
        }
        onScreen = shown
        pendingTakeDown?.cancel()
        pendingTakeDown = nil
        if onScreen.contains(where: { !needed.contains($0) }) {
            pendingTakeDown = scheduler.schedule(at: Date().addingTimeInterval(Self.fadeDuration)) { [weak self] in
                self?.pendingTakeDown = nil
                self?.arrange(animated: false)
            }
        }
        if windows.map(ObjectIdentifier.init) != before { onWindowsChange?() }
    }

    /// The window for `screen`, made if there's none, and moved if the screen changed.
    private func panel(for screen: KeyDisplayScreen) -> KeyDisplayOverlayWindow {
        if let existing = panels[screen.display] {
            if existing.screen != screen {
                existing.window.setFrame(screen.frame, display: false)
                existing.window.contentView = NSHostingView(rootView: KeyDisplayOverlayView(state: state, screen: screen))
                panels[screen.display] = (screen, existing.window)
            }
            return existing.window
        }
        let window = KeyDisplayOverlayWindow(frame: screen.frame)
        window.contentView = NSHostingView(rootView: KeyDisplayOverlayView(state: state, screen: screen))
        panels[screen.display] = (screen, window)
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// A borderless, click-through panel covering one screen: above full-screen apps, the menu bar, and
/// the Dock, on every Space, and never key, main, or active. Adapted from Snapzy's
/// `KeystrokeOverlayWindow`. Its level is `.statusBar`, the lowest standard level above the menu
/// bar (`.mainMenu`) and the Dock; full-screen apps' windows are at the normal level in their own
/// Space, which `.fullScreenAuxiliary` lets it join. It ignores the mouse, so Shortcut Coach's click
/// detection treats it as Keybumps's click-through window and looks past it.
final class KeyDisplayOverlayWindow: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
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

/// What every screen's overlay draws.
@MainActor @Observable
final class KeyDisplayOverlayState {
    var content: KeyDisplayContent?
}

extension KeyDisplayScreen {
    /// How far the visible frame is from each edge, so the keys sit above the Dock.
    var insets: EdgeInsets { insets(to: visibleFrame) }

    /// Where the keys go on this screen, in AppKit's global space: inside the visible frame by
    /// `KeyDisplayOverlayView.margin`, or, for an `anchor` on this screen, inside it, so they're in
    /// what a recording records:
    /// - inside its part clear of the menu bar and the Dock, by `KeyDisplayOverlayView.anchorMargin`;
    /// - when that part is too small (a thin strip, or an area mostly over the Dock or the menu
    ///   bar), inside its part on the screen at all, by a margin it has room for: the overlay is
    ///   above the menu bar and the Dock.
    /// Only an anchor that isn't on this screen leaves them where they'd be without one.
    func keyArea(anchor: CGRect?) -> CGRect {
        let plain = visibleFrame.insetBy(dx: KeyDisplayOverlayView.margin, dy: KeyDisplayOverlayView.margin)
        guard let anchor = anchor?.standardized else { return plain }
        let margin = KeyDisplayOverlayView.anchorMargin
        let clear = anchor.intersection(visibleFrame)
        if !clear.isNull, clear.width > margin * 4, clear.height > margin * 4 {
            return clear.insetBy(dx: margin, dy: margin)
        }
        let onScreen = anchor.intersection(frame)
        guard !onScreen.isNull, onScreen.width > 0, onScreen.height > 0 else { return plain }
        return onScreen.insetBy(dx: min(margin, onScreen.width / 4), dy: min(margin, onScreen.height / 4))
    }

    /// How far `rect` is from each edge of the screen.
    func insets(to rect: CGRect) -> EdgeInsets {
        EdgeInsets(
            top: frame.maxY - rect.maxY,
            leading: rect.minX - frame.minX,
            bottom: rect.minY - frame.minY,
            trailing: frame.maxX - rect.maxX
        )
    }
}

/// One screen's overlay: the lines at the configured position, if they show on this screen, and
/// rings where the pointer clicked on it, if rings may show here.
struct KeyDisplayOverlayView: View {
    /// How far the keys sit from the visible frame's edges.
    static let margin: CGFloat = 32
    /// How far they sit from an anchor's edges, such as a recorded window's.
    static let anchorMargin: CGFloat = 16

    let state: KeyDisplayOverlayState
    let screen: KeyDisplayScreen

    var body: some View {
        ZStack {
            Color.clear
            if let content = state.content {
                let metrics = KeystrokeMetrics(content.configuration.size)
                if content.showsClicks(on: screen.display) {
                    ForEach(content.clicks.filter { screen.frame.contains($0.location) }) { click in
                        ClickRing(diameter: metrics.ring).position(screen.local(click.location))
                    }
                }
                if content.lineDisplays.contains(screen.display) {
                    KeystrokeStack(content: content, metrics: metrics)
                        .padding(screen.insets(to: screen.keyArea(anchor: content.configuration.anchor)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: content.configuration.position.alignment)
                }
            }
        }
        .frame(width: screen.frame.width, height: screen.frame.height)
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
