import Foundation

enum Capability: String, CaseIterable, Codable, Identifiable {
    case quickSearch
    case clipboardHistory
    case dictation
    case windowManagement
    case keyboardShortcutter
    case screenshotTools
    case snippets
    case timer
    case emojiPicker
    case translation
    case keystrokes

    var id: String { rawValue }

    var descriptor: CapabilityDescriptor { CapabilityCatalog.descriptor(for: self) }
    var title: String { descriptor.title }
    var systemImage: String { descriptor.systemImage }

    /// Capabilities that existed before per-capability introduction tracking.
    /// Anything outside this set is enabled once for existing installs when it first ships.
    static let originalCapabilities: Set<Capability> = [
        .quickSearch, .clipboardHistory, .dictation, .windowManagement, .keyboardShortcutter
    ]
}
