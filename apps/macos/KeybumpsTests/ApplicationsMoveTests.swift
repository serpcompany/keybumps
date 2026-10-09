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

    @Test("With no Keybumps in Applications, this copy is installed")
    func installsWhenAbsent() {
        let plan = makePlan(installedBuild: nil)
        #expect(plan.action == .install(replacingOlder: false))
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

    @Test("Without write access to Applications, it explains instead of failing")
    func cannotInstall() {
        #expect(makePlan(installedBuild: nil, canWriteApplications: false).action == .cannotInstall)
        #expect(makePlan(installedBuild: "4029", canWriteApplications: false).action == .openInstalled)
    }

    @Test("A copy in Downloads goes to the Trash after copying; a disk image's copy stays")
    func trashesOnlyWritableSources() {
        #expect(makePlan(installedBuild: nil, diskImage: nil, canRemoveSource: true).trashesSource)
        #expect(!makePlan(installedBuild: nil, diskImage: nil, canRemoveSource: false).trashesSource)
        #expect(!makePlan(installedBuild: nil, diskImage: diskImage, canRemoveSource: true).trashesSource)
    }

    @Test("Build numbers compare part by part as numbers")
    func buildNumbers() {
        #expect(BuildNumber("4028.430.10").isNewer(than: BuildNumber("4028.430.9")))
        #expect(BuildNumber("4028.1").isNewer(than: BuildNumber("4028")))
        #expect(!BuildNumber("4028.0").isNewer(than: BuildNumber("4028")))
        #expect(!BuildNumber("").isNewer(than: BuildNumber("1")))
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
    func untranslocatedURL() {
        #expect(AppTranslocation.originalURL(for: source) == source)
    }

    @Test("The helper waits for this process, opens Applications' copy, then ejects; paths stay arguments")
    func relaunchPlan() {
        let plan = ApplicationsMoveRelaunchPlan(open: destination, eject: diskImage.mountPoint, after: 42)
        #expect(plan.executableURL.path == "/bin/sh")
        #expect(Array(plan.arguments.suffix(4)) == ["keybumps-move", "42", "/Applications/Keybumps.app", "/Volumes/Keybumps"])
        let script = plan.arguments[1]
        #expect(!script.contains("/Applications/Keybumps.app") && !script.contains("/Volumes/Keybumps"))
        let open = try? #require(script.range(of: "/usr/bin/open \"$2\""))
        let eject = try? #require(script.range(of: "hdiutil detach \"$3\""))
        if let open, let eject { #expect(open.lowerBound < eject.lowerBound) }
        #expect(ApplicationsMoveRelaunchPlan(open: destination, eject: nil, after: 42).arguments.last == "")
    }

    private func makePlan(
        ownBuild: String = "4028",
        installedBuild: String?,
        diskImage: DiskImage? = nil,
        canWriteApplications: Bool = true,
        canRemoveSource: Bool = true
    ) -> ApplicationsMovePlan {
        ApplicationsMovePlan(
            source: source,
            destination: destination,
            ownBuild: ownBuild,
            installedBuild: installedBuild,
            diskImage: diskImage,
            canWriteApplications: canWriteApplications,
            canRemoveSource: canRemoveSource
        )
    }
}
