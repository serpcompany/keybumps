// Renders the release disk image's window background (#437) at 1x and 2x: the site's near-black
// with a lavender glow, and a lit powder tray that holds Keybumps, chevrons, and Applications.
// The tray keeps the area behind Finder's labels light, so its dark labels stay readable.
// dmg-settings.py places the icons at the centers below, so keep the two in step.
//
// usage (from the repository root): swift apps/macos/scripts/dmg/render-background.swift apps/macos/scripts/dmg
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift \(arguments[0]) <output directory>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])

// The window's content size in points, and the icon centers dmg-settings.py uses. Finder's tab
// bar and path bar are global settings that a disk image can't turn off, and on macOS 26 they take
// about 70pt from the bottom, so everything that matters sits in the top 330pt and the rest is sky.
let width: CGFloat = 640
let height: CGFloat = 410
let iconY: CGFloat = 200
let appX: CGFloat = 170
let applicationsX: CGFloat = 470

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
// Brand and site tokens.
let powder = hex(0xFAF7F0)
let lavender = hex(0xAA9CFF)
let deepLavender = hex(0x7A67F2)
let muted = hex(0xA3A1A8)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [NSColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations)!
}

func render(scale: CGFloat) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Points in, pixels out: Finder reads the 2x image's size from its DPI.
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    // Draw top-down, like Finder's icon positions.
    cg.translateBy(x: 0, y: height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // Night sky: near-black, a touch of violet at the top.
    cg.drawLinearGradient(gradient([hex(0x1A1824), hex(0x0D0D0F)]),
                          start: .zero, end: CGPoint(x: 0, y: height), options: [])
    // Aurora behind the headline, and a low ember at each side.
    cg.drawRadialGradient(gradient([lavender.withAlphaComponent(0.34), lavender.withAlphaComponent(0)]),
                          startCenter: CGPoint(x: width / 2, y: -30), startRadius: 0,
                          endCenter: CGPoint(x: width / 2, y: -30), endRadius: 300, options: [])
    for x in [CGFloat(-40), width + 40] {
        cg.drawRadialGradient(gradient([deepLavender.withAlphaComponent(0.22), deepLavender.withAlphaComponent(0)]),
                              startCenter: CGPoint(x: x, y: 210), startRadius: 0,
                              endCenter: CGPoint(x: x, y: 210), endRadius: 200, options: [])
    }
    // A fine dot grid that fades out toward the bottom.
    for row in 0..<23 {
        for col in 0..<41 {
            let y = 8 + CGFloat(row) * 16, x = 8 + CGFloat(col) * 16
            let a = 0.07 * max(0, 1 - y / 200)
            if a <= 0.005 { continue }
            cg.setFillColor(hex(0xFFFFFF, a).cgColor)
            cg.fillEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
        }
    }

    // Copy.
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    NSAttributedString(string: "Drag Keybumps into your Applications folder", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: powder,
        .kern: -0.4, .paragraphStyle: center,
    ]).draw(in: CGRect(x: 0, y: 30, width: width, height: 30))
    NSAttributedString(string: "The last time you’ll ever have to use your mouse", attributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: muted, .paragraphStyle: center,
    ]).draw(in: CGRect(x: 0, y: 64, width: width, height: 18))

    // The tray: a lit powder slab with a lavender halo and a deep drop shadow.
    let tray = CGRect(x: 44, y: 110, width: width - 88, height: 196)
    let trayPath = CGPath(roundedRect: tray, cornerWidth: 22, cornerHeight: 22, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 0), blur: 46, color: lavender.withAlphaComponent(0.45).cgColor)
    cg.addPath(trayPath); cg.setFillColor(powder.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: hex(0x000000, 0.55).cgColor)
    cg.addPath(trayPath); cg.setFillColor(powder.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(trayPath); cg.clip()
    cg.drawLinearGradient(gradient([hex(0xFFFDF8), powder, hex(0xF1EDE5)], [0, 0.45, 1]),
                          start: CGPoint(x: 0, y: tray.minY), end: CGPoint(x: 0, y: tray.maxY), options: [])
    // A faint lavender wash across the middle, under the chevrons.
    cg.drawRadialGradient(gradient([lavender.withAlphaComponent(0.16), lavender.withAlphaComponent(0)]),
                          startCenter: CGPoint(x: width / 2, y: iconY), startRadius: 0,
                          endCenter: CGPoint(x: width / 2, y: iconY), endRadius: 150, options: [])
    // Soft contact shadows that seat each icon on the tray.
    for x in [appX, applicationsX] {
        cg.saveGState()
        cg.translateBy(x: x, y: iconY + 58)
        cg.scaleBy(x: 1, y: 0.16)
        cg.drawRadialGradient(gradient([hex(0x3A3150, 0.22), hex(0x3A3150, 0)]),
                              startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 62, options: [])
        cg.restoreGState()
    }
    cg.restoreGState()
    // Rim light along the tray's top edge, and a hairline all round.
    cg.saveGState()
    cg.addPath(trayPath); cg.clip()
    let rim = CGPath(roundedRect: tray.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 21.5, cornerHeight: 21.5, transform: nil)
    cg.addPath(rim); cg.setStrokeColor(hex(0xFFFFFF, 0.9).cgColor); cg.setLineWidth(1); cg.strokePath()
    cg.restoreGState()
    cg.addPath(trayPath); cg.setStrokeColor(lavender.withAlphaComponent(0.35).cgColor); cg.setLineWidth(0.75); cg.strokePath()

    // Three chevrons that brighten toward Applications.
    let tints = [hex(0xD9D2FF), hex(0xB1A4FF), deepLavender]
    for (i, tint) in tints.enumerated() {
        let cx = width / 2 - 26 + CGFloat(i) * 26
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: cx - 6, y: iconY - 13))
        chevron.addLine(to: CGPoint(x: cx + 7, y: iconY))
        chevron.addLine(to: CGPoint(x: cx - 6, y: iconY + 13))
        cg.addPath(chevron)
        cg.setStrokeColor(tint.cgColor)
        cg.setLineWidth(4.5); cg.setLineCap(.round); cg.setLineJoin(.round)
        cg.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@\(Int(scale))x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try render(scale: 1)
try render(scale: 2)
