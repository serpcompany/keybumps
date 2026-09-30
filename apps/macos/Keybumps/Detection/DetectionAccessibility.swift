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
    var copyElementAtPosition: (AXUIElement, CGPoint) -> AXUIElement? = { application, point in
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element)
        return result == .success ? element : nil
    }
    var copyAttributeValue: (AXUIElement, String) -> CFTypeRef? = { element, name in
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    var copyActionNames: (AXUIElement) -> [String] = { element in
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
    }

    /// The one hit-test of a press or release: the element at `point` in `application`'s windows.
    func element(at point: CGPoint, in application: pid_t) -> AXUIElement? {
        guard application != ownProcess else { return nil }
        let target = AXUIElementCreateApplication(application)
        setMessagingTimeout(target, Self.messagingTimeout)
        guard let hit = copyElementAtPosition(target, point), processIdentifier(of: hit) != ownProcess else { return nil }
        return hit
    }

    func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        guard canMessage(element) else { return nil }
        return copyAttributeValue(element, name)
    }

    func actionNames(of element: AXUIElement) -> [String] {
        guard canMessage(element) else { return [] }
        return copyActionNames(element)
    }

    /// Gives an element in another process its timeout; false for Keybumps' own.
    private func canMessage(_ element: AXUIElement) -> Bool {
        guard let pid = processIdentifier(of: element), pid != ownProcess else { return false }
        setMessagingTimeout(element, Self.messagingTimeout)
        return true
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}
