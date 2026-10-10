import AppKit
import SwiftUI

/// The floating control bar while recording (#448). `ScreencastRecordingControls` makes one for the
/// capture flow, shows it on the recorded screen when recording starts, and hides it when the
/// recording ends. The bar acts through the flow (`ScreencastBarRecording`), and the menu bar's
/// Pause and Stop and the recording shortcuts act through `model`, so the bar always shows where
/// the recording is.
///
/// It remembers where it was left on each display (`ScreencastControlBarPlacement`), never takes
/// the keyboard from the app being recorded, and is never in the video: the recorder leaves out
/// every Keybumps window except the overlays passed to `includeOverlayWindow`, and this one never is.
@MainActor
final class ScreencastControlBar {
    let model: ScreencastControlBarModel
    let panel = ScreencastControlBarPanel()

    private let placement: ScreencastControlBarPlacement
    private let displays: @MainActor () -> [ScreencastBarDisplay]
    private let ordersPanelIn: Bool
    private var hostingView: NSHostingView<ScreencastControlBarView>?
    private var moveObserver: NSObjectProtocol?
    /// Where the bar last put itself, so that move isn't remembered as the person's.
    private var placedOrigin: CGPoint?
    /// Between `show` and `hide`.
    private(set) var isShown = false

    /// - Parameters:
    ///   - placement: Where the bar's positions are kept (`AppPreferences.screencastBarPlacement`);
    ///     tests pass one on `InMemoryDefaults`.
    ///   - displays: The connected displays, which a moved bar is matched to.
    ///   - ordersPanelIn: False keeps the panel off screen, as under the unit-test host.
    init(
        recording: any ScreencastBarRecording,
        placement: ScreencastControlBarPlacement,
        displays: @escaping @MainActor () -> [ScreencastBarDisplay] = { ScreencastBarDisplay.connected },
        ordersPanelIn: Bool = !UnitTestHost.isActive,
        confirmationTimeout: Duration = ScreencastControlBarModel.confirmationTimeout
    ) {
        model = ScreencastControlBarModel(recording: recording, confirmationTimeout: confirmationTimeout)
        self.placement = placement
        self.displays = displays
        self.ordersPanelIn = ordersPanelIn
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// Drawing's switch (#449). The Draw button shows only while it's set, and the bar resizes.
    var onToggleDrawing: (() -> Void)? {
        get { model.onToggleDrawing }
        set {
            model.onToggleDrawing = newValue
            if isShown { fitToContent() }
        }
    }

    /// Whether drawing is on, which the Draw button shows.
    var isDrawing: Bool {
        get { model.isDrawing }
        set { model.isDrawing = newValue }
    }

    // MARK: Showing

    /// Shows the bar on `screen`: where it was left there last, or centered near the bottom, clear
    /// of `area` (in AppKit's global space) when only part of the screen is recorded.
    func show(on screen: NSScreen, avoiding area: CGRect? = nil) {
        guard let display = ScreencastBarDisplay(screen: screen) else { return }
        show(on: display, avoiding: area)
    }

    func show(on display: ScreencastBarDisplay, avoiding area: CGRect? = nil) {
        let size = contentSize()
        place(CGRect(origin: placement.origin(for: size, on: display, avoiding: area), size: size))
        isShown = true
        observeMoves()
        guard ordersPanelIn else { return }
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
    }

    /// Hides the bar, and a question waiting for an answer. It shows again for the next recording.
    func hide() {
        isShown = false
        model.keep()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel.orderOut(nil)
    }

    // MARK: Position

    /// Remembers where the person left the bar, on the display it's on now.
    func panelDidMove() {
        let origin = panel.frame.origin
        guard isShown, origin != placedOrigin,
              let display = ScreencastControlBarPlacement.display(for: panel.frame, among: displays()) else { return }
        placedOrigin = nil
        placement.remember(origin, on: display)
    }

    private func observeMoves() {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidMove() }
        }
    }

    private func place(_ frame: CGRect) {
        placedOrigin = frame.origin
        panel.setFrame(frame, display: false)
        panel.invalidateShadow()
    }

    /// Resizes the bar to its content around its middle, kept on its display.
    private func fitToContent() {
        // Read before measuring, which can already resize the panel from its left edge.
        let frame = panel.frame
        let size = contentSize()
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY)
        if let display = ScreencastControlBarPlacement.display(for: frame, among: displays()) {
            origin = ScreencastControlBarPlacement.clamped(origin, size: size, within: display.visibleFrame)
        }
        place(CGRect(origin: origin, size: size))
    }

    /// The bar's size, once its view is in the panel. Setting the view again lays it out now, not
    /// on SwiftUI's next update, so a button that just appeared is measured.
    private func contentSize() -> CGSize {
        let view = ScreencastControlBarView(model: model)
        if let hostingView {
            hostingView.rootView = view
            hostingView.layoutSubtreeIfNeeded()
            return hostingView.fittingSize
        }
        let host = ScreencastBarHostingView(rootView: view)
        panel.contentView = host
        hostingView = host
        return host.fittingSize
    }
}

/// The control bar's window: a borderless panel that floats over other apps, on every Space and
/// beside full-screen apps, and takes clicks without becoming key or main, so the app being
/// recorded keeps the keyboard and stays in front. After BetterCapture's `RecordingOverlayPanel`
/// (MIT, see LICENSE.bettercapture) and Shotnix's `RecordingHUDWindow` (MIT, see LICENSE.shotnix).
///
/// It doesn't set `sharingType`: ScreenCaptureKit ignores it, so the recorder's filter is what
/// keeps the bar out of the video.
final class ScreencastControlBarPanel: NSPanel {
    static let identifier = NSUserInterfaceItemIdentifier("screencastControlBar")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        // ⌘H and Hide Others leave it, since the recording goes on.
        canHide = false
        // Keybumps is rarely the active app while recording, and the buttons explain themselves.
        allowsToolTipsWhenApplicationIsInactive = true
        identifier = Self.identifier
        setAccessibilityLabel("Screencast controls")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, so a button works while another app is active.
private final class ScreencastBarHostingView: NSHostingView<ScreencastControlBarView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
