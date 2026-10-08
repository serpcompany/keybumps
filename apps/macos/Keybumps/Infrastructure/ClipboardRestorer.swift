import AppKit

/// Puts the clipboard back after Keybumps pastes through it, once the app in front has had time to
/// read the paste, unless something else was copied meanwhile. Keyword expansion, the Command
/// Palette's pastes, and Dictation's insert share one restorer, so quick pastes in a row, from any
/// of them, put back the clipboard from before the first.
@MainActor
final class ClipboardRestorer {
    private let pasteboard: NSPasteboard
    /// The clipboard from before the first of a run of pastes, still waiting to be put back, and
    /// the clipboard's change count right after the last paste.
    private var pendingSnapshot: PasteboardSnapshot?
    private var pendingChangeCount: Int?
    /// The restore waiting out `delay`; tests await it.
    private(set) var pendingRestore: Task<Void, Never>?

    /// How long to wait before putting the clipboard back, so the app in front has read the paste.
    var delay: Duration = .milliseconds(500)
    /// Called right after the clipboard is put back, so Clipboard History skips that change.
    var didRestore: () -> Void = {}

    init(pasteboard: NSPasteboard = .keybumps) {
        self.pasteboard = pasteboard
    }

    /// The clipboard to put back after the paste about to be written: the one still waiting from an
    /// earlier paste when nothing was copied since, else the clipboard as it is now.
    func clipboardBeforePaste() -> PasteboardSnapshot {
        if pendingChangeCount == pasteboard.changeCount, let pendingSnapshot { return pendingSnapshot }
        return PasteboardSnapshot(pasteboard)
    }

    /// Runs `paste`, which writes the clipboard, then puts back the clipboard from before it, as
    /// `restore` does. A paste that fails before writing leaves the clipboard alone; one that fails
    /// after writing still puts it back.
    func restoreAfter(_ paste: () throws -> Void) rethrows {
        let previous = clipboardBeforePaste()
        let changeCount = pasteboard.changeCount
        do {
            try paste()
        } catch {
            if pasteboard.changeCount != changeCount { restore(previous) }
            throw error
        }
        restore(previous)
    }

    /// Puts `snapshot` back after `delay`, unless something else is copied first. Call it right
    /// after the paste wrote the clipboard; it replaces any restore still waiting.
    func restore(_ snapshot: PasteboardSnapshot) {
        pendingRestore?.cancel()
        pendingSnapshot = snapshot
        let changeCount = pasteboard.changeCount
        pendingChangeCount = changeCount
        let delay = delay
        pendingRestore = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pendingSnapshot = nil
            self.pendingChangeCount = nil
            self.pendingRestore = nil
            guard self.pasteboard.changeCount == changeCount else { return }
            snapshot.restore(to: self.pasteboard)
            self.didRestore()
        }
    }
}
