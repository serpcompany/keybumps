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
    private var localToken: Any?
    private var globalToken: Any?

    func startDismissalHandler(_ handler: @escaping () -> Bool) {
        guard localToken == nil, globalToken == nil else { return }
        localToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isDismissalEvent(event) else { return event }
            return handler() ? nil : event
        }
        globalToken = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isDismissalEvent(event) else { return }
            Task { @MainActor in _ = handler() }
        }
    }

    static func isDismissalEvent(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Escape)
    }

    func stop() {
        if let localToken { NSEvent.removeMonitor(localToken) }
        if let globalToken { NSEvent.removeMonitor(globalToken) }
        localToken = nil
        globalToken = nil
    }
}

@MainActor
private final class PresentationSession {
    let panel: NSPanel
    var dismissalTask: Task<Void, Never>?
    var remainingDismissalTime: TimeInterval
    var dismissalStartedAt: Date?
    var swipeTranslation: NSSize = .zero

    init(panel: NSPanel, remainingDismissalTime: TimeInterval) {
        self.panel = panel
        self.remainingDismissalTime = remainingDismissalTime
    }
}

@MainActor
final class PresentationWindowController {
    private var sessions: [NotificationChannel: PresentationSession] = [:]
    private var scrollMonitor: Any?
    private var localScrollMonitor: Any?
    private let keyboardMonitor: any KeyboardEventMonitoring

    init(keyboardMonitor: (any KeyboardEventMonitoring)? = nil) {
        let keyboardMonitor = keyboardMonitor ?? LocalKeyboardEventMonitor()
        self.keyboardMonitor = keyboardMonitor
    }

    deinit {
        MainActor.assumeIsolated {
            stopInteractionMonitors()
        }
    }

    func show(event: CoachingEvent, style: NotificationChannel) {
        guard style != .nativeBanner,
              style != .sound else { return }

        dismiss(style)

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
        panel.hasShadow = true
        panel.collectionBehavior = panelCollectionBehavior
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: CoachingPresentationView(
            event: event,
            style: style,
            onDismiss: dismissalAction(for: style),
            onHoverChanged: { [weak self] isHovering in
                self?.setHovering(isHovering, style: style)
            }
        ))
        panel.setFrameOrigin(origin(for: style, size: size, event: event))
        panel.orderFrontRegardless()
        let session = PresentationSession(
            panel: panel,
            remainingDismissalTime: dismissalDelay(for: style)
        )
        sessions[style] = session
        startInteractionMonitorsIfNeeded()
        scheduleDismissal(style, session: session, after: session.remainingDismissalTime)
    }

    @discardableResult
    func handleDismissalCommand() -> Bool {
        guard !sessions.isEmpty else { return false }
        dismissAll()
        return true
    }

    func dismissAll() {
        for style in Array(sessions.keys) {
            dismiss(style)
        }
    }

    var activeChannels: Set<NotificationChannel> {
        Set(sessions.keys)
    }

    var scheduledDismissalChannels: Set<NotificationChannel> {
        Set(sessions.compactMap { $0.value.dismissalTask == nil ? nil : $0.key })
    }

    func panelSize(for style: NotificationChannel) -> NSSize {
        switch style {
        case .topRightToast: NSSize(width: 360, height: 92)
        case .topCenterShelf: NSSize(width: 500, height: 112)
        default: NSSize(width: 360, height: 92)
        }
    }

    var panelCollectionBehavior: NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func dismissalDelayNanoseconds(for style: NotificationChannel) -> UInt64 {
        UInt64(dismissalDelay(for: style) * 1_000_000_000)
    }

    func dismiss(_ style: NotificationChannel) {
        guard let session = sessions.removeValue(forKey: style) else { return }
        session.dismissalTask?.cancel()
        session.dismissalTask = nil
        session.panel.orderOut(nil)
        if sessions.isEmpty { stopInteractionMonitors() }
    }

    func dismissalAction(for style: NotificationChannel) -> () -> Void {
        { [weak self] in self?.dismiss(style) }
    }

    func setHovering(_ isHovering: Bool, style: NotificationChannel, now: Date = Date()) {
        guard let session = sessions[style] else { return }
        if isHovering {
            guard let startedAt = session.dismissalStartedAt else { return }
            session.remainingDismissalTime = ToastDismissalPolicy.remainingDuration(
                initial: session.remainingDismissalTime,
                elapsed: now.timeIntervalSince(startedAt)
            )
            session.dismissalStartedAt = nil
            session.dismissalTask?.cancel()
            session.dismissalTask = nil
        } else if session.dismissalTask == nil {
            scheduleDismissal(
                style,
                session: session,
                after: session.remainingDismissalTime,
                now: now
            )
        }
    }

    var pausedDismissalChannels: Set<NotificationChannel> {
        Set(sessions.compactMap {
            $0.value.dismissalStartedAt == nil && $0.value.dismissalTask == nil ? $0.key : nil
        })
    }

    private func dismissalDelay(for style: NotificationChannel) -> TimeInterval {
        4
    }

    private func scheduleDismissal(
        _ style: NotificationChannel,
        session: PresentationSession,
        after delay: TimeInterval,
        now: Date = Date()
    ) {
        guard delay > 0 else {
            dismiss(style)
            return
        }
        session.remainingDismissalTime = delay
        session.dismissalStartedAt = now
        session.dismissalTask?.cancel()
        session.dismissalTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let session else { return }
            guard sessions[style] === session else { return }
            dismiss(style)
        }
    }

    private func handleTrackpadScroll(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase
    ) {
        guard !sessions.isEmpty else { return }
        if phase == .began {
            for session in sessions.values {
                session.swipeTranslation = .zero
            }
        }
        for session in sessions.values {
            session.swipeTranslation = NSSize(
                width: session.swipeTranslation.width + deltaX,
                height: session.swipeTranslation.height + deltaY
            )
        }
        if phase == .ended || phase == .cancelled {
            let shouldDismiss = sessions.values.contains {
                ToastDismissalPolicy.shouldDismiss(for: $0.swipeTranslation)
            }
            for session in sessions.values {
                session.swipeTranslation = .zero
            }
            if shouldDismiss {
                dismissAll()
            }
        }
    }

    private func startInteractionMonitorsIfNeeded() {
        guard sessions.count == 1 else { return }
        keyboardMonitor.startDismissalHandler { [weak self] in
            self?.handleDismissalCommand() ?? false
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let phase = event.phase
            Task { @MainActor in
                self?.handleTrackpadScroll(
                    deltaX: deltaX,
                    deltaY: deltaY,
                    phase: phase
                )
            }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleTrackpadScroll(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                phase: event.phase
            )
            return event
        }
    }

    private func stopInteractionMonitors() {
        keyboardMonitor.stop()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        scrollMonitor = nil
        localScrollMonitor = nil
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
        case .topCenterShelf:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16)
        default:
            return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16)
        }
    }
}

struct KeyBumpVisibleCopy: Equatable {
    let lines: [String]

    init(event: CoachingEvent) {
        lines = [event.actionTitle, event.applicationName]
    }

    var title: String { lines.first ?? "" }
}

struct CoachingPresentationView: View {
    let event: CoachingEvent
    let style: NotificationChannel
    let onDismiss: () -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }

    var visibleCopy: KeyBumpVisibleCopy { KeyBumpVisibleCopy(event: event) }
    var visibleShortcut: String { event.shortcut }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss Key Bump")
            }
            .padding(.top, 6)
            .padding(.horizontal, 10)

            HStack(spacing: 14) {
                coachingCopy
                Spacer(minLength: 18)
                ShortcutKeycaps(shortcut: visibleShortcut, fontSize: 13)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(4)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCopy)
    }

    private var coachingCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(visibleCopy.title).font(.headline)
            Text(event.applicationName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var accessibilityCopy: String {
        "Key Bump. \(event.actionTitle). \(event.applicationName). \(KeyboardShortcutRegistry.accessibilityCopy(for: event.shortcut))."
    }
}

enum ToastDismissalPolicy {
    static let minimumHorizontalSwipe: CGFloat = 60

    static func remainingDuration(initial: TimeInterval, elapsed: TimeInterval) -> TimeInterval {
        max(0, initial - max(0, elapsed))
    }

    static func shouldDismiss(for translation: NSSize) -> Bool {
        abs(translation.width) >= minimumHorizontalSwipe
            && abs(translation.width) > abs(translation.height)
    }
}
