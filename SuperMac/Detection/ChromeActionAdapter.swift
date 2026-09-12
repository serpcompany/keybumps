import ApplicationServices
import CoreGraphics
import Foundation

enum ManualActionKind: Equatable, Sendable {
    case chromeNewTab
    case chromeCloseActiveTab(tabToken: String)
    case chromeSelectTab(tabToken: String, index: Int, tabCount: Int)
    case chromeSettings(shortcut: String)
}

struct ManualActionCandidate: Equatable, Sendable {
    let kind: ManualActionKind
    let applicationName: String
    let point: CGPoint
    let targetFrame: AXFrameSnapshot?
    let preSnapshot: AccessibilitySnapshot
    let preRuntime: ChromeRuntimeState
}

protocol ApplicationActionAdapter {
    func classify(_ snapshot: AccessibilitySnapshot, runtime: ChromeRuntimeState, point: CGPoint) -> ManualActionCandidate?
}

struct ChromeTabState: Codable, Equatable, Sendable {
    let containerToken: String
    let tabs: [AXNodeSnapshot]
}

enum LiveShortcutResolution: Codable, Equatable, Sendable {
    case resolved(String)
    case unavailable
    case ambiguous
}

enum ChromeNavigationDestination: String, Codable, Equatable, Sendable {
    case settings
    case other
    case unavailable
}

enum ChromeRuntimeRequirement: Equatable, Sendable {
    case none
    case tabs
    case settings
}

struct ChromeRuntimeState: Equatable, Sendable {
    var tabs: ChromeTabState?
    var settingsShortcut: LiveShortcutResolution
    var destination: ChromeNavigationDestination

    static let unavailable = ChromeRuntimeState(tabs: nil, settingsShortcut: .unavailable, destination: .unavailable)
}

protocol ChromeRuntimeStateReading {
    func read(pid: Int32, requirement: ChromeRuntimeRequirement) -> ChromeRuntimeState
}

struct ChromeMenuCommandObservation: Equatable, Sendable {
    let node: AXNodeSnapshot
    let enabled: Bool?
    let command: String?
    let modifiers: Int?
}

enum ChromeSettingsSemantics {
    static func isSettingsMenuItem(_ node: AXNodeSnapshot) -> Bool {
        guard node.role == kAXMenuItemRole as String else { return false }
        return [node.identifier, node.elementDescription, node.title]
            .compactMap(normalize)
            .contains(where: settingsTitles.contains)
    }

    static func isAddressField(role: String?, title: String?, description: String?, identifier: String?) -> Bool {
        guard role == kAXTextFieldRole as String else { return false }
        return [title, description, identifier].compactMap(normalizeCompact).contains {
            $0.contains("addressandsearchbar") || $0.contains("locationbar") || $0.contains("omnibox")
        }
    }

    static func resolveShortcut(from observations: [ChromeMenuCommandObservation]) -> LiveShortcutResolution {
        let matches = observations.filter { isSettingsMenuItem($0.node) }
        guard matches.count == 1, let match = matches.first else {
            return matches.isEmpty ? .unavailable : .ambiguous
        }
        guard match.enabled == true,
              let command = match.command, !command.isEmpty,
              let modifiers = match.modifiers,
              modifiers >= 0, modifiers & ~15 == 0 else { return .unavailable }
        return .resolved(ShortcutFormatter.format(command: command, modifiers: modifiers))
    }

    private static let settingsTitles: Set<String> = ["settings", "preferences"]

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".…")))
            .lowercased()
    }

    private static func normalizeCompact(_ value: String?) -> String? {
        normalize(value)?.replacingOccurrences(of: " ", with: "")
    }
}

struct SystemChromeRuntimeStateReader: ChromeRuntimeStateReading {
    func read(pid: Int32, requirement: ChromeRuntimeRequirement) -> ChromeRuntimeState {
        let application = AXUIElementCreateApplication(pid)
        switch requirement {
        case .none:
            return .unavailable
        case .tabs:
            guard let window = focusedWindow(of: application) else { return .unavailable }
            return ChromeRuntimeState(tabs: tabState(in: window), settingsShortcut: .unavailable, destination: .unavailable)
        case .settings:
            guard let window = focusedWindow(of: application) else { return .unavailable }
            return ChromeRuntimeState(
                tabs: nil,
                settingsShortcut: settingsShortcut(in: application),
                destination: navigationDestination(in: window)
            )
        }
    }

    private func settingsShortcut(in application: AXUIElement) -> LiveShortcutResolution {
        guard let menuBar: AXUIElement = attribute(kAXMenuBarAttribute, from: application) else { return .unavailable }
        var observations: [ChromeMenuCommandObservation] = []
        walk(from: menuBar, limit: 500) { element in
            let node = nodeSnapshot(element)
            observations.append(ChromeMenuCommandObservation(
                node: node,
                enabled: attribute(kAXEnabledAttribute, from: element),
                command: attribute(kAXMenuItemCmdCharAttribute, from: element),
                modifiers: (attribute(kAXMenuItemCmdModifiersAttribute, from: element) as NSNumber?)?.intValue
            ))
        }
        return ChromeSettingsSemantics.resolveShortcut(from: observations)
    }

    private func navigationDestination(in window: AXUIElement) -> ChromeNavigationDestination {
        var result = ChromeNavigationDestination.unavailable
        walk(from: window, limit: 500) { element in
            guard result == .unavailable,
                  ChromeSettingsSemantics.isAddressField(
                    role: attribute(kAXRoleAttribute, from: element),
                    title: attribute(kAXTitleAttribute, from: element),
                    description: attribute(kAXDescriptionAttribute, from: element),
                    identifier: attribute(kAXIdentifierAttribute, from: element)
                  ),
                  let address: String = attribute(kAXValueAttribute, from: element) else { return }
            result = address == "chrome://settings" || address.hasPrefix("chrome://settings/") ? .settings : .other
        }
        return result
    }

    private func tabState(in window: AXUIElement) -> ChromeTabState? {
        var result: ChromeTabState?
        walk(from: window, limit: 400) { element in
            guard result == nil else { return }
            let tabs = children(of: element).map(nodeSnapshot).filter {
                $0.role == kAXRadioButtonRole as String || $0.role == "AXTab"
            }
            guard !tabs.isEmpty, tabs.contains(where: { $0.selected == true || $0.value == "1" }) else { return }
            result = ChromeTabState(containerToken: token(for: element), tabs: tabs)
        }
        return result
    }

    private func walk(from root: AXUIElement, limit: Int, visit: (AXUIElement) -> Void) {
        var frontier = [root]
        var seen = Set<String>()
        while !frontier.isEmpty, seen.count < limit {
            let element = frontier.removeFirst()
            let elementToken = token(for: element)
            guard seen.insert(elementToken).inserted else { continue }
            visit(element)
            frontier.append(contentsOf: children(of: element))
        }
    }

    private func nodeSnapshot(_ element: AXUIElement) -> AXNodeSnapshot {
        let rawValue = copyAttribute(kAXValueAttribute, from: element)
        let value: String?
        if let string = rawValue as? String { value = string }
        else if let number = rawValue as? NSNumber { value = number.stringValue }
        else { value = nil }
        return AXNodeSnapshot(
            token: token(for: element), role: attribute(kAXRoleAttribute, from: element),
            subrole: attribute(kAXSubroleAttribute, from: element), title: attribute(kAXTitleAttribute, from: element),
            elementDescription: attribute(kAXDescriptionAttribute, from: element),
            identifier: attribute(kAXIdentifierAttribute, from: element), value: value,
            selected: (attribute(kAXSelectedAttribute, from: element) as Bool?) ?? ((rawValue as? NSNumber)?.boolValue),
            enabled: attribute(kAXEnabledAttribute, from: element), actions: [], frame: nil, menuShortcut: nil
        )
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, from: element) ?? []
    }

    private func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        attribute(kAXFocusedWindowAttribute, from: application)
    }

    private func token(for element: AXUIElement) -> String { String(CFHash(element), radix: 16) }
    private func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? { copyAttribute(name, from: element) as? T }
}

enum ChromeShortcutCatalog {
    // Static defaults are the explicit fallback characterized against this Chrome build.
    // A later slice can resolve equivalent visible menu items before using these values.
    static let characterizedChromeVersion = "153.0.8010.12"
    static let newTab = "⌘T"
    static let closeTab = "⌘W"
    static func selectTab(index: Int) -> String { index <= 8 ? "⌘\(index)" : "⌘9" }
}

struct ChromeActionAdapter: ApplicationActionAdapter {
    static let bundleIdentifiers: Set<String> = ["com.google.Chrome", "org.chromium.Chromium"]

    func contextRequirement(for snapshot: AccessibilitySnapshot) -> ChromeRuntimeRequirement {
        guard let bundle = snapshot.bundleIdentifier, Self.bundleIdentifiers.contains(bundle) else { return .none }
        return ChromeSettingsSemantics.isSettingsMenuItem(snapshot.hit) ? .settings : .tabs
    }

    func classify(_ snapshot: AccessibilitySnapshot, runtime: ChromeRuntimeState, point: CGPoint) -> ManualActionCandidate? {
        guard let bundle = snapshot.bundleIdentifier, Self.bundleIdentifiers.contains(bundle),
              snapshot.hit.enabled != false else { return nil }

        if ChromeSettingsSemantics.isSettingsMenuItem(snapshot.hit), snapshot.hit.actions.contains(kAXPressAction as String) {
            guard snapshot.hit.enabled == true else { return nil }
            guard case .resolved(let shortcut) = runtime.settingsShortcut,
                  runtime.destination == .other else { return nil }
            return candidate(.chromeSettings(shortcut: shortcut), snapshot, runtime, point)
        }

        guard let tabs = runtime.tabs else { return nil }

        if let tab = tabNode(in: snapshot) {
            if isCloseButton(snapshot.hit) {
                // Chrome's button descendant is safe only for the selected tab.
                guard tab.selected == true else { return nil }
                return candidate(.chromeCloseActiveTab(tabToken: tab.token), snapshot, runtime, point)
            }
            guard let index = tabs.tabs.firstIndex(where: { $0.token == tab.token }), tab.selected != true else { return nil }
            let oneBased = index + 1
            guard oneBased <= 8 || oneBased == tabs.tabs.count else { return nil }
            return candidate(.chromeSelectTab(tabToken: tab.token, index: oneBased, tabCount: tabs.tabs.count), snapshot, runtime, point)
        }

        if isNewTabButton(snapshot.hit), snapshot.hit.actions.contains(kAXPressAction as String) {
            return candidate(.chromeNewTab, snapshot, runtime, point)
        }
        return nil
    }

    private func tabNode(in snapshot: AccessibilitySnapshot) -> AXNodeSnapshot? {
        snapshot.hitAndAncestors.first { $0.role == kAXRadioButtonRole as String || $0.role == "AXTab" }
    }

    private func isNewTabButton(_ node: AXNodeSnapshot) -> Bool {
        guard node.role == kAXButtonRole as String else { return false }
        let semantic = [node.identifier, node.elementDescription, node.title]
            .compactMap { $0?.lowercased().replacingOccurrences(of: " ", with: "") }
        // Names are never sufficient alone: classification also requires bundle identity,
        // button role, AXPress, and a characterized tab container.
        return semantic.contains { value in
            value.contains("newtab") || value.contains("new-tab") || value == "nouvelonglet" || value == "neuertab"
        }
    }

    private func isCloseButton(_ node: AXNodeSnapshot) -> Bool {
        guard node.role == kAXButtonRole as String, node.actions.contains(kAXPressAction as String) else { return false }
        let semantic = [node.identifier, node.elementDescription, node.title]
            .compactMap { $0?.lowercased().replacingOccurrences(of: " ", with: "") }
        return semantic.contains { value in
            value.contains("closetab") || value.contains("tab-close") || value == "close" || value == "fermer" || value == "schließen"
        }
    }

    private func candidate(
        _ kind: ManualActionKind,
        _ snapshot: AccessibilitySnapshot,
        _ runtime: ChromeRuntimeState,
        _ point: CGPoint
    ) -> ManualActionCandidate {
        ManualActionCandidate(kind: kind, applicationName: snapshot.applicationName, point: point,
                              targetFrame: snapshot.hit.frame, preSnapshot: snapshot, preRuntime: runtime)
    }
}
