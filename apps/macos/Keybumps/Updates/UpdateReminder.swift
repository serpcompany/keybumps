import AppKit
import SwiftUI

/// Shows the restart prompt (#225).
@MainActor
protocol UpdatePromptPresenting: AnyObject {
    var isShowing: Bool { get }
    func show(version: String?, restart: @escaping () -> Void, later: @escaping () -> Void)
    func close()
}

enum UpdatePromptText {
    static func title(version: String?) -> String {
        version.map { "Keybumps \($0) is ready" } ?? "A Keybumps update is ready"
    }

    static let message = "Restart Keybumps to get the newest features and fixes. It takes a few seconds."
}

/// Asks to restart for a downloaded update, so nobody has to remember to (#225): as soon as an
/// update is ready and restarting is safe (`UpdateInstallationSafetyPolicy`, so never during
/// Dictation, an unsaved screenshot edit, or a window being moved) and the Command Palette is
/// closed, then again an hour after each Later, every hour until the restart. Restart Now clicked
/// while restarting isn't safe restarts as soon as it is. It never restarts unasked.
@MainActor
final class UpdateReminder {
    static let interval: TimeInterval = 60 * 60

    private let snapshot: () -> UpdateSnapshot
    private let isSafe: () -> Bool
    private let restart: () -> Void
    let presenter: any UpdatePromptPresenting
    private let now: () -> Date
    private var laterAt: Date?
    private var laterVersion: String?
    private var timer: Timer?
    /// While true, no new prompt appears: the Command Palette is open.
    var isSuppressed: () -> Bool = { false }
    /// Restart Now was clicked while restarting wasn't safe.
    private var restartRequested = false

    init(
        snapshot: @escaping () -> UpdateSnapshot,
        isSafe: @escaping () -> Bool,
        restart: @escaping () -> Void,
        presenter: any UpdatePromptPresenting,
        now: @escaping () -> Date = Date.init
    ) {
        self.snapshot = snapshot
        self.isSafe = isSafe
        self.restart = restart
        self.presenter = presenter
        self.now = now
    }

    /// Re-checks every minute, so an hour after Later, or the moment restarting becomes safe, it asks.
    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.evaluate() }
        }
        timer.tolerance = 10
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func evaluate() {
        let current = snapshot()
        let version = current.status.pendingVersion
        guard current.canRestart else {
            restartRequested = false
            if presenter.isShowing { presenter.close() }
            return
        }
        // Restart Now was clicked while restarting wasn't safe: restart as soon as it is.
        if restartRequested {
            if isSafe() {
                restartRequested = false
                restart()
            }
            return
        }
        // An open prompt stays where the user put it. Moments that aren't safe (Dictation, a window
        // being dragged or snapped) or the open palette only keep a new one from appearing.
        guard !presenter.isShowing, isSafe(), !isSuppressed() else { return }
        if let laterAt, laterVersion == version, now().timeIntervalSince(laterAt) < Self.interval { return }
        presenter.show(
            version: version,
            restart: { [weak self] in
                guard let self else { return }
                // A restart still looks available until Keybumps quits; don't ask meanwhile.
                laterAt = now()
                laterVersion = version
                presenter.close()
                if isSafe() {
                    restart()
                } else {
                    restartRequested = true
                }
            },
            later: { [weak self] in
                guard let self else { return }
                laterAt = now()
                laterVersion = version
                presenter.close()
            }
        )
    }
}

/// The restart prompt: a small floating panel above every app, on every Space and over full-screen
/// apps, so it can't be missed. It never takes keyboard focus and has no default button, so a key
/// meant for another app can't restart Keybumps: only a click does. Closing it counts as Later.
@MainActor
final class UpdatePromptWindowController: NSObject, UpdatePromptPresenting, NSWindowDelegate {
    private var window: NSPanel?
    private var later: (() -> Void)?

    /// True from show until close, even while Keybumps is hidden, so there's only ever one.
    var isShowing: Bool { window != nil }

    func show(version: String?, restart: @escaping () -> Void, later: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: UpdatePromptView(version: version, restart: restart, later: later))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.view.fittingSize),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = "Keybumps Update"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // ⌘H and Hide Others hide Keybumps' windows; this one stays.
        panel.canHide = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
        self.later = later
        panel.orderFrontRegardless()
    }

    func close() {
        later = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        let later = later
        self.later = nil
        window = nil
        later?()
    }
}

/// Never shows a window: unit tests and the UI-test composition.
@MainActor
final class InertUpdatePromptPresenter: UpdatePromptPresenting {
    var isShowing: Bool { false }
    func show(version: String?, restart: @escaping () -> Void, later: @escaping () -> Void) {}
    func close() {}
}

struct UpdatePromptView: View {
    let version: String?
    let restart: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                Text(UpdatePromptText.title(version: version))
                    .font(.system(size: 15, weight: .semibold))
                Text(UpdatePromptText.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // No keyboard shortcuts: the panel never has focus, and Return mustn't restart.
                HStack {
                    Spacer()
                    Button("Later", action: later)
                    Button("Restart Now", action: restart)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Shows the restart prompt and What's New on demand, so they can be checked before a release
/// ships them: only in QA candidates (`-dev.` versions) and Debug builds, launched with
/// `-KBPreviewUpdates YES`. The prompt's buttons only close it.
enum UpdatePreview {
    static let argument = "-KBPreviewUpdates"

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func isAllowed(version: String) -> Bool {
        isDebugBuild || version.contains("-dev.")
    }
}
