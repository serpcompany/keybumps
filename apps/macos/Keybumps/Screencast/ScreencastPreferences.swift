import Foundation

/// Settings › ScreenGrabs' Recordings group, as one value for what starts and records a recording:
/// read it as each recording starts, so a change applies to the next one. Its parts are ScreenGrabs'
/// recording preferences, still stored as Screencast's were (`plugin.screencast.<key>`, ADR 0010),
/// and the folder recordings are saved in.
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

    /// The picker's switches, which are these settings too.
    var switches: ScreencastSwitches {
        ScreencastSwitches(
            recordsMicrophone: recordsMicrophone,
            recordsSystemAudio: recordsSystemAudio,
            showsShortcuts: showsShortcuts,
            highlightsClicks: highlightsClicks
        )
    }
}

/// The picker's switches. Each is one of Settings › ScreenGrabs' recording settings, with one stored value, so the
/// two never disagree: the picker starts with them, and Record saves what it recorded with (#483).
struct ScreencastSwitches: Equatable, Sendable {
    var recordsMicrophone: Bool
    var recordsSystemAudio: Bool
    var showsShortcuts: Bool
    var highlightsClicks: Bool
}

extension AppPreferences {
    /// ScreenGrabs' recording settings as they are now.
    var screencast: ScreencastPreferences {
        ScreencastPreferences(
            recordsMicrophone: bool(.screencastRecordsMicrophone, for: .screenshotTools),
            recordsSystemAudio: bool(.screencastRecordsSystemAudio, for: .screenshotTools),
            countdownSeconds: Int(choice(.screencastCountdown, for: .screenshotTools)) ?? 0,
            showsShortcuts: bool(.screencastShowsShortcuts, for: .screenshotTools),
            highlightsClicks: bool(.screencastHighlightsClicks, for: .screenshotTools),
            capturesFolder: ProductPaths.keybumps().captures
        )
    }

    /// Saves the picker's switches as Settings › ScreenGrabs' recording settings. One left as it was
    /// isn't stored, so one never changed keeps following its default.
    func setScreencastSwitches(_ switches: ScreencastSwitches) {
        let values: [(PluginPreference, Bool)] = [
            (.screencastRecordsMicrophone, switches.recordsMicrophone),
            (.screencastRecordsSystemAudio, switches.recordsSystemAudio),
            (.screencastShowsShortcuts, switches.showsShortcuts),
            (.screencastHighlightsClicks, switches.highlightsClicks),
        ]
        for (preference, value) in values where bool(preference, for: .screenshotTools) != value {
            set(.bool(value), of: preference, for: .screenshotTools)
        }
    }
}

/// ScreenGrabs' recording settings, in its Recordings group. They came from Screencast, which
/// ScreenGrabs replaced, and keep its stored name (`storageName`), so each is still
/// `plugin.screencast.<key>` (ADR 0010).
extension PluginPreference {
    static let recordingsGroup = "Recordings"
    static let screencastStorageName = "screencast"

    static let screencastRecordsMicrophone = PluginPreference(
        key: "recordsMicrophone",
        title: "Record the microphone",
        subtitle: "Your voice, while Keybumps has Microphone access.",
        group: recordingsGroup,
        kind: .toggle(default: true),
        storageName: screencastStorageName
    )
    static let screencastRecordsSystemAudio = PluginPreference(
        key: "recordsSystemAudio",
        title: "Record the Mac’s sound",
        subtitle: "What your apps play, such as alerts and videos.",
        group: recordingsGroup,
        kind: .toggle(default: true),
        storageName: screencastStorageName
    )
    /// Its values are whole seconds, "0" for none.
    static let screencastCountdown = PluginPreference(
        key: "countdown",
        title: "Countdown",
        subtitle: "Time to get ready after you choose what to record.",
        group: recordingsGroup,
        kind: .choice(
            options: [
                Choice(value: "0", title: "None"),
                Choice(value: "3", title: "3 seconds"),
                Choice(value: "5", title: "5 seconds"),
                Choice(value: "10", title: "10 seconds"),
            ],
            default: "3"
        ),
        storageName: screencastStorageName
    )
    static let screencastShowsShortcuts = PluginPreference(
        key: "showsShortcuts",
        title: "Show shortcuts on screen",
        subtitle: "Shortcuts you press with ⌘, ⌃, or ⌥ show in the recording. What you type never does.",
        group: recordingsGroup,
        kind: .toggle(default: true),
        storageName: screencastStorageName
    )
    static let screencastHighlightsClicks = PluginPreference(
        key: "highlightsClicks",
        title: "Highlight clicks",
        subtitle: "A ring shows where you click.",
        group: recordingsGroup,
        kind: .toggle(default: false),
        storageName: screencastStorageName
    )
}
