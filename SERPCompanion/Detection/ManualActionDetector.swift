import ApplicationServices
import CoreGraphics
import Foundation

protocol DetectorPermissionProviding {
    var isAccessibilityTrusted: Bool { get }
    var isInputMonitoringAuthorized: Bool { get }
    func requestAccessibility()
    func requestInputMonitoring()
}

struct SystemDetectorPermissions: DetectorPermissionProviding {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    var isInputMonitoringAuthorized: Bool { CGPreflightListenEventAccess() }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        CGRequestListenEventAccess()
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
    private let snapshotter: AccessibilitySnapshotter
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
        snapshotter: AccessibilitySnapshotter = AccessibilitySnapshotter(),
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
                   let shortcut = snapshot.hit.menuShortcut,
                   snapshot.hit.role == kAXMenuItemRole as String,
                   let title = snapshot.hit.title, !title.isEmpty {
                    let signature = "\(snapshot.applicationName)|\(title)|\(shortcut)"
                    if signature != self.lastMenuSignature || Date().timeIntervalSince(self.lastMenuEmission) > 1 {
                        self.lastMenuSignature = signature
                        self.lastMenuEmission = Date()
                        self.onEvent?(CoachingEvent(applicationName: snapshot.applicationName, actionTitle: title,
                                                    shortcut: shortcut, pointerX: sample.location.x, pointerY: sample.location.y))
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
                let runtimeRequirement = self.chromeClickDetector.postRuntimeRequirement
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.snapshotter.snapshot(at: sample.location) { [weak self] post in
                        guard let self, self.generation == currentGeneration else { return }
                        let runtime = post.map {
                            self.chromeRuntimeReader.read(pid: $0.pid, requirement: runtimeRequirement)
                        } ?? .unavailable
                        if case .event(let event) = self.chromeClickDetector.receive(
                            .post(post, runtime, timestamp: ProcessInfo.processInfo.systemUptime)
                        ) {
                            self.onEvent?(event)
                        }
                    }
                }
            }
    }
}
