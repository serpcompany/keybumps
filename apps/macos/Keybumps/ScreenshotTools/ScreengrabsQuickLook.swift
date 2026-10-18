import AppKit
import QuickLookUI

/// Space in the ScreenGrabs tab (#494): the highlighted screengrab's files in Quick Look, a recording
/// of every screen's videos one after another (← and →). Tests pass their own.
@MainActor
protocol ScreengrabsQuickLooking: AnyObject {
    func preview(_ files: [URL])
}

/// macOS's Quick Look panel, adapted from Screendrop's `QuickLookPreviewPresenter` (CC0-1.0, see
/// `LICENSE.screendrop`): Keybumps comes to the front before the panel shows, so the panel has the
/// keyboard and a video plays at once, and the panel is fed directly as its data source. The palette
/// never takes the front, so the app that had it gets it back once the panel closes, unless another
/// Keybumps window has the keyboard by then. Under the unit-test host it shows nothing.
@MainActor
final class ScreengrabsQuickLook: NSObject, ScreengrabsQuickLooking, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ScreengrabsQuickLook()

    private var files: [NSURL] = []
    /// The app in front before Keybumps took it for the panel.
    private var previousApp: pid_t?
    private let front: ScreencastReviewFront

    init(front: ScreencastReviewFront = .app) {
        self.front = front
    }

    func preview(_ files: [URL]) {
        guard !UnitTestHost.isActive, !files.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.files = files.map { $0 as NSURL }
        if let app = front.otherAppInFront() { previousApp = app }
        // Before the panel shows, so macOS counts Keybumps as the app in front; otherwise the panel
        // opens without the keyboard, and a video waits for a click to play.
        NSApp.activate()
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        // Again on the next turn: the window server can drop a makeKey that comes right after an
        // activation.
        DispatchQueue.main.async { panel.makeKeyAndOrderFront(nil) }
    }

    /// The panel closed itself: Space, Escape, its close button, or another app coming to the front.
    func windowWillClose(_ notification: Notification) {
        files = []
        guard let previousApp else { return }
        self.previousApp = nil
        // Once the panel is gone, so a Keybumps window that took the keyboard in its place keeps it.
        DispatchQueue.main.async { [front] in
            if front.keybumpsIsActive(), NSApp.keyWindow == nil { front.activate(previousApp) }
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { files.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { files.indices.contains(index) ? files[index] : nil }
    }
}
