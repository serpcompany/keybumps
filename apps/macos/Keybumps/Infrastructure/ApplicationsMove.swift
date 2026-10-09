import AppKit

/// Offers to move Keybumps into Applications when it opens from anywhere else: the disk image,
/// Downloads, or the read-only copy macOS runs a quarantined app from (App Translocation). Run
/// from there, Sparkle can't install updates and permissions attach to a copy that goes away
/// (#437). It runs before launch finishes, so nothing has started yet if Keybumps moves.
enum ApplicationsMove {
    static let appName = "Keybumps.app"
    static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func userApplicationsFolder(home: URL) -> URL {
        home.appendingPathComponent("Applications", isDirectory: true)
    }

    /// Whether `appURL` is already somewhere Keybumps belongs: `/Applications` or the person's
    /// own `~/Applications`, including folders inside them.
    static func isInApplications(_ appURL: URL, home: URL) -> Bool {
        let path = appURL.standardizedFileURL.path
        return [applicationsFolder, userApplicationsFolder(home: home)]
            .contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// The installed copy if there is one (`/Applications` first, then `~/Applications`);
    /// otherwise where a new one goes: `/Applications`, or `~/Applications` for an account that
    /// can't write there. Nil when it can't go anywhere.
    static func destination(home: URL, exists: (URL) -> Bool, canWrite: (URL) -> Bool) -> URL? {
        let folders = [applicationsFolder, userApplicationsFolder(home: home)]
        if let installed = folders.map({ $0.appendingPathComponent(appName) }).first(where: exists) {
            return installed
        }
        if canWrite(applicationsFolder) { return applicationsFolder.appendingPathComponent(appName) }
        let user = userApplicationsFolder(home: home)
        if exists(user) ? canWrite(user) : canWrite(home) { return user.appendingPathComponent(appName) }
        return nil
    }

    /// Release builds only: Debug builds and their test hosts run from DerivedData on purpose.
    @MainActor
    static func offerIfNeeded() {
        #if !DEBUG
        guard KeybumpsMain.launchedApp else { return }
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let running = Bundle.main.bundleURL
        guard !isInApplications(running, home: home) else { return }
        let source = AppTranslocation.originalURL(for: running)
        guard !isInApplications(source, home: home) else { return }
        let destination = destination(
            home: home,
            exists: { files.fileExists(atPath: $0.path) },
            canWrite: { files.isWritableFile(atPath: $0.path) }
        )
        let diskImage = DiskImage.containing(source)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL.path + "/"
        let plan = ApplicationsMovePlan(
            source: source,
            destination: destination,
            ownBuild: buildNumber(of: running),
            installedBuild: destination.flatMap { files.fileExists(atPath: $0.path) ? buildNumber(of: $0) : nil },
            // Renaming a bundle out needs write access to both the bundle and its folder.
            installedIsReplaceable: destination.map {
                !files.fileExists(atPath: $0.path)
                    || (files.isWritableFile(atPath: $0.path) && files.isWritableFile(atPath: $0.deletingLastPathComponent().path))
            } ?? false,
            diskImage: diskImage,
            trashesSource: diskImage == nil && source.standardizedFileURL.path.hasPrefix(downloads)
                && files.isWritableFile(atPath: source.deletingLastPathComponent().path)
        )
        ApplicationsMovePrompt.run(plan, ownBuild: buildNumber(of: running))
        #endif
    }

    /// Read from the file each time: `Bundle` caches it, and the installed copy can change while
    /// this runs (a Sparkle update installing as it quits).
    static func buildNumber(of app: URL) -> String {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "" }
        return info["CFBundleVersion"] as? String ?? ""
    }
}

/// What to do with this copy, decided from where it is and what's already installed.
struct ApplicationsMovePlan: Equatable {
    enum Action: Equatable {
        /// Applications has no Keybumps, or an older one: put this copy there.
        case install(replacingOlder: Bool)
        /// Applications already has this build or a newer one: open that instead.
        case openInstalled
        /// This account can't add or replace Keybumps in Applications.
        case cannotInstall
    }

    let source: URL
    let destination: URL?
    let action: Action
    let diskImage: DiskImage?
    /// A copy in Downloads goes to the Trash once it's installed. A disk image's copy stays (the
    /// image is read-only and is ejected), and so does a copy anywhere else.
    let trashesSource: Bool

    init(
        source: URL,
        destination: URL?,
        ownBuild: String,
        installedBuild: String?,
        installedIsReplaceable: Bool,
        diskImage: DiskImage?,
        trashesSource: Bool
    ) {
        self.source = source
        self.destination = destination
        self.diskImage = diskImage
        self.trashesSource = trashesSource
        if destination != nil, let installedBuild, !BuildNumber(ownBuild).isNewer(than: BuildNumber(installedBuild)) {
            action = .openInstalled
        } else if destination == nil || !installedIsReplaceable {
            action = .cannotInstall
        } else {
            action = .install(replacingOlder: installedBuild != nil)
        }
    }
}

/// A `CFBundleVersion` such as `4028` or `4028.430.1`, compared part by part as numbers.
struct BuildNumber: Equatable {
    let parts: [Int]

    init(_ string: String) {
        parts = string.split(separator: ".").map { Int($0) ?? 0 }
    }

    func isNewer(than other: BuildNumber) -> Bool {
        for index in 0..<max(parts.count, other.parts.count) {
            let mine = index < parts.count ? parts[index] : 0
            let theirs = index < other.parts.count ? other.parts[index] : 0
            if mine != theirs { return mine > theirs }
        }
        return false
    }
}

/// Puts a copy of Keybumps in place without ever leaving a half-copied bundle there: `stage`
/// copies it into a staging folder on the destination's volume, and `swap` renames it into place.
/// A copy already there goes to the Trash.
struct ApplicationsInstaller {
    var files = FileManager.default
    /// Inert under the unit-test host, so a test that forgets to inject one never reaches the
    /// owner's Trash.
    var trash: (URL) throws -> Void = { url in
        guard !UnitTestHost.isActive else { throw CocoaError(.featureUnsupported) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Returns the staged copy, its quarantine cleared: the person already chose to open it, so
    /// the installed one opens without asking again.
    func stage(_ source: URL, for destination: URL) throws -> URL {
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        do {
            try files.copyItem(at: source, to: staged)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
        Self.removeQuarantine(under: staged)
        return staged
    }

    func swap(_ staged: URL, into destination: URL) throws {
        let staging = staged.deletingLastPathComponent()
        guard files.fileExists(atPath: destination.path) else {
            try files.moveItem(at: staged, to: destination)
            try? files.removeItem(at: staging)
            return
        }
        let previous = staging.appendingPathComponent("Previous " + destination.lastPathComponent)
        try files.moveItem(at: destination, to: previous)
        do {
            try files.moveItem(at: staged, to: destination)
        } catch {
            try? files.moveItem(at: previous, to: destination)
            throw error
        }
        if (try? trash(previous)) != nil {
            try? files.removeItem(at: staging)
            return
        }
        // The Trash refused it. The staging folder is temporary and macOS clears it, so keep the
        // old copy beside the new one instead.
        let kept = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.deletingPathExtension().lastPathComponent + " (previous).app")
        if (try? files.moveItem(at: previous, to: kept)) != nil {
            try? files.removeItem(at: staging)
        }
    }

    func discard(_ staged: URL) {
        try? files.removeItem(at: staged.deletingLastPathComponent())
    }

    static func removeQuarantine(under root: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(root.path, attribute, XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            removexattr(item.path, attribute, XATTR_NOFOLLOW)
        }
    }
}

/// Whether Sparkle's installer for Keybumps is running: its launchd job (`SUInstallerLauncher`'s
/// `<bundle id>-sparkle-updater`) has a process. It starts once an update is downloaded and
/// installs when Keybumps quits, so while it runs the installed copy may still change.
enum SparkleInstaller {
    static let jobLabel = "\(ProductIdentity.bundleIdentifier)-sparkle-updater"

    static func isRunning() -> Bool {
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["print", "gui/\(getuid())/\(jobLabel)"]
        let output = Pipe()
        launchctl.standardOutput = output
        launchctl.standardError = FileHandle.nullDevice
        guard (try? launchctl.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        return launchctl.terminationStatus == 0 && hasProcess(launchctlPrint: String(decoding: data, as: UTF8.self))
    }

    /// The job's own `pid = …` line, one tab in; nested sections are indented further.
    static func hasProcess(launchctlPrint output: String) -> Bool {
        output.split(separator: "\n").contains { $0.hasPrefix("\tpid = ") }
    }
}

/// The mounted disk image a copy of Keybumps sits on, and the `.dmg` file behind it.
struct DiskImage: Equatable {
    let mountPoint: URL
    let imageFile: URL

    /// Reads `hdiutil info -plist`; nil when `app` isn't on a mounted disk image.
    static func containing(_ app: URL) -> DiskImage? {
        guard let volume = try? app.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["info", "-plist"]
        let output = Pipe()
        hdiutil.standardOutput = output
        hdiutil.standardError = FileHandle.nullDevice
        guard (try? hdiutil.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        hdiutil.waitUntilExit()
        return parse(hdiutilInfo: data, volume: volume)
    }

    static func parse(hdiutilInfo data: Data, volume: URL) -> DiskImage? {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return nil }
        let volumePath = volume.standardizedFileURL.path
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            let mountPoints = entities.compactMap { $0["mount-point"] as? String }
            if mountPoints.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == volumePath }) {
                return DiskImage(mountPoint: URL(fileURLWithPath: volumePath), imageFile: URL(fileURLWithPath: imagePath))
            }
        }
        return nil
    }
}

/// The original location of an app macOS is running from a randomized read-only copy, through
/// Security's App Translocation calls (looked up at run time, as Sparkle and LetsMove do).
enum AppTranslocation {
    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> DarwinBoolean
    private typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?

    static func originalURL(for url: URL) -> URL {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return url }
        defer { dlclose(security) }
        guard let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let isTranslocated = unsafeBitCast(isSymbol, to: IsTranslocated.self)
        let createOriginal = unsafeBitCast(originalSymbol, to: CreateOriginal.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil).boolValue, translocated,
              let original = createOriginal(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }
}

/// After this process exits: open the installed copy, then eject the disk image this one came
/// from, retrying while Finder or Spotlight still holds it. Paths go in as arguments, never into
/// the script text.
struct ApplicationsMoveRelaunchPlan: Equatable {
    let executableURL = URL(fileURLWithPath: "/bin/sh")
    let arguments: [String]

    init(open app: URL, eject mountPoint: URL?, after processIdentifier: pid_t) {
        let script = """
        attempts=0
        while kill -0 "$1" 2>/dev/null; do
          attempts=$((attempts + 1))
          [ "$attempts" -ge 150 ] && exit 1
          sleep 0.1
        done
        /usr/bin/open "$2"
        [ -z "$3" ] && exit 0
        for attempt in 1 2 3 4 5; do
          /usr/bin/hdiutil detach "$3" -quiet && exit 0
          sleep 1
        done
        exit 0
        """
        arguments = ["-c", script, "keybumps-move", String(processIdentifier), app.path, mountPoint?.path ?? ""]
    }
}

/// What happens after the person says yes, with every side effect injected so the order is
/// tested: the new copy is staged before anything quits, and nothing goes to the Trash until the
/// helper that reopens Keybumps is running.
struct ApplicationsMoveSteps {
    enum Outcome: Equatable {
        case relaunching
        /// The Keybumps already open didn't quit (it may be asking about unsaved work).
        case installedCopyStillOpen
        case failed
        /// Keybumps is installed, but the helper that reopens it didn't start.
        case helperFailed
    }

    struct StillOpen: Error {}

    var stage: (_ source: URL, _ destination: URL) throws -> URL
    var discard: (_ staged: URL) -> Void
    /// Throws `StillOpen` when a running copy doesn't quit.
    var quitInstalledCopy: (_ destination: URL) throws -> Void
    var waitForSparkle: () -> Void
    var installedBuild: (_ destination: URL) -> String?
    var swap: (_ staged: URL, _ destination: URL) throws -> Void
    var startHelper: (_ open: URL, _ eject: URL?) throws -> Void
    var trash: (URL) -> Void

    func perform(_ plan: ApplicationsMovePlan, ownBuild: String, trashesDiskImage: Bool) -> Outcome {
        guard let destination = plan.destination else { return .failed }
        if case .install = plan.action {
            guard let staged = try? stage(plan.source, destination) else { return .failed }
            do {
                try quitInstalledCopy(destination)
            } catch {
                discard(staged)
                return .installedCopyStillOpen
            }
            // An older copy may have had an update waiting to install as it quit. Let it finish,
            // and open that copy instead if it's now this build or newer.
            waitForSparkle()
            if let installed = installedBuild(destination), !BuildNumber(ownBuild).isNewer(than: BuildNumber(installed)) {
                discard(staged)
            } else {
                do {
                    try swap(staged, destination)
                } catch {
                    discard(staged)
                    return .failed
                }
            }
        }
        do {
            try startHelper(destination, plan.diskImage?.mountPoint)
        } catch {
            return .helperFailed
        }
        // A mounted image's file can go to the Trash; the helper ejects it after we exit.
        if trashesDiskImage, let image = plan.diskImage?.imageFile { trash(image) }
        if case .install = plan.action, plan.trashesSource { trash(plan.source) }
        return .relaunching
    }
}

@MainActor
enum ApplicationsMovePrompt {
    static func run(_ plan: ApplicationsMovePlan, ownBuild: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSImage(named: NSImage.applicationIconName)
        switch plan.action {
        case .install(let replacingOlder):
            alert.messageText = "Move Keybumps to your Applications folder?"
            alert.informativeText = "Keybumps needs to run from Applications to install updates and keep the permissions you give it."
                + (replacingOlder ? " This replaces the older Keybumps there." : "")
                + (plan.trashesSource ? " The copy in Downloads goes to the Trash." : "")
            alert.addButton(withTitle: "Move to Applications")
        case .openInstalled:
            alert.messageText = "Keybumps is already in your Applications folder"
            alert.informativeText = "Open that copy instead. It's the one that installs updates and keeps your permissions."
            alert.addButton(withTitle: "Open Keybumps")
        case .cannotInstall:
            show("Drag Keybumps into your Applications folder", "This Mac account can't add Keybumps to Applications or replace the copy there. Ask an administrator to drag Keybumps into Applications, then open it from there.")
            return
        }
        alert.addButton(withTitle: "Not Now")
        if plan.diskImage != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Move the downloaded disk image to the Trash"
            alert.suppressionButton?.state = .on
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let progress = plan.action == .openInstalled ? nil : MovingPanel()
        let installer = ApplicationsInstaller()
        let steps = ApplicationsMoveSteps(
            stage: installer.stage(_:for:),
            discard: installer.discard,
            quitInstalledCopy: quitInstalledCopy(at:),
            waitForSparkle: { wait(seconds: 60) { !SparkleInstaller.isRunning() } },
            installedBuild: { FileManager.default.fileExists(atPath: $0.path) ? ApplicationsMove.buildNumber(of: $0) : nil },
            swap: installer.swap(_:into:),
            startHelper: { app, mountPoint in
                let plan = ApplicationsMoveRelaunchPlan(open: app, eject: mountPoint, after: ProcessInfo.processInfo.processIdentifier)
                let helper = Process()
                helper.executableURL = plan.executableURL
                helper.arguments = plan.arguments
                try helper.run()
            },
            trash: { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        )
        let outcome = steps.perform(plan, ownBuild: ownBuild, trashesDiskImage: alert.suppressionButton?.state == .on)
        progress?.close()
        switch outcome {
        case .relaunching:
            exit(0)
        case .installedCopyStillOpen:
            show("Quit the open Keybumps first", "The Keybumps that's already open didn't quit. Quit it, then open this copy again.")
        case .failed:
            show("Keybumps couldn't move itself", "Drag Keybumps into your Applications folder instead, then open it from there.")
        case .helperFailed:
            show("Keybumps is in your Applications folder", "Quit this copy, then open Keybumps from Applications.")
        }
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Asks a copy running from `destination` to quit, and waits for it.
    private static func quitInstalledCopy(at destination: URL) throws {
        let installed = NSRunningApplication.runningApplications(withBundleIdentifier: ProductIdentity.bundleIdentifier)
            .filter { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
        guard !installed.isEmpty else { return }
        installed.forEach { $0.terminate() }
        // It may ask its own question first (unsaved Screenshot Editor changes, Dictation).
        wait(seconds: 30) { installed.allSatisfy(\.isTerminated) }
        guard installed.allSatisfy(\.isTerminated) else { throw ApplicationsMoveSteps.StillOpen() }
    }

    private static func wait(seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    /// A small panel while Keybumps copies itself and waits for the old copy to quit.
    @MainActor
    private final class MovingPanel {
        private let panel: NSPanel

        init() {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Keybumps"
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = NSTextField(labelWithString: "Moving Keybumps to Applications…")
            let row = NSStackView(views: [spinner, label])
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
            panel.contentView = row
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            panel.displayIfNeeded()
        }

        func close() {
            panel.orderOut(nil)
        }
    }
}
