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
            installedIsReplaceable: destination.map { !files.fileExists(atPath: $0.path) || files.isWritableFile(atPath: $0.path) } ?? false,
            diskImage: diskImage,
            trashesSource: diskImage == nil && source.standardizedFileURL.path.hasPrefix(downloads)
                && files.isWritableFile(atPath: source.deletingLastPathComponent().path)
        )
        ApplicationsMovePrompt.run(plan, home: home)
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

/// Puts a copy of Keybumps in place without ever leaving a half-copied bundle there: it copies
/// into a staging folder on the destination's volume, then swaps it in by renaming. A copy
/// already there goes to the Trash.
struct ApplicationsInstaller {
    var files = FileManager.default
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    func install(_ source: URL, at destination: URL) throws {
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        do {
            try files.copyItem(at: source, to: staged)
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
        // The person already chose to open this copy, so the installed one opens without asking
        // again.
        Self.removeQuarantine(under: staged)
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
        // If the Trash refuses it, the old copy stays in the staging folder rather than being deleted.
        if (try? trash(previous)) != nil {
            try? files.removeItem(at: staging)
        }
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

@MainActor
enum ApplicationsMovePrompt {
    private enum Failure: Error {
        case installedCopyStillOpen
    }

    static func run(_ plan: ApplicationsMovePlan, home: URL) {
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
            show("Drag Keybumps into your Applications folder", "This Mac account can't add or replace apps in Applications. Ask an administrator to drag Keybumps there, then open it from Applications.")
            return
        }
        alert.addButton(withTitle: "Not Now")
        if plan.diskImage != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Move the downloaded disk image to the Trash"
            alert.suppressionButton?.state = .on
        }
        guard alert.runModal() == .alertFirstButtonReturn, let destination = plan.destination else { return }
        let trashesDiskImage = alert.suppressionButton?.state == .on

        if case .install = plan.action {
            do {
                // An older copy that was open may have an update waiting to install as it quits;
                // let that finish, and open it instead if it's now the same build or newer.
                if try quitInstalledCopy(at: destination) {
                    waitForPendingUpdate(home: home)
                }
                let installedBuild = FileManager.default.fileExists(atPath: destination.path)
                    ? ApplicationsMove.buildNumber(of: destination) : nil
                let ownBuild = ApplicationsMove.buildNumber(of: Bundle.main.bundleURL)
                if installedBuild == nil || BuildNumber(ownBuild).isNewer(than: BuildNumber(installedBuild ?? "")) {
                    try ApplicationsInstaller().install(plan.source, at: destination)
                }
            } catch Failure.installedCopyStillOpen {
                show("Quit the open Keybumps first", "The Keybumps that's already open didn't quit. Quit it, then open this copy again.")
                return
            } catch {
                show("Keybumps couldn't move itself", "Drag Keybumps into your Applications folder instead, then open it from there.")
                return
            }
        }

        let relaunch = ApplicationsMoveRelaunchPlan(
            open: destination,
            eject: plan.diskImage?.mountPoint,
            after: ProcessInfo.processInfo.processIdentifier
        )
        let helper = Process()
        helper.executableURL = relaunch.executableURL
        helper.arguments = relaunch.arguments
        do {
            try helper.run()
        } catch {
            // Nothing has gone to the Trash yet, so this copy can keep running.
            show("Keybumps is in your Applications folder", "Quit this copy, then open Keybumps from Applications.")
            return
        }
        // A mounted image's file can go to the Trash; the helper ejects it after we exit.
        if trashesDiskImage, let image = plan.diskImage?.imageFile {
            try? FileManager.default.trashItem(at: image, resultingItemURL: nil)
        }
        if case .install = plan.action, plan.trashesSource {
            try? FileManager.default.trashItem(at: plan.source, resultingItemURL: nil)
        }
        exit(0)
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Asks a copy running from `destination` to quit. Returns whether one was running.
    private static func quitInstalledCopy(at destination: URL) throws -> Bool {
        let installed = NSRunningApplication.runningApplications(withBundleIdentifier: ProductIdentity.bundleIdentifier)
            .filter { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
        guard !installed.isEmpty else { return false }
        installed.forEach { $0.terminate() }
        // It may ask its own question first (unsaved Screenshot Editor changes, Dictation).
        wait(seconds: 30) { installed.allSatisfy(\.isTerminated) }
        guard installed.allSatisfy(\.isTerminated) else { throw Failure.installedCopyStillOpen }
        return true
    }

    /// Sparkle stages a downloaded update here and clears it once installed.
    private static func waitForPendingUpdate(home: URL) {
        let staged = home.appendingPathComponent("Library/Caches/\(ProductIdentity.bundleIdentifier)/org.sparkle-project.Sparkle/Installation")
        let isEmpty = { ((try? FileManager.default.contentsOfDirectory(atPath: staged.path)) ?? []).isEmpty }
        guard !isEmpty() else { return }
        wait(seconds: 60, until: isEmpty)
    }

    private static func wait(seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
