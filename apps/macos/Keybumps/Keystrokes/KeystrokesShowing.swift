import Foundation

/// Whether the Keystrokes plugin shows the keys while it's on: Quick Search's Show Keystrokes and
/// Hide Keystrokes (#468) turn that on and off without turning the plugin off, as its Show & Hide
/// Keystrokes shortcut does. Its members are exactly #457's stored show and hide
/// (`plugin.keystrokes.showing`), so `KeystrokesModule` conforms with nothing else once that lands.
@MainActor
protocol KeystrokesShowing: AnyObject {
    var isShowing: Bool { get }
    func setShowing(_ showing: Bool, announces: Bool)
    func toggleShowing(announces: Bool)
}

extension KeystrokesShowing {
    /// The action command's title: what picking it does now.
    var showingActionTitle: String { isShowing ? "Hide Keystrokes" : "Show Keystrokes" }
}

extension PluginAction {
    /// Quick Search's Show Keystrokes or Hide Keystrokes, named for what it does now
    /// (`KeystrokesShowing.showingActionTitle`).
    static let toggleKeystrokes = PluginAction(
        id: "toggleKeystrokes",
        title: "Show & Hide Keystrokes",
        keywords: ["show keystrokes", "hide keystrokes", "keys", "keycastr", "toggle"],
        systemImage: "eye",
        shortcut: .keystrokes
    )
}

extension KeystrokesModule: KeystrokesShowing {}

extension KeystrokesModule {
    func title(for action: PluginAction, _ context: CapabilityContext) -> String? {
        action == .toggleKeystrokes ? showingActionTitle : nil
    }

    /// Shows or hides the keys, with the shortcut's notch notice.
    func perform(_ action: PluginAction, _ context: CapabilityContext) {
        guard action == .toggleKeystrokes else { return }
        toggleShowing(announces: true)
    }
}
