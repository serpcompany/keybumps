import AppKit
import SwiftUI

/// A recording's review window (#475): a standard window that all but fills the screen, to watch
/// the recording with `AVPlayerView`'s own controls (play, pause, and scrubbing), with Discard,
/// Copy, and Save in its compact toolbar and nothing else around the player.
///
/// Its shell is Snapzy's `VideoEditorWindow` (BSD-3-Clause, see LICENSE.snapzy): titled, closable,
/// miniaturizable, and resizable, at the normal level and in the window cycle, with a minimum size.
/// Unlike Snapzy's, closing it (`performClose`, as its close button does) asks the review first
/// (`onClose`), which saves the recording, and Space is the review's key monitor's
/// (`ScreencastReviewKey`). Like the panel, it can open over a full-screen app, and it's never
/// restored at launch. Under the unit-test host it never becomes key or main.
final class ScreencastRecordingReviewWindow: NSWindow, NSToolbarDelegate {
    static let identifier = NSUserInterfaceItemIdentifier(ScreencastReviewID.window)
    /// A player still big enough to watch, and the toolbar's buttons.
    static let minimumSize = CGSize(width: 640, height: 400)
    /// Kept clear between the window and the edges of the screen's visible frame.
    static let screenMargin: CGFloat = 16

    private static let leadingItem = NSToolbarItem.Identifier("screencast.review.toolbar.leading")
    private static let middleItem = NSToolbarItem.Identifier("screencast.review.toolbar.middle")
    private static let trailingItem = NSToolbarItem.Identifier("screencast.review.toolbar.trailing")

    /// Closing: the review saves the recording, then closes the window.
    var onClose: (() -> Void)?

    private let leadingPart = NSHostingView(rootView: ScreencastRecordingReviewToolbar(model: nil, part: .leading))
    private let middlePart = NSHostingView(rootView: ScreencastRecordingReviewToolbar(model: nil, part: .middle))
    private let trailingPart = NSHostingView(rootView: ScreencastRecordingReviewToolbar(model: nil, part: .trailing))

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
        // app, as the panel did, so stopping a recording of one doesn't move to a desktop Space.
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
    }

    override var canBecomeKey: Bool { !UnitTestHost.isActive }
    override var canBecomeMain: Bool { !UnitTestHost.isActive }

    override func performClose(_ sender: Any?) {
        guard let onClose else { return super.performClose(sender) }
        onClose()
    }

    /// Puts `model`'s Discard, display picker, Copy, and Save in the toolbar.
    func showActions(for model: ScreencastReviewModel) {
        leadingPart.rootView = ScreencastRecordingReviewToolbar(model: model, part: .leading)
        middlePart.rootView = ScreencastRecordingReviewToolbar(model: model, part: .middle)
        trailingPart.rootView = ScreencastRecordingReviewToolbar(model: model, part: .trailing)
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

    /// Discard on the left, the display picker in the middle, Copy and Save on the right.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.leadingItem, .flexibleSpace, Self.middleItem, .flexibleSpace, Self.trailingItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let view: NSView
        switch itemIdentifier {
        case Self.leadingItem: view = leadingPart
        case Self.middleItem: view = middlePart
        case Self.trailingItem: view = trailingPart
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = view
        return item
    }
}
