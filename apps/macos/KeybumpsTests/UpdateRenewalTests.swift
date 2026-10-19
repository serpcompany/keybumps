import Foundation
import Sparkle
import Testing
@testable import Keybumps

/// ADR 0011: a version released after the license's update year shows, with Renew, and never installs.
@Suite("Update year filter")
struct UpdateYearFilterTests {
    private let year = UpdateYear(lastDay: UpdateYear.day("2027-11-05")!)

    private func candidate(_ build: String, _ released: String?, runsHere: Bool = true) -> UpdateCandidate {
        UpdateCandidate(version: build, displayVersion: "v\(build)", releaseDate: released.flatMap(PolarDates.parse), runsHere: runsHere)
    }

    @Test("Without an update year, or with nothing it leaves out, Sparkle picks as before")
    func sparklePicks() {
        #expect(UpdateYearFilter.choose([candidate("5000", "2027-12-01T00:00:00Z")], hostVersion: "4032", updateYear: nil) == .init(pick: .sparkle))
        let covered = [candidate("5000", "2027-11-05T22:00:00Z"), candidate("4040", nil)]
        #expect(UpdateYearFilter.choose(covered, hostVersion: "4032", updateYear: year) == .init(pick: .sparkle))
    }

    @Test("A newer version released after the update year is shown for renewal, never installed")
    func renewalOnly() {
        let choice = UpdateYearFilter.choose([candidate("5000", "2027-11-06T00:00:00Z")], hostVersion: "4032", updateYear: year)
        #expect(choice == .init(pick: .nothing, renewalVersion: "v5000"))
    }

    @Test("The newest covered version still installs beside ones that need a renewal")
    func coveredBesideRenewal() {
        let items = [candidate("4040", "2027-10-01T00:00:00Z"), candidate("5000", "2027-12-01T00:00:00Z"), candidate("5100", "2028-01-01T00:00:00Z")]
        #expect(UpdateYearFilter.choose(items, hostVersion: "4032", updateYear: year) == .init(pick: .candidate(0), renewalVersion: "v5100"))
        #expect(UpdateYearFilter.choose(items, hostVersion: "4040", updateYear: year) == .init(pick: .nothing, renewalVersion: "v5100"))
    }

    @Test("A version this Mac can't run, or one no newer than it, never asks for a renewal")
    func notOffered() {
        let tooNew = [candidate("5000", "2027-12-01T00:00:00Z", runsHere: false)]
        #expect(UpdateYearFilter.choose(tooNew, hostVersion: "4032", updateYear: year) == .init(pick: .sparkle))
        // A newer build installed by hand is the appcast's own release.
        #expect(UpdateYearFilter.choose([candidate("5000", "2027-12-01T00:00:00Z")], hostVersion: "5000", updateYear: year) == .init(pick: .sparkle))
    }

    @Test("Check for Updates… is quiet only once the update year has ended")
    func quietCheck() {
        #expect(!UpdateYearFilter.checksQuietly(updateYear: nil, now: .now))
        #expect(!UpdateYearFilter.checksQuietly(updateYear: year, now: PolarDates.parse("2027-11-05T23:00:00Z")!))
        #expect(UpdateYearFilter.checksQuietly(updateYear: year, now: PolarDates.parse("2027-11-06T00:00:00Z")!))
    }
}

@MainActor
@Suite("Update renewal state")
struct UpdateRenewalStateTests {
    private func controller(preview: String? = nil) -> SparkleUpdateController {
        SparkleUpdateController(
            configuration: SparkleUpdateConfiguration(feedURL: URL(string: "https://updates.keybumps.app/appcast.xml")!, publicKey: "test"),
            safetyPolicy: UpdateInstallationSafetyPolicy(),
            previewRenewalVersion: preview
        )
    }

    /// An appcast item as Sparkle parses one, `<keybumps:releaseDate>` included.
    private func item(build: String, version: String, released: String?) throws -> SUAppcastItem {
        var properties: [String: Any] = [
            "sparkle:version": build,
            "sparkle:shortVersionString": version,
            "enclosure": ["url": "https://updates.keybumps.app/releases/\(build)/Keybumps-\(version).zip", "length": "1"],
        ]
        properties[UpdateCandidate.releaseDateKey] = released
        return try #require(SUAppcastItem(dictionary: properties))
    }

    @Test("A version that needs a renewal keeps the dot through checks and failures, until a check finds nothing newer or one to install")
    func renewalPersists() {
        var snapshot = UpdateSnapshot(status: .idle, automaticallyChecks: true, canCheck: true, canRestart: false)
        snapshot.setStatus(.renewalRequired(version: "0.0.4"))
        #expect(snapshot.renewalVersion == "0.0.4")
        #expect(snapshot.newerVersion == nil, "Nothing to install")
        #expect(MenuBarAttention.updateIsWaiting(snapshot))
        #expect(MenuBarAttention.updatePhrase(snapshot) == "update available with a renewal")

        snapshot.setStatus(.checking)
        snapshot.setStatus(.failed("The update check failed. Try again."))
        #expect(snapshot.renewalVersion == "0.0.4")
        #expect(snapshot.waitingSummary == "Version 0.0.4 is available with a renewal")

        snapshot.setStatus(.available(version: "0.0.4"))
        #expect(snapshot.renewalVersion == nil, "A renewal covers it now")
        snapshot.setStatus(.renewalRequired(version: "0.0.5"))
        snapshot.setStatus(.current)
        #expect(snapshot.renewalVersion == nil)
        #expect(!MenuBarAttention.updateIsWaiting(snapshot))
    }

    @Test("Sparkle reads the appcast's release date; a version after the update year is left out and shown for renewal")
    func appcastItems() throws {
        let updater = controller()
        let covered = try item(build: "4040", version: "0.0.4", released: "2027-10-01T00:00:00Z")
        let after = try item(build: "5000", version: "0.0.5", released: "2027-12-01T00:00:00Z")
        #expect(UpdateCandidate(item: after).releaseDate == PolarDates.parse("2027-12-01T00:00:00Z"))
        #expect(UpdateCandidate(item: try item(build: "4033", version: "0.0.3", released: nil)).releaseDate == nil)

        #expect(updater.choose([covered, after], hostVersion: "4032") == nil, "No update year yet: Sparkle picks")
        updater.setUpdateYear(UpdateYear(lastDay: UpdateYear.day("2027-11-05")!))
        #expect(updater.choose([covered, after], hostVersion: "4032") === covered)
        #expect(updater.choose([after], hostVersion: "4032") === SUAppcastItem.empty())
        #expect(updater.pendingRenewalVersion == "0.0.5")

        // Sparkle then reports that nothing installs, through two callbacks.
        updater.noUpdateFound(reasonCode: 1)
        updater.noUpdateFound(reasonCode: 1)
        #expect(updater.snapshot.status == .renewalRequired(version: "0.0.5"))
        #expect(updater.snapshot.renewalVersion == "0.0.5")
        #expect(MenuBarAttention.updateIsWaiting(updater.snapshot))
    }

    @Test("A QA candidate's renewal preview ends every check with a renewal")
    func preview() {
        let defaults = InMemoryDefaults()
        #expect(UpdatePreview.renewalVersion(version: "0.0.3-dev.issue548", isDebugBuild: false, defaults: defaults) == nil, "Not asked")
        defaults.set(true, forKey: "KBPreviewRenewal")
        #expect(UpdatePreview.renewalVersion(version: "0.0.3-dev.issue548", isDebugBuild: false, defaults: defaults) == "9.9.9 (preview)")
        #expect(UpdatePreview.renewalVersion(version: "0.0.3-beta.27", isDebugBuild: false, defaults: defaults) == nil, "Releases never preview")

        let updater = controller(preview: "9.9.9 (preview)")
        updater.noUpdateFound(reasonCode: 1)
        #expect(updater.snapshot.renewalVersion == "9.9.9 (preview)")
    }

    @Test("While no license is active, the updater keeps filtering by the last update year this Mac learned")
    func rememberedUpdateYear() async {
        let defaults = InMemoryDefaults()
        let year = UpdateYear(lastDay: UpdateYear.day("2027-11-05")!)
        func makeModel(updater: FakeUpdateController, licensing: FixedLicenseController) -> AppModel {
            AppModel(
                preferences: AppPreferences(defaults: defaults),
                inbox: InboxStore(persistence: UpdaterTestEventPersistence()),
                presenceController: UpdaterTestPresenceController(),
                detector: ManualActionDetector(monitor: UpdaterTestPointerMonitor(), permissions: UpdaterTestPermissions()),
                updater: updater,
                licensing: licensing
            )
        }
        let updater = FakeUpdateController()
        let model = makeModel(updater: updater, licensing: FixedLicenseController(updateYear: year))
        #expect(updater.updateYears.last == year)

        await model.deactivateLicense()
        #expect(model.licenseSnapshot.updateYear == nil)
        #expect(updater.updateYears.last == year, "Deactivating keeps the filter")

        let relaunched = FakeUpdateController()
        _ = makeModel(updater: relaunched, licensing: FixedLicenseController(state: .unlicensed))
        #expect(relaunched.updateYears.last == year, "So does relaunching with no license")
    }

    @Test("Settings › Changelog says when the updates ended")
    func renewalNote() {
        let note = ChangelogSettingsView.renewalNote(version: "0.0.5", updateYear: UpdateYear(lastDay: UpdateYear.day("2027-11-05")!))
        #expect(note.hasPrefix("Version 0.0.5 came out after your license’s updates ended on "))
        #expect(note.hasSuffix("The version you have keeps working either way."))
        #expect(ChangelogSettingsView.renewalNote(version: "0.0.5", updateYear: nil).contains("updates have ended."))
    }
}
