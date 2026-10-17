import Foundation
import Testing
@testable import Keybumps

/// ScreenGrabs' Screenshots and Recordings folders (#504, ADR 0010 decision 5): with no choice, each
/// follows the folder macOS saves screenshots to, else the Desktop; a stored choice wins and outlives
/// a relaunch; one that's gone or can't be written to falls back without losing the file, and is
/// used again once it's back; and Settings says which. macOS's screenshot location is a value the
/// test sets, every folder is in a temporary folder, and preferences are `InMemoryDefaults`, so no
/// test reads `com.apple.screencapture`, `UserDefaults.standard`, or a real user folder.
@MainActor
@Suite("ScreenGrabs: the Screenshots and Recordings folders")
struct ScreengrabFoldersTests {
    /// macOS's screenshot location as the test sets it, or nil for none.
    final class Location {
        var value: String?
    }

    let root = TemporaryCapturesFolder()
    let location = Location()
    var home: URL { root.url.appendingPathComponent("Home", isDirectory: true) }
    var desktop: URL { home.appendingPathComponent("Desktop", isDirectory: true) }

    /// A resolver reading `location`, in the test's own home folder.
    var resolver: ScreenshotLocationResolver {
        let location = location
        return ScreenshotLocationResolver(
            preferredLocation: { location.value },
            homeDirectory: home,
            isDirectory: { url in
                var isFolder: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
            }
        )
    }

    func makePreferences(_ defaults: UserDefaults = InMemoryDefaults()) -> AppPreferences {
        AppPreferences(defaults: defaults, screenshotLocation: resolver)
    }

    /// A folder the test makes in its temporary folder.
    func folder(_ path: String) throws -> URL {
        let url = root.url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("With no choice, each folder is where macOS saves screenshots, else the Desktop", arguments: ScreengrabFolders.Kind.allCases)
    func defaultFollowsTheScreenshotLocation(kind: ScreengrabFolders.Kind) throws {
        defer { root.remove() }
        let preferences = makePreferences()
        #expect(preferences.screengrabFolders.folder(for: kind) == desktop, "no location: the Desktop")

        let shots = try folder("Shots")
        location.value = shots.path
        #expect(preferences.screengrabFolders.folder(for: kind) == shots.standardizedFileURL)

        location.value = root.url.appendingPathComponent("Gone").path
        #expect(preferences.screengrabFolders.folder(for: kind) == desktop, "a location that isn't a folder: the Desktop")

        let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        location.value = "~/Pictures"
        #expect(preferences.screengrabFolders.folder(for: kind) == pictures.standardizedFileURL)
    }

    @Test("A folder chosen in Settings wins for its kind only, outlives a relaunch, and clearing it follows macOS again", arguments: ScreengrabFolders.Kind.allCases)
    func storedChoiceWins(kind: ScreengrabFolders.Kind) throws {
        defer { root.remove() }
        let defaults = InMemoryDefaults()
        let shots = try folder("Shots")
        location.value = shots.path
        let chosen = try folder("Chosen")
        let preferences = makePreferences(defaults)
        let other = ScreengrabFolders.Kind.allCases.first { $0 != kind }!

        preferences.chooseScreengrabFolder(chosen, for: kind)
        #expect(preferences.screengrabFolders.folder(for: kind) == chosen.standardizedFileURL)
        #expect(preferences.screengrabFolders.folder(for: other) == shots.standardizedFileURL, "each kind on its own")
        #expect(defaults.string(forKey: "screengrabs.\(kind.rawValue)Folder") == chosen.standardizedFileURL.path)

        let relaunched = makePreferences(defaults)
        #expect(relaunched.screengrabFolders.folder(for: kind) == chosen.standardizedFileURL)
        #expect(relaunched.chosenScreengrabFolders == [kind: chosen.standardizedFileURL])

        relaunched.chooseScreengrabFolder(nil, for: kind)
        #expect(relaunched.screengrabFolders.folder(for: kind) == shots.standardizedFileURL)
        #expect(defaults.object(forKey: "screengrabs.\(kind.rawValue)Folder") == nil)
    }

    @Test("A stored path that isn't absolute is ignored")
    func relativePathIgnored() {
        defer { root.remove() }
        let defaults = InMemoryDefaults()
        defaults.set("Pictures/Shots", forKey: "screengrabs.screenshotsFolder")
        #expect(makePreferences(defaults).chosenScreengrabFolders.isEmpty)
    }

    @Test("A chosen folder that's gone, can't be written to, or isn't a folder falls back to the default and stays chosen, and is used again once it's back", arguments: ScreengrabFolders.Kind.allCases)
    func unusableChoiceFallsBack(kind: ScreengrabFolders.Kind) throws {
        defer { root.remove() }
        let chosen = try folder("Chosen")
        let preferences = makePreferences()
        preferences.chooseScreengrabFolder(chosen, for: kind)
        #expect(!preferences.screengrabFolders.choiceIsUnavailable(for: kind))

        try FileManager.default.removeItem(at: chosen)
        #expect(preferences.screengrabFolders.folder(for: kind) == desktop, "gone")
        #expect(preferences.screengrabFolders.choiceIsUnavailable(for: kind))
        #expect(preferences.chosenScreengrabFolders[kind] == chosen.standardizedFileURL, "still chosen")

        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        #expect(preferences.screengrabFolders.folder(for: kind) == chosen.standardizedFileURL, "back")

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: chosen.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chosen.path) }
        #expect(preferences.screengrabFolders.folder(for: kind) == desktop, "can't be written to")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chosen.path)

        let file = root.url.appendingPathComponent("NotAFolder")
        try Data("file".utf8).write(to: file)
        preferences.chooseScreengrabFolder(file, for: kind)
        #expect(preferences.screengrabFolders.folder(for: kind) == desktop, "a file")
    }

    @Test("Changing macOS's screenshot location moves a folder's default only while no Keybumps choice is stored", arguments: ScreengrabFolders.Kind.allCases)
    func locationMovesOnlyTheDefault(kind: ScreengrabFolders.Kind) throws {
        defer { root.remove() }
        let first = try folder("First")
        let second = try folder("Second")
        let chosen = try folder("Chosen")
        let preferences = makePreferences()

        location.value = first.path
        #expect(preferences.screengrabFolders.folder(for: kind) == first.standardizedFileURL)
        location.value = second.path
        #expect(preferences.screengrabFolders.folder(for: kind) == second.standardizedFileURL, "follows macOS")

        preferences.chooseScreengrabFolder(chosen, for: kind)
        location.value = first.path
        #expect(preferences.screengrabFolders.folder(for: kind) == chosen.standardizedFileURL, "the choice stays")
        #expect(preferences.screengrabFolders.defaultFolder == first.standardizedFileURL)
    }

    @Test("A hotkey's screenshot goes in the chosen Screenshots folder, or in the default when that folder is gone, so it isn't lost")
    func screenshotsLandInTheFolder() async throws {
        defer { root.remove() }
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let chosen = try folder("Chosen")
        let preferences = makePreferences()
        preferences.chooseScreengrabFolder(chosen, for: .screenshots)
        // As `AppModel` makes it: the folder is read as each hotkey captures.
        let capturer = ScreenshotCapturer(
            runner: WritingCaptureRunner(),
            folder: { preferences.screengrabFolders.folder(for: .screenshots) },
            displayCount: { 1 }
        )

        let saved = await capture(with: capturer)
        #expect(saved.map { $0.deletingLastPathComponent().standardizedFileURL } == [chosen.standardizedFileURL])

        try FileManager.default.removeItem(at: chosen)
        let fellBack = await capture(with: capturer)
        #expect(fellBack.map { $0.deletingLastPathComponent().standardizedFileURL } == [desktop.standardizedFileURL])
        #expect(!FileManager.default.fileExists(atPath: chosen.path), "the gone folder isn't made again")
    }

    @Test("A recording goes in the chosen Recordings folder, with the default to fall back to, or in the default alone")
    func recordingsFolderAndFallback() throws {
        defer { root.remove() }
        let shots = try folder("Shots")
        location.value = shots.path
        let chosen = try folder("Chosen")
        let preferences = makePreferences()
        #expect(preferences.screencast.capturesFolder == shots.standardizedFileURL)
        #expect(preferences.screencast.fallbackFolder == nil)

        preferences.chooseScreengrabFolder(chosen, for: .recordings)
        #expect(preferences.screencast.capturesFolder == chosen.standardizedFileURL)
        #expect(preferences.screencast.fallbackFolder == shots.standardizedFileURL)

        try FileManager.default.removeItem(at: chosen)
        #expect(preferences.screencast.capturesFolder == shots.standardizedFileURL)
        #expect(preferences.screencast.fallbackFolder == nil)

        preferences.chooseScreengrabFolder(shots, for: .recordings)
        #expect(preferences.screencast.fallbackFolder == nil, "the default chosen has nothing else to fall back to")
    }

    @Test("Settings › ScreenGrabs says where each kind saves: the default, as where macOS saves screenshots; a choice; or the default until a choice is back")
    func settingsSubtitles() throws {
        defer { root.remove() }
        let chosen = try folder("Chosen")
        let preferences = makePreferences()
        let path = ScreengrabFolderRow.displayPath(desktop)
        #expect(ScreengrabFolderRow.subtitle(.recordings, in: preferences.screengrabFolders) == "\(path), where macOS saves screenshots")

        preferences.chooseScreengrabFolder(chosen, for: .recordings)
        #expect(ScreengrabFolderRow.subtitle(.recordings, in: preferences.screengrabFolders) == ScreengrabFolderRow.displayPath(chosen))

        try FileManager.default.removeItem(at: chosen)
        #expect(
            ScreengrabFolderRow.subtitle(.recordings, in: preferences.screengrabFolders)
                == "Saving to \(path) until \(ScreengrabFolderRow.displayPath(chosen.standardizedFileURL)) is available"
        )
        #expect(ScreengrabFolderRow.title(.screenshots) == "Screenshots folder")
        #expect(ScreengrabFolderRow.title(.recordings) == "Recordings folder")
    }

    @Test("Under the unit-test host, each default is in this run's folder")
    func defaultsStayInTheRunsFolder() {
        let folders = AppPreferences(defaults: InMemoryDefaults()).screengrabFolders
        let run = UnitTestHost.dataDirectory.standardizedFileURL.path
        for kind in ScreengrabFolders.Kind.allCases {
            #expect(folders.folder(for: kind).standardizedFileURL.path.hasPrefix(run + "/"), "\(kind)")
        }
    }

    private func capture(with capturer: ScreenshotCapturer) async -> [URL] {
        await withCheckedContinuation { continuation in
            capturer.capture(.screens) { continuation.resume(returning: $0) }
        }
    }
}

/// Writes each file `screencapture` would, where it's told, and exits at once.
private final class WritingCaptureRunner: ScreenshotCaptureRunning {
    func run(arguments: [String], completion: @escaping @MainActor () -> Void) {
        for file in arguments.filter({ $0.hasSuffix(".png") }) {
            FileManager.default.createFile(atPath: file, contents: Data("png".utf8))
        }
        MainActor.assumeIsolated { completion() }
    }
}
