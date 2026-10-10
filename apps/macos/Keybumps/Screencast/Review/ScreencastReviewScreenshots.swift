import AppKit

/// Clipboard History's screenshot items, which the Command Palette's Screenshots tab (⌘3) lists.
/// The review panel's "Also add to Screenshots (⌘3)" puts a saved screenshot there.
/// `ClipboardHistoryService` is the one in the app; there's none while Clipboard History is off.
@MainActor
protocol ScreencastScreenshotsLibrary: AnyObject {
    /// Adds the image file as a screenshot item from Screencast, as Screenshot Tools adds a new
    /// screenshot, without touching the pasteboard. The file stays where it is.
    func addScreencastScreenshot(at url: URL)
}

extension ClipboardHistoryService: ScreencastScreenshotsLibrary {
    func addScreencastScreenshot(at url: URL) {
        ingestImageFile(at: url, isScreenCapture: true, sourceApp: .screencast)
    }
}

extension ClipboardSourceApp {
    /// What a screenshot item added from Screencast's review panel says it's from.
    static var screencast: ClipboardSourceApp {
        ClipboardSourceApp(bundleIdentifier: Bundle.main.bundleIdentifier, name: "Screencast")
    }
}

/// What the review panel remembers between captures: its "Also add to Screenshots (⌘3)" switch,
/// on until the person turns it off. It's stored as `plugin.screencast.addsToScreenshots`, the name
/// a declared Screencast preference with that key would have. Tests pass `InMemoryDefaults`.
struct ScreencastReviewSettings {
    static let addsToScreenshotsKey = "plugin.screencast.addsToScreenshots"

    let defaults: UserDefaults

    var addsToScreenshots: Bool {
        get { defaults.object(forKey: Self.addsToScreenshotsKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.addsToScreenshotsKey) }
    }
}
