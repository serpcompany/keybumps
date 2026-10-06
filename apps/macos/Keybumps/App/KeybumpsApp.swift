import SwiftUI

@main
@MainActor
enum KeybumpsMain {
    /// Whether this process launched the app itself. Debug unit tests are hosted by Keybumps.app, so
    /// under XCTest a bare `NSApplication` runs instead: tests build their own compositions, and the
    /// host never composes `AppModel` against its preferences (`com.serp.keybumps.debug`), registers
    /// global hot keys, installs the status item, or monitors the real pasteboard.
    private(set) static var launchedApp = false

    static func main() {
        if UnitTestHost.isActive {
            NSApplication.shared.run()
            return
        }
        launchedApp = true
        CrashReporter.startIfAllowed()
        // Even with reports off, so a QA candidate can show that nothing is sent.
        CrashReportTest.runIfRequested()
        KeybumpsApp.main()
    }
}

struct KeybumpsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel.forLaunch()
        _model = State(initialValue: model)
        // macOS can relaunch Keybumps at login with no window, so start at launch rather than when
        // the main window first appears.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppShellLaunch.start(model) }
        }
    }

    /// The size Settings takes when macOS has none saved and it has already filled the screen once
    /// (`SettingsWindowFiller`); never larger than the screen, which macOS doesn't fit a new window's
    /// width to.
    private static var defaultSize: CGSize {
        SettingsWindowSize.defaultContentSize(fitting: NSScreen.main?.visibleFrame.size)
    }

    /// Never taller or wider than the space the menu bar and Dock leave, so the window always ends
    /// above the Dock (#294).
    private static var minimumSize: CGSize {
        SettingsWindowSize.minimumContentSize(fitting: NSScreen.main?.visibleFrame.size)
    }

    var body: some Scene {
        Window(ReleaseLane.current.productName, id: "main") {
            SettingsRootView()
                .frame(
                    minWidth: Self.minimumSize.width, idealWidth: Self.defaultSize.width,
                    minHeight: Self.minimumSize.height, idealHeight: Self.defaultSize.height
                )
                .environment(model)
                .task {
                    AppShellLaunch.start(model)
                    model.performUITestLaunchActions()
                }
                .uiTestAnimationsDisabled()
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.applicationDidBecomeActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.applicationDidResignActive()
                }
                .alert(
                    "Restart Keybumps to finish setup",
                    isPresented: $model.isPermissionRelaunchPromptPresented,
                    presenting: model.relaunchPromptPermission
                ) { _ in
                    Button("Not Now", role: .cancel) { model.dismissPermissionRelaunchPrompt() }
                    Button("Restart Keybumps") { model.restartForPermissionRelaunch() }
                } message: { permission in
                    Text("macOS has not made \(permission.title) available to this running copy of Keybumps. Restart now to finish setup.")
                }
                .modifier(MainWindowRoutingModifier(model: model))
                .background(SettingsEscapeCloser())
                .background(SettingsWindowFiller(preferences: model.preferences))
        }
        .defaultSize(Self.defaultSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenMainWindowButton(title: "Settings…")
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Report a Problem…") { model.showProblemReport() }
            }
        }

    }
}

private struct MainWindowRoutingModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .onAppear {
                MainWindowRouter.shared.configure(openMainWindow)
                AppShellLaunch.start(model)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openMainWindow()
            }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct OpenMainWindowButton: View {
    let title: String

    var body: some View {
        Button(title) {
            MainWindowRouter.shared.open()
        }
    }
}

/// Everything Keybumps needs to run, none of which depends on a window: capabilities and global
/// shortcuts, the status item, and the Dock and Quick Search routes. Runs once.
@MainActor
enum AppShellLaunch {
    private static var didStart = false

    static func start(_ model: AppModel) {
        guard !didStart else { return }
        didStart = true
        model.start()
        QuickSearchRouter.shared.configure(model.showQuickSearch)
        NativeStatusItemController.shared.configureQuickSearch(
            isVisible: { model.isQuickSearchVisible },
            setVisible: model.setQuickSearchVisible,
            shortcut: { model.preferences.capabilityShortcut(for: .quickSearch) }
        )
        NativeStatusItemController.shared.configureUpdater(
            snapshot: { model.updateSnapshot },
            checkNow: model.checkForUpdates,
            restartWhenSafe: model.restartToUpdate
        )
        NativeStatusItemController.shared.configureProblemReport(model.showProblemReport)
        NativeStatusItemController.shared.configureAttention(model.menuBarAttention)
        NativeStatusItemController.shared.configureStatus(model.menuBarStatus)
        NativeStatusItemController.shared.install()
        model.menuBarAttention.onChange = { NativeStatusItemController.shared.refreshMenuBarItem() }
        model.menuBarStatus.onChange = { NativeStatusItemController.shared.refreshMenuBarItem() }
        NativeStatusItemController.shared.refreshMenuBarItem()
    }
}
