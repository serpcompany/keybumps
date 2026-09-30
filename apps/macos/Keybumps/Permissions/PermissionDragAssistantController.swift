import AppKit
import SwiftUI

enum ApplicationBundleDragPayload {
    static func write(_ applicationURL: URL, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([applicationURL as NSURL])
    }

    static func shouldDismiss(after operation: NSDragOperation) -> Bool {
        !operation.isEmpty
    }
}

enum PermissionAssistantCopy {
    static let title = "Keybumps"
    static let dragInstruction = "Drag this card into the app list above"

    static func switchInstruction(for permission: MacPermission) -> String {
        "Turn on the \(permission.title) switch in the list above."
    }

    /// Keybumps can't tell whether the user turned the permission on, so the card asks.
    static func systemSettingsFollowUp(for permission: MacPermission) -> String {
        "Turned on \(permission.title) for Keybumps? Restart to finish."
    }
}

@MainActor
final class PermissionDragAssistantController {
    /// The card on screen, if any.
    enum Presentation: Equatable {
        case applicationDrag(MacPermission)
        case enableSwitch(MacPermission)
        case dictationSetup([MacPermission])
        case systemSettingsFollowUp(MacPermission)
    }

    private var panel: NSPanel?
    private(set) var presentation: Presentation?

    func show(for permission: MacPermission) {
        guard permission.usesApplicationDragAssistant else { return }
        presentation = .applicationDrag(permission)
        if panel == nil { makePanel() }
        updateDragContent()
        positionPanel()
        panel?.hideDuringUnitTests()
        panel?.orderFrontRegardless()
    }

    func showEnableSwitch(for permission: MacPermission) {
        guard !permission.usesApplicationDragAssistant else { return }
        presentation = .enableSwitch(permission)
        if panel == nil { makePanel() }
        updateSwitchContent(for: permission)
        positionPanel()
        panel?.hideDuringUnitTests()
        panel?.orderFrontRegardless()
    }

    /// After System Settings was opened for `permission` and it's still missing: offers both Open
    /// System Settings… and Restart Keybumps, since macOS sometimes applies a new grant only after
    /// a relaunch and Keybumps can't tell. The panel doesn't activate Keybumps, so this shows while
    /// the Settings window is closed.
    func showSystemSettingsFollowUp(
        for permission: MacPermission,
        openSystemSettings: @escaping () -> Void,
        restart: @escaping () -> Void
    ) {
        presentation = .systemSettingsFollowUp(permission)
        if panel == nil { makePanel() }
        panel?.contentViewController = NSHostingController(
            rootView: PermissionFollowUpAssistantView(
                permission: permission,
                openSystemSettings: { [weak self] in
                    self?.dismiss()
                    openSystemSettings()
                },
                restart: restart,
                dismiss: { [weak self] in self?.dismiss() }
            )
            .frame(width: 560, height: 92)
        )
        positionPanel()
        panel?.hideDuringUnitTests()
        panel?.orderFrontRegardless()
    }

    func showDictationSetup(
        missingPermissions: [MacPermission],
        onContinue: @escaping () -> Void
    ) {
        presentation = .dictationSetup(missingPermissions)
        if panel == nil { makePanel() }
        panel?.contentViewController = NSHostingController(
            rootView: DictationSetupAssistantView(
                missingPermissions: missingPermissions,
                continueSetup: { [weak self] in
                    self?.dismiss()
                    onContinue()
                },
                dismiss: dismiss
            )
            .frame(width: 560, height: 92)
        )
        positionPanel()
        panel?.hideDuringUnitTests()
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        presentation = nil
    }

    /// Dismisses a card about one permission once macOS reports it granted.
    func dismissIfGranted(using coordinator: PermissionCoordinator) {
        let permission: MacPermission? = switch presentation {
        case .applicationDrag(let permission), .enableSwitch(let permission), .systemSettingsFollowUp(let permission): permission
        case .dictationSetup, nil: nil
        }
        guard let permission, coordinator.state(for: permission).isGranted else { return }
        dismiss()
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel
    }

    private func updateDragContent() {
        panel?.contentViewController = NSHostingController(
            rootView: PermissionDragAssistantView(
                applicationURL: Bundle.main.bundleURL,
                dismiss: dismiss
            )
            .frame(width: 560, height: 92)
        )
    }

    private func updateSwitchContent(for permission: MacPermission) {
        panel?.contentViewController = NSHostingController(
            rootView: PermissionSwitchAssistantView(
                permission: permission,
                dismiss: dismiss
            )
            .frame(width: 560, height: 92)
        )
    }

    private func positionPanel() {
        guard let panel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let x = screen.visibleFrame.midX - panel.frame.width / 2
        let y = screen.visibleFrame.minY + 34
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct DictationSetupAssistantView: View {
    let missingPermissions: [MacPermission]
    let continueSetup: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 12) {
                PermissionAssistantAppIcon()
                VStack(alignment: .leading, spacing: 3) {
                    Text(PermissionAssistantCopy.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text("Set up \(permissionNames) to use Dictation.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up Dictation…", action: continueSetup)
                    .buttonStyle(.borderedProminent)
                    .padding(.trailing, 28)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(PermissionAssistantCardStyle())

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.16), in: Circle())
            }
            .buttonStyle(.borderless)
            .padding(10)
            .accessibilityLabel("Close Dictation setup")
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation needs \(permissionNames)")
    }

    private var permissionNames: String {
        MacPermission.names(missingPermissions)
    }
}

private struct PermissionSwitchAssistantView: View {
    let permission: MacPermission
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 12) {
                PermissionAssistantAppIcon()
                VStack(alignment: .leading, spacing: 3) {
                    Text(PermissionAssistantCopy.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(PermissionAssistantCopy.switchInstruction(for: permission))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 34)
                Image(systemName: "switch.2")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(PermissionAssistantCardStyle())

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.16), in: Circle())
            }
            .buttonStyle(.borderless)
            .padding(10)
            .accessibilityLabel("Close permission helper")
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enable \(permission.title) for Keybumps in System Settings")
    }
}

struct PermissionFollowUpAssistantView: View {
    let permission: MacPermission
    let openSystemSettings: () -> Void
    let restart: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 12) {
                PermissionAssistantAppIcon()
                VStack(alignment: .leading, spacing: 3) {
                    Text(PermissionAssistantCopy.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(PermissionAssistantCopy.systemSettingsFollowUp(for: permission))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Open System Settings…", action: openSystemSettings)
                Button("Restart Keybumps", action: restart)
                    .buttonStyle(.borderedProminent)
                    .padding(.trailing, 28)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(PermissionAssistantCardStyle())

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.16), in: Circle())
            }
            .buttonStyle(.borderless)
            .padding(10)
            .accessibilityLabel("Close permission follow-up")
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PermissionAssistantCopy.systemSettingsFollowUp(for: permission))
    }
}

private struct PermissionAssistantAppIcon: View {
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path))
            .resizable()
            .scaledToFit()
            .frame(width: 42, height: 42)
    }
}

private struct PermissionAssistantCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.78),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}

private struct PermissionDragAssistantView: View {
    let applicationURL: URL
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ApplicationBundleDragSource(
                applicationURL: applicationURL,
                onAcceptedDrop: dismiss
            )
            .accessibilityLabel("Keybumps application")
            .accessibilityHint("Drag this application into the System Settings list above")

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.16), in: Circle())
            }
            .buttonStyle(.borderless)
            .padding(10)
            .accessibilityLabel("Close permission helper")
        }
        .padding(6)
    }
}

private struct ApplicationBundleDragSource: NSViewRepresentable {
    let applicationURL: URL
    let onAcceptedDrop: () -> Void

    func makeNSView(context: Context) -> ApplicationBundleDragSourceView {
        ApplicationBundleDragSourceView(
            applicationURL: applicationURL,
            onAcceptedDrop: onAcceptedDrop
        )
    }

    func updateNSView(_ nsView: ApplicationBundleDragSourceView, context: Context) {
        nsView.update(
            applicationURL: applicationURL,
            onAcceptedDrop: onAcceptedDrop
        )
    }
}

@MainActor
private final class ApplicationBundleDragSourceView: NSView, NSDraggingSource {
    private var applicationURL: URL
    private var onAcceptedDrop: () -> Void
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: PermissionAssistantCopy.title)
    private let instructionField = NSTextField(labelWithString: PermissionAssistantCopy.dragInstruction)
    private let dragIconView = NSImageView()
    private var mouseDownLocation: NSPoint?
    private var hasStartedDrag = false
    private var isHovering = false

    init(applicationURL: URL, onAcceptedDrop: @escaping () -> Void) {
        self.applicationURL = applicationURL
        self.onAcceptedDrop = onAcceptedDrop
        super.init(frame: .zero)
        buildView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    func update(applicationURL: URL, onAcceptedDrop: @escaping () -> Void) {
        self.applicationURL = applicationURL
        self.onAcceptedDrop = onAcceptedDrop
        iconView.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        hasStartedDrag = false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedDrag, let mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - mouseDownLocation.x, current.y - mouseDownLocation.y) >= 4 else { return }
        hasStartedDrag = true

        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(bounds, contents: snapshot())
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        hasStartedDrag = false
        NSCursor.openHand.set()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownLocation = nil
        hasStartedDrag = false
        if ApplicationBundleDragPayload.shouldDismiss(after: operation) {
            NSCursor.arrow.set()
            onAcceptedDrop()
        } else {
            NSCursor.openHand.set()
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func buildView() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        updateAppearance()

        iconView.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        instructionField.font = .systemFont(ofSize: 11)
        instructionField.textColor = .secondaryLabelColor
        instructionField.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [titleField, instructionField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        dragIconView.image = NSImage(
            systemSymbolName: "hand.draw.fill",
            accessibilityDescription: "Drag"
        )
        dragIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        dragIconView.contentTintColor = .controlAccentColor
        dragIconView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)
        addSubview(dragIconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: dragIconView.leadingAnchor, constant: -12),
            dragIconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -50),
            dragIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragIconView.widthAnchor.constraint(equalToConstant: 24),
            dragIconView.heightAnchor.constraint(equalToConstant: 24)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag Keybumps into System Settings")
        setAccessibilityHelp("Drag this entire card into the app list above")
    }

    private func updateAppearance() {
        layer?.backgroundColor = (
            isHovering
                ? NSColor.controlAccentColor.withAlphaComponent(0.14)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.78)
        ).cgColor
        layer?.borderColor = (
            isHovering
                ? NSColor.controlAccentColor.withAlphaComponent(0.7)
                : NSColor.separatorColor
        ).cgColor
    }

    private func snapshot() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSWorkspace.shared.icon(forFile: applicationURL.path)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}
