import CoreText
import Foundation

/// Whether Apple Color Emoji draws an emoji as one emoji on this Mac. An emoji newer than the Mac's
/// font falls back to another font (tofu), or splits apart wider than one emoji, as the Emoji 15.1
/// sequences do on macOS 14.2 and 14.3. Checking every emoji takes about 40 ms, once, the first
/// time the Emoji tab opens. A count of glyphs would be wrong: Apple draws many two-person emoji as
/// two glyphs in one emoji's space.
struct EmojiRenderCheck {
    private let font: CTFont
    private let emojiWidth: Double

    /// Nil when Apple Color Emoji is missing: CoreText would quietly substitute another font, and
    /// every emoji would fail the check.
    init?() {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 32, nil)
        guard CTFontCopyPostScriptName(font) as String == "AppleColorEmoji" else { return nil }
        self.font = font
        emojiWidth = Self.width(of: "\u{1F600}", font: font)
    }

    func canDraw(_ emoji: String) -> Bool {
        let line = Self.line(emoji, font: font)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName] else { return false }
            // swiftlint:disable:next force_cast
            guard CTFontCopyPostScriptName(runFont as! CTFont) as String == "AppleColorEmoji" else { return false }
        }
        return Self.width(of: line) <= emojiWidth * 1.05
    }

    private static func line(_ text: String, font: CTFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
    }

    private static func width(of text: String, font: CTFont) -> Double {
        width(of: line(text, font: font))
    }

    private static func width(of line: CTLine) -> Double {
        CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}
