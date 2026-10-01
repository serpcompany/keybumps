import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Keybumps

/// Shortcut Coach's click checks (#212): where a click lands, the one Accessibility hit-test each
/// press and release gets, its timeout, the queue it runs on, and the checks after a click.
///
/// Every process here is made up: macOS never hands out a process identifier above 99,999. No test
/// sends a real Accessibility message. The fakes answer from their own tables, and creating an
/// element sends nothing.
enum FakeProcess {
    static let keybumps: pid_t = 900_001
    static let app: pid_t = 900_002
    static let otherApp: pid_t = 900_003
    static let panelService: pid_t = 900_004
    static let windowServer: pid_t = 900_005
    static let chrome: pid_t = 900_006
    // A made-up app's elements are told apart by process, so each part of its window gets its own.
    static let window: pid_t = 900_007
    static let menuBar: pid_t = 900_008
    static let menuItem: pid_t = 900_009
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

    @Test("Keybumps' click-through panels, like the notch notice, let the click through to the window below")
    func clickThroughPanels() {
        // The window list can't tell a panel that ignores mouse events from one that takes them.
        let notice = 4_101
        let stacked = [
            window(FakeProcess.keybumps, Self.under, layer: CGWindowLevelForKey(.popUpMenuWindow), number: notice),
            window(FakeProcess.app, Self.under)
        ]
        #expect(probe(stacked).target(at: Self.point, clickThrough: [notice]) == .application(FakeProcess.app))
        #expect(probe(stacked).target(at: Self.point, clickThrough: [4_102]) == .keybumps, "a panel that takes clicks is Keybumps'")
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
    private func window(_ owner: pid_t, _ frame: CGRect, layer: Int32 = 0, alpha: Double = 1, number: Int = 1) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: number),
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

    @Test("An app that doesn't answer in time is asked nothing more until the next press or release")
    func unresponsiveApp() {
        let log = AccessibilityLog()
        let hit = AXUIElementCreateApplication(FakeProcess.app)
        let other = AXUIElementCreateApplication(FakeProcess.otherApp)
        let accessibility = DetectionAccessibility.recording(log, unresponsive: [FakeProcess.app]) { _ in hit }

        accessibility.beginPressOrRelease()
        #expect(accessibility.element(at: Self.point, in: FakeProcess.app) === hit)
        #expect(accessibility.copyAttribute(kAXRoleAttribute, from: hit) == nil, "timed out")
        _ = accessibility.copyAttribute(kAXParentAttribute, from: hit)
        _ = accessibility.actionNames(of: hit)
        #expect(accessibility.element(at: Self.point, in: FakeProcess.app) == nil)
        #expect(log.messages.map(\.name) == [AccessibilityLog.hitTest, kAXRoleAttribute], "nothing after the timeout")

        _ = accessibility.copyAttribute(kAXRoleAttribute, from: other)
        #expect(log.messages.last?.element === other, "other apps are still asked")

        accessibility.beginPressOrRelease()
        #expect(accessibility.element(at: Self.point, in: FakeProcess.app) === hit, "the next press or release asks again")
        #expect(log.count(of: AccessibilityLog.hitTest) == 2)
    }

    @Test("An app whose hit-test times out is asked nothing more during that press or release")
    func unresponsiveHitTest() {
        let log = AccessibilityLog()
        var accessibility = DetectionAccessibility.recording(log) { _ in nil }
        accessibility.copyElementAtPosition = { application, point in
            log.record(AccessibilityLog.hitTest, application, at: point)
            return (.cannotComplete, nil)
        }
        let element = AXUIElementCreateApplication(FakeProcess.app)

        accessibility.beginPressOrRelease()
        #expect(accessibility.element(at: Self.point, in: FakeProcess.app) == nil)
        #expect(accessibility.copyAttribute(kAXRoleAttribute, from: element) == nil)
        #expect(accessibility.actionNames(of: element).isEmpty)
        #expect(log.messages.map(\.name) == [AccessibilityLog.hitTest])
    }

    @Test("A check after the click gives the app it asks one fresh try, and no other app")
    func delayedCheckAsksAgain() {
        let log = AccessibilityLog()
        let app = AXUIElementCreateApplication(FakeProcess.app)
        let other = AXUIElementCreateApplication(FakeProcess.otherApp)
        let accessibility = DetectionAccessibility.recording(log, unresponsive: [FakeProcess.app, FakeProcess.otherApp]) { _ in nil }

        accessibility.beginPressOrRelease()
        _ = accessibility.copyAttribute(kAXRoleAttribute, from: app)
        _ = accessibility.copyAttribute(kAXRoleAttribute, from: other)
        #expect(log.messages.count == 2, "both timed out during the click")

        accessibility.beginDelayedCheck(of: FakeProcess.app)
        _ = accessibility.copyAttribute(kAXRoleAttribute, from: other)
        _ = accessibility.copyAttribute(kAXRoleAttribute, from: app)
        _ = accessibility.copyAttribute(kAXParentAttribute, from: app)
        _ = accessibility.actionNames(of: app)
        #expect(log.messages.count == 3, "one more message: the app's fresh try, which timed out again")
        #expect(log.messages.last?.element === app)
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

    @Test("Each press and release tells the probe which of Keybumps' windows let clicks through")
    func clickThroughWindowsReachTheProbe() async throws {
        // Never ordered in, so never on screen; a window has its number once it's created.
        let clickThrough = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        clickThrough.ignoresMouseEvents = true
        let takesClicks = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let harness = DetectorHarness(targets: [.nothing]) { _ in nil }
        defer { harness.stop() }

        harness.click(at: Self.point)
        try await harness.waitUntil { harness.targets.callCount == 2 }

        let received = harness.targets.clickThrough
        #expect(received.count == 2, "the press and the release")
        #expect(received.allSatisfy { $0.contains(clickThrough.windowNumber) })
        #expect(received.allSatisfy { !$0.contains(takesClicks.windowNumber) })
    }

    @Test("An app that stops answering after the hit-test is asked nothing more that press or release")
    func unresponsiveAppIsAskedNothingMore() async throws {
        let hit = AXUIElementCreateApplication(FakeProcess.app)
        let harness = DetectorHarness(targets: [.application(FakeProcess.app), .application(FakeProcess.app), .nothing],
                                      unresponsive: [FakeProcess.app]) { _ in hit }
        defer { harness.stop() }

        harness.click(at: Self.point)
        harness.press(at: Self.elsewhere)
        try await harness.waitUntil { harness.targets.callCount == 3 }

        // Each of the press and the release: its hit-test, then the first read, which timed out.
        let names = harness.log.messages.map(\.name)
        #expect(names.count == 4)
        #expect(names.enumerated().allSatisfy { ($0.offset % 2 == 0) == ($0.element == AccessibilityLog.hitTest) })
    }

    @Test("A window-control tip verified just before Shortcut Coach stops, as locking stops it, never arrives")
    func eventsAfterStopAreDropped() async {
        let harness = DetectorHarness(targets: [.nothing]) { _ in nil }
        defer { harness.stop() }
        var events: [CoachingEvent] = []
        harness.detector.onEvent = { events.append($0) }
        let windowControl = harness.detector.detection.windowControlMonitor
        let finder = harness.detector.detection.finderTrashMonitor
        let minimize = CoachingEvent(applicationName: "Example App", actionTitle: "Minimize Window", shortcut: "⌘M")

        // What each detector queues for the main thread once it verifies an action on the detection queue.
        DispatchQueue.main.async {
            windowControl.onEvent?(minimize)
            finder.onEvent?(minimize)
        }
        harness.stop()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(events.isEmpty, "no tip, and nothing for history")

        harness.detector.start()
        windowControl.onEvent?(minimize)
        #expect(events.map(\.actionTitle) == ["Minimize Window"], "while Shortcut Coach runs, its tips arrive")
    }
}

/// The checks that run after a click to see what it did: Chrome's five follow-up reads, and window
/// control's checks at 0.35 s and 1.0 s. The app is often still busy with the click as it's released,
/// and these checks exist to wait it out.
@MainActor
@Suite("Shortcut Coach checks after a click")
struct DelayedCheckTests {
    static let point = CGPoint(x: 400, y: 300)

    @Test("Chrome, still busy with + as it's released, still gets the New Tab tip")
    func busyChromeGetsItsTip() async throws {
        let chrome = ChromeClick { apps in apps.stall(FakeProcess.chrome) }
        defer { chrome.harness.stop() }
        var events: [CoachingEvent] = []
        chrome.harness.detector.onEvent = { events.append($0) }

        chrome.harness.click(at: Self.point)
        try await chrome.harness.waitUntil { !events.isEmpty }

        #expect(events.map(\.actionTitle) == ["New Tab"])
        #expect(events.map(\.shortcut) == ["⌘T"])
        #expect(chrome.runtime.readCount == 2, "the press's read, then the first follow-up read found the new tab")
    }

    @Test("A Chrome that stops answering as + is released is asked once for each check after it, off the main thread")
    func hungChromeIsAskedOncePerCheck() async throws {
        let chrome = ChromeClick { apps in apps.hang(FakeProcess.chrome) }
        defer { chrome.harness.stop() }
        var events: [CoachingEvent] = []
        chrome.harness.detector.onEvent = { events.append($0) }

        chrome.harness.click(at: Self.point)
        // The press's read, then the five follow-up reads.
        try await chrome.harness.waitUntil { chrome.runtime.readCount == 6 }
        try await Task.sleep(for: .milliseconds(400))

        #expect(chrome.runtime.readCount == 6, "nothing more after the fifth follow-up read")
        #expect(events.isEmpty)
        let messages = chrome.harness.log.messages
        let hitTests = messages.indices.filter { messages[$0].name == AccessibilityLog.hitTest }
        try #require(hitTests.count == 2)
        // The release's first read, then one for each follow-up read, each timing out. At 0.25 s apiece,
        // a hung Chrome holds the detection queue for 1.5 s at most.
        #expect(messages[(hitTests[1] + 1)...].count == 6)
        #expect(messages.allSatisfy { !$0.onMainThread })
    }

    @Test("Window control's checks give an app still busy with the click a fresh try", arguments: [1, 2])
    func windowControlChecksAskAgain(busyMessages: Int) async throws {
        // 1: busy through the release, so the check at 0.35 s finds the window minimized.
        // 2: busy through that check too, so the re-check at 1.0 s finds it.
        let log = AccessibilityLog()
        let app = MinimizeButtonApp()
        let accessibility = DetectionAccessibility.recording(log, apps: app.apps) { _ in app.button }
        let pipeline = DetectionPipeline(
            clickTargets: ScriptedClickTargets([.application(FakeProcess.app)]),
            accessibility: accessibility,
            snapshotter: ReadingSnapshotter(accessibility, describing: nil) { app.minimize(busyFor: busyMessages) },
            chromeRuntimeReader: UnavailableChromeRuntime(),
            runningApplication: { pid in
                pid == FakeProcess.app
                    ? RunningApplicationState(bundleIdentifier: "com.example.app", name: "Example App", isActive: true)
                    : nil
            }
        )
        var events: [CoachingEvent] = []
        pipeline.windowControlMonitor.onEvent = { events.append($0) }

        for (phase, timestamp) in [(PointerSample.Phase.down, 1.0), (.up, 1.1)] {
            let sample = PointerSample(phase: phase, location: MinimizeButtonApp.buttonCenter, modifiers: [], timestamp: timestamp)
            pipeline.queue.async { _ = pipeline.process(sample, clickThrough: []) }
        }
        try await waitForDetection { !events.isEmpty }

        #expect(events.map(\.actionTitle) == ["Minimize Window"])
        #expect(events.map(\.shortcut) == ["⌘M"])
        #expect(log.count(of: kAXMinimizedAttribute) == 1 + busyMessages,
                "read at the press, then by each check until one finds the window minimized")
    }
}

// MARK: - Test doubles

/// A running detector and a made-up Chrome whose + button is under the pointer. Chrome answers the
/// press, then `onRelease` runs as + is released, when Chrome adds the tab.
@MainActor
private struct ChromeClick {
    let harness: DetectorHarness
    let runtime: ScriptedChromeRuntime

    init(onRelease: @escaping (ScriptedApps) -> Void) {
        let log = AccessibilityLog()
        let apps = ScriptedApps()
        apps.answer(FakeProcess.chrome, kAXFocusedWindowAttribute, with: AXUIElementCreateApplication(FakeProcess.chrome))
        let accessibility = DetectionAccessibility.recording(log, apps: apps) { _ in
            AXUIElementCreateApplication(FakeProcess.chrome)
        }
        runtime = ScriptedChromeRuntime(accessibility, states: [Self.chrome(tabs: 2), Self.chrome(tabs: 3)])
        harness = DetectorHarness(
            targets: [.application(FakeProcess.chrome)], log: log, accessibility: accessibility,
            snapshotter: ReadingSnapshotter(accessibility, describing: Self.newTabButton) { onRelease(apps) },
            chromeRuntimeReader: runtime
        )
    }

    static let newTabButton = AccessibilitySnapshot(
        pid: FakeProcess.chrome, bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome",
        hit: AXNodeSnapshot(
            token: "new-tab", role: kAXButtonRole as String, subrole: nil, title: nil, elementDescription: "New Tab",
            identifier: nil, value: nil, selected: nil, enabled: true, actions: [kAXPressAction as String],
            frame: nil, menuShortcut: nil
        ),
        ancestors: []
    )

    /// Chrome with `count` tabs, the first selected, and New Tab ⌘T and Close Tab ⌘W in its menus.
    static func chrome(tabs count: Int) -> ChromeRuntimeState {
        let tabs = (0..<count).map { index in
            AXNodeSnapshot(
                token: "tab-\(index)", role: kAXRadioButtonRole as String, subrole: nil, title: nil,
                elementDescription: nil, identifier: nil, value: index == 0 ? "1" : "0", selected: index == 0,
                enabled: true, actions: [], frame: nil, menuShortcut: nil
            )
        }
        func shortcut(_ character: String) -> LiveShortcutResolution {
            .resolved(LiveShortcutObservation(evidence: AXShortcutEvidence(
                commandCharacter: character, modifiers: 0, commandGlyph: nil, virtualKey: nil
            ))!)
        }
        return ChromeRuntimeState(
            tabs: ChromeTabState(containerToken: "strip", tabs: tabs),
            tabShortcuts: ChromeTabShortcutState(newTab: shortcut("T"), closeTab: shortcut("W"), directSelection: [:]),
            settingsShortcut: .unavailable,
            destination: .unavailable,
            applicationVersion: nil
        )
    }
}

/// A made-up app with one standard window whose minimize button is under the pointer, and Window ›
/// Minimize (⌘M) in its menu bar. The window minimizes as the button is released.
final class MinimizeButtonApp: @unchecked Sendable {
    static let buttonFrame = CGRect(x: 100, y: 100, width: 16, height: 16)
    static let buttonCenter = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
    let apps = ScriptedApps()
    /// The app's element is the button too: the two are asked different attributes.
    let button = AXUIElementCreateApplication(FakeProcess.app)

    init() {
        let window = AXUIElementCreateApplication(FakeProcess.window)
        let menuBar = AXUIElementCreateApplication(FakeProcess.menuBar)
        let item = AXUIElementCreateApplication(FakeProcess.menuItem)
        // The button.
        apps.answer(FakeProcess.app, kAXRoleAttribute, with: kAXButtonRole as CFString)
        apps.answer(FakeProcess.app, kAXSubroleAttribute, with: kAXMinimizeButtonSubrole as CFString)
        apps.answerActions(FakeProcess.app, [kAXPressAction as String])
        apps.answer(FakeProcess.app, kAXWindowAttribute, with: window)
        answerFrame(FakeProcess.app, Self.buttonFrame)
        // The app.
        apps.answer(FakeProcess.app, kAXWindowsAttribute, with: [window] as CFArray)
        apps.answer(FakeProcess.app, kAXMenuBarAttribute, with: menuBar)
        // Its window.
        apps.answer(FakeProcess.window, kAXSubroleAttribute, with: kAXStandardWindowSubrole as CFString)
        apps.answer(FakeProcess.window, kAXModalAttribute, with: kCFBooleanFalse)
        apps.answer(FakeProcess.window, kAXMinimizedAttribute, with: kCFBooleanFalse)
        apps.answer(FakeProcess.window, "AXFullScreen", with: kCFBooleanFalse)
        answerFrame(FakeProcess.window, CGRect(x: 90, y: 90, width: 600, height: 400))
        // Window › Minimize.
        apps.answer(FakeProcess.menuBar, kAXRoleAttribute, with: kAXMenuBarRole as CFString)
        apps.answer(FakeProcess.menuBar, kAXChildrenAttribute, with: [item] as CFArray)
        apps.answer(FakeProcess.menuItem, kAXRoleAttribute, with: kAXMenuItemRole as CFString)
        apps.answer(FakeProcess.menuItem, kAXEnabledAttribute, with: kCFBooleanTrue)
        apps.answer(FakeProcess.menuItem, kAXTitleAttribute, with: "Minimize" as CFString)
        apps.answer(FakeProcess.menuItem, kAXMenuItemCmdCharAttribute, with: "M" as CFString)
        apps.answer(FakeProcess.menuItem, kAXMenuItemCmdModifiersAttribute, with: NSNumber(value: 0))
    }

    /// The release: the window minimizes, and the app is too busy to answer its next `messages`.
    func minimize(busyFor messages: Int) {
        apps.answer(FakeProcess.window, kAXMinimizedAttribute, with: kCFBooleanTrue)
        apps.stall(FakeProcess.app, messages: messages)
    }

    private func answerFrame(_ pid: pid_t, _ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        apps.answer(pid, kAXPositionAttribute, with: AXValueCreate(.cgPoint, &origin)!)
        apps.answer(pid, kAXSizeAttribute, with: AXValueCreate(.cgSize, &size)!)
    }
}

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
    /// Records every message in `log` and answers none, apart from the hit-test's `hit`. Reads of
    /// `unresponsive` apps' elements time out. With `apps`, reads are answered from its table instead.
    static func recording(_ log: AccessibilityLog, unresponsive: Set<pid_t> = [], apps: ScriptedApps? = nil,
                          hit: @escaping (CGPoint) -> AXUIElement?) -> DetectionAccessibility {
        func error(for element: AXUIElement) -> AXError {
            unresponsive.contains(ScriptedApps.processIdentifier(of: element)) ? .cannotComplete : .noValue
        }
        var accessibility = DetectionAccessibility()
        accessibility.setMessagingTimeout = { log.setTimeout($0, $1) }
        accessibility.copyElementAtPosition = { application, point in
            log.record(AccessibilityLog.hitTest, application, at: point)
            let element = hit(point)
            return (element == nil ? .noValue : .success, element)
        }
        accessibility.copyAttributeValue = { element, name in
            log.record(name, element)
            return apps?.value(of: name, from: element) ?? (error(for: element), nil)
        }
        accessibility.copyActionNames = { element in
            log.record(AccessibilityLog.actions, element)
            return apps?.actionNames(of: element) ?? (error(for: element), [])
        }
        return accessibility
    }
}

/// Made-up apps that answer reads from a table; an attribute not in it has no value. An app can
/// stall, timing out its next few messages as an app still busy with a click does, or hang, timing
/// out every message from then on.
final class ScriptedApps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [pid_t: [String: CFTypeRef]] = [:]
    private var actions: [pid_t: [String]] = [:]
    private var stalls: [pid_t: Int] = [:]
    private var hung: Set<pid_t> = []

    func answer(_ pid: pid_t, _ name: String, with value: CFTypeRef) {
        lock.withLock { values[pid, default: [:]][name] = value }
    }

    func answerActions(_ pid: pid_t, _ names: [String]) {
        lock.withLock { actions[pid] = names }
    }

    func stall(_ pid: pid_t, messages: Int = 1) {
        lock.withLock { stalls[pid, default: 0] += messages }
    }

    func hang(_ pid: pid_t) {
        lock.withLock { _ = hung.insert(pid) }
    }

    func value(of name: String, from element: AXUIElement) -> (AXError, CFTypeRef?) {
        let pid = Self.processIdentifier(of: element)
        return lock.withLock {
            if timesOut(pid) { return (.cannotComplete, nil) }
            guard let value = values[pid]?[name] else { return (.noValue, nil) }
            return (.success, value)
        }
    }

    func actionNames(of element: AXUIElement) -> (AXError, [String]) {
        let pid = Self.processIdentifier(of: element)
        return lock.withLock { timesOut(pid) ? (.cannotComplete, []) : (.success, actions[pid] ?? []) }
    }

    static func processIdentifier(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : 0
    }

    /// Called with the lock held.
    private func timesOut(_ pid: pid_t) -> Bool {
        if hung.contains(pid) { return true }
        guard let remaining = stalls[pid], remaining > 0 else { return false }
        stalls[pid] = remaining - 1
        return true
    }
}

/// Reads the hit as the real snapshotter's first read does, through `DetectionAccessibility`, and
/// describes it as `snapshot` whatever the read answers: the real one still names the app, from
/// `NSRunningApplication`. `onRelease` runs just before the second snapshot, the release's, which is
/// when the app gets the click.
final class ReadingSnapshotter: AccessibilitySnapshotting, @unchecked Sendable {
    private let accessibility: DetectionAccessibility
    private let snapshot: AccessibilitySnapshot?
    private let onRelease: () -> Void
    /// Only the detection queue touches it.
    private var calls = 0

    init(_ accessibility: DetectionAccessibility, describing snapshot: AccessibilitySnapshot?,
         onRelease: @escaping () -> Void) {
        self.accessibility = accessibility
        self.snapshot = snapshot
        self.onRelease = onRelease
    }

    func snapshot(of hit: AXUIElement) -> AccessibilitySnapshot? {
        calls += 1
        if calls == 2 { onRelease() }
        _ = accessibility.copyAttribute(kAXRoleAttribute, from: hit)
        return snapshot
    }
}

/// Reads Chrome through `DetectionAccessibility` a read at a time, as the real reader does: its
/// focused window, then the menu bar and windows its tab and shortcut walks start from. Like those
/// walks, it goes on reading after a read fails, so the test sees every read that gets through. Once
/// the window answers, it describes Chrome as the next of `states`, then the last one again.
final class ScriptedChromeRuntime: ChromeRuntimeStateReading, @unchecked Sendable {
    private let accessibility: DetectionAccessibility
    private let lock = NSLock()
    private var states: [ChromeRuntimeState]
    private var reads = 0

    init(_ accessibility: DetectionAccessibility, states: [ChromeRuntimeState]) {
        self.accessibility = accessibility
        self.states = states
    }

    var readCount: Int { lock.withLock { reads } }

    func read(pid: Int32, requirement: ChromeRuntimeRequirement) -> ChromeRuntimeState {
        lock.withLock { reads += 1 }
        let chrome = AXUIElementCreateApplication(pid)
        let window = accessibility.copyAttribute(kAXFocusedWindowAttribute, from: chrome)
        _ = accessibility.copyAttribute(kAXMenuBarAttribute, from: chrome)
        _ = accessibility.copyAttribute(kAXWindowsAttribute, from: chrome)
        guard window != nil else { return .unavailable }
        return lock.withLock { states.count > 1 ? states.removeFirst() : states[0] }
    }
}

extension ClickTargetProbing {
    func target(at point: CGPoint) -> ClickTarget { target(at: point, clickThrough: []) }
}

/// Answers each press and release with the next target, then the last one again.
final class ScriptedClickTargets: ClickTargetProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ClickTarget]
    private var calls = 0
    private var received: [Set<Int>] = []

    init(_ targets: [ClickTarget]) { remaining = targets }

    var callCount: Int { lock.withLock { calls } }
    /// The click-through windows each call was given.
    var clickThrough: [Set<Int>] { lock.withLock { received } }

    func target(at point: CGPoint, clickThrough: Set<Int>) -> ClickTarget {
        lock.withLock {
            calls += 1
            received.append(clickThrough)
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
    let log: AccessibilityLog
    let targets: ScriptedClickTargets
    let detector: ManualActionDetector

    convenience init(targets: [ClickTarget], snapshotter: (any AccessibilitySnapshotting)? = nil,
                     unresponsive: Set<pid_t> = [], hit: @escaping (CGPoint) -> AXUIElement?) {
        let log = AccessibilityLog()
        self.init(targets: targets, log: log, accessibility: .recording(log, unresponsive: unresponsive, hit: hit),
                  snapshotter: snapshotter)
    }

    /// `accessibility` records its messages in `log`.
    init(targets: [ClickTarget], log: AccessibilityLog, accessibility: DetectionAccessibility,
         snapshotter: (any AccessibilitySnapshotting)? = nil,
         chromeRuntimeReader: any ChromeRuntimeStateReading = UnavailableChromeRuntime()) {
        self.log = log
        self.targets = ScriptedClickTargets(targets)
        detector = ManualActionDetector(
            monitor: monitor,
            snapshotter: snapshotter,
            permissions: GrantedDetectorPermissions(),
            chromeRuntimeReader: chromeRuntimeReader,
            clickTargets: self.targets,
            accessibility: accessibility
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
        try await waitForDetection(condition)
    }

    func stop() { detector.stop() }
}

/// Waits up to 3 seconds, long enough for every check Shortcut Coach runs after a click.
@MainActor
private func waitForDetection(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "timed out waiting for Shortcut Coach's detection queue")
}
