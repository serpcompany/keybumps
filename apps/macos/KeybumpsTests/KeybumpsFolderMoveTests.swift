import AppKit
import Foundation
import Testing
@testable import Keybumps

/// The one-time move into the Keybumps folder (#602, ADR 0013). A Mac with the old layout ends up
/// with each plugin's files in their own folders, and each store reads them there. A move cut short
/// finishes at the next launch. A file in both places is never overwritten. A failure leaves the
/// file where its store reads it. `~/Documents/Keybumps` is looked in only on a Mac that kept
/// something there. Everything runs in a temporary folder, with `InMemoryDefaults` and made-up
/// content.
@MainActor
@Suite("Keybumps folder: the one-time move")
struct KeybumpsFolderMoveTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeybumpsFolderMove-\(UUID().uuidString)", isDirectory: true)
    let defaults = InMemoryDefaults()

    /// The Keybumps folder and `~/Documents/Keybumps`, in `root`.
    var paths: ProductPaths {
        let keybumps = root.appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Keybumps", isDirectory: true)
        return ProductPaths(
            keybumpsFolder: keybumps,
            oldDocumentsFolder: root.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Keybumps", isDirectory: true),
            translatedSpeechTemporary: root.appendingPathComponent("tmp", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    // MARK: The old layout

    @Test("A Mac with the old layout ends up with each plugin's files in its own folder, and each store reads them there")
    func movesTheOldLayout() async throws {
        defer { tearDown() }
        let fixture = RecordingLibraryFixture()
        defer { fixture.tearDown() }
        let paths = self.paths

        // Dictation History in Documents, and the last dictation.
        try dictation(at: 1_790_000_000, in: paths.oldPlace(of: .dictationHistory))
        try write("made-up last dictation", to: paths.oldPlace(of: .lastDictation))

        // Clipboard History: a screenshot from the old recordings folder, with its copy, and text.
        let media = paths.oldPlace(of: .clipboardMedia).appendingPathComponent("made-up.png")
        try write("made-up image", to: media)
        let shot = paths.oldPlace(of: .recordings).appendingPathComponent("made-up-shot", isDirectory: true)
            .appendingPathComponent("screenshot-1.png")
        try write("made-up screenshot", to: shot)
        try write(JSONEncoder().encode([
            ClipboardEntry(
                id: UUID(), text: "", capturedAt: Date(timeIntervalSince1970: 1_790_000_000), kind: .image,
                mediaPath: media.path, mediaPasteboardType: "public.png", fingerprint: "image:made-up",
                sourcePath: shot.path, isScreenCapture: true
            ),
            ClipboardEntry(id: UUID(), text: "made-up clipboard text", capturedAt: Date(timeIntervalSince1970: 1_790_000_001)),
        ]), to: paths.oldPlace(of: .clipboardHistory))

        RecentTranslations(storageURL: paths.oldPlace(of: .recentTranslations))
            .save("made-up source", translated: "made-up translation", from: "en", to: "fr")
        try SnippetStore(storageURL: paths.oldPlace(of: .snippets), secrets: InMemorySnippetSecretStore())
            .add(SnippetDraft(name: "Made-up", keyword: "mup", text: "made-up snippet"))
        let unreadableSnippets = "snippets.unreadable-made-up.json"
        try write("made-up unreadable snippets", to: paths.keybumpsFolder.appendingPathComponent(unreadableSnippets))
        try write("[]", to: paths.oldPlace(of: .coachingEvents))

        // A recording in the old recordings folder, indexed, and the index's unreadable copy.
        let capture = try await fixture.recording(at: 100, in: paths.oldPlace(of: .recordings))
        let library = recordingLibrary(at: paths.oldPlace(of: .recordingsIndex), capturesFolder: paths.oldPlace(of: .recordings))
        library.load()
        library.add(capture)
        await library.launchCheck?.value
        try #require(library.recordings.count == 1)
        // A build before #605 remembered the folder it recorded into.
        defaults.set([paths.oldPlace(of: .recordings).path], forKey: RecordingFolderMemory.key)
        try write("made-up unreadable index", to: paths.oldPlace(of: .recordingsIndexUnreadable))
        let repository = try #require(ScreencastRepository("made-up/repo"))
        try write(
            JSONEncoder().encode(ScreencastRepositoryMemory.Stored(websites: ["example.com": repository])),
            to: paths.oldPlace(of: .screencastRepositories)
        )

        // What was at the top of the Keybumps folder: Dictation's models, recent emoji, Quick
        // Search's Recent Items and learned usage, and timers.
        let model = try installedModel(.whisperCppTurbo, in: paths.oldPlace(of: .dictationModels))
        EmojiRecents(storageURL: paths.oldPlace(of: .emojiRecents)).use("😀")
        let app = QuickSearchResult(url: URL(fileURLWithPath: "/System/Applications/Dictionary.app"), kind: .application)
        RecentItemStore(storageURL: paths.oldPlace(of: .recentItems)).record(app)
        ApplicationUsageStore(storageURL: paths.oldPlace(of: .applicationUsage)).record(app)
        try write("made-up timers", to: paths.oldPlace(of: .timers))

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 0)
        #expect(report.conflicts == 0)
        #expect(report.leftInOldPlace.isEmpty)
        #expect(report.looksInDocuments)
        for item in KeybumpsFolderItem.allCases {
            #expect(!exists(paths.oldPlace(of: item)), "\(item.rawValue) left its old place")
            #expect(exists(paths.place(of: item)), "\(item.rawValue) is in the Keybumps folder")
            #expect(paths.inUse(item) == paths.place(of: item))
        }
        #expect(!exists(paths.keybumpsFolder.appendingPathComponent(unreadableSnippets)))
        #expect(text(at: paths.snippets.appendingPathComponent(unreadableSnippets)) == "made-up unreadable snippets")
        #expect(text(at: paths.inUse(.lastDictation)) == "made-up last dictation")
        #expect(text(at: paths.inUse(.coachingEvents)) == "[]")
        #expect(text(at: paths.inUse(.timers)) == "made-up timers")
        #expect(!exists(paths.oldDocumentsFolder), "Documents/Keybumps is removed once it's empty")
        // Nothing is left loose at the top: each plugin that saves files has its own folder.
        #expect(try names(in: paths.keybumpsFolder) == [
            "clipboard_history", "dictation", "emoji_picker", "quick_search", "screengrabs",
            "shortcut_coach", "snippets", "timers", "translations",
        ])
        #expect(try names(in: paths.dictation) == ["last-dictation.txt", "models", "recordings"])
        #expect(documentsMoved(defaults))

        // Each store reads its new folder.
        let history = DictationHistoryService(recordingsDirectoryURL: paths.inUse(.dictationHistory), appVersion: "0.0.0")
        #expect(history.entries.map(\.text) == ["made-up dictation"])
        #expect(history.entries.first?.audioURL.map(exists) == true)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KeybumpsFolderMove-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardHistoryService(
            storageURL: paths.inUse(.clipboardHistory),
            pasteboard: pasteboard,
            mediaDirectoryURL: paths.inUse(.clipboardMedia),
            sourceApps: .inert
        )
        #expect(clipboard.entries.count == 2)
        let image = try #require(clipboard.entries.first { $0.kind == .image })
        #expect(image.mediaPath == paths.inUse(.clipboardMedia).appendingPathComponent("made-up.png").path)
        #expect(image.sourcePath == paths.screengrabsRecordings.appendingPathComponent("made-up-shot/screenshot-1.png").path)
        #expect(image.mediaPath.map { exists(URL(fileURLWithPath: $0)) } == true)
        #expect(image.sourcePath.map { exists(URL(fileURLWithPath: $0)) } == true)

        #expect(RecentTranslations(storageURL: paths.inUse(.recentTranslations)).records.map(\.translatedText) == ["made-up translation"])
        #expect(SnippetStore(storageURL: paths.inUse(.snippets), secrets: InMemorySnippetSecretStore()).snippets.map(\.name) == ["Made-up"])
        #expect(ScreencastRepositoryMemory(storageURL: paths.inUse(.screencastRepositories)).stored.websites["example.com"] == repository)
        #expect(EmojiRecents(storageURL: paths.inUse(.emojiRecents)).glyphs == ["😀"])
        #expect(RecentItemStore(storageURL: paths.inUse(.recentItems)).items.map(\.result) == [app])
        #expect(ApplicationUsageStore(storageURL: paths.inUse(.applicationUsage)).record(for: app.url)?.launchCount == 1)
        let models = DictationModelManager(modelsRoot: paths.inUse(.dictationModels), downloader: NoModelDownloader())
        #expect(models.state(for: .whisperCppTurbo) == .installed, "model-location.txt names the model's new folder")
        #expect(models.installedModelFolder(for: .whisperCppTurbo)?.path == paths.dictationModels.appendingPathComponent(model).path)

        // The index names the recording's new folder, is still readable only by the person, and
        // ScreenGrabs remembers the new folder, not Documents.
        let index = paths.inUse(.recordingsIndex)
        let permissions = try FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let moved = recordingLibrary(at: index, capturesFolder: paths.inUse(.recordings))
        moved.load()
        await moved.launchCheck?.value
        let recordingFolder = paths.screengrabsRecordings.appendingPathComponent(RecordingLibraryFixture.folderName(100), isDirectory: true)
        #expect(moved.recordings.map(\.folder.path) == [recordingFolder.path])
        #expect(moved.recordings.map(\.isMissing) == [false])
        #expect(defaults.stringArray(forKey: RecordingFolderMemory.key) == [paths.screengrabsRecordings.path])

        // The next launch finds nothing to do and changes nothing.
        let indexBytes = try Data(contentsOf: index)
        let clipboardBytes = try Data(contentsOf: paths.inUse(.clipboardHistory))
        #expect(KeybumpsFolderMove(paths: paths, defaults: defaults).run() == KeybumpsFolderMove.Report())
        #expect(try Data(contentsOf: index) == indexBytes)
        #expect(try Data(contentsOf: paths.inUse(.clipboardHistory)) == clipboardBytes)
    }

    // MARK: A move cut short

    @Test("A move cut short finishes at the next launch, from a partial copy, a copy left beside its original, or a half-merged folder")
    func resumesAnInterruptedMove() throws {
        defer { tearDown() }
        let paths = self.paths

        // Clipboard History's copy was being written when Keybumps quit: the original is still there.
        try write("[]", to: paths.oldPlace(of: .clipboardHistory))
        try write("[", to: KeybumpsFolderMove.partialCopy(of: paths.place(of: .clipboardHistory)))
        // Recent translations' copy was put in place, but the original wasn't removed yet.
        try write("made-up translations", to: paths.oldPlace(of: .recentTranslations))
        try write("made-up translations", to: paths.place(of: .recentTranslations))
        // Half the clipboard's images, and one dictation of two, had moved.
        for name in ["a.png", "b.png"] {
            try write("made-up \(name)", to: paths.oldPlace(of: .clipboardMedia).appendingPathComponent(name))
        }
        try write("made-up a.png", to: paths.place(of: .clipboardMedia).appendingPathComponent("a.png"))
        try dictation(at: 1_790_000_000, in: paths.oldPlace(of: .dictationHistory))
        try dictation(at: 1_790_000_100, in: paths.oldPlace(of: .dictationHistory))
        try FileManager.default.createDirectory(at: paths.dictationRecordings, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: paths.oldPlace(of: .dictationHistory).appendingPathComponent("1790000000", isDirectory: true),
            to: paths.dictationRecordings.appendingPathComponent("1790000000", isDirectory: true)
        )

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 0)
        #expect(report.conflicts == 0)
        #expect(report.leftInOldPlace.isEmpty)
        for item in [KeybumpsFolderItem.clipboardHistory, .recentTranslations, .clipboardMedia, .dictationHistory] {
            #expect(!exists(paths.oldPlace(of: item)), "\(item.rawValue) left its old place")
        }
        #expect(text(at: paths.place(of: .clipboardHistory)) == "[]")
        #expect(!exists(KeybumpsFolderMove.partialCopy(of: paths.place(of: .clipboardHistory))))
        #expect(text(at: paths.place(of: .recentTranslations)) == "made-up translations")
        #expect(try names(in: paths.place(of: .clipboardMedia)) == ["a.png", "b.png"])
        #expect(text(at: paths.place(of: .clipboardMedia).appendingPathComponent("b.png")) == "made-up b.png")
        let history = DictationHistoryService(recordingsDirectoryURL: paths.inUse(.dictationHistory), appVersion: "0.0.0")
        #expect(history.entries.map(\.id) == ["1790000100", "1790000000"])
        #expect(!exists(paths.oldDocumentsFolder))
        #expect(documentsMoved(defaults))
    }

    // MARK: Never overwritten

    @Test("A file in both places that differs is never overwritten: both stay, and the store reads the Keybumps folder's")
    func neverOverwrites() throws {
        defer { tearDown() }
        let paths = self.paths

        try write("made-up old translations", to: paths.oldPlace(of: .recentTranslations))
        try write("made-up new translations", to: paths.place(of: .recentTranslations))
        try write("made-up old image", to: paths.oldPlace(of: .clipboardMedia).appendingPathComponent("x.png"))
        try write("made-up new image", to: paths.place(of: .clipboardMedia).appendingPathComponent("x.png"))
        let oldMeta = paths.oldPlace(of: .recordings).appendingPathComponent("1791000100/meta.json")
        let newMeta = paths.place(of: .recordings).appendingPathComponent("1791000100/meta.json")
        try write("made-up old meta", to: oldMeta)
        try write("made-up new meta", to: newMeta)

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.conflicts == 3)
        #expect(report.failures == 0)
        #expect(report.leftInOldPlace.isEmpty)
        #expect(text(at: paths.oldPlace(of: .recentTranslations)) == "made-up old translations")
        #expect(text(at: paths.place(of: .recentTranslations)) == "made-up new translations")
        #expect(paths.inUse(.recentTranslations) == paths.place(of: .recentTranslations))
        #expect(text(at: paths.oldPlace(of: .clipboardMedia).appendingPathComponent("x.png")) == "made-up old image")
        #expect(text(at: paths.place(of: .clipboardMedia).appendingPathComponent("x.png")) == "made-up new image")
        #expect(text(at: oldMeta) == "made-up old meta", "Documents/Keybumps keeps what it can't move")
        #expect(text(at: newMeta) == "made-up new meta")
        // Nothing of Keybumps's is waiting to move: Documents isn't looked in again.
        #expect(documentsMoved(defaults))

        // The next launch still overwrites nothing, and leaves Documents alone: the conflicts left
        // in the old places are older than the move, so they don't show an older build ran since.
        let next = KeybumpsFolderMove(paths: paths, defaults: defaults).run()
        #expect(next.conflicts == 2)
        #expect(!next.looksInDocuments)
        #expect(text(at: oldMeta) == "made-up old meta")
        #expect(text(at: paths.oldPlace(of: .recentTranslations)) == "made-up old translations")
        #expect(text(at: paths.place(of: .recentTranslations)) == "made-up new translations")
    }

    // MARK: Failures

    @Test("A move that fails leaves the file in its old place, where its store reads it")
    func failureLeavesTheFileInUse() throws {
        defer { tearDown() }
        let paths = self.paths
        try SnippetStore(storageURL: paths.oldPlace(of: .snippets), secrets: InMemorySnippetSecretStore())
            .add(SnippetDraft(name: "Made-up", keyword: "mup", text: "made-up snippet"))
        let snippetsBytes = try Data(contentsOf: paths.oldPlace(of: .snippets))
        // A file where the Snippets folder goes, so the folder can't be made.
        try write("made-up blocker", to: URL(fileURLWithPath: paths.snippets.path))

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 1)
        #expect(report.leftInOldPlace == [.snippets])
        #expect(try Data(contentsOf: paths.oldPlace(of: .snippets)) == snippetsBytes)
        var thisLaunch = paths
        thisLaunch.leftInOldPlace = report.leftInOldPlace
        #expect(thisLaunch.inUse(.snippets) == paths.oldPlace(of: .snippets))
        #expect(thisLaunch.inUse(.recentTranslations) == paths.place(of: .recentTranslations))
        #expect(SnippetStore(storageURL: thisLaunch.inUse(.snippets), secrets: InMemorySnippetSecretStore()).snippets.map(\.name) == ["Made-up"])

        // Once the folder can be made, the next launch moves it.
        try FileManager.default.removeItem(at: paths.snippets)
        let next = KeybumpsFolderMove(paths: paths, defaults: defaults).run()
        #expect(next.failures == 0)
        #expect(next.leftInOldPlace.isEmpty)
        #expect(try Data(contentsOf: paths.place(of: .snippets)) == snippetsBytes)
    }

    @Test("Documents is looked in again at each launch until everything of Keybumps's there has moved")
    func documentsFailureIsRetried() throws {
        defer { tearDown() }
        let paths = self.paths
        let meta = paths.oldPlace(of: .recordings).appendingPathComponent("1791000100/meta.json")
        try write("made-up meta", to: meta)
        // A file where ScreenGrabs' folder goes, so the recordings can't move.
        try write("made-up blocker", to: URL(fileURLWithPath: paths.screengrabs.path))

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 1)
        #expect(report.leftInOldPlace == [.recordings])
        #expect(text(at: meta) == "made-up meta")
        #expect(!documentsMoved(defaults))

        try FileManager.default.removeItem(at: paths.screengrabs)
        let next = KeybumpsFolderMove(paths: paths, defaults: defaults).run()
        #expect(next.looksInDocuments)
        #expect(next.failures == 0)
        #expect(text(at: paths.place(of: .recordings).appendingPathComponent("1791000100/meta.json")) == "made-up meta")
        #expect(!exists(paths.oldDocumentsFolder))
        #expect(documentsMoved(defaults))
    }

    // MARK: Documents

    @Test("A Mac with no Keybumps folder never ran an earlier build, so Documents isn't looked in")
    func newInstallSkipsDocuments() throws {
        defer { tearDown() }
        let paths = self.paths
        let meta = paths.oldPlace(of: .recordings).appendingPathComponent("1791000100/meta.json")
        try write("made-up meta", to: meta)

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(!report.looksInDocuments)
        #expect(report == KeybumpsFolderMove.Report())
        #expect(documentsMoved(defaults))
        #expect(text(at: meta) == "made-up meta")
        #expect(!exists(paths.keybumpsFolder))
    }

    @Test("Once everything has moved out of Documents, Documents isn't looked in again")
    func documentsMovedIsRemembered() throws {
        defer { tearDown() }
        let paths = self.paths
        try FileManager.default.createDirectory(at: paths.keybumpsFolder, withIntermediateDirectories: true)
        let meta = paths.oldPlace(of: .recordings).appendingPathComponent("1791000100/meta.json")
        try write("made-up meta", to: meta)
        defaults.set(Date(), forKey: KeybumpsFolderMove.documentsMovedKey)

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(!report.looksInDocuments)
        #expect(text(at: meta) == "made-up meta")
        #expect(!exists(paths.place(of: .recordings)))
    }

    @Test("Dictations an older build saves in Documents after the move, move once its files outside Documents show it ran")
    func olderBuildAfterTheMove() throws {
        defer { tearDown() }
        let paths = self.paths
        try FileManager.default.createDirectory(at: paths.keybumpsFolder, withIntermediateDirectories: true)
        try dictation(at: 1_790_000_000, in: paths.oldPlace(of: .dictationHistory))
        #expect(KeybumpsFolderMove(paths: paths, defaults: defaults).run().looksInDocuments)
        #expect(!exists(paths.oldDocumentsFolder))
        // The move finished a minute ago.
        defaults.set(Date(timeIntervalSinceNow: -60), forKey: KeybumpsFolderMove.documentsMovedKey)

        // A build before #602 runs again, and dictates into Documents. Nothing outside Documents
        // shows it yet, so Documents isn't looked in.
        try dictation(at: 1_790_000_100, in: paths.oldPlace(of: .dictationHistory))
        #expect(!KeybumpsFolderMove(paths: paths, defaults: defaults).run().looksInDocuments)

        // It writes the last dictation at the top of the Keybumps folder once it's transcribed.
        try write("made-up older last dictation", to: paths.oldPlace(of: .lastDictation))
        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.looksInDocuments)
        #expect(report.failures == 0)
        #expect(report.conflicts == 0)
        #expect(!exists(paths.oldDocumentsFolder))
        #expect(text(at: paths.place(of: .lastDictation)) == "made-up older last dictation")
        let history = DictationHistoryService(recordingsDirectoryURL: paths.inUse(.dictationHistory), appVersion: "0.0.0")
        #expect(history.entries.map(\.id) == ["1790000100", "1790000000"])
        // The key is the time of this move now, so the next launch leaves Documents alone.
        #expect(!KeybumpsFolderMove(paths: paths, defaults: defaults).run().looksInDocuments)
    }

    @Test("A Mac where an earlier build ran, but whose Keybumps folder was removed, still has Documents looked in")
    func earlierBuildWithoutKeybumpsFolder() throws {
        for setupDone in [true, false] {
            defer { tearDown() }
            let defaults = InMemoryDefaults()
            let preferences = AppPreferences(defaults: defaults)
            if setupDone { preferences.didCompleteOnboarding = true } else { preferences.lastLaunchedVersion = "0.0.3-beta.30" }
            let paths = self.paths
            try write("made-up meta", to: paths.oldPlace(of: .recordings).appendingPathComponent("1791000100/meta.json"))

            let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

            #expect(report.looksInDocuments)
            #expect(report.failures == 0)
            #expect(text(at: paths.place(of: .recordings).appendingPathComponent("1791000100/meta.json")) == "made-up meta")
            #expect(!exists(paths.oldDocumentsFolder))
            #expect(documentsMoved(defaults))
        }
    }

    @Test("Documents/Keybumps is removed when only Finder's .DS_Store is left, and kept with anything else in it")
    func documentsFolderIsRemovedOnlyWhenEmpty() throws {
        for keepsOwnFile in [false, true] {
            defer { tearDown() }
            let defaults = InMemoryDefaults()
            let paths = self.paths
            try FileManager.default.createDirectory(at: paths.keybumpsFolder, withIntermediateDirectories: true)
            try write("made-up meta", to: paths.oldPlace(of: .recordings).appendingPathComponent("1791000100/meta.json"))
            try write("made-up Finder data", to: paths.oldDocumentsFolder.appendingPathComponent(".DS_Store"))
            let own = paths.oldDocumentsFolder.appendingPathComponent("made-up notes.txt")
            if keepsOwnFile { try write("made-up notes", to: own) }

            let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

            #expect(report.failures == 0)
            #expect(!exists(paths.oldPlace(of: .recordings)))
            #expect(exists(paths.oldDocumentsFolder) == keepsOwnFile)
            if keepsOwnFile { #expect(text(at: own) == "made-up notes") }
            #expect(documentsMoved(defaults))
        }
    }

    @Test("A folder chosen in Settings › ScreenGrabs before #605 stays where it is, and so does a chosen Documents/Keybumps")
    func chosenFoldersStay() throws {
        defer { tearDown() }
        let paths = self.paths
        try FileManager.default.createDirectory(at: paths.keybumpsFolder, withIntermediateDirectories: true)
        let meta = paths.oldPlace(of: .recordings).appendingPathComponent("1791000100/meta.json")
        try write("made-up meta", to: meta)
        defaults.set(paths.oldPlace(of: .recordings).standardizedFileURL.path, forKey: Self.chosenRecordingsFolderKey)

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 0)
        #expect(report.leftInOldPlace == [.recordings])
        #expect(text(at: meta) == "made-up meta")
        #expect(!exists(paths.place(of: .recordings)))
        #expect(!documentsMoved(defaults), "looked at again each launch")

        // Chose Documents/Keybumps itself instead: the old recordings move, and the folder stays.
        defaults.set(paths.oldDocumentsFolder.standardizedFileURL.path, forKey: Self.chosenRecordingsFolderKey)
        let next = KeybumpsFolderMove(paths: paths, defaults: defaults).run()
        #expect(next.leftInOldPlace.isEmpty)
        #expect(text(at: paths.place(of: .recordings).appendingPathComponent("1791000100/meta.json")) == "made-up meta")
        #expect(exists(paths.oldDocumentsFolder))
        #expect(documentsMoved(defaults))
    }

    // MARK: Across volumes

    @Test("Across volumes, each item is copied beside its place, checked, put in place, and only then removed, after a partial copy left by an earlier launch is cleared")
    func copiesAcrossVolumes() throws {
        defer { tearDown() }
        let paths = self.paths
        try dictation(at: 1_790_000_000, in: paths.oldPlace(of: .dictationHistory))
        try SnippetStore(storageURL: paths.oldPlace(of: .snippets), secrets: InMemorySnippetSecretStore())
            .add(SnippetDraft(name: "Made-up", keyword: "mup", text: "made-up snippet"))
        try write("made-up image", to: paths.oldPlace(of: .clipboardMedia).appendingPathComponent("made-up.png"))
        // An earlier launch quit while copying Dictation History.
        let leftover = KeybumpsFolderMove.partialCopy(of: paths.place(of: .dictationHistory))
        try write("made-up half a copy", to: leftover.appendingPathComponent("1790000000/output.wav"))

        var move = KeybumpsFolderMove(paths: paths, defaults: defaults)
        move.rename = Self.acrossVolumes
        let report = move.run()

        #expect(report.failures == 0)
        #expect(report.conflicts == 0)
        #expect(report.moved == 3)
        #expect(report.leftInOldPlace.isEmpty)
        for item in [KeybumpsFolderItem.dictationHistory, .snippets, .clipboardMedia] {
            #expect(!exists(paths.oldPlace(of: item)), "\(item.rawValue) left its old place")
            #expect(!exists(KeybumpsFolderMove.partialCopy(of: paths.place(of: item))), "\(item.rawValue) has no partial copy")
        }
        let history = DictationHistoryService(recordingsDirectoryURL: paths.inUse(.dictationHistory), appVersion: "0.0.0")
        #expect(history.entries.map(\.text) == ["made-up dictation"])
        #expect(history.entries.first?.audioURL.flatMap { text(at: $0) } == "made-up audio")
        #expect(SnippetStore(storageURL: paths.inUse(.snippets), secrets: InMemorySnippetSecretStore()).snippets.map(\.name) == ["Made-up"])
        #expect(text(at: paths.place(of: .clipboardMedia).appendingPathComponent("made-up.png")) == "made-up image")
        #expect(!exists(paths.oldDocumentsFolder))
        #expect(documentsMoved(defaults))
    }

    @Test("Across volumes, a copy cut short or that doesn't match is removed, and the original stays where its store reads it")
    func failedCopyLeavesTheOriginal() throws {
        for fault in [FaultyFileManager.Fault.copyCutShort, .copyDiffers] {
            defer { tearDown() }
            let paths = self.paths
            try SnippetStore(storageURL: paths.oldPlace(of: .snippets), secrets: InMemorySnippetSecretStore())
                .add(SnippetDraft(name: "Made-up", keyword: "mup", text: "made-up snippet"))
            let snippetsBytes = try Data(contentsOf: paths.oldPlace(of: .snippets))

            var move = KeybumpsFolderMove(paths: paths, fileManager: FaultyFileManager(fault), defaults: defaults)
            move.rename = Self.acrossVolumes
            let report = move.run()

            #expect(report.failures == 1, "\(fault)")
            #expect(report.leftInOldPlace == [.snippets], "\(fault)")
            #expect(try Data(contentsOf: paths.oldPlace(of: .snippets)) == snippetsBytes)
            #expect(!exists(paths.place(of: .snippets)))
            #expect(!exists(KeybumpsFolderMove.partialCopy(of: paths.place(of: .snippets))), "\(fault): no partial copy")
        }
    }

    @Test("Across volumes, a copy in place whose original couldn't be removed is read in the Keybumps folder, and the original goes next launch")
    func copyInPlaceOriginalStays() throws {
        defer { tearDown() }
        let paths = self.paths
        try SnippetStore(storageURL: paths.oldPlace(of: .snippets), secrets: InMemorySnippetSecretStore())
            .add(SnippetDraft(name: "Made-up", keyword: "mup", text: "made-up snippet"))
        let snippetsBytes = try Data(contentsOf: paths.oldPlace(of: .snippets))

        var move = KeybumpsFolderMove(paths: paths, fileManager: FaultyFileManager(.originalStays), defaults: defaults)
        move.rename = Self.acrossVolumes
        let report = move.run()

        #expect(report.failures == 1)
        #expect(report.leftInOldPlace.isEmpty)
        #expect(try Data(contentsOf: paths.place(of: .snippets)) == snippetsBytes)
        #expect(exists(paths.oldPlace(of: .snippets)))
        #expect(paths.inUse(.snippets) == paths.place(of: .snippets))

        let next = KeybumpsFolderMove(paths: paths, defaults: defaults).run()
        #expect(next.failures == 0)
        #expect(next.conflicts == 0)
        #expect(!exists(paths.oldPlace(of: .snippets)), "identical, so removed")
        #expect(try Data(contentsOf: paths.place(of: .snippets)) == snippetsBytes)
    }

    // MARK: Dictation's models

    @Test("Dictation's models move whole: an installed model is still installed, and a download cut short moves along and is still not installed")
    func modelsMoveWhole() throws {
        defer { tearDown() }
        let paths = self.paths
        let old = paths.oldPlace(of: .dictationModels)
        let model = try installedModel(.whisperCppTurbo, in: old)
        // whisper.cpp quit while checking its download, and WhisperKit while downloading: neither
        // wrote model-location.txt.
        let partialFile = "\(WhisperCppModel.turbo.fileName).partial"
        try write("made-up half a model", to: old.appendingPathComponent("whisperCppTurbo/\(partialFile)"))
        let partialFolder = "whisperMediumEnglish/models/argmaxinc/whisperkit-coreml/openai_whisper-medium.en/AudioEncoder.mlmodelc/weights"
        try write("made-up half a model", to: old.appendingPathComponent(partialFolder))
        let before = DictationModelManager(modelsRoot: old, downloader: NoModelDownloader())
        try #require(before.state(for: .whisperCppTurbo) == .installed)
        try #require(before.state(for: .whisperMediumEnglish) == .notInstalled)

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 0)
        #expect(report.conflicts == 0)
        #expect(report.moved == 1, "one rename")
        #expect(!exists(old))
        #expect(paths.inUse(.dictationModels) == paths.dictationModels)
        #expect(text(at: paths.dictationModels.appendingPathComponent("whisperCppTurbo/\(partialFile)")) == "made-up half a model")
        #expect(text(at: paths.dictationModels.appendingPathComponent(partialFolder)) == "made-up half a model")
        let after = DictationModelManager(modelsRoot: paths.inUse(.dictationModels), downloader: NoModelDownloader())
        #expect(after.state(for: .whisperCppTurbo) == .installed)
        #expect(after.installedModelFolder(for: .whisperCppTurbo)?.path == paths.dictationModels.appendingPathComponent(model).path)
        #expect(after.state(for: .whisperMediumEnglish) == .notInstalled, "a download cut short is never installed")
        #expect(after.state(for: .whisperTurboCompressed) == .notInstalled)

        // The next launch changes nothing.
        let location = DictationModelManager.locationFile(for: .whisperCppTurbo, in: paths.dictationModels)
        let locationBytes = try Data(contentsOf: location)
        #expect(KeybumpsFolderMove(paths: paths, defaults: defaults).run() == KeybumpsFolderMove.Report())
        #expect(try Data(contentsOf: location) == locationBytes)
    }

    @Test("Models that can't move stay installed in their old place, where Dictation reads them this launch")
    func modelsThatCantMoveStayInUse() throws {
        defer { tearDown() }
        let paths = self.paths
        let old = paths.oldPlace(of: .dictationModels)
        let model = try installedModel(.whisperCppTurbo, in: old)
        // A file where Dictation's folder goes, so its folder can't be made.
        try write("made-up blocker", to: URL(fileURLWithPath: paths.dictation.path))

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.leftInOldPlace.contains(.dictationModels))
        var thisLaunch = paths
        thisLaunch.leftInOldPlace = report.leftInOldPlace
        #expect(thisLaunch.inUse(.dictationModels) == old)
        let models = DictationModelManager(modelsRoot: thisLaunch.inUse(.dictationModels), downloader: NoModelDownloader())
        #expect(models.installedModelFolder(for: .whisperCppTurbo)?.path == old.appendingPathComponent(model).path)
    }

    // MARK: Merging

    @Test("What's already in a plugin's folder is merged with what moves, and a file that differs is never overwritten")
    func mergesIntoExistingFolders() throws {
        defer { tearDown() }
        let paths = self.paths
        // An older build ran after the move, downloaded a second model, and saved its own recents.
        let first = try installedModel(.whisperCppTurbo, in: paths.dictationModels)
        let second = try installedModel(.whisperMediumEnglish, in: paths.oldPlace(of: .dictationModels))
        try write("made-up newer recent items", to: paths.place(of: .recentItems))
        try write("made-up older recent items", to: paths.oldPlace(of: .recentItems))
        try write("made-up usage", to: paths.oldPlace(of: .applicationUsage))
        try write("made-up emoji", to: paths.place(of: .emojiRecents))
        try write("made-up emoji", to: paths.oldPlace(of: .emojiRecents))

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 0)
        #expect(report.conflicts == 1)
        #expect(!exists(paths.oldPlace(of: .dictationModels)))
        let models = DictationModelManager(modelsRoot: paths.inUse(.dictationModels), downloader: NoModelDownloader())
        #expect(models.installedModelFolder(for: .whisperCppTurbo)?.path == paths.dictationModels.appendingPathComponent(first).path)
        #expect(models.installedModelFolder(for: .whisperMediumEnglish)?.path == paths.dictationModels.appendingPathComponent(second).path)
        #expect(text(at: paths.place(of: .recentItems)) == "made-up newer recent items")
        #expect(text(at: paths.oldPlace(of: .recentItems)) == "made-up older recent items", "never overwritten")
        #expect(paths.inUse(.recentItems) == paths.place(of: .recentItems))
        #expect(text(at: paths.place(of: .applicationUsage)) == "made-up usage", "joins quick_search/")
        #expect(!exists(paths.oldPlace(of: .emojiRecents)), "identical, so removed")
        #expect(text(at: paths.place(of: .emojiRecents)) == "made-up emoji")
    }

    @Test("Dictations at the top of dictation/, where this change's first candidates kept them, move into recordings/")
    func firstCandidatesDictationsMove() throws {
        defer { tearDown() }
        let paths = self.paths
        try FileManager.default.createDirectory(at: paths.keybumpsFolder, withIntermediateDirectories: true)
        defaults.set(Date(), forKey: KeybumpsFolderMove.documentsMovedKey)
        try dictation(at: 1_790_000_000, in: paths.dictation)
        try dictation(at: 1_790_000_000, in: paths.dictation)
        try dictation(at: 1_790_000_100, in: paths.dictationRecordings)
        try write("made-up last dictation", to: paths.place(of: .lastDictation))
        try write("made-up notes", to: paths.dictation.appendingPathComponent("made-up notes/notes.txt"))

        let report = KeybumpsFolderMove(paths: paths, defaults: defaults).run()

        #expect(report.failures == 0)
        #expect(report.conflicts == 0)
        #expect(!report.looksInDocuments)
        #expect(try names(in: paths.dictation) == ["last-dictation.txt", "made-up notes", "recordings"], "only dictations move")
        let history = DictationHistoryService(recordingsDirectoryURL: paths.inUse(.dictationHistory), appVersion: "0.0.0")
        #expect(history.entries.map(\.id) == ["1790000100", "1790000000-2", "1790000000"])
        #expect(KeybumpsFolderMove.isDictationFolderName("1790000000-2"))
        #expect(!KeybumpsFolderMove.isDictationFolderName("models"))
        #expect(!KeybumpsFolderMove.isDictationFolderName("1790000000-"))
        #expect(!KeybumpsFolderMove.isDictationFolderName(".1790000000.keybumps-moving"))
    }

    // MARK: Helpers

    /// Renames that fail as they do across volumes, except the copy fallback's own, which puts a
    /// checked copy in place beside its destination.
    nonisolated static func acrossVolumes(_ source: URL, _ destination: URL) -> Int32 {
        source.lastPathComponent.hasSuffix(".keybumps-moving")
            ? KeybumpsFolderMove.renameExclusively(source, to: destination)
            : EXDEV
    }

    private func documentsMoved(_ defaults: UserDefaults) -> Bool {
        KeybumpsFolderMove.documentsMoved(in: defaults) != nil
    }

    /// A whisper.cpp or WhisperKit model as `DictationModelManager` installs one, with made-up
    /// files, in `modelsRoot`. Its folder, relative to `modelsRoot`.
    private func installedModel(_ engine: DictationTranscriptionEngine, in modelsRoot: URL) throws -> String {
        let relative = "\(engine.rawValue)/made-up-\(engine.rawValue)"
        let folder = modelsRoot.appendingPathComponent(relative, isDirectory: true)
        for file in engine.requiredModelFiles { try write("made-up model", to: folder.appendingPathComponent(file)) }
        try write(folder.path, to: DictationModelManager.locationFile(for: engine, in: modelsRoot))
        return relative
    }

    private func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A finished dictation, with made-up audio, as Dictation History saves one.
    private func dictation(at seconds: TimeInterval, in folder: URL) throws {
        let history = DictationHistoryService(recordingsDirectoryURL: folder, appVersion: "0.0.0")
        let pending = try history.prepareRecording(capturedAt: Date(timeIntervalSince1970: seconds))
        try Data("made-up audio".utf8).write(to: pending.audioURL)
        try history.completeRecording(pending, text: "made-up dictation", language: "en-US", duration: 1)
    }

    /// Where a build before #605 stored the Recordings folder chosen in Settings › ScreenGrabs.
    private static let chosenRecordingsFolderKey = "screengrabs.recordingsFolder"

    private func recordingLibrary(at index: URL, capturesFolder: URL) -> RecordingLibrary {
        RecordingLibrary(
            storageURL: index,
            capturesFolder: capturesFolder,
            posterFrames: RecordingPosterFrames(folder: root.appendingPathComponent("Caches/posters", isDirectory: true)),
            importMemory: RecordingImportMemory(defaults: defaults),
            screenshots: nil
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func text(at url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

/// A file manager that fails one step of the copy fallback.
private final class FaultyFileManager: FileManager {
    enum Fault {
        /// The copy fails after writing part of it.
        case copyCutShort
        /// The copy doesn't match its original.
        case copyDiffers
        /// An original can't be removed. The move's own partial copies still can.
        case originalStays
    }

    let fault: Fault

    init(_ fault: Fault) {
        self.fault = fault
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        if fault == .copyCutShort { throw CocoaError(.fileWriteOutOfSpace) }
    }

    override func contentsEqual(atPath path1: String, andPath path2: String) -> Bool {
        fault == .copyDiffers ? false : super.contentsEqual(atPath: path1, andPath: path2)
    }

    override func removeItem(at url: URL) throws {
        if fault == .originalStays, !url.lastPathComponent.hasSuffix(".keybumps-moving") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

/// Never called: these tests only read what's installed.
@MainActor
private struct NoModelDownloader: DictationModelDownloading {
    func downloadModel(identifier: String, to downloadBase: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw CancellationError()
    }
}
