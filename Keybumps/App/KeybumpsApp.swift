import SwiftUI

@main
@MainActor
enum KeybumpsMain {
    /// Whether this process launched the app itself. Debug unit tests are hosted by Keybumps.app, so
    /// under XCTest a bare `NSApplication` runs instead: tests build their own compositions, and the
    /// host never composes `AppModel` against the real `com.serp.keybumps` preferences, registers
    /// global hot keys, installs the status item, or monitors the real pasteboard.
    private(set) static var launchedApp = false

    static func main() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApplication.shared.run()
            return
        }
        #endif
        launchedApp = true
        KeybumpsApp.main()
    }
}

struct KeybumpsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.forLaunch()

    var body: some Scene {
        Window(ReleaseLane.current.productName, id: "main") {
            SettingsRootView()
                .environment(model)
                .task {
                    model.start()
                    model.performUITestLaunchActions()
                }
                .uiTestAnimationsDisabled()
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.applicationDidBecomeActive()
                    Task { await model.refreshNotificationPermission() }
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
        }
        .defaultSize(width: 920, height: 640)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenMainWindowButton(title: "Settings…")
                    .keyboardShortcut(",", modifiers: .command)
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
                QuickSearchRouter.shared.configure(model.showQuickSearch)
                AppShellRouter.shared.configure { destination in
                    switch destination {
                    case .keyboardShortcutterHistory:
                        model.showKeyboardShortcutterHistory()
                    }
                }
                NativeStatusItemController.shared.configureQuickSearch(
                    isVisible: { model.isQuickSearchVisible },
                    setVisible: model.setQuickSearchVisible
                )
                NativeStatusItemController.shared.configureUpdater(
                    snapshot: { model.updateSnapshot },
                    checkNow: model.checkForUpdates,
                    restartWhenSafe: model.restartToUpdate
                )
                NativeStatusItemController.shared.install()
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
