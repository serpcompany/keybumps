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
        /// No title (an empty window name). The title itself is never read into this, and no
        /// filter rule uses it.
        let isUntitled: Bool
        let isOnScreen: Bool
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
    /// Only these windows on the display. Window recordings: the window and Keybumps's overlays,
    /// each named; no app is included whole, so no other window can show, not even one opened
    /// later. `ScreencastCaptureFilter.narrowed` takes overlays since removed out of it without a
    /// read.
    case windows(CGDirectDisplayID, includingWindows: [CGWindowID])

    var displayID: CGDirectDisplayID {
        switch self {
        case .display(let id, _, _), .windows(let id, _): id
        }
    }

    /// The windows a window plan names; none for a display plan.
    var windowIDs: [CGWindowID] {
        if case .windows(_, let ids) = self { ids } else { [] }
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

    /// A window recording, on the display showing most of it, as a list of windows: the window,
    /// and Keybumps's registered overlays (drawing, keys), on screen or not, so one shows the
    /// moment it's ordered in.
    ///
    /// Nothing else (the owner's decision for the MVP): none of its app's other windows, titled or
    /// not, wherever they are (its menus, sheets, popovers, tooltips, completion lists, Settings
    /// window, another document); nothing below the windows (Finder's desktop and its icons); no
    /// other app's window; and none of Keybumps's but the overlays, so a notice or the Command
    /// Palette can't be in the video, even for a frame. Record an area or the screen to show menus
    /// and sheets; #473 brings them to window recordings.
    ///
    /// Nil when the window or its display isn't in `content` (closed): a filter built from
    /// `content` couldn't name the window, so the recorder builds none from it.
    static func windowPlan(
        window windowID: CGWindowID,
        ownProcessID: pid_t,
        overlays: Set<CGWindowID>,
        content: ScreencastContent
    ) -> ScreencastFilterPlan? {
        guard let window = content.window(windowID),
              let display = content.display(mostOverlapping: window.frame) else { return nil }
        let shownOverlays = content.windows.filter { $0.processID == ownProcessID && overlays.contains($0.id) }.map(\.id)
        return .windows(display.id, includingWindows: Set([window.id] + shownOverlays).sorted())
    }

    /// A window recording's `plan` with only the windows it may still show: the recorded window
    /// and Keybumps's registered overlays (`overlays`). It takes out an overlay since removed, and
    /// never adds one, so it's applied from the read the list in hand was built from, without a new
    /// read. A display plan is unchanged.
    static func narrowed(
        _ plan: ScreencastFilterPlan,
        window windowID: CGWindowID,
        overlays: Set<CGWindowID>
    ) -> ScreencastFilterPlan {
        guard case .windows(let display, let included) = plan else { return plan }
        return .windows(display, includingWindows: included.filter { $0 == windowID || overlays.contains($0) })
    }
}
