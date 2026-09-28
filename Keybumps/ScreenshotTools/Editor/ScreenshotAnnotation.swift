import AppKit

/// Editor tools for the v1 Screenshot Tools markup editor.
enum ScreenshotEditorTool: String, CaseIterable, Identifiable {
    case pixelate, redact, arrow, draw, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .redact: "Redact"
        case .arrow: "Arrow"
        case .draw: "Draw"
        case .text: "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .pixelate: "square.grid.3x3.fill"
        case .redact: "rectangle.fill"
        case .arrow: "arrow.up.right"
        case .draw: "pencil.tip"
        case .text: "textformat"
        }
    }

    /// Single-key shortcut shown in tooltips and handled by the canvas.
    var key: String {
        switch self {
        case .pixelate: "p"
        case .redact: "r"
        case .arrow: "a"
        case .draw: "d"
        case .text: "t"
        }
    }

    static func matching(key: String) -> ScreenshotEditorTool? {
        allCases.first { $0.key == key.lowercased() }
    }

    /// Redaction tools cover content and ignore the selected color.
    var usesColor: Bool { self == .arrow || self == .draw || self == .text }
}

enum ScreenshotAnnotationColor: String, CaseIterable, Identifiable {
    case red, yellow, green, blue, black, white

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .black: .black
        case .white: .white
        }
    }
}

/// One mark in image points, top-left origin. Value type so undo is a snapshot.
/// Model shape follows Skritch (MIT); drawing and redaction follow Shotnix (MIT).
/// See docs/provenance/donor-ledger.md.
struct ScreenshotAnnotation: Equatable, Identifiable {
    enum Kind: Equatable {
        case pixelate(CGRect)
        case redact(CGRect)
        case arrow(start: CGPoint, end: CGPoint)
        case freehand([CGPoint])
        case text(origin: CGPoint, string: String)
    }

    let id: UUID
    var kind: Kind
    var color: ScreenshotAnnotationColor
    var lineWidth: CGFloat
    var fontSize: CGFloat

    init(
        id: UUID = UUID(),
        kind: Kind,
        color: ScreenshotAnnotationColor = .red,
        lineWidth: CGFloat = 4,
        fontSize: CGFloat = 24
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }

    var isRedaction: Bool {
        switch kind {
        case .pixelate, .redact: true
        case .arrow, .freehand, .text: false
        }
    }

    /// Marks too small to mean anything are discarded when a gesture ends.
    var isMeaningful: Bool {
        switch kind {
        case .pixelate(let rect), .redact(let rect):
            return rect.standardized.width >= 3 && rect.standardized.height >= 3
        case .arrow(let start, let end):
            return hypot(end.x - start.x, end.y - start.y) >= 6
        case .freehand(let points):
            return points.count >= 2
        case .text(_, let string):
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Snapshot undo/redo, one step per completed gesture, capped like Shotnix.
struct ScreenshotEditorHistory: Equatable {
    static let limit = 100

    private(set) var annotations: [ScreenshotAnnotation] = []
    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { annotations.isEmpty }

    mutating func add(_ annotation: ScreenshotAnnotation) {
        guard annotation.isMeaningful else { return }
        record()
        annotations.append(annotation)
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    private mutating func record() {
        undoStack.append(annotations)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
    }
}
