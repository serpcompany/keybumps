import Foundation
import Observation

enum DictationModelInstallationState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)
}

@MainActor
protocol DictationModelDownloading {
    func downloadModel(
        identifier: String,
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

@MainActor
@Observable
final class DictationModelManager {
    private(set) var states: [DictationTranscriptionEngine: DictationModelInstallationState] = [:]

    /// Where models are installed; read by the unit-test isolation guard.
    let modelsRoot: URL
    private let fileManager: FileManager
    private let downloader: any DictationModelDownloading

    init(
        modelsRoot: URL,
        fileManager: FileManager = .default,
        downloader: any DictationModelDownloading
    ) {
        self.modelsRoot = modelsRoot
        self.fileManager = fileManager
        self.downloader = downloader
        refresh()
    }

    func state(for engine: DictationTranscriptionEngine) -> DictationModelInstallationState {
        if engine == .appleSpeech { return .installed }
        return states[engine] ?? .notInstalled
    }

    func refresh() {
        for engine in DictationTranscriptionEngine.allCases where engine.requiresDownload {
            states[engine] = installedModelFolder(for: engine) == nil ? .notInstalled : .installed
        }
    }

    func download(_ engine: DictationTranscriptionEngine) async {
        guard let modelIdentifier = engine.modelIdentifier else { return }
        let engineRoot = root(for: engine)
        states[engine] = .downloading(0)
        do {
            try fileManager.createDirectory(at: engineRoot, withIntermediateDirectories: true)
            let folder = try await downloader.downloadModel(
                identifier: modelIdentifier,
                to: engineRoot,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              case .downloading(let currentProgress) = self.states[engine] else {
                            return
                        }
                        self.states[engine] = .downloading(max(
                            currentProgress,
                            min(max(progress, 0), 1)
                        ))
                    }
                }
            )
            try folder.path.write(
                to: locationFile(for: engine),
                atomically: true,
                encoding: .utf8
            )
            states[engine] = .installed
        } catch is CancellationError {
            try? fileManager.removeItem(at: engineRoot)
            states[engine] = .notInstalled
        } catch {
            states[engine] = .failed(error.localizedDescription)
        }
    }

    func delete(_ engine: DictationTranscriptionEngine) throws {
        guard engine.requiresDownload else { return }
        let engineRoot = root(for: engine)
        if fileManager.fileExists(atPath: engineRoot.path) {
            try fileManager.removeItem(at: engineRoot)
        }
        states[engine] = .notInstalled
    }

    func installedModelFolder(for engine: DictationTranscriptionEngine) -> URL? {
        guard engine.requiresDownload,
              let storedPath = try? String(contentsOf: locationFile(for: engine), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !storedPath.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: storedPath, isDirectory: true)
        guard folder.standardizedFileURL.path.hasPrefix(root(for: engine).standardizedFileURL.path + "/"),
              engine.requiredModelFiles.allSatisfy({ component in
                  fileManager.fileExists(atPath: folder.appendingPathComponent(component).path)
              }) else { return nil }
        return folder
    }

    private func root(for engine: DictationTranscriptionEngine) -> URL {
        modelsRoot.appendingPathComponent(engine.rawValue, isDirectory: true)
    }

    private func locationFile(for engine: DictationTranscriptionEngine) -> URL {
        root(for: engine).appendingPathComponent("model-location.txt")
    }
}
