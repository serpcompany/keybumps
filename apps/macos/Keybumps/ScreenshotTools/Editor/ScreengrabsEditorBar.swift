import SwiftUI

/// The bar along the top of ScreenGrabs' editing windows, the Screenshot Editor and the recording
/// window (#511), so both look and work alike: the window's tools on the left, then on the right
/// anything else the window shows there, undo and redo, and the actions, each with the key that also
/// does it as a keycap after its title. A question the actions answer, such as "Discard this
/// recording?", goes before them. 64 points tall, on the window's background, with a line under it.
struct ScreengrabsEditorBar<Tools: View, Accessories: View>: View {
    /// Undo and redo, for a window with marks to take back; none hides them.
    var history: ScreengrabsEditorHistory?
    var question: String?
    let actions: [ScreengrabsEditorAction]
    private let tools: Tools
    private let accessories: Accessories

    init(
        history: ScreengrabsEditorHistory? = nil,
        question: String? = nil,
        actions: [ScreengrabsEditorAction],
        @ViewBuilder tools: () -> Tools,
        @ViewBuilder accessories: () -> Accessories
    ) {
        self.history = history
        self.question = question
        self.actions = actions
        self.tools = tools()
        self.accessories = accessories()
    }

    var body: some View {
        HStack(spacing: 14) {
            tools

            Spacer(minLength: 8)

            accessories
            if let history {
                Button(action: history.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!history.canUndo)
                    .help("Undo (⌘Z)")
                    .accessibilityLabel("Undo")
                Button(action: history.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!history.canRedo)
                    .help("Redo (⇧⌘Z)")
                    .accessibilityLabel("Redo")
            }
            if let question {
                Text(question)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
            }
            ForEach(actions) { action in
                ScreengrabsEditorActionButton(action: action)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 12)
        .frame(height: ScreengrabsEditorBarMetrics.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension ScreengrabsEditorBar where Accessories == EmptyView {
    init(
        history: ScreengrabsEditorHistory? = nil,
        question: String? = nil,
        actions: [ScreengrabsEditorAction],
        @ViewBuilder tools: () -> Tools
    ) {
        self.init(history: history, question: question, actions: actions, tools: tools) { EmptyView() }
    }
}

enum ScreengrabsEditorBarMetrics {
    static let height: CGFloat = 64
}

/// Undo and redo in the bar.
struct ScreengrabsEditorHistory {
    let canUndo: Bool
    let canRedo: Bool
    let undo: @MainActor () -> Void
    let redo: @MainActor () -> Void
}

/// One of the bar's actions: its title, the key that also does it, and how it looks.
struct ScreengrabsEditorAction: Identifiable {
    /// Return, as macOS shows it beside a menu item: both windows' Save key.
    static let returnSign = "↩"

    enum Style: String, Equatable {
        /// An ordinary button.
        case standard
        /// An ordinary button in red: it deletes, after asking (Discard).
        case destructive
        /// The window's main action, filled with the accent color (Save).
        case prominent
        /// The answer that deletes, filled with red (Discard, after "Discard this recording?").
        case prominentDestructive
    }

    let title: String
    /// The key that also does it, shown as a keycap after the title. VoiceOver reads the title alone.
    var key: String?
    var style: Style = .standard
    /// The window's default button (`.defaultAction`). The window's key monitor still does Return,
    /// so this is how the button is drawn and reported. The Screenshot Editor's Save isn't one: Return
    /// there belongs to its key monitor, which leaves it to the text being typed.
    var isDefault = false
    let help: String
    /// What the UI tests find it by.
    var identifier: String?
    var isEnabled = true
    let perform: @MainActor () -> Void

    var id: String { identifier ?? title }
}

/// An action's button, in the Screenshot Editor's style: a large button with its title, then its
/// key as a keycap.
struct ScreengrabsEditorActionButton: View {
    let action: ScreengrabsEditorAction

    var body: some View {
        styled
            .keyboardShortcut(action.isDefault ? .defaultAction : nil)
            .disabled(!action.isEnabled)
            .help(action.help)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier(ifAny: action.identifier)
    }

    @ViewBuilder private var styled: some View {
        let isDestructive = action.style == .destructive || action.style == .prominentDestructive
        let button = Button(role: isDestructive ? .destructive : nil, action: action.perform) { label }
        switch action.style {
        case .standard, .destructive:
            button
        case .prominent:
            button.buttonStyle(.borderedProminent)
        case .prominentDestructive:
            button.buttonStyle(.borderedProminent).tint(.red)
        }
    }

    @ViewBuilder private var label: some View {
        if let key = action.key {
            ScreengrabsEditorActionLabel(title: action.title, key: key)
        } else if action.style == .destructive {
            // A destructive role alone doesn't color an ordinary macOS button's title.
            Text(action.title).foregroundStyle(.red)
        } else {
            Text(action.title)
        }
    }
}

/// An action's title with the key that also does it. The keycap takes the button's own text color,
/// so it stays readable on the prominent Save button and in inactive windows.
struct ScreengrabsEditorActionLabel: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.tertiary, lineWidth: 0.75))
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

/// The tools on the bar's left, in one rounded well.
struct ScreengrabsEditorTools<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(3)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// A tool's button: its icon over its name, with its number in the corner, filled with the accent
/// color while it's picked.
struct ScreengrabsEditorToolButton: View {
    let title: String
    let systemImage: String
    /// Its number, the first of its keys, shown in the corner.
    let number: String
    /// Its letter, its other key.
    let key: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 58, height: 44)
            .overlay(alignment: .topTrailing) {
                Text(number)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 13, height: 13)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isSelected ? Color.white.opacity(0.5) : Color.secondary.opacity(0.5), lineWidth: 0.75)
                    )
                    .padding(3)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(number) or \(key.uppercased()))")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    @ViewBuilder func accessibilityIdentifier(ifAny identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
