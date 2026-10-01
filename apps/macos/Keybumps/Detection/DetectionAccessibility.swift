import ApplicationServices
import CoreGraphics
import Foundation

/// Every Accessibility message Shortcut Coach's click detection sends. `ManualActionDetector` sends
/// them from its detection queue, never the main thread, so an app that's slow to answer can't
/// freeze Keybumps (#212).
///
/// - Each element gets `messagingTimeout` before it's messaged. The timeout is set on the other
///   app's elements, never on the system-wide element, where it would apply to every Accessibility
///   call in Keybumps (Window Manager's moves included).
/// - Keybumps' own elements are never messaged. AppKit answers those in-process, on the calling
///   thread, and its accessibility is main-thread-only. Hit-tests go to the other app's element,
///   but a remote view's ancestors (an open panel's, say) can lead back into Keybumps.
/// - An app that doesn't answer in time isn't messaged again until the next press or release, so
///   it holds up detection for one timeout, not one for each of the press's many reads. Each check
///   that follows a click asks that app once more (`beginDelayedCheck(of:)`).
///
/// Tests replace the raw calls. Creating an element sends no message.
struct DetectionAccessibility {
    /// An app that's responding answers in a millisecond or two. One still busy after a quarter of a
    /// second is usually handling that very click, and that click goes uncoached (detection fails
    /// closed) rather than holding up the checks of the clicks after it.
    static let messagingTimeout: Float = 0.25
    static let system = DetectionAccessibility()

    var ownProcess = ProcessInfo.processInfo.processIdentifier
    var setMessagingTimeout: (AXUIElement, Float) -> Void = { _ = AXUIElementSetMessagingTimeout($0, $1) }
    /// The raw calls return their error, so a timeout (`cannotComplete`) is seen, and a value only
    /// with `success`.
    var copyElementAtPosition: (AXUIElement, CGPoint) -> (AXError, AXUIElement?) = { application, point in
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element)
        return (error, element)
    }
    var copyAttributeValue: (AXUIElement, String) -> (AXError, CFTypeRef?) = { element, name in
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }
    var copyActionNames: (AXUIElement) -> (AXError, [String]) = { element in
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        return (error, names as? [String] ?? [])
    }
    /// Shared by every copy, so every detector sees an app that didn't answer.
    private let unresponsive = UnresponsiveApplications()

    /// Called for each press and release, before its hit-test: apps that didn't answer during the
    /// last one are asked again.
    func beginPressOrRelease() {
        unresponsive.removeAll()
    }

    /// Called at the start of each check that follows a click to see what it did (Chrome's follow-up
    /// reads, window control's checks): `application` gets one fresh try. It's often still busy with
    /// the click as it's released, and these checks exist to wait it out. An app that never answers
    /// still costs only one timeout per check.
    func beginDelayedCheck(of application: pid_t) {
        unresponsive.remove(application)
    }

    /// The one hit-test of a press or release: the element at `point` in `application`'s windows.
    func element(at point: CGPoint, in application: pid_t) -> AXUIElement? {
        guard application != ownProcess, !unresponsive.contains(application) else { return nil }
        let target = AXUIElementCreateApplication(application)
        setMessagingTimeout(target, Self.messagingTimeout)
        let (error, hit) = copyElementAtPosition(target, point)
        guard answered(error, by: application), let hit, processIdentifier(of: hit) != ownProcess else { return nil }
        return hit
    }

    func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        guard let pid = messageableProcess(of: element) else { return nil }
        let (error, value) = copyAttributeValue(element, name)
        return answered(error, by: pid) ? value : nil
    }

    func actionNames(of element: AXUIElement) -> [String] {
        guard let pid = messageableProcess(of: element) else { return [] }
        let (error, names) = copyActionNames(element)
        return answered(error, by: pid) ? names : []
    }

    /// Gives an element in another process its timeout and returns that process; nil for Keybumps'
    /// own elements and an app that didn't answer in time.
    private func messageableProcess(of element: AXUIElement) -> pid_t? {
        guard let pid = processIdentifier(of: element), pid != ownProcess, !unresponsive.contains(pid) else { return nil }
        setMessagingTimeout(element, Self.messagingTimeout)
        return pid
    }

    /// Whether the app answered. A timeout comes back as `cannotComplete`.
    private func answered(_ error: AXError, by pid: pid_t) -> Bool {
        if error == .cannotComplete { unresponsive.insert(pid) }
        return error == .success
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}

/// The apps that didn't answer in time during the current press, release, or check. Locked, because
/// `DetectionAccessibility.system` is shared.
private final class UnresponsiveApplications: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: Set<pid_t> = []

    func contains(_ pid: pid_t) -> Bool { lock.withLock { processes.contains(pid) } }
    func insert(_ pid: pid_t) { lock.withLock { _ = processes.insert(pid) } }
    func remove(_ pid: pid_t) { lock.withLock { _ = processes.remove(pid) } }
    func removeAll() { lock.withLock { processes.removeAll() } }
}
