import AppKit

/// The review's work on a capture's files: putting a capture on the clipboard, and deleting it.
enum ScreencastReviewFiles {
    /// Puts the recording on `pasteboard` as its files, each display's mixdown when it has one, as
    /// Finder copies files.
    @discardableResult
    static func copy(_ input: ScreencastReviewInput, to pasteboard: NSPasteboard) -> Bool {
        switch input {
        case .video(let capture):
            let files = capture.videos.map(\.forSharing)
            guard !files.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(files.map { $0 as NSURL })
        }
    }

    /// Deletes the capture's folder, and only a folder holding the capture's own files.
    static func delete(_ input: ScreencastReviewInput, fileManager: FileManager) throws {
        let folder = input.folder.standardizedFileURL.path
        guard !input.mediaFiles.isEmpty,
              input.mediaFiles.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == folder }) else {
            throw ScreencastReviewFailure.deleteFailed
        }
        do {
            try fileManager.removeItem(at: input.folder)
        } catch {
            throw ScreencastReviewFailure.deleteFailed
        }
    }
}
