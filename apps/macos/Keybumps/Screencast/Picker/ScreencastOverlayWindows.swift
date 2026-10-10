import AppKit
import SwiftUI

/// Screencast's windows around a capture: the picker over every screen, the countdown, and the
/// area highlight while an area records. All borderless, non-activating panels of Keybumps's own,
/// so a recording leaves them out (only windows registered with `includeOverlayWindow` show, and
/// these never are) and a screenshot's filter leaves out all of Keybumps.
///
/// Adapted from Screendrop's `RecordingAreaSelectionPresenter`, `RecordingAreaHighlightPresenter`,
/// and `CaptureCountdownPresenter` (CC0-1.0, see LICENSE.screendrop) and BetterCapture's
/// `AreaSelectionOverlay` (MIT, see LICENSE.bettercapture): one panel per screen at the screen
/// saver level that can take the keys, dimmed outside the area, with its size in pixels; a
/// click-through highlight; and a countdown that Escape, here or in any app, cancels.
@available(macOS 15, *)
@MainActor
final class ScreencastOverlayWindows: ScreencastOverlayPresenting {
    private var pickerPanels: [ScreencastKeyPanel] = []
    private weak var pickerModel: ScreencastPickerModel?
    private var returnMonitor: Any?
    private var countdownPanels: [ScreencastKeyPanel] = []
    private let countdown = ScreencastCountdownState()
    private var highlightPanel: NSPanel?
    private var escapeMonitors: [Any] = []
    private var escapeHandler: (() -> Void)?

    // MARK: The picker

    func showPicker(_ model: ScreencastPickerModel, confirm: @escaping () -> Void, cancel: @escaping () -> Void) {
        closePicker()
        let layout = model.layout
        let barScreen = layout.screen(containing: NSEvent.mouseLocation) ?? layout.screens.first
        var keyPanel: ScreencastKeyPanel?
        for screen in layout.screens {
            let panel = ScreencastKeyPanel(frame: screen.frame, level: .screenSaver, identifier: "screencastPicker")
            panel.acceptsMouseMovedEvents = true
            let view = ScreencastPickerView(model: model, screen: screen, confirm: confirm)
            panel.contentView = view
            if screen.id == barScreen?.id {
                view.showBar(ScreencastPickerBar(model: model, confirm: confirm, cancel: cancel), bottomInset: Self.dockInset(of: screen))
                keyPanel = panel
            }
            panel.hideDuringUnitTests()
            panel.orderFrontRegardless()
            pickerPanels.append(panel)
        }
        pickerModel = model
        model.onChange = { [weak self] in
            self?.pickerPanels.forEach { $0.contentView?.needsDisplay = true }
        }
        keyPanel?.makeKey()
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard event.keyCode == 36 || event.keyCode == 76 else { return event }
            if model?.canConfirm == true { confirm() }
            return nil
        }
    }

    func closePicker() {
        if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
        returnMonitor = nil
        pickerModel?.onChange = nil
        pickerModel = nil
        for panel in pickerPanels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        pickerPanels = []
        NSCursor.arrow.set()
    }

    /// How far above the screen's bottom the bar sits: clear of the Dock.
    private static func dockInset(of screen: ScreencastScreen) -> CGFloat {
        let visible = NSScreen.screens.first { $0.frame == screen.frame }?.visibleFrame ?? screen.frame
        return visible.minY - screen.frame.minY + 28
    }

    // MARK: The countdown

    func showCountdown(_ remaining: Int, in frames: [CGRect], cancel: @escaping () -> Void) {
        countdown.remaining = remaining
        guard countdownPanels.isEmpty else { return }
        let layout = ScreencastScreenLayout.current()
        let size = ScreencastCountdownView.size
        for frame in frames {
            var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
            if let screen = layout.screen(mostOverlapping: frame)?.frame {
                origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
                origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))
            }
            let panel = ScreencastKeyPanel(frame: CGRect(origin: origin, size: size), level: .statusBar, identifier: "screencastCountdown")
            panel.collectionBehavior.formUnion([.stationary, .ignoresCycle])
            panel.contentView = ScreencastFirstClickHostingView(rootView: ScreencastCountdownView(state: countdown, cancel: cancel))
            panel.hideDuringUnitTests()
            panel.orderFrontRegardless()
            countdownPanels.append(panel)
        }
        // So Escape reaches Keybumps even without the global monitor.
        countdownPanels.first?.makeKey()
    }

    func closeCountdown() {
        for panel in countdownPanels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        countdownPanels = []
    }

    // MARK: The area highlight

    func showAreaHighlight(_ area: ScreencastPickedArea) {
        closeAreaHighlight()
        guard let screen = ScreencastScreenLayout.current().screen(area.display) else { return }
        // Below `.floating`, so the control bar and the overlays stay above its dimming.
        let panel = ScreencastKeyPanel(
            frame: screen.frame,
            level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1),
            identifier: "screencastAreaHighlight",
            takesKeys: false
        )
        panel.ignoresMouseEvents = true
        panel.collectionBehavior.formUnion([.stationary, .ignoresCycle])
        panel.contentView = ScreencastAreaHighlightView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            area: area.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        )
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
        highlightPanel = panel
    }

    func closeAreaHighlight() {
        highlightPanel?.orderOut(nil)
        highlightPanel = nil
    }

    // MARK: Escape and messages

    func watchEscape(_ handler: @escaping () -> Void) {
        stopWatchingEscape()
        escapeHandler = handler
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, let handler = self?.escapeHandler else { return event }
            handler()
            return nil
        }) {
            escapeMonitors.append(local)
        }
        // Another app has the keys during the countdown and while recording starts. This hears
        // Escape there while Keybumps has Accessibility; the countdown's Cancel works either way.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.escapeHandler?() }
        }) {
            escapeMonitors.append(global)
        }
    }

    func stopWatchingEscape() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors = []
        escapeHandler = nil
    }

    func showMessage(_ message: String) {
        PaletteHUD.shared.show(message, systemImage: "exclamationmark.triangle.fill", tint: .orange, duration: 4)
    }

    func showGettingReady() {
        PaletteHUD.shared.show("Getting ready…", systemImage: "record.circle", tint: .secondary, duration: 10)
    }

    func hideGettingReady() {
        PaletteHUD.shared.dismiss()
    }
}

/// A borderless, non-activating panel over other apps, on every Space and over full-screen apps,
/// that takes the keys without activating Keybumps, as the Command Palette does; never in the
/// unit-test host.
final class ScreencastKeyPanel: NSPanel {
    private let takesKeys: Bool

    init(frame: CGRect, level: NSWindow.Level, identifier: String, takesKeys: Bool = true) {
        self.takesKeys = takesKeys
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // ⌘H hides Keybumps's windows; a capture's stay.
        canHide = false
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { takesKeys && !UnitTestHost.isActive }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that takes the first click even when its panel isn't key, so the bar's buttons
/// work after a click on another screen's picker.
final class ScreencastFirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One screen's part of the picker: dimmed, with the area being drawn, the window under the
/// pointer, or the screen marked when it's chosen, and the bar on the screen the pointer was on.
@available(macOS 15, *)
@MainActor
final class ScreencastPickerView: NSView {
    private static let dimming = NSColor.black.withAlphaComponent(0.32)

    private let model: ScreencastPickerModel
    private let screen: ScreencastScreen
    private let confirm: () -> Void
    private var bar: NSView?

    init(model: ScreencastPickerModel, screen: ScreencastScreen, confirm: @escaping () -> Void) {
        self.model = model
        self.screen = screen
        self.confirm = confirm
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func showBar(_ content: ScreencastPickerBar, bottomInset: CGFloat) {
        let host = ScreencastFirstClickHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            // Kept inside a narrow screen, where the bar's options drop their titles to fit.
            host.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            host.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        bar = host
    }

    // MARK: Mouse, in AppKit's global space

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = globalPoint(event)
        switch model.target {
        case .area:
            if event.clickCount == 2, let area = model.area, area.rect.contains(point) {
                confirm()
                return
            }
            model.pressArea(at: point, on: screen)
        case .window:
            model.clickWindow(at: point)
            if event.clickCount == 2, model.canConfirm { confirm() }
        case .screen:
            model.clickScreen(screen)
            if event.clickCount == 2 { confirm() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        model.dragArea(to: globalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        model.releaseArea()
        updateCursor(at: globalPoint(event))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = globalPoint(event)
        model.hoverWindow(at: point)
        updateCursor(at: point)
    }

    private func updateCursor(at point: CGPoint) {
        if let bar, bar.frame.contains(CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)) {
            NSCursor.arrow.set()
            return
        }
        switch model.target {
        case .area:
            if let editor = model.areaEditor, editor.bounds == screen.frame, editor.gesture == nil, let rect = editor.rect {
                if let handle = editor.handle(at: point) {
                    Self.cursor(for: handle).set()
                    return
                }
                if rect.contains(point) {
                    NSCursor.openHand.set()
                    return
                }
            }
            NSCursor.crosshair.set()
        case .window:
            NSCursor.pointingHand.set()
        case .screen:
            NSCursor.pointingHand.set()
        }
    }

    private static func cursor(for handle: ScreencastAreaEditor.Handle) -> NSCursor {
        let position: NSCursor.FrameResizePosition = switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .left: .left
        case .right: .right
        case .bottomLeft: .bottomLeft
        case .bottom: .bottom
        case .bottomRight: .bottomRight
        }
        return .frameResize(position: position, directions: [.inward, .outward])
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch model.target {
        case .area:
            context.setFillColor(Self.dimming.cgColor)
            context.fill(bounds)
            if let editor = model.areaEditor, editor.bounds == screen.frame, let rect = editor.rect {
                drawArea(local(rect), editor: editor, in: context)
            }
        case .window:
            context.setFillColor(Self.dimming.cgColor)
            context.fill(bounds)
            let shown = [model.selectedWindow, model.hoveredWindow].compactMap { $0 }
            for id in Set(shown) {
                guard let frame = model.appKitFrame(of: id) else { continue }
                let rect = local(frame).intersection(bounds)
                guard !rect.isNull, !rect.isEmpty else { continue }
                clear(rect, in: context)
                let isSelected = id == model.selectedWindow
                context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(isSelected ? 1 : 0.6).cgColor)
                context.setLineWidth(isSelected ? 4 : 2)
                context.stroke(rect.insetBy(dx: 2, dy: 2))
            }
        case .screen:
            guard model.isChosen(screen) else {
                context.setFillColor(Self.dimming.cgColor)
                context.fill(bounds)
                return
            }
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            context.fill(bounds)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(6)
            context.stroke(bounds.insetBy(dx: 3, dy: 3))
        }
    }

    private func clear(_ rect: CGRect, in context: CGContext) {
        context.setBlendMode(.clear)
        context.fill(rect)
        context.setBlendMode(.normal)
    }

    private func drawArea(_ rect: CGRect, editor: ScreencastAreaEditor, in context: CGContext) {
        clear(rect, in: context)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        if editor.isDrawing { context.setLineDash(phase: 0, lengths: [6, 4]) }
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
        if !editor.isDrawing {
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(0.5)
            for handle in editor.handleRects().values {
                context.addEllipse(in: local(handle))
                context.drawPath(using: .fillStroke)
            }
        }
        drawSize(of: rect)
    }

    /// The area's size in the pixels the recording will have, under it (or over it, at the
    /// screen's bottom).
    private func drawSize(of rect: CGRect) {
        let displayRect = ScreencastTarget.displayLocalRect(fromAppKit: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screenFrame: screen.frame)
        let geometry = ScreencastCaptureGeometry.area(displayRect, displaySize: screen.frame.size, scale: screen.scale)
        let label = NSAttributedString(string: "\(geometry.pixelWidth) × \(geometry.pixelHeight)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let padding = CGSize(width: 8, height: 4)
        let size = CGSize(width: label.size().width + padding.width * 2, height: label.size().height + padding.height * 2)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < bounds.minY + 4 { origin.y = min(rect.maxY + 8, bounds.maxY - size.height - 4) }
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - size.width - 4))
        let badge = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        label.draw(at: CGPoint(x: badge.minX + padding.width, y: badge.minY + padding.height))
    }
}

/// Dims a screen outside the area being recorded. Purely drawn: its panel ignores the mouse.
@MainActor
final class ScreencastAreaHighlightView: NSView {
    private let area: CGRect

    init(frame: CGRect, area: CGRect) {
        self.area = area
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        context.setFillColor((isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.28)).cgColor)
        context.fill(bounds)
        context.setBlendMode(.clear)
        context.fill(area)
        context.setBlendMode(.normal)
        // Just outside the area, so it frames what's recorded without covering it.
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.stroke(area.insetBy(dx: -1.5, dy: -1.5))
    }
}
