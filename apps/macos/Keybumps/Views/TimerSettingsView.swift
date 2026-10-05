import SwiftUI

/// The Timer page: its switch and Open Timers shortcut, and whether a timer's end plays a sound.
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
                        title: "Play a sound",
                        subtitle: "Keybumps always shows a notch notice, and marks its menu bar icon until you open the Timers tab."
                    )
                }
                .toggleStyle(SettingsSwitchToggleStyle())
                .accessibilityIdentifier("timer.sound")
            }
        }
    }
}
