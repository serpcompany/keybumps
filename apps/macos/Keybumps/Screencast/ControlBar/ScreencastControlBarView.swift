import AppKit
import SwiftUI

/// The bar's accessibility identifiers, which the UI tests drive.
enum ScreencastControlBarID {
    static let timer = "screencast.bar.timer"
    static let pause = "screencast.bar.pause"
    static let draw = "screencast.bar.draw"
    static let microphone = "screencast.bar.microphone"
    static let systemAudio = "screencast.bar.systemAudio"
    static let restart = "screencast.bar.restart"
    static let discard = "screencast.bar.discard"
    static let stop = "screencast.bar.stop"
    /// Discard, answering "Discard?".
    static let confirmDiscard = "screencast.bar.confirmDiscard"
    /// Restart, answering "Restart?".
    static let confirmRestart = "screencast.bar.confirmRestart"
    /// Keep, answering either question.
    static let keep = "screencast.bar.keep"
    /// The question itself.
    static let question = "screencast.bar.question"

    static func audio(_ source: ScreencastAudioSource) -> String {
        source == .microphone ? microphone : systemAudio
    }

    static func confirm(_ question: ScreencastBarQuestion) -> String {
        question == .discard ? confirmDiscard : confirmRestart
    }
}

/// The control bar, after Snapzy's `RecordingStatusBarView` (BSD-3-Clause, see LICENSE.snapzy):
/// a drag handle, the pulsing dot and timer, then Pause, Draw, the microphone and the Mac's sound,
/// Restart, Discard, and Stop. While the microphone is on, its level moves behind the bar. Restart's
/// and Discard's questions take the controls' place, so the bar keeps its size.
struct ScreencastControlBarView: View {
    static let cornerRadius: CGFloat = 14

    let model: ScreencastControlBarModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        HStack(spacing: 4) {
            ScreencastBarDragHandle()
            ScreencastBarDivider()
            ScreencastBarStatus(model: model)
            ScreencastBarDivider()
            ZStack(alignment: .trailing) {
                ScreencastBarControls(model: model)
                    .opacity(model.question == nil ? 1 : 0)
                    .allowsHitTesting(model.question == nil)
                    .accessibilityHidden(model.question != nil)
                if let question = model.question {
                    ScreencastBarConfirmation(model: model, question: question)
                }
            }
            .disabled(!model.acceptsActions)
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .fixedSize()
        .background {
            ZStack {
                shape.fill(PaletteTheme.background)
                ScreencastBarMeter(model: model)
                    .clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .uiTestAnimationsDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screencast controls")
    }
}

/// The pulsing dot and the time recorded. Its own view, so only it redraws as the time changes.
private struct ScreencastBarStatus: View {
    let model: ScreencastControlBarModel

    var body: some View {
        HStack(spacing: 7) {
            ScreencastBarRecordingDot(isPaused: model.isPaused)
            Text(model.timerText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(model.isPaused ? Color.white.opacity(0.5) : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // Room for 000:00, so the bar never grows while recording.
                .frame(width: 46, alignment: .leading)
                .accessibilityLabel("Recorded")
                .accessibilityValue(model.timerAccessibilityValue)
                .accessibilityIdentifier(ScreencastControlBarID.timer)
        }
        .padding(.horizontal, 4)
    }
}

/// Red and slowly pulsing while recording; dim and still while paused or with Reduce Motion.
private struct ScreencastBarRecordingDot: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: isPaused || reduceMotion)) { context in
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(opacity(at: context.date))
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    private func opacity(at date: Date) -> Double {
        if isPaused { return 0.35 }
        if reduceMotion { return 1 }
        let period = 1.6
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.65 + 0.35 * cos(phase * 2 * .pi)
    }
}

private struct ScreencastBarControls: View {
    let model: ScreencastControlBarModel

    var body: some View {
        HStack(spacing: 2) {
            Button(action: model.togglePause) {
                Image(systemName: model.pauseSystemImage)
            }
            .buttonStyle(ScreencastBarIconButtonStyle())
            .help(model.pauseHelp)
            .accessibilityLabel(model.pauseTitle)
            .accessibilityIdentifier(ScreencastControlBarID.pause)

            if model.showsDrawButton {
                Button(action: model.toggleDrawing) {
                    Image(systemName: model.drawSystemImage)
                }
                .buttonStyle(ScreencastBarIconButtonStyle(isOn: model.isDrawing))
                .help(model.drawHelp)
                .accessibilityLabel("Draw")
                .accessibilityValue(model.isDrawing ? "On" : "Off")
                .accessibilityIdentifier(ScreencastControlBarID.draw)
            }

            audioButton(.microphone)
            audioButton(.systemAudio)

            ScreencastBarDivider()

            Button(action: model.askToRestart) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(ScreencastBarIconButtonStyle())
            .help("Start over: what’s recorded so far is thrown away")
            .accessibilityLabel("Restart")
            .accessibilityIdentifier(ScreencastControlBarID.restart)

            Button(action: model.askToDiscard) {
                Image(systemName: "trash")
            }
            .buttonStyle(ScreencastBarIconButtonStyle())
            .help("Discard this recording")
            .accessibilityLabel("Discard")
            .accessibilityIdentifier(ScreencastControlBarID.discard)

            ScreencastBarDivider()

            Button {
                Task { await model.stop() }
            } label: {
                Text("Stop")
            }
            .buttonStyle(ScreencastBarTextButtonStyle(tint: .red, isFilled: true))
            .help("Stop and keep the recording")
            .accessibilityIdentifier(ScreencastControlBarID.stop)
        }
    }

    private func audioButton(_ source: ScreencastAudioSource) -> some View {
        let button = model.audioButton(for: source)
        return Button {
            model.toggleAudio(source)
        } label: {
            Image(systemName: button.systemImage)
        }
        .buttonStyle(ScreencastBarIconButtonStyle(isWarning: button.isWarning))
        .disabled(!button.isEnabled)
        .help(button.help)
        .accessibilityLabel(button.label)
        .accessibilityValue(button.value)
        .accessibilityHint(button.isEnabled ? "" : button.help)
        .accessibilityIdentifier(ScreencastControlBarID.audio(source))
    }
}

/// "Discard?" or "Restart?" with its answer and Keep, in the controls' place.
private struct ScreencastBarConfirmation: View {
    let model: ScreencastControlBarModel
    let question: ScreencastBarQuestion

    var body: some View {
        HStack(spacing: 6) {
            Text(question.prompt)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .accessibilityIdentifier(ScreencastControlBarID.question)
            Button(question.confirmTitle) {
                Task { await model.confirm() }
            }
            .buttonStyle(ScreencastBarTextButtonStyle(tint: .red))
            .help(question.confirmHelp)
            .accessibilityIdentifier(ScreencastControlBarID.confirm(question))
            Button("Keep", action: model.keep)
                .buttonStyle(ScreencastBarTextButtonStyle(tint: .white))
                .help("Keep recording")
                .accessibilityIdentifier(ScreencastControlBarID.keep)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.accessibilityLabel)
    }
}

/// Drags the bar. AppKit moves the panel by its background too, but a SwiftUI view inside it
/// doesn't pass the drag on, so the handle asks the window to drag.
private struct ScreencastBarDragHandle: View {
    var body: some View {
        ZStack {
            WindowDragArea()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.35))
                .allowsHitTesting(false)
        }
        .frame(width: 18, height: 30)
        .help("Drag to move")
        .accessibilityHidden(true)
    }

    private struct WindowDragArea: NSViewRepresentable {
        func makeNSView(context: Context) -> DragView { DragView() }
        func updateNSView(_ nsView: DragView, context: Context) {}

        final class DragView: NSView {
            override var mouseDownCanMoveWindow: Bool { true }
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
            override func mouseDown(with event: NSEvent) {
                window?.performDrag(with: event)
            }
        }
    }
}

private struct ScreencastBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

// MARK: The microphone's level

/// The microphone's level as a wave along the bottom of the bar, after Snapzy's
/// `RecordingWaveformView` (BSD-3-Clause, see LICENSE.snapzy). The wave stays in place: fixed
/// points each bob on their own phase, scaled by the level, so silence lies nearly flat and speech
/// raises it. It lies flat while paused, and holds still with Reduce Motion. Its own view, so only
/// it redraws as the level changes.
private struct ScreencastBarMeter: View {
    let model: ScreencastControlBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let level = model.microphoneMeter {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.isPaused || reduceMotion)) { context in
                Canvas { canvas, size in
                    let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                    canvas.fill(
                        Self.wave(in: size, level: CGFloat(level), time: time),
                        with: .linearGradient(
                            Gradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.02)]),
                            startPoint: CGPoint(x: 0, y: size.height * (Self.baseline - Self.peak)),
                            endPoint: CGPoint(x: 0, y: size.height)
                        )
                    )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Where the wave rests, and how far up its loudest point reaches, as parts of the bar's height.
    static let baseline: CGFloat = 0.72
    static let peak: CGFloat = 0.45
    static let points = 9

    /// The wave's fill: a smooth curve through the points, closed along the bottom.
    static func wave(in size: CGSize, level: CGFloat, time: Double) -> Path {
        let baseline = size.height * Self.baseline
        let peak = size.height * Self.peak
        let t = CGFloat(time)
        let nodes: [CGPoint] = (0..<Self.points).map { index in
            let i = CGFloat(index)
            let x = i / CGFloat(Self.points - 1)
            let envelope = 0.35 + 0.65 * sin(x * .pi)
            let weight = 0.6 + 0.4 * abs(sin(i * 1.3 + 0.6))
            let speed = 1.4 + 0.7 * (0.5 + 0.5 * sin(i * 2.1))
            let wobble = 0.62 + 0.38 * sin(t * speed + i * 1.7)
            return CGPoint(x: x * size.width, y: baseline - level * envelope * weight * wobble * peak)
        }
        var path = Path()
        path.move(to: nodes[0])
        // A Catmull-Rom spline through the points, as cubic Béziers.
        for index in 0..<(nodes.count - 1) {
            let p0 = nodes[max(index - 1, 0)]
            let p1 = nodes[index]
            let p2 = nodes[index + 1]
            let p3 = nodes[min(index + 2, nodes.count - 1)]
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

// MARK: Button styles

/// A square icon button: a soft fill on hover or press, and while it's switched on.
private struct ScreencastBarIconButtonStyle: ButtonStyle {
    var isOn = false
    var isWarning = false

    func makeBody(configuration: Configuration) -> some View {
        ScreencastBarIconButton(configuration: configuration, isOn: isOn, isWarning: isWarning)
    }
}

private struct ScreencastBarIconButton: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let isWarning: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(fillOpacity))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }

    private var fillOpacity: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.22 }
        if isOn { return 0.16 }
        return isHovering ? 0.1 : 0
    }

    private var foreground: Color {
        if isWarning { return .orange }
        return Color.white.opacity(isEnabled ? 0.9 : 0.3)
    }
}

/// A labelled button: Stop, filled red, and Discard? and Keep, tinted.
private struct ScreencastBarTextButtonStyle: ButtonStyle {
    let tint: Color
    var isFilled = false

    func makeBody(configuration: Configuration) -> some View {
        ScreencastBarTextButton(configuration: configuration, tint: tint, isFilled: isFilled)
    }
}

private struct ScreencastBarTextButton: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let isFilled: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isFilled ? Color.white : tint)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(shape.fill(isFilled ? tint.opacity(configuration.isPressed ? 0.75 : 0.9) : tint.opacity(configuration.isPressed ? 0.32 : 0.18)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}
