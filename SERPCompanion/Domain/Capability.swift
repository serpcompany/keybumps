import Foundation

enum Capability: String, CaseIterable, Codable, Identifiable {
    case quickSearch
    case clipboardHistory
    case dictation
    case windowManagement
    case shortcutCoaching

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickSearch: "Quick Search"
        case .clipboardHistory: "Clipboard History"
        case .dictation: "Dictation"
        case .windowManagement: "Window Management"
        case .shortcutCoaching: "Shortcut Coaching"
        }
    }

    var systemImage: String {
        switch self {
        case .quickSearch: "magnifyingglass"
        case .clipboardHistory: "clipboard"
        case .dictation: "waveform"
        case .windowManagement: "rectangle.split.2x1"
        case .shortcutCoaching: "keyboard"
        }
    }
}
