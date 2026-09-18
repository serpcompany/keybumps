import AppKit
import ApplicationServices
import Foundation

struct AXFrameSnapshot: Codable, Equatable, Sendable {
    let x: Double, y: Double, width: Double, height: Double
    func contains(_ point: CGPoint, tolerance: Double = 2) -> Bool {
        point.x >= x - tolerance && point.x <= x + width + tolerance &&
        point.y >= y - tolerance && point.y <= y + height + tolerance
    }
}

struct AXNodeSnapshot: Codable, Equatable, Sendable {
    let token: String
    let role: String?
    let subrole: String?
    let title: String?
    let elementDescription: String?
    let identifier: String?
    let value: String?
    let selected: Bool?
    let enabled: Bool?
    let actions: [String]
    let frame: AXFrameSnapshot?
    let menuShortcut: String?
    let menuShortcutEvidence: AXShortcutEvidence?

    init(
        token: String,
        role: String?,
        subrole: String?,
        title: String?,
        elementDescription: String?,
        identifier: String?,
        value: String?,
        selected: Bool?,
        enabled: Bool?,
        actions: [String],
        frame: AXFrameSnapshot?,
        menuShortcut: String?,
        menuShortcutEvidence: AXShortcutEvidence? = nil
    ) {
        self.token = token
        self.role = role
        self.subrole = subrole
        self.title = title
        self.elementDescription = elementDescription
        self.identifier = identifier
        self.value = value
        self.selected = selected
        self.enabled = enabled
        self.actions = actions
        self.frame = frame
        self.menuShortcut = menuShortcut
        self.menuShortcutEvidence = menuShortcutEvidence
    }
}

struct AccessibilitySnapshot: Codable, Equatable, Sendable {
    let pid: Int32
    let bundleIdentifier: String?
    let applicationVersion: String?
    let applicationName: String
    let hit: AXNodeSnapshot
    let ancestors: [AXNodeSnapshot]
    var hitAndAncestors: [AXNodeSnapshot] { [hit] + ancestors }

    init(
        pid: Int32,
        bundleIdentifier: String?,
        applicationVersion: String? = nil,
        applicationName: String,
        hit: AXNodeSnapshot,
        ancestors: [AXNodeSnapshot]
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.applicationVersion = applicationVersion
        self.applicationName = applicationName
        self.hit = hit
        self.ancestors = ancestors
    }
}

protocol AccessibilitySnapshotting {
    func snapshot(at point: CGPoint, completion: @escaping (AccessibilitySnapshot?) -> Void)
}

final class AccessibilitySnapshotter: AccessibilitySnapshotting {
    // AppKit's in-process accessibility implementation is main-thread-bound.
    // A global click can land on SuperMac itself, so all AX hit-testing
    // must share the main queue rather than racing from detector worker queues.
    private let queue = DispatchQueue.main

    func snapshot(at point: CGPoint, completion: @escaping (AccessibilitySnapshot?) -> Void) {
        queue.async {
            let result = self.makeSnapshot(at: point)
            completion(result)
        }
    }

    private func makeSnapshot(at point: CGPoint) -> AccessibilitySnapshot? {
        var rawHit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &rawHit) == .success,
              let hit = rawHit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleIdentifier = app?.bundleIdentifier
        let applicationVersion = app?.bundleURL
            .flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        var ancestors: [(AXUIElement, AXNodeSnapshot)] = []
        var cursor = hit
        for _ in 0..<8 {
            guard let parent: AXUIElement = attribute(kAXParentAttribute, from: cursor) else { break }
            let node = nodeSnapshot(parent)
            ancestors.append((parent, node))
            cursor = parent
            if node.role == kAXApplicationRole as String { break }
        }
        let hitSnapshot = nodeSnapshot(hit)
        return AccessibilitySnapshot(pid: pid, bundleIdentifier: bundleIdentifier, applicationVersion: applicationVersion,
                                     applicationName: app?.localizedName ?? "Current app",
                                     hit: hitSnapshot, ancestors: ancestors.map(\.1))
    }

    private func nodeSnapshot(_ element: AXUIElement) -> AXNodeSnapshot {
        let position = pointAttribute(kAXPositionAttribute, from: element)
        let size = sizeAttribute(kAXSizeAttribute, from: element)
        let selected: Bool? = attribute(kAXSelectedAttribute, from: element)
        let rawValue = copyAttribute(kAXValueAttribute, from: element)
        let valueString: String?
        if let string = rawValue as? String { valueString = string }
        else if let number = rawValue as? NSNumber { valueString = number.stringValue }
        else { valueString = nil }
        var actionNames: CFArray?
        let actions = AXUIElementCopyActionNames(element, &actionNames) == .success ? (actionNames as? [String] ?? []) : []
        let shortcutEvidence = AXShortcutEvidenceReader.read(from: element)
        return AXNodeSnapshot(
            token: token(for: element), role: attribute(kAXRoleAttribute, from: element),
            subrole: attribute(kAXSubroleAttribute, from: element), title: attribute(kAXTitleAttribute, from: element),
            elementDescription: attribute(kAXDescriptionAttribute, from: element), identifier: attribute(kAXIdentifierAttribute, from: element),
            value: valueString, selected: selected ?? ((rawValue as? NSNumber)?.boolValue),
            enabled: attribute(kAXEnabledAttribute, from: element), actions: actions.sorted(),
            frame: position.flatMap { origin in size.map { AXFrameSnapshot(x: origin.x, y: origin.y, width: $0.width, height: $0.height) } },
            menuShortcut: KeyboardShortcutRegistry.resolve(shortcutEvidence)?.displayString,
            menuShortcutEvidence: shortcutEvidence
        )
    }

    private func token(for element: AXUIElement) -> String { String(CFHash(element), radix: 16) }
    private func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? { copyAttribute(name, from: element) as? T }
    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        guard let raw = copyAttribute(name, from: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &result) ? result : nil
    }
    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        guard let raw = copyAttribute(name, from: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &result) ? result : nil
    }
}
