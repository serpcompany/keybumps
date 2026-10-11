import AppKit

/// The review's work on a capture's files: putting it on the clipboard, and deleting it.
enum ScreencastReviewFiles {
    /// Puts the capture on `pasteboard`: a recording as its files, each display's mixdown when it
    /// has one, as Finder copies files; a screenshot as an item per display with the image and its
    /// file, so an app takes whichever it can, as Snapzy's `ClipboardHelper` does (BSD-3-Clause,
    /// see LICENSE.snapzy). `images` are a screenshot's files as they are now, a marked-up copy in
    /// place of its original. They're read before the pasteboard is cleared, so one that can't be
    /// read leaves the clipboard as it was.
    @discardableResult
    static func copy(_ input: ScreencastReviewInput, images: [URL]? = nil, to pasteboard: NSPasteboard) -> Bool {
        switch input {
        case .video(let capture):
            let files = capture.videos.map(\.forSharing)
            guard !files.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(files.map { $0 as NSURL })
        case .screenshot(let screenshot):
            let files = images ?? screenshot.images.map(\.file)
            var items: [NSPasteboardItem] = []
            for file in files {
                guard let png = pngData(of: file) else { return false }
                let item = NSPasteboardItem()
                guard item.setData(png, forType: .png), item.setString(file.absoluteString, forType: .fileURL) else { return false }
                items.append(item)
            }
            guard !items.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(items)
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

    private static func pngData(of file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        if file.pathExtension.lowercased() == "png" { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}
