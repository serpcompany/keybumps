import AppKit
import Carbon.HIToolbox

/// What one key press means to keyword expansion.
enum TypedKey: Equatable {
    /// Text the key typed, with no ⌘ or ⌃ held.
    case characters(String)
    /// Delete, which takes back the last character typed.
    case deleteBackward
    /// Anything that ends what was being typed: Return, Tab, Escape, an arrow or other key that
    /// moves the caret, a ⌘ or ⌃ shortcut, a dead key, a click, switching apps, or a key Keybumps
    /// posted itself.
    case reset

    init(keyCode: Int, characters: String, flags: CGEventFlags, isSynthetic: Bool) {
        if isSynthetic || !flags.isDisjoint(with: [.maskCommand, .maskControl]) {
            self = .reset
        } else if keyCode == kVK_Delete {
            // ⌥⌫ deletes a word, so what's on screen no longer matches.
            self = flags.contains(.maskAlternate) ? .reset : .deleteBackward
        } else if !characters.isEmpty, characters.unicodeScalars.allSatisfy(Self.isTyped) {
            self = .characters(characters)
        } else {
            self = .reset
        }
    }

    /// Printable text: not a control character, and not one of the private-use characters AppKit
    /// reports for arrows, function keys, and Forward Delete.
    private static func isTyped(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }
}

enum KeywordExpansion {
    /// A keyword and the snippet it expands to.
    struct Entry: Equatable {
        let keyword: String
        let snippetID: Snippet.ID
    }

    /// The keywords to listen for, longest first, so `;ship` wins over `ship` when both were typed.
    static func entries(for snippets: [Snippet]) -> [Entry] {
        snippets
            .compactMap { snippet in snippet.keyword.map { Entry(keyword: $0, snippetID: snippet.id) } }
            .sorted { $0.keyword.count > $1.keyword.count }
    }
}

/// The last few characters typed, never more than the longest keyword, and only in memory: nothing
/// here is logged or saved. A keyword matches exactly, case included, the moment it's complete,
/// even in the middle of a word, as in Alfred.
struct KeywordBuffer {
    struct Match: Equatable {
        let snippetID: Snippet.ID
        /// How many characters to delete: the keyword's.
        let length: Int
    }

    private(set) var typed = ""

    /// Feeds one key. Returns the keyword it completes, if any, and starts over after a match.
    mutating func handle(_ key: TypedKey, keywords: [KeywordExpansion.Entry]) -> Match? {
        switch key {
        case .reset:
            typed = ""
            return nil
        case .deleteBackward:
            if !typed.isEmpty { typed.removeLast() }
            return nil
        case .characters(let characters):
            let longest = keywords.first?.keyword.count ?? 0
            typed = String((typed + characters).suffix(longest))
            guard let entry = keywords.first(where: { typed.hasSuffix($0.keyword) }) else { return nil }
            typed = ""
            return Match(snippetID: entry.snippetID, length: entry.keyword.count)
        }
    }
}

/// Keyword auto-expansion (ADR 0004): while it listens, typing a snippet's keyword in another app
/// replaces it with the snippet's text, then puts the clipboard back as it was.
/// - **Listening** goes through `KeyTypingMonitoring`, a listen-only tap that can't delay typing.
///   It runs only while Snippets and Settings' switch are on and Input Monitoring and Accessibility
///   are granted (`shouldListen`, from `SnippetsModule`). If macOS refuses the tap anyway (it can
///   until Keybumps relaunches), `isListening` stays false and Settings says so.
/// - **Never** in Keybumps' own windows, the Command Palette included (`isTypingInKeybumps`), or
///   during secure input (password fields).
/// - **Replacing** reads the text first (from the Keychain for a sensitive snippet), deletes the
///   keyword at once, then pastes through the shared paste step, kept out of Clipboard History and
///   marked concealed for a sensitive snippet.
/// - **The clipboard** is put back after `restoreDelay` unless something else was copied
///   meanwhile; quick expansions in a row put back the clipboard from before the first, unless
///   something was copied between them.
@MainActor
@Observable
final class KeywordExpansionController {
    private(set) var isListening = false

    @ObservationIgnored private let snippets: SnippetStore
    @ObservationIgnored private let monitor: any KeyTypingMonitoring
    @ObservationIgnored private let replacer: any TextPasting
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let notices: any PaletteNoticePresenting
    @ObservationIgnored private var buffer = KeywordBuffer()
    @ObservationIgnored private var appSwitchObserver: NSObjectProtocol?
    /// The clipboard from before the first of a run of expansions, still waiting to be put back,
    /// and the clipboard's change count right after the last paste.
    @ObservationIgnored private var pendingSnapshot: PasteboardSnapshot?
    @ObservationIgnored private var pendingChangeCount: Int?
    @ObservationIgnored private var pendingRestore: Task<Void, Never>?

    /// How long to wait before putting the clipboard back, so the app in front has read the paste.
    @ObservationIgnored var restoreDelay: Duration = .milliseconds(500)
    @ObservationIgnored var typingIsInKeybumps: () -> Bool = {
        KeywordExpansionController.isTypingInKeybumps(
            isActive: NSApp.isActive,
            hasKeyWindow: NSApp.keyWindow != nil,
            frontmostIsKeybumps: NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
        )
    }
    @ObservationIgnored var secureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    /// Called right after the clipboard is put back, so Clipboard History skips that change.
    @ObservationIgnored var didRestorePasteboard: () -> Void = {}

    init(
        snippets: SnippetStore,
        monitor: any KeyTypingMonitoring,
        replacer: any TextPasting,
        pasteboard: NSPasteboard = .keybumps,
        notices: (any PaletteNoticePresenting)? = nil
    ) {
        self.snippets = snippets
        self.monitor = monitor
        self.replacer = replacer
        self.pasteboard = pasteboard
        self.notices = notices ?? PaletteHUD.shared
        // The tap delivers on the main run loop.
        monitor.onKey = { [weak self] key in MainActor.assumeIsolated { self?.handle(key) } }
    }

    static func shouldListen(snippetsOn: Bool, switchOn: Bool, inputMonitoring: Bool, accessibility: Bool) -> Bool {
        snippetsOn && switchOn && inputMonitoring && accessibility
    }

    /// Whether typing goes to Keybumps: it's the active app, or one of its windows is key. The
    /// Command Palette is a key window that never makes Keybumps active, so the app under it
    /// stays frontmost.
    nonisolated static func isTypingInKeybumps(isActive: Bool, hasKeyWindow: Bool, frontmostIsKeybumps: Bool) -> Bool {
        isActive || hasKeyWindow || frontmostIsKeybumps
    }

    /// Starts or stops listening. Stopping forgets what was typed. While it should listen but macOS
    /// refused the tap, each update tries again.
    func update(listening: Bool) {
        guard listening != isListening else { return }
        _ = buffer.handle(.reset, keywords: [])
        if listening {
            guard monitor.start() else { return }
            isListening = true
            appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.reset) }
            }
        } else {
            monitor.stop()
            isListening = false
            if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
            appSwitchObserver = nil
        }
    }

    func handle(_ key: TypedKey) {
        guard let match = buffer.handle(key, keywords: KeywordExpansion.entries(for: snippets.snippets)) else { return }
        guard !typingIsInKeybumps(), !secureInputEnabled(),
              let snippet = snippets.snippet(withID: match.snippetID) else { return }
        guard let text = snippets.text(for: snippet) else {
            notices.showNotice("Couldn’t read this snippet from the Keychain", isWarning: true)
            return
        }
        // Delete the keyword before anything slower, such as reading the clipboard, so more typing
        // can't land in between.
        do {
            try replacer.deleteTyped(match.length)
        } catch {
            return
        }
        let snapshot = pendingChangeCount == pasteboard.changeCount ? pendingSnapshot : nil
        let previous = snapshot ?? PasteboardSnapshot(pasteboard)
        do {
            try replacer.paste(text, concealed: snippet.isSensitive)
        } catch {
            return
        }
        snippets.markUsed(snippet.id)
        scheduleRestore(of: previous)
    }

    /// Puts the clipboard back once the paste has been read, unless something else was copied.
    private func scheduleRestore(of snapshot: PasteboardSnapshot) {
        pendingRestore?.cancel()
        pendingSnapshot = snapshot
        let changeCount = pasteboard.changeCount
        pendingChangeCount = changeCount
        let delay = restoreDelay
        pendingRestore = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pendingSnapshot = nil
            self.pendingChangeCount = nil
            self.pendingRestore = nil
            guard self.pasteboard.changeCount == changeCount else { return }
            snapshot.restore(to: self.pasteboard)
            self.didRestorePasteboard()
        }
    }
}
