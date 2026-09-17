import SwiftUI

@main
struct SuperMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window(ReleaseLane.current.productName, id: "main") {
            SettingsRootView()
                .environment(model)
                .task {
                    model.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshPermissions()
                    Task { await model.refreshNotificationPermission() }
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
