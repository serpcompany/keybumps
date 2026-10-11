import AppKit
import ScreenCaptureKit

/// What the picker reads from the screen, behind a seam: ScreenCaptureKit in the app
/// (`ScreenCaptureKitPickerSystem`), a fake in tests, and an inert one in the unit-test host, so no
/// test reads the screen or asks for Screen Recording. Errors it throws are `ScreencastFailure`s.
@MainActor
protocol ScreencastPickerSystem: AnyObject {
    /// What's on screen now, windows front to back.
    func content() async throws -> ScreencastContent

    /// The windows on screen the window server draws fully transparent (alpha 0), which can't be
    /// picked: some apps keep invisible ordinary windows over others.
    func transparentWindows() -> Set<CGWindowID>
}

/// The app's picker system: the recorder's `SCShareableContent` read, with its windows put front to
/// back.
@available(macOS 15, *)
@MainActor
final class ScreenCaptureKitPickerSystem: ScreencastPickerSystem {
    /// The real system, except in the unit-test host.
    static var current: any ScreencastPickerSystem {
        UnitTestHost.isActive ? InertScreencastPickerSystem() : ScreenCaptureKitPickerSystem()
    }

    func content() async throws -> ScreencastContent {
        let content = try await ScreenCaptureKitCaptureSystem().content()
        let order = Dictionary(Self.windowList().enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Windows the window server doesn't list on screen go last; the picker skips them anyway.
        let windows = content.windows.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
        return ScreencastContent(
            displays: content.displays,
            windows: windows,
            applicationProcessIDs: content.applicationProcessIDs,
            source: content.source
        )
    }

    func transparentWindows() -> Set<CGWindowID> {
        Set(Self.windowList().filter { $0.alpha == 0 }.map(\.id))
    }

    /// The window server's on-screen windows, front to back: their numbers and alpha only, never a
    /// name or an owner.
    static func windowList() -> [(id: CGWindowID, alpha: Double)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (CGWindowID(number.uint32Value), (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }
}

/// A picker system that reads nothing: the unit-test host's default.
@MainActor
final class InertScreencastPickerSystem: ScreencastPickerSystem {
    func content() async throws -> ScreencastContent {
        throw ScreencastFailure.captureFailed
    }

    func transparentWindows() -> Set<CGWindowID> { [] }
}
