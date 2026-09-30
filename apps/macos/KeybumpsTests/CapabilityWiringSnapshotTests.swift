import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import Speech
import Testing
@testable import Keybumps

/// Characterizes how `AppModel` wires every capability, so a refactor can prove it changed nothing.
/// Re-record only with `KEYBUMPS_RECORD_SNAPSHOTS=1` (through xcodebuild: `TEST_RUNNER_KEYBUMPS_RECORD_SNAPSHOTS=1`).
@MainActor
@Suite("Capability wiring snapshot")
struct CapabilityWiringSnapshotTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/capability-wiring.json")

    @Test("Wiring for every capability combination matches the recorded fixture")
    func wiringMatchesFixture() throws {
        let actual = try WiringRecorder.renderSnapshot()
        let environment = ProcessInfo.processInfo.environment
        if environment["KEYBUMPS_RECORD_SNAPSHOTS"] == "1" {
            try actual.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        if actual != expected {
            Attachment.record(actual, named: "capability-wiring.actual.json")
            Issue.record("Capability wiring changed. \(WiringRecorder.firstDifference(expected: expected, actual: actual))")
        }
    }

    @Test("Rendering the wiring snapshot is deterministic")
    func renderingIsDeterministic() throws {
        #expect(try WiringRecorder.renderSnapshot() == WiringRecorder.renderSnapshot())
    }
}

// MARK: - Snapshot model

struct CapabilityWiringSnapshot: Codable {
    struct PaletteTab: Codable {
        let tab: String
        let label: String
        let commandKey: String
        let matchedByCommandKey: String?
        let systemImage: String
        let prompt: String
        let primaryAction: String?
        let secondaryAction: String?
    }

    struct Destination: Codable {
        let section: String
        let icon: String
    }

    struct State: Codable {
        let shortcuts: [String: String]
        let screenshotToolsStatus: String
        let clipboardEditActionWired: Bool
        let detectorStatus: String
        let settingsAttention: [String: Int]
        let missingPermissionCount: Int
    }

    struct Combination: Codable {
        let enabled: [String]
        let requiredPermissions: [String]
        let startLifecycle: [String]
        let afterStart: State
        /// One line per step, in order: lifecycle calls, shortcut owners added/removed, and resulting status.
        let steps: [String]
        /// Keyed by the missing permission; each line records start lifecycle, detector status,
        /// non-zero Settings attention, and missing permissions.
        let permissionsMissing: [String: String]
        /// `start()` while onboarding is incomplete: lifecycle, shortcut owners, and detector status.
        let startBeforeOnboarding: String
    }

    let paletteTabs: [PaletteTab]
    let settingsDestinations: [Destination]
    let combinations: [String: Combination]
}

// MARK: - Recorder

@MainActor
enum WiringRecorder {
    static func renderSnapshot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeybumpsCapabilityWiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var combinations: [String: CapabilityWiringSnapshot.Combination] = [:]
        for mask in 0..<(1 << Capability.allCases.count) {
            let enabled = Set(Capability.allCases.enumerated().compactMap { index, capability in
                mask & (1 << index) != 0 ? capability : nil
            })
            let key = String(format: "%02d", mask) + " " + (enabled.isEmpty ? "none" : Capability.allCases.filter(enabled.contains).map(\.rawValue).joined(separator: "+"))
            combinations[key] = record(enabled: enabled, root: root)
        }

        let snapshot = CapabilityWiringSnapshot(
            paletteTabs: CommandPaletteTab.allCases.map { tab in
                let key = String(tab.shortcutLabel.last ?? " ")
                return .init(
                    tab: tab.rawValue,
                    label: tab.labelPresentation.name,
                    commandKey: tab.labelPresentation.shortcut,
                    matchedByCommandKey: CommandPaletteTab.matchingCommandKey(key)?.rawValue,
                    systemImage: tab.systemImage,
                    prompt: tab.prompt,
                    primaryAction: tab.primaryActionTitle,
                    secondaryAction: tab.secondaryActionTitle
                )
            },
            settingsDestinations: SettingsSection.allCases.map { .init(section: $0.rawValue, icon: $0.icon) },
            combinations: combinations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(snapshot), as: UTF8.self) + "\n"
    }

    private static func record(enabled: Set<Capability>, root: URL) -> CapabilityWiringSnapshot.Combination {
        let granted = WiringHarness(enabled: enabled, missing: nil, root: root)
        granted.model.start()
        let startLifecycle = granted.log.drain()
        let afterStart = granted.state()

        var steps: [String] = []
        steps.append(granted.step("dictation phase recording") { $0.dictation.onPhaseChange?(.recording) })
        for capability in Capability.allCases {
            let isEnabled = enabled.contains(capability)
            steps.append(granted.step("\(isEnabled ? "disable" : "enable") \(capability.rawValue)") {
                $0.setCapability(capability, enabled: !isEnabled)
            })
            steps.append(granted.step("\(isEnabled ? "re-enable" : "re-disable") \(capability.rawValue)") {
                $0.setCapability(capability, enabled: isEnabled)
            })
        }
        steps.append(granted.step("dictation phase idle") { $0.dictation.onPhaseChange?(.idle) })

        var permissionsMissing: [String: String] = [:]
        for missing in MacPermission.allCases {
            let harness = WiringHarness(enabled: enabled, missing: missing, root: root)
            harness.model.start()
            let lifecycle = harness.log.drain()
            permissionsMissing[missing.rawValue] = [
                "start \(list(lifecycle))",
                "detector \(describe(harness.model.detectorStatus))",
                "attention \(describe(harness.attention()))",
                "missing \(list(harness.model.permissionReadiness.missingPermissions.map(\.rawValue)))"
            ].joined(separator: "; ")
        }

        let onboarding = WiringHarness(enabled: enabled, missing: nil, root: root, didCompleteOnboarding: false)
        onboarding.model.start()
        let startBeforeOnboarding = [
            "start \(list(onboarding.log.drain()))",
            "shortcuts \(list(onboarding.shortcuts().keys.sorted()))",
            "detector \(describe(onboarding.model.detectorStatus))"
        ].joined(separator: "; ")

        return .init(
            enabled: Capability.allCases.filter(enabled.contains).map(\.rawValue),
            requiredPermissions: PermissionSetupPlan.requiredPermissions(for: enabled).map(\.rawValue),
            startLifecycle: startLifecycle,
            afterStart: afterStart,
            steps: steps,
            permissionsMissing: permissionsMissing,
            startBeforeOnboarding: startBeforeOnboarding
        )
    }

    static func list(_ items: [String]) -> String {
        "[" + items.joined(separator: ", ") + "]"
    }

    /// Only sections that need attention, in Settings order.
    static func describe(_ attention: [String: Int]) -> String {
        list(SettingsSection.allCases.compactMap { section in
            attention[section.rawValue].flatMap { $0 > 0 ? "\(section.rawValue): \($0)" : nil }
        })
    }

    static func describe(_ status: ManualActionDetector.Status) -> String {
        switch status {
        case .stopped: "stopped"
        case .monitoring: "monitoring"
        case .failed: "failed"
        case .permissionRequired(let permissions):
            "permissionRequired(" + permissions.map { $0 == .accessibility ? "accessibility" : "inputMonitoring" }.joined(separator: ",") + ")"
        }
    }

    static func describe(_ status: ScreenshotToolsStatus) -> String {
        // Folder paths are omitted: they are environment-specific and must never be committed.
        switch status {
        case .stopped: "stopped"
        case .requiresClipboardHistory: "requiresClipboardHistory"
        case .watching: "watching"
        case .folderAccessDenied: "folderAccessDenied"
        case .folderUnavailable: "folderUnavailable"
        }
    }

    static func firstDifference(expected: String, actual: String) -> String {
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        for index in 0..<max(expectedLines.count, actualLines.count) {
            let lhs = index < expectedLines.count ? expectedLines[index] : "<end of fixture>"
            let rhs = index < actualLines.count ? actualLines[index] : "<end of output>"
            if lhs != rhs {
                return "First difference at line \(index + 1):\n  fixture: \(lhs)\n  actual:  \(rhs)"
            }
        }
        return "Outputs differ only in length."
    }
}

// MARK: - Harness

@MainActor
final class WiringHarness {
    let log = LifecycleLog()
    let model: AppModel
    private let coordinator: GlobalShortcutCoordinator
    private let pasteboard: NSPasteboard
    private var lastShortcuts: [String: String] = [:]

    /// `quickSearch` defaults to one with no apps and its stores in the harness's own folder.
    init(
        enabled: Set<Capability>,
        missing: MacPermission?,
        root: URL,
        didCompleteOnboarding: Bool = true,
        quickSearch: QuickSearchModel? = nil
    ) {
        let id = UUID().uuidString
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = AppPreferences(defaults: InMemoryDefaults())
        preferences.enabledCapabilities = enabled
        preferences.didCompleteOnboarding = didCompleteOnboarding
        // Open Snippets starts unassigned; give it one so the snapshot records Snippets registering
        // and releasing its only shortcut.
        preferences.setCapabilityShortcut(Self.snippetsBinding, for: .snippets)

        let log = log
        let grants = FakePermissionState(missing: missing)
        coordinator = GlobalShortcutCoordinator(backend: LoggingHotKeyBackend(log: log))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsCapabilityWiring-\(id)"))
        self.pasteboard = pasteboard
        let clipboard = SpyClipboardHistoryService(
            log: log,
            storageURL: directory.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: directory.appendingPathComponent("clipboard-media", isDirectory: true)
        )
        let screenshotHome = directory.appendingPathComponent("home", isDirectory: true)
        let screenshotTools = SpyScreenshotToolsService(
            log: log,
            resolver: ScreenshotLocationResolver(
                preferredLocation: { nil },
                homeDirectory: screenshotHome,
                isDirectory: { _ in true }
            ),
            reader: FakeScreenshotDirectoryReader(granted: true),
            ingest: { _ in false }
        )
        model = AppModel(
            preferences: preferences,
            inbox: InboxStore(persistence: NullEventPersistence()),
            presenceController: NullPresenceController(),
            detector: ManualActionDetector(
                monitor: LoggingPointerMonitor(log: log),
                permissions: FakeDetectorPermissions(grants: grants)
            ),
            shortcutCoordinator: coordinator,
            permissionCoordinator: PermissionCoordinator(
                accessibilityTrusted: { grants.isGranted(.accessibility) },
                inputMonitoringAuthorized: { grants.isGranted(.inputMonitoring) },
                microphoneAuthorizationStatus: { grants.isGranted(.microphone) ? .authorized : .denied },
                speechAuthorizationStatus: { grants.isGranted(.speechRecognition) ? .authorized : .denied },
                screenRecordingAuthorized: { grants.isGranted(.screenRecording) },
                requestScreenRecording: {},
                openSettings: { _ in }
            ),
            updater: DisabledUpdateController(reason: "Capability wiring snapshot"),
            dictationModelManager: DictationModelManager(
                modelsRoot: directory.appendingPathComponent("models", isDirectory: true),
                downloader: WhisperKitModelDownloader()
            ),
            spotlightShortcutResolver: InertSpotlightShortcutResolver(),
            clipboard: clipboard,
            dictationHistory: DictationHistoryService(
                recordingsDirectoryURL: directory.appendingPathComponent("recordings", isDirectory: true)
            ),
            quickSearch: quickSearch ?? .forTests(in: directory),
            windows: SpyWindowManagementService(log: log),
            screenshotTools: screenshotTools,
            dictationIndicator: SilentDictationIndicator(),
            dictationFileManager: SandboxedFileManager(root: directory)
        )
        _ = log.drain()
        lastShortcuts = shortcuts()
    }

    static let snippetsBinding = ShortcutBinding(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(controlKey | optionKey | shiftKey),
        displayName: "⌃⌥⇧S"
    )

    /// Named pasteboards live in the pasteboard server until released, so drop each one with its harness.
    deinit {
        pasteboard.releaseGlobally()
    }

    func shortcuts() -> [String: String] {
        coordinator.desiredBindings.mapValues { "\($0.displayName) [\($0.keyCode)/\($0.modifiers)]" }
    }

    func attention() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: SettingsSection.allCases.map {
            ($0.rawValue, model.settingsAttentionCount(for: $0))
        })
    }

    func state() -> CapabilityWiringSnapshot.State {
        lastShortcuts = shortcuts()
        return .init(
            shortcuts: lastShortcuts,
            screenshotToolsStatus: WiringRecorder.describe(model.screenshotTools.status),
            clipboardEditActionWired: model.commandPalette.editImage != nil,
            detectorStatus: WiringRecorder.describe(model.detectorStatus),
            settingsAttention: attention(),
            missingPermissionCount: model.missingPermissionCount
        )
    }

    func step(_ name: String, _ action: (AppModel) -> Void) -> String {
        _ = log.drain()
        action(model)
        let current = shortcuts()
        let added = current.filter { lastShortcuts[$0.key] != $0.value }.map(\.key).sorted()
        let removed = lastShortcuts.filter { current[$0.key] != $0.value }.map(\.key).sorted()
        lastShortcuts = current
        return [
            "\(name): lifecycle \(WiringRecorder.list(log.drain()))",
            "shortcuts +\(WiringRecorder.list(added)) -\(WiringRecorder.list(removed))",
            "screenshotTools \(WiringRecorder.describe(model.screenshotTools.status))",
            "editAction \(model.commandPalette.editImage != nil ? "wired" : "unwired")"
        ].joined(separator: "; ")
    }
}

// MARK: - Fakes

@MainActor
final class LifecycleLog {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func drain() -> [String] {
        defer { events = [] }
        return events
    }
}

private final class FakePermissionState: @unchecked Sendable {
    let missing: MacPermission?
    init(missing: MacPermission?) { self.missing = missing }
    func isGranted(_ permission: MacPermission) -> Bool { permission != missing }
}

private struct FakeDetectorPermissions: DetectorPermissionProviding {
    let grants: FakePermissionState
    var isAccessibilityTrusted: Bool { grants.isGranted(.accessibility) }
    var isInputMonitoringAuthorized: Bool { grants.isGranted(.inputMonitoring) }
    func requestAccessibility() {}
    func requestInputMonitoring() {}
}

@MainActor
private final class LoggingHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    private let log: LifecycleLog
    private var escapeIdentifiers: Set<UInt32> = []

    init(log: LifecycleLog) { self.log = log }

    func installHandler(_ handler: @escaping (UInt32) -> Void) {}

    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool {
        if binding == DefaultShortcut.cancelDictation {
            escapeIdentifiers.insert(identifier)
            log.append("dictationEscape.register")
        }
        return true
    }

    func unregister(identifier: UInt32) {
        if escapeIdentifiers.remove(identifier) != nil {
            log.append("dictationEscape.unregister")
        }
    }
}

private final class LoggingPointerMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    private let log: LifecycleLog

    init(log: LifecycleLog) { self.log = log }

    func start() -> Bool {
        MainActor.assumeIsolated { log.append("detector.eventTap.start") }
        return true
    }

    func stop() {
        MainActor.assumeIsolated { log.append("detector.eventTap.stop") }
    }
}

private final class SpyClipboardHistoryService: ClipboardHistoryService {
    private let log: LifecycleLog

    init(log: LifecycleLog, storageURL: URL, pasteboard: NSPasteboard, mediaDirectoryURL: URL) {
        self.log = log
        super.init(storageURL: storageURL, pasteboard: pasteboard, mediaDirectoryURL: mediaDirectoryURL, sourceApps: .inert)
    }

    override func start() { log.append("clipboardMonitor.start") }
    override func stop() { log.append("clipboardMonitor.stop") }
}

private final class SpyScreenshotToolsService: ScreenshotToolsService {
    private let log: LifecycleLog

    init(
        log: LifecycleLog,
        resolver: ScreenshotLocationResolver,
        reader: any ScreenshotDirectoryReading,
        ingest: @escaping (URL) -> Bool
    ) {
        self.log = log
        super.init(resolver: resolver, reader: reader, ingest: ingest)
    }

    override func apply(enabled: Bool, clipboardHistoryEnabled: Bool) {
        log.append("screenshotWatcher.apply(enabled: \(enabled), clipboardHistoryEnabled: \(clipboardHistoryEnabled))")
        super.apply(enabled: enabled, clipboardHistoryEnabled: clipboardHistoryEnabled)
    }

    override func stop() {
        log.append("screenshotWatcher.stop")
        super.stop()
    }
}

private final class SpyWindowManagementService: WindowManagementService {
    private let log: LifecycleLog

    init(log: LifecycleLog) {
        self.log = log
        super.init()
    }

    override func startDragSnapping() { log.append("dragToSnap.start") }
    override func stop() { log.append("dragToSnap.stop") }
}

private final class SilentDictationIndicator: DictationIndicatorController {
    override func update(_ phase: DictationPhase) {}
}

/// Keeps Dictation's recovery file out of the user's real Application Support folder.
private final class SandboxedFileManager: FileManager {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root.appendingPathComponent("\(directory.rawValue)", isDirectory: true)]
    }
}

private struct NullEventPersistence: EventPersistence {
    func load() throws -> [CoachingEvent] { [] }
    func save(_ events: [CoachingEvent]) throws {}
}

@MainActor
private struct NullPresenceController: AppPresenceControlling {
    func apply(showInDockAndSwitcher: Bool) {}
}
