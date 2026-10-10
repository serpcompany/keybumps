import Observation
import SwiftUI

/// The picker's bar, on the screen the pointer was on: Video or Screenshot; Area, Window, or
/// Screen (and Every Screen, with more than one); for a video, the microphone, the Mac's sound,
/// shortcuts, and clicks; then Record (or Capture) and close. What to do next shows above it. One
/// slim bar, after Screendrop's `RecordingPickerBar` (CC0-1.0, see LICENSE.screendrop): an input
/// that's off is dimmed, not hidden.
struct ScreencastPickerBar: View {
    @Bindable var model: ScreencastPickerModel
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(model.hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.65), in: Capsule())
                .accessibilityIdentifier("screencast.picker.hint")

            // On a screen too narrow for the whole bar, the options drop their titles.
            ViewThatFits(in: .horizontal) {
                controls(showsTitles: true)
                controls(showsTitles: false)
            }
        }
        .padding(12)
    }

    private func controls(showsTitles: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(ScreencastCaptureKind.allCases, id: \.self) { kind in
                option(kind.title, systemImage: kind.systemImage, showsTitle: showsTitles, isSelected: model.kind == kind, identifier: "screencast.picker.kind.\(kind.rawValue)") {
                    model.kind = kind
                }
            }
            divider
            ForEach(ScreencastPickerTarget.allCases, id: \.self) { target in
                option(
                    target.title,
                    systemImage: target.systemImage(screens: model.layout.screens.count),
                    showsTitle: showsTitles,
                    isSelected: model.target == target,
                    identifier: "screencast.picker.target.\(target.rawValue)"
                ) {
                    model.target = target
                }
            }
            if model.target == .screen, model.offersEveryScreen {
                option("Every Screen", systemImage: "rectangle.on.rectangle", showsTitle: showsTitles, isSelected: model.selectedScreen == nil, identifier: "screencast.picker.everyScreen") {
                    model.chooseEveryScreen()
                }
            }
            if model.kind == .video {
                divider
                toggle(
                    "Microphone", on: "mic.fill", off: "mic.slash", isOn: $model.recordsMicrophone, identifier: "screencast.picker.microphone",
                    help: model.microphoneAvailable
                        ? "Record your voice"
                        : "To record your voice, give Keybumps Microphone access in Settings › Screencast"
                )
                .disabled(!model.microphoneAvailable)
                toggle("Mac’s sound", on: "speaker.wave.2.fill", off: "speaker.slash", isOn: $model.recordsSystemAudio, identifier: "screencast.picker.systemAudio", help: "Record what your apps play")
                toggle("Shortcuts", on: "command", off: "command", isOn: $model.showsShortcuts, identifier: "screencast.picker.shortcuts", help: "Show the shortcuts you press")
                toggle("Clicks", on: "cursorarrow.click.2", off: "cursorarrow", isOn: $model.highlightsClicks, identifier: "screencast.picker.clicks", help: "Highlight where you click")
            }
            divider
            Button(action: confirm) {
                Label(model.confirmTitle, systemImage: model.kind == .video ? "record.circle" : "camera")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(model.canConfirm ? Color.red : Color.gray.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canConfirm)
            .help("\(model.confirmTitle) (Return)")
            .accessibilityIdentifier("screencast.picker.confirm")
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScreencastBarButtonStyle(isSelected: false))
            .help("Cancel (Esc)")
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("screencast.picker.cancel")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .paletteFloatingSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screencast.picker.bar")
    }

    private var divider: some View {
        Divider().frame(height: 20).padding(.horizontal, 4)
    }

    private func option(
        _ title: String,
        systemImage: String,
        showsTitle: Bool,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if showsTitle {
                    Label(title, systemImage: systemImage)
                } else {
                    Label(title, systemImage: systemImage).labelStyle(.iconOnly)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .buttonStyle(ScreencastBarButtonStyle(isSelected: isSelected))
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func toggle(_ title: String, on: String, off: String, isOn: Binding<Bool>, identifier: String, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: isOn.wrappedValue ? on : off)
                .font(.system(size: 13, weight: .medium))
                .opacity(isOn.wrappedValue ? 1 : 0.45)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScreencastBarButtonStyle(isSelected: isOn.wrappedValue))
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(identifier)
    }
}

/// A bar button: a rounded highlight while chosen or pressed.
private struct ScreencastBarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.14 : configuration.isPressed ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension ScreencastCaptureKind {
    var title: String {
        switch self {
        case .video: "Video"
        case .screenshot: "Screenshot"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "record.circle"
        case .screenshot: "camera"
        }
    }
}

extension ScreencastPickerTarget {
    var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .screen: "Screen"
        }
    }

    func systemImage(screens: Int) -> String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: screens > 1 ? "display.2" : "display"
        }
    }
}

/// The countdown's number, shared by its panels on every screen it shows on.
@MainActor
@Observable
final class ScreencastCountdownState {
    var remaining = 0
}

/// The seconds before recording starts, large, with Cancel under them. After Screendrop's
/// `CaptureCountdownView` (CC0-1.0, see LICENSE.screendrop).
struct ScreencastCountdownView: View {
    static let size = CGSize(width: 140, height: 140)

    let state: ScreencastCountdownState
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text("\(state.remaining)")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: state.remaining)
                .accessibilityLabel("Recording starts in \(state.remaining)")
                .accessibilityIdentifier("screencast.countdown")
            Button("Cancel", action: cancel)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .help("Cancel (Esc)")
                .accessibilityIdentifier("screencast.countdown.cancel")
        }
        .foregroundStyle(.white)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.black.opacity(0.62)))
    }
}
