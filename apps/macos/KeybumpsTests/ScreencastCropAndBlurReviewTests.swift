import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Keybumps

/// Crop and Blur in the recording window (#517): the tools and their options, what they do to the
/// edits, undo and redo, the keys, and that what they make is what Save's export gets and writes.
/// Made-up captures in a temporary folder, short movies made in the test for the real export, a
/// named pasteboard, and no window ordered in.
@MainActor
@Suite("ScreenGrabs: Crop and Blur in the recording window")
struct ScreencastCropAndBlurReviewTests {
    let fixture = ReviewFixture()

    /// A blur drawn over the video as the overlay draws it: from `start` to `end` in a player
    /// `area` points big.
    private func draw(
        _ model: ScreencastReviewModel, from start: CGPoint, to end: CGPoint, in area: CGSize = CGSize(width: 640, height: 360)
    ) {
        let geometry = ScreencastVideoOverlayGeometry(area: area, shown: model.shownFrame, pixelSize: model.pixelSize)
        model.addBlur(ScreencastFrameRect.spanning(geometry.framePoint(start), geometry.framePoint(end)))
    }

    // MARK: Tools

    @Test("The bar's tools are Trim, Crop, and Blur, numbered 1 to 3, with T, C, and B; the timeline shows with Trim and Blur")
    func tools() throws {
        defer { fixture.tearDown() }
        let titles = ScreencastEditTool.allCases.map(\.title)
        #expect(titles == ["Trim", "Crop", "Blur"])
        let numbers = ScreencastEditTool.allCases.map(\.number)
        #expect(numbers == ["1", "2", "3"])
        #expect(ScreencastEditTool.matching(key: "C") == .crop)
        #expect(ScreencastEditTool.matching(key: "b") == .blur)
        let blurIcon = ScreencastEditTool.blur.systemImage
        #expect(blurIcon == ScreenshotEditorTool.pixelate.systemImage, "the Screenshot Editor's Blur's")

        let model = fixture.model(try fixture.video())
        model.pick(.crop)
        #expect(!model.showsTimeline)
        model.pick(.blur)
        #expect(model.showsTimeline)
    }

    // MARK: Crop

    @Test("A shape crops at once, centered, and Reset Crop and undo bring the whole frame back")
    func cropShape() throws {
        defer { fixture.tearDown() }
        // 64 × 36 pixels.
        let model = fixture.model(try fixture.video())
        model.pick(.crop)
        #expect(!model.hasCrop)
        model.setCropAspect(.square)
        #expect(model.cropAspect == .square)
        let pixels = model.cropPixels
        #expect(pixels == CGRect(x: 14, y: 0, width: 36, height: 36))
        #expect(model.canUndo)

        model.resetCrop()
        #expect(!model.hasCrop)
        model.undo()
        #expect(model.hasCrop)
        model.undo()
        #expect(model.edits.isEmpty)
        model.redo()
        let redone = model.cropPixels
        #expect(redone == pixels)

        model.setCropAspect(.free)
        #expect(model.cropPixels == pixels, "Free keeps the crop")
    }

    @Test("While Crop is picked the player shows the whole frame to place the crop on; otherwise the crop as Save writes it")
    func shownFrame() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.crop)
        model.setCropAspect(.square)
        #expect(model.shownFrame == ScreencastFrameRect.whole)
        model.pick(.blur)
        let shown = model.shownFrame
        #expect(shown == CGRect(x: 14.0 / 64, y: 0, width: 36.0 / 64, height: 1))

        // The player plays a crop-only edit as recorded while Crop is picked.
        let changes = ScreencastReviewPlayback.changes(display: 0, of: model.edits, crops: false)
        #expect(!changes)
        let cropped = ScreencastReviewPlayback.changes(display: 0, of: model.edits)
        #expect(cropped)
    }

    @Test("The player loads again only when Crop changes what plays: not for Crop picked or put down without a crop")
    func cropToolKeepsThePlayer() async throws {
        defer { fixture.tearDown() }
        let file = fixture.folder.url.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 0))
        try await EditTestMovie.write(to: file, seconds: 1, picture: .movingBar, sounds: false)
        let video = ScreencastVideo(
            file: file, mixdown: nil, pixelWidth: EditTestMovie.width, pixelHeight: EditTestMovie.height, audioTracks: [], duration: 1
        )
        var edits = ScreencastRecordingEdits(duration: 1, displayCount: 2)
        let playback = ScreencastReviewPlayback()
        defer { playback.stop() }
        playback.show(video, display: 0, edits: edits)
        let item = try #require(playback.view.player?.currentItem)
        playback.show(video, display: 0, edits: edits, crops: false)
        #expect(playback.view.player?.currentItem === item, "no edits")

        // With blurs, or a crop elsewhere, or only Crop's shape changed, the same plays.
        edits.addBlur(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), strength: .high, display: 0)
        edits.setCrop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), display: 1)
        let playing = ScreencastReviewPlayback.played(display: 0, of: edits)
        let placing = ScreencastReviewPlayback.played(display: 0, of: edits, crops: false)
        #expect(playing != nil && playing == placing)

        edits.setCrop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), display: 0)
        let cropped = ScreencastReviewPlayback.played(display: 0, of: edits)
        #expect(cropped != playing, "a crop plays")
        #expect(ScreencastReviewPlayback.played(display: 0, of: edits, crops: false) == placing)
        edits.setCrop(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), aspect: .square, display: 0)
        #expect(ScreencastReviewPlayback.played(display: 0, of: edits) == cropped, "only the shape")
    }

    @Test("A crop dragged by its handles is one edit, made when the drag ends")
    func cropDrag() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.crop)
        model.beginDrag()
        model.dragCrop(to: CGRect(x: 0.25, y: 0, width: 0.75, height: 1))
        model.dragCrop(to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(!model.canUndo, "not until the drag ends")
        model.endDrag()
        #expect(model.crop == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        model.undo()
        #expect(!model.hasCrop)
    }

    @Test("Aspect is each display's, kept with its crop: undo, redo, and Reset Crop take it along")
    func cropAspectGoesWithTheCrop() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video(displays: 2))
        model.pick(.crop)
        model.setCropAspect(.square)
        model.selectedDisplay = 1
        #expect(model.cropAspect == .free, "the second display's")
        model.selectedDisplay = 0
        #expect(model.cropAspect == .square)

        model.undo()
        #expect(model.cropAspect == .free, "undo")
        model.redo()
        #expect(model.cropAspect == .square, "redo")
        model.resetCrop()
        #expect(model.cropAspect == .free, "Reset Crop")
        model.undo()
        #expect(model.cropAspect == .square)

        // A handle pressed without moving finds the crop in the shape picked.
        let ratio = try #require(ScreencastFrameRect.ratio(of: model.crop, pixelSize: model.pixelSize))
        #expect(abs(ratio - 1) < 0.01)
        model.beginDrag()
        model.dragCrop(to: CGRect(x: 0.3, y: 0, width: 0.5625, height: 1))
        model.endDrag()
        #expect(model.cropAspect == .square, "a drag keeps it")
        model.setCropAspect(.free)
        #expect(model.cropAspect == .free && model.hasCrop)
        model.undo()
        #expect(model.cropAspect == .square)
    }

    @Test("A crop drag cut short by Escape is one edit; the rest of the press changes nothing; undo goes back in order")
    func cropDragCutShort() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        let half = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        model.pick(.crop)
        model.beginDrag()
        model.dragCrop(to: half)
        model.putToolDown()
        model.dragCrop(to: CGRect(x: 0.25, y: 0, width: 0.75, height: 1))
        #expect(model.crop == half, "the press goes on, but the drag ended")
        model.endDrag()

        model.pick(.blur)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 320, y: 180))
        let id = try #require(model.selectedBlurID)
        let drawn = model.selectedBlur?.rect
        model.beginDrag()
        model.dragBlur(id, to: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        model.endDrag()

        model.undo()
        #expect(model.selectedBlur?.rect == drawn, "the blur's drag")
        model.undo()
        #expect(model.blurs.isEmpty, "the blur drawn")
        #expect(model.crop == half)
        model.undo()
        #expect(!model.hasCrop, "the crop's drag")
        #expect(!model.canUndo)
    }

    // MARK: Blur

    @Test("A drawn blur is picked, at the strength picked, for the whole recording; Strength changes the picked one and the next")
    func drawBlur() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.blur)
        #expect(model.blurStrength == .high)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 320, y: 180))
        let blur = try #require(model.selectedBlur)
        #expect(blur.rect == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(blur.time == model.edits.whole)
        #expect(blur.strength == .high)

        model.setBlurStrength(.low)
        #expect(model.selectedBlur?.strength == .low)
        draw(model, from: CGPoint(x: 320, y: 180), to: CGPoint(x: 640, y: 360))
        #expect(model.selectedBlur?.strength == .low, "the next one too")
        #expect(model.blurs.count == 2)
    }

    @Test("Several blurs, one picked: Tab picks the next, Delete takes the picked one off, and undo brings it back")
    func selectAndDelete() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.blur)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        draw(model, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 300))
        let ids = model.blurs.map(\.id)
        #expect(model.selectedBlurID == ids[1], "the last drawn")
        model.selectNextBlur()
        #expect(model.selectedBlurID == ids[0], "after the last, the first")

        model.deleteSelectedBlur()
        #expect(model.blurs.map(\.id) == [ids[1]])
        #expect(model.selectedBlur == nil)
        model.undo()
        #expect(model.blurs.map(\.id) == ids)
        model.selectBlur(nil)
        model.deleteSelectedBlur()
        #expect(model.blurs.count == 2, "nothing picked, nothing deleted")
    }

    @Test("A blur's rect and its bar's ends are dragged as one edit each; its time stays inside the recording")
    func blurDrags() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.blur)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 320, y: 180))
        let id = try #require(model.selectedBlurID)

        model.beginDrag()
        model.dragBlur(id, to: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        model.endDrag()
        model.beginDrag()
        model.dragBlurTime(id, edge: .start, to: 1)
        model.dragBlurTime(id, edge: .end, to: 9)
        model.endDrag()
        let blur = try #require(model.selectedBlur)
        #expect(blur.rect == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(blur.time == ScreencastTimeRange(start: 1, end: 4), "the recording is 4 seconds")

        model.undo()
        #expect(model.selectedBlur?.time == model.edits.whole)
        model.undo()
        #expect(model.selectedBlur?.rect == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    }

    @Test("A blur drag cut short by Trim's key, or by Tab picking another blur, is one edit, and the rest of it changes nothing")
    func blurDragCutShort() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.blur)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        draw(model, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 300))
        let id = try #require(model.selectedBlurID)

        model.beginDrag()
        model.dragBlurTime(id, edge: .start, to: 1)
        model.pick(.trim)
        model.dragBlurTime(id, edge: .start, to: 2)
        model.endDrag()
        #expect(model.selectedBlur?.time.start == 1)

        model.pick(.blur)
        let rect = model.selectedBlur?.rect
        model.beginDrag()
        model.dragBlur(id, to: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        model.selectNextBlur()
        let other = try #require(model.selectedBlurID)
        model.dragBlur(other, to: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))
        model.endDrag()
        let first = model.blurs.first { $0.id == other }
        #expect(first?.rect != CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), "the other blur stays")

        model.undo()
        let undone = model.blurs.first { $0.id == id }
        #expect(undone?.rect == rect, "the move")
        model.undo()
        let timeUndone = model.blurs.first { $0.id == id }
        #expect(timeUndone?.time.start == 0, "the bar's drag")
    }

    @Test("Strength shows the picked blur's strength after undo, redo, and a display switch")
    func strengthFollowsThePickedBlur() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video(displays: 2))
        model.pick(.blur)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        model.setBlurStrength(.low)
        model.undo()
        #expect(model.selectedBlur?.strength == .high)
        #expect(model.blurStrength == .high, "undo")
        model.redo()
        #expect(model.blurStrength == .low, "redo")

        model.selectedDisplay = 1
        #expect(model.selectedBlur == nil)
        model.setBlurStrength(.high)
        #expect(model.blurStrength == .high, "the next one drawn's")
        model.selectedDisplay = 0
        #expect(model.blurStrength == .low, "Blur 1 is still picked")
    }

    @Test("Each display has its own crop and blurs, picked with the display picker")
    func severalDisplays() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video(displays: 2))
        model.pick(.crop)
        model.setCropAspect(.square)
        model.selectedDisplay = 1
        #expect(!model.hasCrop, "the second display isn't cropped")
        #expect(model.cropAspect == .free)
        model.pick(.blur)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        #expect(model.blurs.count == 1)
        model.selectedDisplay = 0
        #expect(model.blurs.isEmpty && model.selectedBlur == nil)
        #expect(model.hasCrop)
        #expect(model.edits.displays[1].blurs.count == 1)
    }

    @Test("Keys: C and B pick Crop and Blur; with Blur, ⌫ deletes the picked blur and Tab picks the next while there are blurs")
    func keys() {
        func key(
            _ code: UInt16, _ characters: String?, _ modifiers: NSEvent.ModifierFlags = [],
            _ editing: ScreencastReviewKey.Editing = .none, controlHasKeyboard: Bool = false
        ) -> ScreencastReviewKey {
            ScreencastReviewKey.action(
                keyCode: code, modifiers: modifiers, characters: characters, isComposing: false,
                isConfirmingDiscard: false, controlHasKeyboard: controlHasKeyboard, editing: editing
            )
        }
        #expect(key(19, "2") == .tool(.crop))
        #expect(key(8, "c") == .tool(.crop))
        #expect(key(8, "c", .command) == .copy, "⌘C still copies")
        #expect(key(20, "3") == .tool(.blur))
        #expect(key(11, "b") == .tool(.blur))

        let blur = ScreencastReviewKey.Editing(tool: .blur)
        let blurs = ScreencastReviewKey.Editing(tool: .blur, hasBlurs: true)
        #expect(key(51, nil, [], blur) == .deleteBlur)
        #expect(key(117, nil, [], blurs) == .deleteBlur)
        #expect(key(48, nil, [], blur) == .tab, "no blurs to pick")
        #expect(key(48, nil, [], blurs) == .selectNextBlur)
        #expect(key(48, nil, .shift, blurs) == .tab)
        #expect(key(48, nil, [], blurs, controlHasKeyboard: true) == .tab)
        #expect(key(53, nil, [], blurs) == .putToolDown)

        let crop = ScreencastReviewKey.Editing(tool: .crop)
        #expect(key(51, nil, [], crop) == .pass, "⌫ does nothing in Crop")
        #expect(key(36, nil, [], crop) == .save)
    }

    // MARK: Drawn

    @Test("Crop draws over the video: dimmed outside the crop, clear inside it, edged in white")
    func cropOverlayDraws() throws {
        defer { fixture.tearDown() }
        // 64 × 36 pixels, filling a 640 × 360 player: the square crop is 360 points wide, at 140.
        let model = fixture.model(try fixture.video())
        model.pick(.crop)
        model.setCropAspect(.square)
        let image = try render(ScreencastEditOverlay(model: model, playback: nil))
        let outside = image.alpha(x: 60, y: 180)
        #expect(outside > 0.4, "dimmed: \(outside)")
        let inside = image.alpha(x: 320, y: 180)
        #expect(inside < 0.05, "clear: \(inside)")
        let edge = (138...142).map { image.brightness(x: $0, y: 180) }.max() ?? 0
        #expect(edge > 0.6, "white along its edge: \(edge)")
    }

    @Test("Blur outlines its blurs over the video, clear inside, where the player draws the mosaic")
    func blurOverlayDraws() throws {
        defer { fixture.tearDown() }
        let model = fixture.model(try fixture.video())
        model.pick(.blur)
        draw(model, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 440, y: 260))
        let image = try render(ScreencastEditOverlay(model: model, playback: nil))
        let inside = image.alpha(x: 320, y: 180)
        #expect(inside < 0.05, "clear: \(inside)")
        let edge = (98...102).map { image.alpha(x: 320, y: $0) }.max() ?? 0
        #expect(edge > 0.8, "outlined: \(edge)")
        let away = image.alpha(x: 60, y: 300)
        #expect(away < 0.05, "nothing elsewhere: \(away)")
    }

    @Test("The timeline grows a lane for each blur under the strip, up to three, then scrolls")
    func timelineLanes() {
        let none = ScreencastTrimTimeline.height(blurLanes: 0)
        #expect(none == ScreencastTrimTimeline.height)
        let one = ScreencastTrimTimeline.height(blurLanes: 1)
        let three = ScreencastTrimTimeline.height(blurLanes: 3)
        let five = ScreencastTrimTimeline.height(blurLanes: 5)
        #expect(three - one == 2 * ScreencastBlurLanes.laneHeight)
        #expect(five == three)
    }

    /// `view` in a 640 × 360 player, drawn off screen at 1x.
    private func render(_ view: some View) throws -> RenderedOverlay {
        let host = NSHostingView(rootView: view.frame(width: 640, height: 360))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: 640, height: 360)
        host.cacheDisplay(in: host.bounds, to: rep)
        return RenderedOverlay(rep: rep)
    }

    @Test("In the window, with Blur picked, Tab picks the next blur and ⌫ deletes the picked one")
    func windowKeys() async throws {
        defer { fixture.tearDown() }
        let panel = ScreencastReviewPanel(
            repositories: fixture.repositories, pasteboard: fixture.pasteboard, keepOutOfClipboardHistory: {},
            screen: { nil }, makePlayback: { nil }, export: FakeEditExport().export
        )
        await panel.show(try fixture.video())
        let model = try #require(panel.model)
        model.pick(.blur)
        let none = panel.action(forKey: 48, modifiers: [], in: panel.window)
        #expect(none == .tab, "no blurs yet")
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))
        draw(model, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 300))
        let ids = model.blurs.map(\.id)

        let tab = panel.action(forKey: 48, modifiers: [], in: panel.window)
        #expect(tab == .selectNextBlur)
        panel.perform(tab)
        #expect(model.selectedBlurID == ids[0])
        let delete = panel.action(forKey: 51, modifiers: [], in: panel.window)
        #expect(delete == .deleteBlur)
        panel.perform(delete)
        #expect(model.blurs.map(\.id) == [ids[1]])
        await panel.close()
    }

    // MARK: What Save gets

    @Test("What Crop and Blur make is what Save's export gets: each display's crop, and its blurs with their rects, strengths, and times")
    func exportGetsTheEdits() async throws {
        defer { fixture.tearDown() }
        let export = FakeEditExport(.succeed)
        let model = fixture.model(try fixture.video(displays: 2), export: export.export)
        model.pick(.crop)
        model.setCropAspect(.square)
        model.selectedDisplay = 1
        model.pick(.blur)
        model.setBlurStrength(.medium)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 160, y: 360))
        let id = try #require(model.selectedBlurID)
        model.beginDrag()
        model.dragBlurTime(id, edge: .start, to: 1.5)
        model.endDrag()
        let made = model.edits

        await model.save()
        let got = try #require(export.runs.last)
        #expect(got == made)
        #expect(got.displays[0].crop != nil && got.displays[0].blurs.isEmpty)
        #expect(got.displays[1].crop == nil)
        let blur = try #require(got.displays[1].blurs.first)
        #expect(blur.rect == CGRect(x: 0, y: 0, width: 0.25, height: 1))
        #expect(blur.strength == .medium)
        #expect(blur.time == ScreencastTimeRange(start: 1.5, end: 4))
    }

    @Test("Save writes what the window shows: the video is the crop's size in pixels, blurred where the blur was drawn over the cropped video")
    func exportWritesTheEdits() async throws {
        defer { fixture.tearDown() }
        let capture = try await movieCapture()
        let model = fixture.model(.video(capture))
        model.pick(.crop)
        model.setCropAspect(.square)
        let label = model.cropPixels.size
        // Drawn over the left half of the cropped video, as Blur shows it.
        model.pick(.blur)
        draw(model, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 150, y: 300), in: CGSize(width: 300, height: 300))

        await model.save()
        let saved = try #require(fixture.outcomes.last)
        guard case .saved(.video(let edited)) = saved else {
            Issue.record("not saved: \(saved)")
            return
        }
        let size = try await EditTestMovie.size(of: edited.videos[0].file)
        #expect(size == label, "the size the crop said")
        let image = try await EditTestMovie.image(of: edited.videos[0].file, at: 1.5)
        let blurred = EditTestMovie.contrast(in: image, columns: 4..<50)
        let sharp = EditTestMovie.contrast(in: image, columns: 58..<104)
        #expect(blurred < 12, "a mosaic on the left: \(blurred)")
        #expect(sharp > 30, "sharp on the right: \(sharp)")
    }

    /// A recording's folder with a real three-second movie of a checkerboard, 192 × 108 pixels, no
    /// sound, and its `meta.json`.
    private func movieCapture() async throws -> ScreencastCapture {
        let folder = fixture.folder.url.appendingPathComponent("1791000000", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(ScreencastCaptureFolder.videoName(index: 0))
        try await EditTestMovie.write(to: file, seconds: 3, picture: .checkerboard, sounds: false)
        let video = ScreencastVideo(
            file: file, mixdown: nil, pixelWidth: EditTestMovie.width, pixelHeight: EditTestMovie.height, audioTracks: [], duration: 3
        )
        let capture = ScreencastCapture(folder: folder, videos: [video], duration: 3, endedEarly: nil)
        try ScreencastMetadata(capture: capture, target: .display(1), startedAt: ReviewFixture.reviewDate).write(to: capture.metadataURL)
        return capture
    }
}

/// An overlay drawn off screen, read in points from its top left.
private struct RenderedOverlay {
    let rep: NSBitmapImageRep

    func alpha(x: Int, y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// How bright the pixel is, from 0 to 1, where it's drawn.
    func brightness(x: Int, y: Int) -> CGFloat {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { return 0 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
}
