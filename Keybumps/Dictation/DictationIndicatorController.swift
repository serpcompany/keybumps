import AppKit
import Observation
import SwiftUI

/// Shows Dictation's state in the notch: while recording, a red dot and timer sit left of the
/// camera housing and live microphone bars right of it; while transcribing, a sparkle and moving
/// dots; a failure drops the notch down with the message. Screens without a notch show the same
/// black tab hanging from the top of the menu bar.
@MainActor
class DictationIndicatorController {
    private(set) var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let state = DictationNotchState()

    func update(_ phase: DictationPhase) {
        hideTask?.cancel()
        hideTask = nil
        if phase == .recording, state.phase != .recording {
            state.recordingStartedAt = Date()
            state.level = 0
        }
        state.phase = phase
        switch phase {
        case .recording, .transcribing, .inserting, .failed:
            show()
            if case .failed = phase {
                hideTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.panel?.orderOut(nil)
                }
            }
        case .idle:
            panel?.orderOut(nil)
        }
    }

    func updateLevel(_ level: Float) {
        state.level = level
    }

    private func show() {
        guard let screen = NSScreen.main else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let geometry = DictationNotchGeometry(
            notchWidth: PaletteHUD.notchWidth(of: screen),
            notchHeight: max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 28),
            isFailure: state.phase.isFailure
        )
        // A new panel already has a plain content view, so check for the notch view itself.
        if !(panel.contentView is NSHostingView<DictationNotchView>) {
            panel.contentView = NSHostingView(rootView: DictationNotchView(state: state))
        }
        state.geometry = geometry
        let size = geometry.panelSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("dictationNotch")
        return panel
    }
}

@MainActor
@Observable
final class DictationNotchState {
    var phase: DictationPhase = .idle
    var level: Float = 0
    var recordingStartedAt = Date()
    var geometry = DictationNotchGeometry(notchWidth: 0, notchHeight: 32, isFailure: false)
}

struct DictationNotchGeometry: Equatable {
    static let wingWidth: CGFloat = 116
    /// Transparent room around the shape for its glow.
    static let margin: CGFloat = 16

    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let isFailure: Bool

    var shapeSize: CGSize {
        let width = max(notchWidth, 120) + Self.wingWidth * 2
        return isFailure ? CGSize(width: max(width, 380), height: notchHeight + 40) : CGSize(width: width, height: notchHeight)
    }

    var panelSize: CGSize {
        CGSize(width: shapeSize.width + Self.margin * 2, height: shapeSize.height + Self.margin)
    }
}

private extension DictationPhase {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

struct DictationNotchView: View {
    let state: DictationNotchState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let geometry = state.geometry
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading.frame(width: DictationNotchGeometry.wingWidth, alignment: .leading)
                Spacer(minLength: 0)
                trailing.frame(width: DictationNotchGeometry.wingWidth, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: geometry.notchHeight)
            if case .failed(let message) = state.phase {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: geometry.shapeSize.width, height: geometry.shapeSize.height)
        .background(shape.fill(.black))
        .shadow(color: glow.opacity(0.45), radius: 10, y: 3)
        .frame(width: geometry.panelSize.width, height: geometry.panelSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: geometry)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var glow: Color {
        switch state.phase {
        case .recording: .red
        case .failed: .orange
        default: .purple
        }
    }

    @ViewBuilder private var leading: some View {
        switch state.phase {
        case .recording:
            HStack(spacing: 7) {
                PulsingDot(reduceMotion: reduceMotion)
                TimelineView(.periodic(from: state.recordingStartedAt, by: 1)) { context in
                    Text(Self.elapsed(from: state.recordingStartedAt, to: context.date))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        case .transcribing, .inserting:
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                Text(state.phase == .inserting ? "Inserting" : "Transcribing")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Dictation failed").foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state.phase {
        case .recording:
            HStack(spacing: 8) {
                LevelBars(level: state.level, reduceMotion: reduceMotion)
                Text("esc")
                    .font(.system(size: 10, weight: .semibold))
                    .fixedSize()
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.3), lineWidth: 1))
            }
        case .transcribing, .inserting:
            WorkingDots(reduceMotion: reduceMotion)
        case .failed, .idle:
            EmptyView()
        }
    }

    private var accessibilityLabel: String {
        switch state.phase {
        case .recording: "Dictation recording. Press Escape to cancel."
        case .failed(let message): "Dictation failed. \(message)"
        default: "Dictation \(state.phase.label.lowercased())"
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PulsingDot: View {
    let reduceMotion: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true }
            }
    }
}

/// Five bars that follow the microphone's loudness, taller in the middle.
private struct LevelBars: View {
    let level: Float
    let reduceMotion: Bool
    private static let shape: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Self.shape.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 4 + 14 * CGFloat(level) * Self.shape[index])
            }
        }
        .frame(height: 18)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
    }
}

private struct WorkingDots: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let step = reduceMotion ? 3 : Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 4
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index < step ? 0.9 : 0.25))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}
