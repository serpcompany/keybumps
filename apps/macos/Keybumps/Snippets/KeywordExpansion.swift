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
            self = .deleteBackward
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
///   are granted (`shouldListen`, from `SnippetsModule`).
/// - **Never** in Keybumps' own windows (so the snippet editor's Keyword field doesn't expand) or
///   during secure input (password fields).
/// - **Replacing** deletes the keyword and pastes through the shared paste step, kept out of
///   Clipboard History; a sensitive snippet's text comes from the Keychain and is marked concealed.
/// - **The clipboard** is put back after `restoreDelay` unless something else was copied
///   meanwhile; quick expansions in a row put back the clipboard from before the first.
@MainActor
final class KeywordExpansionController {
    private let snippets: SnippetStore
    private let monitor: any KeyTypingMonitoring
    private let replacer: any TextPasting
    private let pasteboard: NSPasteboard
    private let notices: any PaletteNoticePresenting
    private var buffer = KeywordBuffer()
    private var isListening = false
    private var appSwitchObserver: NSObjectProtocol?
    /// The clipboard from before the first expansion still waiting to be put back.
    private var pendingSnapshot: PasteboardSnapshot?
    private var pendingRestore: Task<Void, Never>?

    /// How long to wait before putting the clipboard back, so the app in front has read the paste.
    var restoreDelay: Duration = .milliseconds(500)
    var keybumpsIsFrontmost: () -> Bool = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
    var secureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    /// Called right after the clipboard is put back, so Clipboard History skips that change.
    var didRestorePasteboard: () -> Void = {}

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

    /// Starts or stops listening. Stopping forgets what was typed.
    func update(listening: Bool) {
        guard listening != isListening else { return }
        _ = buffer.handle(.reset, keywords: [])
        if listening {
            isListening = monitor.start()
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
        guard !keybumpsIsFrontmost(), !secureInputEnabled(),
              let snippet = snippets.snippet(withID: match.snippetID) else { return }
        guard let text = snippets.text(for: snippet) else {
            notices.showNotice("Couldn’t read this snippet from the Keychain", isWarning: true)
            return
        }
        let snapshot = pendingSnapshot ?? PasteboardSnapshot(pasteboard)
        do {
            try replacer.replaceTyped(match.length, with: text, concealed: snippet.isSensitive)
        } catch {
            return
        }
        snippets.markUsed(snippet.id)
        scheduleRestore(of: snapshot)
    }

    /// Puts the clipboard back once the paste has been read, unless something else was copied.
    private func scheduleRestore(of snapshot: PasteboardSnapshot) {
        pendingRestore?.cancel()
        pendingSnapshot = snapshot
        let changeCount = pasteboard.changeCount
        let delay = restoreDelay
        pendingRestore = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pendingSnapshot = nil
            self.pendingRestore = nil
            guard self.pasteboard.changeCount == changeCount else { return }
            snapshot.restore(to: self.pasteboard)
            self.didRestorePasteboard()
        }
    }
}
