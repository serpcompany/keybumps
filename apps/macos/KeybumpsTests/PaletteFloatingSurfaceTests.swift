import AppKit
import SwiftUI
import Testing
@testable import Keybumps

/// Pixel checks for the palette's pill family (`paletteFloatingSurface`). Core Animation draws
/// their outlines in the app, and `ImageRenderer` draws them differently, so these render through
/// an `NSHostingView`, as the app does. Its window is never shown or made key.
@MainActor
@Suite("Palette floating surface")
struct PaletteFloatingSurfaceTests {
    enum Pill: String, CaseIterable, CustomTestStringConvertible {
        /// The footer's action pill, laid out as `PaletteFooter` lays it out.
        case footer
        /// The compact capsule every history tab's Clear All uses.
        case clearAll
        /// A button at the footer pill's height.
        case regular
        /// An icon-only round button, like a screenshot card's Delete.
        case round

        var testDescription: String { rawValue }

        var height: CGFloat {
            switch self {
            case .footer: PaletteTheme.footerHeight
            case .regular: PalettePillButtonStyle.Size.regular.height
            case .clearAll, .round: PalettePillButtonStyle.Size.compact.height
            }
        }

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .footer:
                Text("Select")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.leading, 16)
                    .padding(.trailing, 7)
                    .frame(height: PaletteTheme.footerHeight)
                    .paletteFloatingSurface()
            case .clearAll:
                ClearAllButton(confirmationTitle: "Clear?", confirmationMessage: "Made-up", disabled: false, clear: {})
                    .buttonStyle(PalettePillButtonStyle())
            case .regular:
                Button("Copy", systemImage: "doc.on.doc") {}
                    .buttonStyle(PalettePillButtonStyle(size: .regular))
            case .round:
                Button("Delete", systemImage: "trash", role: .destructive) {}
                    .buttonStyle(PalettePillButtonStyle(isCircular: true))
            }
        }
    }

    @Test("A pill draws nothing outside the rounded outline at its ends", arguments: Pill.allCases)
    func nothingOutsideTheEnds(_ pill: Pill) throws {
        let image = try Self.render(pill.view, size: CGSize(width: 240, height: 100))
        let stray = try Self.strayRows(in: image, height: pill.height)
        #expect(stray.left.isEmpty, "something drawn outside the left end, at pixel rows \(stray.left) from the middle")
        #expect(stray.right.isEmpty, "something drawn outside the right end, at pixel rows \(stray.right) from the middle")
    }

    /// The pixel rows, counted from the middle, where something is drawn between an end of the pill
    /// centered in `image` and its frame. Seen from outside, a row stays background until it reaches
    /// the outline, which curves in by `r - sqrt(r² - dy²)` at `dy` from the middle. Rows near the
    /// top and bottom are skipped: the curve is almost flat there, so its antialiasing runs sideways.
    static func strayRows(in image: Bitmap, height: CGFloat) throws -> (left: [Int], right: [Int]) {
        let centerY = image.height / 2
        let background = image.luma(4, centerY)
        let ink = (0..<image.width).filter { abs(image.luma($0, centerY) - background) >= 10 }
        let left = try #require(ink.first, "the pill didn't render")
        let right = try #require(ink.last)
        let radius = Double(height * scale / 2)
        #expect(right - left >= Int(radius * 2) - 4, "the pill didn't render at its full size")

        var stray: (left: [Int], right: [Int]) = ([], [])
        let checkedRows = Int(radius * 0.75)
        for dy in -checkedRows...checkedRows {
            let inset = radius - (radius * radius - Double(dy * dy)).squareRoot()
            // Only rows where the curve leaves a clear pixel, checked one pixel short of its antialiasing.
            guard inset >= 3 else { continue }
            let y = centerY + dy
            for (end, inward) in [(left, 1), (right, -1)] {
                let rowBackground = image.luma(end - 10 * inward, y)
                let isDrawn = (-1...Int(inset) - 2).contains { abs(image.luma(end + $0 * inward, y) - rowBackground) >= 8 }
                guard isDrawn else { continue }
                if inward == 1 { stray.left.append(dy) } else { stray.right.append(dy) }
            }
        }
        return stray
    }

    // MARK: Rendering

    static let scale: CGFloat = 2

    struct Bitmap {
        let rep: NSBitmapImageRep
        var width: Int { rep.pixelsWide }
        var height: Int { rep.pixelsHigh }

        /// Mean of red, green, and blue in sRGB, 0 to 255.
        func luma(_ x: Int, _ y: Int) -> Double {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
        }
    }

    /// Draws `pill` centered on the palette's dark background at 2x, through AppKit and Core
    /// Animation, in a borderless window that is never ordered in. Dark only: the stray line shows in
    /// both appearances, but on the light background the pill's shadow is too strong for the thresholds.
    static func render(_ pill: some View, size: CGSize) throws -> Bitmap {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ZStack { PaletteTheme.background; pill }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return Bitmap(rep: rep)
    }
}
