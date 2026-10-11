import Foundation

/// Settings › Screencast, as one value for what starts and records a capture: read it as each
/// capture starts, so a change applies to the next one. Its parts are the plugin's declared
/// preferences (`plugin.screencast.<key>`), and the folder captures are saved in.
struct ScreencastPreferences: Equatable {
    /// Whether a video records the microphone, while Keybumps has Microphone access. On by default.
    var recordsMicrophone: Bool
    /// Whether a video records the Mac's own sound. On by default.
    var recordsSystemAudio: Bool
    /// The seconds counted down before recording starts; 0 for none. 3 by default.
    var countdownSeconds: Int
    /// Whether the shortcuts pressed while recording show on screen: only ⌘, ⌃, and ⌥ combinations,
    /// never plain typing. On by default.
    var showsShortcuts: Bool
    /// Whether a ring shows where the pointer clicks while recording. Off by default.
    var highlightsClicks: Bool
    /// Where captures are saved, each in its own `<timestamp>/` folder: `~/Documents/Keybumps/captures/`
    /// (`ProductPaths.captures`), or its stand-in in the UI-test sandbox and the unit-test host. It
    /// isn't a setting yet.
    var capturesFolder: URL
}

extension AppPreferences {
    /// Screencast's settings as they are now.
    var screencast: ScreencastPreferences {
        ScreencastPreferences(
            recordsMicrophone: bool(.screencastRecordsMicrophone, for: .screencast),
            recordsSystemAudio: bool(.screencastRecordsSystemAudio, for: .screencast),
            countdownSeconds: Int(choice(.screencastCountdown, for: .screencast)) ?? 0,
            showsShortcuts: bool(.screencastShowsShortcuts, for: .screencast),
            highlightsClicks: bool(.screencastHighlightsClicks, for: .screencast),
            capturesFolder: ProductPaths.keybumps().captures
        )
    }
}

extension PluginPreference {
    static let screencastRecordsMicrophone = PluginPreference(
        key: "recordsMicrophone",
        title: "Record the microphone",
        subtitle: "Your voice, while Keybumps has Microphone access.",
        group: "Sound",
        kind: .toggle(default: true)
    )
    static let screencastRecordsSystemAudio = PluginPreference(
        key: "recordsSystemAudio",
        title: "Record the Mac’s sound",
        subtitle: "What your apps play, such as alerts and videos.",
        group: "Sound",
        kind: .toggle(default: true)
    )
    /// Its values are whole seconds, "0" for none.
    static let screencastCountdown = PluginPreference(
        key: "countdown",
        title: "Countdown",
        subtitle: "Time to get ready after you choose what to record.",
        group: "Recording",
        kind: .choice(
            options: [
                Choice(value: "0", title: "None"),
                Choice(value: "3", title: "3 seconds"),
                Choice(value: "5", title: "5 seconds"),
                Choice(value: "10", title: "10 seconds"),
            ],
            default: "3"
        )
    )
    static let screencastShowsShortcuts = PluginPreference(
        key: "showsShortcuts",
        title: "Show shortcuts on screen",
        subtitle: "Shortcuts you press with ⌘, ⌃, or ⌥ show in the recording. What you type never does.",
        group: "Recording",
        kind: .toggle(default: true)
    )
    static let screencastHighlightsClicks = PluginPreference(
        key: "highlightsClicks",
        title: "Highlight clicks",
        subtitle: "A ring shows where you click.",
        group: "Recording",
        kind: .toggle(default: false)
    )
}
