import AppKit

@MainActor
protocol AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool)
}

@MainActor
struct AppPresenceController: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {
        let policy: NSApplication.ActivationPolicy = showInDockAndSwitcher ? .regular : .accessory
        NSApplication.shared.setActivationPolicy(policy)
        if showInDockAndSwitcher {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

