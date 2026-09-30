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
    private let snapshotter: any AccessibilitySnapshotting
    private let permissions: any DetectorPermissionProviding
    private let chromeRuntimeReader: any ChromeRuntimeStateReading
    private let windowControlMonitor = StandardWindowControlMonitor()
    private let finderTrashMonitor = FinderTrashMonitor()
    private var chromeClickDetector = ChromeClickDetector()
    private var generation = 0
    private var downSnapshotPending = false
    private var bufferedMouseUp: PointerSample?
    private var bufferedDragLocations: [CGPoint] = []
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
        snapshotter: any AccessibilitySnapshotting = AccessibilitySnapshotter(),
        permissions: any DetectorPermissionProviding = SystemDetectorPermissions(),
        chromeRuntimeReader: any ChromeRuntimeStateReading = SystemChromeRuntimeStateReader()
    ) {
        self.monitor = monitor
        self.snapshotter = snapshotter
        self.permissions = permissions
        self.chromeRuntimeReader = chromeRuntimeReader
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

        monitor.onSample = { [weak self] sample in
            self?.windowControlMonitor.receive(sample)
            self?.finderTrashMonitor.receive(sample)
            DispatchQueue.main.async { self?.receive(sample) }
        }
        monitor.onTapRecovered = { [weak self] in
            self?.windowControlMonitor.cancel()
            self?.finderTrashMonitor.cancel()
            DispatchQueue.main.async { _ = self?.chromeClickDetector.receive(.cancelled) }
        }
        windowControlMonitor.onEvent = { [weak self] event in self?.onEvent?(event) }
        finderTrashMonitor.onEvent = { [weak self] event in self?.onEvent?(event) }
        guard monitor.start() else {
            operationalStatus = .failed("macOS did not create the pointer event monitor")
            return
        }
        operationalStatus = .monitoring
    }

    func stop() {
        monitor.stop()
        windowControlMonitor.cancel()
        finderTrashMonitor.cancel()
        _ = chromeClickDetector.receive(.cancelled)
        downSnapshotPending = false
        bufferedMouseUp = nil
        bufferedDragLocations.removeAll()
        generation += 1
        operationalStatus = .stopped
    }

    private func receive(_ sample: PointerSample) {
        switch sample.phase {
        case .dragged:
            if downSnapshotPending {
                bufferedDragLocations.append(sample.location)
            } else {
                _ = chromeClickDetector.receive(.dragged(sample))
            }
        case .cancelled: _ = chromeClickDetector.receive(.cancelled)
        case .down:
            downSnapshotPending = true
            bufferedMouseUp = nil
            bufferedDragLocations.removeAll()
            let currentGeneration = generation
            snapshotter.snapshot(at: sample.location) { [weak self] snapshot in
                guard let self, self.generation == currentGeneration else { return }
                self.downSnapshotPending = false
                guard let snapshot else {
                    self.bufferedMouseUp = nil
                    self.bufferedDragLocations.removeAll()
                    return
                }
                let runtimeRequirement = self.chromeClickDetector.runtimeRequirement(for: snapshot)
                let chromeRuntime = self.chromeRuntimeReader.read(pid: snapshot.pid, requirement: runtimeRequirement)
                let chromeOutcome = self.chromeClickDetector.receive(.down(sample, snapshot, chromeRuntime))
                let isChromeSettings = runtimeRequirement == .settings
                if self.chromeClickDetector.hasPendingCandidate {
                    for location in self.bufferedDragLocations {
                        let drag = PointerSample(phase: .dragged, location: location, modifiers: sample.modifiers, timestamp: sample.timestamp)
                        _ = self.chromeClickDetector.receive(.dragged(drag))
                    }
                    self.bufferedDragLocations.removeAll()
                    if let mouseUp = self.bufferedMouseUp {
                        self.bufferedMouseUp = nil
                        self.handleMouseUp(mouseUp, generation: currentGeneration)
                    }
                } else if !isChromeSettings,
                          let event = MenuActionEventResolver.makeEvent(from: snapshot) {
                    let signature = "\(event.applicationName)|\(event.actionTitle)|\(event.shortcut)"
                    if signature != self.lastMenuSignature || Date().timeIntervalSince(self.lastMenuEmission) > 1 {
                        self.lastMenuSignature = signature
                        self.lastMenuEmission = Date()
                        self.onEvent?(event)
                    }
                } else if case .event(let event) = chromeOutcome {
                    self.onEvent?(event)
                }
            }
        case .up:
            if downSnapshotPending {
                bufferedMouseUp = sample
            } else {
                handleMouseUp(sample, generation: generation)
            }
        }
    }

    private func handleMouseUp(_ sample: PointerSample, generation currentGeneration: Int) {
        snapshotter.snapshot(at: sample.location) { [weak self] upSnapshot in
                guard let self, self.generation == currentGeneration else { return }
                _ = self.chromeClickDetector.receive(.up(sample, upSnapshot))
                guard self.chromeClickDetector.needsPostObservation else { return }
                self.scheduleChromePostObservation(generation: currentGeneration, attempt: 0)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            let runtime = self.chromeRuntimeReader.read(
                pid: processIdentity.pid,
                requirement: runtimeRequirement
            )
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
