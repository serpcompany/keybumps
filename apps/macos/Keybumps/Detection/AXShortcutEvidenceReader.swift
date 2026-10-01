import ApplicationServices
import Foundation

enum AXShortcutEvidenceReader {
    static func read(from element: AXUIElement, using accessibility: DetectionAccessibility) -> AXShortcutEvidence {
        read { accessibility.copyAttribute($0, from: element) }
    }

    static func read(valueForAttribute: (String) -> Any?) -> AXShortcutEvidence {
        AXShortcutEvidence(
            commandCharacter: valueForAttribute(kAXMenuItemCmdCharAttribute) as? String,
            modifiers: (valueForAttribute(kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue,
            commandGlyph: (valueForAttribute(kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue,
            virtualKey: (valueForAttribute(kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue
        )
    }
}
