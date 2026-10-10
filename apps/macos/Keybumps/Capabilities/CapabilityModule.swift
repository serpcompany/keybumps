import Foundation
import SwiftUI

// MARK: - Static contract

/// The static half of a capability module: identity, names, and what it contributes to the shared
/// app surfaces. Descriptors are plain values, so permission planning, palette tabs, and Settings
/// read them without an `AppModel`. `Capability` raw values stay the saved preference IDs.
struct CapabilityDescriptor: Identifiable {
    let capability: Capability
    let title: String
    let systemImage: String
    /// The fill of the capability's rounded-square icon tile in Settings.
    let iconTint: Color
    /// macOS permissions the module needs while enabled, granted through `PermissionCoordinator`.
    let requiredPermissions: Set<MacPermission>
    /// Modules that must be enabled for this module's resources to run.
    let dependencies: Set<Capability>
    let paletteTab: CapabilityPaletteTab?
    let settingsPage: CapabilitySettingsPage?
    /// Named app-owned operations the module reports to `UpdateInstallationSafetyPolicy`.
    let criticalOperations: Set<ApplicationCriticalOperation>
    /// Whether Quick Search offers a capability command for it, and the words besides its title that
    /// find it, such as its tab's name and what people call what it does ("dictate", "paste"). Nil
    /// means no capability command; an empty list means one found by its title alone. A keyword
    /// ranks the command after the apps, so it never hides an app with that name.
    let searchKeywords: [String]?
    /// Its plugin manifest's Store category.
    let category: PluginCategory
    var publisher: PluginPublisher = .keybumps
    /// Its declared settings, which its Settings page draws and `AppPreferences` stores.
    var preferences: [PluginPreference] = []
    /// Permissions it can use but doesn't need (`requiredPermissions` are the ones it needs).
    var optionalPermissions: [PluginOptionalPermission] = []
    /// Whether it's on in a new install, and turned on once in existing installs by the update that
    /// adds it. One that ships off is listed in Settings › Plugins with its switch off.
    var isOnByDefault = true
    /// The oldest macOS it runs on, as a major version such as 15; nil for every macOS Keybumps
    /// runs on. On an older Mac it's listed with "Requires macOS 15" and can't be turned on
    /// (`PluginCompatibility`).
    var minimumMacOS: Int?

    var id: Capability { capability }
}

/// A Command Palette tab a module owns. `dataSource` names another module when the tab lists that
/// module's data (the Screenshots tab filters Clipboard History entries).
struct CapabilityPaletteTab {
    let tab: CommandPaletteTab
    let name: String
    /// The Command-number that selects the tab; tabs appear in this order.
    let commandKey: Int
    let systemImage: String
    let prompt: String
    /// What Return does, shown first in the footer with ↵.
    let primaryActionTitle: String?
    /// The other keys the footer names after Return, with their keys, such as Paste ⌘P.
    let secondaryActions: [PaletteKeyAction]
    let dataSource: Capability?
}

/// A module's Settings destination. The section title is the capability title.
struct CapabilitySettingsPage {
    let section: SettingsSection
    /// The one line under the capability's name at the top of its page.
    let summary: String
    /// What turning the module off releases; the tooltip on its toolbar enable switch.
    let disableExplanation: String?
    let content: @MainActor () -> AnyView
}

/// Every registered module's descriptor.
enum CapabilityCatalog {
    /// Registry order. It is the order modules apply in and Quick Search lists their commands; a module
    /// follows every module it depends on, so a dependency is settled before its dependents read it.
    static let descriptors: [CapabilityDescriptor] = [
        .quickSearch, .clipboardHistory, .screenshotTools, .dictation, .windowManagement, .keyboardShortcutter, .snippets, .timer, .emojiPicker,
        .translation, .keystrokes,
    ]

    /// The default capabilities: the feature set Keybumps was locked at (#205). Every capability
    /// added since, starting with Timer, is an added capability, which Settings lists in its own
    /// group below them.
    static let defaultCapabilities: Set<Capability> = [
        .quickSearch, .clipboardHistory, .screenshotTools, .dictation, .windowManagement, .keyboardShortcutter, .snippets
    ]

    private static let byCapability = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.capability, $0) })

    private static let byPaletteTab = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
        descriptor.paletteTab.map { ($0.tab, (owner: descriptor.capability, tab: $0)) }
    })

    static func descriptor(for capability: Capability) -> CapabilityDescriptor {
        guard let descriptor = byCapability[capability] else {
            preconditionFailure("\(capability.rawValue) has no registered capability module")
        }
        return descriptor
    }

    /// Palette tabs in Command-number order.
    static var paletteTabs: [CapabilityPaletteTab] {
        descriptors.compactMap(\.paletteTab).sorted { $0.commandKey < $1.commandKey }
    }

    static func paletteTab(for tab: CommandPaletteTab) -> (owner: Capability, tab: CapabilityPaletteTab) {
        guard let entry = byPaletteTab[tab] else {
            preconditionFailure("\(tab.rawValue) has no owning capability module")
        }
        return entry
    }

    static func requiredPermissions(for enabledCapabilities: Set<Capability>) -> [MacPermission] {
        let required = enabledCapabilities.reduce(into: Set<MacPermission>()) {
            $0.formUnion(descriptor(for: $1).requiredPermissions)
        }
        return MacPermission.allCases.filter(required.contains)
    }
}

// MARK: - Runtime contract

/// The runtime half of a capability module. The app shell owns one instance per descriptor and
/// drives it through `CapabilityRegistry`; the module starts and stops the resources it owns and
/// registers its shortcuts only through `GlobalShortcutCoordinator`.
@MainActor
protocol CapabilityModule: AnyObject {
    var descriptor: CapabilityDescriptor { get }
    /// Registers or releases owned shortcuts and starts or stops owned resources for the enabled set.
    func apply(_ context: CapabilityContext)
    /// Runs immediately before the module is turned off: closes its surfaces and cancels its work.
    func deactivate(_ context: CapabilityContext)
    /// Resumes resources that were waiting on a permission after `PermissionCoordinator` re-reads macOS.
    func permissionsDidRefresh(_ context: CapabilityContext)
    /// Settings attention the module reports for its own page, including setup that isn't a
    /// TCC permission (for example Screenshot Tools' Requires Clipboard History).
    func attentionCount(_ context: CapabilityContext) -> Int
    /// The rows of the module's palette tab, when the module supplies them itself rather than
    /// through a case in `CommandPaletteController`.
    var paletteContent: (any CapabilityPaletteContent)? { get }
}

extension CapabilityModule {
    var capability: Capability { descriptor.capability }
    func permissionsDidRefresh(_ context: CapabilityContext) {}
    func attentionCount(_ context: CapabilityContext) -> Int { 0 }
    var paletteContent: (any CapabilityPaletteContent)? { nil }
}

/// What the shell hands a module each time it applies, deactivates, or refreshes it.
@MainActor
struct CapabilityContext {
    let enabledCapabilities: Set<Capability>
    let preferences: AppPreferences
    let shortcuts: GlobalShortcutCoordinator
    let permissions: PermissionCoordinator
    let permissionReadiness: (Set<Capability>) -> PermissionReadinessSnapshot

    func isEnabled(_ capability: Capability) -> Bool {
        enabledCapabilities.contains(capability)
    }

    /// Registers `binding` for `owner` while `capability` is enabled; otherwise releases the owner.
    func configureShortcut(
        owner: String,
        for capability: Capability,
        binding: ShortcutBinding?,
        handler: @escaping () -> Void
    ) {
        guard isEnabled(capability), let binding else {
            shortcuts.unregister(owner: owner)
            return
        }
        shortcuts.register(owner: owner, binding: binding, handler: handler)
    }
}

/// A module's view of update-installation safety, limited to the critical operations its
/// descriptor declares.
@MainActor
struct CapabilityUpdateSafety {
    let policy: UpdateInstallationSafetyPolicy
    let updater: any UpdateControlling
    let criticalOperations: Set<ApplicationCriticalOperation>

    init(policy: UpdateInstallationSafetyPolicy, updater: any UpdateControlling, descriptor: CapabilityDescriptor) {
        self.policy = policy
        self.updater = updater
        criticalOperations = descriptor.criticalOperations
    }

    func setCriticalOperation(_ operation: ApplicationCriticalOperation, active: Bool) {
        assert(criticalOperations.contains(operation), "Undeclared critical operation \(operation)")
        policy.updateCriticalOperation(operation, active: active)
        updater.installationSafetyDidChange()
    }

    func performSynchronously(_ operation: ApplicationCriticalOperation, _ body: () -> Void) {
        assert(criticalOperations.contains(operation), "Undeclared critical operation \(operation)")
        policy.performSynchronousCriticalOperation(
            operation,
            notify: updater.installationSafetyDidChange,
            operation: body
        )
    }

    func update(dictationPhase: DictationPhase) {
        policy.update(dictationPhase: dictationPhase)
        updater.installationSafetyDidChange()
    }
}

/// The app shell's registered modules, in `CapabilityCatalog` order.
@MainActor
final class CapabilityRegistry {
    let modules: [any CapabilityModule]
    private let byCapability: [Capability: any CapabilityModule]
    /// The palette tabs whose rows their modules supply, for `CommandPaletteController`.
    let paletteContents: [CommandPaletteTab: any CapabilityPaletteContent]

    init(modules: [any CapabilityModule]) {
        precondition(
            modules.map(\.capability) == CapabilityCatalog.descriptors.map(\.capability),
            "Register one module per catalog descriptor, in catalog order"
        )
        self.modules = modules
        byCapability = Dictionary(uniqueKeysWithValues: modules.map { ($0.capability, $0) })
        paletteContents = Dictionary(uniqueKeysWithValues: modules.compactMap { module in
            module.paletteContent.map { content in
                precondition(
                    content.tab == module.descriptor.paletteTab?.tab,
                    "\(module.capability) supplies rows for a tab it doesn't register"
                )
                return (content.tab, content)
            }
        })
    }

    func module(for capability: Capability) -> (any CapabilityModule)? {
        byCapability[capability]
    }

    func apply(_ context: CapabilityContext) {
        for module in modules { module.apply(context) }
    }

    func deactivate(_ capability: Capability, context: CapabilityContext) {
        module(for: capability)?.deactivate(context)
    }

    /// Runs in reverse registry order, the order the wiring used before modules existed: Keyboard
    /// Shortcutter retries its detector before Window Manager re-arms drag-to-snap.
    func permissionsDidRefresh(_ context: CapabilityContext) {
        for module in modules.reversed() { module.permissionsDidRefresh(context) }
    }

    func attentionCount(for capability: Capability, context: CapabilityContext) -> Int {
        module(for: capability)?.attentionCount(context) ?? 0
    }
}
