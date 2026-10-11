import AppKit
import CoreGraphics
import Foundation

/// QA candidates only: `-KBScreencastSmokeTest YES` runs Screencast's real capture path instead of
/// Keybumps, with no mouse or keyboard input, then quits (#470). Unit and UI tests run Screencast
/// against fake capture, so this is what first runs ScreenCaptureKit, AVFoundation, and the
/// control bar's and overlays' windows for real before a candidate reaches the owner.
///
/// It records 2 seconds each of the main display, a small window of its own, and an area in the
/// middle of the main display, with no sound, shortcuts, or click highlights, and takes a
/// screenshot of each (`ScreencastSmokeRunner`); checks each file, deletes it, writes a structural
/// result to `resultURL()`, and exits 0 when everything passed. Nothing of the person's is
/// composed: no `AppModel`, shortcuts, menu bar item, or updater. It needs Screen Recording already
/// granted and never asks for it. `apps/macos/scripts/smoke-screencast.sh` runs it on the
/// installed candidate.
@MainActor
enum ScreencastSmokeTest {
    static let launchOption = "KBScreencastSmokeTest"
    /// Its own defaults, so the area it draws never replaces the person's last one. Emptied before
    /// and after it runs.
    static let defaultsSuite = "com.serp.keybumps.screencast-smoke-test"

    /// Whether this launch is the smoke test: asked for, in a QA candidate (`CrashReportTest.isAllowed`).
    static func isRequested(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Bool {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return isRequested(version: version, defaults: defaults)
    }

    static func isRequested(version: String, defaults: UserDefaults) -> Bool {
        CrashReportTest.isAllowed(version: version) && defaults.bool(forKey: launchOption)
    }

    /// `~/Library/Developer/Keybumps-QA/screencast-smoke-test.json`, beside the QA candidates'
    /// backups (`build-qa-candidate.sh`).
    static func resultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
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

        let window = ScreencastSmokeWindow()
        window.show()
        defer { window.close() }
        let captureSystem = ScreenCaptureKitCaptureSystem.current
        let rig = ScreencastSmokeRig.make(
            recorder: ScreencastRecorder(system: captureSystem, microphoneGranted: { false }),
            captureSystem: captureSystem,
            pickerSystem: ScreenCaptureKitPickerSystem.current,
            presenter: ScreencastOverlayWindows(),
            screens: { ScreencastScreenLayout.current() },
            defaults: defaults,
            capturesFolder: FileManager.default.temporaryDirectory
                .appendingPathComponent("Keybumps-screencast-smoke-\(UUID().uuidString)", isDirectory: true)
        )
        let runner = ScreencastSmokeRunner(
            rig: rig,
            inspector: .system,
            environment: ScreencastSmokeRunner.Environment(
                macOS: macOS,
                displayCount: displayCount,
                screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
                mainDisplay: { CGMainDisplayID() },
                ownWindow: { window.windowID },
                isFinder: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == "com.apple.finder" },
                resultURL: resultURL
            )
        )
        return await runner.run().exitCode
    }
}

/// The small plain window the window video records: Keybumps's own, so none of the person's
/// windows is recorded, with a spinner so its picture keeps changing. It never takes the keyboard.
@MainActor
final class ScreencastSmokeWindow {
    private let window: NSWindow

    init() {
        let size = CGSize(width: 360, height: 220)
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = CGRect(x: visible.minX + 80, y: visible.maxY - size.height - 80, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Keybumps Screencast smoke test"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: "Keybumps is checking Screencast. This window closes on its own.")
        label.alignment = .center
        label.frame = CGRect(x: 20, y: 40, width: size.width - 40, height: 40)
        let spinner = NSProgressIndicator(frame: CGRect(x: (size.width - 32) / 2, y: 110, width: 32, height: 32))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        content.addSubview(label)
        content.addSubview(spinner)
        window.contentView = content
    }

    /// Its number, once it's on screen.
    var windowID: CGWindowID? {
        CGWindowID(exactly: window.windowNumber).flatMap { $0 > 0 ? $0 : nil }
    }

    func show() {
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
