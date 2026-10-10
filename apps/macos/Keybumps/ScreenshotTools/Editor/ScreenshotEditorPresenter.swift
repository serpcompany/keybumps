import AppKit

/// Opens at most one editor, marks unsaved work for update safety while it is open,
/// and returns focus to the app the user came from when it closes.
@MainActor
final class ScreenshotEditorPresenter {
    private var controller: ScreenshotEditorWindowController?
    private let fallbackFolder: () -> URL
    private let editingChanged: (Bool) -> Void
    private let notice = PaletteHUD.shared

    init(fallbackFolder: @escaping () -> URL, editingChanged: @escaping (Bool) -> Void) {
        self.fallbackFolder = fallbackFolder
        self.editingChanged = editingChanged
    }

    var isEditing: Bool { controller != nil }

    @discardableResult
    func edit(_ entry: ClipboardEntry) -> Bool {
        if let controller {
            controller.present()
            return true
        }
        guard entry.kind == .image,
              let imageURL = entry.imageURL,
              let data = try? Data(contentsOf: imageURL),
              let source = ScreenshotRenderSource(imageData: data) else { return false }
        present(source, sourceURL: entry.sourceURL)
        return true
    }

    /// Opens the editor on an image file of its own, as Screencast's review panel does for a
    /// screenshot (#450); Save writes the `(edited)` copy beside it. While another image is being
    /// edited, it brings that editor forward and returns false. `onFinish` gets the edited copy's
    /// location after Save, and nil after Cancel or when the copy couldn't be saved.
    func editScreenshot(at url: URL, onFinish: @escaping (URL?) -> Void) -> Bool {
        if let controller {
            controller.present()
            return false
        }
        guard let data = try? Data(contentsOf: url), let source = ScreenshotRenderSource(imageData: data) else { return false }
        present(source, sourceURL: url) { onFinish($0?.savedURL) }
        return true
    }

    func close() {
        controller?.cancel()
    }

    private func present(
        _ source: ScreenshotRenderSource,
        sourceURL: URL?,
        then finished: ((ScreenshotEditorWindowController.Result?) -> Void)? = nil
    ) {
        let previousApp = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        let controller = ScreenshotEditorWindowController(
            source: source,
            sourceURL: sourceURL,
            fallbackFolder: fallbackFolder()
        )
        controller.onFinish = { [weak self] result in
            self?.controller = nil
            self?.editingChanged(false)
            previousApp?.activate()
            if result?.copied == true { self?.notice.show("Copied to Clipboard") }
            finished?(result)
        }
        self.controller = controller
        editingChanged(true)
        controller.present()
    }
}

extension ScreenshotEditorPresenter: ScreencastScreenshotEditing {}
