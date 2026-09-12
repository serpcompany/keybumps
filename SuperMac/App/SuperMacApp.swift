import SwiftUI

@main
struct SuperMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(ReleaseLane.current.productName, id: "main") {
            SettingsRootView()
                .environment(model)
                .task {
                    model.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshPermissions()
                }
                .modifier(MainWindowRoutingModifier())
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

    func body(content: Content) -> some View {
        content
            .onAppear {
                NativeStatusItemController.shared.configureOpenMainWindow(openMainWindow)
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
