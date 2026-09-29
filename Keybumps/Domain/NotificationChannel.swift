import Foundation

enum NotificationChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case notch
    case sound

    /// Saved selections of the retired Native macOS Banner, Top-right Toast, and Top-center Shelf,
    /// which now present through the notch.
    static let retiredVisualRawValues: Set<String> = ["nativeBanner", "topRightToast", "topCenterShelf"]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: "Notch"
        case .sound: "Sound"
        }
    }

    /// Decodes saved selections, moving retired visual channels to the notch and dropping unknown
    /// ones (such as the earlier Pointer Card).
    static func decoding(_ rawValues: [String]) -> Set<NotificationChannel> {
        var channels = Set(rawValues.compactMap(NotificationChannel.init(rawValue:)))
        if !retiredVisualRawValues.isDisjoint(with: rawValues) { channels.insert(.notch) }
        return channels
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
