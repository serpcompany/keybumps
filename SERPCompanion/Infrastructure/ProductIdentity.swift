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
    static let statusItemImageName = "SERPMenuBarMark"
    static let inAppBrandImageName = "SERPArrow"
}

enum StatusItemBranding {
    static func configure(_ button: NSStatusBarButton, target: AnyObject, action: Selector) {
        guard let image = NSImage(named: ProductIdentity.statusItemImageName) else {
            assertionFailure("Missing SERP menu-bar image")
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
