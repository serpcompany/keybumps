import AppKit

/// A recording's review window (#475): a standard window, bigger than the panel, to watch the
/// recording with `AVPlayerView`'s own controls (play, pause, and scrubbing) beside the review.
///
/// Its shell is Snapzy's `VideoEditorWindow` (BSD-3-Clause, see LICENSE.snapzy): titled, closable,
/// miniaturizable, and resizable, its title bar blending into the window, at the normal level and in
/// the window cycle, with a minimum size. Unlike Snapzy's, closing it (`performClose`, as its close
/// button does) asks the review first (`onClose`), which saves the recording, and Space is the
/// review's key monitor's (`ScreencastReviewKey`). Like the panel, it can open over a full-screen app,
/// and it's never restored at launch. Under the unit-test host it never becomes key or main.
final class ScreencastRecordingReviewWindow: NSWindow {
    static let identifier = NSUserInterfaceItemIdentifier(ScreencastReviewID.window)
    /// Snapzy's editor opens at 1200 × 800; this one at a little less, fitted to the screen.
    static let defaultSize = CGSize(width: 1_100, height: 700)
    /// The sidebar and a player still big enough to watch.
    static let minimumSize = CGSize(width: 760, height: 500)
    /// Kept clear between the window and a screen too small for its default size.
    static let screenMargin: CGFloat = 20

    /// Closing: the review saves the recording, then closes the window.
    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        title = "Review Recording"
        titlebarAppearsTransparent = true
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
    }

    override var canBecomeKey: Bool { !UnitTestHost.isActive }
    override var canBecomeMain: Bool { !UnitTestHost.isActive }

    override func performClose(_ sender: Any?) {
        guard let onClose else { return super.performClose(sender) }
        onClose()
    }

    /// Centered on the screen's visible frame at the default size, or as much of it as fits inside
    /// `screenMargin`, and never smaller than the minimum size unless the screen is.
    static func frame(in visibleFrame: CGRect) -> CGRect {
        let room = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let width = max(min(defaultSize.width, room.width), min(minimumSize.width, visibleFrame.width))
        let height = max(min(defaultSize.height, room.height), min(minimumSize.height, visibleFrame.height))
        return CGRect(
            x: (visibleFrame.midX - width / 2).rounded(),
            y: (visibleFrame.midY - height / 2).rounded(),
            width: width,
            height: height
        )
    }
}

/// What a recording's review window says once the recording is saved or copied, and the folder its
/// Show in Finder reveals: "Saved · Documents › Keybumps › captures". Discard has none: the window
/// closes. It names folders only, never the note or a file, though it's never logged anyway.
struct ScreencastReviewConfirmation: Equatable {
    /// "Saved", or "Copied to Clipboard".
    let title: String
    /// The captures folder the capture is in, from the home folder: "Documents › Keybumps › captures".
    let place: String
    /// The capture's own folder, `<captures folder>/<timestamp>/`, which Show in Finder selects.
    let folder: URL

    var text: String { "\(title) · \(place)" }

    /// Nil until the review is done, and after Discard.
    init?(_ outcome: ScreencastReviewOutcome?, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        switch outcome {
        case .saved(let input):
            title = "Saved"
            folder = input.folder
        case .copied(let input):
            title = "Copied to Clipboard"
            folder = input.folder
        case .discarded, nil:
            return nil
        }
        place = Self.place(of: folder.deletingLastPathComponent(), home: home)
    }

    /// A folder's path as Finder's path bar names it, from the home folder when it's in it.
    static func place(of folder: URL, home: URL) -> String {
        let components = folder.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let homeComponents = home.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let inHome = components.count > homeComponents.count && components.starts(with: homeComponents)
        return components.dropFirst(inHome ? homeComponents.count : 0).joined(separator: " › ")
    }
}
