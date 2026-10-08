import Foundation
import Testing
@testable import Keybumps

@Suite("Settings › Changelog")
struct ChangelogTests {
    @Test("Versions sort as releases do: numbers by value, prereleases below their release, candidates as their release")
    func releaseVersionOrder() throws {
        let ordered = ["0.0.2", "0.0.3-beta.2", "0.0.3-beta.12", "0.0.3-rc.1", "0.0.3", "0.1.0"]
        let versions = try ordered.map { try #require(ReleaseVersion($0)) }
        #expect(versions == versions.sorted())
        #expect(versions.shuffled().sorted().map(\.description) == ordered)

        // build-qa-candidate.sh's format: the marketing version, then -dev.issue<N>.
        let candidate = try #require(ReleaseVersion("0.0.3-dev.issue416"))
        #expect(candidate.description == "0.0.3")
        #expect(candidate == ReleaseVersion("0.0.3"))
        #expect(ReleaseVersion("beta") == nil)
        #expect(ReleaseVersion("") == nil)
    }

    @Test("The notes list newest first, up to the installed version, and skip files that aren't release notes")
    func entriesNewestFirstUpToInstalled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for version in ["0.0.3-beta.2", "0.0.3-beta.12", "0.0.3-beta.3", "0.0.3-beta.13"] {
            try "# Keybumps \(version)\n\nSummary.\n\n- A change.\n".write(
                to: directory.appendingPathComponent("v\(version).md"), atomically: true, encoding: .utf8
            )
        }
        try "Not notes".write(to: directory.appendingPathComponent("operations.md"), atomically: true, encoding: .utf8)
        try "Not notes".write(to: directory.appendingPathComponent("v0.0.3-beta.4.txt"), atomically: true, encoding: .utf8)

        let all = Changelog.entries(in: directory, upTo: nil)
        #expect(all.map(\.version) == ["0.0.3-beta.13", "0.0.3-beta.12", "0.0.3-beta.3", "0.0.3-beta.2"])
        #expect(all.first?.notes.blocks == [.title("Keybumps 0.0.3-beta.13"), .paragraph("Summary."), .bullet("A change.")])

        let installed = Changelog.entries(in: directory, upTo: ReleaseVersion("0.0.3-beta.12"))
        #expect(installed.map(\.version) == ["0.0.3-beta.12", "0.0.3-beta.3", "0.0.3-beta.2"])
        let candidate = Changelog.entries(in: directory, upTo: ReleaseVersion("0.0.3-dev.issue416"))
        #expect(candidate.map(\.version) == all.map(\.version), "A candidate lists every beta of its version")

        #expect(Changelog.entries(in: directory.appendingPathComponent("missing"), upTo: nil).isEmpty)
    }

    @Test("The app carries every release's notes, so the page works offline")
    func appCarriesReleaseNotes() {
        let entries = Changelog.entries(in: .main, isDebugBuild: true)
        #expect(entries.contains { $0.version == "0.0.3-beta.1" })
        #expect(entries.map(\.version).first != "0.0.3-beta.1", "Newest first")
    }
}
