import Foundation
import XCTest
@testable import Keybumps

@MainActor
final class DictationWarmRuntimeBenchmarkTests: XCTestCase {
    func testReportsColdLoadAndWarmInferenceTimingsWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        // The model folder is named explicitly: tests never read the installed app's data, so
        // under the unit-test host its model location isn't looked up.
        let modelPath = environment["KEYBUMPS_WHISPER_BENCHMARK_MODEL"]
        let audioPath = environment["KEYBUMPS_WHISPER_BENCHMARK_AUDIO"]
            ?? "/tmp/keybumps-whisper-benchmark.wav"
        guard let modelPath,
              FileManager.default.fileExists(atPath: modelPath),
              FileManager.default.fileExists(atPath: audioPath) else {
            throw XCTSkip("Set KEYBUMPS_WHISPER_BENCHMARK_MODEL to a model folder and provide a non-private WAV to collect local timing evidence.")
        }

        let modelURL = URL(fileURLWithPath: modelPath, isDirectory: true)
        let audioURL = URL(fileURLWithPath: audioPath)
        let loadStarted = ContinuousClock.now
        let transcriber = try await WhisperKitCompletedAudioTranscriber.load(modelFolder: modelURL)
        let loadDuration = loadStarted.duration(to: .now)
        var inferenceDurations: [Duration] = []

        for _ in 0..<3 {
            let inferenceStarted = ContinuousClock.now
            _ = try await transcriber.transcribe(
                audioURL: audioURL,
                language: "en-US",
                recordedDuration: 4
            )
            inferenceDurations.append(inferenceStarted.duration(to: .now))
        }
        await transcriber.unload().value

        print("KEYBUMPS_WHISPER_TIMING load=\(loadDuration) inference=\(inferenceDurations)")
    }
}
