import SwiftUI

/// Where times sit across the timeline: the whole recording from `inset` to `width - inset`.
struct ScreencastTimelineGeometry: Equatable {
    static let inset: CGFloat = 16

    let duration: Double
    let width: CGFloat

    var trackWidth: CGFloat { max(width - Self.inset * 2, 1) }

    func x(_ time: Double) -> CGFloat {
        guard duration > 0 else { return Self.inset }
        return Self.inset + CGFloat(min(max(time, 0), duration) / duration) * trackWidth
    }

    func time(atX x: CGFloat) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(Double((x - Self.inset) / trackWidth) * duration, 0), duration)
    }

    /// The seconds between labeled ticks: the first of the usual steps at least `minimumSpacing`
    /// points apart.
    func labelStep(minimumSpacing: CGFloat = 70) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
        let pointsPerSecond = duration > 0 ? Double(trackWidth) / duration : 0
        return steps.first { $0 * pointsPerSecond >= Double(minimumSpacing) } ?? steps[steps.count - 1]
    }
}

/// Trim's timeline under the player (#517), after QuickTime's trim: a ruler, then the recording's
/// frames in a strip with a yellow frame around the part kept. Drag a handle to trim an end; the
/// trimmed ends stay on the strip, dimmed, so they can be dragged back. Drag across the strip to
/// select a part, then Cut Section or ⌫ cuts it; a cut stays on the strip, hatched, with Restore. A
/// click on the strip or the ruler moves the playhead there.
///
/// Blur opens it too, without the trim's frame: the shown display's blurs have their bars under the
/// strip (`ScreencastBlurLanes`), and a click or drag on the strip moves the playhead.
struct ScreencastTrimTimeline: View {
    /// Its height without blurs' bars.
    static let height: CGFloat = 104
    static let rulerTop: CGFloat = 8
    static let stripTop: CGFloat = 36
    static let stripHeight: CGFloat = 52
    static let handleWidth: CGFloat = 12

    let model: ScreencastReviewModel
    let playback: ScreencastReviewPlayback?

    /// Where a drag across the strip started, in the recording's time.
    @State private var selectionStart: Double?

    /// Its height with `lanes` blurs' bars under the strip.
    static func height(blurLanes lanes: Int) -> CGFloat {
        lanes == 0 ? height : stripTop + stripHeight + 4 + ScreencastBlurLanes.height(lanes: lanes) + 8
    }

    private var isTrimming: Bool { model.tool == .trim }

    var body: some View {
        let height = Self.height(blurLanes: model.blurs.count)
        GeometryReader { proxy in
            let geometry = ScreencastTimelineGeometry(duration: model.edits.duration, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                ruler(geometry)
                strip(geometry)
                if !model.blurs.isEmpty {
                    ScreencastBlurLanes(model: model, geometry: geometry, isEditable: model.tool == .blur)
                        .offset(y: Self.stripTop + Self.stripHeight + 4)
                }
                if isTrimming {
                    trimFrame(geometry)
                    pills(geometry)
                }
                ScreencastTimelinePlayhead(playback: playback, geometry: geometry, height: height - 12)
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: height)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
        .accessibilityIdentifier(ScreencastReviewID.timeline)
    }

    // MARK: Ruler

    private func ruler(_ geometry: ScreencastTimelineGeometry) -> some View {
        let step = geometry.labelStep()
        return Canvas { context, size in
            guard geometry.duration > 0 else { return }
            let minor = step / 5
            var tick = 0.0
            var index = 0
            while tick <= geometry.duration + 0.0001 {
                let isMajor = index % 5 == 0
                let x = geometry.x(tick)
                let height: CGFloat = isMajor ? 9 : 4
                context.fill(
                    Path(CGRect(x: x, y: size.height - height, width: 1, height: height)),
                    with: .color(isMajor ? .secondary : Color.secondary.opacity(0.5))
                )
                if isMajor, tick < geometry.duration - step / 4 {
                    context.draw(
                        Text(ScreencastEditTime.format(tick)).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary),
                        at: CGPoint(x: x + 4, y: 5), anchor: .leading
                    )
                }
                index += 1
                tick = Double(index) * minor
            }
        }
        .frame(width: geometry.width, height: 20)
        .offset(y: Self.rulerTop)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            playback?.seek(toRecordingTime: geometry.time(atX: location.x))
        }
        .accessibilityHidden(true)
    }

    // MARK: Strip

    private func strip(_ geometry: ScreencastTimelineGeometry) -> some View {
        let edits = model.edits
        let width = geometry.trackWidth
        return ZStack(alignment: .topLeading) {
            filmstrip(width: width)
            // Trimmed off: dimmed, still there to drag back.
            Color.black.opacity(0.62)
                .frame(width: geometry.x(edits.trim.start) - ScreencastTimelineGeometry.inset)
            Color.black.opacity(0.62)
                .frame(width: max(geometry.x(edits.duration) - geometry.x(edits.trim.end), 0))
                .offset(x: geometry.x(edits.trim.end) - ScreencastTimelineGeometry.inset)
            ForEach(edits.cuts, id: \.self) { cut in
                ScreencastCutHatch()
                    .frame(width: max(geometry.x(cut.end) - geometry.x(cut.start), 1))
                    .offset(x: geometry.x(cut.start) - ScreencastTimelineGeometry.inset)
            }
            if let selection = model.trimSelection {
                Rectangle()
                    .fill(Color.red.opacity(0.32))
                    .overlay(Rectangle().strokeBorder(Color.red, lineWidth: 2))
                    .frame(width: max(geometry.x(selection.end) - geometry.x(selection.start), 1))
                    .offset(x: geometry.x(selection.start) - ScreencastTimelineGeometry.inset)
            }
        }
        .frame(width: width, height: Self.stripHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .gesture(isTrimming ? selectionGesture(geometry) : nil)
        .gesture(isTrimming ? nil : scrubGesture(geometry))
        .offset(x: ScreencastTimelineGeometry.inset, y: Self.stripTop)
    }

    /// The recording's frames across the strip, or black until they're made.
    private func filmstrip(width: CGFloat) -> some View {
        let frames = playback?.filmstrip ?? []
        return HStack(spacing: 0) {
            ForEach(frames.indices, id: \.self) { index in
                Image(decorative: frames[index], scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(frames.count, 1)), height: Self.stripHeight)
                    .clipped()
            }
        }
        .frame(width: width, height: Self.stripHeight, alignment: .leading)
        .background(Color.black)
    }

    /// A drag across the strip selects that part; a click moves the playhead.
    private func selectionGesture(_ geometry: ScreencastTimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // The strip's own coordinates start at the inset.
                let start = geometry.time(atX: value.startLocation.x + ScreencastTimelineGeometry.inset)
                let current = geometry.time(atX: value.location.x + ScreencastTimelineGeometry.inset)
                guard abs(value.translation.width) >= 3 else { return }
                if selectionStart == nil { selectionStart = start }
                model.selectForCut(ScreencastTimeRange(start: selectionStart ?? start, end: current))
            }
            .onEnded { value in
                defer { selectionStart = nil }
                guard abs(value.translation.width) < 3 else { return }
                model.selectForCut(nil)
                playback?.seek(toRecordingTime: geometry.time(atX: value.location.x + ScreencastTimelineGeometry.inset))
            }
    }

    /// Without Trim, a click or drag on the strip moves the playhead.
    private func scrubGesture(_ geometry: ScreencastTimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                playback?.seek(toRecordingTime: geometry.time(atX: value.location.x + ScreencastTimelineGeometry.inset))
            }
    }

    // MARK: The trim's frame

    private func trimFrame(_ geometry: ScreencastTimelineGeometry) -> some View {
        let trim = model.edits.trim
        let left = geometry.x(trim.start) - Self.handleWidth
        let width = geometry.x(trim.end) - geometry.x(trim.start) + Self.handleWidth * 2
        return ZStack(alignment: .topLeading) {
            ScreencastTrimFrameShape(handleWidth: Self.handleWidth)
                .fill(Color.yellow)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .frame(width: width, height: Self.stripHeight)
                .allowsHitTesting(false)
            handle(.start, geometry: geometry)
                .frame(width: Self.handleWidth, height: Self.stripHeight)
            handle(.end, geometry: geometry)
                .frame(width: Self.handleWidth, height: Self.stripHeight)
                .offset(x: width - Self.handleWidth)
        }
        .offset(x: left, y: Self.stripTop)
    }

    private enum End { case start, end }

    private func handle(_ end: End, geometry: ScreencastTimelineGeometry) -> some View {
        Capsule()
            .fill(Color.black.opacity(0.55))
            .frame(width: 2, height: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(ScreencastTrimTimeline.space))
                    .onChanged { value in
                        model.beginDrag()
                        let time = geometry.time(atX: value.location.x)
                        model.dragEdit { edits in
                            let trim = edits.trim
                            if end == .start {
                                edits.setTrim(start: min(time, trim.end), end: trim.end)
                            } else {
                                edits.setTrim(start: trim.start, end: max(time, trim.start))
                            }
                        }
                        let shown = end == .start ? model.edits.trim.start : model.edits.trim.end
                        playback?.preview(atRecordingTime: shown)
                    }
                    .onEnded { _ in
                        model.endDrag()
                        playback?.endPreview()
                        let trim = model.edits.trim
                        playback?.seek(toRecordingTime: end == .start ? trim.start : max(trim.end - 0.05, trim.start))
                    }
            )
            .help(end == .start ? "Drag to trim the start" : "Drag to trim the end")
            .accessibilityElement()
            .accessibilityLabel(end == .start ? "Trim start" : "Trim end")
            .accessibilityValue(ScreencastEditTime.format(end == .start ? model.edits.trim.start : model.edits.trim.end))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1.0 : -1.0
                model.edit { edits in
                    let trim = edits.trim
                    return end == .start
                        ? edits.setTrim(start: trim.start + step, end: trim.end)
                        : edits.setTrim(start: trim.start, end: trim.end + step)
                }
            }
    }

    static let space = "screencast.review.timeline.space"

    // MARK: Above the strip

    private func pills(_ geometry: ScreencastTimelineGeometry) -> some View {
        let edits = model.edits
        return ZStack(alignment: .topLeading) {
            ScreencastTimelinePill(text: ScreencastEditTime.format(edits.trim.start), style: .trim)
                .position(x: geometry.x(edits.trim.start), y: 17)
                .allowsHitTesting(false)
            ScreencastTimelinePill(text: ScreencastEditTime.format(edits.trim.end), style: .trim)
                .position(x: geometry.x(edits.trim.end), y: 17)
                .allowsHitTesting(false)
            ForEach(edits.cuts.filter { $0.overlaps(edits.trim) }, id: \.self) { cut in
                Button {
                    model.restoreCut(at: cut.start)
                } label: {
                    ScreencastTimelinePill(text: "\(ScreencastEditTime.format(cut.duration)) cut", style: .restore)
                }
                .buttonStyle(.plain)
                .help("Bring this part back")
                .position(x: (geometry.x(cut.start) + geometry.x(cut.end)) / 2, y: 17)
            }
            if let selection = model.trimSelection {
                Button(action: model.cutSelection) {
                    ScreencastTimelinePill(text: "Cut \(ScreencastEditTime.format(selection.duration))", style: .cut)
                }
                .buttonStyle(.plain)
                .help("Cut the selected part out (⌫)")
                .position(x: (geometry.x(selection.start) + geometry.x(selection.end)) / 2, y: 17)
            }
        }
        .frame(width: geometry.width, height: Self.height, alignment: .topLeading)
    }
}

/// Where the player is, across the timeline. A view of its own, so only it follows the player.
private struct ScreencastTimelinePlayhead: View {
    let playback: ScreencastReviewPlayback?
    let geometry: ScreencastTimelineGeometry
    let height: CGFloat

    var body: some View {
        let x = geometry.x(playback?.recordingTime ?? 0)
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 3, style: .continuous)
                .frame(width: 12, height: 13)
            Rectangle().frame(width: 2)
        }
        .foregroundStyle(Color.primary)
        .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(0.75), radius: 0.5)
        .frame(width: 12, height: height)
        .offset(x: x - 6, y: 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The trim's yellow frame: thick sides for the handles, a thin top and bottom.
private struct ScreencastTrimFrameShape: Shape {
    let handleWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 7, style: .continuous)
        let inner = rect.insetBy(dx: handleWidth, dy: 3)
        path.addRoundedRect(in: inner, cornerSize: CGSize(width: 2, height: 2))
        return path.normalized(eoFill: true)
    }
}

/// A cut part of the strip: hatched, between yellow edges.
private struct ScreencastCutHatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.52)))
            var x = -size.height
            while x < size.width {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(stripe, with: .color(.black.opacity(0.6)), lineWidth: 5)
                x += 10
            }
            context.fill(Path(CGRect(x: 0, y: 0, width: 1.5, height: size.height)), with: .color(.yellow))
            context.fill(Path(CGRect(x: size.width - 1.5, y: 0, width: 1.5, height: size.height)), with: .color(.yellow))
        }
        .allowsHitTesting(false)
    }
}

/// A small label above the strip: a trim handle's time, the selection's Cut, or a cut's Restore.
private struct ScreencastTimelinePill: View {
    enum Style { case trim, cut, restore }

    let text: String
    let style: Style

    var body: some View {
        HStack(spacing: 4) {
            if style != .trim { Image(systemName: "scissors") }
            Text(text)
            if style == .cut { Text(ScreencastTrimOptions.cutKey).opacity(0.85) }
            if style == .restore { Text("Restore").foregroundStyle(Color.accentColor) }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .trim: .black
        case .cut: .white
        case .restore: .primary
        }
    }

    private var background: Color {
        switch style {
        case .trim: .yellow
        case .cut: .red
        case .restore: Color(nsColor: .controlBackgroundColor)
        }
    }
}
