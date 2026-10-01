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
    static let closeSettingsArgument = "-KBCloseSettings"
    static let disableHotKeysArgument = "-KBDisableHotKeys"
    static let seedClipboardImageArgument = "-KBUITestSeedClipboardImage"
    static let seedRecentKeybumpsArgument = "-KBUITestSeedRecentKeybumps"
    static let seedSnippetsArgument = "-KBUITestSeedSnippets"
    static let licenseStateArgument = "-KBLicenseState"

    /// The fixed license state a UI test starts in (`active` unless `-KBLicenseState` says otherwise).
    enum LicenseStateMode: String, Equatable {
        case active
        case unlicensed
        case revoked
    }

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
    /// With `openPalette`, closes Settings before the palette opens, so a test can show that an
    /// action opens it.
    private(set) var closesSettings = false
    private(set) var disablesHotKeys = false
    private(set) var seedsClipboardImage = false
    /// Adds the running app itself as the one Recent Item, which Quick Search must hide; the app
    /// under test isn't in `/Applications` for Quick Search to find.
    private(set) var seedsRecentKeybumps = false
    /// Adds three made-up plain snippets, so a test can select several.
    private(set) var seedsSnippets = false
    private(set) var licenseState: LicenseStateMode = .active

    var isUITesting: Bool { permissions != nil }

    init(arguments: [String]) {
        guard let mode = Self.value(after: Self.permissionsArgument, in: arguments)
            .flatMap(PermissionMode.init(rawValue:)) else { return }
        permissions = mode
        openPalette = Self.value(after: Self.openPaletteArgument, in: arguments)
            .flatMap(CommandPaletteTab.init(rawValue:))
        openSettings = Self.value(after: Self.openSettingsArgument, in: arguments)
            .flatMap(SettingsSection.init(launchToken:))
        closesSettings = Self.flag(Self.closeSettingsArgument, in: arguments)
        disablesHotKeys = Self.flag(Self.disableHotKeysArgument, in: arguments)
        seedsClipboardImage = Self.flag(Self.seedClipboardImageArgument, in: arguments)
        seedsRecentKeybumps = Self.flag(Self.seedRecentKeybumpsArgument, in: arguments)
        seedsSnippets = Self.flag(Self.seedSnippetsArgument, in: arguments)
        licenseState = Self.value(after: Self.licenseStateArgument, in: arguments)
            .flatMap(LicenseStateMode.init(rawValue:)) ?? .active
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
