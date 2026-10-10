import CoreGraphics
import Foundation

/// What's on screen, as the recorder needs it: plain facts read from `SCShareableContent`, so the
/// filter rules can be tested without ScreenCaptureKit. No window title or app name is kept.
struct ScreencastContent {
    struct Display: Equatable, Sendable {
        let id: CGDirectDisplayID
        /// In the global top-left space, in points.
        let frame: CGRect
        /// Pixels per point.
        let scale: CGFloat
    }

    struct Window: Equatable, Sendable {
        let id: CGWindowID
        /// In the global top-left space, in points.
        let frame: CGRect
        /// The window server layer: 0 for ordinary windows, higher for menus and panels.
        let layer: Int
        let processID: pid_t
        /// Untitled: a sheet, popover, or panel rather than a document window. The title itself is
        /// never read into this.
        let isUntitled: Bool
        let isOnScreen: Bool
        /// Its place front to back among the windows on screen, 0 in front; nil when it isn't on
        /// screen or that isn't known, which counts as behind every window.
        var order: Int?
    }

    let displays: [Display]
    let windows: [Window]
    /// The processes ScreenCaptureKit lists as apps, which a filter can include or exclude whole.
    let applicationProcessIDs: Set<pid_t>
    /// The `SCShareableContent` this came from, which the app's capture system builds filters
    /// from. Nil in tests.
    let source: AnyObject?

    init(displays: [Display], windows: [Window], applicationProcessIDs: Set<pid_t>, source: AnyObject? = nil) {
        self.displays = displays
        self.windows = windows
        self.applicationProcessIDs = applicationProcessIDs
        self.source = source
    }

    func display(_ id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    func window(_ id: CGWindowID) -> Window? {
        windows.first { $0.id == id }
    }

    /// The display showing the largest part of `frame`.
    func display(mostOverlapping frame: CGRect) -> Display? {
        displays
            .map { (display: $0, overlap: $0.frame.intersection(frame)) }
            .filter { !$0.overlap.isNull && !$0.overlap.isEmpty }
            .max { $0.overlap.width * $0.overlap.height < $1.overlap.width * $1.overlap.height }?
            .display
    }
}

/// What one video stream shows: a `SCContentFilter`, described with window and process IDs.
enum ScreencastFilterPlan: Equatable, Sendable {
    /// The display without `excludedProcess`'s windows (Keybumps), except `exceptingWindows`
    /// (its overlays), which come back. Display and area recordings. Excluding the whole app keeps
    /// windows it opens mid-recording out too.
    case display(CGDirectDisplayID, excludingProcess: pid_t?, exceptingWindows: [CGWindowID])
    /// Only these windows on the display. Window recordings: the window, its app's menus, sheets,
    /// and popovers on screen, and Keybumps's overlays, each named; no app is included whole, so a
    /// window opened later shows only once a rebuild names it.
    case windows(CGDirectDisplayID, includingWindows: [CGWindowID])

    var displayID: CGDirectDisplayID {
        switch self {
        case .display(let id, _, _), .windows(let id, _): id
        }
    }

    /// Whether a window Keybumps (`ownProcessID`) opens later would show until the filter is
    /// rebuilt: only a display plan that couldn't leave out the whole app. A window plan names
    /// every window it shows, so none of Keybumps's can slip in.
    func dependsOnWindows(of ownProcessID: pid_t) -> Bool {
        switch self {
        case .display(_, let excluded, _): excluded == nil
        case .windows: false
        }
    }
}

/// Which windows a recording shows: never Keybumps's own (the control bar, the picker's dimming,
/// notices, Settings), except the overlays registered with the recorder (drawing, click rings,
/// shortcuts), which are in the video on purpose.
///
/// Adapted from Shotnix's `RecordingCaptureFilter` (`Sources/ShotnixCore/Capture/RecordingCaptureFilter.swift`,
/// MIT, see LICENSE.shotnix) and Snapzy's `makeContentFilter` and `addExceptedWindow`
/// (`Snapzy/Services/Capture/ScreenRecordingManager.swift`, BSD-3-Clause, see LICENSE.snapzy).
enum ScreencastCaptureFilter {
    /// A display or area recording.
    static func displayPlan(
        display: CGDirectDisplayID,
        ownProcessID: pid_t,
        overlays: Set<CGWindowID>,
        content: ScreencastContent
    ) -> ScreencastFilterPlan {
        let ownWindows = content.windows.filter { $0.processID == ownProcessID }
        guard content.applicationProcessIDs.contains(ownProcessID) else {
            // ScreenCaptureKit doesn't list Keybumps (no windows yet), so there's nothing of it to
            // exclude now, and nothing to except either.
            return .display(display, excludingProcess: nil, exceptingWindows: [])
        }
        return .display(
            display,
            excludingProcess: ownProcessID,
            exceptingWindows: ownWindows.map(\.id).filter(overlays.contains).sorted()
        )
    }

    /// A window recording, on the display showing most of it, as a list of windows:
    /// - the window;
    /// - its app's other windows on screen on that display, except its ordinary windows, which
    ///   would cover the chosen one where they overlap it, so its menus, sheets, and popovers show.
    ///   An ordinary window laid out as the chosen one's sheet (`isSheet(_:on:)`: a titled Save or
    ///   Open sheet) shows too;
    /// - Keybumps's registered overlays, on screen or not, so one shows the moment it's ordered in.
    ///
    /// Nothing else: Keybumps itself is never included whole, so none of its other windows (a
    /// notice, the Command Palette, typed keys) can be in the video, even for a frame, and no other
    /// app's window is named.
    ///
    /// **Known limitation:** a sandboxed app's Open and Save panels are drawn by a system service,
    /// one process per app, and nothing public ties a service process to its app. Naming them would
    /// risk another app's panel, with its folders and file names, so they're left out. In a
    /// sandboxed app, record an area to include its Save or Open panel.
    ///
    /// The recorder rebuilds the list when the app's windows change. Nil when the window or its
    /// display isn't in `content` (closed, or not on screen in an on-screen read).
    static func windowPlan(
        window windowID: CGWindowID,
        ownProcessID: pid_t,
        overlays: Set<CGWindowID>,
        content: ScreencastContent
    ) -> ScreencastFilterPlan? {
        guard let window = content.window(windowID),
              let display = content.display(mostOverlapping: window.frame) else { return nil }
        let siblings = content.windows.filter { $0.processID == window.processID && $0.id != window.id }
        let hidden = windowsToHide(recording: window, others: siblings)
        let appWindows = siblings.filter { sibling in
            sibling.isOnScreen && sibling.frame.intersects(display.frame)
                && (!hidden.contains(sibling.id) || isSheet(sibling, on: window))
                // Recording one of Keybumps's own windows: its others only when they're overlays.
                && (window.processID != ownProcessID || overlays.contains(sibling.id))
        }
        let ownOverlays = content.windows.filter { $0.processID == ownProcessID && $0.id != window.id && overlays.contains($0.id) }
        let included = Set([window.id] + appWindows.map(\.id) + ownOverlays.map(\.id))
        return .windows(display.id, includingWindows: included.sorted())
    }

    /// Whether `other` is laid out as `window`'s sheet: centred on it (within 2 pt), its top below
    /// the window's title bar and toolbar (within 150 pt of the window's top, which leaves room for
    /// an expanded or labelled toolbar and a tab bar), and in front of it. It may run past the
    /// window's bottom, as a tall Save sheet on a short window does. A smaller window that merely
    /// sits inside isn't one, nor is a window of unknown place. Only the recorded app's own windows
    /// are ever asked about, so a loose bound can't let in another app's.
    static func isSheet(_ other: ScreencastContent.Window, on window: ScreencastContent.Window) -> Bool {
        guard let otherOrder = other.order, let windowOrder = window.order, otherOrder < windowOrder else { return false }
        let centred = abs(other.frame.midX - window.frame.midX) <= 2
        let below = other.frame.minY - window.frame.minY
        return centred && below >= 0 && below <= 150
    }

    /// The other windows of a recorded window's app to leave out: its ordinary windows (layer 0).
    /// Menus, popovers, and sheets that open later still come through, and so does an untitled
    /// window already over the chosen one when recording starts: that's its sheet or popover.
    static func windowsToHide(recording chosen: ScreencastContent.Window, others: [ScreencastContent.Window]) -> Set<CGWindowID> {
        Set(others.compactMap { other -> CGWindowID? in
            guard other.id != chosen.id, other.layer == 0 else { return nil }
            if other.isUntitled, other.frame.intersects(chosen.frame) { return nil }
            return other.id
        })
    }
}
