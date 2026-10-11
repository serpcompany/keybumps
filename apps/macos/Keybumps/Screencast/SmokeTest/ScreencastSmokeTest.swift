import AppKit
import CoreGraphics
import Foundation

/// QA candidates only: `-KBScreencastSmokeTest YES` runs Screencast's real capture path instead of
/// Keybumps, with no mouse or keyboard input, then quits (#470). Unit and UI tests run Screencast
/// against fake capture, so this is what first runs ScreenCaptureKit, AVFoundation, and the
/// control bar's and overlays' windows for real before a candidate reaches the owner.
///
/// It records 2 seconds each of the main display, the blank window the script shows from a helper
/// process (`windowProcessOption`), and an area in the middle of the main display, with no sound,
/// shortcuts, or click highlights, and takes a screenshot of each (`ScreencastSmokeRunner`);
/// checks each file, deletes it, writes a structural result to `resultURL()`, and exits 0 when
/// everything passed.
/// Nothing of the person's is composed: no `AppModel`, shortcuts, menu bar item, or updater. It
/// needs Screen Recording already granted and never asks for it.
/// `apps/macos/scripts/smoke-screencast.sh` runs it on the installed candidate.
@MainActor
enum ScreencastSmokeTest {
    nonisolated static let launchOption = "KBScreencastSmokeTest"
    /// The process ID of the script's helper, whose blank window is the only one the window
    /// captures may take.
    nonisolated static let windowProcessOption = "KBScreencastSmokeWindowPID"
    /// Its own defaults, so the area it draws never replaces the person's last one. Emptied before
    /// and after it runs.
    static let defaultsSuite = "com.serp.keybumps.screencast-smoke-test"
    /// Its captures folder, in the temporary folder: emptied before it runs, deleted after, and
    /// deleted by the script too, so a run that crashed leaves nothing for long.
    nonisolated static let capturesFolderName = "Keybumps-screencast-smoke-test"

    /// Whether this launch is the smoke test: asked for, in a QA candidate (`CrashReportTest.isAllowed`).
    static func isRequested(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Bool {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return isRequested(version: version, defaults: defaults)
    }

    static func isRequested(version: String, defaults: UserDefaults) -> Bool {
        CrashReportTest.isAllowed(version: version) && defaults.bool(forKey: launchOption)
    }

    /// The helper's process ID from `-KBScreencastSmokeWindowPID <pid>`; nil when there's none.
    static func windowProcessID(defaults: UserDefaults = .standard) -> pid_t? {
        let value = defaults.integer(forKey: windowProcessOption)
        return value > 0 && value <= Int(Int32.max) ? pid_t(value) : nil
    }

    /// `~/Library/Developer/Keybumps-QA/screencast-smoke-test.json`, beside the QA candidates'
    /// backups (`build-qa-candidate.sh`).
    nonisolated static func resultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Developer/Keybumps-QA", isDirectory: true)
            .appendingPathComponent("screencast-smoke-test.json")
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
        let runner = ScreencastSmokeRunner(
            rig: rig,
            inspector: .system,
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
