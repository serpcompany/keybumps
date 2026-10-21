import Foundation

/// Moves a recording's own folder to the Trash, as Delete in the ⌘3 tab and the recording window's
/// Move to Trash do (#494), so it can be put back from there. It moves only a folder the recorder
/// named (`ScreencastCaptureFolder.isFolderName`) that holds every one of the recording's files, so
/// an index that names another folder, such as the folder recordings are saved in, never trashes it.
///
/// The app's (`app`) moves it to the Finder's Trash. In UI test mode it moves it into the sandbox's
/// own `Trash` folder instead, and under the unit-test host it refuses, so no test reaches the real
/// Trash; tests pass their own `move`.
struct RecordingTrash {
    /// Moves one folder to the Trash, or throws.
    var move: @MainActor (URL) throws -> Void

    /// Why the folder wasn't moved. A category only, never a path.
    enum Failure: Error, Equatable {
        /// Not a recording's own folder, or a file of the recording isn't in it.
        case notARecordingFolder
        /// The unit-test host never moves anything to the Trash.
        case unavailable
    }

    /// Moves `folder`, the recording's own, once it's checked: named by the recorder and holding
    /// each of `files`.
    @MainActor
    func moveToTrash(folder: URL, holding files: [URL]) throws {
        let path = folder.standardizedFileURL.path
        guard ScreencastCaptureFolder.isFolderName(folder.lastPathComponent), !files.isEmpty,
              files.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == path }) else {
            throw Failure.notARecordingFolder
        }
        try move(folder)
    }

    /// The app's: the Finder's Trash; the sandbox's `Trash` folder in UI test mode; nothing under
    /// the unit-test host.
    static var app: RecordingTrash {
        RecordingTrash { folder in
            guard !UnitTestHost.isActive else { throw Failure.unavailable }
            if let sandbox = ProductPaths.sandboxRoot {
                let trash = sandbox.appendingPathComponent("Trash", isDirectory: true)
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: folder, to: trash.appendingPathComponent(UUID().uuidString, isDirectory: true))
                return
            }
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }
}
