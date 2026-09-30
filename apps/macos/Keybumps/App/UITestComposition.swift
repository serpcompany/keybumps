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
        guard configuration.isUITesting, !Self.didPerformUITestLaunchActions,
              let tab = configuration.openPalette else { return }
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

        let clipboard = ClipboardHistoryService(pasteboard: .uiTestPasteboard, sourceApps: .inert)
        let model = AppModel(
            preferences: AppPreferences(defaults: defaults),
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
                openSettings: PermissionPrompts.inert.openSettings
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
            symbolicHotKeyPreferences: InertSymbolicHotKeyPreferences()
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

private final class InertPointerEventMonitor: PointerEventMonitoring {
    var onSample: ((PointerSample) -> Void)?
    var onTapRecovered: (() -> Void)?
    func start() -> Bool { true }
    func stop() {}
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
