import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

struct ShortcutBinding: Hashable, Codable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String
}

extension ShortcutBinding {
    func usesSameKeys(as other: ShortcutBinding) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

extension ShortcutBinding {
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey); symbols += "⌘" }
        guard carbonModifiers != 0 else { return nil }
        let key = Self.keyName(for: event)
        guard !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers, displayName: symbols + key)
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        default: (event.charactersIgnoringModifiers ?? "").uppercased()
        }
    }
}

@MainActor
@Observable
final class GlobalShortcutCoordinator {
    private(set) var failures: [String: String] = [:]
    private var registrations: [String: EventHotKeyRef] = [:]
    private var identifiers: [UInt32: String] = [:]
    private var handlers: [String: () -> Void] = [:]
    private var nextIdentifier: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), serpHotKeyHandler, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    @discardableResult
    func register(owner: String, binding: ShortcutBinding, handler: @escaping () -> Void) -> Bool {
        unregister(owner: owner)
        let numericID = nextIdentifier
        nextIdentifier += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53525043), id: numericID) // SRPC
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            failures[owner] = "Could not register \(binding.displayName). Another app or macOS may already own it."
            return false
        }
        registrations[owner] = reference
        identifiers[numericID] = owner
        handlers[owner] = handler
        failures[owner] = nil
        return true
    }

    func unregister(owner: String) {
        if let reference = registrations.removeValue(forKey: owner) {
            UnregisterEventHotKey(reference)
        }
        handlers[owner] = nil
        failures[owner] = nil
        identifiers = identifiers.filter { $0.value != owner }
    }

    func unregisterAll() {
        for owner in Array(registrations.keys) { unregister(owner: owner) }
    }

    fileprivate func invoke(identifier: UInt32) {
        guard let owner = identifiers[identifier] else { return }
        handlers[owner]?()
    }
}

private func serpHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let coordinator = Unmanaged<GlobalShortcutCoordinator>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in coordinator.invoke(identifier: hotKeyID.id) }
    return noErr
}

enum DefaultShortcut {
    static let quickSearch = ShortcutBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), displayName: "⌘ Space")
    static let clipboard = ShortcutBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘ Space")
    static let dictation = ShortcutBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), displayName: "⌥ Space")
    static let cancelDictation = ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, displayName: "Escape")
}

enum CapabilityShortcut: String, CaseIterable, Codable, Identifiable {
    case quickSearch
    case clipboardHistory
    case dictation

    var id: String { rawValue }
    var ownerID: String { rawValue }

    var capability: Capability {
        switch self {
        case .quickSearch: .quickSearch
        case .clipboardHistory: .clipboardHistory
        case .dictation: .dictation
        }
    }

    var title: String {
        switch self {
        case .quickSearch: "Open Quick Search"
        case .clipboardHistory: "Open Clipboard History"
        case .dictation: "Start or stop Dictation"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .quickSearch: DefaultShortcut.quickSearch
        case .clipboardHistory: DefaultShortcut.clipboard
        case .dictation: DefaultShortcut.dictation
        }
    }
}
