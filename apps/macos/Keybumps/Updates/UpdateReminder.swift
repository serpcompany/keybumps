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
/// Dictation or an unsaved screenshot edit) and the Command Palette is closed, then again an hour
/// after each Later, every hour until the restart. It closes itself while those stop holding, and it
/// never restarts on its own.
@MainActor
final class UpdateReminder {
    static let interval: TimeInterval = 60 * 60

    private let snapshot: () -> UpdateSnapshot
    private let isSafe: () -> Bool
    private let restart: () -> Void
    private let presenter: any UpdatePromptPresenting
    private let now: () -> Date
    private var laterAt: Date?
    private var laterVersion: String?
    private var timer: Timer?
    /// While true, the prompt waits: the Command Palette is open, so it never takes its keys.
    var isSuppressed: () -> Bool = { false }

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
        guard current.canRestart, isSafe(), !isSuppressed() else {
            // Restart Now couldn't work now, or the palette needs the keys: it comes back, not as a Later.
            if presenter.isShowing { presenter.close() }
            return
        }
        guard !presenter.isShowing else { return }
        if let laterAt, laterVersion == version, now().timeIntervalSince(laterAt) < Self.interval { return }
        presenter.show(
            version: version,
            restart: { [weak self] in
                guard let self else { return }
                // A restart still looks available until Keybumps quits; don't ask meanwhile.
                laterAt = now()
                laterVersion = version
                presenter.close()
                restart()
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
