import CoreGraphics
import Foundation

struct ActionCorrelator {
    let maximumDuration: TimeInterval
    let deduplicationWindow: TimeInterval
    private(set) var candidate: ManualActionCandidate?
    private(set) var downTimestamp: TimeInterval = 0
    private(set) var dragDistance: CGFloat = 0
    private var lastSignature: String?
    private var lastEmissionTimestamp: TimeInterval = -.infinity

    init(maximumDuration: TimeInterval = 1.5, deduplicationWindow: TimeInterval = 1) {
        self.maximumDuration = maximumDuration
        self.deduplicationWindow = deduplicationWindow
    }

    mutating func begin(_ candidate: ManualActionCandidate, at timestamp: TimeInterval, modifiers: CGEventFlags) {
        guard modifiers.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { cancel(); return }
        self.candidate = candidate
        downTimestamp = timestamp
        dragDistance = 0
    }

    mutating func observeDrag(to point: CGPoint) {
        guard let candidate else { return }
        dragDistance = max(dragDistance, hypot(point.x - candidate.point.x, point.y - candidate.point.y))
    }

    mutating func markDragged() { dragDistance = .infinity }
    mutating func cancel() { candidate = nil; dragDistance = 0 }

    mutating func acceptsMouseUp(_ sample: PointerSample, hit: AccessibilitySnapshot?) -> Bool {
        guard let candidate, dragDistance <= 4,
              sample.timestamp - downTimestamp <= maximumDuration,
              sample.modifiers.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              candidate.targetFrame?.contains(sample.location) != false else { cancel(); return false }
        if hit == nil, case .chromeSettings = candidate.kind {
            return true
        }
        guard hit?.bundleIdentifier == candidate.preSnapshot.bundleIdentifier else { cancel(); return false }
        return true
    }

    mutating func verify(post: AccessibilitySnapshot, runtime: ChromeRuntimeState, at timestamp: TimeInterval) -> CoachingEvent? {
        guard let candidate else { return nil }
        defer { cancel() }
        guard post.bundleIdentifier == candidate.preSnapshot.bundleIdentifier else { return nil }
        let event: CoachingEvent?
        switch candidate.kind {
        case .chromeNewTab
            where tabStates(candidate.preRuntime, runtime, satisfy: { $1.tabs.count == $0.tabs.count + 1 }):
            event = liveEvent(
                title: "New Tab",
                pre: candidate.preRuntime.tabShortcuts.newTab,
                post: runtime.tabShortcuts.newTab,
                candidate: candidate
            )
        case .chromeCloseActiveTab(let token)
            where tabStates(candidate.preRuntime, runtime, satisfy: {
                $1.tabs.count == $0.tabs.count - 1 && !$1.tabs.contains(where: { $0.token == token })
            }):
            event = liveEvent(
                title: "Close Tab",
                pre: candidate.preRuntime.tabShortcuts.closeTab,
                post: runtime.tabShortcuts.closeTab,
                candidate: candidate
            )
        case .chromeSelectTab(let token, let index, let count)
            where tabStates(candidate.preRuntime, runtime, satisfy: {
                $1.tabs.count == count && $1.tabs.first(where: { $0.token == token })?.selected == true
            }):
            let shortcutIndex = min(index, 9)
            let preResolution = candidate.preRuntime.tabShortcuts.directSelection[shortcutIndex] ?? .unavailable
            let postResolution = runtime.tabShortcuts.directSelection[shortcutIndex] ?? .unavailable
            if let live = liveEvent(
                title: "Select Tab \(index)",
                pre: preResolution,
                post: postResolution,
                candidate: candidate
            ) {
                event = live
            } else if preResolution == .unavailable,
                      postResolution == .unavailable,
                      ChromeShortcutCatalog.isCompatible(
                          snapshotVersion: candidate.preSnapshot.applicationVersion,
                          preRuntimeVersion: candidate.preRuntime.applicationVersion,
                          postRuntimeVersion: runtime.applicationVersion
                      ) {
                event = characterizedEvent(
                    title: "Select Tab \(index)",
                    shortcut: ChromeShortcutCatalog.selectTab(index: index),
                    candidate: candidate
                )
            } else {
                event = nil
            }
        case .chromeSettings(let shortcut)
            where runtime.destination == .settings && runtime.settingsShortcut == .resolved(shortcut):
            event = CoachingEventFactory.make(
                applicationName: candidate.applicationName,
                actionTitle: "Settings",
                shortcutEvidence: shortcut.evidence,
                pointerX: candidate.point.x,
                pointerY: candidate.point.y
            )
        default: event = nil
        }
        guard let event else { return nil }
        let signature = "\(event.applicationName)|\(event.actionTitle)|\(event.shortcut)"
        guard signature != lastSignature || timestamp - lastEmissionTimestamp > deduplicationWindow else { return nil }
        lastSignature = signature
        lastEmissionTimestamp = timestamp
        return event
    }

    private func characterizedEvent(
        title: String,
        shortcut: String,
        candidate: ManualActionCandidate
    ) -> CoachingEvent? {
        CoachingEventFactory.makeCharacterized(
            applicationName: candidate.applicationName,
            actionTitle: title,
            displayShortcut: shortcut,
            adapterID: ChromeShortcutCatalog.adapterID,
            compatibleApplicationVersion: ChromeShortcutCatalog.characterizedChromeVersion,
            pointerX: candidate.point.x,
            pointerY: candidate.point.y
        )
    }

    private func liveEvent(
        title: String,
        pre: LiveShortcutResolution,
        post: LiveShortcutResolution,
        candidate: ManualActionCandidate
    ) -> CoachingEvent? {
        guard case .resolved(let preShortcut) = pre,
              case .resolved(let postShortcut) = post,
              preShortcut == postShortcut else { return nil }
        return CoachingEventFactory.make(
            applicationName: candidate.applicationName,
            actionTitle: title,
            shortcutEvidence: preShortcut.evidence,
            pointerX: candidate.point.x,
            pointerY: candidate.point.y
        )
    }

    private func tabStates(
        _ pre: ChromeRuntimeState,
        _ post: ChromeRuntimeState,
        satisfy predicate: (ChromeTabState, ChromeTabState) -> Bool
    ) -> Bool {
        guard let preTabs = pre.tabs, let postTabs = post.tabs,
              preTabs.containerToken == postTabs.containerToken else { return false }
        return predicate(preTabs, postTabs)
    }
}

enum ChromeClickObservation: Equatable, Sendable {
    case down(PointerSample, AccessibilitySnapshot?, ChromeRuntimeState)
    case dragged(PointerSample)
    case up(PointerSample, AccessibilitySnapshot?)
    case post(AccessibilitySnapshot?, ChromeRuntimeState, timestamp: TimeInterval)
    case cancelled
}

enum ChromeClickSuppression: Equatable, Sendable {
    case unrecognizedAction
    case invalidGesture
    case missingPostObservation
    case postconditionFailed
    case cancelled
}

enum ChromeClickOutcome: Equatable, Sendable {
    case pending
    case suppressed(ChromeClickSuppression)
    case event(CoachingEvent)
}

struct ChromeClickDetector {
    private let adapter = ChromeActionAdapter()
    private var correlator = ActionCorrelator()
    private var ignoringGesture = false
    private(set) var needsPostObservation = false
    var hasPendingCandidate: Bool { correlator.candidate != nil }
    var postRuntimeRequirement: ChromeRuntimeRequirement {
        guard let candidate = correlator.candidate else { return .none }
        if case .chromeSettings = candidate.kind { return .settings }
        return .tabs
    }

    func runtimeRequirement(for snapshot: AccessibilitySnapshot) -> ChromeRuntimeRequirement {
        adapter.contextRequirement(for: snapshot)
    }

    mutating func receive(_ observation: ChromeClickObservation) -> ChromeClickOutcome {
        switch observation {
        case .down(let sample, let snapshot, let runtime):
            ignoringGesture = false
            needsPostObservation = false
            guard let snapshot, let candidate = adapter.classify(snapshot, runtime: runtime, point: sample.location) else {
                correlator.cancel()
                ignoringGesture = true
                return .suppressed(.unrecognizedAction)
            }
            correlator.begin(candidate, at: sample.timestamp, modifiers: sample.modifiers)
            guard correlator.candidate != nil else { return .suppressed(.invalidGesture) }
            return .pending
        case .dragged(let sample):
            guard !ignoringGesture else { return .pending }
            correlator.observeDrag(to: sample.location)
            return .pending
        case .up(let sample, let snapshot):
            if ignoringGesture {
                ignoringGesture = false
                return .pending
            }
            guard correlator.acceptsMouseUp(sample, hit: snapshot) else { return .suppressed(.invalidGesture) }
            needsPostObservation = true
            return .pending
        case .post(let snapshot, let runtime, let timestamp):
            needsPostObservation = false
            guard let snapshot else {
                correlator.cancel()
                return .suppressed(.missingPostObservation)
            }
            guard let event = correlator.verify(post: snapshot, runtime: runtime, at: timestamp) else {
                return .suppressed(.postconditionFailed)
            }
            return .event(event)
        case .cancelled:
            ignoringGesture = false
            needsPostObservation = false
            correlator.cancel()
            return .suppressed(.cancelled)
        }
    }
}
