import ApplicationServices
import CoreGraphics
import XCTest
@testable import Keybumps

@MainActor
final class ChromeActionDetectionTests: XCTestCase {
    private let adapter = ChromeActionAdapter()

    func testStaticFallbackCatalogIsExplicitlyVersioned() {
        XCTAssertEqual(ChromeShortcutCatalog.characterizedChromeVersion, "153.0.8010.12")
        XCTAssertEqual(ChromeShortcutCatalog.newTab, "⌘T")
        XCTAssertEqual(ChromeShortcutCatalog.closeTab, "⌘W")
        XCTAssertEqual(ChromeShortcutCatalog.selectTab(index: 4), "⌘4")
        XCTAssertEqual(ChromeShortcutCatalog.selectTab(index: 10), "⌘9")
    }

    func testSanitizedCharacterizationFixtureHasNoPrivateBrowserData() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KeybumpsTests/Fixtures/KeyboardShortcutter/chrome-153-tab-strip.json")
        let data = try Data(contentsOf: fixture)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["chromeVersion"] as? String, "153.0.8010.12")
        let serialized = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["http://", "https://", "url", "account", "profile", "history", "@"] {
            XCTAssertFalse(serialized.contains(forbidden), "Fixture contains forbidden private-data marker: \(forbidden)")
        }
    }

    func testSanitizedSettingsFailingTraceReplaysThroughProductionDetector() throws {
        let trace = try loadSettingsTrace()
        var detector = ChromeClickDetector()
        var events: [CoachingEvent] = []
        var suppressions = 0

        for observation in trace.observations {
            let outcome = detector.receive(observation.detectorObservation)
            switch outcome {
            case .event(let event): events.append(event)
            case .suppressed: suppressions += 1
            case .pending: break
            }
        }

        XCTAssertEqual(events.map { [$0.applicationName, $0.actionTitle, $0.shortcut] }, trace.expectedEvents)
        XCTAssertEqual(suppressions, 1, "The three-dot opener is an explicit non-coaching action")
    }

    func testProductionDetectorSuppressesSettingsNegativeControls() {
        let down = sample(.down, time: 1)
        let up = sample(.up, time: 1.1)
        let validPre = makeSnapshot(
            hit: node("settings", role: "AXMenuItem", title: "Settings", actions: ["AXPress"])
        )
        let validPreRuntime = runtime(shortcut: resolved("⌘,"), destination: .other)
        let validPost = makeSnapshot(hit: node("content", role: "AXGroup"))
        let validPostRuntime = runtime(shortcut: resolved("⌘,"), destination: .settings)

        var keyboardInvocation = ChromeClickDetector()
        assertSuppressed(keyboardInvocation.receive(.post(identity(validPost), validPostRuntime, timestamp: 1.2)))

        var menuDismissal = ChromeClickDetector()
        XCTAssertEqual(menuDismissal.receive(.down(down, validPre, validPreRuntime)), .pending)
        XCTAssertEqual(menuDismissal.receive(.up(up, nil)), .pending)
        XCTAssertEqual(menuDismissal.receive(.post(identity(validPre), validPreRuntime, timestamp: 1.2)), .pending)
        assertSuppressed(menuDismissal.receive(.cancelled))

        var movedOff = ChromeClickDetector()
        XCTAssertEqual(movedOff.receive(.down(down, validPre, validPreRuntime)), .pending)
        assertSuppressed(movedOff.receive(.up(sample(.up, x: 50, y: 50, time: 1.1), validPre)))

        var cancelled = ChromeClickDetector()
        XCTAssertEqual(cancelled.receive(.down(down, validPre, validPreRuntime)), .pending)
        assertSuppressed(cancelled.receive(.cancelled))
        assertSuppressed(cancelled.receive(.post(identity(validPost), validPostRuntime, timestamp: 1.2)))

        for resolution in [LiveShortcutResolution.unavailable, .ambiguous] {
            var unresolved = ChromeClickDetector()
            assertSuppressed(unresolved.receive(.down(down, validPre, runtime(shortcut: resolution, destination: .other))))
            XCTAssertEqual(unresolved.receive(.up(up, validPre)), .pending)
            assertSuppressed(unresolved.receive(.post(identity(validPost), validPostRuntime, timestamp: 1.2)))
        }

        var failedNavigation = ChromeClickDetector()
        XCTAssertEqual(failedNavigation.receive(.down(down, validPre, validPreRuntime)), .pending)
        XCTAssertEqual(failedNavigation.receive(.up(up, validPre)), .pending)
        XCTAssertEqual(failedNavigation.receive(.post(identity(validPre), validPreRuntime, timestamp: 1.2)), .pending)
        assertSuppressed(failedNavigation.receive(.cancelled))
    }

    func testClassifiesNewTabUsingSemanticConjunction() {
        let snapshot = makeSnapshot(hit: node("new", role: "AXButton", description: "New Tab", actions: ["AXPress"]))
        let tabRuntime = runtime(tabs: tabs(count: 3))
        XCTAssertEqual(adapter.classify(snapshot, runtime: tabRuntime, point: .init(x: 10, y: 10))?.kind, .chromeNewTab)

        XCTAssertNil(adapter.classify(makeSnapshot(hit: node("new", role: "AXButton", description: nil, actions: ["AXPress"])), runtime: tabRuntime, point: .zero))
        XCTAssertNil(adapter.classify(makeSnapshot(hit: node("new", role: "AXButton", description: "New Tab", actions: [])), runtime: tabRuntime, point: .zero))
        XCTAssertNil(adapter.classify(makeSnapshot(bundle: "com.apple.Safari", hit: node("new", role: "AXButton", description: "New Tab", actions: ["AXPress"])), runtime: tabRuntime, point: .zero))
    }

    func testLocalizedNewTabNameAndAncestorVariationAreAccepted() {
        let hit = node("new", role: "AXButton", description: "Nouvel onglet", actions: ["AXPress"])
        let snapshot = makeSnapshot(hit: hit, ancestors: [node("toolbar", role: "AXGroup")])
        XCTAssertEqual(adapter.classify(snapshot, runtime: runtime(tabs: tabs(count: 2)), point: .zero)?.kind, .chromeNewTab)
    }

    func testCloseOnlyClassifiesSelectedTab() {
        let close = node("close", role: "AXButton", description: "Close", actions: ["AXPress"])
        let active = node("tab-1", role: "AXRadioButton", selected: true)
        let inactive = node("tab-2", role: "AXRadioButton", selected: false)
        let state = ChromeTabState(containerToken: "strip", tabs: [active, inactive])
        XCTAssertEqual(adapter.classify(makeSnapshot(hit: close, ancestors: [active]), runtime: runtime(tabs: state), point: .zero)?.kind,
                       .chromeCloseActiveTab(tabToken: "tab-1"))
        XCTAssertNil(adapter.classify(makeSnapshot(hit: close, ancestors: [inactive]), runtime: runtime(tabs: state), point: .zero))
    }

    func testDirectTabIndexesAndLastTabMapping() {
        let eight = tabs(count: 8)
        let second = eight.tabs[1]
        XCTAssertEqual(adapter.classify(makeSnapshot(hit: second), runtime: runtime(tabs: eight), point: .zero)?.kind,
                       .chromeSelectTab(tabToken: second.token, index: 2, tabCount: 8))

        let ten = tabs(count: 10)
        XCTAssertNil(adapter.classify(makeSnapshot(hit: ten.tabs[8]), runtime: runtime(tabs: ten), point: .zero))
        XCTAssertEqual(adapter.classify(makeSnapshot(hit: ten.tabs[9]), runtime: runtime(tabs: ten), point: .zero)?.kind,
                       .chromeSelectTab(tabToken: "tab-10", index: 10, tabCount: 10))
    }

    func testNewTabRequiresVerifiedPostcondition() {
        let pre = makeSnapshot(hit: node("new", role: "AXButton", description: "New Tab", actions: ["AXPress"]))
        let preRuntime = runtime(tabs: tabs(count: 2))
        var correlator = ActionCorrelator()
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.1), hit: pre))
        XCTAssertNil(correlator.verify(processIdentity: identity(pre), runtime: preRuntime, at: 1.2))

        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 2, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 2.1), hit: pre))
        let event = correlator.verify(processIdentity: identity(pre), runtime: runtime(tabs: tabs(count: 3)), at: 2.2)
        XCTAssertEqual(event?.shortcut, "⌘T")
        XCTAssertEqual(event?.shortcutProvenance, .liveAX)
        XCTAssertEqual(event?.rawShortcutEvidence, tryResolvedObservation("⌘T").evidence)
    }

    func testProductionDetectorRetriesAStalePostconditionAndEmitsExactlyOnce() {
        let pre = makeSnapshot(hit: node("new", role: "AXButton", description: "New Tab", actions: ["AXPress"]))
        let preRuntime = runtime(tabs: tabs(count: 2))
        let post = makeSnapshot(hit: pre.hit)
        let settledRuntime = runtime(tabs: tabs(count: 3))
        var detector = ChromeClickDetector()

        XCTAssertEqual(detector.receive(.down(sample(.down, time: 1), pre, preRuntime)), .pending)
        XCTAssertEqual(detector.receive(.up(sample(.up, time: 1.1), pre)), .pending)
        XCTAssertEqual(detector.receive(.post(identity(post), preRuntime, timestamp: 1.2)), .pending)
        XCTAssertTrue(detector.needsPostObservation)

        guard case .event(let event) = detector.receive(.post(identity(post), settledRuntime, timestamp: 1.3)) else {
            return XCTFail("The first action must survive a stale AX sample and emit after the verified postcondition")
        }
        XCTAssertEqual(event.shortcut, "⌘T")
        XCTAssertFalse(detector.needsPostObservation)
        assertSuppressed(detector.receive(.post(identity(post), settledRuntime, timestamp: 1.4)))
    }

    func testCloseTabRetriesAStalePostconditionAndEmitsExactlyOnce() {
        let active = node("tab-1", role: "AXRadioButton", selected: true)
        let other = node("tab-2", role: "AXRadioButton", selected: false)
        let close = node("close", role: "AXButton", description: "Close", actions: ["AXPress"])
        let pre = makeSnapshot(hit: close, ancestors: [active])
        let preRuntime = runtime(tabs: ChromeTabState(containerToken: "strip", tabs: [active, other]))
        let settledRuntime = runtime(tabs: ChromeTabState(containerToken: "strip", tabs: [other]))
        var detector = ChromeClickDetector()

        XCTAssertEqual(detector.receive(.down(sample(.down, time: 1), pre, preRuntime)), .pending)
        XCTAssertEqual(detector.receive(.up(sample(.up, time: 1.1), pre)), .pending)
        XCTAssertEqual(detector.receive(.post(identity(pre), preRuntime, timestamp: 1.2)), .pending)

        guard case .event(let event) = detector.receive(.post(identity(pre), settledRuntime, timestamp: 1.3)) else {
            return XCTFail("Close Tab must survive a stale AX sample and emit after the verified tab-count change")
        }
        XCTAssertEqual(event.actionTitle, "Close Tab")
        XCTAssertEqual(event.shortcut, "⌘W")
        assertSuppressed(detector.receive(.post(identity(pre), settledRuntime, timestamp: 1.4)))
    }

    func testIssue31LiveEvidenceIsCurrentAndContainsNoPrivateBrowserOrDocumentData() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KeybumpsTests/Fixtures/KeyboardShortcutter/issue-31-live-shortcuts.json")
        let data = try Data(contentsOf: fixture)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"version\": \"1.138.0\""))
        XCTAssertTrue(text.contains("\"version\": \"153.0.8010.48\""))
        for forbidden in ["http://", "https://", "\"url\"", "\"filename\"", "\"documentTitle\"", "\"tabTitle\"", "\"account\"", "@"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()))
        }
    }

    func testCharacterizedTabDefaultsSuppressWhenChromeVersionIsMissingOrMismatched() {
        for incompatibleVersion in [nil, "153.0.8010.11", "154.0.0.0"] as [String?] {
            let tabState = tabs(count: 2)
            let selected = tabState.tabs[1]
            let pre = makeSnapshot(
                applicationVersion: incompatibleVersion,
                hit: selected
            )
            let preRuntime = runtime(
                tabs: tabState,
                tabShortcuts: .unavailable,
                applicationVersion: incompatibleVersion
            )
            let selectedPost = ChromeTabState(
                containerToken: tabState.containerToken,
                tabs: [
                    node("tab-1", role: "AXRadioButton", selected: false),
                    node("tab-2", role: "AXRadioButton", selected: true)
                ]
            )
            let postRuntime = runtime(
                tabs: selectedPost,
                tabShortcuts: .unavailable,
                applicationVersion: incompatibleVersion
            )
            var correlator = ActionCorrelator()
            correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: [])
            XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.1), hit: pre))
            XCTAssertNil(
                correlator.verify(processIdentity: identity(pre), runtime: postRuntime, at: 1.2),
                "Characterized defaults must suppress for version \(incompatibleVersion ?? "missing")"
            )
        }
    }

    func testDirectTabSelectionUsesVersionedCharacterizedFallbackOnlyWhenLiveEvidenceIsUnavailable() {
        let tabState = tabs(count: 2)
        let target = tabState.tabs[1]
        let pre = makeSnapshot(hit: target)
        let preRuntime = runtime(tabs: tabState, tabShortcuts: .unavailable)
        let postTabs = ChromeTabState(
            containerToken: tabState.containerToken,
            tabs: [
                node("tab-1", role: "AXRadioButton", selected: false),
                node("tab-2", role: "AXRadioButton", selected: true)
            ]
        )
        var correlator = ActionCorrelator()
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.1), hit: pre))

        let event = correlator.verify(
            processIdentity: identity(pre),
            runtime: runtime(tabs: postTabs, tabShortcuts: .unavailable),
            at: 1.2
        )

        XCTAssertEqual(event?.shortcut, "⌘2")
        XCTAssertEqual(
            event?.shortcutProvenance,
            .characterizedDefault(
                adapterID: ChromeShortcutCatalog.adapterID,
                compatibleApplicationVersion: ChromeShortcutCatalog.characterizedChromeVersion
            )
        )
    }

    func testCloseAndSelectionRequireExactPostconditions() {
        let active = node("tab-1", role: "AXRadioButton", selected: true)
        let other = node("tab-2", role: "AXRadioButton", selected: false)
        let close = node("close", role: "AXButton", description: "Close", actions: ["AXPress"])
        let pre = makeSnapshot(hit: close, ancestors: [active])
        let preRuntime = runtime(tabs: ChromeTabState(containerToken: "strip", tabs: [active, other]))
        var correlator = ActionCorrelator()
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.1), hit: pre))
        XCTAssertEqual(correlator.verify(processIdentity: identity(pre), runtime: runtime(tabs: ChromeTabState(containerToken: "strip", tabs: [other])), at: 1.2)?.shortcut, "⌘W")

        let tabPre = makeSnapshot(hit: other)
        correlator.begin(tryCandidate(tabPre, runtime: preRuntime), at: 2, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 2.1), hit: tabPre))
        let selectedOther = node("tab-2", role: "AXRadioButton", selected: true)
        XCTAssertEqual(correlator.verify(processIdentity: identity(tabPre), runtime: runtime(tabs: ChromeTabState(containerToken: "strip", tabs: [node("tab-1", role: "AXRadioButton", selected: false), selectedOther])), at: 2.2)?.shortcut, "⌘2")
    }

    func testGestureSuppressionsCoverModifiersDragMovedOffDisabledAndExpiry() {
        let pre = makeSnapshot(hit: node("new", role: "AXButton", description: "New Tab", actions: ["AXPress"], frame: AXFrameSnapshot(x: 0, y: 0, width: 20, height: 20)))
        let preRuntime = runtime(tabs: tabs(count: 2))
        var correlator = ActionCorrelator()
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: .maskCommand)
        XCTAssertNil(correlator.candidate)

        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 2, modifiers: [])
        correlator.markDragged()
        XCTAssertFalse(correlator.acceptsMouseUp(sample(.up, x: 5, y: 5, time: 2.1), hit: pre))

        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 3, modifiers: [])
        XCTAssertFalse(correlator.acceptsMouseUp(sample(.up, x: 50, y: 50, time: 3.1), hit: pre))

        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 4, modifiers: [])
        XCTAssertFalse(correlator.acceptsMouseUp(sample(.up, x: 5, y: 5, time: 6), hit: pre))

        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 7, modifiers: [])
        let modifiedUp = PointerSample(phase: .up, location: CGPoint(x: 5, y: 5), modifiers: .maskShift, timestamp: 7.1)
        XCTAssertFalse(correlator.acceptsMouseUp(modifiedUp, hit: pre))

        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 8, modifiers: [])
        correlator.cancel()
        XCTAssertNil(correlator.candidate)

        let disabled = makeSnapshot(hit: node("new", role: "AXButton", description: "New Tab", enabled: false, actions: ["AXPress"]))
        XCTAssertNil(adapter.classify(disabled, runtime: preRuntime, point: .zero))
    }

    func testOrdinaryPointerJitterDoesNotCancelAChromeClick() {
        let pre = makeSnapshot(
            hit: node(
                "new",
                role: "AXButton",
                description: "New Tab",
                actions: ["AXPress"],
                frame: AXFrameSnapshot(x: 0, y: 0, width: 20, height: 20)
            )
        )
        let preRuntime = runtime(tabs: tabs(count: 2))
        var correlator = ActionCorrelator()
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: [])
        correlator.observeDrag(to: CGPoint(x: 5.2, y: 5.1))

        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, x: 5.2, y: 5.1, time: 1.1), hit: pre))
    }

    func testChromeSettingsMenuItemProducesSettingsCandidate() {
        let snapshot = makeSnapshot(hit: node("settings", role: "AXMenuItem", title: "Settings...", actions: ["AXPress"]))

        XCTAssertEqual(
            adapter.classify(
                snapshot,
                runtime: runtime(shortcut: resolved("⇧⌘,"), destination: .other),
                point: CGPoint(x: 5, y: 5)
            )?.kind,
            .chromeSettings(shortcut: tryResolvedObservation("⇧⌘,"))
        )
        XCTAssertTrue(ChromeSettingsSemantics.isSettingsMenuItem(snapshot.hit))
    }

    func testChromeSettingsLiveShortcutRequiresKnownEnabledAndModifierMetadata() {
        let settings = node("settings", role: "AXMenuItem", title: "Preferences…", actions: ["AXPress"])
        func observation(enabled: Bool?, modifiers: Int?) -> ChromeMenuCommandObservation {
            ChromeMenuCommandObservation(
                node: settings,
                enabled: enabled,
                shortcutEvidence: AXShortcutEvidence(
                    commandCharacter: ",",
                    modifiers: modifiers,
                    commandGlyph: nil,
                    virtualKey: nil
                )
            )
        }

        XCTAssertEqual(
            ChromeSettingsSemantics.resolveShortcut(from: [observation(enabled: true, modifiers: 0)]),
            resolved("⌘,")
        )
        XCTAssertEqual(ChromeSettingsSemantics.resolveShortcut(from: [observation(enabled: nil, modifiers: 0)]), .unavailable)
        XCTAssertEqual(ChromeSettingsSemantics.resolveShortcut(from: [observation(enabled: false, modifiers: 0)]), .unavailable)
        XCTAssertEqual(ChromeSettingsSemantics.resolveShortcut(from: [observation(enabled: true, modifiers: nil)]), .unavailable)
        XCTAssertEqual(ChromeSettingsSemantics.resolveShortcut(from: [observation(enabled: true, modifiers: 32)]), .unavailable)
        XCTAssertEqual(
            ChromeSettingsSemantics.resolveShortcut(from: [
                observation(enabled: true, modifiers: 0),
                observation(enabled: true, modifiers: 0)
            ]),
            .ambiguous
        )
    }

    func testChromeSettingsRequiresTheResolvedCommandAndSettingsDestination() {
        let pre = makeSnapshot(hit: node("settings", role: "AXMenuItem", title: "Settings", actions: ["AXPress"]))
        let preRuntime = runtime(shortcut: resolved("⇧⌘,"), destination: .other)
        var correlator = ActionCorrelator()
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.1), hit: pre))
        XCTAssertNil(correlator.verify(processIdentity: identity(pre), runtime: preRuntime, at: 1.2))

        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 2, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 2.1), hit: pre))
        let event = correlator.verify(
            processIdentity: identity(pre),
            runtime: runtime(shortcut: resolved("⇧⌘,"), destination: .settings),
            at: 2.2
        )
        XCTAssertEqual(event?.actionTitle, "Settings")
        XCTAssertEqual(event?.shortcut, "⇧⌘,")
    }

    func testChromeSettingsSuppressesUnavailableAmbiguousStaleAndFailedNavigation() {
        let hit = node("settings", role: "AXMenuItem", title: "Settings", actions: ["AXPress"])
        let snapshot = makeSnapshot(hit: hit)
        XCTAssertNil(adapter.classify(snapshot, runtime: runtime(shortcut: .unavailable), point: .zero))
        XCTAssertNil(adapter.classify(snapshot, runtime: runtime(shortcut: .ambiguous), point: .zero))
        XCTAssertNil(adapter.classify(snapshot, runtime: runtime(shortcut: resolved("⌘,"), destination: .settings), point: .zero))
        XCTAssertNil(adapter.classify(snapshot, runtime: runtime(shortcut: resolved("⌘,"), destination: .unavailable), point: .zero))
        let unknownEnabled = makeSnapshot(hit: node("settings", role: "AXMenuItem", title: "Settings", enabled: nil, actions: ["AXPress"]))
        XCTAssertNil(adapter.classify(unknownEnabled, runtime: runtime(shortcut: resolved("⌘,"), destination: .other), point: .zero))

        let preRuntime = runtime(shortcut: resolved("⌘,"), destination: .other)
        for postRuntime in [
            runtime(shortcut: resolved("⌥⌘,"), destination: .settings),
            runtime(shortcut: .unavailable, destination: .settings),
            runtime(shortcut: resolved("⌘,"), destination: .other),
            runtime(shortcut: resolved("⌘,"), destination: .unavailable)
        ] {
            var correlator = ActionCorrelator()
            correlator.begin(tryCandidate(snapshot, runtime: preRuntime), at: 1, modifiers: [])
            XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.1), hit: snapshot))
            XCTAssertNil(correlator.verify(processIdentity: identity(snapshot), runtime: postRuntime, at: 1.2))
        }
    }

    func testReloadOmniboxAndUnknownButtonsAreSuppressed() {
        for description in ["Reload", "Stop", "Address and search bar", nil] {
            let snapshot = makeSnapshot(hit: node("button", role: "AXButton", description: description, actions: ["AXPress"]))
            XCTAssertNil(adapter.classify(snapshot, runtime: runtime(tabs: tabs(count: 2)), point: .zero))
        }
    }

    func testFallbackDeduplicatesAndTapDisableTypesRecover() {
        let pre = makeSnapshot(hit: node("new", role: "AXButton", description: "New Tab", actions: ["AXPress"]))
        let preRuntime = runtime(tabs: tabs(count: 2))
        let post = makeSnapshot(hit: pre.hit)
        let postRuntime = runtime(tabs: tabs(count: 3))
        var correlator = ActionCorrelator()
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.1), hit: pre))
        XCTAssertNotNil(correlator.verify(processIdentity: identity(post), runtime: postRuntime, at: 1.2))
        correlator.begin(tryCandidate(pre, runtime: preRuntime), at: 1.3, modifiers: [])
        XCTAssertTrue(correlator.acceptsMouseUp(sample(.up, time: 1.4), hit: pre))
        XCTAssertNil(correlator.verify(processIdentity: identity(post), runtime: postRuntime, at: 1.5))
        XCTAssertTrue(PointerEventMonitor.shouldRecover(from: .tapDisabledByTimeout))
        XCTAssertTrue(PointerEventMonitor.shouldRecover(from: .tapDisabledByUserInput))
        XCTAssertFalse(PointerEventMonitor.shouldRecover(from: .leftMouseDown))
    }

    private func tryCandidate(_ snapshot: AccessibilitySnapshot, runtime: ChromeRuntimeState) -> ManualActionCandidate {
        // Test construction always supplies a fixture that the adapter accepts.
        adapter.classify(snapshot, runtime: runtime, point: CGPoint(x: 5, y: 5))!
    }

    private func sample(_ phase: PointerSample.Phase, x: Double = 5, y: Double = 5, time: TimeInterval) -> PointerSample {
        PointerSample(phase: phase, location: CGPoint(x: x, y: y), modifiers: [], timestamp: time)
    }

    private func identity(_ snapshot: AccessibilitySnapshot) -> ApplicationProcessIdentity {
        ApplicationProcessIdentity(snapshot: snapshot)
    }

    private func tabs(count: Int) -> ChromeTabState {
        ChromeTabState(containerToken: "strip", tabs: (1...count).map { node("tab-\($0)", role: "AXRadioButton", selected: $0 == 1) })
    }

    private func makeSnapshot(
        bundle: String = "com.google.Chrome",
        applicationVersion: String? = ChromeShortcutCatalog.characterizedChromeVersion,
        hit: AXNodeSnapshot,
        ancestors: [AXNodeSnapshot] = []
    ) -> AccessibilitySnapshot {
        AccessibilitySnapshot(pid: 123, bundleIdentifier: bundle, applicationVersion: applicationVersion, applicationName: "Google Chrome",
                              hit: hit, ancestors: ancestors)
    }

    private func runtime(
        tabs: ChromeTabState? = nil,
        tabShortcuts: ChromeTabShortcutState? = nil,
        shortcut: LiveShortcutResolution = .unavailable,
        destination: ChromeNavigationDestination = .unavailable,
        applicationVersion: String? = ChromeShortcutCatalog.characterizedChromeVersion
    ) -> ChromeRuntimeState {
        ChromeRuntimeState(
            tabs: tabs,
            tabShortcuts: tabShortcuts ?? fixtureTabShortcuts(),
            settingsShortcut: shortcut,
            destination: destination,
            applicationVersion: applicationVersion
        )
    }

    private func fixtureTabShortcuts() -> ChromeTabShortcutState {
        ChromeTabShortcutState(
            newTab: resolved("⌘T"),
            closeTab: resolved("⌘W"),
            directSelection: Dictionary(uniqueKeysWithValues: (1...9).map { ($0, resolved("⌘\($0)")) })
        )
    }

    private func resolved(_ displayString: String) -> LiveShortcutResolution {
        .resolved(tryResolvedObservation(displayString))
    }

    private func tryResolvedObservation(_ displayString: String) -> LiveShortcutObservation {
        var modifiers = 0
        if displayString.contains("⇧") { modifiers |= 1 }
        if displayString.contains("⌥") { modifiers |= 2 }
        if displayString.contains("⌃") { modifiers |= 4 }
        if !displayString.contains("⌘") { modifiers |= 8 }
        let primary = String(displayString.last ?? ",")
        return LiveShortcutObservation(
            evidence: AXShortcutEvidence(
                commandCharacter: primary,
                modifiers: modifiers,
                commandGlyph: nil,
                virtualKey: nil
            )
        )!
    }

    private func node(_ token: String, role: String, title: String? = nil, description: String? = nil,
                      selected: Bool? = nil, enabled: Bool? = true,
                      actions: [String] = [], frame: AXFrameSnapshot? = AXFrameSnapshot(x: 0, y: 0, width: 20, height: 20)) -> AXNodeSnapshot {
        AXNodeSnapshot(token: token, role: role, subrole: nil, title: title,
                       elementDescription: description, identifier: nil, value: selected.map { $0 ? "1" : "0" },
                       selected: selected, enabled: enabled, actions: actions, frame: frame, menuShortcut: nil)
    }

    private func loadSettingsTrace() throws -> SettingsTraceFixture {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("KeybumpsTests/Fixtures/KeyboardShortcutter/chrome-153-settings-failing-trace.json")
        let data = try Data(contentsOf: fixture)
        let serialized = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["http://", "https://", "chrome://", "@", "tabtitle", "accountname"] {
            XCTAssertFalse(serialized.contains(forbidden), "Trace contains forbidden private-data marker: \(forbidden)")
        }
        return try JSONDecoder().decode(SettingsTraceFixture.self, from: data)
    }

    private func assertSuppressed(_ outcome: ChromeClickOutcome) {
        guard case .suppressed = outcome else {
            XCTFail("Expected explicit suppression, got \(outcome)")
            return
        }
    }
}

private struct SettingsTraceFixture: Decodable {
    let observations: [SettingsTraceObservation]
    let expectedEvents: [[String]]

    private enum CodingKeys: String, CodingKey { case observations, expectedEvents }
    private struct ExpectedEvent: Decodable {
        let applicationName: String
        let actionTitle: String
        let shortcut: String
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        observations = try values.decode([SettingsTraceObservation].self, forKey: .observations)
        expectedEvents = try values.decode([ExpectedEvent].self, forKey: .expectedEvents)
            .map { [$0.applicationName, $0.actionTitle, $0.shortcut] }
    }
}

private struct SettingsTraceObservation: Decodable {
    let phase: String
    let time: TimeInterval
    let x: Double
    let y: Double
    let hit: Hit
    let tabCount: Int
    let settingsShortcut: String
    let destination: ChromeNavigationDestination

    struct Hit: Decodable {
        let token: String
        let role: String
        let name: String?
        let actions: [String]
    }

    var detectorObservation: ChromeClickObservation {
        let point = CGPoint(x: x, y: y)
        let snapshot = AccessibilitySnapshot(
            pid: 123,
            bundleIdentifier: "com.google.Chrome",
            applicationVersion: ChromeShortcutCatalog.characterizedChromeVersion,
            applicationName: "Google Chrome",
            hit: AXNodeSnapshot(
                token: hit.token,
                role: hit.role,
                subrole: nil,
                title: hit.name,
                elementDescription: hit.name,
                identifier: nil,
                value: nil,
                selected: nil,
                enabled: true,
                actions: hit.actions,
                frame: AXFrameSnapshot(x: x - 20, y: y - 20, width: 40, height: 40),
                menuShortcut: nil
            ),
            ancestors: []
        )
        let runtime = ChromeRuntimeState(
            tabs: ChromeTabState(
                containerToken: "strip",
                tabs: (0..<tabCount).map {
                    AXNodeSnapshot(token: "tab-\($0)", role: "AXRadioButton", subrole: nil, title: nil,
                                   elementDescription: nil, identifier: nil, value: $0 == 0 ? "1" : "0",
                                   selected: $0 == 0, enabled: true, actions: [], frame: nil, menuShortcut: nil)
                }
            ),
            settingsShortcut: parseShortcut(settingsShortcut),
            destination: destination,
            applicationVersion: ChromeShortcutCatalog.characterizedChromeVersion
        )
        switch phase {
        case "down": return .down(PointerSample(phase: .down, location: point, modifiers: [], timestamp: time), snapshot, runtime)
        case "up": return .up(PointerSample(phase: .up, location: point, modifiers: [], timestamp: time), snapshot)
        case "post": return .post(ApplicationProcessIdentity(snapshot: snapshot), runtime, timestamp: time)
        default: return .cancelled
        }
    }

    private func parseShortcut(_ value: String) -> LiveShortcutResolution {
        value.hasPrefix("resolved:") ? resolved(String(value.dropFirst("resolved:".count))) : .unavailable
    }

    private func resolved(_ displayString: String) -> LiveShortcutResolution {
        var modifiers = 0
        if displayString.contains("⇧") { modifiers |= 1 }
        if displayString.contains("⌥") { modifiers |= 2 }
        if displayString.contains("⌃") { modifiers |= 4 }
        if !displayString.contains("⌘") { modifiers |= 8 }
        let evidence = AXShortcutEvidence(
            commandCharacter: ",",
            modifiers: modifiers,
            commandGlyph: nil,
            virtualKey: nil
        )
        return .resolved(LiveShortcutObservation(evidence: evidence)!)
    }
}
