import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ScreenshotEditorModel {
    var tool: ScreenshotEditorTool = .pixelate { didSet { onChange?() } }
    var color: ScreenshotAnnotationColor = .red { didSet { onChange?() } }
    private(set) var history = ScreenshotEditorHistory() { didSet { onChange?() } }
    var isEditingText = false
    @ObservationIgnored var onChange: (() -> Void)?

    func add(_ annotation: ScreenshotAnnotation) { history.add(annotation) }
    func undo() { history.undo() }
    func redo() { history.redo() }
}

/// Hosts the canvas and toolbar for one image. Save flattens, copies, and saves an
/// `(edited)` copy; Cancel discards. Never logs image content, text, or filenames.
@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    struct Result: Equatable {
        let savedURL: URL?
        let copied: Bool
    }

    private let source: ScreenshotRenderSource
    private let sourceURL: URL?
    private let fallbackFolder: URL
    private let pasteboard: NSPasteboard
    private let model = ScreenshotEditorModel()
    private let renderer = ScreenshotAnnotationRenderer()
    private let canvas: ScreenshotEditorCanvasView
    private var keyMonitor: Any?
    private var didFinish = false
    var onFinish: ((Result?) -> Void)?

    init(source: ScreenshotRenderSource, sourceURL: URL?, fallbackFolder: URL, pasteboard: NSPasteboard = .keybumps) {
        self.source = source
        self.sourceURL = sourceURL
        self.fallbackFolder = fallbackFolder
        self.pasteboard = pasteboard
        canvas = ScreenshotEditorCanvasView(source: source, model: model, renderer: renderer)

        let window = NSWindow(
            contentRect: Self.initialFrame(for: source.pointSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Screenshot"
        window.identifier = NSUserInterfaceItemIdentifier("screenshotEditor")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: Self.minimumWidth, height: 420)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        // One SwiftUI root (toolbar above the AppKit canvas) so the toolbar always renders.
        let root = NSHostingView(rootView: ScreenshotEditorRootView(
            model: model,
            canvas: canvas,
            cancel: { [weak self] in self?.cancel() },
            save: { [weak self] in self?.save() }
        ).uiTestAnimationsDisabled())
        window.contentView = root
        model.onChange = { [weak self] in self?.canvas.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        window?.center()
        window?.hideDuringUnitTests()
        if !UnitTestHost.isActive { NSApp.activate(ignoringOtherApps: true) }
        showWindow(nil)
        window?.makeFirstResponder(canvas)
        installKeyMonitor()
    }

    // MARK: Actions

    func save() {
        canvas.commitTextEditing()
        guard let flattened = renderer.export(source: source, annotations: model.history.annotations),
              let png = ScreenshotAnnotationRenderer.pngData(flattened, density: source.density) else {
            finish(nil)
            return
        }
        pasteboard.clearContents()
        let copied = pasteboard.setData(png, forType: .png)
        if copied { pasteboard.markCopiedByKeybumps() }
        let destination = ScreenshotEditorOutput.destination(sourceURL: sourceURL, fallbackFolder: fallbackFolder)
        let savedURL: URL? = (try? png.write(to: destination, options: .withoutOverwriting)) == nil ? nil : destination
        if savedURL == nil {
            let alert = NSAlert()
            alert.messageText = "Couldn’t save the edited copy"
            alert.informativeText = copied ? "The edited image is on the clipboard." : "The edited image could not be copied either."
            alert.runModal()
        }
        finish(Result(savedURL: savedURL, copied: copied))
    }

    func cancel() {
        if canvas.cancelTextEditing() { return }
        finish(nil)
    }

    private func finish(_ result: Result?) {
        guard !didFinish else { return }
        didFinish = true
        removeKeyMonitor()
        window?.orderOut(nil)
        onFinish?(result)
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let flags = Self.shortcutFlags(event.modifierFlags)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.keyCode == 53 { self.cancel(); return nil }
            if self.model.isEditingText { return event }
            if Self.isSaveKey(key, modifiers: event.modifierFlags) { self.save(); return nil }
            switch (flags, key) {
            case (.command, "z"): self.model.undo(); return nil
            case ([.command, .shift], "z"): self.model.redo(); return nil
            case ([], _):
                if let tool = Self.tool(forKey: key, modifiers: event.modifierFlags) { self.model.tool = tool; return nil }
                return event
            default:
                return event
            }
        }
    }

    /// Keypad digits carry .numericPad (and arrows .function); treat them like the main keys.
    static func shortcutFlags(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
    }

    /// Return or ⌘Return, including the keypad's Enter (also fn-Return), saves.
    static func isSaveKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = shortcutFlags(modifiers)
        return (key == "\r" || key == "\u{3}") && (flags.isEmpty || flags == .command)
    }

    /// Unmodified 1–5 or B/R/A/D/T select a tool; anything with Command, Option, or Control does not.
    static func tool(forKey key: String, modifiers: NSEvent.ModifierFlags) -> ScreenshotEditorTool? {
        guard shortcutFlags(modifiers).isEmpty else { return nil }
        return ScreenshotEditorTool.matching(key: key)
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Fits the whole toolbar, including the Cancel and Save key hints, without truncating.
    static let minimumWidth: CGFloat = 840
    static let toolbarHeight: CGFloat = 64

    private static func initialFrame(for imageSize: CGSize) -> NSRect {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8 - toolbarHeight)
        let scale = min(1, maxSize.width / max(imageSize.width, 1), maxSize.height / max(imageSize.height, 1))
        let width = max(minimumWidth, imageSize.width * scale + 32)
        let height = max(420, imageSize.height * scale + 32 + toolbarHeight)
        return NSRect(x: 0, y: 0, width: width, height: height)
    }
}

private struct ScreenshotEditorRootView: View {
    @Bindable var model: ScreenshotEditorModel
    let canvas: ScreenshotEditorCanvasView
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScreenshotEditorToolbar(model: model, cancel: cancel, save: save)
            CanvasHost(canvas: canvas)
        }
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: ScreenshotEditorCanvasView
    func makeNSView(context: Context) -> ScreenshotEditorCanvasView { canvas }
    func updateNSView(_ nsView: ScreenshotEditorCanvasView, context: Context) {}
}

private struct ScreenshotEditorToolbar: View {
    @Bindable var model: ScreenshotEditorModel
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(ScreenshotEditorTool.allCases) { tool in
                    ToolButton(tool: tool, isSelected: model.tool == tool) { model.tool = tool }
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 4) {
                ForEach(ScreenshotAnnotationColor.allCases) { color in
                    Button { model.color = color } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                            .padding(2)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.color == color ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(color.rawValue.capitalized)
                    .accessibilityLabel(color.rawValue.capitalized)
                }
            }
            .opacity(model.tool.usesColor ? 1 : 0.35)
            .disabled(!model.tool.usesColor)

            Spacer(minLength: 8)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.history.canUndo)
                .help("Undo (⌘Z)")
                .accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.history.canRedo)
                .help("Redo (⇧⌘Z)")
                .accessibilityLabel("Redo")
            Button(action: cancel) { ActionLabel(title: "Cancel", key: "esc") }
                .help("Discard changes (Esc)")
                .accessibilityLabel("Cancel")
            Button(action: save) { ActionLabel(title: "Save", key: "↵") }
                .buttonStyle(.borderedProminent)
                .help("Copy to clipboard and save an edited copy (Return)")
                .accessibilityLabel("Save")
        }
        .controlSize(.large)
        .padding(.horizontal, 12)
        .frame(height: ScreenshotEditorWindowController.toolbarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A toolbar action with the key that also triggers it. The keycap takes the button's own
/// text color, so it stays readable on the prominent Save button and in inactive windows.
private struct ActionLabel: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.tertiary, lineWidth: 0.75))
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

private struct ToolButton: View {
    let tool: ScreenshotEditorTool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 2) {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(tool.title)
                    .font(.caption2)
            }
            .frame(width: 58, height: 44)
            .overlay(alignment: .topTrailing) {
                Text(tool.number)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 13, height: 13)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isSelected ? Color.white.opacity(0.5) : Color.secondary.opacity(0.5), lineWidth: 0.75)
                    )
                    .padding(3)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(tool.number) or \(tool.key.uppercased()))")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Fits the image in the view and turns drags into annotations in image points.
@MainActor
final class ScreenshotEditorCanvasView: NSView, NSTextFieldDelegate {
    private let source: ScreenshotRenderSource
    private let model: ScreenshotEditorModel
    private let renderer: ScreenshotAnnotationRenderer
    private var inProgress: ScreenshotAnnotation?
    private var dragStart: CGPoint?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    init(source: ScreenshotRenderSource, model: ScreenshotEditorModel, renderer: ScreenshotAnnotationRenderer) {
        self.source = source
        self.model = model
        self.renderer = renderer
        super.init(frame: .zero)
        // macOS 14 no longer clips views by default, and dirty rects can extend past
        // bounds; without this the canvas background painted over the toolbar.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    private var fitScale: CGFloat {
        let available = bounds.insetBy(dx: 16, dy: 16).size
        return min(available.width / max(source.pointSize.width, 1), available.height / max(source.pointSize.height, 1), 2)
    }

    private var imageRect: CGRect {
        let scale = fitScale
        let size = CGSize(width: source.pointSize.width * scale, height: source.pointSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        let scale = fitScale
        let x = min(max((point.x - rect.minX) / scale, 0), source.pointSize.width)
        let y = min(max((point.y - rect.minY) / scale, 0), source.pointSize.height)
        return CGPoint(x: x, y: y)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: fitScale, y: fitScale)
        var annotations = model.history.annotations
        if let inProgress, !inProgress.isRedaction || isRedactRect(inProgress) { annotations.append(inProgress) }
        renderer.draw(source: source, annotations: annotations, in: ctx)
        if let inProgress, case .pixelate(let pixelRect) = inProgress.kind {
            // The mosaic renders when the drag ends; show its footprint meanwhile.
            ctx.setFillColor(NSColor.gray.withAlphaComponent(0.55).cgColor)
            ctx.fill(pixelRect.standardized)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1 / fitScale)
            ctx.setLineDash(phase: 0, lengths: [4 / fitScale, 3 / fitScale])
            ctx.stroke(pixelRect.standardized)
        }
        ctx.restoreGState()
    }

    private func isRedactRect(_ annotation: ScreenshotAnnotation) -> Bool {
        if case .redact = annotation.kind { return true }
        return false
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        let point = imagePoint(for: event)
        dragStart = point
        switch model.tool {
        case .pixelate: inProgress = ScreenshotAnnotation(kind: .pixelate(CGRect(origin: point, size: .zero)))
        case .redact: inProgress = ScreenshotAnnotation(kind: .redact(CGRect(origin: point, size: .zero)))
        case .arrow: inProgress = ScreenshotAnnotation(kind: .arrow(start: point, end: point), color: model.color)
        case .draw: inProgress = ScreenshotAnnotation(kind: .freehand([point]), color: model.color)
        case .text:
            inProgress = nil
            beginTextEditing(at: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, var annotation = inProgress else { return }
        let point = imagePoint(for: event)
        switch annotation.kind {
        case .pixelate: annotation.kind = .pixelate(Self.rect(from: start, to: point))
        case .redact: annotation.kind = .redact(Self.rect(from: start, to: point))
        case .arrow(let origin, _): annotation.kind = .arrow(start: origin, end: point)
        case .freehand(var points):
            points.append(point)
            annotation.kind = .freehand(points)
        case .text: break
        }
        inProgress = annotation
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let inProgress { model.add(inProgress) }
        inProgress = nil
        dragStart = nil
        needsDisplay = true
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: Text

    private let fontSize: CGFloat = 24

    private func beginTextEditing(at point: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .boldSystemFont(ofSize: fontSize * fitScale)
        field.textColor = model.color.nsColor
        field.placeholderString = "Text"
        field.delegate = self
        let rect = imageRect
        field.frame = NSRect(x: rect.minX + point.x * fitScale, y: rect.minY + point.y * fitScale, width: 240, height: fontSize * fitScale * 1.4)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textOrigin = point
        model.isEditingText = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width + 12, 240)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            _ = cancelTextEditing()
            return true
        }
        return false
    }

    func commitTextEditing() {
        guard let field = textField, let origin = textOrigin else { return }
        let string = field.stringValue
        endTextEditing()
        model.add(ScreenshotAnnotation(kind: .text(origin: origin, string: string), color: model.color, fontSize: fontSize))
    }

    /// Returns true when there was text editing to cancel.
    func cancelTextEditing() -> Bool {
        guard textField != nil else { return false }
        endTextEditing()
        return true
    }

    private func endTextEditing() {
        textField?.delegate = nil
        textField?.removeFromSuperview()
        textField = nil
        textOrigin = nil
        model.isEditingText = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
