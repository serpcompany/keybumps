import AppKit

/// A display the control bar can sit on: a key that stays the same across launches and
/// reconnections, and the part of it windows may use (below the menu bar, beside the Dock), in
/// AppKit's global space.
struct ScreencastBarDisplay: Equatable {
    let key: String
    let visibleFrame: CGRect
}

extension ScreencastBarDisplay {
    @MainActor
    init?(screen: NSScreen) {
        guard let id = Self.displayID(of: screen) else { return nil }
        self.init(key: Self.key(for: id), visibleFrame: screen.visibleFrame)
    }

    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The display's UUID, which survives a restart or a reconnection, unlike its ID.
    static func key(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return "display-\(id)" }
        return string as String
    }

    @MainActor
    static var connected: [ScreencastBarDisplay] {
        NSScreen.screens.compactMap(ScreencastBarDisplay.init(screen:))
    }
}

/// Where the control bar sits: where it was last left on that display, kept inside its visible
/// frame, or else centered near the bottom, away from the notch notices at the top, and above an
/// area being recorded when there's room. Positions are kept per display, relative to its visible
/// frame, in the injected defaults.
struct ScreencastControlBarPlacement {
    static let defaultsKey = "screencast.controlBarPositions"
    /// The default spot's height above the bottom of the visible frame, clear of the Dock.
    static let bottomInset: CGFloat = 24
    /// Room the default spot keeps from the visible frame's edges, and from an area it moves off.
    static let margin: CGFloat = 12

    let defaults: UserDefaults

    /// The bar's origin on `display`. `area`, in AppKit's global space, is the part of the screen
    /// being recorded; only the default spot moves off it, since a spot the person chose is theirs.
    func origin(for size: CGSize, on display: ScreencastBarDisplay, avoiding area: CGRect? = nil) -> CGPoint {
        guard let offset = storedOffset(on: display) else {
            return Self.defaultOrigin(for: size, in: display.visibleFrame, avoiding: area)
        }
        let origin = CGPoint(x: display.visibleFrame.minX + offset.x, y: display.visibleFrame.minY + offset.y)
        return Self.clamped(origin, size: size, within: display.visibleFrame)
    }

    /// Remembers `origin` as where the bar was left on `display`.
    func remember(_ origin: CGPoint, on display: ScreencastBarDisplay) {
        var positions = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        positions[display.key] = [Double(origin.x - display.visibleFrame.minX), Double(origin.y - display.visibleFrame.minY)]
        defaults.set(positions, forKey: Self.defaultsKey)
    }

    /// Where the bar was left on `display`, from its visible frame's bottom-left corner.
    func storedOffset(on display: ScreencastBarDisplay) -> CGPoint? {
        guard let values = defaults.dictionary(forKey: Self.defaultsKey)?[display.key] as? [Double],
              values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    static func defaultOrigin(for size: CGSize, in visibleFrame: CGRect, avoiding area: CGRect?) -> CGPoint {
        var frame = CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + bottomInset,
            width: size.width,
            height: size.height
        )
        if let area, frame.intersects(area) {
            // Just above the area. An area that leaves no room there keeps the bar where it is:
            // it's never in the video anyway.
            let above = frame.offsetBy(dx: 0, dy: area.maxY + margin - frame.minY)
            if visibleFrame.insetBy(dx: margin, dy: margin).contains(above) { frame = above }
        }
        return clamped(frame.origin, size: size, within: visibleFrame)
    }

    /// `origin` moved as little as keeps a bar of `size` inside `visibleFrame`, after Snapzy's
    /// `RecordingToolbarWindow.clampedOrigin` (BSD-3-Clause, see LICENSE.snapzy).
    static func clamped(_ origin: CGPoint, size: CGSize, within visibleFrame: CGRect) -> CGPoint {
        guard !visibleFrame.isNull, !visibleFrame.isEmpty else { return origin }
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    /// The display a bar at `frame` is on: the one whose visible frame holds its middle, else the
    /// one it overlaps most; nil when it's on none.
    static func display(for frame: CGRect, among displays: [ScreencastBarDisplay]) -> ScreencastBarDisplay? {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        if let holding = displays.first(where: { $0.visibleFrame.contains(middle) }) { return holding }
        func overlap(_ display: ScreencastBarDisplay) -> CGFloat {
            let shared = display.visibleFrame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let most = displays.max(by: { overlap($0) < overlap($1) }), overlap(most) > 0 else { return nil }
        return most
    }
}
