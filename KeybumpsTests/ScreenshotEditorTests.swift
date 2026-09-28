import AppKit
import XCTest
@testable import Keybumps

@MainActor
final class ScreenshotEditorTests: XCTestCase {
    // MARK: History

    func testHistoryRecordsMeaningfulMarksWithUndoAndRedo() {
        var history = ScreenshotEditorHistory()
        history.add(ScreenshotAnnotation(kind: .redact(CGRect(x: 0, y: 0, width: 1, height: 1))))
        history.add(ScreenshotAnnotation(kind: .text(origin: .zero, string: "   ")))
        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(history.canUndo)

        let first = ScreenshotAnnotation(kind: .arrow(start: .zero, end: CGPoint(x: 40, y: 0)))
        let second = ScreenshotAnnotation(kind: .freehand([.zero, CGPoint(x: 5, y: 5)]))
        history.add(first)
        history.add(second)
        XCTAssertEqual(history.annotations, [first, second])

        history.undo()
        XCTAssertEqual(history.annotations, [first])
        history.redo()
        XCTAssertEqual(history.annotations, [first, second])

        history.undo()
        let third = ScreenshotAnnotation(kind: .redact(CGRect(x: 0, y: 0, width: 10, height: 10)))
        history.add(third)
        XCTAssertFalse(history.canRedo, "a new mark clears redo")
        XCTAssertEqual(history.annotations, [first, third])
    }

    func testHistoryCapsUndoSteps() {
        var history = ScreenshotEditorHistory()
        for index in 0..<(ScreenshotEditorHistory.limit + 20) {
            history.add(ScreenshotAnnotation(kind: .redact(CGRect(x: CGFloat(index), y: 0, width: 10, height: 10))))
        }
        var undos = 0
        while history.canUndo { history.undo(); undos += 1 }
        XCTAssertEqual(undos, ScreenshotEditorHistory.limit)
    }

    func testToolShortcutsAndColorUse() {
        XCTAssertEqual(ScreenshotEditorTool.allCases, [.pixelate, .redact, .arrow, .draw, .text])
        XCTAssertEqual(ScreenshotEditorTool.matching(key: "P"), .pixelate)
        XCTAssertEqual(ScreenshotEditorTool.matching(key: "t"), .text)
        XCTAssertNil(ScreenshotEditorTool.matching(key: "c"), "crop is deferred")
        XCTAssertFalse(ScreenshotEditorTool.pixelate.usesColor)
        XCTAssertFalse(ScreenshotEditorTool.redact.usesColor)
        XCTAssertTrue(ScreenshotEditorTool.arrow.usesColor)
    }

    // MARK: Output naming

    func testOutputSavesNextToSourceAndNeverOverwrites() {
        let source = URL(fileURLWithPath: "/Shots/Screenshot 1.png")
        let fallback = URL(fileURLWithPath: "/Fallback", isDirectory: true)
        var existing: Set<String> = []
        func destination() -> URL {
            ScreenshotEditorOutput.destination(sourceURL: source, fallbackFolder: fallback, isWritableDirectory: { _ in true }, exists: { existing.contains($0.path) })
        }
        XCTAssertEqual(destination().path, "/Shots/Screenshot 1 (edited).png")
        existing.insert("/Shots/Screenshot 1 (edited).png")
        XCTAssertEqual(destination().path, "/Shots/Screenshot 1 (edited 2).png")
    }

    func testOutputFallsBackForUnwritableFoldersAndCopiedImages() {
        let fallback = URL(fileURLWithPath: "/Fallback", isDirectory: true)
        let readOnly = ScreenshotEditorOutput.destination(
            sourceURL: URL(fileURLWithPath: "/ReadOnly/Shot.png"), fallbackFolder: fallback,
            isWritableDirectory: { _ in false }, exists: { _ in false }
        )
        XCTAssertEqual(readOnly.path, "/Fallback/Shot (edited).png")

        var components = DateComponents(); components.year = 2026; components.month = 9; components.day = 28
        components.hour = 9; components.minute = 41; components.second = 5
        let date = Calendar.current.date(from: components)!
        let copied = ScreenshotEditorOutput.destination(sourceURL: nil, fallbackFolder: fallback, now: date, isWritableDirectory: { _ in true }, exists: { _ in false })
        XCTAssertEqual(copied.path, "/Fallback/Image 2026-09-28 at 09.41.05 (edited).png")
    }

    // MARK: Rendering

    func testExportKeepsSourcePixelsAndDensity() throws {
        let source = ScreenshotRenderSource(cgImage: try checkerboard(width: 80, height: 60), pointSize: CGSize(width: 40, height: 30))
        XCTAssertEqual(source.density, 2)
        let exported = try XCTUnwrap(ScreenshotAnnotationRenderer().export(source: source, annotations: []))
        XCTAssertEqual(exported.width, 80)
        XCTAssertEqual(exported.height, 60)
        let png = try XCTUnwrap(ScreenshotAnnotationRenderer.pngData(exported, density: source.density))
        let reloaded = try XCTUnwrap(ScreenshotRenderSource(imageData: png))
        XCTAssertEqual(reloaded.pointSize, CGSize(width: 40, height: 30), "Retina DPI survives the round trip")
        XCTAssertEqual(try pixels(of: exported), try pixels(of: source.cgImage), "no marks means an identical image")
    }

    func testRedactBlockIsOpaqueBlackAtRetinaPixelCoordinates() throws {
        let source = ScreenshotRenderSource(cgImage: try checkerboard(width: 120, height: 120), pointSize: CGSize(width: 60, height: 60))
        let annotation = ScreenshotAnnotation(kind: .redact(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let image = try pixels(of: try XCTUnwrap(ScreenshotAnnotationRenderer().export(source: source, annotations: [annotation])))
        let original = try pixels(of: source.cgImage)
        for y in 0..<120 {
            for x in 0..<120 {
                let inside = (20..<60).contains(x) && (20..<60).contains(y)
                if inside {
                    XCTAssertEqual(image.rgba(x, y), [0, 0, 0, 255], "(\(x),\(y)) must be black")
                } else {
                    XCTAssertEqual(image.rgba(x, y), original.rgba(x, y), "(\(x),\(y)) outside the block must be untouched")
                }
            }
        }
    }

    func testPixelateNeverLeavesOriginalCheckerPixels() throws {
        let source = ScreenshotRenderSource(cgImage: try checkerboard(width: 112, height: 112), pointSize: CGSize(width: 112, height: 112))
        let region = CGRect(x: 0, y: 0, width: 56, height: 56)
        let image = try pixels(of: try XCTUnwrap(ScreenshotAnnotationRenderer().export(source: source, annotations: [ScreenshotAnnotation(kind: .pixelate(region))])))
        var distinct: Set<[UInt8]> = []
        for y in 0..<56 {
            for x in 0..<56 {
                let pixel = image.rgba(x, y)
                XCTAssertEqual(pixel[3], 255, "mosaic must be opaque")
                XCTAssertNotEqual(pixel, [0, 0, 0, 255], "original black survived at (\(x),\(y))")
                XCTAssertNotEqual(pixel, [255, 255, 255, 255], "original white survived at (\(x),\(y))")
                distinct.insert(pixel)
            }
        }
        XCTAssertLessThanOrEqual(distinct.count, 16, "a 1-pixel checker collapses to a few block averages")
        XCTAssertEqual(image.rgba(80, 80), try pixels(of: source.cgImage).rgba(80, 80), "outside the region is untouched")
    }

    func testPixelateFailureFillsOpaqueInsteadOfShowingOriginal() throws {
        let source = ScreenshotRenderSource(cgImage: try checkerboard(width: 40, height: 40), pointSize: CGSize(width: 40, height: 40))
        let renderer = ScreenshotAnnotationRenderer()
        renderer.pixelateFilterOverride = { _ in nil }
        let image = try pixels(of: try XCTUnwrap(renderer.export(source: source, annotations: [ScreenshotAnnotation(kind: .pixelate(CGRect(x: 0, y: 0, width: 20, height: 20)))])))
        let fill = image.rgba(5, 5)
        XCTAssertEqual(fill[3], 255)
        for y in 0..<20 { for x in 0..<20 { XCTAssertEqual(image.rgba(x, y), fill) } }
        XCTAssertNotEqual(fill, [0, 0, 0, 255])
        XCTAssertNotEqual(fill, [255, 255, 255, 255])
    }

    func testPixelateBlockHasAMinimumSize() {
        XCTAssertGreaterThanOrEqual(ScreenshotAnnotationRenderer.pixelateBlock, ScreenshotAnnotationRenderer.minimumPixelateBlock)
        XCTAssertGreaterThanOrEqual(ScreenshotAnnotationRenderer.minimumPixelateBlock, 10)
    }

    func testMarksDrawOverRedactionsInTheirColor() throws {
        let source = ScreenshotRenderSource(cgImage: try solid(width: 100, height: 100, gray: 255), pointSize: CGSize(width: 100, height: 100))
        let marks = [
            ScreenshotAnnotation(kind: .redact(CGRect(x: 0, y: 40, width: 100, height: 20))),
            ScreenshotAnnotation(kind: .freehand([CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100)]), color: .red, lineWidth: 6)
        ]
        let image = try pixels(of: try XCTUnwrap(ScreenshotAnnotationRenderer().export(source: source, annotations: marks)))
        let crossing = image.rgba(50, 50)
        XCTAssertGreaterThan(Int(crossing[0]), 150, "the pen stroke sits on top of the redaction")
        XCTAssertLessThan(Int(crossing[1]), 120)
        XCTAssertEqual(image.rgba(10, 50), [0, 0, 0, 255])
        XCTAssertEqual(image.rgba(10, 10), [255, 255, 255, 255])
    }

    // MARK: Helpers

    private struct Pixels: Equatable {
        let width: Int
        let bytes: [UInt8]
        func rgba(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(bytes[offset..<(offset + 4)])
        }
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func checkerboard(width: Int, height: Int) throws -> CGImage {
        let ctx = try context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for y in 0..<height { for x in 0..<width where (x + y) % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: 1, height: 1)) } }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func solid(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        let ctx = try context(width: width, height: height)
        ctx.setFillColor(CGColor(srgbRed: gray / 255, green: gray / 255, blue: gray / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Top-left-origin RGBA8 pixels in sRGB.
    private func pixels(of image: CGImage) throws -> Pixels {
        let ctx = try context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(ctx.data)
        let count = image.width * image.height * 4
        let buffer = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
        // CGContext memory is top row first, which matches image coordinates.
        return Pixels(width: image.width, bytes: buffer)
    }
}
