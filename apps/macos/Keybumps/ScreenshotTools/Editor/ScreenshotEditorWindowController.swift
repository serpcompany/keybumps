import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ScreenshotEditorModel {
    /// Opens on the first tool, Arrow (#544).
    var tool: ScreenshotEditorTool = .arrow { didSet { onChange?() } }
    var color: ScreenshotAnnotationColor = .red { didSet { onChange?() } }
    private(set) var history = ScreenshotEditorHistory() { didSet { onChange?() } }
    var isEditingText = false
    @ObservationIgnored var onChange: (() -> Void)?

    func add(_ annotation: ScreenshotAnnotation) { history.add(annotation) }
    func undo() { history.undo() }
    func redo() { history.redo() }
}

/// Hosts the canvas and editor bar for one image. Save flattens, copies, and saves an
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

        // One SwiftUI root (the editor bar above the AppKit canvas) so the bar always renders.
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

    /// Unmodified 1–5 or A/T/D/B/R select a tool; anything with Command, Option, or Control does not.
    static func tool(forKey key: String, modifiers: NSEvent.ModifierFlags) -> ScreenshotEditorTool? {
        guard shortcutFlags(modifiers).isEmpty else { return nil }
        return ScreenshotEditorTool.matching(key: key)
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The bar's actions: Cancel (Esc), then Save (Return), filled with the accent color. Return is
    /// the key monitor's (`isSaveKey`), so Save isn't the window's default button.
    static func barActions(cancel: @escaping () -> Void, save: @escaping () -> Void) -> [ScreengrabsEditorAction] {
        [
            ScreengrabsEditorAction(title: "Cancel", key: "esc", help: "Discard changes (Esc)", perform: cancel),
            ScreengrabsEditorAction(
                title: "Save", key: ScreengrabsEditorAction.returnSign, style: .prominent,
                help: "Copy to clipboard and save an edited copy (Return)", perform: save
            ),
        ]
    }

    /// Fits the whole bar, including the Cancel and Save key hints, without truncating.
    static let minimumWidth: CGFloat = 840
    static let barHeight: CGFloat = ScreengrabsEditorBarMetrics.height

    private static func initialFrame(for imageSize: CGSize) -> NSRect {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8 - barHeight)
        let scale = min(1, maxSize.width / max(imageSize.width, 1), maxSize.height / max(imageSize.height, 1))
        let width = max(minimumWidth, imageSize.width * scale + 32)
        let height = max(420, imageSize.height * scale + 32 + barHeight)
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
            ScreenshotEditorBar(model: model, cancel: cancel, save: save)
            CanvasHost(canvas: canvas)
        }
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: ScreenshotEditorCanvasView
    func makeNSView(context: Context) -> ScreenshotEditorCanvasView { canvas }
    func updateNSView(_ nsView: ScreenshotEditorCanvasView, context: Context) {}
}

/// The editor's bar (`ScreengrabsEditorBar`, shared with the recording window): the tools and the
/// colors, then undo and redo, Cancel, and Save.
struct ScreenshotEditorBar: View {
    @Bindable var model: ScreenshotEditorModel
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        ScreengrabsEditorBar(
            history: history,
            actions: ScreenshotEditorWindowController.barActions(cancel: cancel, save: save)
        ) {
            ScreengrabsEditorTools {
                ForEach(tools, id: \.title) { $0 }
            }

            HStack(spacing: 4) {
                ForEach(swatches, id: \.color) { $0 }
            }
            .opacity(swatchesAreEnabled ? 1 : 0.35)
            .disabled(!swatchesAreEnabled)
        }
    }

    /// Undo and redo, from the model's history.
    var history: ScreengrabsEditorHistory? {
        ScreengrabsEditorHistory(
            canUndo: model.history.canUndo,
            canRedo: model.history.canRedo,
            undo: { model.undo() },
            redo: { model.redo() }
        )
    }

    /// A button for each tool, in order, the model's tool picked.
    var tools: [ScreengrabsEditorToolButton] {
        ScreenshotEditorTool.allCases.map { tool in
            ScreengrabsEditorToolButton(
                title: tool.title,
                systemImage: tool.systemImage,
                number: tool.number,
                key: tool.key,
                isSelected: model.tool == tool
            ) { model.tool = tool }
        }
    }

    /// A swatch for each color, the model's color picked.
    var swatches: [ScreenshotEditorSwatch] {
        ScreenshotAnnotationColor.allCases.map { color in
            ScreenshotEditorSwatch(color: color, isSelected: model.color == color) { model.color = color }
        }
    }

    /// The colors are for the tools that draw in one: dimmed and off for the others.
    var swatchesAreEnabled: Bool { model.tool.usesColor }
}

/// One color in the editor's bar, ringed with the accent color while it's picked.
struct ScreenshotEditorSwatch: View {
    let color: ScreenshotAnnotationColor
    let isSelected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            Circle()
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(color.rawValue.capitalized)
        .accessibilityLabel(color.rawValue.capitalized)
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
        // bounds; without this the canvas background painted over the editor bar.
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
