import SwiftUI

/// Launch arguments that let XCUITests reach surfaces without real permissions or global hot keys.
///
/// UI test mode starts only when `-KBUITestPermissions granted|denied` is present. Every other
/// flag is ignored outside UI test mode, so a production launch behaves exactly as before.
struct UITestLaunchConfiguration: Equatable {
    enum PermissionMode: String, Equatable {
        case granted
        case denied
    }

    static let permissionsArgument = "-KBUITestPermissions"
    static let openPaletteArgument = "-KBOpenPalette"
    static let openSettingsArgument = "-KBOpenSettings"
    static let disableHotKeysArgument = "-KBDisableHotKeys"
    static let seedClipboardImageArgument = "-KBUITestSeedClipboardImage"

    /// Release builds never read the flags, so the shipping app has no test mode.
    static let current: UITestLaunchConfiguration = {
        #if DEBUG
        UITestLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        #else
        UITestLaunchConfiguration(arguments: [])
        #endif
    }()

    private(set) var permissions: PermissionMode?
    private(set) var openPalette: CommandPaletteTab?
    private(set) var openSettings: SettingsSection?
    private(set) var disablesHotKeys = false
    private(set) var seedsClipboardImage = false

    var isUITesting: Bool { permissions != nil }

    init(arguments: [String]) {
        guard let mode = Self.value(after: Self.permissionsArgument, in: arguments)
            .flatMap(PermissionMode.init(rawValue:)) else { return }
        permissions = mode
        openPalette = Self.value(after: Self.openPaletteArgument, in: arguments)
            .flatMap(CommandPaletteTab.init(rawValue:))
        openSettings = Self.value(after: Self.openSettingsArgument, in: arguments)
            .flatMap(SettingsSection.init(launchToken:))
        disablesHotKeys = Self.flag(Self.disableHotKeysArgument, in: arguments)
        seedsClipboardImage = Self.flag(Self.seedClipboardImageArgument, in: arguments)
    }

    /// Accepts both `-Flag` and `-Flag YES`, since Foundation's argument domain pairs every `-key` with a value.
    private static func flag(_ name: String, in arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return true }
        return !["NO", "no", "false", "0"].contains(arguments[next])
    }

    private static func value(after name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return nil }
        return arguments[next]
    }
}

extension View {
    /// Turns off SwiftUI animations under UI test mode. Apply at every hosting root.
    func uiTestAnimationsDisabled() -> some View {
        transaction { transaction in
            if UITestLaunchConfiguration.current.isUITesting { transaction.disablesAnimations = true }
        }
    }
}

extension SettingsSection {
    /// Stable, title-independent token for launch arguments and accessibility identifiers.
    var launchToken: String { String(describing: self) }

    init?(launchToken: String) {
        guard let section = Self.allCases.first(where: {
            $0.launchToken.caseInsensitiveCompare(launchToken) == .orderedSame
        }) else { return nil }
        self = section
    }
}
