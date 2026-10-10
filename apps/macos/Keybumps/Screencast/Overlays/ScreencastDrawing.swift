import AppKit

/// What a mark is drawn with while recording.
enum ScreencastDrawingTool: String, CaseIterable, Identifiable {
    case pen, arrow, highlighter, rectangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .arrow: "Arrow"
        case .highlighter: "Highlighter"
        case .rectangle: "Rectangle"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .highlighter: "highlighter"
        case .rectangle: "rectangle"
        }
    }

    /// The line's width in points. The highlighter's is wide and see-through.
    var lineWidth: CGFloat {
        switch self {
        case .pen, .arrow, .rectangle: 4
        case .highlighter: 18
        }
    }
}

/// The colors a mark can have.
enum ScreencastDrawingColor: String, CaseIterable, Identifiable {
    case red, yellow, green, blue, white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .white: "White"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .white: .white
        }
    }
}

/// Whether a mark goes by itself a few seconds after it's drawn, or stays until it's cleared.
enum ScreencastMarkLifetime: String, CaseIterable, Identifiable {
    case fades, stays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fades: "Fade"
        case .stays: "Stay"
        }
    }
}

/// How the next mark is drawn: the drawing tools' choices. Each mark keeps the ones it was drawn
/// with, so changing them never changes a mark already on screen.
struct ScreencastDrawingStyle: Equatable {
    var tool: ScreencastDrawingTool = .pen
    var color: ScreencastDrawingColor = .red
    var lifetime: ScreencastMarkLifetime = .fades
}

/// One mark on one display, in that display's points from its top-left corner.
struct ScreencastMark: Equatable, Identifiable {
    enum Kind: Equatable {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case arrow(start: CGPoint, end: CGPoint)
        /// Two opposite corners: where the drag started and where it is.
        case rectangle(from: CGPoint, to: CGPoint)
    }

    let id: UUID
    let display: CGDirectDisplayID
    var kind: Kind
    let color: ScreencastDrawingColor
    let lifetime: ScreencastMarkLifetime
    /// When the pointer lifted, in the drawing clock's seconds; nil while it's being drawn. A mark
    /// that fades starts its time then.
    var finishedAt: TimeInterval?

    init(
        id: UUID = UUID(),
        display: CGDirectDisplayID,
        kind: Kind,
        color: ScreencastDrawingColor = .red,
        lifetime: ScreencastMarkLifetime = .fades,
        finishedAt: TimeInterval? = nil
    ) {
        self.id = id
        self.display = display
        self.kind = kind
        self.color = color
        self.lifetime = lifetime
        self.finishedAt = finishedAt
    }

    var tool: ScreencastDrawingTool {
        switch kind {
        case .pen: .pen
        case .highlighter: .highlighter
        case .arrow: .arrow
        case .rectangle: .rectangle
        }
    }

    var lineWidth: CGFloat { tool.lineWidth }

    /// A rectangle's frame, however it was dragged.
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Everything the mark draws on, its line and an arrow's head included, so a redraw of this
    /// part of the screen covers it.
    var bounds: CGRect {
        let outline: CGRect
        let margin: CGFloat
        switch kind {
        case .pen(let points), .highlighter(let points):
            outline = Self.boundingBox(of: points)
            margin = lineWidth / 2 + 2
        case .arrow(let start, let end):
            outline = Self.rect(from: start, to: end)
            margin = ScreenshotAnnotationRenderer.arrowHeadLength(lineWidth: lineWidth) + lineWidth
        case .rectangle(let start, let end):
            outline = Self.rect(from: start, to: end)
            margin = lineWidth / 2 + 2
        }
        return outline.insetBy(dx: -margin, dy: -margin)
    }

    /// Marks too small to mean anything, such as a click with the arrow, are dropped when the
    /// pointer lifts.
    var isMeaningful: Bool {
        switch kind {
        case .pen(let points), .highlighter(let points):
            return points.count >= 2
        case .arrow(let start, let end):
            return hypot(end.x - start.x, end.y - start.y) >= 6
        case .rectangle(let start, let end):
            let rect = Self.rect(from: start, to: end)
            return rect.width >= 3 && rect.height >= 3
        }
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var (minX, minY, maxX, maxY) = (first.x, first.y, first.x, first.y)
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A mark as it's drawn right now.
struct ScreencastVisibleMark: Equatable {
    let mark: ScreencastMark
    /// 0…1: below 1 while it fades.
    let opacity: Double
}

/// The marks on screen while recording, across every recorded display: the finished ones, oldest
/// first, and the one being drawn. A value type that's told the time, so fading is tested with
/// made-up times; the overlays hold it and give it their clock.
///
/// After Snapzy's `RecordingAnnotationState` (BSD-3-Clause, see LICENSE.snapzy): marks kept with
/// how they were drawn and when, cleared all at once or by time, with a short fade just before
/// they go; and hop's `FadingInk` (MIT, see LICENSE.hop): an opacity asked for at a time rather
/// than a timer per mark, and nothing to tick while nothing fades.
struct ScreencastDrawing: Equatable {
    /// Seconds a fading mark stays at full strength once the pointer lifts.
    static let life: TimeInterval = 3
    /// Seconds it then takes to fade out.
    static let fade: TimeInterval = 0.5
    /// The pen and highlighter skip a point closer than this to the last one.
    static let minimumStep: CGFloat = 1

    private(set) var marks: [ScreencastMark] = []
    /// The mark being drawn: from the press to the release.
    private(set) var current: ScreencastMark?

    var isEmpty: Bool { marks.isEmpty && current == nil }

    // MARK: Drawing a mark

    /// The pointer went down: a new mark at `point`, drawn with `style`. A mark still being drawn
    /// is dropped.
    mutating func begin(at point: CGPoint, on display: CGDirectDisplayID, style: ScreencastDrawingStyle) {
        let kind: ScreencastMark.Kind = switch style.tool {
        case .pen: .pen([point])
        case .highlighter: .highlighter([point])
        case .arrow: .arrow(start: point, end: point)
        case .rectangle: .rectangle(from: point, to: point)
        }
        current = ScreencastMark(display: display, kind: kind, color: style.color, lifetime: style.lifetime)
    }

    /// The pointer moved to `point` while down. Returns the part of the display to redraw, or nil
    /// when nothing changed.
    @discardableResult
    mutating func extend(to point: CGPoint) -> CGRect? {
        guard var mark = current else { return nil }
        let before = mark.bounds
        switch mark.kind {
        case .pen(var points):
            guard Self.isStep(from: points.last, to: point) else { return nil }
            points.append(point)
            mark.kind = .pen(points)
        case .highlighter(var points):
            guard Self.isStep(from: points.last, to: point) else { return nil }
            points.append(point)
            mark.kind = .highlighter(points)
        case .arrow(let start, let end):
            guard end != point else { return nil }
            mark.kind = .arrow(start: start, end: point)
        case .rectangle(let start, let end):
            guard end != point else { return nil }
            mark.kind = .rectangle(from: start, to: point)
        }
        current = mark
        return before.union(mark.bounds)
    }

    /// The pointer lifted at `now`: the mark is kept if it means anything. Returns the mark that
    /// ended, kept or not, so its part of the screen can be redrawn.
    @discardableResult
    mutating func finish(at now: TimeInterval) -> ScreencastMark? {
        guard var mark = current else { return nil }
        current = nil
        mark.finishedAt = now
        if mark.isMeaningful { marks.append(mark) }
        return mark
    }

    /// Drops the mark being drawn, as when drawing ends mid-stroke.
    @discardableResult
    mutating func cancel() -> ScreencastMark? {
        defer { current = nil }
        return current
    }

    // MARK: Clearing

    /// Removes the last finished mark, and returns it.
    @discardableResult
    mutating func undo() -> ScreencastMark? {
        marks.popLast()
    }

    /// Removes every mark, the one being drawn too, and returns them.
    @discardableResult
    mutating func clear() -> [ScreencastMark] {
        let removed = marks + [current].compactMap { $0 }
        marks.removeAll()
        current = nil
        return removed
    }

    /// Removes the marks that have faded out by `now`, and returns them.
    @discardableResult
    mutating func removeExpired(at now: TimeInterval) -> [ScreencastMark] {
        let expired = marks.filter { Self.opacity(of: $0, at: now) <= 0 }
        guard !expired.isEmpty else { return [] }
        marks.removeAll { Self.opacity(of: $0, at: now) <= 0 }
        return expired
    }

    // MARK: Fading

    /// How strongly `mark` shows at `now`: fully while it's drawn and for `life` seconds after,
    /// then less and less over `fade` seconds. A mark that stays always shows fully.
    static func opacity(of mark: ScreencastMark, at now: TimeInterval) -> Double {
        guard mark.lifetime == .fades, let finishedAt = mark.finishedAt else { return 1 }
        let age = now - finishedAt
        if age <= life { return 1 }
        if age >= life + fade { return 0 }
        return 1 - (age - life) / fade
    }

    /// What `display` shows at `now`, oldest first, the mark being drawn last.
    func visibleMarks(on display: CGDirectDisplayID, at now: TimeInterval) -> [ScreencastVisibleMark] {
        (marks + [current].compactMap { $0 })
            .filter { $0.display == display }
            .map { ScreencastVisibleMark(mark: $0, opacity: Self.opacity(of: $0, at: now)) }
            .filter { $0.opacity > 0 }
    }

    /// The finished marks fading at `now`: the ones to redraw as time passes.
    func fadingMarks(at now: TimeInterval) -> [ScreencastMark] {
        marks.filter { Self.opacity(of: $0, at: now) < 1 }
    }

    /// Whether anything on screen will still change by itself: a mark that fades and hasn't gone.
    func needsTicking(at now: TimeInterval) -> Bool {
        marks.contains { $0.lifetime == .fades && Self.opacity(of: $0, at: now) > 0 }
    }

    private static func isStep(from last: CGPoint?, to point: CGPoint) -> Bool {
        guard let last else { return true }
        return hypot(point.x - last.x, point.y - last.y) >= minimumStep
    }
}
