import SwiftUI

/// The Snippets page: its command, then every snippet in a searchable table with + and − and
/// Edit…, which open the editor sheet, and Import from Alfred… (`AlfredSnippetImport`). The table
/// sorts by column (`SnippetTableSort`) and selects several snippets at once, which −, Delete, and
/// the context menu's Delete… and Mark as Sensitive / Not Sensitive act on together
/// (`SnippetTableSelection`). Everything here is saved on this Mac only.
struct SnippetsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: Set<Snippet.ID> = []
    @State private var sortOrder: [SnippetTableSort] = []
    @State private var pendingDeletion: SnippetTableSelection?
    @State private var errorMessage: String?
    @State private var confirmsStartOver = false
    @State private var choosesAlfredExport = false
    @State private var importAlert: SnippetImportAlert?

    var body: some View {
        @Bindable var store = model.snippets
        let rows = SnippetTableSort.sorted(SnippetSearch.settingsResults(store.snippets, query: query), by: sortOrder)
        let selected = SnippetTableSelection(selection, in: rows)
        let isWritable = store.libraryState.isWritable
        SettingsPage {
            CapabilityControl(capability: .snippets, shortcuts: [.snippets])
            // Accessibility is optional: without it, ⌘P copies instead of pasting. Expanding needs
            // it too, so while auto-expansion is on, its row below also asks for it.
            PluginPermissionsGroup(capability: .snippets)
            SettingsGroup("Auto-expansion") {
                Toggle(isOn: Binding(
                    get: { model.preferences.expandsSnippetKeywords },
                    set: { isOn in
                        model.preferences.expandsSnippetKeywords = isOn
                        model.applyCapabilities()
                    }
                )) {
                    SettingsRowLabel(
                        title: "Expand keywords as you type",
                        subtitle: "Type a snippet’s keyword in any app and Keybumps replaces it with the snippet, then puts your clipboard back. Never in password fields or in Keybumps itself."
                    )
                }
                .toggleStyle(SettingsSwitchToggleStyle())
                .accessibilityIdentifier("snippets.expansion")
                if model.preferences.enabledCapabilities.contains(.snippets) {
                    let missing = SnippetsModule.missingExpansionPermissions(model.capabilityContext)
                    if model.preferences.expandsSnippetKeywords, missing.isEmpty, !model.keywordExpansion.isListening {
                        LabeledContent {
                            Button("Restart Keybumps") { model.restartForPermissionRelaunch() }
                        } label: {
                            SettingsNote("Keybumps can’t hear typing yet. macOS applies Input Monitoring after a restart.", tint: .orange)
                        }
                    }
                    ForEach(missing, id: \.self) { permission in
                        LabeledContent {
                            Button("Allow…") { Task { await model.recoverPermission(permission) } }
                                .disabled(model.permissions.activeRequest != nil)
                                .accessibilityLabel("Allow \(permission.title) so keywords expand")
                        } label: {
                            SettingsRowLabel(
                                title: "Expanding needs \(permission.title)",
                                subtitle: permission == .inputMonitoring
                                    ? "Lets Keybumps notice when you type a keyword."
                                    : "Lets Keybumps replace the keyword with the snippet."
                            )
                        }
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
                    if isWritable {
                        Text(SnippetTableSelection.countText(total: store.snippets.count, selected: selected.snippets.count))
                            .font(.system(size: SettingsTheme.subtitleSize))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("snippets.count")
                    }
                }
                if !isWritable {
                    // The group above says why. A library that can't be read isn't an empty one.
                    SettingsNote("Your snippets show here once Keybumps can read them.")
                } else if store.snippets.isEmpty {
                    SettingsRowLabel(
                        title: "No snippets yet",
                        subtitle: "Click + to save text you reuse. In the Command Palette’s Snippets tab, Return copies it and ⌘P pastes it."
                    )
                } else if rows.isEmpty {
                    SettingsNote("No matching snippets")
                } else {
                    table(rows, selected: selected)
                }
                HStack(spacing: 6) {
                    SettingsIconButton(systemImage: "plus", help: "New Snippet") {
                        store.editorRequest = .new
                    }
                    .disabled(!isWritable)
                    .accessibilityIdentifier("snippets.add")
                    SettingsIconButton(systemImage: "minus", help: "Delete Selected Snippets") {
                        confirmDeletion(selected)
                    }
                    .disabled(selected.isEmpty || !isWritable)
                    .accessibilityIdentifier("snippets.remove")
                    Spacer()
                    Button("Import from Alfred…") { choosesAlfredExport = true }
                        .disabled(!isWritable)
                        .help("Add the snippets from an Alfred snippets export (.alfredsnippets)")
                        .accessibilityIdentifier("snippets.importAlfred")
                    Button("Edit…") {
                        if let id = selected.editableID { store.editorRequest = .edit(id) }
                    }
                    .disabled(selected.editableID == nil || !isWritable)
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
            pendingDeletion?.deletionTitle ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { deletion in
            Button("Delete", role: .destructive) { delete(deletion.ids) }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.deletionMessage)
        }
        .fileImporter(isPresented: $choosesAlfredExport, allowedContentTypes: [AlfredSnippetImport.contentType]) { result in
            switch result {
            case .success(let url): importAlert = AlfredSnippetImport.importFile(at: url, into: store)
            case .failure: importAlert = .failed(AlfredSnippetImport.Failure.unreadable.message)
            }
        }
        .fileDialogMessage("Choose a snippet collection exported from Alfred.")
        .fileDialogConfirmationLabel("Import")
        .alert(
            importAlert?.title ?? "",
            isPresented: Binding(get: { importAlert != nil }, set: { if !$0 { importAlert = nil } }),
            presenting: importAlert
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private func table(_ rows: [Snippet], selected: SnippetTableSelection) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", sortUsing: SnippetTableSort(column: .name)) { snippet in
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
            TableColumn("Keyword", sortUsing: SnippetTableSort(column: .keyword)) { snippet in
                if let keyword = snippet.keyword {
                    SnippetKeywordChip(keyword: keyword)
                }
            }
            .width(min: 80, ideal: 110, max: 170)
            TableColumn("Snippet", sortUsing: SnippetTableSort(column: .snippet)) { snippet in
                Text(SnippetPresentation.preview(of: snippet))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Snippet.ID.self) { ids in
            // The clicked row, or every selected row when the click is inside the selection.
            let chosen = SnippetTableSelection(ids, in: rows)
            if !chosen.isEmpty {
                if let id = chosen.editableID {
                    Button("Edit…") { model.snippets.editorRequest = .edit(id) }
                }
                if chosen.canMarkSensitive {
                    Button("Mark as Sensitive") { setSensitive(true, chosen.ids) }
                }
                if chosen.canMarkNotSensitive {
                    Button("Mark as Not Sensitive") { setSensitive(false, chosen.ids) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDeletion(chosen) }
            }
        } primaryAction: { ids in
            if let id = SnippetTableSelection(ids, in: rows).editableID { model.snippets.editorRequest = .edit(id) }
        }
        .onDeleteCommand { confirmDeletion(selected) }
        .frame(height: Self.tableHeight(rows: rows.count))
        .accessibilityIdentifier("snippets.list")
    }

    /// Tall enough for a few rows, growing with the list up to twelve before it scrolls. A row with
    /// a keyword chip is about 30 points tall, and the header about 30.
    static func tableHeight(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 4), 12)) * 31 + 34
    }

    private func confirmDeletion(_ selection: SnippetTableSelection) {
        if !selection.isEmpty { pendingDeletion = selection }
    }

    private func delete(_ ids: Set<Snippet.ID>) {
        if perform({ try model.snippets.delete(ids) }) { selection.subtract(ids) }
    }

    private func setSensitive(_ isSensitive: Bool, _ ids: Set<Snippet.ID>) {
        perform { try model.snippets.setSensitive(isSensitive, for: ids) }
    }

    /// Runs a change to the library, showing why it failed, if it did.
    @discardableResult
    private func perform(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            errorMessage = nil
            return true
        } catch let error as SnippetStoreError {
            errorMessage = error.message
        } catch {
            errorMessage = SnippetStoreError.storage.message
        }
        return false
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
