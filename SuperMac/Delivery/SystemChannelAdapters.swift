import AppKit
import UserNotifications

enum DeliveryAdapterError: LocalizedError, Equatable {
    case notificationsDenied
    case notificationAlertsDisabled
    case soundUnavailable

    var errorDescription: String? {
        switch self {
        case .notificationsDenied: "macOS notification permission is not granted"
        case .notificationAlertsDisabled: "macOS notification banners are disabled"
        case .soundUnavailable: "the macOS notification sound is unavailable"
        }
    }
}

enum NativeNotificationAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
    case authorizedWithoutAlerts
    case provisional
    case ephemeral
    case unknown
}

@MainActor
protocol NativeNotificationCenterClient {
    func authorizationStatus() async -> NativeNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func add(identifier: String, title: String, body: String) async throws
}

@MainActor
final class SystemNativeNotificationCenterClient: NativeNotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> NativeNotificationAuthorization {
        let settings = await center.notificationSettings()
        if settings.alertSetting != .enabled,
           settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional {
            return .authorizedWithoutAlerts
        }
        return switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func add(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

@MainActor
final class NativeNotificationAdapter: ChannelDelivering {
    private let center: any NativeNotificationCenterClient
    private let identifierFactory: () -> String

    init(
        center: (any NativeNotificationCenterClient)? = nil,
        identifierFactory: @escaping () -> String = { UUID().uuidString }
    ) {
        self.center = center ?? SystemNativeNotificationCenterClient()
        self.identifierFactory = identifierFactory
    }

    func deliver(_ event: CoachingEvent) async throws {
        var status = await center.authorizationStatus()
        if status == .notDetermined {
            guard try await center.requestAuthorization() else {
                throw DeliveryAdapterError.notificationsDenied
            }
            status = await center.authorizationStatus()
        }
        if status == .authorizedWithoutAlerts {
            throw DeliveryAdapterError.notificationAlertsDisabled
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            throw DeliveryAdapterError.notificationsDenied
        }
        try await center.add(
            identifier: identifierFactory(),
            title: event.coachingTitle,
            body: event.coachingBody
        )
    }
}

enum NotificationSettingsRecovery {
    static let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?com.serp.supermac"
    )!
}

@MainActor
final class SoundAdapter: ChannelDelivering {
    private let playSound: @MainActor (NSSound.Name) -> Bool

    init(playSound: (@MainActor (NSSound.Name) -> Bool)? = nil) {
        self.playSound = playSound ?? { NSSound(named: $0)?.play() ?? false }
    }

    func deliver(_ event: CoachingEvent) async throws {
        guard playSound(NSSound.Name("Glass")) else {
            throw DeliveryAdapterError.soundUnavailable
        }
    }
}

@MainActor
final class PanelChannelAdapter: ChannelDelivering {
    private let channel: NotificationChannel
    private let presenter: PresentationWindowController

    init(channel: NotificationChannel, presenter: PresentationWindowController) {
        self.channel = channel
        self.presenter = presenter
    }

    func deliver(_ event: CoachingEvent) async throws {
        presenter.show(event: event, style: channel)
    }
}
