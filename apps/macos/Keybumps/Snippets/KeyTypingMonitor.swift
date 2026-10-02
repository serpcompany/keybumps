import AppKit

/// Where keyword expansion hears typing. Tests and the UI-test composition use fakes that never
/// listen to the keyboard.
protocol KeyTypingMonitoring: AnyObject {
    var onKey: ((TypedKey) -> Void)? { get set }
    /// Starts listening; false when macOS refuses (Input Monitoring isn't granted).
    func start() -> Bool
    func stop()
    /// Whether another key went down after the last key handed on: typing that may already have
    /// landed after the keyword, so deleting the keyword now would delete it instead.
    func keyWentDownSinceLastKey() -> Bool
}

extension KeyTypingMonitoring {
    func keyWentDownSinceLastKey() -> Bool { false }
}

/// A session-wide, listen-only event tap for key presses and clicks. Listen-only, so it can never
/// delay or change what the user types, and it needs Input Monitoring. The callback only reads the
/// key's code, characters, and flags and hands them on: it never logs them, and nothing slow runs
/// on that path. A key that arrives late (Keybumps was busy) counts as a reset, since more typing
/// may already have landed after it.
final class KeyTypingMonitor: KeyTypingMonitoring {
    var onKey: ((TypedKey) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// When the last key handed on went down, in system uptime.
    private var lastKeyUptime: TimeInterval?

    /// How late a key may arrive and still count.
    static let lateness: TimeInterval = 0.1

    deinit {
        stop()
    }

    func start() -> Bool {
        stop()
        // Read silently first: creating a keyboard tap without Input Monitoring can make macOS prompt.
        guard CGPreflightListenEventAccess() else { return false }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyTypingMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                monitor.onKey?(.reset)
            case .keyDown:
                let sent = KeyTypingMonitor.uptime(of: event)
                let isLate = sent.map { KeyTypingMonitor.isLate(eventUptime: $0, now: ProcessInfo.processInfo.systemUptime) } ?? false
                monitor.lastKeyUptime = sent
                monitor.onKey?(isLate ? .reset : KeyTypingMonitor.typedKey(from: event))
            default:
                // A click can move the caret.
                monitor.onKey?(.reset)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
    }

    func keyWentDownSinceLastKey() -> Bool {
        guard let lastKeyUptime else { return false }
        let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        return ProcessInfo.processInfo.systemUptime - since > lastKeyUptime + 0.01
    }

    /// When a key event happened, in system uptime; nil for an event posted without a timestamp.
    static func uptime(of event: CGEvent) -> TimeInterval? {
        guard event.timestamp != 0 else { return nil }
        return NSEvent(cgEvent: event)?.timestamp
    }

    /// Whether a key reached Keybumps too late to trust. A key with no timestamp (0) is on time.
    static func isLate(eventUptime: TimeInterval, now: TimeInterval) -> Bool {
        eventUptime > 0 && now - eventUptime > lateness
    }

    static func typedKey(from event: CGEvent) -> TypedKey {
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        return TypedKey(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            characters: String(utf16CodeUnits: characters, count: length),
            flags: event.flags,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SystemTextPaster.syntheticEventMarker
        )
    }
}

/// Never listens: unit tests and the UI-test composition.
final class InertKeyTypingMonitor: KeyTypingMonitoring {
    var onKey: ((TypedKey) -> Void)?
    func start() -> Bool { false }
    func stop() {}
}
