import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Keybumps

/// The Translate tab's saved translations in the Dictation tab's list-and-detail layout (#377): the
/// highlighted one in full beside the list, with buttons that do what the keys do. The palette is laid
/// out offscreen (`layOutForTesting`) and read through its accessibility elements, as VoiceOver reads
/// it (`PaletteAccessibility`).
@MainActor
@Suite("Translation: a saved translation in full (#377)", .serialized)
struct TranslateDetailTests {
    static let longSource = String(repeating: "A made-up sentence to translate, long enough to wrap. ", count: 30)
    static let longTranslation = String(repeating: "A made-up translated sentence that goes on and on. ", count: 40)

    // MARK: The model

    @Test("The detail is the highlighted saved translation in full: both texts unshortened, its languages, and when it was saved")
    func detailInFull() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let recents = RecentTranslations(storageURL: nil, now: { now })
        recents.save(Self.longSource, translated: Self.longTranslation, from: "en", to: "ja")
        now += 60
        recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        let tab = TranslateTabTests.tab(FakeTranslator(), recents: recents)

        let long = try #require(tab.detail(row: 1, query: ""))
        #expect(long.record.translatedText == Self.longTranslation)
        #expect(long.record.sourceText == Self.longSource)
        #expect(long.languages == "English → Japanese")
        #expect(long.saved == Date(timeIntervalSince1970: 1_000_000).formatted(date: .abbreviated, time: .shortened))
        #expect(long.readAloudTitle == "Read Aloud")
        #expect(long.speechProblem == nil)

        #expect(tab.detail(row: 0, query: "")?.record.translatedText == "Merci", "The newest is first")
        #expect(tab.detail(row: 0, query: "  ")?.record.translatedText == "Merci", "Spaces alone are an empty field")
        #expect(tab.detail(row: 2, query: "") == nil)
        #expect(tab.detail(row: 0, query: "Hello") == nil, "With text in the field, there's no list")
        let off = TranslateTabTests.tab(FakeTranslator(), preferences: TranslateTabTests.preferences(on: false), recents: recents)
        #expect(off.detail(row: 0, query: "") == nil, "Turned off, the tab lists nothing")
    }

    @Test("Read Aloud says Stop Reading while its record is read; with no voice, that record's detail says so")
    func readAloudState() async throws {
        let speaker = FakeTranslationSpeaker()
        speaker.languagesWithoutVoice = ["ja"]
        let recents = RecentTranslations(storageURL: nil)
        let japanese = recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let french = recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        let tab = TranslateTabTests.tab(FakeTranslator(), recents: recents, speaker: speaker)

        tab.readAloud(french.id)
        await tab.reading?.value
        #expect(tab.detail(row: 0, query: "")?.isReading == true)
        #expect(tab.detail(row: 0, query: "")?.readAloudTitle == "Stop Reading")
        #expect(tab.playback(row: 0, query: "")?.title == "Stop Reading", "The footer's Space says the same")
        #expect(tab.detail(row: 1, query: "")?.isReading == false)

        tab.readAloud(japanese.id)
        await tab.reading?.value
        #expect(tab.detail(row: 1, query: "")?.speechProblem == FakeTranslationSpeaker.noVoice)
        #expect(tab.detail(row: 1, query: "")?.readAloudTitle == "Read Aloud")
        #expect(tab.detail(row: 0, query: "")?.speechProblem == nil, "Only the record that couldn't be read says so")
        #expect(tab.detail(row: 0, query: "")?.isReading == false, "Reading another stopped it")
    }

    // MARK: The palette

    @Test("Saved translations are a list with the highlighted one's detail beside it; a long translation shows in full, wrapped, and scrolls")
    func listAndDetailLayout() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        fixture.recents.save(Self.longSource, translated: Self.longTranslation, from: "en", to: "ja")
        let ax = try await PaletteAccessibility.layOut(fixture.palette)
        defer { ax.close() }

        #expect(await ax.text("palette.translate.detail.translation") == Self.longTranslation)
        #expect(await ax.text("palette.translate.detail.source") == Self.longSource)
        let detail = try await ax.require("palette.translate.detail")
        let translation = try await ax.require("palette.translate.detail.translation")

        let list = try #require(PaletteAccessibility.scrollViews(in: ax.root).first { $0.documentView is NSTableView })
        let listFrame = list.accessibilityFrame()
        #expect(abs(listFrame.width - 330) < 1, "The list keeps Dictation's width")
        #expect(PaletteAccessibility.frame(of: detail).minX >= listFrame.maxX, "The detail is to its right")
        #expect(PaletteAccessibility.frame(of: translation).height > 100, "Many lines, not one line cut short")
        #expect(PaletteAccessibility.frame(of: translation).width < PaletteAccessibility.frame(of: detail).width)

        let detailScroll = try #require(PaletteAccessibility.scrollViews(in: ax.root).first {
            !($0.documentView is NSTableView) && $0.accessibilityFrame().minX >= listFrame.maxX
        })
        let document = try #require(detailScroll.documentView)
        #expect(document.frame.height > detailScroll.contentView.bounds.height, "Too long for the pane, so it scrolls")
    }

    @Test("A hairline divides the translation from the text it was translated from, drawn as Information's rows are divided")
    func dividerBetweenTheLanguages() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        // Dark, as the other pixel checks are (`PaletteFloatingSurfaceTests`).
        let ax = try await PaletteAccessibility.layOut(fixture.palette, appearance: .darkAqua)
        defer { ax.close() }
        #expect(await ax.shows("palette.translate.detail.translation", "おやすみ"))
        let detail = try await ax.require("palette.translate.detail")
        let translation = ax.frameFromTop(of: try await ax.require("palette.translate.detail.translation"))
        let english = ax.frameFromTop(of: try #require(PaletteAccessibility.element(reading: "English", in: detail)))
        let information = ax.frameFromTop(of: try #require(PaletteAccessibility.element(reading: "Information", in: detail)))
        let languages = ax.frameFromTop(of: try #require(PaletteAccessibility.element(reading: "Languages", in: detail)))
        #expect(translation.maxY < english.minY && english.maxY < information.minY && information.maxY < languages.minY)

        let image = try ax.render()
        let x = translation.minX + 4
        let between = PaletteAccessibility.hairlines(in: image, x: x, from: translation.maxY + 2, to: english.minY - 2)
        let inInformation = PaletteAccessibility.hairlines(in: image, x: x, from: information.maxY + 1, to: languages.minY - 2)
        #expect(between.count == 1, "One hairline between the translation and English")
        #expect(inInformation.count == 1, "The hairline above Languages, for comparison")
        let ink = try #require(between.first)
        let reference = try #require(inInformation.first)
        #expect(abs(ink - reference) <= reference * 0.2, "Drawn alike: \(ink) and \(reference)")
    }

    @Test("The Dictation tab keeps its layout on the shared pieces: its header and Clear All, a row per recording, and the highlighted one's detail beside them")
    func dictationLayoutOnTheSharedPieces() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        for transcript in ["made-up first transcript", "made-up second transcript"] {
            let audio = fixture.folder.url.appendingPathComponent("made-up-\(UUID().uuidString).wav")
            try Data("made-up audio".utf8).write(to: audio)
            _ = try fixture.dictationHistory.record(transcript, language: "en-US", duration: 1, audioSourceURL: audio)
        }
        let ax = try await PaletteAccessibility.layOut(fixture.palette, tab: .dictation)
        defer {
            fixture.palette.dictationPlayer.stop()
            ax.close()
        }

        #expect(await ax.waitFor { PaletteAccessibility.element(reading: "Recent", in: ax.root) } != nil, "The list's header")
        #expect(PaletteAccessibility.element(reading: "Clear All", in: ax.root) != nil)
        let list = try #require(PaletteAccessibility.scrollViews(in: ax.root).first { $0.documentView is NSTableView })
        #expect((list.documentView as? NSTableView)?.numberOfRows == 2)
        #expect(abs(list.accessibilityFrame().width - 330) < 1)

        // The detail: what's read right of the list.
        let listEdge = list.accessibilityFrame().maxX
        func inDetail(_ text: String) -> NSObject? {
            PaletteAccessibility.element(reading: text, in: ax.root) { PaletteAccessibility.frame(of: $0).minX >= listEdge }
        }
        #expect(await ax.waitFor { inDetail("made-up second transcript") } != nil, "The newest recording's transcript")
        #expect(inDetail("Information") != nil)
        #expect(inDetail("Recorded") != nil)

        #expect(fixture.palette.handleKeyDown(fixture.commandKey(kVK_DownArrow, "", modifiers: [.function, .numericPad])) == nil)
        #expect(await ax.waitFor { inDetail("made-up first transcript") } != nil, "The detail follows the highlight")
    }

    @Test("Moving the highlight shows that record in the detail")
    func detailFollowsTheHighlight() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        fixture.recents.save("Thank you", translated: "Merci", from: "en", to: "fr")
        let ax = try await PaletteAccessibility.layOut(fixture.palette)
        defer { ax.close() }

        #expect(await ax.text("palette.translate.detail.translation") == "Merci")
        #expect(await ax.text("palette.translate.detail.source") == "Thank you")
        #expect(try await ax.texts(in: "palette.translate.detail.languages").contains("English → French"))

        #expect(fixture.palette.handleKeyDown(fixture.commandKey(kVK_DownArrow, "", modifiers: [.function, .numericPad])) == nil)
        #expect(fixture.palette.state.selection == 1)
        #expect(await ax.shows("palette.translate.detail.translation", "おやすみ"))
        #expect(await ax.shows("palette.translate.detail.source", "Good night"))
        #expect(try await ax.texts(in: "palette.translate.detail.languages").contains("English → Japanese"))
    }

    @Test("The detail's buttons do what the keys do: Copy (↵, ⌘C), Paste (⌘P), Read Aloud (Space), and Delete, which asks first")
    func buttonsDoWhatTheKeysDo() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        var offered: [Capability] = []
        palette.offerPasteSetup = { offered.append($0) }
        palette.frontmostApp = { PasteTarget(processIdentifier: 4242, isKeybumps: false) }
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let merci = fixture.recents.save("Thank you", translated: "Merci", from: "en", to: "fr")

        // Copy: copied, kept out of Clipboard History, as Return and ⌘C do.
        var ax = try await PaletteAccessibility.layOut(palette)
        defer { ax.close() }
        let copy = try await ax.require("palette.translate.detail.copy")
        #expect(PaletteAccessibility.label(of: copy) == "Copy")
        #expect(PaletteAccessibility.hint(of: copy) == "Return, or Command C")
        PaletteAccessibility.press(copy)
        #expect(fixture.pasteboard.string(forType: .string) == "Merci")
        fixture.clipboard.pollForTesting()
        #expect(fixture.clipboard.entries.isEmpty, "Kept out of Clipboard History")
        ax.close()

        // Paste: as ⌘P does. Without Accessibility, it copies instead and offers setup.
        fixture.pasteboard.clearContents()
        ax = try await PaletteAccessibility.layOut(palette)
        palette.rememberPasteTarget()
        let paste = try await ax.require("palette.translate.detail.paste")
        #expect(PaletteAccessibility.hint(of: paste) == "Command P")
        PaletteAccessibility.press(paste)
        #expect(fixture.pasteboard.string(forType: .string) == "Merci")
        #expect(offered == [.translation])
        ax.close()

        // Read Aloud: as Space does; it says Stop Reading while it reads, and again stops.
        ax = try await PaletteAccessibility.layOut(palette)
        let readAloud = try await ax.require("palette.translate.detail.readAloud")
        #expect(PaletteAccessibility.label(of: readAloud) == "Read Aloud")
        #expect(PaletteAccessibility.hint(of: readAloud) == "Space")
        PaletteAccessibility.press(readAloud)
        await fixture.tab.reading?.value
        #expect(fixture.speaker.readings == [.init(text: "Merci", language: "fr")])
        #expect(fixture.tab.isReading(merci.id))
        #expect(await ax.waitFor { ax.label(ofElement: "palette.translate.detail.readAloud") == "Stop Reading" ? true : nil } == true)
        PaletteAccessibility.press(try await ax.require("palette.translate.detail.readAloud"))
        #expect(!fixture.tab.isReading(merci.id))
        #expect(fixture.speaker.stops == 1)
        #expect(await ax.waitFor { ax.label(ofElement: "palette.translate.detail.readAloud") == "Read Aloud" ? true : nil } == true)

        // Delete: asks first, as the Delete key does; nothing goes until the alert's Delete.
        let delete = try await ax.require("palette.translate.detail.delete")
        #expect(PaletteAccessibility.hint(of: delete) == "Command Delete")
        PaletteAccessibility.press(delete)
        let asked = try #require(palette.state.contentPendingDeletion)
        #expect(asked.title == "Delete this translation?")
        #expect(asked.message == "It will be removed from this Mac.")
        #expect(fixture.recents.records.count == 2, "Nothing deleted yet")
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) != nil, "The alert has the keys")
        palette.confirmContentDeletion(asked)
        palette.contentDeletionDidClose()
        #expect(fixture.recents.records.map(\.sourceText) == ["Good night"])
    }

    @Test("With no voice for its language, the detail says so under its buttons")
    func noVoiceMessage() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        fixture.speaker.languagesWithoutVoice = ["ja"]
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let ax = try await PaletteAccessibility.layOut(fixture.palette)
        defer { ax.close() }

        #expect(ax.element("palette.translate.detail.speechProblem") == nil)
        #expect(fixture.palette.handleKeyDown(fixture.key(kVK_Space, " ")) == nil)
        await fixture.tab.reading?.value
        #expect(await ax.waitFor { ax.text(ofElement: "palette.translate.detail.speechProblem") } == FakeTranslationSpeaker.noVoice)
        #expect(ax.label(ofElement: "palette.translate.detail.readAloud") == "Read Aloud")
    }

    @Test("VoiceOver reads the detail in order: the translation, the source, the languages, then the actions")
    func voiceOverOrder() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let ax = try await PaletteAccessibility.layOut(fixture.palette)
        defer { ax.close() }

        let detail = try await ax.require("palette.translate.detail")
        let read = PaletteAccessibility.identifiersInNavigationOrder(in: detail)
            .filter { $0.hasPrefix("palette.translate.detail.") }
        #expect(read == [
            "palette.translate.detail.translation",
            "palette.translate.detail.source",
            "palette.translate.detail.languages",
            "palette.translate.detail.copy",
            "palette.translate.detail.paste",
            "palette.translate.detail.readAloud",
            "palette.translate.detail.delete",
        ])
        #expect(try await ax.texts(in: "palette.translate.detail.languages") == [
            "Information", "Languages", "English → Japanese", "Saved", fixture.recents.records[0].savedAt.formatted(date: .abbreviated, time: .shortened),
        ])
    }

    @Test("Text selected with the pointer in the detail: ⌘C is Edit › Copy's, not the saved translation's")
    func pointerSelectionInTheDetail() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        fixture.recents.save("Good night", translated: "おやすみ", from: "en", to: "ja")
        let panel = try #require(fixture.palette.layOutForTesting(.translate))
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()

        // Some macOS versions (26 on CI) build SwiftUI's selectable text only on a real click, so
        // there's nothing to find and this test stops here;
        // `PaletteCopyPasteKeyTests.pointerSelectionInAStandIn` covers the same decision on every macOS.
        guard let translation = PaletteCopyPasteKeyTests.selectableText(in: panel.contentView) else { return }
        #expect(panel.makeFirstResponder(translation))
        #expect(fixture.palette.handleKeyDown(fixture.commandKey(kVK_ANSI_C, "c")) == nil, "Nothing selected: ⌘C copies the record")
        #expect(fixture.pasteboard.string(forType: .string) == "おやすみ")

        fixture.pasteboard.clearContents()
        _ = fixture.palette.layOutForTesting(.translate)
        try await Task.sleep(for: .milliseconds(100))
        let again = try #require(PaletteCopyPasteKeyTests.selectableText(in: panel.contentView))
        #expect(panel.makeFirstResponder(again))
        again.perform(#selector(NSResponder.selectAll(_:)), with: nil)
        #expect(fixture.palette.handleKeyDown(fixture.commandKey(kVK_ANSI_C, "c")) != nil, "Selected text is Edit › Copy's")
        #expect(fixture.pasteboard.string(forType: .string) == nil, "The record wasn't copied")
    }

    @Test("After saving, the new translation is highlighted and shown; after a delete, the highlight stays on a row that exists; with none left, the empty state")
    func selectionAfterSaveAndDelete() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        let palette = fixture.palette
        fixture.recents.save("One", translated: "Un", from: "en", to: "fr")
        fixture.recents.save("Two", translated: "Deux", from: "en", to: "fr")
        let ax = try await PaletteAccessibility.layOut(palette)
        defer { ax.close() }

        // Return saves the translation being typed; it's highlighted at the top, and shown.
        palette.state.historyQuery = TranslateTabTests.english
        fixture.tab.update(query: TranslateTabTests.english)
        await fixture.tab.work?.value
        #expect(!ax.panel.isKeyWindow, "The translation's end didn't give the hidden palette keystrokes typed in other apps")
        #expect(palette.handleKeyDown(fixture.key(kVK_Return, "\r")) == nil)
        #expect(palette.state.selection == 0)
        let saved = "[ja] \(TranslateTabTests.english)"
        #expect(await ax.shows("palette.translate.detail.translation", saved))

        func deleteHighlighted() async throws {
            PaletteAccessibility.press(try await ax.require("palette.translate.detail.delete"))
            let confirmation = try #require(palette.state.contentPendingDeletion)
            palette.confirmContentDeletion(confirmation)
            palette.contentDeletionDidClose()
        }

        // The last row: the highlight moves up to the new last row.
        palette.state.selection = 2
        #expect(await ax.shows("palette.translate.detail.translation", "Un"))
        try await deleteHighlighted()
        #expect(fixture.recents.records.map(\.translatedText) == [saved, "Deux"])
        #expect(palette.state.selection == 1)
        #expect(await ax.shows("palette.translate.detail.translation", "Deux"))

        // The first row: the next one takes its place.
        palette.state.selection = 0
        #expect(await ax.shows("palette.translate.detail.translation", saved))
        try await deleteHighlighted()
        #expect(palette.state.selection == 0)
        #expect(await ax.shows("palette.translate.detail.translation", "Deux"))

        try await deleteHighlighted()
        #expect(fixture.recents.records.isEmpty)
        #expect(await ax.waitFor { ax.element("palette.translate.empty") } != nil, "The empty state, as before")
        #expect(ax.element("palette.translate.detail") == nil)
    }

    @Test("Arrowing past the visible rows scrolls the list to the highlight, as in Dictation (#353)")
    func listScrollsToTheHighlight() async throws {
        let fixture = TranslatePaletteFixture()
        defer { fixture.tearDown() }
        for index in 1...40 {
            fixture.recents.save("Made-up text \(index)", translated: "Texte inventé \(index)", from: "en", to: "fr")
        }
        let ax = try await PaletteAccessibility.layOut(fixture.palette)
        defer { ax.close() }
        let list = try #require(PaletteAccessibility.scrollViews(in: ax.root).first { $0.documentView is NSTableView })
        #expect(list.contentView.bounds.minY <= 0)

        for _ in 0..<30 { _ = fixture.palette.handleKeyDown(fixture.commandKey(kVK_DownArrow, "", modifiers: [.function, .numericPad])) }

        #expect(fixture.palette.state.selection == 30)
        #expect(await ax.waitFor { list.contentView.bounds.minY > 300 ? true : nil } == true, "The list scrolled down to row 30")
        #expect(await ax.shows("palette.translate.detail.translation", "Texte inventé 10"))
    }
}

/// A palette laid out offscreen on the Translate tab, read through SwiftUI's accessibility elements
/// as VoiceOver reads them. SwiftUI builds those only while an assistive app asks for them, so
/// `layOut` asks as one does (`AXEnhancedUserInterface`) and `close` stops asking. Elements are read
/// through the NSAccessibility getters by name, since SwiftUI's aren't a public type.
@MainActor
struct PaletteAccessibility {
    let panel: NSWindow
    let root: NSView

    /// `appearance` fixes light or dark, as a pixel check needs; nil follows the Mac's. When it
    /// throws, it has already stopped asking and put the panel away, since the caller can't `close`.
    static func layOut(
        _ palette: CommandPaletteController,
        tab: CommandPaletteTab = .translate,
        appearance: NSAppearance.Name? = nil
    ) async throws -> PaletteAccessibility {
        let panel = try #require(palette.layOutForTesting(tab))
        setAssistiveAppAsking(true)
        do {
            panel.appearance = appearance.flatMap(NSAppearance.init(named:))
            let root = try #require(panel.contentView)
            let accessibility = PaletteAccessibility(panel: panel, root: root)
            // The palette's own element, once SwiftUI has built them, and its list, once laid out.
            _ = try #require(await accessibility.waitFor {
                children(of: root).first { label(of: $0) == "Keybumps command palette" }
            }, "SwiftUI built no accessibility elements")
            _ = await accessibility.waitFor {
                root.layoutSubtreeIfNeeded()
                return scrollViews(in: root).first { $0.documentView is NSTableView }
            }
            return accessibility
        } catch {
            panel.orderOut(nil)
            setAssistiveAppAsking(false)
            throw error
        }
    }

    func close() {
        panel.orderOut(nil)
        Self.setAssistiveAppAsking(false)
    }

    /// The deprecated setter is called by name: there's no other way to set an attribute on the
    /// app, which is what an assistive app does.
    private static func setAssistiveAppAsking(_ asking: Bool) {
        _ = NSApp.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: asking as NSNumber, with: "AXEnhancedUserInterface"
        )
    }

    // MARK: Finding

    func element(_ identifier: String) -> NSObject? {
        Self.element(identifier, in: root)
    }

    func require(_ identifier: String) async throws -> NSObject {
        try #require(await waitFor { element(identifier) }, "No element \(identifier)")
    }

    /// An element's text, once SwiftUI has filled it in.
    func text(_ identifier: String) async -> String? {
        await waitFor { text(ofElement: identifier) }
    }

    /// Whether an element comes to read `text`, as SwiftUI redraws.
    func shows(_ identifier: String, _ expected: String) async -> Bool {
        await waitFor { text(ofElement: identifier) == expected ? true : nil } ?? false
    }

    func text(ofElement identifier: String) -> String? {
        element(identifier).flatMap(Self.text(of:))
    }

    func label(ofElement identifier: String) -> String? {
        element(identifier).flatMap(Self.label(of:))
    }

    /// The texts inside an element, in order.
    func texts(in identifier: String) async throws -> [String] {
        func collect(_ object: NSObject) -> [String] {
            let children = Self.children(of: object)
            return children.isEmpty ? [Self.text(of: object)].compactMap { $0 } : children.flatMap(collect)
        }
        return collect(try await require(identifier))
    }

    func waitFor<T>(_ value: () -> T?) async -> T? {
        for _ in 0..<150 {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return value()
    }

    /// The first element under `object` that VoiceOver reads as `text`, such as a section header,
    /// and that `matches`, such as by where it is.
    static func element(
        reading text: String, in object: NSObject, where matches: (NSObject) -> Bool = { _ in true }
    ) -> NSObject? {
        if children(of: object).isEmpty, self.text(of: object) == text, matches(object) { return object }
        for child in children(of: object) {
            if let found = element(reading: text, in: child, where: matches) { return found }
        }
        return nil
    }

    // MARK: Drawing

    /// An element's frame in the palette view's own points, measured from its top left.
    func frameFromTop(of object: NSObject) -> NSRect {
        let inView = root.convert(panel.convertFromScreen(Self.frame(of: object)), from: nil)
        return root.isFlipped ? inView : NSRect(
            x: inView.minX, y: root.bounds.height - inView.maxY, width: inView.width, height: inView.height
        )
    }

    /// The palette as it draws, at 2x, through AppKit and Core Animation, as the app draws it.
    func render() throws -> NSBitmapImageRep {
        root.layoutSubtreeIfNeeded()
        let size = root.bounds.size
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep
    }

    /// The hairlines drawn across `x` (in points) between two heights measured from the top: how
    /// much each one differs from the background there, summed over its pixel rows, so a line
    /// that straddles two rows counts the same as one that fills one.
    static func hairlines(in image: NSBitmapImageRep, x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> [Double] {
        func luma(_ row: Int) -> Double {
            // Averaged across a short stretch of the line.
            let columns = Array(stride(from: Int(x * 2), to: Int(x * 2) + 40, by: 4))
            return columns.map { column in
                guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return 0 }
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
            }.reduce(0, +) / Double(columns.count)
        }
        let rows = Array(Int(top * 2)..<Int(bottom * 2))
        guard let first = rows.first else { return [] }
        let background = luma(first)
        var lines: [Double] = []
        var current = 0.0
        for row in rows {
            let difference = abs(luma(row) - background)
            if difference > 3 {
                current += difference
            } else if current > 0 {
                lines.append(current)
                current = 0
            }
        }
        if current > 0 { lines.append(current) }
        return lines
    }

    static func element(_ identifier: String, in object: NSObject) -> NSObject? {
        if self.identifier(of: object) == identifier { return object }
        for child in children(of: object) {
            if let found = element(identifier, in: child) { return found }
        }
        return nil
    }

    /// Every identifier under an element, in the order VoiceOver moves through them.
    static func identifiersInNavigationOrder(in object: NSObject) -> [String] {
        let ordered = (get(object, "accessibilityChildrenInNavigationOrder") as? [Any])?.compactMap { $0 as? NSObject }
        return (ordered ?? children(of: object)).flatMap { child in
            [identifier(of: child)].compactMap { $0 }.filter { !$0.isEmpty } + identifiersInNavigationOrder(in: child)
        }
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    // MARK: Reading and pressing

    static func children(of object: NSObject) -> [NSObject] {
        (get(object, "accessibilityChildren") as? [Any])?.compactMap { $0 as? NSObject } ?? []
    }

    static func identifier(of object: NSObject) -> String? { get(object, "accessibilityIdentifier") as? String }
    static func label(of object: NSObject) -> String? { get(object, "accessibilityLabel") as? String }
    static func hint(of object: NSObject) -> String? { get(object, "accessibilityHelp") as? String }
    static func frame(of object: NSObject) -> NSRect { (get(object, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero }

    /// What VoiceOver reads for a text: its value, or its label.
    static func text(of object: NSObject) -> String? {
        if let value = get(object, "accessibilityValue") as? String, !value.isEmpty { return value }
        return label(of: object)
    }

    static func press(_ object: NSObject) {
        _ = object.perform(NSSelectorFromString("accessibilityPerformPress"))
    }

    private static func get(_ object: NSObject, _ getter: String) -> Any? {
        object.responds(to: NSSelectorFromString(getter)) ? object.value(forKey: getter) : nil
    }
}
