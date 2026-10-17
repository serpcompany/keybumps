import AppKit
import AVKit

/// The review window (#475): a standard window that all but fills the screen, to watch the
/// recording with `AVPlayerView`'s own controls (play, pause, and scrubbing), under the bar the
/// Screenshot Editor has too (#511, `ScreencastRecordingReviewBar`): Discard, Copy, and Save, Save
/// the window's default button, and nothing else around the player. It's titled "Edit Recording", as
/// the editor's is "Edit Screenshot".
///
/// Its shell is Snapzy's `VideoEditorWindow` (BSD-3-Clause, see LICENSE.snapzy): titled, closable,
/// miniaturizable, and resizable, at the normal level and in the window cycle, with a minimum size.
/// Unlike Snapzy's, closing it (`performClose`, as its close button does) asks the review first
/// (`onClose`), which saves the recording, and Space is the review's key monitor's
/// (`ScreencastReviewKey`). It can open over a full-screen app, and it's never restored at launch.
/// Under the unit-test host it never becomes key or main.
final class ScreencastRecordingReviewWindow: NSWindow {
    static let identifier = NSUserInterfaceItemIdentifier(ScreencastReviewID.window)
    /// A player still big enough to watch, and the bar's three tools (#517) and buttons.
    static let minimumSize = CGSize(width: 760, height: 400)
    /// Kept clear between the window and the edges of the screen's visible frame.
    static let screenMargin: CGFloat = 16

    /// Closing: the review saves the recording, then closes the window.
    var onClose: (() -> Void)?
    /// Whether the bar's controls may take the keyboard: not as the window opens, so Space plays the
    /// recording even with Keyboard Navigation on, which gives the first button the keyboard. The
    /// first Tab or Shift-Tab lets them (`ScreencastReviewKey.tab`); the next recording takes it back.
    var barTakesKeyboard = false

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        title = "Edit Recording"
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
    }

    override var canBecomeKey: Bool { !UnitTestHost.isActive }
    override var canBecomeMain: Bool { !UnitTestHost.isActive }

    /// Refuses the bar the keyboard until `barTakesKeyboard`. SwiftUI's buttons aren't views, so a
    /// focused one makes the content view, the bar's host, the first responder.
    @discardableResult
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if !barTakesKeyboard, barHas(responder) { return false }
        return super.makeFirstResponder(responder)
    }

    override func performClose(_ sender: Any?) {
        guard let onClose else { return super.performClose(sender) }
        onClose()
    }

    /// Whether `responder` is one of the bar's controls, or in one: where Full Keyboard Access's Tab
    /// puts the keyboard. Everything in the window's content but the player is the bar's, the content
    /// view too, which has the keyboard for whichever SwiftUI button has it.
    func barHas(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView, let contentView, view.isDescendant(of: contentView) else { return false }
        return !sequence(first: view, next: \.superview).contains { $0 is AVPlayerView }
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
}
