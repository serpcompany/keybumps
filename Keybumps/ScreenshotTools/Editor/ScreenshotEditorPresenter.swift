import AppKit

/// Opens at most one editor, marks unsaved work for update safety while it is open,
/// and returns focus to the app the user came from when it closes.
@MainActor
final class ScreenshotEditorPresenter {
    private var controller: ScreenshotEditorWindowController?
    private let fallbackFolder: () -> URL
    private let editingChanged: (Bool) -> Void
    private let notice = PaletteHUD()

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

        let previousApp = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        let controller = ScreenshotEditorWindowController(
            source: source,
            sourceURL: entry.sourceURL,
            fallbackFolder: fallbackFolder()
        )
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
}
