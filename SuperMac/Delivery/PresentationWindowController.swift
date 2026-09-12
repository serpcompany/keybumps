import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
protocol KeyboardEventMonitoring: AnyObject {
    func startDismissalHandler(_ handler: @escaping () -> Bool)
    func stop()
}

@MainActor
final class LocalKeyboardEventMonitor: KeyboardEventMonitoring {
    private var token: Any?

    func startDismissalHandler(_ handler: @escaping () -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isDismissalEvent(event) else { return event }
            return handler() ? nil : event
        }
    }

    static func isDismissalEvent(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Escape)
    }

    func stop() {
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }
}

@MainActor
final class PresentationWindowController {
    private var panels: [NotificationChannel: NSPanel] = [:]
    private var dismissalTasks: [NotificationChannel: Task<Void, Never>] = [:]
    private let keyboardMonitor: any KeyboardEventMonitoring

    init(keyboardMonitor: (any KeyboardEventMonitoring)? = nil) {
        let keyboardMonitor = keyboardMonitor ?? LocalKeyboardEventMonitor()
        self.keyboardMonitor = keyboardMonitor
        keyboardMonitor.startDismissalHandler { [weak self] in
            self?.handleDismissalCommand() ?? false
        }
    }

    deinit {
        MainActor.assumeIsolated {
            keyboardMonitor.stop()
        }
    }

    func show(event: CoachingEvent, style: NotificationChannel) {
        guard style != .nativeBanner,
              style != .dockBadge,
              style != .dockBounce,
              style != .sound else { return }

        dismissalTasks[style]?.cancel()
        dismiss(style)
        if let exclusiveGroup = PresentationOverlapPolicy.exclusiveGroup(containing: style) {
            for conflictingStyle in exclusiveGroup where conflictingStyle != style {
                dismiss(conflictingStyle)
            }
        }

        let size = panelSize(for: style)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = style != .cursorHalo
        panel.collectionBehavior = panelCollectionBehavior
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: CoachingPresentationView(
            event: event,
            style: style,
            onDismiss: dismissalAction(for: style)
        ))
        panel.setFrameOrigin(origin(for: style, size: size, event: event))
        panel.orderFrontRegardless()
        panels[style] = panel

        dismissalTasks[style] = Task { [weak self, weak panel] in
            guard let self else { return }
            let delay = dismissalDelayNanoseconds(for: style)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            guard panels[style] === panel else { return }
            dismiss(style)
        }
    }

    @discardableResult
    func handleDismissalCommand() -> Bool {
        guard !panels.isEmpty else { return false }
        dismissAll()
        return true
    }

    func dismissAll() {
        for style in Array(panels.keys) {
            dismiss(style)
        }
    }

    var activeChannels: Set<NotificationChannel> {
        Set(panels.keys)
    }

    var scheduledDismissalChannels: Set<NotificationChannel> {
        Set(dismissalTasks.keys)
    }

    func panelSize(for style: NotificationChannel) -> NSSize {
        switch style {
        case .topRightToast: NSSize(width: 360, height: 92)
        case .topCenterShelf: NSSize(width: 500, height: 112)
        case .cursorHalo: NSSize(width: 120, height: 120)
        case .pointerCard: NSSize(width: 320, height: 92)
        case .statusFeedback: NSSize(width: 300, height: 76)
        case .decisionBanner: NSSize(width: 700, height: 128)
        default: NSSize(width: 360, height: 92)
        }
    }

    var panelCollectionBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func dismissalDelayNanoseconds(for style: NotificationChannel) -> UInt64 {
        style == .decisionBanner ? 8_000_000_000 : 4_000_000_000
    }

    func dismiss(_ style: NotificationChannel) {
        dismissalTasks[style]?.cancel()
        dismissalTasks[style] = nil
        panels[style]?.orderOut(nil)
        panels[style] = nil
    }

    func dismissalAction(for style: NotificationChannel) -> () -> Void {
        { [weak self] in self?.dismiss(style) }
    }

    private func origin(for style: NotificationChannel, size: NSSize, event: CoachingEvent) -> NSPoint {
        let primaryScreen = NSScreen.screens[0]
        let fallbackScreen = NSScreen.main ?? primaryScreen
        let pointer = event.pointerX.flatMap { x in
            event.pointerY.map { y in
                PresentationLayout.appKitPoint(
                    fromQuartzPoint: NSPoint(x: x, y: y),
                    primaryScreenFrame: primaryScreen.frame
                )
            }
        } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? fallbackScreen

        return PresentationLayout.origin(
            for: style,
            size: size,
            visibleFrame: screen.visibleFrame,
            pointer: pointer
        )
    }
}

enum PresentationLayout {
    static func appKitPoint(fromQuartzPoint point: NSPoint, primaryScreenFrame: NSRect) -> NSPoint {
        NSPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }

    static func origin(
        for style: NotificationChannel,
        size: NSSize,
        visibleFrame visible: NSRect,
        pointer: NSPoint
    ) -> NSPoint {
        switch style {
        case .topRightToast:
            return NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20)
        case .topCenterShelf, .decisionBanner, .statusFeedback:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16)
        case .cursorHalo:
            return NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2)
        case .pointerCard:
            let x = min(max(pointer.x + 18, visible.minX), visible.maxX - size.width)
            let y = min(max(pointer.y - size.height / 2, visible.minY), visible.maxY - size.height)
            return NSPoint(x: x, y: y)
        default:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16)
        }
    }
}

struct CoachingPresentationView: View {
    let event: CoachingEvent
    let style: NotificationChannel
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var statusCompleted = false

    var body: some View {
        Group {
            if style == .cursorHalo {
                ZStack {
                    Circle().stroke(.green.opacity(0.35), lineWidth: 12)
                    Circle().stroke(.green, lineWidth: 3)
                    Text(event.shortcut).font(.headline.monospaced()).padding(8).background(.regularMaterial, in: Capsule())
                }
                .padding(8)
            } else if style == .decisionBanner {
                HStack(spacing: 16) {
                    Image(systemName: "keyboard.badge.ellipsis").font(.title)
                    coachingCopy
                    Spacer()
                    Button("Not now", action: onDismiss)
                    Button("Got it", action: onDismiss).buttonStyle(.borderedProminent)
                }
                .padding(18)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
            } else {
                HStack(spacing: 14) {
                    Image(systemName: statusImage)
                        .font(.title2)
                        .foregroundStyle(.green)
                    coachingCopy
                    Spacer(minLength: 8)
                    Text(event.shortcut)
                        .font(.title3.bold().monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(16)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shortcut coaching. \(event.actionTitle). Try \(event.shortcut) next time.")
        .task {
            guard style == .statusFeedback else { return }
            let delay = PresentationMotionPolicy.statusFeedbackDelayNanoseconds(reduceMotion: reduceMotion)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            statusCompleted = true
        }
    }

    private var coachingCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.coachingTitle).font(.headline)
            Text("\(event.actionTitle) · \(event.applicationName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusImage: String {
        style == .statusFeedback && !statusCompleted ? "ellipsis.circle" : style.systemImage
    }
}

enum PresentationMotionPolicy {
    static func statusFeedbackDelayNanoseconds(reduceMotion: Bool) -> UInt64 {
        reduceMotion ? 0 : 700_000_000
    }
}
