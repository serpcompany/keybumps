# 0004: Snippets expand their keywords as you type

Status: Accepted (2026-10-03). Reverses the "text expansion" non-goal in `AGENTS.md`. Tracked by #170.

## Context

Snippets v1 (#190) let you search snippets and copy or paste them from the Command Palette. A snippet's keyword only helped search, because `AGENTS.md` listed text expansion as a Mac app non-goal: expansion has to read every key you type in every app, and change the text in other apps. The owner, coming from Alfred's "Automatically expand snippets by keyword", decided on 2026-10-03 that this is a feature to build now. The decisions and the proposal are recorded on #170.

## Decisions

1. **One switch, off by default.** Settings › Snippets › Expand keywords as you type turns expansion on for every snippet with a keyword, sensitive ones included. There are no options (excluded apps, word boundaries, a switch for each snippet, sound, or key timing) until the owner asks for them.
2. **A listen-only keyboard tap.** `KeyTypingMonitor` is a session-wide, listen-only event tap for key presses and clicks, so it can never delay or change typing (the lesson of #212). It needs Input Monitoring. It runs only while Snippets and the switch are on and Input Monitoring and Accessibility are granted (`KeywordExpansionController.shouldListen`). Keybumps never prompts for either permission; Settings offers the usual System Settings setup.
3. **Matching.** `KeywordBuffer` keeps the last characters typed, never more than the longest keyword. A keyword matches exactly, case included, the moment it's complete, even in the middle of a word, as in Alfred, and the longest match wins. Return, Tab, Escape, keys that move the caret, ⌘ or ⌃ shortcuts, clicks, switching apps, and keys Keybumps posts itself all clear it.
4. **Replacing.** The shared paste step (`TextPasting.replaceTyped`) presses Delete once per keyword character, then pastes the snippet the way ⌘Return does: kept out of Clipboard History, and marked concealed for a sensitive snippet, whose text comes from the Keychain. Every key Keybumps posts carries `SystemTextPaster.syntheticEventMarker`, so the tap ignores it, and `Infrastructure/TextPaster.swift` remains the only file that posts keys (`PermissionPromptSourceTests`).
5. **The clipboard is put back.** After each expansion, `PasteboardSnapshot` puts back everything that was on the clipboard, unless something new was copied meanwhile, and Clipboard History skips that change.
6. **Never expands** in Keybumps' own windows, the Command Palette included (it's a key window that never makes Keybumps active), or during secure input (password fields). A key that reaches Keybumps more than 0.1 s late isn't matched, since more typing may already have landed after it.
7. **Privacy.** The typed characters live only in memory, are cleared after each match or reset, and are forgotten when listening stops. Nothing typed is logged or saved, and expansion has no logging at all.

## Consequences

- Keybumps now reads keystrokes in other apps while the switch is on. Turning the switch off, turning Snippets off, or revoking Input Monitoring stops the tap.
- Snippets, which needed no permission, can now show missing Input Monitoring and Accessibility in Settings, but only while the switch is on.
- **Known limits:**
  - **Changed keywords:** Delete counts the keyword's characters as typed. An app that changes them as you type, such as smart dashes turning `--` into `—`, can leave a character off or delete one too many.
  - **Slow apps:** an app that reads the paste more than 0.5 s late (Screen Sharing, a busy VM) can paste the restored clipboard instead.
  - Both are on the owner's hit list rather than worked around.
- Unit tests and the UI-test composition never listen to the keyboard (`InertKeyTypingMonitor`) or post keys (`InertTextPaster`). Real typing, password fields, and the clipboard coming back are on the owner's hit list for a signed build.
