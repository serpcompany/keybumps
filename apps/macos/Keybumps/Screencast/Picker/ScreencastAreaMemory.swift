import CoreGraphics
import Foundation

/// The last area chosen, so the picker opens with it drawn, ready to record again or adjust.
///
/// After Snapzy's `RecordingCoordinator.saveLastAreaRect` and `loadLastAreaRect`
/// (`Snapzy/Features/Recording/RecordingCoordinator.swift`, BSD-3-Clause, see LICENSE.snapzy): the
/// rect in AppKit's global space as four numbers, dropped when no connected screen shows it, and
/// kept only for an area, never a window or every screen (`RecordingDisplaySelectionLogic
/// .shouldSaveLastArea`). It's a rect on screen, nothing more, so it's no user content.
struct ScreencastAreaMemory {
    static let key = "screencast.lastArea"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func save(_ rect: CGRect) {
        defaults.set(
            ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)],
            forKey: Self.key
        )
    }

    /// The remembered area on the screen showing most of it, cut to fit that screen. Nil when none
    /// is remembered, no screen shows it (the display it was on is gone), or what's left of it is
    /// smaller than an area can be.
    func area(in layout: ScreencastScreenLayout) -> ScreencastPickedArea? {
        guard let stored = defaults.dictionary(forKey: Self.key),
              let x = Self.number(stored["x"]), let y = Self.number(stored["y"]),
              let width = Self.number(stored["width"]), let height = Self.number(stored["height"]) else { return nil }
        let rect = CGRect(x: x, y: y, width: width, height: height).standardized
        guard let screen = layout.screen(mostOverlapping: rect) else { return nil }
        let fitted = rect.intersection(screen.frame)
        guard fitted.width >= ScreencastAreaEditor.minimumSize, fitted.height >= ScreencastAreaEditor.minimumSize else { return nil }
        return ScreencastPickedArea(display: screen.id, rect: fitted)
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return CGFloat(number.doubleValue)
    }
}
