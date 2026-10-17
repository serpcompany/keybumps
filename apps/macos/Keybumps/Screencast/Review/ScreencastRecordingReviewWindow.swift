import AppKit
import SwiftUI

/// The review window (#475): a standard window that all but fills the screen, to watch the
/// recording with `AVPlayerView`'s own controls (play, pause, and scrubbing), with Discard, Copy,
/// and Save in its compact toolbar and nothing else around the player. Save is the toolbar's
/// prominent item, the window's default button.
///
/// Its shell is Snapzy's `VideoEditorWindow` (BSD-3-Clause, see LICENSE.snapzy): titled, closable,
/// miniaturizable, and resizable, at the normal level and in the window cycle, with a minimum size.
/// Unlike Snapzy's, closing it (`performClose`, as its close button does) asks the review first
/// (`onClose`), which saves the recording, and Space is the review's key monitor's
/// (`ScreencastReviewKey`). It can open over a full-screen app, and it's never restored at launch.
/// Under the unit-test host it never becomes key or main.
final class ScreencastRecordingReviewWindow: NSWindow, NSToolbarDelegate {
    static let identifier = NSUserInterfaceItemIdentifier(ScreencastReviewID.window)
    /// A player still big enough to watch, and the toolbar's buttons.
    static let minimumSize = CGSize(width: 640, height: 400)
    /// Kept clear between the window and the edges of the screen's visible frame.
    static let screenMargin: CGFloat = 16

    /// Closing: the review saves the recording, then closes the window.
    var onClose: (() -> Void)?

    /// A toolbar item per control, each showing its part of the review.
    private let parts: [ScreencastRecordingReviewToolbar.Part: NSHostingView<ScreencastRecordingReviewToolbar>] =
        Dictionary(uniqueKeysWithValues: ScreencastRecordingReviewToolbar.Part.allCases.map { part in
            (part, NSHostingView(rootView: ScreencastRecordingReviewToolbar(model: nil, part: part)))
        })
    /// The review the toolbar acts on.
    private weak var shownModel: ScreencastReviewModel?

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        title = "Recording"
        minSize = Self.minimumSize
        isReleasedWhenClosed = false
        // Nothing to put back at launch: quitting saves the review.
        isRestorable = false
        // An ordinary window: the normal level, and in ⌘` cycling. It also opens over a full-screen
        // app, so stopping a recording of one doesn't move to a desktop Space.
        level = .normal
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        tabbingMode = .disallowed
        identifier = Self.identifier
        setAccessibilityIdentifier(ScreencastReviewID.window)

        let toolbar = NSToolbar(identifier: "screencast.review.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
        // A title shown in a unified toolbar takes the room the flexible spaces would, which pushes
        // Discard over to Copy and Save. The toolbar's middle shows it instead.
        titleVisibility = .hidden
    }

    override var canBecomeKey: Bool { !UnitTestHost.isActive }
    override var canBecomeMain: Bool { !UnitTestHost.isActive }

    override func performClose(_ sender: Any?) {
        guard let onClose else { return super.performClose(sender) }
        onClose()
    }

    /// Puts `model`'s Discard, title and display picker, Copy, and Save in the toolbar.
    func showActions(for model: ScreencastReviewModel) {
        shownModel = model
        for (part, view) in parts {
            view.rootView = ScreencastRecordingReviewToolbar(model: model, part: part)
        }
        followDiscardQuestion(of: model)
    }

    /// Whether `responder` is one of the toolbar's controls, or in one: where Full Keyboard Access's
    /// Tab puts the keyboard.
    func toolbarHas(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return parts.values.contains { view.isDescendant(of: $0) }
    }

    /// Hides the items whose parts make way for the discard question, and shows them again after,
    /// so no empty item shape stays in the toolbar. Before macOS 15, which can't hide an item, a
    /// part not shown is empty, and its item has no shape of its own.
    private func followDiscardQuestion(of model: ScreencastReviewModel) {
        let isConfirming = withObservationTracking {
            model.isConfirmingDiscard
        } onChange: { [weak self, weak model] in
            // Told before the change: look again once it's made.
            Task { @MainActor in
                guard let self, let model, self.shownModel === model else { return }
                self.followDiscardQuestion(of: model)
            }
        }
        guard #available(macOS 15, *) else { return }
        for item in toolbar?.items ?? [] {
            guard let part = Self.part(for: item.itemIdentifier) else { continue }
            item.isHidden = !part.isShown(confirmingDiscard: isConfirming)
        }
    }

    /// The screen's visible frame (the menu bar and Dock left out), but `screenMargin` on each side,
    /// never smaller than the minimum size unless the screen is, and centered on it.
    static func frame(in visibleFrame: CGRect) -> CGRect {
        let room = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let width = max(room.width, min(minimumSize.width, visibleFrame.width))
        let height = max(room.height, min(minimumSize.height, visibleFrame.height))
        return CGRect(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: (visibleFrame.midY - height / 2).rounded(),
            width: width,
            height: height
        )
    }

    // MARK: The toolbar

    /// The toolbar item showing `part`.
    static func identifier(for part: ScreencastRecordingReviewToolbar.Part) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("screencast.review.toolbar.\(part)")
    }

    private static func part(for identifier: NSToolbarItem.Identifier) -> ScreencastRecordingReviewToolbar.Part? {
        ScreencastRecordingReviewToolbar.Part.allCases.first { self.identifier(for: $0) == identifier }
    }

    /// Discard (or its question, Keep, and Discard) on the left, the title (and the display picker)
    /// in the middle, Copy and Save on the right.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.identifier(for: .discard), Self.identifier(for: .question), Self.identifier(for: .keep),
            Self.identifier(for: .confirmDiscard), .flexibleSpace, Self.identifier(for: .title), .flexibleSpace,
            Self.identifier(for: .copy), Self.identifier(for: .save),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let part = Self.part(for: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = parts[part]
        switch part {
        case .title, .question:
            // Words, not buttons: no button shape around them.
            item.isBordered = false
        case .save:
            // The window's default button, tinted with the accent color, as a toolbar's Done is.
            // Before macOS 26 its own button style (`.borderedProminent`) shows that.
            if #available(macOS 26, *) { item.style = .prominent }
        case .confirmDiscard:
            if #available(macOS 26, *) {
                item.style = .prominent
                item.backgroundTintColor = .systemRed
            }
        case .discard, .keep, .copy:
            break
        }
        return item
    }
}
