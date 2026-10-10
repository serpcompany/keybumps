import AppKit
import Foundation
import Testing
@testable import Keybumps

/// Screencast's drawing model and how it draws: marks for each tool, fading by a made-up clock,
/// staying, clearing, and undo, and the pixels a mark leaves. Nothing here makes a window.
@MainActor
@Suite("Screencast: drawing")
struct ScreencastDrawingTests {
    nonisolated static let display: CGDirectDisplayID = 1
    nonisolated static let other: CGDirectDisplayID = 2

    /// Draws one mark from `points` with `style`, the pointer lifting at `now`.
    @discardableResult
    func draw(
        _ points: [CGPoint],
        style: ScreencastDrawingStyle = ScreencastDrawingStyle(),
        on display: CGDirectDisplayID = Self.display,
        at now: TimeInterval = 100,
        into drawing: inout ScreencastDrawing
    ) -> ScreencastMark? {
        drawing.begin(at: points[0], on: display, style: style)
        for point in points.dropFirst() { drawing.extend(to: point) }
        return drawing.finish(at: now)
    }

    // MARK: Each tool

    @Test("The pen keeps every point of the drag")
    func pen() throws {
        var drawing = ScreencastDrawing()
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 15), CGPoint(x: 40, y: 30)]
        draw(points, into: &drawing)
        let mark = try #require(drawing.marks.first)
        #expect(drawing.marks.count == 1)
        #expect(mark.kind == .pen(points))
        #expect(mark.tool == .pen && mark.color == .red && mark.lifetime == .fades)
        #expect(mark.display == Self.display)
        #expect(mark.finishedAt == 100)
        #expect(drawing.current == nil)
    }

    @Test("The highlighter keeps every point too, in a wider line")
    func highlighter() throws {
        var drawing = ScreencastDrawing()
        let points = [CGPoint(x: 10, y: 50), CGPoint(x: 200, y: 50)]
        draw(points, style: ScreencastDrawingStyle(tool: .highlighter, color: .yellow), into: &drawing)
        let mark = try #require(drawing.marks.first)
        #expect(mark.kind == .highlighter(points))
        #expect(mark.color == .yellow)
        #expect(mark.lineWidth > ScreencastDrawingTool.pen.lineWidth)
    }

    @Test("The arrow goes from where the drag started to where it ended")
    func arrow() throws {
        var drawing = ScreencastDrawing()
        draw([CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 20), CGPoint(x: 120, y: 80)],
             style: ScreencastDrawingStyle(tool: .arrow, color: .blue), into: &drawing)
        let mark = try #require(drawing.marks.first)
        #expect(mark.kind == .arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 120, y: 80)))
    }

    @Test("The rectangle spans the drag, whichever way it went")
    func rectangle() throws {
        var drawing = ScreencastDrawing()
        draw([CGPoint(x: 200, y: 150), CGPoint(x: 60, y: 40)],
             style: ScreencastDrawingStyle(tool: .rectangle, color: .green), into: &drawing)
        let mark = try #require(drawing.marks.first)
        guard case .rectangle(let start, let end) = mark.kind else {
            Issue.record("Not a rectangle: \(mark.kind)")
            return
        }
        #expect(ScreencastMark.rect(from: start, to: end) == CGRect(x: 60, y: 40, width: 140, height: 110))
    }

    @Test("A click, or a mark too small to mean anything, leaves nothing")
    func tinyMarks() {
        var drawing = ScreencastDrawing()
        for tool in ScreencastDrawingTool.allCases {
            draw([CGPoint(x: 10, y: 10)], style: ScreencastDrawingStyle(tool: tool), into: &drawing)
        }
        draw([CGPoint(x: 10, y: 10), CGPoint(x: 13, y: 12)], style: ScreencastDrawingStyle(tool: .arrow), into: &drawing)
        draw([CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 11)], style: ScreencastDrawingStyle(tool: .rectangle), into: &drawing)
        #expect(drawing.marks.isEmpty)
        #expect(drawing.isEmpty)
    }

    @Test("The pen skips a move too small to see, and says nothing needs redrawing")
    func smallSteps() throws {
        var drawing = ScreencastDrawing()
        drawing.begin(at: CGPoint(x: 10, y: 10), on: Self.display, style: ScreencastDrawingStyle())
        #expect(drawing.extend(to: CGPoint(x: 10.4, y: 10.3)) == nil)
        let extended = drawing.extend(to: CGPoint(x: 30, y: 10))
        let changed = try #require(extended)
        #expect(changed.contains(CGPoint(x: 10, y: 10)) && changed.contains(CGPoint(x: 30, y: 10)))
        #expect(drawing.current?.kind == .pen([CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)]))
    }

    @Test("A mark's bounds hold its whole line, and an arrow's head")
    func bounds() {
        let pen = ScreencastMark(display: Self.display, kind: .pen([CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10)]))
        #expect(pen.bounds.contains(CGRect(x: 8, y: 8, width: 44, height: 4)))
        let arrow = ScreencastMark(display: Self.display, kind: .arrow(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 100)))
        let head = ScreenshotAnnotationRenderer.arrowHeadLength(lineWidth: arrow.lineWidth)
        #expect(arrow.bounds.contains(CGPoint(x: 200, y: 100 + head / 2)))
        let rectangle = ScreencastMark(display: Self.display, kind: .rectangle(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 10)))
        #expect(rectangle.bounds.contains(CGRect(x: -2, y: -2, width: 14, height: 14)))
    }

    @Test("Each mark keeps the style it was drawn with")
    func styleIsPerMark() {
        var drawing = ScreencastDrawing()
        var style = ScreencastDrawingStyle(tool: .pen, color: .red, lifetime: .fades)
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)], style: style, into: &drawing)
        style = ScreencastDrawingStyle(tool: .rectangle, color: .white, lifetime: .stays)
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20)], style: style, into: &drawing)
        #expect(drawing.marks.map(\.tool) == [.pen, .rectangle])
        #expect(drawing.marks.map(\.color) == [.red, .white])
        #expect(drawing.marks.map(\.lifetime) == [.fades, .stays])
    }

    // MARK: Fading

    @Test("A fading mark shows fully for a few seconds, fades over half a second, then goes")
    func fading() throws {
        var drawing = ScreencastDrawing()
        let drawn = draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], at: 100, into: &drawing)
        let mark = try #require(drawn)
        let life = ScreencastDrawing.life, fade = ScreencastDrawing.fade
        #expect(life >= 2 && life <= 5, "a few seconds")

        #expect(ScreencastDrawing.opacity(of: mark, at: 100) == 1)
        #expect(ScreencastDrawing.opacity(of: mark, at: 100 + life) == 1)
        #expect(abs(ScreencastDrawing.opacity(of: mark, at: 100 + life + fade / 2) - 0.5) < 0.0001)
        #expect(ScreencastDrawing.opacity(of: mark, at: 100 + life + fade) == 0)

        #expect(drawing.fadingMarks(at: 100 + life - 0.1).isEmpty)
        #expect(drawing.fadingMarks(at: 100 + life + 0.1).map(\.id) == [mark.id])
        #expect(drawing.visibleMarks(on: Self.display, at: 100 + life + fade / 2).first?.opacity == 0.5)

        #expect(drawing.removeExpired(at: 100 + life + fade - 0.01).isEmpty)
        #expect(drawing.removeExpired(at: 100 + life + fade).map(\.id) == [mark.id])
        #expect(drawing.marks.isEmpty)
        #expect(drawing.visibleMarks(on: Self.display, at: 100 + life + fade).isEmpty)
    }

    @Test("A mark that stays never fades, and needs no ticking")
    func staying() throws {
        var drawing = ScreencastDrawing()
        let style = ScreencastDrawingStyle(lifetime: .stays)
        let drawn = draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], style: style, at: 100, into: &drawing)
        let mark = try #require(drawn)
        #expect(!drawing.needsTicking(at: 100))
        for later in [100.0, 104, 1_000, 100_000] {
            #expect(ScreencastDrawing.opacity(of: mark, at: later) == 1)
            #expect(drawing.removeExpired(at: later).isEmpty)
        }
        #expect(drawing.marks.count == 1)
    }

    @Test("A mark being drawn shows fully, however long it takes")
    func beingDrawn() throws {
        var drawing = ScreencastDrawing()
        drawing.begin(at: CGPoint(x: 0, y: 0), on: Self.display, style: ScreencastDrawingStyle())
        drawing.extend(to: CGPoint(x: 30, y: 30))
        let current = try #require(drawing.current)
        #expect(current.finishedAt == nil)
        #expect(ScreencastDrawing.opacity(of: current, at: 10_000) == 1)
        #expect(drawing.visibleMarks(on: Self.display, at: 10_000).map(\.mark.id) == [current.id])
        #expect(drawing.removeExpired(at: 10_000).isEmpty)
        // Its time starts when the pointer lifts.
        let ended = drawing.finish(at: 10_000)
        let finished = try #require(ended)
        #expect(ScreencastDrawing.opacity(of: finished, at: 10_000 + ScreencastDrawing.life) == 1)
    }

    @Test("Ticking is needed only while a fading mark is still on screen")
    func needsTicking() {
        var drawing = ScreencastDrawing()
        #expect(!drawing.needsTicking(at: 0))
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], at: 100, into: &drawing)
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], style: ScreencastDrawingStyle(lifetime: .stays), at: 100, into: &drawing)
        #expect(drawing.needsTicking(at: 100))
        #expect(drawing.needsTicking(at: 100 + ScreencastDrawing.life + 0.1))
        let gone = 100 + ScreencastDrawing.life + ScreencastDrawing.fade
        #expect(!drawing.needsTicking(at: gone))
        drawing.removeExpired(at: gone)
        #expect(drawing.marks.map(\.lifetime) == [.stays])
    }

    // MARK: Clearing and undo

    @Test("Clear removes every mark, the one being drawn too")
    func clear() {
        var drawing = ScreencastDrawing()
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], into: &drawing)
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], on: Self.other, into: &drawing)
        drawing.begin(at: CGPoint(x: 5, y: 5), on: Self.display, style: ScreencastDrawingStyle())
        drawing.extend(to: CGPoint(x: 50, y: 5))
        let removed = drawing.clear()
        #expect(removed.count == 3)
        #expect(Set(removed.map(\.display)) == [Self.display, Self.other])
        #expect(drawing.isEmpty)
        #expect(drawing.clear().isEmpty)
    }

    @Test("Undo removes the last mark, wherever it is, one at a time")
    func undo() {
        var drawing = ScreencastDrawing()
        let first = draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], into: &drawing)
        let second = draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], on: Self.other, into: &drawing)
        #expect(drawing.undo()?.id == second?.id)
        #expect(drawing.marks.map(\.id) == [first?.id].compactMap { $0 })
        #expect(drawing.undo()?.id == first?.id)
        #expect(drawing.undo() == nil)
    }

    @Test("Cancel drops the mark being drawn and keeps the rest")
    func cancel() {
        var drawing = ScreencastDrawing()
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], into: &drawing)
        drawing.begin(at: CGPoint(x: 5, y: 5), on: Self.display, style: ScreencastDrawingStyle())
        #expect(drawing.cancel() != nil)
        #expect(drawing.current == nil && drawing.marks.count == 1)
        #expect(drawing.cancel() == nil)
    }

    @Test("Each display shows only its own marks")
    func perDisplay() {
        var drawing = ScreencastDrawing()
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], on: Self.display, into: &drawing)
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], on: Self.other, into: &drawing)
        draw([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], on: Self.other, into: &drawing)
        #expect(drawing.visibleMarks(on: Self.display, at: 100).count == 1)
        #expect(drawing.visibleMarks(on: Self.other, at: 100).count == 2)
        #expect(drawing.visibleMarks(on: 99, at: 100).isEmpty)
    }

    // MARK: How marks are drawn

    /// A 100×100-point bitmap, transparent, with the origin at its top left as on screen.
    final class Canvas {
        static let size = 100
        let context: CGContext

        init() {
            context = CGContext(
                data: nil, width: Self.size, height: Self.size, bitsPerComponent: 8, bytesPerRow: Self.size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.translateBy(x: 0, y: CGFloat(Self.size))
            context.scaleBy(x: 1, y: -1)
        }

        /// Red, green, blue, and alpha at a top-left point, 0…255, premultiplied.
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            let offset = (y * Self.size + x) * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]), Int(data[offset + 3]))
        }
    }

    @Test("A rectangle draws its edge in its color and leaves its middle clear")
    func rectanglePixels() {
        let canvas = Canvas()
        let mark = ScreencastMark(display: Self.display, kind: .rectangle(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80)), color: .red)
        ScreencastDrawingRenderer.draw(mark, opacity: 1, in: canvas.context)
        let edge = canvas.pixel(20, 50)
        #expect(edge.a == 255 && edge.r > 200 && edge.g < 120 && edge.b < 120, "\(edge)")
        #expect(canvas.pixel(50, 50).a == 0)
        #expect(canvas.pixel(5, 5).a == 0)
    }

    @Test("The highlighter shows what's under it; a mark at half strength draws half as strongly")
    func translucency() {
        let highlighter = Canvas()
        let mark = ScreencastMark(display: Self.display, kind: .highlighter([CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)]), color: .yellow)
        ScreencastDrawingRenderer.draw(mark, opacity: 1, in: highlighter.context)
        let marked = highlighter.pixel(50, 50).a
        #expect(marked > 40 && marked < 140, "\(marked)")

        let fading = Canvas()
        let pen = ScreencastMark(display: Self.display, kind: .pen([CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)]), color: .blue)
        ScreencastDrawingRenderer.draw(pen, opacity: 0.5, in: fading.context)
        let half = fading.pixel(50, 50).a
        #expect(half > 110 && half < 145, "\(half)")
    }

    @Test("An arrow draws its head at its end; a mark that's faded out draws nothing")
    func arrowAndGone() {
        let canvas = Canvas()
        let arrow = ScreencastMark(display: Self.display, kind: .arrow(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 90, y: 50)), color: .green)
        ScreencastDrawingRenderer.draw(arrow, opacity: 1, in: canvas.context)
        // The head is wider than the shaft just behind the tip.
        #expect(canvas.pixel(82, 50).a == 255)
        #expect(canvas.pixel(82, 54).a > 0, "the head")
        #expect(canvas.pixel(30, 54).a == 0, "the shaft is narrow")

        let gone = Canvas()
        ScreencastDrawingRenderer.draw(arrow, opacity: 0, in: gone.context)
        #expect(gone.pixel(50, 50).a == 0)
    }

    // MARK: Names

    @Test("Every tool, color, and lifetime has its own name, and every tool's symbol is one macOS has")
    func names() {
        #expect(Set(ScreencastDrawingTool.allCases.map(\.title)).count == ScreencastDrawingTool.allCases.count)
        #expect(Set(ScreencastDrawingColor.allCases.map(\.title)).count == ScreencastDrawingColor.allCases.count)
        #expect(ScreencastMarkLifetime.allCases.map(\.title) == ["Fade", "Stay"])
        #expect(ScreencastDrawingColor.allCases.count >= 3)
        for tool in ScreencastDrawingTool.allCases {
            #expect(NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: nil) != nil, "\(tool.systemImage)")
        }
        let defaults = ScreencastDrawingStyle()
        #expect(defaults.tool == .pen && defaults.color == .red && defaults.lifetime == .fades)
    }
}
