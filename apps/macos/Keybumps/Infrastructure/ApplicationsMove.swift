import AppKit

/// Offers to move Keybumps into Applications when it opens from anywhere else: the disk image,
/// Downloads, or the read-only copy macOS runs a quarantined app from (App Translocation). Run
/// from there, Sparkle can't install updates and permissions attach to a copy that goes away
/// (#437). It runs before launch finishes, so nothing has started yet if Keybumps moves.
enum ApplicationsMove {
    static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Whether `appURL` is already somewhere Keybumps belongs: `/Applications` or the person's
    /// own `~/Applications`, including folders inside them.
    static func isInApplications(_ appURL: URL, home: URL) -> Bool {
        let path = appURL.standardizedFileURL.path
        return [applicationsFolder, home.appendingPathComponent("Applications", isDirectory: true)]
            .contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Release builds only: Debug builds and their test hosts run from DerivedData on purpose.
    @MainActor
    static func offerIfNeeded() {
        #if !DEBUG
        guard KeybumpsMain.launchedApp else { return }
        let running = Bundle.main.bundleURL
        guard !isInApplications(running, home: FileManager.default.homeDirectoryForCurrentUser) else { return }
        let source = AppTranslocation.originalURL(for: running)
        guard !isInApplications(source, home: FileManager.default.homeDirectoryForCurrentUser) else { return }
        let plan = ApplicationsMovePlan(
            source: source,
            destination: applicationsFolder.appendingPathComponent(running.lastPathComponent),
            ownBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            installedBuild: Bundle(url: applicationsFolder.appendingPathComponent(running.lastPathComponent))?
                .object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            diskImage: DiskImage.containing(source),
            canWriteApplications: FileManager.default.isWritableFile(atPath: applicationsFolder.path),
            canRemoveSource: FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path)
        )
        ApplicationsMovePrompt.run(plan)
        #endif
    }
}

/// What to do with this copy, decided from where it is and what's already installed.
struct ApplicationsMovePlan: Equatable {
    enum Action: Equatable {
        /// Applications has no Keybumps, or an older one: put this copy there.
        case install(replacingOlder: Bool)
        /// Applications already has this build or a newer one: open that instead.
        case openInstalled
        /// This account can't add apps to Applications.
        case cannotInstall
    }

    let source: URL
    let destination: URL
    let action: Action
    let diskImage: DiskImage?
    /// From Downloads or the Desktop, the original goes to the Trash once it's copied; on a disk
    /// image it stays, since the image is read-only and goes to the Trash or is ejected afterwards.
    let trashesSource: Bool

    init(
        source: URL,
        destination: URL,
        ownBuild: String,
        installedBuild: String?,
        diskImage: DiskImage?,
        canWriteApplications: Bool,
        canRemoveSource: Bool
    ) {
        self.source = source
        self.destination = destination
        self.diskImage = diskImage
        trashesSource = diskImage == nil && canRemoveSource
        if let installedBuild, !BuildNumber(ownBuild).isNewer(than: BuildNumber(installedBuild)) {
            action = .openInstalled
        } else if !canWriteApplications {
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
    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> Bool
    private typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?

    static func originalURL(for url: URL) -> URL {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return url }
        defer { dlclose(security) }
        guard let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let isTranslocated = unsafeBitCast(isSymbol, to: IsTranslocated.self)
        let createOriginal = unsafeBitCast(originalSymbol, to: CreateOriginal.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let original = createOriginal(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return original as URL
    }
}

/// After this process exits: open the copy in Applications, then eject the disk image this one
/// came from. Paths go in as arguments, never into the script text.
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
        [ -n "$3" ] && /usr/bin/hdiutil detach "$3" -quiet
        exit 0
        """
        arguments = ["-c", script, "keybumps-move", String(processIdentifier), app.path, mountPoint?.path ?? ""]
    }
}

@MainActor
enum ApplicationsMovePrompt {
    static func run(_ plan: ApplicationsMovePlan) {
        let app = NSApplication.shared
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSImage(named: NSImage.applicationIconName)
        switch plan.action {
        case .install(let replacingOlder):
            alert.messageText = "Move Keybumps to your Applications folder?"
            alert.informativeText = "Keybumps needs to run from Applications to install updates and keep the permissions you give it."
                + (replacingOlder ? " This replaces the older Keybumps there." : "")
            alert.addButton(withTitle: "Move to Applications")
        case .openInstalled:
            alert.messageText = "Keybumps is already in your Applications folder"
            alert.informativeText = "Open that copy instead. It's the one that installs updates and keeps your permissions."
            alert.addButton(withTitle: "Open Keybumps")
        case .cannotInstall:
            alert.messageText = "Drag Keybumps into your Applications folder"
            alert.informativeText = "This Mac account can't add apps to Applications. Ask an administrator to drag Keybumps there, then open it from Applications."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.addButton(withTitle: "Not Now")
        if plan.diskImage != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Move the downloaded disk image to the Trash"
            alert.suppressionButton?.state = .on
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trashesDiskImage = alert.suppressionButton?.state == .on

        do {
            if case .install = plan.action {
                try install(plan)
            }
            if trashesDiskImage, let image = plan.diskImage?.imageFile {
                // A mounted image's file can go to the Trash; the helper ejects it after we exit.
                try? FileManager.default.trashItem(at: image, resultingItemURL: nil)
            }
            let relaunch = ApplicationsMoveRelaunchPlan(
                open: plan.destination,
                eject: plan.diskImage?.mountPoint,
                after: ProcessInfo.processInfo.processIdentifier
            )
            let helper = Process()
            helper.executableURL = relaunch.executableURL
            helper.arguments = relaunch.arguments
            try helper.run()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Keybumps couldn't move itself"
            failure.informativeText = "Drag Keybumps into your Applications folder instead, then open it from there."
            failure.runModal()
            return
        }
        exit(0)
    }

    private static func install(_ plan: ApplicationsMovePlan) throws {
        try quitInstalledCopy(at: plan.destination)
        let files = FileManager.default
        if files.fileExists(atPath: plan.destination.path) {
            try files.trashItem(at: plan.destination, resultingItemURL: nil)
        }
        // Copy rather than move: a translocated copy is still running from the original.
        try files.copyItem(at: plan.source, to: plan.destination)
        // The person already chose to open this copy, so the one in Applications opens without
        // asking again.
        removeQuarantine(under: plan.destination)
        if plan.trashesSource {
            try? files.trashItem(at: plan.source, resultingItemURL: nil)
        }
    }

    /// An older Keybumps already running from Applications quits before it's replaced.
    private static func quitInstalledCopy(at destination: URL) throws {
        let installed = NSRunningApplication.runningApplications(withBundleIdentifier: ProductIdentity.bundleIdentifier)
            .filter { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
        guard !installed.isEmpty else { return }
        installed.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while installed.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if installed.contains(where: { !$0.isTerminated }) {
            throw CocoaError(.fileWriteFileExists)
        }
    }

    private static func removeQuarantine(under root: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(root.path, attribute, XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            removexattr(item.path, attribute, XATTR_NOFOLLOW)
        }
    }
}
