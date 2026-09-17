import AppKit

enum ReleaseLane: String, CaseIterable {
    case full
    static let current = ReleaseLane.full
    var productName: String { "SuperMac" }
    var bundleIdentifier: String { "com.serp.supermac" }
    var supportsManualActionDetection: Bool { true }
    var showsFullVersionCTA: Bool { false }
}

enum ProductIdentity {
    static let legacyBundleIdentifiers: [String] = []
    static let statusItemImageName = "SuperMacMenuBarMark"
    static let inAppBrandImageName = "SuperMacArrow"
}

enum AppVersionDisplay {
    static func title(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown Version"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let build, !build.isEmpty else {
            return "\(ReleaseLane.current.productName) \(version)"
        }
        return "\(ReleaseLane.current.productName) \(version) (\(build))"
    }
}

enum StatusItemBranding {
    static func configure(_ button: NSStatusBarButton, target: AnyObject, action: Selector) {
        guard let image = NSImage(named: ProductIdentity.statusItemImageName) else {
            assertionFailure("Missing SuperMac menu-bar image")
            return
        }
        image.isTemplate = true
        image.size = NSSize(width: 17, height: 17)
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = ReleaseLane.current.productName
        button.setAccessibilityLabel(ReleaseLane.current.productName)
        button.target = target
        button.action = action
    }
}
