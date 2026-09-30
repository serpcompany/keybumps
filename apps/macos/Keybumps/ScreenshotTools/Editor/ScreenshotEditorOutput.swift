import Foundation

/// Where Save writes the edited copy. Originals are never overwritten.
enum ScreenshotEditorOutput {
    static func destination(
        sourceURL: URL?,
        fallbackFolder: URL,
        now: Date = Date(),
        isWritableDirectory: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "Image \(timestamp(now))"
        let sourceFolder = sourceURL?.deletingLastPathComponent()
        let folder = sourceFolder.flatMap { isWritableDirectory($0) ? $0 : nil } ?? fallbackFolder
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "(edited)" : "(edited \(attempt))"
            let candidate = folder.appendingPathComponent("\(base) \(suffix).png")
            if !exists(candidate) { return candidate }
            attempt += 1
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
