import ApplicationServices
import Foundation

enum AXShortcutEvidenceReader {
    static func read(from element: AXUIElement) -> AXShortcutEvidence {
        read { attributeName in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                attributeName as CFString,
                &value
            ) == .success else { return nil }
            return value
        }
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
