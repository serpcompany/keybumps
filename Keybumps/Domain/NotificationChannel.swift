import Foundation

enum NotificationChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case notch
    case nativeBanner
    case topRightToast
    case topCenterShelf
    case sound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeBanner: "Native macOS Banner"
        case .topRightToast: "Top-right Toast"
        case .topCenterShelf: "Top-center Shelf"
        case .notch: "Notch"
        case .sound: "Sound"
        }
    }

    var summary: String {
        switch self {
        case .nativeBanner: "A Notification Center alert that remains available to macOS."
        case .topRightToast: "A compact keyboard-shortcut card near the top-right corner."
        case .topCenterShelf: "A prominent expandable shelf centered at the top."
        case .notch: "The action and its shortcut flash out of the notch (or the top of the menu bar)."
        case .sound: "Plays the system notification sound."
        }
    }

    var systemImage: String {
        switch self {
        case .nativeBanner: "macwindow.badge.plus"
        case .topRightToast: "rectangle.topthird.inset.filled"
        case .topCenterShelf: "rectangle.tophalf.inset.filled"
        case .notch: "menubar.rectangle"
        case .sound: "speaker.wave.2"
        }
    }

    var supportsPreview: Bool {
        self != .nativeBanner
    }
}

enum PresentationOverlapPolicy {
    static func selecting(
        _ channel: NotificationChannel,
        in channels: Set<NotificationChannel>
    ) -> Set<NotificationChannel> {
        channels.union([channel])
    }

    static func normalized(_ channels: Set<NotificationChannel>) -> Set<NotificationChannel> {
        channels
    }
}

enum DeliveryOutcome: Equatable, Sendable {
    case delivered
    case failed(String)
}

struct DeliveryReport: Equatable, Sendable {
    let eventID: UUID
    let inboxRecorded: Bool
    let outcomes: [NotificationChannel: DeliveryOutcome]
}
