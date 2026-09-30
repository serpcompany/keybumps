import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

protocol DetectorPermissionProviding {
    var isAccessibilityTrusted: Bool { get }
    var isInputMonitoringAuthorized: Bool { get }
    /// Despite the name, only re-reads the state silently; it never prompts. Accessibility and
    /// Input Monitoring recover through System Settings and the drag card.
    func requestAccessibility()
    /// Despite the name, only re-reads the state silently; it never prompts.
    func requestInputMonitoring()
}

struct SystemDetectorPermissions: DetectorPermissionProviding {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    var isInputMonitoringAuthorized: Bool { CGPreflightListenEventAccess() }

    func requestAccessibility() {
        _ = AXIsProcessTrusted()
    }

    func requestInputMonitoring() {
        _ = CGPreflightListenEventAccess()
    }
}

enum MenuActionEventResolver {
    static func makeEvent(from snapshot: AccessibilitySnapshot) -> CoachingEvent? {
        let menuItems = snapshot.hitAndAncestors.filter { node in
            node.role == kAXMenuItemRole as String
                && node.enabled == true
                && node.title?.isEmpty == false
                && node.menuShortcutEvidence != nil
        }
        let uniqueItems = Dictionary(grouping: menuItems, by: \.token).compactMap(\.value.first)
        guard uniqueItems.count == 1,
              let menuItem = uniqueItems.first,
              let title = menuItem.title,
              let evidence = menuItem.menuShortcutEvidence else { return nil }
        return CoachingEventFactory.make(
            applicationName: snapshot.applicationName,
            actionTitle: title,
            shortcutEvidence: evidence
        )
    }
}

@MainActor
final class ManualActionDetector {
    enum RequiredPermission: Equatable {
        case accessibility
        case inputMonitoring
    }

    enum Status: Equatable {
        case stopped
        case permissionRequired([RequiredPermission])
        case monitoring
        case failed(String)
    }

    private var operationalStatus: Status = .stopped
    var status: Status {
        let missing = missingPermissions
        if operationalStatus != .stopped, !missing.isEmpty {
            return .permissionRequired(missing)
        }
        if case .permissionRequired = operationalStatus {
            return .stopped
        }
        return operationalStatus
    }
    var onEvent: ((CoachingEvent) -> Void)?
    private let monitor: any PointerEventMonitoring
    private let permissions: any DetectorPermissionProviding
    /// Not private so tests can reach the detectors' event delivery. Its work stays on its queue.
    let detection: DetectionPipeline
    private var chromeClickDetector = ChromeClickDetector()
    private var generation = 0
    private var lastMenuSignature: String?
    private var lastMenuEmission = Date.distantPast

    var isAccessibilityTrusted: Bool { permissions.isAccessibilityTrusted }
    var isInputMonitoringAuthorized: Bool { permissions.isInputMonitoringAuthorized }

    private var missingPermissions: [RequiredPermission] {
        var missing: [RequiredPermission] = []
        if !permissions.isAccessibilityTrusted { missing.append(.accessibility) }
        if !permissions.isInputMonitoringAuthorized { missing.append(.inputMonitoring) }
        return missing
    }

    init(
        monitor: any PointerEventMonitoring = PointerEventMonitor(),
        snapshotter: (any AccessibilitySnapshotting)? = nil,
        permissions: any DetectorPermissionProviding = SystemDetectorPermissions(),
        chromeRuntimeReader: (any ChromeRuntimeStateReading)? = nil,
        clickTargets: any ClickTargetProbing = WindowListClickTargetProbe(),
        accessibility: DetectionAccessibility = .system
    ) {
        self.monitor = monitor
        self.permissions = permissions
        detection = DetectionPipeline(
            clickTargets: clickTargets,
            accessibility: accessibility,
            snapshotter: snapshotter ?? AccessibilitySnapshotter(accessibility: accessibility),
            chromeRuntimeReader: chromeRuntimeReader ?? SystemChromeRuntimeStateReader(accessibility: accessibility)
        )
    }

    func requestAccessibilityPermission() {
        permissions.requestAccessibility()
    }

    func requestInputMonitoringPermission() {
        permissions.requestInputMonitoring()
    }

    func start() {
        stop()
        let missing = missingPermissions
        guard missing.isEmpty else {
            operationalStatus = .permissionRequired(missing)
            return
        }

        monitor.onSample = { [weak self] sample in self?.route(sample) }
        // Queued behind the samples already on their way, so it also drops the gestures they start.
        monitor.onTapRecovered = { [weak self] in
            self?.route(PointerSample(phase: .cancelled, location: .zero, modifiers: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime))
        }
        // An action verified on the detection queue just before `stop()` reaches the main thread after
        // it. Drop it, as `route` drops late results: locking stops Shortcut Coach but leaves it turned
        // on, so `AppModel` would still show it and record it.
        let currentGeneration = generation
        let deliver: (CoachingEvent) -> Void = { [weak self] event in
            guard let self, self.generation == currentGeneration else { return }
            self.onEvent?(event)
        }
        detection.windowControlMonitor.onEvent = deliver
        detection.finderTrashMonitor.onEvent = deliver
        guard monitor.start() else {
            operationalStatus = .failed("macOS did not create the pointer event monitor")
            return
        }
        operationalStatus = .monitoring
    }

    func stop() {
        monitor.stop()
        detection.cancelGestures()
        _ = chromeClickDetector.receive(.cancelled)
        generation += 1
        operationalStatus = .stopped
    }

    /// Hands a sample to the detection queue and brings what it found back to the main thread, in
    /// pointer order.
    private func route(_ sample: PointerSample) {
        let currentGeneration = generation
        let detection = detection
        let clickThrough = sample.phase == .down || sample.phase == .up ? Self.clickThroughWindows() : []
        detection.queue.async { [weak self] in
            let (snapshot, runtime) = detection.process(sample, clickThrough: clickThrough)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.receive(sample, snapshot: snapshot, runtime: runtime)
            }
        }
    }

    /// Keybumps' windows that let clicks through to the window below, such as its notch panels. AppKit
    /// lists them only on the main thread.
    private static func clickThroughWindows() -> Set<Int> {
        Set(NSApplication.shared.windows.filter(\.ignoresMouseEvents).map(\.windowNumber))
    }

    private func receive(_ sample: PointerSample, snapshot: AccessibilitySnapshot?, runtime: ChromeRuntimeState?) {
        switch sample.phase {
        case .dragged: _ = chromeClickDetector.receive(.dragged(sample))
        case .cancelled: _ = chromeClickDetector.receive(.cancelled)
        case .down:
            // Every press starts a new Chrome gesture, even one with nothing to describe (in
            // Keybumps, or unanswered).
            let chromeOutcome = chromeClickDetector.receive(.down(sample, snapshot, runtime ?? .unavailable))
            // A pending Chrome click waits for its drags and release, which follow in order.
            guard let snapshot, !chromeClickDetector.hasPendingCandidate else { return }
            let isChromeSettings = chromeClickDetector.runtimeRequirement(for: snapshot) == .settings
            if !isChromeSettings,
               let event = MenuActionEventResolver.makeEvent(from: snapshot) {
                let signature = "\(event.applicationName)|\(event.actionTitle)|\(event.shortcut)"
                if signature != lastMenuSignature || Date().timeIntervalSince(lastMenuEmission) > 1 {
                    lastMenuSignature = signature
                    lastMenuEmission = Date()
                    onEvent?(event)
                }
            } else if case .event(let event) = chromeOutcome {
                onEvent?(event)
            }
        case .up:
            _ = chromeClickDetector.receive(.up(sample, snapshot))
            guard chromeClickDetector.needsPostObservation else { return }
            scheduleChromePostObservation(generation: generation, attempt: 0)
        }
    }

    private func scheduleChromePostObservation(generation currentGeneration: Int, attempt: Int) {
        let delays: [TimeInterval] = [0.08, 0.10, 0.15, 0.20, 0.30]
        guard attempt < delays.count,
              let processIdentity = chromeClickDetector.pendingProcessIdentity else {
            _ = chromeClickDetector.receive(.cancelled)
            return
        }
        let runtimeRequirement = chromeClickDetector.postRuntimeRequirement
        let detection = detection
        detection.queue.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            let runtime = detection.chromeRuntimeReader.read(
                pid: processIdentity.pid,
                requirement: runtimeRequirement
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                let outcome = self.chromeClickDetector.receive(
                    .post(processIdentity, runtime, timestamp: ProcessInfo.processInfo.systemUptime)
                )
                if case .event(let event) = outcome {
                    self.onEvent?(event)
                } else if self.chromeClickDetector.needsPostObservation {
                    self.scheduleChromePostObservation(generation: currentGeneration, attempt: attempt + 1)
                }
            }
        }
    }
}

/// Shortcut Coach's Accessibility work, confined to `queue`, a serial queue of its own. Nothing here
/// runs on the main thread, where a click in a slow app, or in an open panel Keybumps shows (whose
/// service needs Keybumps' main thread to answer), used to freeze Keybumps (#212). The confinement is
/// what makes it safe to hand between threads.
final class DetectionPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.serp.keybumps.shortcut-coach.detection", qos: .userInitiated)
    let windowControlMonitor: StandardWindowControlMonitor
    let finderTrashMonitor: FinderTrashMonitor
    let chromeRuntimeReader: any ChromeRuntimeStateReading
    private let clickTargets: any ClickTargetProbing
    private let accessibility: DetectionAccessibility
    private let snapshotter: any AccessibilitySnapshotting

    init(
        clickTargets: any ClickTargetProbing,
        accessibility: DetectionAccessibility,
        snapshotter: any AccessibilitySnapshotting,
        chromeRuntimeReader: any ChromeRuntimeStateReading
    ) {
        self.clickTargets = clickTargets
        self.accessibility = accessibility
        self.snapshotter = snapshotter
        self.chromeRuntimeReader = chromeRuntimeReader
        windowControlMonitor = StandardWindowControlMonitor(queue: queue, accessibility: accessibility)
        finderTrashMonitor = FinderTrashMonitor(queue: queue, accessibility: accessibility)
    }

    /// On `queue`: hands the sample and its hit to every detector, and describes the hit for the
    /// menu and Chrome checks on the main thread.
    func process(_ sample: PointerSample, clickThrough: Set<Int>) -> (snapshot: AccessibilitySnapshot?, runtime: ChromeRuntimeState?) {
        let hit = sharedHit(for: sample, clickThrough: clickThrough)
        windowControlMonitor.handle(sample, hit: hit)
        finderTrashMonitor.handle(sample, hit: hit)
        let snapshot = hit.flatMap(snapshotter.snapshot(of:))
        guard sample.phase == .down, let snapshot else { return (snapshot, nil) }
        let requirement = ChromeActionAdapter().contextRequirement(for: snapshot)
        return (snapshot, chromeRuntimeReader.read(pid: snapshot.pid, requirement: requirement))
    }

    func cancelGestures() {
        windowControlMonitor.cancel()
        finderTrashMonitor.cancel()
    }

    /// The one Accessibility hit-test of a press or release, shared by every detector. A click on
    /// Keybumps' own windows is never hit-tested, so it's never coached either.
    private func sharedHit(for sample: PointerSample, clickThrough: Set<Int>) -> AXUIElement? {
        guard sample.phase == .down || sample.phase == .up else { return nil }
        accessibility.beginPressOrRelease()
        guard case .application(let pid) = clickTargets.target(at: sample.location, clickThrough: clickThrough) else { return nil }
        return accessibility.element(at: sample.location, in: pid)
    }
}
