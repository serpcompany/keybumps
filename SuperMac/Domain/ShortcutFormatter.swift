import Foundation

/// The complete public Accessibility shortcut tuple exposed by a menu item.
///
/// Apple documents the character, modifier mask, menu glyph, and virtual key as
/// separate attributes. Keeping the values together lets the registry resolve
/// special keys without displaying private-use Unicode scalars.
struct AXShortcutEvidence: Codable, Equatable, Sendable {
    let commandCharacter: String?
    let modifiers: Int?
    let commandGlyph: Int?
    let virtualKey: Int?
}

enum KeyboardSemanticKey: Hashable, Sendable {
    case command
    case shift
    case option
    case control
    case printable(String)
    case returnKey
    case enter
    case tabRight
    case tabLeft
    case escape
    case space
    case delete
    case forwardDelete
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case pageUp
    case pageDown
    case home
    case end
    case help
    case clear
    case function(Int)
}

struct KeyboardShortcutKey: Equatable, Sendable {
    let semanticKey: KeyboardSemanticKey
    let officialName: String
    let renderedSymbol: String
}

struct CanonicalKeyboardShortcut: Equatable, Sendable {
    let modifiers: [KeyboardShortcutKey]
    let primaryKey: KeyboardShortcutKey

    var displayString: String {
        modifiers.map(\.renderedSymbol).joined() + primaryKey.renderedSymbol
    }

    var keycapTokens: [String] {
        modifiers.map(\.renderedSymbol) + [primaryKey.renderedSymbol]
    }

    var accessibilityDescription: String {
        (modifiers.map(\.officialName) + [primaryKey.officialName]).joined(separator: " ")
    }
}

struct KeyboardGlyphLegendEntry: Identifiable, Equatable, Sendable {
    let semanticKey: KeyboardSemanticKey
    let symbol: String
    let name: String

    var id: KeyboardSemanticKey { semanticKey }
}

#if DEBUG
struct KeyboardShortcutRegistryValidationFixture: Sendable {
    let semanticKey: KeyboardSemanticKey
    let evidence: AXShortcutEvidence
}
#endif

enum KeyboardShortcutRegistry {
    // Sources for the values below:
    // - AXAttributeConstants.h: AX menu modifier semantics and the four AX attributes.
    // - HIToolbox Menus.h: public MenuCommandGlyph values.
    // - HIToolbox Events.h: public layout-independent virtual key codes.
    // - Apple Support "What are those symbols shown in menus on Mac?": user-facing names.
    // The runtime resolver accepts only these public definitions plus sanitized
    // printable AX characters; it does not infer bindings from ShortcutCatalog.
    private struct KeyDefinition: Sendable {
        let key: KeyboardShortcutKey
        let characters: Set<String>
        let glyphs: Set<Int>
        let virtualKeys: Set<Int>
    }

    private static let modifierDefinitions: [KeyboardShortcutKey] = [
        .init(semanticKey: .control, officialName: "Control", renderedSymbol: "⌃"),
        .init(semanticKey: .option, officialName: "Option", renderedSymbol: "⌥"),
        .init(semanticKey: .shift, officialName: "Shift", renderedSymbol: "⇧"),
        .init(semanticKey: .command, officialName: "Command", renderedSymbol: "⌘")
    ]

    private static let fixedDefinitions: [KeyDefinition] = [
        definition(.returnKey, "Return", "↩", ["\r", "\n"], [0x0B, 0x0C, 0x0D], [0x24]),
        definition(.enter, "Enter", "⌤", [], [0x04], [0x4C]),
        definition(.tabRight, "Tab Right", "⇥", ["\t"], [0x02], [0x30]),
        definition(.tabLeft, "Tab Left", "⇤", ["\u{19}"], [0x03], []),
        definition(.escape, "Escape (Esc)", "⎋", ["\u{1B}"], [0x1B], [0x35]),
        definition(.space, "Space", "Space", [" "], [0x09], [0x31]),
        definition(.delete, "Delete", "⌫", ["\u{08}", "\u{7F}"], [0x17], [0x33]),
        definition(.forwardDelete, "Forward Delete", "⌦", ["\u{F728}"], [0x0A], [0x75]),
        definition(.upArrow, "Up Arrow", "↑", ["\u{F700}"], [0x68], [0x7E]),
        definition(.downArrow, "Down Arrow", "↓", ["\u{F701}"], [0x6A], [0x7D]),
        definition(.leftArrow, "Left Arrow", "←", ["\u{F702}"], [0x64], [0x7B]),
        definition(.rightArrow, "Right Arrow", "→", ["\u{F703}"], [0x65], [0x7C]),
        definition(.pageUp, "Page Up", "⇞", ["\u{F72C}"], [0x62], [0x74]),
        definition(.pageDown, "Page Down", "⇟", ["\u{F72D}"], [0x6B], [0x79]),
        definition(.home, "Top (Home)", "↖", ["\u{F729}"], [], [0x73]),
        definition(.end, "End", "↘", ["\u{F72B}"], [], [0x77]),
        definition(.help, "Help", "?⃝", ["\u{F746}"], [0x67], [0x72]),
        definition(.clear, "Clear", "⌧", ["\u{F739}"], [0x1C], [0x47])
    ]

    private static let functionDefinitions: [KeyDefinition] = {
        let glyphs = Array(0x6F...0x7A) + Array(0x87...0x89) + Array(0x8F...0x92)
        let virtualKeys = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A
        ]
        return (1...20).map { number in
            definition(
                .function(number),
                "F\(number)",
                "F\(number)",
                [String(UnicodeScalar(0xF703 + number)!)],
                number <= glyphs.count ? [glyphs[number - 1]] : [],
                [virtualKeys[number - 1]]
            )
        }
    }()

    private static let definitions = fixedDefinitions + functionDefinitions

    static let legendEntries: [KeyboardGlyphLegendEntry] = {
        let modifierEntries = modifierDefinitions.map {
            KeyboardGlyphLegendEntry(semanticKey: $0.semanticKey, symbol: $0.renderedSymbol, name: $0.officialName)
        }
        let primaryEntries = definitions.map {
            KeyboardGlyphLegendEntry(semanticKey: $0.key.semanticKey, symbol: $0.key.renderedSymbol, name: $0.key.officialName)
        }
        return modifierEntries + primaryEntries
    }()

    #if DEBUG
    static let validationFixtures: [KeyboardShortcutRegistryValidationFixture] = {
        definitions.flatMap { definition in
            let characterFixtures = definition.characters.map {
                KeyboardShortcutRegistryValidationFixture(
                    semanticKey: definition.key.semanticKey,
                    evidence: AXShortcutEvidence(
                        commandCharacter: $0,
                        modifiers: 8,
                        commandGlyph: nil,
                        virtualKey: nil
                    )
                )
            }
            let glyphFixtures = definition.glyphs.map {
                KeyboardShortcutRegistryValidationFixture(
                    semanticKey: definition.key.semanticKey,
                    evidence: AXShortcutEvidence(
                        commandCharacter: nil,
                        modifiers: 8,
                        commandGlyph: $0,
                        virtualKey: nil
                    )
                )
            }
            let virtualKeyFixtures = definition.virtualKeys.map {
                KeyboardShortcutRegistryValidationFixture(
                    semanticKey: definition.key.semanticKey,
                    evidence: AXShortcutEvidence(
                        commandCharacter: nil,
                        modifiers: 8,
                        commandGlyph: nil,
                        virtualKey: $0
                    )
                )
            }
            return characterFixtures + glyphFixtures + virtualKeyFixtures
        }
    }()
    #endif

    static func resolve(_ evidence: AXShortcutEvidence) -> CanonicalKeyboardShortcut? {
        guard let modifierMask = evidence.modifiers,
              modifierMask >= 0,
              modifierMask & ~0x0F == 0 else { return nil }

        var candidates = Set<KeyboardSemanticKey>()
        var sawUnsupportedGlyph = false

        if let character = evidence.commandCharacter, !character.isEmpty {
            if let definition = definitions.first(where: { $0.characters.contains(character) }) {
                candidates.insert(definition.key.semanticKey)
            } else if let printable = printableKey(from: character) {
                candidates.insert(printable.semanticKey)
            } else {
                return nil
            }
        }

        if let glyph = evidence.commandGlyph, glyph != 0, glyph != 0x61 {
            if let definition = definitions.first(where: { $0.glyphs.contains(glyph) }) {
                candidates.insert(definition.key.semanticKey)
            } else {
                sawUnsupportedGlyph = true
            }
        }

        if let virtualKey = evidence.virtualKey,
           let definition = definitions.first(where: { $0.virtualKeys.contains(virtualKey) }) {
            candidates.insert(definition.key.semanticKey)
        }

        guard !sawUnsupportedGlyph, candidates.count == 1, let semanticKey = candidates.first else { return nil }
        let primaryKey: KeyboardShortcutKey
        if case .printable(let value) = semanticKey {
            guard let printable = printableKey(from: value) else { return nil }
            primaryKey = printable
        } else if let definition = definitions.first(where: { $0.key.semanticKey == semanticKey }) {
            primaryKey = definition.key
        } else {
            return nil
        }

        return CanonicalKeyboardShortcut(
            modifiers: modifiers(from: modifierMask),
            primaryKey: primaryKey
        )
    }

    static func resolve(displayString: String) -> CanonicalKeyboardShortcut? {
        guard !displayString.isEmpty else { return nil }
        var remainder = displayString
        var modifiers: [KeyboardShortcutKey] = []
        for definition in modifierDefinitions {
            if let range = remainder.range(of: definition.renderedSymbol), range.lowerBound == remainder.startIndex {
                modifiers.append(definition)
                remainder.removeSubrange(range)
            }
        }
        guard !remainder.isEmpty else { return nil }

        if let definition = definitions.first(where: {
            $0.key.renderedSymbol == remainder || $0.key.officialName == remainder
        }) {
            return CanonicalKeyboardShortcut(modifiers: modifiers, primaryKey: definition.key)
        }
        guard let printable = printableKey(from: remainder) else { return nil }
        return CanonicalKeyboardShortcut(modifiers: modifiers, primaryKey: printable)
    }

    static func keycapTokens(for displayString: String) -> [String] {
        resolve(displayString: displayString)?.keycapTokens ?? []
    }

    static func accessibilityDescription(for displayString: String) -> String? {
        resolve(displayString: displayString)?.accessibilityDescription
    }

    private static func modifiers(from mask: Int) -> [KeyboardShortcutKey] {
        var result: [KeyboardShortcutKey] = []
        if mask & 4 != 0 { result.append(modifierDefinitions[0]) }
        if mask & 2 != 0 { result.append(modifierDefinitions[1]) }
        if mask & 1 != 0 { result.append(modifierDefinitions[2]) }
        if mask & 8 == 0 { result.append(modifierDefinitions[3]) }
        return result
    }

    private static func printableKey(from value: String) -> KeyboardShortcutKey? {
        guard value.count == 1,
              let scalar = value.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xE000...0xF8FF).contains(Int(scalar.value)) else { return nil }
        let rendered = CharacterSet.letters.contains(scalar) ? value.uppercased() : value
        return KeyboardShortcutKey(
            semanticKey: .printable(rendered),
            officialName: rendered,
            renderedSymbol: rendered
        )
    }

    private static func definition(
        _ semanticKey: KeyboardSemanticKey,
        _ name: String,
        _ symbol: String,
        _ characters: Set<String>,
        _ glyphs: Set<Int>,
        _ virtualKeys: Set<Int>
    ) -> KeyDefinition {
        KeyDefinition(
            key: KeyboardShortcutKey(semanticKey: semanticKey, officialName: name, renderedSymbol: symbol),
            characters: characters,
            glyphs: glyphs,
            virtualKeys: virtualKeys
        )
    }
}

enum ShortcutFormatter {
    static func format(
        command: String?,
        modifiers: Int?,
        glyph: Int? = nil,
        virtualKey: Int? = nil
    ) -> String? {
        KeyboardShortcutRegistry.resolve(
            AXShortcutEvidence(
                commandCharacter: command,
                modifiers: modifiers,
                commandGlyph: glyph,
                virtualKey: virtualKey
            )
        )?.displayString
    }
}
