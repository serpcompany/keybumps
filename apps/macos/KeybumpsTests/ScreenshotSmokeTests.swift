import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Keybumps

/// The QA smoke test's screenshots (#491), taken through the real `ScreenshotCapturer`, watcher,
/// and Clipboard History with a stand-in for `screencapture` that writes made-up PNGs, on made-up
/// displays, in a temporary folder. Nothing here captures the screen, reads the screenshot folder
/// or the Desktop, or writes to the real pasteboard: the real path runs only on an installed QA
/// candidate (`apps/macos/scripts/smoke-screengrabs.sh`).
@MainActor
@Suite("Screengrabs: the QA smoke test's screenshots")
struct ScreenshotSmokeTests {
    /// The main display, 320 × 200 points at 2 pixels a point, and one on its right at 1.
    nonisolated static let main = ScreenshotSmokeDisplay(frame: CGRect(x: 0, y: 0, width: 320, height: 200), scale: 2)
    nonisolated static let side = ScreenshotSmokeDisplay(frame: CGRect(x: 320, y: 0, width: 200, height: 100), scale: 1)

    let folder = TemporaryCapturesFolder()
    var screenshotsFolder: URL { folder.url.appendingPathComponent("screenshots", isDirectory: true) }
    var clipboardFolder: URL { folder.url.appendingPathComponent("clipboard", isDirectory: true) }

    @available(macOS 15, *)
    static var quick: ScreenshotSmokeRunner.Configuration {
        ScreenshotSmokeRunner.Configuration(captureTimeout: 2, listTimeout: 4, pollInterval: .milliseconds(20))
    }

    @available(macOS 15, *)
    func makeRunner(
        tool: FakeScreencaptureTool,
        displays: [ScreenshotSmokeDisplay] = [Self.main, Self.side],
        configuration: ScreenshotSmokeRunner.Configuration? = nil,
        screenshotsFolder: URL? = nil
    ) -> ScreenshotSmokeRunner {
        let environment = ScreenshotSmokeRunner.Environment(
            screenshotsFolder: screenshotsFolder ?? self.screenshotsFolder,
            clipboardFolder: clipboardFolder,
            runner: tool,
            displays: displays
        )
        return ScreenshotSmokeRunner(configuration: configuration ?? Self.quick, environment: environment)
    }

    // MARK: Running

    @available(macOS 15, *)
    @Test("A file of each display, then an area through -R, each a checked PNG ⌘3 would list, all deleted after")
    func passes() async throws {
        defer { folder.remove() }
        let tool = FakeScreencaptureTool(displays: [Self.main, Self.side])
        let runner = makeRunner(tool: tool)
        var updates: [[ScreenshotSmokeRunner.Line]] = []
        runner.onChange = { updates.append($0) }

        let lines = await runner.run()

        #expect(lines.map(\.kind) == [.screen, .screen, .area])
        #expect(lines.map(\.display) == [1, 2, 1])
        #expect(lines.map(\.displayCount) == [2, 2, 1])
        for line in lines {
            #expect(line.passed && line.stage == .cleanedUp && line.errorCategory == nil, "\(line)")
            #expect(line.pixelWidth == line.expectedPixelWidth && line.pixelHeight == line.expectedPixelHeight, "\(line)")
            #expect((line.bytes ?? 0) > 0 && line.captureMs != nil && line.listMs != nil, "\(line)")
        }
        let sizes = lines.map { ScreenshotSmokePixelSize(width: $0.pixelWidth ?? 0, height: $0.pixelHeight ?? 0) }
        let expectedSizes = [
            ScreenshotSmokePixelSize(width: 640, height: 400),
            ScreenshotSmokePixelSize(width: 200, height: 100),
            ScreenshotSmokePixelSize(width: 320, height: 200),
        ]
        #expect(sizes == expectedSizes, "each display's pixels, and the 160 × 100-point area at the main display's 2")
        #expect(updates.last == lines, "the last update is the result")

        // Screen as Screenshot Screen takes it, then the area from the main display's top left;
        // every file in the smoke test's own folder.
        #expect(tool.arguments.count == 2)
        let screens = tool.arguments.first ?? []
        let area = tool.arguments.last ?? []
        #expect(Array(screens.prefix(2)) == ["-t", "png"] && screens.count == 4, "\(screens)")
        #expect(Array(area.prefix(4)) == ["-R", "80,50,160,100", "-t", "png"] && area.count == 5, "\(area)")
        let files = tool.arguments.flatMap { $0.filter { $0.hasSuffix(".png") } }
        let inFolder = files.allSatisfy { URL(fileURLWithPath: $0).deletingLastPathComponent().path == screenshotsFolder.path }
        #expect(files.count == 3 && inFolder, "\(files)")

        // The screenshots, the Clipboard History, and its copies are gone.
        #expect(!FileManager.default.fileExists(atPath: screenshotsFolder.path))
        #expect(!FileManager.default.fileExists(atPath: clipboardFolder.path))
    }

    @available(macOS 15, *)
    @Test("A file of the wrong size, one that isn't a PNG, an unmarked one, and one never written each fail with their reason, and are still deleted")
    func failures() async throws {
        defer { folder.remove() }
        let third = ScreenshotSmokeDisplay(frame: CGRect(x: -100, y: 0, width: 100, height: 80), scale: 1)
        let tool = FakeScreencaptureTool(displays: [Self.main, Self.side, third])
        tool.screenOutputs = [1: .wrongSize, 2: .notPNG]
        tool.areaOutput = .nothing
        let runner = makeRunner(tool: tool, displays: [Self.main, Self.side, third])

        let lines = await runner.run()

        let categories = lines.map(\.errorCategory)
        #expect(categories == [nil, "wrongSize", "notPNG", "missingFile"], "\(categories)")
        #expect(lines.map(\.stage) == [.cleanedUp, .saved, .saved, .capturing])
        #expect(lines.map(\.passed) == [true, false, false, false])
        #expect(lines[1].expectedPixelWidth == 200 && lines[1].pixelWidth == 201, "the size read, beside the one expected")
        #expect(!FileManager.default.fileExists(atPath: screenshotsFolder.path))

        let unmarked = ScreenshotSmokeTests()
        defer { unmarked.folder.remove() }
        let readOnly = FakeScreencaptureTool(displays: [Self.main])
        readOnly.screenOutputs = [0: .readOnly]
        let marked = await unmarked.makeRunner(tool: readOnly, displays: [Self.main]).run()
        #expect(marked.map(\.errorCategory) == ["notMarkedAsScreenCapture", nil], "a file the capturer couldn't mark")
        #expect(!FileManager.default.fileExists(atPath: unmarked.screenshotsFolder.path))
    }

    @available(macOS 15, *)
    @Test("A screencapture that never finishes times out, and the area is still taken")
    func hang() async throws {
        defer { folder.remove() }
        let tool = FakeScreencaptureTool(displays: [Self.main, Self.side])
        tool.holdsScreens = true
        var configuration = Self.quick
        configuration.captureTimeout = 0.2
        let lines = await makeRunner(tool: tool, configuration: configuration).run()

        #expect(lines.prefix(2).allSatisfy { $0.stage == .capturing && $0.errorCategory == "timeout" })
        #expect(lines.last?.passed == true, "\(String(describing: lines.last))")
        tool.releaseHeld()
    }

    @available(macOS 15, *)
    @Test("Where the smoke test's folder can't be made, nothing is captured and nothing else is watched")
    func noFolder() async throws {
        defer { folder.remove() }
        let blocker = folder.url.appendingPathComponent("blocker")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("file".utf8))
        let tool = FakeScreencaptureTool(displays: [Self.main])
        let lines = await makeRunner(tool: tool, displays: [Self.main], screenshotsFolder: blocker.appendingPathComponent("screenshots")).run()

        #expect(lines.allSatisfy { $0.stage == .notStarted && $0.errorCategory == "watcherUnavailable" })
        #expect(tool.arguments.isEmpty)

        // The watcher's folder is the smoke test's own; without it, a Desktop inside it, never
        // the person's.
        let resolver = ScreenshotSmokeRunner.resolver(watching: screenshotsFolder, fileManager: .default)
        #expect(resolver.resolve().path == screenshotsFolder.appendingPathComponent("Desktop").path)
        try FileManager.default.createDirectory(at: screenshotsFolder, withIntermediateDirectories: true)
        #expect(resolver.resolve().path == screenshotsFolder.path)
    }

    // MARK: Checks

    @Test("Screen files match the main display first, then the displays left in any order; an area is placed from the main display's top left")
    func sizes() {
        let third = ScreenshotSmokeDisplay(frame: CGRect(x: -100, y: 0, width: 100, height: 80), scale: 1)
        let displays = [Self.main, Self.side, third]
        let swapped: [ScreenshotSmokePixelSize?] = [Self.main.pixelSize, third.pixelSize, Self.side.pixelSize]
        let expected = ScreenshotSmokeChecks.expectedScreenSizes(read: swapped, displays: displays)
        #expect(expected == swapped)

        let wrong = ScreenshotSmokePixelSize(width: 1, height: 1)
        let unread: [ScreenshotSmokePixelSize?] = [wrong, nil, third.pixelSize]
        let filled = ScreenshotSmokeChecks.expectedScreenSizes(read: unread, displays: displays)
        #expect(filled == [Self.main.pixelSize, Self.side.pixelSize, third.pixelSize])

        let area = ScreenshotSmokeChecks.area(in: CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(area == CGRect(x: 436, y: 311, width: 640, height: 360))
        let topLeft = ScreenshotSmokeChecks.fromTopLeft(CGRect(x: 10, y: 20, width: 30, height: 40), main: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(topLeft == CGRect(x: 10, y: 40, width: 30, height: 40))
        #expect(ScreenshotSmokeChecks.pixelSize(of: CGSize(width: 1512, height: 982), scale: 2) == ScreenshotSmokePixelSize(width: 3024, height: 1964))
    }

    @Test("A check reads a real PNG's size, and fails one that isn't a PNG, is the wrong size, or isn't marked")
    func checks() throws {
        defer { folder.remove() }
        let png = folder.url.appendingPathComponent("shot.png")
        let data = try #require(FakeScreencaptureTool.png(width: 64, height: 36, shade: 10))
        try data.write(to: png)
        let facts = try #require(ScreenshotSmokeChecks.facts(of: png))
        let size = ScreenshotSmokePixelSize(width: 64, height: 36)
        #expect(facts == ScreenshotSmokeImageFacts(isPNG: true, pixelSize: size))
        #expect(throws: Never.self) { try ScreenshotSmokeChecks.check(facts, expected: size, isMarked: true) }
        #expect(throws: ScreencastSmokeFailure.wrongSize) {
            try ScreenshotSmokeChecks.check(facts, expected: ScreenshotSmokePixelSize(width: 64, height: 37), isMarked: true)
        }
        #expect(throws: ScreencastSmokeFailure.notMarkedAsScreenCapture) { try ScreenshotSmokeChecks.check(facts, expected: size, isMarked: false) }
        #expect(throws: ScreencastSmokeFailure.notPNG) { try ScreenshotSmokeChecks.check(nil, expected: size, isMarked: true) }
        #expect(!ScreenshotSmokeChecks.isMarkedAsScreenCapture(png))

        let garbage = folder.url.appendingPathComponent("garbage.png")
        FileManager.default.createFile(atPath: garbage.path, contents: Data("picture".utf8))
        let garbageFacts = ScreenshotSmokeChecks.facts(of: garbage)
        #expect(garbageFacts == nil || garbageFacts?.isPNG == false)
    }

    @Test("Each screenshot planned: one of every display, then an area on the main one")
    func planned() {
        let lines = ScreencastSmokeReport.Screenshot.planned(displayCount: 3)
        #expect(lines.map(\.kind) == [.screen, .screen, .screen, .area])
        #expect(lines.map(\.display) == [1, 2, 3, 1])
        #expect(lines.map(\.displayCount) == [3, 3, 3, 1])
        let none = ScreencastSmokeReport.Screenshot.planned(displayCount: 0)
        #expect(none.map(\.kind) == [.screen, .area], "a capture writes at least one file")
    }
}

/// Stands in for `screencapture`: writes a made-up PNG of each display's size at each path it's
/// given, or for `-R`, one of the area's size at the main display's scale, then finishes. It
/// notes its arguments, and can write the wrong file, nothing, or a file it can't be marked, or
/// hold a Screen capture until released.
final class FakeScreencaptureTool: ScreenshotCaptureRunning {
    enum Output {
        case png
        case wrongSize
        case notPNG
        case nothing
        /// A PNG whose permissions keep the capturer from marking it.
        case readOnly
    }

    let displays: [ScreenshotSmokeDisplay]
    /// How each Screen file is written, by its place among the files; the rest are PNGs.
    var screenOutputs: [Int: Output] = [:]
    var areaOutput = Output.png
    var holdsScreens = false
    private(set) var arguments: [[String]] = []
    private var held: [@MainActor () -> Void] = []

    init(displays: [ScreenshotSmokeDisplay]) {
        self.displays = displays
    }

    func run(arguments: [String], completion: @escaping @MainActor () -> Void) {
        self.arguments.append(arguments)
        let files = arguments.filter { $0.hasSuffix(".png") }
        if let index = arguments.firstIndex(of: "-R"), index + 1 < arguments.count {
            let size = areaSize(arguments[index + 1])
            for file in files { write(areaOutput, size: size, shade: 200, to: file) }
        } else {
            if holdsScreens {
                held.append(completion)
                return
            }
            for (index, file) in files.enumerated() {
                let size = index < displays.count ? displays[index].pixelSize : ScreenshotSmokePixelSize(width: 8, height: 8)
                write(screenOutputs[index] ?? .png, size: size, shade: UInt8(20 * (index + 1)), to: file)
            }
        }
        Task { @MainActor in completion() }
    }

    /// Finishes the held captures.
    @MainActor
    func releaseHeld() {
        let completions = held
        held = []
        completions.forEach { $0() }
    }

    private func areaSize(_ rectangle: String) -> ScreenshotSmokePixelSize {
        let values = rectangle.split(separator: ",").compactMap { Double($0) }
        let scale = displays.first?.scale ?? 1
        guard values.count == 4 else { return ScreenshotSmokePixelSize(width: 0, height: 0) }
        return ScreenshotSmokeChecks.pixelSize(of: CGSize(width: values[2], height: values[3]), scale: scale)
    }

    private func write(_ output: Output, size: ScreenshotSmokePixelSize, shade: UInt8, to path: String) {
        switch output {
        case .png, .readOnly:
            FileManager.default.createFile(atPath: path, contents: Self.png(width: size.width, height: size.height, shade: shade))
            if output == .readOnly { chmod(path, 0o444) }
        case .wrongSize:
            FileManager.default.createFile(atPath: path, contents: Self.png(width: size.width + 1, height: size.height, shade: shade))
        case .notPNG:
            FileManager.default.createFile(atPath: path, contents: Data("not a picture".utf8))
        case .nothing:
            break
        }
    }

    /// A PNG of one shade, so files of the same size still differ by their shade.
    static func png(width: Int, height: Int, shade: UInt8) -> Data? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let gray = CGFloat(shade) / 255
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
