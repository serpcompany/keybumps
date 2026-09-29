import AppKit

enum DeliveryAdapterError: LocalizedError, Equatable {
    case soundUnavailable

    var errorDescription: String? {
        switch self {
        case .soundUnavailable: "the macOS notification sound is unavailable"
        }
    }
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

/// Shows a coaching event as a notch notice: the notch drops down with the app, the action, and
/// its shortcut.
@MainActor
final class NotchChannelAdapter: ChannelDelivering {
    private let notice = PaletteHUD()

    func deliver(_ event: CoachingEvent) async throws {
        notice.showCoach(NotchCoachPresentation(event: event))
    }
}
