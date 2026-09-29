// Renders a built Keybumps.app's icon (compiled from Keybumps.icon) at every macOS icon size,
// for the brand pack's brand/apple/macos/png and Keybumps.icns.
// usage: swift scripts/render-app-icon.swift <Keybumps.app> <output.iconset>
//        iconutil -c icns <output.iconset> -o brand/apple/macos/Keybumps.icns
import AppKit
let app = CommandLine.arguments[1], out = CommandLine.arguments[2]
let icon = NSWorkspace.shared.icon(forFile: app)
for (point, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = point * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    }
}
