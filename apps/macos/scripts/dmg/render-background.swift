// Renders the release disk image's window background (#437): Keybumps on the left, an arrow, and
// Applications on the right, at 1x and 2x. dmg-settings.py places the icons over the gaps this
// leaves, so keep the two in step.
//
// usage (from the repository root): swift apps/macos/scripts/dmg/render-background.swift apps/macos/scripts/dmg
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift \(arguments[0]) <output directory>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])

// The window's content size in points, and the icon centers dmg-settings.py uses.
let width: CGFloat = 640
let height: CGFloat = 400
let iconY: CGFloat = 190
let appX: CGFloat = 170
let applicationsX: CGFloat = 470

// Brand tokens (brand/tokens/brand-tokens.json).
let powder = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF0 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x1B / 255, green: 0x1B / 255, blue: 0x1C / 255, alpha: 1)
let lavender = NSColor(srgbRed: 0xAA / 255, green: 0x9C / 255, blue: 0xFF / 255, alpha: 1)

func render(scale: CGFloat) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Points in, pixels out: Finder reads the 2x image's size from its DPI.
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    // AppKit's origin is bottom-left; Finder's icon positions are from the top-left.
    func flipped(_ y: CGFloat) -> CGFloat { height - y }

    powder.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // The arrow from Keybumps to Applications.
    let arrow = NSBezierPath()
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    let start = appX + 100
    let end = applicationsX - 100
    arrow.move(to: NSPoint(x: start, y: flipped(iconY)))
    arrow.line(to: NSPoint(x: end, y: flipped(iconY)))
    arrow.move(to: NSPoint(x: end - 16, y: flipped(iconY) + 16))
    arrow.line(to: NSPoint(x: end, y: flipped(iconY)))
    arrow.line(to: NSPoint(x: end - 16, y: flipped(iconY) - 16))
    lavender.setStroke()
    arrow.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let title = NSAttributedString(string: "Install Keybumps", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: ink, .paragraphStyle: paragraph,
    ])
    title.draw(in: NSRect(x: 0, y: flipped(68), width: width, height: 30))
    let instruction = NSAttributedString(string: "Drag Keybumps onto Applications.", attributes: [
        .font: NSFont.systemFont(ofSize: 15), .foregroundColor: ink.withAlphaComponent(0.7), .paragraphStyle: paragraph,
    ])
    instruction.draw(in: NSRect(x: 0, y: flipped(352), width: width, height: 22))

    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@\(Int(scale))x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try render(scale: 1)
try render(scale: 2)
