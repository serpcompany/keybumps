import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum FinderTrashItemEligibility: String, Codable, Equatable, Sendable {
    case supportedRegularItem
    case multipleSelection
    case volume
    case alias
    case lockedOrImmutable
    case externalOrNetwork
    case readOnly
    case unknown
}

enum FinderTrashPostcondition: String, Codable, Equatable, Sendable {
    case removedFromOriginalParent
    case stillPresent
    case inaccessible
}

struct DragDropTrace: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let itemEligibility: FinderTrashItemEligibility
    let releasedOnDockTrash: Bool
    let meaningfulDrag: Bool
    let modifiersPresent: Bool
    let postcondition: FinderTrashPostcondition
}

struct FinderItemFacts: Equatable, Sendable {
    let isFileURL: Bool
    let isRegularFile: Bool?
    let isDirectory: Bool?
    let isSymbolicLink: Bool?
    let isAliasFile: Bool?
    let isVolume: Bool?
    let isWritable: Bool?
    let volumeIsLocal: Bool?
    let volumeIsInternal: Bool?
    let volumeIsRemovable: Bool?
    let volumeIsEjectable: Bool?
    let volumeIsReadOnly: Bool?
    let isUserImmutable: Bool?
    let isSystemImmutable: Bool?
}

struct DragDropActionDetector {
    static let currentSchemaVersion = 1
    private static let userModifierFlags: CGEventFlags = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
        .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn
    ]

    static func hasDisallowedModifiers(_ flags: CGEventFlags) -> Bool {
        if !flags.intersection(userModifierFlags).isEmpty { return true }
        let allowedBookkeepingBits = CGEventFlags.maskNonCoalesced.rawValue
        return flags.rawValue & ~(userModifierFlags.rawValue | allowedBookkeepingBits) != 0
    }

    static func eligibility(for facts: FinderItemFacts) -> FinderTrashItemEligibility {
        guard facts.isFileURL else { return .unknown }
        if facts.isVolume == true { return .volume }
        guard facts.isVolume == false else { return .unknown }
        if facts.isAliasFile == true || facts.isSymbolicLink == true { return .alias }
        guard facts.isAliasFile == false, facts.isSymbolicLink == false else { return .unknown }
        if facts.isUserImmutable == true || facts.isSystemImmutable == true { return .lockedOrImmutable }
        guard facts.isUserImmutable == false, facts.isSystemImmutable == false else { return .unknown }
        guard facts.volumeIsLocal == true,
              facts.volumeIsInternal == true,
              facts.volumeIsRemovable == false,
              facts.volumeIsEjectable == false else { return .externalOrNetwork }
        guard facts.isWritable == true, facts.volumeIsReadOnly == false else { return .readOnly }
        guard facts.isRegularFile == true || facts.isDirectory == true else { return .unknown }
        return .supportedRegularItem
    }

    func detect(_ trace: DragDropTrace) -> CoachingEvent? {
        guard trace.schemaVersion == Self.currentSchemaVersion,
              trace.itemEligibility == .supportedRegularItem,
              trace.releasedOnDockTrash,
              trace.meaningfulDrag,
              !trace.modifiersPresent,
              trace.postcondition == .removedFromOriginalParent else { return nil }
        return CoachingEvent(applicationName: "Finder", actionTitle: "Move to Trash", shortcut: "⌘⌫")
    }
}

final class FinderTrashMonitor {
    private enum SelectionStatus { case exactlyOne, multiple, unknown }

    private final class Session {
        let source: AXUIElement
        let parent: AXUIElement?
        let itemEligibility: FinderTrashItemEligibility
        let down: CGPoint
        var modifiersPresent: Bool
        var maximumTravel: CGFloat = 0

        init(source: AXUIElement, parent: AXUIElement?, itemEligibility: FinderTrashItemEligibility,
             down: CGPoint, modifiersPresent: Bool) {
            self.source = source
            self.parent = parent
            self.itemEligibility = itemEligibility
            self.down = down
            self.modifiersPresent = modifiersPresent
        }
    }

    var onEvent: ((CoachingEvent) -> Void)?
    // Keep AX access serialized with every other detector path.
    private let queue = DispatchQueue.main
    private let detector = DragDropActionDetector()
    private var session: Session?

    func receive(_ sample: PointerSample) {
        queue.async { [weak self] in self?.handle(sample) }
    }

    func cancel() {
        queue.async { [weak self] in self?.session = nil }
    }

    private func handle(_ sample: PointerSample) {
        switch sample.phase {
        case .down:
            begin(sample)
        case .dragged:
            guard let session else { return }
            session.modifiersPresent = session.modifiersPresent || DragDropActionDetector.hasDisallowedModifiers(sample.modifiers)
            session.maximumTravel = max(session.maximumTravel, hypot(sample.location.x - session.down.x, sample.location.y - session.down.y))
        case .up:
            guard let current = session else { return }
            let targetIsTrash = isDockTrash(at: sample.location)
            let modified = current.modifiersPresent || DragDropActionDetector.hasDisallowedModifiers(sample.modifiers)
            let meaningful = current.maximumTravel >= 8
            queue.asyncAfter(deadline: .now() + 0.45) { [weak self, weak current] in
                guard let self, let current, self.session === current else { return }
                let trace = DragDropTrace(
                    schemaVersion: DragDropActionDetector.currentSchemaVersion,
                    itemEligibility: current.itemEligibility,
                    releasedOnDockTrash: targetIsTrash,
                    meaningfulDrag: meaningful,
                    modifiersPresent: modified,
                    postcondition: self.postcondition(for: current)
                )
                self.session = nil
                if let event = self.detector.detect(trace) {
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
                }
            }
        case .cancelled:
            session = nil
        }
    }

    private func begin(_ sample: PointerSample) {
        session = nil
        guard !DragDropActionDetector.hasDisallowedModifiers(sample.modifiers),
              let hit = element(at: sample.location),
              applicationBundle(for: hit) == "com.apple.finder",
              isFinderItem(hit) else { return }
        let parent: AXUIElement? = attribute(kAXParentAttribute, from: hit)
        let eligibility = itemEligibility(of: hit, parent: parent)
        guard eligibility == .supportedRegularItem else { return }
        session = Session(source: hit, parent: parent, itemEligibility: eligibility,
                          down: sample.location, modifiersPresent: false)
    }

    private func isFinderItem(_ element: AXUIElement) -> Bool {
        guard let role: String = attribute(kAXRoleAttribute, from: element) else { return false }
        return [kAXImageRole as String, kAXRowRole as String, kAXCellRole as String].contains(role)
    }

    private func itemEligibility(of element: AXUIElement, parent: AXUIElement?) -> FinderTrashItemEligibility {
        switch settledSelectionStatus(element, parent: parent) {
        case .multiple: return .multipleSelection
        case .unknown: return .unknown
        case .exactlyOne: break
        }
        guard let url = elementURL(element),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey,
                .isVolumeKey, .isWritableKey, .volumeIsLocalKey, .volumeIsInternalKey,
                .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey,
                .isUserImmutableKey, .isSystemImmutableKey
              ]) else { return .unknown }
        return DragDropActionDetector.eligibility(for: FinderItemFacts(
            isFileURL: url.isFileURL,
            isRegularFile: values.isRegularFile,
            isDirectory: values.isDirectory,
            isSymbolicLink: values.isSymbolicLink,
            isAliasFile: values.isAliasFile,
            isVolume: values.isVolume,
            isWritable: values.isWritable,
            volumeIsLocal: values.volumeIsLocal,
            volumeIsInternal: values.volumeIsInternal,
            volumeIsRemovable: values.volumeIsRemovable,
            volumeIsEjectable: values.volumeIsEjectable,
            volumeIsReadOnly: values.volumeIsReadOnly,
            isUserImmutable: values.isUserImmutable,
            isSystemImmutable: values.isSystemImmutable
        ))
    }

    private func settledSelectionStatus(_ element: AXUIElement, parent: AXUIElement?) -> SelectionStatus {
        if let selected: Bool = attribute(kAXSelectedAttribute, from: element), !selected { return .unknown }
        var cursor = parent
        for _ in 0..<8 {
            guard let candidate = cursor else { break }
            if let selected: [AXUIElement] = attribute(kAXSelectedChildrenAttribute, from: candidate) {
                if selected.count > 1 { return .multiple }
                return selected.count == 1 && selected.contains { CFEqual($0, element) } ? .exactlyOne : .unknown
            }
            cursor = attribute(kAXParentAttribute, from: candidate)
        }
        return .unknown
    }

    private func isDockTrash(at point: CGPoint) -> Bool {
        guard let hit = element(at: point), applicationBundle(for: hit) == "com.apple.dock" else { return false }
        var cursor = hit
        for _ in 0..<8 {
            if (attribute(kAXSubroleAttribute, from: cursor) as String?) == kAXTrashDockItemSubrole as String { return true }
            guard let parent: AXUIElement = attribute(kAXParentAttribute, from: cursor) else { break }
            cursor = parent
        }
        return false
    }

    private func postcondition(for session: Session) -> FinderTrashPostcondition {
        guard let parent = session.parent else { return .inaccessible }
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement] else { return .inaccessible }
        return children.contains { CFEqual($0, session.source) } ? .stillPresent : .removedFromOriginalParent
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    private func applicationBundle(for element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func elementURL(_ element: AXUIElement) -> URL? {
        if let url: URL = attribute(kAXURLAttribute, from: element) { return url }
        if let value: String = attribute(kAXURLAttribute, from: element) { return URL(string: value) }
        return nil
    }

    private func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        copyAttribute(name, from: element) as? T
    }
}
