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

    var canPresentAlerts: Bool {
        self == .authorized || self == .provisional || self == .ephemeral
    }
}

enum NativeNotificationAuthorizationResolver {
    static func resolve(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting,
        alertStyle: UNAlertStyle
    ) -> NativeNotificationAuthorization {
        let authorization: NativeNotificationAuthorization = switch authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
        guard authorization == .authorized
                || authorization == .provisional
                || authorization == .ephemeral else {
            return authorization
        }
        guard alertSetting != .disabled, alertStyle != .none else {
            return .authorizedWithoutAlerts
        }
        return authorization
    }
}

enum AppShellDestination: String, Equatable {
    case keyboardShortcutterHistory

    static func decode(_ persistedRawValue: String) -> AppShellDestination? {
        if persistedRawValue == "keyBumpsHistory" { return .keyboardShortcutterHistory }
        return AppShellDestination(rawValue: persistedRawValue)
    }
}

struct NativeNotificationPayload: Equatable {
    static let destinationKey = "keybumps.destination"
    static let keyboardShortcutterUserInfo = [destinationKey: AppShellDestination.keyboardShortcutterHistory.rawValue]

    let title: String
    let body: String
    let destination: AppShellDestination

    var userInfo: [String: String] {
        [Self.destinationKey: destination.rawValue]
    }
}

enum SystemNotificationContentFactory {
    static func makeContent(for payload: NativeNotificationPayload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = payload.userInfo
        return content
    }
}

@MainActor
protocol NativeNotificationCenterClient {
    func authorizationStatus() async -> NativeNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func add(identifier: String, payload: NativeNotificationPayload) async throws
}

@MainActor
final class SystemNativeNotificationCenterClient: NativeNotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> NativeNotificationAuthorization {
        let settings = await center.notificationSettings()
        return NativeNotificationAuthorizationResolver.resolve(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            alertStyle: settings.alertStyle
        )
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func add(identifier: String, payload: NativeNotificationPayload) async throws {
        let content = SystemNotificationContentFactory.makeContent(for: payload)
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
            payload: NativeNotificationPayload(
                title: event.coachingTitle,
                body: event.coachingBody,
                destination: .keyboardShortcutterHistory
            )
        )
    }
}

enum NotificationSettingsRecovery {
    static let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?com.serp.keybumps"
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

/// Shows a coaching event as a notch notice: the action on the left, its shortcut on the right.
@MainActor
final class NotchChannelAdapter: ChannelDelivering {
    private let notice = PaletteHUD()

    func deliver(_ event: CoachingEvent) async throws {
        notice.show(event.actionTitle, shortcut: event.shortcut, duration: 3)
    }
}
