import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// A screenshot's size in pixels.
struct ScreenshotSmokePixelSize: Equatable, Sendable {
    var width: Int
    var height: Int
}

/// A display as the smoke test's screenshots see it: its frame in AppKit's space, and its pixels
/// per point.
struct ScreenshotSmokeDisplay: Equatable, Sendable {
    var frame: CGRect
    var scale: CGFloat

    /// The size a screenshot of the whole display has.
    var pixelSize: ScreenshotSmokePixelSize {
        ScreenshotSmokeChecks.pixelSize(of: frame.size, scale: scale)
    }

    /// The connected displays, the main one (with the menu bar) first, as `screencapture` writes
    /// its files.
    @MainActor
    static func connected() -> [ScreenshotSmokeDisplay] {
        NSScreen.screens.map { ScreenshotSmokeDisplay(frame: $0.frame, scale: $0.backingScaleFactor) }
    }
}

/// What a check reads from a screenshot file.
struct ScreenshotSmokeImageFacts: Equatable, Sendable {
    let isPNG: Bool
    let pixelSize: ScreenshotSmokePixelSize
}

/// The checks on each screenshot: a PNG of its display's size, or the area's, marked as a screen
/// capture, which ⌘3 would list.
enum ScreenshotSmokeChecks {
    /// What ImageIO reads from `url`; nil when it reads no image there.
    static func facts(of url: URL) -> ScreenshotSmokeImageFacts? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let type = CGImageSourceGetType(source) as String?
        return ScreenshotSmokeImageFacts(isPNG: type == "public.png", pixelSize: ScreenshotSmokePixelSize(width: width, height: height))
    }

    /// Whether `url` carries macOS's screen-capture attribute, which the watcher reads.
    static func isMarkedAsScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, FileSystemScreenshotDirectoryReader.screenCaptureAttribute, nil, 0, 0, 0) >= 0
    }

    /// Throws why a written screenshot fails: it isn't a PNG, it's the wrong size, or it isn't
    /// marked as a screen capture.
    static func check(_ facts: ScreenshotSmokeImageFacts?, expected: ScreenshotSmokePixelSize?, isMarked: Bool) throws {
        guard let facts, facts.isPNG else { throw ScreencastSmokeFailure.notPNG }
        guard let expected, facts.pixelSize == expected else { throw ScreencastSmokeFailure.wrongSize }
        guard isMarked else { throw ScreencastSmokeFailure.notMarkedAsScreenCapture }
    }

    /// `size` in points at `scale`, as whole pixels.
    static func pixelSize(of size: CGSize, scale: CGFloat) -> ScreenshotSmokePixelSize {
        ScreenshotSmokePixelSize(
            width: ScreencastSmokeChecks.pixels(size.width * scale),
            height: ScreencastSmokeChecks.pixels(size.height * scale)
        )
    }

    /// The area it takes: up to 640 × 360 points in the middle of `frame`, in AppKit's space.
    static func area(in frame: CGRect) -> CGRect {
        let width = min(640, (frame.width / 2).rounded(.down))
        let height = min(360, (frame.height / 2).rounded(.down))
        return CGRect(x: (frame.midX - width / 2).rounded(), y: (frame.midY - height / 2).rounded(), width: width, height: height)
    }

    /// `rect`, in AppKit's space, measured from the top left of the main display, whose frame is
    /// `main`, as `screencapture -R` takes it.
    static func fromTopLeft(_ rect: CGRect, main: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: main.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The size each of a Screen capture's files should be, in the order they were read. The first
    /// is the main display's. Each later one is a display left that has the size read, so displays
    /// macOS orders differently from `NSScreen.screens` still pass; any file still without one gets
    /// the first display left.
    static func expectedScreenSizes(read: [ScreenshotSmokePixelSize?], displays: [ScreenshotSmokeDisplay]) -> [ScreenshotSmokePixelSize?] {
        var left = displays.dropFirst().map(\.pixelSize)
        var expected: [ScreenshotSmokePixelSize?] = read.indices.map { $0 == 0 ? displays.first?.pixelSize : nil }
        for index in read.indices.dropFirst() {
            guard let size = read[index], let match = left.firstIndex(of: size) else { continue }
            expected[index] = left.remove(at: match)
        }
        for index in read.indices.dropFirst() where expected[index] == nil && !left.isEmpty {
            expected[index] = left.removeFirst()
        }
        return expected
    }

    /// Whether ⌘3 would list `file`: the Screengrabs tab's own filter over `clipboard`.
    @MainActor
    static func isListed(_ file: URL, in clipboard: ClipboardHistoryService) -> Bool {
        let path = comparablePath(file)
        let listed = ScreenshotPaletteContent.resolve(entries: clipboard.entries, query: "", isEnabled: true).entries
        return listed.contains { entry in entry.sourcePath.map { comparablePath(URL(fileURLWithPath: $0)) } == path }
    }

    /// One spelling for a path, whether it came through `/var` or `/private/var`.
    private static func comparablePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Takes the smoke test's screenshots through Screengrabs' own path (#491), with no mouse or
/// keyboard input: `ScreenshotCapturer` with `screencapture`, as Screenshot Screen takes one file of
/// each display, then an area in the middle of the main display (`-R`, since a selection needs a
/// person). Each file is checked (a PNG of the expected size, marked as a screen capture), then
/// handed to a watcher (`ScreenshotToolsService`) and a Clipboard History of the smoke test's own,
/// and has to be one ⌘3 would list. Then everything is deleted.
///
/// Files go only in `environment.screenshotsFolder`, the smoke test's own, never the screenshot
/// folder or the Desktop. The Clipboard History keeps its items in `environment.clipboardFolder`,
/// is never started, and has a pasteboard of its own that nothing writes to, so the person's
/// Clipboard History and clipboard are never touched.
@available(macOS 15, *)
@MainActor
final class ScreenshotSmokeRunner {
    typealias Line = ScreencastSmokeReport.Screenshot

    struct Configuration {
        /// How long `screencapture` has to finish.
        var captureTimeout: TimeInterval = 15
        /// How long the watcher has to add a capture's files to Clipboard History.
        var listTimeout: TimeInterval = 10
        var pollInterval: Duration = .milliseconds(50)
    }

    struct Environment {
        /// Where the screenshots are saved and the watcher watches: emptied first, deleted after.
        var screenshotsFolder: URL
        /// Where the smoke test's own Clipboard History keeps its items: deleted after.
        var clipboardFolder: URL
        /// Runs `screencapture`; tests pass one that writes made-up PNGs.
        var runner: any ScreenshotCaptureRunning
        /// The displays, the main one first.
        var displays: [ScreenshotSmokeDisplay]
        var now: () -> Date = Date.init
        var fileManager: FileManager = .default
    }

    private let configuration: Configuration
    private let environment: Environment
    /// One line for each screenshot, in the order they're taken.
    private(set) var screenshots: [Line]
    /// Called with every line after each stage, so the result on disk stays current.
    var onChange: (([Line]) -> Void)?

    init(configuration: Configuration = Configuration(), environment: Environment) {
        self.configuration = configuration
        self.environment = environment
        screenshots = Line.planned(displayCount: environment.displays.count)
    }

    /// Takes every screenshot and returns their lines.
    func run() async -> [Line] {
        let fileManager = environment.fileManager
        let folders = [environment.screenshotsFolder, environment.clipboardFolder]
        for folder in folders { try? fileManager.removeItem(at: folder) }
        try? fileManager.createDirectory(at: environment.screenshotsFolder, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardHistoryService(
            fileManager: fileManager,
            storageURL: environment.clipboardFolder.appendingPathComponent("clipboard-history.json"),
            pasteboard: pasteboard,
            mediaDirectoryURL: environment.clipboardFolder.appendingPathComponent("media", isDirectory: true),
            sourceApps: .inert
        )
        // As the app hands a new screenshot to Clipboard History, never copying it.
        let delivery = ScreenshotClipboardDelivery(clipboard: clipboard, copiesToClipboard: { false })
        let watcher = ScreenshotToolsService(
            resolver: Self.resolver(watching: environment.screenshotsFolder, fileManager: fileManager),
            reader: FileSystemScreenshotDirectoryReader(),
            now: environment.now,
            ingest: { delivery.add($0, copying: false) }
        )
        for kind in ScreenshotSmokeKind.allCases {
            await capture(kind, watcher: watcher, clipboard: clipboard)
        }
        watcher.stop()
        pasteboard.releaseGlobally()
        for folder in folders { try? fileManager.removeItem(at: folder) }
        return screenshots
    }

    /// The watcher's folder: the smoke test's own. Its Desktop, should that folder be missing, is
    /// inside it too, so the watcher never reads the screenshot folder or the person's Desktop.
    static func resolver(watching folder: URL, fileManager: FileManager) -> ScreenshotLocationResolver {
        let watched = folder.standardizedFileURL.path
        return ScreenshotLocationResolver(
            preferredLocation: { folder.path },
            homeDirectory: folder,
            isDirectory: { url in
                var isDirectory: ObjCBool = false
                return url.standardizedFileURL.path == watched
                    && fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        )
    }

    // MARK: One capture

    private func capture(_ kind: ScreenshotSmokeKind, watcher: ScreenshotToolsService, clipboard: ClipboardHistoryService) async {
        let lines = screenshots.indices.filter { screenshots[$0].kind == kind }
        guard !lines.isEmpty else { return }
        let folder = environment.screenshotsFolder
        let displays = environment.displays
        let mode = mode(for: kind)
        let takenAt = environment.now()
        let files = ScreenshotCapturePlan.files(in: folder, at: takenAt, displayCount: displays.count, mode: mode)
        defer {
            cleanUp(lines, files: files, watcher: watcher, clipboard: clipboard)
            changed()
        }

        guard files.count == lines.count else {
            fail(lines, ScreencastSmokeFailure.wrongFileCount)
            return
        }
        // Started afresh before each capture, as Screengrabs' watcher is running before a hotkey's.
        watcher.stop()
        watcher.apply(enabled: true, clipboardHistoryEnabled: true)
        guard case .watching = watcher.status else {
            fail(lines, ScreencastSmokeFailure.watcherUnavailable)
            return
        }
        for line in lines { screenshots[line].stage = .capturing }
        changed()

        let started = ContinuousClock.now
        let capturer = ScreenshotCapturer(
            runner: environment.runner,
            folder: { folder },
            now: { takenAt },
            displayCount: { displays.count },
            fileManager: environment.fileManager
        )
        let written: [URL]
        do {
            written = try await ScreencastSmokeRunner.within(configuration.captureTimeout) { await Self.take(mode, with: capturer) }
        } catch {
            fail(lines, error)
            return
        }
        let captured = ContinuousClock.now
        let captureMs = Self.milliseconds(from: started, to: captured)
        for line in lines { screenshots[line].captureMs = captureMs }

        check(lines, files: files, written: written, kind: kind)
        changed()
        await waitUntilListed(lines, files: files, clipboard: clipboard, since: captured)
    }

    private func mode(for kind: ScreenshotSmokeKind) -> ScreenshotCaptureMode {
        switch kind {
        case .screen:
            return .screens
        case .area:
            let main = environment.displays.first?.frame ?? .zero
            return .fixedArea(ScreenshotSmokeChecks.fromTopLeft(ScreenshotSmokeChecks.area(in: main), main: main))
        }
    }

    /// The capturer's files, once `screencapture` has finished and they're marked.
    private static func take(_ mode: ScreenshotCaptureMode, with capturer: ScreenshotCapturer) async -> [URL] {
        await withCheckedContinuation { continuation in
            capturer.capture(mode) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Checking

    private func check(_ lines: [Int], files: [URL], written: [URL], kind: ScreenshotSmokeKind) {
        let fileManager = environment.fileManager
        var facts: [ScreenshotSmokeImageFacts?] = []
        for (line, file) in zip(lines, files) {
            guard written.contains(file) else {
                screenshots[line].errorCategory = ScreencastSmokeFailure.missingFile.rawValue
                facts.append(nil)
                continue
            }
            screenshots[line].stage = .saved
            do {
                screenshots[line].bytes = try ScreencastSmokeChecks.size(of: file, fileManager: fileManager)
            } catch {
                screenshots[line].errorCategory = ScreencastSmokeRunner.category(of: error)
                facts.append(nil)
                continue
            }
            let read = ScreenshotSmokeChecks.facts(of: file)
            screenshots[line].pixelWidth = read?.pixelSize.width
            screenshots[line].pixelHeight = read?.pixelSize.height
            facts.append(read)
        }

        let expected = expectedSizes(kind, read: facts.map { $0?.pixelSize })
        for (offset, line) in lines.enumerated() where screenshots[line].stage == .saved && screenshots[line].errorCategory == nil {
            screenshots[line].expectedPixelWidth = expected[offset]?.width
            screenshots[line].expectedPixelHeight = expected[offset]?.height
            do {
                let isMarked = ScreenshotSmokeChecks.isMarkedAsScreenCapture(files[offset])
                try ScreenshotSmokeChecks.check(facts[offset], expected: expected[offset], isMarked: isMarked)
                screenshots[line].stage = .checked
            } catch {
                screenshots[line].errorCategory = ScreencastSmokeRunner.category(of: error)
            }
        }
    }

    private func expectedSizes(_ kind: ScreenshotSmokeKind, read: [ScreenshotSmokePixelSize?]) -> [ScreenshotSmokePixelSize?] {
        switch kind {
        case .screen:
            return ScreenshotSmokeChecks.expectedScreenSizes(read: read, displays: environment.displays)
        case .area:
            guard let main = environment.displays.first else { return read.map { _ in nil } }
            let size = ScreenshotSmokeChecks.pixelSize(of: ScreenshotSmokeChecks.area(in: main.frame).size, scale: main.scale)
            return read.map { _ in size }
        }
    }

    /// Waits until the watcher has added every checked file to the Clipboard History, as ⌘3 would
    /// list it, noting how long each took; one it hasn't in time fails as `notListed`.
    private func waitUntilListed(_ lines: [Int], files: [URL], clipboard: ClipboardHistoryService, since captured: ContinuousClock.Instant) async {
        let waiting = lines.indices.filter { screenshots[lines[$0]].stage == .checked }
        let deadline = captured + .seconds(configuration.listTimeout)
        while true {
            for offset in waiting where screenshots[lines[offset]].listMs == nil {
                guard ScreenshotSmokeChecks.isListed(files[offset], in: clipboard) else { continue }
                screenshots[lines[offset]].listMs = Self.milliseconds(from: captured, to: .now)
            }
            let done = waiting.allSatisfy { screenshots[lines[$0]].listMs != nil }
            guard !done, ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: configuration.pollInterval)
        }
        for offset in waiting {
            let line = lines[offset]
            if screenshots[line].listMs == nil {
                screenshots[line].errorCategory = ScreencastSmokeFailure.notListed.rawValue
            } else {
                screenshots[line].stage = .listed
            }
        }
    }

    // MARK: Cleaning up

    /// Stops the watcher and deletes the capture's files, anything else in the folder, and the
    /// Clipboard History's items with their copies, however the capture ended. A screenshot that
    /// was listed passes once its file and its item are gone.
    private func cleanUp(_ lines: [Int], files: [URL], watcher: ScreenshotToolsService, clipboard: ClipboardHistoryService) {
        let fileManager = environment.fileManager
        watcher.stop()
        for entry in clipboard.entries { clipboard.delete(entry) }
        let folder = environment.screenshotsFolder
        let items = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items { try? fileManager.removeItem(at: item) }
        let copies = (try? fileManager.contentsOfDirectory(atPath: clipboard.mediaDirectoryURL.path)) ?? []
        let clipboardEmpty = clipboard.entries.isEmpty && copies.isEmpty
        for (offset, line) in lines.enumerated() where screenshots[line].stage == .listed {
            guard clipboardEmpty, !fileManager.fileExists(atPath: files[offset].path) else {
                screenshots[line].errorCategory = ScreencastSmokeFailure.cleanupFailed.rawValue
                continue
            }
            screenshots[line].stage = .cleanedUp
            screenshots[line].passed = true
        }
    }

    // MARK: Reporting

    private func fail(_ lines: [Int], _ error: Error) {
        for line in lines { screenshots[line].errorCategory = ScreencastSmokeRunner.category(of: error) }
    }

    private func changed() {
        onChange?(screenshots)
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        Int(((end - start) / .milliseconds(1)).rounded())
    }
}
