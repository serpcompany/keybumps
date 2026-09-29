// Renders a built Keybumps.app's icon (compiled from Keybumps.icon) at every macOS icon size, in
// the light appearance, into an .iconset folder, for the brand pack's brand/apple/macos/png and
// Keybumps.icns.
//
// usage: swift scripts/render-app-icon.swift <Keybumps.app> <output.iconset>
//        iconutil -c icns <output.iconset> -o brand/apple/macos/Keybumps.icns
//        cp <output.iconset>/*.png brand/apple/macos/png/
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift \(arguments[0]) <Keybumps.app> <output.iconset>\n".utf8))
    exit(64)
}
// A missing or wrong path would render macOS's generic document icon, so check the bundle first.
guard let bundle = Bundle(path: arguments[1]),
      bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "Keybumps" else {
    FileHandle.standardError.write(Data("\(arguments[1]) is not a built Keybumps.app\n".utf8))
    exit(66)
}
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let icon = NSWorkspace.shared.icon(forFile: arguments[1])

/// Share of pixels that are at least half opaque; a failed lookup returns a mostly clear placeholder.
func opaqueShare(_ bitmap: NSBitmapImageRep) -> Double {
    var opaque = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            opaque += 1
        }
    }
    return Double(opaque) / Double(((bitmap.pixelsWide + 3) / 4) * ((bitmap.pixelsHigh + 3) / 4))
}

NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    for point in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = point * scale
            // Asking for an explicit size makes the icon service render that size; drawing the
            // image into a bitmap returns a placeholder at 1024 px.
            var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform()]) else {
                FileHandle.standardError.write(Data("could not render \(pixels) px\n".utf8))
                exit(70)
            }
            // The service may return a larger rendition (for example 1024 px for 512); scale it to
            // the exact size.
            // Display P3 at 16 bits keeps the icon's saturated purples, which sRGB would clip.
            guard image.width >= pixels,
                  let space = CGColorSpace(name: CGColorSpace.displayP3),
                  let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 16, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                FileHandle.standardError.write(Data("could not render \(pixels) px (got \(image.width) px)\n".utf8))
                exit(70)
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard let scaled = context.makeImage() else {
                FileHandle.standardError.write(Data("could not render \(pixels) px\n".utf8))
                exit(70)
            }
            let bitmap = NSBitmapImageRep(cgImage: scaled)
            guard opaqueShare(bitmap) > 0.3 else {
                FileHandle.standardError.write(Data("\(pixels) px render is not the app icon; is \(arguments[1]) built?\n".utf8))
                exit(70)
            }
            let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
            try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        }
    }
}
print("Wrote \(output.path)")
