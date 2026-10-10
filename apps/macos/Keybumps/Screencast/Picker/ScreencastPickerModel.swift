import CoreGraphics
import Foundation
import Observation

/// A screenshot or a video.
enum ScreencastCaptureKind: String, CaseIterable, Equatable, Sendable {
    case video
    case screenshot
}

/// What the picker chooses on screen.
enum ScreencastPickerTarget: String, CaseIterable, Equatable, Sendable {
    /// An area dragged on one screen.
    case area
    /// A window clicked.
    case window
    /// A screen clicked, or every screen, one file each.
    case screen
}

/// What the picker's Record or Capture chose: everything the countdown, the recording, and the
/// pieces around it (#448's control bar, #449's overlays) need.
struct ScreencastChoice: Equatable, Sendable {
    /// Where the target is on one display.
    struct Region: Equatable, Sendable {
        let display: CGDirectDisplayID
        /// In AppKit's global space: the area, the window's part of that screen, or the whole screen.
        let frame: CGRect
    }

    var kind: ScreencastCaptureKind
    var target: ScreencastTarget
    /// One per display it shows on, in display order. The countdown shows on these, and the
    /// shortcuts only on these displays.
    var regions: [Region]
    /// The area and its screen, for the highlight while it records; nil for a window or every screen.
    var area: ScreencastPickedArea?
    /// The sounds to record: none for a screenshot.
    var audio: ScreencastAudio
    /// Whether the shortcuts pressed show on screen while it records; off for a screenshot.
    var showsShortcuts: Bool
    /// Whether clicks are highlighted while it records; off for a screenshot.
    var highlightsClicks: Bool
}

/// The picker's state, shared by its windows (one per screen) and its bar: screenshot or video,
/// area, window, or every screen, the area drawn or the window picked, and the switches. The
/// switches start from the settings; changing them here applies to this capture only.
@MainActor
@Observable
final class ScreencastPickerModel {
    var kind: ScreencastCaptureKind = .video {
        didSet { changed() }
    }

    /// Switching keeps the area drawn and the window picked, so switching back finds them.
    var target: ScreencastPickerTarget = .area {
        didSet {
            hoveredWindow = nil
            changed()
        }
    }

    var recordsMicrophone: Bool
    var recordsSystemAudio: Bool
    var showsShortcuts: Bool
    var highlightsClicks: Bool
    /// Whether Keybumps has Microphone access. Without it the microphone switch stays off, so
    /// recording never asks for it.
    let microphoneAvailable: Bool

    let layout: ScreencastScreenLayout
    /// Windows that can be picked, front to back (`ScreencastWindowPicking`). Empty until what's on
    /// screen has been read, and when it can't be.
    var windows: [ScreencastContent.Window] = [] {
        didSet {
            if let selectedWindow, !windows.contains(where: { $0.id == selectedWindow }) { self.selectedWindow = nil }
            changed()
        }
    }

    /// The window under the pointer.
    private(set) var hoveredWindow: CGWindowID?
    /// The window clicked, which Record records.
    private(set) var selectedWindow: CGWindowID?
    /// The screen clicked in Screen mode; nil for every screen, as it starts.
    private(set) var selectedScreen: CGDirectDisplayID?
    private(set) var areaEditor: ScreencastAreaEditor?

    /// Runs after anything the windows draw changes, so they redraw. The bar observes the model.
    @ObservationIgnored var onChange: (() -> Void)?

    init(
        layout: ScreencastScreenLayout,
        preferences: ScreencastPreferences,
        microphoneAvailable: Bool,
        rememberedArea: ScreencastPickedArea? = nil
    ) {
        self.layout = layout
        self.microphoneAvailable = microphoneAvailable
        recordsMicrophone = preferences.recordsMicrophone && microphoneAvailable
        recordsSystemAudio = preferences.recordsSystemAudio
        showsShortcuts = preferences.showsShortcuts
        highlightsClicks = preferences.highlightsClicks
        if let rememberedArea, let screen = layout.screen(rememberedArea.display) {
            areaEditor = ScreencastAreaEditor(rect: rememberedArea.rect, bounds: screen.frame)
        }
    }

    // MARK: What's chosen

    /// The area, once one is drawn: not while it's being drawn, and only at least the minimum size.
    var area: ScreencastPickedArea? {
        guard let editor = areaEditor, let rect = editor.rect, !editor.isDrawing,
              rect.width >= ScreencastAreaEditor.minimumSize, rect.height >= ScreencastAreaEditor.minimumSize,
              let screen = layout.screens.first(where: { $0.frame == editor.bounds }) ?? layout.screen(mostOverlapping: rect)
        else { return nil }
        return ScreencastPickedArea(display: screen.id, rect: rect)
    }

    var canConfirm: Bool { choice() != nil }

    /// Record's title: Record for a video, Capture for a screenshot.
    var confirmTitle: String { kind == .video ? "Record" : "Capture" }

    /// What to do next, under the bar.
    var hint: String {
        switch target {
        case .area:
            area == nil
                ? "Drag to choose an area."
                : "Drag inside it to move it, or its edges to resize it, or drag elsewhere for a new one."
        case .window:
            selectedWindow == nil ? "Click a window to choose it." : "Click another window to change it."
        case .screen:
            if layout.screens.count < 2 {
                "The whole screen."
            } else if selectedScreen == nil {
                "Every screen, one file each. Click a screen for just that one."
            } else {
                "This screen only. Choose Every Screen for all of them."
            }
        }
    }

    /// Whether Screen mode offers Every Screen: with more than one screen.
    var offersEveryScreen: Bool { layout.screens.count > 1 }

    /// What Record would capture now, or nil while nothing is chosen.
    func choice() -> ScreencastChoice? {
        let isVideo = kind == .video
        let audio = isVideo ? ScreencastAudio(microphone: recordsMicrophone && microphoneAvailable, systemAudio: recordsSystemAudio) : .none
        func make(_ target: ScreencastTarget, regions: [ScreencastChoice.Region], area: ScreencastPickedArea? = nil) -> ScreencastChoice {
            ScreencastChoice(
                kind: kind, target: target, regions: regions, area: area, audio: audio,
                showsShortcuts: isVideo && showsShortcuts, highlightsClicks: isVideo && highlightsClicks
            )
        }
        switch target {
        case .area:
            guard let area, let screen = layout.screen(area.display) else { return nil }
            let rect = ScreencastTarget.displayLocalRect(fromAppKit: area.rect, screenFrame: screen.frame)
            return make(.area(display: area.display, rect: rect), regions: [.init(display: area.display, frame: area.rect)], area: area)
        case .window:
            guard let id = selectedWindow, let window = windows.first(where: { $0.id == id }) else { return nil }
            let frame = layout.appKitRect(fromTopLeft: window.frame)
            guard let screen = layout.screen(mostOverlapping: frame) else { return nil }
            return make(.window(id), regions: [.init(display: screen.id, frame: frame.intersection(screen.frame))])
        case .screen:
            if let id = selectedScreen, let screen = layout.screen(id) {
                return make(.display(id), regions: [.init(display: id, frame: screen.frame)])
            }
            // Left to right, as the recorder numbers its files.
            let screens = layout.screens.sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
            guard let first = screens.first else { return nil }
            let target: ScreencastTarget = screens.count == 1 ? .display(first.id) : .everyDisplay
            return make(target, regions: screens.map { .init(display: $0.id, frame: $0.frame) })
        }
    }

    /// Whether Screen mode would capture `screen`: the one clicked, or every screen.
    func isChosen(_ screen: ScreencastScreen) -> Bool {
        selectedScreen == nil || selectedScreen == screen.id
    }

    // MARK: Choosing a screen

    /// Screen mode: just this screen.
    func clickScreen(_ screen: ScreencastScreen) {
        guard target == .screen, layout.screen(screen.id) != nil, selectedScreen != screen.id else { return }
        selectedScreen = screen.id
        changed()
    }

    /// Screen mode: every screen again.
    func chooseEveryScreen() {
        guard selectedScreen != nil else { return }
        selectedScreen = nil
        changed()
    }

    // MARK: Drawing an area (AppKit's global space)

    func pressArea(at point: CGPoint, on screen: ScreencastScreen) {
        guard target == .area else { return }
        var editor = areaEditor ?? ScreencastAreaEditor(bounds: screen.frame)
        editor.press(at: point, on: screen.frame)
        areaEditor = editor
        changed()
    }

    func dragArea(to point: CGPoint) {
        guard target == .area, var editor = areaEditor else { return }
        editor.drag(to: point)
        areaEditor = editor
        changed()
    }

    func releaseArea() {
        guard target == .area, var editor = areaEditor else { return }
        editor.release()
        areaEditor = editor
        changed()
    }

    // MARK: Picking a window (AppKit's global space)

    func hoverWindow(at point: CGPoint) {
        guard target == .window else { return }
        let id = ScreencastWindowPicking.window(at: layout.topLeftPoint(fromAppKit: point), in: windows)?.id
        guard id != hoveredWindow else { return }
        hoveredWindow = id
        changed()
    }

    /// Picks the window under `point`; a click on no window keeps the one picked.
    func clickWindow(at point: CGPoint) {
        guard target == .window,
              let window = ScreencastWindowPicking.window(at: layout.topLeftPoint(fromAppKit: point), in: windows) else { return }
        hoveredWindow = window.id
        selectedWindow = window.id
        changed()
    }

    /// A pickable window's frame in AppKit's global space.
    func appKitFrame(of id: CGWindowID) -> CGRect? {
        windows.first { $0.id == id }.map { layout.appKitRect(fromTopLeft: $0.frame) }
    }

    private func changed() {
        onChange?()
    }
}
