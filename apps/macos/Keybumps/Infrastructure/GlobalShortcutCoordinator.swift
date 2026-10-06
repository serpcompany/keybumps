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
    /// Modifier symbols in the order shortcuts display them (⌃⌥⇧⌘).
    static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> String {
        modifierOrder.filter { flags.contains($0.flag) }.map(\.symbol).joined()
    }

    private static let modifierOrder: [(flag: NSEvent.ModifierFlags, carbon: Int, symbol: String)] = [
        (.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
    ]

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonModifiers = Self.modifierOrder.filter { flags.contains($0.flag) }
            .reduce(UInt32(0)) { $0 | UInt32($1.carbon) }
        let symbols = Self.modifierSymbols(for: flags)
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

enum GlobalHotKeyRegistrationScope: Equatable {
    case systemWide
    case applicationLocal
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    var registrationScope: GlobalHotKeyRegistrationScope { get }
    func installHandler(_ handler: @escaping (UInt32) -> Void)
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool
    func unregister(identifier: UInt32)
}

@MainActor
private final class CarbonGlobalHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var handler: ((UInt32) -> Void)?

    deinit {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func installHandler(_ handler: @escaping (UInt32) -> Void) {
        self.handler = handler
        guard eventHandler == nil else { return }
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonGlobalHotKeyHandler,
            1,
            &specification,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
        unregister(identifier: identifier)
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D4143), id: identifier) // SMAC
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        registrations[identifier] = reference
        return true
    }

    func unregister(identifier: UInt32) {
        guard let reference = registrations.removeValue(forKey: identifier) else { return }
        UnregisterEventHotKey(reference)
    }

    fileprivate func invoke(identifier: UInt32) {
        handler?(identifier)
    }
}

private func carbonGlobalHotKeyHandler(
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
    let backend = Unmanaged<CarbonGlobalHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in backend.invoke(identifier: hotKeyID.id) }
    return noErr
}

@MainActor
@Observable
final class GlobalShortcutCoordinator {
    private struct Registration {
        let identifier: UInt32
        let binding: ShortcutBinding
        let handler: () -> Void
    }

    private(set) var failures: [String: String] = [:]
    private let backend: any GlobalHotKeyRegistering
    private var desiredRegistrations: [String: Registration] = [:]
    private var activeIdentifiers: [String: UInt32] = [:]
    private var identifiers: [UInt32: String] = [:]
    private var nextIdentifier: UInt32 = 1
    private(set) var isSuspendedForRecording = false

    var activeOwners: Set<String> { Set(activeIdentifiers.keys) }
    var desiredOwners: Set<String> { Set(desiredRegistrations.keys) }
    var desiredBindings: [String: ShortcutBinding] { desiredRegistrations.mapValues(\.binding) }
    var registrationScope: GlobalHotKeyRegistrationScope { backend.registrationScope }

    init(backend: (any GlobalHotKeyRegistering)? = nil) {
        self.backend = backend ?? CarbonGlobalHotKeyBackend()
        self.backend.installHandler { [weak self] identifier in
            self?.invoke(identifier: identifier)
        }
    }

    @discardableResult
    func register(owner: String, binding: ShortcutBinding, handler: @escaping () -> Void) -> Bool {
        unregister(owner: owner)
        let numericID = nextIdentifier
        nextIdentifier += 1
        desiredRegistrations[owner] = Registration(
            identifier: numericID,
            binding: binding,
            handler: handler
        )
        guard !isSuspendedForRecording else {
            failures[owner] = nil
            return true
        }
        return activate(owner: owner)
    }

    private func activate(owner: String) -> Bool {
        guard let registration = desiredRegistrations[owner] else { return false }
        guard backend.register(binding: registration.binding, identifier: registration.identifier) else {
            failures[owner] = "Could not register \(registration.binding.displayName). Another app or macOS may already own it."
            return false
        }
        activeIdentifiers[owner] = registration.identifier
        identifiers[registration.identifier] = owner
        failures[owner] = nil
        return true
    }

    func unregister(owner: String) {
        if let identifier = activeIdentifiers.removeValue(forKey: owner) {
            backend.unregister(identifier: identifier)
            identifiers[identifier] = nil
        }
        desiredRegistrations[owner] = nil
        failures[owner] = nil
    }

    func unregisterAll() {
        for owner in Array(desiredRegistrations.keys) { unregister(owner: owner) }
    }

    func suspendForRecording() {
        guard !isSuspendedForRecording else { return }
        isSuspendedForRecording = true
        for (owner, identifier) in Array(activeIdentifiers) {
            backend.unregister(identifier: identifier)
            identifiers[identifier] = nil
            activeIdentifiers[owner] = nil
        }
    }

    func resumeAfterRecording() {
        guard isSuspendedForRecording else { return }
        isSuspendedForRecording = false
        for owner in desiredRegistrations.keys.sorted() {
            _ = activate(owner: owner)
        }
    }

    fileprivate func invoke(identifier: UInt32) {
        guard let owner = identifiers[identifier],
              let registration = desiredRegistrations[owner] else { return }
        registration.handler()
    }
}

enum DefaultShortcut {
    static let quickSearch = ShortcutBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), displayName: "⌘ Space")
    static let clipboard = ShortcutBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘ Space")
    static let dictation = ShortcutBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), displayName: "⌥ Space")
    static let cancelDictation = ShortcutBinding(keyCode: UInt32(kVK_Escape), modifiers: 0, displayName: "Escape")
    static let screenshotScreen = ShortcutBinding(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘2")
    static let screenshotScreenAndEdit = ShortcutBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘3")
    static let screenshotArea = ShortcutBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), displayName: "⇧⌘4")
}

enum CapabilityShortcut: String, CaseIterable, Codable, Identifiable {
    case quickSearch
    case clipboardHistory
    case dictation
    /// Registered only while Dictation is recording or transcribing (`DictationModule`), so its
    /// key, Esc by default, works normally everywhere else.
    case cancelDictation
    case screenshotScreen
    case screenshotScreenAndEdit
    case screenshotArea
    case snippets
    case timer
    case emojiPicker

    var id: String { rawValue }
    var ownerID: String { rawValue }

    /// The shortcuts that shipped before per-shortcut introduction tracking. Anything else gets its
    /// default once when it first ships, as new capabilities are enabled once.
    static let originalShortcuts: Set<CapabilityShortcut> = [.quickSearch, .clipboardHistory, .dictation]

    var capability: Capability {
        switch self {
        case .quickSearch: .quickSearch
        case .clipboardHistory: .clipboardHistory
        case .dictation, .cancelDictation: .dictation
        case .screenshotScreen, .screenshotScreenAndEdit, .screenshotArea: .screenshotTools
        case .snippets: .snippets
        case .timer: .timer
        case .emojiPicker: .emojiPicker
        }
    }

    var title: String {
        switch self {
        case .quickSearch: "Open Quick Search"
        case .clipboardHistory: "Open Clipboard History"
        case .dictation: "Start & Stop Dictation"
        case .cancelDictation: "Cancel Dictation"
        case .screenshotScreen: "Screenshot Screen"
        case .screenshotScreenAndEdit: "Screenshot Screen and Edit"
        case .screenshotArea: "Screenshot Area"
        case .snippets: "Open Snippets"
        case .timer: "Open Timers"
        case .emojiPicker: "Open Emoji Picker"
        }
    }

    /// Whether the shortcut works from anywhere. Cancel Dictation works only while Dictation is
    /// recording or transcribing, which `detail` says in Settings.
    var worksEverywhere: Bool { self != .cancelDictation }

    /// A note under the title, for a shortcut that works only at certain times.
    var detail: String? {
        switch self {
        case .cancelDictation: "Only while Dictation is recording or transcribing"
        default: nil
        }
    }

    /// The binding a new install starts with; nil for a shortcut that starts unassigned.
    var defaultBinding: ShortcutBinding? {
        switch self {
        case .quickSearch: DefaultShortcut.quickSearch
        case .clipboardHistory: DefaultShortcut.clipboard
        case .dictation: DefaultShortcut.dictation
        case .cancelDictation: DefaultShortcut.cancelDictation
        case .screenshotScreen: DefaultShortcut.screenshotScreen
        case .screenshotScreenAndEdit: DefaultShortcut.screenshotScreenAndEdit
        case .screenshotArea: DefaultShortcut.screenshotArea
        case .snippets, .timer, .emojiPicker: nil
        }
    }
}
