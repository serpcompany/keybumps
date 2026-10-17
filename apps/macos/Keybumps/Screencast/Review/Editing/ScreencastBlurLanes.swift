import AppKit
import SwiftUI

/// The blurs' bars under the timeline's strip (#517): a lane for each of the shown display's blurs,
/// in the order drawn, each bar spanning when its blur shows. With Blur picked, a click on a bar
/// picks its blur and a drag on either end changes when it shows; with Trim, they show faded and
/// still, so a trim never hides one by surprise. Trimmed and cut parts stay dimmed across them. More
/// than three lanes scroll.
struct ScreencastBlurLanes: View {
    static let laneHeight: CGFloat = 24
    static let barHeight: CGFloat = 18
    static let visibleLanes = 3

    let model: ScreencastReviewModel
    let geometry: ScreencastTimelineGeometry
    let isEditable: Bool

    /// The lanes' height in the timeline, for `lanes` blurs.
    static func height(lanes: Int) -> CGFloat { CGFloat(min(lanes, visibleLanes)) * laneHeight }

    var body: some View {
        let blurs = model.blurs
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(blurs.enumerated()), id: \.element.id) { index, blur in
                    ScreencastBlurBar(
                        model: model, blur: blur, number: index + 1, isSelected: isEditable && blur.id == model.selectedBlurID,
                        isEditable: isEditable, geometry: geometry
                    )
                    .offset(y: CGFloat(index) * Self.laneHeight + (Self.laneHeight - Self.barHeight) / 2)
                }
                dims(height: CGFloat(blurs.count) * Self.laneHeight)
            }
            .frame(width: geometry.width, height: CGFloat(blurs.count) * Self.laneHeight, alignment: .topLeading)
        }
        .scrollDisabled(blurs.count <= Self.visibleLanes)
        .scrollIndicators(.automatic)
        .frame(width: geometry.width, height: Self.height(lanes: blurs.count))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Blurs")
        .accessibilityIdentifier(ScreencastReviewID.blurLanes)
    }

    /// The trimmed ends and the cuts, dimmed across the lanes.
    private func dims(height: CGFloat) -> some View {
        let edits = model.edits
        let dimmed = [
            ScreencastTimeRange(start: 0, end: edits.trim.start),
            ScreencastTimeRange(start: edits.trim.end, end: edits.duration),
        ] + edits.cuts.filter { $0.overlaps(edits.trim) }
        return ZStack(alignment: .topLeading) {
            ForEach(dimmed.filter { $0.duration > 0 }, id: \.self) { range in
                Color(nsColor: .underPageBackgroundColor)
                    .opacity(0.74)
                    .frame(width: max(geometry.x(range.end) - geometry.x(range.start), 0), height: height)
                    .offset(x: geometry.x(range.start))
            }
        }
        .allowsHitTesting(false)
    }
}

/// One blur's bar: its number and when it shows, filled with the accent color and with grips at
/// its ends while picked.
private struct ScreencastBlurBar: View {
    let model: ScreencastReviewModel
    let blur: ScreencastBlur
    let number: Int
    let isSelected: Bool
    let isEditable: Bool
    let geometry: ScreencastTimelineGeometry

    /// When the blur showed as an end's drag found it.
    @State private var origin: ScreencastTimeRange?

    var body: some View {
        let x = geometry.x(blur.time.start)
        let width = max(geometry.x(blur.time.end) - x, 6)
        let times = "\(ScreencastEditTime.format(blur.time.start))–\(ScreencastEditTime.format(blur.time.end))"
        HStack(spacing: 5) {
            Image(systemName: ScreencastEditTool.blur.systemImage).font(.system(size: 8))
            Text("Blur \(number)")
            Text(times).foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .lineLimit(1)
        .padding(.horizontal, isSelected ? 14 : 8)
        .frame(width: width, height: ScreencastBlurLanes.barHeight, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            if !isSelected { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) { end(.start, width: width) }
        .overlay(alignment: .trailing) { end(.end, width: width) }
        .contentShape(Rectangle())
        .onTapGesture { model.selectBlur(blur.id) }
        .opacity(isEditable ? 1 : 0.55)
        .allowsHitTesting(isEditable)
        .offset(x: x)
        .help("Blur \(number): drag its ends to change when it shows")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blur \(number)")
        .accessibilityValue("\(ScreencastEditTime.format(blur.time.start)) to \(ScreencastEditTime.format(blur.time.end))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { model.selectBlur(blur.id) }
    }

    /// An end of the bar: a grip while picked, and a drag there moves that end.
    private func end(_ edge: ScreencastTimeEdge, width: CGFloat) -> some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2.5, height: 10)
            }
        }
        .frame(width: min(10, width / 3), height: ScreencastBlurLanes.barHeight)
        .contentShape(Rectangle())
        .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let origin = origin ?? blur.time
                    if self.origin == nil {
                        self.origin = origin
                        model.selectBlur(blur.id)
                    }
                    let from = edge == .start ? origin.start : origin.end
                    let moved = Double(value.translation.width / geometry.trackWidth) * geometry.duration
                    model.dragBlurTime(blur.id, edge: edge, to: from + moved)
                }
                .onEnded { _ in
                    origin = nil
                    model.endDrag()
                }
        )
    }
}
