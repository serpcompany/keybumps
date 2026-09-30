import SwiftUI

/// The Snippets page: its command, then every snippet in a searchable table with + and − and
/// Edit…, which open the editor sheet. Everything here is saved on this Mac only.
struct SnippetsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: Snippet.ID?
    @State private var pendingDeletion: Snippet?
    @State private var errorMessage: String?
    @State private var confirmsStartOver = false

    var body: some View {
        @Bindable var store = model.snippets
        let results = SnippetSearch.settingsResults(store.snippets, query: query)
        SettingsPage {
            CapabilityControl(capability: .snippets, shortcuts: [.snippets])
            // Accessibility is optional: without it, ⌘Return copies instead of pasting.
            if model.preferences.enabledCapabilities.contains(.snippets), !model.permissions.accessibilityGranted {
                SettingsGroup("Paste") {
                    LabeledContent {
                        Button("Allow…") { Task { await model.recoverPermission(.accessibility) } }
                            .disabled(model.permissions.activeRequest != nil)
                            .accessibilityLabel("Allow Accessibility so ⌘Return pastes")
                    } label: {
                        SettingsRowLabel(
                            title: "⌘Return pastes with Accessibility",
                            subtitle: "Without it, ⌘Return in the Snippets tab copies the snippet instead of pasting it into the app you’re using. Copying needs no permission."
                        )
                    }
                }
            }
            if store.libraryState == .readOnly {
                SettingsGroup("Saved snippets can’t be read") {
                    SettingsNote(
                        "Keybumps can’t read snippets.json in its Application Support folder, so it won’t save any changes until it can. Check the file’s permissions and Try Again, or set the file aside and start a new library.",
                        tint: .orange
                    )
                    HStack(spacing: 8) {
                        Button("Try Again") { store.reload() }
                            .accessibilityIdentifier("snippets.reload")
                        Button("Start Over…") { confirmsStartOver = true }
                            .accessibilityIdentifier("snippets.startOver")
                    }
                }
            }
            SettingsGroup("All Snippets", subtitle: "Kept on this Mac only. A keyword is a short word to find a snippet by.") {
                HStack(spacing: 12) {
                    SettingsSearchField(text: $query, prompt: "Search snippets…", identifier: "snippets.search")
                        .frame(maxWidth: 300)
                    Spacer()
                    Text(SnippetPresentation.count(store.snippets.count))
                        .font(.system(size: SettingsTheme.subtitleSize))
                        .foregroundStyle(.secondary)
                }
                if store.snippets.isEmpty {
                    SettingsRowLabel(
                        title: "No snippets yet",
                        subtitle: "Click + to save text you reuse. In the Command Palette’s Snippets tab, Return copies it and ⌘Return pastes it."
                    )
                } else if results.isEmpty {
                    SettingsNote("No matching snippets")
                } else {
                    table(results)
                }
                HStack(spacing: 6) {
                    SettingsIconButton(systemImage: "plus", help: "New Snippet") {
                        store.editorRequest = .new
                    }
                    .accessibilityIdentifier("snippets.add")
                    SettingsIconButton(systemImage: "minus", help: "Delete Snippet") {
                        pendingDeletion = selectedSnippet
                    }
                    .disabled(selectedSnippet == nil)
                    .accessibilityIdentifier("snippets.remove")
                    Spacer()
                    Button("Edit…") {
                        if let selection { store.editorRequest = .edit(selection) }
                    }
                    .disabled(selectedSnippet == nil)
                    .accessibilityIdentifier("snippets.edit")
                }
            }
            if let errorMessage {
                SettingsNote(errorMessage, tint: .orange)
            }
            if case .recovered(let copyName) = store.libraryState {
                SettingsNote("Some saved snippets couldn’t be read. Keybumps kept a copy of the file as \(copyName) in its Application Support folder.", tint: .orange)
            }
        }
        .navigationTitle("Snippets")
        .alert("Start a new snippet library?", isPresented: $confirmsStartOver) {
            Button("Start Over", role: .destructive) {
                do {
                    try store.startOver()
                    errorMessage = nil
                } catch {
                    errorMessage = SnippetStoreError.storage.message
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keybumps renames snippets.json to keep it, unread, beside the new library in its Application Support folder.")
        }
        .sheet(item: $store.editorRequest) { request in
            SnippetEditorSheet(request: request)
                .environment(model)
        }
        .alert(
            "Delete this snippet?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { snippet in
            Button("Delete", role: .destructive) { delete(snippet) }
            Button("Cancel", role: .cancel) {}
        } message: { snippet in
            Text("“\(snippet.name)” will be removed from this Mac.")
        }
    }

    private var selectedSnippet: Snippet? {
        selection.flatMap(model.snippets.snippet(withID:))
    }

    private func table(_ snippets: [Snippet]) -> some View {
        Table(snippets, selection: $selection) {
            TableColumn("Name") { snippet in
                HStack(spacing: 5) {
                    Text(snippet.name)
                        .lineLimit(1)
                    if snippet.isSensitive {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .help("Sensitive: the text is kept in the Keychain")
                            .accessibilityLabel("Sensitive")
                    }
                }
            }
            .width(min: 140, ideal: 200, max: 260)
            TableColumn("Keyword") { snippet in
                if let keyword = snippet.keyword {
                    SnippetKeywordChip(keyword: keyword)
                }
            }
            .width(min: 80, ideal: 110, max: 170)
            TableColumn("Snippet") { snippet in
                Text(SnippetPresentation.preview(of: snippet))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Snippet.ID.self) { ids in
            if let id = ids.first {
                Button("Edit…") { model.snippets.editorRequest = .edit(id) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDeletion = model.snippets.snippet(withID: id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.snippets.editorRequest = .edit(id) }
        }
        .onDeleteCommand { pendingDeletion = selectedSnippet }
        .frame(height: Self.tableHeight(rows: snippets.count))
        .accessibilityIdentifier("snippets.list")
    }

    /// Tall enough for a few rows, growing with the list up to twelve before it scrolls. A row with
    /// a keyword chip is about 30 points tall, and the header about 30.
    static func tableHeight(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 4), 12)) * 31 + 34
    }

    private func delete(_ snippet: Snippet) {
        do {
            try model.snippets.delete(snippet.id)
            if selection == snippet.id { selection = nil }
            errorMessage = nil
        } catch let error as SnippetStoreError {
            errorMessage = error.message
        } catch {
            errorMessage = SnippetStoreError.storage.message
        }
    }
}

/// The editor sheet for a new or existing snippet: Name, Keyword, the text, and Sensitive. It's the
/// only place snippets are created or changed; the palette's New Snippet and Edit open it through
/// `SnippetStore.editorRequest`. A sensitive snippet's text is masked until Show and read from the
/// Keychain only then; saving without showing it, or without changing it, keeps the saved text.
/// The Snippet and Keyword fields are `PlainTextInput`, so text is saved exactly as typed.
struct SnippetEditorSheet: View {
    @Environment(AppModel.self) private var model
    let request: SnippetEditorRequest
    @State private var draft = SnippetDraft()
    @State private var didLoad = false
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false
    /// Whether the text shows while Sensitive is on. It starts hidden.
    @State private var showsSensitiveText = false
    /// A sensitive snippet's saved text stays in the Keychain, unread, until Show (or turning
    /// Sensitive off) needs it. Saving without it keeps the saved text.
    @State private var keepsSavedText = false
    /// The saved text Show read, to tell whether the user changed it.
    @State private var revealedText: String?

    private var editingID: Snippet.ID? {
        if case .edit(let id) = request { return id }
        return nil
    }

    var body: some View {
        let problem = model.snippets.problem(with: draft, editing: editingID, keepsText: keepsSavedText)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SettingsIconTile(systemImage: SnippetPaletteResults.symbol, tint: .green, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editingID == nil ? "New Snippet" : "Edit Snippet")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Saved on this Mac only.")
                        .font(.system(size: SettingsTheme.subtitleSize))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                row("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("Support reply"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .accessibilityIdentifier("snippets.editor.name")
                }
                divider
                row("Keyword") {
                    VStack(alignment: .leading, spacing: 5) {
                        SnippetKeywordField(keyword: $draft.keyword)
                        if problem == .keywordHasSpaces || problem == .keywordInUse, let problem {
                            SettingsNote(problem.message, tint: .orange)
                        } else {
                            SettingsNote("A short word to find this snippet.")
                        }
                    }
                }
                divider
                row("Snippet", alignment: .top) {
                    VStack(alignment: .trailing, spacing: 6) {
                        if draft.isSensitive, !showsSensitiveText {
                            maskedText
                        } else {
                            // Plain text with no smart quotes, dashes, or replacements, so commands
                            // and secrets are saved exactly as typed.
                            PlainTextEditor(text: $draft.text, accessibilityLabel: "Snippet", identifier: "snippets.editor.text")
                                .padding(6)
                                .frame(height: 180)
                                .background(SettingsTheme.field, in: RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.1))
                                )
                        }
                        if draft.isSensitive {
                            Button(showsSensitiveText ? "Hide" : "Show") { toggleSensitiveText() }
                                .accessibilityIdentifier("snippets.editor.show")
                        }
                    }
                }
                divider
                Toggle(isOn: Binding(get: { draft.isSensitive }, set: setSensitive)) {
                    SettingsRowLabel(
                        title: "Sensitive",
                        subtitle: "Hides the text in the Command Palette and Settings, and leaves it out of search. The text is kept in the Keychain."
                    )
                }
                .toggleStyle(SettingsSwitchToggleStyle())
                .padding(.vertical, 10)
                .accessibilityIdentifier("snippets.editor.sensitive")
            }
            .padding(.horizontal, SettingsTheme.rowInset + 4)
            .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
            if let errorMessage {
                SettingsNote(errorMessage, tint: .orange)
            }
            HStack(spacing: 8) {
                if editingID != nil {
                    Button("Delete…", role: .destructive) { confirmsDeletion = true }
                        .accessibilityIdentifier("snippets.editor.delete")
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(SettingsButtonStyle(isProminent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                    .accessibilityIdentifier("snippets.editor.save")
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .padding(20)
        .frame(width: 540)
        .background(SettingsTheme.pageBackground)
        .font(.system(size: SettingsTheme.titleSize))
        .onAppear(perform: load)
        .alert("Delete this snippet?", isPresented: $confirmsDeletion) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(draft.trimmedName)” will be removed from this Mac.")
        }
    }

    private var divider: some View {
        SettingsTheme.separator.frame(height: 1)
    }

    /// The text while it's hidden: the mask, in the field's place.
    private var maskedText: some View {
        Text(SnippetPresentation.maskedText)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(SettingsTheme.field, in: RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1))
            )
            .accessibilityLabel("Snippet, hidden")
            .accessibilityIdentifier("snippets.editor.masked")
    }

    private func toggleSensitiveText() {
        if !showsSensitiveText, !loadSavedText() { return }
        showsSensitiveText.toggle()
    }

    /// Turning Sensitive on hides the text; turning it off shows it, since it will be saved in the file.
    private func setSensitive(_ isSensitive: Bool) {
        if !isSensitive, !loadSavedText() { return }
        draft.isSensitive = isSensitive
        showsSensitiveText = !isSensitive
    }

    /// Reads a sensitive snippet's saved text from the Keychain, once, when it's needed.
    private func loadSavedText() -> Bool {
        guard keepsSavedText else { return true }
        guard let editingID, let snippet = model.snippets.snippet(withID: editingID),
              let text = model.snippets.text(for: snippet) else {
            errorMessage = "Keybumps couldn’t read this snippet’s text from the Keychain."
            return false
        }
        draft.text = text
        revealedText = text
        keepsSavedText = false
        return true
    }

    /// Whether saving leaves a sensitive snippet's saved text alone: it was never shown, or it was
    /// shown but not changed. Then the Keychain isn't touched.
    private var savesWithoutText: Bool {
        guard let editingID, model.snippets.snippet(withID: editingID)?.isSensitive == true, draft.isSensitive else {
            return false
        }
        return keepsSavedText || draft.text == revealedText
    }

    private func row(
        _ label: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .frame(width: 70, alignment: .leading)
                .padding(.top, alignment == .top ? 6 : 0)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let editingID else { return }
        if let existing = model.snippets.draft(for: editingID) {
            draft = existing
            // Its text stays in the Keychain until Show.
            keepsSavedText = existing.isSensitive
        } else {
            errorMessage = SnippetStoreError.notFound.message
        }
    }

    private func save() {
        do {
            if let editingID {
                try model.snippets.update(editingID, with: draft, keepsText: savesWithoutText)
            } else {
                try model.snippets.add(draft)
            }
            close()
        } catch let error as SnippetStoreError {
            errorMessage = error.message
        } catch {
            errorMessage = SnippetStoreError.storage.message
        }
    }

    private func delete() {
        guard let editingID else { return }
        do {
            try model.snippets.delete(editingID)
            close()
        } catch let error as SnippetStoreError {
            errorMessage = error.message
        } catch {
            errorMessage = SnippetStoreError.storage.message
        }
    }

    private func close() {
        model.snippets.editorRequest = nil
    }
}

/// The editor's keyword field, drawn as the keyword chip it becomes: monospaced, on the chip's
/// subtle fill with a hairline border.
private struct SnippetKeywordField: View {
    @Binding var keyword: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
        PlainTextField(
            text: $keyword,
            placeholder: ";ship",
            font: .monospacedSystemFont(ofSize: 13, weight: .medium),
            accessibilityLabel: "Keyword",
            identifier: "snippets.editor.keyword"
        )
        .padding(.horizontal, 8)
        .frame(width: 220, height: 26)
        .background(PaletteTheme.keycapFill, in: shape)
        .overlay(shape.strokeBorder(PaletteTheme.keycapBorder, lineWidth: 1))
    }
}
