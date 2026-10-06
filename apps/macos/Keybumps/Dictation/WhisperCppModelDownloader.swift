import CryptoKit
import Foundation

/// A whisper.cpp model file, pinned to one revision and checksum (ADR 0008).
struct WhisperCppModel: Sendable, Equatable {
    let identifier: String
    let fileName: String
    let source: URL
    let byteCount: Int64
    let sha256: String

    static let turbo = WhisperCppModel(
        identifier: "ggml-large-v3-turbo-q5_0",
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        source: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin")!,
        byteCount: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    )

    static let all = [turbo]

    static func model(identifier: String) -> WhisperCppModel? {
        all.first { $0.identifier == identifier }
    }

    /// The model file in `folder`, when the folder holds a whisper.cpp model.
    static func installedFile(in folder: URL, fileManager: FileManager = .default) -> URL? {
        all.lazy
            .map { folder.appendingPathComponent($0.fileName) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}

enum WhisperCppModelDownloadError: LocalizedError, Equatable {
    case unknownModel
    case badResponse(Int)
    case wrongSize
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .unknownModel: "This model can't be downloaded."
        case .badResponse(let status): "The model download failed (HTTP \(status))."
        case .wrongSize, .checksumMismatch: "The downloaded model was incomplete or damaged. Try again."
        }
    }
}

/// Downloads a whisper.cpp model as one file, without credentials, and installs it only after its
/// size and SHA-256 match the pinned values.
struct WhisperCppModelDownloader: DictationModelDownloading {
    var models = WhisperCppModel.all

    func downloadModel(
        identifier: String,
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let model = models.first(where: { $0.identifier == identifier }) else {
            throw WhisperCppModelDownloadError.unknownModel
        }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let folder = downloadBase.appendingPathComponent(model.identifier, isDirectory: true)
        let partial = downloadBase.appendingPathComponent("\(model.fileName).partial")
        defer { try? FileManager.default.removeItem(at: partial) }

        try await ModelFileDownload.run(from: model.source, to: partial) { written, expected in
            let total = expected > 0 ? expected : model.byteCount
            progress(min(Double(written) / Double(max(total, 1)), 1) * 0.97)
        }
        try await Task.detached(priority: .utility) {
            try Self.verify(partial, matches: model)
        }.value
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(model.fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        progress(1)
        return folder
    }

    nonisolated static func verify(_ file: URL, matches model: WhisperCppModel) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        guard size == model.byteCount else { throw WhisperCppModelDownloadError.wrongSize }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == model.sha256 else { throw WhisperCppModelDownloadError.checksumMismatch }
    }
}

/// Sends a model download to the downloader for its format.
struct DictationModelDownloadRouter: DictationModelDownloading {
    let whisperKit: any DictationModelDownloading
    let whisperCpp: any DictationModelDownloading

    func downloadModel(
        identifier: String,
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloader = WhisperCppModel.model(identifier: identifier) == nil ? whisperKit : whisperCpp
        return try await downloader.downloadModel(identifier: identifier, to: downloadBase, progress: progress)
    }
}

/// One file download with progress, moved to `destination` when it finishes. Cancelling the
/// calling task cancels it. No cookies or credentials are sent.
private enum ModelFileDownload {
    static func run(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (_ written: Int64, _ expected: Int64) -> Void
    ) async throws {
        let delegate = Delegate(destination: destination, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: source)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64, Int64) -> Void
        // Touched only on the session's serial delegate queue.
        var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                failure = WhisperCppModelDownloadError.badResponse(response.statusCode)
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let continuation = continuation
            self.continuation = nil
            if let error = error as? URLError, error.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else if let error = error ?? failure {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
        }
    }
}
