import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum StandardWindowControlKind: String, Codable, Equatable, Sendable {
    case close
    case minimize
    case fullScreen
}

struct WindowControlState: Equatable, Sendable {
    let present: Bool
    let minimized: Bool?
    let fullScreen: Bool?
    let frame: CGRect?
}

enum WindowControlApplicationProfile: String, Codable, Equatable, Sendable {
    case googleChrome
    case finder
    case safari
    case other

    init(bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.google.Chrome": self = .googleChrome
        case "com.apple.finder": self = .finder
        case "com.apple.Safari": self = .safari
        default: self = .other
        }
    }
}

struct WindowControlTrace: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: StandardWindowControlKind
    let applicationProfile: WindowControlApplicationProfile
    let shortcut: String
    let shortcutEvidence: AXShortcutEvidence?
    let prePresent: Bool
    let postPresent: Bool
    let preMinimized: Bool?
    let postMinimized: Bool?
    let preFullScreen: Bool?
    let postFullScreen: Bool?
    let frameChanged: Bool

    init(
        schemaVersion: Int,
        kind: StandardWindowControlKind,
        applicationProfile: WindowControlApplicationProfile,
        shortcut: String,
        shortcutEvidence: AXShortcutEvidence? = nil,
        prePresent: Bool,
        postPresent: Bool,
        preMinimized: Bool?,
        postMinimized: Bool?,
        preFullScreen: Bool?,
        postFullScreen: Bool?,
        frameChanged: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.applicationProfile = applicationProfile
        self.shortcut = shortcut
        self.shortcutEvidence = shortcutEvidence
        self.prePresent = prePresent
        self.postPresent = postPresent
        self.preMinimized = preMinimized
        self.postMinimized = postMinimized
        self.preFullScreen = preFullScreen
        self.postFullScreen = postFullScreen
        self.frameChanged = frameChanged
    }
}

struct WindowControlActionDetector {
    static let currentSchemaVersion = 1
    private static let userModifierFlags: CGEventFlags = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
        .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn
    ]

    static func hasDisallowedModifiers(_ flags: CGEventFlags) -> Bool {
        if !flags.intersection(userModifierFlags).isEmpty { return true }
        let allowedBookkeepingBits = CGEventFlags.maskNonCoalesced.rawValue
        return flags.rawValue & ~(userModifierFlags.rawValue | allowedBookkeepingBits) != 0
    }

    static func uniqueShortcut(from matches: [String]) -> String? {
        matches.count == 1 && !matches[0].isEmpty ? matches[0] : nil
    }

    static func shortcutIsCurrent(_ captured: String, reread: String?) -> Bool {
        !captured.isEmpty && reread == captured
    }

    static func shortcutIsCurrent(
        _ captured: LiveShortcutObservation,
        reread: LiveShortcutObservation?
    ) -> Bool {
        reread == captured
    }

    static func acceptsWindow(isStandard: Bool?, isModal: Bool?) -> Bool {
        isStandard == true && isModal == false
    }

    func detect(
        _ trace: WindowControlTrace,
        applicationName: String
    ) -> CoachingEvent? {
        guard trace.schemaVersion == Self.currentSchemaVersion,
              trace.prePresent,
              !trace.shortcut.isEmpty,
              let shortcutEvidence = trace.shortcutEvidence else { return nil }
        let completed: Bool
        let title: String
        switch trace.kind {
        case .minimize:
            completed = trace.preMinimized == false && trace.postPresent && trace.postMinimized == true
            title = "Minimize Window"
        case .close:
            completed = !trace.postPresent
            title = "Close Window"
        case .fullScreen:
            completed = fullScreenTransitionCompleted(trace)
            title = trace.preFullScreen == true ? "Exit Full Screen" : "Enter Full Screen"
        }
        guard completed else { return nil }
        return CoachingEventFactory.make(
            applicationName: applicationName,
            actionTitle: title,
            shortcutEvidence: shortcutEvidence
        )
    }

    private func fullScreenTransitionCompleted(_ trace: WindowControlTrace) -> Bool {
        // Chrome is the only green-button behavior characterized by the
        // captured acceptance run. Other apps remain suppressed until each
        // gets its own adapter instead of inheriting generic frame logic.
        guard trace.applicationProfile == .googleChrome else { return false }
        return trace.postPresent
            && trace.frameChanged
            && trace.preFullScreen != nil
            && trace.postFullScreen == !(trace.preFullScreen ?? false)
    }
}

/// What window control reads about the app it checks, from `NSRunningApplication`, which, unlike
/// `NSWorkspace.frontmostApplication`, is documented safe off the main thread. Tests make one up.
struct RunningApplicationState: Equatable, Sendable {
    var bundleIdentifier: String?
    var name: String?
    var isActive: Bool

    static func current(_ pid: pid_t) -> RunningApplicationState? {
        NSRunningApplication(processIdentifier: pid).map {
            RunningApplicationState(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName, isActive: $0.isActive)
        }
    }
}

final class StandardWindowControlMonitor {
    private final class Session {
        let kind: StandardWindowControlKind
        let applicationName: String
        let applicationProfile: WindowControlApplicationProfile
        let processIdentifier: pid_t
        let application: AXUIElement
        let window: AXUIElement
        let buttonFrame: CGRect
        let preState: WindowControlState
        let shortcut: LiveShortcutObservation
        let pointerDown: CGPoint
        let downTimestamp: TimeInterval
        var maximumTravel: CGFloat = 0
        var modifiersPresent = false

        init(kind: StandardWindowControlKind, applicationName: String,
             applicationProfile: WindowControlApplicationProfile, processIdentifier: pid_t,
             application: AXUIElement, window: AXUIElement, buttonFrame: CGRect,
             preState: WindowControlState, shortcut: LiveShortcutObservation, pointerDown: CGPoint,
             downTimestamp: TimeInterval) {
            self.kind = kind
            self.applicationName = applicationName
            self.applicationProfile = applicationProfile
            self.processIdentifier = processIdentifier
            self.application = application
            self.window = window
            self.buttonFrame = buttonFrame
            self.preState = preState
            self.shortcut = shortcut
            self.pointerDown = pointerDown
            self.downTimestamp = downTimestamp
        }
    }

    var onEvent: ((CoachingEvent) -> Void)?
    /// `ManualActionDetector`'s detection queue. The session, its verification, and every
    /// Accessibility read stay on it.
    private let queue: DispatchQueue
    private let accessibility: DetectionAccessibility
    private let runningApplication: (pid_t) -> RunningApplicationState?
    private let detector = WindowControlActionDetector()
    private var session: Session?

    init(queue: DispatchQueue, accessibility: DetectionAccessibility,
         runningApplication: @escaping (pid_t) -> RunningApplicationState? = RunningApplicationState.current) {
        self.queue = queue
        self.accessibility = accessibility
        self.runningApplication = runningApplication
    }

    func cancel() {
        queue.async { [weak self] in self?.session = nil }
    }

    /// Called on the detection queue with every pointer sample, in order. `hit` is the element under
    /// a press or release, from the one hit-test every detector shares.
    func handle(_ sample: PointerSample, hit: AXUIElement?) {
        switch sample.phase {
        case .down:
            begin(sample, hit: hit)
        case .dragged:
            guard let session else { return }
            session.modifiersPresent = session.modifiersPresent || WindowControlActionDetector.hasDisallowedModifiers(sample.modifiers)
            session.maximumTravel = max(
                session.maximumTravel,
                hypot(sample.location.x - session.pointerDown.x, sample.location.y - session.pointerDown.y)
            )
        case .up:
            finishGesture(sample)
        case .cancelled:
            session = nil
        }
    }

    private func begin(_ sample: PointerSample, hit: AXUIElement?) {
        session = nil
        guard !WindowControlActionDetector.hasDisallowedModifiers(sample.modifiers),
              let hit,
              let kind = controlKind(hit),
              let window = containingWindow(for: hit),
              let frame = frame(of: hit),
              WindowControlActionDetector.acceptsWindow(
                isStandard: (attribute(kAXSubroleAttribute, from: window) as String?) == kAXStandardWindowSubrole as String,
                isModal: attribute(kAXModalAttribute, from: window)
              ) else { return }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              let running = runningApplication(pid),
              let bundle = running.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier,
              running.isActive else { return }

        let application = AXUIElementCreateApplication(pid)
        let pre = state(of: window, in: application)
        guard pre.present else { return }
        guard let shortcut = liveShortcut(for: kind, in: application, state: pre, requireEnabled: true) else { return }
        session = Session(
            kind: kind,
            applicationName: running.name ?? "Current app",
            applicationProfile: WindowControlApplicationProfile(bundleIdentifier: bundle),
            processIdentifier: pid,
            application: application,
            window: window,
            buttonFrame: frame,
            preState: pre,
            shortcut: shortcut,
            pointerDown: sample.location,
            downTimestamp: sample.timestamp
        )
    }

    private func finishGesture(_ sample: PointerSample) {
        guard let current = session else { return }
        guard !current.modifiersPresent,
              !WindowControlActionDetector.hasDisallowedModifiers(sample.modifiers),
              runningApplication(current.processIdentifier)?.isActive == true,
              sample.timestamp - current.downTimestamp <= 1.5,
              current.maximumTravel <= 4,
              current.buttonFrame.insetBy(dx: -2, dy: -2).contains(sample.location) else {
            session = nil
            return
        }
        guard WindowControlActionDetector.shortcutIsCurrent(
            current.shortcut,
            reread: liveShortcut(for: current.kind, in: current.application,
                                 state: current.preState, requireEnabled: true)
        ) else {
            session = nil
            return
        }

        queue.asyncAfter(deadline: .now() + 0.35) { [weak self, weak current] in
            guard let self, let current, self.session === current else { return }
            if let event = self.verifiedEvent(for: current) {
                self.session = nil
                DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.65) { [weak self, weak current] in
                guard let self, let current, self.session === current else { return }
                let event = self.verifiedEvent(for: current)
                self.session = nil
                if let event { DispatchQueue.main.async { [weak self] in self?.onEvent?(event) } }
            }
        }
    }

    /// The check at 0.35 s, and the re-check at 1.0 s if that one fails. The app is often still busy
    /// with the click, so each gives it a fresh try.
    private func verifiedEvent(for session: Session) -> CoachingEvent? {
        accessibility.beginDelayedCheck(of: session.processIdentifier)
        let post = state(of: session.window, in: session.application)
        guard WindowControlActionDetector.shortcutIsCurrent(
            session.shortcut,
            reread: liveShortcut(for: session.kind, in: session.application,
                                 state: post, requireEnabled: false)
        ) else { return nil }
        let frameChanged: Bool
        if let before = session.preState.frame, let after = post.frame {
            frameChanged = abs(before.width - after.width) > 20 || abs(before.height - after.height) > 20
        } else {
            frameChanged = false
        }
        let trace = WindowControlTrace(
            schemaVersion: WindowControlActionDetector.currentSchemaVersion,
            kind: session.kind,
            applicationProfile: session.applicationProfile,
            shortcut: session.shortcut.displayString ?? "",
            shortcutEvidence: session.shortcut.evidence,
            prePresent: session.preState.present,
            postPresent: post.present,
            preMinimized: session.preState.minimized,
            postMinimized: post.minimized,
            preFullScreen: session.preState.fullScreen,
            postFullScreen: post.fullScreen,
            frameChanged: frameChanged
        )
        return detector.detect(trace, applicationName: session.applicationName)
    }

    private func controlKind(_ element: AXUIElement) -> StandardWindowControlKind? {
        guard (attribute(kAXRoleAttribute, from: element) as String?) == kAXButtonRole as String,
              actions(of: element).contains(kAXPressAction as String),
              let subrole: String = attribute(kAXSubroleAttribute, from: element) else { return nil }
        switch subrole {
        case "AXCloseButton": return .close
        case "AXMinimizeButton": return .minimize
        case "AXFullScreenButton", "AXZoomButton": return .fullScreen
        default: return nil
        }
    }

    private func state(of window: AXUIElement, in application: AXUIElement) -> WindowControlState {
        let present = applicationWindows(application).contains { CFEqual($0, window) }
        return WindowControlState(
            present: present,
            minimized: attribute(kAXMinimizedAttribute, from: window),
            fullScreen: attribute("AXFullScreen", from: window),
            frame: frame(of: window)
        )
    }

    private func liveShortcut(
        for kind: StandardWindowControlKind,
        in application: AXUIElement,
        state: WindowControlState,
        requireEnabled: Bool
    ) -> LiveShortcutObservation? {
        guard let menuBar: AXUIElement = attribute(kAXMenuBarAttribute, from: application) else { return nil }
        var frontier = [menuBar]
        var visited = 0
        var matches: [LiveShortcutObservation] = []
        while !frontier.isEmpty && visited < 600 {
            let element = frontier.removeFirst()
            visited += 1
            if (attribute(kAXRoleAttribute, from: element) as String?) == kAXMenuItemRole as String,
               (!requireEnabled || (attribute(kAXEnabledAttribute, from: element) as Bool?) != false),
               let title: String = attribute(kAXTitleAttribute, from: element),
               menuTitle(title, matches: kind, state: state) {
                if let shortcut = LiveShortcutObservation(
                    evidence: AXShortcutEvidenceReader.read(from: element, using: accessibility)
                ) {
                    matches.append(shortcut)
                }
            }
            let children: [AXUIElement] = attribute(kAXChildrenAttribute, from: element) ?? []
            frontier.append(contentsOf: children)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func menuTitle(_ title: String, matches kind: StandardWindowControlKind, state: WindowControlState) -> Bool {
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch kind {
        case .minimize: return normalized == "minimize" || normalized == "miniaturize"
        case .close: return normalized == "close window" || normalized == "close"
        case .fullScreen:
            return state.fullScreen == true ? normalized == "exit full screen" : normalized == "enter full screen"
        }
    }

    private func containingWindow(for element: AXUIElement) -> AXUIElement? {
        if let window: AXUIElement = attribute(kAXWindowAttribute, from: element) { return window }
        var cursor = element
        for _ in 0..<12 {
            if (attribute(kAXRoleAttribute, from: cursor) as String?) == kAXWindowRole as String { return cursor }
            guard let parent: AXUIElement = attribute(kAXParentAttribute, from: cursor) else { return nil }
            cursor = parent
        }
        return nil
    }

    private func applicationWindows(_ application: AXUIElement) -> [AXUIElement] {
        attribute(kAXWindowsAttribute, from: application) ?? []
    }

    private func actions(of element: AXUIElement) -> [String] {
        accessibility.actionNames(of: element)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        accessibility.copyAttribute(name, from: element)
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        copyAttribute(name, from: element) as? T
    }

    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        guard let raw = copyAttribute(name, from: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &value) ? value : nil
    }

    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        guard let raw = copyAttribute(name, from: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &value) ? value : nil
    }
}
