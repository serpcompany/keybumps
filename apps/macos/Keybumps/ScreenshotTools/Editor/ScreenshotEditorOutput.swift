import Foundation

/// Where Save writes the edited copy. Originals are never overwritten.
enum ScreenshotEditorOutput {
    /// Beside the source, named after it, where that folder can be written to, else in
    /// `fallbackFolder`. `besideSource: false` always writes in `fallbackFolder`, still named after
    /// the source: for a screenshot, ScreenGrabs' history (#605). The first name nothing has is
    /// used, so nothing is written over.
    static func destination(
        sourceURL: URL?,
        fallbackFolder: URL,
        besideSource: Bool = true,
        now: Date = Date(),
        isWritableDirectory: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "Image \(timestamp(now))"
        let sourceFolder = besideSource ? sourceURL?.deletingLastPathComponent() : nil
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
