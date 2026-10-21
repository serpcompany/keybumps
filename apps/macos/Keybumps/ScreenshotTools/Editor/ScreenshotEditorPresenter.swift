import AppKit

/// Opens at most one editor, marks unsaved work for update safety while it is open,
/// and returns focus to the app the user came from when it closes.
///
/// An edited screenshot is a screenshot of its own (#605): Save writes it into ScreenGrabs'
/// history (`screenshotsFolder`), and `keepsEditedScreenshot` lists it and puts its copy where
/// macOS saves screenshots, as for a hotkey's (`ScreenshotClipboardDelivery.addEdited`). An edited
/// image that isn't a screenshot goes beside its file, else in `fallbackFolder`.
@MainActor
final class ScreenshotEditorPresenter {
    private var controller: ScreenshotEditorWindowController?
    private let fallbackFolder: () -> URL
    private let screenshotsFolder: () -> URL
    private let keepsEditedScreenshot: (URL) -> Void
    private let pasteboard: NSPasteboard
    private let editingChanged: (Bool) -> Void
    private let notice = PaletteHUD.shared

    init(
        fallbackFolder: @escaping () -> URL,
        screenshotsFolder: @escaping () -> URL,
        keepsEditedScreenshot: @escaping (URL) -> Void,
        pasteboard: NSPasteboard = .keybumps,
        editingChanged: @escaping (Bool) -> Void
    ) {
        self.fallbackFolder = fallbackFolder
        self.screenshotsFolder = screenshotsFolder
        self.keepsEditedScreenshot = keepsEditedScreenshot
        self.pasteboard = pasteboard
        self.editingChanged = editingChanged
    }

    var isEditing: Bool { controller != nil }

    @discardableResult
    func edit(_ entry: ClipboardEntry) -> Bool {
        if let controller {
            controller.present()
            return true
        }
        guard let controller = makeController(for: entry) else { return false }

        let previousApp = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        controller.onFinish = { [weak self] result in
            self?.controller = nil
            self?.editingChanged(false)
            previousApp?.activate()
            if result?.copied == true { self?.notice.show("Copied to Clipboard") }
        }
        self.controller = controller
        editingChanged(true)
        controller.present()
        return true
    }

    func close() {
        controller?.cancel()
    }

    /// The editor for `entry`, not yet shown, saving where `entry`'s edited copy goes; nil when it
    /// isn't an image that can be read.
    func makeController(for entry: ClipboardEntry) -> ScreenshotEditorWindowController? {
        guard entry.kind == .image,
              let imageURL = entry.imageURL,
              let data = try? Data(contentsOf: imageURL),
              let source = ScreenshotRenderSource(imageData: data) else { return nil }
        let isScreenshot = entry.isScreenshot
        let controller = ScreenshotEditorWindowController(
            source: source,
            sourceURL: entry.sourceURL,
            fallbackFolder: isScreenshot ? screenshotsFolder() : fallbackFolder(),
            savesBesideSource: !isScreenshot,
            pasteboard: pasteboard
        )
        if isScreenshot { controller.onSaved = keepsEditedScreenshot }
        return controller
    }
}
