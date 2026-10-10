import AppKit

/// A screen the overlays cover: its ID, as the recorder's targets name it, and its frames in
/// AppKit's global space.
struct ScreencastOverlayDisplay: Equatable {
    let id: CGDirectDisplayID
    /// The whole screen, which the drawing layer covers.
    let frame: CGRect
    /// The part below the menu bar and beside the Dock, which the border while drawing goes around:
    /// the menu bar and the Dock sit above the layer.
    let visibleFrame: CGRect
}

extension ScreencastOverlayDisplay {
    @MainActor
    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        self.init(id: CGDirectDisplayID(number.uint32Value), frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    @MainActor
    static var connected: [ScreencastOverlayDisplay] {
        NSScreen.screens.compactMap(ScreencastOverlayDisplay.init(screen:))
    }
}

/// What the drawing layer's views draw, and where they send the pointer while drawing.
@MainActor
protocol ScreencastDrawingCanvasDelegate: AnyObject {
    func visibleMarks(on display: CGDirectDisplayID) -> [ScreencastVisibleMark]
    /// Points are in the display's points from its top-left corner.
    func pointerDown(at point: CGPoint, on display: CGDirectDisplayID)
    func pointerDragged(to point: CGPoint, on display: CGDirectDisplayID)
    func pointerUp(at point: CGPoint, on display: CGDirectDisplayID)
}

/// The drawing layer: on each recorded display, a transparent window the marks are drawn in, which
/// the recorder puts in the video, and another for the border that shows while drawing, which it
/// leaves out. They're on screen from `show` to `hide`, so the windows given to the recorder keep
/// their IDs and no new window of Keybumps's appears mid-recording.
///
/// The marks' window lets every click through to the app underneath, except while drawing, when
/// it takes the pointer and the border shows, so the Mac never seems frozen. Neither window ever
/// becomes key or activates Keybumps: the recorded app keeps the keyboard and the menu bar.
///
/// After hop's `MarkupOverlayController`, `MarkupOverlayWindow`, and `ScreenAnnotateController`
/// (MIT, see LICENSE.hop): a window per display that passes clicks or takes them, with the border
/// while it takes them, rebuilt as displays come and go; and Snapzy's
/// `RecordingAnnotationOverlayWindow` (BSD-3-Clause, see LICENSE.snapzy): a transparent window
/// over the recording that the recorder re-includes, passing the mouse through when not drawing.
@MainActor
final class ScreencastDrawingLayer {
    /// Above ordinary windows, and below the control bar and the drawing tools (`.floating`), so
    /// they stay clickable while drawing. The menu bar and the Dock stay above it too.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    /// The hit-through rule: the marks' windows take the pointer only while drawing.
    static func ignoresMouseEvents(isDrawing: Bool) -> Bool { !isDrawing }

    weak var delegate: (any ScreencastDrawingCanvasDelegate)? {
        didSet { for window in inkWindows.values { window.canvas.delegate = delegate } }
    }
    /// Called with the marks' windows whenever they change: when the layer shows, when a recorded
    /// display goes or comes back, and with none when it hides.
    var onWindowsChange: (([CGWindowID]) -> Void)?

    private(set) var isDrawing = false
    /// The displays it's on, in order.
    private(set) var displays: [ScreencastOverlayDisplay] = []
    private var inkWindows: [CGDirectDisplayID: ScreencastDrawingWindow] = [:]
    private var borderWindows: [CGDirectDisplayID: ScreencastDrawingBorderWindow] = [:]
    private let ordersWindowsIn: Bool

    /// - Parameter ordersWindowsIn: False keeps the windows off screen, as under the unit-test host.
    init(ordersWindowsIn: Bool = !UnitTestHost.isActive) {
        self.ordersWindowsIn = ordersWindowsIn
    }

    /// The marks' windows, which the recorder shows in the video, in display order.
    var windowIDs: [CGWindowID] {
        displays.compactMap { inkWindows[$0.id]?.windowID }
    }

    var isShown: Bool { !displays.isEmpty }

    func window(on display: CGDirectDisplayID) -> ScreencastDrawingWindow? { inkWindows[display] }

    func borderWindow(on display: CGDirectDisplayID) -> ScreencastDrawingBorderWindow? { borderWindows[display] }

    // MARK: Showing

    /// Covers exactly `displays`: a display already covered keeps its windows, moved to its frame
    /// if that changed; a new one gets windows, and one no longer listed loses them.
    func show(on displays: [ScreencastOverlayDisplay]) {
        let before = windowIDs
        let wanted = Set(displays.map(\.id))
        for id in Array(inkWindows.keys) where !wanted.contains(id) {
            inkWindows.removeValue(forKey: id)?.closeOverlay()
            borderWindows.removeValue(forKey: id)?.closeOverlay()
        }
        for display in displays {
            if let window = inkWindows[display.id] {
                if window.frame != display.frame { window.setFrame(display.frame, display: false) }
                if let border = borderWindows[display.id], border.frame != display.visibleFrame {
                    border.setFrame(display.visibleFrame, display: false)
                }
            } else {
                let window = ScreencastDrawingWindow(display: display)
                window.canvas.delegate = delegate
                window.ignoresMouseEvents = Self.ignoresMouseEvents(isDrawing: isDrawing)
                let border = ScreencastDrawingBorderWindow(frame: display.visibleFrame)
                border.isShowingBorder = isDrawing
                inkWindows[display.id] = window
                borderWindows[display.id] = border
                if ordersWindowsIn {
                    window.hideDuringUnitTests()
                    border.hideDuringUnitTests()
                    window.orderFrontRegardless()
                    border.orderFrontRegardless()
                }
            }
        }
        self.displays = displays
        if windowIDs != before { onWindowsChange?(windowIDs) }
    }

    /// Takes every window off screen and closes it.
    func hide() {
        setDrawing(false)
        let hadWindows = !inkWindows.isEmpty
        for window in inkWindows.values { window.closeOverlay() }
        for window in borderWindows.values { window.closeOverlay() }
        inkWindows.removeAll()
        borderWindows.removeAll()
        displays = []
        if hadWindows { onWindowsChange?([]) }
    }

    // MARK: Drawing

    /// Takes the pointer and shows the border on every display while drawing; lets clicks through
    /// and hides the border otherwise.
    func setDrawing(_ drawing: Bool) {
        isDrawing = drawing
        for window in inkWindows.values { window.ignoresMouseEvents = Self.ignoresMouseEvents(isDrawing: drawing) }
        for window in borderWindows.values { window.isShowingBorder = drawing }
    }

    /// Redraws `rect` of `display` (its points from the top-left), or all of it.
    func redraw(_ rect: CGRect? = nil, on display: CGDirectDisplayID) {
        guard let canvas = inkWindows[display]?.canvas else { return }
        if let rect, !rect.isNull {
            canvas.setNeedsDisplay(rect.intersection(canvas.bounds))
        } else {
            canvas.needsDisplay = true
        }
    }

    func redrawAll() {
        for window in inkWindows.values { window.canvas.needsDisplay = true }
    }
}

// MARK: - The windows

/// A recorded display's drawing: a transparent, borderless panel covering it, on every Space and
/// beside full-screen apps. It takes clicks without becoming key or activating Keybumps. Its
/// `sharingType` stays readable: the recorder puts it in the video.
final class ScreencastDrawingWindow: NSPanel {
    static let identifier = NSUserInterfaceItemIdentifier("screencastDrawing")

    let display: CGDirectDisplayID
    let canvas: ScreencastDrawingCanvasView

    init(display: ScreencastOverlayDisplay) {
        self.display = display.id
        canvas = ScreencastDrawingCanvasView(display: display.id)
        // Not deferred, so the window has its number, which the recorder is given, at once.
        super.init(contentRect: display.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay(level: ScreencastDrawingLayer.level)
        identifier = Self.identifier
        setAccessibilityLabel("Screencast drawing")
        canvas.frame = CGRect(origin: .zero, size: display.frame.size)
        canvas.autoresizingMask = [.width, .height]
        contentView = canvas
        setFrame(display.frame, display: false)
    }

    /// Its window server ID, which `SCWindow.windowID` matches.
    var windowID: CGWindowID { CGWindowID(windowNumber) }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The border while drawing, on its own window so the video never shows it: it ignores the mouse
/// always, and draws only while drawing.
final class ScreencastDrawingBorderWindow: NSPanel {
    static let identifier = NSUserInterfaceItemIdentifier("screencastDrawingBorder")
    static let lineWidth: CGFloat = 4
    static let color = NSColor.systemYellow.withAlphaComponent(0.8)

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay(level: ScreencastDrawingLayer.level)
        identifier = Self.identifier
        ignoresMouseEvents = true
        let view = BorderView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        contentView = view
        setFrame(frame, display: false)
        setAccessibilityElement(false)
    }

    var isShowingBorder: Bool {
        get { contentView?.isHidden == false }
        set { contentView?.isHidden = !newValue }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let inset = ScreencastDrawingBorderWindow.lineWidth / 2
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            path.lineWidth = ScreencastDrawingBorderWindow.lineWidth
            ScreencastDrawingBorderWindow.color.setStroke()
            path.stroke()
        }
    }
}

private extension NSPanel {
    /// Transparent, borderless, and out of the way: on every Space and beside full-screen apps,
    /// left in place by Mission Control, never hidden by ⌘H or by Keybumps going inactive.
    func configureAsOverlay(level: NSWindow.Level) {
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    func closeOverlay() {
        orderOut(nil)
        close()
    }
}

// MARK: - The view

/// Draws one display's marks, and while drawing hands the pointer to the delegate in the display's
/// points from its top-left corner. After Snapzy's `RecordingAnnotationCanvasView` (BSD-3-Clause,
/// see LICENSE.snapzy): a press starts a mark, a drag extends it, the release ends it.
final class ScreencastDrawingCanvasView: NSView {
    let display: CGDirectDisplayID
    weak var delegate: (any ScreencastDrawingCanvasDelegate)?

    init(display: CGDirectDisplayID) {
        self.display = display
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// The first press draws, rather than only bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let delegate else { return }
        for visible in delegate.visibleMarks(on: display) where visible.mark.bounds.intersects(dirtyRect) {
            ScreencastDrawingRenderer.draw(visible, in: ctx)
        }
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.pointerDown(at: convert(event.locationInWindow, from: nil), on: display)
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.pointerDragged(to: convert(event.locationInWindow, from: nil), on: display)
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.pointerUp(at: convert(event.locationInWindow, from: nil), on: display)
    }
}
