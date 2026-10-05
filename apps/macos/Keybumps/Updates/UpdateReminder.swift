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
/// Dictation or an unsaved screenshot edit), then again an hour after each Later, every hour until
/// the restart. A newer update asks right away. It never restarts on its own.
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
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func evaluate() {
        let current = snapshot()
        guard current.canRestart else {
            if presenter.isShowing { presenter.close() }
            return
        }
        let version = current.status.pendingVersion
        guard !presenter.isShowing, isSafe() else { return }
        if let laterAt, laterVersion == version, now().timeIntervalSince(laterAt) < Self.interval { return }
        presenter.show(
            version: version,
            restart: { [weak self] in
                self?.presenter.close()
                self?.restart()
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

/// The restart prompt: a small floating window that brings Keybumps forward, so it can't be missed.
/// Closing it with its close button counts as Later.
@MainActor
final class UpdatePromptWindowController: NSObject, UpdatePromptPresenting, NSWindowDelegate {
    private var window: NSWindow?
    private var later: (() -> Void)?

    var isShowing: Bool { window?.isVisible == true }

    func show(version: String?, restart: @escaping () -> Void, later: @escaping () -> Void) {
        let view = UpdatePromptView(version: version, restart: restart, later: later)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Keybumps Update"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.later = later
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
                HStack {
                    Spacer()
                    Button("Later", action: later)
                        .keyboardShortcut(.cancelAction)
                    Button("Restart Now", action: restart)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
