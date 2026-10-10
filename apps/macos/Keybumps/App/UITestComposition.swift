import AppKit
import AVFoundation
import Speech

/// The composition XCUITests launch. It swaps every permission check, event tap, hot-key
/// registration, audio capture, and user folder for a fake, and keeps all data in a disposable
/// sandbox. Production launches never reach it: `AppModel.forLaunch()` returns the normal
/// composition when `-KBUITestPermissions` is absent, and Release builds compile none of it.
extension AppModel {
    static func forLaunch(_ configuration: UITestLaunchConfiguration = .current) -> AppModel {
        #if DEBUG
        if let mode = configuration.permissions {
            return makeForUITesting(granted: mode == .granted, configuration: configuration)
        }
        #endif
        return AppModel()
    }

    private static var didPerformUITestLaunchActions = false

    /// Runs after `start()`, once the main window exists. Only the first call acts, because the
    /// window's `.task` reruns whenever the main window is reopened.
    func performUITestLaunchActions(_ configuration: UITestLaunchConfiguration = .current) {
        guard configuration.isUITesting, !Self.didPerformUITestLaunchActions else { return }
        if configuration.opensScreencastPicker {
            Self.didPerformUITestLaunchActions = true
            // The next turn, once the main window has appeared, so the picker opens over it.
            DispatchQueue.main.async { [weak self] in self?.startScreencast() }
            return
        }
        #if DEBUG
        if configuration.startsScreencastRecording {
            Self.didPerformUITestLaunchActions = true
            DispatchQueue.main.async { [weak self] in self?.startScreencastRecordingForUITesting() }
            return
        }
        #endif
        guard let tab = configuration.openPalette else { return }
        Self.didPerformUITestLaunchActions = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard configuration.closesSettings else {
            showCommandPalette(tab)
            return
        }
        // Settings opens at launch, so close it first; a test can then show that an action
        // reopens it. The next turn lets the window finish appearing before it closes.
        DispatchQueue.main.async { [weak self] in
            for window in NSApplication.shared.windows where window.isVisible && window.canBecomeMain {
                window.close()
            }
            self?.showCommandPalette(tab)
        }
    }
}

extension NSPasteboard {
    static let uiTestPasteboard = NSPasteboard(name: NSPasteboard.Name("com.serp.keybumps.uitests.clipboard"))

    /// The pasteboard Keybumps reads and writes: the general pasteboard, or a private named one in
    /// UI test mode so tests never touch the user's real clipboard.
    static var keybumps: NSPasteboard {
        UITestLaunchConfiguration.current.isUITesting ? uiTestPasteboard : .general
    }
}

#if DEBUG
extension AppModel {
    static let uiTestDefaultsSuite = "com.serp.keybumps.uitests"

    private static func makeForUITesting(granted: Bool, configuration: UITestLaunchConfiguration) -> AppModel {
        let sandbox = UITestSandbox.prepare()

        let defaults = UserDefaults(suiteName: uiTestDefaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: uiTestDefaultsSuite)
        defaults.set(true, forKey: "didCompleteOnboarding")
        let preferences = AppPreferences(defaults: defaults)
        for capability in configuration.enabledCapabilities {
            preferences.setCapability(capability, enabled: true)
        }
        if configuration.startsScreencastRecording {
            preferences.set(.choice("0"), of: .screencastCountdown, for: .screencast)
        }

        let clipboard = ClipboardHistoryService(pasteboard: .uiTestPasteboard, sourceApps: .inert)
        if configuration.seedsRecentKeybumps {
            // Into the sandbox's Recent Items, before the palette's Quick Search loads them.
            RecentItemStore().record(QuickSearchResult(url: Bundle.main.bundleURL, kind: .application))
        }
        // Sensitive snippets stay in memory, never in the Keychain.
        let snippets = SnippetStore(
            storageURL: ProductPaths.keybumps().applicationSupport.appendingPathComponent(SnippetStore.fileName),
            secrets: InMemorySnippetSecretStore()
        )
        if configuration.seedsSnippets {
            for name in ["Made-up alpha", "Made-up beta", "Made-up gamma"] {
                _ = try? snippets.add(SnippetDraft(name: name, text: "Text of \(name)"))
            }
        }
        let model = AppModel(
            preferences: preferences,
            inbox: InboxStore(),
            presenceController: AppPresenceController(),
            detector: ManualActionDetector(
                monitor: InertPointerEventMonitor(),
                permissions: FakeDetectorPermissions(granted: granted)
            ),
            shortcutCoordinator: configuration.disablesHotKeys
                ? GlobalShortcutCoordinator(backend: InertGlobalHotKeyBackend())
                : nil,
            permissionCoordinator: PermissionCoordinator(
                accessibilityTrusted: { granted },
                inputMonitoringAuthorized: { granted },
                microphoneAuthorizationStatus: { granted ? .authorized : .denied },
                speechAuthorizationStatus: { granted ? .authorized : .denied },
                screenRecordingAuthorized: { granted },
                requestMicrophone: PermissionPrompts.inert.requestMicrophone,
                requestSpeechRecognition: PermissionPrompts.inert.requestSpeechRecognition,
                requestScreenRecording: PermissionPrompts.inert.requestScreenRecording,
                openSettings: { _ in },
                openSystemSettings: PermissionPrompts.inert.openSystemSettings
            ),
            licensing: FixedLicenseController(state: {
                switch configuration.licenseState {
                case .active: return .active(FixedLicenseController.sampleCheck)
                case .unlicensed: return .unlicensed
                case .revoked: return .locked(.notAccepted)
                }
            }()),
            spotlightShortcutResolver: InertSpotlightShortcutResolver(),
            clipboard: clipboard,
            snippets: snippets,
            // Never writes the pasteboard or posts ⌘V, even if system access were allowed.
            textPaster: InertTextPaster(),
            // Never listens to the keyboard.
            keyTypingMonitor: InertKeyTypingMonitor(),
            // The key display never hears the keyboard or the pointer, and draws nothing.
            keyDisplay: KeyDisplay(keys: InertKeyTypingMonitor(), pointer: InertPointerEventMonitor(), presenter: InertKeyDisplayPresenter()),
            // Never shows the restart prompt or What's New.
            updatePrompt: InertUpdatePromptPresenter(),
            whatsNew: InertWhatsNewPresenter(),
            // A timer's end never plays a sound.
            timerAlerts: InertTimerAlerts(),
            // Never downloads a language, translates, or reads aloud.
            translator: InertTextTranslator(),
            translationSpeaker: InertTranslationSpeaker(),
            screenshotTools: ScreenshotToolsService(
                resolver: ScreenshotLocationResolver(
                    preferredLocation: { sandbox.screenshots.path },
                    homeDirectory: sandbox.root,
                    isDirectory: { _ in true }
                ),
                reader: FakeScreenshotDirectoryReader(granted: granted),
                ingest: { clipboard.ingestImageFile(at: $0, isScreenCapture: true) }
            ),
            allowsDictationSystemAccess: false,
            screenshotEditorFallbackFolder: { sandbox.screenshots },
            symbolicHotKeyPreferences: InertSymbolicHotKeyPreferences(),
            // Screencast's picker opens on made-up screens and windows; a recording runs on them but
            // captures nothing, and a capture is never shown in Finder.
            screencast: ScreencastSeams(
                captureSystem: UITestScreencastCaptureSystem(),
                pickerSystem: UITestScreencastScreen(),
                screens: { UITestScreencastScreen.layout },
                revealCapture: { _ in }
            )
        )
        if configuration.seedsClipboardImage, let image = UITestSandbox.writeSampleImage(in: sandbox.root) {
            model.clipboard.ingestImageFile(at: image, isScreenCapture: false)
        }
        return model
    }
}

enum UITestSandbox {
    struct Paths {
        let root: URL
        let screenshots: URL
    }

    static func prepare(fileManager: FileManager = .default) -> Paths {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KeybumpsUITests", isDirectory: true)
        try? fileManager.removeItem(at: root)
        let screenshots = root.appendingPathComponent("Screenshots", isDirectory: true)
        try? fileManager.createDirectory(at: screenshots, withIntermediateDirectories: true)
        ProductPaths.sandboxRoot = root
        return Paths(root: root, screenshots: screenshots)
    }

    /// A generated 320×200 PNG so tests never depend on the real pasteboard or user files.
    static func writeSampleImage(in root: URL) -> URL? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 200, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = root.appendingPathComponent("sample.png")
        guard let data = bitmap.representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

private struct FakeDetectorPermissions: DetectorPermissionProviding {
    let granted: Bool
    var isAccessibilityTrusted: Bool { granted }
    var isInputMonitoringAuthorized: Bool { granted }
    func requestAccessibility() {}
    func requestInputMonitoring() {}
}

@MainActor
private final class InertGlobalHotKeyBackend: GlobalHotKeyRegistering {
    let registrationScope = GlobalHotKeyRegistrationScope.systemWide
    func installHandler(_ handler: @escaping (UInt32) -> Void) {}
    func register(binding: ShortcutBinding, identifier: UInt32) -> Bool { true }
    func unregister(identifier: UInt32) {}
}

/// Screencast's made-up screen in UI test mode: the main screen split into two displays side by
/// side, with two windows of a made-up app on the left one, so a test can switch modes and pick a
/// screen without reading the real screen. Screenshots are blank.
@MainActor
final class UITestScreencastScreen: ScreencastPickerSystem {
    static let madeUpProcess: pid_t = 1

    /// The two displays in AppKit's space: the left and right halves of the main screen.
    static var layout: ScreencastScreenLayout {
        let main = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let half = (main.width / 2).rounded(.down)
        return ScreencastScreenLayout(screens: [
            ScreencastScreen(id: 9_001, frame: CGRect(x: main.minX, y: main.minY, width: half, height: main.height), scale: 2),
            ScreencastScreen(id: 9_002, frame: CGRect(x: main.minX + half, y: main.minY, width: half, height: main.height), scale: 2),
        ])
    }

    func content() async throws -> ScreencastContent {
        let layout = Self.layout
        let displays = layout.screens.map {
            ScreencastContent.Display(id: $0.id, frame: layout.topLeftRect(fromAppKit: $0.frame), scale: $0.scale)
        }
        let windows = [CGRect(x: 60, y: 120, width: 400, height: 300), CGRect(x: 200, y: 260, width: 360, height: 240)]
            .enumerated()
            .map { index, frame in
                ScreencastContent.Window(
                    id: CGWindowID(9_101 + index), frame: frame, layer: 0, processID: Self.madeUpProcess,
                    isUntitled: false, isOnScreen: true
                )
            }
        return ScreencastContent(displays: displays, windows: windows, applicationProcessIDs: [Self.madeUpProcess])
    }

    func transparentWindows() -> Set<CGWindowID> { [] }

    func screenshot(_ plan: ScreencastScreenshotPlan, content: ScreencastContent) async throws -> CGImage {
        let width = max(plan.configuration.pixelWidth, 2)
        let height = max(plan.configuration.pixelHeight, 2)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { throw ScreencastFailure.captureFailed }
        return image
    }
}

final class InertSpotlightShortcutResolver: SpotlightShortcutConflictResolving {
    func status(for binding: ShortcutBinding) -> SpotlightShortcutConflictStatus { .noConflict }
    func disableIfConflicting(_ binding: ShortcutBinding) -> SpotlightShortcutResolution { .noLongerConflicting }
}

struct FakeScreenshotDirectoryReader: ScreenshotDirectoryReading {
    let granted: Bool
    func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry] {
        guard granted else { throw ScreenshotFolderReadError.accessDenied }
        return []
    }
}
#endif
