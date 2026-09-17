import Foundation
import XCTest

final class UpdateReleaseScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    func testFixtureServerAndLiveByteVerification() throws {
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
        let arbitraryHTTPSFixture = try run(validator, common + [
            "https://example.com/appcast.xml", "1", "2", "0.0.2", "/tmp/tools", "fixture", "--skip-apple-trust-for-fixture"
        ])
        XCTAssertNotEqual(arbitraryHTTPSFixture.status, 0)
        XCTAssertTrue(arbitraryHTTPSFixture.output.contains("loopback feeds only"))

        let reusedBuild = try run(validator, common + [
            "https://updates.example.com/appcast.xml", "2", "2", "0.0.2", "/tmp/tools", "production"
        ])
        XCTAssertNotEqual(reusedBuild.status, 0)
        XCTAssertTrue(reusedBuild.output.contains("greater than"))

        let orchestrator = repositoryRoot.appendingPathComponent("scripts/build-update-release.sh")
        let invalidBuild = try run(orchestrator, [
            "0.0.2", "2", "2", "https://updates.example.com/appcast.xml", "public", "notary", "key", "/tmp/tools", "/tmp/output"
        ])
        XCTAssertNotEqual(invalidBuild.status, 0)
        XCTAssertTrue(invalidBuild.output.contains("greater than"))
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
