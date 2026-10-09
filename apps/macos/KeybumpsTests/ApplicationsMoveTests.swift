import Foundation
import Testing
@testable import Keybumps

@Suite("Move to Applications")
struct ApplicationsMoveTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    private let source = URL(fileURLWithPath: "/Volumes/Keybumps/Keybumps.app")
    private let destination = URL(fileURLWithPath: "/Applications/Keybumps.app")
    private let diskImage = DiskImage(
        mountPoint: URL(fileURLWithPath: "/Volumes/Keybumps"),
        imageFile: URL(fileURLWithPath: "/Users/example/Downloads/Keybumps-1.0.dmg")
    )

    @Test("Applications and ~/Applications count as installed; anywhere else is offered the move", arguments: [
        ("/Applications/Keybumps.app", true),
        ("/Applications/Utilities/Keybumps.app", true),
        ("/Users/example/Applications/Keybumps.app", true),
        ("/Volumes/Keybumps/Keybumps.app", false),
        ("/Users/example/Downloads/Keybumps.app", false),
        ("/private/var/folders/xy/T/AppTranslocation/1234/d/Keybumps.app", false),
        ("/ApplicationsOld/Keybumps.app", false),
    ])
    func classifiesLocations(_ path: String, _ installed: Bool) {
        #expect(ApplicationsMove.isInApplications(URL(fileURLWithPath: path), home: home) == installed)
    }

    @Test("The destination is always Keybumps.app: an installed copy first, then wherever this account can write")
    func choosesDestination() {
        let system = URL(fileURLWithPath: "/Applications/Keybumps.app")
        let user = URL(fileURLWithPath: "/Users/example/Applications/Keybumps.app")
        let userFolder = URL(fileURLWithPath: "/Users/example/Applications", isDirectory: true)
        func pick(existing: Set<String>, writable: Set<String>) -> URL? {
            ApplicationsMove.destination(
                home: home,
                exists: { existing.contains($0.standardizedFileURL.path) },
                canWrite: { writable.contains($0.standardizedFileURL.path) }
            )
        }
        #expect(pick(existing: [], writable: ["/Applications"]) == system)
        #expect(pick(existing: [user.path], writable: ["/Applications"]) == user, "Not a second copy beside it")
        #expect(pick(existing: [system.path, user.path], writable: []) == system)
        #expect(pick(existing: [], writable: [home.path]) == user, "An account that can't write /Applications")
        #expect(pick(existing: [userFolder.path], writable: [userFolder.path]) == user)
        #expect(pick(existing: [userFolder.path], writable: [home.path]) == nil)
        #expect(pick(existing: [], writable: []) == nil)
    }

    @Test("With no Keybumps installed, this copy is installed")
    func installsWhenAbsent() {
        #expect(makePlan(installedBuild: nil).action == .install(replacingOlder: false))
    }

    @Test("An older installed build is replaced; the same or a newer one is opened instead", arguments: [
        ("4027", ApplicationsMovePlan.Action.install(replacingOlder: true)),
        ("4027.999.9", .install(replacingOlder: true)),
        ("4028", .openInstalled),
        ("4028.430.1", .openInstalled),
        ("4029", .openInstalled),
    ])
    func comparesWithInstalledBuild(_ installed: String, _ action: ApplicationsMovePlan.Action) {
        #expect(makePlan(ownBuild: "4028", installedBuild: installed).action == action)
    }

    @Test("Nowhere to install, or an installed copy it can't replace, explains instead of failing")
    func cannotInstall() {
        #expect(makePlan(destination: nil, installedBuild: nil).action == .cannotInstall)
        #expect(makePlan(installedBuild: "4027", installedIsReplaceable: false).action == .cannotInstall)
        #expect(makePlan(installedBuild: "4029", installedIsReplaceable: false).action == .openInstalled)
    }

    @Test("Build numbers compare part by part as numbers")
    func buildNumbers() {
        #expect(BuildNumber("4028.430.10").isNewer(than: BuildNumber("4028.430.9")))
        #expect(BuildNumber("4028.1").isNewer(than: BuildNumber("4028")))
        #expect(!BuildNumber("4028.0").isNewer(than: BuildNumber("4028")))
        #expect(!BuildNumber("").isNewer(than: BuildNumber("1")))
    }

    @Test("A fresh install copies the bundle in and clears its quarantine")
    func installsFresh() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let source = try folder.makeApp("Source/Keybumps.app", build: "2", quarantined: true)
        let destination = folder.url.appendingPathComponent("Applications/Keybumps.app")
        let installer = ApplicationsInstaller(trash: { _ in Issue.record("Nothing to trash") })
        try installer.swap(try installer.stage(source, for: destination), into: destination)

        #expect(ApplicationsMove.buildNumber(of: destination) == "2")
        #expect(!folder.hasQuarantine(destination.appendingPathComponent("Contents/Info.plist")))
        #expect(FileManager.default.fileExists(atPath: source.path), "The source is the caller's to trash")
    }

    @Test("Staging leaves the installed copy alone until the swap, which sends the old one to the Trash")
    func replacesOlder() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let source = try folder.makeApp("Source/Keybumps.app", build: "2")
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        var trashed: [String] = []
        let installer = ApplicationsInstaller(trash: { url in
            trashed.append(ApplicationsMove.buildNumber(of: url))
            try FileManager.default.removeItem(at: url)
        })
        let staged = try installer.stage(source, for: destination)
        #expect(ApplicationsMove.buildNumber(of: destination) == "1")
        try installer.swap(staged, into: destination)

        #expect(ApplicationsMove.buildNumber(of: destination) == "2")
        #expect(trashed == ["1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Keybumps.app"])
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test("A failed copy stages nothing and leaves the installed one untouched")
    func failedCopyKeepsInstalled() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        let missing = folder.url.appendingPathComponent("Source/Keybumps.app")
        #expect(throws: (any Error).self) {
            _ = try ApplicationsInstaller(trash: { _ in Issue.record("Nothing to trash") }).stage(missing, for: destination)
        }
        #expect(ApplicationsMove.buildNumber(of: destination) == "1")
    }

    @Test("When the Trash refuses the old copy, it's kept beside the new one rather than deleted")
    func keepsOldCopyWhenTrashFails() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let source = try folder.makeApp("Source/Keybumps.app", build: "2")
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        let installer = ApplicationsInstaller(trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        try installer.swap(try installer.stage(source, for: destination), into: destination)

        #expect(ApplicationsMove.buildNumber(of: destination) == "2")
        #expect(ApplicationsMove.buildNumber(of: destination.deletingLastPathComponent().appendingPathComponent("Keybumps (previous).app")) == "1")
    }

    @Test("If the new copy can't move in and the old one can't go back, the old one is kept beside it, never deleted")
    func keepsOldCopyWhenRollbackFails() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let source = try folder.makeApp("Source/Keybumps.app", build: "2")
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        _ = try folder.makeApp("Applications/Keybumps (previous).app", build: "0")
        let files = RefusingFileManager(refusedDestination: destination)
        let installer = ApplicationsInstaller(files: files, trash: { _ in Issue.record("Nothing to trash") })
        let staged = try installer.stage(source, for: destination)
        #expect(throws: (any Error).self) { try installer.swap(staged, into: destination) }
        installer.discard(staged)

        let applications = destination.deletingLastPathComponent()
        #expect(ApplicationsMove.buildNumber(of: applications.appendingPathComponent("Keybumps (previous 2).app")) == "1")
        #expect(ApplicationsMove.buildNumber(of: applications.appendingPathComponent("Keybumps (previous).app")) == "0")
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test("If the old copy can't be kept anywhere, discarding the staged copy still leaves it in place")
    func discardNeverDeletesOldCopy() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let source = try folder.makeApp("Source/Keybumps.app", build: "2")
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        let files = RefusingFileManager(refusedFolder: destination.deletingLastPathComponent())
        let installer = ApplicationsInstaller(files: files, trash: { _ in Issue.record("Nothing to trash") })
        let staged = try installer.stage(source, for: destination)
        // Moving the old copy out goes into staging, which isn't refused; every move back into
        // Applications is.
        #expect(throws: (any Error).self) { try installer.swap(staged, into: destination) }
        installer.discard(staged)

        let staging = staged.deletingLastPathComponent()
        #expect(ApplicationsMove.buildNumber(of: staging.appendingPathComponent("Previous Keybumps.app")) == "1")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        try? FileManager.default.removeItem(at: staging)
    }

    @Test("Only Keybumps' own download counts as the disk image to eject and trash")
    func ownDiskImageOnly() {
        #expect(DiskImage.isKeybumpsDownload(URL(fileURLWithPath: "/Users/example/Downloads/Keybumps-0.0.3-beta.24.dmg")))
        #expect(DiskImage.isKeybumpsDownload(URL(fileURLWithPath: "/Users/example/Downloads/Keybumps-0.0.3-beta.24 (1).dmg")))
        #expect(!DiskImage.isKeybumpsDownload(URL(fileURLWithPath: "/Users/example/Work.dmg")))
        #expect(!DiskImage.isKeybumpsDownload(URL(fileURLWithPath: "/Users/example/KeybumpsBackups.dmg")))
        #expect(!DiskImage.isKeybumpsDownload(URL(fileURLWithPath: "/Users/example/Keybumps.sparseimage")))
    }

    @Test("The default Trash is inert under the unit-test host")
    func defaultTrashIsInert() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let app = try folder.makeApp("Keybumps.app", build: "1")
        #expect(throws: (any Error).self) { try ApplicationsInstaller().trash(app) }
        #expect(FileManager.default.fileExists(atPath: app.path))
    }

    @Test("Sparkle's installer counts as running only with its own pid line")
    func sparkleInstallerProcess() {
        #expect(SparkleInstaller.jobLabel == "com.serp.keybumps-sparkle-updater")
        #expect(SparkleInstaller.hasProcess(launchctlPrint: "gui/501/com.serp.keybumps-sparkle-updater = {\n\tstate = running\n\tpid = 4242\n}"))
        #expect(!SparkleInstaller.hasProcess(launchctlPrint: "gui/501/com.serp.keybumps-sparkle-updater = {\n\tstate = not running\n\tendpoints = {\n\t\tpid = 1\n\t}\n}"))
        #expect(!SparkleInstaller.hasProcess(launchctlPrint: ""))
    }

    @Test("Install: stage, quit the old copy, wait for Sparkle, swap, start the helper, then trash")
    func installSteps() {
        let log = StepLog()
        let steps = recordingSteps(log, installed: "4027")
        let plan = makePlan(installedBuild: "4027", diskImage: diskImage, trashesSource: false)
        #expect(steps.perform(plan, ownBuild: "4028", trashesDiskImage: true) == .relaunching)
        #expect(log.entries == ["stage", "quit", "wait", "build", "swap", "helper /Volumes/Keybumps", "trash Keybumps-1.0.dmg"])
    }

    @Test("If Sparkle installed the same build or newer meanwhile, it opens that copy instead of swapping")
    func sparkleInstalledMeanwhile() {
        let log = StepLog()
        let steps = recordingSteps(log, installed: "4028")
        #expect(steps.perform(makePlan(installedBuild: "4027", trashesSource: true), ownBuild: "4028", trashesDiskImage: false) == .relaunching)
        #expect(log.entries == ["stage", "quit", "wait", "build", "discard", "helper -", "trash Keybumps.app"])
    }

    @Test("A copy that won't quit stops before anything is swapped or trashed")
    func stillOpen() {
        let log = StepLog()
        let steps = recordingSteps(log, installed: "4027", quitFails: true)
        #expect(steps.perform(makePlan(installedBuild: "4027", diskImage: diskImage), ownBuild: "4028", trashesDiskImage: true) == .installedCopyStillOpen)
        #expect(log.entries == ["stage", "quit", "discard"])
    }

    @Test("A failed copy stops before the old copy is asked to quit")
    func stageFailsFirst() {
        let log = StepLog()
        let steps = recordingSteps(log, installed: "4027", stageFails: true)
        #expect(steps.perform(makePlan(installedBuild: "4027"), ownBuild: "4028", trashesDiskImage: true) == .failed)
        #expect(log.entries == ["stage"])
    }

    @Test("If the helper can't start, nothing goes to the Trash")
    func helperFailsKeepsEverything() {
        let log = StepLog()
        let steps = recordingSteps(log, installed: nil, helperFails: true)
        #expect(steps.perform(makePlan(installedBuild: nil, diskImage: diskImage, trashesSource: true), ownBuild: "4028", trashesDiskImage: true) == .helperFailed)
        #expect(!log.entries.contains { $0.hasPrefix("trash") })
    }

    @Test("Opening the installed copy skips installing, but still ejects and trashes the disk image")
    func openInstalledSteps() {
        let log = StepLog()
        let steps = recordingSteps(log, installed: "4029")
        #expect(steps.perform(makePlan(installedBuild: "4029", diskImage: diskImage, trashesSource: true), ownBuild: "4028", trashesDiskImage: true) == .relaunching)
        #expect(log.entries == ["helper /Volumes/Keybumps", "trash Keybumps-1.0.dmg"])
    }

    @Test("The disk image comes from hdiutil's mount table")
    func parsesHdiutilInfo() throws {
        let info: [String: Any] = ["images": [
            ["image-path": "/Users/example/Downloads/Other.dmg",
             "system-entities": [["dev-entry": "/dev/disk9"], ["mount-point": "/Volumes/Other"]]],
            ["image-path": "/Users/example/Downloads/Keybumps-1.0.dmg",
             "system-entities": [["dev-entry": "/dev/disk10"], ["mount-point": "/Volumes/Keybumps"]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        #expect(DiskImage.parse(hdiutilInfo: data, volume: URL(fileURLWithPath: "/Volumes/Keybumps")) == diskImage)
        #expect(DiskImage.parse(hdiutilInfo: data, volume: URL(fileURLWithPath: "/")) == nil)
        #expect(DiskImage.parse(hdiutilInfo: Data("not a plist".utf8), volume: URL(fileURLWithPath: "/Volumes/Keybumps")) == nil)
    }

    @Test("An app that isn't translocated keeps its own location")
    func untranslocatedURL() throws {
        let folder = try ApplicationsMoveFolder()
        defer { folder.remove() }
        let app = try folder.makeApp("Keybumps.app", build: "1")
        #expect(AppTranslocation.originalURL(for: app) == app)
    }

    @Test("The helper waits for this process, opens the installed copy, then ejects with retries; paths stay arguments")
    func relaunchPlan() throws {
        let plan = ApplicationsMoveRelaunchPlan(open: destination, eject: diskImage.mountPoint, after: 42)
        #expect(plan.executableURL.path == "/bin/sh")
        #expect(Array(plan.arguments.suffix(4)) == ["keybumps-move", "42", "/Applications/Keybumps.app", "/Volumes/Keybumps"])
        let script = plan.arguments[1]
        #expect(!script.contains("/Applications/Keybumps.app") && !script.contains("/Volumes/Keybumps"))
        let open = try #require(script.range(of: "/usr/bin/open \"$2\""))
        let eject = try #require(script.range(of: "hdiutil detach \"$3\""))
        #expect(open.lowerBound < eject.lowerBound)
        #expect(script.contains("for attempt in 1 2 3 4 5"))
        #expect(ApplicationsMoveRelaunchPlan(open: destination, eject: nil, after: 42).arguments.last == "")
    }

    private func makePlan(
        destination: URL? = URL(fileURLWithPath: "/Applications/Keybumps.app"),
        ownBuild: String = "4028",
        installedBuild: String?,
        installedIsReplaceable: Bool = true,
        diskImage: DiskImage? = nil,
        trashesSource: Bool = false
    ) -> ApplicationsMovePlan {
        ApplicationsMovePlan(
            source: source,
            destination: destination,
            ownBuild: ownBuild,
            installedBuild: installedBuild,
            installedIsReplaceable: installedIsReplaceable,
            diskImage: diskImage,
            trashesSource: trashesSource
        )
    }

    /// Steps that only record what they were asked to do, in order.
    private func recordingSteps(
        _ log: StepLog,
        installed: String?,
        stageFails: Bool = false,
        quitFails: Bool = false,
        helperFails: Bool = false
    ) -> ApplicationsMoveSteps {
        let staged = URL(fileURLWithPath: "/tmp/staging/Keybumps.app")
        return ApplicationsMoveSteps(
            stage: { _, _ in
                log.entries.append("stage")
                if stageFails { throw CocoaError(.fileReadNoSuchFile) }
                return staged
            },
            discard: { _ in log.entries.append("discard") },
            quitInstalledCopy: { _ in
                log.entries.append("quit")
                if quitFails { throw ApplicationsMoveSteps.StillOpen() }
            },
            waitForSparkle: { log.entries.append("wait") },
            installedBuild: { _ in log.entries.append("build"); return installed },
            swap: { _, _ in log.entries.append("swap") },
            startHelper: { _, mountPoint in
                log.entries.append("helper \(mountPoint?.path ?? "-")")
                if helperFails { throw CocoaError(.executableNotLoadable) }
            },
            trash: { log.entries.append("trash \($0.lastPathComponent)") }
        )
    }
}

/// Refuses every move onto one path, or into one folder, as when it can't be written at that moment.
private final class RefusingFileManager: FileManager {
    private let refuses: (URL) -> Bool

    init(refusedDestination: URL) {
        let path = refusedDestination.standardizedFileURL.path
        refuses = { $0.standardizedFileURL.path == path }
        super.init()
    }

    init(refusedFolder: URL) {
        let path = refusedFolder.standardizedFileURL.path
        refuses = { $0.deletingLastPathComponent().standardizedFileURL.path == path }
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if refuses(dstURL) { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

/// What `ApplicationsMoveSteps` was asked to do, in order.
private final class StepLog {
    var entries: [String] = []
}

/// A folder under the test's temporary directory; each test removes it with `defer`.
private final class ApplicationsMoveFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationsMoveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    /// A minimal bundle with a `CFBundleVersion`, optionally carrying a quarantine flag.
    func makeApp(_ path: String, build: String, quarantined: Bool = false) throws -> URL {
        let app = url.appendingPathComponent(path)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": build, "CFBundleIdentifier": "test.keybumps"], format: .xml, options: 0)
        let plist = contents.appendingPathComponent("Info.plist")
        try info.write(to: plist)
        if quarantined {
            let value = Array("0081;00000000;Test;".utf8)
            setxattr(plist.path, "com.apple.quarantine", value, value.count, 0, XATTR_NOFOLLOW)
        }
        return app
    }

    func hasQuarantine(_ file: URL) -> Bool {
        getxattr(file.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
