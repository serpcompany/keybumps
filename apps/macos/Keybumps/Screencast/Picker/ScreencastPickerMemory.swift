import Foundation

/// The picker's choices as they were last left, so it opens with them (#483).
struct ScreencastPickerChoices: Equatable, Sendable {
    /// A screen chosen in Screen mode.
    enum Screen: Equatable, Sendable {
        /// One display, by its UUID (`ScreencastScreen.uuid`).
        case display(uuid: String)
        case all
    }

    var target: ScreencastPickerTarget = .area
    /// Nil until Record is pressed in Screen mode, and Screen mode starts on the pointer's screen.
    var screen: Screen?
}

/// Area, Window, or Screen, and the screen chosen, as Record last took them
/// (`screencast.pickerChoices`). The switches are Settings › Screencast's
/// (`AppPreferences.setScreencastSwitches`), and the area has its own memory
/// (`ScreencastAreaMemory`). A window is never remembered, since its ID doesn't outlast it. A name
/// and a display's UUID, so it's no user content.
struct ScreencastPickerMemory {
    static let key = "screencast.pickerChoices"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The choices last saved, or the defaults (an area) where none is, or one isn't understood.
    var choices: ScreencastPickerChoices {
        let stored = defaults.dictionary(forKey: Self.key) ?? [:]
        func value(_ key: String) -> String? { stored[key] as? String }
        let fallback = ScreencastPickerChoices()
        let screen: ScreencastPickerChoices.Screen? = if stored["allScreens"] as? Bool == true {
            .all
        } else if let uuid = value("display"), !uuid.isEmpty {
            .display(uuid: uuid)
        } else {
            nil
        }
        return ScreencastPickerChoices(
            target: value("target").flatMap(ScreencastPickerTarget.init(rawValue:)) ?? fallback.target,
            screen: screen
        )
    }

    func save(_ choices: ScreencastPickerChoices) {
        var stored: [String: Any] = ["target": choices.target.rawValue]
        switch choices.screen {
        case .display(let uuid): stored["display"] = uuid
        case .all: stored["allScreens"] = true
        case nil: break
        }
        defaults.set(stored, forKey: Self.key)
    }
}
