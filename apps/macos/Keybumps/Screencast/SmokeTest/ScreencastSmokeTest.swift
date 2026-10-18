import AppKit
import CoreGraphics
import Foundation

/// QA candidates only: `-KBScreengrabsSmokeTest YES` runs Screengrabs' real capture paths instead
/// of Keybumps, with no mouse or keyboard input, then quits (#470, #491). Unit and UI tests run
/// Screengrabs against fake capture, so this is what first runs `screencapture`, ScreenCaptureKit,
/// AVFoundation, and the control bar's and overlays' windows for real before a candidate reaches
/// the owner.
///
/// It takes a screenshot of each display and one of an area through `ScreenshotCapturer`, checks
/// each, has a watcher add it to a Clipboard History of its own and checks that ⌘3 would list it
/// (`ScreenshotSmokeRunner`). Then it records 2 seconds each of the main display, the blank window
/// the script shows from a helper process (`windowProcessOption`), and an area in the middle of the
/// main display, with no sound, shortcuts, or click highlights (`ScreencastSmokeRunner`), and
/// checks each file. It deletes every file, writes a structural result to `resultURL()`, and exits
/// 0 when everything passed.
/// Nothing of the person's is composed: no `AppModel`, Clipboard History, shortcuts, menu bar
/// item, or updater, and nothing is saved in the screenshot folder, the Desktop, or the recordings
/// folder. It needs Screen Recording already granted and never asks for it.
/// `apps/macos/scripts/smoke-screengrabs.sh` runs it on the installed candidate.
@MainActor
enum ScreencastSmokeTest {
    nonisolated static let launchOption = "KBScreengrabsSmokeTest"
    /// The process ID of the script's helper, whose blank window is the only one the window
    /// capture may take.
    nonisolated static let windowProcessOption = "KBScreengrabsSmokeWindowPID"
    /// Its own defaults, so the area it draws and the mode and screen it picks never replace the
    /// person's last ones. Emptied before and after it runs.
    static let defaultsSuite = "com.serp.keybumps.screencast-smoke-test"
    /// Its Recordings folder, in the temporary folder: emptied before it runs, deleted after, and
    /// deleted by the script too, so a run that crashed leaves nothing for long. Recordings are
    /// saved in it, and the screenshots and their Clipboard History in folders inside it.
    nonisolated static let capturesFolderName = "Keybumps-screengrabs-smoke-test"
    nonisolated static let screenshotsFolderName = "screenshots"
    nonisolated static let clipboardFolderName = "clipboard"

    /// Whether this launch is the smoke test: asked for, in a QA candidate (`CrashReportTest.isAllowed`).
    static func isRequested(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Bool {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return isRequested(version: version, defaults: defaults)
    }

    static func isRequested(version: String, defaults: UserDefaults) -> Bool {
        CrashReportTest.isAllowed(version: version) && defaults.bool(forKey: launchOption)
    }

    /// The helper's process ID from `-KBScreengrabsSmokeWindowPID <pid>`, which arrives as a string
    /// like every launch argument; nil when there's none or it isn't a process ID.
    static func windowProcessID(defaults: UserDefaults = .standard) -> pid_t? {
        guard let value = defaults.string(forKey: windowProcessOption).flatMap({ pid_t($0) }), value > 0 else { return nil }
        return value
    }

    /// `~/Library/Developer/Keybumps-QA/screengrabs-smoke-test.json`, beside the QA candidates'
    /// backups (`build-qa-candidate.sh`).
    nonisolated static func resultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Developer/Keybumps-QA", isDirectory: true)
            .appendingPathComponent("screengrabs-smoke-test.json")
    }

    /// Runs the smoke test in a bare application, then exits with its result's code.
    static func runAndExit() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                _ = Task { @MainActor in exit(await run()) }
            }
        }
        withExtendedLifetime(observer) { app.run() }
        exit(1)
    }

    private static func run() async -> Int32 {
        let resultURL = resultURL()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let displayCount = NSScreen.screens.count
        guard #available(macOS 15, *) else {
            var report = ScreencastSmokeReport(macOS: macOS, displayCount: displayCount, modes: [])
            report.errorCategory = ScreencastSmokeFailure.unsupportedMacOS.rawValue
            report.complete = true
            try? report.write(to: resultURL)
            return report.exitCode
        }
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            var report = ScreencastSmokeReport(macOS: macOS, displayCount: displayCount, modes: [])
            report.errorCategory = ScreencastSmokeFailure.setupFailed.rawValue
            report.complete = true
            try? report.write(to: resultURL)
            return report.exitCode
        }

        let capturesFolder = FileManager.default.temporaryDirectory.appendingPathComponent(capturesFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: capturesFolder)
        let captureSystem = ScreenCaptureKitCaptureSystem.current
        let rig = ScreencastSmokeRig.make(
            recorder: ScreencastRecorder(system: captureSystem, microphoneGranted: { false }),
            captureSystem: captureSystem,
            pickerSystem: ScreenCaptureKitPickerSystem.current,
            presenter: ScreencastOverlayWindows(),
            screens: { ScreencastScreenLayout.current() },
            defaults: defaults,
            capturesFolder: capturesFolder
        )
        let screenshots = ScreenshotSmokeRunner(
            environment: ScreenshotSmokeRunner.Environment(
                screenshotsFolder: capturesFolder.appendingPathComponent(screenshotsFolderName, isDirectory: true),
                clipboardFolder: capturesFolder.appendingPathComponent(clipboardFolderName, isDirectory: true),
                runner: ProcessScreenshotCaptureRunner(),
                displays: ScreenshotSmokeDisplay.connected()
            )
        )
        let runner = ScreencastSmokeRunner(
            rig: rig,
            inspector: .system,
            screenshots: screenshots,
            environment: ScreencastSmokeRunner.Environment(
                macOS: macOS,
                displayCount: displayCount,
                screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
                mainDisplay: { CGMainDisplayID() },
                windowProcessID: windowProcessID(),
                resultURL: resultURL
            )
        )
        return await runner.run().exitCode
    }
}
