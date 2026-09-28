import Foundation

enum Capability: String, CaseIterable, Codable, Identifiable {
    case quickSearch
    case clipboardHistory
    case dictation
    case windowManagement
    case keyboardShortcutter
    case screenshotTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickSearch: "Quick Search"
        case .clipboardHistory: "Clipboard History"
        case .dictation: "Dictation"
        case .windowManagement: "Window Management"
        case .keyboardShortcutter: "Keyboard Shortcutter"
        case .screenshotTools: "Screenshot Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .quickSearch: "magnifyingglass"
        case .clipboardHistory: "clipboard"
        case .dictation: "waveform"
        case .windowManagement: "rectangle.split.2x1"
        case .keyboardShortcutter: "keyboard"
        case .screenshotTools: "camera.viewfinder"
        }
    }

    /// Capabilities that existed before per-capability introduction tracking.
    /// Anything outside this set is enabled once for existing installs when it first ships.
    static let originalCapabilities: Set<Capability> = [
        .quickSearch, .clipboardHistory, .dictation, .windowManagement, .keyboardShortcutter
    ]
}
