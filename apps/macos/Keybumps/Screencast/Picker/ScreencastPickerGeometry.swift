import AppKit
import CoreGraphics

// The picker's geometry, kept free of windows so it can be tested: the displays and the two
// global spaces, the area being drawn, and which windows can be picked.

/// A display as the picker draws on it.
struct ScreencastScreen: Equatable, Sendable {
    let id: CGDirectDisplayID
    /// Its `NSScreen.frame`: AppKit's global space, origin at the main display's bottom-left.
    let frame: CGRect
    /// Pixels per point.
    let scale: CGFloat
}

/// The connected displays, and the conversions between AppKit's global space, which the picker's
/// windows and the mouse use, and the top-left global space ScreenCaptureKit uses (`SCWindow.frame`,
/// `SCDisplay.frame`, and so `ScreencastContent`).
struct ScreencastScreenLayout: Equatable, Sendable {
    let screens: [ScreencastScreen]

    /// The displays now, from `NSScreen`.
    @MainActor
    static func current() -> ScreencastScreenLayout {
        ScreencastScreenLayout(screens: NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return ScreencastScreen(id: CGDirectDisplayID(number.uint32Value), frame: screen.frame, scale: screen.backingScaleFactor)
        })
    }

    /// The main display's height: both spaces start at its corners, AppKit's at the bottom-left
    /// and the top-left space at the top-left.
    var primaryHeight: CGFloat {
        (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
    }

    /// `rect` in AppKit's space, in the top-left space. The conversion is its own inverse, so
    /// `appKitRect(fromTopLeft:)` is the same flip.
    func topLeftRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    func appKitRect(fromTopLeft rect: CGRect) -> CGRect {
        topLeftRect(fromAppKit: rect)
    }

    func topLeftPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    func screen(_ id: CGDirectDisplayID) -> ScreencastScreen? {
        screens.first { $0.id == id }
    }

    /// The screen under `point` (AppKit's space). A point on an edge two screens share belongs to
    /// one of them: `minX ≤ x < maxX` and `minY < y ≤ maxY`, as `NSMouseInRect` reads an unflipped
    /// rect, so the pointer at a screen's very top is on it. Nil in a gap between screens. From
    /// Snapzy's `RecordingDisplaySelectionLogic.display(containing:screens:)` (BSD-3-Clause, see
    /// LICENSE.snapzy).
    func screen(containing point: CGPoint) -> ScreencastScreen? {
        screens.first { screen in
            point.x >= screen.frame.minX && point.x < screen.frame.maxX
                && point.y > screen.frame.minY && point.y <= screen.frame.maxY
        }
    }

    /// The screen showing the largest part of `rect` (AppKit's space), nil when it's on none.
    func screen(mostOverlapping rect: CGRect) -> ScreencastScreen? {
        screens
            .map { (screen: $0, overlap: $0.frame.intersection(rect)) }
            .filter { !$0.overlap.isNull && !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .screen
    }
}

/// An area chosen on one screen.
struct ScreencastPickedArea: Equatable, Sendable {
    let display: CGDirectDisplayID
    /// In AppKit's global space.
    let rect: CGRect
}

/// Drawing, moving, and resizing the area to capture, in AppKit's global space, on one screen.
///
/// Adapted from BetterCapture's `AreaSelectionView` (`BetterCapture/View/AreaSelectionOverlay.swift`,
/// MIT, see LICENSE.bettercapture): pressing outside the area draws a new one, inside moves it, and
/// on a handle resizes it, corners before edges; an area drawn too small is dropped.
struct ScreencastAreaEditor: Equatable {
    enum Handle: CaseIterable, Equatable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var isCorner: Bool {
            self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight
        }
    }

    enum Gesture: Equatable {
        case drawing(origin: CGPoint)
        /// From the press to the area's origin.
        case moving(offset: CGVector)
        case resizing(Handle)
    }

    /// The smallest area, in points each way.
    static let minimumSize: CGFloat = 24
    static let handleSize: CGFloat = 8
    /// How far around a handle a press still takes it.
    static let handleHitMargin: CGFloat = 8

    /// The area, or nil until one is drawn. While it's being drawn it can be smaller than the
    /// minimum.
    private(set) var rect: CGRect?
    /// The frame of the screen it's on: drawing, moving, and resizing stay inside it.
    private(set) var bounds: CGRect
    private(set) var gesture: Gesture?

    init(rect: CGRect? = nil, bounds: CGRect) {
        self.bounds = bounds
        self.rect = rect.map { Self.clamped($0, to: bounds) }
    }

    /// A press at `point` on the screen whose frame is `screen`.
    mutating func press(at point: CGPoint, on screen: CGRect) {
        if let rect, screen == bounds {
            if let handle = handle(at: point) {
                gesture = .resizing(handle)
                return
            }
            if rect.contains(point) {
                gesture = .moving(offset: CGVector(dx: point.x - rect.minX, dy: point.y - rect.minY))
                return
            }
        }
        bounds = screen
        let origin = clamp(point)
        rect = CGRect(origin: origin, size: .zero)
        gesture = .drawing(origin: origin)
    }

    mutating func drag(to point: CGPoint) {
        guard let gesture, let current = rect else { return }
        let point = clamp(point)
        switch gesture {
        case .drawing(let origin):
            rect = Self.rect(from: origin, to: point)
        case .moving(let offset):
            var origin = CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
            origin.x = max(bounds.minX, min(origin.x, bounds.maxX - current.width))
            origin.y = max(bounds.minY, min(origin.y, bounds.maxY - current.height))
            rect = CGRect(origin: origin, size: current.size)
        case .resizing(let handle):
            rect = Self.resized(current, handle: handle, to: point)
        }
    }

    /// Ends the gesture. A drawn area smaller than the minimum is dropped; a resized one grows back
    /// to it.
    mutating func release() {
        guard let gesture else { return }
        self.gesture = nil
        guard let current = rect else { return }
        switch gesture {
        case .drawing:
            if current.width < Self.minimumSize || current.height < Self.minimumSize { rect = nil }
        case .resizing:
            let size = CGSize(width: max(current.width, Self.minimumSize), height: max(current.height, Self.minimumSize))
            rect = Self.clamped(CGRect(origin: current.origin, size: size), to: bounds)
        case .moving:
            break
        }
    }

    var isDrawing: Bool {
        if case .drawing = gesture { true } else { false }
    }

    /// The handle under `point`, corners first.
    func handle(at point: CGPoint) -> Handle? {
        let rects = handleRects()
        let order = Handle.allCases.filter(\.isCorner) + Handle.allCases.filter { !$0.isCorner }
        return order.first { handle in
            rects[handle]?.insetBy(dx: -Self.handleHitMargin, dy: -Self.handleHitMargin).contains(point) == true
        }
    }

    /// Each handle's square, centered on a corner or an edge's middle. AppKit's space is unflipped,
    /// so the top is `maxY`.
    func handleRects() -> [Handle: CGRect] {
        guard let rect else { return [:] }
        let half = Self.handleSize / 2
        func square(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - half, y: y - half, width: Self.handleSize, height: Self.handleSize)
        }
        return [
            .topLeft: square(rect.minX, rect.maxY), .top: square(rect.midX, rect.maxY), .topRight: square(rect.maxX, rect.maxY),
            .left: square(rect.minX, rect.midY), .right: square(rect.maxX, rect.midY),
            .bottomLeft: square(rect.minX, rect.minY), .bottom: square(rect.midX, rect.minY), .bottomRight: square(rect.maxX, rect.minY),
        ]
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: max(bounds.minX, min(point.x, bounds.maxX)), y: max(bounds.minY, min(point.y, bounds.maxY)))
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// `rect` resized by dragging `handle` to `point`: a corner from the opposite corner, an edge
    /// along its own axis only, never below the minimum.
    static func resized(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        switch handle {
        case .topLeft: return Self.rect(from: CGPoint(x: rect.maxX, y: rect.minY), to: point)
        case .topRight: return Self.rect(from: CGPoint(x: rect.minX, y: rect.minY), to: point)
        case .bottomLeft: return Self.rect(from: CGPoint(x: rect.maxX, y: rect.maxY), to: point)
        case .bottomRight: return Self.rect(from: CGPoint(x: rect.minX, y: rect.maxY), to: point)
        case .top:
            let maxY = max(rect.minY + minimumSize, point.y)
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: maxY - rect.minY)
        case .bottom:
            let minY = min(rect.maxY - minimumSize, point.y)
            return CGRect(x: rect.minX, y: minY, width: rect.width, height: rect.maxY - minY)
        case .left:
            let minX = min(rect.maxX - minimumSize, point.x)
            return CGRect(x: minX, y: rect.minY, width: rect.maxX - minX, height: rect.height)
        case .right:
            let maxX = max(rect.minX + minimumSize, point.x)
            return CGRect(x: rect.minX, y: rect.minY, width: maxX - rect.minX, height: rect.height)
        }
    }

    /// `rect` moved, then cut, to fit inside `bounds`.
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(rect.width, bounds.width), height: min(rect.height, bounds.height))
        let x = max(bounds.minX, min(rect.minX, bounds.maxX - size.width))
        let y = max(bounds.minY, min(rect.minY, bounds.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// Which windows the picker offers, and which is under the pointer.
///
/// After Snapzy's `WindowSelectionQueryService` and `WindowCaptureSelectionPolicy`
/// (BSD-3-Clause, see LICENSE.snapzy): ordinary windows only (layer 0, so not the menu bar, the
/// Dock, menus, or the desktop), more than 32 points each way, on a display, front to back, and
/// never Keybumps's own, such as the picker itself.
enum ScreencastWindowPicking {
    static let minimumSize: CGFloat = 32

    /// The windows in `content` that can be picked, in its order (front to back, as
    /// `ScreencastPickerSystem.content()` lists them).
    static func pickableWindows(in content: ScreencastContent, ownProcessID: pid_t) -> [ScreencastContent.Window] {
        content.windows.filter { window in
            window.isOnScreen
                && window.layer == 0
                && window.processID != ownProcessID
                && window.frame.width > minimumSize
                && window.frame.height > minimumSize
                && content.displays.contains { $0.frame.intersects(window.frame) }
        }
    }

    /// The frontmost of `windows` (front to back) under `point`, both in the top-left space.
    static func window(at point: CGPoint, in windows: [ScreencastContent.Window]) -> ScreencastContent.Window? {
        windows.first { $0.frame.contains(point) }
    }
}
