import AppKit

/// Keys pressed in Keybumps's own windows that something takes ahead of those windows' own
/// handlers: Escape, Delete, and ⌘Z while Screencast draws (`ScreencastOverlays`). AppKit calls its
/// local event monitors in no set order, not the order they were added, and the order changes from
/// one launch to the next, so no monitor can count on hearing a key first. A window's handler that
/// takes one of those keys, such as Settings' Escape closer (`SettingsEscapePolicy`) or the
/// Screencast review's keys, leaves a claimed key alone, and the claimant hears it through this
/// one monitor, installed only while something claims a key and never under the unit-test host.
@MainActor
final class OwnWindowKeyClaims {
    static let shared = OwnWindowKeyClaims()

    /// What the claimant does with a key and its modifiers, or nil for a key it leaves.
    typealias Claim = @MainActor (_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> (@MainActor () -> Void)?

    private var claims: [(owner: String, claim: Claim)] = []
    private var monitor: Any?
    private let monitorsEvents: Bool

    /// - Parameter monitorsEvents: False hears no real key, as under the unit-test host; a test
    ///   presses one with `take`.
    init(monitorsEvents: Bool = !UnitTestHost.isActive) {
        self.monitorsEvents = monitorsEvents
    }

    /// Claims the keys `claim` answers for until `release(owner)`, in place of the owner's last claim.
    func claim(_ owner: String, _ claim: @escaping Claim) {
        claims.removeAll { $0.owner == owner }
        claims.append((owner, claim))
        installMonitor()
    }

    func release(_ owner: String) {
        claims.removeAll { $0.owner == owner }
        if claims.isEmpty { removeMonitor() }
    }

    /// Whether something claims this key, which a window's own handler then leaves alone.
    func isClaimed(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        action(keyCode: keyCode, modifiers: modifiers) != nil
    }

    /// Does what the claimant does with a key, and says whether one took it.
    @discardableResult
    func take(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let action = action(keyCode: keyCode, modifiers: modifiers) else { return false }
        action()
        return true
    }

    private func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> (@MainActor () -> Void)? {
        for (_, claim) in claims {
            if let action = claim(keyCode, modifiers) { return action }
        }
        return nil
    }

    private func installMonitor() {
        guard monitorsEvents, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated {
                self?.take(keyCode: event.keyCode, modifiers: event.modifierFlags) ?? false
            }
            return taken ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
