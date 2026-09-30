import Foundation
import Observation

/// Resolves the folder macOS saves screenshots to. Reads `com.apple.screencapture`
/// `location` without ever writing system preferences; falls back to the Desktop.
struct ScreenshotLocationResolver {
    var preferredLocation: () -> String?
    var homeDirectory: URL
    var isDirectory: (URL) -> Bool

    func resolve() -> URL {
        let desktop = homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = preferredLocation()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return desktop
        }
        let expanded: String
        if raw == "~" {
            expanded = homeDirectory.path
        } else if raw.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            expanded = raw
        }
        let candidate = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        return isDirectory(candidate) ? candidate : desktop
    }

    static let system = ScreenshotLocationResolver(
        preferredLocation: {
            CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        },
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        isDirectory: { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    )
}

struct ScreenshotDirectoryEntry: Equatable {
    let url: URL
    let createdAt: Date
    let size: Int
    let isScreenCapture: Bool
}

enum ScreenshotFolderReadError: Error, Equatable {
    case accessDenied
    case unavailable
}

protocol ScreenshotDirectoryReading {
    func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry]
}

struct FileSystemScreenshotDirectoryReader: ScreenshotDirectoryReading {
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ScreenshotFolderReadError.accessDenied
        } catch {
            throw ScreenshotFolderReadError.unavailable
        }
        return urls.compactMap { url in
            guard ScreenshotFileFilter.hasImageExtension(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return ScreenshotDirectoryEntry(
                url: url,
                createdAt: values.creationDate ?? .distantPast,
                size: values.fileSize ?? 0,
                isScreenCapture: getxattr(url.path, Self.screenCaptureAttribute, nil, 0, 0, 0) >= 0
            )
        }
    }
}

struct UnavailableScreenshotDirectoryReader: ScreenshotDirectoryReading {
    func entries(in folder: URL) throws -> [ScreenshotDirectoryEntry] {
        throw ScreenshotFolderReadError.unavailable
    }
}

enum ScreenshotFileFilter {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif"]

    static func hasImageExtension(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Only files macOS marked as screen captures, created after watching began.
    static func accepts(_ entry: ScreenshotDirectoryEntry, since start: Date) -> Bool {
        entry.isScreenCapture && hasImageExtension(entry.url) && entry.createdAt >= start
    }
}

/// Adds new screenshot files to Clipboard History and, while "Copy new screenshots to the
/// clipboard" is on, puts each one on the pasteboard too. Restoring the item marks that
/// pasteboard write as seen, so Clipboard History doesn't add it a second time.
@MainActor
struct ScreenshotClipboardDelivery {
    let clipboard: ClipboardHistoryService
    let copiesToClipboard: () -> Bool

    /// True when the file became a new Clipboard History item. The Screen and Edit hotkey adds
    /// its files before the watcher sees them, so a file already in Clipboard History (or matching
    /// the newest item) is neither added nor copied again. `copying: false` never copies.
    @discardableResult
    func add(_ url: URL, copying: Bool = true) -> Bool {
        guard !clipboard.entries.contains(where: { $0.sourcePath == url.path }) else { return false }
        let copies = copying && copiesToClipboard()
        if copies { clipboard.recordPendingChange() }
        guard clipboard.ingestImageFile(at: url, isScreenCapture: true) else { return false }
        if copies, let entry = clipboard.entries.first(where: { $0.sourcePath == url.path }) {
            clipboard.restore(entry)
        }
        return true
    }
}

enum ScreenshotToolsStatus: Equatable {
    case stopped
    case requiresClipboardHistory
    case watching(URL)
    case folderAccessDenied(URL)
    case folderUnavailable(URL)
}

/// Watches the macOS screenshot folder and hands new screenshot files to Clipboard History.
/// Never captures the screen and never logs filenames or paths.
@MainActor
@Observable
class ScreenshotToolsService {
    private(set) var status: ScreenshotToolsStatus = .stopped

    @ObservationIgnored private let resolver: ScreenshotLocationResolver
    @ObservationIgnored private let reader: any ScreenshotDirectoryReading
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let ingest: (URL) -> Bool
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var handled: Set<URL> = []
    @ObservationIgnored private var lastSeenSize: [URL: Int] = [:]
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var locationTimer: Timer?
    @ObservationIgnored private var pendingScan: DispatchWorkItem?

    init(
        resolver: ScreenshotLocationResolver = .system,
        reader: any ScreenshotDirectoryReading = FileSystemScreenshotDirectoryReader(),
        now: @escaping () -> Date = Date.init,
        ingest: @escaping (URL) -> Bool
    ) {
        self.resolver = resolver
        self.reader = reader
        self.now = now
        self.ingest = ingest
    }

    /// Screenshot Tools only runs while Clipboard History is enabled, because screenshots
    /// are presented as Clipboard History items.
    func apply(enabled: Bool, clipboardHistoryEnabled: Bool) {
        guard enabled else { stop(); return }
        guard clipboardHistoryEnabled else {
            stopWatching()
            status = .requiresClipboardHistory
            return
        }
        start()
    }

    func stop() {
        stopWatching()
        status = .stopped
    }

    func scanForTesting() { scan() }

    private func start() {
        let resolved = resolver.resolve()
        if case .watching(let current) = status, current == resolved { return }
        stopWatching()
        folder = resolved
        startedAt = now()
        handled = []
        lastSeenSize = [:]
        guard refreshStatusByReading(resolved) else {
            scheduleLocationCheck()
            return
        }
        startSource(for: resolved)
        scheduleLocationCheck()
    }

    private func stopWatching() {
        pendingScan?.cancel(); pendingScan = nil
        source?.cancel(); source = nil
        locationTimer?.invalidate(); locationTimer = nil
        folder = nil
    }

    @discardableResult
    private func refreshStatusByReading(_ folder: URL) -> Bool {
        do {
            _ = try reader.entries(in: folder)
            status = .watching(folder)
            return true
        } catch ScreenshotFolderReadError.accessDenied {
            status = .folderAccessDenied(folder)
        } catch {
            status = .folderUnavailable(folder)
        }
        return false
    }

    private func startSource(for folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan(after: 0.3) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// The screenshot folder can change from the Screenshot app's Options menu.
    private func scheduleLocationCheck() {
        locationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let folder = self.folder else { return }
                let resolved = self.resolver.resolve()
                if resolved != folder {
                    self.start()
                } else if case .watching = self.status {
                    return
                } else if self.refreshStatusByReading(resolved) {
                    self.startSource(for: resolved)
                }
            }
        }
    }

    private func scheduleScan(after delay: TimeInterval) {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        guard case .watching(let folder) = status,
              let entries = try? reader.entries(in: folder) else { return }
        var needsRescan = false
        for entry in entries where !handled.contains(entry.url) && ScreenshotFileFilter.accepts(entry, since: startedAt) {
            // macOS may still be writing; ingest only once the size is stable across two scans.
            guard entry.size > 0, lastSeenSize[entry.url] == entry.size else {
                lastSeenSize[entry.url] = entry.size
                needsRescan = true
                continue
            }
            handled.insert(entry.url)
            lastSeenSize[entry.url] = nil
            _ = ingest(entry.url)
        }
        if needsRescan { scheduleScan(after: 0.5) }
    }
}
