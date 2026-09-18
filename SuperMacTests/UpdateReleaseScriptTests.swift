import Foundation
import XCTest
@testable import SuperMac

final class UpdateReleaseScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBuildProvenanceGuardAndBundleKeys() throws {
        let guardTest = repositoryRoot.appendingPathComponent("scripts/test-build-provenance.sh")
        let result = try run(guardTest, [])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("build provenance guard tests passed"))

        let infoData = try Data(contentsOf: repositoryRoot.appendingPathComponent("SuperMac/Resources/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(info["SuperMacSourceCommit"] as? String, "$(SUPERMAC_SOURCE_COMMIT)")
        XCTAssertEqual(info["SuperMacSourceBranch"] as? String, "$(SUPERMAC_SOURCE_BRANCH)")
        XCTAssertEqual(info["SuperMacBuildKind"] as? String, "$(SUPERMAC_BUILD_KIND)")
    }

    func testPublicationDryRunAndFailClosedInputs() throws {
        let fixture = repositoryRoot.appendingPathComponent("SuperMacTests/Fixtures/Updates")
        let verifier = repositoryRoot.appendingPathComponent("scripts/verify-update-publication.sh")
        let success = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.zip").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://127.0.0.1:18765/appcast.xml",
            "--dry-run"
        ])
        XCTAssertEqual(success.status, 0, success.output)
        XCTAssertTrue(success.output.contains("Phase 1"))
        XCTAssertTrue(success.output.contains("Phase 2"))

        let invalid = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.zip").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://example.com/appcast.xml",
            "--dry-run"
        ])
        XCTAssertNotEqual(invalid.status, 0)
    }

    func testFixtureServerAndLiveByteVerification() async throws {
        let fixture = repositoryRoot.appendingPathComponent("SuperMacTests/Fixtures/Updates")
        let server = Process()
        server.executableURL = repositoryRoot.appendingPathComponent("scripts/serve-update-fixture.sh")
        server.arguments = [fixture.path, "18765"]
        server.environment = cleanChildEnvironment
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
        }
        var becameReady = false
        for _ in 0..<30 {
            let health = try run(
                URL(fileURLWithPath: "/usr/bin/curl"),
                ["--fail", "--silent", "http://127.0.0.1:18765/appcast.xml"]
            )
            if health.status == 0 {
                becameReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !becameReady, !server.isRunning {
            XCTFail("Fixture server exited before becoming ready")
        }
        XCTAssertTrue(becameReady)

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServedUpdaterFixture-\(UUID().uuidString).bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.serp.supermac.served-fixture",
                "CFBundlePackageType": "BNDL",
                "SUPublicEDKey": "fixture-public-key"
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: bundleURL.path))
        let configuration = try XCTUnwrap(SparkleUpdateConfiguration.from(
            bundle: bundle,
            environment: ["SUPERMAC_UPDATE_FIXTURE_FEED_URL": "http://127.0.0.1:18765/appcast.xml"]
        ))
        let (servedFeed, response) = try await URLSession.shared.data(from: configuration.feedURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(XMLParser(data: servedFeed).parse(), "The served fixture must be parseable XML")

        let verifier = repositoryRoot.appendingPathComponent("scripts/verify-update-publication.sh")
        let verified = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.zip").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://127.0.0.1:18765/appcast.xml",
            "--verify-live"
        ])
        XCTAssertEqual(verified.status, 0, verified.output)

        let mismatched = try run(verifier, [
            fixture.appendingPathComponent("appcast.xml").path,
            fixture.appendingPathComponent("fixture.md").path,
            fixture.appendingPathComponent("fixture.md").path,
            "http://127.0.0.1:18765/appcast.xml",
            "--verify-live"
        ])
        XCTAssertNotEqual(mismatched.status, 0)
        XCTAssertTrue(mismatched.output.contains("archive bytes differ"))
    }

    func testReleaseValidationAndOrchestrationFailClosedBeforeArtifacts() throws {
        let validator = repositoryRoot.appendingPathComponent("scripts/validate-update-release.sh")
        let common = ["/tmp/missing.app", "/tmp/missing.zip", "/tmp/missing.xml", "/tmp/missing.md"]
        for maliciousFixtureURL in [
            "https://example.com/appcast.xml",
            "https://user:password@localhost/appcast.xml",
            "https://localhost/appcast.xml#fragment",
            "http://localhost:bad/appcast.xml",
            "http://local host/appcast.xml"
        ] {
            let result = try run(validator, common + [
                maliciousFixtureURL, maliciousFixtureURL, "1", "2", "0.0.2", "/tmp/tools", "fixture", "--skip-apple-trust-for-fixture"
            ])
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("loopback feeds only"))
        }

        let reusedBuild = try run(validator, common + [
            "https://updates.example.com/appcast.xml", "https://staging.example.com/appcast.xml", "2", "2", "0.0.2", "/tmp/tools", "production"
        ])
        XCTAssertNotEqual(reusedBuild.status, 0)
        XCTAssertTrue(reusedBuild.output.contains("greater than"))

        let orchestrator = repositoryRoot.appendingPathComponent("scripts/build-update-release.sh")
        let invalidBuild = try run(orchestrator, [
            "0.0.2", "2", "2", "https://updates.example.com/appcast.xml", "public", "notary", "key", "/tmp/tools", "/tmp/output"
        ])
        XCTAssertNotEqual(invalidBuild.status, 0)
        XCTAssertTrue(invalidBuild.output.contains("greater than"))

        for maliciousProductionURL in [
            "https:///appcast.xml",
            "https://user:password@example.com/appcast.xml",
            "https://example.com/appcast.xml#fragment",
            "https://example.com:99999/appcast.xml",
            "https://example .com/appcast.xml"
        ] {
            let result = try run(orchestrator, [
                "0.0.2", "2", "1", maliciousProductionURL, "public", "notary", "key", "/tmp/tools", "/tmp/output"
            ])
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("credential-free"))
        }

        let urlHelper = repositoryRoot.appendingPathComponent("scripts/lib/update_url_validation.py")
        let normalizedParent = try run(
            URL(fileURLWithPath: "/usr/bin/python3"),
            [urlHelper.path, "parent", "https://updates.example.com/beta/nested/appcast.xml"]
        )
        XCTAssertEqual(normalizedParent.status, 0, normalizedParent.output)
        XCTAssertEqual(normalizedParent.output.trimmingCharacters(in: .whitespacesAndNewlines), "https://updates.example.com/beta/nested/")
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = cleanChildEnvironment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private var cleanChildEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("XCTest")
        }
    }
}
