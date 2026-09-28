import AppKit
import SwiftUI

@MainActor
class DictationIndicatorController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func update(_ phase: DictationPhase) {
        hideTask?.cancel()
        hideTask = nil
        switch phase {
        case .recording, .transcribing, .inserting, .failed:
            show(phase)
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

    private func show(_ phase: DictationPhase) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 210, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = true
            self.panel = panel
        }
        guard let panel, let screen = NSScreen.main else { return }
        let size = phase.isFailure ? NSSize(width: 390, height: 64) : NSSize(width: 210, height: 54)
        panel.setContentSize(size)
        panel.contentViewController = NSHostingController(
            rootView: DictationIndicatorView(phase: phase)
                .frame(width: size.width, height: size.height)
        )
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 42))
        panel.hideDuringUnitTests()
        panel.orderFrontRegardless()
    }
}

private extension DictationPhase {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

private struct DictationIndicatorView: View {
    let phase: DictationPhase
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, isActive: !phase.isFailure)
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label).font(.headline)
                if case .failed(let message) = phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if phase == .recording { Text("Esc to cancel").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial, in: Capsule())
    }

    private var iconName: String {
        switch phase {
        case .recording: "waveform.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .transcribing, .inserting, .idle: "ellipsis.circle.fill"
        }
    }

    private var iconColor: Color {
        switch phase {
        case .recording: .red
        case .failed: .orange
        case .transcribing, .inserting, .idle: .accentColor
        }
    }
}
