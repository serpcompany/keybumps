import CoreGraphics
import Foundation

struct PointerSample: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case down, up, dragged, cancelled }
    let phase: Phase
    let location: CGPoint
    let modifiers: CGEventFlags
    let timestamp: TimeInterval
}

protocol PointerEventMonitoring: AnyObject {
    var onSample: ((PointerSample) -> Void)? { get set }
    var onTapRecovered: (() -> Void)? { get set }
    func start() -> Bool
    func stop()
}

final class PointerEventMonitor: PointerEventMonitoring {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?

    static func shouldRecover(from type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    func start() -> Bool {
        stop()
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PointerEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if PointerEventMonitor.shouldRecover(from: type) {
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                monitor.onTapRecovered?()
                return Unmanaged.passUnretained(event)
            }
            let phase: PointerSample.Phase
            switch type {
            case .leftMouseDown: phase = .down
            case .leftMouseUp: phase = .up
            case .leftMouseDragged: phase = .dragged
            default: return Unmanaged.passUnretained(event)
            }
            // The callback only copies scalar event data; all AX messaging happens later.
            monitor.onSample?(PointerSample(phase: phase, location: event.location,
                                            modifiers: event.flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime))
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
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
}
