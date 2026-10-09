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
        let source = try folder.makeApp("Source/Keybumps.app", build: "2", quarantined: true)
        let destination = folder.url.appendingPathComponent("Applications/Keybumps.app")
        var trashed: [URL] = []
        try ApplicationsInstaller(trash: { trashed.append($0) }).install(source, at: destination)

        #expect(ApplicationsMove.buildNumber(of: destination) == "2")
        #expect(!folder.hasQuarantine(destination.appendingPathComponent("Contents/Info.plist")))
        #expect(FileManager.default.fileExists(atPath: source.path), "The source is the caller's to trash")
        #expect(trashed.isEmpty)
    }

    @Test("Replacing swaps the new copy in and sends the old one to the Trash")
    func replacesOlder() throws {
        let folder = try ApplicationsMoveFolder()
        let source = try folder.makeApp("Source/Keybumps.app", build: "2")
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        var trashed: [String] = []
        try ApplicationsInstaller(trash: { url in
            trashed.append(ApplicationsMove.buildNumber(of: url))
            try FileManager.default.removeItem(at: url)
        }).install(source, at: destination)

        #expect(ApplicationsMove.buildNumber(of: destination) == "2")
        #expect(trashed == ["1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Keybumps.app"])
    }

    @Test("A failed copy leaves the installed one untouched")
    func failedCopyKeepsInstalled() throws {
        let folder = try ApplicationsMoveFolder()
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        let missing = folder.url.appendingPathComponent("Source/Keybumps.app")
        #expect(throws: (any Error).self) {
            try ApplicationsInstaller(trash: { _ in Issue.record("Nothing to trash") }).install(missing, at: destination)
        }
        #expect(ApplicationsMove.buildNumber(of: destination) == "1")
    }

    @Test("When the Trash refuses the old copy, it's kept rather than deleted")
    func keepsOldCopyWhenTrashFails() throws {
        let folder = try ApplicationsMoveFolder()
        let source = try folder.makeApp("Source/Keybumps.app", build: "2")
        let destination = try folder.makeApp("Applications/Keybumps.app", build: "1")
        var refused: URL?
        try ApplicationsInstaller(trash: { refused = $0; throw CocoaError(.fileWriteNoPermission) }).install(source, at: destination)

        #expect(ApplicationsMove.buildNumber(of: destination) == "2")
        let kept = try #require(refused)
        #expect(ApplicationsMove.buildNumber(of: kept) == "1")
        try? FileManager.default.removeItem(at: kept.deletingLastPathComponent())
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
        installedIsReplaceable: Bool = true
    ) -> ApplicationsMovePlan {
        ApplicationsMovePlan(
            source: source,
            destination: destination,
            ownBuild: ownBuild,
            installedBuild: installedBuild,
            installedIsReplaceable: installedIsReplaceable,
            diskImage: nil,
            trashesSource: false
        )
    }
}

/// A folder under the test's temporary directory, removed when it goes out of scope.
private final class ApplicationsMoveFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationsMoveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

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
