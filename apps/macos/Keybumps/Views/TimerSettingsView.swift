import SwiftUI

/// The Timer page: its switch and Open Timers shortcut, whether a timer's end plays a sound, and
/// whether running timers show in the menu bar.
struct TimerSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            CapabilityControl(capability: .timer, shortcuts: [.timer])
            SettingsGroup("When a timer ends") {
                Toggle(isOn: Binding(
                    get: { model.preferences.timerPlaysSound },
                    set: { model.preferences.timerPlaysSound = $0 }
                )) {
                    SettingsRowLabel(
                        title: "Ring until you stop it",
                        subtitle: "Keybumps always shows an alarm that stays on screen until you click Stop or open the Timers tab. Turn this off for a silent alarm."
                    )
                }
                .toggleStyle(SettingsSwitchToggleStyle())
                .accessibilityIdentifier("timer.sound")
            }
            SettingsGroup("Menu bar") {
                Toggle(isOn: Binding(
                    get: { model.preferences.timerShowsMenuBarCountdown },
                    set: { isOn in
                        model.preferences.timerShowsMenuBarCountdown = isOn
                        model.applyCapabilities()
                    }
                )) {
                    SettingsRowLabel(
                        title: "Show the countdown",
                        subtitle: "While a timer runs, the time left on the soonest one shows beside the Keybumps icon."
                    )
                }
                .toggleStyle(SettingsSwitchToggleStyle())
                .accessibilityIdentifier("timer.menuBarCountdown")
                Toggle(isOn: Binding(
                    get: { model.preferences.timerListsTimersInMenu },
                    set: { isOn in
                        model.preferences.timerListsTimersInMenu = isOn
                        model.applyCapabilities()
                    }
                )) {
                    SettingsRowLabel(
                        title: "List timers in the Keybumps menu",
                        subtitle: "Click one there to pause or resume it."
                    )
                }
                .toggleStyle(SettingsSwitchToggleStyle())
                .accessibilityIdentifier("timer.menuList")
            }
        }
    }
}
