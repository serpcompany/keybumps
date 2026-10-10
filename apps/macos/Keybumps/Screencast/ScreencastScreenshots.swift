import AppKit
import ImageIO
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

/// What the picker and screenshots read from the screen, behind a seam: ScreenCaptureKit in the app
/// (`ScreenCaptureKitPickerSystem`), a fake in tests, and an inert one in the unit-test host, so no
/// test reads the screen or asks for Screen Recording. Errors it throws are `ScreencastFailure`s.
@MainActor
protocol ScreencastPickerSystem: AnyObject {
    /// What's on screen now, windows front to back.
    func content() async throws -> ScreencastContent

    /// The windows on screen the window server draws fully transparent (alpha 0), which can't be
    /// picked: some apps keep invisible ordinary windows over others.
    func transparentWindows() -> Set<CGWindowID>

    /// A still image of what `plan` shows, read from `content`.
    func screenshot(_ plan: ScreencastScreenshotPlan, content: ScreencastContent) async throws -> CGImage
}

/// What one screenshot image shows and its size, without the pointer.
struct ScreencastScreenshotPlan: Equatable, Sendable {
    enum Filter: Equatable, Sendable {
        /// A display, or part of it (`configuration.sourceRect`), as a recording's filter reads it,
        /// with all of Keybumps left out.
        case display(ScreencastFilterPlan)
        /// One window on its own, whole, with its transparent corners, wherever it is, even across
        /// displays (`SCContentFilter(desktopIndependentWindow:)`). Nothing else shows: not its
        /// app's other windows, menus, or palettes, and never Keybumps.
        case window(CGWindowID)

        var displayID: CGDirectDisplayID? {
            if case .display(let plan) = self { plan.displayID } else { nil }
        }
    }

    let filter: Filter
    let configuration: ScreencastStreamConfiguration
}

/// A screenshot saved in its own folder in the captures folder, as a video is.
struct ScreencastScreenshot: Equatable, Sendable {
    struct Image: Equatable, Sendable {
        let file: URL
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// `<captures folder>/<timestamp>/`.
    let folder: URL
    /// One per display, in display order: `screenshot-1.png`, `screenshot-2.png`, …
    let images: [Image]

    var metadataURL: URL { folder.appendingPathComponent(ScreencastMetadata.fileName) }
}

extension ScreencastCaptureFolder {
    /// The screenshot of the display at `index` (from 0): `screenshot-1.png`, …
    static func screenshotName(index: Int) -> String {
        "screenshot-\(index + 1).png"
    }
}

/// A screenshot's `meta.json`: structure only, like a video's (`ScreencastMetadata`), with the same
/// keys where they're the same thing, and `kind` to tell them apart. Never a window, app, title, or
/// address. The review panel (#450) adds its user content to it, as to a video's.
struct ScreencastScreenshotMetadata: Codable, Equatable {
    struct Image: Codable, Equatable {
        /// A file name in the capture's folder.
        var file: String
        var width: Int
        var height: Int
    }

    var version = ScreencastMetadata.currentVersion
    var kind = "screenshot"
    var startedAt: Date
    /// `display`, `everyDisplay`, `window`, or `area`.
    var target: String
    var displayCount: Int
    var images: [Image]

    init(screenshot: ScreencastScreenshot, target: ScreencastTarget, startedAt: Date) {
        self.startedAt = startedAt
        self.target = target.kind
        displayCount = screenshot.images.count
        images = screenshot.images.map { Image(file: $0.file.lastPathComponent, width: $0.pixelWidth, height: $0.pixelHeight) }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ScreencastScreenshotMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScreencastScreenshotMetadata.self, from: Data(contentsOf: url))
    }
}

/// Taking a screenshot of what the picker chose. Every Keybumps window is left out, the key
/// display's overlay included (owner, 2026-10-10: the overlay doesn't belong in a screenshot), and
/// so is the pointer.
enum ScreencastScreenshots {
    private static let logger = Logger(subsystem: "com.serp.keybumps", category: "screencast")

    /// Reads the screen, takes an image per display `target` shows, and saves them with `meta.json`
    /// in a new `<timestamp>` folder. Nothing is saved when an image can't be taken.
    static func take(
        _ target: ScreencastTarget,
        system: any ScreencastPickerSystem,
        ownProcessID: pid_t,
        capturesFolder: URL,
        takenAt: Date,
        fileManager: FileManager
    ) async throws -> ScreencastScreenshot {
        let content = try await system.content()
        var images: [CGImage] = []
        for plan in try plans(for: target, content: content, ownProcessID: ownProcessID) {
            images.append(try await system.screenshot(plan, content: content))
        }
        return try save(images, target: target, in: capturesFolder, takenAt: takenAt, fileManager: fileManager)
    }

    /// One plan per display, in the recorder's order (left to right, then top to bottom).
    static func plans(for target: ScreencastTarget, content: ScreencastContent, ownProcessID: pid_t) throws -> [ScreencastScreenshotPlan] {
        func displayPlan(_ display: ScreencastContent.Display, area: CGRect?) -> ScreencastScreenshotPlan {
            let geometry = area.map { ScreencastCaptureGeometry.area($0, displaySize: display.frame.size, scale: display.scale) }
                ?? .display(size: display.frame.size, scale: display.scale)
            return ScreencastScreenshotPlan(
                // No overlays: all of Keybumps stays out.
                filter: .display(ScreencastCaptureFilter.displayPlan(display: display.id, ownProcessID: ownProcessID, overlays: [], content: content)),
                configuration: configuration(geometry)
            )
        }

        switch target {
        case .display(let id):
            guard let display = content.display(id) else { throw ScreencastFailure.targetUnavailable }
            return [displayPlan(display, area: nil)]
        case .everyDisplay:
            guard !content.displays.isEmpty else { throw ScreencastFailure.targetUnavailable }
            let displays = content.displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
            return displays.map { displayPlan($0, area: nil) }
        case .area(let id, let rect):
            guard let display = content.display(id) else { throw ScreencastFailure.targetUnavailable }
            return [displayPlan(display, area: rect)]
        case .window(let id):
            // The window alone, whole, at the scale of the display showing most of it; never one of
            // Keybumps's.
            guard let window = content.window(id), window.processID != ownProcessID,
                  let display = content.display(mostOverlapping: window.frame) else { throw ScreencastFailure.targetUnavailable }
            let scale = max(display.scale, 1)
            return [ScreencastScreenshotPlan(
                filter: .window(id),
                configuration: ScreencastStreamConfiguration(
                    pixelWidth: Int((window.frame.width * scale).rounded(.up)),
                    pixelHeight: Int((window.frame.height * scale).rounded(.up)),
                    sourceRect: CGRect(origin: .zero, size: window.frame.size),
                    framesPerSecond: 1,
                    showsCursor: false,
                    showsMouseClicks: false,
                    scalesToFit: false
                )
            )]
        }
    }

    private static func configuration(_ geometry: ScreencastCaptureGeometry) -> ScreencastStreamConfiguration {
        ScreencastStreamConfiguration(
            pixelWidth: geometry.pixelWidth,
            pixelHeight: geometry.pixelHeight,
            sourceRect: geometry.sourceRect,
            framesPerSecond: 1,
            showsCursor: false,
            showsMouseClicks: false,
            scalesToFit: false
        )
    }

    /// Saves `images` as `screenshot-N.png` with `meta.json` in a new folder. A PNG that can't be
    /// written removes the folder; a `meta.json` that can't be written is only logged, as for a video.
    static func save(
        _ images: [CGImage],
        target: ScreencastTarget,
        in capturesFolder: URL,
        takenAt: Date,
        fileManager: FileManager
    ) throws -> ScreencastScreenshot {
        let folder: URL
        do {
            folder = try ScreencastCaptureFolder.create(in: capturesFolder, startedAt: takenAt, fileManager: fileManager)
        } catch {
            throw ScreencastFailure.folderUnavailable
        }
        var saved: [ScreencastScreenshot.Image] = []
        for (index, image) in images.enumerated() {
            let file = folder.appendingPathComponent(ScreencastCaptureFolder.screenshotName(index: index))
            guard writePNG(image, to: file) else {
                try? fileManager.removeItem(at: folder)
                throw ScreencastFailure.writerFailed
            }
            saved.append(.init(file: file, pixelWidth: image.width, pixelHeight: image.height))
        }
        let screenshot = ScreencastScreenshot(folder: folder, images: saved)
        do {
            try ScreencastScreenshotMetadata(screenshot: screenshot, target: target, startedAt: takenAt).write(to: screenshot.metadataURL)
        } catch {
            logger.error("screencast screenshot meta.json not written")
        }
        return screenshot
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

/// The app's picker system: the recorder's `SCShareableContent` read, with its windows put front to
/// back, and `SCScreenshotManager` for stills.
///
/// Screenshots use `captureImage(contentFilter:configuration:)`, not `captureImage(in:)`: only a
/// content filter can leave Keybumps's windows out.
@available(macOS 15, *)
@MainActor
final class ScreenCaptureKitPickerSystem: ScreencastPickerSystem {
    /// The real system, except in the unit-test host.
    static var current: any ScreencastPickerSystem {
        UnitTestHost.isActive ? InertScreencastPickerSystem() : ScreenCaptureKitPickerSystem()
    }

    func content() async throws -> ScreencastContent {
        let content = try await ScreenCaptureKitCaptureSystem().content()
        let order = Dictionary(Self.windowList().enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Windows the window server doesn't list on screen go last; the picker skips them anyway.
        let windows = content.windows.enumerated()
            .sorted { (order[$0.element.id] ?? Int.max, $0.offset) < (order[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
        return ScreencastContent(
            displays: content.displays,
            windows: windows,
            applicationProcessIDs: content.applicationProcessIDs,
            source: content.source
        )
    }

    func transparentWindows() -> Set<CGWindowID> {
        Set(Self.windowList().filter { $0.alpha == 0 }.map(\.id))
    }

    func screenshot(_ plan: ScreencastScreenshotPlan, content: ScreencastContent) async throws -> CGImage {
        let filter: SCContentFilter
        let configuration = ScreenCaptureKitCaptureSystem.streamConfiguration(plan.configuration)
        switch plan.filter {
        case .display(let displayPlan):
            filter = try ScreenCaptureKitCaptureSystem.filter(for: displayPlan, in: content)
        case .window(let id):
            guard let window = (content.source as? SCShareableContent)?.windows.first(where: { $0.windowID == id }) else {
                throw ScreencastFailure.targetUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            // The window's own size and scale, as ScreenCaptureKit measures them now.
            let scale = CGFloat(max(filter.pointPixelScale, 1))
            configuration.width = Int((filter.contentRect.width * scale).rounded(.up))
            configuration.height = Int((filter.contentRect.height * scale).rounded(.up))
            configuration.sourceRect = .zero
        }
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenCaptureKitCaptureSystem.failure(for: error)
        }
    }

    /// The window server's on-screen windows, front to back: their numbers and alpha only, never a
    /// name or an owner.
    static func windowList() -> [(id: CGWindowID, alpha: Double)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (CGWindowID(number.uint32Value), (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }
}

/// A picker system that reads nothing: the unit-test host's default.
@MainActor
final class InertScreencastPickerSystem: ScreencastPickerSystem {
    func content() async throws -> ScreencastContent {
        throw ScreencastFailure.captureFailed
    }

    func transparentWindows() -> Set<CGWindowID> { [] }

    func screenshot(_ plan: ScreencastScreenshotPlan, content: ScreencastContent) async throws -> CGImage {
        throw ScreencastFailure.captureFailed
    }
}
