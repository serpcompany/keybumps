import AppKit
import SwiftUI

/// Text entry that keeps exactly what's typed: no smart quotes or dashes, no text replacement,
/// no autocorrection or completion, and no link or data detection. Snippets hold commands and
/// secrets, where `"` becoming `“` or `--` becoming `—` breaks them.
enum PlainTextInput {
    static func configure(_ textView: NSTextView) {
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
    }

    /// A text view's settings that `configure` changes, so a shared field editor can be put back.
    struct Settings: Equatable {
        let quotes, dashes, replacement, spellingCorrection, completion, links, data, spellChecking, grammar, smartInsertDelete: Bool

        init(of textView: NSTextView) {
            quotes = textView.isAutomaticQuoteSubstitutionEnabled
            dashes = textView.isAutomaticDashSubstitutionEnabled
            replacement = textView.isAutomaticTextReplacementEnabled
            spellingCorrection = textView.isAutomaticSpellingCorrectionEnabled
            completion = textView.isAutomaticTextCompletionEnabled
            links = textView.isAutomaticLinkDetectionEnabled
            data = textView.isAutomaticDataDetectionEnabled
            spellChecking = textView.isContinuousSpellCheckingEnabled
            grammar = textView.isGrammarCheckingEnabled
            smartInsertDelete = textView.smartInsertDeleteEnabled
        }

        func restore(to textView: NSTextView) {
            textView.isAutomaticQuoteSubstitutionEnabled = quotes
            textView.isAutomaticDashSubstitutionEnabled = dashes
            textView.isAutomaticTextReplacementEnabled = replacement
            textView.isAutomaticSpellingCorrectionEnabled = spellingCorrection
            textView.isAutomaticTextCompletionEnabled = completion
            textView.isAutomaticLinkDetectionEnabled = links
            textView.isAutomaticDataDetectionEnabled = data
            textView.isContinuousSpellCheckingEnabled = spellChecking
            textView.isGrammarCheckingEnabled = grammar
            textView.smartInsertDeleteEnabled = smartInsertDelete
        }
    }
}

/// A multi-line plain-text editor (`PlainTextInput`), transparent so its container draws the field.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let identifier: String

    static func makeTextView() -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        PlainTextInput.configure(textView)
        return textView
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = Self.makeTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityIdentifier(identifier)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// A single-line plain-text field (`PlainTextInput`), borderless so its container draws the field.
struct PlainTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let accessibilityLabel: String
    let identifier: String

    func makeNSView(context: Context) -> SubstitutionFreeTextField {
        let field = SubstitutionFreeTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.stringValue = text
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: SubstitutionFreeTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// An `NSTextField` whose field editor, which the window shares with its other fields, has
/// substitution turned off while it edits and put back as it was afterwards.
final class SubstitutionFreeTextField: NSTextField {
    private var editorSettings: PlainTextInput.Settings?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            if editorSettings == nil { editorSettings = PlainTextInput.Settings(of: editor) }
            PlainTextInput.configure(editor)
        }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        if let editor = notification.object as? NSTextView, let editorSettings {
            editorSettings.restore(to: editor)
            self.editorSettings = nil
        }
        super.textDidEndEditing(notification)
    }
}
