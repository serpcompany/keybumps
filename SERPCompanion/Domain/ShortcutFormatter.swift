import Foundation

enum ShortcutFormatter {
    static func format(command: String, modifiers: Int) -> String {
        var result = ""
        if modifiers & 4 != 0 { result += "⌃" }
        if modifiers & 2 != 0 { result += "⌥" }
        if modifiers & 1 != 0 { result += "⇧" }
        if modifiers & 8 == 0 { result += "⌘" }
        result += command.uppercased()
        return result
    }
}

