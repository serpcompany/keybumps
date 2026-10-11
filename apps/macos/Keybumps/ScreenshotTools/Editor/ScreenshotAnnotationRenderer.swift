import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The image being edited: its pixels and how many pixels make an image point.
struct ScreenshotRenderSource {
    let cgImage: CGImage
    let pointSize: CGSize
    let density: CGFloat

    var pixelBounds: CGRect { CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height) }

    init(cgImage: CGImage, pointSize: CGSize) {
        self.cgImage = cgImage
        self.pointSize = pointSize
        let density = max(CGFloat(cgImage.width) / max(pointSize.width, 1), CGFloat(cgImage.height) / max(pointSize.height, 1))
        self.density = max(density, 0.25)
    }

    /// Decodes image data, honoring its DPI so a Retina screenshot edits at screen scale.
    init?(imageData: Data) {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = max(CGFloat(dpi) / 72, 1)
        self.init(
            cgImage: cgImage,
            pointSize: CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
    }

    /// Image-point rect → the whole source pixels covering it (top-left origin).
    func pixelRect(covering rect: CGRect) -> CGRect {
        let minX = floor(rect.minX * density + 0.001)
        let minY = floor(rect.minY * density + 0.001)
        let maxX = ceil(rect.maxX * density - 0.001)
        let maxY = ceil(rect.maxY * density - 0.001)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
            .intersection(pixelBounds)
    }

    func pointRect(forPixels rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / density, y: rect.minY / density, width: rect.width / density, height: rect.height / density)
    }
}

/// Draws an annotated image into a top-left-origin context in image points.
/// The canvas and export share this path, so what you see is what is copied.
/// Redaction rendering is adapted from Shotnix (MIT); see docs/provenance/donor-ledger.md.
@MainActor
final class ScreenshotAnnotationRenderer {
    /// Pixelate block size in points; never smaller than `minimumPixelateBlock`
    /// so text under a mosaic cannot be recovered.
    static let pixelateBlock: CGFloat = 14
    static let minimumPixelateBlock: CGFloat = 10
    static let redactColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let failureFill = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    private struct TileKey: Hashable {
        let minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat
        init(_ rect: CGRect) { minX = rect.minX; minY = rect.minY; width = rect.width; height = rect.height }
    }

    private struct Tile {
        let image: CGImage
        let fill: CGColor
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var tileCache: [TileKey: Tile] = [:]
    /// Test seam: force the pixelate filter to fail to exercise the opaque fallback.
    var pixelateFilterOverride: ((CGImage) -> CGImage?)?

    func draw(source: ScreenshotRenderSource, annotations: [ScreenshotAnnotation], in ctx: CGContext) {
        Self.drawUpright(source.cgImage, in: CGRect(origin: .zero, size: source.pointSize), context: ctx)

        let imageBounds = CGRect(origin: .zero, size: source.pointSize)
        ctx.saveGState()
        ctx.clip(to: imageBounds)
        var usedTiles: Set<TileKey> = []
        for annotation in annotations where annotation.isRedaction {
            switch annotation.kind {
            case .pixelate(let rect):
                if let key = drawPixelate(rect: rect, source: source, in: ctx) { usedTiles.insert(key) }
            case .redact(let rect):
                ctx.setFillColor(Self.redactColor)
                ctx.fill(rect.standardized.intersection(imageBounds))
            case .arrow, .freehand, .text:
                break
            }
        }
        ctx.restoreGState()
        tileCache = tileCache.filter { usedTiles.contains($0.key) }

        for annotation in annotations where !annotation.isRedaction {
            Self.drawMark(annotation, in: ctx)
        }
    }

    /// Renders at the source's own pixel density, never the display's.
    func export(source: ScreenshotRenderSource, annotations: [ScreenshotAnnotation]) -> CGImage? {
        let width = source.cgImage.width
        let height = source.cgImage.height
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let space = source.cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = makeContext(space) ?? makeContext(sRGB) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: source.density, y: -source.density)
        draw(source: source, annotations: annotations, in: ctx)
        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage, density: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * density
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Redaction

    /// Mosaics the source pixels under `rect`. Box-average then pixellate so each
    /// block is the mean of what it covers; an opaque average fill sits underneath,
    /// and any failure paints an opaque fill instead of the original.
    private func drawPixelate(rect: CGRect, source: ScreenshotRenderSource, in ctx: CGContext) -> TileKey? {
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: source.pointSize))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let pixelRect = source.pixelRect(covering: clipped)
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        let tileRect = source.pointRect(forPixels: pixelRect)
        let key = TileKey(pixelRect)

        let tile: Tile
        if let cached = tileCache[key] {
            tile = cached
        } else if let rendered = renderPixelateTile(pixelRect: pixelRect, source: source) {
            tileCache[key] = rendered
            tile = rendered
        } else {
            ctx.setFillColor(Self.failureFill)
            ctx.fill(tileRect)
            return nil
        }
        ctx.setFillColor(tile.fill)
        ctx.fill(tileRect)
        Self.drawUpright(tile.image, in: tileRect, context: ctx)
        return key
    }

    private func renderPixelateTile(pixelRect: CGRect, source: ScreenshotRenderSource) -> Tile? {
        guard let cropped = source.cgImage.cropping(to: pixelRect) else { return nil }
        let colorSpace = cropped.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let input = CIImage(cgImage: cropped)
        let extent = input.extent
        let clamped = input.clampedToExtent()

        let image: CGImage?
        if let override = pixelateFilterOverride {
            image = override(cropped)
        } else {
            let block = max(Self.pixelateBlock, Self.minimumPixelateBlock) * source.density
            let output = clamped
                .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: max(block / 2, 1)])
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: block,
                    kCIInputCenterKey: CIVector(x: extent.minX, y: extent.maxY)
                ])
                .cropped(to: extent)
            image = Self.ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace)
        }
        guard let image else { return nil }
        return Tile(image: image, fill: averageColor(of: clamped.cropped(to: extent), colorSpace: colorSpace))
    }

    private func averageColor(of image: CIImage, colorSpace: CGColorSpace) -> CGColor {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        Self.ciContext.render(average, toBitmap: &pixel, rowBytes: 4,
                              bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                              format: .RGBA8, colorSpace: colorSpace)
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0 else { return Self.failureFill }
        let components = [CGFloat(pixel[0]) / 255 / alpha, CGFloat(pixel[1]) / 255 / alpha, CGFloat(pixel[2]) / 255 / alpha, 1]
            .map { min($0, 1) }
        return CGColor(colorSpace: colorSpace, components: components) ?? Self.failureFill
    }

    // MARK: Marks

    static func drawMark(_ annotation: ScreenshotAnnotation, in ctx: CGContext) {
        let color = annotation.color.nsColor.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch annotation.kind {
        case .arrow(let start, let end):
            drawArrow(from: start, to: end, lineWidth: annotation.lineWidth, color: color, in: ctx)
        case .freehand(let points):
            guard points.count > 1 else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(annotation.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: points[0])
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        case .text(let origin, let string):
            guard !string.isEmpty else { return }
            let attributes = textAttributes(color: annotation.color, fontSize: annotation.fontSize)
            let size = textSize(string, fontSize: annotation.fontSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            (string as NSString).draw(with: CGRect(origin: origin, size: size), options: textDrawingOptions, attributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        case .pixelate, .redact:
            break
        }
    }

    static let textDrawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static func textAttributes(color: ScreenshotAnnotationColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = (color == .white || color == .yellow) ? NSColor.black.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: color.nsColor, .shadow: shadow]
    }

    static func textSize(_ string: String, fontSize: CGFloat) -> CGSize {
        let rect = ((string.isEmpty ? " " : string) as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: textDrawingOptions,
            attributes: [.font: NSFont.boldSystemFont(ofSize: fontSize)]
        )
        return CGSize(width: ceil(rect.width) + 2, height: ceil(rect.height))
    }

    /// How long an arrow's head is for a line this wide.
    nonisolated static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        max(lineWidth * 4.5, 14)
    }

    /// An arrow from `start` to `end`: a round-capped shaft and a filled head. Screencast's drawing
    /// draws its arrows with it too, so both look the same.
    static func drawArrow(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, color: CGColor, in ctx: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let headLength = arrowHeadLength(lineWidth: lineWidth)
        let headAngle: CGFloat = .pi / 6
        let inset = min(headLength * cos(headAngle), length * 0.7)
        let shaftEnd = CGPoint(x: end.x - dx / length * inset, y: end.y - dy / length * inset)

        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let angle = atan2(dy, dx)
        ctx.setFillColor(color)
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x - headLength * cos(angle - headAngle), y: end.y - headLength * sin(angle - headAngle)))
        ctx.addLine(to: CGPoint(x: end.x - headLength * cos(angle + headAngle), y: end.y - headLength * sin(angle + headAngle)))
        ctx.closePath()
        ctx.fillPath()
    }

    static func drawUpright(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}
