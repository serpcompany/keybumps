import CoreGraphics
import Foundation
import Observation

/// A screen choice in the picker's bar that the pointer is over.
enum ScreencastScreenPreview: Equatable, Sendable {
    case screen(CGDirectDisplayID)
    case all
}

/// What the picker chooses on screen.
enum ScreencastPickerTarget: String, CaseIterable, Equatable, Sendable {
    /// An area dragged on one screen.
    case area
    /// A window clicked.
    case window
    /// A screen chosen in the bar or clicked, or all screens, one file each.
    case screen
}

/// What the picker's Record chose: everything the countdown, the recording, and the
/// pieces around it (#448's control bar, #449's overlays) need.
struct ScreencastChoice: Equatable, Sendable {
    /// Where the target is on one display.
    struct Region: Equatable, Sendable {
        let display: CGDirectDisplayID
        /// In AppKit's global space: the area, the window's part of that screen, or the whole screen.
        let frame: CGRect
    }

    var target: ScreencastTarget
    /// One per display it shows on, in display order. The countdown shows on these, and the
    /// shortcuts only on these displays.
    var regions: [Region]
    /// The area and its screen, for the highlight while it records; nil for a window or every screen.
    var area: ScreencastPickedArea?
    /// The sounds to record.
    var audio: ScreencastAudio
    /// Whether the shortcuts pressed show on screen while it records.
    var showsShortcuts: Bool
    /// Whether clicks are highlighted while it records.
    var highlightsClicks: Bool
}

/// The picker's state, shared by its windows (one per screen) and its bar: area, window, or every
/// screen, the area drawn or the window picked, and the switches. The switches are the settings',
/// which Record saves (`switches`). It opens on the mode and screen last recorded
/// (`ScreencastPickerMemory`), with no window picked.
@MainActor
@Observable
final class ScreencastPickerModel {
    /// Switching keeps the area drawn and the window picked, so switching back finds them.
    var target: ScreencastPickerTarget = .screen {
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
    /// The microphone's setting, kept while its switch has to stay off.
    private let microphoneSetting: Bool

    let layout: ScreencastScreenLayout
    /// The screen the pointer was on at Start Screencast, or else the main one, read once: the bar
    /// shows on it, and Screen mode starts with it chosen unless the choice last taken is there.
    let pointerScreen: ScreencastScreen?
    /// Screen mode's choice when the picker opened, kept when Record is pressed in another mode.
    private let rememberedScreen: ScreencastPickerChoices.Screen?
    /// Windows that can be picked, front to back (`ScreencastWindowPicking`). Empty until what's on
    /// screen has been read, and when it can't be.
    var windows: [ScreencastContent.Window] = [] {
        didSet {
            if let selectedWindow, !windows.contains(where: { $0.id == selectedWindow }) { self.selectedWindow = nil }
            changed()
        }
    }

    /// The window under the pointer, which a click would choose: none over the bar.
    private(set) var hoveredWindow: CGWindowID?
    /// The window clicked, which Record records. Only a click on another window changes it: never
    /// the pointer moving, and never the bar.
    private(set) var selectedWindow: CGWindowID?
    /// The bar's frame in AppKit's global space, once it's laid out. The pointer over it is on the
    /// bar, never on a window under it, and a press on it changes no choice (`press`).
    @ObservationIgnored var barFrame: CGRect?
    /// The screen chosen in Screen mode; nil for all screens. At first the one last chosen while
    /// it's connected, or All Screens while there's more than one, or else `pointerScreen`.
    private(set) var selectedScreen: CGDirectDisplayID?
    /// The choice the pointer is over in the bar's screen choices, which the screens show until it
    /// leaves.
    private(set) var previewedScreens: ScreencastScreenPreview?
    private(set) var areaEditor: ScreencastAreaEditor?

    /// Runs after anything the windows draw changes, so they redraw. The bar observes the model.
    @ObservationIgnored var onChange: (() -> Void)?

    init(
        layout: ScreencastScreenLayout,
        preferences: ScreencastPreferences,
        microphoneAvailable: Bool,
        remembered: ScreencastPickerChoices = ScreencastPickerChoices(),
        rememberedArea: ScreencastPickedArea? = nil,
        pointerScreen: CGDirectDisplayID? = nil
    ) {
        self.layout = layout
        self.microphoneAvailable = microphoneAvailable
        microphoneSetting = preferences.recordsMicrophone
        recordsMicrophone = preferences.recordsMicrophone && microphoneAvailable
        recordsSystemAudio = preferences.recordsSystemAudio
        showsShortcuts = preferences.showsShortcuts
        highlightsClicks = preferences.highlightsClicks
        let startScreen = pointerScreen.flatMap { layout.screen($0) } ?? layout.screens.first
        self.pointerScreen = startScreen
        rememberedScreen = remembered.screen
        switch remembered.screen {
        case .all? where layout.screens.count > 1:
            selectedScreen = nil
        case .display(let uuid)?:
            selectedScreen = layout.screen(uuid: uuid)?.id ?? startScreen?.id
        default:
            selectedScreen = startScreen?.id
        }
        if let rememberedArea, let screen = layout.screen(rememberedArea.display) {
            areaEditor = ScreencastAreaEditor(rect: rememberedArea.rect, bounds: screen.frame)
        }
        target = remembered.target
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
            if let id = selectedScreen, let screen = layout.screen(id) {
                "Records all of \(layout.title(of: screen))."
            } else {
                "Records all screens, one file each."
            }
        }
    }

    /// Whether Screen mode offers All Screens: with more than one screen.
    var offersEveryScreen: Bool { layout.screens.count > 1 }

    /// The switches as Record saves them, for the settings. Without Microphone access the
    /// microphone's switch is off and can't be changed, so its setting stays as it was.
    var switches: ScreencastSwitches {
        ScreencastSwitches(
            recordsMicrophone: microphoneAvailable ? recordsMicrophone : microphoneSetting,
            recordsSystemAudio: recordsSystemAudio,
            showsShortcuts: showsShortcuts,
            highlightsClicks: highlightsClicks
        )
    }

    /// What the next picker opens with (`ScreencastPickerMemory`). Never the window, and the screen
    /// only from Screen mode, so a recording in another mode keeps the screen last chosen there. A
    /// screen macOS gives no UUID is remembered as none, so the next picker starts on the pointer's.
    var choicesToRemember: ScreencastPickerChoices {
        var choices = ScreencastPickerChoices(target: target, screen: rememberedScreen)
        if target == .screen {
            if let id = selectedScreen {
                choices.screen = layout.screen(id)?.uuid.map { .display(uuid: $0) }
            } else {
                choices.screen = .all
            }
        }
        return choices
    }

    /// What Record would capture now, or nil while nothing is chosen.
    func choice() -> ScreencastChoice? {
        let audio = ScreencastAudio(microphone: recordsMicrophone && microphoneAvailable, systemAudio: recordsSystemAudio)
        func make(_ target: ScreencastTarget, regions: [ScreencastChoice.Region], area: ScreencastPickedArea? = nil) -> ScreencastChoice {
            ScreencastChoice(
                target: target, regions: regions, area: area, audio: audio,
                showsShortcuts: showsShortcuts, highlightsClicks: highlightsClicks
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
            let screens = layout.orderedScreens
            guard let first = screens.first else { return nil }
            let target: ScreencastTarget = screens.count == 1 ? .display(first.id) : .everyDisplay
            return make(target, regions: screens.map { .init(display: $0.id, frame: $0.frame) })
        }
    }

    /// Whether Screen mode would capture `screen`: the one chosen, or all screens.
    func isChosen(_ screen: ScreencastScreen) -> Bool {
        selectedScreen == nil || selectedScreen == screen.id
    }

    /// Whether Screen mode shows `screen` as what's recorded: the choice the pointer is over in the
    /// bar, or else what's chosen.
    func isLit(_ screen: ScreencastScreen) -> Bool {
        switch previewedScreens {
        case .all: true
        case .screen(let id): id == screen.id
        case nil: isChosen(screen)
        }
    }

    // MARK: A press on a screen (AppKit's global space)

    /// A press on `screen`'s part of the picker, the only way a press reaches a choice: in Area it
    /// draws, moves, or resizes the area, in Window it chooses the window under it, and in Screen it
    /// chooses that screen. Says whether it records: a double click in the area, on a window, or on
    /// a screen. A press on the bar does none of it, in every mode: the bar's controls take their
    /// own clicks, and one it passes on (its padding, the hint, the gaps) stops here. With no
    /// gesture started, the drag and release that follow do nothing either.
    func press(at point: CGPoint, on screen: ScreencastScreen, clickCount: Int) -> Bool {
        if isOnBar(point) { return false }
        switch target {
        case .area:
            if clickCount == 2, let area, area.rect.contains(point) { return true }
            pressArea(at: point, on: screen)
            return false
        case .window:
            return clickWindow(at: point) && clickCount == 2
        case .screen:
            clickScreen(screen)
            return clickCount == 2
        }
    }

    /// Whether `point` is on the bar, never on what's under it.
    private func isOnBar(_ point: CGPoint) -> Bool {
        barFrame?.contains(point) == true
    }

    // MARK: Choosing a screen

    /// Screen mode: a click on a screen chooses it.
    func clickScreen(_ screen: ScreencastScreen) {
        guard target == .screen else { return }
        chooseScreen(screen.id)
    }

    /// One of the bar's screen choices: just this screen.
    func chooseScreen(_ id: CGDirectDisplayID) {
        guard layout.screen(id) != nil, selectedScreen != id else { return }
        selectedScreen = id
        changed()
    }

    /// The bar's All Screens, with more than one screen.
    func chooseEveryScreen() {
        guard offersEveryScreen, selectedScreen != nil else { return }
        selectedScreen = nil
        changed()
    }

    /// The pointer moved onto a screen choice in the bar, or off them (nil).
    func previewScreens(_ preview: ScreencastScreenPreview?) {
        guard previewedScreens != preview else { return }
        previewedScreens = preview
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

    /// Notes the window under the pointer, if any, which only previews it: the window picked stays.
    /// Over the bar, it's on no window.
    func hoverWindow(at point: CGPoint) {
        guard target == .window else { return }
        let id = isOnBar(point) ? nil : window(at: point)?.id
        guard id != hoveredWindow else { return }
        hoveredWindow = id
        changed()
    }

    /// Picks the window under `point`, and says whether there was one. A click on no window keeps
    /// the one picked; `press` keeps the bar's clicks from reaching here.
    @discardableResult
    func clickWindow(at point: CGPoint) -> Bool {
        guard target == .window, let window = window(at: point) else { return false }
        hoveredWindow = window.id
        selectedWindow = window.id
        changed()
        return true
    }

    private func window(at point: CGPoint) -> ScreencastContent.Window? {
        ScreencastWindowPicking.window(at: layout.topLeftPoint(fromAppKit: point), in: windows)
    }

    /// A pickable window's frame in AppKit's global space.
    func appKitFrame(of id: CGWindowID) -> CGRect? {
        windows.first { $0.id == id }.map { layout.appKitRect(fromTopLeft: $0.frame) }
    }

    private func changed() {
        onChange?()
    }
}
