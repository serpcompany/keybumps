import AppKit

/// Draws marks into a context with a top-left origin, in display points: the drawing layer's view
/// on screen, and tests that read the pixels. Arrows are the Screenshot Editor's
/// (`ScreenshotAnnotationRenderer.drawArrow`), so both draw the same arrow.
@MainActor
enum ScreencastDrawingRenderer {
    /// How much of the highlighter's color shows: enough to mark something, little enough that
    /// what's under it still reads.
    static let highlighterAlpha: CGFloat = 0.35

    static func draw(_ visible: ScreencastVisibleMark, in ctx: CGContext) {
        draw(visible.mark, opacity: visible.opacity, in: ctx)
    }

    static func draw(_ mark: ScreencastMark, opacity: Double, in ctx: CGContext) {
        guard opacity > 0 else { return }
        let color = mark.color.nsColor.usingColorSpace(.sRGB)?.cgColor ?? mark.color.nsColor.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // A fading arrow's shaft and head fade as one, not as two overlapping parts.
        let fades = opacity < 1
        if fades {
            ctx.setAlpha(CGFloat(opacity))
            ctx.beginTransparencyLayer(in: mark.bounds, auxiliaryInfo: nil)
        }
        defer { if fades { ctx.endTransparencyLayer() } }

        switch mark.kind {
        case .pen(let points):
            stroke(points, color: color, lineWidth: mark.lineWidth, in: ctx)
        case .highlighter(let points):
            // One stroke for the whole line, so where it crosses itself isn't any darker.
            stroke(points, color: color.copy(alpha: highlighterAlpha) ?? color, lineWidth: mark.lineWidth, in: ctx)
        case .arrow(let start, let end):
            ScreenshotAnnotationRenderer.drawArrow(from: start, to: end, lineWidth: mark.lineWidth, color: color, in: ctx)
        case .rectangle(let start, let end):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(mark.lineWidth)
            ctx.setLineJoin(.round)
            ctx.stroke(ScreencastMark.rect(from: start, to: end))
        }
    }

    private static func stroke(_ points: [CGPoint], color: CGColor, lineWidth: CGFloat, in ctx: CGContext) {
        guard let first = points.first, points.count > 1 else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: first)
        for point in points.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()
    }
}
