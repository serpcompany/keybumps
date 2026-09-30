import AppKit
import CoreGraphics
import Foundation

/// Where a press or release lands, decided without Accessibility so that a click on Keybumps never
/// reaches a hit-test (#212).
enum ClickTarget: Equatable, Sendable {
    /// Keybumps' own windows, menus, sheets, and menu bar, and an open or save panel it shows. Never
    /// hit-tested, so Shortcut Coach never coaches a click inside Keybumps.
    case keybumps
    /// A window of another app, by process.
    case application(pid_t)
    /// Nothing that takes clicks.
    case nothing
}

protocol ClickTargetProbing {
    /// Called on the detection queue for each press and release. Sends no Accessibility message.
    /// `clickThrough` numbers Keybumps' windows that let clicks through to the window below, such as
    /// its notch panels; the window list can't tell them from windows that take clicks.
    func target(at point: CGPoint, clickThrough: Set<Int>) -> ClickTarget
}

/// Finds the frontmost window under the point in the Window Server's window list. The list needs no
/// permission for what's read here: owners, frames, layers, and alpha, never titles.
struct WindowListClickTargetProbe: ClickTargetProbing {
    /// AppKit's out-of-process open and save panel. Its window belongs to this service, which answers
    /// Accessibility on the main thread of the app showing the panel.
    static let openAndSavePanelService = "com.apple.appkit.xpc.openAndSavePanelService"

    var ownProcess = ProcessInfo.processInfo.processIdentifier
    /// On-screen windows, front to back.
    var windows: () -> [[String: Any]] = {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    }
    /// Nil for a process that isn't an app, such as the Window Server.
    var bundleIdentifier: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    /// `NSRunningApplication`, unlike `NSWorkspace.frontmostApplication`, is documented safe off the
    /// main thread.
    var frontmostApplication: () -> pid_t? = {
        NSWorkspace.shared.runningApplications.first(where: \.isActive)?.processIdentifier
    }

    func target(at point: CGPoint, clickThrough: Set<Int>) -> ClickTarget {
        guard let window = windows().first(where: { Self.takesClick($0, at: point, clickThrough: clickThrough) }),
              let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return .nothing }
        if owner == ownProcess { return .keybumps }
        switch bundleIdentifier(owner) {
        case nil:
            // The Window Server draws the menu bar, status items included, for the app in front.
            guard let frontmost = frontmostApplication() else { return .nothing }
            return frontmost == ownProcess ? .keybumps : .application(frontmost)
        case .some(Self.openAndSavePanelService) where frontmostApplication() == ownProcess:
            return .keybumps
        default:
            return .application(owner)
        }
    }

    /// The cursor, drag images, invisible windows, and Keybumps' click-through panels never take the
    /// click.
    private static func takesClick(_ window: [String: Any], at point: CGPoint, clickThrough: Set<Int>) -> Bool {
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.int32Value ?? 0
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue
        guard alpha > 0,
              number.map(clickThrough.contains) != true,
              layer != CGWindowLevelForKey(.draggingWindow),
              layer < CGWindowLevelForKey(.cursorWindow),
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return frame.contains(point)
    }
}
