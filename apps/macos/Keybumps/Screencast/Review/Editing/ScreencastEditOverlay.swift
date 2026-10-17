import AppKit
import SwiftUI

/// What Crop and Blur draw over the video (#517), fitted to where the player draws it
/// (`ScreencastVideoOverlayGeometry`). The bottom of the player stays the player's own controls':
/// a press there reaches them, unless it's on a handle.
struct ScreencastEditOverlay: View {
    /// The player's controls along its bottom, which presses on the video leave alone.
    static let controlsBand: CGFloat = 56
    static let space = "screencast.review.overlay.space"

    let model: ScreencastReviewModel
    let playback: ScreencastReviewPlayback?

    var body: some View {
        GeometryReader { proxy in
            let geometry = ScreencastVideoOverlayGeometry(area: proxy.size, shown: model.shownFrame, pixelSize: model.pixelSize)
            let reach = CGRect(x: 0, y: 0, width: proxy.size.width, height: max(proxy.size.height - Self.controlsBand, 0))
            ZStack(alignment: .topLeading) {
                switch model.tool {
                case .crop: ScreencastCropOverlay(model: model, playback: playback, geometry: geometry, reach: reach)
                case .blur: ScreencastBlurOverlay(model: model, playback: playback, geometry: geometry, reach: reach)
                case .trim, nil: EmptyView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
        }
    }

    /// Where presses on `rect` reach the overlay: the part of it within `reach`, or nowhere.
    static func shape(_ rect: CGRect, within reach: CGRect) -> Path {
        let reachable = rect.intersection(reach)
        return reachable.isNull ? Path() : Path(reachable)
    }
}

/// Crop's rectangle over the whole frame, after Shotnix's `VideoCropOverlay` (MIT, see
/// LICENSE.shotnix): dimmed outside, a thirds grid inside, a handle at each corner and side, the
/// size in the video's pixels as Save writes it, and a drag inside moves it. A picked shape keeps
/// while resizing; with Free, Shift keeps the shape the crop had.
struct ScreencastCropOverlay: View {
    let model: ScreencastReviewModel
    let playback: ScreencastReviewPlayback?
    let geometry: ScreencastVideoOverlayGeometry
    let reach: CGRect

    /// The crop as the drag found it.
    @State private var origin: CGRect?

    var body: some View {
        let rect = geometry.viewRect(model.crop)
        let video = geometry.videoRect
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(video)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.56), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for third in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(third) / 3
                    let y = rect.minY + rect.height * CGFloat(third) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.32), lineWidth: 1)
            .allowsHitTesting(false)

            Path(rect)
                .stroke(Color.white, lineWidth: 1.5)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(ScreencastEditOverlay.shape(rect, within: reach))
                .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
                .gesture(moveGesture)

            sizeLabel
                .offset(x: rect.minX + 10, y: rect.minY + 10)
                .allowsHitTesting(false)

            ForEach(ScreencastRectHandle.allCases, id: \.self) { handle in
                ScreencastCropHandle(handle: handle)
                    .gesture(resizeGesture(handle))
                    .position(handle.point(in: rect))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop")
        .accessibilityValue(sizeText)
        .accessibilityIdentifier(ScreencastReviewID.cropOverlay)
        // Escape or a tool's key mid-drag takes the overlay away, and the drag never says it ended.
        .onDisappear { end() }
    }

    /// "2688 × 1512 px": the crop's size in the video's pixels.
    private var sizeText: String {
        let pixels = model.cropPixels
        return "\(Int(pixels.width)) × \(Int(pixels.height)) px"
    }

    private var sizeLabel: some View {
        Text(sizeText)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.black.opacity(0.66), in: Capsule())
            .fixedSize()
            .help("The size the saved recording will be, of \(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height))")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(ScreencastEditOverlay.space))
            .onChanged { value in
                let origin = start()
                NSCursor.closedHand.set()
                model.dragCrop(to: ScreencastFrameRect.moved(origin, by: geometry.frameDelta(value.translation)))
            }
            .onEnded { _ in end() }
    }

    private func resizeGesture(_ handle: ScreencastRectHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(ScreencastEditOverlay.space))
            .onChanged { value in
                let origin = start()
                // A press alone changes nothing.
                guard value.translation != .zero else { return }
                let keepsShape = NSEvent.modifierFlags.contains(.shift)
                let ratio = model.cropAspect.ratio ?? (keepsShape ? ScreencastFrameRect.ratio(of: origin, pixelSize: model.pixelSize) : nil)
                model.dragCrop(to: ScreencastFrameRect.resized(
                    origin, handle: handle, by: geometry.frameDelta(value.translation),
                    minimumSide: ScreencastFrameRect.minimumCropSide, ratio: ratio, pixelSize: model.pixelSize
                ))
            }
            .onEnded { _ in end() }
    }

    /// The drag's start, once: its changes are one edit, and none once it's cut short.
    private func start() -> CGRect {
        if let origin { return origin }
        playback?.pause()
        origin = model.crop
        model.beginDrag()
        return model.crop
    }

    private func end() {
        origin = nil
        model.endDrag()
    }
}

/// One of the crop's handles: an L at a corner, a bar along a side, white with a shadow.
private struct ScreencastCropHandle: View {
    let handle: ScreencastRectHandle

    var body: some View {
        Group {
            if handle.isCorner {
                Path { path in
                    // Two arms inward from just outside the crop's corner, at the middle.
                    let sx: CGFloat = handle.movesLeft ? 1 : -1
                    let sy: CGFloat = handle.movesTop ? 1 : -1
                    let corner = CGPoint(x: 18 - sx * 1.5, y: 18 - sy * 1.5)
                    path.move(to: CGPoint(x: corner.x + sx * 20, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * 20))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .square))
                .frame(width: 36, height: 36)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(width: handle.movesLeft || handle.movesRight ? 4 : 28, height: handle.movesTop || handle.movesBottom ? 4 : 28)
                    .frame(width: 28, height: 28)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 1.5)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside else { return NSCursor.arrow.set() }
            if handle.isCorner {
                NSCursor.crosshair.set()
            } else if handle.movesLeft || handle.movesRight {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.resizeUpDown.set()
            }
        }
    }
}

/// Blur over the video (#517), after the Screenshot Editor's Blur and Shotnix's overlay boxes
/// (`VideoStageInteractionLayer`): a drag where there's no blur draws one, gray with a dashed edge
/// as the Screenshot Editor draws its Blur until the drag ends. A press on a blur picks it and a drag
/// moves it; the picked one has a handle at each corner and side. Each blur is outlined with its
/// number; one not showing at the playhead is dashed, so it can still be found.
struct ScreencastBlurOverlay: View {
    /// A drawn blur smaller than this, in points, is a click.
    static let minimumDrawn: CGFloat = 4

    let model: ScreencastReviewModel
    let playback: ScreencastReviewPlayback?
    let geometry: ScreencastVideoOverlayGeometry
    let reach: CGRect

    private enum Press: Equatable {
        case draw(from: CGPoint)
        case move(id: Int, from: CGRect)
    }

    @State private var press: Press?
    /// The blur being drawn, in fractions of the frame.
    @State private var drawn: CGRect?
    /// The picked blur as a handle's drag found it.
    @State private var resizeOrigin: CGRect?

    var body: some View {
        let video = geometry.videoRect
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(ScreencastEditOverlay.shape(video, within: reach))
                .gesture(pressGesture)

            ZStack(alignment: .topLeading) {
                ForEach(Array(model.blurs.enumerated()), id: \.element.id) { index, blur in
                    ScreencastBlurOutline(
                        blur: blur, number: index + 1, isSelected: blur.id == model.selectedBlurID,
                        rect: geometry.viewRect(blur.rect), playback: playback
                    )
                }
                if let drawn {
                    let rect = geometry.viewRect(drawn)
                    Path(rect).fill(Color.gray.opacity(0.55))
                    Path(rect).stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .frame(width: geometry.area.width, height: geometry.area.height, alignment: .topLeading)
            .clipShape(Path(video))
            .allowsHitTesting(false)

            if let selected = model.selectedBlur {
                let rect = geometry.viewRect(selected.rect)
                ForEach(ScreencastRectHandle.allCases, id: \.self) { handle in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .gesture(resizeGesture(handle, blur: selected))
                        .position(handle.point(in: rect))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blurs")
        .accessibilityValue(model.blurs.isEmpty ? "None; drag over the video to add one" : "\(model.blurs.count)")
        .accessibilityIdentifier(ScreencastReviewID.blurOverlay)
        // Escape or a tool's key mid-drag takes the overlay away, and the drag never says it ended.
        .onDisappear { model.endDrag() }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(ScreencastEditOverlay.space))
            .onChanged { value in
                if press == nil { begin(at: value.startLocation) }
                switch press {
                case .draw(let start):
                    drawn = ScreencastFrameRect.spanning(start, geometry.framePoint(value.location))
                case .move(let id, let origin):
                    guard hypot(value.translation.width, value.translation.height) > 2 else { return }
                    NSCursor.closedHand.set()
                    model.dragBlur(id, to: ScreencastFrameRect.moved(origin, by: geometry.frameDelta(value.translation)))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                switch press {
                case .draw:
                    let size = drawn.map { geometry.viewRect($0).size } ?? .zero
                    if let drawn, size.width >= Self.minimumDrawn, size.height >= Self.minimumDrawn {
                        model.addBlur(drawn)
                    } else {
                        model.selectBlur(nil)
                    }
                case .move:
                    model.endDrag()
                case nil:
                    break
                }
                press = nil
                drawn = nil
            }
    }

    /// A press at `point`: on a blur, picks it to move; elsewhere, starts drawing one.
    private func begin(at point: CGPoint) {
        playback?.pause()
        if let blur = blur(at: point) {
            model.selectBlur(blur.id)
            model.beginDrag()
            press = .move(id: blur.id, from: blur.rect)
        } else {
            press = .draw(from: geometry.framePoint(point))
        }
    }

    /// The blur under `point`: the picked one, then those showing at the playhead, then the rest,
    /// the last drawn first.
    private func blur(at point: CGPoint) -> ScreencastBlur? {
        let time = playback?.recordingTime ?? 0
        let blurs = model.blurs.reversed()
        let candidates = blurs.filter { $0.id == model.selectedBlurID }
            + blurs.filter { $0.time.contains(time) }
            + blurs.filter { !$0.time.contains(time) }
        return candidates.first { geometry.viewRect($0.rect).insetBy(dx: -3, dy: -3).contains(point) }
    }

    private func resizeGesture(_ handle: ScreencastRectHandle, blur: ScreencastBlur) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(ScreencastEditOverlay.space))
            .onChanged { value in
                if resizeOrigin == nil {
                    playback?.pause()
                    resizeOrigin = blur.rect
                    model.beginDrag()
                }
                guard let origin = resizeOrigin else { return }
                model.dragBlur(blur.id, to: ScreencastFrameRect.resized(
                    origin, handle: handle, by: geometry.frameDelta(value.translation), minimumSide: ScreencastFrameRect.minimumBlurSide
                ))
            }
            .onEnded { _ in
                resizeOrigin = nil
                model.endDrag()
            }
    }
}

/// One blur's outline and number over the video: the accent color while picked, white otherwise,
/// and dashed while it doesn't show at the playhead. A view of its own, so only it follows the
/// player.
private struct ScreencastBlurOutline: View {
    let blur: ScreencastBlur
    let number: Int
    let isSelected: Bool
    let rect: CGRect
    let playback: ScreencastReviewPlayback?

    var body: some View {
        let isShowing = blur.time.contains(playback?.recordingTime ?? 0)
        let dash: [CGFloat] = isShowing ? [] : [5, 4]
        ZStack(alignment: .topLeading) {
            if isSelected {
                Path(rect).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: dash))
            } else {
                Path(rect.insetBy(dx: -1, dy: -1)).stroke(Color.black.opacity(0.3), lineWidth: 1)
                Path(rect).stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: isShowing ? 1 : 1.5, dash: dash))
            }
            Text("Blur \(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(isSelected ? Color.accentColor : Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
                // Above its top left, or inside it when there's no room above.
                .offset(x: rect.minX - 2, y: rect.minY >= 25 ? rect.minY - 25 : rect.minY + 4)
        }
    }
}
