import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// Shortcut Coach's click checks (#212): where a click lands, the one Accessibility hit-test each
/// press and release gets, its timeout, and the queue it runs on.
///
/// Every process here is made up: macOS never hands out a process identifier above 99,999. No test
/// sends a real Accessibility message. The fakes answer none, and creating an element sends nothing.
enum FakeProcess {
    static let keybumps: pid_t = 900_001
    static let app: pid_t = 900_002
    static let otherApp: pid_t = 900_003
    static let panelService: pid_t = 900_004
    static let windowServer: pid_t = 900_005
}

@Suite("Shortcut Coach click targets")
struct ClickTargetProbeTests {
    static let point = CGPoint(x: 400, y: 300)
    static let under = CGRect(x: 100, y: 100, width: 600, height: 400)
    static let elsewhere = CGRect(x: 900, y: 100, width: 200, height: 200)
    static let menuBar = CGRect(x: 0, y: 0, width: 1728, height: 33)
    static let bundles: [pid_t: String] = [
        FakeProcess.keybumps: "com.serp.keybumps",
        FakeProcess.app: "com.example.app",
        FakeProcess.otherApp: "com.example.other",
        FakeProcess.panelService: WindowListClickTargetProbe.openAndSavePanelService
    ]

    @Test("A click on Keybumps' own window is Keybumps'")
    func ownWindow() {
        #expect(probe([window(FakeProcess.keybumps, Self.under)]).target(at: Self.point) == .keybumps)
        let stacked = [
            window(FakeProcess.app, Self.elsewhere),
            window(FakeProcess.keybumps, Self.under, layer: 101),
            window(FakeProcess.app, Self.under)
        ]
        #expect(probe(stacked).target(at: Self.point) == .keybumps, "Keybumps' menu in front of an app's window")
    }

    @Test("Another app's window in front of Keybumps' gets the click")
    func appInFront() {
        let stacked = [window(FakeProcess.app, Self.under), window(FakeProcess.keybumps, Self.under)]
        #expect(probe(stacked).target(at: Self.point) == .application(FakeProcess.app))
    }

    @Test("The cursor, drag images, and invisible windows never take a click")
    func windowsThatTakeNoClicks() {
        let cursor = CGRect(x: Self.point.x - 5, y: Self.point.y - 5, width: 37, height: 35)
        let stacked = [
            window(FakeProcess.windowServer, cursor, layer: CGWindowLevelForKey(.cursorWindow)),
            window(FakeProcess.otherApp, Self.under, layer: CGWindowLevelForKey(.draggingWindow)),
            window(FakeProcess.keybumps, Self.under, alpha: 0),
            window(FakeProcess.app, Self.under)
        ]
        // Taken as the target, the Window Server's cursor would send the click to the app in front.
        #expect(probe(stacked, frontmost: FakeProcess.otherApp).target(at: Self.point) == .application(FakeProcess.app))
    }

    @Test("The menu bar goes to the app in front, and is Keybumps' while Keybumps is in front")
    func menuBar() {
        // The Window Server draws the menu bar, status items included; it isn't an app.
        let point = CGPoint(x: 1500, y: 10)
        let windows = [window(FakeProcess.windowServer, Self.menuBar, layer: CGWindowLevelForKey(.mainMenuWindow))]
        #expect(probe(windows, frontmost: FakeProcess.app).target(at: point) == .application(FakeProcess.app))
        #expect(probe(windows, frontmost: FakeProcess.keybumps).target(at: point) == .keybumps)
        #expect(probe(windows, frontmost: nil).target(at: point) == .nothing)
    }

    @Test("An open or save panel is Keybumps' while Keybumps is in front")
    func openPanel() {
        // The panel's window belongs to AppKit's panel service, which answers on the main thread of
        // the app showing it.
        let windows = [window(FakeProcess.panelService, Self.under), window(FakeProcess.keybumps, Self.under)]
        #expect(probe(windows, frontmost: FakeProcess.keybumps).target(at: Self.point) == .keybumps)
        #expect(probe(windows, frontmost: FakeProcess.app).target(at: Self.point) == .application(FakeProcess.panelService))
    }

    @Test("Nothing under the point is nothing")
    func nothing() {
        #expect(probe([window(FakeProcess.app, Self.elsewhere)]).target(at: Self.point) == .nothing)
        #expect(probe([]).target(at: Self.point) == .nothing)
    }

    private func probe(_ windows: [[String: Any]], frontmost: pid_t? = FakeProcess.app) -> WindowListClickTargetProbe {
        WindowListClickTargetProbe(
            ownProcess: FakeProcess.keybumps,
            windows: { windows },
            bundleIdentifier: { Self.bundles[$0] },
            frontmostApplication: { frontmost }
        )
    }

    /// A window as `CGWindowListCopyWindowInfo` describes it. Titles are never read.
    private func window(_ owner: pid_t, _ frame: CGRect, layer: Int32 = 0, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: owner),
            kCGWindowBounds as String: frame.dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha)
        ]
    }
}

@Suite("Shortcut Coach Accessibility messages")
struct DetectionAccessibilityTests {
    static let point = CGPoint(x: 400, y: 300)

    @Test("The hit-test and every read time out after a quarter second, set on the app's elements only")
    func messagingTimeout() {
        let log = AccessibilityLog()
        let hit = AXUIElementCreateApplication(FakeProcess.app)
        let accessibility = DetectionAccessibility.recording(log) { _ in hit }

        #expect(accessibility.element(at: Self.point, in: FakeProcess.app) === hit)
        _ = accessibility.copyAttribute(kAXRoleAttribute, from: hit)
        _ = accessibility.actionNames(of: hit)

        #expect(log.messages.map(\.name) == [AccessibilityLog.hitTest, kAXRoleAttribute, AccessibilityLog.actions])
        #expect(log.messages.allSatisfy { $0.timeout == 0.25 }, "each element had its timeout before its message")
        #expect(log.hitTestPoints == [Self.point])
        // Set on the system-wide element, a timeout would apply to all of Keybumps (Window Manager's
        // moves too), so it's set on the app's elements.
        #expect(!log.timedOutElements.isEmpty)
        #expect(log.timedOutElements.allSatisfy { !CFEqual($0, AXUIElementCreateSystemWide()) && processIdentifier(of: $0) == FakeProcess.app })
    }

    @Test("Keybumps' own elements are never messaged")
    func ownElements() {
        let log = AccessibilityLog()
        let own = AXUIElementCreateApplication(FakeProcess.keybumps)
        var accessibility = DetectionAccessibility.recording(log) { _ in own }
        accessibility.ownProcess = FakeProcess.keybumps

        #expect(accessibility.element(at: Self.point, in: FakeProcess.keybumps) == nil)
        #expect(accessibility.copyAttribute(kAXParentAttribute, from: own) == nil)
        #expect(accessibility.actionNames(of: own).isEmpty)
        #expect(log.messages.isEmpty)

        // A hit in another app can lead into Keybumps, as an open panel's remote view does.
        #expect(accessibility.element(at: Self.point, in: FakeProcess.app) == nil)
        #expect(log.messages.map(\.name) == [AccessibilityLog.hitTest])
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}

@MainActor
@Suite("Shortcut Coach click hit-tests")
struct ClickHitTestTests {
    static let point = CGPoint(x: 400, y: 300)
    static let elsewhere = CGPoint(x: 950, y: 150)

    @Test("A click on Keybumps' own windows never reaches the hit-test")
    func ownWindowsAreNeverHitTested() async throws {
        let harness = DetectorHarness(targets: [.keybumps, .keybumps, .application(FakeProcess.app)]) { _ in nil }
        defer { harness.stop() }

        harness.click(at: Self.point)
        harness.press(at: Self.elsewhere)
        // The detection queue is serial, so the press after the click is hit-tested after the click is done.
        try await harness.waitUntil { harness.log.count(of: AccessibilityLog.hitTest) == 1 }

        #expect(harness.log.hitTestPoints == [Self.elsewhere])
        #expect(harness.log.messages.map(\.name) == [AccessibilityLog.hitTest], "and nothing else asked about the click")
    }

    @Test("Every detector reads the one hit-test of each press and release")
    func detectorsShareOneHitTest() async throws {
        let hit = AXUIElementCreateApplication(FakeProcess.app)
        let harness = DetectorHarness(targets: [.application(FakeProcess.app), .application(FakeProcess.app), .nothing]) { _ in hit }
        defer { harness.stop() }

        harness.click(at: Self.point)
        harness.press(at: Self.elsewhere)
        try await harness.waitUntil { harness.targets.callCount == 3 }

        #expect(harness.log.count(of: AccessibilityLog.hitTest) == 2, "one for the press and one for the release, not one per detector")
        let reads = harness.log.messages.filter { $0.name != AccessibilityLog.hitTest }
        #expect(reads.contains { $0.name == kAXRoleAttribute }, "the detectors read the hit")
        #expect(reads.allSatisfy { $0.element === hit }, "and only the shared hit")
        #expect(harness.log.messages.allSatisfy { $0.timeout == DetectionAccessibility.messagingTimeout })
        #expect(harness.log.messages.allSatisfy { !$0.onMainThread })
    }

    @Test("The hit-test runs off the main thread, which stays free while an app is slow to answer")
    func hitTestNeverBlocksTheMainThread() async throws {
        let app = SlowApp()
        let harness = DetectorHarness(targets: [.application(FakeProcess.app)]) { _ in app.answer() }
        defer {
            app.release()
            harness.stop()
        }

        harness.press(at: Self.point)
        try await harness.waitUntil { harness.log.count(of: AccessibilityLog.hitTest) == 1 }

        let clock = ContinuousClock()
        let start = clock.now
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(clock.now - start < .milliseconds(500), "the main queue ran while the app hadn't answered")
        #expect(!app.answered, "the hit-test was still waiting")

        app.release()
        try await harness.waitUntil { app.answered }
        #expect(harness.log.messages.allSatisfy { !$0.onMainThread })
    }

    @Test("A menu click in another app is coached, and the same click in Keybumps isn't")
    func menuClicksStillCoached() async throws {
        let targets: [ClickTarget] = [.keybumps, .keybumps, .application(FakeProcess.app), .application(FakeProcess.app)]
        let harness = DetectorHarness(targets: targets, snapshotter: MenuItemSnapshotter()) { _ in
            AXUIElementCreateApplication(FakeProcess.app)
        }
        defer { harness.stop() }
        var events: [CoachingEvent] = []
        harness.detector.onEvent = { events.append($0) }

        harness.click(at: Self.point)
        harness.click(at: Self.point, timestamp: 3)
        try await harness.waitUntil { !events.isEmpty }
        try await Task.sleep(for: .milliseconds(100))

        #expect(events.map(\.actionTitle) == ["Duplicate"])
        #expect(events.map(\.shortcut) == ["⌘D"])
    }
}

// MARK: - Test doubles

/// Every Accessibility message a `DetectionAccessibility` would send, none of them answered. The
/// detection queue writes it and the test reads it.
final class AccessibilityLog: @unchecked Sendable {
    static let hitTest = "hitTest"
    static let actions = "actions"

    struct Message {
        let name: String
        let element: AXUIElement
        /// The timeout the element had when it was messaged.
        let timeout: Float?
        let onMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Message] = []
    private var points: [CGPoint] = []
    private var timeouts: [(element: AXUIElement, seconds: Float)] = []

    var messages: [Message] { lock.withLock { recorded } }
    var hitTestPoints: [CGPoint] { lock.withLock { points } }
    var timedOutElements: [AXUIElement] { lock.withLock { timeouts.map(\.element) } }
    func count(of name: String) -> Int { messages.filter { $0.name == name }.count }

    func setTimeout(_ element: AXUIElement, _ seconds: Float) {
        lock.withLock { timeouts.append((element, seconds)) }
    }

    func record(_ name: String, _ element: AXUIElement, at point: CGPoint? = nil) {
        lock.withLock {
            let timeout = timeouts.last { $0.element === element }?.seconds
            recorded.append(Message(name: name, element: element, timeout: timeout, onMainThread: Thread.isMainThread))
            if let point { points.append(point) }
        }
    }
}

extension DetectionAccessibility {
    /// Records every message in `log` and answers none, apart from the hit-test's `hit`.
    static func recording(_ log: AccessibilityLog, hit: @escaping (CGPoint) -> AXUIElement?) -> DetectionAccessibility {
        var accessibility = DetectionAccessibility()
        accessibility.setMessagingTimeout = { log.setTimeout($0, $1) }
        accessibility.copyElementAtPosition = { application, point in
            log.record(AccessibilityLog.hitTest, application, at: point)
            return hit(point)
        }
        accessibility.copyAttributeValue = { element, name in
            log.record(name, element)
            return nil
        }
        accessibility.copyActionNames = { element in
            log.record(AccessibilityLog.actions, element)
            return []
        }
        return accessibility
    }
}

/// Answers each press and release with the next target, then the last one again.
final class ScriptedClickTargets: ClickTargetProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ClickTarget]
    private var calls = 0

    init(_ targets: [ClickTarget]) { remaining = targets }

    var callCount: Int { lock.withLock { calls } }

    func target(at point: CGPoint) -> ClickTarget {
        lock.withLock {
            calls += 1
            return remaining.count > 1 ? remaining.removeFirst() : remaining.first ?? .nothing
        }
    }
}

/// An app that doesn't answer the hit-test until the test lets it.
final class SlowApp: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didAnswer = false

    var answered: Bool { lock.withLock { didAnswer } }

    func answer() -> AXUIElement? {
        _ = gate.wait(timeout: .now() + 2)
        lock.withLock { didAnswer = true }
        return nil
    }

    func release() { gate.signal() }
}

/// Describes every hit as Finder's File > Duplicate (⌘D).
struct MenuItemSnapshotter: AccessibilitySnapshotting {
    func snapshot(of hit: AXUIElement) -> AccessibilitySnapshot? {
        let item = AXNodeSnapshot(
            token: "duplicate", role: kAXMenuItemRole as String, subrole: nil, title: "Duplicate",
            elementDescription: nil, identifier: nil, value: nil, selected: nil, enabled: true,
            actions: [kAXPressAction as String], frame: nil, menuShortcut: nil,
            menuShortcutEvidence: AXShortcutEvidence(commandCharacter: "D", modifiers: 0, commandGlyph: nil, virtualKey: nil)
        )
        return AccessibilitySnapshot(pid: FakeProcess.app, bundleIdentifier: "com.example.app", applicationName: "Example App",
                                     hit: item, ancestors: [])
    }
}

private final class SamplePointerMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    func start() -> Bool { true }
    func stop() {}
}

private struct GrantedDetectorPermissions: DetectorPermissionProviding {
    var isAccessibilityTrusted: Bool { true }
    var isInputMonitoringAuthorized: Bool { true }
    func requestAccessibility() {}
    func requestInputMonitoring() {}
}

private struct UnavailableChromeRuntime: ChromeRuntimeStateReading {
    func read(pid: Int32, requirement: ChromeRuntimeRequirement) -> ChromeRuntimeState { .unavailable }
}

/// A running `ManualActionDetector` whose clicks come from the test, with made-up click targets and
/// an Accessibility log in place of the system.
@MainActor
private final class DetectorHarness {
    let monitor = SamplePointerMonitor()
    let log = AccessibilityLog()
    let targets: ScriptedClickTargets
    let detector: ManualActionDetector

    init(targets: [ClickTarget], snapshotter: (any AccessibilitySnapshotting)? = nil,
         hit: @escaping (CGPoint) -> AXUIElement?) {
        self.targets = ScriptedClickTargets(targets)
        detector = ManualActionDetector(
            monitor: monitor,
            snapshotter: snapshotter,
            permissions: GrantedDetectorPermissions(),
            chromeRuntimeReader: UnavailableChromeRuntime(),
            clickTargets: self.targets,
            accessibility: .recording(log, hit: hit)
        )
        detector.start()
    }

    func press(at point: CGPoint, timestamp: TimeInterval = 1) {
        monitor.onSample?(PointerSample(phase: .down, location: point, modifiers: [], timestamp: timestamp))
    }

    func click(at point: CGPoint, timestamp: TimeInterval = 1) {
        press(at: point, timestamp: timestamp)
        monitor.onSample?(PointerSample(phase: .up, location: point, modifiers: [], timestamp: timestamp + 0.1))
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for Shortcut Coach's detection queue")
    }

    func stop() { detector.stop() }
}
