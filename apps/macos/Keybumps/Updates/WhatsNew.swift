import AppKit
import SwiftUI

/// What's New (#225): after an update installs, a window shows that version's release notes once.
/// Release builds carry their `docs/releases/v<version>.md` as `WhatsNew.md` (`project.yml`,
/// `build-update-release.sh`), so it works offline. Debug builds carry none, and QA candidates carry
/// notes only for `UpdatePreview`. A fresh install shows onboarding instead.
enum WhatsNew {
    static let notesResourceName = "WhatsNew"

    static func shouldShow(currentVersion: String, lastLaunchedVersion: String?, completedOnboarding: Bool, hasNotes: Bool) -> Bool {
        hasNotes && completedOnboarding && lastLaunchedVersion != currentVersion
    }

    /// This build's release notes, if it carries them.
    static func bundledNotes(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: notesResourceName, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The release notes' Markdown as the few blocks they use: a title, section headings, a callout
/// (`>` lines), bullets, and paragraphs. Inline Markdown such as bold stays in each block's text.
struct ReleaseNotesDocument: Equatable {
    enum Block: Equatable {
        case title(String)
        case heading(String)
        case paragraph(String)
        case callout([String])
        case bullet(String)
    }

    let blocks: [Block]

    init(markdown: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var callout: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            if !callout.isEmpty { blocks.append(.callout(callout)) }
            paragraph = []
            callout = []
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { callout.append(text) }
                continue
            }
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("### ") {
                // Notes generated from CHANGELOG.md use ### for Features and Fixes.
                flush()
                blocks.append(.heading(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flush()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush()
                blocks.append(.title(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                if !callout.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        self.blocks = blocks
    }
}

/// Shows What's New, if it should, and records the version that launched.
@MainActor
protocol WhatsNewPresenting: AnyObject {
    func show(_ notes: ReleaseNotesDocument)
}

@MainActor
final class WhatsNewWindowController: WhatsNewPresenting {
    private var window: NSWindow?

    func show(_ notes: ReleaseNotesDocument) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: WhatsNewView(notes: notes) { [weak self] in
            self?.window?.close()
            self?.window = nil
        }))
        window.title = "What's New in Keybumps"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Never shows a window: unit tests and the UI-test composition.
@MainActor
final class InertWhatsNewPresenter: WhatsNewPresenting {
    func show(_ notes: ReleaseNotesDocument) {}
}

struct WhatsNewView: View {
    let notes: ReleaseNotesDocument
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(notes.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Continue", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesDocument.Block) -> some View {
        switch block {
        case .title(let text):
            Text(Self.inline(text)).font(.system(size: 22, weight: .bold))
        case .heading(let text):
            Text(Self.inline(text)).font(.system(size: 15, weight: .semibold)).padding(.top, 8)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
        case .callout(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(Self.inline(line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 13))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
